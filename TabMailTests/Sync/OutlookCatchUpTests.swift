/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Outlook's catch-up of older mail (`ExchangeProviderCatchUp.swift`, ADR-IOS-107)
/// against the stateful Graph fake (`StatefulExchangeActionServer`), with a real
/// `DatabasePool`, the change reader for the folders' baselines, and the engine's
/// own catch-up apply (`SyncEngine.runCatchUp`). Every test asserts what the user
/// sees (rows, flags) or a bound the catch-up must keep (requests sent), never
/// how the provider gets there.
///
/// `.serialized, .processGlobalState`: these tests replace `AppDatabase.shared`
/// and set the page walk's hold clock and the catch-up's wall clock.
@Suite("Outlook catch-up", .serialized, .processGlobalState)
struct OutlookCatchUpTests {
    typealias R = OutlookChangeReadingTests
    typealias Seed = StatefulExchangeActionServer.Seed

    static let inbox = R.inbox
    static let archive = R.archive

    // MARK: - World

    /// Whole-second dates, as Graph serves them.
    struct Clock {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        func daysAgo(_ days: Double) -> Date {
            Date(timeIntervalSince1970: (now.timeIntervalSince1970 - days * 86_400).rounded(.down))
        }
    }

    static func seed(_ id: String, in folderId: String, at date: Date, isRead: Bool = false, isFlagged: Bool = false) -> Seed {
        Seed(rfc822MessageId: "\(id)@example.com", providerMessageId: id, folderId: folderId,
             isRead: isRead, isFlagged: isFlagged, receivedAt: date)
    }

    /// The change reader's world, with every folder's walk complete unless
    /// `walkComplete` is false, and an engine registered for its account.
    static func withWorld(
        seeds: [Seed] = [], heldSince: Date? = R.daysAgo(30), walkComplete: Bool = true,
        _ body: (R.World, SyncEngine) async throws -> Void
    ) async throws {
        try await R.withWorld(seeds: seeds, heldSince: heldSince) { w in
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = ? WHERE accountId = ?",
                               arguments: [walkComplete, w.accountId])
            }
            let engine = SyncEngine()
            await engine.register(
                accountId: w.accountId, provider: w.provider,
                workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            defer { SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = nil } }
            do {
                try await body(w, engine)
            } catch {
                await engine.remove(accountId: w.accountId)
                throw error
            }
            await engine.remove(accountId: w.accountId)
        }
    }

    /// A budget that never runs out (the Graph allowance still bounds a call).
    static func unlimited(expensive: Bool = false, storageLimit: Bool = false, at clock: @escaping @Sendable () -> Date = { Date() }) -> CatchUpContext {
        CatchUpContext(isExpensiveNetwork: expensive, deadline: .distantFuture, clock: clock, storageLimitInForce: storageLimit)
    }

    /// A slice of at most `requests` requests.
    static func requests(_ requests: Int) -> CatchUpContext {
        CatchUpContext(isExpensiveNetwork: false, deadline: .distantFuture, clock: { Date() }, maxRequests: requests)
    }

    /// One catch-up call for `paths`, applied by the engine. True on progress.
    @discardableResult
    static func pass(_ w: R.World, _ engine: SyncEngine, _ paths: [String], context: CatchUpContext = unlimited()) async -> Bool {
        await engine.runCatchUp(provider: w.provider, folderIds: paths.map(w.folderId), context: context)
    }

    static func state(_ w: R.World, _ path: String) throws -> ExchangeCatchUpState? {
        ExchangeCatchUpState.decode(try w.folder(path).catchUpState)
    }

    /// Calls until `path`'s listing in progress (or a new one) completes after
    /// `previous`. Returns the calls it took, or nil at `limit`.
    @discardableResult
    static func untilListed(
        _ w: R.World, _ engine: SyncEngine, _ path: String, after previous: Date? = nil,
        context: @autoclosure () -> CatchUpContext = unlimited(), limit: Int = 60
    ) async throws -> Int? {
        for call in 1...limit {
            await pass(w, engine, [path], context: context())
            let s = try state(w, path)
            if let done = s?.lastCompletedAt, s?.listing == nil, previous.map({ done > $0 }) ?? true { return call }
        }
        return nil
    }

    static func setLocal(_ w: R.World, _ id: String, in path: String, isRead: Bool? = nil, isFlagged: Bool? = nil) throws {
        let key = MessageIdentity.headerId(accountId: w.accountId, folderPath: path, messageId: id)
        try w.pool.write { db in
            if let isRead { try db.execute(sql: "UPDATE messageHeader SET isRead = ? WHERE id = ?", arguments: [isRead, key]) }
            if let isFlagged { try db.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [isFlagged, key]) }
        }
    }

    static func setWalkComplete(_ w: R.World, _ path: String, _ complete: Bool) throws {
        try w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET backfillComplete = ? WHERE id = ?", arguments: [complete, w.folderId(path)])
        }
    }

    static func setHoldClock(_ now: Date?) {
        SyncEngine.backfillPageHoldNowForTesting.withLock { $0 = now }
    }

    static var holdBound: TimeInterval { SyncConfig.backfillPageHoldSeconds }

    /// A `$batch` item body: the message as Graph returns it from `folderId`.
    static func detailBody(_ id: String, in folderId: String, at date: Date) -> String {
        let row = StatefulExchangeActionServer.graphRow(StatefulExchangeActionServer.Message(
            rfc822MessageId: "\(id)@example.com", providerMessageId: id, folderId: folderId,
            isRead: false, isFlagged: false, receivedAt: date))
        let data = (try? JSONSerialization.data(withJSONObject: row)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// GETs of one message (`/messages/{id}`), the direct load's fetch.
    static func messageGets(_ w: R.World, _ id: String) -> Int {
        w.server.http.recordedCalls().filter { call in
            call.method == "GET" && URL(string: call.url).flatMap { StatefulExchangeActionServer.messageId(from: $0, move: false) } == id
        }.count
    }

    /// The Graph request allowance of one catch-up call.
    static var allowance: Int {
        Int((SyncConfig.graphCatchUpRequestsPerSecond * SyncConfig.catchUpSliceIntervalSeconds).rounded(.down))
    }

    // MARK: - #733: removals

    /// An older Archive message deleted on the web before the update stays on
    /// the phone after the folder's baseline (a baseline never removes). The
    /// folder's first listing proves it gone and removes it; the others stay.
    @Test("#733: an older Archive message deleted on the web before the update is removed after the folder's baseline")
    func preUpdateDeletionIsRemoved() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("a-1", in: Self.archive, at: c.daysAgo(5)), Self.seed("a-3", in: Self.archive, at: c.daysAgo(7)),
        ]) { w, engine in
            for (id, days) in [("a-1", 5.0), ("a-2", 6), ("a-3", 7)] { try w.insertRow(id, in: w.archive, date: c.daysAgo(days)) }
            try await w.baselineAll()
            #expect(try w.rowIds(in: w.archive) == ["a-1", "a-2", "a-3"], "precondition: the baseline removed nothing")

            #expect(try await Self.untilListed(w, engine, w.archive) != nil, "the listing never completed")

            #expect(try w.rowIds(in: w.archive) == ["a-1", "a-3"])
        }
    }

    /// #733 going forward: once the Archive tracks, a delete and a move away on
    /// another client reach the phone through the delta alone.
    @Test("#733: an older Archive message deleted or moved away after tracking is removed by the delta, with no catch-up")
    func deltaRemovesAfterTracking() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("a-1", in: Self.archive, at: c.daysAgo(200)), Self.seed("a-2", in: Self.archive, at: c.daysAgo(300)),
        ]) { w, _ in
            try w.insertRow("a-1", in: w.archive, date: c.daysAgo(200))
            try w.insertRow("a-2", in: w.archive, date: c.daysAgo(300))
            try await w.baselineAll()

            w.server.deleteFromOtherClient(providerMessageId: "a-1")
            let movedId = try #require(w.server.moveFromOtherClient(providerMessageId: "a-2", to: Self.inbox))
            try await w.read()

            #expect(try w.rowIds(in: w.archive).isEmpty, "the deleted and the moved message left the Archive")
            #expect(try w.row(movedId, in: w.inbox) != nil, "the moved message is in the Inbox under its new id")
            #expect(w.server.requestCounts().dateFilteredListings == 0, "no listing was needed")
        }
    }

    /// The proofs: a row the listing leaves out is removed only when its own
    /// answer says it is gone or in another folder. A row the server holds in
    /// this folder (the listing missed it) stays, and is not asked about again.
    @Test("A row the listing leaves out is removed only when its own answer proves it gone or elsewhere")
    func proofOutcomes() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("keep", in: Self.archive, at: c.daysAgo(3)),
            Self.seed("c-moved", in: Self.archive, at: c.daysAgo(5)),
            Self.seed("c-same", in: Self.archive, at: c.daysAgo(6)),
        ]) { w, engine in
            for (id, days) in [("keep", 3.0), ("c-gone", 4), ("c-moved", 5), ("c-same", 6)] {
                try w.insertRow(id, in: w.archive, date: c.daysAgo(days))
            }
            try await w.baselineAll()
            w.server.hideFromListings(["c-moved", "c-same"])
            w.server.answerBatchItem(
                providerMessageId: "c-moved", status: 200, body: Self.detailBody("c-moved", in: Self.inbox, at: c.daysAgo(5)))

            #expect(try await Self.untilListed(w, engine, w.archive) != nil, "the listing never completed")

            #expect(try w.rowIds(in: w.archive) == ["keep", "c-same"],
                    "gone and moved-elsewhere rows are removed; a row the server holds here stays")
            let asked = w.batchedIds()
            #expect(asked.filter { $0 == "c-same" }.count == 1, "the row the server holds here was asked about once: \(asked)")
            #expect(!asked.contains("keep"), "a row the listing named needs no proof")

            let before = w.server.requestCounts().total
            #expect(!(await Self.pass(w, engine, [w.archive])), "nothing is due after the listing")
            #expect(w.server.requestCounts().total == before, "a completed listing with no lapse sends nothing")
        }
    }

    /// A proof answer that cannot be used (a 500 for that message) or that does
    /// not come (a 429) keeps the row. The candidate is asked again on later
    /// calls until the page walk's hold bound, then let go with its row kept, and
    /// the listing completes.
    @Test("An unusable or missing proof answer keeps the row; the candidate is retried until the hold bound, then let go")
    func unusableProofKeepsTheRow() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("keep", in: Self.archive, at: c.daysAgo(3)),
            Self.seed("u-bad", in: Self.archive, at: c.daysAgo(5)),
            Self.seed("u-busy", in: Self.archive, at: c.daysAgo(6)),
        ]) { w, engine in
            for (id, days) in [("keep", 3.0), ("u-bad", 5), ("u-busy", 6)] { try w.insertRow(id, in: w.archive, date: c.daysAgo(days)) }
            try await w.baselineAll()
            w.server.hideFromListings(["u-bad", "u-busy"])
            w.server.answerBatchItem(providerMessageId: "u-bad", status: 500, body: nil)
            w.server.answerBatchItem(providerMessageId: "u-busy", status: 429, body: nil)
            let start = Date()
            Self.setHoldClock(start)

            for _ in 0..<3 { await Self.pass(w, engine, [w.archive]) }
            Self.setHoldClock(start.addingTimeInterval(Self.holdBound - 60))
            await Self.pass(w, engine, [w.archive])

            #expect(try Self.state(w, w.archive)?.lastCompletedAt == nil, "the listing completed while candidates were held")
            #expect(try w.rowIds(in: w.archive) == ["keep", "u-bad", "u-busy"], "an unusable answer removed a row")
            #expect(w.batchedIds().filter { $0 == "u-bad" }.count >= 2, "the held candidate was not asked again")

            Self.setHoldClock(start.addingTimeInterval(Self.holdBound + 60))
            #expect(try await Self.untilListed(w, engine, w.archive, limit: 3) != nil, "past the hold bound the listing still did not complete")
            #expect(try w.rowIds(in: w.archive) == ["keep", "u-bad", "u-busy"], "letting a candidate go removed its row")

            let asked = w.batchedIds().count
            await Self.pass(w, engine, [w.archive])
            #expect(w.batchedIds().count == asked, "a let-go candidate is asked about again")
        }
    }

    // MARK: - #722: loads

    /// #722's residual: an old message moved into the Archive below its held
    /// range, with the walk complete. The baseline does not insert below the
    /// held range; the listing reaches down to the epoch and loads it. Under a
    /// storage limit, nothing below the oldest local row is listed or loaded.
    /// Either way the walk's columns are left as they were.
    @Test("#722: an old message moved in below the held range is loaded; not under a storage limit; the walk's columns stay",
          arguments: [false, true])
    func oldMovedInMessageLoads(storageLimit: Bool) async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("r-1", in: Self.archive, at: c.daysAgo(2)), Self.seed("o-1", in: Self.archive, at: c.daysAgo(400)),
        ]) { w, engine in
            try w.insertRow("r-1", in: w.archive, date: c.daysAgo(2))
            try await w.baselineAll()
            #expect(try w.row("o-1", in: w.archive) == nil, "precondition: the baseline does not insert below the held range")
            let walkBefore = try w.folder(w.archive)

            #expect(try await Self.untilListed(w, engine, w.archive, context: Self.unlimited(storageLimit: storageLimit)) != nil)

            #expect((try w.row("o-1", in: w.archive) != nil) == !storageLimit,
                    storageLimit ? "a message below the oldest kept row was loaded under a storage limit" : "the old moved-in message was not loaded")
            let oldest = Int(c.daysAgo(2).timeIntervalSince1970)
            if storageLimit {
                for url in w.server.dateFilteredListingURLs() {
                    let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }?.value ?? ""
                    let lower = StatefulExchangeActionServer.dateBounds(filter)?.first { $0.op == "ge" }?.second
                    #expect(lower.map { $0 >= oldest } == true, "a listing reached below the oldest kept row: \(filter)")
                }
            }
            let walkAfter = try w.folder(w.archive)
            #expect(walkAfter.backfillComplete == walkBefore.backfillComplete
                    && walkAfter.oldestSyncedDate == walkBefore.oldestSyncedDate
                    && walkAfter.backfillPageToken == walkBefore.backfillPageToken,
                    "the catch-up wrote the walk's columns")
        }
    }

    /// The walk pages by offset. A message deleted between two of its pages
    /// shifts the next page, so the walk never lists one message. Once the walk
    /// completes, the catch-up lists the folder again, down to the epoch, and
    /// loads it.
    @Test("A hole the walk's offset paging leaves when a message is deleted between its pages loads once the walk completes")
    func walkDriftHoleLoads() async throws {
        let c = Clock()
        let ids = (1...6).map { "m\($0)" }
        try await Self.withWorld(
            seeds: ids.enumerated().map { Self.seed($0.element, in: Self.archive, at: c.daysAgo(Double($0.offset + 1))) },
            heldSince: nil, walkComplete: false
        ) { w, engine in
            w.server.servePagedListings(pageSize: BackfillPageWalkFixture.pageSize)
            try await w.baselineAll()
            await Self.pass(w, engine, [w.archive])
            #expect(try Self.state(w, w.archive)?.lastCompletedAt != nil, "precondition: the first listing completed on an empty folder")

            w.server.failListings(status: 500, onlyWithSkipToken: true)
            _ = await engine.runBackfillWalk(account: try w.account(), deadline: BackfillPageWalkFixture.deadline())
            #expect(try w.rowIds(in: w.archive) == ["m1", "m2"], "precondition: the walk stopped after its first page")
            w.server.deleteFromOtherClient(providerMessageId: "m1")
            w.server.clearListingFailures()
            try await w.read()
            for _ in 0..<5 where !(try w.folder(w.archive).backfillComplete) {
                _ = await engine.runBackfillWalk(account: try w.account(), deadline: BackfillPageWalkFixture.deadline())
            }
            #expect(try w.folder(w.archive).backfillComplete, "precondition: the walk completed")
            #expect(try w.row("m3", in: w.archive) == nil, "precondition: the walk's offset skipped m3")

            #expect(try await Self.untilListed(w, engine, w.archive) != nil)

            #expect(try w.rowIds(in: w.archive) == w.server.messageIds(inFolder: Self.archive), "the hole stayed")
        }
    }

    /// The walk passes over a message whose fetch keeps failing past the hold
    /// bound. Once the walk completes, the catch-up lists the folder again and
    /// loads it.
    @Test("A message the walk passed over after its fetch kept failing loads once the walk completes")
    func walkPassedOverIdLoads() async throws {
        let c = Clock()
        try await Self.withWorld(
            seeds: (1...3).map { Self.seed("x\($0)", in: Self.archive, at: c.daysAgo(Double($0))) },
            heldSince: nil, walkComplete: false
        ) { w, engine in
            w.server.servePagedListings(pageSize: BackfillPageWalkFixture.pageSize)
            w.server.injectGetFailure(providerMessageId: "x3", status: 500)
            try await w.baselineAll()
            await Self.pass(w, engine, [w.archive])

            let start = Date()
            Self.setHoldClock(start)
            _ = await engine.runBackfillWalk(account: try w.account(), deadline: BackfillPageWalkFixture.deadline())
            Self.setHoldClock(start.addingTimeInterval(Self.holdBound + 60))
            _ = await engine.runBackfillWalk(account: try w.account(), deadline: BackfillPageWalkFixture.deadline())
            #expect(try w.folder(w.archive).backfillComplete, "precondition: the walk passed x3 over and completed")
            #expect(try w.row("x3", in: w.archive) == nil, "precondition: x3 was passed over")
            w.server.clearGetFailures()

            #expect(try await Self.untilListed(w, engine, w.archive) != nil)

            #expect(try w.row("x3", in: w.archive) != nil, "the passed-over message never loaded")
        }
    }

    // MARK: - Lapses

    /// A Graph refusal (410) lapses the folder. A message deleted during the
    /// refusal gap reaches no delta, and the new baseline never removes. Once the
    /// folder tracks again, a new listing removes it.
    @Test("A refusal lapses the folder: once it tracks again a new listing removes a message deleted in the gap")
    func refusalLapseListsAgain() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("a-1", in: Self.archive, at: c.daysAgo(5)), Self.seed("a-2", in: Self.archive, at: c.daysAgo(6)),
        ]) { w, engine in
            try w.insertRow("a-1", in: w.archive, date: c.daysAgo(5))
            try w.insertRow("a-2", in: w.archive, date: c.daysAgo(6))
            try await w.baselineAll()
            let first = try #require(try await Self.untilListed(w, engine, w.archive).flatMap { _ in try Self.state(w, w.archive)?.lastCompletedAt })

            w.server.refuseIssuedLinks(folderId: Self.archive, status: 410)
            try await w.read()
            #expect(try w.cursor(w.archive) == nil, "precondition: the refusal dropped the Archive's bookmark")
            w.server.deleteFromOtherClient(providerMessageId: "a-2")
            w.server.refuseIssuedLinks(folderId: Self.archive, status: 410)
            try await w.baselineAll()
            #expect(try w.row("a-2", in: w.archive) != nil, "precondition: the new baseline did not remove the gap's deletion")

            #expect(try await Self.untilListed(w, engine, w.archive, after: first) != nil, "no new listing after the lapse")

            #expect(try w.rowIds(in: w.archive) == ["a-1"])
        }
    }

    /// More messages to read again than the folder may keep (`changeRecheckLimit`)
    /// arms a listing; it heals a read state the delta never delivered.
    @Test("A re-read list that overflows arms a listing that heals a stale read state")
    func recheckOverflowHealsAFlag() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("f-1", in: Self.archive, at: c.daysAgo(5), isRead: true, isFlagged: true)]) { w, engine in
            try w.insertRow("f-1", in: w.archive, date: c.daysAgo(5), isRead: true, isFlagged: true)
            try await w.baselineAll()
            let first = try #require(try await Self.untilListed(w, engine, w.archive).flatMap { _ in try Self.state(w, w.archive)?.lastCompletedAt })
            // A change the delta never delivered: the phone holds a stale state.
            try Self.setLocal(w, "f-1", in: w.archive, isRead: false, isFlagged: false)

            let unreadable = (0...SyncConfig.changeRecheckLimit).map { String(format: "rr-%04d", $0) }
            for id in unreadable { w.server.answerBatchItem(providerMessageId: id, status: 500, body: nil) }
            let overflowing = FolderChangeState(tracking: true, recheck: unreadable).encoded
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [overflowing, w.folderId(w.archive)])
            }
            try await w.read()
            #expect(try Self.state(w, w.archive)?.lapsedSinceLastListing == true, "precondition: the overflow armed a listing")

            #expect(try await Self.untilListed(w, engine, w.archive, after: first) != nil)

            let row = try #require(try w.row("f-1", in: w.archive))
            #expect(row.isRead && row.isFlagged, "the stale read state and flag were not healed")
        }
    }

    // MARK: - #732, #767: the baseline (pins of the change reader)

    /// #732: a stored Archive row whose read state and flag changed on the
    /// server before the update is corrected by the folder's baseline.
    @Test("#732: a baseline corrects a stored Archive row's read state and flag changed before the update")
    func baselineCorrectsStoredFlags() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive, at: c.daysAgo(5), isRead: true, isFlagged: true)]) { w, _ in
            try w.insertRow("p-1", in: w.archive, date: c.daysAgo(5), isRead: false, isFlagged: false)
            try await w.baselineAll()
            let row = try #require(try w.row("p-1", in: w.archive))
            #expect(row.isRead, "the read state from before the update was not corrected")
            #expect(row.isFlagged, "the flag from before the update was not corrected")
        }
    }

    /// #767, Outlook: after a refusal, the folder's new baseline inserts every
    /// message inside the held range, however many arrived meanwhile, in the
    /// Inbox and in a busy non-Inbox folder alike.
    @Test("#767: after a refusal plus 200 new messages, all of them appear", arguments: [R.inbox, R.archive])
    func newMailAfterARefusalAllAppears(path: String) async throws {
        try await Self.withWorld { w, _ in
            try await w.baselineAll()
            w.server.refuseIssuedLinks(folderId: path, status: 410)
            let base = Date().addingTimeInterval(-3_600).timeIntervalSince1970.rounded(.down)
            let ids = (0..<200).map { String(format: "n-%03d", $0) }
            for (i, id) in ids.enumerated() {
                w.server.deliver(Self.seed(id, in: path, at: Date(timeIntervalSince1970: base + Double(i))))
            }
            for _ in 0..<10 {
                try await w.read()
                if try w.cursor(path)?.phase == .tracking, try Set(ids).isSubset(of: w.rowIds(in: path)) { break }
            }
            let missing = Set(ids).subtracting(try w.rowIds(in: path))
            #expect(missing.isEmpty, "\(missing.count) new message(s) never appeared in \(path)")
        }
    }

    // MARK: - Bounds

    /// No call sends more than its Graph allowance, a `$batch` counted at its
    /// width; over the request window that keeps the catch-up within its share
    /// of the mailbox limit.
    @Test("A call never sends more than the Graph allowance, a batch counted at its width")
    func requestCeiling() async throws {
        let c = Clock()
        let hidden = (0..<30).map { String(format: "h-%02d", $0) }
        let missing = (0..<12).map { String(format: "m-%02d", $0) }
        try await Self.withWorld(seeds:
            hidden.enumerated().map { Self.seed($0.element, in: Self.archive, at: c.daysAgo(Double($0.offset) + 2)) }
            + missing.enumerated().map { Self.seed($0.element, in: Self.archive, at: c.daysAgo(Double($0.offset) + 40)) }
        ) { w, engine in
            for (i, id) in hidden.enumerated() { try w.insertRow(id, in: w.archive, date: c.daysAgo(Double(i) + 2)) }
            try await w.baselineAll()
            w.server.hideFromListings(Set(hidden))
            let windowCalls = SyncConfig.graphMailboxRequestWindowSeconds / SyncConfig.catchUpSliceIntervalSeconds
            #expect(Double(Self.allowance) * windowCalls <= SyncConfig.graphMailboxRequestLimit * SyncConfig.graphCatchUpRequestShare,
                    "the per-call allowance exceeds the catch-up's share of the mailbox limit")

            var calls = 0
            while try Self.state(w, w.archive)?.lastCompletedAt == nil, calls < 60 {
                let before = w.server.requestCounts()
                await Self.pass(w, engine, [w.archive])
                let after = w.server.requestCounts()
                let sent = (after.dateFilteredListings - before.dateFilteredListings)
                    + (after.batchItems - before.batchItems) + (after.messageGets - before.messageGets)
                #expect(sent <= Self.allowance, "call \(calls) sent \(sent) requests, over the allowance of \(Self.allowance)")
                calls += 1
            }
            #expect(try Self.state(w, w.archive)?.lastCompletedAt != nil, "the listing never completed")
            #expect(Set(missing).isSubset(of: try w.rowIds(in: w.archive)), "a missing message never loaded")
        }
    }

    /// Nothing due: no request and no progress. A failed listing request: no
    /// progress, so the run stops; the next call lists again.
    @Test("A call with nothing due sends nothing; a failed listing request makes no progress")
    func progressRules() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive, at: c.daysAgo(5))]) { w, engine in
            try w.insertRow("a-1", in: w.archive, date: c.daysAgo(5))
            try await w.baselineAll()
            w.server.failCatchUpListings([.status(500)])
            #expect(!(await Self.pass(w, engine, [w.archive])), "a failed listing request reported progress")
            #expect(w.server.catchUpListingFailuresServed() == 1, "precondition: the listing request failed")

            #expect(await Self.pass(w, engine, [w.archive]), "the next call made no progress")
            #expect(try Self.state(w, w.archive)?.lastCompletedAt != nil)

            let before = w.server.requestCounts().total
            #expect(!(await Self.pass(w, engine, [w.archive])), "a call with nothing due reported progress")
            #expect(w.server.requestCounts().total == before, "a call with nothing due sent a request")
        }
    }

    /// Paged by date: a listing cut off after every page, with messages
    /// delivered and deleted between its pages, still lists every message that
    /// stayed in the folder, so none is left missing.
    @Test("A listing resumed after every page, with mail delivered and deleted between pages, leaves no hole")
    func keysetPagingLeavesNoHole() async throws {
        let c = Clock()
        let local = (1...12).map { (String(format: "k-%02d", $0), Double($0)) }
        let holes = ["h-a", "h-b", "h-c"]
        try await Self.withWorld(seeds:
            local.map { Self.seed($0.0, in: Self.archive, at: c.daysAgo($0.1)) }
            + zip(holes, [7.5, 9.5, 11.5]).map { Self.seed($0.0, in: Self.archive, at: c.daysAgo($0.1)) },
            heldSince: c.daysAgo(0.5)
        ) { w, engine in
            for (id, days) in local { try w.insertRow(id, in: w.archive, date: c.daysAgo(days)) }
            try await w.baselineAll()
            #expect(try w.rowIds(in: w.archive).isDisjoint(with: holes), "precondition: the baseline does not insert below the held range")
            w.server.setCatchUpListingPageCap(3)
            let deletions = Mutex(["k-01", "k-02", "k-03", "k-04"])
            let server = w.server
            server.afterCatchUpListingPage { _ in
                // Each page shifts the folder: one of the newest messages leaves.
                if let id = deletions.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    server.deleteFromOtherClient(providerMessageId: id)
                }
            }

            #expect(try await Self.untilListed(w, engine, w.archive, context: Self.requests(3)) != nil)

            let rows = try w.rowIds(in: w.archive)
            #expect(Set(holes).isSubset(of: rows), "a message missing on the phone was never listed: \(Set(holes).subtracting(rows))")
            for id in holes { #expect(Self.messageGets(w, id) == 1, "\(id) was loaded \(Self.messageGets(w, id)) times") }
        }
    }

    /// More messages in one second than a page holds are all listed, through
    /// Graph's own link inside the call.
    @Test("More messages in one second than a page holds are all listed and loaded")
    func oneSecondOverflowsAPage() async throws {
        let c = Clock()
        let second = c.daysAgo(10)
        let same = (1...7).map { "s-\($0)" }
        try await Self.withWorld(seeds:
            [Self.seed("anchor", in: Self.archive, at: second)] + same.map { Self.seed($0, in: Self.archive, at: second) },
            heldSince: c.daysAgo(0.5)
        ) { w, engine in
            try w.insertRow("anchor", in: w.archive, date: second)
            try await w.baselineAll()
            #expect(try w.rowIds(in: w.archive) == ["anchor"], "precondition: the baseline does not insert below the held range")
            w.server.setCatchUpListingPageCap(3)

            #expect(try await Self.untilListed(w, engine, w.archive) != nil)

            let listed = try w.rowIds(in: w.archive)
            #expect(Set(same).isSubset(of: listed),
                    "messages sharing one second past the first page were not listed: \(Set(same).subtracting(listed))")
        }
    }

    /// Graph gives several messages of one folder the same `receivedDateTime`
    /// second (groups of three are common). A page boundary that falls inside
    /// such a group, wherever it falls, skips none of the group and loads none
    /// twice, and the listing completes.
    @Test("A page boundary inside a group of messages sharing one second skips none and loads none twice",
          arguments: [2, 3, 4])
    func pageBoundaryInsideASameSecondGroup(pageCap: Int) async throws {
        let c = Clock()
        let s = c.daysAgo(10)
        func at(_ offset: Int) -> Date { s.addingTimeInterval(TimeInterval(offset)) }
        // A, B newer; C, D, E share one second; F, G older. Local: A, C, F.
        let all: [(String, Date)] = [("A", at(3)), ("B", at(2)), ("C", at(1)), ("D", at(1)), ("E", at(1)), ("F", at(0)), ("G", at(-1))]
        let local = ["A", "C", "F"]
        try await Self.withWorld(seeds: all.map { Self.seed($0.0, in: Self.archive, at: $0.1) }, heldSince: c.daysAgo(0.5)) { w, engine in
            for (id, date) in all where local.contains(id) { try w.insertRow(id, in: w.archive, date: date) }
            try await w.baselineAll()
            #expect(try w.rowIds(in: w.archive) == Set(local), "precondition: the baseline does not insert below the held range")
            w.server.setCatchUpListingPageCap(pageCap)

            #expect(try await Self.untilListed(w, engine, w.archive) != nil, "the listing did not complete")

            #expect(try w.rowIds(in: w.archive) == Set(all.map(\.0)), "a message of the folder is missing on the phone")
            let rows = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ?", arguments: [w.folderId(w.archive)])
            }
            #expect(rows == all.count, "a message has more than one row")
            for id in ["B", "D", "E", "G"] {
                #expect(Self.messageGets(w, id) == 1, "\(id) was loaded \(Self.messageGets(w, id)) times")
            }
            #expect(w.batchedIds().isEmpty, "a row the server lists was taken for a removal candidate")
        }
    }

    /// A load that keeps failing holds its page for at most the hold bound; then
    /// the listing passes over it and completes.
    @Test("A failing load holds its page until the hold bound, then the listing passes over it")
    func failingLoadHoldsUntilTheBound() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("r-1", in: Self.archive, at: c.daysAgo(2)), Self.seed("m-x", in: Self.archive, at: c.daysAgo(10)),
        ], heldSince: c.daysAgo(0.5)) { w, engine in
            try w.insertRow("r-1", in: w.archive, date: c.daysAgo(2))
            try await w.baselineAll()
            #expect(try w.row("m-x", in: w.archive) == nil, "precondition: the baseline does not insert below the held range")
            w.server.injectGetFailure(providerMessageId: "m-x", status: 500)
            let start = Date()
            Self.setHoldClock(start)
            for _ in 0..<2 { await Self.pass(w, engine, [w.archive]) }
            Self.setHoldClock(start.addingTimeInterval(Self.holdBound - 60))
            await Self.pass(w, engine, [w.archive])
            #expect(try Self.state(w, w.archive)?.lastCompletedAt == nil, "the page was passed over inside the hold bound")

            Self.setHoldClock(start.addingTimeInterval(Self.holdBound + 60))
            #expect(try await Self.untilListed(w, engine, w.archive, limit: 3) != nil, "the page stayed held past the bound")
            #expect(try w.row("m-x", in: w.archive) == nil)
        }
    }

    /// Placeholder rows (`sent-`, `draft-`) are never named to Graph.
    @Test("Placeholder ids are never asked about or loaded, and their rows stay")
    func placeholdersAreNeverNamed() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("r-1", in: Self.archive, at: c.daysAgo(2))]) { w, engine in
            try w.insertRow("r-1", in: w.archive, date: c.daysAgo(2))
            try w.insertRow("sent-local-1", in: w.archive, date: c.daysAgo(3))
            try w.insertRow("draft-local-1", in: w.archive, date: c.daysAgo(4))
            try await w.baselineAll()

            #expect(try await Self.untilListed(w, engine, w.archive) != nil)

            let named = w.batchedIds() + ["sent-local-1", "draft-local-1"].filter { Self.messageGets(w, $0) > 0 }
            #expect(!named.contains { isSyntheticPlaceholderId($0) }, "a placeholder id was named: \(named)")
            #expect(try w.rowIds(in: w.archive) == ["r-1", "sent-local-1", "draft-local-1"])
        }
    }

    /// Mail newer than the newest local row belongs to the delta and the full
    /// sync: the catch-up never lists or loads it.
    @Test("Nothing above the newest local row is listed or loaded")
    func nothingAboveTheNewestRow() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("r-1", in: Self.archive, at: c.daysAgo(5)), Self.seed("n-1", in: Self.archive, at: c.daysAgo(1)),
        ]) { w, engine in
            try w.insertRow("r-1", in: w.archive, date: c.daysAgo(5))
            try await w.baselineAll()
            try await w.pool.write { db in
                try db.execute(sql: "DELETE FROM messageHeader WHERE messageId = 'n-1'")
            }

            #expect(try await Self.untilListed(w, engine, w.archive) != nil)

            #expect(try w.row("n-1", in: w.archive) == nil, "mail above the newest local row was loaded")
            let newest = Int(c.daysAgo(5).timeIntervalSince1970)
            for url in w.server.dateFilteredListingURLs() {
                let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }?.value ?? ""
                let upper = StatefulExchangeActionServer.dateBounds(filter)?.first { $0.op == "lt" }?.second
                #expect(upper.map { $0 <= newest + 1 } == true, "a listing reached above the newest local row: \(filter)")
            }
        }
    }

    /// A load whose insert fails writes no state: the next call lists and loads
    /// it again.
    @Test("A load that does not land writes no state; the next call loads it")
    func failedInsertWritesNoState() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("r-1", in: Self.archive, at: c.daysAgo(2)), Self.seed("m", in: Self.archive, at: c.daysAgo(10)),
        ], heldSince: c.daysAgo(0.5)) { w, engine in
            try w.insertRow("r-1", in: w.archive, date: c.daysAgo(2))
            try await w.baselineAll()
            #expect(try w.row("m", in: w.archive) == nil, "precondition: the baseline does not insert below the held range")
            try await w.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER test_failInsert BEFORE INSERT ON messageHeader
                    WHEN NEW.messageId = 'm'
                    BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END
                    """)
            }
            let before = try w.folder(w.archive).catchUpState

            await Self.pass(w, engine, [w.archive])
            #expect(Self.messageGets(w, "m") >= 1, "precondition: m was loaded")
            #expect(try w.folder(w.archive).catchUpState == before, "a state was written although the load did not land")

            try await w.pool.write { db in try db.execute(sql: "DROP TRIGGER test_failInsert") }
            #expect(try await Self.untilListed(w, engine, w.archive) != nil)
            #expect(try w.row("m", in: w.archive) != nil)
        }
    }

    /// On an expensive network the first listing waits up to the wait bound
    /// from the catch-up's first sight of the folder.
    @Test("On an expensive network a folder's first listing waits until the bound, counted from first sight")
    func expensiveNetworkWaits() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive, at: c.daysAgo(5))]) { w, engine in
            try w.insertRow("a-1", in: w.archive, date: c.daysAgo(5))
            try await w.baselineAll()
            let t0 = Date()
            let before = w.server.requestCounts().total
            await Self.pass(w, engine, [w.archive], context: Self.unlimited(expensive: true, at: { t0 }))
            #expect(try Self.state(w, w.archive)?.createdAt == t0, "first sight was not recorded")
            let wait = SyncConfig.catchUpExpensiveNetworkMaxWaitSeconds
            await Self.pass(w, engine, [w.archive], context: Self.unlimited(expensive: true, at: { t0.addingTimeInterval(wait - 1) }))
            #expect(w.server.requestCounts().total == before, "a request went out on an expensive network before the bound")

            await Self.pass(w, engine, [w.archive], context: Self.unlimited(expensive: true, at: { t0.addingTimeInterval(wait) }))
            #expect(w.server.requestCounts().dateFilteredListings > 0, "no listing after the bound")
        }
    }

    /// A Settings reset clears the walk and the change bookmark but not the
    /// catch-up state. Once the folder tracks again and its walk completes, a
    /// new listing runs, and heals what the re-download left.
    @Test("After a Settings reset, a new listing runs once the folder tracks and its walk completes")
    func settingsResetListsAgain() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive, at: c.daysAgo(5))]) { w, engine in
            try w.insertRow("a-1", in: w.archive, date: c.daysAgo(5))
            try await w.baselineAll()
            let first = try #require(try await Self.untilListed(w, engine, w.archive).flatMap { _ in try Self.state(w, w.archive)?.lastCompletedAt })

            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET backfillComplete = 0, changeCursor = NULL, changeState = NULL WHERE id = ?",
                               arguments: [w.folderId(w.archive)])
            }
            try w.insertRow("ghost", in: w.archive, date: c.daysAgo(6))
            await Self.pass(w, engine, [w.archive])
            try await w.baselineAll()
            await Self.pass(w, engine, [w.archive])
            #expect(try w.row("ghost", in: w.archive) != nil, "precondition: nothing listed while the walk is unfinished")
            try Self.setWalkComplete(w, w.archive, true)

            #expect(try await Self.untilListed(w, engine, w.archive, after: first) != nil, "no listing after the walk completed")
            #expect(try w.rowIds(in: w.archive) == ["a-1"])
        }
    }

    /// The user's queued action wins over the listing's value (the engine's
    /// pending-operation shield, through the seam).
    @Test("A queued user flag action wins over the listing's value")
    func queuedActionWins() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("x", in: Self.archive, at: c.daysAgo(5), isRead: true),
            Self.seed("y", in: Self.archive, at: c.daysAgo(6), isRead: true),
        ]) { w, engine in
            try w.insertRow("x", in: w.archive, date: c.daysAgo(5))
            try w.insertRow("y", in: w.archive, date: c.daysAgo(6))
            try await w.baselineAll()
            try Self.setLocal(w, "x", in: w.archive, isRead: false)
            try Self.setLocal(w, "y", in: w.archive, isRead: false)
            let accountId = w.accountId
            try await w.pool.write { db in
                var op = PendingOperation(type: .markUnread, messageIds: ["x"], accountId: accountId, folderPath: OutlookCatchUpTests.archive)
                try op.insert(db)
            }

            #expect(try await Self.untilListed(w, engine, w.archive) != nil)

            #expect(try w.row("x", in: w.archive)?.isRead == false, "the listing overwrote a queued user action")
            #expect(try w.row("y", in: w.archive)?.isRead == true, "precondition: the listing healed the row no action stands on")
        }
    }

    // MARK: - The plan

    @Test("The per-folder plan: expensive wait, a listing in progress, the tracking gate, and the three reasons to list")
    func plan() {
        let now = Date()
        func plan(_ s: ExchangeCatchUpState?, gate: Bool = true, walk: Bool = true, expensive: Bool = false) -> ExchangeProvider.CatchUpPlan {
            ExchangeProvider.catchUpPlan(state: s, trackingGateOpen: gate, walkComplete: walk, isExpensiveNetwork: expensive, now: now)
        }
        let fresh = ExchangeCatchUpState(createdAt: now)
        var done = fresh
        done.lastCompletedAt = now
        var lapsed = done
        lapsed.lapseCount = 1
        var walkSeen = done
        walkSeen.walkIncompleteSeen = true
        var inProgress = done
        inProgress.listing = .init(nextBeforeSecond: 5)

        #expect(plan(nil) == .list(.init()), "no state: the first listing")
        #expect(plan(fresh, gate: false) == .none, "the gate holds a new listing")
        #expect(plan(inProgress, gate: false) == .list(.init(nextBeforeSecond: 5)), "a listing in progress continues")
        #expect(plan(done) == .none, "no periodic listing")
        #expect(plan(lapsed) == .list(.init(lapseCountAtStart: 1)), "a lapse lists again")
        #expect(plan(walkSeen) == .list(.init()), "a walk completed since lists again")
        #expect(plan(walkSeen, walk: false) == .none, "not while the walk is unfinished")
        #expect(plan(fresh, expensive: true) == .none, "an expensive network waits")
    }
}
