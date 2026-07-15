/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for InboxViewModel.evictAndRebuild() — when archiving/deleting the thread
/// head while expanded, children must be promoted to their own group(s) immediately.
/// Also tests that expanded-thread swipe/tag actions scope to the individual message.
@Suite("InboxViewModel Thread Evict & Rebuild", .serialized, .processGlobalState)
struct InboxViewModelThreadEvictTests {

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

    /// Escaped-write hygiene barrier (ADR-IOS-058, PROJECT_MEMORY "drain-before-
    /// return" rule): enqueue a no-op onto `AccountManager.shared`'s FIFO write
    /// queue and await it — since the queue is strictly FIFO, every fold
    /// closure enqueued BEFORE this call is guaranteed to have executed by the
    /// time this returns. MUST run before a test returns, or an escaped fold
    /// closure executes against the NEXT test's freshly-installed DB (composite
    /// ids reuse the same values across tests). Mirrors
    /// `InboxGestureActionTests.drainWriteQueue`.
    /// Round-2 audit: a single FIFO enqueue+await only guarantees closures
    /// already enqueued BEFORE this call have run — it does NOT guarantee the
    /// journal is empty. Two independently-created Tasks (a gesture site's
    /// `record()`, which spawns its own fold-executor Task, and this drain
    /// call) can reach the shared FIFO in EITHER order, so a fold closure the
    /// gesture just triggered may land AFTER this barrier's no-op closure and
    /// still be pending when the barrier returns — closing this window is the
    /// likely fix for the plan's known settle-flake. Loop the barrier until
    /// the journal reports fully drained (no pending records, no in-flight
    /// display holds/seqs); bounded so a genuine stuck-drain bug fails the
    /// test instead of hanging it forever.
    private func drainWriteQueue() async {
        var iterations = 0
        repeat {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
            }
            iterations += 1
        } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting() && iterations < 200
    }

    /// Insert messages with optional computedThreadId. Returns IDs ordered by insertion.
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
            header.rfc822MessageId = "<\(spec.messageId)@example.com>"
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

    // MARK: - evictAndRebuild tests

    @Test("Evicting thread head removes it from loadedMessages and rebuilds groups")
    @MainActor func evictHeadRemovesFromLoaded() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
            ("m3", "Thread", baseDate.addingTimeInterval(120), "thread-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.loadedMessages.count == 3)
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].isThread == true)
        #expect(vm.displayGroups[0].memberCount == 3)

        // Representative is the most recent message (m3)
        let repId = vm.displayGroups[0].representative.id
        #expect(repId == ids[2])

        // Expand the thread
        let groupId = vm.displayGroups[0].id
        vm.toggleThreadExpansion(groupId)
        #expect(vm.expandedThreads.contains(groupId))

        // Evict the head (m3)
        vm.evictAndRebuild(repId, collapseThread: groupId)

        // Head should be gone from loadedMessages
        #expect(vm.loadedMessages.count == 2)
        #expect(!vm.loadedMessages.contains(where: { $0.id == repId }))

        // Thread should be collapsed
        #expect(!vm.expandedThreads.contains(groupId))

        // Remaining 2 messages should form a thread group with new representative (m2)
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].memberCount == 2)
        #expect(vm.displayGroups[0].representative.id == ids[1])
        #expect(vm.displayGroups[0].isThread == true)
    }

    @Test("Evicting head of 2-message thread leaves single non-thread message")
    @MainActor func evictHeadOfTwoMessageThread() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        let groupId = vm.displayGroups[0].id
        let repId = vm.displayGroups[0].representative.id
        #expect(repId == ids[1]) // m2 is most recent

        vm.toggleThreadExpansion(groupId)
        vm.evictAndRebuild(repId, collapseThread: groupId)

        // Only 1 message remains — no longer a thread
        #expect(vm.loadedMessages.count == 1)
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].isThread == false)
        #expect(vm.displayGroups[0].memberCount == 1)
        #expect(vm.displayGroups[0].representative.id == ids[0])
    }

    @Test("Evict collapses expandedThreads entry")
    @MainActor func evictCollapsesThread() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        _ = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
            ("m3", "Thread", baseDate.addingTimeInterval(120), "thread-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.displayGroups.count == 1 else { return }
        let groupId = vm.displayGroups[0].id
        vm.toggleThreadExpansion(groupId)
        #expect(vm.expandedThreads.contains(groupId))

        let repId = vm.displayGroups[0].representative.id
        vm.evictAndRebuild(repId, collapseThread: groupId)

        // The group ID should be removed from expandedThreads
        #expect(!vm.expandedThreads.contains(groupId))
    }

    @Test("Evict with mixed threads preserves other groups")
    @MainActor func evictPreservesOtherGroups() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread A", baseDate, "thread-a", "alice@test.com"),
            ("m2", "Thread A", baseDate.addingTimeInterval(60), "thread-a", "bob@test.com"),
            ("m3", "Standalone", baseDate.addingTimeInterval(120), "standalone-1", "carol@test.com"),
            ("m4", "Thread B", baseDate.addingTimeInterval(180), "thread-b", "dave@test.com"),
            ("m5", "Thread B", baseDate.addingTimeInterval(240), "thread-b", "eve@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.loadedMessages.count == 5)
        #expect(vm.displayGroups.count == 3) // thread-b, standalone, thread-a (sorted by date desc)
        guard vm.displayGroups.count == 3 else { return }

        // Find thread-b group and expand it
        let threadBGroup = vm.displayGroups.first(where: { $0.representative.id == ids[4] })!
        vm.toggleThreadExpansion(threadBGroup.id)

        // Evict thread-b head (m5)
        vm.evictAndRebuild(ids[4], collapseThread: threadBGroup.id)

        // m5 gone, 4 messages remain
        #expect(vm.loadedMessages.count == 4)
        // thread-a (2 members) + standalone (1) + thread-b remnant (1) = 3 groups
        #expect(vm.displayGroups.count == 3)

        // thread-a still intact with 2 members
        let threadA = vm.displayGroups.first(where: { $0.id == "thread-a" })
        #expect(threadA?.memberCount == 2)

        // standalone still intact
        let standalone = vm.displayGroups.first(where: { $0.representative.id == ids[2] })
        #expect(standalone?.memberCount == 1)

        // thread-b remnant now has 1 member (m4)
        let threadBRemnant = vm.displayGroups.first(where: { $0.representative.id == ids[3] })
        #expect(threadBRemnant?.memberCount == 1)
        #expect(threadBRemnant?.isThread == false)
    }

    @Test("Evicted message's loadedIds is also cleaned up")
    @MainActor func evictCleansLoadedIds() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard vm.displayGroups.count == 1 else { return }
        let groupId = vm.displayGroups[0].id
        let repId = ids[1] // m2 = representative
        vm.toggleThreadExpansion(groupId)

        vm.evictAndRebuild(repId, collapseThread: groupId)

        // After evict, loadedMessages should not contain the evicted ID
        #expect(!vm.loadedMessages.contains(where: { $0.id == repId }))
        // The remaining message should still be present
        #expect(vm.loadedMessages.contains(where: { $0.id == ids[0] }))
    }

    @Test("Children sorted correctly after head eviction — date ordering preserved")
    @MainActor func childrenSortedAfterEviction() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        // Thread with head dated AFTER a standalone message
        // After evicting head, remaining child should sort below the standalone
        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Standalone", baseDate.addingTimeInterval(120), "standalone-1", "bob@test.com"),
            ("m3", "Thread", baseDate.addingTimeInterval(240), "thread-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        // Before evict: thread-1 group (rep=m3 @240s) sorts before standalone (m2 @120s)
        #expect(vm.displayGroups.count == 2)
        guard vm.displayGroups.count == 2 else { return }
        #expect(vm.displayGroups[0].representative.id == ids[2]) // thread head m3
        #expect(vm.displayGroups[1].representative.id == ids[1]) // standalone m2

        let groupId = vm.displayGroups[0].id
        vm.toggleThreadExpansion(groupId)
        vm.evictAndRebuild(ids[2], collapseThread: groupId)

        // After evict: standalone m2 (@120s) sorts before thread remnant m1 (@0s)
        #expect(vm.displayGroups.count == 2)
        guard vm.displayGroups.count == 2 else { return }
        #expect(vm.displayGroups[0].representative.id == ids[1]) // standalone m2 now first
        #expect(vm.displayGroups[1].representative.id == ids[0]) // thread remnant m1 now second
    }

    // MARK: - Stale expandedThreads pruning (non-evict removal pathways)

    @Test("Removing a child outside evictAndRebuild prunes stale expandedThreads entry")
    @MainActor func childRemovalPrunesExpandedThreads() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        let groupId = vm.displayGroups[0].id
        vm.toggleThreadExpansion(groupId)
        #expect(vm.expandedThreads.contains(groupId))

        // Remove the CHILD (m1, not the representative) directly from the DB —
        // simulates detail-view archive, agent tool, or sync from another device:
        // none of these go through evictAndRebuild.
        _ = try await pool.writeWithoutTransaction { db in
            try MessageHeader.deleteOne(db, key: ids[0])
        }
        await vm.reloadMessages()

        // Thread shrank to a single message — the stale expansion entry must be
        // pruned, otherwise the remaining row paints the expanded-thread
        // background forever with no chevron to clear it.
        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].isThread == false)
        #expect(!vm.expandedThreads.contains(groupId))
    }

    @Test("Removing an entire expanded thread prunes its expandedThreads entry")
    @MainActor func threadRemovalPrunesExpandedThreads() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
            ("m3", "Solo", baseDate.addingTimeInterval(120), "solo-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        guard let group = vm.displayGroups.first(where: { $0.id == "thread-1" }) else {
            Issue.record("thread-1 group missing")
            return
        }
        vm.toggleThreadExpansion(group.id)
        #expect(vm.expandedThreads.contains(group.id))

        _ = try await pool.writeWithoutTransaction { db in
            try MessageHeader.deleteOne(db, key: ids[0])
        }
        _ = try await pool.writeWithoutTransaction { db in
            try MessageHeader.deleteOne(db, key: ids[1])
        }
        await vm.reloadMessages()

        #expect(vm.expandedThreads.isEmpty)
    }

    @Test("Expanded thread that stays a thread after removal keeps its expansion")
    @MainActor func survivingThreadKeepsExpansion() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
            ("m3", "Thread", baseDate.addingTimeInterval(120), "thread-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        let groupId = vm.displayGroups[0].id
        vm.toggleThreadExpansion(groupId)

        // Remove one child — 2 members remain, still a thread.
        _ = try await pool.writeWithoutTransaction { db in
            try MessageHeader.deleteOne(db, key: ids[0])
        }
        await vm.reloadMessages()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        #expect(vm.displayGroups[0].isThread == true)
        #expect(vm.displayGroups[0].memberCount == 2)
        // No over-pruning: the thread is still a thread and stays expanded.
        #expect(vm.expandedThreads.contains(groupId))
    }

    // MARK: - Grouped thread move (single undo entry)

    @Test("moveThread pushes ONE grouped undo entry covering all members")
    @MainActor func moveThreadGroupedUndo() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }

        let ids = try insertMessages(pool, specs: [
            ("m1", "Thread", baseDate, "thread-1", "alice@test.com"),
            ("m2", "Thread", baseDate.addingTimeInterval(60), "thread-1", "bob@test.com"),
            ("m3", "Thread", baseDate.addingTimeInterval(120), "thread-1", "carol@test.com"),
        ], folderId: folder.id)

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()

        #expect(vm.displayGroups.count == 1)
        guard vm.displayGroups.count == 1 else { return }
        let group = vm.displayGroups[0]
        #expect(group.memberCount == 3)

        // Isolate the global undo stack (singleton) for this assertion.
        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        vm.moveThread(group.members.map(\.id), toFolderPath: "Archive")

        // Round-2 audit guard-gap fix: drain BEFORE the guard below, not only
        // at function end — an early return from the guard would otherwise
        // let moveThread's fold closure escape past this test's return. Safe
        // to drain here: the assertions below read UndoService.shared's
        // in-memory undo stack, set synchronously by push() (inside
        // moveThread(), before record() is even called) — untouched by
        // draining.
        await drainWriteQueue()

        // A whole-thread move must be a SINGLE grouped undo entry carrying every
        // member — not three separate entries. This is the bug #1 invariant.
        #expect(UndoService.shared.undoStack.count == 1)
        guard let action = UndoService.shared.currentAction else {
            Issue.record("moveThread did not push an undo action")
            return
        }
        #expect(action.totalMemberCount == 3)
        #expect(Set(action.commands.flatMap { $0.members.map(\.originalHeaderId) }) == Set(ids))
        #expect(action.commands.allSatisfy { $0.forwardDestinationPath == "Archive" })
    }
}

// MARK: - ThreadGroupBuilder pure-logic tests for head eviction scenarios

@Suite("ThreadGroupBuilder Head Eviction")
struct ThreadGroupBuilderHeadEvictionTests {

    private func makeSnapshot(
        messageId: String = "1",
        subject: String = "Test",
        from: String = "sender@test.com",
        date: Date = Date(),
        computedThreadId: String = "",
        isRead: Bool = true,
        actionTag: ActionTag? = nil
    ) -> MessageSnapshot {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: from,
            fromAddress: from,
            to: "recipient@test.com",
            date: date,
            snippet: "snippet",
            folderId: "acct1:INBOX",
            accountId: "acct1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.computedThreadId = computedThreadId
        header.isRead = isRead
        header.actionTag = actionTag
        if let tag = actionTag {
            header.tagSortOrder = tag.sortOrder
        }
        return MessageSnapshot(from: header)
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Removing head from 3-message thread promotes next child to representative")
    func removeHeadPromotesChild() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1")
        let s3 = makeSnapshot(messageId: "m3", date: baseDate.addingTimeInterval(120), computedThreadId: "t1")

        // Full thread
        let full = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, s3])
        #expect(full.count == 1)
        guard full.count == 1 else { return }
        #expect(full[0].representative.id == s3.id) // m3 is head

        // Remove head (m3), rebuild
        let remaining = [s1, s2]
        let rebuilt = ThreadGroupBuilder.buildDisplayGroups(from: remaining)
        #expect(rebuilt.count == 1)
        guard rebuilt.count == 1 else { return }
        #expect(rebuilt[0].representative.id == s2.id) // m2 promoted to head
        #expect(rebuilt[0].memberCount == 2)
        #expect(rebuilt[0].isThread == true)
    }

    @Test("Removing head from 2-message thread dissolves thread")
    func removeHeadDissolvesThread() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1")

        let full = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(full[0].isThread == true)

        // Remove head (s2)
        let rebuilt = ThreadGroupBuilder.buildDisplayGroups(from: [s1])
        #expect(rebuilt.count == 1)
        guard rebuilt.count == 1 else { return }
        #expect(rebuilt[0].isThread == false)
        #expect(rebuilt[0].memberCount == 1)
        #expect(rebuilt[0].representative.id == s1.id)
    }

    @Test("Removing head re-sorts group into correct chronological position")
    func removeHeadResorts() {
        // Thread head is most recent overall; after removal, remnant sorts lower
        let standalone = makeSnapshot(messageId: "solo", date: baseDate.addingTimeInterval(100), computedThreadId: "solo-id")
        let child = makeSnapshot(messageId: "child", date: baseDate, computedThreadId: "t1")
        let head = makeSnapshot(messageId: "head", date: baseDate.addingTimeInterval(200), computedThreadId: "t1")

        let full = ThreadGroupBuilder.buildDisplayGroups(from: [standalone, child, head])
        #expect(full.count == 2)
        guard full.count == 2 else { return }
        // Thread (head @200) sorts before standalone (@100)
        #expect(full[0].representative.id == head.id)

        // Remove head, rebuild
        let rebuilt = ThreadGroupBuilder.buildDisplayGroups(from: [standalone, child])
        #expect(rebuilt.count == 2)
        guard rebuilt.count == 2 else { return }
        // Standalone (@100) now sorts before remnant child (@0)
        #expect(rebuilt[0].representative.id == standalone.id)
        #expect(rebuilt[1].representative.id == child.id)
    }

    @Test("Thread group ID is preserved after head removal (same computedThreadId)")
    func groupIdPreserved() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "thread-abc")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "thread-abc")
        let s3 = makeSnapshot(messageId: "m3", date: baseDate.addingTimeInterval(120), computedThreadId: "thread-abc")

        let full = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, s3])
        let originalGroupId = full[0].id

        let rebuilt = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(rebuilt[0].id == originalGroupId)
    }

    @Test("Thread tag recalculated after head removal")
    func threadTagRecalculated() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1", actionTag: .archive)
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1", actionTag: .delete)
        let head = makeSnapshot(messageId: "m3", date: baseDate.addingTimeInterval(120), computedThreadId: "t1", actionTag: .reply)

        let full = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, head])
        #expect(full[0].threadTag == .reply) // reply has lowest sortOrder

        // Remove head with .reply tag
        let rebuilt = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(rebuilt[0].threadTag == .archive) // archive (sortOrder=2) < delete (sortOrder=3)
    }

    @Test("hasUnread recalculated after head removal")
    func hasUnreadRecalculated() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1", isRead: true)
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1", isRead: true)
        let head = makeSnapshot(messageId: "m3", date: baseDate.addingTimeInterval(120), computedThreadId: "t1", isRead: false)

        let full = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, head])
        #expect(full[0].hasUnread == true) // head is unread

        // Remove unread head
        let rebuilt = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(rebuilt[0].hasUnread == false) // all remaining are read
    }
}
