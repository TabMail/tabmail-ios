/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A message a change read proved gone never comes back from a header another
/// path read before that proof (#755), and a standalone folder listing never
/// runs between a change read and its apply (the account's sync turn). Driven
/// through the engine's own entry points against `FakeIMAPServer`, with a
/// command held on the wire to place each race deterministically.
@Suite("IMAP change reads: the turn and the from-server insert guard", .serialized, .processGlobalState)
struct IMAPChangeTurnAndGuardTests {
    typealias E = IMAPChangeEngineTests
    typealias C = IMAPChangeCondstoreTests

    /// How long a held race may take to show its first step; a bound, never a sleep.
    static let raceBoundSeconds: TimeInterval = 10
    /// How long a waiter is watched for NOT starting while the turn is held.
    static let quietWatchSeconds: TimeInterval = 1

    final class Done: Sendable { let flag = Mutex(false) }
    final class Finished: Sendable { let count = Mutex(0) }

    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(raceBoundSeconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("the race's step never happened"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("T15: load older holds a page whose message a change read proves gone meanwhile: the message is not re-created, and the call reports more to load")
    func loadOlderNeverRecreatesAProvenGoneMessage() async throws {
        try await E.withWorld("cs-t15", capabilities: C.condstore, serverUIDs: Array(1...6), localUIDs: [4, 5, 6]) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let folder = try w.folder()
            w.server.holdNextFetchAfterSnapshot(in: E.path)
            let older = Task { try await w.engine.fetchOlderMessages(folders: [folder]) }
            try await Self.waitUntil { w.server.isHoldingFetchAfterSnapshot(in: E.path) }
            // Expunged elsewhere while the page's answer is held; the change read
            // commits a new bookmark for the folder.
            C.remove([2], from: w.server, E.path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            w.server.releaseFetchAfterSnapshot(in: E.path)
            let result = try await older.value
            #expect(!(try w.uids()).contains("2"), "a message proven gone is not re-created")
            #expect(result.mayHaveMore, "the refused page is asked again: never 'no older mail'")
            // Converges: the next call loads the live older messages and no ghost.
            _ = try await w.engine.fetchOlderMessages(folders: [try w.folder()])
            let rows = try w.uids()
            #expect(rows.contains("1") && rows.contains("3") && !rows.contains("2"), "rows: \(rows.sorted())")
        }
    }

    @Test("T16: a standalone folder listing started while a change pass reads waits for that pass's turn, and both complete")
    func standaloneListingWaitsForTheChangePass() async throws {
        try await E.withWorld("cs-t16", capabilities: C.qresync, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]) { w in
            w.server.honorSearchUIDSetCriterion()
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            w.server.setFlags(["\\Seen"], in: E.path, uid: 1)
            w.server.holdNextCommand(containing: "(QRESYNC (")
            // The production entry point, which takes the account's sync turn
            // (`performDeltaSync` is the pass body, called inside it).
            let pass = Task { try await w.engine.backgroundDeltaSync(account: w.account) }
            try await Self.waitUntil { w.server.isHoldingCommand(containing: "(QRESYNC (") }
            let start = w.server.recordedCommands().count
            let folder = try w.folder()
            let listing = Task { try await w.engine.syncFolderMessages(folder: folder, provider: w.provider) }
            try await Task.sleep(nanoseconds: UInt64(Self.quietWatchSeconds * 1_000_000_000))
            let duringRead = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("FETCH") }
            #expect(duringRead.isEmpty, "no listing ran between the change read and its apply: \(Array(duringRead))")
            w.server.releaseHeldCommand(containing: "(QRESYNC (")
            _ = try await pass.value
            _ = try await listing.value
            #expect(try w.uids() == ["1", "2", "3"])
        }
    }

    @Test("T17: a folder listing started by a task that holds the account's turn runs in that turn (re-entrant), never deadlocks")
    func nestedListingInsideTheTurnCompletes() async throws {
        try await E.withWorld("cs-t17", capabilities: C.condstore, serverUIDs: [1, 2, 3], localUIDs: [1, 2]) { w in
            let folder = try w.folder()
            let done = Done()
            // Never awaited: a deadlock must fail the test, not hang the suite.
            Task {
                _ = try? await w.engine.oneSyncAtATime(accountId: w.account.id) {
                    try await w.engine.syncFolderMessages(folder: folder, provider: w.provider)
                }
                done.flag.withLock { $0 = true }
            }
            try await Self.waitUntil { done.flag.withLock { $0 } }
            #expect(try w.uids().contains("3"), "the nested listing ran and loaded the new message")
        }
    }

    @Test("A task spawned inside a held turn is not the turn's holder: its own turn waits until the pass ends")
    func spawnedTaskWaitsForTheTurn() async throws {
        try await E.withWorld("cs-turn-spawn", capabilities: C.condstore, serverUIDs: [1], localUIDs: [1]) { w in
            let ran = Done()
            let spawned: Task<Void, Never> = await w.engine.oneSyncAtATime(accountId: w.account.id) {
                let child = Task {
                    await w.engine.oneSyncAtATime(accountId: w.account.id) { ran.flag.withLock { $0 = true } }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.quietWatchSeconds * 1_000_000_000))
                #expect(!ran.flag.withLock { $0 }, "the spawned task ran inside the pass's turn")
                return child
            }
            await spawned.value
            #expect(ran.flag.withLock { $0 }, "it runs once the pass ends")
        }
    }

    /// Asserts only the catch-up's requests (its `(UID FLAGS)` fetches). The worker's walk runs
    /// outside the turn on main by design; its writes are covered by the from-server insert guard.
    @Test("The backfill worker started from inside a sync pass takes the turn: no catch-up request goes out while the pass holds it")
    func backfillWorkerStartedInAPassWaitsForTheTurn() async throws {
        try await E.withWorld("cs-turn-backfill", capabilities: E.condstoreOnly, serverUIDs: Array(1...6), localUIDs: [4, 5, 6]) { w in
            defer { Task { await w.engine.resetBackfill(accountId: w.account.id) } }
            let (start, during): (Int, Int) = await w.engine.oneSyncAtATime(accountId: w.account.id) {
                let start = w.server.recordedCommands().count
                await w.engine.startBackfill(account: w.account)
                try? await Task.sleep(nanoseconds: UInt64(Self.quietWatchSeconds * 1_000_000_000))
                return (start, w.server.recordedCommands().count)
            }
            let sent = w.server.recordedCommands()[start..<during].filter { $0.uppercased().contains("(UID FLAGS)") }
            #expect(sent.isEmpty, "the catch-up's requests interleaved with the pass holding the turn: \(Array(sent))")
            try await Self.waitUntil { w.server.recordedCommands().count > during }
        }
    }

    /// More post-send finalisations than the IMAP work queue has slots.
    static let postSendBurst = SyncConfig.imapMaxConnectionCeiling + 1
    /// How long the held pass and the burst may take to finish once released:
    /// past the stuck-wait watch's bound, so a wedge is reported by the watch
    /// (and released by it) before this test gives up.
    static let burstBoundSeconds = SyncConfig.syncTurnWaitTestBoundSeconds * 2

    /// No account-wide wedge: a foreground pass holds the account's sync turn
    /// while a burst of completed sends is finalised (crash recovery,
    /// `reconcileOutbox`). Each finalisation lists the Sent folder, which waits
    /// for the turn. With a work-queue slot held around that wait, the burst
    /// filled the queue and the pass's next request never got a slot. The
    /// engine and the drains share one queue, as `connectAccount` sets them up.
    @Test("A pass holding the turn while more sends are finalised than the work queue has slots: the pass and every finalisation complete")
    func postSendBurstDuringAHeldPassNeverWedgesTheAccount() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "post-send-burst"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Sent", role: .sent, pool: pool)
        let server = FakeIMAPServer(mailboxes: ["INBOX": [1, 2, 3].map(IMAPChangeReaderTests.message), "Sent": []])
        try server.start()
        defer { server.stop() }
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        await AccountManager.shared.connectProviderForTesting(account: account, provider: imap)
        defer { Task { await AccountManager.shared.disconnectProviderForTesting(accountId: accountId) } }
        let engine = await AccountManager.shared.syncEngine

        for index in 0..<Self.postSendBurst {
            var sent = OutboxMessage(
                accountId: accountId,
                draft: DraftMessage(to: ["recipient@example.com"], subject: "burst \(index)", body: "sent already"))
            sent.status = OutboxStatus.sending.rawValue
            sent.sentAt = Date()
            sent.appendedToSent = true
            let row = sent
            try await pool.write { db in try row.insert(db) }
        }

        // The pass holds the turn, parked inside its change read (a STATUS, in
        // a work-queue slot); its full sync and maintenance still need slots.
        server.holdNextCommand(containing: "STATUS")
        let passDone = Done()
        let pass = Task {
            _ = try? await engine.sync(account: account)
            passDone.flag.withLock { $0 = true }
        }
        try await Self.waitUntil { server.isHoldingCommand(containing: "STATUS") }

        await AccountManager.shared.reconcileOutbox()
        try await Self.waitUntil { (try? pool.read { db in try OutboxMessage.fetchCount(db) }) == 0 }
        // Each finalisation's Sent listing is started and waiting for the turn.
        try await Task.sleep(nanoseconds: UInt64(Self.quietWatchSeconds * 1_000_000_000))
        server.releaseHeldCommand(containing: "STATUS")

        let deadline = Date().addingTimeInterval(Self.burstBoundSeconds)
        func settled() async -> Bool {
            guard passDone.flag.withLock({ $0 }) else { return false }
            let running = await engine.syncPassRunning.isEmpty
            let waiting = await engine.syncPassWaiters.isEmpty
            // Every finalisation's Sent listing reached the server.
            let sentSelects = server.recordedCommands().filter {
                let u = $0.uppercased(); return u.contains("SELECT") && u.contains("SENT")
            }.count
            return running && waiting && sentSelects >= Self.postSendBurst
        }
        while !(await settled()), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(passDone.flag.withLock { $0 }, "the pass holding the turn never finished: the account is wedged")
        #expect(await settled(), "not every finalisation listed the Sent folder: the account is wedged")
        if passDone.flag.withLock({ $0 }) { await pass.value }
    }

    /// How long a full sync over one quarantined folder may take before it
    /// counts as stuck (a bound, never a sleep).
    static let quarantinedFullSyncBoundSeconds: TimeInterval = 20

    @Test("A full sync over a quarantined folder finishes within its bound and its turnover reaction ran (the reaction's resync lists inside the pass's turn)")
    func fullSyncReDrivesAQuarantinedFolderWithoutDeadlock() async throws {
        let oldEpoch = 755_001
        let newEpoch = 755_002
        let server = FakeIMAPServer(mailboxes: ["INBOX": [IMAPChangeReaderTests.message(1)]])
        server.setUidValidity(newEpoch, for: "INBOX")
        try server.start()
        defer { server.stop() }
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "cs-quarantine-fullsync"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool, totalCount: 1, lastKnownUidValidity: oldEpoch)
        try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: "INBOX", uids: [301], pool: pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?", arguments: [Date(), "\(accountId):INBOX"])
        }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        let engine = await AccountManager.shared.syncEngine
        let done = Done()
        await TestProviderRegistry.withRegisteredProvider(accountId: accountId, provider: provider) {
            // Never awaited: a deadlock must fail the test by its bound, not hang the suite.
            Task {
                _ = try? await engine.oneSyncAtATime(accountId: accountId) {
                    try await engine.fullSync(account: account, provider: provider)
                }
                done.flag.withLock { $0 = true }
            }
            let deadline = Date().addingTimeInterval(Self.quarantinedFullSyncBoundSeconds)
            while !done.flag.withLock({ $0 }), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(done.flag.withLock { $0 }, "the full sync did not finish within its bound: deadlocked on the turn")
        let folder = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        #expect(folder?.uidValidityResetPendingAt == nil && folder?.lastKnownUidValidity == newEpoch, "the reaction ran and completed")
    }

    enum TurnFuzz {
        static let iterations = 4
        static let seed: UInt64 = 0x0755_7017_0000_0001
        static let tasksPerIteration = 6
        static let latencyMaxMilliseconds = 5
    }

    @Test("T17 fuzz: seeded mixes of nested listings, standalone listings and change passes, with seeded latency, all complete and converge to the server's folder")
    func turnFuzzNeverDeadlocksAndConverges() async throws {
        for iteration in 0..<TurnFuzz.iterations {
            var rng = SplitMix64(seed: TurnFuzz.seed &+ UInt64(iteration))
            let label = "seed=0x\(String(TurnFuzz.seed, radix: 16)) iteration=\(iteration)"
            try await E.withWorld("cs-t17f-\(iteration)", capabilities: C.condstore, serverUIDs: Array(1...6), localUIDs: [4, 5, 6]) { w in
                w.server.honorSearchUIDSetCriterion()
                w.server.setSeededLatencyInjection(seed: TurnFuzz.seed &+ UInt64(iteration) &* 31, maxMilliseconds: TurnFuzz.latencyMaxMilliseconds)
                let folder = try w.folder()
                let kinds = (0..<TurnFuzz.tasksPerIteration).map { _ in Int.random(in: 0..<4, using: &rng) }
                let finished = Finished()
                for kind in kinds {
                    // Never awaited: a deadlock must fail the test, not hang the suite.
                    Task {
                        switch kind {
                        case 0:
                            _ = try? await w.engine.oneSyncAtATime(accountId: w.account.id) {
                                try await w.engine.syncFolderMessages(folder: folder, provider: w.provider)
                            }
                        case 1: _ = try? await w.engine.syncFolderMessages(folder: folder, provider: w.provider)
                        // The production pass entry points, which take the turn.
                        case 2: _ = try? await w.engine.backgroundDeltaSync(account: w.account)
                        default: _ = try? await w.engine.sync(account: w.account)
                        }
                        finished.count.withLock { $0 += 1 }
                    }
                }
                try await Self.waitUntil { finished.count.withLock { $0 } == kinds.count }
                #expect(finished.count.withLock { $0 } == kinds.count, "\(label): every task completed (\(kinds))")
                // One more change pass through the production entry, and no repair
                // listing: a listing would re-list the folder and hide what the
                // overlapping tasks left behind.
                _ = try await w.engine.backgroundDeltaSync(account: w.account)
                let rows = try w.uids()
                #expect(Set(["4", "5", "6"]).isSubset(of: rows), "\(label): no live message lost: \(rows.sorted())")
                #expect(rows.isSubset(of: Set((1...6).map(String.init))), "\(label): no row the server does not hold: \(rows.sorted())")
            }
        }
    }
}
