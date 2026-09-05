/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
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
/// (`MessageHeaderRekey.readdressQueuedOperations`) and the lane loop re-reads
/// each row immediately before executing it. Without both halves, serialization
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
    @discardableResult
    private func seedHeader(
        _ fixture: Fixture, graphId: String, rfc: String
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: graphId,
            subject: "graph handoff \(graphId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "graph-handoff@example.com",
            date: Date(),
            snippet: "graph handoff body",
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: Self.source),
            accountId: fixture.accountId,
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

        // OFFLINE: no provider is registered yet, so both gestures queue without
        // executing — the shape a user produces on a plane, and the only shape in
        // which a follower is guaranteed to be in the same drain pass as its
        // predecessor.
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
    /// components, so `drainPendingQueue` launches them as concurrent tasks and
    /// whichever finishes last wins — including the OLDER gesture.
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
    /// key itself). Both go red when `.outlook` leaves the account-scoped set.
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

    // MARK: - T5 — a lane halt must not revert the handoff

    /// **THE PROPERTY: a lane that halts mid-drain resumes at the addresses the
    /// wire proved, not at the ones its snapshot was taken with.**
    ///
    /// The drain snapshots every operation at the start of a pass and builds lanes
    /// from those VALUES. When a lane halts, the ops behind the halt are returned
    /// to `queued`. Writing that with a whole-row `save` of the snapshot would
    /// silently REVERT a re-address committed moments earlier by the predecessor's
    /// retirement, and the reverted operation goes out at the dead id on the next
    /// drain, 404s, and is deleted. Only the two columns the requeue actually
    /// decided may be written (`PendingOperation.markQueued`).
    @Test("Outlook: a lane halt behind a retired move does not revert the re-addressed followers")
    @MainActor
    func aLaneHaltDoesNotRevertTheHandoff() async throws {
        let rfc = "graph-handoff-halt@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-handoff-halt")
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // OFFLINE: move, then two flag gestures, so the lane has something BEHIND
        // the operation that fails.
        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        let optimistic = try rows(f)
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markRead([optimistic[0]])
        await AccountManager.shared.markFlagged([optimistic[0]], flagged: true)
        #expect(try queuedOperationCount(f) == 3,
                "all three gestures must be queued offline, or the halt has nothing behind it")

        await register(server.provider(), f)
        // The move succeeds; the mark-read's PATCH is refused once, which halts
        // the lane and requeues the mark-flagged behind it.
        server.failNextPatch()
        await AccountManager.shared.drainPendingQueue()
        try await drainToQuiescence(f)

        // NON-VACUITY, read from the WIRE once everything has settled rather than
        // from the queue mid-pass. `drainPendingQueue()` re-drives itself from its
        // own `defer` when a lane halted, and a caller that arrives while a pass is
        // running returns immediately instead of joining it — so there is no
        // instant at which "the queue still has work" can be sampled reliably, and
        // an earlier revision of this test sampled it before the halt had even
        // happened. The refusal leaves a permanent mark on the wire instead: THREE
        // PATCHes must have been served for two flag gestures — the mark-read that
        // was refused, its retry after the requeue, and the mark-flagged that was
        // requeued behind it. Two would mean the lane never halted and the requeue
        // path this test exists for never ran.
        #expect(serverFolders(server, rfc: rfc) == [Self.firstDestination],
                "the move did not land, so there is no handoff for the requeue to revert")
        let patches = server.http.servedCallSequence().filter { $0.hasPrefix("PATCH ") }
        #expect(patches.count == 3, """
            the mark-read's PATCH was not refused and retried, so the lane never \
            halted and nothing was requeued behind it: \(patches)
            """)

        let current = liveId(server, rfc: rfc)

        // WHICH ADDRESS THOSE THREE PATCHES NAMED, which is the actual subject of
        // this test. Counting them proves the lane halted and re-drove; it does
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

    // MARK: - T6 — a whole-account halt must not revert the handoff either

    /// **THE PROPERTY: an operation requeued because ANOTHER lane's failure took
    /// the whole account down resumes at the address the wire proved, and is
    /// never charged a retry for a failure that was not its own.**
    ///
    /// T5 covers the two requeues that happen INSIDE a lane (the refused op's own
    /// halt, and the members behind it). This is the third requeue site and the
    /// only one driven from a DIFFERENT lane: when any operation fails for a
    /// connectivity reason, `executeSingleOp` puts the account into
    /// `DrainContext.failedAccounts`, and every other lane of that account then
    /// requeues its remaining members before executing them — deliberately, so
    /// one drain does not hammer a server that is down.
    ///
    /// That arm is reached only when a SECOND lane is still mid-flight when the
    /// first one fails, and on Graph a second lane exists only because the lane
    /// key is `(account, message id)` — two different messages, two lanes, run
    /// concurrently. The schedule is produced with the fixture's existing seams
    /// and is deterministic in both directions:
    ///  - the handoff lane cannot advance past its move, because `holdNextMove`
    ///    parks it inside the route;
    ///  - the failure lane's `failNextPatch` is therefore consumed by the only
    ///    PATCH that can reach the wire while the move is parked;
    ///  - and the release waits on a strict HAPPENS-AFTER of the account being
    ///    marked failed: `failedAccounts.insert` precedes the `.haltLane`
    ///    requeue of the rest of that lane, so observing the second failure-lane
    ///    operation back at `queued` proves the flag is already set.
    ///
    /// The oracle is the ADDRESS the follower carries and where it lands, never
    /// "the arm was taken" (`MIS-015`).
    @Test("Outlook: an operation requeued because another lane failed the account keeps the address the wire proved")
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

        // OFFLINE, so every gesture is durably queued before any of them runs.
        // LANE A (graph-1): a move, then a follower that must inherit its address.
        await AccountManager.shared.move([handoffSeed], to: Self.firstDestination)
        let optimistic = try rows(f).filter { $0.rfc822MessageId == handoffRfc }
        #expect(optimistic.count == 1)
        guard optimistic.count == 1 else { return }
        await AccountManager.shared.markRead([optimistic[0]])
        // LANE B (graph-2): the operation that will fail, and one behind it whose
        // requeue is this test's happens-after signal.
        await AccountManager.shared.markFlagged([unrelatedSeed], flagged: true)
        await AccountManager.shared.markRead([unrelatedSeed])
        #expect(try queuedOperationCount(f) == 4,
                "all four gestures must be queued offline, or the two lanes do not overlap")

        let laneBTrailerId = try await f.pool.read { db -> String? in
            try PendingOperation.fetchAll(db).first {
                $0.messageIds == ["graph-2"] && $0.type == .markRead
            }?.id
        }
        #expect(laneBTrailerId != nil, "lane B's trailing operation was not queued")
        guard let laneBTrailerId else { return }

        await register(server.provider(), f)
        let release = server.holdNextMove()
        server.failNextPatch()
        let drain = Task { await AccountManager.shared.drainPendingQueue() }

        #expect(try await awaitHeldMoves(server, count: 1),
                "the move was never parked, so lane A can advance before lane B fails")

        // Wait for lane B's trailing operation to be back at `queued`. That write
        // happens strictly AFTER `failedAccounts.insert`, so it is a real barrier
        // rather than a sleep.
        var accountMarkedFailed = false
        for _ in 0..<600 {
            let status = try await f.pool.read { db in
                try PendingOperation.fetchOne(db, key: laneBTrailerId)?.status
            }
            if status == PendingStatus.queued.rawValue { accountMarkedFailed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(accountMarkedFailed, """
            lane B never halted, so the account was never marked failed and lane A's \
            follower does not take the requeue arm this test exists for
            """)

        release()
        _ = await drain.value

        // PHASE 1 — inside the drain that marked the account failed. The follower
        // was requeued rather than executed, and the requeue must have preserved
        // the address the move's retirement had just committed.
        #expect(serverFolders(server, rfc: handoffRfc) == [Self.firstDestination],
                "the move did not land, so there is no handoff for the requeue to revert")
        #expect(server.snapshot(providerMessageId: "graph-1") == nil,
                "Graph did not reallocate the id, so this test is not exercising the churn")
        let proven = liveId(server, rfc: handoffRfc)
        #expect(proven != nil && proven != "graph-1")
        guard let proven else { return }

        let surviving = try await f.pool.read { db in try PendingOperation.fetchAll(db) }
        let addresses = surviving.map { "\($0.type.rawValue)=\($0.messageIdsJSON)" }
        let held = surviving.filter { $0.messageIds == [proven] }
        #expect(held.count == 1, """
            the follower is not addressed by the id the wire proved (\(proven)): \
            \(addresses). A requeue that wrote the lane's pre-handoff snapshot back \
            would leave it at graph-1, where the next drain 404s and the \
            single-message conflict arm deletes the user's gesture.
            """)
        guard held.count == 1 else { return }
        #expect(held[0].status == PendingStatus.queued.rawValue,
                "an operation held back by another lane's failure must be left retryable, not inFlight")
        #expect(held[0].everAttempted == true, "the claim's durable proof stands across a requeue")
        #expect(held[0].retryCount == 0, """
            a retry was charged for a failure on a DIFFERENT operation — got \
            \(held[0].retryCount)
            """)
        #expect(server.snapshot(providerMessageId: proven)?.isRead == false,
                "the follower executed anyway while the account was marked failed")

        // PHASE 2 — a healthy drain. Every gesture lands, at the proven address.
        try await drainToQuiescence(f)
        let final = liveId(server, rfc: handoffRfc)
        #expect(final == proven, "the message moved again after the handoff, so the oracle below is not the one under test")
        try expectGesturePreservedAndExecuted(
            f, effectVisibleOnServer: server.snapshot(providerMessageId: proven)?.isRead == true,
            gesture: "the follower requeued by the failed-account arm",
            serverState: "id=\(proven) folders=\(serverFolders(server, rfc: handoffRfc))")
        let bystander = server.snapshot(providerMessageId: "graph-2")
        #expect(bystander?.isFlagged == true && bystander?.isRead == true, """
            the lane whose PATCH was refused did not converge: \
            \(String(describing: bystander))
            """)

        await finish(f)
    }
}
