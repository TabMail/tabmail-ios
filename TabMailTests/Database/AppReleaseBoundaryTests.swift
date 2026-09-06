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
///
/// 🚨 NO `AppDatabase.shared` SWAP, AND THAT IS DELIBERATE. The boundary is
/// driven by constructing `AppDatabase` on a LOCAL pool, and every assertion
/// below reads that same local pool, so the singleton is never needed. Installing
/// the fixture into it anyway would make this suite a process-global mutator
/// without the `.processGlobalState` scope that serializes them — and
/// `.serialized` orders a suite's own children, not sibling suites, so an
/// annotated suite mid-drain could have `AccountManager` resolve `dbPool` to this
/// fixture. Not swapping is what makes plain `.serialized` sufficient here.
@Suite("App-upgrade action-queue retirement boundary", .serialized)
struct AppReleaseBoundaryTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
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
        _ = try AppDatabase(dbPool: pool)
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
        return Fixture(pool: pool, directory: directory)
    }

    /// Ordinary local-pool teardown. `InstalledTestDatabaseLifetime` is for
    /// fixtures INSTALLED into `AppDatabase.shared`, which this one is not: its
    /// only reason to retain a pool until process exit is escaped production work
    /// that reached it through the singleton, and nothing here publishes it.
    private func finish(_ fixture: Fixture) {
        TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory)
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
    /// would be a red claim the tree does not support. What DOES catch it is the
    /// sibling below whose failure is injected at the STAMP, i.e. after the
    /// delete and the account update have already run:
    /// `aBoundaryFailingAfterTheDeleteCommitsNothingThroughTheRealInitializer`.
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

    // MARK: - 6. The REAL initializer, failing AFTER the deletion

    /// Refuse the stamp write — the LAST statement of the boundary's transaction,
    /// reached only after the delete and the account update have already run.
    ///
    /// Both trigger events are created because the boundary's stamp write is an
    /// UPSERT: it INSERTs on a database that has never been stamped and UPDATEs
    /// the conflicting row on one that has, and a fixture that armed only one of
    /// them would silently stop refusing the moment the other path was taken.
    private func armStampRefusal(_ fixture: Fixture) throws {
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_stamp_insert BEFORE INSERT ON appReleaseStamp
                BEGIN SELECT RAISE(ABORT, 'simulated storage failure at the stamp'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER refuse_stamp_update BEFORE UPDATE ON appReleaseStamp
                BEGIN SELECT RAISE(ABORT, 'simulated storage failure at the stamp'); END
                """)
        }
    }

    private func clearStampRefusal(_ fixture: Fixture) throws {
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER refuse_stamp_insert")
            try db.execute(sql: "DROP TRIGGER refuse_stamp_update")
        }
    }

    /// Run the real launch and report whether it refused to open the database.
    private func launchRefused(_ fixture: Fixture) -> Bool {
        do {
            _ = try AppDatabase(dbPool: fixture.pool)
            return false
        } catch {
            return true
        }
    }

    /// **THE PROPERTY: a boundary that fails AFTER it has already deleted commits
    /// NONE of it, and the launch it belongs to refuses to open the database at
    /// all.**
    ///
    /// 🚨 THIS IS THE HALF THE EARLIER TEST CANNOT SEE. Its failure is injected at
    /// the DELETE, which is the transaction's FIRST statement, so it is satisfied
    /// by an implementation that commits the delete and the account update in one
    /// transaction and the stamp in another — the shape whose crash window leaves
    /// a database stamped current with the previous release's operations still in
    /// it, i.e. the boundary permanently un-rerunnable for exactly the rows it
    /// exists to retire. It also calls the static helper directly and drops the
    /// trigger before the real initializer runs, so it says nothing about whether
    /// `AppDatabase.init` PROPAGATES the failure. An `init` that swallowed it
    /// would publish a pool whose previous-release actions are eligible to run,
    /// which is the whole failure this mechanism exists to prevent.
    ///
    /// All three facts are compared after the rollback — queue rows, account sync
    /// timestamps, and the stamp — because the boundary writes all three and a
    /// partial commit of any one of them is a different, and separately
    /// dangerous, half-done state.
    ///
    /// LIVENESS, second: once the storage failure clears, the next REAL launch
    /// completes the retirement atomically, and the launch after that leaves the
    /// work admitted since alone.
    ///
    /// RED PROOF (recorded): with the stamp written in a `pool.write` of its own
    /// AFTER the delete's, the launch still throws but the queue is EMPTY and
    /// `lastFullSyncAt` is nil after the rollback — the delete and the account
    /// update committed without the stamp. With the boundary call in
    /// `AppDatabase.init` wrapped in `try?`, `launchRefused` is false and the
    /// initializer returns a pool whose previous-release rows are still runnable.
    @Test("A launch whose boundary fails at the stamp commits nothing and refuses to open the database")
    @MainActor
    func aBoundaryFailingAfterTheDeleteCommitsNothingThroughTheRealInitializer() throws {
        let f = try fixture()
        defer { finish(f) }

        let doomed = try seedOperation(f, messageIds: ["101", "102"])
        try seedUndecodableOperation(f, id: "legacy-late-failure")
        try seedAuthoredContent(f)
        let syncedAt = try lastFullSyncAt(f)
        #expect(syncedAt != nil, "the fixture must have a full-sync timestamp whose rollback can be checked")
        let before = try operationIds(f)
        #expect(before.count == 2, "the fixture must actually have work to retire")
        try setStamp(f, to: Self.previousRelease)

        try armStampRefusal(f)

        // 🚨 THE LAUNCH ITSELF MUST FAIL. A swallowed boundary error publishes a
        // database whose previous-release operations are still eligible to run,
        // which is indistinguishable from never having had a boundary.
        #expect(launchRefused(f), """
            `AppDatabase.init` returned a usable database even though the release \
            boundary could not commit. Every previous-release row is now claimable \
            by this binary's drain.
            """)

        // NOTHING COMMITTED — all three writes rolled back together.
        let afterRollback = try operationIds(f)
        #expect(afterRollback == before, """
            the delete committed without the stamp. The next launch then reads a \
            stamp naming the PREVIOUS release, re-runs the boundary, and the \
            damage is invisible — but the mirror ordering, stamp first, strands \
            these rows forever. Got: \(afterRollback)
            """)
        #expect(try lastFullSyncAt(f) == syncedAt, """
            the accounts were marked full-sync-due by a retirement that never \
            happened, forcing a full re-sync for nothing
            """)
        #expect(try stamp(f) == Self.previousRelease, """
            recording the new release while the retirement failed makes the \
            boundary un-rerunnable: the next launch sees a current stamp, skips \
            the retirement, and hands a previous release's operations to this \
            binary's drain.
            """)

        // The storage failure clears; the next REAL launch completes all of it.
        try clearStampRefusal(f)
        _ = try AppDatabase(dbPool: f.pool)

        #expect(try operationCount(f) == 0, "an interrupted retirement must be retried, not silently skipped")
        #expect(try lastFullSyncAt(f) == nil, "the retirement landed without marking the accounts full-sync-due")
        #expect(try stamp(f) == AppDatabase.currentAppRelease,
                "the boundary must record the release it retired for, or it fires again next launch")
        #expect(try authoredContentSurvives(f),
                "the carve-out is scoped to QUEUE STATE; authored drafts, queued sends and mail keep their lifecycle")
        #expect(doomed.id != "", "silences the unused-binding warning without weakening the ids comparison above")

        // And the launch after that is an ordinary one: work admitted since the
        // boundary belongs to THIS release and must survive.
        let fresh = try seedOperation(f, messageIds: ["103"])
        _ = try AppDatabase(dbPool: f.pool)
        let afterRelaunch = try operationIds(f)
        #expect(afterRelaunch == [fresh.id], """
            a same-release relaunch destroyed work admitted after the boundary: \
            \(afterRelaunch)
            """)
    }

    /// **THE PROPERTY: the same fail-closed propagation when the failure is at
    /// the DELETE — driven through the REAL initializer.**
    ///
    /// The sibling above pins the ordering; this one pins only the propagation,
    /// at the other end of the same transaction. Test 5 injects the same failure
    /// but calls the static helper directly and removes the trigger before it ever
    /// constructs an `AppDatabase`, so a `try?` around the boundary call inside
    /// `init` survives it. Here the failure is standing WHILE the initializer
    /// runs.
    ///
    /// RED PROOF (recorded): with the boundary call in `AppDatabase.init` wrapped
    /// in `try?`, `launchRefused` is false — the pool is published with both
    /// previous-release rows intact and eligible to run.
    @Test("A launch whose boundary fails at the delete refuses to open the database")
    @MainActor
    func aBoundaryFailingAtTheDeleteRefusesTheLaunch() throws {
        let f = try fixture()
        defer { finish(f) }

        try seedOperation(f, messageIds: ["111"])
        try seedOperation(f, messageIds: ["112"])
        let syncedAt = try lastFullSyncAt(f)
        try setStamp(f, to: Self.previousRelease)

        try f.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_pending_delete_in_init BEFORE DELETE ON pendingOperation
                BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END
                """)
        }

        #expect(launchRefused(f), """
            `AppDatabase.init` swallowed a boundary failure and published the pool \
            anyway. There is no `try?` here for the same reason the migrations \
            above it have none: a database that cannot take this write must not go \
            on to release claims into unretired state.
            """)
        #expect(try operationCount(f) == 2, "the delete failed, so both operations must still be owed")
        #expect(try lastFullSyncAt(f) == syncedAt, "the accounts were marked full-sync-due by a retirement that never happened")
        #expect(try stamp(f) == Self.previousRelease, "the stamp advanced past a retirement that never happened")

        try f.pool.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER refuse_pending_delete_in_init")
        }
        _ = try AppDatabase(dbPool: f.pool)
        #expect(try operationCount(f) == 0, "an interrupted retirement must be retried, not silently skipped")
        #expect(try stamp(f) == AppDatabase.currentAppRelease)
    }


    // MARK: - 8. The release IDENTITY is both bundle keys, and the build is half of it

    /// The running bundle's two version keys, read by NAME by the test rather
    /// than taken from the code under test.
    private func bundleVersionKeys() -> (marketing: String, build: String) {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "",
                info?["CFBundleVersion"] as? String ?? "")
    }

    /// **THE PROPERTY: two builds of the SAME marketing version are different
    /// releases, and the boundary fires between them.**
    ///
    /// 🚨 THIS IS THE COMMON UPGRADE, NOT AN EDGE CASE. A marketing version
    /// changes a few times per cycle; the build number changes on every
    /// TestFlight and App Store submission. If the release string carried only
    /// the marketing version, every one of those upgrades would compare EQUAL,
    /// the boundary would never fire, and the previous binary's operations would
    /// execute under the new one — silently, and for most upgrades.
    ///
    /// The stamp is BUILT from the running bundle's marketing version and a
    /// DIFFERENT build, so the two releases agree on everything except the half
    /// under test. Its control is `unchangedReleaseDoesNotPurge` above, which
    /// stamps the exact current pair and must NOT purge — without that pair this
    /// test would also be satisfied by a release string that never compares equal
    /// to anything, which destroys the queue on every launch.
    ///
    /// RED PROOF (recorded): with `build` dropped from
    /// `AppDatabase.appRelease(marketingVersion:build:)`, the seeded stamp and the
    /// running release become the same string, the boundary does not fire, and
    /// `operationCount == 0` fails with 1.
    @Test("A build-only upgrade of the same marketing version retires the queue")
    @MainActor
    func aBuildOnlyUpgradeIsAReleaseBoundary() throws {
        let f = try fixture()
        defer { finish(f) }

        let keys = bundleVersionKeys()
        #expect(!keys.marketing.isEmpty, "the host bundle has no marketing version, so this test is vacuous")
        #expect(!keys.build.isEmpty, "the host bundle has no build number, so this test is vacuous")

        try seedOperation(f, messageIds: ["121"])
        // SAME marketing version, DIFFERENT build. Derived from the running
        // bundle so the two releases differ in exactly one half.
        let previousBuild = AppDatabase.appRelease(
            marketingVersion: keys.marketing, build: keys.build + "0")
        #expect(previousBuild != AppDatabase.currentAppRelease, """
            the release string ignores the build, so \(previousBuild) and \
            \(AppDatabase.currentAppRelease) are the same release. Every \
            build-only upgrade then keeps the previous binary's queue.
            """)
        try setStamp(f, to: previousBuild)

        _ = try AppDatabase(dbPool: f.pool)

        #expect(try operationCount(f) == 0, """
            a previous BUILD's queued operations survived the upgrade. Two builds \
            of one marketing version are different binaries with different queue \
            semantics.
            """)
        #expect(try stamp(f) == AppDatabase.currentAppRelease)
    }

    /// **THE PROPERTY: `currentAppRelease` is the running bundle's marketing
    /// version AND its build, and each half is what makes two releases differ.**
    ///
    /// Both halves are checked without asking the code under test what it thinks
    /// they are. The bundle keys are read here BY NAME, and the formatter is
    /// exercised on pairs that differ in exactly one component — so an
    /// implementation that dropped either key fails, where a test comparing
    /// `currentAppRelease` to itself, or to a hand-written `"0.0.1 (1)"`, would
    /// not notice at all.
    ///
    /// The equal-pair leg is the two-sided control: a formatter that returned
    /// something unique per call would satisfy every "these differ" assertion
    /// while making the boundary fire on every launch and destroy the queue each
    /// time.
    ///
    /// RED PROOF (recorded): with `build` dropped from the formatter,
    /// `differsOnBuild != same` fails, and the production-property leg fails
    /// because the value no longer contains the bundle's build number.
    @Test("The release string carries both bundle version keys, and differs when either changes")
    func releaseIdentityIsBothBundleKeys() throws {
        let keys = bundleVersionKeys()
        #expect(!keys.marketing.isEmpty, "the host bundle has no marketing version, so this test is vacuous")
        #expect(!keys.build.isEmpty, "the host bundle has no build number, so this test is vacuous")

        // The pure formatter, on pairs the running process does not have.
        let same = AppDatabase.appRelease(marketingVersion: "9.9.9", build: "1000")
        let differsOnBuild = AppDatabase.appRelease(marketingVersion: "9.9.9", build: "1001")
        let differsOnMarketing = AppDatabase.appRelease(marketingVersion: "9.9.10", build: "1000")
        #expect(differsOnBuild != same, """
            two builds of one marketing version compare EQUAL, so the boundary \
            never fires for a TestFlight or App Store rebuild
            """)
        #expect(differsOnMarketing != same,
                "two marketing versions compare EQUAL, so the boundary never fires at all")
        #expect(AppDatabase.appRelease(marketingVersion: "9.9.9", build: "1000") == same, """
            the same pair produced two different strings, so every relaunch is an \
            upgrade and the queue is destroyed each time
            """)

        // The production property reads the REAL keys — asserted against the
        // formatter proven build-sensitive above, and against each raw value.
        #expect(AppDatabase.currentAppRelease == AppDatabase.appRelease(
            marketingVersion: keys.marketing, build: keys.build), """
            `currentAppRelease` is not the running bundle's (CFBundleShortVersionString, \
            CFBundleVersion) pair: \(AppDatabase.currentAppRelease)
            """)
        #expect(AppDatabase.currentAppRelease.contains(keys.marketing),
                "the release string omits the bundle's marketing version")
        #expect(AppDatabase.currentAppRelease.contains(keys.build),
                "the release string omits the bundle's build number")
    }

}
