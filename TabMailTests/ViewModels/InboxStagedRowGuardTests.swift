/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-049 race-fix regression tests. Covers two holes in `reloadMessages`'
/// Pass-1 anti-flicker guard for NSE-staged rows whose durable GRDB write
/// hasn't landed yet:
///
/// BUG 1 — any overlay mutation (isRead/isFlagged/actionTag) used to release
/// the guard, not just a folder move. A user opening (marking read) a
/// just-pushed message could evict it from the list until the durable write
/// landed. Fix: only a folder-move overlay (`overlay[id]?.folderId != nil`)
/// releases the guard.
///
/// BUG 2 — the phase-1 durable header write / a sync-created header carries
/// NO AI fields (summary/action land in phase 2), so the first fresh row for
/// a staged id clobbered the staged `actionTag`/`tagSortOrder`/`summaryBlurb`
/// with nil, flashing the tag chip/summary away. Fix: carry over staged AI
/// fields when the fresh row lacks them, and keep the `pendingStagedRows`
/// guard entry alive (still bounded by `stagedRowEvictionGuardSeconds`) until
/// a fresh row arrives with real AI fields.
@Suite("Inbox staged-row guard races (ADR-IOS-049 fix)", .serialized)
struct InboxStagedRowGuardTests {

    // MARK: - Harness (mirrors InboxStagedInsertTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, folder: Folder, dir: URL, previous: AppDatabase?) {
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
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let f = folder; try f.insert(db) }
        return (pool, folder, dir, previous)
    }

    private func makeStagedRow(
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        messageId: String,
        actionTag: String? = nil,
        summaryBlurb: String? = nil
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: actionTag, summaryBlurb: summaryBlurb
        )
    }

    /// Clears any overlay entries left behind by a test — `AccountManager.shared`
    /// is a real singleton, not swapped per-test (mirrors
    /// InboxViewModelInsertUndoneTests.swift's `clearOverlay`).
    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    // MARK: - BUG 1: only a folder-move overlay releases the guard

    @Test("isRead-only overlay does NOT release the guard — staged row survives a reload that omits it")
    @MainActor func isReadOnlyOverlaySurvivesReload() async throws {
        let (_, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        // Phantom staged row — no durable GRDB write ever lands, so `fresh`
        // never contains it on any reload (mirrors the pre-phase-2 window).
        vm.insertStagedRows([makeStagedRow(messageId: "m-read")])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-read")

        // Simulate the user opening the message (MessageDetailViewModel.markReadOnOpenIfNeeded):
        // an isRead-only overlay mutation, no folder change.
        AccountManager.shared.registerMutation(id: id, mutation: .init(isRead: true))

        // A competing reload (fresh from DB doesn't contain this row) must NOT
        // evict it — pre-fix, `overlay[id] == nil` was false (overlay exists),
        // so the guard was released and the row vanished here.
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.contains { $0.id == id })
    }

    @Test("folderId overlay (message moved out of displayed folders) DOES release the guard — row is evicted")
    @MainActor func folderMoveOverlayEvicts() async throws {
        let (_, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        vm.insertStagedRows([makeStagedRow(messageId: "m-moved")])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-moved")

        // Simulate the user archiving the just-pushed row: overlay redirects it
        // to a folder not in the VM's displayed set.
        AccountManager.shared.registerMutation(id: id, mutation: .init(folderId: "acc1:Archive"))

        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)
        #expect(!vm.loadedMessages.contains { $0.id == id })
    }

    // MARK: - BUG 2: AI-less fresh rows must not clobber staged AI fields

    @Test("AI-less durable/sync row does not clobber staged actionTag/tagSortOrder/summaryBlurb; guard entry retained")
    @MainActor func aiFieldsCarryOverAndGuardRetained() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        vm.insertStagedRows([makeStagedRow(messageId: "m-ai", actionTag: ActionTag.reply.rawValue, summaryBlurb: "staged blurb")])
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].actionTag == .reply)
        #expect(vm.loadedMessages[0].tagSortOrder == ActionTag.reply.sortOrder)
        #expect(vm.loadedMessages[0].summaryBlurb == "staged blurb")

        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-ai")

        // Phase-1 durable write / sync-created header lands for the SAME headerId
        // (same accountId/folderPath/messageId → deterministic id), but with NO
        // AI fields — mirrors NSEDataBridge's phase-1 upsert / a plain sync insert.
        var durable = MessageHeader(
            messageId: "m-ai", subject: "Subj m-ai", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        // actionTag / summaryBlurb intentionally left nil (AI-less phase-1 row).
        // let-copy: the async writeWithoutTransaction closure is @Sendable and
        // can't capture a mutable var.
        let durableRow = durable
        try await pool.writeWithoutTransaction { db in try durableRow.insert(db) }
        #expect(durable.id == id)

        await vm.reloadMessages()

        // Staged AI fields survive the AI-less durable row landing.
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].id == id)
        #expect(vm.loadedMessages[0].actionTag == .reply)
        #expect(vm.loadedMessages[0].tagSortOrder == ActionTag.reply.sortOrder)
        #expect(vm.loadedMessages[0].summaryBlurb == "staged blurb")

        // Indirect proof the pendingStagedRows guard entry was RETAINED (not
        // dropped) by the carry-over pass: delete the durable row so the next
        // reload's `fresh` omits this id entirely. If the guard entry had been
        // dropped, this reload would fall through to the final `else` branch
        // and evict the row immediately (well inside the 60s guard window).
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [id])
        }
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.loadedMessages.contains { $0.id == id })
    }

    @Test("fresh row WITH real AI fields wins and drops the guard entry — row no longer protected afterward")
    @MainActor func realAIFieldsWinAndDropGuard() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            clearOverlay()
        }
        clearOverlay()

        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        vm.insertStagedRows([makeStagedRow(messageId: "m-ai2", actionTag: ActionTag.reply.rawValue, summaryBlurb: "staged blurb")])
        #expect(vm.loadedMessages.count == 1)
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m-ai2")

        // Phase-1 AI-less durable row lands first (same as previous test) —
        // carry-over keeps the staged AI fields and the guard entry alive.
        var durable = MessageHeader(
            messageId: "m-ai2", subject: "Subj m-ai2", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        let durableRow = durable
        try await pool.writeWithoutTransaction { db in try durableRow.insert(db) }
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].actionTag == .reply) // still carried over

        // Phase 2 lands: the row now has REAL AI fields (simulating the AI
        // repaint / a later merge phase-2 write).
        try await pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, summaryBlurb = ? WHERE id = ?",
                arguments: [ActionTag.archive.rawValue, ActionTag.archive.sortOrder, "real blurb", id]
            )
        }
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        // Fresh (real) values win over the stale staged ones.
        #expect(vm.loadedMessages[0].actionTag == .archive)
        #expect(vm.loadedMessages[0].tagSortOrder == ActionTag.archive.sortOrder)
        #expect(vm.loadedMessages[0].summaryBlurb == "real blurb")

        // Indirect proof the guard entry was DROPPED on the real-AI-fields pass:
        // backdate (no-op — the DEBUG hook itself no-ops for an id no longer in
        // pendingStagedRows) then delete the row and reload immediately (well
        // inside what would have been the 60s guard window). If the guard entry
        // had survived, this reload would keep the row; since it was dropped,
        // the row is evicted immediately.
        vm._testBackdateStagedGuard(id: id, by: SyncConfig.stagedRowEvictionGuardSeconds + 1)
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [id])
        }
        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)
        #expect(!vm.loadedMessages.contains { $0.id == id })
    }
}
