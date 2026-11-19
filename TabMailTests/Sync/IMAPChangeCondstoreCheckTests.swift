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
}
