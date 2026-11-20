/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
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

    @Test("An owed listing whose loads the apply skips as an over-age read completes unclean: the mark stays")
    @MainActor
    func overAgeSkippedLoadsDoNotSettle() async throws {
        let server = Array(1...20) + Array(1001...1060)
        try await Self.withWorld("owed-over-age", server: server, local: server) { w in
            try await w.dropLocal([12])
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
                try SyncEngine.recordCatchUpWindowFloor(folderId: folderId, lowest: 1, db: db)
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
            let busy = Task { await engine.oneSyncAtATime(accountId: accountId) { await held.set(); await gate.wait() } }
            #expect(try await SyncTurnsForResetTests.waitFor(held), "setup: the account's turn is held")
            let wipe = Task { try await engine.wipeLocalIndex() }
            #expect(try await SyncTurnsForResetTests.waitForWaiters(engine, accountId, count: 1), "setup: the wipe waits")
            // A second account appears, its own pass holding its turn.
            let added = "\(accountId)-added"
            _ = try FolderEpochTestFixture.makeAccount(id: added, provider: .imap, pool: w.pool)
            try FolderEpochTestFixture.insertFolder(accountId: added, path: Self.path, role: .archive, pool: w.pool)
            try FolderEpochTestFixture.insertHeaders(accountId: added, path: Self.path, uids: server, pool: w.pool)
            let addedHeld = SyncTurnsForResetTests.Flag()
            let addedPass = Task { await engine.oneSyncAtATime(accountId: added) { await addedHeld.set(); await addedGate.wait() } }
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
