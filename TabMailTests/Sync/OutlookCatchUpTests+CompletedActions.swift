/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import os
import Synchronization
import Testing
@testable import TabMail

// MARK: - A catch-up read that began before a user action completed
//
// A catch-up page carries a message's read and flag state as the server held it
// when the page was read. A user action on that message that completes after the
// read began is newer, so the apply never lets the page's value overwrite it,
// however long the read takes to reach the apply: the shared 30 s protection
// (`recentlyCompleted`) can run out first. The apply compares the action's
// completion time (`AccountManager.recordActionCompleted`) with the moment the
// read began (`SyncEngine.runCatchUp` stamps it just before the provider call),
// both on one wall clock (`CatchUpWallClock`). A read older than the completion
// log's retention applies no flag update at all, and still applies its
// removals, loads and state, so a listing always moves on.
extension OutlookCatchUpTests {

    /// Every call reads the wall clock from `clock`.
    static func withWallClock<T>(_ clock: OSAllocatedUnfairLock<Date>, _ body: () async throws -> T) async rethrows -> T {
        CatchUpWallClock.nowForTesting.withLock { $0 = { clock.withLock { $0 } } }
        defer { CatchUpWallClock.nowForTesting.withLock { $0 = nil } }
        return try await body()
    }

    /// A user action on `ids` (with the RFC ids `insertRow` gives them)
    /// completing at `at` on the wall clock, as the queue's drain records it.
    /// Only the completion log: the shared 30 s protection has run out.
    static func completeAction(_ w: R.World, _ ids: [String], at: Date) throws {
        let keys = try ids.flatMap { id -> [String] in
            let rfc = try w.pool.read { db in
                try String.fetchOne(db, sql: "SELECT rfc822MessageId FROM messageHeader WHERE messageId = ?", arguments: [id])
            }
            return [id] + (rfc.map { [$0] } ?? [])
        }
        let clock = Mutex(at)
        CatchUpWallClock.nowForTesting.withLock { $0 = { clock.withLock { $0 } } }
        defer { CatchUpWallClock.nowForTesting.withLock { $0 = nil } }
        AccountManager.shared.recordActionCompleted(accountId: w.accountId, messageKeys: keys)
    }

    /// The Archive rows of the apply tests: `u` the user flagged (the result
    /// carries it unflagged), `o` whose read state the result heals, and `g` the
    /// user also acted on, which the result proves gone.
    static func applyWorld(_ body: (R.World, SyncEngine) async throws -> Void) async throws {
        let c = Clock()
        try await withWorld { w, engine in
            try w.insertRow("u", in: w.archive, date: c.daysAgo(3), isFlagged: true)
            try w.insertRow("o", in: w.archive, date: c.daysAgo(4), isRead: false)
            try w.insertRow("g", in: w.archive, date: c.daysAgo(5))
            try await body(w, engine)
        }
    }

    static func staleResult(_ w: R.World) -> CatchUpFolderResult {
        var result = CatchUpFolderResult(folderId: w.folderId(w.archive), epoch: nil)
        result.flagUpdates = [
            CatchUpFlagUpdate(messageId: "u", isRead: false, isFlagged: false),
            CatchUpFlagUpdate(messageId: "o", isRead: true, isFlagged: false),
        ]
        result.removedIds = ["g"]
        result.newState = #"{"marker":"applied"}"#
        return result
    }

    static func apply(_ w: R.World, _ engine: SyncEngine, _ result: CatchUpFolderResult, readStartedAt: Date, now: Date) async -> CatchUpApplyOutcome {
        await withWallClock(OSAllocatedUnfairLock(initialState: now)) {
            await engine.applyCatchUpResult(result, windowMode: .date, readStartedAt: readStartedAt)
        }
    }

    @Test("26a: a flag update read before the user's flag action completed is skipped after the 30 s protection; the rest applies")
    func readBeforeAnActionIsSkipped() async throws {
        try await Self.applyWorld { w, engine in
            let readStartedAt = Date()
            let completedAt = readStartedAt.addingTimeInterval(1)
            try Self.completeAction(w, ["u", "g"], at: completedAt)

            let outcome = await Self.apply(w, engine, Self.staleResult(w), readStartedAt: readStartedAt,
                                           now: completedAt.addingTimeInterval(SyncConfig.recentlyCompletedTTLSeconds + 1))

            guard case .applied = outcome else { Issue.record("not applied: \(outcome)"); return }
            #expect(try w.row("u", in: w.archive)?.isFlagged == true, "the read overwrote the user's newer flag")
            #expect(try w.row("o", in: w.archive)?.isRead == true, "another message's update did not apply")
            #expect(try w.row("g", in: w.archive) == nil, "a gone message the user had acted on was not removed")
            #expect(try w.folder(w.archive).catchUpState == #"{"marker":"applied"}"#, "the state was not written")
        }
    }

    @Test("26b: a flag update read after the user's action completed applies")
    func readAfterAnActionApplies() async throws {
        try await Self.applyWorld { w, engine in
            let readStartedAt = Date()
            try Self.completeAction(w, ["u"], at: readStartedAt.addingTimeInterval(-1))

            _ = await Self.apply(w, engine, Self.staleResult(w), readStartedAt: readStartedAt, now: readStartedAt.addingTimeInterval(40))

            #expect(try w.row("u", in: w.archive)?.isFlagged == false, "an update read after the action was skipped")
            #expect(try w.row("o", in: w.archive)?.isRead == true)
        }
    }

    @Test("26c: an action that completed exactly when the read began wins")
    func actionAtTheReadStartWins() async throws {
        try await Self.applyWorld { w, engine in
            let readStartedAt = Date()
            try Self.completeAction(w, ["u"], at: readStartedAt)

            _ = await Self.apply(w, engine, Self.staleResult(w), readStartedAt: readStartedAt, now: readStartedAt.addingTimeInterval(40))

            #expect(try w.row("u", in: w.archive)?.isFlagged == true)
        }
    }

    /// Over-age: the log may have dropped a completion that matters, so no flag
    /// update applies; the removals and the state still do. Just inside the
    /// retention, the per-message rule applies as usual.
    @Test("26d: a read as old as the log's retention applies no flag update but its removals and state; just inside it, the rest applies",
          arguments: [0.0, -1.0])
    func overAgeReadAppliesNoFlags(offset: TimeInterval) async throws {
        try await Self.applyWorld { w, engine in
            let readStartedAt = Date()
            try Self.completeAction(w, ["u"], at: readStartedAt.addingTimeInterval(1))
            let now = readStartedAt.addingTimeInterval(SyncConfig.catchUpCompletionLogRetentionSeconds + offset)

            let outcome = await Self.apply(w, engine, Self.staleResult(w), readStartedAt: readStartedAt, now: now)

            guard case .applied = outcome else { Issue.record("not applied: \(outcome)"); return }
            let overAge = offset >= 0
            #expect(try w.row("u", in: w.archive)?.isFlagged == true, "the read overwrote the user's newer flag")
            #expect(try w.row("o", in: w.archive)?.isRead == !overAge,
                    overAge ? "an over-age read applied a flag update" : "a read inside the retention applied no flag update")
            #expect(try w.row("g", in: w.archive) == nil, "the removal did not apply")
            #expect(try w.folder(w.archive).catchUpState == #"{"marker":"applied"}"#, "the state was not written")
        }
    }

    /// The completion log's retention and the over-age bound are one constant.
    /// Another action completes while the read is in flight, late enough that a
    /// shorter retention would have dropped the user's entry. Just past the
    /// retention the read is over-age, so no flag update applies; just inside
    /// it, the entry is still in the log, so the user's flag wins. Either way the
    /// user's flag stays.
    @Test("26d: an entry the log may have dropped is never needed, and one it still needs is never dropped",
          arguments: [120.0, -60.0])
    func retentionAndOverAgeAreOneBound(offset: TimeInterval) async throws {
        try await Self.applyWorld { w, engine in
            let readStartedAt = Date()
            let retention = SyncConfig.catchUpCompletionLogRetentionSeconds
            try Self.completeAction(w, ["u"], at: readStartedAt.addingTimeInterval(1))
            // Another action, just before the apply: a shorter retention would
            // drop the user's entry here.
            try Self.completeAction(w, ["x"], at: readStartedAt.addingTimeInterval(retention + offset - 1))
            let now = readStartedAt.addingTimeInterval(retention + offset)

            let outcome = await Self.apply(w, engine, Self.staleResult(w), readStartedAt: readStartedAt, now: now)

            guard case .applied = outcome else { Issue.record("not applied: \(outcome)"); return }
            let overAge = offset >= 0
            #expect(try w.row("u", in: w.archive)?.isFlagged == true, "the read overwrote the user's newer flag")
            #expect(try w.row("o", in: w.archive)?.isRead == !overAge,
                    overAge ? "an over-age read applied a flag update" : "a read inside the retention applied no flag update")
            #expect(try w.row("g", in: w.archive) == nil, "the removal did not apply")
        }
    }

    /// 26a through the queue: the user's flag is queued before the read began and
    /// completes after it (its request is answered late). What counts is when
    /// the action completed, not when it was queued, so the flag wins.
    @Test("26a: a flag queued before the read began and completed after it wins over the read")
    func queuedBeforeReadCompletedAfterWins() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("u", in: Self.archive, at: c.daysAgo(3))]) { w, engine in
            try w.insertRow("u", in: w.archive, date: c.daysAgo(3))
            try await w.baselineAll()
            await AccountManager.shared.registerProviderForTesting(accountId: w.accountId, provider: w.provider)
            let wall = OSAllocatedUnfairLock(initialState: Date())
            do {
                try await Self.withWallClock(wall) {
                    w.server.holdPatch(providerMessageId: "u", forSeconds: 0.5)
                    await AccountManager.shared.markFlagged([try #require(try w.row("u", in: w.archive))], flagged: true)
                    let readStartedAt = wall.withLock { $0 = $0.addingTimeInterval(1); return $0 }
                    wall.withLock { $0 = $0.addingTimeInterval(1) }
                    try await Self.drainQueue(w)
                    #expect(w.server.snapshot(providerMessageId: "u")?.isFlagged == true, "precondition: the flag landed")
                    // The shared 30 s protection runs out.
                    await AccountManager.shared.clearRecentlyCompletedForTesting()
                    wall.withLock { $0 = $0.addingTimeInterval(SyncConfig.recentlyCompletedTTLSeconds + 1) }

                    var stale = CatchUpFolderResult(folderId: w.folderId(w.archive), epoch: nil)
                    stale.flagUpdates = [CatchUpFlagUpdate(messageId: "u", isRead: false, isFlagged: false)]
                    stale.newState = try w.folder(w.archive).catchUpState
                    _ = await engine.applyCatchUpResult(stale, windowMode: .date, readStartedAt: readStartedAt)

                    #expect(try w.row("u", in: w.archive)?.isFlagged == true, "a read that began before the flag completed overwrote it")
                }
            } catch {
                await AccountManager.shared.unregisterProviderForTesting(accountId: w.accountId)
                throw error
            }
            await AccountManager.shared.unregisterProviderForTesting(accountId: w.accountId)
        }
    }

    /// 26e, the whole cycle: the user's flag completes while the slice's read is
    /// in flight (after the page that carries the message is served), so the
    /// page holds the state from before it. The read began before the provider
    /// call, so the user's flag stays.
    @Test("26e: a flag the user sets while a slice's read is in flight survives that slice")
    func actionDuringTheReadSurvives() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("u", in: Self.archive, at: c.daysAgo(3)), Self.seed("o", in: Self.archive, at: c.daysAgo(4), isRead: true),
        ]) { w, engine in
            try w.insertRow("u", in: w.archive, date: c.daysAgo(3))
            try w.insertRow("o", in: w.archive, date: c.daysAgo(4))
            try await w.baselineAll()
            let wall = OSAllocatedUnfairLock(initialState: Date())
            let key = MessageIdentity.headerId(accountId: w.accountId, folderPath: w.archive, messageId: "u")
            let (pool, server, accountId) = (w.pool, w.server, w.accountId)
            server.afterCatchUpListingPage { serial in
                guard serial == 1 else { return }
                try? pool.write { db in try db.execute(sql: "UPDATE messageHeader SET isFlagged = 1 WHERE id = ?", arguments: [key]) }
                server.setFlagFromOtherClient(providerMessageId: "u", isFlagged: true)
                wall.withLock { $0 = $0.addingTimeInterval(5) }
                AccountManager.shared.recordActionCompleted(accountId: accountId, messageKeys: ["u"])
                // The read goes on after the action completed.
                wall.withLock { $0 = $0.addingTimeInterval(1) }
            }

            let listed = try await Self.withWallClock(wall) {
                try await Self.untilListed(w, engine, w.archive)
            }
            #expect(listed != nil, "the listing did not complete")

            #expect(try w.row("u", in: w.archive)?.isFlagged == true, "the slice's older value overwrote the user's flag")
            #expect(try w.row("o", in: w.archive)?.isRead == true, "precondition: the slice healed another row")
        }
    }

    /// 26e with the slice's own clock far from the wall clock: the read's start
    /// is taken on the wall clock the completions are recorded on, never on the
    /// slice's budget clock, so the user's flag still stays.
    @Test("26f: the read's start is on the wall clock, not the slice's clock")
    func readStartIsOnTheWallClock() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("u", in: Self.archive, at: c.daysAgo(3))]) { w, engine in
            try w.insertRow("u", in: w.archive, date: c.daysAgo(3))
            try await w.baselineAll()
            let wall = OSAllocatedUnfairLock(initialState: Date())
            let key = MessageIdentity.headerId(accountId: w.accountId, folderPath: w.archive, messageId: "u")
            let (pool, server, accountId) = (w.pool, w.server, w.accountId)
            server.afterCatchUpListingPage { serial in
                guard serial == 1 else { return }
                try? pool.write { db in try db.execute(sql: "UPDATE messageHeader SET isFlagged = 1 WHERE id = ?", arguments: [key]) }
                server.setFlagFromOtherClient(providerMessageId: "u", isFlagged: true)
                wall.withLock { $0 = $0.addingTimeInterval(5) }
                AccountManager.shared.recordActionCompleted(accountId: accountId, messageKeys: ["u"])
            }
            // The slice's clock runs two hours ahead of the wall clock.
            let sliceClock: @Sendable () -> Date = { wall.withLock { $0 }.addingTimeInterval(7_200) }

            let listed = try await Self.withWallClock(wall) {
                try await Self.untilListed(w, engine, w.archive, context: Self.unlimited(at: sliceClock))
            }
            #expect(listed != nil, "the listing did not complete")

            #expect(try w.row("u", in: w.archive)?.isFlagged == true, "the slice's older value overwrote the user's flag")
        }
    }

    /// Outlook gives a message a new id when it moves. The user moves a message
    /// and then flags it; a catch-up read of the destination that began before
    /// the flag completed carries it unflagged. The log records the flag under
    /// the id the message has after the move (the one the apply looks up), for
    /// this account, so the flag stays: whether the flag was queued before the
    /// read began or after.
    @Test("A message moved and then flagged keeps its flag against a catch-up read that began before the flag completed",
          arguments: [false, true])
    func movedThenFlaggedIsProtected(flagQueuedBeforeRead: Bool) async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [Self.seed("m", in: Self.inbox, at: c.daysAgo(5))]) { w, engine in
            try w.insertRow("m", in: w.inbox, date: c.daysAgo(5))
            try await w.baselineAll()
            await AccountManager.shared.registerProviderForTesting(accountId: w.accountId, provider: w.provider)
            let wall = OSAllocatedUnfairLock(initialState: Date())
            do {
                try await Self.withWallClock(wall) {
                    _ = await AccountManager.shared.move([try #require(try w.row("m", in: w.inbox))], to: w.archive)
                    try await Self.drainQueue(w)
                    let movedId = try #require(try w.rowIds(in: w.archive).first, "precondition: the move landed")
                    #expect(movedId != "m", "precondition: Graph gave the moved message a new id")

                    let readStartedAt: Date
                    if flagQueuedBeforeRead {
                        // The flag's request is answered only after the read began,
                        // so the action is queued before it and completes after it.
                        w.server.holdPatch(providerMessageId: movedId, forSeconds: 0.5)
                        await AccountManager.shared.markFlagged([try #require(try w.row(movedId, in: w.archive))], flagged: true)
                        readStartedAt = wall.withLock { $0 = $0.addingTimeInterval(1); return $0 }
                        wall.withLock { $0 = $0.addingTimeInterval(1) }
                        try await Self.drainQueue(w)
                    } else {
                        readStartedAt = wall.withLock { $0 }
                        wall.withLock { $0 = $0.addingTimeInterval(1) }
                        await AccountManager.shared.markFlagged([try #require(try w.row(movedId, in: w.archive))], flagged: true)
                        try await Self.drainQueue(w)
                    }
                    #expect(w.server.snapshot(providerMessageId: movedId)?.isFlagged == true, "precondition: the flag landed")
                    // The shared 30 s protection runs out.
                    await AccountManager.shared.clearRecentlyCompletedForTesting()
                    wall.withLock { $0 = $0.addingTimeInterval(SyncConfig.recentlyCompletedTTLSeconds + 1) }

                    var stale = CatchUpFolderResult(folderId: w.folderId(w.archive), epoch: nil)
                    stale.flagUpdates = [CatchUpFlagUpdate(messageId: movedId, isRead: false, isFlagged: false)]
                    stale.newState = try w.folder(w.archive).catchUpState
                    _ = await engine.applyCatchUpResult(stale, windowMode: .date, readStartedAt: readStartedAt)

                    #expect(try w.row(movedId, in: w.archive)?.isFlagged == true, "a read that began before the flag overwrote it")
                }
            } catch {
                await AccountManager.shared.unregisterProviderForTesting(accountId: w.accountId)
                throw error
            }
            await AccountManager.shared.unregisterProviderForTesting(accountId: w.accountId)
        }
    }

    /// Drains the action queue until it is empty and no drain is in flight.
    static func drainQueue(_ w: R.World) async throws {
        for _ in 0..<300 {
            let isEmpty = try await w.pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent { await AccountManager.shared.drainPendingQueue() }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the action queue did not drain")
    }

    /// 29: slow reads never stall a listing. The wall clock moves on by `jump`
    /// with every listing page, so every slice's read spans more than the 30 s
    /// protection (29a) or the completion log's retention (29b), and the user's
    /// flag completes during the first page's read. The listing still completes
    /// within a slice ceiling, its removal and load land, and the user's flag
    /// stays. With reads under the retention (29a) the stale flags heal; past it
    /// (29b) no flag update applies, so they wait for the next listing.
    @Test("29: with every page's read slower than the protection (31 s) or the retention (3,601 s), the listing completes and keeps the user's flag",
          arguments: [31.0, 3_601.0])
    func slowReadsStillComplete(jump: TimeInterval) async throws {
        let c = Clock()
        let overAge = jump >= SyncConfig.catchUpCompletionLogRetentionSeconds
        try await Self.withWorld(seeds: [
            Self.seed("u", in: Self.archive, at: c.daysAgo(2)),
            Self.seed("s-1", in: Self.archive, at: c.daysAgo(3), isRead: true),
            Self.seed("s-2", in: Self.archive, at: c.daysAgo(4), isFlagged: true),
            Self.seed("k-1", in: Self.archive, at: c.daysAgo(6)),
            Self.seed("old", in: Self.archive, at: c.daysAgo(400)),
        ]) { w, engine in
            for (id, days) in [("u", 2.0), ("s-1", 3), ("s-2", 4), ("gone", 5), ("k-1", 6)] {
                try w.insertRow(id, in: w.archive, date: c.daysAgo(days))
            }
            try await w.baselineAll()
            // Stale on the phone, as a lost change leaves them.
            try Self.setLocal(w, "s-1", in: w.archive, isRead: false)
            try Self.setLocal(w, "s-2", in: w.archive, isFlagged: false)
            w.server.setCatchUpListingPageCap(2)
            let wall = OSAllocatedUnfairLock(initialState: Date())
            let key = MessageIdentity.headerId(accountId: w.accountId, folderPath: w.archive, messageId: "u")
            let (pool, server, accountId) = (w.pool, w.server, w.accountId)
            server.afterCatchUpListingPage { serial in
                if serial == 1 {
                    try? pool.write { db in try db.execute(sql: "UPDATE messageHeader SET isFlagged = 1 WHERE id = ?", arguments: [key]) }
                    server.setFlagFromOtherClient(providerMessageId: "u", isFlagged: true)
                    AccountManager.shared.recordActionCompleted(accountId: accountId, messageKeys: ["u"])
                }
                wall.withLock { $0 = $0.addingTimeInterval(jump) }
            }

            let ceiling = 12
            var slices = 0
            try await Self.withWallClock(wall) {
                while try Self.state(w, w.archive)?.lastCompletedAt == nil, slices < ceiling {
                    await Self.pass(w, engine, [w.archive], context: Self.requests(SyncConfig.catchUpSliceMaxRequests))
                    slices += 1
                }
            }

            #expect(try Self.state(w, w.archive)?.lastCompletedAt != nil, "the listing did not complete within \(ceiling) slices")
            #expect(try w.row("gone", in: w.archive) == nil, "the removal did not land")
            #expect(try w.row("old", in: w.archive) != nil, "the load did not land")
            #expect(try w.row("u", in: w.archive)?.isFlagged == true, "a slow read overwrote the user's flag")
            #expect(try w.row("s-1", in: w.archive)?.isRead == !overAge)
            #expect(try w.row("s-2", in: w.archive)?.isFlagged == !overAge)
        }
    }
}
