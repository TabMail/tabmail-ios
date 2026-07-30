/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Coverage for the STAGE-MEMO SKIP added to `NSEDataBridge.performMerge`
/// (2026-07-09): a merge TRIGGER unrelated to a particular row (a push for a
/// different message, syncStartup, foreground, a notif-tap gate) re-reads the
/// same staged content for every KEPT gradual row on every wake. Without a way
/// to tell "unchanged since we last durably wrote it" apart from "just
/// arrived", every such trigger redid BOTH write phases for a row whose
/// staged content hadn't advanced at all.
///
/// The fix is a per-row `NSEDataBridge.StageKey` (presence signature: body /
/// summary / action / notified / aiCompleted) plus an in-process memo
/// (`stageMemo`) of the key each staging row last had durably written. A
/// memo-identical row is durability-VERIFIED (its `messageHeader` — and, if it
/// staged a body, `MessageBody` — row still exists) before being skipped, so a
/// row whose durable counterpart vanished (e.g. a sync stale-delete) always
/// self-heals instead of staying invisible.
///
/// Drives the REAL `NSEDataBridge.mergeNSEStagingData` against a real
/// pool-backed `AppDatabase` + a real staging DB, mirroring the harness in
/// `NSEGradualMergeTests`. `stageMemo` is a process-global static — reset it
/// at the start of every test (`resetStageMemoForTesting`) and keep the suite
/// serialized, same as `NSEGradualMergeTests`.
@Suite("NSE merge — stage-memo skip", .serialized)
@MainActor
struct NSEMergeStageMemoTests {

    // MARK: - Harness (mirrors NSEGradualMergeTests)

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

    /// Stage summary only (mirrors `NSEStagingDB.stageSummary`) — NOT terminal,
    /// so the row stays a KEPT gradual row that re-merges until the action
    /// vote lands.
    private func stageSummaryRow(_ q: DatabaseQueue, messageId: String = "msg-1") throws {
        try q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET summaryBlurb = ?, summaryTodos = ?
                WHERE id = ?
                """, arguments: ["A short summary", "todo one", "acc1:\(messageId)"])
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

    @Test("First merge writes durable header+body and records the memo; second merge with UNCHANGED staging skips (no reload signal, row still verified-skipped)")
    func unchangedGradualRowSkipsSecondMerge() async throws {
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
        NSEDataBridge.resetStageMemoForTesting()

        try stageHeaderRow(q)
        try stageBodyRow(q) // gradual: aiCompleted=0, body staged — KEPT after merge

        // ── Merge 1: advances (no memo entry yet) — full write. ──
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let h1 = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        guard h1 != nil else { Issue.record("header not durable after merge 1"); return }
        let bodyCount1 = try await pool.read { try MessageBody.filter(Column("id") == headerId()).fetchCount($0) }
        #expect(bodyCount1 == 1)
        #expect(try stagingRowExists(q) == true) // kept, gradual (aiCompleted=0)

        // Memo recorded the row's durable stage key.
        let stagingId = "acc1:msg-1"
        let memoAfterMerge1 = NSEDataBridge.stageMemoSnapshotForTesting()
        guard let key1 = memoAfterMerge1[stagingId] else {
            Issue.record("stage memo did not record a key after a successful merge")
            return
        }
        #expect(key1 == NSEDataBridge.StageKey(
            hasBody: true, hasSummary: false, hasAction: false, notified: false, aiCompleted: false
        ))

        // ── Merge 2: staging content UNCHANGED — this pass must SKIP the row's
        // write phases entirely (memo hit + durability verified). Observe it via
        // the render-signal contract (`reMergeWithoutChangesEmitsNoSignal` proves
        // the pre-existing value-guards already made a same-content re-write a
        // no-op reload-wise; this proves the memo/skip path leaves that contract
        // intact) AND via the memo staying exactly as merge 1 left it — a
        // verified-skipped row is not written, so nothing re-records it. ──
        let posts = Mutex<Int>(0)
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { _ in posts.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(obs) }

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        #expect(posts.withLock { $0 } == 0, "unchanged staged row must not fire a reload (didMutate stayed false)")
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] == key1)
        #expect(try stagingRowExists(q) == true) // still kept — merge 2 didn't touch it
    }

    @Test("Stage advance: a kept row's memo key updates as content grows, and a terminal advance writes the AI fields")
    func advancingContentIsRewrittenAndMemoTracksIt() async throws {
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
        NSEDataBridge.resetStageMemoForTesting()
        let stagingId = "acc1:msg-1"

        // ── Merge 1: header + body (kept). ──
        try stageHeaderRow(q)
        try stageBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        let keyAfterMerge1 = NSEDataBridge.stageMemoSnapshotForTesting()[stagingId]
        #expect(keyAfterMerge1 == NSEDataBridge.StageKey(
            hasBody: true, hasSummary: false, hasAction: false, notified: false, aiCompleted: false
        ))

        // ── Merge 2: summary arrives, STILL not terminal — an ADVANCE while
        // KEPT. The memo key must change to reflect the new stage (not just
        // "stay recorded"), proving the memo tracks intermediate advances, not
        // only the terminal drop. ──
        try stageSummaryRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let hAfterSummary = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(hAfterSummary?.summaryBlurb == "A short summary")
        #expect(hAfterSummary?.actionTag == nil) // still no action — not terminal
        #expect(try stagingRowExists(q) == true) // still kept

        let keyAfterSummary = NSEDataBridge.stageMemoSnapshotForTesting()[stagingId]
        #expect(keyAfterSummary == NSEDataBridge.StageKey(
            hasBody: true, hasSummary: true, hasAction: false, notified: false, aiCompleted: false
        ))
        #expect(keyAfterSummary != keyAfterMerge1, "an advancing row's memo key must change, not stay pinned to the earlier stage")

        // ── Merge 3: terminal AI lands — writes the action + AI cache, then
        // drains (deletes) the staging row in the SAME pass. ──
        try stageAIRow(q, action: "reply")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let hFinal = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(hFinal?.actionTag == .reply)
        let cacheCount = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageAICache WHERE actionTag = 'reply'") ?? 0
        }
        #expect(cacheCount == 1)

        // Terminal → staging row deleted → no "next merge" to skip, so the
        // memo entry must be gone, not left dangling.
        #expect(try stagingRowExists(q) == false)
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] == nil)
    }

    @Test("Durability-verify fallback: a deleted durable header/body is NOT masked by a memo hit — re-merge recreates it")
    func deletedDurableRowIsRecreatedNotSkipped() async throws {
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
        NSEDataBridge.resetStageMemoForTesting()
        let stagingId = "acc1:msg-1"

        try stageHeaderRow(q)
        try stageBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        guard let keyAfterMerge1 = NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] else {
            Issue.record("expected a memo entry after merge 1")
            return
        }

        // Simulate a sync stale-delete racing the merge: the durable header
        // (and body) vanish from main GRDB WITHOUT the staging row changing at
        // all. Body first (FK), then header — mirrors how a real stale-delete
        // would need to cascade.
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM messageBody WHERE id = ?", arguments: [headerId()])
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [headerId()])
        }
        let goneCheck = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(goneCheck == nil) // sanity: the delete really happened

        // Staging content is UNCHANGED (same header/body stage — a memo HIT).
        // A naive memo skip would leave the message invisible forever; the
        // durability check must catch the missing rows and force a real
        // re-merge instead of trusting the memo.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h != nil, "a deleted durable header must be RECREATED, not silently skipped")
        let bodyCount = try await pool.read { try MessageBody.filter(Column("id") == headerId()).fetchCount($0) }
        #expect(bodyCount == 1, "a deleted durable body must be RECREATED, not silently skipped")

        // The row is still gradual (not terminal) — kept in staging — and the
        // memo is re-recorded (dropped on the failed verification, then
        // re-added on the fresh commit). Same key as before: the STAGED
        // content itself never changed, only its durable counterpart did.
        #expect(try stagingRowExists(q) == true)
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] == keyAfterMerge1)
    }

    @Test("Memo cleanup: once a terminal row drains, its stage-memo entry is removed")
    func memoEntryRemovedOnTerminalDrain() async throws {
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
        NSEDataBridge.resetStageMemoForTesting()
        let stagingId = "acc1:msg-1"

        // Header + body (kept, gradual) — records a memo entry.
        try stageHeaderRow(q)
        try stageBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] != nil)
        #expect(try stagingRowExists(q) == true)

        // Terminal AI lands — this merge both writes the AI fields AND drains
        // (deletes) the staging row in the same pass.
        try stageAIRow(q, action: "archive")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(try stagingRowExists(q) == false)

        // The row has no "next merge" left to skip — its memo entry must be
        // gone, not left dangling (an unbounded leak, or a stale entry that
        // could wrongly memo-match a future re-use of the same identity).
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] == nil)
    }

    @Test("Skip-set cleanup: an abandoned, memo-matched row is drained from staging via the skip path (no GRDB re-write needed)")
    func abandonedSkipSetRowIsDrained() async throws {
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
        NSEDataBridge.resetStageMemoForTesting()
        let stagingId = "acc1:msg-1"

        // Header + body (kept, gradual) — merge 1 writes it for real and
        // records the memo.
        try stageHeaderRow(q)
        try stageBodyRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] != nil)
        #expect(try stagingRowExists(q) == true)

        // Simulate the NSE having died a while ago: backdate `processedAt`
        // past the 60s abandon window WITHOUT touching any staged CONTENT
        // field — the stage key is unchanged, so this is still a memo HIT and
        // gets routed to `skipSet`, not `writeSet`.
        try await q.write { db in
            try db.execute(
                sql: "UPDATE nse_processed_message SET processedAt = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970 - 120, stagingId]
            )
        }

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        // Drained via the skip-set cleanup path (durable + unchanged +
        // abandoned) — no GRDB re-write was needed since the row's durable
        // rows were already confirmed present — and the memo entry drops with
        // it, same as any other terminal/abandoned drain.
        #expect(try stagingRowExists(q) == false)
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()[stagingId] == nil)
        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h != nil) // the durable row itself is untouched, still there
    }
}
