/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// THE ADDRESS PROBLEM in the **Graph** id space, closed — the sibling of
/// `FinishTheMoveLocallyTests`, which closed it for IMAP's `COPYUID`.
///
/// `POST /messages/{id}/move` answers with the moved message carrying its NEW
/// `id`; Graph reallocates that id on every folder move unless the client sends
/// `Prefer: IdType="ImmutableId"`, which this app sends nowhere. That response
/// used to be bound to `_`, so the local row kept an address the app itself had
/// invalidated, the user's next gesture named it, Graph answered `404`, and the
/// drain read the 404 as *"the provider says the work is done"* and DELETED the
/// `PendingOperation` — with the optimistic local move already applied and never
/// rolled back, so the UI showed success. `KNOWN_ISSUES.md` `IOS-GRAPH-002`.
///
/// Tests here assert SYSTEM PROPERTIES — what reached the wire and what is still
/// durably queued — never the re-key's mechanism. In particular none of them
/// asserts "the header now carries the new id"; a test written that way stays
/// green on a wrong spec (`MIS-015`).
///
/// **WHY THE DESTINATION FOLDERS ARE NOT SEEDED AS LOCAL `Folder` ROWS.**
/// `drainPendingQueue` ends by SYNCING every destination folder it touched, and
/// that sync is a REPAIR strictly downstream of the drop (`MIS-024`): it
/// materialises the message under its new id and can sweep the remnant. Against
/// a fake Graph server holding one message it always succeeds, so a fixture that
/// lets it run would repair the defect itself and every assertion below would
/// pass on the pre-fix code for a reason unrelated to the fix. Production cannot
/// rely on it — that is the whole reason `IOS-GRAPH-002` is BLOCKING rather than
/// registrable: `selectStaleHeaders`' `.date` arm only reaches messages inside
/// the destination folder's newest-N window, and Exchange delta is Inbox-only.
/// Omitting the destination `Folder` row makes the post-drain lookup miss and
/// the sync be skipped, which is the ONLY thing it changes — nothing on the
/// gesture, admission, drain, or re-key path reads that row except for
/// `finishMove`'s epoch probe, whose answer for an Exchange folder is `nil`
/// either way.
@Suite("Finish the move locally — Microsoft Graph", .serialized, .processGlobalState)
struct FinishTheMoveLocallyGraphTests {

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
                emailAddress: "graph-address@example.com", displayName: "Graph address",
                provider: .outlook)
            account.id = accountId
            try account.insert(db)
            // Source only — see the suite comment. An Exchange folder carries no
            // UIDVALIDITY, so no epoch is seeded anywhere in this file.
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
    private func register(
        _ provider: ExchangeProvider, _ fixture: Fixture
    ) async {
        await AccountManager.shared.registerProviderForTesting(
            accountId: fixture.accountId, provider: provider)
    }

    /// A local header seeded as an Exchange sync leaves it: addressed by its
    /// Graph resource id, with NO epoch (Exchange has no UIDVALIDITY space).
    @discardableResult
    private func seedHeader(
        _ fixture: Fixture, graphId: String, rfc: String
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: graphId,
            subject: "graph address \(graphId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "graph-address@example.com",
            date: Date(),
            snippet: "graph address body",
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

    /// Drain until the queue is empty AND no drain is in flight. Ported from
    /// `FinishTheMoveLocallyTests.drainToQuiescence` — the quiescence read comes
    /// FIRST so the barrier cannot re-arm itself.
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

    // MARK: - THE HEADLINE — a second gesture on a just-moved Outlook message

    /// **THE PROPERTY: a queued move either reaches the server, or it is still
    /// durably queued. It is never destroyed on an address the app itself
    /// invalidated.**
    ///
    /// Stated as an either/or on purpose. It is the never-drop invariant
    /// verbatim — not "the header was re-keyed", which is the fix's mechanism
    /// and would stay green on a wrong spec, and not "the queue is empty and the
    /// message is still in the first destination", which is the BUG.
    ///
    /// The liveness half is asserted separately below, because the two failure
    /// modes are opposites and one assertion cannot see both: the safety
    /// property alone is satisfied by an operation that retries against the dead
    /// id forever, which is `IOS-GRAPH-002`'s named mirror-image trap — with
    /// `buildLanes` keyed on `accountId:folderPath:messageId` that operation
    /// starves its whole lane, and a starved intention has not been preserved
    /// either (the wedge corollary). What makes retry TERMINATE is re-learning
    /// the address, which is why the fix is the re-key and not a
    /// reclassification of the 404.
    @Test("A second gesture on a just-moved Outlook message still reaches the server")
    @MainActor
    func aSecondGestureOnAJustMovedGraphMessageReachesTheServer() async throws {
        let rfc = "graph-second-gesture@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfc, providerMessageId: "graph-1", folderId: Self.source),
        ])
        defer { server.close() }

        let f = try fixture(accountId: "graph-address-second-gesture")
        await register(server.provider(), f)
        let seeded = try seedHeader(f, graphId: "graph-1", rfc: rfc)

        // GESTURE 1 — swipe-archive, through the production gesture path.
        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        try await drainToQuiescence(f)

        // NON-VACUITY, wire side: the first move really did happen, and Graph
        // really did reallocate the id — so the second half of this test is
        // exercising the churn rather than a server that never churned.
        #expect(
            serverFolders(server, rfc: rfc) == [Self.firstDestination],
            "the first move did not reach the server, so nothing below would prove anything")
        #expect(
            server.snapshot(providerMessageId: "graph-1") == nil,
            "Graph did not reallocate the id, so this test is not exercising the churn")

        // GESTURE 2 — swipe-delete, on whatever row the user is now looking at.
        let afterArchive = try rows(f)
        #expect(afterArchive.count == 1)
        if let subject = afterArchive.first {
            await AccountManager.shared.move([subject], to: Self.secondDestination)
            try await drainToQuiescence(f)
        }

        // THE PROPERTY.
        let landed = serverFolders(server, rfc: rfc) == [Self.secondDestination]
        let stillQueued = try queuedOperationCount(f) > 0
        #expect(
            landed || stillQueued,
            """
            the user's second gesture was DESTROYED: the server still has the message at \
            \(serverFolders(server, rfc: rfc)) and no PendingOperation survives to retry it. \
            A 404 on an address this app invalidated by discarding Graph's /move response is \
            not evidence that the queued work is done.
            """)

        // THE LIVENESS HALF — the trap named in `IOS-GRAPH-002`: reclassifying
        // the 404 as merely retryable satisfies the property above forever
        // while never executing anything, and starves the lane doing it.
        #expect(
            landed,
            """
            the gesture is preserved but has not TERMINATED — the operation is queued against an \
            address that can never resolve, which starves every later operation in its lane. \
            Server: \(serverFolders(server, rfc: rfc)).
            """)
        #expect(
            try queuedOperationCount(f) == 0,
            "the queue did not drain, so the intention is retained rather than executed")

        await finish(f)
    }

    // MARK: - Non-vacuity, the other side

    /// **THE ANCHOR: the same two gestures on a tenant whose Graph ids do NOT
    /// churn across a move must go through unchanged.**
    ///
    /// The symmetric leg of the test above (`MIS-005`: a fix validated only in
    /// the direction of its bug is not finished). It holds before the fix, after
    /// it, and — the point of an anchor — with the fix INVERTED, so it cannot be
    /// satisfied by a "fix" that merely keeps the operation queued: it asserts
    /// the queue drains AND the message arrives. Its non-vacuity is discharged
    /// from the inversion run's printed output, never from reading it
    /// (`MIS-024` instance 4).
    @Test("Two gestures still work when the tenant's Graph ids survive a move")
    @MainActor
    func twoGesturesWorkWhenGraphIdsDoNotChurn() async throws {
        let rfc = "graph-stable-id@example.com"
        let server = StatefulExchangeActionServer(
            messages: [
                .init(rfc822MessageId: rfc, providerMessageId: "graph-stable", folderId: Self.source),
            ],
            churnsIdOnMove: false)
        defer { server.close() }

        let f = try fixture(accountId: "graph-address-stable-id")
        await register(server.provider(), f)
        let seeded = try seedHeader(f, graphId: "graph-stable", rfc: rfc)

        await AccountManager.shared.move([seeded], to: Self.firstDestination)
        try await drainToQuiescence(f)

        // NON-VACUITY: this server really does NOT churn, which is the whole
        // difference between this test and the one above.
        #expect(
            server.snapshot(providerMessageId: "graph-stable")?.folderId == Self.firstDestination,
            "the id did not survive the move, so this is not the stable-id case")

        let afterArchive = try rows(f)
        #expect(afterArchive.count == 1)
        if let subject = afterArchive.first {
            await AccountManager.shared.move([subject], to: Self.secondDestination)
            try await drainToQuiescence(f)
        }

        #expect(
            serverFolders(server, rfc: rfc) == [Self.secondDestination],
            "the second gesture did not reach a server that never invalidated the address")
        #expect(try queuedOperationCount(f) == 0)

        await finish(f)
    }

    // MARK: - The batch that failed partway

    /// **THE PROPERTY: an address the server already gave us for one member is
    /// not thrown away because a LATER member of the same batch failed.**
    ///
    /// Each Graph move is its own request, so a two-member batch can land one and
    /// fail the next. Throwing the whole attempt away would discard the
    /// destination address the wire had already supplied for the first member —
    /// re-creating, one mid-batch failure later, exactly the state this change
    /// exists to prevent. The proven prefix is returned instead, which is the
    /// input `AccountManagerQueue.retirePartiallyCompletedOp` re-keys from
    /// (covered end-to-end by `QueueCoreInvariantTests`).
    ///
    /// Driven at the provider boundary because the member ORDER is what decides
    /// which member fails, and the gesture path does not promise one: pinning it
    /// here keeps the test deterministic instead of depending on the order rows
    /// happen to come back from GRDB.
    @Test("A batch that fails partway returns the addresses Graph already gave it")
    @MainActor
    func aPartiallyFailedBatchReturnsTheProvenAddresses() async throws {
        let movedRfc = "graph-batch-moved@example.com"
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: movedRfc, providerMessageId: "graph-a", folderId: Self.source),
        ])
        defer { server.close() }
        let provider = server.provider()

        // `graph-missing` has no resource on the server at all, so its move is a
        // deterministic 404 — the second member fails after the first landed.
        let outcome = try await provider.moveProvingDestinations(
            ids: ["graph-a", "graph-missing"],
            from: Self.source, to: Self.firstDestination)

        // NON-VACUITY: the batch really did fail partway.
        #expect(
            serverFolders(server, rfc: movedRfc) == [Self.firstDestination],
            "the first member never moved, so there is no proven address to preserve")
        #expect(
            server.snapshot(providerMessageId: "graph-missing") == nil,
            "the second member exists after all, so this is not a partial batch")

        // THE PROPERTY: the member that moved is dispositioned and its
        // re-learned address survives the sibling's failure.
        #expect(outcome.provenIds == ["graph-a"])
        #expect(outcome.provenDestinations.count == 1)
        guard let proven = outcome.provenDestinations.first else { return }
        #expect(proven.sourceProviderId == "graph-a")
        let liveId = server.snapshots(rfc822MessageId: movedRfc).first?.providerMessageId
        #expect(
            proven.destinationProviderId == liveId,
            """
            the address reported for the member that moved is not the one the server actually \
            assigned it (\(String(describing: liveId))) — a re-key onto it would address a \
            message the gesture never selected.
            """)
        // No epoch is invented for a provider that has no epoch space: a
        // fabricated stamp is a POSITIVE disagreement with the folder's own
        // `nil`, which `roleMoveRejectDispositions` treats as its only TERMINAL
        // arm — the mirror image of the bug this change closes.
        #expect(proven.destinationUidValidity == nil)
    }
}
