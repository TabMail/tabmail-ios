/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for diff-based reloadMessages() and rebuildDisplayGroups().
/// Verifies that background reloads preserve existing message/group identity
/// (scroll position stability) while correctly reflecting data changes.
@Suite("InboxViewModel Diff-Based Updates", .serialized, .processGlobalState)
struct InboxViewModelDiffTests {

    // MARK: - Helpers

    @MainActor
    private func makeTestDB() throws -> (pool: DatabasePool, folder: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)

        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }

        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let f = folder
            try f.insert(db)
        }

        return (pool, folder, dir, previous)
    }

    @MainActor
    private func insertMessages(
        _ pool: DatabasePool,
        specs: [(messageId: String, subject: String, date: Date, computedThreadId: String, from: String)],
        folderId: String
    ) throws -> [String] {
        var ids: [String] = []
        for spec in specs {
            var header = MessageHeader(
                messageId: spec.messageId,
                subject: spec.subject,
                from: spec.from,
                fromAddress: spec.from,
                to: "test@example.com",
                date: spec.date,
                snippet: "Snippet for \(spec.messageId)",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            header.computedThreadId = spec.computedThreadId
            header.headerComplete = true  // Required for inbox display (v38 migration gate)
            try pool.writeWithoutTransaction { db in
                try header.insert(db)
            }
            let stored = try pool.read { db in
                try MessageHeader
                    .filter(Column("messageId") == spec.messageId && Column("accountId") == "acc1")
                    .fetchOne(db)
            }
            if let stored { ids.append(stored.id) }
        }
        return ids
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - reloadMessages preserves loaded range

    @Test("reloadMessages re-fetches full loaded range, not just page 1")
    @MainActor func reloadPreservesRange() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Insert more messages than one page (SyncConfig.inboxPageSize is typically 50)
        var specs: [(String, String, Date, String, String)] = []
        for i in 0..<80 {
            specs.append(("m\(i)", "Msg \(i)", baseDate.addingTimeInterval(Double(i) * 60), "standalone-\(i)", "user\(i)@test.com"))
        }
        let ids = try insertMessages(pool, specs: specs, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        let initialCount = vm.loadedMessages.count
        #expect(initialCount > 0)

        // Load more pages until we have more than 1 page
        while vm.hasMoreMessages && vm.loadedMessages.count < 80 {
            vm.loadMoreMessages()
        }
        let fullCount = vm.loadedMessages.count
        #expect(fullCount > initialCount)

        // Reload — should preserve the full range, not truncate to page 1
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == fullCount)

        // Verify all original IDs are still present
        let loadedIdSet = Set(vm.loadedMessages.map(\.id))
        for id in ids {
            #expect(loadedIdSet.contains(id))
        }
    }

    @Test("reload refills window after archive — bug regression: shrunk window doesn't ratchet down")
    @MainActor func reloadRefillsAfterArchive() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Start with 5 messages, all in the inbox.
        let ids = try insertMessages(pool, specs: [
            ("m1", "A", baseDate, "s1", "alice@test.com"),
            ("m2", "B", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
            ("m3", "C", baseDate.addingTimeInterval(120), "s3", "carol@test.com"),
            ("m4", "D", baseDate.addingTimeInterval(180), "s4", "dave@test.com"),
            ("m5", "E", baseDate.addingTimeInterval(240), "s5", "eve@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 5)

        // Simulate user archiving 4 messages — sync moves them out of the inbox.
        // Pre-fix: the next reload would see 1 message and clamp targetCount=1.
        try await pool.writeWithoutTransaction { db in
            for id in ids.prefix(4) {
                try db.execute(sql: "UPDATE messageHeader SET folderId = 'archived' WHERE id = ?", arguments: [id])
            }
        }
        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)

        // Simulate 3 new messages arriving in the inbox.
        // Pre-fix bug: window was clamped to 1, only the newest would appear and total would stay at 1.
        // Post-fix: target is still pageSize, so all 4 (1 old + 3 new) should be visible.
        _ = try insertMessages(pool, specs: [
            ("n1", "New1", baseDate.addingTimeInterval(300), "n1", "n1@test.com"),
            ("n2", "New2", baseDate.addingTimeInterval(360), "n2", "n2@test.com"),
            ("n3", "New3", baseDate.addingTimeInterval(420), "n3", "n3@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 4)
        let ids4 = Set(vm.loadedMessages.map(\.messageId))
        #expect(ids4 == ["m5", "n1", "n2", "n3"])
        // hasMoreMessages should remain true while count is still under the page floor with room to grow
        #expect(vm.hasMoreMessages == false || vm.loadedMessages.count >= SyncConfig.inboxPageSize)
    }

    @Test("reloadMessages picks up new messages inserted during background sync")
    @MainActor func reloadPicksUpNewMessages() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "First", baseDate, "s1", "alice@test.com"),
            ("m2", "Second", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)

        // Simulate background sync inserting a newer message.
        // fetchFullRange targets `targetWindowSize` (= pageSize, sticky), not the
        // current array size — so all 3 messages fit and m1 stays in the view.
        _ = try insertMessages(pool, specs: [
            ("m3", "New", baseDate.addingTimeInterval(30), "s3", "carol@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        // Count grows to 3 (window refills from DB up to the target page size)
        #expect(vm.loadedMessages.count == 3)
        #expect(vm.loadedMessages.contains { $0.messageId == "m3" })
        #expect(vm.loadedMessages.contains { $0.messageId == "m1" })
    }

    @Test("reloadMessages removes messages deleted from DB")
    @MainActor func reloadRemovesDeleted() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "First", baseDate, "s1", "alice@test.com"),
            ("m2", "Second", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
            ("m3", "Third", baseDate.addingTimeInterval(120), "s3", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3)

        // Delete middle message from DB (simulating sync discovered server-side delete)
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [ids[1]])
        }

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 2)
        #expect(!vm.loadedMessages.contains { $0.id == ids[1] })
    }

    @Test("reloadMessages updates changed message properties in-place")
    @MainActor func reloadUpdatesProperties() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Msg", baseDate, "s1", "alice@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].isRead == false)

        // Mark as read in DB
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [ids[0]])
        }

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].isRead == true)
    }

    // MARK: - rebuildDisplayGroups diff behavior

    @Test("rebuildDisplayGroups preserves group order when content unchanged")
    @MainActor func rebuildPreservesOrder() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Alpha", baseDate, "t1", "alice@test.com"),
            ("m2", "Beta", baseDate.addingTimeInterval(60), "t2", "bob@test.com"),
            ("m3", "Gamma", baseDate.addingTimeInterval(120), "t3", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 3)
        guard vm.displayGroups.count == 3 else { return }

        let originalOrder = vm.displayGroups.map(\.id)

        // Rebuild — groups should stay in same order
        vm.rebuildDisplayGroups()
        #expect(vm.displayGroups.map(\.id) == originalOrder)
    }

    @Test("rebuildDisplayGroups adds new group at correct sorted position")
    @MainActor func rebuildInsertsNewGroup() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Old", baseDate, "t1", "alice@test.com"),
            ("m3", "New", baseDate.addingTimeInterval(120), "t3", "carol@test.com"),
            ("m4", "Extra", baseDate.addingTimeInterval(180), "t4", "dave@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 3)

        // Insert a message between two existing dates into DB, then reload.
        // Target window stays at pageSize, so all 4 messages fit — m1 keeps its slot.
        _ = try insertMessages(pool, specs: [
            ("m2", "Mid", baseDate.addingTimeInterval(60), "t2", "bob@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        #expect(vm.displayGroups.count == 4)
        guard vm.displayGroups.count == 4 else { return }

        // Should be sorted by date desc: t4 (180s), t3 (120s), t2 (60s), t1 (0s)
        #expect(vm.displayGroups[0].id == "t4")
        #expect(vm.displayGroups[1].id == "t3")
        #expect(vm.displayGroups[2].id == "t2")
        #expect(vm.displayGroups[3].id == "t1")
    }

    @Test("rebuildDisplayGroups removes group when its messages are deleted")
    @MainActor func rebuildRemovesEmptyGroup() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Stay", baseDate, "t1", "alice@test.com"),
            ("m2", "Go", baseDate.addingTimeInterval(60), "t2", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 2)

        // Delete the second message from DB and reload
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [ids[1]])
        }
        await vm.reloadMessages()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].id == "t1")
    }

    @Test("rebuildDisplayGroups re-sorts when group representative date changes")
    @MainActor func rebuildResortsOnDateChange() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Thread t1 has most recent message (m3 @240s), standalone m2 @120s
        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "t1", "alice@test.com"),
            ("m2", "Standalone", baseDate.addingTimeInterval(120), "standalone-1", "bob@test.com"),
            ("m3", "Thread", baseDate.addingTimeInterval(240), "t1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 2)
        guard vm.displayGroups.count == 2 else { return }
        // t1 group (rep=m3 @240s) should be first
        #expect(vm.displayGroups[0].id == "t1")
        #expect(vm.displayGroups[1].id == "standalone-1")

        // Delete m3 (thread head) from DB — now t1's rep is m1 @0s, should sort after standalone @120s
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [ids[2]])
        }
        await vm.reloadMessages()

        #expect(vm.displayGroups.count == 2)
        guard vm.displayGroups.count == 2 else { return }
        #expect(vm.displayGroups[0].id == "standalone-1")
        #expect(vm.displayGroups[1].id == "t1")
    }

    @Test("rebuildDisplayGroups merges two groups into one when thread link added")
    @MainActor func rebuildMergesGroups() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Two standalone messages
        let ids = try insertMessages(pool, specs: [
            ("m1", "Alpha", baseDate, "s1", "alice@test.com"),
            ("m2", "Beta", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 2)

        // Update both messages to share a thread ID (simulating thread discovery)
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE messageHeader SET computedThreadId = 'shared-t' WHERE id = ?", arguments: [ids[0]])
            try db.execute(sql: "UPDATE messageHeader SET computedThreadId = 'shared-t' WHERE id = ?", arguments: [ids[1]])
        }

        // Reload to pick up the thread ID changes
        await vm.reloadMessages()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].id == "shared-t")
        #expect(vm.displayGroups[0].memberCount == 2)
    }

    // MARK: - resetMessages vs reloadMessages

    @Test("resetMessages drops all pages and reloads page 1 only")
    @MainActor func resetDropsToPage1() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        var specs: [(String, String, Date, String, String)] = []
        for i in 0..<80 {
            specs.append(("m\(i)", "Msg \(i)", baseDate.addingTimeInterval(Double(i) * 60), "s\(i)", "user\(i)@test.com"))
        }
        _ = try insertMessages(pool, specs: specs, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        let page1Count = vm.loadedMessages.count

        // Load additional pages
        while vm.hasMoreMessages && vm.loadedMessages.count < 80 {
            vm.loadMoreMessages()
        }
        #expect(vm.loadedMessages.count > page1Count)

        // resetMessages should drop back to page 1
        vm.resetMessages()
        #expect(vm.loadedMessages.count == page1Count)
    }

    @Test("resetMessages works correctly after filter toggle")
    @MainActor func resetAfterFilterToggle() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Read msg", baseDate, "s1", "alice@test.com"),
            ("m2", "Unread msg", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
        ], folderId: folder.id)

        // Mark m1 as read
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE messageId = 'm1' AND accountId = 'acc1'")
        }

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)

        // Toggle unread filter and reset
        vm.filterUnread = true
        vm.resetMessages()

        // Should only have the unread message
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].messageId == "m2")
    }

    // MARK: - reloadMessages sort order preservation

    @Test("reloadMessages preserves message sort order after no-op reload")
    @MainActor func reloadPreservesOrder() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Oldest", baseDate, "s1", "alice@test.com"),
            ("m2", "Middle", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
            ("m3", "Newest", baseDate.addingTimeInterval(120), "s3", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        let originalIds = vm.loadedMessages.map(\.id)
        let originalGroupIds = vm.displayGroups.map(\.id)

        // Reload with no DB changes — order must be identical
        await vm.reloadMessages()
        #expect(vm.loadedMessages.map(\.id) == originalIds)
        #expect(vm.displayGroups.map(\.id) == originalGroupIds)
    }

    @Test("reloadMessages inserts newer message at correct position (top)")
    @MainActor func reloadInsertsNewerAtTop() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Old", baseDate, "s1", "alice@test.com"),
            ("m2", "Mid", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)

        // Insert a newer message. Target stays at pageSize so all 3 fit.
        let newIds = try insertMessages(pool, specs: [
            ("m3", "Newest", baseDate.addingTimeInterval(120), "s3", "carol@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 3)
        guard vm.loadedMessages.count == 3 else { return }
        // Newest should be at index 0 (date descending)
        #expect(vm.loadedMessages[0].id == newIds[0])
    }

    // MARK: - rebuildDisplayGroups edge cases

    @Test("rebuildDisplayGroups handles simultaneous add and remove")
    @MainActor func rebuildSimultaneousAddRemove() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "A", baseDate, "s1", "alice@test.com"),
            ("m2", "B", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
            ("m3", "C", baseDate.addingTimeInterval(120), "s3", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 3)

        // Delete one message and add a new one in the same reload
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [ids[1]])
        }
        _ = try insertMessages(pool, specs: [
            ("m4", "D", baseDate.addingTimeInterval(90), "s4", "dave@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        #expect(vm.displayGroups.count == 3)
        // m2 (s2) removed, m4 (s4) added
        let groupIds = Set(vm.displayGroups.map(\.id))
        #expect(!groupIds.contains("s2"))
        #expect(groupIds.contains("s4"))
    }

    @Test("rebuildDisplayGroups correctly updates thread member count")
    @MainActor func rebuildUpdatesThreadMemberCount() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "t1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "t1", "bob@test.com"),
            ("m0", "Thread", baseDate.addingTimeInterval(-60), "t1", "dave@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].memberCount == 3)

        // Add a 4th message to the thread. Target stays at pageSize so all 4 fit.
        _ = try insertMessages(pool, specs: [
            ("m3", "Thread", baseDate.addingTimeInterval(120), "t1", "carol@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].memberCount == 4)
    }

    // MARK: - Empty / edge cases

    @Test("reloadMessages on empty list loads first page normally")
    @MainActor func reloadEmptyLoadsFirstPage() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Construct VM against an empty folder. `InboxViewModel.init` now calls
        // `loadInitialPage` so the first render has data, but here there's no
        // data yet — loadedMessages stays empty with hasLoadedInitialPage=true.
        let vm = InboxViewModel(folders: [folder])
        vm.start()
        #expect(vm.loadedMessages.isEmpty)
        #expect(vm.hasLoadedInitialPage)

        // Insert data after VM init; exercise the empty-list reload fallback in
        // `fetchFullRange` (which routes to `fetchPage(before: nil)`).
        _ = try insertMessages(pool, specs: [
            ("m1", "Msg", baseDate, "s1", "alice@test.com"),
        ], folderId: folder.id)

        await vm.reloadMessages()
        #expect(vm.loadedMessages.count == 1)
    }

    @Test("rebuildDisplayGroups on empty displayGroups does full assign")
    @MainActor func rebuildEmptyAssigns() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Msg", baseDate, "s1", "alice@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.displayGroups.count == 1)
    }

    @Test("reloadMessages with all messages deleted leaves empty state")
    @MainActor func reloadAllDeleted() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "A", baseDate, "s1", "alice@test.com"),
            ("m2", "B", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)

        // Delete all messages
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = 'acc1'")
        }

        await vm.reloadMessages()
        #expect(vm.loadedMessages.isEmpty)
        #expect(vm.displayGroups.isEmpty)
    }

    // MARK: - loadInitialPage guard

    @Test("loadInitialPage second call is a no-op — does not reset loaded messages")
    @MainActor func loadInitialPageGuard() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        var specs: [(String, String, Date, String, String)] = []
        for i in 0..<80 {
            specs.append(("m\(i)", "Msg \(i)", baseDate.addingTimeInterval(Double(i) * 60), "s\(i)", "user\(i)@test.com"))
        }
        _ = try insertMessages(pool, specs: specs, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        let page1Count = vm.loadedMessages.count

        while vm.hasMoreMessages && vm.loadedMessages.count < 80 {
            vm.loadMoreMessages()
        }
        let fullCount = vm.loadedMessages.count
        #expect(fullCount > page1Count)

        // Second loadInitialPage should be a no-op
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == fullCount)
    }

    // MARK: - syncMove correctness

    @Test("archive asynchronously moves message folderId in GRDB")
    @MainActor func archiveSyncMove() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let archiveFolder = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in
            let f = archiveFolder
            try f.insert(db)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Test", baseDate, "s1", "alice@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 1)

        vm.archive(ids[0])

        // archive fires an async Task — poll until the DB write lands
        for _ in 0..<50 {
            let header = try await pool.read { db in
                try MessageHeader.fetchOne(db, key: ids[0])
            }
            if header?.folderId == archiveFolder.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let header = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: ids[0])
        }
        #expect(header?.folderId == archiveFolder.id)
        #expect(header?.folderPath == "Archive")
    }

    @Test("archive removes message from inbox query on next reload")
    @MainActor func archiveRemovesFromInbox() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let archiveFolder = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try await pool.writeWithoutTransaction { db in
            let f = archiveFolder
            try f.insert(db)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Stay", baseDate, "s1", "alice@test.com"),
            ("m2", "Go", baseDate.addingTimeInterval(60), "s2", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)

        vm.archive(ids[1])

        // archive fires an async Task — poll until the DB write lands
        for _ in 0..<50 {
            let header = try await pool.read { db in
                try MessageHeader.fetchOne(db, key: ids[1])
            }
            if header?.folderId != folder.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        await vm.reloadMessages()

        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].id == ids[0])
    }

    // MARK: - toggleRead immediate update

    @Test("toggleRead updates snapshot isRead immediately")
    @MainActor func toggleReadImmediate() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Unread msg", baseDate, "s1", "alice@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].isRead == false)

        vm.toggleRead(ids[0])
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].isRead == true)
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].hasUnread == false)
    }

    // MARK: - markRead([String]) batch (commit 4d23eef)

    @Test("markRead batch flips multiple unread messages in one pass")
    @MainActor func markReadBatchFlipsMultiple() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Three messages all in one computed thread, all unread.
        let ids = try insertMessages(pool, specs: [
            ("m1", "Re: thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Re: thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
            ("m3", "Re: thread", baseDate.addingTimeInterval(120), "thread-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3)
        guard vm.loadedMessages.count == 3 else { return }
        for m in vm.loadedMessages { #expect(m.isRead == false) }

        // Apply batched markRead — covers the tag-tap-on-collapsed-thread path.
        vm.markRead(ids)

        #expect(vm.loadedMessages.count == 3)
        guard vm.loadedMessages.count == 3 else { return }
        for m in vm.loadedMessages { #expect(m.isRead == true) }
        // The single collapsed display group now shows no unread badge.
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].hasUnread == false)
    }

    @Test("markRead batch skips already-read members (filters to unread)")
    @MainActor func markReadBatchSkipsAlreadyRead() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Re: thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Re: thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
        ], folderId: folder.id)

        // Pre-mark m1 read so the batch sees a mixed set.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [ids[0]])
        }

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)
        guard vm.loadedMessages.count == 2 else { return }

        let m1Before = vm.loadedMessages.first { $0.id == ids[0] }
        let m2Before = vm.loadedMessages.first { $0.id == ids[1] }
        #expect(m1Before?.isRead == true)
        #expect(m2Before?.isRead == false)

        vm.markRead(ids)

        let m1After = vm.loadedMessages.first { $0.id == ids[0] }
        let m2After = vm.loadedMessages.first { $0.id == ids[1] }
        #expect(m1After?.isRead == true)  // unchanged
        #expect(m2After?.isRead == true)  // flipped
    }

    @Test("markRead batch is a no-op when all messages already read")
    @MainActor func markReadBatchNoOpAllRead() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Re: thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Re: thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
        ], folderId: folder.id)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1", arguments: [])
        }

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        for m in vm.loadedMessages { #expect(m.isRead == true) }
        let snapshotIds = vm.loadedMessages.map(\.id)

        // No-op: no overlay registration, no enqueueWrite call. Hard to assert
        // those side effects from here, so assert the visible state is unchanged.
        vm.markRead(ids)

        #expect(vm.loadedMessages.map(\.id) == snapshotIds)
        for m in vm.loadedMessages { #expect(m.isRead == true) }
    }

    @Test("markRead batch ignores unknown ids without crashing")
    @MainActor func markReadBatchIgnoresUnknownIds() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Hello", baseDate, "thread-1", "alice@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 1)

        // Pass real + bogus ids — lookupMessage compactMap drops the bogus one.
        vm.markRead(ids + ["does-not-exist", "also-bogus"])

        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].isRead == true)
    }

    // MARK: - Pagination + reload interaction

    @Test("loadMoreMessages appends new groups via diff-based rebuild")
    @MainActor func loadMoreAppendsGroups() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        var specs: [(String, String, Date, String, String)] = []
        for i in 0..<80 {
            specs.append(("m\(i)", "Msg \(i)", baseDate.addingTimeInterval(Double(i) * 60), "s\(i)", "user\(i)@test.com"))
        }
        _ = try insertMessages(pool, specs: specs, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        let page1GroupCount = vm.displayGroups.count
        #expect(page1GroupCount > 0)

        // Load page 2
        vm.loadMoreMessages()
        #expect(vm.displayGroups.count > page1GroupCount)

        // All groups should be in date-descending order
        for i in 1..<vm.displayGroups.count {
            #expect(vm.displayGroups[i - 1].representative.date >= vm.displayGroups[i].representative.date)
        }
    }

    // MARK: - Folder self-heal on reload (warm-foreground hang fix characterization)

    /// Characterizes the behavior of `selfHealFolders` as invoked by
    /// `reloadMessages` on a warm-foreground return: when the VM's folder list
    /// is stale relative to GRDB (NavigationStore lagging the DB), the reload
    /// resolves the real folder from the DB and loads its messages. This MUST
    /// hold identically whether the folder resolve is synchronous (pre-fix) or
    /// asynchronous (Half A) — the only thing changing is that the read no
    /// longer blocks the main thread.
    @Test("reloadMessages self-heals stale folders from GRDB (unified inbox)")
    @MainActor func reloadSelfHealsStaleFolders() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // One message in the REAL inbox folder ("acc1:INBOX").
        let ids = try insertMessages(pool, specs: [
            ("m1", "Hello", baseDate, "s1", "alice@test.com"),
        ], folderId: folder.id)

        // Construct the VM with a STALE inbox folder ("acc1:STALE") not present in
        // the DB — simulates NavigationStore's folder list lagging the DB on a
        // foreground return. `resolveFoldersFromDB` (unified .inbox) should heal
        // it to the real DB inbox folder, and the reload should then load m1.
        let staleFolder = Folder(name: "Stale", path: "STALE", role: .inbox, accountId: "acc1")
        #expect(staleFolder.id != folder.id)

        let vm = InboxViewModel(folders: [staleFolder])   // selection defaults to .unified(.inbox)
        await vm.reloadMessages()

        #expect(vm.folders.contains { $0.id == folder.id }, "folders should self-heal to the DB inbox folder")
        #expect(!vm.folders.contains { $0.id == staleFolder.id }, "stale folder should be replaced")
        #expect(vm.loadedMessages.contains { $0.id == ids[0] }, "message in the healed folder should load")
    }

    // MARK: - R13 — ONE inbox ordering key, agreed by every spelling of it

    /// 🚨 **THE INVARIANT: the order the view model's in-memory positioning
    /// produces IS the order the reader produces.** Not "the comparator ends in
    /// `id`" — that pins the mechanism and would stay green if the reference
    /// order itself moved. The system property is agreement: whatever the SQL
    /// `ORDER BY` + `InboxListComposer` step 7 decide the list looks like, the
    /// VM's sorted inserts must land rows in exactly that arrangement.
    ///
    /// **Why it is load-bearing and not cosmetic.** `loadMoreMessages` takes its
    /// keyset cursor from `loadedMessages.last` (R12-T3, `3b31fdb4d`). If the
    /// array is not in the reader's total order, `last` is not the maximal row
    /// under that order, so the keyset predicate re-admits rows the VM already
    /// holds. Those rows consume slots in the reader's per-folder SQL `LIMIT`
    /// and are only dropped afterwards by `excludeIds`/the VM belt — the
    /// filter-after-LIMIT shape `IOS-SCROLL-002` was filed for. The short page
    /// then sets `hasMoreMessages = nextPage.count >= inboxPageSize` false and
    /// **every older message in the mailbox becomes unreachable by scrolling.**
    /// Ties on the ordering key are ordinary: IMAP `INTERNALDATE` has second
    /// granularity, and in triage the primary key is `tagSortOrder`, where a
    /// whole bucket shares one value.
    ///
    /// The oracle is deliberately the READER, never a second copy of the
    /// comparator written here.
    @MainActor
    private func readerOrder(_ vm: InboxViewModel) -> [String] {
        let query = InboxListQuery(
            displayedFolderIds: Set(vm.folders.map(\.id)),
            filterUnread: vm.filterUnread,
            filterLabelIds: vm.filterLabelIds,
            mode: vm.mode,
            targetCount: SyncConfig.inboxPageSize,
            before: nil
        )
        return InboxListReader.fetchSync(folders: vm.folders, query: query).map(\.id)
    }

    /// Insert one durable, inbox-visible header with an explicit date and tag.
    /// `insertMessages` above cannot set `actionTag`/`tagSortOrder`, which the
    /// triage arm of the ordering key needs.
    @MainActor
    private func insertOrderingRow(
        _ pool: DatabasePool, messageId: String, date: Date, tag: ActionTag? = nil, folderId: String
    ) throws -> String {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Subj \(messageId)",
            from: "\(messageId)@test.com",
            fromAddress: "\(messageId)@test.com",
            to: "test@example.com",
            date: date,
            snippet: "snip",
            folderId: folderId,
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.computedThreadId = "thread-\(messageId)"
        header.headerComplete = true
        header.actionTag = tag
        header.tagSortOrder = tag?.sortOrder ?? 99
        try pool.writeWithoutTransaction { db in try header.insert(db) }
        return header.id
    }

    @Test("reload-diff places a row tied on the ordering key exactly where the reader does (normal mode)")
    @MainActor func reloadDiffAgreesWithReaderOnTiesNormal() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Two rows share ONE second; a third is strictly older so the tie block
        // is not the whole list (a fix that merely appended would still pass).
        let tied = baseDate
        _ = try insertOrderingRow(pool, messageId: "m-b", date: tied, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-d", date: tied, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-y", date: tied.addingTimeInterval(-60), folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        // ⚠️ Anchor the fixture before asserting an arrangement (MIS-030): three
        // rows must actually be visible, or the comparison below is vacuous.
        #expect(vm.loadedMessages.count == 3, "fixture did not stage 3 visible rows; got \(vm.loadedMessages.count)")
        guard vm.loadedMessages.count == 3 else { return }
        #expect(vm.loadedMessages.map(\.id) == readerOrder(vm), "the initial page already disagreed with the reader — the diff assertion below would be testing the wrong thing")

        // A new row arrives tied on the SAME second, with an id that sorts BEFORE
        // both loaded tied rows. Under the reader's `(date DESC, id ASC)` it
        // belongs at the HEAD of the tie block, not at its end.
        _ = try insertOrderingRow(pool, messageId: "m-a", date: tied, folderId: folder.id)

        await vm.reloadMessages()

        #expect(vm.loadedMessages.count == 4)
        #expect(
            vm.loadedMessages.map(\.id) == readerOrder(vm),
            """
            the reload-diff's in-memory arrangement disagrees with the reader's. \
            `loadMoreMessages` keys its pagination cursor off `loadedMessages.last`, \
            so a list that is not in the reader's total order re-requests rows it \
            already holds; they burn SQL LIMIT slots, the page comes back short, and \
            `hasMoreMessages` goes false with mail still unread below.
            vm     = \(vm.loadedMessages.map(\.id))
            reader = \(readerOrder(vm))
            """)
    }

    @Test("reload-diff places a row tied on the ordering key exactly where the reader does (triage mode)")
    @MainActor func reloadDiffAgreesWithReaderOnTiesTriage() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // Triage orders `tagSortOrder ASC, date DESC`. The reply bucket (0) is
        // OLDER than the untagged row (99) — the ordinary shape, and the reason
        // this order is not date-monotonic.
        let tied = baseDate
        _ = try insertOrderingRow(pool, messageId: "m-b", date: tied, tag: .reply, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-d", date: tied, tag: .reply, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-z", date: tied.addingTimeInterval(3600), folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.mode = .triage
        vm.start()
        // `init` already ran `loadInitialPage()` in `.normal`, and that call is
        // one-shot — `resetMessages()` is the only way to re-seed page 1 under
        // the new mode. Calling `loadInitialPage()` here would silently leave a
        // NORMAL-ordered list and the triage arm would never be exercised.
        vm.resetMessages()
        #expect(vm.loadedMessages.count == 3, "fixture did not stage 3 visible rows; got \(vm.loadedMessages.count)")
        guard vm.loadedMessages.count == 3 else { return }
        #expect(vm.loadedMessages.map(\.id) == readerOrder(vm), "the initial triage page already disagreed with the reader")

        // Tied on BOTH tagSortOrder and date; its id sorts first.
        _ = try insertOrderingRow(pool, messageId: "m-a", date: tied, tag: .reply, folderId: folder.id)

        await vm.reloadMessages()

        #expect(vm.loadedMessages.count == 4)
        #expect(
            vm.loadedMessages.map(\.id) == readerOrder(vm),
            """
            the triage reload-diff's arrangement disagrees with the reader's.
            vm     = \(vm.loadedMessages.map(\.id))
            reader = \(readerOrder(vm))
            """)
    }

    @Test("insertUndoneMessages places an undone row tied on the ordering key exactly where the reader does")
    @MainActor func insertUndoneAgreesWithReaderOnTies() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let tied = baseDate
        _ = try insertOrderingRow(pool, messageId: "m-b", date: tied, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-d", date: tied, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-y", date: tied.addingTimeInterval(-60), folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3, "fixture did not stage 3 visible rows; got \(vm.loadedMessages.count)")
        guard vm.loadedMessages.count == 3 else { return }

        // The undone row is restored to the inbox in GRDB, then re-inserted into
        // the on-screen list by the targeted undo path (not by a full reload).
        let undoneId = try insertOrderingRow(pool, messageId: "m-a", date: tied, folderId: folder.id)
        vm.insertUndoneMessages([undoneId])

        #expect(vm.loadedMessages.count == 4)
        #expect(
            vm.loadedMessages.map(\.id) == readerOrder(vm),
            """
            the undo path's targeted insert disagrees with the reader's arrangement.
            vm     = \(vm.loadedMessages.map(\.id))
            reader = \(readerOrder(vm))
            """)
    }

    @Test("insertStagedRows places a staged row tied on the ordering key exactly where the reader will")
    @MainActor func insertStagedAgreesWithReaderOnTies() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let tied = baseDate
        _ = try insertOrderingRow(pool, messageId: "m-b", date: tied, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-d", date: tied, folderId: folder.id)
        _ = try insertOrderingRow(pool, messageId: "m-y", date: tied.addingTimeInterval(-60), folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3, "fixture did not stage 3 visible rows; got \(vm.loadedMessages.count)")
        guard vm.loadedMessages.count == 3 else { return }

        // ADR-IOS-049's zero-I/O instant insert. The property under test is that
        // the slot it picks is the slot the DURABLE read will pick once the merge
        // lands — otherwise the row visibly jumps on the next reload, and until
        // then the array is out of the reader's order with the cursor read off it.
        vm.insertStagedRows([
            StagedInboxRow(
                accountId: "acc1", folderPath: "INBOX", messageId: "m-a",
                rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [],
                subject: "Subj m-a", senderName: "Sender", senderAddress: "m-a@test.com",
                to: "test@example.com", snippet: "snip", date: tied,
                isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
                isForwarded: false, actionTag: nil, summaryBlurb: nil
            )
        ])
        #expect(vm.loadedMessages.count == 4)

        // Now let the merge land: the same row becomes durable, so the reader can
        // speak for where it belongs.
        _ = try insertOrderingRow(pool, messageId: "m-a", date: tied, folderId: folder.id)

        #expect(
            vm.loadedMessages.map(\.id) == readerOrder(vm),
            """
            the staged instant-insert put the row in a slot the durable read does not agree with.
            vm     = \(vm.loadedMessages.map(\.id))
            reader = \(readerOrder(vm))
            """)
    }
}
