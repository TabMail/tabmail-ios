/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
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
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        let (path, q) = try makeStagingFile(in: dir)

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
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        let (path, q) = try makeStagingFile(in: dir)

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
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        let (path, q) = try makeStagingFile(in: dir)

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

    /// Simulator measurement: a clean header-only merge (no AI, no contention)
    /// surfaces the message in a handful of ms — the whole point of gradual
    /// staging is that visibility is NOT blocked behind the NSE's ~6-10s of AI.
    /// Prints the measured time; asserts a generous ceiling for CI jitter.
    @Test("Measurement: header-only merge surfaces the message fast (not blocked on AI)")
    func headerOnlyMergeIsFast() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        let (path, q) = try makeStagingFile(in: dir)
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
