/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// End-to-end coverage for the GRADUAL NSE staging merge (2026-06-25).
///
/// The NSE now stages a message in stages — header → body → summary → action —
/// flipping `populated=1` at the header stage so the main app's merge can SHOW
/// the message before AI completes (instead of all-or-nothing on `aiCompleted`).
/// `mergeNSEStagingData` must therefore:
///   • surface a header-only (`populated=1, aiCompleted=0`) row and KEEP it in
///     staging so the next wake picks up body + AI,
///   • apply body and summary incrementally on the existing header,
///   • DELETE the staging row only once AI completes (terminal) or the row is
///     abandoned (NSE died — `processedAt` older than the stale window).
///
/// Drives the REAL `NSEDataBridge.mergeNSEStagingData` against a real pool-backed
/// `AppDatabase` + a real staging DB built at a temp path via the
/// `stagingPathOverride` test seam (the unit-test host has no App Group entitlement).
@Suite("NSE gradual staging merge", .serialized)
@MainActor
struct NSEGradualMergeTests {

    // MARK: - Harness

    private func makeAppDatabase() throws -> (dir: URL, pool: DatabasePool, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 64
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
        }
        return (dir, pool, previous)
    }

    private func makeStagingFile(in dir: URL) throws -> (path: String, queue: DatabaseQueue) {
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        return (path, try DatabaseQueue(path: path))
    }

    /// Stage 1 — header only (`populated=1, aiCompleted=0`, no body, no AI),
    /// mirroring `NSEStagingDB.stageHeader`.
    private func stageHeaderRow(
        _ q: DatabaseQueue, messageId: String = "msg-1",
        processedAt: Double = Date().timeIntervalSince1970
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, 'acc1', 'user@example.com', 'gmail', ?, ?, 'INBOX',
                        'Subject under test', 'Alice', 'alice@example.com', 'snippet preview', ?,
                        ?, 0, 0, 1)
                """, arguments: [
                    "acc1:\(messageId)", messageId, "rfc-\(messageId)@example.com",
                    Double(1_710_000_000), processedAt
                ])
        }
    }

    /// Stage 2 — attach the rendered body (mirrors `NSEStagingDB.stageBody`).
    private func stageBodyRow(_ q: DatabaseQueue, messageId: String = "msg-1") throws {
        try q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET
                    htmlContent = ?, textContent = ?, hasUnresolvedCIDs = 0
                WHERE id = ?
                """, arguments: ["<p>Hello body</p>", "Hello body", "acc1:\(messageId)"])
        }
    }

    /// Stage a body the NSE rendered but left with UNRESOLVED inline CIDs (an
    /// inline image exceeded the size/count cap so a `cid:` ref remains). Mirrors
    /// `NSEStagingDB.stageBody` with `hasUnresolvedCIDs=1` — such a body is
    /// intentionally NOT cached as `MessageBody` (the main app re-renders on open)
    /// and NOT FTS-body-indexed, yet the header must still become inbox-visible.
    private func stageUnresolvedCIDBodyRow(_ q: DatabaseQueue, messageId: String = "msg-1") throws {
        try q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET
                    htmlContent = ?, textContent = ?, hasUnresolvedCIDs = 1
                WHERE id = ?
                """, arguments: [
                    "<p>Newsletter</p><img src=\"cid:logo@x\">", "Newsletter", "acc1:\(messageId)"
                ])
        }
    }

    /// Stage 3 — terminal AI (summary + action + `aiCompleted=1`), mirroring
    /// `NSEStagingDB.stageSummary` + the terminal `persistProcessedMessage`.
    private func stageAIRow(
        _ q: DatabaseQueue, messageId: String = "msg-1",
        action: String = "reply", notified: Bool = true
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET
                    summaryBlurb = ?, summaryTodos = ?, actionTag = ?,
                    aiCompleted = 1, notified = ?
                WHERE id = ?
                """, arguments: ["A short summary", "todo one", action, notified ? 1 : 0, "acc1:\(messageId)"])
        }
    }

    nonisolated private func headerId(_ messageId: String = "msg-1") -> String {
        MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: messageId)
    }

    private func stagingRowExists(_ q: DatabaseQueue, messageId: String = "msg-1") throws -> Bool {
        try q.read { db in
            try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE id = ?)",
                arguments: ["acc1:\(messageId)"]) ?? false
        }
    }

    // MARK: - Tests

    @Test("Header → body → AI: each stage merges incrementally; row kept until AI, then deleted")
    func gradualLifecycle() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // ── Stage 1: header only ──
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        // Message is VISIBLE (header inserted) with no AI yet.
        let h1 = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        guard let h1 else { Issue.record("header-only stage did not surface the message"); return }
        #expect(h1.subject == "Subject under test")
        #expect(h1.summaryBlurb == nil)
        #expect(h1.actionTag == nil)
        // No body yet.
        let bodyCount1 = try await pool.read { try MessageBody.filter(Column("id") == headerId()).fetchCount($0) }
        #expect(bodyCount1 == 0)
        // Row KEPT (not terminal) so the next wake can pick up body + AI.
        #expect(try stagingRowExists(q) == true)

        // ── Stage 2: body ──
        try stageBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let bodyCount2 = try await pool.read { try MessageBody.filter(Column("id") == headerId()).fetchCount($0) }
        #expect(bodyCount2 == 1)
        let h2 = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h2?.snippet.contains("Hello") == true)  // snippet derived from staged body text
        #expect(h2?.actionTag == nil)                   // still no AI
        #expect(try stagingRowExists(q) == true) // still kept

        // ── Stage 3: terminal AI ──
        try stageAIRow(q, action: "reply")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let h3 = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h3?.summaryBlurb == "A short summary")
        #expect(h3?.actionTag == .reply)
        // AI cache written so the main-app AI queue skips a duplicate LLM call.
        let cacheCount = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageAICache WHERE actionTag = 'reply'") ?? 0
        }
        #expect(cacheCount == 1)
        // Terminal → staging row DELETED.
        #expect(try stagingRowExists(q) == false)
    }

    @Test("Abandoned gradual row (aiCompleted=0, old) is merged then cleaned up")
    func abandonedRowCleanedUp() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // Header-only row whose NSE died long ago (well past the 60s stale window).
        try stageHeaderRow(q, processedAt: Date().timeIntervalSince1970 - 120)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        // Header still surfaced (durable in GRDB)…
        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h != nil)
        // …and the redundant staging row is cleaned up (no forever re-merge).
        #expect(try stagingRowExists(q) == false)
    }

    @Test("Terminal full row merges and deletes in a single pass (regression)")
    func terminalRowInOnePass() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        try stageHeaderRow(q)
        try stageBodyRow(q)
        try stageAIRow(q, action: "archive")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h?.actionTag == .archive)
        #expect(h?.summaryBlurb == "A short summary")
        let bodyCount = try await pool.read { try MessageBody.filter(Column("id") == headerId()).fetchCount($0) }
        #expect(bodyCount == 1)
        #expect(try stagingRowExists(q) == false)
    }

    @Test("Coordinator serializes concurrent merges — terminal row merged exactly once")
    func concurrentMergesSerialized() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // A complete, terminal staged message.
        try stageHeaderRow(q)
        try stageBodyRow(q)
        try stageAIRow(q, action: "archive")

        // Fire several merges concurrently. WITHOUT the coordinator these would
        // each open the staging DB in parallel and fight the busy lock / GRDB
        // writer (the "sometimes slow" contention). WITH it they serialize into
        // one chain: the first pass does the work + deletes the staging row, the
        // rest find it drained and early-return. INSERT OR IGNORE + the
        // deterministic AI-cache key make the end state exactly-once regardless
        // of how many callers raced.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path) }
            }
        }

        let headerCount = try await pool.read {
            try MessageHeader.filter(Column("id") == headerId()).fetchCount($0)
        }
        #expect(headerCount == 1)
        let bodyCount = try await pool.read {
            try MessageBody.filter(Column("id") == headerId()).fetchCount($0)
        }
        #expect(bodyCount == 1)
        let cacheCount = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageAICache") ?? 0
        }
        #expect(cacheCount == 1)
        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h?.actionTag == .archive)
        #expect(try stagingRowExists(q) == false)
    }

    @Test("Header-only / body-less merge makes the message inbox-visible immediately (headerComplete=1, bodyComplete=0)")
    @MainActor func mergeFlipsHeaderCompleteSynchronously() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // Header only — no body text. Header visibility is DECOUPLED from body
        // indexing: the merge FTS-indexes the header and flips headerComplete=1
        // (inbox-visible NOW — the inbox query gates on headerComplete == true)
        // even with no body yet; bodyComplete stays 0 so the body queue fetches it.
        // BEFORE this fix a body-less push stayed headerComplete=0 → invisible until
        // a later recoverIncompleteHeaders pass (the reported 1-3s "minor cases").
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        let afterHeader = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(afterHeader?.headerComplete == true)
        #expect(afterHeader?.bodyComplete == false)

        // Body staged: bodyComplete now ALSO flips. The merge AWAITS the FTS flush
        // (was a detached Task), so both flags MUST be set by the time the merge
        // returns — a regression to a detached flush would leave the freshly-merged
        // message invisible/bodyless until some unrelated later signal.
        try stageBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        let afterBody = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(afterBody?.headerComplete == true)
        #expect(afterBody?.bodyComplete == true)
    }

    @Test("Unresolved-CID body: header becomes visible; no MessageBody cached, bodyComplete stays 0")
    @MainActor func unresolvedCIDMergeStillVisible() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // A pushed inline-image email whose CIDs the NSE could not resolve within
        // its memory budget — it has a body, but the body is neither MessageBody-
        // cached nor FTS-body-indexed, so the OLD merge never flipped
        // headerComplete and the message was invisible for 1-3s. The fix flips
        // headerComplete on the header alone (visible NOW); the body re-fetches on
        // open / via the body queue, which resolves the CIDs.
        try stageHeaderRow(q)
        try stageUnresolvedCIDBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h?.headerComplete == true)   // VISIBLE now (the fix)
        #expect(h?.bodyComplete == false)    // body not claimed → body queue re-fetches + resolves CIDs
        // No MessageBody is cached for an unresolved-CID body (re-render on open).
        let bodyCount = try await pool.read {
            try MessageBody.filter(Column("id") == headerId()).fetchCount($0)
        }
        #expect(bodyCount == 0)

        // The merge now kicks `ActiveBodyQueue.repopulateFromDatabase()` for body-less
        // pushes so a CID/inline-image message is PRECACHED (body fetched proactively)
        // instead of waiting for a cold user open (a recently-arrived inline-image
        // message rendered slowly). Confirm the merged row matches that queue's
        // candidate filter — `BodyFetchQueueRepopulateTests` proves the queue enqueues
        // such rows; this pins the merge's end-state that feeds it. (The actor dispatch
        // itself isn't driven here — it starts a real IMAP body fetch the unit host
        // can't service.)
        let isBodyFetchCandidate = try await pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM messageHeader
                    WHERE id = ? AND headerComplete = 1 AND bodyComplete = 0
                      AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                )
                """, arguments: [headerId()]) ?? false
        }
        #expect(isBodyFetchCandidate, "CID push must match ActiveBodyQueue's precache filter")
    }

    @Test("Two-phase merge emits TWO immediate inboxDataDidChange (header render, then body/AI)")
    @MainActor func mergePostsSingleImmediateSignal() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)
        try stageHeaderRow(q)
        try stageBodyRow(q)
        try stageAIRow(q, action: "archive")

        // Capture every .inboxDataDidChange + whether it carried the immediate flag.
        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { note in
            let imm = (note.userInfo?[Notification.Name.inboxReloadImmediateKey] as? Bool) == true
            posts.withLock { $0.append(imm) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        // The single post is dispatched via Task { @MainActor } at the very end of
        // the merge — let it run.
        try await Task.sleep(for: .milliseconds(200))

        let captured = posts.withLock { $0 }
        // TWO posts by design: the two-phase merge renders the inbox TWICE — phase 1
        // surfaces header + snippet (inbox-visible) OFF the body blob's critical path,
        // then phase 2 lands the body + AI. Both MUST be flagged immediate so the
        // inbox bypasses its 500ms background-coalescing debounce. (Bounded at two —
        // it must NOT spam a post per gradual stage the way the pre-gradual code did.)
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0 == true })
    }

    @Test("Merge posts .nseMergeDidCommit at phase-1 surface and end-of-merge; none on an empty re-merge")
    @MainActor func mergePostsMergeCommitSignal() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)
        try stageHeaderRow(q)
        try stageBodyRow(q)
        try stageAIRow(q, action: "archive")

        let posts = Mutex<Int>(0)
        let obs = NotificationCenter.default.addObserver(
            forName: .nseMergeDidCommit, object: nil, queue: .main
        ) { note in
            // Production posts carry `object: nil`; detail-VM tests in a
            // concurrently-running suite post with a sentinel object — exclude
            // those so this count contract can't flake cross-suite.
            guard note.object == nil else { return }
            posts.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        // Mirrors the two-render contract of `.inboxDataDidChange`: one when
        // phase 1 makes headers + reference junctions queryable (the open
        // detail view can re-run thread detection NOW), one at end-of-merge.
        #expect(posts.withLock { $0 } == 2)

        // The terminal row was deleted from staging — an empty re-merge commits
        // nothing and must not fire the signal (no redundant thread re-runs).
        posts.withLock { $0 = 0 }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0 } == 0)
    }

    @Test("Re-merge with nothing new emits NO extra inboxDataDidChange (no redundant reload)")
    @MainActor func reMergeWithoutChangesEmitsNoSignal() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)
        // Header + body, NO AI → a KEPT gradual row (aiCompleted=0) that survives
        // the first merge in staging and is re-read on the next wake.
        try stageHeaderRow(q)
        try stageBodyRow(q)

        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { _ in posts.withLock { $0.append(true) } }
        defer { NotificationCenter.default.removeObserver(obs) }

        // First merge: surfaces the header + lands the body → at least one render.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0.count } >= 1)

        // Re-merge the SAME staging with nothing new: the header is already visible
        // (flushHeadersToFTS flips 0 rows) and phase 2's total_changes delta is 0
        // (body insert ignored, snippet value-guarded, no AI staged) → ZERO reloads.
        // This is the redundant-reload guard.
        posts.withLock { $0 = [] }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0 }.isEmpty)
    }

    @Test("Re-merge of a summary-staged, action-pending row emits NO extra reload")
    @MainActor func reMergeWithSummaryButNoActionEmitsNoSignal() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)
        try stageHeaderRow(q)
        try stageBodyRow(q)
        // Summary staged but NOT aiCompleted — the NSE stages the summary BEFORE the
        // terminal action vote, so this is a KEPT gradual row that re-merges every
        // wake until the action lands. Re-applying the SAME summary must NOT reload.
        // (await: GRDB picks the async write overload in this async test context.)
        try await q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET summaryBlurb = ?, summaryTodos = ?
                WHERE id = ?
                """, arguments: ["A short summary", "todo one", "acc1:msg-1"])
        }

        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { _ in posts.withLock { $0.append(true) } }
        defer { NotificationCenter.default.removeObserver(obs) }

        // First merge surfaces header + body + summary → at least one render.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0.count } >= 1)

        // Re-merge with nothing new: the value-guarded summary UPDATE is a 0-row
        // no-op, so total_changes doesn't grow → NO redundant reload. (Without the
        // guard the unconditional summary re-write would re-fire the reload.)
        posts.withLock { $0 = [] }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0 }.isEmpty)
    }

    @Test("Re-merge of a re-staged TERMINAL (aiCompleted) row emits NO extra reload")
    @MainActor func reMergeTerminalRowEmitsNoSignal() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)
        try stageHeaderRow(q)
        try stageBodyRow(q)
        try stageAIRow(q, action: "archive")   // terminal: aiCompleted=1 + summary + action

        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { _ in posts.withLock { $0.append(true) } }
        defer { NotificationCenter.default.removeObserver(obs) }

        // First merge writes header + body + summary + action + AI cache, then
        // deletes the terminal staging row.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0.count } >= 1)

        // Simulate a terminal row whose prior staging delete FAILED (or a re-delivery):
        // re-stage the SAME row and re-merge. Everything is already applied → the
        // value-guarded summary/action UPDATEs AND the AI-cache UPSERT are all 0-row
        // no-ops → total_changes doesn't grow → NO redundant reload. (Without the
        // UPSERT guard the AI-cache INSERT OR REPLACE would re-count and reload.)
        try stageHeaderRow(q)
        try stageBodyRow(q)
        try stageAIRow(q, action: "archive")
        posts.withLock { $0 = [] }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0 }.isEmpty)
    }

    /// Simulator measurement: a clean header-only merge (no AI, no contention)
    /// surfaces the message in a handful of ms — the whole point of gradual
    /// staging is that visibility is NOT blocked behind the NSE's ~6-10s of AI.
    /// Prints the measured time; asserts a generous ceiling for CI jitter.
    @Test("Measurement: header-only merge surfaces the message fast (not blocked on AI)")
    func headerOnlyMergeIsFast() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)
        try stageHeaderRow(q)

        let t0 = CFAbsoluteTimeGetCurrent()
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h != nil)                          // visible…
        print("[measure] header-only mergeNSEStagingData surfaced the message in \(Int(ms))ms")
        #expect(ms < 1500)                         // …and fast (no AI wait, no contention)
    }
}
