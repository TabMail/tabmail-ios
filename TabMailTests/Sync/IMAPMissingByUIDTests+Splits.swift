/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The catch-up's listing ranges on a bunched folder and a slow link, and its
/// load floor before the older-mail walk starts (#1062). Same world as
/// `IMAPMissingByUIDTests`.
extension IMAPMissingByUIDTests {

    /// The request timeout of a test whose request times out, the production
    /// one: the request that must time out is held by the server
    /// (`FakeIMAPServer.holdListingFetches`, `holdNextCommand`) until the test
    /// releases it, so it times out whatever the timeout's length, while every
    /// request the server answers takes far less than this on a busy machine,
    /// so none of them times out. Nothing is timed against it.
    static let heldRequestTimeout: TimeInterval = SyncConfig.catchUpRequestTimeoutSeconds
    /// A run's slice in those tests, the production one: shorter than one
    /// request's timeout (`catchUpSliceSeconds` 2 s against
    /// `catchUpRequestTimeoutSeconds` 3 s), so a timeout spends its slice.
    /// *Superseded (#1062):* a 0.3 s slice, a 0.5 s timeout, a slow answer after
    /// 1 s and slices 1.2 s apart: an answered request could reach the short
    /// timeout on a busy machine, and the slow answer raced it from the other side.
    static let heldRunSliceSeconds: TimeInterval = SyncConfig.catchUpSliceSeconds
    static let slowLinkDeadline: TimeInterval = 180

    /// The `lo...hi` of each listing FETCH (`UID FETCH lo:hi (UID FLAGS)`) among `commands`, in order.
    static func listingRanges(_ commands: some Collection<String>) -> [ClosedRange<Int>] {
        commands.compactMap { command -> ClosedRange<Int>? in
            let upper = command.uppercased()
            guard upper.contains("FETCH"), upper.contains("FLAGS"), !upper.contains("ENVELOPE") else { return nil }
            let tokens = upper.split(separator: " ")
            guard let index = tokens.firstIndex(of: "FETCH"), index + 1 < tokens.count else { return nil }
            // `lo:hi`, or a one-UID range written as its UID alone (`7`).
            let bounds = tokens[index + 1].split(separator: ":").compactMap { Int($0) }
            if bounds.count == 1 { return bounds[0]...bounds[0] }
            guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
            return bounds[0]...bounds[1]
        }
    }

    /// Run the worker on the scaled slow link, run after run, until the
    /// folder's listing completes, and check the timeout path: a run asks the
    /// folder nothing after its listing request timed out, so each run holds at
    /// most one listing timeout and the listing completes across runs, all on
    /// the slow link; and a range that timed out is never asked again at its own
    /// width. `ceiling` is the test's bound on listing requests; the returned
    /// cost counts every listing request of those runs. The slow link holds
    /// every listing FETCH that matches more than `overRecords` messages
    /// (`FakeIMAPServer.holdListingFetches`), so exactly those time out.
    /// *Superseded (#1062):* one worker run, in which "the listing completes
    /// across calls": the run now leaves the folder out after its timeout.
    @MainActor
    static func runOnSlowLink(_ w: World, overRecords: Int, ceiling: Int) async throws -> (fetches: Int, ranges: [ClosedRange<Int>]) {
        w.server.holdListingFetches(in: path, overRecords: overRecords)
        defer { w.server.stopHoldingListingFetches(in: path) }
        let sizesBefore = w.server.listingFetchSizes(in: path).count
        let start = w.server.recordedCommands().count
        // Every run but the last ends on a listing timeout, and every timeout is
        // a listing request within the ceiling.
        let runBound = ceiling + 1
        var runs = 0
        repeat {
            let runSizesBefore = w.server.listingFetchSizes(in: path).count
            try await w.workerRun(deadlineIn: slowLinkDeadline, requestTimeout: heldRequestTimeout, sliceSeconds: heldRunSliceSeconds)
            // The run gave its held FETCH up: let it answer, and join the
            // server's handler of it before reading what the run asked. The
            // answer reaches no client (the timeout closed that session), and
            // the next run asks on a new one.
            let inProgress = w.server.heldRequestsInProgress()
            w.server.releaseListingFetches(in: path)
            if inProgress > 0 {
                #expect(try await joinHeldHandlers(w.server, below: inProgress), "setup: the released listing FETCH's handler went on")
            }
            runs += 1
            // Nothing after the run's held (timed-out) listing request: not a
            // wider one, and not a smaller retry that answers either.
            let runSizes = Array(w.server.listingFetchSizes(in: path).dropFirst(runSizesBefore))
            if let timedOutAt = runSizes.firstIndex(where: { $0 > overRecords }) {
                #expect(timedOutAt == runSizes.count - 1,
                        "#1062: a run asks the folder nothing after its listing request timed out: run \(runs) listed \(runSizes)")
            }
        } while try w.catchUpState()?.listing != nil && runs < runBound
        // The cost below then counts every listing request of the repair: none
        // is left for a later run on a link without the delay.
        #expect(try w.catchUpState()?.listing == nil,
                "#1062: the listing completed on the slow link, within \(runBound) runs (\(runs) ran)")
        let commands = Array(w.server.recordedCommands().dropFirst(start))
        let ranges = listingRanges(commands)
        let sizes = Array(w.server.listingFetchSizes(in: path).dropFirst(sizesBefore))
        #expect(ranges.count == sizes.count, "setup: every listing FETCH is parsed: \(ranges.count) vs \(sizes.count)")
        let timedOut = zip(ranges, sizes).filter { $0.1 > overRecords }.map(\.0)
        #expect(!timedOut.isEmpty, "setup: the link timed a listing range out")
        for (index, range) in ranges.enumerated() where timedOut.contains(range) {
            let askedAgain = ranges[(index + 1)...].first {
                $0.lowerBound == range.lowerBound && $0.count >= range.count
            }
            #expect(askedAgain == nil,
                    "#1062: from where a range timed out, no later range is as wide again: \(range), then \(askedAgain.map { "\($0)" } ?? "")")
        }
        return (listingCost(commands).fetches, ranges)
    }

    // MARK: - Range widths (pure)

    @Test("The first listing range's width: the minimum with no UIDNEXT, no count or a count of 0; scaled by mean density, rounded up; clamped to the configured minimum and maximum")
    func firstListingRangeSpanEdges() {
        let minimum = SyncConfig.catchUpListingMinRangeSpan, maximum = SyncConfig.catchUpListingMaxRangeSpan
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: 500, uidNext: nil) == minimum)
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: 500, uidNext: 1) == minimum)
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: nil, uidNext: 5_000_001) == minimum)
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: 0, uidNext: 5_000_001) == minimum,
                "a stored count of 0 is unknown, never one range for the whole folder")
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: 5000, uidNext: 5001) == minimum,
                "a dense folder: the minimum width")
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: 3000, uidNext: 10_001) == 3334,
                "10000 / 3000 * 1000, rounded up")
        #expect(IMAPProvider.listingRangeSpan(messages: 1000, exists: 3, uidNext: 1_000_000_001) == maximum,
                "a very sparse folder: the maximum width")
    }

    @Test("The next listing range's width: the maximum after an empty range; scaled from the previous range's own count, rounded up; clamped")
    func nextListingRangeSpanEdges() {
        let minimum = SyncConfig.catchUpListingMinRangeSpan, maximum = SyncConfig.catchUpListingMaxRangeSpan
        #expect(IMAPProvider.nextListingRangeSpan(messages: 1000, width: 5000, held: 0) == maximum)
        #expect(IMAPProvider.nextListingRangeSpan(messages: 1000, width: 10_000, held: 3000) == 3334)
        #expect(IMAPProvider.nextListingRangeSpan(messages: 1000, width: 1000, held: 1000) == minimum)
        #expect(IMAPProvider.nextListingRangeSpan(messages: 1000, width: 2000, held: 1) == 2_000_000)
        #expect(IMAPProvider.nextListingRangeSpan(messages: 1000, width: maximum, held: 1) == maximum)
    }

    @Test("The walk's splitting rule: halves cover the range exactly; a one-UID range has none; the walk retries its upper half first and sets a one-UID range aside unconfirmed; a timeout, not a cancellation, calls for a smaller range")
    func walkSplitsAFailedRangeInHalves() async {
        let halves = UIDWalkCursor.halves(from: 101, to: 200)
        #expect(halves?.lower.from == 101 && halves?.lower.to == 150 && halves?.upper.from == 151 && halves?.upper.to == 200)
        let odd = UIDWalkCursor.halves(from: 1, to: 2)
        #expect(odd?.lower.from == 1 && odd?.lower.to == 1 && odd?.upper.from == 2 && odd?.upper.to == 2)
        #expect(UIDWalkCursor.halves(from: 7, to: 7) == nil)

        let cursor = UIDWalkCursor(startCursor: 200, chunkSize: 100)
        let first = await cursor.nextRange()
        #expect(first?.from == 101 && first?.to == 200)
        await cursor.failRangeSmaller(from: 101, to: 200)
        let retryA = await cursor.nextRange(), retryB = await cursor.nextRange()
        #expect(retryA?.from == 151 && retryA?.to == 200, "the walk's upper half first")
        #expect(retryB?.from == 101 && retryB?.to == 150)

        let single = UIDWalkCursor(startCursor: 1, chunkSize: 1)
        _ = await single.nextRange()
        await single.failRangeSmaller(from: 1, to: 1)
        #expect(await single.hasFailedThisWalk, "a one-UID range is set aside for this walk")
        #expect(await single.currentCursor >= 1, "and never confirmed")
        #expect(!(await single.isComplete))

        #expect(UIDWalkCursor.failureCallsForSmallerRange(TimeoutError(duration: 1)))
        #expect(!UIDWalkCursor.failureCallsForSmallerRange(CancellationError()))
    }

    // MARK: - Ranges on a bunched folder and a slow link

    /// 200 messages low in the UID space, then 5000 in one dense band near
    /// UIDNEXT: the folder's mean density says one range holds about 1000, but
    /// the band packs 5000 into a range of that width.
    static let bunchedServer = Array(1...200) + Array(1_000_001...1_005_000)

    @Test("A bunched folder on a slow link whose slice is shorter than one request: a range that times out stops the folder for that run with its width halved, the next run goes on from the same place, and the listing completes across runs within a request ceiling")
    @MainActor
    func bunchedFolderListsWithinACeiling() async throws {
        // Debug-gated diagnostics for one run (#1062): `TEST_RUNNER_TABMAIL_TEST_DEBUG_LOG=1`.
        let debugLog = ProcessInfo.processInfo.environment["TABMAIL_TEST_DEBUG_LOG"] == "1"
        if debugLog { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true } }
        defer { if debugLog { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } } }
        let server = Self.bunchedServer
        let tooMany = 2 * SyncConfig.catchUpListingRangeMessages
        try await Self.withWorld("bunched", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let missing = [50, 1_000_500, 1_004_900]
            try await w.dropLocal(missing)
            try await w.markOwed()
            // Ceiling: the band halves at most log2(UIDNEXT) times on its way
            // down, plus one range per `tooMany / 2` messages once it answers.
            let halvings = Int(log2(Double(server.max()! + 1)).rounded(.up))
            let answering = server.count / (tooMany / 2) + 1
            let ceiling = 2 * halvings + answering
            let cost = try await Self.runOnSlowLink(w, overRecords: tooMany, ceiling: ceiling)
            #expect(cost.fetches <= ceiling, "a bounded number of listing requests: \(cost.fetches) > \(ceiling)")
            // The slow-link runs did the repair, so the cost above bounds it.
            try w.expectHeldExactly(server, "#1062 bunched, on the slow link")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing completed and settled on the slow link")
            // Once the app is at rest, every message the server holds is held.
            try await w.reachRest("#1062 bunched")
            try w.expectHeldExactly(server, "#1062 bunched")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing completed and settled")
        }
    }

    @Test("A folder whose stored message count is 0 while its UIDNEXT is known: its first listing range has the minimum width, never the whole folder, and no listing request answers more than about one range's messages")
    @MainActor
    func unknownCountListsInRangesOfTheMinimumWidth() async throws {
        let server = Array(1...5000)
        let messages = SyncConfig.catchUpListingRangeMessages
        try await Self.withWorld("count-zero", server: server, local: server, rangeMessages: messages) { w in
            let missing = [10, 2500, 4990]
            try await w.dropLocal(missing)
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET totalCount = 0 WHERE id = ?", arguments: [folderId])
            }
            try await w.markOwed()
            let sizesBefore = w.server.listingFetchSizes(in: Self.path).count
            let start = w.server.recordedCommands().count
            try await w.workerRun()
            let sizes = Array(w.server.listingFetchSizes(in: Self.path).dropFirst(sizesBefore))
            let cost = Self.listingCost(w.server.recordedCommands().dropFirst(start))
            #expect(!sizes.isEmpty, "setup: the listing ran")
            #expect((sizes.max() ?? 0) <= max(messages, SyncConfig.catchUpListingMinRangeSpan),
                    "#1062: no listing request covers the whole folder: \(sizes)")
            // One listing FETCH per range, plus one more per slice boundary: a
            // slice's request cap can end a call inside a range (after its FETCH,
            // or between its SEARCH and its load), and the next call lists that
            // range again from where it stands. Slices are counted from the
            // requests the run sent (`catchUpSliceMaxRequests` each).
            let requests = w.server.recordedCommands().dropFirst(start).filter {
                let upper = $0.uppercased()
                return upper.contains("FETCH") || upper.contains("SEARCH")
            }.count
            let slices = (requests + SyncConfig.catchUpSliceMaxRequests - 1) / SyncConfig.catchUpSliceMaxRequests
            let ranges = (server.count + messages - 1) / messages
            let ceiling = ranges + max(0, slices - 1)
            #expect(cost.fetches <= ceiling, "#1062: about one listing request per range: \(cost.fetches) > \(ceiling)")
            let asked = Self.listingRanges(w.server.recordedCommands().dropFirst(start))
            #expect(Set(asked.map(\.lowerBound)).count == asked.count,
                    "#1062: no slice lists a range again that an earlier slice listed: \(asked)")
            try w.expectHeldExactly(server, "#1062 count zero")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing completed and settled")
        }
    }

    @Test("A first listing range that times out, with a slice shorter than one request: each run holds at most one timeout, the next run asks half its width from the same place, never the full width again, and the listing completes across runs within a request ceiling")
    @MainActor
    func firstRangeThatTimesOutCompletesAfterSplits() async throws {
        // Debug-gated diagnostics for one run (#1062): `TEST_RUNNER_TABMAIL_TEST_DEBUG_LOG=1`.
        let debugLog = ProcessInfo.processInfo.environment["TABMAIL_TEST_DEBUG_LOG"] == "1"
        if debugLog { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true } }
        defer { if debugLog { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } } }
        let server = Array(1...3000)
        let messages = SyncConfig.catchUpListingRangeMessages
        let tooMany = messages / 2
        try await Self.withWorld("first-timeout", server: server, local: server, rangeMessages: messages) { w in
            let missing = [5, 1500, 2995]
            try await w.dropLocal(missing)
            try await w.markOwed()
            // Every answering range holds about `tooMany`; each one before it
            // timed out at most once at twice its width.
            let ceiling = 2 * (server.count / tooMany + 1)
            let cost = try await Self.runOnSlowLink(w, overRecords: tooMany, ceiling: ceiling)
            let first = try #require(cost.ranges.first, "setup: the listing ran")
            #expect(first.count > tooMany, "setup: the first range was too large for the link: \(first)")
            #expect(cost.fetches <= ceiling, "#1062: a bounded number of listing requests: \(cost.fetches) > \(ceiling)")
            try w.expectHeldExactly(server, "#1062 first range timed out")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the listing completed and settled")
        }
    }

    // MARK: - Carried ranges: every slice keeps what it proved (#1062)

    /// The server and missing UIDs of the carried-range tests: three listing
    /// ranges of the minimum width, one missing message in each.
    static let carryServer = Array(1...3000)
    static let carryMissing = [5, 1500, 2995]
    /// Requests the repair needs at most: per range its listing FETCH, its
    /// membership SEARCH and one header batch.
    static var carryRequestsNeeded: Int {
        let ranges = (carryServer.count + SyncConfig.catchUpListingMinRangeSpan - 1) / SyncConfig.catchUpListingMinRangeSpan
        return 3 * ranges
    }

    @Test("Any slice budget that fits one request repairs the folder in a bounded number of slices, and no slice throws away what it proved: no listing range is listed twice, no membership proof is asked twice",
          arguments: [1, 2, 3, 4])
    @MainActor
    func anySliceBudgetConvergesWithoutRepeats(budget: Int) async throws {
        let server = Self.carryServer
        try await Self.withWorld("carry-budget-\(budget)", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            let start = w.server.recordedCommands().count
            // Every slice sends at least one request of new work, and one more
            // slice finds the listing complete.
            let bound = Self.carryRequestsNeeded + 1
            var slices = 0
            while try w.held() != server || w.catchUpState()?.listing != nil, slices < 2 * bound {
                await w.slice(maxRequests: budget, clock: clock)
                slices += 1
            }
            #expect(slices <= bound, "#1062: budget \(budget): the repair converges within \(bound) slices: \(slices)")
            try w.expectHeldExactly(server, "#1062 budget \(budget)")
            let commands = Array(w.server.recordedCommands().dropFirst(start))
            let asked = Self.listingRanges(commands)
            #expect(Set(asked.map(\.lowerBound)).count == asked.count,
                    "#1062: budget \(budget): no range is listed again: \(asked)")
            let cost = Self.listingCost(commands)
            #expect(cost.searches <= asked.count,
                    "#1062: budget \(budget): one membership proof per listed range: \(cost.searches) for \(asked.count)")
        }
    }

    /// What happens to a carried missing UID between the call that carried it
    /// and the call that loads it.
    enum CarriedUidGoes: String, CaseIterable, Sendable {
        /// Another path wrote its row first.
        case alreadyLocal
        /// The server expunged it.
        case expunged
    }

    @Test("A carried missing UID that went stale before its load (another path wrote it, or the server expunged it) loads nothing, is never fetched again or held, and writes no row",
          arguments: CarriedUidGoes.allCases)
    @MainActor
    func staleCarriedUidWritesNothing(_ goes: CarriedUidGoes) async throws {
        let server = Self.carryServer
        let stale = Self.carryMissing[0]
        try await Self.withWorld("carry-stale-\(goes.rawValue)", server: server, local: server,
                                 rangeMessages: SyncConfig.catchUpListingRangeMessages) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "CREATE TEMP TABLE keptRow AS SELECT * FROM messageHeader WHERE folderId = ? AND messageId = ?",
                               arguments: [folderId, "\(stale)"])
            }
            try await w.dropLocal(Self.carryMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            // One request after the listing's start: the first range's listing
            // FETCH; its proof and load are carried.
            await w.slice(maxRequests: Self.newListingStartRequests + 1, clock: clock)
            let carried = try #require(try w.catchUpState()?.listing?.carried, "setup: the range is carried")
            #expect(carried.missing.contains(UInt32(stale)), "setup: the carried range names \(stale)")
            var expected = server
            switch goes {
            case .alreadyLocal:
                try await w.pool.write { db in
                    try db.execute(sql: "INSERT INTO messageHeader SELECT * FROM keptRow")
                }
            case .expunged:
                w.server.setMessages(server.filter { $0 != stale }.map(Self.message), in: Self.path)
                expected = server.filter { $0 != stale }
            }
            let start = w.server.recordedCommands().count
            var heldStale = 0
            _ = try await Self.slicesUntilRepaired(w, expected: expected, maxRequests: 1, clock: clock,
                                                   bound: 2 * (Self.carryRequestsNeeded + 1)) {
                if let listing = try w.catchUpState()?.listing, listing.nextUid == stale, listing.loadHeldSince != nil {
                    heldStale += 1
                }
            }
            try w.expectHeldExactly(expected, "#1062 stale carried UID (\(goes.rawValue))")
            #expect(heldStale == 0, "#1062: the stale UID is never held: \(heldStale) slice(s)")
            let asked = Self.headerFetches(w.server.recordedCommands().dropFirst(start)).filter { Self.uidSet($0).contains(stale) }
            switch goes {
            case .alreadyLocal:
                #expect(asked.isEmpty, "#1062: a carried UID already local is not fetched again: \(asked)")
            case .expunged:
                #expect(asked.count <= 1, "#1062: an expunged carried UID is asked at most once: \(asked)")
            }
            let rows = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ? AND messageId = ?",
                                 arguments: [folderId, "\(stale)"]) ?? 0
            }
            #expect(rows == (goes == .alreadyLocal ? 1 : 0), "#1062: no header row is written for the stale UID: \(rows)")
        }
    }

    @Test("A carried range names at most the configured number of UIDs: past it the range is cut at the UID that reaches it, keeping its lowest UIDs, so the carry is bounded and the listing still moves")
    func carriedRangeIsCapped() {
        let cap = SyncConfig.catchUpCarriedUidCap
        let missing = (1...UInt32(cap + 10)).map { $0 * 2 }
        let carry = IMAPProvider.carry(lo: 1, hi: Int(missing.last!) + 5, candidates: [], missing: missing,
                                       deletedListed: [], proven: true, heldFloor: missing.last, loadsFrom: 1)
        #expect(carry.missing.count == cap, "#1062: at most \(cap) carried UIDs: \(carry.missing.count)")
        #expect(carry.missing == Array(missing.prefix(cap)), "#1062: the carry keeps the range's lowest UIDs")
        #expect(carry.hi == Int(missing[cap - 1]), "#1062: the range is cut at the UID that reaches the cap")
        #expect(carry.hi >= carry.lo, "#1062: the cut range is not empty, so the listing moves past it")
        #expect(carry.heldFloor == nil, "#1062: a held UID past the cut is left to the next listing")
        #expect(carry.loadsFrom == 1, "#1062: the carry keeps the load floor its range was listed under")
        let small = IMAPProvider.carry(lo: 1, hi: 1000, candidates: [7], missing: [5], deletedListed: [9], proven: false, heldFloor: nil, loadsFrom: nil)
        #expect(small.hi == 1000 && small.missing == [5] && small.candidates == [7] && small.deletedListed == [9],
                "#1062: a range under the cap is carried whole")
    }

    // MARK: - The load floor before the walk starts

    @Test("Wi-Fi-only on cellular, the older-mail walk not started, rows infinite scroll wrote far below the window: a catch-up loads none of the older mail between them and the window")
    @MainActor
    func infiniteScrollRowsDoNotPullTheFloorDown() async throws {
        let server = Array(1...400)
        let window = Array((server.count - SyncConfig.syncMessageLimit + 1)...server.count)
        let scrolled = Array(1...5)
        try await Self.withWorld("floor-scroll", server: server, local: window, walkStarted: false) { w in
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            let floor = try #require(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch), "setup: the window listing recorded its floor")
            #expect(floor == window[0], "setup: the floor is where the window listing reached")
            // Infinite scroll writes old rows without moving the walk.
            try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: Self.path, uids: scrolled, pool: w.pool)
            let folderId = w.folderId
            try await w.pool.write { db in
                for uid in scrolled {
                    try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = ?, observedUidValidity = ? WHERE folderId = ? AND messageId = ?",
                                   arguments: ["<missing-by-uid-\(uid)@example.com>", Self.epoch, folderId, "\(uid)"])
                }
            }
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runBackfillCycle(account: try w.account(), walkAllowed: false)
            let headerFetches = w.server.recordedCommands().dropFirst(start).filter {
                $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE")
            }
            let holes = Set((scrolled.max()! + 1)..<window[0])
            let loadedHoles = holes.filter { uid in headerFetches.contains { Self.uidSet($0).contains(uid) } }
            #expect(loadedHoles.isEmpty, "#1062: no older mail below the window floor is downloaded: \(loadedHoles.sorted().prefix(20))")
            try w.expectHeldExactly(scrolled + window, "#1062 scroll")
            let folder = try w.folder()
            #expect(!folder.backfillComplete && folder.backfillUidCursor == nil, "setup: the walk has still not started")
        }
    }
    // MARK: - The window floor's bookkeeping

    @Test("The window floor: recorded as the lowest any window listing reached, never raised by a later one; a NULL or non-object state becomes an object holding it; a catch-up's own state write carries it")
    @MainActor
    func windowFloorIsKeptAndCarried() async throws {
        let server = Array(1...20)
        try await Self.withWorld("floor-books", server: server, local: server, walkStarted: false) { w in
            let folderId = w.folderId
            func floor() throws -> Int? { CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) }
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            #expect(try floor() == 1, "setup: the window listing recorded its floor")

            // A later listing that reached higher never raises it.
            try await w.pool.write { db in try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 9, epoch: Self.epoch, db: db) }
            #expect(try floor() == 1, "#1062: the floor is the lowest any window listing reached")
            try await w.pool.write { db in try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 0, epoch: Self.epoch, db: db) }
            #expect(try floor() == 0, "#1062: a listing that reached lower lowers it")

            // The catch-up rewrites the folder's state; the floor survives it.
            try await w.markOwed()
            let before = try w.folder().catchUpState
            try await w.workerRun()
            #expect(try w.folder().catchUpState != before, "setup: the catch-up wrote its state")
            #expect(try floor() == 0, "#1062: the catch-up's state write carries the floor")
            #expect(IMAPCatchUpState.decode(try w.folder().catchUpState) != nil, "#1062: the provider still reads its own state")

            // A floor of a new epoch replaces the old one, even a higher one.
            try await w.pool.write { db in try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 15, epoch: Self.epoch + 1, db: db) }
            let replaced = try w.folder().catchUpState
            #expect(CatchUpWindowFloor.read(replaced, epoch: Self.epoch + 1) == 15 && CatchUpWindowFloor.read(replaced, epoch: Self.epoch) == nil,
                    "#1062: a floor of another epoch replaces the old one, which is no longer read")

            // NULL and non-object states.
            for raw in [nil, "not json", "[1, 2]"] as [String?] {
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
                    try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 4, epoch: Self.epoch, db: db)
                }
                #expect(try floor() == 4, "#1062: a state \(raw ?? "NULL") becomes an object holding the floor")
            }
        }
    }

    @Test("Before the older-mail walk starts, a window listing whose lowest UID's header record cannot be read: once that record reads, the next catch-up loads the message (under a storage limit too), and the window floor is that UID",
          arguments: [false, true])
    @MainActor
    func unreadableLowestWindowUIDIsLoadedOnceItReads(limit: Bool) async throws {
        let server = Array(1...200)
        let window = Array((server.count - SyncConfig.syncMessageLimit + 1)...server.count)
        let lowest = window[0]
        try await Self.withWorld("floor-unreadable-\(limit)", server: server, local: Array(window.dropFirst()), walkStarted: false) { w in
            // The window's lowest message has a header record the client cannot read.
            var messages = server.map { Self.message($0) }
            let index = try #require(server.firstIndex(of: lowest))
            messages[index] = Self.message(lowest, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [lowest])
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            try w.expectNotHeld([lowest], "setup: the unreadable message was not inserted")

            // The record reads again; the catch-up runs before any window listing does.
            w.server.setMessages(server.map { Self.message($0) }, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [])
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            if limit {
                _ = try await Self.runUnderTheLimit(w)
            } else {
                try await w.workerRun()
            }
            let loads = Self.requests(to: Self.path, w.server, from: start).map { $0.command }.filter {
                $0.uppercased().hasPrefix("UID FETCH") && $0.uppercased().contains("ENVELOPE")
            }
            let asksLowest = loads.contains { Self.uidSet($0).contains(lowest) }
            #expect(asksLowest, "#1062: the catch-up's header load of the folder asks the recovered UID: \(loads)")
            try w.expectHeldExactly(window, "#1062: the window's lowest message, unreadable when the window listed it, is loaded once it reads")
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == lowest,
                    "#1062: the window floor is the lowest UID the window named, read or not")
            if limit {
                #expect(CatchUpPruneCutoff.read(try w.folder().catchUpState, epoch: Self.epoch) == lowest - 1,
                        "#1062: the one-time cutoff of a folder nothing recorded a prune for is below the window floor, so the unreadable UID stays loadable")
            }
            let folder = try w.folder()
            #expect(!folder.backfillComplete && folder.backfillUidCursor == nil, "setup: the walk has still not started")
        }
    }

    @Test("Before the walk starts, a window listing none of whose header records can be read still records the lowest UID it named as the window floor")
    @MainActor
    func windowFloorCountsAWindowWithNoReadableHeader() async throws {
        let server = Array(1...200)
        let window = Array((server.count - SyncConfig.syncMessageLimit + 1)...server.count)
        try await Self.withWorld("floor-all-unreadable", server: server, local: [], walkStarted: false) { w in
            var messages = server.map { Self.message($0) }
            for uid in window {
                let index = try #require(server.firstIndex(of: uid))
                messages[index] = Self.message(uid, date: "not a date")
            }
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: Set(window))
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            try w.expectNotHeld(window, "setup: no window message was inserted")
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == window[0],
                    "#1062: the window floor is the lowest UID the window named, with no header read")
        }
    }

    @Test("Before the walk starts, an owed folder with no window floor in its epoch and no local row: the catch-up asks the server nothing and the folder stays owed; once a window floor is recorded, the next listing loads the folder's mail and settles it")
    @MainActor
    func folderWithNothingToCheckStaysOwed() async throws {
        let server = Array(1...20)
        try await Self.withWorld("nothing-to-check", server: server, local: [], walkStarted: false) { w in
            let folderId = w.folderId
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == nil, "setup: no window floor in this epoch")
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            try await w.workerRun()
            let asked = Self.requests(to: Self.path, w.server, from: start).map { $0.command }.filter { command in
                ["SELECT", "EXAMINE", "FETCH", "SEARCH"].contains { command.uppercased().contains($0) }
            }
            #expect(asked.isEmpty, "setup: with nothing to check, the folder is asked nothing: \(asked)")
            #expect(try w.changeState().selfHealDue, "#1062: a listing that read nothing from the server leaves the folder owed")

            // A window listing records a floor in this epoch; the next listing loads.
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db)
                try SyncEngine.markCatchUpLapse(folderId: folderId, db: db)
            }
            try await w.workerRun()
            try w.expectHeldExactly(server, "#1062: once a floor of this epoch exists, the owed folder's mail loads")
            #expect(!(try w.changeState()).selfHealDue, "#1062: and a clean listing settles the owed mark")
        }
    }

    @Test("A window listing whose SELECT reports no UIDVALIDITY records no window floor; the next one under a known epoch records it")
    @MainActor
    func windowFloorNeedsAKnownEpoch() async throws {
        let server = Array(1...20)
        // No CONDSTORE: a full sync then lists the folder's window on every
        // pass. With it, the second sync would skip the folder as unchanged
        // (its HIGHESTMODSEQ has not moved) and list nothing.
        try await Self.withWorld("floor-epoch", capabilities: FakeIMAPServer.defaultCapabilities,
                                 server: server, local: server, walkStarted: false) { w in
            func floor() throws -> Int? { CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) }
            #expect(try floor() == nil, "setup: no window listing has recorded a floor")
            w.server.suppressSelectUidValidity(for: Self.path)
            try await w.makeFullSyncDue()
            let start = w.server.recordedCommands().count
            try await w.foregroundSync()
            // The window listing asks the newest messages by sequence number
            // (`selection.latest`): a plain FETCH with the ENVELOPE, sent to
            // this folder; no catch-up or UID request stands in for it.
            func windowFetches(from start: Int) -> [String] {
                Self.requests(to: Self.path, w.server, from: start).map { $0.command }.filter {
                    let command = $0.uppercased()
                    return command.hasPrefix("FETCH ") && command.contains("ENVELOPE")
                }
            }
            #expect(!windowFetches(from: start).isEmpty, "setup: the window listing of the folder ran")
            let raw = try w.folder().catchUpState
            #expect(!(raw ?? "").contains(CatchUpWindowFloor.key),
                    "#1062: a listing of unknown numbering records no floor in any epoch, so none can outlive an epoch change: \(String(describing: raw))")
            w.server.restoreSelectUidValidity(for: Self.path)
            try await w.makeFullSyncDue()
            let second = w.server.recordedCommands().count
            try await w.foregroundSync()
            #expect(!windowFetches(from: second).isEmpty, "setup: the second sync listed the folder's window again")
            #expect(try floor() == 1, "setup: a listing under a known epoch records the floor")
        }
    }

    @Test("Before the walk starts, a window floor recorded under another UIDVALIDITY is ignored, not rebound: nothing loads until a window listing of the current epoch records one; the catch-up's state write keeps the old floor's own epoch")
    @MainActor
    func windowFloorOfAnotherEpochIsIgnored() async throws {
        let server = Array(1...20)
        let local = Array(11...20)
        try await Self.withWorld("floor-other-epoch", server: server, local: local, walkStarted: false) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch + 1, db: db)
            }
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == nil,
                    "setup: the folder holds a floor of another epoch only")
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            try await w.workerRun()
            let asked = Self.requests(to: Self.path, w.server, from: start).map { $0.command }
            #expect(!Self.listingRanges(asked).isEmpty, "setup: the folder's listing ran: \(asked)")
            let loads = Self.headerFetches(asked)
            #expect(loads.isEmpty, "#1062: a floor of another epoch counts for nothing: nothing loads: \(loads)")
            try w.expectHeldExactly(local, "#1062: nothing below the held rows loads before a floor of this epoch")
            let state = try w.folder().catchUpState
            #expect(CatchUpWindowFloor.read(state, epoch: Self.epoch) == nil
                        && CatchUpWindowFloor.read(state, epoch: Self.epoch + 1) == 1,
                    "#1062: the catch-up's state write carries the old floor under its own epoch, never rebound to the current one")

            // Control: a floor of the current epoch loads the rest.
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db)
            }
            try await w.markOwed()
            try await w.workerRun()
            try w.expectHeldExactly(server, "#1062 control: a floor of this epoch loads the missing mail from it")
        }
    }

    @Test("Under a storage limit with the walk complete, local rows below the prune cutoff are still reconciled (an expunge removes one, a flag change reaches another), while nothing at or below the cutoff loads and the mail above it does")
    @MainActor
    func rowsBelowTheCutoffAreStillReconciled() async throws {
        let server = Array(1...40)
        let cutoff = 20
        let flagged = 5, expunged = 8
        try await Self.withWorld("scan-floor-cutoff", server: server, local: server) { w in
            try await w.dropLocal(server.filter { $0 != flagged && $0 != expunged })
            let folderId = w.folderId
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: cutoff, epoch: Self.epoch, db: db)
            }
            w.server.setMessages(server.filter { $0 != expunged }.map(Self.message), in: Self.path)
            w.server.setFlags(["\\Seen"], in: Self.path, uid: flagged)
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            let loads = try await Self.runUnderTheLimit(w)
            let ranges = Self.listingRanges(Self.requests(to: Self.path, w.server, from: start).map { $0.command })
            #expect(ranges.contains { $0.contains(flagged) && $0.contains(expunged) },
                    "#1062: the listing reaches the local rows below the cutoff: \(ranges)")
            let below = Array(1...cutoff).filter { uid in loads.contains { Self.uidSet($0).contains(uid) } }
            #expect(below.isEmpty, "#1062: nothing at or below the cutoff loads: \(below)")
            try w.expectHeldExactly([flagged] + Array((cutoff + 1)...40),
                                    "#1062: the expunged row below the cutoff is removed, the mail above the cutoff loads")
            let isRead = try await w.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = ?",
                                  arguments: [folderId, "\(flagged)"])
            }
            #expect(isRead == true, "#1062: the flag change on the row below the cutoff is applied")
        }
    }

    @Test("Under a storage limit before the walk starts, loads start above the prune cutoff when it is higher than the window floor; with no limit, at the window floor",
          arguments: [true, false])
    @MainActor
    func storageLimitTakesTheHigherFloorBeforeTheWalk(limit: Bool) async throws {
        let server = Array(1...200)
        let window = Array((server.count - SyncConfig.syncMessageLimit + 1)...server.count)
        try await Self.withWorld("floor-limit-\(limit)", server: server, local: window, walkStarted: false) { w in
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState, epoch: Self.epoch) == window[0], "setup: the floor is where the window reached")
            // The prune took the window's lowest rows and recorded where it reached.
            let pruned = Array(window.prefix(10))
            try await w.dropLocal(pruned)
            let folderId = w.folderId
            let cutoff = try #require(pruned.last)
            try await w.pool.write { db in
                try SyncEngine.recordCatchUpPruneCutoff(folderId: folderId, highest: cutoff, epoch: Self.epoch, db: db)
            }
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: limit, deadline: Date().addingTimeInterval(60),
                sliceSeconds: SyncConfig.catchUpSliceSeconds, intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds,
                clock: { Date() })
            run.listingRangeMessages = w.rangeMessages
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runCatchUpRun(account: try w.account(), run: run)
            let headerFetches = Self.headerFetches(Self.requests(to: Self.path, w.server, from: start).map { $0.command })
            let reloaded = pruned.filter { uid in headerFetches.contains { Self.uidSet($0).contains(uid) } }
            if limit {
                #expect(reloaded.isEmpty, "#1062: under a limit nothing at or below the prune cutoff is loaded: \(reloaded)")
                try w.expectHeldExactly(Array(window.dropFirst(10)), "#1062 limit")
            } else {
                #expect(Set(reloaded) == Set(pruned), "#1062 control: with no limit the floor is the window's: \(reloaded)")
                try w.expectHeldExactly(window, "#1062 no limit")
            }
        }
    }
    // MARK: - The stored width across calls

    /// Write the folder's catch-up state: a listing in progress at `nextUid`,
    /// with `rangeWidth` stored (nil: none, as a listing written before the field),
    /// and `loadHeldSince`: a hold on `nextUid` running since then.
    @MainActor
    static func setListing(_ w: World, nextUid: Int, rangeWidth: Int?,
                           widthCap: Int? = nil, top: Int? = nil, loadHeldSince: Date? = nil) async throws {
        var listing = IMAPCatchUpState.Listing(nextUid: nextUid, rangeWidth: rangeWidth)
        listing.widthCap = widthCap
        listing.top = top
        listing.loadHeldSince = loadHeldSince
        let state = IMAPCatchUpState(epoch: UInt32(epoch), listing: listing)
        let raw = try #require(state.encoded())
        let folderId = w.folderId
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    @Test("A call that answers a range at a stored half width and then stops on its budget stores the width re-sized from that range's count; the next call asks at that width")
    @MainActor
    func answeredRangeStoresItsResizedWidth() async throws {
        let server = Array(1...3000)
        let messages = SyncConfig.catchUpListingRangeMessages
        try await Self.withWorld("stored-width-resized", server: server, local: server, rangeMessages: messages) { w in
            let half = messages / 2
            // A listing in progress already knows its top (`Listing.top`).
            try await Self.setListing(w, nextUid: 1, rangeWidth: half, top: server.last)
            let clock = CatchUpTestClock()
            // Budget for one range: its listing FETCH and its membership SEARCH.
            await w.slice(maxRequests: 2, clock: clock)
            let listing = try #require(try w.catchUpState()?.listing, "setup: the listing is in progress")
            let resized = IMAPProvider.nextListingRangeSpan(messages: messages, width: half, held: half)
            #expect(resized != half, "setup: the re-sized width differs from the stored half")
            #expect(listing.nextUid == half + 1, "setup: the call answered one range")
            #expect(listing.rangeWidth == resized, "#1062: an answered range stores the width re-sized from its own count")
            let start = w.server.recordedCommands().count
            await w.slice(maxRequests: 1, clock: clock)
            let next = Self.listingRanges(w.server.recordedCommands().dropFirst(start)).first
            #expect(next == (half + 1)...(half + resized), "#1062: the next call asks at the stored width: \(next.map { "\($0)" } ?? "none")")
        }
    }

    @Test("A range that times out caps the width at half its own: the next call asks that width from the same place, and a range that answers doubles the cap")
    @MainActor
    func timedOutWidthCapGrowsBackOnAnswers() async throws {
        let server = Array(1...5000)
        let messages = SyncConfig.catchUpListingRangeMessages
        try await Self.withWorld("width-cap", server: server, local: server, rangeMessages: messages) { w in
            let first = 2 * messages
            try await Self.setListing(w, nextUid: 1, rangeWidth: first)
            let clock = CatchUpTestClock()
            // The range of more than `messages` records is held: it times out.
            w.server.holdListingFetches(in: Self.path, overRecords: messages)
            await w.slice(clock: clock, requestTimeout: Self.heldRequestTimeout)
            w.server.stopHoldingListingFetches(in: Self.path)
            let timedOut = try #require(try w.catchUpState()?.listing, "setup: the listing is in progress")
            let half = first / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(timedOut.nextUid == 1, "setup: the listing kept its place")
            #expect(timedOut.widthCap == half, "#1062: the cap is the timed-out width divided by the shrink factor")
            #expect(try await Self.nextRange(w, clock) == 1...half, "#1062: the next call asks the capped width from the same place")
            let raised = try w.catchUpState()?.listing?.widthCap
            #expect(raised == half * SyncConfig.catchUpWidthCapGrowthFactor, "#1062: a range that answers raises the cap: \(String(describing: raised))")
        }
    }

    @Test("Many timeouts drove the cap to one UID on a sparse folder with a huge first span; once the server answers, the listing completes within a few slices, however wide the span")
    @MainActor
    func widthCapRecoversAfterTheServerDoes() async throws {
        let far = SyncConfig.catchUpListingMaxRangeSpan / 2
        let server = Array(1...20) + Array(far...(far + 20))
        try await Self.withWorld("width-cap-recovers", server: server, local: server) { w in
            try await Self.setListing(w, nextUid: 1, rangeWidth: SyncConfig.catchUpListingMaxRangeSpan, widthCap: 1)
            let clock = CatchUpTestClock()
            let slices = try await Self.slicesUntilRepaired(
                w, expected: server, maxRequests: SyncConfig.catchUpSliceMaxRequests, clock: clock, bound: 4)
            #expect(try w.catchUpState()?.listing == nil,
                    "#1062: the listing completes in a bounded number of slices after recovery (\(slices) ran)")
        }
    }

    @Test("A timeout at the maximum span caps the width at half of it; the range that answers at that cap raises it to the maximum, where it is dropped: the later ranges are sized from their counts again, wide on a sparse folder, and the listing completes in a few ranges with every message held")
    @MainActor
    func widthCapIsDroppedAtTheMaximumSpan() async throws {
        let maxSpan = SyncConfig.catchUpListingMaxRangeSpan
        // Sparse, and running well past the range at which the cap reaches the maximum.
        let far = 2 * maxSpan + maxSpan / 2
        let server = Array(1...10) + Array(far...(far + 10))
        let missing = far + 5
        try await Self.withWorld("width-cap-dropped", server: server, local: server.filter { $0 != missing }) { w in
            // The warm-up loaded it: the device loses it again, so the repair is this scenario's.
            try await w.dropLocal([missing])
            try w.expectNotHeld([missing], "#1062 cap dropped")
            try await Self.setListing(w, nextUid: 1, rangeWidth: maxSpan, top: server.last)
            let clock = CatchUpTestClock()
            // The range is held: it times out.
            w.server.holdListingFetches(in: Self.path, overRecords: 0)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock, requestTimeout: Self.heldRequestTimeout)
            w.server.stopHoldingListingFetches(in: Self.path)
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)) == [1...maxSpan],
                    "setup: one range at the maximum span was asked, and it timed out")
            let half = maxSpan / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(try w.catchUpState()?.listing?.widthCap == half, "setup: the timeout capped the width at half the maximum span")
            let healed = w.server.recordedCommands().count
            let slices = try await Self.slicesUntilRepaired(
                w, expected: server, maxRequests: SyncConfig.catchUpSliceMaxRequests, clock: clock, bound: 4)
            // The first range answers at the cap; with no cap after it, each later
            // range is sized from the one before (`nextListingRangeSpan`), up to the top.
            let top = try #require(server.last)
            var expected = [1...half]
            var width = IMAPProvider.nextListingRangeSpan(
                messages: w.rangeMessages, width: half, held: server.filter { $0 <= half }.count)
            var lo = half + 1
            while lo <= top {
                let range = lo...min(lo + width - 1, top)
                expected.append(range)
                width = IMAPProvider.nextListingRangeSpan(
                    messages: w.rangeMessages, width: range.count, held: server.filter { range.contains($0) }.count)
                lo = range.upperBound + 1
            }
            let ranges = Self.listingRanges(w.server.recordedCommands().dropFirst(healed))
            #expect(ranges == expected, "#1062: once the cap reaches the maximum span it is dropped, and the ranges follow their counts: \(ranges)")
            try w.expectHeldExactly(server, "#1062 cap dropped")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the listing completed (\(slices) slice(s))")
        }
    }

    @Test("A held UID keeps the listing on its range: a call that lists that range again and moves nothing leaves the width cap as it was")
    @MainActor
    func noProgressCallKeepsTheCap() async throws {
        let held = 12
        let server = Array(1...40)
        try await Self.withWorld("cap-no-progress", server: server, local: server) { w in
            try await w.dropLocal([held])
            w.server.suppressFetchRecord(in: Self.path, uids: [held])
            defer { w.server.suppressFetchRecord(in: Self.path, uids: []) }
            try await w.markOwed()
            let cap = 4
            try await Self.setListing(w, nextUid: 1, rangeWidth: cap, widthCap: cap, top: server.last)
            let clock = CatchUpTestClock()
            var idle = 0
            for _ in 0..<4 {
                let before = try #require(try w.catchUpState()?.listing, "setup: the listing is in progress")
                await w.slice(clock: clock)
                let after = try #require(try w.catchUpState()?.listing, "setup: the held UID keeps the listing open")
                guard after.withoutWidthCap == before.withoutWidthCap else { continue }
                idle += 1
                #expect(after.widthCap == before.widthCap,
                        "#1062: a call that moved nothing changed the cap: \(String(describing: before.widthCap)) -> \(String(describing: after.widthCap))")
            }
            #expect(idle >= 1, "setup: a call listed the held range again and moved nothing")
        }
    }

    /// Reload the stored catch-up state through storage, as a restart reads it.
    @MainActor
    static func reloadState(_ w: World) async throws {
        let raw = try #require(try w.folder().catchUpState)
        let state = try #require(IMAPCatchUpState.decode(raw), "the stored state decodes")
        let again = try #require(state.encoded())
        let folderId = w.folderId
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [again, folderId])
        }
    }

    /// One call that lists one range (its FETCH and its SEARCH) after a reload.
    @MainActor
    static func nextRange(_ w: World, _ clock: CatchUpTestClock) async throws -> ClosedRange<Int>? {
        try await reloadState(w)
        let start = w.server.recordedCommands().count
        await w.slice(maxRequests: 2, clock: clock)
        return listingRanges(w.server.recordedCommands().dropFirst(start)).first
    }

    @Test("A one-UID listing range that times out again: the stored width stays 1, the listing does not move past it, and the call reports no progress")
    @MainActor
    func failingOneUIDRangeStaysUnconfirmed() async throws {
        let server = Array(1...20)
        try await Self.withWorld("one-uid-timeout", server: server, local: server) { w in
            try await Self.setListing(w, nextUid: 7, rangeWidth: 1, top: server.last)
            // The range is held: it times out.
            w.server.holdListingFetches(in: Self.path, overRecords: 0)
            defer { w.server.stopHoldingListingFetches(in: Self.path) }
            let start = w.server.recordedCommands().count
            let read = try await w.read(CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.heldRequestTimeout))
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)).first == 7...7, "setup: the one-UID range was asked")
            let result = try #require(read.results.first, "setup: the folder was worked")
            let listing = try #require(IMAPCatchUpState.decode(result.newState)?.listing, "#1062: the listing stays in progress")
            #expect(listing.nextUid == 7, "#1062: the listing never moves past a range that did not answer")
            #expect(listing.rangeWidth == 1, "#1062: a one-UID range that fails keeps the width 1")
            #expect(listing.widthCap == 1, "#1062: a one-UID range that fails caps the next range at that one UID: \(String(describing: listing.widthCap))")
            #expect(!result.madeProgress, "#1062: a repeat failure at width 1 is no progress, so the run stops")
        }
    }

    @Test("A one-UID listing range already capped at width 1 that times out again: the cap it writes again is no progress")
    @MainActor
    func cappedOneUIDRangeTimeoutIsNoProgress() async throws {
        let server = Array(1...20)
        try await Self.withWorld("one-uid-capped-timeout", server: server, local: server) { w in
            try await Self.setListing(w, nextUid: 7, rangeWidth: 1, widthCap: 1, top: server.last)
            // The range is held: it times out.
            w.server.holdListingFetches(in: Self.path, overRecords: 0)
            defer { w.server.stopHoldingListingFetches(in: Self.path) }
            let start = w.server.recordedCommands().count
            let read = try await w.read(CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.heldRequestTimeout))
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)).first == 7...7, "setup: the one-UID range was asked")
            let result = try #require(read.results.first, "setup: the folder was worked")
            let listing = try #require(IMAPCatchUpState.decode(result.newState)?.listing, "#1062: the listing stays in progress")
            #expect(listing.nextUid == 7, "#1062: the listing never moves past a range that did not answer")
            #expect(listing.rangeWidth == 1, "#1062: a one-UID range that fails keeps the width 1")
            #expect(!result.madeProgress, "#1062: a timeout under a stored cap is no progress, so the run stops")
        }
    }

    @Test("A range that times out at its stored width, which could still be halved, writes only the cap: the slice reports no progress and the folder's request as possibly in flight; the listing stays at its UID, and the next call asks the capped width from there")
    @MainActor
    func timedOutRangeThatCouldHalveIsNoProgress() async throws {
        let server = Array(1...20)
        try await Self.withWorld("halvable-timeout", server: server, local: server) { w in
            let width = 5
            try await Self.setListing(w, nextUid: 7, rangeWidth: width, top: server.last)
            // The range is held: it times out.
            w.server.holdListingFetches(in: Self.path, overRecords: 0)
            let start = w.server.recordedCommands().count
            // One slice of this folder, as the background run takes it.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            let slice = await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.heldRequestTimeout))
            w.server.stopHoldingListingFetches(in: Self.path)
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)) == [7...(6 + width)],
                    "setup: one range at the stored width was asked, and it timed out")
            #expect(!slice.progressed, "#1062: a timed-out range is no progress, even one that could still be halved: the cap is all it writes")
            #expect(slice.inFlightFolderIds == [w.folderId], "#1062: the slice reports the folder's request as possibly in flight, so the run asks it nothing more")
            #expect(try w.catchUpState()?.listing?.nextUid == 7, "#1062: the listing stays at the UID whose range timed out")
            let capped = width / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(try await Self.nextRange(w, CatchUpTestClock()) == 7...(6 + capped),
                    "#1062: the next call asks the timed-out width divided by the shrink factor, from the same UID")
        }
    }

    @Test("A stored listing written before the width field: the first range is sized from the folder's EXISTS and UIDNEXT")
    @MainActor
    func listingWithoutStoredWidthSizesFromTheFolder() async throws {
        let server = Array(1...20) + Array(100_001...100_020) + Array(200_001...200_020)
        try await Self.withWorld("no-stored-width", server: server, local: server) { w in
            let folderId = w.folderId
            let raw = "{\"epoch\":\(Self.epoch),\"listing\":{\"nextUid\":1}}"
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
            }
            #expect(try w.catchUpState()?.listing?.rangeWidth == nil, "setup: the stored listing has no width")
            let folder = try w.folder()
            let expected = IMAPProvider.listingRangeSpan(
                messages: w.rangeMessages, exists: folder.totalCount, uidNext: folder.lastKnownUidNext)
            #expect(expected != SyncConfig.catchUpListingMinRangeSpan && expected != SyncConfig.catchUpListingMaxRangeSpan,
                    "setup: the folder's width is neither clamp: \(expected)")
            let start = w.server.recordedCommands().count
            // A stored listing with no top starts as a new one does (`newListingStartRequests`).
            await w.slice(maxRequests: Self.newListingStartRequests + 1, clock: CatchUpTestClock())
            let first = Self.listingRanges(w.server.recordedCommands().dropFirst(start)).first
            #expect(first == 1...expected, "#1062: sized from EXISTS and UIDNEXT: \(first.map { "\($0)" } ?? "none")")
        }
    }
}
