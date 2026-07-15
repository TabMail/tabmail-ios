/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// End-to-end coverage for `AccountManager.archiveOldInboxMessages`: account
/// routing, admission, returned counts, visible Undo-stack entries, and final
/// local message state.
///
/// `.serialized`: tests swap the process-wide `AppDatabase.shared` and touch
/// `AccountManager.shared`'s intention journal + `UndoService.shared`'s stack
/// — mirrors `CoordinatedToolActionTests` / `AccountManagerActionsTagClearTests`.
@Suite("AccountManager.archiveOldInboxMessages", .serialized, .processGlobalState)
@MainActor
struct ArchiveOldMessagesTests {

    // MARK: - Harness (mirrors CoordinatedToolActionTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
        }
        return (pool, inbox, archive, dir, previous)
    }

    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func clearOverlay() {
        AccountManager.shared.intentionJournal.resetForTesting()
    }

    private func drainWriteQueue() async {
        var iterations = 0
        repeat {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
            }
            iterations += 1
        } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting() && iterations < 200
    }

    /// The same cutoff `SettingsView.archiveOldMessages` computes — dynamic,
    /// relative to "now" (never a hardcoded date, per CLAUDE.md Testing
    /// Rule 7).
    private var archiveCutoff: Date {
        Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: Date()) ?? Date()
    }

    /// An old, query-visible header dated well before `archiveCutoff`.
    private func makeOldHeader(folder: Folder, messageId: String, archiveCutoff: Date) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: archiveCutoff.addingTimeInterval(-10 * 86400), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        h.rfc822MessageId = "<\(messageId)@archive-old.example.com>"
        return h
    }

    // MARK: - Per-account archive outcomes

    @Test("each account archives to its own folder and exposes one Undo entry")
    func perAccountGroupingAndVisibleUndoEntries() async throws {
        let (pool, inbox1, archive1, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        try await pool.writeWithoutTransaction { db in
            var acc2 = Account(emailAddress: "second@example.com", displayName: "Second", provider: .gmail)
            acc2.id = "acc2"
            try acc2.insert(db)
            var acc3 = Account(emailAddress: "third@example.com", displayName: "Third", provider: .gmail)
            acc3.id = "acc3"
            try acc3.insert(db)
        }
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let archive2 = Folder(name: "Archived Mail", path: "Archived Mail", role: .archive, accountId: "acc2")
        let inbox3 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc3")
        let archive3 = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc3")
        try await pool.writeWithoutTransaction { db in
            let i = inbox2; try i.insert(db)
            let a = archive2; try a.insert(db)
            let i3 = inbox3; try i3.insert(db)
            let a3 = archive3; try a3.insert(db)
        }

        let cutoff = archiveCutoff
        let h1 = makeOldHeader(folder: inbox1, messageId: "m-acc1-old", archiveCutoff: cutoff)
        let h2 = makeOldHeader(folder: inbox2, messageId: "m-acc2-old", archiveCutoff: cutoff)
        let h3 = makeOldHeader(folder: inbox3, messageId: "m-acc3-old", archiveCutoff: cutoff)
        try await pool.writeWithoutTransaction { db in try h1.insert(db); try h2.insert(db)
            try h3.insert(db) }

        let archived = await AccountManager.shared.archiveOldInboxMessages(
            inboxFolderIds: [inbox1.id, inbox2.id, inbox3.id], archiveCutoff: cutoff
        )
        #expect(archived == 3)

        let f1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h1.id) }
        let f2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h2.id) }
        #expect(f1?.folderId == archive1.id, "acc1's message lands in acc1's archive")
        #expect(f2?.folderId == archive2.id, "acc2's message lands in acc2's OWN archive, not acc1's")
        let f3 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h3.id) }
        #expect(f3?.folderId == archive3.id, "acc3's message lands in acc3's OWN archive")

        #expect(UndoService.shared.undoStack.count == 3, "one UndoableAction pushed PER ACCOUNT")
        #expect(UndoService.shared.undoStack.map { $0.commands.first?.accountId } == ["acc1", "acc2", "acc3"],
                "the visible Undo order matches the deterministic account order")

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - Committed archive outcome

    @Test("await-until-committed: after the call returns (no gate), rows are durably moved and the return value equals the archived count")
    func awaitUntilCommittedReturnsArchivedCount() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        let cutoff = archiveCutoff
        let h1 = makeOldHeader(folder: inbox, messageId: "m-await-1", archiveCutoff: cutoff)
        let h2 = makeOldHeader(folder: inbox, messageId: "m-await-2", archiveCutoff: cutoff)
        try await pool.writeWithoutTransaction { db in try h1.insert(db); try h2.insert(db) }

        let archived = await AccountManager.shared.archiveOldInboxMessages(inboxFolderIds: [inbox.id], archiveCutoff: cutoff)
        #expect(archived == 2, "return value equals the archived count")

        // No gate, no poll — direct assertion that the rows are durably moved.
        let f1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h1.id) }
        let f2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: h2.id) }
        #expect(f1?.folderId == archive.id)
        #expect(f2?.folderId == archive.id)

        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded")
    }

    // MARK: - Admission and missing-folder outcomes

    @Test("an account with NO archive folder is skipped cleanly; the sibling account still archives and counts")
    func accountMissingArchiveFolderSkipsWithoutAbortingSiblings() async throws {
        let (pool, inbox1, archive1, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        // Second account "acc0" — named to sort BEFORE acc1: the production
        // loop iterates accounts in SORTED order (test-review round 3), so
        // the folder-less account is DETERMINISTICALLY processed first and a
        // continue→return regression always aborts before acc1 archives —
        // caught on every run, not a Dictionary-order coin flip.
        try await pool.writeWithoutTransaction { db in
            var acc0 = Account(emailAddress: "aaa-second@example.com", displayName: "Second", provider: .gmail)
            acc0.id = "acc0"
            try acc0.insert(db)
            let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc0")
            try inbox2.insert(db)
        }
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc0")

        let cutoff = archiveCutoff
        let m1 = makeOldHeader(folder: inbox1, messageId: "old-a1", archiveCutoff: cutoff)
        let m2 = makeOldHeader(folder: inbox2, messageId: "old-a2", archiveCutoff: cutoff)
        try await pool.writeWithoutTransaction { db in
            try m1.insert(db)
            try m2.insert(db)
        }

        let archived = await AccountManager.shared.archiveOldInboxMessages(
            inboxFolderIds: [inbox1.id, inbox2.id], archiveCutoff: cutoff
        )
        await drainWriteQueue()

        // acc1 (has the folder): archived and counted.
        let final1 = try await pool.read { db in try MessageHeader.fetchOne(db, key: m1.id) }
        #expect(final1?.folderPath == archive1.path, "the sibling account with a real archive folder must still archive")
        #expect(archived == 1, "only the archivable account's messages count")

        // acc0 (no folder): skipped cleanly — row unchanged, no intention
        // recorded, no op, no undo entry for it.
        let final2 = try await pool.read { db in try MessageHeader.fetchOne(db, key: m2.id) }
        #expect(final2?.folderPath == inbox2.path, "the folder-less account's messages stay in its inbox")
        let ops = try await pool.read { db in try PendingOperation.filter(Column("accountId") == "acc0").fetchAll(db) }
        #expect(ops.isEmpty, "no PendingOperation for the skipped account")
        #expect(UndoService.shared.undoStack.count == 1, "exactly one UndoableAction — the archivable account's")
        #expect(UndoService.shared.currentAction?.commands.first?.accountId == "acc1")
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting(), "journal stranded by the skip")
    }

    @Test("mixed hybrid admission archives BOTH members: normalized RFC + provider-ID token")
    func mixedHybridAdmissionIncludesBothMembers() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        let cutoff = archiveCutoff
        let valid = makeOldHeader(folder: inbox, messageId: "mixed-valid", archiveCutoff: cutoff)
        var invalid = makeOldHeader(folder: inbox, messageId: "mixed-invalid", archiveCutoff: cutoff)
        invalid.rfc822MessageId = nil
        let invalidHeader = invalid
        let invalidId = invalidHeader.id
        try await pool.writeWithoutTransaction { db in
            try valid.insert(db)
            try invalidHeader.insert(db)
        }

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let archiveTask = Task {
            await AccountManager.shared.archiveOldInboxMessages(
                inboxFolderIds: [inbox.id], archiveCutoff: cutoff
            )
        }

        var settled = false
        for _ in 0..<200 where !settled {
            if UndoService.shared.undoStack.count == 1 { settled = true } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(settled)
        let overlay = AccountManager.shared.snapshotOverlay()
        #expect(overlay[valid.id]?.folderId == archive.id)
        #expect(overlay[invalidId]?.folderId == archive.id,
                "the token member enters the optimistic overlay like any other (PLAN_IDENTITY_HYBRID)")
        #expect(
            Set(UndoService.shared.currentAction?.commands.flatMap { $0.members.map(\.originalHeaderId) } ?? [])
                == [valid.id, invalidId]
        )

        gate.finish()
        #expect(await archiveTask.value == 2)
        await drainWriteQueue()

        let finalValid = try await pool.read { db in try MessageHeader.fetchOne(db, key: valid.id) }
        let finalTail = try await pool.read { db in try MessageHeader.fetchOne(db, key: invalidId) }
        #expect(finalValid?.folderId == archive.id)
        #expect(finalTail?.folderId == archive.id, "the token member's optimistic move must land too")
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(Set(ops[0].messageIds) == ["mixed-valid@archive-old.example.com", "mixed-invalid"],
                "normalized RFC member + byte-exact provider token")
    }

    @Test("identity-less members archive as provider-ID tokens — the bulk archive never refuses a message that has a provider ID")
    func tailOnlyBulkArchiveAdmitsTokens() async throws {
        let (pool, inbox, _, dir, previous) = try makeTestDB()
        defer {
            restoreTestDB(previous: previous, dir: dir)
            clearOverlay()
            UndoService.shared.dismissAll()
        }
        clearOverlay()
        UndoService.shared.dismissAll()

        let cutoff = archiveCutoff
        var missing = makeOldHeader(folder: inbox, messageId: "all-missing", archiveCutoff: cutoff)
        missing.rfc822MessageId = nil
        var malformed = makeOldHeader(folder: inbox, messageId: "all-malformed", archiveCutoff: cutoff)
        malformed.rfc822MessageId = "<broken"
        let missingHeader = missing
        let malformedHeader = malformed
        let refusedIds = [missingHeader.id, malformedHeader.id]
        try await pool.writeWithoutTransaction { db in
            try missingHeader.insert(db)
            try malformedHeader.insert(db)
        }

        let archived = await AccountManager.shared.archiveOldInboxMessages(
            inboxFolderIds: [inbox.id], archiveCutoff: cutoff
        )
        await drainWriteQueue()

        #expect(archived == 2, "hybrid admission: identity-less rows archive by provider-ID token")
        #expect(UndoService.shared.undoStack.count == 1)
        let rows = try await pool.read { db in
            try MessageHeader.filter(refusedIds.contains(Column("id"))).fetchAll(db)
        }
        #expect(rows.count == 2)
        guard rows.count == 2 else { return }
        #expect(rows.allSatisfy { $0.folderPath != inbox.path }, "both tail rows left the inbox optimistically")
        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(Set(ops[0].messageIds) == ["all-missing", "all-malformed"], "byte-exact provider-ID tokens")
    }

}
