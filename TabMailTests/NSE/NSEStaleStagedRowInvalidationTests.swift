/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Coverage for the STALE-BY-MOVE DETECTION added to `NSEDataBridge.performMerge`
/// (2026-07-09; boot_logs 3 on-device report): a message the user ARCHIVED
/// in-app REAPPEARED in the inbox LIST later. Root cause: the NSE re-staged the
/// SAME message on a later, unrelated push (`nse_processed_message.folderPath`
/// is push-time truth, still `"INBOX"`); the merge published it via
/// `latestStagedRows` + `.messagesStaged`; `InboxViewModel.insertStagedRows`
/// re-inserted it in-memory. Nothing compared the staged row's folder against
/// the DURABLE header's CURRENT folder — `loadedIds`/identity dedup only scan
/// what's currently displayed (the archived row isn't), and the overlay entry
/// from the original archive was long drained by the time the later push
/// arrived.
///
/// The fix (`NSEDataBridge.detectStaleByMoveRows`) resolves each staged row's
/// existing durable header (same identity lookup phase 1/2 use) and compares
/// its CURRENT `folderId`/`isInInbox` against the staged folder. A mismatch —
/// durable header exists but disagrees — excludes the row from this wake's
/// write phases, deletes its staging row, scrubs it from the already-published
/// `latestStagedRows`/`latestStagedBodies` snapshots, and drops its
/// `stageMemo` entry. PLAN_INBOX_UNIFIED_READ.md §3: the companion
/// `.stagedRowsInvalidated` notification + VM eviction handler
/// (`InboxViewModel.invalidateStagedRows`) that used to tell a VM which
/// already-inserted phantom to evict are GONE — the merge-side scrub above is
/// now sufficient on its own, because `InboxListReader`'s stale-by-move
/// suppression (§2.1a) re-evaluates identity on every reload directly against
/// the durable header, independent of any notification.
///
/// Drives the REAL `NSEDataBridge.mergeNSEStagingData` against a real
/// pool-backed `AppDatabase` + a real staging DB, mirroring the harness in
/// `NSEMergeStageMemoTests`/`NSEGradualMergeTests`. Static globals
/// (`stageMemo`, `latestStagedRows`, `latestStagedBodies`) are process-wide —
/// reset them at the start of every test.
@Suite("NSE merge — stale-by-move staged row invalidation", .serialized)
@MainActor
struct NSEStaleStagedRowInvalidationTests {

    // MARK: - Harness (mirrors NSEMergeStageMemoTests)

    private func makeAppDatabase() throws -> (dir: URL, pool: DatabasePool, inbox: Folder, archive: Folder, previous: AppDatabase?) {
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
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
        return (dir, pool, inbox, archive, previous)
    }

    private func makeStagingFile(in dir: URL) throws -> (path: String, queue: DatabaseQueue) {
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        return (path, try DatabaseQueue(path: path))
    }

    /// Header-only staged row (`populated=1, aiCompleted=0`), mirroring
    /// `NSEStagingDB.stageHeader` — a gradual row that MERGES but is KEPT in
    /// staging (not deleted) until AI lands, exactly the shape a re-stage of
    /// an already-archived message would have.
    private func stageHeaderRow(
        _ q: DatabaseQueue, messageId: String = "msg-1", folderPath: String = "INBOX"
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, 'acc1', 'user@example.com', 'gmail', ?, ?, ?,
                        'Subject under test', 'Alice', 'alice@example.com', 'snippet preview', ?,
                        ?, 0, 0, 1)
                """, arguments: [
                    "acc1:\(messageId)", messageId, "rfc-\(messageId)@example.com", folderPath,
                    Double(1_710_000_000), Date().timeIntervalSince1970
                ])
        }
    }

    nonisolated private func headerId(_ messageId: String = "msg-1", folderPath: String = "INBOX") -> String {
        MessageIdentity.headerId(accountId: "acc1", folderPath: folderPath, messageId: messageId)
    }

    private func stagingRowExists(_ q: DatabaseQueue, messageId: String = "msg-1") throws -> Bool {
        try q.read { db in
            try Bool.fetchOne(db, sql:
                "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE id = ?)",
                arguments: ["acc1:\(messageId)"]) ?? false
        }
    }

    private func resetGlobals() {
        NSEDataBridge.resetStageMemoForTesting()
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
    }

    // MARK: - Tests

    @Test("Archived-then-restaged message: staging row deleted, snapshots scrubbed, stage-memo dropped, durable header stays in Archive")
    func archivedMessageRestagedIsInvalidatedNotResurrected() async throws {
        let (dir, pool, inbox, archive, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)

        // ── Merge 1: ordinary push arrives, message lands in INBOX. ──
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let h1 = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(h1?.folderId == inbox.id)
        #expect(h1?.isInInbox == true)
        // Header-only + aiCompleted=0 is a KEPT gradual row — merge 1 does not
        // drain it from staging (mirrors the real "NSE still has more stages to
        // write" case, and is exactly the shape a later re-stage would find).
        #expect(try stagingRowExists(q) == true)
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()["acc1:msg-1"] != nil)

        // ── User archives the message IN-APP. Durable state now says Archive;
        // the staging row (push-time truth) still says INBOX and is untouched —
        // exactly what a later, unrelated push re-staging the SAME message
        // would produce (deterministic staging id `"acc1:msg-1"`). ──
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderId = ?, isInInbox = 0 WHERE id = ?",
                arguments: [archive.id, headerId()]
            )
        }
        let archived = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(archived?.folderId == archive.id)
        #expect(archived?.isInInbox == false)

        // ── Merge 2: the (unchanged, still-staged) row must be recognized as
        // STALE-BY-MOVE and invalidated, not merged. ──
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        // Staging row DELETED — no longer around to be merged again.
        #expect(try stagingRowExists(q) == false)

        // Not resurrected in the in-memory snapshot consumers.
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(!stagedRows.contains { $0.headerId == headerId() })

        // Stage-memo entry gone — no "next merge" to skip against.
        #expect(NSEDataBridge.stageMemoSnapshotForTesting()["acc1:msg-1"] == nil)

        // Durable header UNCHANGED — the merge did not move it back to INBOX.
        let stillArchived = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(stillArchived?.folderId == archive.id)
        #expect(stillArchived?.isInInbox == false)
    }

    @Test("IMAP UID-remap archive (durable header re-keyed, found via rfc822 fallback): invalidation is keyed by the STAGED headerId")
    func uidRemapArchiveInvalidatesByStagedHeaderId() async throws {
        let (dir, pool, _, archive, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)

        // Merge 1: message lands durable in INBOX under the staged identity.
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(try stagingRowExists(q) == true) // kept gradual row

        // Simulate an IMAP archive: MOVE re-keys the message — new UID, new
        // folder, new header id. Only the rfc822MessageId still links it to
        // the staged row (the merge's fallback identity).
        let remappedId = "acc1:Archive:999"
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE messageHeader
                SET id = ?, messageId = '999', folderId = ?, folderPath = 'Archive', isInInbox = 0
                WHERE id = ?
                """, arguments: [remappedId, archive.id, headerId()])
        }

        // Merge 2: the staged row's (accountId, messageId) lookup misses; the
        // rfc822 fallback finds the re-keyed Archive header → stale-by-move.
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        #expect(try stagingRowExists(q) == false)
        // Snapshot scrub MUST use the STAGED headerId — the id the published
        // snapshots are keyed by. A durable-id scrub (the pre-fix bug) would
        // target `remappedId` and miss it.
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(!stagedRows.contains { $0.headerId == headerId() })
        // Durable header untouched, still archived under its remapped identity.
        let durable = try await pool.read { try MessageHeader.fetchOne($0, key: remappedId) }
        #expect(durable?.isInInbox == false)
    }

    @Test("A normal new message (no durable header yet) is NOT invalidated — merges normally")
    func newMessageWithoutDurableHeaderMergesNormally() async throws {
        let (dir, pool, inbox, _, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)

        // Brand-new message, never seen before — no durable header exists.
        try stageHeaderRow(q, messageId: "msg-new")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        // Merged normally: durable header created in INBOX.
        let h = try await pool.read { try MessageHeader.fetchOne($0, key: headerId("msg-new")) }
        #expect(h != nil)
        #expect(h?.folderId == inbox.id)
        #expect(h?.isInInbox == true)

        // No false-positive invalidation for an ordinary new message: it's
        // still a KEPT gradual row (aiCompleted=0), so the staging row
        // survives merge 1 AND the published snapshot still carries it — a
        // stale-by-move exclusion would have scrubbed it from here instead.
        #expect(try stagingRowExists(q, messageId: "msg-new") == true)
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(stagedRows.contains { $0.headerId == headerId("msg-new") })
    }
}
