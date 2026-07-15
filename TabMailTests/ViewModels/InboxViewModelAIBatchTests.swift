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
@Suite("InboxViewModel AI Batch Throttle", .serialized, .processGlobalState)
struct InboxViewModelAIBatchTests {

    /// Wait (bounded) for a throttled AI flush to LAND, instead of betting a fixed sleep
    /// against a wall clock.
    ///
    /// `flushAIBatch` is a 300ms THROTTLE plus a GRDB read. These tests used to sleep 450ms
    /// and assert — a 150ms margin. In the full suite (1000+ suites in parallel) the
    /// simulator's I/O stalls badly (the run log fills with `disk I/O error`), the flush
    /// misses the budget, and the suite goes red for reasons that have nothing to do with
    /// the code under test. That flake devalues every green run, so it is worse than the
    /// time it costs: it was observed twice in this audit.
    ///
    /// Polling asserts exactly the same thing — the flush DOES land — without pinning it to
    /// a stopwatch. It cannot mask a regression: if the flush never lands, the condition
    /// never holds, the deadline expires, and the #expect that follows still fails.
    ///
    /// Deliberately NOT used for ABSENCE assertions (`notificationForUnloadedMessageSkipped`
    /// asserts nothing changed): polling for "still nothing" would return instantly and pass
    /// vacuously. Those keep a fixed sleep, and load can only delay a flush, so they cannot
    /// flake in the failing direction.
    @MainActor
    private func waitForFlush(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

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
            let f = folder
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

    // MARK: - Snippet semantics

    /// Insert one header with an explicit snippet value; returns its header id.
    /// Sync helper (matches `insertMessages`) so GRDB's SYNC overloads are chosen —
    /// an inline call in an async test body selects the async overloads instead.
    @MainActor
    private func insertHeader(
        _ pool: DatabasePool, messageId: String, folderId: String, snippet: String
    ) throws -> String {
        let header = MessageHeader(
            messageId: messageId, subject: "Push", from: "s@example.com",
            fromAddress: "s@example.com", to: "test@example.com", date: Date(),
            snippet: snippet, folderId: folderId, accountId: "acc1",
            folderPath: "INBOX", isInInbox: true
        )
        try pool.writeWithoutTransaction { db in
            var h = header
            h.headerComplete = true
            try h.insert(db)
        }
        let stored = try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)
        }
        return stored?.id ?? ""
    }

    /// Write snippet + actionTag for a message (merge-phase-2 style).
    @MainActor
    private func writeSnippetAndTag(
        _ pool: DatabasePool, headerId: String, snippet: String, tag: ActionTag
    ) throws {
        try pool.writeWithoutTransaction { db in
            guard var msg = try MessageHeader.fetchOne(db, key: headerId) else { return }
            msg.snippet = snippet
            msg.actionTag = tag
            msg.tagSortOrder = tag.sortOrder
            try msg.save(db)
        }
    }

    @Test("flushAIBatch: fresh DB snippet WINS over a stale empty in-memory one (IMAP-push regression)")
    @MainActor func freshSnippetWins() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        // Header lands with an EMPTY snippet (an IMAP push: the NSE stages
        // snippet=""); phase-2 later computes and writes the real snippet.
        let targetId = try insertHeader(pool, messageId: "2000", folderId: folder.id, snippet: "")

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 message, got \(vm.loadedMessages.count)"); return
        }
        #expect(vm.loadedMessages[0].snippet.isEmpty)

        // Merge phase-2 writes snippet + action; AI completion fires the signal.
        try writeSnippetAndTag(pool, headerId: targetId, snippet: "The real snippet", tag: .reply)
        NotificationCenter.default.post(name: .messageDataDidChange, object: targetId)
        await waitForFlush { vm.loadedMessages.first(where: { $0.id == targetId })?.actionTag == .reply }

        let row = vm.loadedMessages.first(where: { $0.id == targetId })
        #expect(row?.actionTag == .reply)
        // The old unconditional "preserve" stomped this back to "" — the row
        // showed the action tag with no snippet until the terminal reload.
        #expect(row?.snippet == "The real snippet")
    }

    @Test("flushAIBatch: in-memory snippet kept when the fresh DB header has none")
    @MainActor func inMemorySnippetKeptWhenDBEmpty() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        // Row loads with a snippet (stands in for a SnippetLoader in-place fill —
        // in-memory state ahead of the DB), then the DB header's snippet is
        // cleared while AI lands. The flush must keep the in-memory value.
        let targetId = try insertHeader(pool, messageId: "2001", folderId: folder.id, snippet: "Loader-filled")

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 message, got \(vm.loadedMessages.count)"); return
        }
        #expect(vm.loadedMessages[0].snippet == "Loader-filled")

        // AI lands but the fresh DB header carries NO snippet.
        try writeSnippetAndTag(pool, headerId: targetId, snippet: "", tag: .archive)
        NotificationCenter.default.post(name: .messageDataDidChange, object: targetId)
        await waitForFlush { vm.loadedMessages.first(where: { $0.id == targetId })?.actionTag == .archive }

        let row = vm.loadedMessages.first(where: { $0.id == targetId })
        #expect(row?.actionTag == .archive)
        #expect(row?.snippet == "Loader-filled")
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

        await waitForFlush { vm.loadedMessages.first(where: { $0.id == targetId })?.actionTag == .archive }

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

        // A SUSTAINED burst of arrivals faster than the 300ms window — this is the scenario
        // the throttle exists for (the suite header: "32 concurrent LLM workers completing
        // faster than 300ms would starve the flush indefinitely").
        //
        // Two notifications 50ms apart CANNOT tell a throttle from a debounce: once arrivals
        // stop, even a debounced timer fires 300ms later and both ids land. The starvation
        // only shows while arrivals KEEP COMING — a debounce re-arms on each one and never
        // fires, a throttle keeps its first timer and fires at ~300ms. So keep posting for
        // several seconds and require the flush to land WHILE the burst is still running.
        let burst = Task { @MainActor in
            for _ in 0..<100 {
                NotificationCenter.default.post(name: .messageDataDidChange, object: id0)
                NotificationCenter.default.post(name: .messageDataDidChange, object: id1)
                try? await Task.sleep(for: .milliseconds(50))   // 100 × 50ms ≈ 5s of arrivals
            }
        }
        defer { burst.cancel() }

        // 3s is ~10× the throttle window (generous under full-suite load) but well inside the
        // ~5s burst, so a debounce — which cannot fire until 300ms AFTER the last arrival —
        // fails here, while a throttle flushes at ~300ms and passes.
        await waitForFlush(timeout: .seconds(3)) {
            vm.loadedMessages.first(where: { $0.id == id0 })?.actionTag == .reply
                && vm.loadedMessages.first(where: { $0.id == id1 })?.actionTag == .reply
        }

        // BOTH messages updated in a flush that fired DURING the burst — not starved.
        #expect(vm.loadedMessages.first(where: { $0.id == id0 })?.actionTag == .reply,
                "the throttle must flush DURING a sustained burst — a debounce would re-arm on every arrival and starve indefinitely")
        #expect(vm.loadedMessages.first(where: { $0.id == id1 })?.actionTag == .reply,
                "and both ids coalesce into that one flush")
        burst.cancel()
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

        await waitForFlush { vm.loadedMessages.first(where: { $0.id == id0 })?.actionTag == .archive }
        #expect(vm.loadedMessages.first(where: { $0.id == id0 })?.actionTag == .archive)

        // Second batch (after first flush completed — aiBatchTask is nil again)
        try writeTag(pool, headerId: id1, tag: .delete)
        NotificationCenter.default.post(name: .messageDataDidChange, object: id1)

        await waitForFlush { vm.loadedMessages.first(where: { $0.id == id1 })?.actionTag == .delete }
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
        await waitForFlush { vm.loadedMessages.first(where: { $0.id == targetId })?.actionTag == .archive }

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

    // MARK: - Overlay Pin (ADR-IOS-058 round-11 lens B)

    @Test("flushAIBatch: pending overlay state survives the repaint, and actionTag re-derives tagSortOrder, while fresh DB data still lands")
    @MainActor func overlayPendingStateSurvivesAIRepaint() async throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
            AccountManager.shared.intentionJournal.resetForTesting()
        }
        AccountManager.shared.intentionJournal.resetForTesting()

        // Durable inbox header: unread, unflagged, in-inbox, untagged, no AI
        // fields yet — every seeded overlay field below DIFFERS from the
        // durable row, so a field-scoped reversion of the overlay block is
        // discriminated per field.
        let targetId = try insertHeader(pool, messageId: "2002", folderId: folder.id, snippet: "")

        let vm = InboxViewModel(folders: [folder])
        vm.start()
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 message, got \(vm.loadedMessages.count)"); return
        }
        #expect(vm.loadedMessages[0].isRead == false)
        #expect(vm.loadedMessages[0].isFlagged == false)
        #expect(vm.loadedMessages[0].isInInbox == true)
        #expect(vm.loadedMessages[0].actionTag == nil)
        #expect(vm.loadedMessages[0].tagSortOrder == 99)

        // A gesture's intention is pending (journal display entry) covering
        // ALL FOUR fields the flushAIBatch overlay block applies: mark-read +
        // flag + tag set + inbox exit. The fold has NOT drained — the durable
        // row still says unread/unflagged/in-inbox, and will say a DIFFERENT
        // tag below.
        AccountManager.shared.intentionJournal.seedDisplayForTesting(
            id: targetId,
            mutation: .init(isRead: true, isInInbox: false, isFlagged: true, actionTag: .some(ActionTag.delete))
        )

        // AI/backfill result lands out-of-band in the durable row (snippet +
        // a stale tag vs. the pending intent), then the repaint signal fires.
        try writeSnippetAndTag(pool, headerId: targetId, snippet: "The AI snippet", tag: .reply)
        NotificationCenter.default.post(name: .messageDataDidChange, object: targetId)
        // Wait for the repaint to have applied BOTH sources. The snippet ALONE is too weak a
        // witness — the row is observable carrying fresh DB data before the overlay lands on
        // it, so polling on the snippet returns inside that gap and asserts too early (this
        // is what turned the test red when it was first converted off its fixed sleep).
        // Requiring both is still un-vacuous: the snippet starts EMPTY and the durable tag is
        // `.reply`, so neither half holds at t=0 — and if a repaint ever STOMPED the overlay
        // (the regression this test exists to catch) the condition would never hold, the
        // deadline would expire, and the assertions below would still fail.
        await waitForFlush {
            let row = vm.loadedMessages.first(where: { $0.id == targetId })
            return row?.snippet == "The AI snippet" && row?.actionTag == .delete
        }

        let row = vm.loadedMessages.first(where: { $0.id == targetId })
        // The overlay's pending state must survive the full-snapshot
        // replacement (InboxViewModel.flushAIBatch overlay application) —
        // deleting that block (or any single field line in it) would stomp
        // the visualized gesture back to DB truth on every AI/backfill
        // repaint until the fold drains. All 4 applied fields pinned.
        #expect(row?.isRead == true)
        #expect(row?.isFlagged == true)
        #expect(row?.isInInbox == false)
        #expect(row?.actionTag == .delete)
        #expect(row?.tagSortOrder == ActionTag.delete.sortOrder,
                "tagSortOrder is derived from the overlaid actionTag; the stale durable .reply order must not survive")
        // … AND the fresh DB data still lands: the repaint merges both
        // sources; neither stomps the other.
        #expect(row?.snippet == "The AI snippet")
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

        await waitForFlush { vm.loadedMessages.first(where: { $0.id == targetId })?.actionTag == .reply }

        let updated = vm.loadedMessages.first(where: { $0.id == targetId })
        #expect(updated?.actionTag == .reply)
        #expect(updated?.summaryBlurb == "AI-generated summary")
    }
}
