/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// THE OUTLOOK QUEUE HANDOFF (`IOS-GRAPH-005`) — end to end, against a Graph
/// server that reallocates a message's id on every move.
///
/// **What changed and why these tests exist.** Outlook now shares one drain lane
/// per `(account, message id)` instead of per `(account, folder, message id)`
/// (`IOS-QUEUE-008`'s amendment). That guarantees an operation naming a message
/// runs AFTER an in-flight move of the same message. On Microsoft Graph that
/// guarantee is only safe because the move's retirement REWRITES every queued
/// follower's `messageIds` to the id the wire just proved
/// (`MessageHeaderRekey.readdressQueuedOperations`) and the executor claims the
/// LIVE front row — reading it inside the claim transaction, after that rewrite
/// committed, never from a snapshot. Without both halves, serialization
/// converts an inherited RACE into a DETERMINISTIC dropped intention: the
/// follower goes out naming the id the move invalidated, Graph answers 404, and
/// the single-message conflict arm deletes the user's newest gesture.
///
/// **Every test states the SYSTEM PROPERTY, never the mechanism** (`MIS-015`). In
/// particular nothing here asserts "the operation's `messageIdsJSON` was
/// rewritten"; a test written that way stays green on a wrong spec. The oracles
/// are the wire (what the server holds, at which id, in which folder) and the
/// durable queue (what is still owed).
///
/// **WHY THE DESTINATION FOLDERS ARE NOT SEEDED AS LOCAL `Folder` ROWS.** Lifted
/// deliberately from `FinishTheMoveLocallyGraphTests`, for its reason:
/// `drainPendingQueue` ends by SYNCING every destination folder it touched, and
/// that sync is a repair strictly downstream of the defect (`MIS-024`). Against a
/// fake server holding one message it always succeeds, so a fixture that let it
/// run would repair the drop itself and every assertion below would pass on
/// broken code for a reason unrelated to the fix. Omitting the destination
/// `Folder` row makes the post-drain lookup miss and skips the sync, which is the
/// only thing it changes.
@Suite("Outlook queue handoff — IOS-GRAPH-005", .serialized, .processGlobalState)
struct OutlookQueueHandoffTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    /// Graph folder ids ARE the folder paths on Exchange.
    private static let source = "graph-source-folder"
    private static let firstDestination = "graph-archive-folder"
    private static let secondDestination = "graph-trash-folder"

    /// How long a "nothing happened while the move was held" oracle waits before
    /// it is believed.
    ///
    /// 🚨 THIS BOUND IS THE ORACLE, so it is stated once and reasoned about once.
    /// Under the folder-qualified lane key the follower is a SEPARATE lane whose
    /// `Task` is launched in the same loop iteration as the held move's, so it
    /// reaches the wire within milliseconds — 400 ms is three orders of magnitude
    /// of margin. Under the account-qualified key the follower cannot run at all
    /// until the predecessor's lane iteration returns, so no amount of waiting
    /// changes the answer. The window therefore separates the two regimes without
    /// depending on scheduling luck in either. It is far inside
    /// `SyncConfig.pendingOperationTimeoutSeconds` (15 s), so a held move never
    /// turns into a queue timeout, which would silently change what is measured.
    private static let concurrencySettleMilliseconds = 400

    @MainActor
    private func fixture(accountId: String) throws -> Fixture {
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
                emailAddress: "graph-handoff@example.com", displayName: "Graph handoff",
                provider: .outlook)
            account.id = accountId
            try account.insert(db)
            // Source only — see the suite comment.
            try Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: accountId
            ).insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.accountId)
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    @MainActor
    private func register(_ provider: ExchangeProvider, _ fixture: Fixture) async {
        await AccountManager.shared.registerProviderForTesting(
            accountId: fixture.accountId, provider: provider)
    }

    /// A local header seeded as an Exchange sync leaves it: addressed by its Graph
    /// resource id, with NO epoch (Exchange has no UIDVALIDITY space).
    ///
    /// `accountId` defaults to the fixture's own account and is only ever passed
    /// by the multi-account test, which seeds a SECOND Outlook account into the
    /// same pool so the drain has two disjoint lanes to retain proofs for.
    @discardableResult
    private func seedHeader(
        _ fixture: Fixture, graphId: String, rfc: String, accountId: String? = nil
    ) throws -> MessageHeader {
        let owner = accountId ?? fixture.accountId
        var header = MessageHeader(
            messageId: graphId,
            subject: "graph handoff \(graphId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "graph-handoff@example.com",
            date: Date(),
            snippet: "graph handoff body",
            folderId: MessageIdentity.folderId(
                accountId: owner, folderPath: Self.source),
            accountId: owner,
            folderPath: Self.source,
            isInInbox: true)
        header.rfc822MessageId = rfc
        let seeded = header
        try fixture.pool.writeWithoutTransaction { db in try seeded.insert(db) }
        return seeded
    }

    private func rows(_ fixture: Fixture) throws -> [MessageHeader] {
        try fixture.pool.read { db in
            try MessageHeader.order(Column("id").asc).fetchAll(db)
        }
    }

    private func queuedOperationCount(_ fixture: Fixture) throws -> Int {
        try fixture.pool.read { db in try PendingOperation.fetchCount(db) }
    }

    /// Drain until the queue is empty AND no drain is in flight. The quiescence
    /// read comes FIRST so the barrier cannot re-arm itself.
    @MainActor
    private func drainToQuiescence(_ fixture: Fixture) async throws {
        for _ in 0..<300 {
            let isEmpty = try await fixture.pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Where the server says every copy of this message currently sits.
    private func serverFolders(
        _ server: StatefulExchangeActionServer, rfc: String
    ) -> [String] {
        server.snapshots(rfc822MessageId: rfc).map(\.folderId).sorted()
    }

    /// The message's CURRENT Graph id, whatever the churn has made it.
    private func liveId(
        _ server: StatefulExchangeActionServer, rfc: String
    ) -> String? {
        server.snapshots(rfc822MessageId: rfc).first?.providerMessageId
    }

    /// Block until the fixture has parked `count` moves in the route, or give up.
    private func awaitHeldMoves(
        _ server: StatefulExchangeActionServer, count: Int
    ) async throws -> Bool {
        for _ in 0..<600 {
            if server.heldMoveCount() >= count { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// THE NEVER-DROP ORACLE — stated once here and reused by every test below,
    /// because restating it per test is how the two halves drift apart.
    ///
    /// **SAFETY:** for every gesture the test issued, EITHER the server shows its
    /// effect at the message's current id, OR a `PendingOperation` still names
    /// that message so the intention can still execute. A gesture that is neither
    /// visible on the server nor still owed has been DESTROYED.
    ///
    /// **LIVENESS, asserted separately because the two failure modes are
    /// opposites and one assertion cannot see both:** the safety half alone is
    /// satisfied forever by an operation that retries against a dead address, and
    /// under account-qualified lanes such an operation starves every later
    /// operation on that message. A starved intention has not been preserved
    /// either (the wedge corollary). So the queue must also be EMPTY once the
    /// drain quiesces.
    private func expectGesturePreservedAndExecuted(
        _ fixture: Fixture,
        effectVisibleOnServer: Bool,
        gesture: String,
        serverState: @autoclosure () -> String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) throws {
        let stillOwed = try queuedOperationCount(fixture) > 0
        #expect(effectVisibleOnServer || stillOwed, """
            \(gesture) was DESTROYED: the server does not show its effect \
            (\(serverState())) and no PendingOperation survives to retry it. A 404 \
            on an address this app invalidated by moving the message is not \
            evidence that the queued work is done.
            """, sourceLocation: sourceLocation)
        #expect(effectVisibleOnServer, """
            \(gesture) is preserved but has not TERMINATED — it is queued against \
            an address that can never resolve, which starves every later \
            operation on this message. Server: \(serverState()).
            """, sourceLocation: sourceLocation)
        #expect(!stillOwed, """
            the queue did not drain after \(gesture) — the intention is retained \
            rather than executed. Server: \(serverState()).
            """, sourceLocation: sourceLocation)
    }

    // MARK: - T1 — a follower queued behind a move runs at the address the move proved

    /// **THE PROPERTY: a mark-read queued behind a move of the same message does
    /// not reach the wire while the move is unresolved, and then reaches it at the
    /// address the move PROVED.**
    ///
    /// Both halves are load-bearing and they fail in opposite directions.
    /// *Ordering* is what account-qualified lanes buy: without it the two ops are
    /// separate lanes, launched as concurrent `Task`s, and the read races the move
    /// — sometimes landing on the pre-move id, sometimes on nothing.
    /// *Re-addressing* is what makes that ordering safe: with it and without the
    /// handoff, the read is GUARANTEED to run after the id was reallocated, 404,
    /// and be deleted by the conflict arm — strictly worse than the race.
    @Test("Outlook: a mark-read queued behind a move waits for it, then lands at the id the move proved")
    @MainActor
    func markReadQueuedBehindAMoveLandsAtTheProvenId() async throws {
        let rfc = "graph-handoff-follower@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-follower")
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // NO PROVIDER IS REGISTERED YET, so both gestures queue without
        // executing — the shape a user produces on a plane, and the only shape in
        // which a follower is guaranteed to be in the same drain pass as its
        // predecessor. ("OFFLINE" here means exactly that and nothing about
        // connectivity: `NetworkMonitor.checkConnected()` is `true` throughout the
        // test process, because nothing calls `NetworkMonitor.shared.start()` and
        // its backing mutex keeps its `true` default. The drain's connectivity
        // guard always passes; the claim loop's `providers[op.accountId] != nil`
        // is what holds these gestures.)
        await AccountManager.shared.move([seeded], to: Self.firstDestination)

        let optimistic = try rows(f)
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markRead([optimistic[0]])
        #expect(try queuedOperationCount(f) == 2,
                "both gestures must be durably queued before the provider exists, or this test proves nothing")

        await register(server.provider(), f)
        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }

        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so the 'while held' oracle below is vacuous")
        try await Task.sleep(for: .milliseconds(Self.concurrencySettleMilliseconds))

        // ORDERING, while the move is unresolved. The follower must not have
        // reached the wire at all — not at the old id, not at any id.
        let patchesWhileHeld = server.http.servedCallSequence().filter { $0.hasPrefix("PATCH ") }
        #expect(patchesWhileHeld.isEmpty, """
            the mark-read raced its own predecessor's move instead of serializing \
            behind it: \(patchesWhileHeld). Two operations naming ONE Graph message \
            must share one lane (IOS-QUEUE-008).
            """)
        #expect(server.snapshot(providerMessageId: "graph-1")?.isRead == false,
                "the follower already mutated the pre-move resource while the move was still unresolved")

        release()
        _ = await drain.value
        try await drainToQuiescence(f)

        // NON-VACUITY, wire side: the move landed and Graph really did reallocate
        // the id, so the follower had a dead address available to fail on.
        #expect(serverFolders(server, rfc: rfc) == [Self.firstDestination],
                "the move never landed, so nothing below distinguishes the handoff from doing nothing")
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so this test is not exercising the churn")

        let current = liveId(server, rfc: rfc)
        #expect(current != "graph-1")
        let readLanded = current.flatMap { server.snapshot(providerMessageId: $0)?.isRead } == true
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: readLanded, gesture: "the mark-read",
            serverState: "id=\(String(describing: current)) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T2 — two queued moves of one message, in issue order

    /// **THE PROPERTY: two moves of one Outlook message never run concurrently,
    /// and the LATEST destination is where the message ends up.**
    ///
    /// This is `IOS-QUEUE-008` in the Graph id space. Folder-qualified, the two
    /// ops key on `source` and `firstDestination` and land in different connected
    /// components — which the drain of the day dispatched as concurrent tasks, so
    /// whichever finished last won, including the OLDER gesture. The global
    /// single-operation executor runs one operation at a time in `queuePosition`
    /// order, so the ordering no longer depends on the key at all; the key still
    /// decides which rows DEFER together, and this fixture still bounds it.
    ///
    /// ⚠️ THE ORACLE HERE IS THE OUTCOME, NOT A WIRE-LEVEL OVERLAP COUNT, and that
    /// is a measured constraint rather than a preference. A `URLProtocol`
    /// transport does not admit a second request into a route while an earlier one
    /// is blocked inside `startLoading()`, so "no two `/move`s were in the route at
    /// once" is something the TRANSPORT guarantees regardless of the lane key — it
    /// cannot distinguish a serialized queue from a raced one. The falsifiable
    /// Outlook serialization oracles are `T1` (a follower's PATCH must not reach
    /// the wire at all while its predecessor's move is unresolved — a DIFFERENT
    /// request, which the transport does let through) and
    /// `PendingQueueLaneTests.outlookSameIdInTwoFoldersSharesOneLane` (the lane
    /// key itself).
    ///
    /// ⚠️ CORRECTED — those two are NOT both red witnesses for the CLASSIFIER.
    /// `outlookSameIdInTwoFoldersSharesOneLane` INJECTS the set it is testing
    /// against (`accountScopedIdAccountIds: ["acc-outlook"]`) and never calls
    /// `AccountManager.accountScopedIdAccountIds`, so it pins `buildLanes`' pure
    /// grouping and stays green no matter which providers the classifier admits.
    /// Removing `.outlook` from the set is caught by `T1`, which drives a real
    /// drain through the classifier, and by
    /// `AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`,
    /// which asserts the membership directly. The three cover different things
    /// and only the latter two bound the classifier.
    @Test("Outlook: two queued moves of one message run in issue order and the latest destination wins")
    @MainActor
    func twoQueuedMovesOfOneMessageSerializeAndTheLatestWins() async throws {
        let rfc = "graph-handoff-two-moves@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-two-moves")
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        let afterFirst = try rows(f)
        #expect(afterFirst.count == 1)
        guard afterFirst.count == 1 else { return }
        await AccountManager.shared.move([afterFirst[0]], to: Self.secondDestination)
        #expect(try queuedOperationCount(f) == 2,
                "both moves must be durably queued offline, or this test proves nothing")

        await register(server.provider(), f)
        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }

        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the first move was never parked, so this is not the in-flight window")

        release()
        _ = await drain.value
        try await drainToQuiescence(f)

        #expect(server.snapshots(rfc822MessageId: rfc).count == 1,
                "the message was duplicated: \(server.snapshots(rfc822MessageId: rfc))")
        let landed = serverFolders(server, rfc: rfc) == [Self.secondDestination]
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: landed, gesture: "the second move",
            serverState: "folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T3 — undo inside the in-flight window

    /// **THE PROPERTY: an undo issued while the move is still on the wire puts the
    /// message back where it started.**
    ///
    /// On Graph there is no deferred-successor path — that arm is IMAP-only,
    /// because only IMAP has to wait for `COPYUID`. The undo therefore queues an
    /// ordinary inverse move built from the OPTIMISTIC row, which still names the
    /// pre-move id. The inverse is correct only if the forward's retirement hands
    /// the new address to it; otherwise it 404s and the conflict arm deletes it,
    /// and the message the user just told the app to put back stays archived.
    @Test("Outlook: an undo issued while the move is in flight restores the message on the server")
    @MainActor
    func undoDuringTheInFlightWindowRestoresTheMessage() async throws {
        let rfc = "graph-handoff-undo@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-undo")
        await register(server.provider(), f)
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        let release = server.holdNextMove()
        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so this is not the in-flight window")

        let optimistic = try rows(f)
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        #expect(optimistic[0].folderPath == Self.firstDestination,
                "the optimistic move has not been applied, so the undo is not the in-flight case")
        // 🚨 THE UNDO IS COMMANDED FROM THE PRE-MOVE HEADER, not from the row the
        // optimistic move left behind — `UndoMember.init(header:)` reads
        // `sourceFolderPath`/`sourceFolderId`/`sourceObservedUidValidity` off the
        // header it is handed, and those describe where the message came FROM.
        // The real UI captures its members at gesture time, before the optimistic
        // update (`UndoService`), which is why every other undo suite passes the
        // source-folder header while the DB row already sits at the destination
        // (`UndoProviderIdentitySafetyTests.installOptimisticallyMoved`). Handing
        // in the post-move row instead makes `sourcePath` the DESTINATION, the
        // forward operation stops matching `exactPayload`, and `undoMove` refuses
        // the whole command silently — the test would then be measuring a
        // mis-built command rather than the handoff.
        await AccountManager.shared.undoDestructiveAction(
            [seeded], accountId: f.accountId, originalOpType: .move,
            fromFolderPath: Self.firstDestination, toFolderPath: Self.source,
            toFolderId: MessageIdentity.folderId(
                accountId: f.accountId, folderPath: Self.source))
        #expect(try queuedOperationCount(f) == 2, """
            the undo did not queue an inverse behind the in-flight forward, so \
            this test is not exercising the handoff
            """)

        release()
        try await drainToQuiescence(f)

        #expect(server.snapshots(rfc822MessageId: rfc).count == 1,
                "the message was duplicated: \(server.snapshots(rfc822MessageId: rfc))")
        let restored = serverFolders(server, rfc: rfc) == [Self.source]
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: restored, gesture: "the undo",
            serverState: "folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T4 — the newest gesture wins after an undo

    /// **THE PROPERTY: a re-delete issued after an undo lands, because the row the
    /// user gestured on carries the address the wire actually proved.**
    ///
    /// This is the exact device sequence behind `IOS-QUEUE-008` — delete, undo,
    /// delete again — and it is the case that needs the re-key to FOLLOW THE ROW.
    /// When the forward retires, the undo has already restored the row to the
    /// source folder, so a primary-key lookup at the operation's destination
    /// misses it and the row keeps the invalidated id. The user's next gesture is
    /// then built from a dead address; re-addressing the queue cannot save it,
    /// because the operation was created naming an id nothing will ever map. The
    /// user's LATEST intention losing is a red line.
    @Test("Outlook: a re-delete issued after an undo wins, because the row carries the proven address")
    @MainActor
    func reDeleteAfterAnUndoIsTheGestureThatWins() async throws {
        let rfc = "graph-handoff-redelete@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-redelete")
        await register(server.provider(), f)
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // GESTURE 1 — archive, parked on the wire.
        let releaseForward = server.holdNextMove()
        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        #expect(try await awaitHeldMoves(server, count: 1),
                "the forward move was never parked, so this is not the in-flight window")

        // GESTURE 2 — undo, inside that window.
        let afterOptimisticMove = try rows(f)
        #expect(afterOptimisticMove.count == 1)
        guard afterOptimisticMove.count == 1 else { return }
        #expect(afterOptimisticMove[0].folderPath == Self.firstDestination,
                "the optimistic move has not been applied, so gesture 2 is not the in-flight case")
        // Commanded from the PRE-move header — see the note in T3.
        await AccountManager.shared.undoDestructiveAction(
            [seeded], accountId: f.accountId, originalOpType: .move,
            fromFolderPath: Self.firstDestination, toFolderPath: Self.source,
            toFolderId: MessageIdentity.folderId(
                accountId: f.accountId, folderPath: Self.source))

        // Park the INVERSE too, so gesture 3 is issued while the undo is on the
        // wire — the row it is built from must already carry the address the
        // forward's retirement proved.
        let releaseInverse = server.holdNextMove()
        releaseForward()
        #expect(try await awaitHeldMoves(server, count: 2),
                "the inverse move was never parked, so gesture 3 is not the in-flight case")

        // GESTURE 3 — re-delete, from whatever row the user is now looking at.
        let afterUndo = try rows(f)
        #expect(afterUndo.count == 1)
        guard afterUndo.count == 1 else { return }
        #expect(afterUndo[0].messageId != "graph-1", """
            the row still names the id the forward move invalidated, so the \
            gesture below is built from a dead address — the re-key did not \
            follow the row out of the operation's destination folder
            """)
        await AccountManager.shared.move([afterUndo[0]], to: Self.secondDestination)

        releaseInverse()
        try await drainToQuiescence(f)

        #expect(server.snapshots(rfc822MessageId: rfc).count == 1,
                "the message was duplicated: \(server.snapshots(rfc822MessageId: rfc))")
        let landed = serverFolders(server, rfc: rfc) == [Self.secondDestination]
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: landed, gesture: "the re-delete",
            serverState: "folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T5 — a failure's requeue must not revert the handoff

    /// **THE PROPERTY: a gesture that fails mid-drain resumes at the addresses
    /// the wire proved, not at the ones the failing attempt was holding.**
    ///
    /// The executor claims a row, sends it, and on failure writes it back. The
    /// struct it holds when it writes back was read BEFORE the provider call, and
    /// a retirement committed earlier in the same drain may have re-addressed
    /// this very row (`MessageHeaderRekey.readdressQueuedOperations`). Writing the
    /// requeue as a whole-row `save` of that struct would silently REVERT the
    /// re-address, and the reverted operation goes out at the dead id on the next
    /// drain, 404s, and is deleted. Only the columns the requeue actually decided
    /// may be written (`PendingOperation.markQueued`), and the same rule governs
    /// `PendingOperation.appendToTail`.
    @Test("Outlook: a failure's requeue behind a retired move does not revert the re-addressed followers")
    @MainActor
    func aFailuresRequeueDoesNotRevertTheHandoff() async throws {
        let rfc = "graph-handoff-halt@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-halt")
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // NO PROVIDER REGISTERED YET (see T1 for why that, not connectivity, is
        // what "offline" means here): move, then two flag gestures, so the lane
        // has something BEHIND the operation that fails.
        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        let optimistic = try rows(f)
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markRead([optimistic[0]])
        await AccountManager.shared.markFlagged([optimistic[0]], flagged: true)
        #expect(try queuedOperationCount(f) == 3,
                "all three gestures must be queued offline, or the halt has nothing behind it")

        await register(server.provider(), f)
        // The move succeeds; the mark-read's PATCH is refused once, which stops
        // the drain and moves the mark-read's whole chain — the mark-flagged
        // behind it included — to the tail.
        server.failNextPatch()
        await AccountManager.shared.drainPendingQueue()
        try await drainToQuiescence(f)

        // NON-VACUITY, read from the WIRE once everything has settled rather than
        // from the queue mid-drain. `drainPendingQueue()` re-drives itself from
        // its own `defer`, and a caller that arrives while a drain is running
        // returns immediately instead of joining it — so there is no instant at
        // which "the queue still has work" can be sampled reliably, and an earlier
        // revision of this test sampled it before the failure had even happened.
        // The refusal leaves a permanent mark on the wire instead: THREE PATCHes
        // must have been served for two flag gestures — the mark-read that was
        // refused, its retry after the deferral, and the mark-flagged that was
        // deferred with it. Two would mean nothing failed and the write-back path
        // this test exists for never ran.
        #expect(serverFolders(server, rfc: rfc) == [Self.firstDestination],
                "the move did not land, so there is no handoff for the requeue to revert")
        let patches = server.http.servedCallSequence().filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 3, """
            the mark-read's PATCH was not refused and retried, so nothing failed \
            and nothing was written back behind it: \(patches)
            """)

        let current = liveId(server, rfc: rfc)

        // WHICH ADDRESS THOSE THREE PATCHES NAMED, which is the actual subject of
        // this test. Counting them proves the drain stopped and re-drove; it does
        // not distinguish a retry at the PROVEN id from a retry at the id the
        // move destroyed. A snapshot-restoring requeue produces exactly the same
        // count and sends the retry to `graph-1`, where Graph answers 404 and the
        // single-message conflict arm deletes the user's gesture.
        #expect(current != nil && current != "graph-1",
                "Graph did not reallocate the id, so no PATCH could name a dead address and the correlation below is vacuous")
        guard let current else { return }
        let misaddressed = patches.filter { !$0.hasSuffix("/\(current)") }
        #expect(misaddressed.isEmpty, """
            a PATCH went out at an address the move had already invalidated — the \
            requeue wrote the lane's pre-handoff snapshot back over the id the wire \
            proved (\(current)): \(misaddressed)
            """)

        // BOTH gestures behind the halt, asserted separately: the refused one and
        // the one requeued behind it fail in different ways, and an assertion on
        // only the flag is satisfied by a run in which the mark-read was retried
        // at the dead id, 404'd, and was deleted as "already done".
        let snapshot = server.snapshot(providerMessageId: current)
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: snapshot?.isRead == true,
            gesture: "the mark-read that was refused and requeued",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: snapshot?.isFlagged == true,
            gesture: "the mark-flagged behind the halt",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T6 — a whole-account suppression must not revert the handoff either

    /// **THE PROPERTY: an operation held back because ANOTHER operation's
    /// failure took the whole account down resumes at the address the wire
    /// proved, and is never charged a retry for a failure that was not its
    /// own.**
    ///
    /// This is the third place a re-addressed follower can be knocked back onto
    /// its dead pre-move id, and the only one driven by a DIFFERENT message's
    /// failure: when any operation fails for a connectivity reason,
    /// `executeSingleOp` puts the account into `DrainContext.failedAccounts`, and
    /// every remaining operation on that account is held for the rest of the
    /// drain — deliberately, so one drain does not hammer a server that is down.
    ///
    /// 🚨 WHAT CHANGED, AND WHY THE FIXTURE GOT SIMPLER. The predecessor ran a
    /// lane per `(account, message id)` concurrently, so this arm was a REQUEUE:
    /// the follower had already been claimed when the other lane failed, and the
    /// suppression had to write it back to `queued` — from a snapshot captured
    /// before the move committed, which is exactly how it could revert the
    /// proven address. Producing that interleaving needed a parked move, a
    /// second lane, and a happens-after barrier on the other lane's requeue.
    ///
    /// The global single-operation executor never claims an operation it is not
    /// about to run, so there is nothing to write back: the suppressed follower
    /// is simply not claimed, and it keeps whatever the retirement of its
    /// predecessor left in its row. The interleaving machinery is gone with the
    /// interleaving; the ORDER is now the fixture, and it is stated by the queue
    /// positions themselves — move, then the unrelated failure, then the
    /// follower.
    ///
    /// Both oracles are asserted, because they fail in different directions. The
    /// WIRE is append-only, so "no PATCH ever named `graph-1`" cannot be
    /// un-observed once true, and it is exactly what a suppression that wrote a
    /// pre-handoff snapshot back would violate — the follower would go out at the
    /// invalidated id, Graph would answer 404, and the single-message conflict
    /// arm would delete the user's gesture. The DURABLE row is read at the one
    /// instant it is now stable — after the suppressing drain returns, before the
    /// recovery drain — and says the same thing from the other side: the
    /// follower is `queued`, never attempted, charged nothing, and addressed to
    /// the id the wire proved.
    @Test("Outlook: an operation held back because another operation failed the account keeps the address the wire proved")
    @MainActor
    func aFailedAccountRequeueDoesNotRevertTheHandoff() async throws {
        let handoffRfc = "graph-handoff-failed-account@example.com"
        let unrelatedRfc = "graph-handoff-bystander@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: handoffRfc, providerMessageId: "graph-1", folderId: Self.source),
            .init(rfc822MessageId: unrelatedRfc, providerMessageId: "graph-2", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-failed-account")
        let handoffSeed = try seedHeader(f, graphId: "graph-1", rfc: handoffRfc)
        let unrelatedSeed = try seedHeader(f, graphId: "graph-2", rfc: unrelatedRfc)

        // NO PROVIDER IS REGISTERED YET, so every gesture is durably queued
        // before any of them runs. (`NetworkMonitor.checkConnected()` is `true`
        // in the test process — nothing calls `NetworkMonitor.shared.start()`, so
        // its mutex keeps its `true` default — and the drain's connectivity guard
        // therefore always passes. What holds these gestures back is the claim
        // walk's `providers[op.accountId] != nil`, not connectivity.)
        //
        // THE ORDER IS THE FIXTURE. Position 1 is the move whose retirement
        // re-addresses the follower; position 2 is the unrelated failure that
        // suppresses the account; positions 3 and 4 are what must NOT run
        // afterwards — the unrelated follow-up, and the re-addressed follower
        // this test is about.
        await AccountManager.shared.move([handoffSeed], to: Self.firstDestination)
        let optimistic = try rows(f).filter { $0.rfc822MessageId == handoffRfc }
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markFlagged([unrelatedSeed], flagged: true)
        await AccountManager.shared.markRead([unrelatedSeed])
        await AccountManager.shared.markRead([optimistic[0]])
        #expect(try queuedOperationCount(f) == 4,
                "all four gestures must be queued before the provider exists")

        let followerOpId = try await f.pool.read { db -> String? in
            try PendingOperation.order(Column("queuePosition").asc).fetchAll(db).last?.id
        }
        #expect(followerOpId != nil, "the re-addressed follower was not queued last")
        guard let followerOpId else { return }

        await register(server.provider(), f)
        // The FIRST PATCH this server serves fails. Position 2 is the unrelated
        // message's flag, so that is the request it lands on — the move at
        // position 1 is a `POST /move`, not a PATCH.
        server.failNextPatch()

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY, wire side: the move landed and Graph reallocated the id,
        // so a follower left at the pre-move address has a dead id to fail on.
        #expect(serverFolders(server, rfc: handoffRfc) == [Self.firstDestination],
                "the move did not land, so there is no handoff for the suppression to revert")
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so this test is not exercising the churn")
        let proven = liveId(server, rfc: handoffRfc)
        #expect(proven != nil && proven != "graph-1")
        guard let proven else { return }

        // NON-VACUITY, the other half: the account really was suppressed, and the
        // follower really was held by it rather than merely not reached.
        let heldFollower = try await f.pool.read { db in
            try PendingOperation.fetchOne(db, key: followerOpId)
        }
        #expect(heldFollower != nil, "the suppressed follower was dropped")
        #expect(heldFollower?.status == PendingStatus.queued.rawValue,
                "the suppressed follower was left claimed: \(heldFollower?.status ?? "<deleted>")")
        #expect(heldFollower?.everAttempted == false,
                "the suppressed follower was attempted after its account was taken down")
        #expect(heldFollower?.retryCount == 0, """
            the follower was charged a retry for a failure that was not its own: \
            \(heldFollower?.retryCount ?? -1)
            """)
        // 🚨 THE DURABLE HALF OF THE ORACLE: the row the suppression left behind
        // names the address the WIRE proved, not the one the gesture was made at.
        #expect(heldFollower?.messageIds == [proven], """
            the suppressed follower is addressed to \
            \(String(describing: heldFollower?.messageIds)) rather than the proven \
            id \(proven) — a snapshot taken before the move committed was written \
            back over the committed address
            """)
        #expect(server.http.servedCallSequence()
                    .filter { $0.hasPrefix("PATCH ") && $0.hasSuffix("/\(proven)") }.isEmpty, """
            the follower executed on the drain that suppressed its account
            """)

        try await drainToQuiescence(f)

        // THE ORACLE — the wire record, which is append-only and therefore the
        // only thing about the earlier drains that can be read after the fact. A
        // follower left at the lane's pre-handoff address would go out at
        // `graph-1`, Graph would answer 404, and the single-message conflict arm
        // would delete the user's gesture. So the misaddressed PATCH is the
        // observable, not the row state that preceded it.
        let patches = server.http.servedCallSequence().filter { $0.hasPrefix("PATCH ") }
        let misaddressed = patches.filter { $0.hasSuffix("/graph-1") }
        #expect(misaddressed.isEmpty, """
            the follower held by the failed-account arm went out at the address \
            the move invalidated: \(misaddressed).
            """)
        let handoffPatches = patches.filter { $0.hasSuffix("/\(proven)") }
        #expect(handoffPatches.count == 1, """
            the follower did not reach the wire exactly once at the proven id \
            (\(proven)): \(patches)
            """)

        let final = liveId(server, rfc: handoffRfc)
        #expect(final == proven, "the message moved again after the handoff, so the oracle below is not the one under test")
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: proven)?.isRead == true,
            gesture: "the follower held by the failed-account arm",
            serverState: "id=\(proven) folders=\(serverFolders(server, rfc: handoffRfc))")
        let bystander = server.snapshot(providerMessageId: "graph-2")
        #expect(bystander?.isFlagged == true && bystander?.isRead == true, """
            the message whose PATCH was refused did not converge: \
            \(String(describing: bystander))
            """)

        await finish(f)
    }

    // MARK: - T7 — a proven move whose LOCAL retirement cannot commit

    /// A GRDB `TransactionObserver` that REFUSES the commit of any transaction
    /// which wrote `messageHeader`, and counts the refusals.
    ///
    /// `databaseWillCommit()` throwing makes SQLite's commit hook abort the
    /// COMMIT, so GRDB rolls back and rethrows to `pool.write`'s caller — the
    /// same shape a full disk or an I/O error at COMMIT produces, and the same
    /// shape GRDB's own suspension produces when the app is backgrounded mid
    /// drain while reads keep working. It is a real production possibility, not
    /// a manufactured writer.
    ///
    /// Lifted from `QueueCoreInvariantTests.HeaderCommitRefuser` (itself lifted
    /// from `SyncEngineRunSyncTests`), file-private per file exactly as those
    /// two are: there is no shared test utility for it and this change does not
    /// invent one.
    private final class HeaderCommitRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let sawHeaderWrite = Mutex(false)
        let refusals = Mutex(0)

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageHeader.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            sawHeaderWrite.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawHeaderWrite.withLock({ $0 }) else { return }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
    }

    /// **THE PROPERTY: a move Graph has already PROVEN is not un-proven by a
    /// local write that will not commit. While the process lives the proof is
    /// retained, nothing behind the move executes, the move is never sent to the
    /// wire twice, and once the database accepts writes again the follower lands
    /// at the id the move proved.**
    ///
    /// The failure this pins is NOT the process-death crash window, which stays
    /// accepted: it is the LIVE process. GRDB suspends writes when the app is
    /// backgrounded mid-drain while reads keep working
    /// (`ADR-IOS-041`), and a full disk or an I/O error at COMMIT does the same
    /// — the wire has answered `2xx` and named the destination id, and the only
    /// thing that failed is a local transaction. Discarding the provider's own
    /// returned result there costs the user their NEWEST gesture: the follower
    /// serialized behind the move in the same account-scoped lane runs next
    /// naming the id Graph has just invalidated, Graph answers `404`, and the
    /// single-message conflict arm reads that as provider-authoritative
    /// "already done" and DELETES it.
    ///
    /// Both halves are asserted, because they fail in opposite directions. The
    /// first drain must leave the wire and the durable rows exactly as the
    /// provider left them — one `/move`, no `PATCH` at any id, the move row
    /// intact with every member, the follower still naming the old id, and no
    /// retry charged to either. The second must converge: still exactly one
    /// `/move` (the move is never replayed on the wire), the follower's only
    /// `PATCH` at the NEW id, the server's own read flag set there, the header
    /// re-keyed, and the queue empty.
    @Test("Outlook: a proven move whose local retirement cannot commit keeps the proof, and the follower lands at the proven id once writes work again")
    @MainActor
    func aRetirementThatCannotCommitRetainsTheProofAndReplaysIt() async throws {
        let rfc = "graph-handoff-retained@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-retained")
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // NO PROVIDER REGISTERED YET (see T1), so the follower is guaranteed to be claimed in the SAME pass
        // as the move it is queued behind — the shape in which the lane's
        // serialization promise is what makes the handoff load-bearing.
        await AccountManager.shared.move([seeded], to: Self.firstDestination)

        // THE UNDO STACK, pushed exactly as the swipe pushes it: from the
        // PRE-move snapshot, naming the source address. A committed retirement
        // re-points it at the address the wire proved (`publishMoveFinish`), and
        // the recovery below asserts the REPLAY publishes that too — an undo
        // entry left naming the destroyed id authenticates against
        // `MessageHeader.fetchOne(db, key: originalHeaderId)`, now nil, and is
        // refused WHOLE with no way to repair an entry already offered to the
        // user (`IOS-UNDO-002`).
        UndoService.shared.dismissAll()
        let undoAction = UndoableAction(
            type: .move(fromPath: Self.source, toPath: Self.firstDestination),
            messages: [seeded],
            originalFolderId: seeded.folderId,
            originalFolderPath: Self.source,
            accountId: f.accountId,
            timestamp: Date())
        let undoActionId = undoAction.id
        UndoService.shared.push(undoAction)
        defer { UndoService.shared.dismissAll() }
        let optimistic = try rows(f)
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markRead([optimistic[0]])

        let queued = try await f.pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
        #expect(queued.count == 2,
                "both gestures must be durably queued before the provider exists, or this test proves nothing")
        guard queued.count == 2 else { return }
        let moveOpId = queued.first(where: { $0.type == .move })?.id
        let followerOpId = queued.first(where: { $0.type == .markRead })?.id
        #expect(moveOpId != nil && followerOpId != nil,
                "the fixture did not queue one move and one mark-read: \(queued.map(\.type.rawValue))")
        guard let moveOpId, let followerOpId else { return }

        await register(server.provider(), f)

        // Installed AFTER every fixture write, so the only header-writing
        // transaction it can refuse is the retirement itself.
        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the retirement really was attempted, and really was
        // refused — once per `retryWrite` attempt, and never more. More than
        // three means some OTHER header write was refused too and this test is
        // not measuring what it names (`MIS-027`).
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts, so this is not the scenario under test: \
            \(refuser.refusals.withLock { $0 })
            """)

        // I1 + I3, on the wire: the provider proved the move exactly once, and
        // the follower did not reach the wire at all while that proof was
        // uncommitted. A follower that PATCHes here names an id Graph has
        // already invalidated.
        let firstDrainCalls = server.http.servedCallSequence()
        #expect(firstDrainCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was not sent exactly once: \(firstDrainCalls)
            """)
        #expect(firstDrainCalls.filter { $0.hasPrefix("PATCH ") }.isEmpty, """
            the follower executed while its predecessor's proof was still \
            uncommitted — it can only have named the id the move destroyed: \
            \(firstDrainCalls.filter { $0.hasPrefix("PATCH ") })
            """)
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so this test is not exercising the churn")

        // I5, durably: nothing was lost and nothing was invented. The move row
        // keeps all of its members, the follower keeps its old address, and a
        // failed LOCAL write charges no provider retry to either.
        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldMove != nil, """
            the move whose retirement could not commit was deleted — the wire \
            effect it applied is now unrecorded anywhere
            """)
        #expect(heldFollower != nil, """
            the follower was DESTROYED: it went to the wire at an address this \
            app had invalidated, 404'd, and the conflict arm read that as \
            "already done". That is the user's newest gesture.
            """)
        #expect(heldMove?.messageIds == ["graph-1"],
                "the move row lost members it was issued with: \(String(describing: heldMove?.messageIds))")
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue, """
            the move was returned to `queued` after the wire had already moved \
            it — the claim loop would hand it to the provider a second time: \
            \(heldMove?.status ?? "<deleted>")
            """)
        #expect(heldFollower?.messageIds == ["graph-1"], """
            the follower's address moved even though the transaction that \
            proves it never committed: \(String(describing: heldFollower?.messageIds))
            """)
        #expect(heldMove?.everAttempted == true,
                "the claim's durable proof stands across a failed local write")
        #expect(heldFollower?.everAttempted == false, """
            the follower carries the attempted-row proof, so it was CLAIMED while \
            its predecessor's proven result was still uncommitted — the executor \
            claims one operation at a time and commits its result before the next
            """)
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a provider retry was charged for a LOCAL write failure: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        // NON-VACUITY for the publication oracle below: nothing has been
        // published yet, because nothing has committed. The stack still names
        // the address the gesture captured.
        let heldMember = UndoService.shared.undoStack.last?.commands.first?.members.first
        #expect(UndoService.shared.undoStack.last?.id == undoActionId,
                "the undo entry under test is not the one on top of the stack")
        #expect(heldMember?.providerMessageId == "graph-1", """
            the undo stack was re-pointed by a retirement that never committed: \
            \(String(describing: heldMember?.providerMessageId))
            """)

        // The database accepts writes again — the recovery every live process
        // eventually reaches when the app returns to the foreground.
        f.pool.remove(transactionObserver: refuser)
        try await drainToQuiescence(f)

        // I3: still exactly one move on the wire, ever.
        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was replayed on the wire — a proven move must be applied \
            exactly once: \(finalCalls)
            """)

        // I4: the follower landed, at the proven address and at no other.
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        let misaddressed = patches.filter { !$0.hasSuffix("/\(current)") }
        #expect(misaddressed.isEmpty, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(misaddressed)
            """)

        // The header answers to the proven address too, in the folder the move
        // put it in.
        let headers = try rows(f)
        #expect(headers.count == 1)
        guard headers.count == 1 else { return }
        #expect(headers[0].messageId == current && headers[0].folderPath == Self.firstDestination, """
            the header was left at the address Graph invalidated: \
            id=\(headers[0].id) messageId=\(headers[0].messageId) \
            folder=\(headers[0].folderPath)
            """)

        // 🚨 THE REPLAY MUST PUBLISH WHAT THE DIRECT PATH PUBLISHES. A committed
        // retirement is not just a durable write: `publishMoveFinish` re-points
        // the undo stack at the address the wire proved. Recovering through the
        // REPLAY arm and skipping that leaves the user an Undo button that is
        // refused whole the moment it is pressed.
        let republished = UndoService.shared.undoStack.last?.commands.first?.members.first
        #expect(UndoService.shared.undoStack.last?.id == undoActionId,
                "the undo entry was dropped by the recovery")
        #expect(republished?.providerMessageId == current, """
            the undo stack still names the address the move destroyed after \
            recovery through the retirement REPLAY (proven id \(current)): \
            \(String(describing: republished?.providerMessageId))
            """)
        #expect(republished?.originalHeaderId == headers[0].id, """
            the undo entry does not authenticate against the re-keyed row, so \
            pressing Undo refuses the whole command: \
            \(String(describing: republished?.originalHeaderId)) vs \(headers[0].id)
            """)
        // The fields that describe where the message came FROM must NOT move.
        #expect(republished?.sourceFolderPath == Self.source,
                "the re-key rewrote the restore target: \(String(describing: republished?.sourceFolderPath))")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: current)?.isRead == true,
            gesture: "the mark-read behind a retirement that could not commit",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T8 — a DEFERRAL that rewrites rows AFTER the handoff committed

    /// **THE PROPERTY: the writes a failure makes to rows the predecessor's
    /// handoff has already re-addressed touch ORDER AND STATUS ONLY — the
    /// held-back followers keep the address the wire proved and execute
    /// there.**
    ///
    /// What makes this delicate on Graph is WHEN the write runs. The move's
    /// retirement has already rewritten these very rows to the reallocated id, in
    /// a committed transaction; the deferral then rewrites the same rows again, a
    /// moment later, to move the failing operation's whole related chain to the
    /// tail. That second write has to be status/position only. Writing a captured
    /// struct back — the obvious way to "put a claimed row back" — would silently
    /// revert `messageIds` to the id Graph invalidated, and the next drain would
    /// `404` and let the single-message conflict arm delete both gestures.
    ///
    /// TWO followers, not one, because the deferral moves the whole chain and
    /// each row is its own write: a revert that hit only one of them would still
    /// destroy a gesture.
    ///
    /// 🚨 WHAT THIS USED TO DRIVE, AND WHY THE PRODUCER CHANGED. The predecessor
    /// re-read each claimed row from the database immediately before executing
    /// it, and this test armed a one-shot fault on that read so the lane-halt
    /// requeue ran with the handoff freshly committed. The global
    /// single-operation executor has no post-claim re-read — the row it claims is
    /// the row it read inside the claim transaction — so that seam is gone from
    /// the drain, and the write that now lands on a just-re-addressed row is the
    /// related-chain deferral. The hazard, the two followers, and every oracle
    /// below are unchanged; only what provokes the write moved.
    ///
    /// `AccountManagerQueueDrainTests` covers deferral retryability on a
    /// MOVE-STABLE provider, where no address can be reverted because none
    /// changed. This one is the ADDRESS oracle, and only Graph's churn can state
    /// it.
    @Test("Outlook: a chain deferred immediately after a committed handoff keeps the proven address")
    @MainActor
    func aFailedPostClaimReReadDoesNotRevertACommittedHandoff() async throws {
        let rfc = "graph-handoff-read-fault@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-read-fault")
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // NO PROVIDER REGISTERED YET (see T1), so the move and BOTH followers are
        // durably queued before anything runs, in gesture order.
        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        let optimistic = try rows(f)
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markRead([optimistic[0]])
        await AccountManager.shared.markFlagged([optimistic[0]], flagged: true)
        #expect(try queuedOperationCount(f) == 3,
                "the move and both followers must be queued offline")

        let followerIds = try await f.pool.read { db -> [String] in
            try PendingOperation.order(Column("queuePosition").asc).fetchAll(db)
                .filter { $0.type != .move }.map(\.id)
        }
        #expect(followerIds.count == 2, "both followers must be queued: \(followerIds)")
        guard followerIds.count == 2 else { return }

        await register(server.provider(), f)
        // The FIRST follower's PATCH is refused once. The move ahead of it
        // succeeds and its retirement re-addresses BOTH followers to the id Graph
        // hands back; the refusal then defers that whole chain to the tail, which
        // is the write this test is about.
        server.failNextPatch()
        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: the handoff really happened, so there is a proven address
        // for the deferral to be able to revert.
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so a reverted address would still work")
        #expect(serverFolders(server, rfc: rfc) == [Self.firstDestination],
                "the move never landed, so there is no committed handoff to revert")
        let proven = liveId(server, rfc: rfc)
        #expect(proven != nil && proven != "graph-1")
        guard let proven else { return }

        // 🚨 THE DURABLE ORACLE, read after the drain returned: both deferred rows
        // still name the address the WIRE proved.
        let deferredRows = try await f.pool.read { db in
            try PendingOperation.filter(followerIds.contains(Column("id")))
                .order(Column("queuePosition").asc).fetchAll(db)
        }
        #expect(deferredRows.count == 2, """
            a follower was destroyed by the deferral: \(deferredRows.map(\.id))
            """)
        #expect(deferredRows.allSatisfy { $0.messageIds == [proven] }, """
            a deferred follower is addressed to \(deferredRows.map(\.messageIds)) \
            rather than the proven id \(proven) — the deferral wrote a snapshot \
            taken before the move committed back over the committed address
            """)
        #expect(deferredRows.allSatisfy { $0.status == PendingStatus.queued.rawValue },
                "a deferred follower was left claimed: \(deferredRows.map(\.status))")
        #expect(deferredRows.map(\.id) == followerIds, """
            the deferral did not preserve the followers' relative order: \
            \(deferredRows.map(\.id)) vs \(followerIds)
            """)

        try await drainToQuiescence(f)

        // THE ORACLE — the wire. Not one PATCH may have gone to the id the move
        // invalidated, and both gestures must be visible at the proven one.
        let patches = server.http.servedCallSequence().filter { $0.hasPrefix("PATCH ") }
        let misaddressed = patches.filter { $0.hasSuffix("/graph-1") }
        #expect(misaddressed.isEmpty, """
            a follower went out at the address the move invalidated: \
            \(misaddressed). The deferral wrote the pre-handoff snapshot back \
            over the committed address.
            """)
        #expect(!patches.isEmpty, "no follower ever reached the wire: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(proven)") },
                "a follower was addressed by neither the proven id nor graph-1: \(patches)")

        let landed = server.snapshot(providerMessageId: proven)
        #expect(landed?.isRead == true && landed?.isFlagged == true, """
            a gesture held back by the deferral never executed: \
            \(String(describing: landed))
            """)

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: landed?.isRead == true && landed?.isFlagged == true,
            gesture: "the two followers deferred right after a committed handoff",
            serverState: "id=\(proven) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - T9/T10 — a PASS BOUNDARY is a CLAIM BOUNDARY

    /// A header exactly as `optimisticMoveToFolder` leaves one after a move
    /// gesture, seeded directly.
    ///
    /// That function updates `folderId`, `folderPath`, `isInInbox` and
    /// `observedUidValidity` and NOTHING ELSE, so the row's PRIMARY KEY and its
    /// `messageId` both stay at their SOURCE values while the row already shows
    /// at the destination. Reproducing that shape is what makes the two tests
    /// below exercise the same rows a real gesture would produce.
    ///
    /// Both shapes are returned. `moved` is what the database now holds;
    /// `source` is the PRE-gesture snapshot, which is what a real swipe captures
    /// into the undo stack (`UndoMember.init(header:)` reads the folder, epoch,
    /// inbox flag and tag to RESTORE, so it must be built from the row as it was
    /// before the optimistic move, exactly as `UndoService` builds it).
    @discardableResult
    private func seedOptimisticallyMovedHeader(
        _ fixture: Fixture, graphId: String, rfc: String, destination: String,
        isRead: Bool = false, isFlagged: Bool = false, accountId: String? = nil
    ) throws -> (source: MessageHeader, moved: MessageHeader) {
        let owner = accountId ?? fixture.accountId
        var header = try seedHeader(fixture, graphId: graphId, rfc: rfc, accountId: owner)
        let source = header
        header.folderPath = destination
        header.folderId = MessageIdentity.folderId(
            accountId: owner, folderPath: destination)
        header.isInInbox = false
        header.isRead = isRead
        header.isFlagged = isFlagged
        header.observedUidValidity = nil
        let moved = header
        try fixture.pool.writeWithoutTransaction { db in try moved.update(db) }
        return (source: source, moved: moved)
    }

    /// Insert a whole schedule of durable operations in a fixed `createdAt`
    /// order, so ONE explicit `drainPendingQueue()` owns it end to end.
    ///
    /// 🚨 WHY THE ROWS ARE SEEDED AND NOT GESTURED. Every `AccountManager`
    /// gesture spawns its OWN drain task, so a later explicit
    /// `drainPendingQueue()` may find `isDraining` already true, record a
    /// redrain and return immediately — it is NOT a barrier, and an assertion
    /// written as though it were is reading a partially-drained queue. With the
    /// rows seeded there is no drain at all until the test starts exactly one,
    /// and every oracle below is either the append-only wire record or a durable
    /// row read after that one call has returned.
    ///
    /// The dates are absolute and tiny rather than `Date()`-relative offsets
    /// because only their ORDER is load-bearing here (the drain sorts by
    /// `createdAt` ascending) and nothing in the queue compares them to now.
    private func seedSchedule(
        _ fixture: Fixture, _ ops: [PendingOperation]
    ) throws -> [PendingOperation] {
        var ordered: [PendingOperation] = []
        for (index, op) in ops.enumerated() {
            var stamped = op
            stamped.createdAt = Date(timeIntervalSince1970: Double(index + 1))
            ordered.append(stamped)
        }
        let toInsert = ordered
        try fixture.pool.writeWithoutTransaction { db in
            for op in toInsert { try op.inserted(db) }
        }
        return ordered
    }

    /// **THE PROPERTY: while this process holds a proven retirement it could not
    /// commit, NO claim pass starts — so the follower behind that retirement is
    /// never claimed alone against the address the retirement is still holding.**
    ///
    /// This is the FULL-retirement arm, with a bystander, and the bystander is
    /// what keeps the test honest: the drain must stop at the retention BECAUSE
    /// of the retention, not because it had nothing else to do. An ordinary
    /// earlier gesture on the same message — a mark-flagged issued before the
    /// move — succeeds on the wire and retires cleanly first, so the executor is
    /// demonstrably still willing to claim when the retention happens.
    ///
    /// The harm if it did not stop: the frontier walk refuses the retained
    /// predecessor because it is `inFlight`, so the FOLLOWER becomes the live
    /// front row and is claimed ALONE, still naming the id Graph reallocated,
    /// because nothing has committed the re-address. Its PATCH `404`s and the
    /// single-message conflict arm reads that as provider-authoritative "already
    /// done" and DELETES the user's NEWEST gesture — no crash, inside a live
    /// process that still holds the proof. That is outside the accepted
    /// process-death window.
    ///
    /// The recovery is the next drain, not a retry here:
    /// `replayRetainedRetirements` runs at the top of `drainPendingQueue` BEFORE
    /// anything is claimed, so the proof commits — re-addressing the follower in
    /// the same transaction — or the drain refuses to start.
    @Test("Outlook: a bystander's success does not start a claim pass while a proven retirement is still held")
    @MainActor
    func aBystandersProgressDoesNotReleaseAHeldRetirementsFollower() async throws {
        let rfc = "graph-handoff-pass-boundary@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-pass-boundary")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination,
            isRead: true, isFlagged: true)

        // PRECONDITION — no earlier test leaked a retained retirement into the
        // shared `AccountManager`. One would stop this drain for a reason that
        // has nothing to do with what is being measured.
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        // mark-flagged (the BYSTANDER, earliest) → move → mark-read (the
        // FOLLOWER). All three name one Graph id, so on an account-scoped
        // provider they are ONE lane and run in `createdAt` order.
        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .markFlagged, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source),
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 3)
        guard ordered.count == 3 else { return }
        let moveOpId = ordered[1].id
        let followerOpId = ordered[2].id

        await register(server.provider(), f)

        // Installed AFTER every fixture write, so the only header-writing
        // transaction it can refuse is the move's retirement. The bystander and
        // the follower are PATCH-shaped operations whose retirement writes
        // `pendingOperation` only (`finishMove` returns `.empty` for anything
        // that is not an address-changing move), which is why the exact refusal
        // count below is a meaningful oracle.
        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY: exactly the retirement's three `retryWrite` attempts were
        // refused. More would mean some OTHER header write was refused too and
        // this is not the scenario under test (`MIS-027`).
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)

        let firstDrain = server.http.servedCallSequence()
        #expect(firstDrain.filter { $0.hasSuffix("/move") }.count == 1,
                "the move was not sent exactly once: \(firstDrain)")
        let moveIndex = firstDrain.firstIndex { $0.hasSuffix("/move") }
        #expect(moveIndex != nil)
        guard let moveIndex else { return }

        // NON-VACUITY, the other side: the bystander really did execute before
        // the move. Without it the drain could have stopped for a reason
        // unrelated to the gate under test — an empty queue, a refused claim —
        // and every assertion below would be vacuous.
        let bystanderPatches = firstDrain[..<moveIndex].filter { $0.hasPrefix("PATCH ") }
        #expect(bystanderPatches.count == 1, """
            the bystander did not execute before the move, so the executor was \
            never shown to be willing to claim and this test is not exercising \
            the retention gate: \(Array(firstDrain))
            """)
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so the follower has no dead address to fail on")

        // 🚨 THE ORACLE. Nothing may reach the wire after the move while its
        // proof is uncommitted — a PATCH here can only name the id the move
        // destroyed.
        let afterTheMove = firstDrain.dropFirst(moveIndex + 1).filter { $0.hasPrefix("PATCH ") }
        #expect(afterTheMove.isEmpty, """
            a claim pass started while this process still held an unresolved \
            proven retirement: \(Array(afterTheMove)). The follower named the \
            address the move invalidated, Graph answered 404, and the \
            single-message conflict arm read that as "already done".
            """)

        // Durable state, read after the drain returned — never mid-drain.
        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldFollower != nil, """
            the follower was DESTROYED while this process still held the proof \
            that would have re-addressed it — the user's newest gesture is gone
            """)
        #expect(heldFollower?.status == PendingStatus.queued.rawValue,
                "the follower is not retryable: \(heldFollower?.status ?? "<deleted>")")
        #expect(heldFollower?.messageIds == ["graph-1"], """
            the follower's address moved even though the transaction that proves \
            it never committed: \(String(describing: heldFollower?.messageIds))
            """)
        #expect(heldFollower?.retryCount == 0,
                "a provider retry was charged for a LOCAL write failure")
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue, """
            the move was returned to `queued` after the wire had already moved \
            it: \(heldMove?.status ?? "<deleted>")
            """)
        #expect(heldMove?.messageIds == ["graph-1"],
                "the move row lost members: \(String(describing: heldMove?.messageIds))")

        // The database accepts writes again — the state every live process
        // reaches when it returns to the foreground.
        f.pool.remove(transactionObserver: refuser)
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was replayed on the wire — a proven move must be applied \
            exactly once: \(finalCalls)
            """)
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let misaddressed = finalCalls
            .dropFirst(moveIndex + 1)
            .filter { $0.hasPrefix("PATCH ") && !$0.hasSuffix("/\(current)") }
        #expect(misaddressed.isEmpty, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(Array(misaddressed))
            """)
        #expect(finalCalls.filter { $0.hasPrefix("PATCH ") && $0.hasSuffix("/\(current)") }.count == 1,
                "the follower did not execute exactly once at the proven id: \(finalCalls)")

        let headers = try rows(f)
        #expect(headers.count == 1)
        guard headers.count == 1 else { return }
        #expect(headers[0].messageId == current && headers[0].folderPath == Self.firstDestination, """
            the header was left at the address Graph invalidated: \
            messageId=\(headers[0].messageId) folder=\(headers[0].folderPath)
            """)
        let landed = server.snapshot(providerMessageId: current)
        #expect(landed?.isFlagged == true, "the bystander's flag was lost: \(String(describing: landed))")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: landed?.isRead == true,
            gesture: "the mark-read behind a retirement held across a bystander's success",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    /// **THE PROPERTY, on the PARTIAL arm and with no bystander at all: a
    /// narrowing that could not commit stops the drain by itself.**
    ///
    /// A narrowing that COMMITS is progress the executor is entitled to keep
    /// going on — the operation is strictly smaller, so the next iteration
    /// re-claims it as the live front row and finishes it in the same run. This
    /// test is the arm where the narrowing write FAILED: the members the provider
    /// proved are held only in memory, so the executor must stop rather than take
    /// the next candidate. If it did not, the frontier walk would refuse the
    /// `inFlight` bundle and claim the FOLLOWER alone, at the id Graph
    /// reallocated for the member the provider DID prove.
    ///
    /// The schedule is a two-member move `[A, B]` whose first member the wire
    /// proves — Graph reallocates A's id — while the second is refused, which is
    /// the only shape that reaches the partial arm at all. A is also the message
    /// the follower names.
    @Test("Outlook: a narrowing that cannot commit stops the drain with no bystander at all")
    @MainActor
    func aHeldNarrowingStopsTheDrainWithoutABystander() async throws {
        let firstRfc = "graph-handoff-narrowing-a@example.com"
        let secondRfc = "graph-handoff-narrowing-b@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: firstRfc, providerMessageId: "graph-a", folderId: Self.source),
            .init(rfc822MessageId: secondRfc, providerMessageId: "graph-b", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-narrowing")
        let a = try seedOptimisticallyMovedHeader(
            f, graphId: "graph-a", rfc: firstRfc, destination: Self.firstDestination, isRead: true)
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-b", rfc: secondRfc, destination: Self.firstDestination)

        // The undo entry the batch gesture would have pushed, built from the
        // PRE-move snapshot of the member the provider proves. The narrowing
        // replay must re-point it at the proven address for the same reason the
        // whole-op replay must (`IOS-UNDO-002`).
        UndoService.shared.dismissAll()
        let undoAction = UndoableAction(
            type: .move(fromPath: Self.source, toPath: Self.firstDestination),
            messages: [a.source],
            originalFolderId: a.source.folderId,
            originalFolderPath: Self.source,
            accountId: f.accountId,
            timestamp: Date())
        let undoActionId = undoAction.id
        UndoService.shared.push(undoAction)
        defer { UndoService.shared.dismissAll() }

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-a", "graph-b"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)
        // A moves and has its id reallocated. B is not addressed in that attempt
        // at all — an attempt settles ONE member — and when a later attempt does
        // reach it, it is refused with a TRANSIENT 503, so it stays owed rather
        // than becoming an authoritative-stale drop.
        server.failMoveOnce(providerMessageId: "graph-b")

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.drainPendingQueue()

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the narrowing write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)

        // NON-VACUITY: the provider really did return a PARTIAL result. An
        // attempt settles ONE member, so a two-member move is partial by
        // construction: A moved and its id churned, and B was not addressed at
        // all — which is why exactly one `/move` is on the wire.
        let firstDrain = server.http.servedCallSequence()
        #expect(firstDrain.filter { $0.hasSuffix("/move") }.count == 1, """
            the attempt addressed more than the one member it may settle, so the \
            proven member is exposed to a cancellation it cannot survive: \
            \(firstDrain)
            """)
        #expect(server.snapshot(providerMessageId: "graph-a") == nil,
                "Graph did not reallocate A's id, so there is no dead address to fail on")
        #expect(server.snapshots(rfc822MessageId: secondRfc).map(\.folderId) == [Self.source],
                "B moved even though its move was refused, so this is not a partial batch")

        // 🚨 THE ORACLE. No PATCH may reach the wire at all: the only address
        // the follower can name is the one the uncommitted narrowing holds.
        #expect(firstDrain.filter { $0.hasPrefix("PATCH ") }.isEmpty, """
            a claim pass started while this process still held an unresolved \
            proven narrowing: \(firstDrain.filter { $0.hasPrefix("PATCH ") }). \
            A narrowing whose write FAILED holds its proven members in memory \
            only, so the executor must stop rather than claim the next candidate.
            """)

        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldFollower != nil, """
            the follower was DESTROYED while this process still held the proof \
            that would have re-addressed it — the user's newest gesture is gone
            """)
        #expect(heldFollower?.status == PendingStatus.queued.rawValue,
                "the follower is not retryable: \(heldFollower?.status ?? "<deleted>")")
        #expect(heldFollower?.messageIds == ["graph-a"], """
            the follower's address moved even though the narrowing never \
            committed: \(String(describing: heldFollower?.messageIds))
            """)
        #expect(heldFollower?.retryCount == 0,
                "a provider retry was charged for a LOCAL write failure")
        #expect(heldMove?.messageIds == ["graph-a", "graph-b"], """
            the bundle was narrowed even though the narrowing write never \
            committed: \(String(describing: heldMove?.messageIds))
            """)
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue, """
            the bundle was returned to `queued` with a member the wire had \
            already moved: \(heldMove?.status ?? "<deleted>")
            """)

        // NON-VACUITY for the publication oracle below: an uncommitted narrowing
        // publishes nothing, so the stack still names the captured address.
        #expect(UndoService.shared.undoStack.last?.id == undoActionId,
                "the undo entry under test is not the one on top of the stack")
        #expect(
            UndoService.shared.undoStack.last?.commands.first?.members.first?
                .providerMessageId == "graph-a",
            "the undo stack was re-pointed by a narrowing that never committed")

        f.pool.remove(transactionObserver: refuser)
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        let provenA = liveId(server, rfc: firstRfc)
        #expect(provenA != nil && provenA != "graph-a")
        guard let provenA else { return }

        // A's move is never re-sent — exactly the one request that proved it.
        #expect(finalCalls.filter { $0.hasSuffix("/messages/graph-a/move") }.count == 1, """
            the proven member's move was re-sent, which would seat a second copy \
            at the destination: \(finalCalls)
            """)
        // B moved EXACTLY ONCE. It was ATTEMPTED twice — the first attempt
        // answered 503 and applied nothing — and the server holds exactly one
        // copy of it, in the destination.
        #expect(finalCalls.filter { $0.hasSuffix("/messages/graph-b/move") }.count == 2, """
            the refused member was not retried exactly once after its transient \
            failure: \(finalCalls)
            """)
        #expect(serverFolders(server, rfc: secondRfc) == [Self.firstDestination], """
            the refused member did not converge: \
            \(serverFolders(server, rfc: secondRfc))
            """)

        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(provenA)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(provenA)): \(patches)
            """)

        // 🚨 THE NARROWING REPLAY MUST PUBLISH TOO. `commitPartialRetirement`
        // re-keys only the PROVEN members, and the replay arm is responsible for
        // publishing that re-key to the undo stack exactly as the direct path is.
        let republished = UndoService.shared.undoStack.last?.commands.first?.members.first
        #expect(UndoService.shared.undoStack.last?.id == undoActionId,
                "the undo entry was dropped by the recovery")
        #expect(republished?.providerMessageId == provenA, """
            the undo stack still names the address the move destroyed after \
            recovery through the narrowing REPLAY (proven id \(provenA)): \
            \(String(describing: republished?.providerMessageId))
            """)
        #expect(
            republished?.originalHeaderId == MessageIdentity.headerId(
                accountId: f.accountId, folderPath: Self.firstDestination,
                messageId: provenA),
            """
            the undo entry does not authenticate against the re-keyed row, so \
            pressing Undo refuses the whole command: \
            \(String(describing: republished?.originalHeaderId))
            """)
        #expect(republished?.sourceFolderPath == Self.source,
                "the re-key rewrote the restore target: \(String(describing: republished?.sourceFolderPath))")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: provenA)?.isRead == true,
            gesture: "the mark-read behind a narrowing that could not commit",
            serverState: "id=\(provenA) folders=\(serverFolders(server, rfc: firstRfc))")

        await finish(f)
    }

    // MARK: - T-H / T-I — the replay that FAILS AGAIN, and charges nobody

    /// **THE PROPERTY: a retained retirement whose replay fails AGAIN stops the
    /// drain with the proof still held, and charges the failure to nobody.**
    ///
    /// This is `replayRetainedRetirements`' catch arm, reached through the real
    /// caller: `drainPendingQueue` calls it at the top, it re-runs
    /// `commitFullRetirement`, the database refuses that write for a second time,
    /// and it returns `false`. The drain must then stop BEFORE the
    /// `NetworkMonitor` check and before any claim pass — because the alternative
    /// is the exact drop `IOS-GRAPH-005` is about: the follower is `queued`, its
    /// `inFlight` predecessor is refused by the claim loop, so the follower is
    /// claimed ALONE naming the id Graph reallocated, `404`s, and is deleted by
    /// the single-message conflict arm as provider-authoritative "already done".
    ///
    /// "Charges nobody" is the second half and it is not cosmetic: a LOCAL write
    /// that will not commit is not the provider failing, so neither the held move
    /// nor the follower may accumulate `retryCount`. A replay that charged a
    /// retry per drain would walk an operation to its retry ceiling during an
    /// ordinary backgrounded-writes window.
    @Test("Outlook: a retirement replay that fails again stops the drain, keeps the proof, and charges no retry")
    @MainActor
    func aRetirementReplayThatFailsAgainStopsTheDrainAndChargesNobody() async throws {
        let rfc = "graph-handoff-replay-refused@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-replay-refused")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.drainPendingQueue()

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1, """
            the provider's proven result was not retained, so the second drain \
            below has no replay to attempt
            """)

        let afterFirstDrain = server.http.servedCallSequence()
        #expect(afterFirstDrain.filter { $0.hasSuffix("/move") }.count == 1,
                "the move was not sent exactly once: \(afterFirstDrain)")

        // 🚨 EXACTLY ONE MORE DRAIN, not a quiescence loop. The refusal COUNT is
        // this test's oracle, and a helper that keeps calling the drain until
        // the queue empties would call it an unbounded number of times and turn
        // that oracle into noise. Quiescence is asserted first so this call is
        // provably the only drain running: `drainPendingQueue` returns
        // immediately and records a redrain when one is already in flight.
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "the first drain has not settled, so the second is not this test's")
        await AccountManager.shared.drainPendingQueue()

        // The replay ran, and ran the SAME write — three more `retryWrite`
        // attempts and no more.
        #expect(refuser.refusals.withLock { $0 } == 6, """
            the retained retirement was not replayed for exactly its three \
            attempts on the second drain: \(refuser.refusals.withLock { $0 })
            """)

        // 🚨 THE ORACLE. The second drain reached the wire NOT AT ALL — it did
        // not claim, so it did not execute, so the wire record is byte-identical
        // to the one the first drain left.
        #expect(server.http.servedCallSequence() == afterFirstDrain, """
            a claim pass ran after a retirement replay that could not commit: \
            \(server.http.servedCallSequence()). The only address the follower \
            can name is the one the still-uncommitted proof is holding.
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1, """
            the provider's proven result was DISCARDED by a replay that failed — \
            the wire effect it applied is now recorded nowhere
            """)

        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldFollower != nil, """
            the follower was DESTROYED across a second failed replay while this \
            process still held the proof that would have re-addressed it
            """)
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue,
                "the held move left `inFlight`: \(heldMove?.status ?? "<deleted>")")
        #expect(heldMove?.messageIds == ["graph-1"],
                "the move row lost members: \(String(describing: heldMove?.messageIds))")
        #expect(heldFollower?.status == PendingStatus.queued.rawValue,
                "the follower is not retryable: \(heldFollower?.status ?? "<deleted>")")
        #expect(heldFollower?.messageIds == ["graph-1"],
                "the follower's address moved with nothing committed to prove it")
        // A LOCAL write that will not commit is not the provider failing. A
        // replay that charged a retry per drain would exhaust an operation
        // during an ordinary backgrounded-writes window.
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a failed replay charged a provider retry: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        // Recovery, unchanged by the extra failed attempt.
        f.pool.remove(transactionObserver: refuser)
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was replayed on the wire — a proven move must be applied \
            exactly once: \(finalCalls)
            """)
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(current)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(patches)
            """)

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: current)?.isRead == true,
            gesture: "the mark-read behind a retirement whose replay failed a second time",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    /// **THE SAME PROPERTY ON THE PARTIAL ARM: a retained NARROWING whose replay
    /// fails again stops the drain, keeps the proof, and charges nobody.**
    ///
    /// Kept separate from the whole-op sibling because the two run different
    /// transactions through the same catch — `commitPartialRetirement` re-keys
    /// only the PROVEN members and narrows the durable row to the ones still
    /// owed, so a replay that failed halfway would leave a row nothing can
    /// address (`IOS-QUEUE-005`). The bundle must therefore still hold BOTH
    /// members after the second refusal, not just the unproven one.
    @Test("Outlook: a narrowing replay that fails again stops the drain, keeps the proof, and charges no retry")
    @MainActor
    func aNarrowingReplayThatFailsAgainStopsTheDrainAndChargesNobody() async throws {
        let firstRfc = "graph-handoff-narrowing-replay-a@example.com"
        let secondRfc = "graph-handoff-narrowing-replay-b@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: firstRfc, providerMessageId: "graph-a", folderId: Self.source),
            .init(rfc822MessageId: secondRfc, providerMessageId: "graph-b", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-narrowing-replay")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-a", rfc: firstRfc, destination: Self.firstDestination)
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-b", rfc: secondRfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-a", "graph-b"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)
        server.failMoveOnce(providerMessageId: "graph-b")

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.drainPendingQueue()

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the narrowing write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the partial result was not retained, so there is no replay to attempt")

        // An attempt settles ONE member, so a two-member move is partial by
        // construction and exactly one `/move` may be on the wire.
        let afterFirstDrain = server.http.servedCallSequence()
        #expect(afterFirstDrain.filter { $0.hasSuffix("/move") }.count == 1,
                """
                the attempt addressed more than the one member it may settle: \
                \(afterFirstDrain)
                """)

        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "the first drain has not settled, so the second is not this test's")
        await AccountManager.shared.drainPendingQueue()

        #expect(refuser.refusals.withLock { $0 } == 6, """
            the retained narrowing was not replayed for exactly its three \
            attempts on the second drain: \(refuser.refusals.withLock { $0 })
            """)
        #expect(server.http.servedCallSequence() == afterFirstDrain, """
            a claim pass ran after a narrowing replay that could not commit: \
            \(server.http.servedCallSequence())
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the proven half of the batch was DISCARDED by a replay that failed")

        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldFollower != nil,
                "the follower was DESTROYED across a second failed narrowing replay")
        #expect(heldMove?.messageIds == ["graph-a", "graph-b"], """
            the bundle was narrowed by a replay whose write never committed, so \
            the unproven member is owed by nobody: \
            \(String(describing: heldMove?.messageIds))
            """)
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue,
                "the bundle left `inFlight`: \(heldMove?.status ?? "<deleted>")")
        #expect(heldFollower?.messageIds == ["graph-a"],
                "the follower's address moved with nothing committed to prove it")
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a failed replay charged a provider retry: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        f.pool.remove(transactionObserver: refuser)
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        let provenA = liveId(server, rfc: firstRfc)
        #expect(provenA != nil && provenA != "graph-a")
        guard let provenA else { return }
        #expect(finalCalls.filter { $0.hasSuffix("/messages/graph-a/move") }.count == 1,
                "the proven member's move was re-sent: \(finalCalls)")
        #expect(serverFolders(server, rfc: secondRfc) == [Self.firstDestination],
                "the refused member did not converge: \(serverFolders(server, rfc: secondRfc))")
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(provenA)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(provenA)): \(patches)
            """)

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: provenA)?.isRead == true,
            gesture: "the mark-read behind a narrowing whose replay failed a second time",
            serverState: "id=\(provenA) folders=\(serverFolders(server, rfc: firstRfc))")

        await finish(f)
    }

    // MARK: - T-J — the retained proof whose ROW the user deleted

    /// **THE PROPERTY: a retained proof whose durable operation the user has
    /// since deleted is DROPPED, and the drain carries on with everything else.**
    ///
    /// This is `replayRetainedRetirements`' row-gone arm, and it is the mirror of
    /// the catch arm above: absence of the row is NOT a failure to commit. The
    /// writers that can delete a claimed row are the local wipes and resets —
    /// here the real one, `SettingsView.localIndexWipeTxn`, the user's own
    /// "delete all local email data" gesture — which never join a running drain.
    /// So the row being gone is the user's NEWER decision winning, and replaying
    /// a retirement against a row nobody wants would re-key a header the wipe
    /// deleted.
    ///
    /// Treating it as a failure instead is the shape that must never ship: the
    /// entry can never be resolved, so the top-of-drain gate refuses EVERY
    /// subsequent drain for the life of the process and the queue wedges whole —
    /// every later gesture, on every account, starves behind one dead entry.
    ///
    /// The deletion is performed by the REAL producer, not a hand-written
    /// `DELETE`, for the reason
    /// `drainPendingQueueRealRowDeletedByALocalWipeMidDrainIsSkipped` states: a
    /// hand-written delete proves the arm runs, only the real transaction proves
    /// it is REACHABLE.
    @Test("Outlook: a retained proof whose row the user's local wipe deleted is dropped, and the drain proceeds")
    @MainActor
    func aRetainedProofWhoseRowWasWipedIsDroppedAndTheDrainProceeds() async throws {
        let movedRfc = "graph-handoff-wiped-move@example.com"
        let bystanderRfc = "graph-handoff-wiped-bystander@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: movedRfc, providerMessageId: "graph-1", folderId: Self.source),
            .init(rfc822MessageId: bystanderRfc, providerMessageId: "graph-2", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-wiped")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: movedRfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
        ])
        #expect(ordered.count == 1)
        guard ordered.count == 1 else { return }

        await register(server.provider(), f)

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        await AccountManager.shared.drainPendingQueue()

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the provider's proven result was not retained, so there is nothing to drop")
        let afterMove = server.http.servedCallSequence()
        #expect(afterMove.filter { $0.hasSuffix("/move") }.count == 1,
                "the move was not sent exactly once: \(afterMove)")

        // Writes work again BEFORE the wipe: `localIndexWipeStatements` begins
        // with `DELETE FROM messageHeader`, so a refuser still installed would
        // refuse the user's gesture instead of the retirement.
        f.pool.remove(transactionObserver: refuser)

        // THE USER'S NEWER DECISION, through its real transaction.
        try await f.pool.write { db in try SettingsView.localIndexWipeTxn(db) }
        #expect(try queuedOperationCount(f) == 0,
                "the wipe left the operation behind, so the row-gone arm is not reached")
        #expect(try rows(f).isEmpty, "the wipe left headers behind")

        // An ORDINARY, independent operation on a different message, seeded
        // after the wipe. It is what proves the drain PROCEEDED rather than
        // merely not crashing.
        try seedHeader(f, graphId: "graph-2", rfc: bystanderRfc)
        let independent = try seedSchedule(f, [
            PendingOperation(
                type: .markRead, messageIds: ["graph-2"],
                accountId: f.accountId, folderPath: Self.source),
        ])
        #expect(independent.count == 1)

        try await drainToQuiescence(f)

        // 🚨 THE ORACLE, both halves. The dead entry is gone, and the drain that
        // dropped it went on to do the work in front of it.
        #expect(await AccountManager.shared.pendingRetirements.isEmpty, """
            a retained proof whose durable row no longer exists was kept, so the \
            top-of-drain gate refuses every later drain for the life of the \
            process and the whole queue wedges
            """)
        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasPrefix("PATCH ") } == ["PATCH /v1.0/me/messages/graph-2"], """
            the independent operation did not execute, so the drain did not \
            proceed past the dropped entry: \(finalCalls)
            """)
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the wiped operation's move was replayed on the wire against a row \
            the user deleted: \(finalCalls)
            """)
        #expect(server.snapshot(providerMessageId: "graph-2")?.isRead == true,
                "the independent operation's effect is not visible on the server")

        let survivors = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(survivors.isEmpty, """
            the queue did not converge: \
            \(survivors.map { "\($0.type.rawValue)/\($0.status)" })
            """)

        await finish(f)
    }

    // MARK: - A1 — the launch reconciler must never sweep what THIS process owns

    /// **THE PROPERTY: a proven retirement this LIVE process is still holding is
    /// not erased by `reconcilePendingOperations`.**
    ///
    /// The premise that made a blind whole-table sweep safe inside that function
    /// was *"nothing has drained yet in this process"*. It is FALSE at its call
    /// site: `RootView` calls it only after EVERY account has finished
    /// connecting, and a connected account's gestures (and the background entry
    /// points) already drain before that. So the sweep runs in the middle of a
    /// live queue, and its `.move` + `everAttempted` arm deletes a row whose
    /// provider result this process is still holding.
    ///
    /// End to end, on the unmodified code: the move is proven on the wire, its
    /// retirement write is refused, the proof is retained and the row stays
    /// `inFlight` + `everAttempted`. The sweep DELETES that row.
    /// `replayRetainedRetirements` then finds no row, takes the arm that exists
    /// for *"the user wiped this"*, and drops the proof — after which the
    /// follower is claimed ALONE at the id Graph already reallocated, `404`s, and
    /// is deleted by the single-message conflict arm as provider-authoritative
    /// "already done". No crash, live process: outside the accepted window.
    ///
    /// The fix moves that sweep to the database-startup boundary
    /// (`AppDatabase.recoverPreviousSessionResidue`, run inside `init` before the
    /// pool is ever published, where nothing in this process can have claimed
    /// anything) and DELETES it from here. The oracle is therefore what this
    /// entry point no longer does, measured on the wire and the durable queue.
    @Test("Outlook: the launch reconciler does not erase a proven retirement this process still holds")
    @MainActor
    func theLaunchReconcilerDoesNotEraseARetirementThisProcessStillOwns() async throws {
        let rfc = "graph-handoff-reconcile-full@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-reconcile-full")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        await AccountManager.shared.drainPendingQueue()
        // Writes work again BEFORE the reconciler runs: the defect under test is
        // the SWEEP, not a second refusal, and a refuser still installed would
        // stop the replay for the wrong reason (`MIS-027`).
        f.pool.remove(transactionObserver: refuser)

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1, """
            the provider's proven result was not retained, so there is nothing \
            for the sweep to erase and this test proves nothing
            """)
        let afterFirstDrain = server.http.servedCallSequence()
        #expect(afterFirstDrain.filter { $0.hasSuffix("/move") }.count == 1,
                "the move was not sent exactly once: \(afterFirstDrain)")
        #expect(afterFirstDrain.filter { $0.hasPrefix("PATCH ") }.isEmpty, """
            the follower executed while its predecessor's proof was still \
            uncommitted: \(afterFirstDrain.filter { $0.hasPrefix("PATCH ") })
            """)
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so there is no dead address to fail on")

        // NON-VACUITY for the sweep itself: the retained row is in EXACTLY the
        // state the sweep's `.move` + `everAttempted` arm selects on. If it were
        // not, the reconciler below would leave it alone for a reason unrelated
        // to the fix.
        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue
                    && heldMove?.everAttempted == true, """
            the retained move is not in the state the sweep selects on: \
            status=\(heldMove?.status ?? "<deleted>") \
            everAttempted=\(heldMove?.everAttempted ?? false)
            """)
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a provider retry was charged for a LOCAL write failure: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        // 🚨 THE ENTRY POINT UNDER TEST — the real `RootView` one, arriving after
        // this account already drained. Never `drainPendingQueue`, and never the
        // startup static: the defect is what THIS function does on its way to the
        // drain.
        await AccountManager.shared.reconcilePendingOperations()
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was replayed on the wire — a proven move must be applied \
            exactly once: \(finalCalls)
            """)
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, """
            the follower did not execute exactly once — the reconciler's sweep \
            deleted the row holding its address, so the proof was dropped and \
            the follower went out at the id Graph had already invalidated: \(patches)
            """)
        #expect(patches.allSatisfy { $0.hasSuffix("/\(current)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(patches)
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained proof never resolved")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: current)?.isRead == true,
            gesture: "the mark-read behind a retirement the launch reconciler swept",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    /// **THE PROPERTY: the launch reconciler does not erase a retained NARROWING
    /// either — and the members that narrowing still OWES survive it.**
    ///
    /// The partial arm loses strictly more than the full one, which is why it is
    /// a separate witness rather than a variant of the previous test. The bundle
    /// row is `inFlight` with BOTH members: the one the wire proved and the one
    /// it refused. The sweep's `.move` + `everAttempted` arm deletes the whole
    /// row, so the still-owed, never-executed member is discarded along with the
    /// proof — a user gesture that never reached the wire at all, dropped by
    /// none of the four exits.
    ///
    /// The schedule is `aHeldNarrowingStopsTheDrainWithoutABystander`'s: a
    /// two-member move whose first member Graph proves (and reallocates) while
    /// the second is refused with a transient `503`, which is the only shape that
    /// reaches the partial arm at all.
    @Test("Outlook: the launch reconciler does not erase a held narrowing or the members it still owes")
    @MainActor
    func theLaunchReconcilerDoesNotEraseAHeldNarrowingsStillOwedMembers() async throws {
        let firstRfc = "graph-handoff-reconcile-narrow-a@example.com"
        let secondRfc = "graph-handoff-reconcile-narrow-b@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: firstRfc, providerMessageId: "graph-a", folderId: Self.source),
            .init(rfc822MessageId: secondRfc, providerMessageId: "graph-b", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-reconcile-narrow")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-a", rfc: firstRfc, destination: Self.firstDestination, isRead: true)
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-b", rfc: secondRfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-a", "graph-b"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id

        await register(server.provider(), f)
        server.failMoveOnce(providerMessageId: "graph-b")

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        await AccountManager.shared.drainPendingQueue()
        f.pool.remove(transactionObserver: refuser)

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the narrowing write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1, """
            the provider's proven partial result was not retained, so there is \
            nothing for the sweep to erase
            """)
        #expect(server.snapshot(providerMessageId: "graph-a") == nil,
                "Graph did not reallocate A's id, so there is no dead address to fail on")
        #expect(server.snapshots(rfc822MessageId: secondRfc).map(\.folderId) == [Self.source],
                "B moved even though its move was refused, so this is not a partial batch")

        // NON-VACUITY: the row the sweep selects on still carries BOTH members —
        // the proven one and the one that is still owed.
        let heldMove = try await f.pool.read { db in
            try PendingOperation.fetchOne(db, key: moveOpId)
        }
        #expect(heldMove?.messageIds == ["graph-a", "graph-b"], """
            the bundle was narrowed even though the narrowing write never \
            committed: \(String(describing: heldMove?.messageIds))
            """)
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue
                    && heldMove?.everAttempted == true, """
            the retained bundle is not in the state the sweep selects on: \
            status=\(heldMove?.status ?? "<deleted>") \
            everAttempted=\(heldMove?.everAttempted ?? false)
            """)

        await AccountManager.shared.reconcilePendingOperations()
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        let provenA = liveId(server, rfc: firstRfc)
        #expect(provenA != nil && provenA != "graph-a")
        guard let provenA else { return }

        #expect(finalCalls.filter { $0.hasSuffix("/messages/graph-a/move") }.count == 1, """
            the proven member's move was re-sent, which would seat a second copy \
            at the destination: \(finalCalls)
            """)
        // 🚨 THE MEMBER THE SWEEP DISCARDS. B never reached the wire successfully
        // before the reconciler ran; if its row is gone, the user's move of B is
        // a dropped intention by none of the four exits.
        #expect(serverFolders(server, rfc: secondRfc) == [Self.firstDestination], """
            the still-owed member never moved — the launch reconciler deleted \
            the bundle that owed it: \(serverFolders(server, rfc: secondRfc))
            """)
        #expect(finalCalls.filter { $0.hasSuffix("/messages/graph-b/move") }.count == 2, """
            the refused member was not retried exactly once after its transient \
            failure: \(finalCalls)
            """)

        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(provenA)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(provenA)): \(patches)
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained proof never resolved")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: provenA)?.isRead == true,
            gesture: "the mark-read behind a narrowing the launch reconciler swept",
            serverState: "id=\(provenA) folders=\(serverFolders(server, rfc: firstRfc))")

        await finish(f)
    }

    /// **THE PROPERTY: the launch reconciler arriving WHILE A DRAIN IS ACTIVE
    /// touches neither the move that drain has claimed nor the follower behind
    /// it.**
    ///
    /// This is the defect at its root, with no retirement failure involved at
    /// all: `reconcilePendingOperations` is reentrant with a running drain,
    /// because `RootView` calls it after the LAST account connects while the
    /// FIRST account's gestures have been draining for some time. A blind sweep
    /// there deletes a `.move` row whose provider call is on the wire right now,
    /// and returns its claimed follower to `queued` while the lane task that owns
    /// it is still holding it.
    ///
    /// ⚠️ WHY THESE TWO ROW READS ARE DETERMINISTIC even though a drain is in
    /// flight. The only other writer of either row while the move is parked is
    /// the lane task, and it is blocked inside the fixture's `/move` route until
    /// `release()` is called; the reconciler call above it has been AWAITED to
    /// completion. So the reads observe exactly one candidate writer — the sweep
    /// — which is what they are here to see. Every other oracle in this test is
    /// the terminal wire record and the terminal queue, per the standing rule
    /// that mid-drain row state is not an oracle.
    @Test("Outlook: the launch reconciler arriving during a live drain leaves the claimed move and its follower alone")
    @MainActor
    func theLaunchReconcilerArrivingDuringADrainLeavesTheClaimedLaneAlone() async throws {
        let rfc = "graph-handoff-reconcile-live@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-reconcile-live")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)
        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }

        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so the reconciler never arrives mid-drain")
        guard held else {
            release()
            _ = await drain.value
            await finish(f)
            return
        }

        // 🚨 THE RECONCILER ARRIVES MID-DRAIN. Its own `drainPendingQueue()` sees
        // `isDraining` and records a redrain, so this call returns without
        // waiting — which is exactly why the sweep that used to run first was
        // able to hit a live queue.
        await AccountManager.shared.reconcilePendingOperations()

        let (midMove, midFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(midMove != nil, """
            the launch reconciler DELETED a move whose provider call is on the \
            wire right now. Nothing in the queue records that the user ever \
            asked, and the result the wire is about to return has no row to retire.
            """)
        #expect(midMove?.status == PendingStatus.inFlight.rawValue, """
            the launch reconciler returned a CLAIMED, in-flight move to the \
            queue, where the next claim pass can hand it to the provider a \
            second time: \(midMove?.status ?? "<deleted>")
            """)
        // The follower was never CLAIMED — the executor runs one operation at a
        // time — so what the reconciler must not do to it is DELETE it. It is
        // `queued` and untouched, which is also what makes it safe: a row that
        // was never claimed cannot be "released" into a second execution.
        #expect(midFollower != nil, """
            the launch reconciler DELETED an ordinary queued follower while the \
            move ahead of it was on the wire — the user's newest gesture is gone
            """)
        #expect(midFollower?.status == PendingStatus.queued.rawValue, """
            the follower is not ordinary queued work, so the reconciler was \
            handed a state it should never see mid-drain: \
            \(midFollower?.status ?? "<deleted>")
            """)
        #expect(midFollower?.everAttempted == false,
                "the follower was claimed while its predecessor's move was still in flight")

        release()
        _ = await drain.value
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move did not run exactly once: \(finalCalls)
            """)
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(current)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(patches)
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a retirement was retained by a drain that had no write failure in it")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: current)?.isRead == true,
            gesture: "the mark-read behind a move the launch reconciler arrived on top of",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - R1 — a refused retirement STOPS the drain, and nothing behind it was claimed

    /// A GRDB `TransactionObserver` that refuses the commit of EVERY write
    /// transaction while it is armed, and counts the refusals.
    ///
    /// 🚨 THE BREADTH IS THE POINT, and it is why `HeaderCommitRefuser` cannot
    /// witness this scenario. That refuser is scoped to transactions that wrote
    /// `messageHeader`, so a status-only `pendingOperation` write sails straight
    /// through it. The real producer of a refused retirement is NOT
    /// header-shaped: GRDB suspends the whole writer connection when the app is
    /// backgrounded mid-drain while WAL reads keep working (ADR-IOS-041), and a
    /// full disk or an I/O error at COMMIT is equally indiscriminate. A
    /// database-WIDE refusal is what makes the retirement and every recovery
    /// write it might attempt fail together, which is the state the retained
    /// proof exists for.
    ///
    /// Armed explicitly rather than at registration so the fixture's own writes
    /// and the drain's claim transaction commit normally — the first transaction
    /// this can refuse is the one the test is about.
    private final class AllWritesRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let armed = Mutex(false)
        let refusals = Mutex(0)

        func arm() { armed.withLock { $0 = true } }
        func disarm() { armed.withLock { $0 = false } }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseWillCommit() throws {
            guard armed.withLock({ $0 }) else { return }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {}
        func databaseDidRollback(_ db: Database) {}
    }

    /// **THE PROPERTY: a retirement the database refuses stops the drain with
    /// the provider's proof held, and every operation behind it is still
    /// ORDINARY QUEUED WORK — untouched, unclaimed, uncharged — that converges
    /// once writes work again.**
    ///
    /// 🚨 WHAT THIS TEST USED TO BE ABOUT, AND WHY THE DEFECT IS GONE RATHER
    /// THAN FIXED. The predecessor claimed EVERY eligible row up front and
    /// dispatched them across lanes, so a lane that halted was holding a SUFFIX
    /// of rows it had already committed to `inFlight`. The halt site returned
    /// them best-effort (`try? await retryWrite`), which is correct for every
    /// halt cause except this one: a database-wide refusal lost the retirement
    /// AND the requeue together and discarded the requeue's error, stranding the
    /// follower `inFlight` — a state only a claim writes and every claim refuses
    /// — so no later pass in that process could pick it up, and the next launch
    /// DELETED it as previous-session residue. The scheduler carried a
    /// `pendingRetirementSuffixes` map purely to undo that.
    ///
    /// The global single-operation executor claims ONE row, executes it, and
    /// commits its result before claiming anything else. There is no suffix: the
    /// follower below is never claimed at all, so it cannot be stranded, nothing
    /// has to be given back, and the map is deleted. The assertions therefore
    /// moved from "the suffix was returned" to the stronger "the suffix never
    /// existed" — the follower is `queued`, never attempted, and charged nothing
    /// — and the convergence half is unchanged, because that is the outcome the
    /// user actually feels.
    ///
    /// Both halves are asserted because they fail in opposite directions. While
    /// the refusal stands, NOTHING may move: one `/move` on the wire, no `PATCH`
    /// at any id, the follower never executed, no retry charged for a local
    /// write failure. Once writes work again the queue must CONVERGE: still
    /// exactly one `/move` ever, the follower's only `PATCH` at the address the
    /// move proved, the server's own read flag set there, and an empty queue.
    @Test("Outlook: a retirement refused by a database-wide failure stops the drain holding its proof, and the work behind it was never claimed")
    @MainActor
    func aRefusedRetirementStopsTheDrainAndNothingBehindItIsClaimed() async throws {
        let rfc = "graph-handoff-suffix-full@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-suffix-full")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)

        let refuser = AllWritesRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        // ARMED ONLY ONCE THE CLAIM HAS COMMITTED AND THE MOVE IS ON THE WIRE.
        // Parking the move is what makes that ordering observable rather than
        // hoped for: the claim transaction is behind us, the provider call is
        // in flight, and the very next write this process attempts is the
        // retirement of a move the server has already performed.
        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }
        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so the refusal cannot be placed after the claim")
        guard held else {
            release()
            _ = await drain.value
            await finish(f)
            return
        }
        refuser.arm()
        release()
        _ = await drain.value

        // NON-VACUITY, and it is the whole scenario in one number. THREE
        // refusals are the retirement's `retryWrite` attempts, and there is
        // nothing else for the refusal to catch: the executor claimed exactly one
        // row, so no requeue of a claimed suffix is even attempted. Fewer than
        // three means the retirement never ran under the refusal and this test is
        // not measuring what it names; more means a second write — a suffix
        // requeue, a speculative claim — happened after a proven result went
        // uncommitted, which is the thing the stop exists to prevent.
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on exactly the retirement's three write \
            attempts, so this is not the scenario under test: \
            \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the provider's proven result was not retained, so there is no replay to attempt")

        let afterFirstDrain = server.http.servedCallSequence()
        #expect(afterFirstDrain.filter { $0.hasSuffix("/move") }.count == 1,
                "the move was not sent exactly once: \(afterFirstDrain)")
        #expect(afterFirstDrain.filter { $0.hasPrefix("PATCH ") }.isEmpty, """
            the follower executed while its predecessor's proof was still \
            uncommitted — it can only have named the id the move destroyed: \
            \(afterFirstDrain.filter { $0.hasPrefix("PATCH ") })
            """)

        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue,
                "the move left `inFlight`: \(heldMove?.status ?? "<deleted>")")
        #expect(heldFollower?.status == PendingStatus.queued.rawValue, """
            the follower was CLAIMED while its predecessor's proven result was \
            still uncommitted — under a single-operation executor nothing behind \
            the stop may be claimed at all: \(heldFollower?.status ?? "<deleted>")
            """)
        #expect(heldFollower?.everAttempted == false, """
            the follower carries the attempted-row proof, so it reached a claim \
            transaction it should never have reached
            """)
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a provider retry was charged for a LOCAL write failure: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        // The database accepts writes again — the recovery every live process
        // reaches when it returns to the foreground.
        refuser.disarm()
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was replayed on the wire — a proven move must be applied \
            exactly once: \(finalCalls)
            """)
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, """
            the follower held behind the refused retirement never executed: \
            \(patches)
            """)
        #expect(patches.allSatisfy { $0.hasSuffix("/\(current)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(patches)
            """)
        let recovered = try await f.pool.read { db in
            try PendingOperation.filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchCount(db)
        }
        #expect(recovered == 0, """
            \(recovered) row(s) were left `inFlight` after the queue drained — \
            unclaimable for the life of the process, and deleted at the next launch
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained proof was never resolved")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: current)?.isRead == true,
            gesture: "the mark-read held behind a retirement the database refused",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    /// **THE PARTIAL SIBLING of the test above: a NARROWING refused by the same
    /// database-wide failure stops the drain the same way, and leaves the work
    /// behind it just as untouched.**
    ///
    /// The two retirement transactions are separate functions
    /// (`commitFullRetirement`, `commitPartialRetirement`) reached from separate
    /// callers, and a fix applied to one of them leaves the other exactly as
    /// broken. The partial arm is also the harder half: its replay narrows the
    /// durable row to the members still owed AND re-addresses the proven ones,
    /// in one transaction, so a refusal must lose both together or neither.
    ///
    /// The second member's move is failed once so the batch retires partially;
    /// everything else is the full test's shape.
    @Test("Outlook: a narrowing refused by a database-wide failure stops the drain holding its proof, and the work behind it was never claimed")
    @MainActor
    func aRefusedNarrowingStopsTheDrainAndNothingBehindItIsClaimed() async throws {
        let firstRfc = "graph-handoff-suffix-partial-a@example.com"
        let secondRfc = "graph-handoff-suffix-partial-b@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: firstRfc, providerMessageId: "graph-a", folderId: Self.source),
            .init(rfc822MessageId: secondRfc, providerMessageId: "graph-b", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-suffix-partial")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-a", rfc: firstRfc, destination: Self.firstDestination)
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-b", rfc: secondRfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-a", "graph-b"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)
        server.failMoveOnce(providerMessageId: "graph-b")

        let refuser = AllWritesRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }
        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so the refusal cannot be placed after the claim")
        guard held else {
            release()
            _ = await drain.value
            await finish(f)
            return
        }
        refuser.arm()
        release()
        _ = await drain.value

        // See the full-retirement sibling: THREE, not six. The executor claimed
        // one row, so there is no claimed suffix for a second refused write to
        // be spent on.
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on exactly the narrowing's three write \
            attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the partial result was not retained, so there is no replay to attempt")

        // An attempt settles ONE member, so a two-member move is partial by
        // construction and exactly one `/move` may be on the wire.
        let afterFirstDrain = server.http.servedCallSequence()
        #expect(afterFirstDrain.filter { $0.hasSuffix("/move") }.count == 1, """
            the attempt addressed more than the one member it may settle: \
            \(afterFirstDrain)
            """)
        #expect(afterFirstDrain.filter { $0.hasPrefix("PATCH ") }.isEmpty, """
            the follower executed while the narrowing that re-addresses it was \
            still uncommitted: \(afterFirstDrain.filter { $0.hasPrefix("PATCH ") })
            """)

        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldMove?.messageIds == ["graph-a", "graph-b"], """
            the bundle was narrowed by a write that never committed, so the \
            unproven member is owed by nobody: \
            \(String(describing: heldMove?.messageIds))
            """)
        #expect(heldFollower?.status == PendingStatus.queued.rawValue, """
            the follower was CLAIMED while the narrowing's proven result was \
            still uncommitted — nothing behind the stop may be claimed at all: \
            \(heldFollower?.status ?? "<deleted>")
            """)
        #expect(heldFollower?.everAttempted == false,
                "the follower carries the attempted-row proof, so it reached a claim it should not have")
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a provider retry was charged for a LOCAL write failure: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        refuser.disarm()
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        let provenA = liveId(server, rfc: firstRfc)
        #expect(provenA != nil && provenA != "graph-a")
        guard let provenA else { return }
        #expect(finalCalls.filter { $0.hasSuffix("/messages/graph-a/move") }.count == 1,
                "the proven member's move was re-sent: \(finalCalls)")
        #expect(serverFolders(server, rfc: secondRfc) == [Self.firstDestination],
                "the refused member did not converge: \(serverFolders(server, rfc: secondRfc))")
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, """
            the follower held behind the refused narrowing never executed: \
            \(patches)
            """)
        #expect(patches.allSatisfy { $0.hasSuffix("/\(provenA)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(provenA)): \(patches)
            """)
        let recovered = try await f.pool.read { db in
            try PendingOperation.filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchCount(db)
        }
        #expect(recovered == 0, """
            \(recovered) row(s) were left `inFlight` after the queue drained — \
            unclaimable for the life of the process, and deleted at the next launch
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained narrowing was never resolved")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: provenA)?.isRead == true,
            gesture: "the mark-read stranded behind a narrowing whose requeue the same refusal swallowed",
            serverState: "id=\(provenA) folders=\(serverFolders(server, rfc: firstRfc))")

        await finish(f)
    }

    // MARK: - TC-2 — the replay's existence read, when the read itself fails

    /// **THE PROPERTY: a replay whose existence read FAILS is not a replay whose
    /// row is absent. The retained proof is kept, nothing is claimed, and the
    /// next healthy drain recovers.**
    ///
    /// `nil` from that read means exactly one thing — a local wipe or reset
    /// deleted the row, which is the user's newer decision winning, so the proof
    /// is dropped. A THROW means we could not determine the answer, which clause
    /// 2 of `never-drop-user-intention.md` makes retryable forever. Collapsing
    /// the two would drop a proven move's result on a busy/interrupted/I-O read
    /// and strand every holder of the old address.
    ///
    /// The replay asks that question through `liveOperation`, and is now that
    /// function's ONLY caller — the executor reads the row it claims inside the
    /// claim transaction, so the post-claim re-read the predecessor needed is
    /// gone. Reusing it rather than writing a second copy of the same two-outcome
    /// contract is what makes the thrown case reachable from a test
    /// at all: `liveOperationReadFaultForTesting` is a `#if DEBUG` one-shot fault
    /// keyed by op id that can only ADD a throw. A connection-level fault cannot
    /// stand in for it, because every earlier read of the drain runs on the same
    /// `PrioritizedDatabase` and would fail the drain before the replay.
    @Test("Outlook: a retirement replay whose existence read FAILS keeps the proof and recovers on the next healthy drain")
    @MainActor
    func aReplayWhoseExistenceReadFailsKeepsTheProof() async throws {
        let rfc = "graph-handoff-replay-read-fault@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-replay-read-fault")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 2)
        guard ordered.count == 2 else { return }
        let moveOpId = ordered[0].id
        let followerOpId = ordered[1].id

        await register(server.provider(), f)

        let refuser = HeaderCommitRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        await AccountManager.shared.drainPendingQueue()

        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the provider's proven result was not retained, so there is no replay to fault")

        let afterFirstDrain = server.http.servedCallSequence()
        #expect(afterFirstDrain.filter { $0.hasSuffix("/move") }.count == 1,
                "the move was not sent exactly once: \(afterFirstDrain)")

        // WRITES WORK AGAIN, so the ONLY thing that can stop the replay below is
        // the read fault. Without this the test would prove nothing about reads.
        f.pool.remove(transactionObserver: refuser)

        defer { AccountManager.liveOperationReadFaultForTesting.withLock { $0 = nil } }
        AccountManager.liveOperationReadFaultForTesting.withLock { $0 = moveOpId }
        #expect(AccountManager.liveOperationReadFaultForTesting.withLock { $0 } == moveOpId,
                "the fault was not armed, so this drain does not exercise the thrown read")

        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "the first drain has not settled, so the second is not this test's")
        await AccountManager.shared.drainPendingQueue()

        // THE SEAM FIRED. It clears its own arming in the same critical section,
        // so `nil` here is proof the replay consulted it — and the only caller
        // that could have is the replay, because the drain stops before any
        // claim.
        #expect(AccountManager.liveOperationReadFaultForTesting.withLock { $0 } == nil, """
            the replay never consulted the read seam, so it is still asking the \
            existence question through a second, uncovered copy of the contract
            """)

        // 🚨 THE ORACLE. A thrown read is not an absent row: the proof is KEPT,
        // and because the drain stops before claiming anything, nothing reached
        // the wire.
        #expect(await AccountManager.shared.pendingRetirements.count == 1, """
            a read that FAILED was read as "the row is gone" and the provider's \
            proven result was DROPPED — every holder of the old address is now \
            stranded
            """)
        #expect(server.http.servedCallSequence() == afterFirstDrain, """
            a claim pass ran after a replay whose existence read failed: \
            \(server.http.servedCallSequence())
            """)

        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldMove?.messageIds == ["graph-1"],
                "the move row lost members: \(String(describing: heldMove?.messageIds))")
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue,
                "the move left `inFlight`: \(heldMove?.status ?? "<deleted>")")
        #expect(heldFollower?.messageIds == ["graph-1"], """
            the follower's address moved even though the transaction that \
            proves it never committed: \(String(describing: heldFollower?.messageIds))
            """)
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a provider retry was charged for a failed local READ: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        // The fault is one-shot, so the next drain reads normally and converges.
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was replayed on the wire — a proven move must be applied \
            exactly once: \(finalCalls)
            """)
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1")
        guard let current else { return }
        let patches = finalCalls.filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 1, "the follower did not execute exactly once: \(patches)")
        #expect(patches.allSatisfy { $0.hasSuffix("/\(current)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(patches)
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained proof was never resolved")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: current)?.isRead == true,
            gesture: "the mark-read behind a replay whose existence read failed",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - TC-1 — MORE THAN ONE retained result in the same replay

    /// A `HeaderCommitRefuser` that ALLOWS the first `allowance` header-writing
    /// commits and refuses every one after that.
    ///
    /// 🚨 THE SELECTOR IS THE TRANSACTION ORDINAL, NEVER THE OP ID.
    /// `replayRetainedRetirements` iterates a Swift `Dictionary`, whose order is
    /// unspecified and seed-dependent, so a refuser keyed on "the second
    /// account's op" would refuse the FIRST replayed entry on some runs and the
    /// second on others — the test would be measuring the hash seed. Counting
    /// commits instead names exactly what the scenario needs ("one replay lands,
    /// the next does not") without depending on which entry that turns out to be,
    /// and every assertion below is written so either assignment satisfies it.
    private final class HeaderCommitOrdinalRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let sawHeaderWrite = Mutex(false)
        private let remaining: Mutex<Int>
        let allowed = Mutex(0)
        let refusals = Mutex(0)

        init(allowing allowance: Int) { self.remaining = Mutex(allowance) }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageHeader.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            sawHeaderWrite.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawHeaderWrite.withLock({ $0 }) else { return }
            let permitted = remaining.withLock { left -> Bool in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            if permitted {
                allowed.withLock { $0 += 1 }
                return
            }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
    }

    /// **THE PROPERTY: an unresolved proven retirement holds back EVERY
    /// ACCOUNT's queue, not just its own — no claim pass starts, nothing else
    /// reaches any wire, and a later healthy drain converges both accounts with
    /// exactly one `/move` per message.**
    ///
    /// 🚨 THIS TEST USED TO DRIVE TWO SIMULTANEOUS PROOFS, AND THAT STATE IS NOW
    /// UNREACHABLE — which is the improvement, not a gap. The predecessor
    /// dispatched accounts concurrently, so one drain could put both accounts'
    /// moves on the wire and have BOTH retirements refused; the replay then had
    /// to be right about a set, and getting it wrong ("some entries committed
    /// counts as success") claimed the unresolved account's follower against an
    /// id Graph had already reallocated. The global single-operation executor
    /// commits one operation's result before claiming anything else, so the
    /// FIRST refused retirement stops the drain and account B's move never
    /// leaves: `pendingRetirements` can hold at most one entry, and the
    /// set-shaped mistake has no state to occur in.
    ///
    /// What survives, and is asserted here, is the cross-account half — the part
    /// a single-account fixture cannot see. Account B is entirely healthy: its
    /// provider works, its rows are `queued`, nothing about it failed. It is held
    /// solely because THIS PROCESS is holding an uncommitted proof for account A.
    /// A gate that scoped the stop to the failing account (or resumed on the next
    /// drain without resolving the proof first) would send account B's move while
    /// account A's proven address is still uncommitted, and the retained-proof
    /// contract would be an account-local convention rather than a drain-wide
    /// one.
    ///
    /// The two accounts are independent Outlook accounts with their own servers
    /// and their own wire records, so "nothing reached the wire" is asserted per
    /// account rather than as an aggregate that one account's silence could
    /// satisfy. The recovery half asserts exactly one `/move` per message across
    /// the whole test, per server — a resolved retirement must never go back to
    /// the wire.
    @Test("Outlook: one unresolved proven retirement starts no claim pass on ANY account, and both accounts converge once writes work again")
    @MainActor
    func aReplayHoldingTwoProofsThatResolvesOnlyOneStartsNoClaimPass() async throws {
        let firstRfc = "graph-handoff-multi-a@example.com"
        let secondRfc = "graph-handoff-multi-b@example.com"
        let firstServer = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: firstRfc, providerMessageId: "graph-a", folderId: Self.source),
        ])
        defer { firstServer.close() }
        let secondServer = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: secondRfc, providerMessageId: "graph-b", folderId: Self.source),
        ])
        defer { secondServer.close() }

        let f = try fixture(accountId: "graph-handoff-multi-a")
        let secondAccountId = "graph-handoff-multi-b"
        try await f.pool.write { db in
            var account = Account(
                emailAddress: "graph-handoff-second@example.com",
                displayName: "Graph handoff second", provider: .outlook)
            account.id = secondAccountId
            try account.insert(db)
            try Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: secondAccountId
            ).insert(db)
        }
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId) }
        }

        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-a", rfc: firstRfc, destination: Self.firstDestination)
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-b", rfc: secondRfc, destination: Self.firstDestination,
            accountId: secondAccountId)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .move, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.firstDestination),
            PendingOperation(
                type: .move, messageIds: ["graph-b"],
                accountId: secondAccountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-b"],
                accountId: secondAccountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 4)
        guard ordered.count == 4 else { return }
        let firstMoveOpId = ordered[0].id
        let firstFollowerOpId = ordered[1].id
        let secondMoveOpId = ordered[2].id
        let secondFollowerOpId = ordered[3].id

        await register(firstServer.provider(), f)
        await AccountManager.shared.registerProviderForTesting(
            accountId: secondAccountId, provider: secondServer.provider())

        // DRAIN 1 — account A's move lands on its server, its retirement is
        // refused, and the drain STOPS holding that one proof. Account B is next
        // in the queue and entirely healthy; it must not move.
        let bothRefused = HeaderCommitOrdinalRefuser(allowing: 0)
        f.pool.add(transactionObserver: bothRefused, extent: .databaseLifetime)
        await AccountManager.shared.drainPendingQueue()

        #expect(bothRefused.refusals.withLock { $0 } == 3, """
            the refusal did not land on exactly one retirement's three write \
            attempts. More means a SECOND operation was executed and retired \
            while a proven result was still uncommitted, which is the whole thing \
            the stop prevents: \(bothRefused.refusals.withLock { $0 })
            """)
        let retainedAfterDrainOne = await AccountManager.shared.pendingRetirements.count
        #expect(retainedAfterDrainOne == 1, """
            this process is not holding the one proof the retention contract is \
            about: \(retainedAfterDrainOne)
            """)

        let firstAfterDrainOne = firstServer.http.servedCallSequence()
        let secondAfterDrainOne = secondServer.http.servedCallSequence()
        #expect(firstAfterDrainOne.filter { $0.hasSuffix("/move") }.count == 1,
                "account A's move was not sent exactly once: \(firstAfterDrainOne)")
        #expect(secondAfterDrainOne.isEmpty, """
            a HEALTHY account's work reached its provider while this process held \
            an uncommitted proof for a DIFFERENT account — the stop is drain-wide, \
            not account-local: \(secondAfterDrainOne)
            """)
        #expect(firstAfterDrainOne.filter { $0.hasPrefix("PATCH ") }.isEmpty,
                "a follower executed while its predecessor's proof was uncommitted")

        // DRAIN 2 — the refusal still stands, so the replay fails again. This is
        // the oracle: an unresolved proof starts NO claim pass, on either
        // account, however many drains are triggered.
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "the first drain has not settled, so the second is not this test's")
        await AccountManager.shared.drainPendingQueue()

        #expect(bothRefused.allowed.withLock { $0 } == 0, """
            a retirement committed while the refusal was still armed, so drain 2 \
            is not the unresolved-replay scenario
            """)
        let retainedAfterDrainTwo = await AccountManager.shared.pendingRetirements.count
        #expect(retainedAfterDrainTwo == 1, """
            the proof was dropped by a replay that could not commit it — the \
            provider's result now exists nowhere: \(retainedAfterDrainTwo) proof(s) held
            """)
        #expect(firstServer.http.servedCallSequence() == firstAfterDrainOne, """
            account A reached the wire again while its own proof was unresolved: \
            \(firstServer.http.servedCallSequence())
            """)
        #expect(secondServer.http.servedCallSequence().isEmpty, """
            account B was claimed on a drain that opened holding an unresolved \
            proof for account A: \(secondServer.http.servedCallSequence())
            """)

        // Every durable row is intact: the proven move is `inFlight` (owned by
        // this process's retained proof), and NOTHING else was claimed — three
        // ordinary `queued` rows, none attempted, none charged.
        let (moves, followers) = try await f.pool.read { db in
            (try PendingOperation.filter(
                [firstMoveOpId, secondMoveOpId].contains(Column("id"))).fetchAll(db),
             try PendingOperation.filter(
                [firstFollowerOpId, secondFollowerOpId].contains(Column("id"))).fetchAll(db))
        }
        #expect(moves.count == 2, """
            a move row was destroyed by a drain that retired nothing: \
            \(moves.map { "\($0.id.prefix(8))/\($0.status)" })
            """)
        guard moves.count == 2 else { return }
        let provenMove = moves.first { $0.id == firstMoveOpId }
        let untouchedMove = moves.first { $0.id == secondMoveOpId }
        #expect(provenMove?.status == PendingStatus.inFlight.rawValue, """
            the proven move left `inFlight`, where a claim pass can hand it to \
            the provider a second time: \(provenMove?.status ?? "<deleted>")
            """)
        #expect(provenMove?.messageIds.count == 1,
                "the proven move lost members: \(String(describing: provenMove?.messageIds))")
        #expect(untouchedMove?.status == PendingStatus.queued.rawValue,
                "the healthy account's move was claimed: \(untouchedMove?.status ?? "<deleted>")")
        #expect(untouchedMove?.everAttempted == false,
                "the healthy account's move was attempted behind another account's held proof")
        #expect(followers.count == 2, """
            a follower was DESTROYED by a drain that retired nothing: \
            \(followers.map { $0.id.prefix(8) })
            """)
        #expect(followers.allSatisfy { $0.status == PendingStatus.queued.rawValue },
                "a follower was claimed: \(followers.map(\.status))")
        #expect(followers.allSatisfy { $0.retryCount == 0 } && provenMove?.retryCount == 0, """
            a provider retry was charged for a LOCAL write failure: \
            \(followers.map(\.retryCount)) move=\(provenMove?.retryCount ?? -1)
            """)

        // RECOVERY — writes work again, and both accounts converge.
        f.pool.remove(transactionObserver: bothRefused)
        try await drainToQuiescence(f)

        let firstFinal = firstServer.http.servedCallSequence()
        let secondFinal = secondServer.http.servedCallSequence()
        #expect(firstFinal.filter { $0.hasSuffix("/move") }.count == 1, """
            account A's proven move was re-sent — a retirement resolved in an \
            earlier drain must never go back to the wire because a SIBLING \
            entry failed: \(firstFinal)
            """)
        #expect(secondFinal.filter { $0.hasSuffix("/move") }.count == 1,
                "account B's proven move was re-sent: \(secondFinal)")

        let firstCurrent = liveId(firstServer, rfc: firstRfc)
        let secondCurrent = liveId(secondServer, rfc: secondRfc)
        #expect(firstCurrent != nil && firstCurrent != "graph-a")
        #expect(secondCurrent != nil && secondCurrent != "graph-b")
        guard let firstCurrent, let secondCurrent else { return }

        let firstPatches = firstFinal.filter { $0.hasPrefix("PATCH ") }
        let secondPatches = secondFinal.filter { $0.hasPrefix("PATCH ") }
        #expect(firstPatches.count == 1, "account A's follower did not execute exactly once: \(firstPatches)")
        #expect(secondPatches.count == 1, "account B's follower did not execute exactly once: \(secondPatches)")
        #expect(firstPatches.allSatisfy { $0.hasSuffix("/\(firstCurrent)") }, """
            account A's PATCH went out at an address the move had already \
            invalidated (proven id \(firstCurrent)): \(firstPatches)
            """)
        #expect(secondPatches.allSatisfy { $0.hasSuffix("/\(secondCurrent)") }, """
            account B's PATCH went out at an address the move had already \
            invalidated (proven id \(secondCurrent)): \(secondPatches)
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a retained proof was never resolved")

        try expectGesturePreservedAndExecuted(
            f,
            effectVisibleOnServer:
                firstServer.snapshot(providerMessageId: firstCurrent)?.isRead == true
                && secondServer.snapshot(providerMessageId: secondCurrent)?.isRead == true,
            gesture: "both accounts' mark-reads behind a retained, unresolved retirement",
            serverState: "A: id=\(firstCurrent) folders=\(serverFolders(firstServer, rfc: firstRfc)); "
                + "B: id=\(secondCurrent) folders=\(serverFolders(secondServer, rfc: secondRfc))")

        await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
        await finish(f)
    }

    // MARK: - R1 — a claimed row whose REQUEUE the same failure refused

    /// A GRDB `TransactionObserver` that refuses the COMMIT of any transaction
    /// which UPDATEd ONE named `pendingOperation` row, after letting the first
    /// such transaction through.
    ///
    /// `databaseWillCommit()` throwing makes SQLite's commit hook abort the
    /// COMMIT, so GRDB rolls back and rethrows to `pool.write`'s caller — the
    /// shape GRDB's own suspension produces when the app is backgrounded
    /// mid-drain while WAL reads keep working (`ADR-IOS-041`), and the shape a
    /// full disk or an I/O error at COMMIT produces.
    ///
    /// 🚨 WHY IT IS SCOPED TO ONE ROW RATHER THAN ARMED BY A CLOCK. The scenario
    /// needs THREE different transactions to land differently inside a single
    /// drain — the claim commits, the predecessor's requeue is refused, the
    /// FOLLOWER's requeue commits — and there is no point between them a test can
    /// synchronise on: the predecessor never reaches the wire (its post-claim
    /// re-read throws), so `holdNextMove` cannot park it. Keying on the row the
    /// scenario is about answers all three deterministically and does not depend
    /// on how many other transactions the drain happens to run. `allowingFirst: 1`
    /// is the drain's own claim of that row, which must commit or nothing is
    /// claimed at all.
    ///
    /// File-private, exactly like `HeaderCommitRefuser`, `AllWritesRefuser` and
    /// `HeaderCommitOrdinalRefuser` above: there is no shared test utility for
    /// this and this change does not invent one.
    private final class OneRowUpdateRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let rowID: Int64
        private let sawTargetUpdate = Mutex(false)
        private let allowance: Mutex<Int>
        private let armed = Mutex(true)
        let allowed = Mutex(0)
        let refusals = Mutex(0)

        init(rowID: Int64, allowingFirst allowance: Int) {
            self.rowID = rowID
            self.allowance = Mutex(allowance)
        }

        func disarm() { armed.withLock { $0 = false } }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            guard eventKind.tableName == PendingOperation.databaseTableName else { return false }
            if case .update = eventKind { return true }
            return false
        }
        func databaseDidChange(with event: DatabaseEvent) {
            guard event.rowID == rowID else { return }
            sawTargetUpdate.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawTargetUpdate.withLock({ $0 }) else { return }
            guard armed.withLock({ $0 }) else { return }
            let permitted = allowance.withLock { left -> Bool in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            if permitted {
                allowed.withLock { $0 += 1 }
                return
            }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawTargetUpdate.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawTargetUpdate.withLock { $0 = false }
        }
    }

    /// **THE PROPERTY: every operation this process CLAIMED and did not execute
    /// becomes claimable again IN THIS SAME PROCESS — even when the failure that
    /// forced the requeue also refused the requeue write itself.**
    ///
    /// THE DEFECT, in a live process with no crash in it. The sites that return
    /// a claimed-but-unexecuted operation to `queued` used to do it best-effort
    /// (`try? await retryWrite { PendingOperation.markQueued }`) and DISCARD the
    /// write's error. When that write fails the row stays `inFlight` — a state
    /// only the claim transaction writes, and one the claim walk refuses — so no
    /// later drain in this process can pick it up. At the next launch
    /// `AppDatabase.recoverPreviousSessionResidue` deletes an `everAttempted`
    /// `.move`: a user gesture, lost with no crash at all. The producer is a
    /// database-wide refusal that swallows the recovery write as well as the one
    /// that provoked it (`ADR-IOS-041`).
    ///
    /// THE SCHEDULE, and why every element of it is load-bearing. A mark-flagged
    /// BYSTANDER first: it succeeds on the wire, which is what proves the
    /// executor was live at all — without it the drain could stop for a reason
    /// unrelated to anything under test and every assertion below would be
    /// vacuous. Then the `.move`, which the server refuses ONCE with a `503`: the
    /// transient arm first tries to move that operation's related chain to the
    /// tail, and the commit observer scoped to the move's row refuses both that
    /// write and the requeue it falls back to, leaving the row `inFlight` and
    /// owned by this process. Then a mark-read FOLLOWER on the same message,
    /// which must not run while the predecessor is unresolved.
    ///
    /// 🚨 WHAT THIS USED TO DRIVE. The predecessor re-read the claimed row from
    /// the database between the claim and the provider call, and this test armed
    /// a one-shot fault on that read. The global single-operation executor has no
    /// such window — the row it claims is the row it read inside the claim
    /// transaction — so the seam is gone from the drain and the state is now
    /// produced by the failure that actually reaches it in production. The
    /// property, and every oracle below, is unchanged.
    ///
    /// THE ORACLES ARE THE WIRE AND THE DURABLE QUEUE, never membership of any
    /// in-memory recovery structure, which is a mechanism and not the property
    /// (`MIS-015`). Three, and they fail in different directions:
    ///   (i)   while the refusal stands, nothing runs BEHIND the unresolved
    ///         operation — the follower is still owed rather than executed;
    ///   (ii)  a further drain under the same refusal sends NO new provider work
    ///         and charges no retry, because the charge rolled back with the
    ///         write that carried it;
    ///   (iii) once writes recover, the move lands and its follower executes
    ///         EXACTLY ONCE after it, in issue order, and the newest intended
    ///         server state wins.
    @Test("Outlook: a claimed operation whose requeue the same failure refused is still claimable in this process")
    @MainActor
    func aRefusedRequeueAfterAFailedReReadStaysClaimableInThisProcess() async throws {
        let rfc = "graph-handoff-refused-requeue@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-refused-requeue")
        try seedOptimisticallyMovedHeader(
            f, graphId: "graph-1", rfc: rfc, destination: Self.firstDestination,
            isRead: true, isFlagged: true)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .markFlagged, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source),
            PendingOperation(
                type: .move, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source,
                destinationPath: Self.firstDestination),
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.firstDestination),
        ])
        #expect(ordered.count == 3)
        guard ordered.count == 3 else { return }
        let moveOpId = ordered[1].id
        let followerOpId = ordered[2].id

        await register(server.provider(), f)

        let moveRowID = try await f.pool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT rowid FROM pendingOperation WHERE id = ?", arguments: [moveOpId])
        }
        #expect(moveRowID != nil, "the move row was not seeded, so nothing can be scoped to it")
        guard let moveRowID else { return }

        let refuser = OneRowUpdateRefuser(rowID: moveRowID, allowingFirst: 1)
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        // The move is refused ONCE, transiently, which is the arm that defers the
        // chain and — when that write cannot commit — requeues the claimed row.
        server.failMoveOnce(providerMessageId: "graph-1")

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY, two ways. The claim of the move must have committed (or
        // nothing was claimed at all), and the six refusals are the `retryWrite`
        // attempts of the tail movement and of the requeue it falls back to —
        // fewer means neither was attempted under the refusal, more means some
        // other transaction was caught in it (`MIS-027`).
        #expect(refuser.allowed.withLock { $0 } == 1, """
            the move's claim did not commit exactly once: \
            \(refuser.allowed.withLock { $0 })
            """)
        #expect(refuser.refusals.withLock { $0 } == 6, """
            the refusal did not land on the move's tail movement and its requeue \
            for exactly three attempts each: \(refuser.refusals.withLock { $0 })
            """)

        let firstDrain = server.http.servedCallSequence()

        // NON-VACUITY, the other side: the bystander really did execute, so the
        // executor was live and the silence measured below is a decision rather
        // than an absence.
        #expect(server.snapshot(providerMessageId: "graph-1")?.isFlagged == true, """
            the bystander did not execute, so this drain proves nothing about \
            what came after it: \(firstDrain)
            """)

        // 🚨 ORACLE (i). The move was attempted exactly once and refused, and
        // NOTHING may go out behind it while this process still owns it. A second
        // PATCH here is the follower claimed ALONE, running ahead of a
        // predecessor whose fate this process has not settled.
        #expect(firstDrain.filter { $0.hasSuffix("/move") }.count == 1, """
            the move was not attempted exactly once: \(firstDrain)
            """)
        #expect(serverFolders(server, rfc: rfc) == [Self.source], """
            the refused move was applied by the server, so the row this process \
            still owns is not the unexecuted one this test is about: \
            \(serverFolders(server, rfc: rfc))
            """)
        #expect(firstDrain.filter { $0.hasPrefix("PATCH ") }.count == 1, """
            a claim started while this process still owned a claimed row it \
            could not return to `queued`, so the follower ran ahead of the \
            unresolved move: \(firstDrain)
            """)

        // Durable state, read after the drain returned — never mid-drain.
        let (heldMove, heldFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(heldMove?.status == PendingStatus.inFlight.rawValue, """
            the move's requeue survived a refusal aimed at exactly it, so this \
            test cannot see the state the defect lives in: \
            \(heldMove?.status ?? "<deleted>")
            """)
        #expect(heldFollower != nil, """
            the follower was DESTROYED while its predecessor was still unresolved \
            — the user's newest gesture is gone
            """)
        #expect(heldFollower?.status == PendingStatus.queued.rawValue, """
            the follower was claimed behind an operation this process still owns: \
            \(heldFollower?.status ?? "<deleted>")
            """)
        #expect(heldFollower?.everAttempted == false,
                "the follower carries the attempted-row proof, so it reached a claim it should not have")
        #expect(heldMove?.retryCount == 0 && heldFollower?.retryCount == 0, """
            a provider retry was charged for a LOCAL write failure: \
            move=\(heldMove?.retryCount ?? -1) follower=\(heldFollower?.retryCount ?? -1)
            """)

        // 🚨 ORACLE (ii). A further drain while the refusal still stands must send
        // no new provider work and charge nobody. Recovery is local, so it is
        // attempted; it fails; nothing else may proceed on the strength of that.
        await AccountManager.shared.drainPendingQueue()

        #expect(server.http.servedCallSequence() == firstDrain, """
            a drain taken while the requeue was still refused sent new provider \
            work: \(server.http.servedCallSequence())
            """)
        let (retriedMove, retriedFollower) = try await f.pool.read { db in
            (try PendingOperation.fetchOne(db, key: moveOpId),
             try PendingOperation.fetchOne(db, key: followerOpId))
        }
        #expect(retriedMove?.retryCount == 0 && retriedFollower?.retryCount == 0, """
            a retry was charged by a drain that made no provider attempt at all: \
            move=\(retriedMove?.retryCount ?? -1) follower=\(retriedFollower?.retryCount ?? -1)
            """)
        #expect(retriedMove?.messageIds == ["graph-1"], """
            the move row lost or changed members while nothing had executed: \
            \(String(describing: retriedMove?.messageIds))
            """)

        // The database accepts writes again — the state every live process reaches
        // when it returns to the foreground.
        refuser.disarm()
        try await drainToQuiescence(f)

        // 🚨 ORACLE (iii). Both gestures execute exactly once, in issue order, and
        // the newest intended state is what the server ends up holding.
        let finalCalls = server.http.servedCallSequence()
        // TWO `/move` requests: the one the server refused with a 503, and the
        // one that landed after the requeue recovered. The refused attempt is why
        // the count is not one, and the server-state assertion further down is
        // what says the move was APPLIED exactly once.
        #expect(finalCalls.filter { $0.hasSuffix("/move") }.count == 2, """
            the move did not run exactly once after the requeue recovered — the \
            first `/move` is the 503 this schedule began with: \(finalCalls)
            """)
        let moveIndex = finalCalls.lastIndex { $0.hasSuffix("/move") }
        #expect(moveIndex != nil, "the move never executed at all: \(finalCalls)")
        guard let moveIndex else { return }
        let current = liveId(server, rfc: rfc)
        #expect(current != nil && current != "graph-1",
                "Graph did not reallocate the id, so issue order cannot be read off the addresses")
        guard let current else { return }
        let followerPatches = finalCalls.dropFirst(moveIndex + 1).filter { $0.hasPrefix("PATCH ") }
        #expect(followerPatches.count == 1, """
            the follower did not execute exactly once after its predecessor: \
            \(finalCalls)
            """)
        #expect(followerPatches.allSatisfy { $0.hasSuffix("/\(current)") }, """
            a PATCH went out at an address the move had already invalidated \
            (proven id \(current)): \(Array(followerPatches))
            """)

        let headers = try rows(f)
        #expect(headers.count == 1)
        guard headers.count == 1 else { return }
        #expect(headers[0].messageId == current && headers[0].folderPath == Self.firstDestination, """
            the header was left at the address Graph invalidated: \
            messageId=\(headers[0].messageId) folder=\(headers[0].folderPath)
            """)
        #expect(serverFolders(server, rfc: rfc) == [Self.firstDestination], """
            the move the user asked for is not reflected on the server: \
            \(serverFolders(server, rfc: rfc))
            """)
        let landed = server.snapshot(providerMessageId: current)
        #expect(landed?.isFlagged == true, "the bystander's flag was lost: \(String(describing: landed))")

        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: landed?.isRead == true,
            gesture: "the mark-read stranded behind a requeue the same failure refused",
            serverState: "id=\(current) folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    /// **THE PROPERTY: a requeue the operation had EARNED a retry charge for
    /// still charges exactly that one retry when this process recovers the
    /// ownership on a later drain — exactly one, not two, not zero.**
    ///
    /// Equivalently, and this is the thing under test: the ownership
    /// `pendingRequeues` retains carries the retry DISPOSITION of the requeue it
    /// stands in for, not a default.
    ///
    /// WHY THIS IS A SEPARATE CASE FROM ITS SIBLING ABOVE. That test drives the
    /// same recovery for a requeue whose site charges NOTHING, and asserts the
    /// false side as an oracle (*"a provider retry was charged for a LOCAL write
    /// failure"*). The other kind is the transient provider-error arm, which
    /// defers with `incrementRetryCount: true` because the PROVIDER was attempted
    /// and refused, and that charge is what keeps the runaway-retry case visible
    /// at all — the arm's own comment records `retryCount` having "stayed at 0
    /// forever" on an op that was hours old. With only the false side pinned, the
    /// retained disposition is entirely unwitnessed: a recovery that ignored the
    /// stored value and always passed `false`, or one that dropped the value and
    /// made the map a set of ids, forgives every provider retry a refused requeue
    /// had earned — and stays green.
    ///
    /// THE SCHEDULE. One `.markRead`, and a `503` on its PATCH: the provider is
    /// attempted and refuses, which is the transient-error arm and the site that
    /// charges. That arm first tries to move the operation's related chain to the
    /// TAIL — the write that carries the charge — and, when that write is
    /// refused, hands the still-claimed row to the ordinary requeue, which is
    /// refused in the same breath. Both refusals come from a commit observer
    /// scoped to exactly that row: the database-wide refusal shape `ADR-IOS-041`
    /// produces. The charge rolls back with the write that carried it and this
    /// process is left owning an `inFlight` row.
    ///
    /// THE SECOND PROVIDER ATTEMPT HAS TO BE NEUTRALISED, or "exactly one" cannot
    /// be read off the row at all: the moment the recovery returns the row to
    /// `queued` the same drain claims it again, and a second `503` would charge a
    /// second, entirely legitimate retry. The provider is therefore UNREGISTERED
    /// for the recovery drain. `recoverPendingRequeues` runs before the claim
    /// walk and does not consult the registry — it is local work, deliberately
    /// not gated on connectivity or on a provider existing — so the recovery
    /// still commits, while the claim walk then declines to claim an account with
    /// no provider and charges nothing. What the row carries when that drain
    /// returns is exactly what the recovery charged and nothing else, and the row
    /// having left `inFlight` is the proof the recovery's write committed.
    ///
    /// THE ORACLES ARE THE DURABLE ROW, READ AFTER EACH DRAIN RETURNED, AND THE
    /// APPEND-ONLY WIRE RECORD — never membership of `pendingRequeues`, which is
    /// the mechanism and not the property (`MIS-015`). Four, and they fail in
    /// different directions:
    ///   (i)   the provider really was attempted and really did refuse, so the
    ///         charge was EARNED — and it is NOT on the row while the requeue
    ///         stands refused, because the increment rolled back with it;
    ///   (ii)  a drain taken while the refusal still stands charges nothing and
    ///         sends no new provider work — a recovery may not charge what it
    ///         cannot commit;
    ///   (iii) the drain in which the recovery COMMITS leaves `retryCount == 1`;
    ///   (iv)  the intention was never in danger: it still executes exactly once
    ///         and the server converges.
    @Test("Outlook: a requeue the same failure refused still charges exactly the one retry the provider refusal earned")
    @MainActor
    func aRecoveredRequeueChargesTheOneRetryTheProviderRefusalEarned() async throws {
        let rfc = "graph-handoff-recovered-charge@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-recovered-charge")
        try seedHeader(f, graphId: "graph-1", rfc: rfc)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingRequeues.isEmpty,
                "a previous test left a retained requeue on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .markRead, messageIds: ["graph-1"],
                accountId: f.accountId, folderPath: Self.source),
        ])
        #expect(ordered.count == 1)
        guard ordered.count == 1 else { return }
        let opId = ordered[0].id

        await register(server.provider(), f)

        let opRowID = try await f.pool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT rowid FROM pendingOperation WHERE id = ?", arguments: [opId])
        }
        #expect(opRowID != nil, "the operation row was not seeded, so nothing can be scoped to it")
        guard let opRowID else { return }

        let refuser = OneRowUpdateRefuser(rowID: opRowID, allowingFirst: 1)
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        // THE PROVIDER IS ATTEMPTED AND REFUSES. A 503 on the PATCH is a
        // connection/transient error, which is the arm that requeues with
        // `incrementRetryCount: true` — the charge this test follows.
        server.failNextPatch()

        await AccountManager.shared.drainPendingQueue()

        let firstDrain = server.http.servedCallSequence()

        // 🚨 ORACLE (i), and the non-vacuity that makes the charge EARNED rather
        // than assumed: the operation reached the provider, exactly once and at
        // its own address, and the provider refused it. A test that never got a
        // provider attempt has nothing to be charged for and cannot fail here.
        let firstPatches = firstDrain.filter { $0.hasPrefix("PATCH ") }
        #expect(firstPatches.count == 1 && firstPatches.allSatisfy { $0.hasSuffix("/graph-1") }, """
            the operation did not reach the provider exactly once at its own \
            address, so no retry charge was ever EARNED: \(firstDrain)
            """)
        #expect(server.snapshot(providerMessageId: "graph-1")?.isRead == false, """
            the PATCH was applied rather than refused, so this drain did not take \
            the transient-error arm and nothing charged a retry: \
            \(String(describing: server.snapshot(providerMessageId: "graph-1")))
            """)

        // NON-VACUITY, the other side: the refusal landed on the two writes the
        // transient arm makes and on nothing else — one permitted commit, the
        // drain's own claim, without which nothing was claimed at all, then three
        // `retryWrite` attempts at moving the chain to the tail and three more at
        // the requeue that failure falls back to (`MIS-027`).
        #expect(refuser.allowed.withLock { $0 } == 1, """
            the operation's claim did not commit exactly once: \
            \(refuser.allowed.withLock { $0 })
            """)
        #expect(refuser.refusals.withLock { $0 } == 6, """
            the refusal did not land on the tail movement and the requeue that \
            follows it for exactly three attempts each: \
            \(refuser.refusals.withLock { $0 })
            """)

        // Durable state, read after the drain RETURNED. This process owns the row,
        // and the charge the transient arm asked for is not on it — the increment
        // rolled back with the requeue that carried it.
        let held = try await f.pool.read { db in try PendingOperation.fetchOne(db, key: opId) }
        #expect(held?.status == PendingStatus.inFlight.rawValue, """
            the requeue survived a refusal aimed at exactly it, so this test \
            cannot reach the recovery whose charge it measures: \
            \(held?.status ?? "<deleted>")
            """)
        #expect(held?.retryCount == 0, """
            a retry was charged by a write that never committed: \
            \(held?.retryCount ?? -1)
            """)

        // 🚨 ORACLE (ii). A drain taken while the refusal still stands recovers
        // nothing, so it may charge nothing and send no new provider work.
        await AccountManager.shared.drainPendingQueue()

        #expect(server.http.servedCallSequence() == firstDrain, """
            a drain taken while the requeue was still refused sent new provider \
            work: \(server.http.servedCallSequence())
            """)
        #expect(refuser.refusals.withLock { $0 } == 9, """
            the recovery did not attempt the guarded requeue for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        let stillHeld = try await f.pool.read { db in
            try PendingOperation.fetchOne(db, key: opId)
        }
        #expect(stillHeld?.status == PendingStatus.inFlight.rawValue, """
            the row left this process's ownership without a write that committed: \
            \(stillHeld?.status ?? "<deleted>")
            """)
        #expect(stillHeld?.retryCount == 0, """
            a recovery that could not commit charged a retry anyway: \
            \(stillHeld?.retryCount ?? -1)
            """)

        // The database accepts writes again — the state every live process reaches
        // when it returns to the foreground. Unregistering the provider
        // neutralises the SECOND provider attempt this recovery would otherwise
        // release, WITHOUT touching the recovery itself: `recoverPendingRequeues`
        // runs above the claim walk and does not consult the provider registry.
        refuser.disarm()
        await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId)

        await AccountManager.shared.drainPendingQueue()

        // NON-VACUITY for the drain the charge is read off: the wire record is
        // unchanged, so nothing went out behind the recovery that could have
        // charged a retry of its own, and the status assertion below is what
        // proves the recovery's write actually COMMITTED.
        #expect(server.http.servedCallSequence() == firstDrain, """
            the neutralised second attempt reached the provider, so a further \
            provider refusal could have charged the retry this test attributes to \
            the recovery: \(server.http.servedCallSequence())
            """)

        // 🚨 ORACLE (iii) — THE ONE THIS TEST EXISTS FOR.
        let recovered = try await f.pool.read { db in
            try PendingOperation.fetchOne(db, key: opId)
        }
        #expect(recovered?.status == PendingStatus.queued.rawValue, """
            the operation is not claimable again after the recovery committed: \
            \(recovered?.status ?? "<deleted>")
            """)
        #expect(recovered?.retryCount == 1, """
            the recovery charged \(recovered?.retryCount ?? -1) retries, not the \
            ONE the provider's refusal had already earned. A recovery that passes \
            a default instead of the disposition the requeue retained silently \
            forgives every charge a refused requeue earned, which is exactly the \
            masking the charge was added to end.
            """)

        // 🚨 ORACLE (iv). The intention was never in danger: it still executes,
        // exactly once, and the server converges.
        await register(server.provider(), f)
        try await drainToQuiescence(f)

        let finalCalls = server.http.servedCallSequence()
        #expect(finalCalls.filter { $0.hasPrefix("PATCH ") }.count == 2, """
            the mark-read did not execute exactly once after its refused requeue \
            recovered — the first PATCH is the 503 this schedule began with: \
            \(finalCalls)
            """)
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: "graph-1")?.isRead == true,
            gesture: "the mark-read whose earned retry charge the same failure refused",
            serverState: "id=graph-1 folders=\(serverFolders(server, rfc: rfc))")

        await finish(f)
    }

    // MARK: - TC-1 (round 8) — MORE THAN ONE retained REQUEUE in the same recovery

    /// A `PendingOperation` commit refuser that ALLOWS the first `allowance`
    /// commits which UPDATEd any of the WATCHED rows, and refuses every one after
    /// that.
    ///
    /// 🚨 THE SELECTOR IS THE TRANSACTION ORDINAL, NEVER THE OP ID OR THE
    /// ACCOUNT. `recoverPendingRequeues` iterates `AccountManager.pendingRequeues`,
    /// a `[String: Bool]`, and Swift dictionary order is seed-dependent and varies
    /// run to run — so a refuser keyed on "the second account's operation" would
    /// refuse the FIRST recovered entry on some runs and the second on others, and
    /// the mutation this test exists to catch would survive on half the seeds.
    /// Counting commits instead names exactly what the scenario needs ("one
    /// recovery lands, the next does not") without depending on which entry that
    /// turns out to be, and every assertion below is written so either assignment
    /// satisfies it.
    ///
    /// The same shape as `HeaderCommitOrdinalRefuser` above, scoped to
    /// `PendingOperation` UPDATEs on named rowids rather than to header writes,
    /// because the write this scenario must split is `requeueIfInFlight`. It is
    /// deliberately NOT a generalisation of that type: file-private and
    /// single-purpose, exactly like `HeaderCommitRefuser`, `AllWritesRefuser`,
    /// `HeaderCommitOrdinalRefuser` and `OneRowUpdateRefuser`.
    ///
    /// 🚨 WHAT IT MUST NOT WATCH IS AS LOAD-BEARING AS WHAT IT WATCHES. Only the
    /// two PREDECESSOR rows are named. A refused claim TRANSACTION ends the drain
    /// (`claimFrontierOperation`'s `catch { queueLog(…); return .stop }`), so if
    /// the followers were watched too, a drain that wrongly started a claim would
    /// produce no wire traffic at all and the wire oracle below would pass on
    /// broken code — the refusal, not the invariant, would be what silenced the
    /// wire.
    private final class PendingOperationCommitOrdinalRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let rowIDs: Set<Int64>
        private let sawWatchedUpdate = Mutex(false)
        private let remaining: Mutex<Int>
        let allowed = Mutex(0)
        let refusals = Mutex(0)

        init(rowIDs: Set<Int64>, allowing allowance: Int) {
            self.rowIDs = rowIDs
            self.remaining = Mutex(allowance)
        }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            guard eventKind.tableName == PendingOperation.databaseTableName else { return false }
            if case .update = eventKind { return true }
            return false
        }
        func databaseDidChange(with event: DatabaseEvent) {
            guard rowIDs.contains(event.rowID) else { return }
            sawWatchedUpdate.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawWatchedUpdate.withLock({ $0 }) else { return }
            let permitted = remaining.withLock { left -> Bool in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            if permitted {
                allowed.withLock { $0 += 1 }
                return
            }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawWatchedUpdate.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawWatchedUpdate.withLock { $0 = false }
        }
    }

    /// **THE PROPERTY: when this process is holding MORE THAN ONE unresolved
    /// requeue, a drain that resolves only some of them starts no claim pass —
    /// neither account reaches the wire, the unresolved row keeps its whole
    /// durable state, and a later healthy drain executes every account's
    /// operations exactly once, in issue order, so the user's LATEST intention is
    /// the one left on the server.**
    ///
    /// Every other requeue-recovery witness on this branch retains exactly ONE
    /// id, so all of them pass against a `recoverPendingRequeues` that reports
    /// success the moment its first entry commits. Two accounts separate those:
    /// the drain-wide gate is `false` if ANY retained ownership is still
    /// unresolved, not "the last one I looked at".
    ///
    /// 🚨 TWO SIMULTANEOUS RETAINED REQUEUES ARE NOW UNREACHABLE, AND THAT IS
    /// THE IMPROVEMENT. The predecessor dispatched accounts concurrently, so one
    /// drain could leave BOTH accounts owning a claimed-but-unexecuted row whose
    /// requeue commit was refused, and the recovery had to be right about a SET —
    /// reporting success after resolving only one of them let the other account's
    /// NEWER follower execute ALONE, ahead of a predecessor this process had not
    /// resolved, so a later drain executed the OLDER intention LAST and overwrote
    /// the user's latest one. The global single-operation executor stops on the
    /// FIRST refused requeue, so `pendingRequeues` can hold at most one entry and
    /// the set-shaped mistake has no state to occur in.
    ///
    /// THE HARM THAT REMAINS REACHABLE, and what this test now pins, is the
    /// CROSS-ACCOUNT half — the part a single-account fixture cannot see. Account
    /// B is entirely healthy: its provider works, its rows are `queued`, nothing
    /// about it failed. It is held solely because THIS PROCESS owns an unresolved
    /// claimed row on account A. A recovery gate scoped to the failing account,
    /// or one that let a drain proceed while an entry was still unresolved, would
    /// admit account B's operations while account A's `inFlight` row is invisible
    /// to the claim walk — and the ordering guarantee would be an account-local
    /// convention rather than a drain-wide one.
    ///
    /// THE SCHEDULE, and why every element of it is load-bearing.
    ///   - **Two independent Outlook accounts in one pool, one lane each**, with
    ///     their own servers and their own append-only wire records, so "nothing
    ///     reached the wire" is asserted PER ACCOUNT rather than as an aggregate
    ///     one account's silence could satisfy.
    ///   - **No `.move` anywhere.** This scenario is about the requeue map alone;
    ///     the retirement machinery must not be involved, and
    ///     `pendingRetirements` is asserted empty at every boundary.
    ///   - **Both retained entries are produced by REAL requeue failures.** A
    ///     `503` on the predecessor's PATCH takes the transient-provider-error
    ///     arm, which requeues with `incrementRetryCount: true`; a row-scoped
    ///     `OneRowUpdateRefuser` per predecessor (the one permitted commit is that
    ///     row's own claim, without which nothing was claimed at all) refuses that
    ///     requeue, so the process retains the ownership. Nothing writes `status`
    ///     by hand and no recovery entry point is called directly.
    ///   - **`.markUnread` then `.markRead` on a message seeded UNREAD.** Both
    ///     write the SAME observable field with DIFFERENT values, and the correct
    ///     final value differs from the seeded one: correct order ends READ, an
    ///     inversion ends unread, and nothing-ran also ends unread — which is why
    ///     the per-account wire counts are asserted alongside it.
    ///
    /// THE ORACLES ARE THE APPEND-ONLY WIRE RECORD (per account) AND THE DURABLE
    /// ROWS READ AFTER A DRAIN RETURNED — never mid-drain row state, and never
    /// membership of `pendingRequeues` as the property under test, which is the
    /// mechanism and not the invariant (`MIS-015`). Reading its count as a SETUP
    /// anchor is a different thing and is done below, because a fixture that does
    /// not actually retain an entry makes every later assertion vacuous
    /// (`MIS-030`).
    @Test("Outlook: one unresolved retained requeue starts no claim pass on ANY account, and both accounts converge later")
    @MainActor
    func aRecoveryHoldingTwoRetainedRequeuesThatResolvesOnlyOneStartsNoClaimPass() async throws {
        let firstRfc = "graph-handoff-multi-requeue-a@example.com"
        let secondRfc = "graph-handoff-multi-requeue-b@example.com"
        let firstServer = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: firstRfc, providerMessageId: "graph-a", folderId: Self.source),
        ])
        defer { firstServer.close() }
        let secondServer = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: secondRfc, providerMessageId: "graph-b", folderId: Self.source),
        ])
        defer { secondServer.close() }

        let f = try fixture(accountId: "graph-handoff-multi-requeue-a")
        let secondAccountId = "graph-handoff-multi-requeue-b"
        try await f.pool.write { db in
            var account = Account(
                emailAddress: "graph-handoff-second@example.com",
                displayName: "Graph handoff second", provider: .outlook)
            account.id = secondAccountId
            try account.insert(db)
            try Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: secondAccountId
            ).insert(db)
        }
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId) }
        }

        try seedHeader(f, graphId: "graph-a", rfc: firstRfc)
        try seedHeader(f, graphId: "graph-b", rfc: secondRfc, accountId: secondAccountId)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")
        #expect(await AccountManager.shared.pendingRequeues.isEmpty,
                "a previous test left a retained requeue on the shared AccountManager")
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "a drain from an earlier test is still running, so this schedule is not this test's")

        let ordered = try seedSchedule(f, [
            PendingOperation(
                type: .markUnread, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.source),
            PendingOperation(
                type: .markRead, messageIds: ["graph-a"],
                accountId: f.accountId, folderPath: Self.source),
            PendingOperation(
                type: .markUnread, messageIds: ["graph-b"],
                accountId: secondAccountId, folderPath: Self.source),
            PendingOperation(
                type: .markRead, messageIds: ["graph-b"],
                accountId: secondAccountId, folderPath: Self.source),
        ])
        #expect(ordered.count == 4)
        guard ordered.count == 4 else { return }
        let firstPredecessorOpId = ordered[0].id
        let firstFollowerOpId = ordered[1].id
        let secondPredecessorOpId = ordered[2].id
        let secondFollowerOpId = ordered[3].id
        let predecessorOpIds = [firstPredecessorOpId, secondPredecessorOpId]
        let followerOpIds = [firstFollowerOpId, secondFollowerOpId]

        await register(firstServer.provider(), f)
        await AccountManager.shared.registerProviderForTesting(
            accountId: secondAccountId, provider: secondServer.provider())

        let predecessorRowIDs = try await f.pool.read { db in
            try predecessorOpIds.compactMap { opId in
                try Int64.fetchOne(
                    db, sql: "SELECT rowid FROM pendingOperation WHERE id = ?", arguments: [opId])
            }
        }
        #expect(predecessorRowIDs.count == 2,
                "a predecessor row was not seeded, so nothing can be scoped to it")
        guard predecessorRowIDs.count == 2 else { return }

        // DRAIN 1 — account A's predecessor is claimed, reaches its provider, is
        // refused with a 503, and both the tail movement that refusal asks for and
        // the requeue it falls back to are themselves refused. The drain stops
        // there, owning ONE unresolved requeue; account B is next in the queue and
        // entirely healthy, and must not move.
        let firstRefuser = OneRowUpdateRefuser(rowID: predecessorRowIDs[0], allowingFirst: 1)
        let secondRefuser = OneRowUpdateRefuser(rowID: predecessorRowIDs[1], allowingFirst: 1)
        f.pool.add(transactionObserver: firstRefuser, extent: .databaseLifetime)
        f.pool.add(transactionObserver: secondRefuser, extent: .databaseLifetime)

        firstServer.failNextPatch()
        secondServer.failNextPatch()

        await AccountManager.shared.drainPendingQueue()

        let firstAfterDrainOne = firstServer.http.servedCallSequence()
        let secondAfterDrainOne = secondServer.http.servedCallSequence()

        // NON-VACUITY, the provider side: account A's predecessor really was
        // attempted, exactly once and at its own address, and nothing followed it
        // — so it really did take the arm that requeues with a retry charge.
        #expect(firstAfterDrainOne.filter { $0.hasPrefix("PATCH ") }.count == 1, """
            account A's predecessor did not reach the provider exactly once, so \
            no requeue was ever asked for: \(firstAfterDrainOne)
            """)
        #expect(firstServer.snapshot(providerMessageId: "graph-a")?.isRead == false, """
            account A's follower executed while its predecessor was unresolved: \
            \(firstAfterDrainOne)
            """)
        // 🚨 THE CROSS-ACCOUNT ORACLE. Account B is healthy in every way and is
        // held ONLY because this process owns an unresolved claimed row on
        // account A.
        #expect(secondAfterDrainOne.isEmpty, """
            a HEALTHY account's work reached its provider while this process owned \
            a claimed, unrequeued row on a DIFFERENT account — the stop is \
            drain-wide, not account-local: \(secondAfterDrainOne)
            """)

        // NON-VACUITY, the write side: one permitted commit — the drain's own
        // claim, without which nothing was claimed at all — then three
        // `retryWrite` attempts at the chain's tail movement and three more at the
        // requeue that failure falls back to. Fewer means neither was attempted
        // under the refusal; more means some other transaction was caught in it
        // (`MIS-027`). Account B's refuser must be untouched: its row was never
        // claimed.
        #expect(firstRefuser.allowed.withLock { $0 } == 1, """
            account A's predecessor was not claimed exactly once: \
            \(firstRefuser.allowed.withLock { $0 })
            """)
        #expect(secondRefuser.allowed.withLock { $0 } == 0, """
            account B's predecessor was CLAIMED behind another account's \
            unresolved row: \(secondRefuser.allowed.withLock { $0 })
            """)
        #expect(firstRefuser.refusals.withLock { $0 } == 6, """
            the refusal did not land on account A's tail movement and the requeue \
            that follows it for exactly three attempts each: \
            \(firstRefuser.refusals.withLock { $0 })
            """)
        #expect(secondRefuser.refusals.withLock { $0 } == 0, """
            a write landed on account B's row though nothing on that account was \
            claimed: \(secondRefuser.refusals.withLock { $0 })
            """)

        // THE PRECONDITION, ANCHORED (`MIS-030`). Without a retained entry there
        // is no recovery under test and every assertion below is vacuous.
        let retainedAfterDrainOne = await AccountManager.shared.pendingRequeues.count
        #expect(retainedAfterDrainOne == 1, """
            this process is not holding the unresolved requeue the recovery under \
            test is about: \(retainedAfterDrainOne)
            """)
        #expect(await AccountManager.shared.pendingRetirements.isEmpty, """
            a retirement was retained, so this scenario is not the requeue-only \
            one it claims to be
            """)

        // The durable shape the recovery will act on, read after the drain
        // RETURNED: account A's predecessor claimed-and-unexecuted, everything
        // else ordinary queued work that was never touched.
        let (predecessorsAfterOne, followersAfterOne) = try await f.pool.read { db in
            (try PendingOperation.filter(predecessorOpIds.contains(Column("id"))).fetchAll(db),
             try PendingOperation.filter(followerOpIds.contains(Column("id"))).fetchAll(db))
        }
        #expect(predecessorsAfterOne.count == 2, """
            a predecessor row was destroyed: \(predecessorsAfterOne.map { $0.id.prefix(8) })
            """)
        #expect(predecessorsAfterOne.first { $0.id == firstPredecessorOpId }.map {
                    $0.status == PendingStatus.inFlight.rawValue && $0.everAttempted
                } == true, """
            account A's predecessor must be claimed-and-unexecuted for the \
            recovery to have anything to resolve: \
            \(predecessorsAfterOne.map { "\($0.status)/everAttempted=\($0.everAttempted)" })
            """)
        #expect(predecessorsAfterOne.first { $0.id == secondPredecessorOpId }.map {
                    $0.status == PendingStatus.queued.rawValue && !$0.everAttempted
                } == true, """
            account B's predecessor was claimed behind another account's \
            unresolved row
            """)
        #expect(followersAfterOne.count == 2
                    && followersAfterOne.allSatisfy {
                        $0.status == PendingStatus.queued.rawValue && !$0.everAttempted
                    }, """
            a follower was claimed while a predecessor was unresolved: \
            \(followersAfterOne.map(\.status))
            """)

        // DRAIN 2 — the refusal still stands, so the recovery fails again. This is
        // the oracle: an unresolved retained requeue starts NO claim pass, on
        // EITHER account, however many drains are triggered. A new call here is a
        // follower admitted ALONE, ahead of a predecessor this process has not
        // resolved, against the intention the user issued LAST.
        #expect(await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
                "the first drain has not settled, so the second is not this test's")
        await AccountManager.shared.drainPendingQueue()

        #expect(firstRefuser.allowed.withLock { $0 } == 1, """
            a recovery write committed while the refusal was still armed, so drain \
            2 is not the unresolved-recovery scenario
            """)
        #expect(firstServer.http.servedCallSequence() == firstAfterDrainOne, """
            account A reached the wire after a recovery that left its retained \
            requeue unresolved: \(firstServer.http.servedCallSequence())
            """)
        #expect(secondServer.http.servedCallSequence().isEmpty, """
            account B was claimed on a drain that opened holding an unresolved \
            requeue for account A: \(secondServer.http.servedCallSequence())
            """)
        #expect(await AccountManager.shared.pendingRequeues.count == 1, """
            the ownership was dropped by a recovery that could not commit it — the \
            claimed row is now invisible to every future claim
            """)

        // The intermediate durable state, read after the drain RETURNED.
        let (predecessorsAfterTwo, followersAfterTwo) = try await f.pool.read { db in
            (try PendingOperation.filter(predecessorOpIds.contains(Column("id"))).fetchAll(db),
             try PendingOperation.filter(followerOpIds.contains(Column("id"))).fetchAll(db))
        }
        #expect(predecessorsAfterTwo.count == 2, """
            a predecessor row was DESTROYED by a drain that resolved nothing: \
            \(predecessorsAfterTwo.map { $0.id.prefix(8) })
            """)
        let heldPredecessors = predecessorsAfterTwo.filter {
            $0.status == PendingStatus.inFlight.rawValue
        }
        let untouchedPredecessors = predecessorsAfterTwo.filter {
            $0.status == PendingStatus.queued.rawValue
        }
        #expect(heldPredecessors.count == 1 && untouchedPredecessors.count == 1, """
            exactly one predecessor should be kept by this process and exactly one \
            left as ordinary queued work: \
            \(predecessorsAfterTwo.map { "\($0.id.prefix(8))/\($0.status)" })
            """)
        guard heldPredecessors.count == 1, untouchedPredecessors.count == 1 else { return }
        #expect(heldPredecessors[0].messageIds.count == 1, """
            the unresolved predecessor lost members: \(heldPredecessors[0].messageIds)
            """)
        #expect(followersAfterTwo.count == 2, """
            a follower was DESTROYED by a drain that resolved nothing: \
            \(followersAfterTwo.map { $0.id.prefix(8) })
            """)
        #expect(followersAfterTwo.allSatisfy { $0.status == PendingStatus.queued.rawValue }, """
            a follower left `queued` though nothing behind an unresolved \
            predecessor may run: \(followersAfterTwo.map(\.status))
            """)

        // Retry accounting. The unrecovered ownership carries none, because its
        // charge rolled back with the write that carried it, and no follower is
        // charged for a failure that was not its own.
        #expect(heldPredecessors[0].retryCount == 0, """
            a retry was charged by a write that never committed: \
            \(heldPredecessors[0].retryCount)
            """)
        #expect(followersAfterTwo.allSatisfy { $0.retryCount == 0 }, """
            a follower was charged for a failure that was not its own: \
            \(followersAfterTwo.map(\.retryCount))
            """)

        // RECOVERY — writes work again, and both accounts converge.
        f.pool.remove(transactionObserver: firstRefuser)
        f.pool.remove(transactionObserver: secondRefuser)
        try await drainToQuiescence(f)

        let firstFinal = firstServer.http.servedCallSequence()
        let secondFinal = secondServer.http.servedCallSequence()
        #expect(firstFinal.filter { $0.hasPrefix("PATCH ") }.count == 3, """
            account A's two gestures did not each execute exactly once — the \
            first PATCH is the 503 this schedule began with: \(firstFinal)
            """)
        #expect(secondFinal.filter { $0.hasPrefix("PATCH ") }.count == 3, """
            account B's two gestures did not each execute exactly once — the \
            first PATCH is the 503 armed at the start, which account B did not \
            reach until the recovery: \(secondFinal)
            """)

        // 🚨 THE ORDERING ORACLE. Both operations write `isRead`; the message was
        // seeded UNREAD. Read is the only state that means "both ran, in issue
        // order". Unread means the mark-unread ran LAST — the follower was
        // admitted ahead of its predecessor and the OLDER intention overwrote the
        // newer one — or that nothing ran at all, which the wire counts above
        // separate.
        #expect(firstServer.snapshot(providerMessageId: "graph-a")?.isRead == true, """
            account A's LATEST intention is not what the server holds: \(firstFinal)
            """)
        #expect(secondServer.snapshot(providerMessageId: "graph-b")?.isRead == true, """
            account B's LATEST intention is not what the server holds: \(secondFinal)
            """)

        #expect(await AccountManager.shared.pendingRequeues.isEmpty,
                "a retained requeue was never resolved")
        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a retirement was retained by a scenario that has no move in it")
        let finalHeaders = try rows(f)
        #expect(finalHeaders.count == 2,
                "a header was destroyed: \(finalHeaders.map(\.messageId))")

        try expectGesturePreservedAndExecuted(
            f,
            effectVisibleOnServer:
                firstServer.snapshot(providerMessageId: "graph-a")?.isRead == true
                && secondServer.snapshot(providerMessageId: "graph-b")?.isRead == true,
            gesture: "both accounts' mark-reads behind a retained, unresolved requeue",
            serverState: "A: folders=\(serverFolders(firstServer, rfc: firstRfc)); "
                + "B: folders=\(serverFolders(secondServer, rfc: secondRfc))")

        await AccountManager.shared.unregisterProviderForTesting(accountId: secondAccountId)
        await finish(f)
    }

    // MARK: - A confirmed-gone member's header follows the member, not the path

    /// **THE PROPERTY: a member the server reported GONE loses its local header
    /// whichever path commits the retirement — including the RETAINED REPLAY.**
    ///
    /// A confirmed-gone member is dispositioned in the provider loop and the
    /// operation completes; the ghost header it leaves behind is retired in the
    /// same drain. But the local retirement write can be refused — GRDB suspends
    /// writes when the app is backgrounded mid-drain (`ADR-IOS-041`), and a full
    /// disk or an I/O error at COMMIT does the same — in which case the proof is
    /// retained and replayed at the next drain. The FIRST version of this change
    /// put the header cleanup only at the direct site, so the replay retired the
    /// queue row and left the ghost row in the mailbox forever: no operation names
    /// that message any more, so nothing will ever retire it, and a sync that
    /// re-reads the folder will not delete a row for a message the server has no
    /// record of either.
    ///
    /// 🚨 ONE MEMBER, AND THE SHAPE OF A RETAINED WHOLE RETIREMENT IS WHY. An
    /// attempt settles exactly one member, so an operation retires WHOLE only
    /// when that member is the last one it owed — and for the retained proof to
    /// carry a confirmed-gone attribution at all, that last member has to be the
    /// gone one. A longer bundle reaches the same state one narrowing at a time;
    /// what it can no longer do is put a gone member and a moved member into ONE
    /// retained proof, which is the shape this test used to build. The
    /// liveness half — a gone member does not strand its siblings — is asserted
    /// where it now lives, across attempts, in `theNarrowingPathRetiresA…` below
    /// and in `QueueMemberAbsenceTests`.
    ///
    /// ⚠️ THE REFUSAL IS DATABASE-WIDE AND ARMED AFTER THE CLAIM, not
    /// header-shaped. A retirement whose only proven member is GONE writes no
    /// header at all — `MessageHeaderRekey.finishMove` has no proven destination
    /// to re-key onto — so a `HeaderCommitRefuser` cannot see that transaction,
    /// and the producer it models is indiscriminate anyway (a suspended writer
    /// connection, a full disk). Arming it while the `/move` is parked is what
    /// keeps the drain's own claim transaction out of its way.
    ///
    /// Both halves are asserted because they fail in opposite directions. While
    /// the write is refused NOTHING may be committed — the ghost header is still
    /// there, because the retirement it belongs to has not happened. After the
    /// database accepts writes again BOTH must land together.
    ///
    /// RED PROOF (recorded): with the cleanup at the direct site only, the first
    /// half passes unchanged and the recovery half fails at
    /// `headerExists(gone) == false` — the queue is empty and the ghost row
    /// survives.
    @Test("Outlook: a confirmed-gone member's header is retired by the retained retirement REPLAY too")
    @MainActor
    func aConfirmedGoneMembersHeaderIsRetiredByTheReplay() async throws {
        let goneRfc = "graph-gone-replay-gone@example.com"
        // `graph-gone` is deliberately NOT on the server: its `/move` is a
        // deterministic 404, Graph's authoritative "this message is gone".
        let server = StatefulExchangeActionServer(messages: [])
        defer { server.close() }

        let f = try fixture(accountId: "graph-gone-replay")
        try seedHeader(f, graphId: "graph-gone", rfc: goneRfc)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")

        let op = PendingOperation(
            type: .move, messageIds: ["graph-gone"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.firstDestination)
        try await f.pool.write { db in _ = try op.inserted(db) }

        await register(server.provider(), f)

        let refuser = AllWritesRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }
        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so the refusal cannot be placed after the claim")
        guard held else {
            release()
            _ = await drain.value
            await finish(f)
            return
        }
        refuser.arm()
        release()
        _ = await drain.value

        // NON-VACUITY: the retirement really was attempted and really was
        // refused, once per `retryWrite` attempt (`MIS-027`).
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the retirement write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the proof was not retained, so the replay path is not under test")

        // NOTHING COMMITTED YET — including the ghost. Deleting the header
        // before the operation that retires it would be the wrong order.
        #expect(try headerExists(f, graphId: "graph-gone") == true, """
            the confirmed-gone member's header was deleted while the retirement \
            that retires it had not committed
            """)
        #expect(try queuedOperationCount(f) == 1, "the operation row must survive a failed local write")

        // The database accepts writes again.
        refuser.disarm()
        try await drainToQuiescence(f)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained retirement never replayed")
        #expect(try queuedOperationCount(f) == 0, "the retained retirement never replayed")
        #expect(try headerExists(f, graphId: "graph-gone") == false, """
            the queue row retired through the REPLAY and left the ghost header \
            behind. Nothing names that message any more, so nothing will ever \
            retire it — the cleanup has to follow the member, not the path.
            """)

        // NON-VACUITY ON THE WIRE: the attribution came from the RETAINED proof,
        // not from a second round trip that rediscovered it.
        let moves = server.http.servedCallSequence().filter { $0.hasSuffix("/move") }
        #expect(moves.count == 1, """
            the absent member was addressed more than once — the retained \
            attribution was not used and the drain went back to the wire to \
            rediscover what it already knew: \(moves)
            """)

        await finish(f)
    }

    /// **THE PROPERTY: the NARROWING path retires a confirmed-gone member's
    /// header too.**
    ///
    /// This shape did not exist before per-member absence moved to the provider
    /// boundary, which is why the narrowing path legitimately had no header
    /// cleanup: a partial outcome could only be a proven PREFIX, every retired
    /// member had actually been mutated, and none of them was gone. A batch of
    /// `[absent, moved, transiently-refused]` now retires the first two and keeps
    /// the third queued — so a member the server reported gone leaves the row
    /// through a path that used to be unable to see one.
    ///
    /// The refusal on the third member is a **503**, not a 404: a transient
    /// refusal leaves that member durably owed, which is what makes this a
    /// partial outcome at all. A 404 there would disposition it too and the
    /// operation would retire whole, taking the direct path instead.
    ///
    /// RED PROOF (recorded): with the cleanup at the whole-op site only, the
    /// narrowing assertions pass and `headerExists(gone) == false` fails — the
    /// member is retired from the operation and its ghost row survives.
    @Test("Outlook: the narrowing path retires a confirmed-gone member's header")
    @MainActor
    func theNarrowingPathRetiresAConfirmedGoneMembersHeader() async throws {
        let liveRfc = "graph-gone-partial-live@example.com"
        let goneRfc = "graph-gone-partial-gone@example.com"
        let refusedRfc = "graph-gone-partial-refused@example.com"
        // `graph-gone` is absent from the server on purpose.
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: liveRfc, providerMessageId: "graph-live", folderId: Self.source),
            .init(rfc822MessageId: refusedRfc, providerMessageId: "graph-refused", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-gone-partial")
        try seedHeader(f, graphId: "graph-gone", rfc: goneRfc)
        try seedHeader(f, graphId: "graph-live", rfc: liveRfc)
        try seedHeader(f, graphId: "graph-refused", rfc: refusedRfc)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")

        // Member order is load-bearing: gone, then moved, then refused, so the
        // provider returns a proven prefix with an unresolved remainder.
        let op = PendingOperation(
            type: .move, messageIds: ["graph-gone", "graph-live", "graph-refused"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.firstDestination)
        try await f.pool.write { db in _ = try op.inserted(db) }

        server.failMoveOnce(providerMessageId: "graph-refused")
        await register(server.provider(), f)

        try await drainToQuiescence(f)

        // NON-VACUITY, ON THE WIRE: this really was the NARROWING path and not a
        // whole-op retry. The one-shot 503 is spent on the first attempt, so the
        // remainder completes in a later pass of the same drain — and the
        // discriminator is that the PROVEN member was moved exactly ONCE. A row
        // retried whole would have re-issued `/move` for `graph-live` too (at an
        // id Graph had already reallocated).
        let moves = server.http.servedCallSequence().filter { $0.hasSuffix("/move") }
        #expect(moves.filter { $0.contains("graph-live") }.count == 1, """
            the proven member was moved more than once, so the row was retried \
            whole rather than narrowed: \(moves)
            """)
        #expect(moves.filter { $0.contains("graph-refused") }.count == 2, """
            the transiently-refused member was not retried exactly once after \
            its 503, so this is not the partial-then-complete shape: \(moves)
            """)
        #expect(moves.filter { $0.contains("graph-gone") }.count == 1, """
            the absent member was addressed more than once — the drain re-shaped \
            the operation to rediscover what the wire already said: \(moves)
            """)

        #expect(try queuedOperationCount(f) == 0, "the narrowed remainder never completed")
        #expect(try headerExists(f, graphId: "graph-gone") == false, """
            the confirmed-gone member left the operation through the NARROWING \
            path and kept its local header. No operation names it any more, so \
            nothing will ever retire it: the cleanup has to follow the member, \
            not the path.
            """)
        #expect(serverFolders(server, rfc: liveRfc) == [Self.firstDestination],
                "the proven member did not move, so this is not a partial outcome")
        #expect(serverFolders(server, rfc: refusedRfc) == [Self.firstDestination],
                "the transiently-refused member never landed")

        await finish(f)
    }

    /// **THE PROPERTY: the RETAINED NARROWING's replay retires a confirmed-gone
    /// member's header too — the fourth and last commit site.**
    ///
    /// The three sites above it are covered: whole-op success, the retained
    /// WHOLE retirement's replay, and the direct narrowing. This is the one that
    /// only exists when both hazards happen at once — an operation that is
    /// partially dispositioned AND a local write that will not commit — and it is
    /// the site with the least redundancy behind it, because by the time the
    /// replay runs nothing else in the process is still looking at that member.
    ///
    /// The gone member leaves the operation inside the retained
    /// `.partial(confirmedGoneMembers:)` payload, so BOTH the attribution's
    /// survival across retention and the replay's use of it are under test here.
    /// Storing `[]` in that field, or dropping the cleanup from the replay arm,
    /// leaves the operation narrowed and the ghost row in the mailbox forever: no
    /// operation names that message any more, and a sync of the SOURCE folder
    /// would not delete a row the server has no record of either.
    ///
    /// 🚨 TWO MEMBERS, GONE FIRST, AND THAT IS FORCED. An attempt settles exactly
    /// one member, so the retained NARROWING carries a confirmed-gone attribution
    /// only when the member it settled was the gone one and something is still
    /// owed behind it. `[gone, live]` is the smallest operation with that shape;
    /// the old `[gone, moved, refused]` fixture built a payload — one gone member
    /// and one moved member in the SAME proof — that an attempt can no longer
    /// produce.
    ///
    /// ⚠️ THE REFUSAL IS DATABASE-WIDE AND ARMED WHILE THE `/move` IS PARKED, not
    /// header-shaped: a narrowing whose only proven member is GONE has no proven
    /// destination to re-key onto, so it writes no header and a
    /// `HeaderCommitRefuser` cannot see it. The producer it models is
    /// indiscriminate anyway — a writer connection suspended by backgrounding
    /// (`ADR-IOS-041`), a full disk — and arming it after the move is parked is
    /// what keeps the drain's own claim transaction out of its way.
    ///
    /// Both halves are asserted because they fail in opposite directions. While
    /// the write is refused NOTHING may be committed — the operation keeps both
    /// members, no retry is charged, and the ghost is still there, because the
    /// narrowing it belongs to has not happened. After writes work again all of
    /// it must land together, and the member already dispositioned must not be
    /// sent to Graph a second time.
    ///
    /// RED PROOF (recorded): with `[]` stored in the retained narrowing's
    /// confirmed-gone field, everything else passes and
    /// `headerExists(graph-gone) == false` fails — the row is narrowed, the
    /// remainder completes, and the ghost survives. Removing
    /// `retireConfirmedGoneMemberHeaders` from the `.partial` replay arm fails the
    /// same assertion the same way.
    @Test("Outlook: the retained NARROWING's replay retires a confirmed-gone member's header")
    @MainActor
    func theNarrowingReplayRetiresAConfirmedGoneMembersHeader() async throws {
        let liveRfc = "graph-gone-narrow-replay-live@example.com"
        let goneRfc = "graph-gone-narrow-replay-gone@example.com"
        // `graph-gone` is deliberately absent from the server: its `/move` is a
        // deterministic 404, Graph's authoritative "this message is gone".
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: liveRfc, providerMessageId: "graph-live", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-gone-narrow-replay")
        try seedHeader(f, graphId: "graph-gone", rfc: goneRfc)
        try seedHeader(f, graphId: "graph-live", rfc: liveRfc)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "a previous test left a retained retirement on the shared AccountManager")

        // Member order is load-bearing: the GONE member first, so the attempt
        // that is refused is the one whose proof names it.
        let op = PendingOperation(
            type: .move, messageIds: ["graph-gone", "graph-live"],
            accountId: f.accountId, folderPath: Self.source,
            destinationPath: Self.firstDestination)
        try await f.pool.write { db in _ = try op.inserted(db) }

        await register(server.provider(), f)

        let refuser = AllWritesRefuser()
        f.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        let release = server.holdNextMove()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }
        let held = try await awaitHeldMoves(server, count: 1)
        #expect(held, "the move was never parked, so the refusal cannot be placed after the claim")
        guard held else {
            release()
            _ = await drain.value
            await finish(f)
            return
        }
        refuser.arm()
        release()
        _ = await drain.value

        // NON-VACUITY: the narrowing really was attempted and really was refused,
        // once per `retryWrite` attempt (`MIS-027`).
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the narrowing write for exactly its \
            three attempts: \(refuser.refusals.withLock { $0 })
            """)
        #expect(await AccountManager.shared.pendingRetirements.count == 1,
                "the narrowing was not retained, so the PARTIAL replay path is not under test")

        // NON-VACUITY on the wire: the gone member 404'd and the member behind it
        // was not addressed at all, which is what makes this a PARTIAL outcome.
        let firstDrain = server.http.servedCallSequence().filter { $0.hasSuffix("/move") }
        #expect(firstDrain.count == 1,
                "the attempt addressed more than the one member it may settle: \(firstDrain)")
        #expect(serverFolders(server, rfc: liveRfc) == [Self.source],
                "the member behind the settled one moved even though nothing addressed it")

        // NOTHING COMMITTED YET — including the ghost. Deleting the header before
        // the narrowing that retires it commits would be the wrong order.
        let held2 = try await f.pool.read { db in try PendingOperation.fetchOne(db, key: op.id) }
        #expect(held2?.messageIds == ["graph-gone", "graph-live"], """
            the operation was narrowed even though the narrowing write never \
            committed: \(String(describing: held2?.messageIds))
            """)
        #expect(held2?.status == PendingStatus.inFlight.rawValue, """
            the operation was returned to `queued` with a member the wire had \
            already dispositioned: \(held2?.status ?? "<deleted>")
            """)
        #expect(held2?.retryCount == 0,
                "a provider retry was charged for a LOCAL write failure")
        #expect(try headerExists(f, graphId: "graph-gone") == true, """
            the confirmed-gone member's header was deleted while the narrowing \
            that retires it had not committed
            """)
        #expect(try headerExists(f, graphId: "graph-live") == true, """
            the member behind the settled one lost its source address even though \
            nothing has moved it
            """)

        // The database accepts writes again.
        refuser.disarm()
        try await drainToQuiescence(f)

        #expect(await AccountManager.shared.pendingRetirements.isEmpty,
                "the retained narrowing never replayed")
        #expect(try queuedOperationCount(f) == 0, "the narrowed remainder never completed")

        // 🚨 THE ORACLE FOR THIS SITE.
        #expect(try headerExists(f, graphId: "graph-gone") == false, """
            the operation was narrowed through the retained-narrowing REPLAY and \
            left the ghost header behind. Nothing names that message any more, so \
            nothing will ever retire it — the attribution has to survive retention \
            and the replay has to use it.
            """)

        // The ghost cleanup is SCOPED: the member behind it converged and carries
        // the address Graph proved for it. Naming that address is what makes
        // "only the gone member's header disappeared" a complete statement.
        let provenLive = liveId(server, rfc: liveRfc)
        #expect(provenLive != nil && provenLive != "graph-live")
        guard let provenLive else { await finish(f); return }
        #expect(try headerExists(f, graphId: "graph-live") == false,
                "the moved member's header was left at the source id the move invalidated")
        let surviving = try rows(f).map(\.messageId).sorted()
        #expect(surviving == [provenLive], """
            exactly the gone member's header may disappear, and the survivor must \
            carry the address Graph proved for it (\(provenLive)): \(surviving)
            """)

        // ALREADY-DISPOSITIONED MEMBERS ARE NOT RESENT, and the remainder lands.
        let finalMoves = server.http.servedCallSequence().filter { $0.hasSuffix("/move") }
        #expect(finalMoves.filter { $0.contains("graph-gone") }.count == 1, """
            the absent member was addressed again — the retained attribution was \
            not used and the drain went back to the wire to rediscover it: \(finalMoves)
            """)
        #expect(finalMoves.filter { $0.contains("graph-live") }.count == 1, """
            the remaining member was moved more than once, which would seat a \
            second copy at the destination: \(finalMoves)
            """)
        #expect(serverFolders(server, rfc: liveRfc) == [Self.firstDestination],
                "the remainder never converged")

        await finish(f)
    }

    /// Does a local header exist at this Graph id, in the source folder?
    private func headerExists(_ fixture: Fixture, graphId: String) throws -> Bool {
        let id = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: Self.source, messageId: graphId)
        return try fixture.pool.read { db in try MessageHeader.fetchOne(db, key: id) != nil }
    }

}
