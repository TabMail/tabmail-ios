/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Persistent-failure chain demotion (ADR-IOS-060 decision 1 amendment,
/// 2026-07-15): a provider failure classified `persistentActionFailure`
/// (permanent-SHAPED but not authoritative-terminal — e.g. an unrecognized
/// REST 400) must NOT block the global FIFO forever the way a transient
/// failure deliberately does. The queue demotes the failing op's exact
/// RELATED CHAIN — the transitive closure over same-account rows whose member
/// sets intersect — to the queue tail, byte-identical and in intra-chain
/// order, so unrelated work proceeds. The intention is never dropped; the
/// error is reported loudly; a spin guard caps the chain at exactly ONE
/// provider attempt per drain.
///
/// Companion to `AccountManagerQueueDrainTests` / `AccountManagerQueueLivenessTests`.
/// The harness and liveness helpers are duplicated per this codebase's
/// established per-file test-fixture convention (see the note atop
/// `AccountManagerQueueLivenessTests`).
///
/// `.serialized`/`.processGlobalState`: swaps the process-wide
/// `AppDatabase.shared` singleton and mutates `AccountManager.shared`'s
/// registries, so it needs the same cross-suite process-global critical
/// section as its sibling queue suites.
@Suite(
    "AccountManagerQueue persistent-failure chain demotion",
    .serialized,
    .processGlobalState
)
struct AccountManagerQueueDemotionTests {

    // MARK: - Harness (mirrors AccountManagerQueueLivenessTests.makeTestDB/restoreTestDB)

    /// Pools are closed at the next serialized test boundary, after the unread-count
    /// actor proves its leading/trailing debounce work is idle. Closing synchronously
    /// in `defer` races the production debounce task and produces SQLite use-after-close.
    private static let deferredDatabaseCleanup = Mutex<[(pool: DatabasePool, dir: URL)]>([])

    private func makeTestDB() async throws -> (
        pool: DatabasePool,
        dir: URL,
        previous: AppDatabase?
    ) {
        await UnreadCountManager.shared.awaitIdleForTesting()
        let deferred = Self.deferredDatabaseCleanup.withLock { cleanups in
            let result = cleanups
            cleanups.removeAll()
            return result
        }
        for cleanup in deferred {
            try? cleanup.pool.close()
            try? FileManager.default.removeItem(at: cleanup.dir)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        return (pool, dir, previous)
    }

    /// Restore the process-global pointer immediately, but defer closing this pool
    /// until the next serialized test has awaited `UnreadCountManager` quiescence.
    private func restoreTestDB(
        pool: DatabasePool,
        previous: AppDatabase?,
        dir: URL
    ) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            Self.deferredDatabaseCleanup.withLock { $0.append((pool, dir)) }
        }
    }

    private func insertOp(_ op: PendingOperation, pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try op.insert(db) }
    }

    private func fetchOp(_ id: String, pool: DatabasePool) throws -> PendingOperation? {
        try pool.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    private func fetchOpsInRowidOrder(pool: DatabasePool) throws -> [PendingOperation] {
        try pool.read { db in
            try PendingOperation.fetchAll(db, sql: "SELECT * FROM pendingOperation ORDER BY rowid ASC")
        }
    }

    private func insertAccount(
        id: String,
        provider: AccountProvider,
        pool: DatabasePool
    ) async throws {
        try await pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "demotion-test-\(UUID().uuidString)@example.com",
                displayName: "Demotion Test",
                provider: provider
            )
            account.id = id
            try account.insert(db)
        }
    }

    private func withRegisteredProvider(
        accountId: String,
        provider: any EmailProvider,
        operation: () async throws -> Void
    ) async throws {
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId,
            provider: provider
        )
        do {
            try await operation()
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }
    }

    /// Every drain in this suite is timeout-wrapped: the spin guard under test
    /// is exactly what prevents a demoted chain from looping a drain forever,
    /// so a hang here IS the failure mode, and it must fail, not wedge CI.
    private func drainOnce() async throws {
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await AccountManager.shared.drainPendingQueue()
        }
    }

    /// Field-by-field payload comparison of a durable row against its
    /// pre-demotion stored copy — demotion must preserve `id` and every
    /// payload byte (`messageIdsJSON` compared as the exact stored string);
    /// only the rowid position may change, and `status` must be `queued`.
    private func expectSameStoredOperation(
        _ after: PendingOperation?,
        asBefore before: PendingOperation,
        _ label: String
    ) {
        guard let after else {
            Issue.record("\(label): demoted row is missing")
            return
        }
        #expect(after.id == before.id, "\(label): id preserved")
        #expect(after.type == before.type, "\(label): type preserved")
        #expect(after.messageIdsJSON == before.messageIdsJSON, "\(label): member payload byte-identical")
        #expect(after.accountId == before.accountId, "\(label): accountId preserved")
        #expect(after.folderPath == before.folderPath, "\(label): folderPath preserved")
        #expect(after.destinationPath == before.destinationPath, "\(label): destinationPath preserved")
        #expect(after.tagValue == before.tagValue, "\(label): tagValue preserved")
        #expect(after.userLabelId == before.userLabelId, "\(label): userLabelId preserved")
        #expect(after.createdAt == before.createdAt, "\(label): createdAt preserved")
        #expect(after.retryCount == before.retryCount, "\(label): retryCount preserved — demotion is not a retry-budget bump")
        #expect(after.status == PendingStatus.queued.rawValue, "\(label): demoted row is queued")
    }

    // MARK: - Shared liveness assertions (duplicated from AccountManagerQueueLivenessTests)

    /// The STATIC liveness invariants — hold even while the queue still holds
    /// a demoted (still-failing) chain. No permit leak, no stranded waiter,
    /// no leaked drain owner/re-drain flag, and no row left `inFlight`.
    private func assertQueueLivenessInvariants(pool: DatabasePool) async throws {
        #expect(
            !AccountManager.shared.pendingOperationMutationGate.isHeldForTesting,
            "the mutation gate must not be leaked"
        )
        #expect(
            AccountManager.shared.pendingOperationMutationGate.waiterCountForTesting == 0,
            "no waiter may be stranded on the mutation gate"
        )
        #expect(
            await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
            "no drain owner or re-drain flag may be leaked"
        )
        let inFlightCount = try await pool.read { db in
            try PendingOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchCount(db)
        }
        #expect(inFlightCount == 0, "no row may be left stranded inFlight")
    }

    // MARK: - 1. RED → GREEN: unrelated work is unblocked by demotion

    @Test("a persistent Gmail 400 demotes the failing message's chain to the tail — same-account and other-account work behind it completes")
    func persistentGmailFailureDemotesChainAndUnblocksUnrelatedWork() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let gmailAccountId = "acc-demote-gmail-\(suffix)"
        let otherAccountId = "acc-demote-other-\(suffix)"
        let rfcA = "demote-a-\(suffix)@example.com"
        let gmailA = "gmail-a-\(suffix)"
        let rfcB = "demote-b-\(suffix)@example.com"
        let gmailB = "gmail-b-\(suffix)"
        let rfcC = "demote-c-\(suffix)@example.com"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfcA, providerMessageId: gmailA, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: rfcB, providerMessageId: gmailB, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.injectUnclassified400(providerMessageId: gmailA)
        let gmailProvider = server.provider()
        let otherProvider = MockEmailProvider()

        try await insertAccount(id: gmailAccountId, provider: .gmail, pool: pool)

        // The failing message A's CHAIN: two ops on the same message.
        let opA1 = PendingOperation(type: .markRead, messageIds: [rfcA], accountId: gmailAccountId, folderPath: "INBOX")
        let opA2 = PendingOperation(type: .markFlagged, messageIds: [rfcA], accountId: gmailAccountId, folderPath: "INBOX")
        // Unrelated work queued BEHIND the chain: same account/different
        // message, and a different account entirely.
        let opB = PendingOperation(
            type: .move, messageIds: [rfcB], accountId: gmailAccountId,
            folderPath: "INBOX", destinationPath: GmailProvider.archivePath
        )
        let opC = PendingOperation(type: .markRead, messageIds: [rfcC], accountId: otherAccountId, folderPath: "INBOX")
        try insertOp(opA1, pool: pool)
        try insertOp(opA2, pool: pool)
        try insertOp(opB, pool: pool)
        try insertOp(opC, pool: pool)
        let opA1Stored = try #require(try fetchOp(opA1.id, pool: pool))
        let opA2Stored = try #require(try fetchOp(opA2.id, pool: pool))

        try await withRegisteredProvider(accountId: gmailAccountId, provider: gmailProvider) {
            try await withRegisteredProvider(accountId: otherAccountId, provider: otherProvider) {
                try await drainOnce()
            }
        }

        // Unrelated work completed this SAME drain (RED today: everything
        // behind A wedges at the frontier).
        #expect(try fetchOp(opB.id, pool: pool) == nil, "B (same account, different message) must complete behind the demoted chain")
        #expect(try fetchOp(opC.id, pool: pool) == nil, "C (other account) must complete behind the demoted chain")
        let bSnapshots = server.snapshots(rfc822MessageId: rfcB)
        #expect(bSnapshots.count == 1)
        #expect(bSnapshots.first.map { !$0.labels.contains("INBOX") } == true, "B's archive reached the provider")
        #expect(await otherProvider.markedReadIds.contains { $0.ids == [rfcC] }, "C's markRead reached its provider")

        // The chain sits at the tail, queued, payloads intact, intra-chain
        // order preserved.
        let remaining = try fetchOpsInRowidOrder(pool: pool)
        #expect(remaining.map(\.id) == [opA1.id, opA2.id], "exactly the chain remains, in original intra-chain order")
        expectSameStoredOperation(remaining.first, asBefore: opA1Stored, "opA1")
        expectSameStoredOperation(remaining.dropFirst().first, asBefore: opA2Stored, "opA2")

        // Exactly one provider attempt for the failing op this drain (spin
        // guard), and the failing message was never mutated remotely.
        #expect(server.unclassified400ServedCount() == 1, "exactly ONE provider attempt for A per drain")
        let aSnapshots = server.snapshots(rfc822MessageId: rfcA)
        #expect(aSnapshots.first.map { $0.labels.contains("UNREAD") } == true, "A stays untouched remotely")
        #expect(
            !server.modifyLog().contains { $0.providerMessageId == gmailA && $0.addLabelIds.contains("STARRED") },
            "the chain's second op (markFlagged) must never reach the provider while its chain is failing"
        )

        // A blocked-at-the-tail chain must still leave a LIVE queue.
        try await assertQueueLivenessInvariants(pool: pool)
    }

    // MARK: - 2. RED → GREEN: recovery canary (GAP-7)

    @Test("clearing the persistent failure lets the next drain complete the demoted chain in intra-chain order")
    func demotedChainCompletesInOrderOnceFailureClears() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-demote-recover-\(suffix)"
        let rfcA = "demote-recover-\(suffix)@example.com"
        let gmailA = "gmail-recover-\(suffix)"
        let rfcB = "demote-recover-b-\(suffix)@example.com"
        let gmailB = "gmail-recover-b-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfcA, providerMessageId: gmailA, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: rfcB, providerMessageId: gmailB, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.injectUnclassified400(providerMessageId: gmailA)
        let provider = server.provider()

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let opA1 = PendingOperation(type: .markRead, messageIds: [rfcA], accountId: accountId, folderPath: "INBOX")
        let opA2 = PendingOperation(type: .markFlagged, messageIds: [rfcA], accountId: accountId, folderPath: "INBOX")
        // Unrelated op behind the chain: today (RED) it wedges behind the
        // transiently-blocking frontier; demotion lets it complete in drain 1.
        let opB = PendingOperation(type: .markRead, messageIds: [rfcB], accountId: accountId, folderPath: "INBOX")
        try insertOp(opA1, pool: pool)
        try insertOp(opA2, pool: pool)
        try insertOp(opB, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await drainOnce()
            #expect(try fetchOp(opB.id, pool: pool) == nil, "the unrelated op behind the chain completed in drain 1")
            #expect(try fetchOpsInRowidOrder(pool: pool).map(\.id) == [opA1.id, opA2.id], "the chain was demoted, not dropped")
            #expect(server.unclassified400ServedCount() == 1)

            // GAP-7 recovery canary: the provider-side condition resolves.
            server.clearUnclassified400s()
            try await drainOnce()
        }

        #expect(try fetchOpsInRowidOrder(pool: pool).isEmpty, "the demoted chain completed and left the queue")
        let aSnapshots = server.snapshots(rfc822MessageId: rfcA)
        #expect(aSnapshots.count == 1)
        #expect(aSnapshots.first?.isRead == true, "A-markRead applied")
        #expect(aSnapshots.first?.isFlagged == true, "A-markFlagged applied")
        // Provider observed A-markRead BEFORE A-markFlagged: the attempt log
        // is [failed markRead, successful markRead, successful markFlagged].
        let aModifies = server.modifyLog().filter { $0.providerMessageId == gmailA }
        #expect(aModifies.count == 3, "one failed + two successful modify attempts")
        #expect(aModifies.first?.removeLabelIds == ["UNREAD"])
        #expect(aModifies.dropFirst().first?.removeLabelIds == ["UNREAD"], "markRead retried FIRST after recovery")
        #expect(aModifies.last?.addLabelIds == ["STARRED"], "markFlagged followed markRead — intra-chain order held")

        try await assertQueueLivenessInvariants(pool: pool)
    }

    // MARK: - 3. Spin guard: one provider attempt per drain, drain terminates

    @Test("a lone failing chain produces exactly ONE provider attempt per drain — requeued untouched, drain stops, later drains behave identically")
    func demotedChainProducesExactlyOneProviderAttemptPerDrain() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-demote-spin-\(suffix)"
        let rfcA = "demote-spin-\(suffix)@example.com"
        let gmailA = "gmail-spin-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: rfcA, providerMessageId: gmailA, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.injectUnclassified400(providerMessageId: gmailA)
        let provider = server.provider()

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let opA1 = PendingOperation(type: .markRead, messageIds: [rfcA], accountId: accountId, folderPath: "INBOX")
        let opA2 = PendingOperation(type: .markFlagged, messageIds: [rfcA], accountId: accountId, folderPath: "INBOX")
        try insertOp(opA1, pool: pool)
        try insertOp(opA2, pool: pool)
        let opA1Stored = try #require(try fetchOp(opA1.id, pool: pool))
        let opA2Stored = try #require(try fetchOp(opA2.id, pool: pool))

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            // Drain 1: exactly one provider attempt, then the demoted frontier
            // is requeued untouched and the drain terminates (drainOnce's
            // timeout is the terminate-proof — a spin would hang it).
            try await drainOnce()
            #expect(server.unclassified400ServedCount() == 1, "exactly one provider attempt in drain 1")
            #expect(server.modifyLog().count == 1, "no other modify (markFlagged) was ever attempted")
            var rows = try fetchOpsInRowidOrder(pool: pool)
            #expect(rows.map(\.id) == [opA1.id, opA2.id])
            expectSameStoredOperation(rows.first, asBefore: opA1Stored, "opA1 after drain 1")
            expectSameStoredOperation(rows.dropFirst().first, asBefore: opA2Stored, "opA2 after drain 1")
            try await assertQueueLivenessInvariants(pool: pool)

            // Drain 2 (still failing): one MORE attempt — the retry cadence is
            // one per external drain trigger, never a loop within one drain.
            try await drainOnce()
            #expect(server.unclassified400ServedCount() == 2, "exactly one additional attempt in drain 2")
            rows = try fetchOpsInRowidOrder(pool: pool)
            #expect(rows.map(\.id) == [opA1.id, opA2.id], "chain intact after repeated failing drains")
            try await assertQueueLivenessInvariants(pool: pool)

            // Clearing the failure completes the chain on a later drain.
            server.clearUnclassified400s()
            try await drainOnce()
        }

        #expect(try fetchOpsInRowidOrder(pool: pool).isEmpty, "the chain completed once the failure cleared")
        let aSnapshots = server.snapshots(rfc822MessageId: rfcA)
        #expect(aSnapshots.first?.isRead == true)
        #expect(aSnapshots.first?.isFlagged == true)
        try await assertQueueLivenessInvariants(pool: pool)
    }

    // MARK: - 4. Chain closure is transitive and same-account; payload bytes survive (queue-level)

    @Test("the demoted chain is the transitive same-account member closure — an overlapping batch drags its other members' ops, unrelated and foreign-account ops complete, payloads stay byte-identical")
    func chainClosureIsTransitiveSameAccountAndPayloadBytesSurviveDemotion() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let mainAccountId = "acc-demote-closure-\(suffix)"
        let foreignAccountId = "acc-demote-foreign-\(suffix)"
        let memberA = "closure-a-\(suffix)@example.com"
        let memberB = "closure-b-\(suffix)@example.com"
        let memberX = "closure-x-\(suffix)@example.com"

        // Queue-level classification seam (Law 5): the adapter cells in
        // GmailProviderMockTests/ExchangeProviderMockTests prove real adapters
        // produce `.persistentActionFailure`; here a mock throws it directly
        // so the closure/payload semantics are tested one level down.
        let mainProvider = MockEmailProvider()
        await mainProvider.setMarkReadThrows(
            ProviderError.persistentActionFailure(underlying: ProviderError.notConnected)
        )
        let foreignProvider = MockEmailProvider()

        // rowid order:                       chain membership
        //   1. opFail    markRead   [A]      seed (fails persistent)
        //   2. opBridge  move       [A,B]    intersects A → chained
        //   3. opX       markFlagged[X]      unrelated same account → completes
        //   4. opTail    markUnread [B]      intersects opBridge's B → transitively chained
        //   5. opForeign markFlagged[A]      SAME member string, OTHER account → completes
        let opFail = PendingOperation(type: .markRead, messageIds: [memberA], accountId: mainAccountId, folderPath: "INBOX")
        let opBridge = PendingOperation(
            type: .move, messageIds: [memberA, memberB], accountId: mainAccountId,
            folderPath: "INBOX", destinationPath: "Archive"
        )
        let opX = PendingOperation(type: .markFlagged, messageIds: [memberX], accountId: mainAccountId, folderPath: "INBOX")
        let opTail = PendingOperation(type: .markUnread, messageIds: [memberB], accountId: mainAccountId, folderPath: "INBOX")
        let opForeign = PendingOperation(type: .markFlagged, messageIds: [memberA], accountId: foreignAccountId, folderPath: "INBOX")
        for op in [opFail, opBridge, opX, opTail, opForeign] {
            try insertOp(op, pool: pool)
        }
        let storedByOpId = Dictionary(
            uniqueKeysWithValues: try fetchOpsInRowidOrder(pool: pool).map { ($0.id, $0) }
        )

        try await withRegisteredProvider(accountId: mainAccountId, provider: mainProvider) {
            try await withRegisteredProvider(accountId: foreignAccountId, provider: foreignProvider) {
                try await drainOnce()
            }
        }

        // Non-chain work completed; the exact transitive chain remains at the
        // tail in its original intra-chain order (opFail, opBridge, opTail).
        let remaining = try fetchOpsInRowidOrder(pool: pool)
        #expect(
            remaining.map(\.id) == [opFail.id, opBridge.id, opTail.id],
            "chain = transitive closure {opFail, opBridge, opTail}, intra-chain order preserved"
        )
        #expect(try fetchOp(opX.id, pool: pool) == nil, "unrelated same-account op completed")
        #expect(try fetchOp(opForeign.id, pool: pool) == nil, "same member string on ANOTHER account is not chained")
        #expect(await mainProvider.markedFlaggedIds.contains { $0.ids == [memberX] })
        #expect(await foreignProvider.markedFlaggedIds.contains { $0.ids == [memberA] })

        // Exactly one provider attempt: the chained ops behind the failing
        // frontier were never attempted.
        #expect(await mainProvider.markedReadIds.count == 1, "one markRead attempt for the failing op")
        #expect(await mainProvider.movedIds.isEmpty, "the chained move was never attempted")
        #expect(await mainProvider.markedUnreadIds.isEmpty, "the transitively chained markUnread was never attempted")

        // Payload byte-equality against the pre-demotion stored copies.
        for (index, id) in [opFail.id, opBridge.id, opTail.id].enumerated() {
            expectSameStoredOperation(
                remaining[safeIndex: index],
                asBefore: try #require(storedByOpId[id]),
                "chain[\(index)]"
            )
        }
        // Undo's newest-related scan is rowid-based: the demoted chain's
        // newest member is still its newest.
        #expect(remaining.last?.id == opTail.id)

        try await assertQueueLivenessInvariants(pool: pool)
    }

    // MARK: - 5. Undo reconciliation still works against demoted rows

    @Test("Undo of a move whose durable row was demoted still annihilates that exact row — newest-related scanning is rowid-based, so demotion is invisible to it")
    func undoReconciliationStillMatchesDemotedRows() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        AccountManager.shared.intentionJournal.resetForTesting()

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-demote-undo-\(suffix)"
        let rfcA = "demote-undo-\(suffix)@example.com"
        let unrelated = "demote-undo-unrelated-\(suffix)@example.com"

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
        try await pool.writeWithoutTransaction { db in
            try inbox.insert(db)
            try archive.insert(db)
        }
        // The message already sits at the forward destination (the optimistic
        // local move applied); only the DURABLE forward move is still queued.
        var header = MessageHeader(
            messageId: "msg-\(suffix)", subject: "Subj", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: archive.id, accountId: accountId, folderPath: archive.path, isInInbox: false
        )
        header.headerComplete = true
        header.rfc822MessageId = "<\(rfcA)>"
        let headerId = header.id
        let insertableHeader = header
        try await pool.writeWithoutTransaction { db in
            try insertableHeader.insert(db)
        }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(
            ProviderError.persistentActionFailure(underlying: ProviderError.notConnected)
        )

        // rowid order: [opFail (chains the move via member A), opX (unrelated),
        // opMove (the forward move Undo will target)].
        let opFail = PendingOperation(type: .markRead, messageIds: [rfcA], accountId: accountId, folderPath: "INBOX")
        let opX = PendingOperation(type: .markFlagged, messageIds: [unrelated], accountId: accountId, folderPath: "INBOX")
        let opMove = PendingOperation(
            type: .move, messageIds: [rfcA], accountId: accountId,
            folderPath: "INBOX", destinationPath: "Archive"
        )
        try insertOp(opFail, pool: pool)
        try insertOp(opX, pool: pool)
        try insertOp(opMove, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            // Demote: chain {opFail, opMove} moves behind opX; opX completes.
            try await drainOnce()
            #expect(
                try fetchOpsInRowidOrder(pool: pool).map(\.id) == [opFail.id, opMove.id],
                "the chain (including the forward move) was demoted to the tail"
            )

            // Undo the forward move through the REAL inverse-command path.
            await AccountManager.shared.undoMove(
                accountId: accountId,
                forwardDestinationPath: "Archive",
                members: [UndoMember(
                    memberIdentity: rfcA,
                    sourceFolderPath: "INBOX",
                    originalHeaderId: headerId
                )]
            )
            // Join the journal fold, then the background drain undoMove fires.
            var iterations = 0
            repeat {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
                }
                iterations += 1
            } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting() && iterations < 200
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                while true {
                    let quiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
                    let rows = try fetchOpsInRowidOrder(pool: pool)
                    if quiescent,
                       rows.map(\.id) == [opFail.id],
                       rows.first?.status == PendingStatus.queued.rawValue {
                        break
                    }
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
        }

        // The demoted forward move was annihilated by Undo's newest-related
        // scan (no inverse row appended — a move inverts by deletion), while
        // the unrelated demoted chain member stays queued and intact.
        let rows = try fetchOpsInRowidOrder(pool: pool)
        #expect(rows.map(\.id) == [opFail.id], "only the still-failing markRead remains — the demoted move was reconciled away, nothing else appeared")
        #expect(rows.first?.messageIds == [rfcA], "the surviving demoted row's payload is untouched")
        #expect(await provider.movedIds.isEmpty, "neither the forward move nor an inverse ever reached the provider")

        // The local inverse applied: the message is back in the inbox.
        let restored = try await pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == accountId && Column("rfc822MessageId") == "<\(rfcA)>")
                .fetchAll(db)
        }
        #expect(restored.count == 1)
        #expect(restored.first?.folderPath == "INBOX", "Undo's local inverse move landed")
        #expect(restored.first?.isInInbox == true)

        try await assertQueueLivenessInvariants(pool: pool)
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    // MARK: - 6. R2 audit: persistent-400 classification gaps (2026-07-15)
    //
    // Two action-path request sites (`GmailProvider.resolveTokenMember` and
    // `ExchangeProvider.resolveActionMessageId`'s first-page fetch) used the
    // plain body-discarding `request` helper, so a structured 400 arrived as
    // a bodyless `.networkError` — classified plain transient instead of
    // `.persistentActionFailure`, wedging the FIFO forever instead of
    // demoting. These three cells pin the fix.

    @Test("a Gmail token member whose exact-ID GET returns an UNRECOGNIZED structural 400 demotes the op to the tail — unrelated later work completes")
    func gmailTokenMemberUnclassifiedGet400DemotesChain() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-demote-token-get-\(suffix)"
        // Provider-token shape (no "@") — MessageIdentity.durableMemberKind
        // classifies this as `.providerToken`, exercising resolveTokenMember
        // (exact-ID GET) rather than resolveActionMessageId's RFC search.
        let tokenA = "gmail-token-a-\(suffix)"
        let rfcB = "demote-token-b-\(suffix)@example.com"
        let gmailB = "gmail-token-b-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: "unused-\(suffix)@example.com", providerMessageId: tokenA, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: rfcB, providerMessageId: gmailB, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.injectUnclassified400OnGet(providerMessageId: tokenA)
        let provider = server.provider()

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)

        let opA = PendingOperation(type: .markRead, messageIds: [tokenA], accountId: accountId, folderPath: "INBOX")
        let opB = PendingOperation(type: .markRead, messageIds: [rfcB], accountId: accountId, folderPath: "INBOX")
        try insertOp(opA, pool: pool)
        try insertOp(opB, pool: pool)
        let opAStored = try #require(try fetchOp(opA.id, pool: pool))

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await drainOnce()
        }

        // Unrelated work completed this SAME drain (RED today: B wedges
        // behind A's plain-transient bodyless failure).
        #expect(try fetchOp(opB.id, pool: pool) == nil, "B (unrelated member) must complete behind the demoted token-member op")
        let bSnapshots = server.snapshots(rfc822MessageId: rfcB)
        #expect(bSnapshots.first?.isRead == true, "B's markRead reached the provider")

        // A sits at the tail, queued, payload intact — demoted, not dropped
        // and not left wedging the frontier.
        let remaining = try fetchOpsInRowidOrder(pool: pool)
        #expect(remaining.map(\.id) == [opA.id], "exactly the failing op remains, demoted to the tail")
        expectSameStoredOperation(remaining.first, asBefore: opAStored, "opA")

        #expect(server.unclassified400OnGetServedCount() == 1, "exactly ONE provider attempt for A per drain (spin guard)")

        try await assertQueueLivenessInvariants(pool: pool)
    }

    @Test("a Gmail token member whose exact-ID GET returns Gmail's 'Invalid id value' 400 resolves as an authoritative stale no-op — no server mutation, later ops run")
    func gmailTokenMemberInvalidIdGet400IsAuthoritativeStaleNoOp() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-demote-token-invalid-\(suffix)"
        let tokenA = "gmail-token-invalid-a-\(suffix)"
        let untouchedRFC = "unused-\(suffix)@example.com"
        let rfcB = "demote-token-invalid-b-\(suffix)@example.com"
        let gmailB = "gmail-token-invalid-b-\(suffix)"

        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: untouchedRFC, providerMessageId: tokenA, labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: rfcB, providerMessageId: gmailB, labels: ["INBOX", "UNREAD"]),
        ])
        defer { server.close() }
        server.injectInvalidIdOnGet(providerMessageId: tokenA)
        let provider = server.provider()

        try await insertAccount(id: accountId, provider: .gmail, pool: pool)

        let opA = PendingOperation(type: .markRead, messageIds: [tokenA], accountId: accountId, folderPath: "INBOX")
        let opB = PendingOperation(type: .markRead, messageIds: [rfcB], accountId: accountId, folderPath: "INBOX")
        try insertOp(opA, pool: pool)
        try insertOp(opB, pool: pool)

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await drainOnce()
        }

        // A completed as an authoritative stale NO-OP (RED today: a bodyless
        // 400 is plain transient, so A stays queued at the frontier and B
        // never runs).
        #expect(try fetchOp(opA.id, pool: pool) == nil, "A completed as a no-op — an id Gmail itself rejects can never resolve")
        let aSnapshots = server.snapshots(rfc822MessageId: untouchedRFC)
        #expect(aSnapshots.first.map { $0.labels.contains("UNREAD") } == true, "A's remote copy is untouched — no modify ever reached the provider")
        #expect(!server.modifyLog().contains { $0.providerMessageId == tokenA }, "no modify attempt for A — it never got past resolution")

        #expect(try fetchOp(opB.id, pool: pool) == nil, "B completed in the same drain")
        let bSnapshots = server.snapshots(rfc822MessageId: rfcB)
        #expect(bSnapshots.first?.isRead == true)

        try await assertQueueLivenessInvariants(pool: pool)
    }

    @Test("an Exchange RFC member whose source-folder \\$filter search returns an UNRECOGNIZED structural 400 demotes the op to the tail — unrelated later work completes")
    func exchangeRFCMemberUnclassifiedFilterSearch400DemotesChain() async throws {
        let (pool, dir, previous) = try await makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let suffix = UUID().uuidString.lowercased()
        let accountId = "acc-demote-exchange-filter-\(suffix)"
        let rfcA = "demote-exchange-filter-a-\(suffix)@example.com"
        let graphA = "graph-filter-a-\(suffix)"
        let rfcB = "demote-exchange-filter-b-\(suffix)@example.com"
        let graphB = "graph-filter-b-\(suffix)"
        let inboxFolderId = "inbox-\(suffix)"

        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: rfcA, providerMessageId: graphA, folderId: inboxFolderId),
            .init(rfc822MessageId: rfcB, providerMessageId: graphB, folderId: inboxFolderId),
        ])
        defer { server.close() }
        server.injectUnclassified400OnFilterSearch(rfc822MessageId: rfcA)
        let provider = server.provider()

        try await insertAccount(id: accountId, provider: .outlook, pool: pool)

        let opA = PendingOperation(type: .markRead, messageIds: [rfcA], accountId: accountId, folderPath: inboxFolderId)
        let opB = PendingOperation(type: .markRead, messageIds: [rfcB], accountId: accountId, folderPath: inboxFolderId)
        try insertOp(opA, pool: pool)
        try insertOp(opB, pool: pool)
        let opAStored = try #require(try fetchOp(opA.id, pool: pool))

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await drainOnce()
        }

        // Unrelated work completed this SAME drain (RED today: B wedges
        // behind A's plain-transient bodyless failure).
        #expect(try fetchOp(opB.id, pool: pool) == nil, "B (unrelated member) must complete behind the demoted chain")
        let bSnapshots = server.snapshots(rfc822MessageId: rfcB)
        #expect(bSnapshots.first?.isRead == true, "B's markRead reached the provider")

        let remaining = try fetchOpsInRowidOrder(pool: pool)
        #expect(remaining.map(\.id) == [opA.id], "exactly the failing op remains, demoted to the tail")
        expectSameStoredOperation(remaining.first, asBefore: opAStored, "opA")

        #expect(server.unclassified400ServedCount() == 1, "exactly ONE provider attempt for A per drain (spin guard)")

        try await assertQueueLivenessInvariants(pool: pool)
    }
}

/// Bounds-checked subscript used by the payload-equality loop — a failed
/// count expectation must not crash the test process on out-of-bounds access
/// (CLAUDE.md Testing Rule 9).
private extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
