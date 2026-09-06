/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// THE APP-UPGRADE RETIREMENT BOUNDARY — the owner-approved lifecycle carve-out.
///
/// On a change of installed release, every `pendingOperation` row queued by the
/// PREVIOUS release is deleted without being decoded, and every account is
/// marked full-sync-due. It runs inside `AppDatabase.init`, on the raw pool,
/// before the pool is published and therefore before anything in this process
/// can admit or claim work.
///
/// 🚨 IT IS NOT A FIFTH EXIT, and these tests are written so that reading them
/// cannot suggest otherwise. The four exits answer *"may the drain retire THIS
/// operation, on THIS attempt, given what the provider said?"*. Nothing here
/// asks that question: the boundary consults no evidence, no epoch, no identity
/// and no provider result, it destroys the queue AS A WHOLE, and it runs outside
/// the drain. Every test below therefore asserts a LIFECYCLE property — what a
/// launch does — never a per-operation disposition.
///
/// The properties, and the direction each one fails in:
///
/// - **A changed release retires the queue.** Failing this leaves a previous
///   binary's operations to execute under semantics they were never written for.
/// - **An unchanged release does NOT.** Failing this destroys live work on an
///   ordinary relaunch — the far worse direction, and the reason the stamp is
///   compared rather than a flag being cleared.
/// - **Delete and stamp commit together or not at all.** A partial commit that
///   recorded the new release while retaining old rows would make the boundary
///   un-rerunnable and strand exactly the work it exists to retire.
/// - **The carve-out stops at queue state.** Authored drafts, outbox rows,
///   headers and their content keep their existing lifecycle.
@Suite("App-upgrade action-queue retirement boundary", .serialized)
struct AppReleaseBoundaryTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
    }

    private static let accountId = "release-boundary-account"
    private static let folderPath = "INBOX"

    /// A release string that is not, and cannot become, the running bundle's.
    private static let previousRelease = "0.0.1 (1)"

    /// Opens a pool and runs `AppDatabase.init` once, which migrates the schema
    /// and — on a database that has never been stamped — takes the boundary. The
    /// fixture then seeds against a database that is already at the CURRENT
    /// release, so each test controls the stamp explicitly rather than inheriting
    /// whatever the first init happened to leave.
    @MainActor
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "boundary@example.com", displayName: "Boundary", provider: .imap)
            account.id = Self.accountId
            account.lastFullSyncAt = Date()
            try account.insert(db)
            try Folder(
                name: Self.folderPath, path: Self.folderPath, role: .inbox,
                accountId: Self.accountId
            ).insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous)
    }

    private func finish(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func setStamp(_ fixture: Fixture, to release: String?) throws {
        try fixture.pool.writeWithoutTransaction { db in
            if let release {
                try db.execute(sql: """
                    INSERT INTO appReleaseStamp (id, release) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET release = excluded.release
                    """, arguments: [release])
            } else {
                try db.execute(sql: "DELETE FROM appReleaseStamp")
            }
        }
    }

    private func stamp(_ fixture: Fixture) throws -> String? {
        try fixture.pool.read { db in
            try String.fetchOne(db, sql: "SELECT release FROM appReleaseStamp WHERE id = 1")
        }
    }

    @discardableResult
    private func seedOperation(
        _ fixture: Fixture, messageIds: [String], type: OperationType = .move
    ) throws -> PendingOperation {
        let op = PendingOperation(
            type: type, messageIds: messageIds, accountId: Self.accountId,
            folderPath: Self.folderPath,
            destinationPath: type == .move ? "Archive" : nil,
            observedUidValidity: 10)
        try fixture.pool.writeWithoutTransaction { db in try op.insert(db) }
        return op
    }

    /// A row no current model can decode — an unknown `type` and a
    /// `messageIdsJSON` that is not JSON. This is the "legacy split child"
    /// stand-in, and it is what makes "without decoding them" a MEASURED claim
    /// rather than a described one: any implementation that fetched these rows as
    /// `PendingOperation` before deleting them would throw here instead of
    /// retiring them.
    private func seedUndecodableOperation(_ fixture: Fixture, id: String) throws {
        let template = try seedOperation(fixture, messageIds: ["placeholder"])
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                UPDATE pendingOperation
                   SET id = ?, type = 'splitChildFromAnOlderRelease', messageIdsJSON = '<not json>'
                 WHERE id = ?
                """, arguments: [id, template.id])
        }
    }

    private func operationCount(_ fixture: Fixture) throws -> Int {
        try fixture.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pendingOperation") ?? -1
        }
    }

    private func operationIds(_ fixture: Fixture) throws -> [String] {
        try fixture.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM pendingOperation ORDER BY id")
        }
    }

    private func lastFullSyncAt(_ fixture: Fixture) throws -> Date? {
        try fixture.pool.read { db in
            try Account.fetchOne(db, key: Self.accountId)?.lastFullSyncAt
        }
    }

    @discardableResult
    private func seedAuthoredContent(_ fixture: Fixture) throws -> (draftId: String, outboxId: String) {
        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: "boundary-draft", accountId: Self.accountId,
            toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Authored subject", body: "Authored body the user typed",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = "E-boundary"
        var outbox = OutboxMessage(
            accountId: Self.accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Queued send", body: "Body"))
        outbox.id = "boundary-outbox"
        var header = MessageHeader(
            messageId: "41", subject: "mail that must survive", from: "Sender",
            fromAddress: "sender@example.com", to: "boundary@example.com",
            date: Date(), snippet: "snippet",
            folderId: MessageIdentity.folderId(
                accountId: Self.accountId, folderPath: Self.folderPath),
            accountId: Self.accountId, folderPath: Self.folderPath, isInInbox: true)
        header.headerComplete = true
        let storedDraft = draft
        let storedOutbox = outbox
        let storedHeader = header
        try fixture.pool.writeWithoutTransaction { db in
            try storedDraft.insert(db)
            try storedOutbox.insert(db)
            try storedHeader.insert(db)
        }
        return (storedDraft.id, storedOutbox.id)
    }

    private func authoredContentSurvives(_ fixture: Fixture) throws -> Bool {
        try fixture.pool.read { db in
            try Draft.fetchOne(db, key: "boundary-draft") != nil
                && OutboxMessage.fetchOne(db, key: "boundary-outbox") != nil
                && MessageHeader.fetchCount(db) == 1
        }
    }

    // MARK: - 1. A changed release retires the queue and marks full sync due

    /// **THE PROPERTY: crossing a release boundary empties the action queue,
    /// marks every account full-sync-due, and touches nothing the user authored
    /// — and it does all of it without decoding a single queued row.**
    ///
    /// The undecodable row is the load-bearing part. "Retire without decoding" is
    /// the whole reason this can be a blanket predicate-free delete instead of a
    /// migration that has to understand every historical operation shape, and the
    /// only way to hold an implementation to it is to seed a row that decoding
    /// would fail on.
    ///
    /// RED PROOF (recorded): with the boundary's body replaced by
    /// `return false`, the queue still holds all three rows after the relaunch and
    /// `lastFullSyncAt` is still set — `operationCount == 0` fails with 3.
    @Test("A changed release retires every queued action row without decoding it, and marks full sync due")
    @MainActor
    func changedReleaseRetiresTheQueue() throws {
        let f = try fixture()
        defer { finish(f) }

        try seedAuthoredContent(f)
        try seedOperation(f, messageIds: ["51", "52"])
        try seedOperation(f, messageIds: ["53"], type: .markRead)
        try seedUndecodableOperation(f, id: "legacy-split-child")
        #expect(try operationCount(f) == 3, "the fixture must actually have work to retire")

        // The previous release's stamp. The relaunch below is therefore an
        // UPGRADE, whatever the running bundle's version happens to be.
        try setStamp(f, to: Self.previousRelease)

        // The relaunch. `AppDatabase.init` is the boundary's only production
        // caller, so driving it is what makes this a test of the launch.
        _ = try AppDatabase(dbPool: f.pool)

        let survivors = try operationIds(f)
        #expect(survivors.isEmpty, """
            a previous release's queued operations must not execute under this \
            binary's semantics. Rows left: \(survivors)
            """)
        #expect(try lastFullSyncAt(f) == nil, """
            retiring the queue leaves optimistic local state the server never \
            heard about; the accounts must be marked full-sync-due in the SAME \
            transaction so the server's own state is what wins.
            """)
        #expect(try stamp(f) == AppDatabase.currentAppRelease,
                "the boundary must record the release it retired for, or it fires again next launch")
        #expect(try authoredContentSurvives(f), """
            the carve-out is scoped to QUEUE STATE. A retired `.saveDraft` loses \
            only the automatic push intention — the authored draft, the queued \
            send and the user's mail all keep their existing lifecycle.
            """)
    }

    // MARK: - 2. An unchanged release does not purge

    /// **THE PROPERTY: an ordinary relaunch of the SAME release keeps every
    /// queued operation, with its own id, and leaves the accounts' sync state
    /// alone.**
    ///
    /// This is the direction that costs users their work if it is wrong, and it
    /// is why the boundary compares a recorded release rather than clearing a
    /// flag: a crash, a force-quit, a background relaunch and a foreground
    /// resume all reopen the database, and none of them are upgrades.
    ///
    /// RED PROOF (recorded): removing the `guard recorded != currentRelease`
    /// early return turns the boundary into a per-launch clear — the row is gone
    /// and `after == [op.id]` fails with `[]`.
    @Test("An unchanged release keeps the queue and does not mark full sync due")
    @MainActor
    func unchangedReleaseDoesNotPurge() throws {
        let f = try fixture()
        defer { finish(f) }

        let op = try seedOperation(f, messageIds: ["61", "62"])
        let syncedAt = try lastFullSyncAt(f)
        #expect(syncedAt != nil, "the fixture must have a full-sync timestamp to preserve")
        try setStamp(f, to: AppDatabase.currentAppRelease)

        _ = try AppDatabase(dbPool: f.pool)

        #expect(try operationIds(f) == [op.id], """
            reopening the same release is not an upgrade. Destroying the queue \
            here would lose a user's gesture on every relaunch, crash recovery and \
            background wake.
            """)
        #expect(try lastFullSyncAt(f) == syncedAt,
                "an unchanged release must not force a full sync either")
    }

    // MARK: - 3. A missing stamp is an upgrade boundary

    /// **THE PROPERTY: a database that has never recorded a release is treated as
    /// having crossed one.**
    ///
    /// First adoption of this rule cannot know which release queued the rows it
    /// finds, and "unknown" must fail in the safe direction here: retiring work
    /// whose provenance we cannot establish costs the user a repeated gesture,
    /// while executing it costs an operation running under semantics it was not
    /// written for. A genuinely fresh database is already empty, so the delete is
    /// a no-op — test 4 pins that half.
    ///
    /// RED PROOF (recorded): changing the guard to `guard let recorded, recorded
    /// != currentRelease` (treating a missing stamp as "nothing to do") leaves the
    /// row in place and `operationCount == 0` fails with 1.
    @Test("A database with no recorded release retires its queue")
    @MainActor
    func missingStampIsAnUpgradeBoundary() throws {
        let f = try fixture()
        defer { finish(f) }

        try seedOperation(f, messageIds: ["71"])
        try setStamp(f, to: nil)

        _ = try AppDatabase(dbPool: f.pool)

        #expect(try operationCount(f) == 0)
        #expect(try stamp(f) == AppDatabase.currentAppRelease)
    }

    // MARK: - 4. Work admitted after the boundary survives the next launch

    /// **THE PROPERTY: the boundary precedes admission, and what is admitted
    /// AFTER it survives.**
    ///
    /// This is the ordering the whole design rests on: the boundary runs inside
    /// `AppDatabase.init`, before the pool is published, so a row admitted by
    /// anything in this process — a cold notification action, an NSE staging
    /// merge, a user gesture — is by construction current-release work. The next
    /// same-release launch must leave it alone.
    ///
    /// RED PROOF (recorded): with the stamp written in a transaction of its own
    /// that runs BEFORE the delete, an interrupted upgrade leaves the stamp
    /// current with rows retained, and this test's sibling (test 5) fails; with
    /// the release comparison removed entirely, the row admitted here is destroyed
    /// and `operationIds == [fresh.id]` fails with `[]`.
    @Test("A row admitted after the boundary survives the next same-release launch")
    @MainActor
    func rowAdmittedAfterTheBoundarySurvives() throws {
        let f = try fixture()
        defer { finish(f) }

        // Cross a boundary first, so the queue starts empty exactly as it does
        // after a real upgrade.
        try seedOperation(f, messageIds: ["81"])
        try setStamp(f, to: Self.previousRelease)
        _ = try AppDatabase(dbPool: f.pool)
        #expect(try operationCount(f) == 0, "the upgrade half of this test did not happen")

        // New work, admitted under the current release.
        let fresh = try seedOperation(f, messageIds: ["82"])

        // The next ordinary launch.
        _ = try AppDatabase(dbPool: f.pool)

        #expect(try operationIds(f) == [fresh.id], """
            work admitted after the boundary belongs to THIS release and must \
            survive. A boundary that fired again here would delete every gesture \
            made since the upgrade.
            """)
    }

    // MARK: - 5. The delete and the stamp commit together or not at all

    /// **THE PROPERTY: a retirement that cannot complete records nothing, so the
    /// next launch retries the whole thing.**
    ///
    /// The failure is injected where it is actually possible — at the DELETE, with
    /// a trigger that aborts it — and the assertion is the pair: the rows are
    /// still there AND the stamp still names the previous release. The dangerous
    /// half is the second one. A stamp written outside the delete's transaction
    /// would make the boundary believe it had already run, and the previous
    /// release's operations would then execute on the launch after next, which is
    /// precisely the work this whole mechanism exists to stop.
    ///
    /// RED PROOF (recorded): moving the stamp write into its own `pool.write`
    /// BEFORE the delete's fails this at the stamp assertion — `"0.0.1 (1)"` has
    /// become the current release while both rows survive — and then at the
    /// re-run assertion, because the retry reads a current stamp and skips the
    /// retirement entirely. It also fails `refused`, since with the stamp already
    /// advanced the second transaction returns early and never attempts the
    /// delete that would have thrown.
    ///
    /// ⚠️ MEASURED, NOT ASSUMED, IN THE OTHER DIRECTION TOO: putting the stamp in
    /// its own `pool.write` AFTER the delete's does NOT fail this test, because
    /// the delete's transaction throws first and the stamp write is never
    /// reached. That ordering is still wrong — nothing makes the two writes
    /// atomic, and a crash between them lands in exactly the un-rerunnable state
    /// above — but this test is not what catches it, and recording that it is
    /// would be a red claim the tree does not support.
    @Test("A failed retirement commits neither the delete nor the stamp, and the next launch retries it")
    @MainActor
    func failedRetirementCommitsNothing() throws {
        let f = try fixture()
        defer { finish(f) }

        try seedOperation(f, messageIds: ["91"])
        try seedOperation(f, messageIds: ["92"])
        try setStamp(f, to: Self.previousRelease)

        try f.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_pending_delete BEFORE DELETE ON pendingOperation
                BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END
                """)
        }

        var refused = false
        do {
            try AppDatabase.retirePreviousReleaseActionQueue(
                on: f.pool, currentRelease: AppDatabase.currentAppRelease)
        } catch {
            refused = true
        }
        #expect(refused, """
            the storage failure must PROPAGATE. Swallowing it would leave \
            `AppDatabase.init` believing the boundary ran; there is no `try?` and \
            no retry ladder here for the same reason the migrations above it have \
            none.
            """)

        #expect(try operationCount(f) == 2,
                "the delete failed, so both operations must still be owed")
        #expect(try stamp(f) == Self.previousRelease, """
            recording the new release while the delete failed would make the \
            boundary un-rerunnable: the next launch would see a current stamp, skip \
            the retirement, and hand a previous release's operations to this \
            binary's drain.
            """)

        // The next launch, with the storage failure cleared, completes it.
        try f.pool.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER refuse_pending_delete")
        }
        _ = try AppDatabase(dbPool: f.pool)

        #expect(try operationCount(f) == 0,
                "an interrupted retirement must be retried, not silently skipped")
        #expect(try stamp(f) == AppDatabase.currentAppRelease)
    }
}
