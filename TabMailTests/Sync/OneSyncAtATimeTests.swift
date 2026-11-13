/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// THE PROPERTY: one sync at a time per account. A delta and a full sync of one
/// account are never in flight together, whichever entry point started them; a
/// pass that arrives while another runs waits its turn and then runs; and a pass
/// that throws still hands the turn on. Passes waiting their turn each run, one
/// at a time, in arrival order, and the turn is per account. A pass never acts on
/// account sync state its caller read before its turn: a pass that waited never
/// clears or overwrites a cursor a pass ahead of it wrote, and never runs a full
/// sync that pass already ran.
///
/// The first two drive production `SyncEngine.sync(account:)` and
/// `SyncEngine.backgroundDeltaSync(account:)` end to end on `FakeHTTP` with a
/// real `GmailProvider`, a real `DatabasePool` and Gmail's real work-queue width,
/// so the work queue's own slots cannot serialize anything. The delta's
/// `history` request and the full sync's Inbox window listing are parked so that,
/// without the semaphore, the first pass reaches its full sync while the second
/// pass's delta is still waiting for its answer. The last two drive the turn
/// itself (`SyncEngine.oneSyncAtATime`) with passes that hold it until released.
@Suite("One sync at a time per account", .serialized, .processGlobalState)
struct OneSyncAtATimeTests {
    private static let accountId = "one-sync-gmail"
    /// How long a parked request waits for the event it is parked on.
    private static let parkCap: DispatchTimeInterval = .seconds(1)

    /// What the fake server saw: requests of each kind in flight, and whether a
    /// request of one kind arrived while the other kind was in flight. A full
    /// sync is seen by its Inbox window listing (`isWindowListing`): the change
    /// read also asks for the label list, so `labels` no longer marks one.
    final class Wire: Sendable {
        struct State {
            var historyRequests = 0
            var listingRequests = 0
            var historyInFlight = 0
            var listingsInFlight = 0
            var overlapped = false
            var historyAfterFirstListing = false
        }
        let state = Mutex(State())
        /// Signalled when the second `history` request arrives.
        let secondHistory = DispatchSemaphore(value: 0)
        /// Signalled when a window listing (a full sync) arrives.
        let listing = DispatchSemaphore(value: 0)

        var snapshot: State { state.withLock { $0 } }
    }

    private static func withAppDB(_ body: (DatabasePool) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await body(pool)
    }

    /// A Gmail account with a cursor and, by default, no full sync yet, so every
    /// foreground pass runs its delta and then its full sync.
    private static func makeAccount(
        pool: DatabasePool, lastFullSyncAt: Date? = nil, lastSyncedAt: Date? = nil
    ) throws -> Account {
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "One sync", provider: .gmail)
        account.id = accountId
        account.lastHistoryId = "1000"
        account.lastFullSyncAt = lastFullSyncAt
        account.lastSyncedAt = lastSyncedAt
        let toInsert = account
        try pool.write { db in
            try toInsert.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
        }
        return account
    }

    /// The full sync's window listing of the Inbox: an unbounded first page of
    /// the window's size (a catch-up list carries a query, a later page a token,
    /// and the backfill walk's id pages are its own chunk size).
    static func isWindowListing(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return url.lastPathComponent == "messages"
            && items.contains { $0.name == "labelIds" && $0.value == "INBOX" }
            && items.contains { $0.name == "maxResults" && $0.value == String(SyncConfig.syncMessageLimit) }
            && !items.contains { $0.name == "q" || $0.name == "pageToken" }
    }

    /// The first `history` request waits for a second one (another pass's delta)
    /// before it answers; every later one waits for a window listing (a full
    /// sync). Each wait ends at `parkCap`. `listingStatus` answers the full
    /// sync's Inbox listing.
    private static func scenario(wire: Wire, listingStatus: Int = 200) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        scenario.register(path: "/history", method: "GET") { _ in
            let order: Int = wire.state.withLock { state in
                state.historyRequests += 1
                if state.listingsInFlight > 0 { state.overlapped = true }
                if state.listingRequests > 0 { state.historyAfterFirstListing = true }
                state.historyInFlight += 1
                return state.historyRequests
            }
            if order == 2 { wire.secondHistory.signal() }
            return .parked {
                _ = (order == 1 ? wire.secondHistory : wire.listing).wait(timeout: .now() + parkCap)
                wire.state.withLock { $0.historyInFlight -= 1 }
                return .json(raw: #"{ "historyId": "1000" }"#)
            }
        }
        scenario.register(path: "/labels", method: "GET", response: .json(
            raw: #"{ "labels": [ { "id": "INBOX", "name": "INBOX", "type": "system" } ] }"#))
        scenario.register(path: "/messages", method: "GET") { request in
            guard Self.isWindowListing(request.url) else { return .json(raw: #"{ "resultSizeEstimate": 0 }"#) }
            wire.state.withLock { state in
                state.listingRequests += 1
                if state.historyInFlight > 0 { state.overlapped = true }
                state.listingsInFlight += 1
            }
            wire.listing.signal()
            return .parked {
                Thread.sleep(forTimeInterval: 0.1)
                wire.state.withLock { $0.listingsInFlight -= 1 }
                guard listingStatus == 200 else { return .status(listingStatus) }
                return .json(raw: #"{ "resultSizeEstimate": 0 }"#)
            }
        }
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "one-sync-gmail@example.com", "historyId": "2000" }"#))
        return scenario
    }

    private static func engine(provider: GmailProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.gmailWorkQueueConcurrency))
        return engine
    }

    /// Waits, bounded, until the fake server has seen `count` history requests.
    private static func waitForHistoryRequests(_ count: Int, wire: Wire, seconds: Double = 10) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if wire.snapshot.historyRequests >= count { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    enum SecondPass: String, CaseIterable, Sendable {
        /// Another foreground pass (poll, pull to refresh, Settings).
        case foreground
        /// A background delta (push wake, background refresh).
        case backgroundDelta
    }

    /// RED on main: the work queue let the first pass's full sync run while the
    /// second pass's delta was in flight. A background delta then runs its delta;
    /// a foreground pass finds, on the row as it is when its turn starts, that the
    /// first pass synced moments ago, and runs neither a delta nor a second full
    /// sync (RED while it decided on its caller's copy).
    @Test("A second pass waits until the first pass's full sync is done", arguments: SecondPass.allCases)
    func secondPassWaitsForTheFirst(second: SecondPass) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let wire = Wire()
            let scenario = Self.scenario(wire: wire)
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await Self.engine(provider: provider)

            let first = Task { try await engine.sync(account: account) }
            #expect(try await Self.waitForHistoryRequests(1, wire: wire), "precondition: the first pass's delta started")
            let secondTask = Task {
                switch second {
                case .foreground: _ = try await engine.sync(account: account)
                case .backgroundDelta: _ = try await engine.backgroundDeltaSync(account: account)
                }
            }
            _ = try await first.value
            switch second {
            case .backgroundDelta:
                // Bounded, so a turn that is never handed on fails here instead of hanging the suite.
                #expect(try await Self.waitForHistoryRequests(2, wire: wire), "the second pass never ran")
                if wire.snapshot.historyRequests == 2 { try await secondTask.value }
            case .foreground:
                let finished = await Self.eventually {
                    let free = await engine.syncPassRunning.isEmpty
                    let waiting = await engine.syncPassWaiters[Self.accountId]
                    return free && waiting == nil
                }
                #expect(finished, "the second pass never took its turn")
                if finished { try await secondTask.value }
            }

            let seen = wire.snapshot
            #expect(!seen.overlapped, "a delta and a full sync of one account were in flight together")
            #expect(seen.listingRequests == 1, "the first pass ran the full sync, and only it")
            switch second {
            case .backgroundDelta:
                #expect(seen.historyRequests == 2, "both passes must run their delta (none is skipped or joined)")
                #expect(seen.historyAfterFirstListing, "the second pass's delta must start after the first pass's full sync")
            case .foreground:
                #expect(seen.historyRequests == 1, "a pass that waited behind a pass that has just synced syncs again")
            }
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// A pass whose full sync throws must still hand the turn on, or every later
    /// pass of the account waits for ever.
    @Test("A pass that throws hands the turn to the next pass")
    func throwingPassHandsTheTurnOn() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let wire = Wire()
            let scenario = Self.scenario(wire: wire, listingStatus: 400)
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await Self.engine(provider: provider)

            let first = Task { try await engine.sync(account: account) }
            #expect(try await Self.waitForHistoryRequests(1, wire: wire), "precondition: the first pass's delta started")
            let secondTask = Task { _ = try? await engine.backgroundDeltaSync(account: account) }

            await #expect(throws: (any Error).self, "precondition: the first pass's full sync throws") {
                _ = try await first.value
            }
            #expect(try await Self.waitForHistoryRequests(2, wire: wire),
                    "the pass waiting behind a pass that threw never ran")
            if wire.snapshot.historyRequests == 2 { await secondTask.value }
            #expect(!wire.snapshot.overlapped)
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// What the fake server saw for the cursor tests below: the `startHistoryId`
    /// of every `history` request, in order, and how many window listings (full
    /// syncs) arrived.
    final class CursorWire: Sendable {
        struct State {
            var historyStarts: [String] = []
            var listingRequests = 0
        }
        let state = Mutex(State())
        /// Released by the test to answer the first window listing.
        let releaseFirstListing = DispatchSemaphore(value: 0)

        var snapshot: State { state.withLock { $0 } }
    }

    /// The server has expired cursor `1000` (its `history` answers 404) and is
    /// at `2000` now (`profile`); a `history` from any other cursor answers
    /// `2001` with no changes. With `parkFirstListing`, the first full sync's
    /// window listing waits for the test to release it.
    private static func cursorScenario(wire: CursorWire, parkFirstListing: Bool) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        scenario.register(path: "/history", method: "GET") { request in
            let start = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "startHistoryId" }?.value ?? ""
            wire.state.withLock { $0.historyStarts.append(start) }
            return start == "1000" ? .status(404) : .json(raw: #"{ "historyId": "2001" }"#)
        }
        scenario.register(path: "/labels", method: "GET", response: .json(
            raw: #"{ "labels": [ { "id": "INBOX", "name": "INBOX", "type": "system" } ] }"#))
        scenario.register(path: "/messages", method: "GET") { request in
            let empty = #"{ "resultSizeEstimate": 0 }"#
            guard Self.isWindowListing(request.url) else { return .json(raw: empty) }
            let order: Int = wire.state.withLock { state in
                state.listingRequests += 1
                return state.listingRequests
            }
            guard parkFirstListing, order == 1 else { return .json(raw: empty) }
            return .parked {
                _ = wire.releaseFirstListing.wait(timeout: .now() + .seconds(10))
                return .json(raw: empty)
            }
        }
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "one-sync-gmail@example.com", "historyId": "2000" }"#))
        return scenario
    }

    private static func storedCursor(_ pool: DatabasePool) throws -> String? {
        try pool.read { db in try Account.fetchOne(db, key: accountId)?.lastHistoryId }
    }

    /// RED while a pass ran on its caller's copy: a push delta queued
    /// behind the launch's full sync carried the expired cursor `1000`, found it
    /// expired again, and cleared the cursor that full sync had just captured,
    /// so new mail waited for the next full sync.
    @Test("A delta that waited behind a full sync runs from the cursor that full sync captured")
    func waitingDeltaKeepsTheFreshCursor() async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let wire = CursorWire()
            let scenario = Self.cursorScenario(wire: wire, parkFirstListing: true)
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await Self.engine(provider: provider)

            let first = Task { try await engine.sync(account: account) }
            #expect(await Self.eventually { wire.snapshot.listingRequests == 1 },
                    "precondition: the first pass reached its full sync")
            // The caller's copy still names the expired cursor.
            let second = Task { _ = try await engine.backgroundDeltaSync(account: account) }
            #expect(await Self.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 1 },
                    "precondition: the delta waits its turn behind the full sync")
            wire.releaseFirstListing.signal()

            _ = try await first.value
            try await second.value

            #expect(wire.snapshot.historyStarts == ["1000", "2000"],
                    "the waiting delta must ask from the cursor the full sync captured, not its caller's")
            #expect(try Self.storedCursor(pool) == "2001", "the cursor the full sync captured was cleared")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// RED while a pass ran on its caller's copy: the epoch rebuild (and
    /// Settings' resync) clears `lastFullSyncAt` to make the full sync due, then
    /// syncs with an account it read before the clear, whose copy still said a
    /// full sync ran a minute ago.
    @Test("A full sync made due after the caller read the account still runs")
    func fullSyncMadeDueAfterTheReadRuns() async throws {
        try await Self.withAppDB { pool in
            let aMinuteAgo = Date().addingTimeInterval(-60)
            let account = try Self.makeAccount(pool: pool, lastFullSyncAt: aMinuteAgo, lastSyncedAt: aMinuteAgo)
            try await pool.write { db in
                _ = try Account.filter(Column("id") == Self.accountId)
                    .updateAll(db, Column("lastHistoryId").set(to: "1500"), Column("lastFullSyncAt").set(to: nil as Date?))
            }
            let wire = CursorWire()
            let scenario = Self.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await Self.engine(provider: provider)

            _ = try await engine.sync(account: account)

            #expect(wire.snapshot.historyStarts == ["1500"], "the delta must run from the stored cursor")
            #expect(wire.snapshot.listingRequests == 1, "the full sync the row says is due did not run")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// A foreground pass and a background delta wait behind a held turn; the
    /// account is removed before their turns start. Each must then do nothing (no
    /// request, no write that brings the row back), report no change, and hand
    /// the turn on. Without the removal, the same two passes do sync: that keeps
    /// the zero-request check from passing for some other reason.
    @Test("Passes whose account was removed while they waited do nothing and hand the turn on",
          arguments: [true, false])
    func removedWhileWaitingDoesNothing(removed: Bool) async throws {
        try await Self.withAppDB { pool in
            let account = try Self.makeAccount(pool: pool)
            let wire = CursorWire()
            let scenario = Self.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let provider = GmailProvider(
                userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
            let engine = await Self.engine(provider: provider)
            let log = PassLog()
            let held = AsyncStream<Void>.makeStream()
            let holder = Self.heldPass(engine: engine, accountId: Self.accountId, name: "held", log: log, release: held.stream)
            #expect(await Self.eventually { log.snapshot == ["start held"] }, "precondition: the turn is held")

            // Both callers pass the copy they read before the wait.
            let foreground = Task { try await engine.sync(account: account) }
            let delta = Task { try await engine.backgroundDeltaSync(account: account) }
            #expect(await Self.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 2 },
                    "precondition: both passes wait their turn")
            if removed {
                _ = try await pool.write { db in try Account.deleteOne(db, key: Self.accountId) }
            }
            held.continuation.yield()
            await holder.value
            let changed = try await foreground.value
            let deltaResult = try await delta.value

            if removed {
                #expect(!changed, "a pass whose account is gone reported a change")
                #expect(deltaResult.changed == false && deltaResult.reason == "noAccount",
                        "a delta whose account is gone must report no change, for the removed account")
                #expect(scenario.recordedCalls().isEmpty, "a pass whose account is gone made a request")
                #expect(try await pool.read { db in try Account.fetchOne(db, key: Self.accountId) } == nil,
                        "a pass whose account is gone wrote its row back")
            } else {
                #expect(!wire.snapshot.historyStarts.isEmpty, "non-vacuity: the same passes sync when the account is there")
            }
            #expect(await engine.syncPassRunning.isEmpty, "the turn was not handed on")
            #expect(await engine.syncPassWaiters[Self.accountId] == nil)
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// What the passes below did, in order.
    final class PassLog: Sendable {
        let entries = Mutex<[String]>([])
        func append(_ entry: String) { entries.withLock { $0.append(entry) } }
        var snapshot: [String] { entries.withLock { $0 } }
    }

    private static func eventually(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// Starts a pass of `accountId` that logs its start, holds its turn until
    /// `release` yields, then logs its end.
    private static func heldPass(
        engine: SyncEngine, accountId: String, name: String, log: PassLog, release: AsyncStream<Void>
    ) -> Task<Void, Never> {
        Task {
            await engine.oneSyncAtATime(accountId: accountId) {
                log.append("start \(name)")
                for await _ in release { break }
                log.append("end \(name)")
            }
        }
    }

    /// Passes of one account: one running and two waiting. Handing the turn on
    /// gives it to the OLDEST waiter only and keeps the rest queued; a pass that
    /// arrives while a handed-over pass runs waits too; every pass runs, one at a
    /// time, in arrival order.
    @Test("Passes waiting behind a running pass each run, one at a time, in arrival order")
    func waitingPassesRunOneAtATimeInArrivalOrder() async throws {
        let engine = SyncEngine()
        let log = PassLog()
        let releases = (0..<4).map { _ in AsyncStream<Void>.makeStream() }
        var passes: [Task<Void, Never>] = []
        for index in 0..<3 {
            passes.append(Self.heldPass(
                engine: engine, accountId: Self.accountId, name: "\(index)", log: log, release: releases[index].stream))
            // Each pass arrives only once the one before it is running or queued.
            #expect(await Self.eventually {
                if index == 0 { return log.snapshot == ["start 0"] }
                return await engine.syncPassWaiters[Self.accountId]?.count == index
            }, "precondition: pass \(index) arrived in order")
        }

        releases[0].continuation.yield()
        #expect(await Self.eventually { log.snapshot == ["start 0", "end 0", "start 1"] },
                "the oldest waiter, and only it, takes the turn")
        #expect(await engine.syncPassWaiters[Self.accountId]?.count == 1, "the third pass still waits its turn")

        // A pass arriving while the handed-over pass runs must queue behind the third.
        passes.append(Self.heldPass(
            engine: engine, accountId: Self.accountId, name: "3", log: log, release: releases[3].stream))
        #expect(await Self.eventually { await engine.syncPassWaiters[Self.accountId]?.count == 2 },
                "a pass arriving during a handed-over turn waits")
        #expect(!log.snapshot.contains("start 3"), "a pass arriving during a handed-over turn ran alongside it")

        for index in 1..<4 {
            releases[index].continuation.yield()
            let next = index + 1
            if next < 4 {
                #expect(await Self.eventually { log.snapshot.last == "start \(next)" },
                        "pass \(next) runs once pass \(index) ends")
            }
        }
        let finished = await Self.eventually { log.snapshot.count == 8 }
        #expect(finished)
        #expect(log.snapshot == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2", "start 3", "end 3"],
                "passes ran one at a time, in arrival order")
        // A stranded pass never returns; only passes that all finished are awaited.
        if finished { for pass in passes { await pass.value } }
        #expect(await engine.syncPassRunning.isEmpty, "the account is free once the last pass ends")
        #expect(await engine.syncPassWaiters[Self.accountId] == nil)
    }

    /// The turn is per account: a pass of another account runs and finishes
    /// while this account's pass holds its turn.
    @Test("Another account's pass does not wait for this account's turn")
    func anotherAccountDoesNotWait() async throws {
        let engine = SyncEngine()
        let log = PassLog()
        let held = AsyncStream<Void>.makeStream()
        let other = AsyncStream<Void>.makeStream()
        let first = Self.heldPass(engine: engine, accountId: Self.accountId, name: "a", log: log, release: held.stream)
        #expect(await Self.eventually { log.snapshot == ["start a"] }, "precondition: this account's pass runs")

        other.continuation.yield()
        let second = Self.heldPass(
            engine: engine, accountId: "\(Self.accountId)-other", name: "b", log: log, release: other.stream)
        let ranAlongside = await Self.eventually { log.snapshot == ["start a", "start b", "end b"] }
        #expect(ranAlongside, "the other account's pass waited for this account's turn")

        held.continuation.yield()
        let finished = await Self.eventually { log.snapshot.count == 4 }
        #expect(finished)
        if finished { await first.value; await second.value }
        #expect(await engine.syncPassRunning.isEmpty)
        #expect(await engine.syncPassWaiters.isEmpty)
    }
}
