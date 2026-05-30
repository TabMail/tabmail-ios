/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for InboxViewModel's AI batch update throttle behavior.
/// The core fix: AI notifications use throttle (flush every 300ms) not debounce
/// (reset timer on each notification). With debounce, 32 concurrent LLM workers
/// completing faster than 300ms would starve the flush indefinitely.
///
/// InboxViewModel is @MainActor and uses AppDatabase.dbPool directly.
/// Tests install a temporary file-backed AppDatabase.shared, then restore it.
@Suite("InboxViewModel AI Batch Throttle", .serialized)
struct InboxViewModelAIBatchTests {

    /// Creates a temp file-backed DatabasePool, installs it as AppDatabase.shared,
    /// inserts a test account + inbox folder, and returns the pool + folder.
    /// Caller is responsible for cleanup via the returned directory URL.
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

        // Insert account + inbox folder (synchronous write on DatabasePool is OK in tests)
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }

        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            var f = folder
            try f.insert(db)
        }

        return (pool, folder, dir, previous)
    }

    /// Insert N test messages, returns their IDs (header primary keys).
    @MainActor
    private func insertMessages(
        _ pool: DatabasePool,
        count: Int,
        folderId: String
    ) throws -> [String] {
        let now = Date()
        var ids: [String] = []
        for i in 0..<count {
            let header = MessageHeader(
                messageId: "\(1000 + i)",
                subject: "Test \(i)",
                from: "sender\(i)@example.com",
                fromAddress: "sender\(i)@example.com",
                to: "test@example.com",
                date: now.addingTimeInterval(TimeInterval(-i * 60)),
                snippet: "Snippet \(i)",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            try pool.writeWithoutTransaction { db in
                var h = header
                h.headerComplete = true  // Required for inbox display (v38 migration gate)
                try h.insert(db)
            }
            // Read back to get auto-generated id
            let stored = try pool.read { db in
                try MessageHeader
                    .filter(Column("messageId") == "\(1000 + i)" && Column("accountId") == "acc1")
                    .fetchOne(db)
            }
            if let stored { ids.append(stored.id) }
        }
        return ids
    }

    /// Write an actionTag for a message in GRDB.
    @MainActor
    private func writeTag(_ pool: DatabasePool, headerId: String, tag: ActionTag) throws {
        try pool.writeWithoutTransaction { db in
            guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return }
            msg.actionTag = tag
            msg.tagSortOrder = tag.sortOrder
            try msg.save(db)
        }
    }

    /// Write actionTag + summaryBlurb for a message.
    @MainActor
    private func writeTagAndSummary(_ pool: DatabasePool, headerId: String, tag: ActionTag, summary: String) throws {
        try pool.writeWithoutTransaction { db in
            guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return }
            msg.actionTag = tag
            msg.tagSortOrder = tag.sortOrder
            msg.summaryBlurb = summary
            try msg.save(db)
        }
    }

    // MARK: - Throttle Behavior

    @Test("AI notification updates snapshot within throttle window")
    @MainActor func singleNotificationUpdatesSnapshot() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, count: 3, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.loadedMessages.count == 3 else {
            Issue.record("Expected 3 messages, got \(vm.loadedMessages.count)")
            return
        }
        #expect(vm.loadedMessages.allSatisfy { $0.actionTag == nil })

        let targetId = ids[0]
        try writeTag(pool, headerId: targetId, tag: .archive)
        NotificationCenter.default.post(name: .messageDataDidChange, object: targetId)

        try await Task.sleep(for: .milliseconds(450))

        let msg0 = vm.loadedMessages.first(where: { $0.id == targetId })
        #expect(msg0?.actionTag == .archive)
    }

    @Test("Rapid notifications flush within one throttle window — not starved")
    @MainActor func rapidNotificationsFlushWithinThrottleWindow() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, count: 5, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.loadedMessages.count == 5 else {
            Issue.record("Expected 5 messages, got \(vm.loadedMessages.count)")
            return
        }

        let id0 = ids[0]
        let id1 = ids[1]
        try writeTag(pool, headerId: id0, tag: .reply)
        try writeTag(pool, headerId: id1, tag: .reply)

        // Post first notification — starts the 300ms throttle timer
        NotificationCenter.default.post(name: .messageDataDidChange, object: id0)

        // Simulate rapid arrivals at 50ms intervals (faster than 300ms debounce)
        try await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: .messageDataDidChange, object: id1)

        // With old debounce, the timer would reset and both updates would be delayed
        // further. With throttle, the first timer is preserved and fires at ~300ms.

        // Wait for throttle window + margin
        try await Task.sleep(for: .milliseconds(400))

        // BOTH messages should have updated in the first throttle flush
        #expect(vm.loadedMessages.first(where: { $0.id == id0 })?.actionTag == .reply)
        #expect(vm.loadedMessages.first(where: { $0.id == id1 })?.actionTag == .reply)
    }

    @Test("Notifications arriving after first flush trigger a second throttle window")
    @MainActor func secondThrottleWindowAfterFlush() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, count: 3, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.loadedMessages.count == 3 else {
            Issue.record("Expected 3 messages, got \(vm.loadedMessages.count)")
            return
        }

        let id0 = ids[0]
        let id1 = ids[1]

        // First batch
        try writeTag(pool, headerId: id0, tag: .archive)
        NotificationCenter.default.post(name: .messageDataDidChange, object: id0)

        try await Task.sleep(for: .milliseconds(450))
        #expect(vm.loadedMessages.first(where: { $0.id == id0 })?.actionTag == .archive)

        // Second batch (after first flush completed — aiBatchTask is nil again)
        try writeTag(pool, headerId: id1, tag: .delete)
        NotificationCenter.default.post(name: .messageDataDidChange, object: id1)

        try await Task.sleep(for: .milliseconds(450))
        #expect(vm.loadedMessages.first(where: { $0.id == id1 })?.actionTag == .delete)
    }

    // MARK: - Interaction Gating

    @Test("AI notifications applied even during user interaction (optimistic overlay)")
    @MainActor func appliedDuringInteraction() async throws {
        // Interaction freeze was replaced by optimistic overlay (see 9d32414).
        // Updates are no longer deferred — the overlay guarantees correctness.
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, count: 2, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.loadedMessages.count == 2 else {
            Issue.record("Expected 2 messages, got \(vm.loadedMessages.count)")
            return
        }

        let targetId = ids[0]

        // Begin interaction (now a no-op — overlay handles correctness)
        vm.beginInteraction()

        // Write AI result and post notification
        try writeTag(pool, headerId: targetId, tag: .archive)
        NotificationCenter.default.post(name: .messageDataDidChange, object: targetId)

        // Wait for notification processing
        try await Task.sleep(for: .milliseconds(500))

        // With optimistic overlay, updates apply immediately regardless of interaction
        #expect(vm.loadedMessages.first(where: { $0.id == targetId })?.actionTag == .archive)

        vm.endInteraction()
    }

    @Test("Notification for message not in loaded page is silently skipped")
    @MainActor func notificationForUnloadedMessageSkipped() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        _ = try insertMessages(pool, count: 2, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.loadedMessages.count == 2 else {
            Issue.record("Expected 2 messages, got \(vm.loadedMessages.count)")
            return
        }

        // Post notification for a message ID that doesn't exist in loaded page
        NotificationCenter.default.post(name: .messageDataDidChange, object: "nonexistent-id")

        try await Task.sleep(for: .milliseconds(450))

        #expect(vm.loadedMessages.count == 2)
        #expect(vm.loadedMessages.allSatisfy { $0.actionTag == nil })
    }

    // MARK: - Snapshot Freshness

    @Test("flushAIBatch reads fresh data from GRDB — not stale snapshot")
    @MainActor func flushReadsFreshGRDB() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, count: 1, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 message, got \(vm.loadedMessages.count)")
            return
        }

        let targetId = ids[0]
        try writeTagAndSummary(pool, headerId: targetId, tag: .reply, summary: "AI-generated summary")

        NotificationCenter.default.post(name: .messageDataDidChange, object: targetId)

        try await Task.sleep(for: .milliseconds(450))

        let updated = vm.loadedMessages.first(where: { $0.id == targetId })
        #expect(updated?.actionTag == .reply)
        #expect(updated?.summaryBlurb == "AI-generated summary")
    }
}
