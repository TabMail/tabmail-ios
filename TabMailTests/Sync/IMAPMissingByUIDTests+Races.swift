/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import GRDB
import Testing
@testable import TabMail

/// A clock a test moves by hand, for the catch-up's hold bound and full-check
/// interval.
final class CatchUpTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

extension IMAPMissingByUIDTests.World {
    /// The provider's read alone (no apply), as the catch-up turn makes it, with
    /// the folder's owed count and the time the read began.
    func read(_ context: CatchUpContext) async throws -> (results: [CatchUpFolderResult], readStartedAt: Date, owedAtRead: Int) {
        let folder = try folder()
        let owed = FolderChangeState(raw: folder.changeState).selfHealOwed
        let readStartedAt = CatchUpWallClock.now()
        let results = await provider.catchUp(
            folders: [folder], localRows: SyncEngineCatchUpRowReader(pool: AppDatabase.syncPool), context: context)
        return (results, readStartedAt, owed)
    }

    /// One catch-up slice under `clock`, with `maxRequests` requests.
    func slice(maxRequests: Int = .max, clock: CatchUpTestClock,
               requestTimeout: TimeInterval = SyncConfig.catchUpRequestTimeoutSeconds) async {
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        let context = CatchUpContext(deadline: .distantFuture, clock: { clock.now }, maxRequests: maxRequests,
                                     listingRangeMessages: rangeMessages, requestTimeoutSeconds: requestTimeout)
        await engine.runCatchUp(provider: provider, folderIds: [folderId], context: context)
    }

    func catchUpState() throws -> IMAPCatchUpState? { IMAPCatchUpState.decode(try folder().catchUpState) }

    /// Rows of the account holding the message `id` names, as (folder path, UID).
    func rows(ofMessage id: Int) throws -> [(String, String)] {
        let accountId = accountId
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT folderPath, messageId FROM messageHeader
                WHERE accountId = ? AND rfc822MessageId LIKE ?
                """, arguments: [accountId, "%missing-by-uid-\(id)@%"])
        }.map { ($0["folderPath"], $0["messageId"]) }
    }

    @MainActor
    func drain() async throws {
        for _ in 0..<300 {
            let empty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            let quiet = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if empty && quiet { return }
            if quiet && !empty { await AccountManager.shared.drainPendingQueue() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension IMAPMissingByUIDTests {

    /// How many 10 ms polls a test waits for a suspended FETCH (5 s).
    static let suspensionPolls = 500
    /// The quiet phase's per-slice request budget: fewer requests than the
    /// fixture's four listing ranges need, so convergence requires resuming.
    static let quietSliceRequests = 3
    /// Upper bound on the quiet phase's slices before convergence is judged.
    static let quietSliceLimit = 60
    /// Slices a three-request budget needs to load a carried range of this
    /// file's 210-message folders: one header batch each, and one to spare.
    static let carriedLoadSlicesBound = 210 / SyncConfig.catchUpLoadBatchSize + 1
    /// The seeded schedule's seeds: 1...6 by default; the iteration knob
    /// `TABMAIL_CATCHUP_FUZZ_SEEDS` (a count) widens the sweep for a soak run
    /// (Testing Rule 11).
    static let fuzzSeeds: [UInt64] = {
        let count = ProcessInfo.processInfo.environment["TABMAIL_CATCHUP_FUZZ_SEEDS"].flatMap(UInt64.init) ?? 6
        return Array(1...max(1, count))
    }()
    /// Most milliseconds of seeded latency injected per server command in the
    /// seeded schedule: small, so every request stays far inside its timeout.
    static let fuzzLatencyMilliseconds = 20
    /// Turnover steps (between the listing and the header FETCH) the seeded
    /// schedule ran, and the seeds that finished, across the serialized seeds:
    /// the step is skipped when no row is held, so the sweep checks it still
    /// runs on some seed.
    static let fuzzTurnoverTally = Mutex<(turnovers: Int, seeds: Set<UInt64>)>((0, []))
    static var holdSeconds: TimeInterval { SyncConfig.backfillPageHoldMinutes * 60 }
    /// Past the hold bound.
    static var pastTheHold: TimeInterval { holdSeconds + 60 }
    /// Past the full-check interval and the hold bound: a new listing is due.
    static var pastTheNextCheck: TimeInterval { SyncConfig.catchUpFullCheckIntervalSeconds + holdSeconds + 60 }

    // MARK: - an old-epoch load after a completed reset

    @Test("A load read under one epoch is not inserted once a reset has stamped a new one; with no reset it is", arguments: [true, false])
    @MainActor
    func loadFromAnEarlierEpochIsRefused(_ resetCompletes: Bool) async throws {
        try await Self.withWorld("c1-\(resetCompletes)", server: Array(1...20) + Array(1001...1060), local: Array(1...20) + Array(1011...1060)) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.loaded.contains { $0.id == "12" }, "setup: the read loaded the missing message")
            if resetCompletes {
                // The reset reaction finished between the read and the insert:
                // the server numbers the folder anew, the rows are purged and
                // the folder is stamped with the new epoch, out of quarantine.
                let fresh = Self.epoch + 1
                w.server.setUidValidity(fresh, for: Self.path)
                let folderId = w.folderId
                try await w.pool.write { db in
                    try db.execute(sql: "DELETE FROM messageHeader WHERE folderId = ?", arguments: [folderId])
                    try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = ?, uidValidityResetPendingAt = NULL WHERE id = ?",
                                   arguments: [fresh, folderId])
                }
            }
            let stateBefore = try w.folder().catchUpState
            let outcome = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: read.readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            if resetCompletes {
                #expect(outcome == .skipped, "#1062: nothing read under the old epoch applies")
                #expect(try w.folder().catchUpState == stateBefore, "#1062: no catch-up state from the old epoch is written")
                let heldAfter = try w.held()
                #expect(heldAfter.isEmpty, "#1062: no row from the old numbering enters the folder: \(heldAfter)")
            } else {
                #expect(try w.held().contains(12), "#1062 control: under the same epoch the load lands")
            }
        }
    }

    @Test("A UIDVALIDITY purge that has run but not yet stamped the new epoch, between the read and the apply: nothing is inserted and no state is written")
    @MainActor
    func purgeInFlightBetweenReadAndApplyWritesNothing() async throws {
        try await Self.withWorld("c1-pending", server: Array(1...20) + Array(1001...1060), local: Array(1...20) + Array(1011...1060)) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.loaded.contains { $0.id == "12" }, "setup: the read loaded the missing message")
            // The purge step ran: rows and state gone, the reset marker set, the
            // stored epoch still the OLD one (the new stamp comes later).
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "DELETE FROM messageHeader WHERE folderId = ?", arguments: [folderId])
                try db.execute(sql: "UPDATE folder SET catchUpState = NULL, uidValidityResetPendingAt = ? WHERE id = ?",
                               arguments: [Date(), folderId])
            }
            let outcome = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: read.readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            #expect(outcome == .skipped, "#1062: nothing read before the purge applies")
            #expect(try w.held().isEmpty, "#1062: no row is inserted during the purge: \(try w.held())")
            #expect(try w.folder().catchUpState == nil, "#1062: no catch-up state is written over the purge")
        }
    }

    // MARK: - a mark that lands during the read

    @Test("An owed mark made while the read runs is kept by that read's completed listing, and the next listing settles it",
          arguments: [true, false])
    @MainActor
    func markDuringTheReadIsKept(_ stateIsNull: Bool) async throws {
        try await Self.withWorld("r1-\(stateIsNull)", server: Array(1...20) + Array(1001...1060), local: Array(1...20) + Array(1011...1060)) { w in
            let folderId = w.folderId
            try await w.dropLocal([12])
            try await w.pool.write { db in
                if stateIsNull {
                    try db.execute(sql: "UPDATE folder SET catchUpState = NULL WHERE id = ?", arguments: [folderId])
                } else {
                    try SyncEngine.markCatchUpLapse(folderId: folderId, db: db)
                }
            }
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing?.clean == true, "setup: the read completed a clean listing")
            // An unproven move retires now, between the read and the apply.
            try await w.markOwed()
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: read.readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            #expect((try w.changeState()).selfHealDue, "#1062: a listing that began before the mark does not settle it")
            try await w.dropLocal([13])
            try await w.workerRun()
            try w.expectHeldExactly(Array(1...20) + Array(1001...1060), "#1062: the next listing runs and loads what is missing")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing that starts after the mark settles it")
        }
    }

    @Test("A plain lapse marked while the read runs, with no owed mark, survives that read's apply and the next budgeted run lists again")
    @MainActor
    func plainLapseDuringTheReadIsKept() async throws {
        try await Self.withWorld("r1-plain", server: Array(1...20) + Array(1001...1060), local: Array(1...20) + Array(1011...1060)) { w in
            let folderId = w.folderId
            try await w.dropLocal([12])
            try await w.pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
            #expect(try w.catchUpState() != nil, "setup: the folder holds valid catch-up state")
            #expect((try w.changeState()).selfHealOwed == 0, "setup: no owed mark")
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing?.clean == true, "setup: the read completed a clean listing")
            // An on-demand window listing finds a gap between the read and the
            // apply: the gap trigger marks a lapse and creates no owed mark.
            try await w.pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
            #expect((try w.changeState()).selfHealOwed == 0, "setup: the gap trigger owes nothing")
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: read.readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            // A message behind the completed cursor goes missing; only the kept
            // lapse can bring a new listing before the next daily check.
            try await w.dropLocal([13])
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            try w.expectHeldExactly(Array(1...20) + Array(1001...1060),
                                    "the lapse marked during the read requests a listing the stale apply must not consume")
            #expect((try w.changeState()).selfHealOwed == 0, "no other forced mark was made")
        }
    }

    // MARK: - I4: a message the server holds but does not answer

    @Test("A missing message the header FETCH does not answer while SEARCH finds it: the others load across a budget stop, the listing holds it, passes over it after the bound, stays owed, and loads it at the next listing")
    @MainActor
    func unansweredMessageIsHeldThenPassedOver() async throws {
        let unanswered = 6
        let server = Array(1...210)
        try await Self.withWorld("i4-unanswered", server: server, local: server) { w in
            // UID 6 is a record the client cannot read without INTERNALDATE.
            var messages = server.map(Self.message)
            messages[unanswered - 1] = Self.message(unanswered, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [unanswered])
            try await w.dropLocal(Array(5...210))
            try w.expectNotHeld(Array(5...210), "I4")
            try await w.markOwed()
            let clock = CatchUpTestClock()

            // Four requests: the listing FETCH (1:1000), the range's membership
            // SEARCH, the first header batch (`SyncConfig.catchUpLoadBatchSize`
            // UIDs from 5, UID 6 unanswered), the SEARCH that finds 6. The second
            // batch cannot start.
            let batchEnd = 5 + SyncConfig.catchUpLoadBatchSize - 1
            await w.slice(maxRequests: 4, clock: clock)
            let held1 = Set(try w.held())
            #expect(Set([5] + Array(7...batchEnd)).isSubset(of: held1), "I4: the first batch's other messages load")
            #expect(held1.isDisjoint(with: (batchEnd + 1)...210), "I4: setup: the second batch did not start")
            #expect(!held1.contains(unanswered), "I4: the unanswered message is not loaded")
            #expect(try w.catchUpState()?.listing?.loadHeldSince != nil, "I4: setup: the SEARCH found 6 and the hold started")
            #expect(try w.catchUpState()?.listing?.nextUid == unanswered,
                    "#1062: the listing resumes at the earliest unresolved UID, not past it at the budget stop")
            #expect((try w.changeState()).selfHealDue, "I4: owed while a message is unresolved")

            // Inside the hold bound the later messages load; the listing still holds 6.
            await w.slice(clock: clock)
            #expect(Set((batchEnd + 1)...210).isSubset(of: Set(try w.held())), "I4: the messages after the budget stop load")
            #expect(try w.catchUpState()?.listing?.nextUid == unanswered, "I4: held inside the bound")
            #expect((try w.changeState()).selfHealDue, "I4: owed while held")

            // Past the bound: passed over, the listing completes as not clean.
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            #expect(try w.catchUpState()?.listing == nil, "I4: the listing completes after the hold bound")
            #expect(!(try w.held()).contains(unanswered), "I4: setup: still unanswered")
            #expect((try w.changeState()).selfHealDue, "I4: a listing that passed a message over does not settle the mark")

            // The server answers again: the next listing loads it and settles.
            w.server.suppressFetchInternalDate(in: Self.path, uids: [])
            clock.advance(by: Self.pastTheNextCheck)
            await w.slice(clock: clock)
            try w.expectHeldExactly(server, "I4")
            #expect(!(try w.changeState()).selfHealDue, "I4: settled once every message is held")
        }
    }

    /// How a slice stops before it proves the held UID.
    enum ProofStop: String, CaseIterable, Sendable {
        /// The slice's budget ends before the SEARCH.
        case budget
        /// The SEARCH fails.
        case searchError
    }

    @Test("#1062: slices that load later messages but stop before proving the held UID keep the FIRST hold: the listing passes over once the bound from the first hold ends, completes as not clean, stays owed, and the next listing restores the server's exact set",
          arguments: ProofStop.allCases)
    @MainActor
    func stopBeforeProvingTheHeldUIDKeepsTheFirstHold(_ stop: ProofStop) async throws {
        let unanswered = 6
        let server = Array(1...210)
        try await Self.withWorld("r1-\(stop.rawValue)", server: server, local: server) { w in
            var messages = server.map(Self.message)
            messages[unanswered - 1] = Self.message(unanswered, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [unanswered])
            try await w.dropLocal(Array(5...210))
            try w.expectNotHeld(Array(5...210), "#1062")
            try await w.markOwed()
            let clock = CatchUpTestClock()

            // Four requests: the listing FETCH, the range's membership SEARCH
            // (211...1000 is unused UID space), the first header batch, the
            // SEARCH that finds 6 still on the server. The hold starts here.
            await w.slice(maxRequests: 4, clock: clock)
            let firstHold = try #require(try w.catchUpState()?.listing?.loadHeldSince, "#1062: setup: the first slice holds 6")
            #expect(try w.catchUpState()?.listing?.nextUid == unanswered, "#1062: setup: held at 6")

            // Each later slice loads later messages, then stops before proving 6:
            // the listing FETCH, the membership SEARCH and the header batch run,
            // and the SEARCH for the unanswered 6 (the slice's second SEARCH)
            // has no budget or fails.
            func stoppedSlice() async {
                switch stop {
                case .budget:
                    await w.slice(maxRequests: 3, clock: clock)
                case .searchError:
                    w.server.failCommand(containing: "SEARCH", onMatch: 2)
                    await w.slice(clock: clock)
                    w.server.stopFailingCommands(containing: "SEARCH")
                }
            }
            clock.advance(by: Self.holdSeconds / 2)
            let before = Set(try w.held())
            await stoppedSlice()
            let afterFirstStop = Set(try w.held())
            // The slice's batch is 6 and the next held-out UIDs after the first
            // slice's batch: `SyncConfig.catchUpLoadBatchSize - 1` of them.
            let firstBatchEnd = 5 + SyncConfig.catchUpLoadBatchSize - 1
            let laterBatch = (firstBatchEnd + 1)...(firstBatchEnd + SyncConfig.catchUpLoadBatchSize - 1)
            #expect(Set(laterBatch).isSubset(of: afterFirstStop), "#1062: setup: the slice loaded the later messages of its batch")
            #expect(afterFirstStop.count > before.count, "#1062: setup: the slice loaded later messages")
            #expect(try w.catchUpState()?.listing?.nextUid == unanswered, "#1062: the listing still resumes at 6")
            #expect(try w.catchUpState()?.listing?.loadHeldSince == firstHold, "#1062: the hold keeps its first start")

            // Past the bound counted from the FIRST hold: passed over, not clean.
            // A slice whose budget ends before a load batch carries the rest of
            // the range (#1062), so the listing completes once the carried loads
            // are done, a bounded number of slices later.
            clock.advance(by: Self.holdSeconds / 2 + 60)
            await stoppedSlice()
            #expect(try w.catchUpState()?.listing?.loadHeldSince == nil, "#1062: past the bound from the first hold, 6 is no longer held")
            var carrySlices = 0
            while try w.catchUpState()?.listing != nil, carrySlices < Self.carriedLoadSlicesBound {
                await stoppedSlice()
                carrySlices += 1
            }
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completes once the bound from the first hold ends")
            #expect(!(try w.held()).contains(unanswered), "#1062: setup: 6 is still unanswered")
            #expect((try w.changeState()).selfHealDue, "#1062: a listing that passed 6 over does not settle the mark")

            w.server.suppressFetchInternalDate(in: Self.path, uids: [])
            clock.advance(by: Self.pastTheNextCheck)
            await w.slice(clock: clock)
            try w.expectHeldExactly(server, "#1062")
            #expect(!(try w.changeState()).selfHealDue, "#1062: settled once every message is held")
        }
    }

    // MARK: - a FLAGS reply that omits a message

    @Test("#1062: a FLAGS FETCH that omits a server message with no local row, below the window, after a new bookmark: the omission does not settle the owed mark, the unclean completion keeps a listing owed, and once replies recover the next catch-up slice alone loads it",
          arguments: [false, true])
    @MainActor
    func omittedFlagsRecordDoesNotSettleTheMark(_ stateIsNull: Bool) async throws {
        let omitted = 12
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("c1-omitted-\(stateIsNull)", server: server, local: server, tracked: true) { w in
            if stateIsNull {
                let folderId = w.folderId
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET catchUpState = NULL WHERE id = ?", arguments: [folderId])
                }
            }
            try await w.dropLocal([omitted])
            try w.expectNotHeld([omitted], "#1062")
            w.server.suppressFetchRecord(in: Self.path, uids: [omitted])
            try await w.markOwed()
            // A new bookmark is established after the mark.
            try await w.backgroundChangePass()
            let clock = CatchUpTestClock()

            await w.slice(clock: clock)
            #expect(!(try w.held()).contains(omitted), "#1062: setup: the omitted message is not loaded")
            #expect((try w.changeState()).selfHealDue, "#1062: a short reply does not settle the owed mark")

            // Past the hold bound: passed over, still not settled.
            var slices = 0
            while try w.catchUpState()?.listing != nil, slices < 4 {
                clock.advance(by: Self.pastTheHold)
                await w.slice(clock: clock)
                slices += 1
            }
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing does not list the same range forever")
            #expect((try w.changeState()).selfHealDue, "#1062: a listing that passed the omitted message over does not settle the mark")

            #expect(try w.folder().changeCursor != nil, "#1062: setup: the folder holds a bookmark, so only a lapse lists it")
            let afterPassOver = try #require(try w.catchUpState())
            #expect(afterPassOver.lapsedSinceLastListing, "#1062: the unclean completion leaves a listing owed")

            // Replies recover: a catch-up slice alone (no full sync) loads it,
            // however long the device waits, and the mark settles.
            w.server.suppressFetchRecord(in: Self.path, uids: [])
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            #expect(try w.held().contains(omitted), "#1062: the re-armed listing loads the message once replies recover")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the clean listing settles the mark")
            try await w.makeFullSyncDue()
            try await w.normalSync()
            try w.expectHeldExactly(server, "#1062")
            #expect(!(try w.changeState()).selfHealDue, "#1062: settled once every message is held")
        }
    }

    @Test("A header FETCH that answers none of a batch holds the listing, then passes over, and the next listing loads them")
    @MainActor
    func emptyHeaderReplyIsHeldThenPassedOver() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("empty-reply", server: server, local: server) { w in
            let gone = [11, 12, 13]
            var messages = server.map(Self.message)
            for uid in gone { messages[uid - 1] = Self.message(uid, date: "not a date") }
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: Set(gone))
            try await w.dropLocal(gone)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            try w.expectNotHeld(gone, "empty reply: nothing in the batch loads")
            #expect(try w.catchUpState()?.listing?.nextUid == gone[0], "empty reply: held at the first unanswered UID")
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            #expect((try w.changeState()).selfHealDue, "empty reply: still owed after the pass-over")
            w.server.suppressFetchInternalDate(in: Self.path, uids: [])
            clock.advance(by: Self.pastTheNextCheck)
            await w.slice(clock: clock)
            try w.expectHeldExactly(server, "empty reply")
            #expect(!(try w.changeState()).selfHealDue, "empty reply: settled")
        }
    }

    // MARK: - a budget stop before any load

    @Test("Slices whose membership SEARCH fails every time load nothing: the range is held from its start, passes over after the bound and completes as not clean, and the next listing loads what was missing. A slice whose budget ends before the SEARCH carries the range instead (anySliceBudgetConvergesWithoutRepeats)",
          arguments: [ProofStop.searchError])
    @MainActor
    func budgetStopBeforeAnyLoadIsBounded(_ stop: ProofStop) async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("r2-\(stop.rawValue)", server: server, local: server) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let clock = CatchUpTestClock()
            // 21...1000 is unused UID space, so the range 1:1000 needs its
            // membership SEARCH before anything in it is decided or loaded.
            func stoppedSlice() async {
                switch stop {
                case .budget:
                    await w.slice(maxRequests: 1, clock: clock)
                case .searchError:
                    w.server.failNextCommand(containing: "SEARCH")
                    await w.slice(clock: clock)
                    w.server.stopFailingCommands(containing: "SEARCH")
                }
            }
            await stoppedSlice()
            let first = try #require(try w.catchUpState()?.listing, "#1062: setup: a listing is in progress")
            #expect(first.nextUid == 1, "#1062: nothing in the range is decided: the listing resumes at its start")
            let firstHold = try #require(first.loadHeldSince, "#1062: a stop before the proof starts the hold")
            #expect(!(try w.held()).contains(12), "#1062: setup: nothing loaded")
            // Inside the bound the hold keeps its first start.
            clock.advance(by: Self.holdSeconds / 2)
            await stoppedSlice()
            #expect(try w.catchUpState()?.listing?.loadHeldSince == firstHold, "#1062: the hold keeps its first start")
            var slices = 0
            while try w.catchUpState()?.listing != nil, slices < 6 {
                clock.advance(by: Self.pastTheHold)
                await stoppedSlice()
                slices += 1
            }
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completes after the hold bound instead of listing the same range forever")
            #expect((try w.changeState()).selfHealDue, "#1062: a completion after a pass-over does not settle the mark")
            clock.advance(by: Self.pastTheNextCheck)
            await w.slice(clock: clock)
            try w.expectHeldExactly(server, "#1062")
            #expect(!(try w.changeState()).selfHealDue, "#1062: settled")
        }
    }

    // MARK: - I5(a): a move that completes after the read

    @Test("A user move of a missing message that completes after the catch-up read: it is not put back in the source, and after the protection lapses it is held once, in the destination")
    @MainActor
    func moveCompletingAfterTheReadIsNotUndone() async throws {
        let server = Array(1...20) + Array(1001...1060)
        let moved = 12
        try await Self.withWorld("i5a", server: server, local: server) { w in
            try await w.dropLocal([moved])
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.loaded.contains { $0.id == "\(moved)" }, "setup: the read loaded the message")

            // The move lands on the server, and the user's action completes after the read.
            w.server.setMessages(server.filter { $0 != moved }.map(Self.message), in: Self.path)
            w.server.setMessages([Self.message(1, date: TestFixtureDate.rfc2822(daysFromAnchor: -Self.ageInDays), id: moved)], in: "INBOX")
            AccountManager.shared.recordActionCompleted(
                accountId: w.accountId, messageKeys: ["\(moved)", "<missing-by-uid-\(moved)@example.com>"])
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: read.readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            #expect(!(try w.held()).contains(moved), "I5a: the read is older than the move: the message is not put back")

            await AccountManager.shared.clearRecentlyCompletedForTesting()
            AccountManager.shared.clearActionCompletionsForTesting()
            try await w.makeFullSyncDue()
            try await w.normalSync()
            try w.expectHeldExactly(server.filter { $0 != moved }, "I5a source")
            let rows = try w.rows(ofMessage: moved)
            #expect(rows.count == 1 && rows.first?.0 == "INBOX" && rows.first?.1 == "1",
                    "I5a: held once, in the destination, under its UID there: \(rows)")
        }
    }

    // MARK: - A failed write

    @Test("A load whose write fails keeps the listing where it was and the folder owed; once writes work, the next run loads it and settles")
    @MainActor
    func failedWriteKeepsTheListing() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("write-fail", server: server, local: server) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let stateBefore = try w.folder().catchUpState
            try await w.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER test_failInsert BEFORE INSERT ON messageHeader
                    WHEN NEW.messageId = '12'
                    BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
                    """)
            }
            try await w.workerRun()
            try w.expectNotHeld([12], "write failure")
            #expect(try w.folder().catchUpState == stateBefore, "write failure: the state is not moved past what did not land")
            #expect((try w.changeState()).selfHealDue, "write failure: still owed")
            try await w.pool.write { db in try db.execute(sql: "DROP TRIGGER test_failInsert") }
            try await w.workerRun()
            try w.expectHeldExactly(server, "write failure")
            #expect(!(try w.changeState()).selfHealDue, "write failure: settled")
        }
    }

    // MARK: - Unknown epoch: fail closed

    @Test("A folder whose epoch is not known loads nothing and stays owed")
    @MainActor
    func unknownEpochLoadsNothing() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("unknown-epoch", server: server, local: server) { w in
            let folderId = w.folderId
            try await w.dropLocal([12])
            try await w.markOwed()
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = NULL WHERE id = ?", arguments: [folderId])
            }
            await w.slice(clock: CatchUpTestClock())
            try w.expectNotHeld([12], "unknown epoch")
            #expect((try w.changeState()).selfHealDue, "unknown epoch: still owed")
        }
    }

    // MARK: - I7: seeded schedules through the real catch-up

    @Test("Seeded schedules of lost rows, budget cuts, partial header replies, short FETCH replies, user moves (also completing mid-slice), \\Deleted messages and epoch resets (also between the listing and the header FETCH) converge: every message held once, where the server holds it, under its UID and epoch",
          arguments: IMAPMissingByUIDTests.fuzzSeeds)
    @MainActor
    func seededSchedulesConverge(_ seed: UInt64) async throws {
        // Debug-gated diagnostics for a replay: `TEST_RUNNER_TABMAIL_TEST_DEBUG_LOG=1`
        // turns the app's debug logs on for this test, so a red seed shows its
        // mechanism in the log. Off by default.
        let debugLog = ProcessInfo.processInfo.environment["TABMAIL_TEST_DEBUG_LOG"] == "1"
        if debugLog { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true } }
        defer { if debugLog { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } } }
        // Acceptance (Testing Rule 11): this schedule rediscovers the removal of
        // the header load's epoch guard (`loadMissing`'s observed-epoch check:
        // the turnover arm loads a lost UID across the turnover) and the loss of
        // the listing's resume cursor between slices (the quiet phase never
        // reaches the last range). It does NOT see the catch-up's own `\Deleted`
        // filter: the insert funnel also skips `\Deleted` messages.
        var rng = SplitMix64(seed: seed)
        // Four listing ranges, so the quiet phase's budgeted slices must resume.
        let span = SyncConfig.catchUpListingMinRangeSpan
        let server = Array(1...60) + Array((span + 1)...(span + 40))
            + Array((2 * span + 1)...(2 * span + 30)) + Array((3 * span + 1)...(3 * span + 30))
        try await Self.withWorld("fuzz-\(seed)", server: server, local: server) { w in
            w.server.setSeededLatencyInjection(seed: seed, maxMilliseconds: Self.fuzzLatencyMilliseconds)
            let clock = CatchUpTestClock()
            let folderId = w.folderId
            var archive = server
            var stamp = Self.epoch
            var moved: [Int] = []
            // Messages whose header FETCH can come back unreadable.
            let fragile = Set(server.filter { _ in rng.pick(5) == 0 })
            func publish() {
                w.server.setMessages(archive.map { fragile.contains($0) ? Self.message($0, date: "not a date") : Self.message($0) }, in: Self.path)
            }
            publish()
            var reset = false
            // Oracle: messages the server flags `\Deleted`, never shown.
            var deleted = Set<Int>()

            /// A slice whose listing FETCH is suspended after the server read its
            /// messages, before it answers; `change` runs at that point.
            func sliceSuspendedAfterTheListing(_ change: @MainActor () async throws -> Void) async throws {
                // A listing is due, so the slice sends the FETCH this suspends.
                try await w.pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
                w.server.holdNextFetchAfterSnapshot(in: Self.path)
                let slice = Task { @MainActor in await w.slice(clock: clock) }
                var polls = 0
                while !w.server.isHoldingFetchAfterSnapshot(in: Self.path), polls < Self.suspensionPolls {
                    try await Task.sleep(for: .milliseconds(10))
                    polls += 1
                }
                let suspended = w.server.isHoldingFetchAfterSnapshot(in: Self.path)
                if suspended { try await change() }
                w.server.releaseFetchAfterSnapshot(in: Self.path)
                await slice.value
                try #require(suspended, "seed \(seed): setup: the slice's listing FETCH was suspended")
            }

            @MainActor func movableRow() async throws -> MessageHeader? {
                let rows = try await w.pool.read { db in
                    try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db)
                }.filter { !fragile.contains(Int($0.messageId) ?? 0) && !deleted.contains(Int($0.messageId) ?? 0) }
                return rows.isEmpty ? nil : rows[rng.pick(rows.count)]
            }

            func recordMove(of row: MessageHeader) {
                if let uid = Int(row.messageId), !w.server.uids(in: "INBOX", rfc822MessageId: "<missing-by-uid-\(uid)@example.com>").isEmpty {
                    archive.removeAll { $0 == uid }
                    moved.append(uid)
                }
            }

            func completeReset(to fresh: Int) async throws {
                try await w.pool.write { db in
                    try db.execute(sql: "DELETE FROM messageHeader WHERE folderId = ?", arguments: [folderId])
                    try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = ?, uidValidityResetPendingAt = NULL, catchUpState = NULL WHERE id = ?",
                                   arguments: [fresh, folderId])
                }
                try await w.markOwed()
            }

            for _ in 0..<10 {
                switch rng.pick(10) {
                case 8:
                    // An unsolicited FETCH for a UID outside the listing's range
                    // (another client's flag change) rides on the next FETCH,
                    // while some rows are lost: it is no part of the listing.
                    guard let uid = archive.last(where: { !deleted.contains($0) }) else { break }
                    let held = try w.held()
                    try await w.dropLocal(held.filter { _ in rng.pick(10) == 0 })
                    w.server.injectUnsolicitedFetch(in: Self.path, uid: uid, flags: [])
                    try await w.markOwed()
                case 4:
                    // Short FLAGS/header replies: some messages get no FETCH record.
                    w.server.suppressFetchRecord(in: Self.path, uids: Set(archive.filter { _ in rng.pick(6) == 0 }))
                    try await w.markOwed()
                case 5:
                    // An epoch turnover between the listing FETCH and the header
                    // FETCH and insert: nothing read after it is inserted.
                    // At least one held message the server still lists is lost,
                    // so the slice has a missing UID it would load. Right after
                    // a reset (rows purged, none loaded yet) no row is held and
                    // there is nothing to lose: the step is skipped.
                    let heldNow = try w.held()
                    var lost = Set(heldNow.filter { _ in rng.pick(4) == 0 })
                    if lost.isEmpty, let one = heldNow.first(where: { archive.contains($0) && !deleted.contains($0) }) { lost.insert(one) }
                    guard !lost.isEmpty else { break }
                    let old = stamp
                    stamp += 1
                    let fresh = stamp
                    try await w.dropLocal(Array(lost))
                    // The state after the loss: a correct slice adds nothing to it.
                    let afterLoss = Set(try w.held())
                    try await w.markOwed()
                    try await sliceSuspendedAfterTheListing {
                        w.server.setUidValidity(fresh, for: Self.path)
                    }
                    let afterSlice = Set(try w.held())
                    #expect(afterSlice.isSubset(of: afterLoss), "seed \(seed): nothing read across the turnover is inserted: \(afterSlice.subtracting(afterLoss).sorted())")
                    #expect(afterSlice.isDisjoint(with: lost), "seed \(seed): no lost UID is loaded across the turnover, under either epoch")
                    let stray = try await w.pool.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ? AND observedUidValidity IS NOT NULL AND observedUidValidity != ?",
                                         arguments: [folderId, old]) ?? 0
                    }
                    #expect(stray == 0, "seed \(seed): no row under the new epoch before the reaction")
                    Self.fuzzTurnoverTally.withLock { $0.turnovers += 1 }
                    try await completeReset(to: fresh)
                case 6:
                    // A user move that completes while the slice's listing is suspended.
                    guard let row = try await movableRow() else { break }
                    var move: Task<Void, Never>?
                    if let rfc = row.rfc822MessageId { w.server.expectMutation(rfc822MessageId: rfc) }
                    try await sliceSuspendedAfterTheListing {
                        move = Task { @MainActor in await AccountManager.shared.move([row], to: "INBOX") }
                    }
                    await move?.value
                    try await w.drain()
                    recordMove(of: row)
                case 7:
                    // A message the server flags `\Deleted`, lost locally: never shown.
                    let candidates = archive.filter { !deleted.contains($0) }
                    guard !candidates.isEmpty else { break }
                    let uid = candidates[rng.pick(candidates.count)]
                    w.server.setFlags(["\\Deleted"], in: Self.path, uid: uid)
                    deleted.insert(uid)
                    try await w.dropLocal([uid])
                    try await w.markOwed()
                case 0:
                    // The device loses some rows.
                    let held = try w.held()
                    let lost = (0..<(1 + rng.pick(8))).compactMap { _ in held.isEmpty ? nil : held[rng.pick(held.count)] }
                    try await w.dropLocal(lost)
                    try await w.markOwed()
                case 1:
                    // Partial header replies for some fragile messages.
                    w.server.suppressFetchInternalDate(in: Self.path, uids: Set(fragile.filter { _ in rng.pick(2) == 0 }))
                case 2:
                    // A slice cut by the budget, at some point in time.
                    if rng.pick(2) == 0 { clock.advance(by: Self.pastTheHold) }
                    await w.slice(maxRequests: 1 + rng.pick(4), clock: clock)
                case 3:
                    // The user moves a held message to the inbox.
                    let rows = try await w.pool.read { db in
                        try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db)
                    }.filter { !fragile.contains(Int($0.messageId) ?? 0) }
                    guard !rows.isEmpty else { break }
                    let row = rows[rng.pick(rows.count)]
                    if let rfc = row.rfc822MessageId { w.server.expectMutation(rfc822MessageId: rfc) }
                    await AccountManager.shared.move([row], to: "INBOX")
                    try await w.drain()
                    if let uid = Int(row.messageId), !w.server.uids(in: "INBOX", rfc822MessageId: "<missing-by-uid-\(uid)@example.com>").isEmpty {
                        archive.removeAll { $0 == uid }
                        moved.append(uid)
                    }
                default:
                    // Once: a UIDVALIDITY reset whose reaction completes (rows
                    // purged, the new epoch stamped, the folder out of quarantine).
                    guard !reset else { break }
                    reset = true
                    stamp += 1
                    let fresh = stamp
                    w.server.setUidValidity(fresh, for: Self.path)
                    try await completeReset(to: fresh)
                }
                let currentStamp = stamp
                let wrongEpoch = try await w.pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ? AND observedUidValidity IS NOT NULL AND observedUidValidity != ?",
                                     arguments: [folderId, currentStamp]) ?? 0
                }
                #expect(wrongEpoch == 0, "seed \(seed): no row under another epoch than the folder's")
            }

            let tally = Self.fuzzTurnoverTally.withLock { tally in
                tally.seeds.insert(seed)
                return tally
            }
            if Set(Self.fuzzSeeds).isSubset(of: tally.seeds) {
                #expect(tally.turnovers > 0, "setup: the turnover step ran on some seed of the sweep")
            }

            // Quiet: every reply readable, the protection lapsed, time passes.
            w.server.suppressFetchInternalDate(in: Self.path, uids: [])
            w.server.suppressFetchRecord(in: Self.path, uids: [])
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            AccountManager.shared.clearActionCompletionsForTesting()
            // A turnover's real reset reaction can leave the folder in quarantine
            // (its flag set after the step stamped the new epoch): the app at
            // rest re-drives it, resyncs and walks older mail (`reachRest`).
            try await w.reachRest("seed \(seed)")
            // The device loses the last range's rows: only a slice that resumes
            // past the earlier ranges reaches them, and no unrestricted repair runs
            // before convergence is checked (a resume cursor lost between slices
            // restarts every slice at the first range and never gets there).
            let lastRange = archive.filter { $0 > 3 * span }
            try await w.dropLocal(lastRange)
            try await w.markOwed()
            let expected = Set(archive.filter { !deleted.contains($0) })
            var quietSlices = 0
            while try Set(w.held()) != expected, quietSlices < Self.quietSliceLimit {
                clock.advance(by: Self.pastTheNextCheck)
                await w.slice(maxRequests: Self.quietSliceRequests, clock: clock)
                quietSlices += 1
            }
            #expect(quietSlices > 1, "seed \(seed): setup: the quiet phase spans more than one slice")
            if DebugModeManager.isLoggingEnabled() {
                // Diagnostic (#1062): the Archive's reset flag and catch-up state
                // when the quiet phase ends.
                let (pending, catchUp) = try await w.pool.read { db in
                    (try String.fetchOne(db, sql: "SELECT CAST(uidValidityResetPendingAt AS TEXT) FROM folder WHERE id = ?", arguments: [folderId]),
                     try String.fetchOne(db, sql: "SELECT catchUpState FROM folder WHERE id = ?", arguments: [folderId]))
                }
                print("[CatchUpTest] seed \(seed) quiet end: reset=\(reset) resetPendingAt=\(pending ?? "nil") catchUpState=\(catchUp ?? "nil") slices=\(quietSlices)")
            }
            try w.expectHeldExactly(Array(expected), "seed \(seed)")
            // Every settled row, recovered ones included, is the server's message
            // at its UID under the folder's current epoch: no NULL epoch.
            try w.expectIdentityAndEpoch(stamp, "seed \(seed)")
            for uid in moved {
                let rows = try w.rows(ofMessage: uid)
                #expect(rows.count == 1 && rows.first?.0 == "INBOX", "seed \(seed): moved \(uid) is held once, in the inbox: \(rows)")
            }
        }
    }
}
