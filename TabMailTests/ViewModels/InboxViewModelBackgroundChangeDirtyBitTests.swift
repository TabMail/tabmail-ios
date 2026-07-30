/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for InboxViewModel's `.inboxDataDidChange` throttle + dirty-bit pattern.
///
/// Race this guards against: a signal arrives during the 500ms throttle sleep OR
/// while `reloadMessages()` is running. The old boolean-gate code silently dropped
/// those mid-window signals — with dirty-bit coalescing, every signal is honored.
///
/// We mutate existing loaded messages (actionTag / isRead) because `reloadMessages`
/// is a diff-reload of the currently-loaded date range. That path is the one the
/// `.inboxDataDidChange` handler invokes, so it's the right surface to assert on.
@Suite("InboxViewModel Background Change Dirty Bit", .serialized)
struct InboxViewModelBackgroundChangeDirtyBitTests {

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
            var f = folder
            try f.insert(db)
        }
        return (pool, folder, dir, previous)
    }

    @MainActor
    private func insertMessages(_ pool: DatabasePool, count: Int, folderId: String) throws -> [String] {
        let now = Date()
        var ids: [String] = []
        for i in 0..<count {
            let header = MessageHeader(
                messageId: "\(4000 + i)",
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
                h.headerComplete = true
                try h.insert(db)
            }
            if let stored = try pool.read({ db in
                try MessageHeader
                    .filter(Column("messageId") == "\(4000 + i)" && Column("accountId") == "acc1")
                    .fetchOne(db)
            }) {
                ids.append(stored.id)
            }
        }
        return ids
    }

    @MainActor
    private func setTag(_ pool: DatabasePool, headerId: String, tag: ActionTag) throws {
        try pool.writeWithoutTransaction { db in
            guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return }
            msg.actionTag = tag
            msg.tagSortOrder = tag.sortOrder
            try msg.save(db)
        }
    }

    // MARK: - Core dirty-bit race

    @Test("Signal arriving during throttle sleep is not lost")
    @MainActor func signalDuringSleepNotLost() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, count: 3, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3)

        // T=0: mutate id[0] and post signal → throttle task starts 500ms sleep.
        try setTag(pool, headerId: ids[0], tag: .archive)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)

        // T=100: mid-sleep mutation + second signal. Old gate dropped this; dirty bit
        // must re-arm the loop so a follow-up reload picks id[1] up.
        try await Task.sleep(for: .milliseconds(100))
        try setTag(pool, headerId: ids[1], tag: .reply)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)

        // Wait for first reload (~500ms) + second reload (~500ms after first completes).
        try await Task.sleep(for: .milliseconds(1200))

        #expect(vm.loadedMessages.first(where: { $0.id == ids[0] })?.actionTag == .archive)
        #expect(vm.loadedMessages.first(where: { $0.id == ids[1] })?.actionTag == .reply)
    }

    @Test("Signal arriving after first reload triggers a follow-up reload")
    @MainActor func signalAfterReloadTriggersFollowUp() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, count: 3, folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3)

        // First cycle.
        try setTag(pool, headerId: ids[0], tag: .archive)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)

        // After first reload fires (~500ms), post another signal to start a fresh cycle.
        try await Task.sleep(for: .milliseconds(700))
        #expect(vm.loadedMessages.first(where: { $0.id == ids[0] })?.actionTag == .archive)

        try setTag(pool, headerId: ids[1], tag: .delete)
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)

        try await Task.sleep(for: .milliseconds(700))
        #expect(vm.loadedMessages.first(where: { $0.id == ids[1] })?.actionTag == .delete)
    }

    @Test("Burst of signals coalesces — all mutations visible after throttle")
    @MainActor func burstCoalesces() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, count: 5, folderId: folder.id)
        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 5)

        // 5 rapid mutations + signals within the throttle window.
        for (i, id) in ids.enumerated() {
            try setTag(pool, headerId: id, tag: i % 2 == 0 ? .archive : .reply)
            NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(40))
        }

        // Wait past throttle + one follow-up cycle.
        try await Task.sleep(for: .milliseconds(1200))

        // Every mutation must be visible — none silently dropped.
        for (i, id) in ids.enumerated() {
            let expected: ActionTag = i % 2 == 0 ? .archive : .reply
            #expect(vm.loadedMessages.first(where: { $0.id == id })?.actionTag == expected)
        }
    }

    // MARK: - Immediate (privileged NSE-merge) bypass

    @Test("Immediate-flagged signal reloads at once, bypassing the 500ms debounce")
    @MainActor func immediateSignalBypassesDebounce() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, count: 3, folderId: folder.id)
        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3)

        // Mutate, then post WITH the privileged immediate flag (what the NSE→inbox
        // merge emits at the end of `performMerge`).
        try setTag(pool, headerId: ids[0], tag: .archive)
        NotificationCenter.default.post(
            name: .inboxDataDidChange, object: nil,
            userInfo: [Notification.Name.inboxReloadImmediateKey: true]
        )

        // The change must be visible WELL under the 500ms debounce floor. If a
        // regression routed the immediate signal through the throttle, the tag
        // would not be applied yet at 250ms.
        try await Task.sleep(for: .milliseconds(250))
        #expect(vm.loadedMessages.first(where: { $0.id == ids[0] })?.actionTag == .archive)
    }

    @Test("Immediate signal arriving during an in-flight reload is not lost")
    @MainActor func immediateDuringReloadNotLost() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, count: 3, folderId: folder.id)
        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 3)

        // Two immediate signals back-to-back: the first starts a reload, the second
        // arrives while it is (potentially) still in flight. The single-flight
        // `runReloadCoalesced` must re-run so the second mutation is never dropped.
        try setTag(pool, headerId: ids[0], tag: .archive)
        NotificationCenter.default.post(
            name: .inboxDataDidChange, object: nil,
            userInfo: [Notification.Name.inboxReloadImmediateKey: true]
        )
        try setTag(pool, headerId: ids[1], tag: .reply)
        NotificationCenter.default.post(
            name: .inboxDataDidChange, object: nil,
            userInfo: [Notification.Name.inboxReloadImmediateKey: true]
        )

        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.loadedMessages.first(where: { $0.id == ids[0] })?.actionTag == .archive)
        #expect(vm.loadedMessages.first(where: { $0.id == ids[1] })?.actionTag == .reply)
    }

    @Test("Idle state — no signal means no unnecessary reload")
    @MainActor func idleStateNoReload() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let ids = try insertMessages(pool, count: 2, folderId: folder.id)
        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        #expect(vm.loadedMessages.count == 2)

        // No signals posted. Mutate the DB — without a signal, the throttle loop
        // must NOT spontaneously run; loadedMessages stays as-is.
        try setTag(pool, headerId: ids[0], tag: .archive)
        try await Task.sleep(for: .milliseconds(700))
        #expect(vm.loadedMessages.first(where: { $0.id == ids[0] })?.actionTag == nil)

        // Now post a signal; reload runs within the window.
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(vm.loadedMessages.first(where: { $0.id == ids[0] })?.actionTag == .archive)
    }
}
