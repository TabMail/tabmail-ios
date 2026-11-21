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

    /// The production shape, scaled down so a test runs in seconds: a slice
    /// shorter than one request's timeout (`catchUpSliceSeconds` 2 s against
    /// `catchUpRequestTimeoutSeconds` 3 s), so a timeout spends the slice; a
    /// slow answer later than the timeout; and slices spaced further apart
    /// than the slow answer, so its late reply has freed the connection by the
    /// next slice, as on a real link between worker slices.
    static let scaledSliceSeconds: TimeInterval = 0.3
    static let scaledTimeout: TimeInterval = 0.5
    static let slowAnswerSeconds: Double = 1
    static let scaledIntervalSeconds: TimeInterval = 1.2
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
    /// cost counts every listing request of those runs.
    /// *Superseded (#1062):* one worker run, in which "the listing completes
    /// across calls": the run now leaves the folder out after its timeout.
    @MainActor
    static func runOnSlowLink(_ w: World, overRecords: Int, ceiling: Int) async throws -> (fetches: Int, ranges: [ClosedRange<Int>]) {
        w.server.slowListingFetch(in: path, overRecords: overRecords, seconds: slowAnswerSeconds)
        defer { w.server.slowListingFetch(in: path, overRecords: overRecords, seconds: nil) }
        let sizesBefore = w.server.listingFetchSizes(in: path).count
        let start = w.server.recordedCommands().count
        // Every run but the last ends on a listing timeout, and every timeout is
        // a listing request within the ceiling.
        let runBound = ceiling + 1
        var runs = 0
        repeat {
            let runSizesBefore = w.server.listingFetchSizes(in: path).count
            // Each run's first slice waits for the account's slice window, which
            // outlasts the late answer of the previous run's timed-out range.
            try await w.workerRun(deadlineIn: slowLinkDeadline, requestTimeout: scaledTimeout,
                                  sliceSeconds: scaledSliceSeconds, intervalSeconds: scaledIntervalSeconds)
            runs += 1
            let timeoutsInRun = w.server.listingFetchSizes(in: path).dropFirst(runSizesBefore).filter { $0 > overRecords }.count
            #expect(timeoutsInRun <= 1,
                    "#1062: a run asks the folder nothing after its listing request timed out: \(timeoutsInRun) listing timeouts in run \(runs)")
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
            let floor = try #require(CatchUpWindowFloor.read(try w.folder().catchUpState), "setup: the window listing recorded its floor")
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
            func floor() throws -> Int? { CatchUpWindowFloor.read(try w.folder().catchUpState) }
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            #expect(try floor() == 1, "setup: the window listing recorded its floor")

            // A later listing that reached higher never raises it.
            try await w.pool.write { db in try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 9, db: db) }
            #expect(try floor() == 1, "#1062: the floor is the lowest any window listing reached")
            try await w.pool.write { db in try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 0, db: db) }
            #expect(try floor() == 0, "#1062: a listing that reached lower lowers it")

            // The catch-up rewrites the folder's state; the floor survives it.
            try await w.markOwed()
            let before = try w.folder().catchUpState
            try await w.workerRun()
            #expect(try w.folder().catchUpState != before, "setup: the catch-up wrote its state")
            #expect(try floor() == 0, "#1062: the catch-up's state write carries the floor")
            #expect(IMAPCatchUpState.decode(try w.folder().catchUpState) != nil, "#1062: the provider still reads its own state")

            // NULL and non-object states.
            for raw in [nil, "not json", "[1, 2]"] as [String?] {
                try await w.pool.write { db in
                    try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
                    try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 4, db: db)
                }
                #expect(try floor() == 4, "#1062: a state \(raw ?? "NULL") becomes an object holding the floor")
            }
        }
    }

    @Test("Under a storage limit before the walk starts, loads start at the higher of the window floor and the lowest held UID; with no limit, at the window floor",
          arguments: [true, false])
    @MainActor
    func storageLimitTakesTheHigherFloorBeforeTheWalk(limit: Bool) async throws {
        let server = Array(1...200)
        let window = Array((server.count - SyncConfig.syncMessageLimit + 1)...server.count)
        try await Self.withWorld("floor-limit-\(limit)", server: server, local: window, walkStarted: false) { w in
            try await w.makeFullSyncDue()
            try await w.foregroundSync()
            #expect(CatchUpWindowFloor.read(try w.folder().catchUpState) == window[0], "setup: the floor is where the window reached")
            // The prune took the window's lowest rows: the lowest held UID is now above the floor.
            let pruned = Array(window.prefix(10))
            try await w.dropLocal(pruned)
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: limit, deadline: Date().addingTimeInterval(60),
                sliceSeconds: SyncConfig.catchUpSliceSeconds, intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds,
                clock: { Date() })
            run.listingRangeMessages = w.rangeMessages
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runCatchUpRun(account: try w.account(), run: run)
            let headerFetches = w.server.recordedCommands().dropFirst(start).filter {
                $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE")
            }
            let reloaded = pruned.filter { uid in headerFetches.contains { Self.uidSet($0).contains(uid) } }
            if limit {
                #expect(reloaded.isEmpty, "#1062: under a limit nothing below the lowest held UID is loaded: \(reloaded)")
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
            w.server.slowListingFetch(in: Self.path, overRecords: messages, seconds: Self.slowAnswerSeconds)
            await w.slice(clock: clock, requestTimeout: Self.scaledTimeout)
            w.server.slowListingFetch(in: Self.path, overRecords: messages, seconds: nil)
            // Let the late answer free the connection.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
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
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock, requestTimeout: Self.scaledTimeout)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)) == [1...maxSpan],
                    "setup: one range at the maximum span was asked, and it timed out")
            let half = maxSpan / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(try w.catchUpState()?.listing?.widthCap == half, "setup: the timeout capped the width at half the maximum span")
            // Let the late answer free the connection.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
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
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            defer { w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil) }
            let start = w.server.recordedCommands().count
            let read = try await w.read(CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.scaledTimeout))
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)).first == 7...7, "setup: the one-UID range was asked")
            let result = try #require(read.results.first, "setup: the folder was worked")
            let listing = try #require(IMAPCatchUpState.decode(result.newState)?.listing, "#1062: the listing stays in progress")
            #expect(listing.nextUid == 7, "#1062: the listing never moves past a range that did not answer")
            #expect(listing.rangeWidth == 1, "#1062: a one-UID range that fails keeps the width 1")
            #expect(!result.madeProgress, "#1062: a repeat failure at width 1 is no progress, so the run stops")
            // Let the late answer free the connection before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    @Test("A one-UID listing range already capped at width 1 that times out again: the cap it writes again is no progress")
    @MainActor
    func cappedOneUIDRangeTimeoutIsNoProgress() async throws {
        let server = Array(1...20)
        try await Self.withWorld("one-uid-capped-timeout", server: server, local: server) { w in
            try await Self.setListing(w, nextUid: 7, rangeWidth: 1, widthCap: 1, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            defer { w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil) }
            let start = w.server.recordedCommands().count
            let read = try await w.read(CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.scaledTimeout))
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)).first == 7...7, "setup: the one-UID range was asked")
            let result = try #require(read.results.first, "setup: the folder was worked")
            let listing = try #require(IMAPCatchUpState.decode(result.newState)?.listing, "#1062: the listing stays in progress")
            #expect(listing.nextUid == 7, "#1062: the listing never moves past a range that did not answer")
            #expect(listing.rangeWidth == 1, "#1062: a one-UID range that fails keeps the width 1")
            #expect(!result.madeProgress, "#1062: a timeout under a stored cap is no progress, so the run stops")
            // Let the late answer free the connection before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    @Test("A range that times out at its stored width, which could still be halved, writes only the cap: the slice reports no progress and the folder's request as possibly in flight; the listing stays at its UID, and the next call asks the capped width from there")
    @MainActor
    func timedOutRangeThatCouldHalveIsNoProgress() async throws {
        let server = Array(1...20)
        try await Self.withWorld("halvable-timeout", server: server, local: server) { w in
            let width = 5
            try await Self.setListing(w, nextUid: 7, rangeWidth: width, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            // One slice of this folder, as the background run takes it.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            let slice = await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.scaledTimeout))
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)) == [7...(6 + width)],
                    "setup: one range at the stored width was asked, and it timed out")
            #expect(!slice.progressed, "#1062: a timed-out range is no progress, even one that could still be halved: the cap is all it writes")
            #expect(slice.inFlightFolderIds == [w.folderId], "#1062: the slice reports the folder's request as possibly in flight, so the run asks it nothing more")
            #expect(try w.catchUpState()?.listing?.nextUid == 7, "#1062: the listing stays at the UID whose range timed out")
            // Let the late answer free the connection, as the slice window does.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            let capped = width / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(try await Self.nextRange(w, CatchUpTestClock()) == 7...(6 + capped),
                    "#1062: the next call asks the timed-out width divided by the shrink factor, from the same UID")
        }
    }

    // MARK: - A request that may still be in flight ends its folder for the run (#1062)

    /// The requests sent to `mailbox` among the recorded commands from `start`
    /// on, each with its index in the log: every command a connection sent while
    /// it had the mailbox selected, and a SELECT, EXAMINE or STATUS naming it.
    static func requests(to mailbox: String, _ server: FakeIMAPServer, from start: Int) -> [(index: Int, command: String)] {
        server.recordedCommandsWithMailbox().enumerated().dropFirst(start).compactMap { entry -> (index: Int, command: String)? in
            let (index, recorded) = entry
            let words = recorded.command.split(separator: " ")
            let verb = words.first.map { $0.uppercased() } ?? ""
            let names = words.count > 1 && words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == mailbox
            let toMailbox = recorded.mailbox == mailbox || (["SELECT", "EXAMINE", "STATUS"].contains(verb) && names)
            return toMailbox ? (index, recorded.command) : nil
        }
    }

    /// The healthy folder of the in-flight tests: the account's INBOX, answered
    /// at once, whose listing is in progress with a small width cap, so it takes
    /// a range or two per slice over several slices.
    static let healthyPath = "INBOX"
    static let healthyServer = Array(1...60)
    static let healthyWidthCap = 2
    /// Requests per slice in the in-flight tests: room for a call that answers
    /// one range (its FETCH and its membership SEARCH) and asks the next.
    static let inFlightSliceRequests = 3

    /// Give the account a healthy folder (`healthyPath`) whose listing is in
    /// progress: the server and the device hold the same messages there.
    @MainActor
    static func startHealthyListing(_ w: World) async throws {
        w.server.setMessages(healthyServer.map { message($0) }, in: healthyPath)
        try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: healthyPath, uids: healthyServer, pool: w.pool)
        var listing = IMAPCatchUpState.Listing(nextUid: 1, rangeWidth: nil)
        listing.widthCap = healthyWidthCap
        listing.top = healthyServer.last
        let raw = try #require(IMAPCatchUpState(epoch: UInt32(epoch), listing: listing).encoded())
        let folderId = "\(w.accountId):\(healthyPath)"
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    /// The healthy folder's stored catch-up state.
    @MainActor
    static func healthyState(_ w: World) throws -> IMAPCatchUpState? {
        let folderId = "\(w.accountId):\(healthyPath)"
        let raw = try w.pool.read { db in
            try String.fetchOne(db, sql: "SELECT catchUpState FROM folder WHERE id = ?", arguments: [folderId])
        }
        return IMAPCatchUpState.decode(raw)
    }

    /// How long an in-flight test's run may take: well within its deadline. A
    /// run that kept taking slices once only its left-out folder had work would
    /// run to the deadline.
    static let leftOutRunSeconds: TimeInterval = slowLinkDeadline / 2

    /// One background run on the scaled link, `maxRequests` per slice: a slice
    /// shorter than a request's timeout, as in production, so a timeout spends
    /// its slice. Returns the run's own answer (an applied result made progress)
    /// and how long the run took.
    @MainActor @discardableResult
    static func inFlightRun(_ w: World, maxRequests: Int = inFlightSliceRequests) async throws -> (didWork: Bool, seconds: TimeInterval) {
        let started = Date()
        let didWork = try await w.workerRun(maxRequests: maxRequests, deadlineIn: slowLinkDeadline, requestTimeout: scaledTimeout,
                                            sliceSeconds: scaledSliceSeconds, intervalSeconds: scaledIntervalSeconds)
        return (didWork, Date().timeIntervalSince(started))
    }

    /// The run of an in-flight test, which took `runSeconds`, after the
    /// folder's request timed out at the command `timedOut`: the folder got no
    /// request after it; the healthy folder was asked after it, so in a later
    /// slice (the timeout spent its own), until its listing completed; and the
    /// run ended once only the left-out folder had work.
    /// *Superseded (#1062):* "the healthy folder kept being asked in later
    /// slices", counted as at least two listing ranges after the timeout.
    @MainActor
    static func expectFolderLeftOutOfTheRun(_ w: World, from start: Int, timedOut: Int, runSeconds: TimeInterval,
                                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        let after = requests(to: path, w.server, from: start).filter { $0.index > timedOut }.map { $0.command }
        #expect(after.isEmpty, "#1062: the run never asks the folder again after its request timed out: \(after)",
                sourceLocation: sourceLocation)
        let healthy = listingRanges(requests(to: healthyPath, w.server, from: timedOut + 1).map { $0.command })
        #expect(!healthy.isEmpty, "#1062: the healthy folder is asked in a later slice of the same run: \(healthy)",
                sourceLocation: sourceLocation)
        #expect(try healthyState(w)?.listing == nil, "#1062: the healthy folder's listing completed in the same run",
                sourceLocation: sourceLocation)
        #expect(runSeconds < leftOutRunSeconds,
                "#1062: the run ends once only the left-out folder has work: it took \(runSeconds) s of its \(slowLinkDeadline) s",
                sourceLocation: sourceLocation)
    }

    /// The next run on a link that answers: the folder's first listing range.
    @MainActor
    static func firstRangeOfTheNextRun(_ w: World) async throws -> ClosedRange<Int>? {
        // Let the late answer free the connection.
        try await Task.sleep(for: .seconds(slowAnswerSeconds))
        let start = w.server.recordedCommands().count
        try await inFlightRun(w)
        return listingRanges(requests(to: path, w.server, from: start).map { $0.command }).first
    }

    @Test("A call that starts a listing and times out on its first range: the run never asks that folder again while a healthy folder of the account goes on in later slices, and the run ends once only that folder has work; the listing keeps the top it learned, and the next run asks half the timed-out width from the same UID")
    @MainActor
    func timeoutOnTheCallThatStartsAListingLeavesTheFolderOutOfTheRun() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-listing-start", server: server, local: server) { w in
            try await Self.startHealthyListing(w)
            try await w.markOwed()
            #expect(try w.catchUpState()?.listing == nil, "setup: no listing is stored, so the call starts one")
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let timedOut = try #require(asked.first { !Self.listingRanges([$0.command]).isEmpty }, "setup: the folder's first range was asked")
            let range = try #require(Self.listingRanges([timedOut.command]).first)
            #expect(range.lowerBound == 1, "setup: the new listing's first range starts at the folder's first UID: \(range)")
            try Self.expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds)
            let listing = try #require(try w.catchUpState()?.listing, "#1062: the listing the call started is saved")
            #expect(listing.top == server.last, "#1062: the saved listing keeps the top the call learned")
            #expect(listing.nextUid == range.lowerBound, "#1062: the listing stays at the UID whose range timed out")
            let capped = range.count / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(listing.widthCap == capped, "#1062: one timeout capped the width once: \(String(describing: listing.widthCap))")
            let next = try await Self.firstRangeOfTheNextRun(w)
            #expect(next == range.lowerBound...(range.lowerBound + capped - 1),
                    "#1062: the next run asks half the timed-out width from the same UID: \(next.map { "\($0)" } ?? "none")")
        }
    }

    @Test("A call that answers a range and then times out on the next: the run never asks that folder again while a healthy folder of the account goes on in later slices, and the run ends once only that folder has work; the listing keeps the place the answer moved it to, and the next run asks half the timed-out width from there")
    @MainActor
    func timeoutAfterAnAnsweredRangeLeavesTheFolderOutOfTheRun() async throws {
        let server = Array(1...20)
        let cap = 5
        try await Self.withWorld("in-flight-after-answer", server: server, local: server) { w in
            try await Self.startHealthyListing(w)
            // The first range (`cap` messages) answers; the second, at the
            // doubled cap, holds more than the link answers in time.
            try await Self.setListing(w, nextUid: 1, rangeWidth: nil, widthCap: cap, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: nil)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let listed = asked.filter { !Self.listingRanges([$0.command]).isEmpty }
            let grown = cap * SyncConfig.catchUpWidthCapGrowthFactor
            #expect(Self.listingRanges(listed.prefix(2).map { $0.command }) == [1...cap, (cap + 1)...(cap + grown)],
                    "setup: one call answered a range at the cap and asked the next at the doubled cap")
            let timedOut = try #require(listed.dropFirst().first, "setup: the second range was asked")
            try Self.expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds)
            let listing = try #require(try w.catchUpState()?.listing, "setup: the listing is in progress")
            #expect(listing.nextUid == cap + 1, "#1062: the saved listing keeps the place the answered range moved it to")
            #expect(listing.top == server.last, "#1062: the saved listing keeps its top")
            let capped = grown / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(listing.widthCap == capped, "#1062: one timeout capped the width once: \(String(describing: listing.widthCap))")
            let next = try await Self.firstRangeOfTheNextRun(w)
            #expect(next == (cap + 1)...(cap + capped),
                    "#1062: the next run asks half the timed-out width from the UID after the answered range: \(next.map { "\($0)" } ?? "none")")
        }
    }

    @Test("A run whose only progress is that of the folder whose request then timed out: the folder is never asked again, the run ends once only that folder has work, and the run still reports the folder's applied progress as work")
    @MainActor
    func soleProgressOfALeftOutFolderEndsTheRunAndCounts() async throws {
        let server = Array(1...20)
        let cap = 5
        try await Self.withWorld("in-flight-sole-progress", server: server, local: server) { w in
            // No healthy folder: the account's INBOX completed its listing in
            // the warm-up and has nothing due. The folder's first range answers;
            // the second, at the doubled cap, holds more than the link answers in time.
            try await Self.setListing(w, nextUid: 1, rangeWidth: nil, widthCap: cap, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: nil)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let listed = asked.filter { !Self.listingRanges([$0.command]).isEmpty }
            let grown = cap * SyncConfig.catchUpWidthCapGrowthFactor
            #expect(Self.listingRanges(listed.prefix(2).map { $0.command }) == [1...cap, (cap + 1)...(cap + grown)],
                    "setup: one call answered a range at the cap and asked the next at the doubled cap")
            let timedOut = try #require(listed.dropFirst().first, "setup: the second range was asked")
            let after = asked.filter { $0.index > timedOut.index }.map { $0.command }
            #expect(after.isEmpty, "#1062: the run never asks the folder again after its request timed out: \(after)")
            #expect(try w.catchUpState()?.listing?.nextUid == cap + 1, "setup: the call's progress was applied")
            #expect(run.didWork, "#1062: the run reports the left-out folder's applied progress as work")
            #expect(run.seconds < Self.leftOutRunSeconds,
                    "#1062: the run ends once only the left-out folder has work: it took \(run.seconds) s of its \(Self.slowLinkDeadline) s")
            // Let the late answer free the connection before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    /// The account's second folder whose requests time out (a Sent folder).
    static let secondPath = "Sent"

    /// Write `listing` as the catch-up state of the account's folder at
    /// `folderPath`, last tried at `lastAttemptAt`.
    @MainActor
    static func writeListing(_ w: World, folderPath: String, _ listing: IMAPCatchUpState.Listing, lastAttemptAt: Date) async throws {
        var state = IMAPCatchUpState(epoch: UInt32(epoch), listing: listing)
        state.lastAttemptAt = lastAttemptAt
        let raw = try #require(state.encoded())
        let folderId = "\(w.accountId):\(folderPath)"
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    /// Give the account its second folder (`secondPath`): the server and the
    /// device hold `uids` there, its listing is in progress at the first of them
    /// with `siteWidth` stored, it was last tried at `lastAttemptAt`, and every
    /// listing request in it is answered only after the timeout.
    @MainActor
    static func addSecondSlowFolder(_ w: World, uids: [Int], lastAttemptAt: Date) async throws {
        w.server.setMessages(uids.map { message($0) }, in: secondPath)
        w.server.setUidValidity(epoch, for: secondPath)
        try FolderEpochTestFixture.insertFolder(accountId: w.accountId, path: secondPath, role: .sent, pool: w.pool,
                                                totalCount: uids.count, lastKnownUidNext: (uids.max() ?? 0) + 1,
                                                lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: secondPath, uids: uids, pool: w.pool)
        var listing = IMAPCatchUpState.Listing(nextUid: uids[0], rangeWidth: siteWidth)
        listing.top = uids.last
        try await writeListing(w, folderPath: secondPath, listing, lastAttemptAt: lastAttemptAt)
        w.server.slowListingFetch(in: secondPath, overRecords: 0, seconds: slowAnswerSeconds)
    }

    @Test("Two folders time out in different slices of one run, each on a call that makes no progress: neither is asked again after its own timeout, the run goes on past each timeout slice, and the healthy folder completes its listing in later slices")
    @MainActor
    func leftOutFoldersAccumulateOverTheRun() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-two-folders", server: server, local: server) { w in
            try await Self.startHealthyListing(w)
            // Tried longest ago first: the healthy folder (never tried) takes
            // the first slice, the folder the second, the second folder the third.
            let now = Date()
            var listing = IMAPCatchUpState.Listing(nextUid: server[0], rangeWidth: Self.siteWidth)
            listing.top = server.last
            try await Self.writeListing(w, folderPath: Self.path, listing, lastAttemptAt: now.addingTimeInterval(-7200))
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            try await Self.addSecondSlowFolder(w, uids: server, lastAttemptAt: now.addingTimeInterval(-3600))
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            w.server.slowListingFetch(in: Self.secondPath, overRecords: 0, seconds: nil)
            func firstListing(_ mailbox: String) -> (index: Int, command: String)? {
                Self.requests(to: mailbox, w.server, from: start).first { !Self.listingRanges([$0.command]).isEmpty }
            }
            let first = try #require(firstListing(Self.path), "setup: the folder's range was asked")
            #expect(try w.catchUpState()?.listing?.nextUid == server[0],
                    "setup: the folder's call made no progress: the listing stays at its first UID")
            // The timeout spent its slice, and the call made no progress: the run
            // goes on only because the slice left the folder out.
            let second = try #require(firstListing(Self.secondPath),
                                      "#1062: the run goes on past the first timeout slice and asks the second folder in a later slice")
            #expect(second.index > first.index, "setup: the second folder timed out after the first")
            for (mailbox, timedOut) in [(Self.path, first), (Self.secondPath, second)] {
                let after = Self.requests(to: mailbox, w.server, from: start).filter { $0.index > timedOut.index }.map { $0.command }
                #expect(after.isEmpty, "#1062: the run never asks \(mailbox) again after its request timed out: \(after)")
            }
            let healthy = Self.listingRanges(Self.requests(to: Self.healthyPath, w.server, from: second.index + 1).map { $0.command })
            #expect(!healthy.isEmpty, "#1062: the healthy folder is asked after the second timeout, in a later slice of the same run: \(healthy)")
            #expect(try Self.healthyState(w)?.listing == nil, "#1062: the healthy folder's listing completed in the same run")
            #expect(run.seconds < Self.leftOutRunSeconds,
                    "#1062: the run ends once only the left-out folders have work: it took \(run.seconds) s of its \(Self.slowLinkDeadline) s")
            // Let the late answers free the connections before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    // MARK: - Every request that times out leaves its folder out (#1062)

    /// The folder of the per-request tests: UIDs no request of the healthy
    /// folder names (it holds `healthyServer`), so a fragment of the folder's own
    /// SEARCH holds only that SEARCH. Listed from its first UID in ranges of
    /// `siteWidth`; `siteMissing` is in the first one.
    static let siteServer = Array(101...120)
    static let siteWidth = 5
    static let siteMissing = 103

    /// One run in which the folder's request whose command contains one of
    /// `fragments` is answered only after the timeout: the folder is never asked
    /// again in the run, the healthy folder goes on in a later slice, and the run
    /// ends once only the folder has work (`expectFolderLeftOutOfTheRun`).
    @MainActor
    static func expectRunLeavesOutTheFolder(_ w: World, timingOut fragments: [String], maxRequests: Int = inFlightSliceRequests,
                                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for fragment in fragments { w.server.stallNextCommand(containing: fragment, seconds: slowAnswerSeconds) }
        let start = w.server.recordedCommands().count
        let run = try await inFlightRun(w, maxRequests: maxRequests)
        let held = fragments.map { $0.uppercased() }
        let timedOut = try #require(requests(to: path, w.server, from: start).first { request in
            held.contains { request.command.uppercased().contains($0) }
        }, "setup: the folder's request held past the timeout was asked", sourceLocation: sourceLocation)
        try expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds,
                                        sourceLocation: sourceLocation)
        // Let the late answer free the connection before the world closes.
        try await Task.sleep(for: .seconds(slowAnswerSeconds))
    }

    /// Start the folder's listing at its first UID, ranges of `siteWidth`.
    @MainActor
    static func startSiteListing(_ w: World) async throws {
        try await setListing(w, nextUid: siteServer[0], rangeWidth: siteWidth, top: siteServer.last)
    }

    @Test("The UIDNEXT read of a call that starts a listing times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func uidNextTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-uidnext", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.startHealthyListing(w)
            try await w.markOwed()
            #expect(try w.catchUpState()?.listing == nil, "setup: no listing is stored, so the call reads the folder's UIDNEXT first")
            // The folder's SELECT, either quoting: the UIDNEXT read is its first request in the run.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["SELECT \(Self.path)", "SELECT \"\(Self.path)\""])
            let listing = try #require(try w.catchUpState()?.listing, "setup: the call saved the listing it started")
            #expect(listing.top == nil, "setup: the UIDNEXT read timed out before the listing learned its top")
        }
    }

    @Test("A range's membership proof times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func proofTimeoutLeavesTheFolderOutOfTheRun() async throws {
        let first = Self.siteServer[0]
        try await Self.withWorld("in-flight-proof", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // The proof of the first range names it whole.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["UID \(first):\(first + Self.siteWidth - 1)"])
        }
    }

    /// Make `siteMissing` a missing message whose header record the client
    /// cannot read: its load leaves the UID unanswered, and the SEARCH for it
    /// (`UID SEARCH UID <uid>`) is the request a test holds.
    @MainActor
    static func makeSiteMissingUnreadable(_ w: World) async throws {
        let server = siteServer, unreadable = siteMissing
        var messages = server.map { message($0) }
        let index = try #require(server.firstIndex(of: unreadable))
        messages[index] = message(unreadable, date: "not a date")
        w.server.setMessages(messages, in: path)
        w.server.suppressFetchInternalDate(in: path, uids: [unreadable])
        try await w.dropLocal([unreadable])
    }

    @Test("The SEARCH a carried range still owes for a UID whose header record could not be read times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func carriedUnansweredSearchTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-unanswered-carried", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.makeSiteMissingUnreadable(w)
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // `inFlightSliceRequests` per slice: the folder's first call lists the
            // range, proves it and loads the UID, and carries the SEARCH it owes
            // (no request left); a later call asks that SEARCH first.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["UID \(Self.siteMissing)"])
        }
    }

    @Test("The SEARCH for a UID whose header record could not be read, asked right after its load, times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func unansweredSearchTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-unanswered", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.makeSiteMissingUnreadable(w)
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // One request more per slice: the folder's first call lists the
            // range, proves it, loads the UID and asks its SEARCH in the same call.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["UID \(Self.siteMissing)"],
                                                       maxRequests: Self.inFlightSliceRequests + 1)
        }
    }

    @Test("The header load of a missing message times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func headerLoadTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-load", server: Self.siteServer, local: Self.siteServer) { w in
            try await w.dropLocal([Self.siteMissing])
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // The healthy folder misses nothing, so the only header load is the folder's.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["ENVELOPE"])
        }
    }

    @Test("A folder's request times out and its result is not applied (a reset of the folder began while the request was out): the slice still reports the folder's request as possibly in flight")
    @MainActor
    func timedOutFolderIsInFlightWhenItsApplyIsSkipped() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-skipped", server: server, local: server) { w in
            let folderId = w.folderId
            try await Self.setListing(w, nextUid: 7, rangeWidth: 5, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            async let sliced = w.engine.runCatchUp(provider: w.provider, folderIds: [folderId], context: CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.scaledTimeout))
            var polls = 0
            while Self.listingRanges(w.server.recordedCommands().dropFirst(start)).isEmpty, polls < Self.suspensionPolls {
                try await Task.sleep(for: .milliseconds(10))
                polls += 1
            }
            #expect(polls < Self.suspensionPolls, "setup: the folder's range was asked")
            // The folder's reset reaction begins while the range's request is
            // out: the apply then writes nothing of the call's result.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?", arguments: [Date(), folderId])
            }
            let slice = await sliced
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            #expect(try w.catchUpState()?.listing?.widthCap == nil, "setup: the apply wrote nothing, not even the cap the call set")
            #expect(!slice.progressed, "setup: nothing of the folder's result was applied")
            #expect(slice.inFlightFolderIds == [folderId],
                    "#1062: a timed-out request is reported in flight whatever the apply did: \(slice.inFlightFolderIds)")
            // Let the late answer free the connection before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    @Test("A call that sees another numbering applies nothing and reports a request of that call that timed out as in flight, and one that did not as not")
    func otherNumberingCarriesTheCallsTimeout() {
        let timedOut = IMAPProvider.otherNumbering(folderId: "account:\(Self.path)", epoch: 7, requestTimedOut: true)
        #expect(timedOut.requestMayBeInFlight, "#1062: the call's timeout is still reported in flight")
        #expect(timedOut.epoch == 7 && !timedOut.madeProgress && timedOut.newState == nil,
                "#1062: nothing of the call applies; the observed numbering is reported")
        let answered = IMAPProvider.otherNumbering(folderId: "account:\(Self.path)", epoch: nil, requestTimedOut: false)
        #expect(!answered.requestMayBeInFlight && answered.epoch == nil, "#1062: no timeout, nothing in flight")
    }

    // MARK: - A timeout past the hold bound ends the call (#1062)

    /// One call that lists `range`, held since past the bound, and whose request
    /// containing `fragment` times out: the range is passed over and saved, the
    /// folder gets no further request in that call, and the next call lists from
    /// past the range. The call's budget is never spent (no deadline, a clock
    /// that stands still, no request cap) and the listing has ranges left, so
    /// only the end of the call after the timeout stops the next range's request.
    @MainActor
    static func expectPassOverEndsTheCall(_ w: World, range: ClosedRange<Int>, timingOut fragment: String,
                                          clock: CatchUpTestClock,
                                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        w.server.stallNextCommand(containing: fragment, seconds: slowAnswerSeconds)
        let start = w.server.recordedCommands().count
        await w.slice(clock: clock, requestTimeout: scaledTimeout)
        let asked = requests(to: path, w.server, from: start)
        #expect(listingRanges(asked.map { $0.command }).first == range, "setup: the call listed \(range) first",
                sourceLocation: sourceLocation)
        let timedOut = try #require(asked.first { $0.command.uppercased().contains(fragment.uppercased()) },
                                    "setup: the request held past the timeout was asked", sourceLocation: sourceLocation)
        let after = asked.filter { $0.index > timedOut.index }.map { $0.command }
        #expect(after.isEmpty, "#1062: after a timeout past the hold bound the folder gets no further request in that call: \(after)",
                sourceLocation: sourceLocation)
        let listing = try #require(try w.catchUpState()?.listing, "#1062: the listing stays in progress",
                                   sourceLocation: sourceLocation)
        #expect(listing.passedOver == true, "#1062: the passed-over range is saved, so the listing completes as not clean",
                sourceLocation: sourceLocation)
        #expect(listing.nextUid == range.upperBound + 1 && listing.loadHeldSince == nil && listing.carried == nil,
                "#1062: the listing is saved past the passed-over range: \(listing)", sourceLocation: sourceLocation)
        // Let the late answer free the connection.
        try await Task.sleep(for: .seconds(slowAnswerSeconds))
        let next = try await nextRange(w, clock)
        #expect(next?.lowerBound == range.upperBound + 1,
                "#1062: the next call goes on from past the passed-over range: \(next.map { "\($0)" } ?? "none")",
                sourceLocation: sourceLocation)
    }

    @Test("A range's membership proof times out with its hold past the bound: the range is passed over and saved, the folder gets no further request in that call, and the next call goes on from past the range")
    @MainActor
    func proofTimeoutPastTheHoldEndsTheCall() async throws {
        let first = Self.siteServer[0]
        try await Self.withWorld("pass-over-proof", server: Self.siteServer, local: Self.siteServer) { w in
            let clock = CatchUpTestClock()
            try await Self.setListing(w, nextUid: first, rangeWidth: Self.siteWidth, top: Self.siteServer.last,
                                      loadHeldSince: clock.now.addingTimeInterval(-Self.pastTheHold))
            try await Self.expectPassOverEndsTheCall(w, range: first...(first + Self.siteWidth - 1),
                                                     timingOut: "SEARCH", clock: clock)
        }
    }

    @Test("A missing message's header load times out with its hold past the bound: the range is passed over and saved, the folder gets no further request in that call, and the next call goes on from past the range")
    @MainActor
    func headerLoadTimeoutPastTheHoldEndsTheCall() async throws {
        let missing = Self.siteMissing
        try await Self.withWorld("pass-over-load", server: Self.siteServer, local: Self.siteServer) { w in
            try await w.dropLocal([missing])
            let clock = CatchUpTestClock()
            // The range starts at the missing message, where its hold runs.
            try await Self.setListing(w, nextUid: missing, rangeWidth: Self.siteWidth, top: Self.siteServer.last,
                                      loadHeldSince: clock.now.addingTimeInterval(-Self.pastTheHold))
            try await Self.expectPassOverEndsTheCall(w, range: missing...(missing + Self.siteWidth - 1),
                                                     timingOut: "ENVELOPE", clock: clock)
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
