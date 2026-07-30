/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
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
    /// an already-archived message would have. `date: nil` stages the
    /// fail-open edge documented at `NSEDataBridge.stagedSetChangedSinceLastPost`
    /// (~line 172): a nil-date row gets a FRESH `Date()` at every merge's row
    /// build, so it never compares equal to the post memo and
    /// `.messagesStaged` suppression never engages for it.
    private func stageHeaderRow(
        _ q: DatabaseQueue, messageId: String = "msg-1", folderPath: String = "INBOX",
        date: Double? = Double(1_710_000_000)
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
                    date, Date().timeIntervalSince1970
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
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

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
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

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
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

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

    /// G3 audit (PLAN_INBOX_UNIFIED_READ.md): an UNRELATED durable message
    /// already living in Archive that happens to share the staged row's raw
    /// UID (a legitimate per-folder IMAP UID collision, not a move) must NOT
    /// be mistaken for "the same message moved" — `detectStaleByMoveRows`
    /// must NOT flag the staged row. Pre-G3, `DurableIdentityLookup.find`'s
    /// folder-blind `(accountId, messageId)` lookup would land on the
    /// Archive row regardless of folder, see `folderId != stagedFolderId`,
    /// and wrongly scrub/suppress the staged row for a completely different
    /// message.
    @Test("A staged row colliding on UID with an UNRELATED Archive message (differing rfc822) is NOT flagged stale-by-move — merges normally")
    func crossFolderUidCollisionIsNotFlaggedStaleByMove() async throws {
        let (dir, pool, inbox, archive, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // An UNRELATED message, already durable in Archive, sharing the SAME
        // raw UID ("msg-1") the staged row below will carry — but with a
        // DIFFERENT rfc822MessageId, proving it is genuinely a different
        // message (IMAP UIDs are per-folder — ADR-IOS-042).
        let unrelatedArchiveId = "acc1:Archive:msg-1"
        try await pool.write { db in
            var header = MessageHeader(
                messageId: "msg-1", subject: "Unrelated", from: "Bob", fromAddress: "bob@example.com",
                to: "user@example.com", date: Date(), snippet: "unrelated",
                folderId: archive.id, accountId: "acc1", folderPath: "Archive", isInInbox: false
            )
            header.id = unrelatedArchiveId
            header.rfc822MessageId = "rfc-unrelated@example.com"
            header.headerComplete = true
            try header.insert(db)
        }

        // `stageHeaderRow`'s deterministic rfc822 is "rfc-msg-1@example.com"
        // — DIFFERING from the Archive row's "rfc-unrelated@example.com".
        try stageHeaderRow(q, messageId: "msg-1")
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        // NOT stale-by-move: merged normally into a NEW durable header in
        // INBOX (the unrelated Archive row is a different message).
        let merged = try await pool.read { try MessageHeader.fetchOne($0, key: headerId("msg-1")) }
        #expect(merged != nil, "staged row was wrongly excluded as stale-by-move")
        #expect(merged?.folderId == inbox.id)
        #expect(merged?.isInInbox == true)

        // Still a KEPT gradual row (aiCompleted=0) — a stale-by-move
        // exclusion would have deleted the staging row and scrubbed the
        // published snapshot instead.
        #expect(try stagingRowExists(q, messageId: "msg-1") == true)
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(stagedRows.contains { $0.headerId == headerId("msg-1") })

        // The unrelated Archive message is untouched.
        let stillArchived = try await pool.read { try MessageHeader.fetchOne($0, key: unrelatedArchiveId) }
        #expect(stillArchived?.folderId == archive.id)
        #expect(stillArchived?.isInInbox == false)
    }

    /// F1 (PLAN_INBOX_UNIFIED_READ.md audit): a "scrub-only" merge wake — the
    /// ONLY staged row this wake is stale-by-move, so after step (a)'s
    /// exclusion `processed` is empty and NO durable write phase runs
    /// (`endOfMergeChanged` never flips true). Before the fix, this meant the
    /// pre-detection `.messagesStaged` post (which already fired WITH the
    /// now-scrubbed row) had no eviction trigger — a VM that inserted the
    /// phantom via `insertStagedRows` would show it forever. The fix adds an
    /// `else if scrubbedStaleStagedRows` branch that posts ONE immediate
    /// `.inboxDataDidChange` so the reader (which no longer finds the row in
    /// `latestStagedRows`, and whose stale-by-move suppression rejects it
    /// regardless — §2.1a) can evict it on the very next reload.
    @Test("Scrub-only wake (only staged row is stale-by-move) posts exactly ONE immediate inboxDataDidChange")
    func scrubOnlyWakePostsExactlyOneImmediateReload() async throws {
        let (dir, pool, _, archive, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // ── Merge 1: ordinary push arrives, message lands in INBOX as a KEPT
        // gradual row (header-only, aiCompleted=0). ──
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(try stagingRowExists(q) == true)

        // ── User archives the message IN-APP. The staging row (push-time
        // truth) is untouched — exactly the shape a later, unrelated push
        // re-staging the SAME message would produce. ──
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderId = ?, isInInbox = 0 WHERE id = ?",
                arguments: [archive.id, headerId()]
            )
        }

        // ── Merge 2: the ONLY staged row is stale-by-move → scrub-only wake.
        // Count every `.inboxDataDidChange` and whether it carried the
        // immediate-reload flag. ──
        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { note in
            let imm = (note.userInfo?[Notification.Name.inboxReloadImmediateKey] as? Bool) == true
            posts.withLock { $0.append(imm) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        let captured = posts.withLock { $0 }
        #expect(captured.count == 1, "scrub-only wake must post exactly ONE reload to evict the phantom, got \(captured.count)")
        #expect(captured.first == true, "the scrub-only reload must carry inboxReloadImmediateKey==true")

        // Existing invalidation assertions still hold: staging row deleted,
        // in-memory snapshot scrubbed.
        #expect(try stagingRowExists(q) == false)
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(!stagedRows.contains { $0.headerId == headerId() })

        // Durable header UNCHANGED — still archived, not resurrected.
        let stillArchived = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(stillArchived?.folderId == archive.id)
        #expect(stillArchived?.isInInbox == false)
    }

    /// F1 edge case: at-least-once REDELIVERY of the same stale identity
    /// AFTER a scrub-only wake already evicted it once. Two independent
    /// wakes, each its own scrub-only wake, must EACH post exactly one
    /// immediate reload — no accumulation across wakes, and no suppression
    /// on the second wake. The redelivered row is staged with `date: nil`,
    /// the fail-open edge in `stagedSetChangedSinceLastPost` (NSEDataBridge.swift
    /// ~172-180): a nil-date row gets a FRESH `Date()` at every merge's row
    /// build, so it never compares equal to the post memo and
    /// `.messagesStaged`'s OWN suppression never engages for it (it would
    /// re-post on every wake regardless of content). This proves F1's
    /// `scrubbedStaleStagedRows` gate is independent of — and does not
    /// double-fire alongside — `.messagesStaged`'s unrelated suppression
    /// state: the eviction post fires once per wake because `staleByMove`
    /// was non-empty THIS wake, not because of anything about the
    /// `.messagesStaged` post's own dedup.
    @Test("Redelivery (two-wake): a stale-by-move row re-staged after the scrub-only wake evicted it once is scrubbed AGAIN with its own single immediate reload — no accumulation, no suppression on wake 2")
    func redeliveredStaleRowIsScrubbedAgainOnSecondWake() async throws {
        let (dir, pool, _, archive, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // ── Merge 1: ordinary push, kept gradual row. ──
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(try stagingRowExists(q) == true)

        // ── User archives IN-APP. ──
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderId = ?, isInInbox = 0 WHERE id = ?",
                arguments: [archive.id, headerId()]
            )
        }

        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { note in
            let imm = (note.userInfo?[Notification.Name.inboxReloadImmediateKey] as? Bool) == true
            posts.withLock { $0.append(imm) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        // ── Wake 1: scrub-only wake (same shape as scrubOnlyWakePostsExactlyOneImmediateReload). ──
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(posts.withLock { $0 }.count == 1, "wake 1 must post exactly one immediate reload")
        #expect(try stagingRowExists(q) == false)

        // ── Redelivery: at-least-once duplicate of the SAME push arrives
        // AFTER wake 1's delete — deterministic staging id ("acc1:msg-1")
        // means this is indistinguishable from the original re-stage.
        // Staged with a nil date (the fail-open edge) so `.messagesStaged`'s
        // own change-detection can never suppress it — isolates that
        // F1's eviction post is gated on `scrubbedStaleStagedRows`, not on
        // whether `.messagesStaged` itself fired this wake. ──
        posts.withLock { $0 = [] }
        try stageHeaderRow(q, date: nil)

        // ── Wake 2: a SECOND, independent scrub-only wake. ──
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        let secondWakePosts = posts.withLock { $0 }
        #expect(
            secondWakePosts.count == 1,
            "wake 2 must ALSO post exactly one immediate reload — no accumulation, no suppression, got \(secondWakePosts.count)"
        )
        #expect(secondWakePosts.first == true)

        // No accumulation: staging row deleted again, snapshot scrubbed again.
        #expect(try stagingRowExists(q) == false)
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(!stagedRows.contains { $0.headerId == headerId() })

        // Durable header never resurrected across either wake.
        let stillArchived = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(stillArchived?.folderId == archive.id)
        #expect(stillArchived?.isInInbox == false)
    }

    /// MIXED wake: a merge wake whose staging contains BOTH a stale-by-move
    /// row AND a genuinely new row (durable work happens). `scrubbedStaleStagedRows`
    /// is set unconditionally whenever `detectStaleByMoveRows` finds ANY stale
    /// row this wake (NSEDataBridge.swift ~951), independent of whether other
    /// staged rows in the SAME wake do durable work — so this wake sets BOTH
    /// `scrubbedStaleStagedRows` (from the stale row) AND `endOfMergeChanged`
    /// (from the new row's durable header write). The end-of-merge signal
    /// site is an `if endOfMergeChanged { … } else if scrubbedStaleStagedRows
    /// { … }` — structurally, the `endOfMergeChanged` branch wins and the
    /// scrub branch's post is skipped, so a mixed wake must NOT emit a THIRD
    /// `.inboxDataDidChange` beyond the normal phase-1 + end-of-merge pair.
    /// Proves the `else if` doesn't silently lose the eviction signal for the
    /// stale row on a mixed wake — the end-of-merge post covers it too (the
    /// reader re-evaluates `latestStagedRows`/durable state on every reload
    /// regardless of which branch posted).
    @Test("Mixed wake (stale-by-move row + genuinely new row): standard post pattern (≤2 total, no third post from the scrub branch); stale row scrubbed, new row merged durably")
    func mixedWakeStaleAndNewRowPostsStandardPattern() async throws {
        let (dir, pool, inbox, archive, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(
                pools: [pool],
                queues: ownedQueues,
                directory: dir
            )
        }
        resetGlobals()
        let (path, q) = try makeStagingFile(in: dir)
        ownedQueues.append(q)

        // ── Merge 1: ordinary push for "msg-1" arrives, kept gradual row
        // (header-only, aiCompleted=0). ──
        try stageHeaderRow(q)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        #expect(try stagingRowExists(q) == true)

        // ── User archives "msg-1" IN-APP. The staging row (push-time truth)
        // is untouched — exactly the shape a later, unrelated push
        // re-staging the SAME message would produce. ──
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET folderId = ?, isInInbox = 0 WHERE id = ?",
                arguments: [archive.id, headerId()]
            )
        }

        // ── A genuinely NEW message ("msg-2") is ALSO staged for the SAME
        // wake — no durable header exists for it anywhere. ──
        try stageHeaderRow(q, messageId: "msg-2")

        // ── Merge 2: mixed wake. Count every `.inboxDataDidChange`. ──
        let posts = Mutex<[Bool]>([])
        let obs = NotificationCenter.default.addObserver(
            forName: .inboxDataDidChange, object: nil, queue: .main
        ) { note in
            let imm = (note.userInfo?[Notification.Name.inboxReloadImmediateKey] as? Bool) == true
            posts.withLock { $0.append(imm) }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        try await Task.sleep(for: .milliseconds(200))

        let captured = posts.withLock { $0 }
        #expect(
            captured.count <= 2,
            "mixed wake must post AT MOST the standard phase-1 + end-of-merge pair — got \(captured.count), a third post would mean the scrub branch fired alongside endOfMergeChanged"
        )
        #expect(!captured.isEmpty, "mixed wake did real durable work (msg-2) and must post at least one reload")
        #expect(captured.allSatisfy { $0 == true }, "every post this wake must carry the immediate-reload flag")

        // Stale row ("msg-1"): staging deleted, snapshot scrubbed, durable
        // header UNCHANGED (still archived, not resurrected).
        #expect(try stagingRowExists(q) == false, "msg-1's staging row must be deleted (stale-by-move)")
        let stagedRows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(!stagedRows.contains { $0.headerId == headerId() }, "msg-1 must be scrubbed from the published staged snapshot")
        let stillArchived = try await pool.read { try MessageHeader.fetchOne($0, key: headerId()) }
        #expect(stillArchived?.folderId == archive.id)
        #expect(stillArchived?.isInInbox == false)

        // New row ("msg-2"): merged durably into INBOX.
        let newHeader = try await pool.read { try MessageHeader.fetchOne($0, key: headerId("msg-2")) }
        #expect(newHeader != nil, "msg-2 must merge durably despite msg-1's stale-by-move exclusion in the SAME wake")
        #expect(newHeader?.folderId == inbox.id)
        #expect(newHeader?.isInInbox == true)
    }
}
