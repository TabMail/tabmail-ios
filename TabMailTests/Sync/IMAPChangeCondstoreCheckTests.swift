/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import Testing
@testable import TabMail

/// The CONDSTORE removal check (#755): owed = M0 + |A| - M1 decides whether a
/// check runs; a candidate is removed only after a FETCH and a confirming SEARCH
/// both leave it out; a check that does not fit the budget is cut, lists the
/// folder the same pass, and resumes on later passes, committing the bookmark of
/// the pass that started it; the catch-up is armed once per check.
@Suite("IMAP CONDSTORE removal check", .serialized, .processGlobalState)
struct IMAPChangeCondstoreCheckTests {
    typealias R = IMAPChangeReaderTests
    typealias C = IMAPChangeCondstoreTests

    /// A deadline that leaves room for a proof pair but not for a chunk SEARCH
    /// plus its proof, so the priced check never fits.
    static var tightContext: ChangeContext {
        ChangeContext(
            deadline: Date().addingTimeInterval(SyncConfig.changeReadRequestTimeoutSeconds * 2 + 1),
            onProgress: { _ in })
    }

    static func cursor(_ raw: String?) throws -> IMAPChangeCursor { try #require(IMAPChangeCursor.decode(raw)) }

    @Test("T4: a chunk SEARCH that leaves out a live held message while a removal is owed never removes it; the gone one is removed")
    func searchOmissionNeverRemovesALiveRow() async throws {
        try await C.withWorld(inbox: [1, 2, 3, 4]) { w in
            let base = try await R.baseline(w)
            C.remove([1], from: w.server)
            w.server.setSearchOmits([3], in: R.inboxPath)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base]))
            #expect(R.isTracked(changes.status), "got \(changes.status)")
            #expect(changes.removals == ["1"], "only the message the server lost: \(changes.removals)")
            #expect(changes.records.contains { $0.messageId == "3" }, "the omitted live message is read again in full")
        }
    }

    @Test("T5: a failed or unlisted chunk SEARCH keeps every row and the bookmark, with the failure time set")
    func failedChunkSearchKeepsEverything() async throws {
        for fault in ["refused", "unlisted"] {
            try await C.withWorld(inbox: [1, 2, 3]) { w in
                let base = try await R.baseline(w)
                C.remove([2], from: w.server)
                if fault == "refused" {
                    w.server.failNextCommand(containing: "UID SEARCH")
                } else {
                    w.server.answerNextUIDSearch(in: R.inboxPath, esearchData: "COUNT 3")
                }
                let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base]))
                guard case .failed = changes.status else { Issue.record("\(fault): expected failed, got \(changes.status)"); return }
                #expect(changes.removals.isEmpty, "\(fault): nothing removed")
                let kept = try Self.cursor(changes.cursor)
                let stored = try Self.cursor(base)
                #expect(kept.failingSince != nil && kept.uidNext == stored.uidNext && kept.highestModSeq == stored.highestModSeq)
            }
        }
    }

    @Test("T6: an expunge that leaves HIGHESTMODSEQ unchanged is read (no fast path) and the row removed; T9: nothing changed reads STATUS only")
    func expungeWithoutModSeqAndQuietFolder() async throws {
        try await C.withWorld(inbox: [1, 2, 3]) { w in
            let base = try await R.baseline(w)
            let start = w.server.recordedCommands().count
            let quiet = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base]))
            #expect(R.isTracked(quiet.status))
            // The property: a quiet folder costs no message read and changes nothing. A SELECT
            // may still appear (re-selecting an already selected mailbox, RFC 3501 6.3.10).
            let reads = w.server.recordedCommands().dropFirst(start).filter {
                let u = $0.uppercased(); return u.contains("FETCH") || u.contains("SEARCH")
            }
            #expect(reads.isEmpty, "an unchanged folder reads no messages: \(Array(reads))")
            #expect(quiet.removals.isEmpty)
            C.remove([2], from: w.server)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base]))
            #expect(changes.removals == ["2"])
        }
    }

    @Test("T7: a deletion below the window advances the bookmark and arms the catch-up for the older rows")
    func deletionBelowTheWindowArmsTheCatchUp() async throws {
        try await C.withWorld(inbox: Array(1...10)) { w in
            await w.provider.setRemovalCheckWindowForTesting(3)
            let base = try await R.baseline(w)
            C.remove([2], from: w.server)
            let changes = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base]))
            #expect(R.isTracked(changes.status), "got \(changes.status)")
            #expect(changes.removals.isEmpty, "UID 2 is below the window: the catch-up's to find")
            #expect(changes.armCatchUpWithBookmark, "the older rows get the catch-up's check")
            let next = try Self.cursor(changes.cursor)
            #expect(next.messageCount == 9 && next.pendingCheck == nil)
        }
    }

    @Test("T12: cut three times, then resumed: the catch-up is armed on the first cut only, the deletion is applied, and the committed bookmark is the first cut's")
    func repeatedCutsArmOnceAndResume() async throws {
        try await C.withWorld(inbox: [1, 2, 3, 4]) { w in
            let base = try await R.baseline(w)
            C.remove([2], from: w.server)
            var stored = base
            var arms = 0
            var firstPending: IMAPRemovalCheckProgress.Bookmark?
            for pass in 1...3 {
                if pass == 2 { C.add([5], to: w.server) }
                let cut = try await R.inbox(w, R.read(w, cursors: [w.inboxId: stored], context: Self.tightContext))
                guard case .untracked(let observation) = cut.status else { Issue.record("pass \(pass): expected the cut, got \(cut.status)"); return }
                #expect(observation.mustList, "pass \(pass): the folder is listed the same pass")
                #expect(!cut.removals.contains { $0 != "2" })
                let carried = try Self.cursor(cut.cursor)
                let startNext = try Self.cursor(base).uidNext
                #expect(carried.uidNext == startNext, "pass \(pass): the reading position stays")
                firstPending = firstPending ?? carried.pendingCheck?.pending
                if cut.armCatchUpWithBookmark && cut.cursor != stored { arms += 1 }
                stored = cut.cursor ?? stored
            }
            #expect(arms == 1, "armed once per check, got \(arms)")
            C.add([6], to: w.server)
            let done = try await R.inbox(w, R.read(w, cursors: [w.inboxId: stored]))
            #expect(R.isTracked(done.status), "got \(done.status)")
            #expect(done.removals.contains("2"), "the deletion is applied")
            #expect(!done.armCatchUpWithBookmark)
            let committed = try Self.cursor(done.cursor)
            #expect(committed.uidNext == firstPending?.uidNext, "the starting pass's bookmark, never the current one")
            #expect(committed.pendingCheck == nil)
        }
    }

    /// A budget spent by the fake server's work, not by wall time: each
    /// `UID SEARCH` the pass sends costs one request timeout. `seconds` is the
    /// pass's whole budget, so the check's own step gates decide how far it gets.
    static func searchBudget(_ w: R.World, seconds: TimeInterval) -> ChangeContext {
        let start = Date()
        let server = w.server
        let before = Self.searchesSent(server)
        return ChangeContext(
            deadline: start.addingTimeInterval(seconds),
            clock: { start.addingTimeInterval(Double(Self.searchesSent(server) - before) * SyncConfig.changeReadRequestTimeoutSeconds) },
            onProgress: { _ in })
    }

    static func searchesSent(_ server: FakeIMAPServer) -> Int {
        server.recordedCommands().filter { $0.uppercased().contains("UID SEARCH") }.count
    }

    /// A pass whose budget pays for one window chunk and its proof only.
    static let oneChunkBudgetSeconds = SyncConfig.changeReadRequestTimeoutSeconds * 4
    /// Most passes either test lets the check take before it counts as stuck.
    static let passCap = 8

    @Test("T1a: a check over several window chunks makes progress on every cut pass, resumes where it stopped, and finishes with every removal proven")
    func finiteBudgetCheckResumesAcrossPasses() async throws {
        let held = Array(1...1_500)
        try await C.withWorld(inbox: held) { w in
            let base = try await R.baseline(w)
            let gone: Set<Int> = [100, 900, 1_400]
            C.remove(gone, from: w.server)
            var stored: String? = base
            var removed = Set<String>()
            var lastPosition: (nextBelow: UInt32, remaining: Int)?
            var cuts = 0
            var finished = false
            for _ in 0..<Self.passCap {
                let pass = try await R.inbox(w, R.read(w, cursors: [w.inboxId: stored], context: Self.searchBudget(w, seconds: Self.oneChunkBudgetSeconds)))
                removed.formUnion(pass.removals)
                if R.isTracked(pass.status) { finished = true; break }
                guard case .untracked = pass.status else { Issue.record("expected a cut, got \(pass.status)"); return }
                cuts += 1
                let progress = try #require(try Self.cursor(pass.cursor).pendingCheck, "a cut carries the check's progress")
                if let last = lastPosition {
                    #expect(progress.nextBelow < last.nextBelow || progress.remaining < last.remaining,
                            "cut \(cuts) made no progress: \(progress.nextBelow)/\(progress.remaining)")
                }
                lastPosition = (progress.nextBelow, progress.remaining)
                stored = pass.cursor
            }
            #expect(finished, "the check finished within \(Self.passCap) passes")
            #expect(cuts >= 2, "the budget cut the check more than once: \(cuts)")
            #expect(removed == Set(gone.map(String.init)), "every removal proven, nothing else: \(removed.sorted())")
        }
    }

    @Test("T1b: after a bulk expunge of over a thousand messages the check finishes within the production budget, the folder is tracked again, and a later flag change on an older message arrives")
    func bulkExpungeReturnsToTracking() async throws {
        let held = Array(1...1_500)
        try await C.withWorld(inbox: held) { w in
            let base = try await R.baseline(w)
            C.remove(Set(1...1_001), from: w.server)
            let productionBudget = SyncConfig.changeReadRequestTimeoutSeconds * 6 + 2
            var stored: String? = base
            var tracked = false
            for _ in 0..<Self.passCap {
                let pass = try await R.inbox(w, R.read(w, cursors: [w.inboxId: stored], context: Self.searchBudget(w, seconds: productionBudget)))
                stored = pass.cursor ?? stored
                if R.isTracked(pass.status) { tracked = true; break }
            }
            #expect(tracked, "the folder is tracked again after the check finishes")
            guard tracked else { return }
            w.server.setFlags(["\\Seen"], in: R.inboxPath, uid: 1_200)
            let later = try await R.inbox(w, R.read(w, cursors: [w.inboxId: stored], context: Self.searchBudget(w, seconds: productionBudget)))
            #expect(R.isTracked(later.status), "got \(later.status)")
            #expect(later.records.contains { $0.messageId == "1200" }, "the older message's flag change arrives")
        }
    }

    @Test("T12 through the apply: three cuts mark exactly one catch-up lapse, and the armed catch-up listing completes and removes the deleted message")
    func repeatedCutsLapseOnceAndTheCatchUpCompletes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: "acct-751", provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: "acct-751", path: R.inboxPath, role: .inbox, pool: pool,
            totalCount: 4, lastKnownUidNext: 5, lastKnownUidValidity: R.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: "acct-751", path: R.inboxPath, uids: [1, 2, 3, 4], pool: pool)
        let folderId = "acct-751:\(R.inboxPath)"
        func stored(_ column: String) async throws -> String? {
            try await pool.read { db in try String.fetchOne(db, sql: "SELECT \(column) FROM folder WHERE id = ?", arguments: [folderId]) }
        }
        func lapses() async throws -> Int { IMAPCatchUpState.decode(try await stored("catchUpState"))?.lapseCount ?? 0 }
        try await C.withWorld(inbox: [1, 2, 3, 4]) { w in
            let base = try await R.baseline(w)
            let completed = IMAPCatchUpState(
                epoch: UInt32(R.epoch), completionStamp: nil, lastCompletedAt: Date().addingTimeInterval(-60), listing: nil, createdAt: nil)
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ?, catchUpState = ? WHERE id = ?",
                               arguments: [base, completed.encoded(), folderId])
            }
            C.remove([2], from: w.server)
            for pass in 1...3 {
                if pass == 2 { C.add([5], to: w.server) }
                let cursor = try await stored("changeCursor")
                let cut = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor], context: Self.tightContext))
                guard case .untracked = cut.status else { Issue.record("pass \(pass): expected the cut, got \(cut.status)"); return }
                _ = try await pool.write { db in try SyncEngine.applyFolderChanges(cut, db: db) }
            }
            let lapseCount = try await lapses()
            #expect(lapseCount == 1, "one lapse per check across three cut passes")
            let folder = try #require(try await pool.read { db in try Folder.fetchOne(db, key: folderId) })
            let results = await w.provider.catchUp(
                folders: [folder], localRows: w.local,
                context: CatchUpContext(isExpensiveNetwork: false, deadline: .distantFuture, clock: { Date() }))
            let result = try #require(results.first, "the armed catch-up runs")
            #expect(result.removedIds.contains("2"), "the catch-up listing proves the deleted message gone: \(result.removedIds)")
            let state = try #require(IMAPCatchUpState.decode(result.newState))
            #expect(state.listing == nil && state.lastCompletedAt != nil, "the catch-up listing completes")
        }
    }

    @Test("T13: a held-rows count that changed between the check and the apply commits neither the bookmark nor the progress")
    func heldRowsMismatchKeepsTheBookmark() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: "cs-t13", provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: "cs-t13", path: "INBOX", role: .inbox, pool: pool,
            totalCount: 3, lastKnownUidNext: 4, lastKnownUidValidity: R.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: "cs-t13", path: "INBOX", uids: [1, 2, 3], pool: pool)
        let folderId = "cs-t13:INBOX"
        let before = IMAPChangeCursor(uidValidity: UInt32(R.epoch), highestModSeq: 5, uidNext: 4, messageCount: 3).encoded
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET changeCursor = ? WHERE id = ?", arguments: [before, folderId])
        }
        var changes = FolderChanges(
            folderId: folderId, status: .tracked, addressEpoch: R.epoch,
            cursor: IMAPChangeCursor(uidValidity: UInt32(R.epoch), highestModSeq: 6, uidNext: 4, messageCount: 3).encoded)
        // The read checked two rows in 1...3; the folder holds three there now.
        changes.heldRowsProof = .init(lowerId: 1, upperId: 3, count: 2)
        let mismatch = changes
        _ = try await pool.write { db in try SyncEngine.applyFolderChanges(mismatch, db: db) }
        #expect(try await pool.read { db in try String.fetchOne(db, sql: "SELECT changeCursor FROM folder WHERE id = ?", arguments: [folderId]) } == before)
        changes.heldRowsProof = .init(lowerId: 1, upperId: 3, count: 3)
        let agreeing = changes
        _ = try await pool.write { db in try SyncEngine.applyFolderChanges(agreeing, db: db) }
        #expect(try await pool.read { db in try String.fetchOne(db, sql: "SELECT changeCursor FROM folder WHERE id = ?", arguments: [folderId]) } == agreeing.cursor)
    }

    // MARK: - T13 through the reader: a row inserted between the check and the apply

    /// Most ordinary passes the race tests allow before the folder must settle.
    static let raceSettlePassCap = 4

    /// The server holds 1...5, the device 1, 3, 4, 5 (UID 2 not loaded yet).
    /// The server expunges `expunged` (always 4, so a check is owed); the
    /// reader's check enumerates the held rows; then a crawl that read UID 2
    /// earlier inserts it, inside the checked range, before the apply. Then
    /// ordinary passes run (reader rows = the database's) until the bookmark
    /// moves. Returns the bookmark after the raced pass, the stored baseline,
    /// the bookmark at the end, and the rows at the end.
    static func rowInsertedBetweenCheckAndApply(
        expunged: Set<Int>, accountId: String
    ) async throws -> (afterRace: String?, baseline: String, final: String?, rows: [String]) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: R.inboxPath, role: .inbox, pool: pool,
            totalCount: 5, lastKnownUidNext: 6, lastKnownUidValidity: R.epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: R.inboxPath, uids: [1, 3, 4, 5], pool: pool)
        let folderId = "\(accountId):\(R.inboxPath)"
        func storedCursor() async throws -> String? {
            try await pool.read { db in try String.fetchOne(db, sql: "SELECT changeCursor FROM folder WHERE id = ?", arguments: [folderId]) }
        }
        func storedRows() async throws -> [String] {
            try await pool.read { db in
                try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ? ORDER BY CAST(messageId AS INTEGER)", arguments: [folderId])
            }
        }
        var outcome: (afterRace: String?, baseline: String, final: String?, rows: [String]) = (nil, "", nil, [])
        try await C.withWorld(inbox: [1, 2, 3, 4, 5]) { w in
            #expect(w.inboxId == folderId, "setup: the reader and the database name one folder")
            w.local.set(w.inboxId, [1, 3, 4, 5])
            let base = try await R.baseline(w)
            outcome.baseline = base
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = ? WHERE id = ?", arguments: [base, folderId])
            }
            C.remove(expunged, from: w.server)

            // The raced pass: the check enumerated 1, 3, 4, 5; UID 2 lands before the apply.
            let raced = try await R.inbox(w, R.read(w, cursors: [w.inboxId: base]))
            #expect(R.isTracked(raced.status), "setup: the raced pass finishes its check, got \(raced.status)")
            try FolderEpochTestFixture.insertHeaders(accountId: accountId, path: R.inboxPath, uids: [2], pool: pool)
            _ = try await pool.write { db in try SyncEngine.applyFolderChanges(raced, db: db) }
            outcome.afterRace = try await storedCursor()

            // Ordinary passes over what the device now holds.
            for _ in 0..<Self.raceSettlePassCap {
                let held = try await storedRows().compactMap(Int.init)
                w.local.set(w.inboxId, held)
                let cursor = try await storedCursor()
                let pass = try await R.inbox(w, R.read(w, cursors: [w.inboxId: cursor]))
                _ = try await pool.write { db in try SyncEngine.applyFolderChanges(pass, db: db) }
                if try await storedCursor() != base { break }
            }
            outcome.final = try await storedCursor()
            outcome.rows = try await storedRows()
        }
        return outcome
    }

    @Test("T13 race: a row a crawl inserts inside the checked range after the reader's check and before the apply keeps the bookmark; the next ordinary pass removes it once the server has expunged it")
    func rowInsertedAfterTheCheckKeepsTheBookmarkAndIsRemovedLater() async throws {
        let outcome = try await Self.rowInsertedBetweenCheckAndApply(expunged: [2, 4], accountId: "cs-t13-race")
        #expect(outcome.afterRace == outcome.baseline, "the bookmark advanced past a row the check never examined")
        #expect(!outcome.rows.contains("2"), "the expunged message the crawl inserted is still shown: \(outcome.rows)")
        #expect(!outcome.rows.contains("4"), "the expunged message is still shown: \(outcome.rows)")
        #expect(outcome.rows.contains("1") && outcome.rows.contains("3") && outcome.rows.contains("5"), "a live row was removed: \(outcome.rows)")
        #expect(outcome.final != outcome.baseline, "the folder's bookmark never moved on after the race settled")
    }

    @Test("Control: a live row a crawl inserts after the reader's check stays, and the bookmark moves on after the next ordinary pass")
    func liveRowInsertedAfterTheCheckLoadsNormally() async throws {
        let outcome = try await Self.rowInsertedBetweenCheckAndApply(expunged: [4], accountId: "cs-t13-live")
        #expect(outcome.rows == ["1", "2", "3", "5"], "the live inserted row is kept and only the expunged one goes: \(outcome.rows)")
        #expect(outcome.final != outcome.baseline, "the bookmark moved on")
    }

    // MARK: - An established bookmark and a SELECT that says EXISTS 0

    /// Bookmark at count 3, UIDNEXT 4; then UID 4 comes and goes so the next
    /// read SELECTs with nothing to read.
    static func trackedThreeWithASpentUID(_ w: IMAPChangeEngineTests.World) async throws {
        w.server.honorSearchUIDSetCriterion()
        w.server.setExpungeKeepsHighestModSeq(true, for: IMAPChangeEngineTests.path)
        // A baseline pass (its listing and commit track the folder), then a tracked read.
        try await C.foregroundPass(w)
        try await C.foregroundPass(w)
        #expect(try C.tracked(w), "setup: tracked")
        #expect(try cursor(w.folder().changeCursor).messageCount == 3, "setup: an established bookmark")
        C.add([4], to: w.server, IMAPChangeEngineTests.path)
        C.remove([4], from: w.server, IMAPChangeEngineTests.path)
    }

    @Test("A SELECT that says EXISTS 0 while SEARCH lists the live UIDs over a tracked folder: the rows and the bookmark stay, coverage is cleared, and the next listing tracks the folder again and applies a flag change")
    func existsZeroOverAnEstablishedBookmarkKeepsIt() async throws {
        let path = IMAPChangeEngineTests.path
        try await IMAPChangeEngineTests.withWorld(
            "cs-exists0", capabilities: C.condstore, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]
        ) { w in
            try await Self.trackedThreeWithASpentUID(w)
            let before = try Self.cursor(w.folder().changeCursor)
            w.server.setSelectExists(0, forNext: 1, of: path)
            try await C.foregroundPass(w)
            let contradicted = try w.folder()
            #expect(!FolderChangeState(raw: contradicted.changeState).tracking, "the contradictory read clears the folder's coverage")
            let kept = try Self.cursor(contradicted.changeCursor)
            #expect(kept.messageCount == 3, "the count is not poisoned")
            #expect(kept.uidNext == before.uidNext && kept.highestModSeq == before.highestModSeq, "the prior bookmark is kept")
            #expect(try w.uids() == ["1", "2", "3"], "the live rows survive")

            w.server.setFlags(["\\Seen"], in: path, uid: 2)
            try await C.foregroundPass(w, listing: true)
            let folderId = w.folderId
            let read = try await w.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT isRead FROM messageHeader WHERE folderId = ? AND messageId = '2'",
                                  arguments: [folderId])
            }
            #expect(read == true, "the next pass applies the flag change")
            #expect(try w.uids() == ["1", "2", "3"], "the live rows survive the listing")
            let folder = try w.folder()
            #expect(FolderChangeState(raw: folder.changeState).tracking, "the next listing tracks the folder again")
            #expect(try Self.cursor(folder.changeCursor).failingSince == nil, "no failure waits for the lapse")
        }
    }

    @Test("Control: a folder the server truly emptied stores count 0 and removes its rows")
    func trulyEmptiedFolderStoresCountZero() async throws {
        let path = IMAPChangeEngineTests.path
        try await IMAPChangeEngineTests.withWorld(
            "cs-empty", capabilities: C.condstore, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]
        ) { w in
            try await Self.trackedThreeWithASpentUID(w)
            C.remove([1, 2, 3], from: w.server, path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            #expect(try w.uids().isEmpty, "the removed messages are gone")
            #expect(try Self.cursor(w.folder().changeCursor).messageCount == 0)
        }
    }
}
