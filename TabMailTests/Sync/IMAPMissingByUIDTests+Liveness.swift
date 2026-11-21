/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os
import GRDB
import Testing
@testable import TabMail

/// Bounds of the catch-up (#1062): the storage-limit load floor after the walk
/// started, an owed folder holding a message that never loads, and an owed
/// mark made on a floor-only state. Same world as `IMAPMissingByUIDTests`.
extension IMAPMissingByUIDTests {

    @Test("Under a storage limit after the walk started, rows infinite scroll cached far below the walk's cursor never pull the load floor down: nothing below the cursor is loaded")
    @MainActor
    func storageLimitFloorAfterTheWalkStartedIgnoresScrolledRows() async throws {
        let server = Array(1...200)
        let cursor = 150
        let scrolled = Array(1...5)
        let walkHeld = Array((cursor + 1)...200)
        try await Self.withWorld("floor-limit-walk", server: server, local: scrolled + walkHeld,
                                 olderMailCursor: cursor) { w in
            try await w.markOwed()
            let start = w.server.recordedCommands().count
            var run = SyncEngine.CatchUpRun(
                storageLimitInForce: true, deadline: Date().addingTimeInterval(60),
                sliceSeconds: SyncConfig.catchUpSliceSeconds, intervalSeconds: SyncConfig.catchUpSliceIntervalSeconds,
                clock: { Date() })
            run.listingRangeMessages = w.rangeMessages
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            _ = await w.engine.runCatchUpRun(account: try w.account(), run: run)
            let headerFetches = w.server.recordedCommands().dropFirst(start).filter {
                $0.uppercased().contains("FETCH") && $0.uppercased().contains("ENVELOPE")
            }
            let below = Array((scrolled.count + 1)...cursor)
            let loaded = below.filter { uid in headerFetches.contains { Self.uidSet($0).contains(uid) } }
            #expect(loaded.isEmpty, "#1062: nothing below the walk's cursor is loaded under a limit: \(loaded.prefix(20))")
            try w.expectHeldExactly(scrolled + walkHeld, "#1062 limit after the walk started")
        }
    }

    /// How many permanently undecodable records the owed folder holds.
    static let undecodableCounts = [1, 2, 3]

    @Test("An owed folder holding permanently undecodable records beside other missing mail: all the other mail loads, the mark never settles, and the folder is relisted at most once a day",
          arguments: undecodableCounts)
    @MainActor
    func undecodableRecordsKeepTheMarkAndRelistDaily(_ count: Int) async throws {
        let broken = Array([12, 15, 18].prefix(count))
        let otherMissing = [11, 13, 14, 16, 17, 19, 1005]
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-undecodable-\(count)", server: server, local: server) { w in
            var messages = server.map(Self.message)
            for uid in broken { messages[uid - 1] = Self.message(uid, date: "not a date") }
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: Set(broken))
            try await w.dropLocal(broken + otherMissing)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            #expect(try w.catchUpState()?.listing == nil, "setup: the listing completed after the hold bound")
            let held = Set(try w.held())
            #expect(Set(otherMissing).isSubset(of: held), "#1062: every other missing message loads: \(Set(otherMissing).subtracting(held).sorted())")
            #expect(held.isDisjoint(with: broken), "setup: the undecodable records never load")
            #expect((try w.changeState()).selfHealDue, "#1062: an unclean completion never settles the mark")

            // Within the day nothing lists the folder again; the next listing
            // comes only at the daily check, and it still does not settle.
            for _ in 0..<3 {
                clock.advance(by: Self.pastTheHold)
                let start = w.server.recordedCommands().count
                await w.slice(clock: clock)
                let ranges = Self.listingRanges(w.server.recordedCommands().dropFirst(start))
                #expect(ranges.isEmpty, "#1062: no relisting within the day: \(ranges)")
            }
            clock.advance(by: Self.pastTheNextCheck)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            #expect(!Self.listingRanges(w.server.recordedCommands().dropFirst(start)).isEmpty, "#1062: the daily check lists it again")
            #expect((try w.changeState()).selfHealDue, "#1062: \(count) unloadable record(s) never settle the mark")
        }
    }

    /// The folder's stored HIGHESTMODSEQ as a foreground sync's listing stores it
    /// (`writeListingCounters`): a catch-up listing takes its stamp from this field.
    @MainActor
    static func storeServerModSeq(_ w: World) async throws {
        let folderId = w.folderId, modSeq = w.server.qresyncHighestModSeq(for: Self.path)
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET lastKnownHighestModSeq = ? WHERE id = ?", arguments: [modSeq, folderId])
        }
    }

    @Test("On a server without CONDSTORE an owed folder is listed once, settles on a clean finish, and is not listed again on the next run")
    @MainActor
    func owedFolderWithoutCondstoreSettlesOnce() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-no-condstore", capabilities: FakeIMAPServer.defaultCapabilities, server: server, local: server) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            #expect(try w.catchUpState()?.listing == nil && (try w.held()).contains(12), "setup: one clean listing loaded the missing message")
            #expect(!(try w.changeState()).selfHealDue, "#1062: a clean finish settles the mark without CONDSTORE")
            for _ in 0..<3 {
                clock.advance(by: Self.pastTheHold)
                let start = w.server.recordedCommands().count
                await w.slice(clock: clock)
                let ranges = Self.listingRanges(w.server.recordedCommands().dropFirst(start))
                #expect(ranges.isEmpty, "#1062: no relisting on the next run without CONDSTORE: \(ranges)")
            }
        }
    }

    @Test("An owed listing whose loads the apply skips as an over-age read completes unclean: the mark stays")
    @MainActor
    func overAgeSkippedLoadsDoNotSettle() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-over-age", server: server, local: server) { w in
            try await w.dropLocal([12])
            try await Self.storeServerModSeq(w)
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing?.clean == true && result.loaded.contains { $0.id == "12" },
                    "setup: a clean completed listing that loaded the missing message")
            let overAge = CatchUpWallClock.now().addingTimeInterval(-SyncConfig.catchUpCompletionLogRetentionSeconds - 60)
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: overAge, selfHealOwedAtRead: read.owedAtRead)
            #expect(!(try w.held()).contains(12), "setup: the over-age read's load was skipped")
            #expect((try w.changeState()).selfHealDue, "#1062: a listing whose loads were skipped does not settle the mark")
            let state = try #require(try w.catchUpState(), "#1062: the stored catch-up state still decodes")
            #expect(state.listing == nil && state.completionStamp != nil, "#1062: the completion is kept, not replaced")
            let clock = CatchUpTestClock()
            clock.advance(by: Self.pastTheHold)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            #expect(Self.listingRanges(w.server.recordedCommands().dropFirst(start)).isEmpty,
                    "#1062: no relisting from scratch before the daily check")
        }
    }

    @Test("An owed listing slice applied over-age with no loads does not make the listing unclean: the mark settles")
    @MainActor
    func overAgeSliceWithoutLoadsKeepsTheListingClean() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-over-age-no-loads", server: server, local: server) { w in
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, maxRequests: 3, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing == nil && result.loaded.isEmpty, "setup: a slice with no loads that does not complete")
            let overAge = CatchUpWallClock.now().addingTimeInterval(-SyncConfig.catchUpCompletionLogRetentionSeconds - 60)
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: overAge, selfHealOwedAtRead: read.owedAtRead)
            #expect(try w.catchUpState()?.skippedLoads == nil, "#1062: nothing was dropped, nothing is marked")
            let clock = CatchUpTestClock()
            for _ in 0..<10 where try w.catchUpState()?.listing != nil { await w.slice(clock: clock) }
            #expect(try w.catchUpState()?.listing == nil, "setup: a later slice completed the listing")
            #expect(!(try w.changeState()).selfHealDue, "#1062: an over-age slice without loads does not keep the mark")
        }
    }

    @Test("The over-age latch flips during the insert: the loads still to come are dropped and the listing is unclean")
    @MainActor
    func overAgeLatchFlipsMidInsert() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-latch-mid-insert", server: server, local: server) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing?.clean == true && result.loaded.contains { $0.id == "12" },
                    "setup: a clean completed listing that loaded the missing message")
            // The first check (before the insert) is in time; every later one,
            // starting with the insert chunk's, is past the retention.
            let readStartedAt = Date()
            let checks = OSAllocatedUnfairLock(initialState: 0)
            CatchUpWallClock.nowForTesting.withLock { $0 = {
                let n = checks.withLock { $0 += 1; return $0 }
                return n == 1 ? readStartedAt.addingTimeInterval(10)
                    : readStartedAt.addingTimeInterval(SyncConfig.catchUpCompletionLogRetentionSeconds + 60)
            } }
            defer { CatchUpWallClock.nowForTesting.withLock { $0 = nil } }
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            #expect(!(try w.held()).contains(12), "#1062: the latch set in the insert chunk drops the load")
            #expect((try w.changeState()).selfHealDue, "#1062: the dropped load makes the listing unclean")
        }
    }

    /// Runs `body` with a wall clock that is in time (10 s after `readStartedAt`)
    /// for the first `inTimeChecks` reads and past the retention for every later one.
    @MainActor
    static func withScriptedOverAge(readStartedAt: Date, inTimeChecks: Int, _ body: () async throws -> Void) async rethrows {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        CatchUpWallClock.nowForTesting.withLock { $0 = {
            let n = reads.withLock { $0 += 1; return $0 }
            return n <= inTimeChecks ? readStartedAt.addingTimeInterval(10)
                : readStartedAt.addingTimeInterval(SyncConfig.catchUpCompletionLogRetentionSeconds + 60)
        } }
        defer { CatchUpWallClock.nowForTesting.withLock { $0 = nil } }
        try await body()
    }

    @Test("The latch sets only in the transaction: the load lands, the flag update is withheld, the listing is clean")
    @MainActor
    func overAgeLatchFlipsOnlyInTheTransaction() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-latch-txn", server: server, local: server) { w in
            w.server.setFlags(["\\Seen"], in: Self.path, uid: 3)
            try await w.dropLocal([12])
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing?.clean == true && result.loaded.contains { $0.id == "12" }
                    && result.flagUpdates.contains { $0.messageId == "3" }, "setup: a clean completion with a load and a flag update")
            let readStartedAt = Date()
            // Checks: before the insert, the one insert chunk, then the transaction.
            await Self.withScriptedOverAge(readStartedAt: readStartedAt, inTimeChecks: 2) {
                _ = await w.engine.applyCatchUpResult(
                    result, windowMode: .uid, readStartedAt: readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            }
            let folderId = w.folderId
            let isRead = try await w.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = '3'", arguments: [folderId])
            }
            #expect((try w.held()).contains(12), "#1062: the load landed before the latch set")
            #expect(isRead == false, "#1062: the transaction's own check withholds the over-age flag update")
            #expect(!(try w.changeState()).selfHealDue, "#1062: no load was dropped, so the listing is clean and settles")
        }
    }

    @Test("The latch sets between insert chunks: the first chunk lands, later ones are dropped, the listing is unclean")
    @MainActor
    func overAgeLatchFlipsBetweenChunks() async throws {
        let server = Array(1...260)
        let missing = Array(101...(100 + SyncConfig.backfillInsertChunkSize + 30))
        try await Self.withWorld("owed-latch-chunks", server: server, local: server) { w in
            try await w.dropLocal(missing)
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing != nil && result.loaded.count > SyncConfig.backfillInsertChunkSize,
                    "setup: one completing result with more loads than one insert chunk")
            let readStartedAt = Date()
            // Checks: before the insert and the first chunk in time; the second chunk on, over-age.
            await Self.withScriptedOverAge(readStartedAt: readStartedAt, inTimeChecks: 2) {
                _ = await w.engine.applyCatchUpResult(
                    result, windowMode: .uid, readStartedAt: readStartedAt, selfHealOwedAtRead: read.owedAtRead)
            }
            let landed = Set(try w.held()).intersection(missing)
            #expect(landed.count == SyncConfig.backfillInsertChunkSize, "#1062: exactly the first chunk landed (\(landed.count))")
            #expect((try w.changeState()).selfHealDue, "#1062: the dropped later chunk makes the listing unclean")
        }
    }

    @Test("An owed folder whose listing completed unclean is listed again once its change counter moves past the stamp")
    @MainActor
    func uncleanOwedFolderRelistsWhenTheCounterMoves() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-unclean-counter", server: server, local: server) { w in
            var messages = server.map(Self.message)
            messages[11] = Self.message(12, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [12])
            try await w.dropLocal([12])
            try await Self.storeServerModSeq(w)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            let stamp = try #require(try w.catchUpState()?.completionStamp, "setup: the unclean listing recorded its stamp")
            #expect((try w.changeState()).selfHealDue, "setup: still owed")
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownHighestModSeq = ? WHERE id = ?", arguments: [stamp + 1, folderId])
            }
            clock.advance(by: Self.pastTheHold)
            let start = w.server.recordedCommands().count
            await w.slice(clock: clock)
            #expect(!Self.listingRanges(w.server.recordedCommands().dropFirst(start)).isEmpty,
                    "#1062: a moved change counter relists an owed folder before the daily check")
        }
    }

    @Test("A multi-slice owed listing: an earlier slice applied over-age, a later slice in time; the mark stays and the message loads at the daily check")
    @MainActor
    func overAgeEarlierSliceKeepsTheListingUnclean() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-over-age-slice", server: server, local: server) { w in
            try await w.dropLocal([12])
            try await w.markOwed()
            let read = try await w.read(CatchUpContext(deadline: .distantFuture, clock: { Date() },
                                                       maxRequests: Self.newListingStartRequests + 3, listingRangeMessages: w.rangeMessages))
            let result = try #require(read.results.first)
            #expect(result.completedListing == nil && result.loaded.contains { $0.id == "12" },
                    "setup: a slice that loads the missing message and does not complete the listing")
            let overAge = CatchUpWallClock.now().addingTimeInterval(-SyncConfig.catchUpCompletionLogRetentionSeconds - 60)
            _ = await w.engine.applyCatchUpResult(
                result, windowMode: .uid, readStartedAt: overAge, selfHealOwedAtRead: read.owedAtRead)
            #expect(!(try w.held()).contains(12), "setup: the over-age apply skipped the load")
            #expect(try w.catchUpState()?.skippedLoads == true, "#1062: the dropped load is recorded on the listing in progress")
            let clock = CatchUpTestClock()
            for _ in 0..<10 where try w.catchUpState()?.listing != nil { await w.slice(clock: clock) }
            #expect(try w.catchUpState()?.listing == nil, "setup: a later in-time slice completed the listing")
            #expect((try w.changeState()).selfHealDue, "#1062: skipped loads in an earlier slice keep the listing unclean")
            #expect(try w.catchUpState()?.skippedLoads == nil, "#1062: completion clears the record for the next listing")
            clock.advance(by: Self.pastTheNextCheck)
            for _ in 0..<10 {
                let loaded = try w.held().contains(12)
                let listing = try w.catchUpState()?.listing
                if loaded && listing == nil { break }
                await w.slice(clock: clock)
            }
            #expect((try w.held()).contains(12), "#1062: the daily check lists and loads the message")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the next clean listing settles the mark")
        }
    }

    @Test("An unclean owed listing that started before the mark completes: the mark stays and the lapse is not marked again")
    @MainActor
    func uncleanListingStartedBeforeTheMarkKeepsTheMark() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-unclean-before-mark", server: server, local: server) { w in
            var messages = server.map(Self.message)
            messages[14] = Self.message(15, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [15])
            try await w.dropLocal([15])
            let folderId = w.folderId
            try await w.pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
            let clock = CatchUpTestClock()
            await w.slice(maxRequests: 1, clock: clock)
            #expect(try w.catchUpState()?.listing != nil, "setup: a listing is in progress")
            try await w.markOwed()
            let lapseAtMark = try w.catchUpState()?.lapseCount
            #expect((try w.catchUpState()?.listing?.lapseCountAtStart ?? 0) < (lapseAtMark ?? 0), "setup: the listing started before the mark")
            await w.slice(clock: clock)
            clock.advance(by: Self.pastTheHold)
            for _ in 0..<5 where try w.catchUpState()?.listing != nil { await w.slice(clock: clock) }
            #expect(try w.catchUpState()?.listing == nil, "setup: the listing completed after the hold bound")
            #expect((try w.changeState()).selfHealDue, "#1062: an unclean completion keeps the mark")
            #expect(try w.catchUpState()?.lapseCount == lapseAtMark, "#1062: an unclean completion marks the lapse nothing more")
        }
    }

    @Test("An owed folder whose listing completed unclean, with no server changes, is not listed again before the daily check")
    @MainActor
    func uncleanOwedFolderWaitsForTheDailyCheck() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-unclean-modseq", server: server, local: server) { w in
            var messages = server.map(Self.message)
            messages[11] = Self.message(12, date: "not a date")
            w.server.setMessages(messages, in: Self.path)
            w.server.suppressFetchInternalDate(in: Self.path, uids: [12])
            try await w.dropLocal([12])
            try await Self.storeServerModSeq(w)
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            clock.advance(by: Self.pastTheHold)
            await w.slice(clock: clock)
            #expect(try w.catchUpState()?.listing == nil, "setup: the listing completed unclean")
            #expect(try w.catchUpState()?.completionStamp != nil, "#1062: an unclean completion still records its change-counter stamp")
            var relistings = 0
            for _ in 0..<5 {
                clock.advance(by: Self.pastTheHold)
                let start = w.server.recordedCommands().count
                await w.slice(clock: clock)
                if !Self.listingRanges(w.server.recordedCommands().dropFirst(start)).isEmpty { relistings += 1 }
            }
            #expect(relistings == 0, "#1062: with the change counter unmoved, no relisting before the daily check (\(relistings))")
            #expect((try w.changeState()).selfHealDue, "#1062: still owed")
        }
    }

    @Test("An owed mark made on a floor-only state (the window merge wrote only the floor) is settled by the first listing that starts after it")
    @MainActor
    func floorOnlyStateMarkSettlesInOneListing() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-floor-only", server: server, local: server) { w in
            let folderId = w.folderId
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = NULL WHERE id = ?", arguments: [folderId])
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, epoch: Self.epoch, db: db)
            }
            #expect(IMAPCatchUpState.decode(try w.folder().catchUpState) == nil, "setup: the state is floor-only")
            try await w.markOwed()
            let clock = CatchUpTestClock()
            await w.slice(clock: clock)
            #expect(try w.catchUpState()?.listing == nil, "setup: one listing completed")
            #expect(!(try w.changeState()).selfHealDue, "#1062: the first listing after the mark settles it")
        }
    }

    @Test("An account added while the full wipe waits for the turns: the wipe takes that account's turn too before it wipes")
    @MainActor
    func wipeTakesTheTurnOfAnAccountAddedWhileItWaits() async throws {
        let server = Array(1...20)
        try await Self.withWorld("wipe-added-account", server: server, local: server) { w in
            let engine = w.engine, accountId = w.accountId
            let gate = SyncTurnsForResetTests.Gate(), addedGate = SyncTurnsForResetTests.Gate()
            let held = SyncTurnsForResetTests.Flag()
            let busy = Task.detached { await engine.oneSyncAtATime(accountId: accountId) { await held.set(); await gate.wait() } }
            #expect(try await SyncTurnsForResetTests.waitFor(held), "setup: the account's turn is held")
            let wipe = Task { try await engine.wipeLocalIndex() }
            #expect(try await SyncTurnsForResetTests.waitForWaiters(engine, accountId, count: 1), "setup: the wipe waits")
            // A second account appears, its own pass holding its turn.
            let added = "\(accountId)-added"
            _ = try FolderEpochTestFixture.makeAccount(id: added, provider: .imap, pool: w.pool)
            try FolderEpochTestFixture.insertFolder(accountId: added, path: Self.path, role: .archive, pool: w.pool)
            try FolderEpochTestFixture.insertHeaders(accountId: added, path: Self.path, uids: server, pool: w.pool)
            let addedHeld = SyncTurnsForResetTests.Flag()
            let addedPass = Task.detached { await engine.oneSyncAtATime(accountId: added) { await addedHeld.set(); await addedGate.wait() } }
            #expect(try await SyncTurnsForResetTests.waitFor(addedHeld), "setup: the added account's turn is held")
            await gate.release()
            let queuedOnAdded = try await SyncTurnsForResetTests.waitForWaiters(engine, added, count: 1)
            let addedRows = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE accountId = ?", arguments: [added]) ?? 0
            }
            await addedGate.release()
            await busy.value
            await addedPass.value
            try await wipe.value
            #expect(queuedOnAdded, "#1062: the wipe waits for the added account's turn")
            #expect(addedRows == server.count, "#1062: the added account is not wiped while its pass holds the turn")
        }
    }
}
