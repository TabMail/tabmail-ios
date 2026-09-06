/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// THE APP-RELEASE BOUNDARY, COMPOSED WITH THE THINGS THAT ADMIT AND THE THINGS
/// THAT REPAIR.
///
/// `AppReleaseBoundaryTests` owns the boundary in isolation: stamps, atomicity,
/// fail-closed propagation, release identity. It deliberately installs nothing
/// into `AppDatabase.shared`, which is exactly why it cannot reach the three
/// properties this file exists for — every one of them needs a REAL producer or
/// a REAL repair path, and those all resolve their database through the
/// singleton:
///
/// 1. **A cold notification action.** `NotificationActionRouter.execute` is the
///    production dispatch for an ARCHIVE / DELETE / MARK_READ notification
///    button, and it admits durable work. Old rows must retire before it admits,
///    and what it admits must survive.
/// 2. **Pending NSE staging.** `NSEDataBridge.mergeNSEStagingData` is the merge
///    producer that admits a `setTag` operation for a message the extension
///    processed while the app was dead. Same two obligations, and a third: the
///    launch must not CONSUME the staged work on its way past.
/// 3. **The repair the boundary schedules.** Retiring an optimistic move leaves
///    local state the server never heard about; the boundary answers that by
///    marking every account full-sync-due, and the source folder's own sync is
///    what has to put the message back.
///
/// And one property that needs no singleton but belongs with them because it is
/// the same sentence in the same requirement list:
///
/// 4. **A never-uploaded draft.** Its `.saveDraft` operation is retired; the
///    authored content is not; and reopening/editing/saving admits fresh work.
///    Sync is NOT asserted to upload it — it cannot, and a test that pretended
///    otherwise would bless a behaviour the design explicitly refuses.
///
/// 🚨 EVERY ADMISSION HERE IS DRIVEN THROUGH ITS REAL PRODUCER. A hand-inserted
/// `PendingOperation` would prove only that `DELETE FROM pendingOperation`
/// deletes rows, which the sibling suite already establishes. What is at stake
/// in this file is the ORDER between a boundary and the production paths that
/// put work in the queue, so the production path has to be the one that runs.
///
/// `.serialized, .processGlobalState`: these tests swap `AppDatabase.shared`,
/// drive `AccountManager.shared`, touch `SearchIndex.shared` and mutate the
/// `markReadOnArchiveDelete` user default — the same reasons
/// `NotificationActionRouterTests` and `NSEMergeStageMemoTests` carry both
/// traits.
@Suite("App-release boundary — real admissions, sync repair, authored drafts",
       .serialized, .processGlobalState)
struct AppReleaseBoundaryAdmissionTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    private static let inboxPath = "INBOX"
    private static let archivePath = "Archive"
    private static let draftsPath = "Drafts"

    /// A release string that is not, and cannot become, the running bundle's.
    private static let previousRelease = "0.0.1 (1)"

    /// Opens a pool, runs the REAL `AppDatabase.init` (which stamps the current
    /// release on this never-stamped database), installs it as
    /// `AppDatabase.shared`, and seeds one account with the folders these tests
    /// need. Every test then sets the stamp explicitly rather than inheriting
    /// whatever the first launch happened to leave.
    ///
    /// `accountId` is unique per test because `SearchIndex.shared` is a
    /// process-global FTS database shared with every other suite.
    @MainActor
    private func fixture(accountId: String, provider: AccountProvider = .gmail) throws -> Fixture {
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
        // "Mark as read on archive & delete" ships default ON and composes an
        // extra `.markRead` ahead of every archive/delete. These tests assert on
        // the SET of admitted rows, so the extra op would not falsify anything —
        // it is forced OFF only so the counts below read as the single gesture
        // they describe, exactly as `NotificationActionRouterTests` does.
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        // A staged row left by another suite must not resolve a notification
        // action here (mirrors `InboxGestureActionTests.resetStagedGlobal`).
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Boundary admission",
                provider: provider)
            account.id = accountId
            account.lastFullSyncAt = Date()
            try account.insert(db)
            try Folder(name: "INBOX", path: Self.inboxPath, role: .inbox, accountId: accountId)
                .insert(db)
            try Folder(name: "Archive", path: Self.archivePath, role: .archive, accountId: accountId)
                .insert(db)
            try Folder(name: "Drafts", path: Self.draftsPath, role: .drafts, accountId: accountId)
                .insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    /// `extraQueues` carries any file-backed sibling opened inside the fixture
    /// directory (the NSE staging database), so the whole directory retires as
    /// one unlink unit rather than being removed out from under a live handle.
    private func finish(_ fixture: Fixture, extraQueues: [DatabaseQueue] = []) {
        UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool,
            queues: extraQueues, directory: fixture.directory)
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

    /// Two operations from the PREVIOUS release, one of which no current model
    /// can decode — the "legacy split child" stand-in that makes "retired
    /// without being decoded" a measured claim rather than a described one.
    private func seedPreviousReleaseWork(_ fixture: Fixture) throws {
        let ordinary = PendingOperation(
            type: .move, messageIds: ["old-1", "old-2"], accountId: fixture.accountId,
            folderPath: Self.inboxPath, destinationPath: Self.archivePath)
        try fixture.pool.writeWithoutTransaction { db in
            try ordinary.insert(db)
            try db.execute(sql: """
                INSERT INTO pendingOperation
                    (id, type, messageIdsJSON, accountId, folderPath, createdAt, status, retryCount)
                VALUES ('legacy-split-child', 'splitChildFromAnOlderRelease', '<not json>', ?,
                        ?, ?, 'queued', 0)
                """, arguments: [fixture.accountId, Self.inboxPath, Date()])
        }
    }

    private func operationIds(_ fixture: Fixture) throws -> [String] {
        try fixture.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM pendingOperation ORDER BY id")
        }
    }

    private func operations(_ fixture: Fixture) throws -> [PendingOperation] {
        try fixture.pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    private func lastFullSyncAt(_ fixture: Fixture) throws -> Date? {
        try fixture.pool.read { db in
            try Account.fetchOne(db, key: fixture.accountId)?.lastFullSyncAt
        }
    }

    // NON-ASYNC read helpers. GRDB's `read` has an `async` overload that wins
    // overload resolution inside an `async` test body, and an `await` there
    // cannot live in an `#expect` autoclosure. Naming each read as its own
    // synchronous function binds the synchronous overload once, at the
    // definition, and keeps the assertions readable.
    private func header(_ fixture: Fixture, id: String) throws -> MessageHeader? {
        try fixture.pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    private func headerExists(_ fixture: Fixture, id: String) throws -> Bool {
        try header(fixture, id: id) != nil
    }

    private func bodyExists(_ fixture: Fixture, contentKey: String) throws -> Bool {
        try fixture.pool.read { db in
            try MessageBody.fetchOne(db, key: ContentKey(rawValue: contentKey)) != nil
        }
    }

    /// Synchronous write, for the same overload-resolution reason as the reads
    /// above.
    private func write(_ fixture: Fixture, _ body: (Database) throws -> Void) throws {
        try fixture.pool.writeWithoutTransaction { db in try body(db) }
    }

    private func draftRow(_ fixture: Fixture, id: String) throws -> Draft? {
        try fixture.pool.read { db in try Draft.fetchOne(db, key: id) }
    }

    private func folderRow(_ fixture: Fixture, path: String) throws -> Folder? {
        try fixture.pool.read { db in
            try Folder.fetchOne(
                db, key: MessageIdentity.folderId(
                    accountId: fixture.accountId, folderPath: path))
        }
    }

    /// A durable, query-visible INBOX header — the shape a notification action
    /// resolves against (`headerComplete = true`).
    @discardableResult
    private func seedInboxHeader(
        _ fixture: Fixture, messageId: String, body: String? = nil
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "boundary \(messageId)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(), snippet: "snippet",
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: Self.inboxPath),
            accountId: fixture.accountId, folderPath: Self.inboxPath, isInInbox: true)
        header.rfc822MessageId = "\(messageId)@example.com"
        header.headerComplete = true
        header.bodyComplete = body != nil
        let stored = header
        try fixture.pool.writeWithoutTransaction { db in
            try stored.insert(db)
            if let body {
                try MessageBody(
                    contentKey: ContentKey(rawValue: stored.id),
                    htmlContent: body).insert(db)
            }
        }
        return stored
    }

    /// Wait for the queue to stop moving before relaunching. Production paths
    /// driven here (`performCoordinatedRoleMove`, `queueDraftSave`) kick an
    /// unstructured `drainPendingQueue`, and a relaunch that raced it would be
    /// measuring the drain rather than the boundary (`IOS-TEST-009`).
    @MainActor
    private func settle() async {
        for _ in 0..<200 {
            if await AccountManager.shared.pendingQueueIsQuiescentForTesting() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 1. A cold notification action

    /// **THE PROPERTY: on a launch that crosses a release boundary, the previous
    /// release's queued work is gone BEFORE anything can admit — and the
    /// operation a notification action admits afterwards survives the next
    /// ordinary launch.**
    ///
    /// 🚨 THE ADMISSION IS THE REAL ONE. `NotificationActionRouter.execute` is
    /// what `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// calls for an ARCHIVE button, and in production it runs only after
    /// `AppStartup.awaitLaunchReady` — i.e. strictly after the boundary inside
    /// `AppDatabase.init`. Driving it in that order here is what makes "old rows
    /// retire before new admission" a statement about production sequencing
    /// rather than about two hand-written INSERTs.
    ///
    /// The two directions this fails in are opposite and both are asserted:
    /// a boundary that does not fire hands a previous binary's operations to
    /// this one; a boundary that fires on EVERY launch destroys the tap the user
    /// just made. The second relaunch is what separates them — it is an ordinary
    /// same-release open, and the admitted row must come through it untouched.
    ///
    /// RED PROOF (recorded): removing the `guard recorded != currentRelease`
    /// early return from `retirePreviousReleaseActionQueue` — i.e. purging on
    /// every launch — fails `survivors == admitted` with `[]`. Skipping the
    /// boundary entirely (`return false` as the body) fails
    /// `afterBoundary.isEmpty` with the two previous-release rows.
    @Test("A cold notification action admitted after the boundary survives, and the previous release's rows do not")
    @MainActor
    func coldNotificationActionAdmittedAfterTheBoundarySurvives() async throws {
        let f = try fixture(accountId: "boundary-notif")
        defer { finish(f) }

        try seedInboxHeader(f, messageId: "notif-1")
        try seedPreviousReleaseWork(f)
        #expect(try operationIds(f).count == 2, "the fixture must actually have previous-release work to retire")
        try setStamp(f, to: Self.previousRelease)

        // THE LAUNCH. Production runs this before the pool is published, so
        // nothing in the process can have admitted yet.
        _ = try AppDatabase(dbPool: f.pool)

        let afterBoundary = try operationIds(f)
        #expect(afterBoundary.isEmpty, """
            a previous release's queued operations survived the launch and are \
            now claimable by this binary's drain: \(afterBoundary)
            """)
        #expect(try stamp(f) == AppDatabase.currentAppRelease,
                "the boundary must record the release it retired for")

        // THE ADMISSION — the production notification-action dispatch, run in
        // the order production runs it: after the launch is ready.
        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", messageId: "notif-1", accountId: f.accountId)
        await settle()

        let admittedOps = try operations(f)
        #expect(admittedOps.count == 1, """
            the notification action admitted \(admittedOps.count) operations \
            instead of the one archive it dispatched: \(admittedOps.map(\.type.rawValue))
            """)
        guard admittedOps.count == 1 else { return }
        #expect(admittedOps[0].type == .move, "the archive must be admitted as a move")
        #expect(admittedOps[0].messageIds == ["notif-1"])
        #expect(admittedOps[0].destinationPath == Self.archivePath)
        let admitted = admittedOps.map(\.id)

        // THE NEXT ORDINARY LAUNCH. Same release, so the boundary must not fire.
        _ = try AppDatabase(dbPool: f.pool)

        let survivors = try operationIds(f)
        #expect(survivors == admitted, """
            the row admitted by the notification action after the boundary did \
            not survive the next same-release launch. Expected \(admitted), got \
            \(survivors) — a boundary that fires here destroys every gesture the \
            user made since the upgrade.
            """)
    }

    // MARK: - 2. Pending NSE staging

    /// Create the staging database the notification-service extension writes,
    /// at a path this test owns. `mergeNSEStagingData` takes an explicit
    /// override because the unit-test host has no App-Group entitlement.
    private func makeStagingFile(in directory: URL) throws -> (path: String, queue: DatabaseQueue) {
        let path = directory.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        return (path, try DatabaseQueue(path: path))
    }

    /// A terminal staged row: header, rendered body, AI complete, and an
    /// `actionTag` — which is the field `queueSetTagPendingOp` fires on. Mirrors
    /// `NSEMergeStageMemoTests.stageHeaderRow` + `stageAIRow`.
    private func stageProcessedMessage(
        _ queue: DatabaseQueue, accountId: String, messageId: String, tag: String
    ) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated,
                     summaryBlurb, summaryTodos, actionTag)
                VALUES (?, ?, ?, 'gmail', ?, ?, 'INBOX',
                        'Staged subject', 'Alice', 'alice@example.com', 'staged snippet', ?,
                        ?, 1, 1, 1, 'A short summary', 'todo one', ?)
                """, arguments: [
                    "\(accountId):\(messageId)", accountId, "\(accountId)@example.com",
                    messageId, "\(messageId)@example.com",
                    Double(1_710_000_000), Date().timeIntervalSince1970, tag
                ])
        }
    }

    private func stagedRowCount(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nse_processed_message") ?? -1
        }
    }

    /// **THE PROPERTY: a launch that crosses the boundary with NSE work still
    /// staged retires the previous release's queue, admits nothing on its way
    /// past, and leaves the staged work intact — and the operation the merge then
    /// admits survives the next ordinary launch.**
    ///
    /// 🚨 THE STAGED-WORK-UNTOUCHED ASSERTION IS THE POINT, and it is the one the
    /// design document names: the stamp read must NOT go through
    /// `PrioritizedDatabase`'s async `read`, because that overload calls
    /// `NSEDataBridge.mergeIfStagingPending` FIRST and the merge ADMITS. A
    /// boundary that read through it would let a staged notification action enter
    /// the queue and then delete it in the same transaction — a brand-new
    /// intention destroyed by the mechanism meant to retire only OLD ones.
    ///
    /// ⚠️ MEASURED HONESTLY: in the unit-test host `containerURL(for:)` resolves
    /// to nil, so a read-through merge would find no staging file at the DEFAULT
    /// path and bail regardless. That leg therefore cannot fail here for the
    /// wrong-channel reason alone, and this test does not claim it does. What it
    /// DOES establish, against a live producer, is the composed requirement: the
    /// staged work is still owed after the launch, the launch admitted nothing,
    /// the real merge then admits it, and the boundary does not come back for it.
    ///
    /// RED PROOF (recorded): purging on every launch (drop the
    /// `guard recorded != currentRelease`) fails `survivors == admitted` with
    /// `[]` — the merged notification action is destroyed by the next ordinary
    /// open. A boundary body of `return false` fails `afterBoundary.isEmpty`.
    @Test("With NSE work still staged, the boundary retires old rows, consumes nothing, and the merged admission survives")
    @MainActor
    func pendingNSEStagingRetiresOldRowsAndTheMergedAdmissionSurvives() async throws {
        let f = try fixture(accountId: "boundary-nse")
        let (stagingPath, stagingQueue) = try makeStagingFile(in: f.directory)
        defer { finish(f, extraQueues: [stagingQueue]) }
        NSEDataBridge.resetStageMemoForTesting()
        try stageProcessedMessage(
            stagingQueue, accountId: f.accountId, messageId: "nse-1", tag: "reply")
        #expect(try stagedRowCount(stagingQueue) == 1,
                "the fixture must actually have pending NSE staging, or the premise is absent")

        try seedPreviousReleaseWork(f)
        #expect(try operationIds(f).count == 2, "the fixture must actually have previous-release work to retire")
        try setStamp(f, to: Self.previousRelease)

        // THE LAUNCH, with staged work outstanding.
        _ = try AppDatabase(dbPool: f.pool)

        let afterBoundary = try operationIds(f)
        #expect(afterBoundary.isEmpty, """
            a previous release's queued operations survived a launch that had NSE \
            work pending: \(afterBoundary)
            """)
        #expect(try stagedRowCount(stagingQueue) == 1, """
            the launch consumed the staged notification work. Whatever it merged \
            was admitted INSIDE the boundary's own window and deleted with the \
            previous release's rows — a brand-new intention destroyed by the \
            mechanism that exists to retire only old ones.
            """)

        // THE ADMISSION — the real merge producer, which is what admits a
        // `setTag` operation for a message the extension processed while the app
        // was dead.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: stagingPath)
        await settle()

        let admittedOps = try operations(f)
        let expectedId = "setTag:\(f.accountId):nse-1:reply"
        #expect(admittedOps.map(\.id) == [expectedId], """
            the merge did not admit the staged action tag through its own \
            deterministic id. Without that admission this test proves nothing \
            about survival. Got: \(admittedOps.map(\.id))
            """)
        guard admittedOps.count == 1 else { return }
        #expect(admittedOps[0].type == .setTag)
        #expect(admittedOps[0].messageIds == ["nse-1"])
        let admitted = admittedOps.map(\.id)

        // THE NEXT ORDINARY LAUNCH.
        _ = try AppDatabase(dbPool: f.pool)

        let survivors = try operationIds(f)
        #expect(survivors == admitted, """
            the operation the NSE merge admitted after the boundary did not \
            survive the next same-release launch. Expected \(admitted), got \
            \(survivors).
            """)
    }

    // MARK: - 3. The repair the boundary schedules

    /// **THE PROPERTY: after the boundary retires an optimistic move, the source
    /// folder's own sync puts the message back where the server actually holds
    /// it, in a state the app can show — never missing, and never a row that
    /// claims a body it does not have.**
    ///
    /// 🚨 THIS IS WHY THE BOUNDARY IS ALLOWED TO DESTROY THE QUEUE AT ALL. The
    /// accepted cost is "the user may have to repeat a gesture", and that costing
    /// is only honest if the *local* consequence of a half-done gesture is
    /// repaired: a move that was applied locally and never sent leaves the
    /// message sitting in a folder the server has never heard of. The boundary's
    /// answer is `Account.lastFullSyncAt = NULL`, committed in the SAME
    /// transaction as the delete, and the repair is the ordinary full sync that
    /// follows. If the repair did not happen, the message would be invisible in
    /// the folder it is really in until something else happened to sync — which
    /// is indistinguishable, to the user, from losing it.
    ///
    /// BOTH ENDS ARE THE REAL THING. The optimistic move is produced by
    /// `NotificationActionRouter.execute` (the production ARCHIVE dispatch, which
    /// re-keys the local row and queues the durable `.move`), and the repair is
    /// `SyncEngine.runSyncMessages` — the production per-folder sync body, not a
    /// simulation of it.
    ///
    /// The body assertion is stated as the INVARIANT rather than as a mechanism:
    /// the restored row must either carry its content or be marked as still
    /// owing it. "`bodyComplete` is true with no `MessageBody`" is the shape that
    /// would leave a permanently blank message no pipeline ever re-fetches, and
    /// it is the only outcome this forbids — a row restored with
    /// `bodyComplete == false` is correct, because the existing body queue owns
    /// it from there.
    ///
    /// ⚠️ SCOPE, MEASURED RATHER THAN ASSUMED. The reconciliation arm that
    /// performs this repair is the ORPHAN RECLAIM in `runSyncMessages` — the
    /// remnant keeps the source-qualified primary key (`optimisticMoveToFolder`
    /// updates `folderId`/`folderPath`/`isInInbox` IN PLACE and leaves the id
    /// alone; the re-key to the destination only happens at drain time from
    /// `COPYUID`), so the source folder's own pass finds it under
    /// `MessageHeader.fetchOne(db, key: header.id)` and re-homes it. That arm is
    /// gated on `providerAddressOwnershipProven`, which answers `true`
    /// unconditionally for `.date` providers and, for `.uid` (IMAP), requires
    /// `row.folderId == folderId && row.folderPath == folderPath` — which a
    /// drifted remnant cannot satisfy. This test therefore drives the account's
    /// OWN window mode (`.gmail` ⇒ `.date`); it does not claim the IMAP case,
    /// where the same-pass reclaim is refused by that C3 proof and repair
    /// depends on the destination folder's own reconcile removing the remnant
    /// first. Asserting the IMAP leg here would either bless a refusal or force
    /// a widening of an epoch guard, and neither is this PR's subject.
    ///
    /// RED PROOF (recorded): with `UPDATE account SET lastFullSyncAt = NULL`
    /// removed from the boundary transaction, `syncDue == nil` fails — the
    /// account is never marked due, so nothing schedules the repair this test
    /// then performs by hand.
    @Test("After the boundary retires an optimistic move, the source folder's sync restores membership and body access")
    @MainActor
    func retiredOptimisticMoveIsRepairedBySourceFolderSync() async throws {
        let f = try fixture(accountId: "boundary-repair")
        defer { finish(f) }

        let seeded = try seedInboxHeader(f, messageId: "repair-1", body: "<p>the body the user had</p>")
        let inboxHeaderId = seeded.id

        // THE OPTIMISTIC MOVE, through the production dispatch: the local row
        // leaves INBOX for Archive and a durable `.move` is queued.
        await NotificationActionRouter.execute(
            actionId: "ARCHIVE", messageId: "repair-1", accountId: f.accountId)
        await settle()

        let queuedBefore = try operations(f)
        #expect(queuedBefore.count == 1 && queuedBefore.first?.type == .move, """
            the fixture must actually hold an optimistic move whose durable \
            operation the boundary can retire: \(queuedBefore.map(\.type.rawValue))
            """)
        let optimistic = try header(f, id: inboxHeaderId)
        #expect(optimistic?.folderPath == Self.archivePath && optimistic?.isInInbox == false, """
            the local row did not leave INBOX, so this fixture never produced the \
            optimistic state the repair is for: \
            folderPath=\(optimistic?.folderPath ?? "<missing>") \
            isInInbox=\(String(describing: optimistic?.isInInbox))
            """)

        // THE BOUNDARY.
        try setStamp(f, to: Self.previousRelease)
        _ = try AppDatabase(dbPool: f.pool)
        #expect(try operationIds(f).isEmpty, "the move was not retired, so nothing needs repairing")
        let syncDue = try lastFullSyncAt(f)
        #expect(syncDue == nil, """
            the account was not marked full-sync-due, so nothing schedules the \
            repair for the optimistic move that just went away
            """)

        // THE REPAIR — the production per-folder sync, against a server that
        // still holds the message in the SOURCE folder, because the move the
        // boundary retired never reached it.
        let inbox = try folderRow(f, path: Self.inboxPath)
        guard let inbox else {
            Issue.record("the INBOX folder row is missing, so there is no sync to run")
            return
        }
        let mock = MockEmailProvider(staleWindowMode: .date)
        await mock.setFetchMessagesResult([
            MessageHeaderInfo(
                messageId: "repair-1", rfc822MessageId: "repair-1@example.com",
                inReplyTo: nil, references: [], threadId: nil,
                subject: "boundary repair-1", from: "Sender", fromAddress: "sender@example.com",
                to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
                date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "snippet",
                isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: nil)
        ])
        _ = try await SyncEngine.runSyncMessages(
            for: inbox, provider: mock, limit: 50,
            dbPool: PrioritizedDatabase(pool: f.pool))

        // MEMBERSHIP — the message is back in the folder the server holds it in,
        // and it is query-visible rather than a half-written row.
        let restored = try header(f, id: inboxHeaderId)
        #expect(restored != nil, """
            the source-folder sync did not restore the message the retired move \
            had optimistically taken out of INBOX. The server holds it there, and \
            nothing local names it any more.
            """)
        guard let restored else { return }
        #expect(restored.folderPath == Self.inboxPath && restored.isInInbox, """
            the restored row is not in the source folder: \
            folderPath=\(restored.folderPath) isInInbox=\(restored.isInInbox)
            """)
        #expect(restored.headerComplete, """
            the restored row is not query-visible, so the message is still \
            missing as far as the user is concerned
            """)

        // BODY ACCESS — the invariant, not the mechanism: the row either has its
        // content or is still marked as owing it. A `bodyComplete` row with no
        // body is a permanently blank message no fetch will ever repair.
        let hasBody = try bodyExists(f, contentKey: restored.id)
        #expect(hasBody || !restored.bodyComplete, """
            the restored row claims a complete body it does not have \
            (bodyComplete=\(restored.bodyComplete), body row present=\(hasBody)). \
            Nothing will re-fetch it, so the message stays permanently blank.
            """)
    }

    // MARK: - 4. A never-uploaded draft

    /// **THE PROPERTY: the boundary retires a never-uploaded draft's `.saveDraft`
    /// operation and keeps everything the user typed — and saving again admits
    /// fresh work that survives.**
    ///
    /// 🚨 THE ACCEPTED COST IS EXACTLY ONE THING, AND THIS PINS ITS EDGES. What
    /// is lost is the automatic push intention. What is NOT lost is the `Draft`
    /// row, its body, its subject, or the optimistic header and body the save
    /// minted — and the recovery is the user reopening and saving, which is the
    /// same "repeat the gesture" cost the whole boundary is priced on.
    ///
    /// ⚠️ WHAT THIS DELIBERATELY DOES NOT ASSERT: that sync uploads the draft.
    /// It cannot — sync reconciles what the server has, and this draft never
    /// reached the server (`serverDraftId` is nil throughout, asserted). A test
    /// that waited for an upload would be asserting the draft sweeper the design
    /// explicitly refuses to add.
    ///
    /// The admission is `AccountManager.queueDraftSave`, the production Save
    /// path, on both sides of the boundary — so "reopening/editing/saving admits
    /// new work" is measured through the same door the user goes through.
    ///
    /// RED PROOF (recorded): with the boundary body replaced by `return false`,
    /// `retiredSave` fails — the original `.saveDraft` is still queued after the
    /// upgrade. Adding `pendingOperation`-shaped cleanup that also touched
    /// `Draft` would fail `survivingDraft?.body == authoredBody`.
    @Test("A never-uploaded draft's save is retired while its authored content remains, and saving again admits new work")
    @MainActor
    func aNeverUploadedDraftsSaveIsRetiredWhileItsContentRemains() async throws {
        let f = try fixture(accountId: "boundary-draft", provider: .imap)
        defer { finish(f) }

        let authoredBody = "Zanzibarquixotic body the user typed"
        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: "boundary-unsent-draft", accountId: f.accountId,
            toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Never uploaded", body: authoredBody,
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = "E-boundary-draft"
        let stored = draft
        try write(f) { db in try stored.insert(db) }

        // THE ADMISSION — the production Save path.
        let admittedFirst = await AccountManager.shared.queueDraftSave(
            draftId: stored.id, accountId: f.accountId)
        #expect(admittedFirst, "the fixture must actually admit a save, or there is nothing to retire")
        await settle()

        let beforeOps = try operations(f)
        #expect(beforeOps.map(\.type) == [.saveDraft], """
            the fixture must hold exactly the save intention: \
            \(beforeOps.map(\.type.rawValue))
            """)
        guard let originalSave = beforeOps.first else { return }
        // The optimistic header + body the save minted. Authored content, and
        // therefore outside the carve-out.
        let placeholderHeaderId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: f.accountId, draftsFolderPath: Self.draftsPath,
            draftId: stored.id, instanceEpoch: "E-boundary-draft")
        #expect(try headerExists(f, id: placeholderHeaderId),
                "the save must have minted its optimistic header, or the survival half is vacuous")

        // THE BOUNDARY.
        try setStamp(f, to: Self.previousRelease)
        _ = try AppDatabase(dbPool: f.pool)

        let retiredSave = try operations(f)
        #expect(retiredSave.isEmpty, """
            the never-uploaded draft's save operation survived the upgrade: \
            \(retiredSave.map(\.type.rawValue))
            """)

        // THE CONTENT SURVIVES — byte for byte, and still unsent.
        let survivingDraft = try draftRow(f, id: stored.id)
        #expect(survivingDraft != nil, "the authored draft was destroyed with its save intention")
        #expect(survivingDraft?.body == authoredBody, """
            the authored body changed across the boundary: \
            \(String(describing: survivingDraft?.body))
            """)
        #expect(survivingDraft?.subject == "Never uploaded")
        #expect(survivingDraft?.serverDraftId == nil, """
            this draft is supposed to have NEVER reached the server; if it has an \
            id, the never-uploaded premise is gone and so is the point of the test
            """)
        #expect(try headerExists(f, id: placeholderHeaderId), """
            the optimistic draft header was destroyed by a boundary whose scope \
            is queue state only — it carries the user's authored subject and \
            recipients, and its content key owns the draft's body row
            """)
        #expect(try bodyExists(f, contentKey: placeholderHeaderId),
                "the authored draft body row was destroyed with the queue")

        // THE RECOVERY — reopening, editing and saving admits fresh work. This
        // is the whole of the accepted cost: one repeated gesture.
        try write(f) { db in
            try db.execute(
                sql: "UPDATE draft SET body = ?, updatedAt = ? WHERE id = ?",
                arguments: ["\(authoredBody) — and one more line", Date().timeIntervalSince1970,
                            stored.id])
        }
        let admittedAgain = await AccountManager.shared.queueDraftSave(
            draftId: stored.id, accountId: f.accountId)
        #expect(admittedAgain, "saving again must admit fresh work")
        await settle()

        let afterOps = try operations(f)
        #expect(afterOps.map(\.type) == [.saveDraft], """
            saving again did not admit a save: \(afterOps.map(\.type.rawValue))
            """)
        guard let freshSave = afterOps.first else { return }
        #expect(freshSave.id != originalSave.id, """
            the "fresh" save is the retired row's id, so nothing new was admitted
            """)
        #expect(freshSave.draftId == stored.id, "the fresh save does not name the user's draft")

        // And it is current-release work, so the next ordinary launch keeps it.
        _ = try AppDatabase(dbPool: f.pool)
        let afterRelaunch = try operationIds(f)
        #expect(afterRelaunch == [freshSave.id], """
            the re-admitted save did not survive the next same-release launch: \
            \(afterRelaunch)
            """)
    }
}
