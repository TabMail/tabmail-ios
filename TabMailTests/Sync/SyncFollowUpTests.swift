/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// THE PROPERTY: a sync trigger never waits for an account's turn and is never
/// dropped. A trigger that finds the account busy reads nothing, sets the
/// account's follow-up flag and returns at once. Setting the flag asks for ONE
/// follow-up stage 2, however many triggers came. The follow-up waits in line
/// for the turn, takes its time limit when it gets it, and runs only if the
/// flag is still set (a stage 2 that ran in between served it); the stage 2
/// clears the flag. Until a stage 2 runs, every release asks again, so a flag
/// set in the background is asked for by the next opening's stage 1. Every time
/// limit counts from when its pass takes the turn. The sync design block at the
/// top of SyncEngineOneSyncAtATime.swift.
///
/// The engine tests drive production `SyncEngine.backgroundDeltaSync` (stage 1),
/// `SyncEngine.syncOrFollowUp` (stage 2 as a trigger) and
/// `SyncEngine.followUpPass` (the follow-up) end to end on `FakeHTTP` with a
/// real `GmailProvider` and a real `DatabasePool`. A test stands in for
/// `SyncScheduler.runSyncFollowUp` with a runner that runs the same follow-up
/// (`followUpPass`). The scheduler tests drive the scheduler's own triggers
/// with its stage 2 recorded.
@Suite("A sync trigger never waits: the follow-up flag", .serialized, .processGlobalState)
struct SyncFollowUpTests {
    typealias O = OneSyncAtATimeTests
    private static let accountId = OneSyncAtATimeTests.accountId

    /// What the engine asked for (`SyncEngine.syncFollowUp`) and the runner a
    /// test installs in the scheduler's place.
    final class FollowUps: Sendable {
        struct State {
            var asks: [String] = []
            var runner: (@Sendable (_ accountId: String) -> Void)?
            /// Stage 2 runs started by the runner and not yet finished.
            var running = 0
            /// Each runner follow-up's outcome: "ran", "served" (nothing ran: an
            /// earlier stage 2 had cleared the flag, or the app had left) or
            /// "threw".
            var outcomes: [String] = []
            /// The app's state for the runner, as the scheduler's follow-up gate
            /// (`SyncScheduler.followUpMayStart`): checked at the ask and again
            /// at the turn.
            var foreground = true
        }
        let state = Mutex(State())
        let log: OneSyncAtATimeTests.PassLog

        init(log: OneSyncAtATimeTests.PassLog = OneSyncAtATimeTests.PassLog()) { self.log = log }

        /// The engine's `syncFollowUp`: called inside the engine when a trigger
        /// first sets the flag, and when the account becomes free with the flag
        /// still set.
        func ask(_ accountId: String) {
            log.append("ask")
            let runner = state.withLock { state in
                state.asks.append(accountId)
                return state.runner
            }
            runner?(accountId)
        }

        var asks: [String] { state.withLock { $0.asks } }
        var running: Int { state.withLock { $0.running } }
        var outcomes: [String] { state.withLock { $0.outcomes } }
        var foreground: Bool { state.withLock { $0.foreground } }
        func setForeground(_ foreground: Bool) { state.withLock { $0.foreground = foreground } }

        /// In the foreground the scheduler runs one follow-up per ask
        /// (`runSyncFollowUp` → `followUpRun` → `followUpPass`), which waits
        /// for the turn, checks the gate again there and takes its change
        /// read's deadline there. Weak: the engine's callback holds this object.
        func runStageTwo(engine: SyncEngine) {
            state.withLock { state in
                state.runner = { [weak self, weak engine] accountId in
                    guard let self, let engine, self.foreground else { return }
                    self.state.withLock { $0.running += 1 }
                    Task {
                        let outcome: String
                        do {
                            let ran = try await engine.followUpPass(accountId: accountId, mayStart: { self.foreground })
                            outcome = ran == nil ? "served" : "ran"
                        } catch {
                            outcome = "threw"
                        }
                        self.state.withLock { state in
                            state.running -= 1
                            state.outcomes.append(outcome)
                        }
                    }
                }
            }
        }
    }

    /// A clock the test moves by hand: the engine's read clock.
    final class TestClock: Sendable {
        private let now = Mutex(Date())
        func read() -> Date { now.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private static func setCursor(_ pool: DatabasePool, _ cursor: String) async throws {
        try await pool.write { db in
            _ = try Account.filter(Column("id") == accountId).updateAll(db, Column("lastHistoryId").set(to: cursor))
        }
    }

    private static func provider(_ account: Account, _ scenario: FakeHTTP.Scenario) -> GmailProvider {
        GmailProvider(userEmail: account.emailAddress, accessToken: { _ in "fake-access-token" }, session: scenario.session)
    }

    /// Bounded: true once the engine holds no turn of the account, no flag,
    /// and the runner has no stage 2 in flight.
    private static func settled(_ engine: SyncEngine, _ followUps: FollowUps) async -> Bool {
        await O.eventually {
            let free = await engine.syncPassRunning.isEmpty
            let flagged = await engine.syncFollowUpWanted.isEmpty
            return free && flagged && followUps.running == 0
        }
    }

    /// Bounded: true once `count` passes wait in line for the account's turn.
    private static func waitingInLine(_ engine: SyncEngine, _ count: Int) async -> Bool {
        await O.eventually { await engine.syncPassWaiters[accountId]?.count == count }
    }

    enum Trigger: String, CaseIterable, Sendable {
        /// Stage 1: a push, IDLE, a return's quick read, pull to refresh.
        case changeRead
        /// Stage 2 as a trigger: the poll's pass.
        case stageTwo
    }

    /// For each trigger that returned, in order: "nothing" (it found the
    /// account busy and read nothing), "read", or "threw".
    final class Returns: Sendable {
        let outcomes = Mutex<[String]>([])
        var snapshot: [String] { outcomes.withLock { $0 } }
    }

    /// Runs `burst` triggers of `kind` one after another in a task and records
    /// each result; a trigger that waits for the turn never records. A throw is
    /// recorded as such, never as a busy account.
    private static func fire(
        _ kind: Trigger, burst: Int, engine: SyncEngine, account: Account, deadline: Date? = nil
    ) -> Returns {
        let returns = Returns()
        Task {
            for _ in 0..<burst {
                let outcome: String
                do {
                    switch kind {
                    case .changeRead:
                        let read = try await engine.backgroundDeltaSync(account: account)
                        outcome = read == nil ? "nothing" : "read"
                    case .stageTwo:
                        let ran = try await engine.syncOrFollowUp(account: account, deadline: deadline)
                        outcome = ran == nil ? "nothing" : "read"
                    }
                } catch {
                    outcome = "threw"
                }
                returns.outcomes.withLock { $0.append(outcome) }
            }
        }
        return returns
    }

    // MARK: - The engine

    /// RED while a trigger waited for the turn (#1289): the triggers never
    /// returned while the turn was held. RED without the ask, with an ask per
    /// trigger (a burst asks more than once), or with a stage 2 that does not
    /// clear the flag (its own release asks a second time).
    @Test("Triggers that find the account busy return at once; the flag asks for one follow-up, which waits in line and runs the due full sync",
          arguments: Trigger.allCases, [1, 3])
    func busyTriggersGetOneStageTwo(kind: Trigger, burst: Int) async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool)
            try await Self.setCursor(pool, "1500")
            let wire = O.CursorWire()
            let scenario = O.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let followUps = FollowUps()
            let engine = await O.engine(provider: Self.provider(account, scenario), syncFollowUp: { followUps.ask($0) })
            followUps.runStageTwo(engine: engine)
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = O.heldPass(
                engine: engine, accountId: Self.accountId, name: "held", log: followUps.log, release: release.stream)
            #expect(await O.eventually { followUps.log.snapshot == ["start held"] }, "precondition: the turn is held")

            let results = Self.fire(kind, burst: burst, engine: engine, account: account)
            let returned = await O.eventually(seconds: 5) { results.snapshot.count == burst }
            let outcomes = results.snapshot
            let wanted = await engine.syncFollowUpWanted
            let inLine = await Self.waitingInLine(engine, 1)
            #expect(returned, "a trigger waited for the turn instead of setting the follow-up flag")
            #expect(outcomes == Array(repeating: "nothing", count: burst), "a busy trigger did not return having read nothing: \(outcomes)")
            #expect(wire.snapshot.historyStarts.isEmpty, "a busy trigger read changes")
            #expect(followUps.asks == [Self.accountId], "setting the flag did not ask for one follow-up, however many triggers came")
            #expect(wanted == [Self.accountId], "the busy account's follow-up flag is not set")
            #expect(inLine, "the follow-up does not wait in line for the turn")

            release.continuation.yield()
            await holder.value
            #expect(await Self.settled(engine, followUps), "the follow-up stage 2 never finished")
            #expect(followUps.asks == [Self.accountId], "the follow-up's own release asked again: it left the flag set")
            #expect(followUps.outcomes == ["ran"], "the follow-up asked for did not run")
            #expect(wire.snapshot.historyStarts == ["1500"], "the stage 2 did not read changes once")
            #expect(wire.snapshot.listingRequests == 1, "the due full sync did not run in the follow-up stage 2")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// RED if the ask cleared the flag: an ask the scheduler declines (in the
    /// background) dropped the trigger. Only a stage 2 clears it; until then
    /// every release of the account asks again, a stage 1's included.
    @Test("A flag no stage 2 answered stays set: every release asks again until a stage 2 runs")
    func flagWaitsForAStageTwo() async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
            try await Self.setCursor(pool, "1500")
            let wire = O.CursorWire()
            let scenario = O.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let followUps = FollowUps()
            let engine = await O.engine(provider: Self.provider(account, scenario), syncFollowUp: { followUps.ask($0) })
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = O.heldPass(
                engine: engine, accountId: Self.accountId, name: "held", log: followUps.log, release: release.stream)
            #expect(await O.eventually { followUps.log.snapshot == ["start held"] }, "precondition: the turn is held")
            // The scheduler declines every ask (background): no runner.
            let busy = try await engine.backgroundDeltaSync(account: account)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")
            #expect(followUps.asks.count == 1, "setting the flag did not ask for the follow-up")

            release.continuation.yield()
            await holder.value
            #expect(followUps.asks.count == 2, "the release did not ask again for the declined follow-up")
            #expect(await engine.syncFollowUpWanted == [Self.accountId], "a declined ask dropped the flag")

            // The next opening's stage 1 runs and asks again when it ends.
            let read = try await engine.backgroundDeltaSync(account: account)
            let stageOneRan = read != nil
            #expect(stageOneRan, "precondition: the account was free, so stage 1 ran")
            #expect(followUps.asks.count == 3, "a stage 1's release did not ask again for the flagged stage 2")
            #expect(await engine.syncFollowUpWanted == [Self.accountId], "a stage 1 cleared the flag")

            // The stage 2 clears it: its own release asks nothing.
            let ran = try await engine.syncOrFollowUp(account: account, deadline: nil)
            let stageTwoRan = ran != nil
            #expect(stageTwoRan, "precondition: the account was free, so the stage 2 ran")
            #expect(followUps.asks.count == 3, "the stage 2's release asked again")
            #expect(await engine.syncFollowUpWanted.isEmpty, "the stage 2 left the flag set")
            #expect(wire.snapshot.historyStarts.count == 2, "precondition: stage 1 and the stage 2 each read once")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// RED without the gate checked again at the turn: a follow-up admitted in
    /// the foreground got the turn after the app had left and ran its stage 2 in
    /// the background, clearing the flag. It returns with the flag set instead;
    /// its release asks again, the scheduler starts nothing while the app is
    /// away, and the next opening's stage 1 asks again when it ends: that
    /// follow-up runs the stage 2.
    @Test("A follow-up whose app leaves before its turn runs no stage 2 in the background; the next opening runs it")
    func followUpAfterTheAppLeftWaitsForTheOpening() async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
            try await Self.setCursor(pool, "1500")
            let wire = O.CursorWire()
            let scenario = O.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let followUps = FollowUps()
            let engine = await O.engine(provider: Self.provider(account, scenario), syncFollowUp: { followUps.ask($0) })
            followUps.runStageTwo(engine: engine)
            let release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish() }
            let holder = O.heldPass(
                engine: engine, accountId: Self.accountId, name: "held", log: followUps.log, release: release.stream)
            #expect(await O.eventually { followUps.log.snapshot == ["start held"] }, "precondition: the turn is held")

            // In the foreground a busy trigger's follow-up is admitted and waits in line.
            let busy = try await engine.backgroundDeltaSync(account: account)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")
            let inLine = await Self.waitingInLine(engine, 1)
            #expect(inLine, "precondition: the follow-up waits in line")

            // The app leaves; then the running work ends and the follow-up gets the turn.
            followUps.setForeground(false)
            release.continuation.yield()
            await holder.value
            let finished = await O.eventually { followUps.running == 0 }
            let wantedAway = await engine.syncFollowUpWanted
            let turnAway = await engine.syncPassRunning
            #expect(finished, "precondition: the admitted follow-up finished")
            #expect(wire.snapshot.historyStarts.isEmpty, "the follow-up ran its stage 2 after the app had left")
            #expect(wantedAway == [Self.accountId], "the follow-up cleared the flag with no stage 2")
            #expect(turnAway.isEmpty, "the follow-up that did not run kept the turn")
            #expect(followUps.asks.count == 2, "its release did not ask again for the flagged stage 2")

            // The next opening: stage 1 reads, and when it ends the follow-up runs stage 2.
            followUps.setForeground(true)
            let read = try await engine.backgroundDeltaSync(account: account)
            let stageOneRan = read != nil
            #expect(stageOneRan, "precondition: the account was free at the opening")
            let settled = await Self.settled(engine, followUps)
            #expect(settled, "the opening's follow-up never finished")
            let reads = wire.snapshot.historyStarts
            #expect(reads.count == 2, "the opening did not run stage 1 and then the follow-up's stage 2: \(reads)")
            #expect(followUps.asks.count == 3, "stage 1's release did not ask for the flagged stage 2")
            #expect(followUps.outcomes == ["served", "ran"], "the follow-ups did not run as expected: \(followUps.outcomes)")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// RED with a stage 2 whose time limit counts from before its wait for the
    /// turn (#1289; a follow-up that took its limit at the ask): the limit ran
    /// out while it waited behind a long stage 1, so it started with no read
    /// budget and read nothing. The follow-up's limit counts from its turn.
    @Test("A follow-up asked for during a long stage 1 reads with its whole time limit")
    func stageTwoAfterALongStageOneReads() async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
            try await Self.setCursor(pool, "1500")
            let wire = O.CursorWire()
            let scenario = O.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let clock = TestClock()
            let followUps = FollowUps()
            let engine = await O.engine(
                provider: Self.provider(account, scenario), changeReadClock: { clock.read() },
                syncFollowUp: { followUps.ask($0) })
            followUps.runStageTwo(engine: engine)
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = O.heldPass(
                engine: engine, accountId: Self.accountId, name: "stage 1", log: followUps.log, release: release.stream)
            #expect(await O.eventually { followUps.log.snapshot == ["start stage 1"] }, "precondition: stage 1 holds the turn")

            // The poll's stage 2, with the time limit the poll gives it, finds
            // stage 1 running; its follow-up waits in line.
            let limit = SyncConfig.perAccountSyncTimeoutSeconds
            let poll = Self.fire(
                .stageTwo, burst: 1, engine: engine, account: account, deadline: clock.read().addingTimeInterval(limit))
            let returned = await O.eventually(seconds: 5) { poll.snapshot.count == 1 }
            #expect(returned, "the poll's stage 2 waited for the turn")
            #expect(await Self.waitingInLine(engine, 1), "precondition: the follow-up waits in line")

            // Stage 1 runs longer than the whole time limit.
            clock.advance(limit + 1)
            release.continuation.yield()
            await holder.value
            #expect(await Self.settled(engine, followUps), "the follow-up stage 2 never finished")
            #expect(followUps.outcomes == ["ran"], "no follow-up ran after stage 1")
            #expect(wire.snapshot.historyStarts == ["1500"], "the follow-up after a long stage 1 read nothing")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// The other side of `stageTwoAfterALongStageOneReads`: the follow-up's time
    /// limit, `SyncConfig.perAccountSyncTimeoutSeconds` from its turn, bounds its
    /// due full sync too. The turn's clock reads the whole limit and half a
    /// minute back, so the limit has passed when the count check (the
    /// deadline-bounded walk after a listing) would start: the walk sends no
    /// SEARCH, removes nothing, and leaves the folder due for the next listing.
    /// RED with a follow-up that takes no deadline, or one that never passes:
    /// the walk ran past the limit and removed the ghost.
    @Test("A follow-up's time limit, counted from its turn, bounds its due full sync")
    func followUpTimeLimitBoundsItsFullSync() async throws {
        typealias L = ListingCountersTests
        let back = SyncConfig.perAccountSyncTimeoutSeconds + 30
        try await IMAPChangeEngineTests.withWorld(
            "follow-up-limit", capabilities: L.condstoreNoReader, serverUIDs: [1], localUIDs: [1],
            changeReadClock: { Date().addingTimeInterval(-back) }
        ) { w in
            try L.addArchive(w, serverUIDs: L.belowWindowServer, localUIDs: L.belowWindowHeld)
            let accountId = w.account.id
            let log = O.PassLog()
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = O.heldPass(engine: w.engine, accountId: accountId, name: "held", log: log, release: release.stream)
            let heldNow = await O.eventually { log.snapshot == ["start held"] }
            #expect(heldNow, "precondition: the turn is held")
            let busy = await w.engine.oneSyncAtATimeOrFollowUp(accountId: accountId) { true }
            let flagged = busy == nil
            #expect(flagged, "precondition: the trigger found the account busy and set the flag")
            release.continuation.yield()
            await holder.value
            let dueBefore = try L.archiveDue(w)
            #expect(!dueBefore, "precondition: no walk is owed before the follow-up")

            let start = w.server.recordedCommands().count
            let ran = try await w.engine.followUpPass(accountId: accountId, mayStart: { true })
            // Only the count walk's UID SEARCH counts: the backfill crawl sends
            // date SEARCHes on its own schedule.
            let searches = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().hasPrefix("UID SEARCH UID") }
            let wanted = await w.engine.followUpWanted(accountId: accountId)
            let tookTheTurn = ran != nil
            #expect(tookTheTurn, "precondition: the follow-up took the turn and ran its stage 2")
            #expect(!wanted, "precondition: the follow-up served the flag")
            #expect(searches.isEmpty, "the follow-up's walk ran past its time limit: \(Array(searches))")
            #expect(try L.archive(w).uids.contains("1"), "the follow-up's walk removed a row past its time limit")
            #expect(try L.archiveDue(w), "the walk the follow-up's time limit cut is not owed to the next listing")
            await w.engine.remove(accountId: accountId)
        }
    }

    /// What served the flag before a follow-up got its turn.
    enum ServedBy: String, CaseIterable, Sendable {
        /// A second ask for the same flag: the account became free with the
        /// flag set before the first follow-up was in line.
        case anotherFollowUp
        /// A stage 2 that waits for its turn (Settings, a new account), in line
        /// before the follow-up.
        case stageTwoAhead
    }

    /// RED without the follow-up's check of the flag at its turn: it ran a
    /// second stage 2 and read changes again.
    @Test("A follow-up whose flag an earlier stage 2 served reads nothing", arguments: ServedBy.allCases)
    func servedFollowUpReadsNothing(servedBy: ServedBy) async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool)
            try await Self.setCursor(pool, "1500")
            let wire = O.CursorWire()
            let scenario = O.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let followUps = FollowUps()
            let engine = await O.engine(provider: Self.provider(account, scenario), syncFollowUp: { followUps.ask($0) })
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = O.heldPass(
                engine: engine, accountId: Self.accountId, name: "held", log: followUps.log, release: release.stream)
            #expect(await O.eventually { followUps.log.snapshot == ["start held"] }, "precondition: the turn is held")
            let busy = try await engine.backgroundDeltaSync(account: account)
            let busyReadNothing = busy == nil
            #expect(busyReadNothing, "precondition: the trigger found the account busy")

            // In line behind the held pass: the stage 2 that serves the flag,
            // then the follow-up.
            let ahead = Task { () async throws -> Bool? in
                switch servedBy {
                case .anotherFollowUp: return try await engine.followUpPass(accountId: Self.accountId, mayStart: { true })
                case .stageTwoAhead: return try await engine.sync(account: account)
                }
            }
            #expect(await Self.waitingInLine(engine, 1), "precondition: the first stage 2 waits in line")
            let followUp = Task { try await engine.followUpPass(accountId: Self.accountId, mayStart: { true }) }
            #expect(await Self.waitingInLine(engine, 2), "precondition: the follow-up waits behind it")

            release.continuation.yield()
            await holder.value
            let aheadResult = try await ahead.value
            let followUpResult = try await followUp.value
            let aheadRan = aheadResult != nil
            let followUpRan = followUpResult != nil
            #expect(aheadRan, "precondition: the stage 2 ahead served the flag")
            #expect(!followUpRan, "a follow-up ran stage 2 although an earlier stage 2 had served its flag")
            #expect(wire.snapshot.historyStarts == ["1500"], "the served follow-up read changes again")
            #expect(wire.snapshot.listingRequests == 1, "precondition: the stage 2 ahead ran the due full sync")
            #expect(await engine.syncFollowUpWanted.isEmpty, "the flag stayed set")
            await engine.remove(accountId: Self.accountId)
        }
    }

    /// RED without the flag's removal with the account: a removed account kept
    /// its flag, and every later release of an account with that id would ask
    /// for a stage 2 no trigger wanted.
    @Test("Removing an account drops its follow-up flag")
    func removingAnAccountDropsItsFlag() async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
            let wire = O.CursorWire()
            let scenario = O.cursorScenario(wire: wire, parkFirstListing: false)
            defer { scenario.close() }
            let followUps = FollowUps()
            let engine = await O.engine(provider: Self.provider(account, scenario), syncFollowUp: { followUps.ask($0) })
            let release = AsyncStream<Void>.makeStream()
            // A test that stops early still ends its held pass.
            defer { release.continuation.finish() }
            let holder = O.heldPass(
                engine: engine, accountId: Self.accountId, name: "held", log: followUps.log, release: release.stream)
            #expect(await O.eventually { followUps.log.snapshot == ["start held"] }, "precondition: the turn is held")
            _ = try await engine.backgroundDeltaSync(account: account)
            release.continuation.yield()
            await holder.value
            #expect(await engine.syncFollowUpWanted == [Self.accountId], "precondition: the declined follow-up's flag is set")

            await engine.remove(accountId: Self.accountId)
            #expect(await engine.syncFollowUpWanted.isEmpty, "the removed account's follow-up flag stayed set")
        }
    }

    // MARK: - An opening

    /// How stage 1 and the poll's stage 2 of one account meet at an opening.
    enum Opening: String, CaseIterable, Sendable {
        /// The usual case: the poll's stage 2 finds stage 1 running.
        case pollDuringStageOne
        /// The account was flagged before the opening (in the background), and
        /// its stage 1 ended before the poll reached it: one extra quick read.
        case flaggedBefore
        /// The poll's stage 2 takes the account before stage 1.
        case pollFirst
    }

    /// What the server saw at an opening, in order with the engine's asks: each
    /// change read ("read <cursor>") and each window listing ("listing").
    private static func openingScenario(log: OneSyncAtATimeTests.PassLog, gate: DispatchSemaphore) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        let reads = Mutex(0)
        scenario.register(path: "/history", method: "GET") { request in
            let start = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "startHistoryId" }?.value ?? ""
            let order = reads.withLock { count in
                count += 1
                return count
            }
            log.append("read \(start)")
            let next = (Int(start) ?? 0) + 1
            guard order == 1 else { return .json(raw: #"{ "historyId": "\#(next)" }"#) }
            // The first read of the opening holds its pass until the test opens the gate.
            return .parked {
                _ = gate.wait(timeout: .now() + .seconds(10))
                return .json(raw: #"{ "historyId": "\#(next)" }"#)
            }
        }
        scenario.register(path: "/labels", method: "GET", response: .json(
            raw: #"{ "labels": [ { "id": "INBOX", "name": "INBOX", "type": "system" } ] }"#))
        scenario.register(path: "/messages", method: "GET") { request in
            if O.isWindowListing(request.url) { log.append("listing") }
            return .json(raw: #"{ "resultSizeEstimate": 0 }"#)
        }
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "one-sync-gmail@example.com", "historyId": "5000" }"#))
        return scenario
    }

    /// RED with no follow-up (a busy trigger dropped): with the poll during
    /// stage 1, or first, no read starts after stage 1. RED with a stage 2 that
    /// waits behind stage 1 instead: the poll's stage 2 does not return while
    /// stage 1 runs. The property at an opening: the due full sync runs once per
    /// account, and each account's last read starts after its stage 1 ends.
    @Test("At an opening the due full sync runs once per account, and each account's last read starts after its stage 1 ends",
          arguments: Opening.allCases)
    func openingRunsTheFullSyncOnceAndReadsLast(opening: Opening) async throws {
        try await O.withAppDB { pool in
            let account = try O.makeAccount(pool: pool)
            try await Self.setCursor(pool, "1500")
            let log = OneSyncAtATimeTests.PassLog()
            let gate = DispatchSemaphore(value: 0)
            let scenario = Self.openingScenario(log: log, gate: gate)
            defer { scenario.close() }
            let followUps = FollowUps(log: log)
            let engine = await O.engine(provider: Self.provider(account, scenario), syncFollowUp: { followUps.ask($0) })

            switch opening {
            case .pollDuringStageOne:
                followUps.runStageTwo(engine: engine)
                log.append("opening")
                let stageOne = Task { try await engine.backgroundDeltaSync(account: account) }
                #expect(await O.eventually { log.snapshot.contains("read 1500") }, "precondition: stage 1 is reading")
                let poll = Self.fire(.stageTwo, burst: 1, engine: engine, account: account)
                #expect(await O.eventually(seconds: 5) { poll.snapshot == ["nothing"] },
                        "precondition: the poll's stage 2 found stage 1 running")
                gate.signal()
                _ = try await stageOne.value
            case .flaggedBefore:
                // In the background: a trigger during another pass, and an ask the
                // scheduler declines.
                gate.signal()
                let release = AsyncStream<Void>.makeStream()
                // A test that stops early still ends its held pass.
                defer { release.continuation.finish() }
                let holder = O.heldPass(
                    engine: engine, accountId: Self.accountId, name: "background", log: log, release: release.stream)
                #expect(await O.eventually { log.snapshot.contains("start background") }, "precondition: a pass holds the turn")
                _ = try await engine.backgroundDeltaSync(account: account)
                release.continuation.yield()
                await holder.value
                #expect(followUps.asks.count == 2, "precondition: the flag and the background release asked, and were declined")

                followUps.runStageTwo(engine: engine)
                log.append("opening")
                let read = try await engine.backgroundDeltaSync(account: account)
                let stageOneRan = read != nil
                #expect(stageOneRan, "precondition: stage 1 ran")
                #expect(followUps.asks.count == 3, "precondition: stage 1's release asked")
                let poll = Self.fire(.stageTwo, burst: 1, engine: engine, account: account)
                #expect(await O.eventually(seconds: 5) { poll.snapshot.count == 1 }, "the poll's stage 2 waited")
            case .pollFirst:
                followUps.runStageTwo(engine: engine)
                log.append("opening")
                let poll = Self.fire(.stageTwo, burst: 1, engine: engine, account: account)
                #expect(await O.eventually { log.snapshot.contains("read 1500") }, "precondition: the poll's stage 2 is reading")
                let read = try await engine.backgroundDeltaSync(account: account)
                let stageOneReadNothing = read == nil
                #expect(stageOneReadNothing, "precondition: stage 1 found the poll's stage 2 running")
                log.append("stage 1 returned")
                gate.signal()
                #expect(await O.eventually(seconds: 5) { poll.snapshot.count == 1 }, "the poll's stage 2 never ended")
            }
            #expect(await Self.settled(engine, followUps), "the opening's passes never settled")

            let events = log.snapshot
            let lastRead = events.lastIndex { $0.hasPrefix("read ") }
            // A read starts after stage 1 ended. Where stage 1 read, it read from
            // 1500 and moved the cursor, which only it could move while it held
            // the turn: a read from a later cursor started after it ended. Where
            // stage 1 found the account busy, it ended at its return.
            let readLast: Bool = switch opening {
            case .pollDuringStageOne, .flaggedBefore:
                lastRead.flatMap { Int(events[$0].dropFirst("read ".count)) }.map { $0 > 1500 } ?? false
            case .pollFirst:
                events.firstIndex(of: "stage 1 returned").flatMap { end in lastRead.map { $0 > end } } ?? false
            }
            let listings = events.filter { $0 == "listing" }.count
            #expect(listings == 1, "the due full sync ran \(listings) times at the opening: \(events)")
            #expect(readLast, "no read started after stage 1 ended: \(events)")
            #expect(!followUps.outcomes.contains("threw"), "a stage 2 failed: \(followUps.outcomes)")
            await engine.remove(accountId: Self.accountId)
        }
    }

    // MARK: - Fuzz (testing rule 11)

    /// Seeds run on every test pass; `fuzzSteps` events per seed. Both are the
    /// iteration knobs.
    static let fuzzSeeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34]
    static let fuzzSteps = 40

    /// What the fake server and the held passes saw, in one order: each
    /// trigger's arrival and each change read's start take the next number.
    final class FuzzWire: Sendable {
        struct State {
            var order = 0
            var lastTrigger = 0
            var lastRead = 0
            var triggers = 0
            var reads = 0
            var historyInFlight = 0
            var held = 0
            var overlaps: [String] = []
            var jitter: ChangeApplyFuzzTests.RNG
        }
        let state: Mutex<State>

        init(seed: UInt64) { state = Mutex(State(jitter: ChangeApplyFuzzTests.RNG(state: seed ^ 0xA5A5_A5A5))) }

        var snapshot: State { state.withLock { $0 } }

        func trigger() {
            state.withLock { state in
                state.order += 1
                state.lastTrigger = state.order
                state.triggers += 1
            }
        }

        /// A change read starts; returns its answer's delay in seconds.
        func readStarts() -> TimeInterval {
            state.withLock { state in
                state.order += 1
                state.lastRead = state.order
                state.reads += 1
                if state.historyInFlight > 0 { state.overlaps.append("two change reads at once") }
                if state.held > 0 { state.overlaps.append("a change read during another pass") }
                state.historyInFlight += 1
                return Double(Int.random(in: 0...4, using: &state.jitter)) / 1000
            }
        }

        func readEnds() { state.withLock { $0.historyInFlight -= 1 } }

        func heldStarts() {
            state.withLock { state in
                if state.historyInFlight > 0 || state.held > 0 { state.overlaps.append("a pass started during another pass") }
                state.held += 1
            }
        }

        func heldEnds() { state.withLock { $0.held -= 1 } }
    }

    /// Every change read answers the next cursor with no changes, after a seeded
    /// delay that stretches the read across other triggers.
    private static func fuzzScenario(wire: FuzzWire) -> FakeHTTP.Scenario {
        let scenario = FakeHTTP.Scenario()
        scenario.register(path: "/history", method: "GET") { request in
            let start = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "startHistoryId" }?.value ?? ""
            let delay = wire.readStarts()
            let next = (Int(start) ?? 0) + 1
            return .parked {
                Thread.sleep(forTimeInterval: delay)
                wire.readEnds()
                return .json(raw: #"{ "historyId": "\#(next)" }"#)
            }
        }
        scenario.register(path: "/labels", method: "GET", response: .json(
            raw: #"{ "labels": [ { "id": "INBOX", "name": "INBOX", "type": "system" } ] }"#))
        scenario.register(path: "/messages", method: "GET", response: .json(raw: #"{ "resultSizeEstimate": 0 }"#))
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{ "emailAddress": "one-sync-gmail@example.com", "historyId": "5000" }"#))
        return scenario
    }

    enum FuzzStep: Sendable {
        /// Stage 1 with its caller's time limit taken now.
        case changeRead
        /// The poll's stage 2 with its caller's time limit taken now.
        case stageTwo
        /// Work that holds the account's turn (a listing, a catch-up slice, a
        /// reset) for a while, and outlasts every time limit taken meanwhile.
        case held(milliseconds: Int)
        /// A checkpoint: wait until the account goes quiet, then check that
        /// every trigger so far already had its read.
        case settle
    }

    /// How many triggers of each kind found the account busy, over every seed.
    final class BusyKinds: Sendable {
        let counts = Mutex<[String: Int]>([:])
        func found(_ kind: String) { counts.withLock { $0[kind, default: 0] += 1 } }
        var snapshot: [String: Int] { counts.withLock { $0 } }
    }

    /// The seeded schedule: a gap before each step, then the step.
    static func fuzzSchedule(seed: UInt64) -> [(gap: Int, step: FuzzStep)] {
        var rng = ChangeApplyFuzzTests.RNG(state: seed)
        var schedule: [(gap: Int, step: FuzzStep)] = []
        for _ in 0..<fuzzSteps {
            let gap = Int.random(in: 0...12, using: &rng)
            let roll = Int.random(in: 0..<100, using: &rng)
            let step: FuzzStep
            if roll < 35 {
                step = .changeRead
            } else if roll < 60 {
                step = .stageTwo
            } else if roll < 92 {
                step = .held(milliseconds: Int.random(in: 5...40, using: &rng))
            } else {
                step = .settle
            }
            schedule.append((gap, step))
        }
        return schedule
    }

    /// Triggers, the poll's stage 2 and work that holds the turn, interleaved by
    /// seed, with seeded latency on every change read and a clock that jumps past
    /// every time limit while held work runs (a long pass), and the foreground
    /// follow-up runner on. Checked by invariants, not by a schedule's expected
    /// values: every trigger gets a change read that starts after it before the
    /// account goes quiet (checked at seeded checkpoints and at the end), one
    /// account never runs two passes at once, and the flag is empty whenever all
    /// is quiet. Over the seeds, both trigger kinds find the account busy.
    /// RED with a trigger that waits for its turn and counts its time limit from
    /// its arrival (#1289): one behind held work reaches its turn with no time
    /// left and reads nothing.
    @Test("Seeded fuzz: every trigger gets a later read, passes never overlap, the flag ends empty")
    func fuzzEveryTriggerGetsALaterRead() async throws {
        var asksSeen = 0
        var checkpoints = 0
        let busyKinds = BusyKinds()
        for seed in Self.fuzzSeeds {
            try await O.withAppDB { pool in
                let account = try O.makeAccount(pool: pool, lastFullSyncAt: Date())
                try await Self.setCursor(pool, "1500")
                let wire = FuzzWire(seed: seed)
                let scenario = Self.fuzzScenario(wire: wire)
                defer { scenario.close() }
                let clock = TestClock()
                let followUps = FollowUps()
                let engine = await O.engine(
                    provider: Self.provider(account, scenario), changeReadClock: { clock.read() },
                    syncFollowUp: { followUps.ask($0) })
                let stageTwoLimit = SyncConfig.perAccountSyncTimeoutSeconds
                followUps.runStageTwo(engine: engine)

                var work: [Task<Void, Never>] = []
                for (gap, step) in Self.fuzzSchedule(seed: seed) {
                    try await Task.sleep(for: .milliseconds(gap))
                    // A trigger arrives, and its caller takes its time limit just
                    // before it calls the engine, as backgroundSyncOne and
                    // foregroundSyncOne do (`fuzzTriggerArrives`).
                    switch step {
                    case .changeRead:
                        work.append(Task {
                            do {
                                let read = try await engine.fuzzTriggerArrives(
                                    stageTwo: false, account: account, limit: SyncConfig.backgroundPerAccountTimeoutSeconds,
                                    now: { clock.read() }, arrives: { wire.trigger() })
                                if read == nil { busyKinds.found("change read") }
                            } catch {}
                        })
                    case .stageTwo:
                        work.append(Task {
                            do {
                                let ran = try await engine.fuzzTriggerArrives(
                                    stageTwo: true, account: account, limit: stageTwoLimit,
                                    now: { clock.read() }, arrives: { wire.trigger() })
                                if ran == nil { busyKinds.found("stage 2") }
                            } catch {}
                        })
                    case .held(let milliseconds):
                        work.append(Task {
                            await engine.oneSyncAtATime(accountId: Self.accountId) {
                                wire.heldStarts()
                                try? await Task.sleep(for: .milliseconds(milliseconds))
                                clock.advance(stageTwoLimit + 1)
                                wire.heldEnds()
                            }
                        })
                    case .settle:
                        for task in work { await task.value }
                        work.removeAll()
                        let quietNow = await Self.settled(engine, followUps)
                        let now = wire.snapshot
                        checkpoints += 1
                        #expect(quietNow, "seed \(seed): at a checkpoint the account never went quiet, or its flag stayed set")
                        #expect(now.triggers == 0 || now.lastRead > now.lastTrigger,
                                "seed \(seed): at a checkpoint a trigger had no change read that started after it (\(now.triggers) triggers, \(now.reads) reads)")
                    }
                }
                for task in work { await task.value }
                let quiet = await Self.settled(engine, followUps)
                let seen = wire.snapshot
                asksSeen += followUps.asks.count
                #expect(quiet, "seed \(seed): the account never went quiet, or its follow-up flag stayed set")
                #expect(seen.triggers > 0, "seed \(seed): precondition: the schedule fired triggers")
                #expect(seen.lastRead > seen.lastTrigger,
                        "seed \(seed): a trigger got no change read that started after it (\(seen.triggers) triggers, \(seen.reads) reads)")
                #expect(seen.overlaps.isEmpty, "seed \(seed): two passes of the account ran at once: \(seen.overlaps)")
                #expect(!followUps.outcomes.contains("threw"), "seed \(seed): a follow-up stage 2 failed: \(followUps.outcomes)")
                await engine.remove(accountId: Self.accountId)
            }
        }
        #expect(asksSeen > 0, "precondition: no seed made a trigger find the account busy")
        let busy = busyKinds.snapshot
        #expect(busy["change read", default: 0] > 0 && busy["stage 2", default: 0] > 0,
                "precondition: not every trigger kind found the account busy: \(busy)")
        #expect(checkpoints > 0, "precondition: no seed reached a checkpoint")
    }

    // MARK: - The scheduler

    @MainActor
    final class Stages {
        var triggers: [String] = []
        /// The first-paint gate was reached.
        var gateReached = false
    }

    /// RED while a tick during a poll only returned (#1313): it read nothing.
    @Test("A poll tick that lands during a poll runs stage 2 for every account")
    @MainActor
    func pollTickDuringAPollRunsStageTwo() async {
        let stages = Stages()
        let scheduler = SyncScheduler(foreground: true, pollActive: true, stageTwo: { stages.triggers.append($0) })
        await scheduler.poll()
        #expect(stages.triggers == ["poll tick during a poll"])
    }

    /// RED while a return during the previous return's work only skipped the
    /// herd (#1314): it read nothing. The stage 2 waits for the first paint,
    /// as the herd it stands for does.
    @Test("A return during a running return runs stage 2 for every account once the inbox has painted")
    @MainActor
    func returnDuringAReturnRunsStageTwo() async throws {
        let stages = Stages()
        let painted = AsyncStream<Bool>.makeStream()
        // A test that stops early still ends the parked stage 2.
        defer { painted.continuation.finish() }
        let scheduler = SyncScheduler(
            foreground: true,
            foregroundReady: {
                stages.gateReached = true
                for await ready in painted.stream { return ready }
                return false
            },
            stageTwo: { stages.triggers.append($0) })
        scheduler.stageTwoForReturnDuringReturn()
        var deadline = Date().addingTimeInterval(5)
        while !stages.gateReached, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stages.gateReached, "precondition: the stage 2 reached the first-paint gate")
        #expect(stages.triggers.isEmpty, "the stage 2 started before the inbox painted")
        painted.continuation.yield(true)
        deadline = Date().addingTimeInterval(5)
        while stages.triggers.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stages.triggers == ["return during a running return"])
    }

    /// The return path that skips the herd calls the stage 2 above.
    @Test("The return that skips the herd asks for its stage 2")
    func herdSkipBranchAsksForStageTwo() throws {
        let files = try DiagnosticPrintGateTests.appTargetSources()
        let scheduler = try #require(files.first { $0.relativePath == "TabMail/Services/SyncScheduler.swift" }).source
        let lines = scheduler.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let skip = try #require(lines.firstIndex { $0.contains("herd SKIPPED") }, "the herd-skip branch is gone")
        let next = lines[(skip + 1)...].first { !$0.isEmpty && !$0.hasPrefix("//") }
        #expect(next == "stageTwoForReturnDuringReturn()", "the herd-skip branch no longer asks for its stage 2")
    }

    /// The follow-up the engine asks for runs only where a stage 2 may start: in
    /// the foreground, inactive included (the app is on screen). In the
    /// background the flag waits for the next opening. RED with the app's state
    /// compared wrongly (`== .active`, or not at all).
    @Test("The follow-up stage 2 runs in the foreground only",
          arguments: [UIApplication.State.active, .inactive, .background])
    @MainActor
    func followUpRunsInTheForegroundOnly(state: UIApplication.State) async {
        let stages = Stages()
        let scheduler = SyncScheduler(foreground: true, stageTwo: { stages.triggers.append($0) })
        scheduler.applicationStateForTesting = state
        await scheduler.runSyncFollowUp(accountId: "follow-up-account")
        let expected = state == .background ? [] : ["follow-up follow-up-account"]
        #expect(stages.triggers == expected, "app state \(state.rawValue)")
    }

    /// The app's state for the stage 2 gates.
    enum GateMode: String, CaseIterable, Sendable {
        case normal
        case fastSync
        case demo
        /// The app is not in the foreground.
        case background
    }

    /// The app's state against the stage 2 gates. The follow-up stands in for a
    /// trigger's own read, which Fast Sync never held back (v1.11.2), so only
    /// demo mode and the background stop it. The stage 2 for every account (a
    /// poll tick during a poll, #1313; a return during a running return, #1314)
    /// keeps the poll's gate, which Fast Sync stops too: the poll skips its own
    /// reads then. RED with the Fast Sync term in the follow-up's gate (a push
    /// during Fast Sync read nothing until the next poll after it), with it
    /// dropped from the poll's gate or from the return's path alone, with demo
    /// mode left out of the follow-up's gate, or with the foreground left out of
    /// the poll's.
    @Test("Fast Sync holds back the poll's and the return's stage 2 but not the follow-up; demo mode and the background hold back all three",
          arguments: GateMode.allCases)
    @MainActor
    func stageTwoGatesForFastSyncAndDemo(mode: GateMode) async throws {
        let stages = Stages()
        let state = AccountManagerState.shared
        let demo = DemoModeStore.shared
        let saved = (state.fastSyncModeActive, demo.isActive)
        state.fastSyncModeActive = mode == .fastSync
        demo.isActive = mode == .demo
        defer {
            state.fastSyncModeActive = saved.0
            demo.isActive = saved.1
        }
        let scheduler = SyncScheduler(
            foreground: mode != .background, pollActive: true,
            foregroundReady: {
                stages.gateReached = true
                return true
            },
            stageTwo: { stages.triggers.append($0) })
        await scheduler.runSyncFollowUp(accountId: "follow-up-account")
        await scheduler.poll()
        stages.gateReached = false
        scheduler.stageTwoForReturnDuringReturn()
        let deadline = Date().addingTimeInterval(5)
        while !stages.gateReached, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stages.gateReached, "precondition: the return's stage 2 reached the first-paint gate")
        // The rest of the return's stage 2 runs on the main actor after the gate.
        try await Task.sleep(for: .milliseconds(100))
        let followUp = mode == .normal || mode == .fastSync ? ["follow-up follow-up-account"] : []
        let others = mode == .normal ? ["poll tick during a poll", "return during a running return"] : []
        #expect(stages.triggers == followUp + others, "mode \(mode.rawValue)")
    }

    /// RED without the first-paint gate: the follow-up's stage 2 could start
    /// before the inbox had painted (a background wake's work ending as the app
    /// opens). It waits for the first paint, as the opening's own reads do.
    @Test("The follow-up stage 2 waits for the inbox's first paint")
    @MainActor
    func followUpWaitsForTheFirstPaint() async throws {
        let stages = Stages()
        let painted = AsyncStream<Bool>.makeStream()
        defer { painted.continuation.finish() }
        let scheduler = SyncScheduler(
            foreground: true,
            foregroundReady: {
                stages.gateReached = true
                for await ready in painted.stream { return ready }
                return false
            },
            stageTwo: { stages.triggers.append($0) })
        let followUp = Task { await scheduler.runSyncFollowUp(accountId: "follow-up-account") }
        let deadline = Date().addingTimeInterval(5)
        while !stages.gateReached, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stages.gateReached, "precondition: the follow-up reached the first-paint gate")
        #expect(stages.triggers.isEmpty, "the stage 2 started before the inbox painted")
        painted.continuation.yield(true)
        await followUp.value
        #expect(stages.triggers == ["follow-up follow-up-account"])
    }
}

extension SyncEngine {
    /// The fuzz's trigger (`SyncFollowUpTests.fuzzEveryTriggerGetsALaterRead`):
    /// it arrives, its caller takes its time limit from the clock, and it calls
    /// the engine, in one step on the engine, as a caller does with no time
    /// between them. The fuzz's clock jumps inside held work, and held work
    /// hands the turn on only on the engine, so none can end between the
    /// arrival and the call: a jump after the limit was taken finds the account
    /// still busy. Nil when the trigger found the account busy.
    func fuzzTriggerArrives(
        stageTwo: Bool, account: Account, limit: TimeInterval,
        now: @Sendable () -> Date, arrives: @Sendable () -> Void
    ) async throws -> Bool? {
        arrives()
        let deadline = now().addingTimeInterval(limit)
        if stageTwo {
            return try await syncOrFollowUp(account: account, deadline: deadline)
        }
        let read = try await backgroundDeltaSync(account: account, deadline: deadline)
        return read?.changed
    }
}
