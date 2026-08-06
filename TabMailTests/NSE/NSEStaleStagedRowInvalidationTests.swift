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
@Suite("NSE merge — stale-by-move staged row invalidation", .serialized, .processGlobalState)
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

/// T5.10 MERGE HALF — the UIDVALIDITY epoch guard in `NSEDataBridge.performMerge`
/// (`uidValidityStagingRowStatus` + `nseMergeIdentityConfirmed`, ADR-IOS-061).
///
/// THE INVARIANT, stated once: **the NSE's staged content may only ever land on the
/// message it was actually about.** A staged row is addressed by a MAILBOX-LOCAL UID
/// (`nse_processed_message.messageId`). If the folder's UIDVALIDITY turns over
/// between staging and merge, that UID names a DIFFERENT physical message — and
/// `DurableIdentityLookup.find`'s step 1 (exact-folder `(accountId, folderPath,
/// messageId)`) carries no RFC check and no epoch input at all, so it returns the new
/// occupant without hesitation. Merging onto it writes this notification's body,
/// summary, action tag and `notified` flag onto a message the notification was never
/// about: C3.
///
/// The NSE stamps the epoch its own SELECT observed (`NSEIMAPConnection.performFetch`
/// → `NSEMessageMetadata.observedUidValidity` → the `nse_processed_message
/// .observedUidValidity` column); this suite covers the MERGE-side disposition of
/// that stamp, in four arms:
///  1. positive epoch mismatch, folder settled ⇒ DROP (skip-and-delete);
///  2. folder QUARANTINED ⇒ KEEP for retry, never delete (the stored epoch is still
///     the old one by construction, so nothing is decidable yet);
///  3. EXISTING durable row + identity not positively confirmed ⇒ DROP;
///  4. NEW-header arm + NULL stamp ⇒ the ARRIVAL still surfaces — with no durable
///     row occupying the UID there is nothing to misattribute, so the header is
///     created and made inbox-visible — while the row's unprovable CONTENT (body,
///     summary, action tag) is refused and the message is left honestly
///     `bodyComplete = 0` for the ordinary body queue. Refusing a write is not
///     dropping an arrival, and arm 4 pins exactly that distinction.
///
/// Every assertion is on the END STATE — what landed on which durable row, and what
/// is still in the staging file — never on a disposition enum or which helper ran.
/// Each drop arm is paired with a case that MERGES, so a guard that refused
/// everything would fail this suite rather than pass it vacuously.
///
/// Drives the REAL `NSEDataBridge.mergeNSEStagingData` against a real pool-backed
/// `AppDatabase` + a real staging file. `.serialized, .processGlobalState` — replaces
/// `AppDatabase.shared` and mutates the process-wide `NSEDataBridge.latestStagedRows`
/// / `latestStagedBodies` / `stageMemo`.
@Suite("NSE merge — staged-row UIDVALIDITY epoch guard (T5.10)", .serialized, .processGlobalState)
@MainActor
struct NSEStagedRowEpochGuardTests {

    // MARK: - Fixture

    private static let epochA = 710_001      // what the NSE observed
    private static let epochB = 710_002      // what the folder settled on afterwards
    private static let siblingEpoch = 810_005
    private static let otherAccountEpoch = 910_009

    private struct World {
        let dir: URL
        let pool: DatabasePool
        let previous: AppDatabase?
        let stagingPath: String
        let stagingQueue: DatabaseQueue
    }

    /// Real pool-backed `AppDatabase` with two accounts: `acc1` (INBOX + Archive)
    /// and `acc2` (INBOX). Folder epochs are set explicitly by each test.
    private func makeWorld() throws -> World {
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
            var acc1 = Account(emailAddress: "one@example.com", displayName: "One", provider: .imap)
            acc1.id = "acc1"
            try acc1.insert(db)
            var acc2 = Account(emailAddress: "two@example.com", displayName: "Two", provider: .imap)
            acc2.id = "acc2"
            try acc2.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2").insert(db)
        }

        // Real production staging schema, then the column the NSE adds for itself
        // (`NSEStagingDB.ensureObservedUidValidityColumn` lives in the extension
        // target and is not linkable from here; the statement is reproduced
        // verbatim, `PRAGMA table_info` first, `ALTER TABLE` only on absence —
        // `AppDatabase.createNSEStagingDB` deliberately does NOT create it).
        let stagingPath = dir.appendingPathComponent("nse_staging.sqlite").path
        _ = AppDatabase.createNSEStagingDB(atPath: stagingPath)
        let q = try DatabaseQueue(path: stagingPath)
        try q.write { db in
            let columns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)")
                    .map { $0["name"] as String }
            )
            guard !columns.contains("observedUidValidity") else { return }
            try db.execute(sql: "ALTER TABLE nse_processed_message ADD COLUMN observedUidValidity INTEGER")
        }
        return World(dir: dir, pool: pool, previous: previous, stagingPath: stagingPath, stagingQueue: q)
    }

    private func teardown(_ world: World) {
        AppDatabase.shared.withLock { $0 = world.previous }
        TestDatabaseTeardown.retire(
            pools: [world.pool], queues: [world.stagingQueue], directory: world.dir
        )
    }

    private func resetGlobals() {
        NSEDataBridge.resetStageMemoForTesting()
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
    }

    /// Set a folder's stored epoch and (optionally) arm its reset quarantine —
    /// exactly the two columns `uidValidityStagingRowStatus` reads.
    private func setFolderEpoch(
        _ pool: DatabasePool, accountId: String, folderPath: String,
        epoch: Int?, quarantinedAt: Date? = nil
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = ?, uidValidityResetPendingAt = ? WHERE id = ?",
                arguments: [epoch, quarantinedAt, MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)]
            )
        }
    }

    /// A TERMINAL staged row (`populated=1, aiCompleted=1`) carrying a body, a
    /// summary and an action tag — so a merge that lands leaves four independently
    /// observable marks (`messageBody` row, `summaryBlurb`, `actionTag`, `notified`)
    /// and a merge that is refused leaves none of them. `processedAt`/`date` derive
    /// from `Date()`; never a literal.
    private func stageRow(
        _ q: DatabaseQueue, accountId: String = "acc1", folderPath: String = "INBOX",
        messageId: String, rfc822: String?, observedUidValidity: Int?, subject: String = "Staged subject"
    ) throws {
        let now = Date().timeIntervalSince1970
        try q.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated,
                     htmlContent, textContent, hasUnresolvedCIDs,
                     summaryBlurb, summaryTodos, actionTag, observedUidValidity)
                VALUES (?, ?, ?, 'imap_new_mail', ?, ?, ?,
                        ?, 'Sender', 'sender@example.com', 'staged snippet', ?,
                        ?, 1, 1, 1,
                        '<p>Staged body</p>', 'Staged body', 0,
                        'Staged summary', 'Staged todo', 'reply', ?)
                """, arguments: [
                    "\(accountId):\(messageId)", accountId, "\(accountId)@example.com",
                    messageId, rfc822, folderPath, subject, now, now, observedUidValidity
                ])
        }
    }

    /// A durable header already occupying `accountId:folderPath:messageId`, with
    /// EMPTY snippet and no body/summary/action/notified — so every mark a merge
    /// would leave is observable by its absence.
    private func insertOccupant(
        _ pool: DatabasePool, accountId: String = "acc1", folderPath: String = "INBOX",
        messageId: String, rfc822: String?, subject: String = "Occupant"
    ) async throws {
        try await pool.write { db in
            var header = MessageHeader(
                messageId: messageId, subject: subject, from: "Other", fromAddress: "other@example.com",
                to: "one@example.com", date: Date(), snippet: "",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
                accountId: accountId, folderPath: folderPath, isInInbox: true
            )
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            try header.insert(db)
        }
    }

    /// Everything the merge would have written for one staged row, read back off the
    /// durable row that occupies its address. Asserting on this whole shape (rather
    /// than on any one column) is what makes "landed on nothing" mean nothing.
    private struct Landed: Equatable, Sendable {
        var exists: Bool
        var subject: String?
        var snippet: String?
        var summaryBlurb: String?
        var actionTag: String?
        var notified: Bool?
        var hasBody: Bool
    }

    private func landed(_ pool: DatabasePool, headerId: String) async throws -> Landed {
        try await pool.read { db in
            guard let h = try MessageHeader.fetchOne(db, key: headerId) else {
                return Landed(exists: false, subject: nil, snippet: nil, summaryBlurb: nil,
                              actionTag: nil, notified: nil, hasBody: false)
            }
            let hasBody = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM messageBody WHERE id = ?)", arguments: [headerId]
            ) ?? false
            return Landed(
                exists: true, subject: h.subject, snippet: h.snippet, summaryBlurb: h.summaryBlurb,
                actionTag: h.actionTag?.rawValue, notified: h.notified, hasBody: hasBody
            )
        }
    }

    private func stagingRowExists(_ q: DatabaseQueue, id: String) throws -> Bool {
        try q.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM nse_processed_message WHERE id = ?)", arguments: [id]
            ) ?? false
        }
    }

    // MARK: - ARM 1: positive epoch mismatch ⇒ DROP

    @Test("A staged row whose observed epoch positively differs from its folder's current epoch is dropped at merge and lands on nothing — no body, no summary, no action, no notified flag on the durable row occupying its UID")
    func positiveEpochMismatchLandsOnNothing() async throws {
        let world = try makeWorld()
        defer { teardown(world) }
        resetGlobals()

        // The folder has SETTLED on a new epoch. The durable row occupying UID 5 is
        // whatever the resync put there. Its rfc822 deliberately AGREES with the
        // staged row's, so the identity door would CONFIRM — the epoch is therefore
        // the only thing that can refuse this merge, and the drop is unambiguously
        // attributable to it (the sibling test below flips exactly that one value).
        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "INBOX", epoch: Self.epochB)
        try await insertOccupant(world.pool, messageId: "5", rfc822: "rfc-shared@example.com")
        try stageRow(world.stagingQueue, messageId: "5",
                     rfc822: "rfc-shared@example.com", observedUidValidity: Self.epochA)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        try await Task.sleep(for: .milliseconds(200))

        let after = try await landed(world.pool, headerId: "acc1:INBOX:5")
        #expect(after == Landed(
            exists: true, subject: "Occupant", snippet: "", summaryBlurb: nil,
            actionTag: nil, notified: false, hasBody: false
        ), "the row occupying UID 5 must be untouched by a staged row from a different epoch")

        // Skip-AND-delete: permanently stale (the stamp is immutable staged data),
        // so it must not be left to re-attempt the same refusal every wake.
        #expect(try stagingRowExists(world.stagingQueue, id: "acc1:5") == false)
        // And scrubbed from the snapshot the pre-guard publish already posted.
        let staged = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(!staged.contains { $0.headerId == "acc1:INBOX:5" })

        try? await Task.sleep(for: .milliseconds(300))
    }

    @Test("A staged row whose observed epoch equals its folder's current epoch still merges in full — the drop is evidence-driven, not a blanket refusal")
    func matchingEpochStillMergesInFull() async throws {
        let world = try makeWorld()
        defer { teardown(world) }
        resetGlobals()

        // Byte-identical to the test above except for ONE value: the staged stamp.
        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "INBOX", epoch: Self.epochB)
        try await insertOccupant(world.pool, messageId: "5", rfc822: "rfc-shared@example.com")
        try stageRow(world.stagingQueue, messageId: "5",
                     rfc822: "rfc-shared@example.com", observedUidValidity: Self.epochB)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        try await Task.sleep(for: .milliseconds(200))

        let after = try await landed(world.pool, headerId: "acc1:INBOX:5")
        #expect(after.exists)
        #expect(after.hasBody, "the staged body must land when the epochs agree")
        #expect(after.summaryBlurb == "Staged summary")
        #expect(after.actionTag == "reply")
        #expect(after.notified == true)
        #expect(after.snippet?.isEmpty == false, "phase 1 must seed the empty snippet")

        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Scoping

    /// ⚠️ THE SIBLING-FOLDER ROW MUST NOT REUSE THE DROPPED ROW'S UID, AND THAT IS A
    /// PROPERTY OF THE STAGING SCHEMA, NOT A WEAKENING OF THIS TEST.
    /// `nse_processed_message`'s primary key is `"<accountId>:<messageId>"` — no
    /// folder, no epoch (see `NSEStagingDB`'s doc, and `stageRow` above composes the
    /// same key production does). So within ONE account, two staged rows carrying the
    /// same `messageId` in DIFFERENT folders **cannot coexist**: the second
    /// `INSERT OR REPLACE` silently evicts the first.
    ///
    /// This test previously staged `acc1`/INBOX/UID 5 and `acc1`/Archive/UID 5 and
    /// believed it held both. It held only the Archive one, so the load-bearing
    /// `dropped.exists == false` assertion passed because the INBOX row had never been
    /// staged — **not** because the epoch guard dropped it. Verified 2026-08-06: with
    /// `uidValidityStagingRowStatus`'s `isOldEpoch` hardwired to `false` (the guard
    /// fully disarmed), the old shape still reported `✔ … passed`. The sibling row
    /// therefore carries UID 6; **do not "restore" it to 5** — that re-collides the key
    /// and re-vacuates arm (a).
    ///
    /// Folder scoping is still pinned, by the EPOCHS rather than by a shared UID: the
    /// three folders hold three distinct epochs, so an implementation that resolved any
    /// row's epoch against the wrong folder (or the wrong account) would find a
    /// disagreement and drop that row. The same-UID-different-folder question at the
    /// identity door itself is pinned directly, and without the schema's key collision,
    /// by `epochDoorIsScopedToTheRefsOwnFolder` below.
    @Test("The epoch drop is scoped to its own folder and account — a sibling folder's and another account's staged rows merge untouched in the same pass")
    func epochDropIsScopedToItsOwnFolderAndAccount() async throws {
        let world = try makeWorld()
        defer { teardown(world) }
        resetGlobals()

        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "INBOX", epoch: Self.epochB)
        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "Archive", epoch: Self.siblingEpoch)
        try await setFolderEpoch(world.pool, accountId: "acc2", folderPath: "INBOX", epoch: Self.otherAccountEpoch)

        // Only this one disagrees with its own folder.
        try stageRow(world.stagingQueue, accountId: "acc1", folderPath: "INBOX", messageId: "5",
                     rfc822: "rfc-inbox@example.com", observedUidValidity: Self.epochA)
        // Sibling folder, SAME account, agreeing epoch — distinct UID, see the note above.
        try stageRow(world.stagingQueue, accountId: "acc1", folderPath: "Archive", messageId: "6",
                     rfc822: "rfc-archive@example.com", observedUidValidity: Self.siblingEpoch,
                     subject: "Sibling folder subject")
        // Same UID as the dropped row, different ACCOUNT, agreeing epoch. This one does
        // not collide — the key is account-prefixed — so the UID is shared on purpose.
        try stageRow(world.stagingQueue, accountId: "acc2", folderPath: "INBOX", messageId: "5",
                     rfc822: "rfc-other-account@example.com", observedUidValidity: Self.otherAccountEpoch,
                     subject: "Other account subject")

        // NON-VACUITY ANCHOR, asserted BEFORE the merge: all three rows are actually in
        // the staging file. If a future edit re-collides two ids, this fails loudly here
        // instead of silently turning the drop assertion below into a tautology.
        #expect(try stagingRowExists(world.stagingQueue, id: "acc1:5"),
                "the old-epoch row under test was never staged — the drop assertion below would be vacuous")
        #expect(try stagingRowExists(world.stagingQueue, id: "acc1:6"),
                "the sibling-folder row was never staged — its unaffected-ness would be vacuous")
        #expect(try stagingRowExists(world.stagingQueue, id: "acc2:5"),
                "the other-account row was never staged — its unaffected-ness would be vacuous")

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        try await Task.sleep(for: .milliseconds(200))

        let dropped = try await landed(world.pool, headerId: "acc1:INBOX:5")
        #expect(dropped.exists == false, "the old-epoch row must not create a header at the UID it no longer owns")

        let sibling = try await landed(world.pool, headerId: "acc1:Archive:6")
        #expect(sibling.exists, "a sibling folder's staged row must be unaffected by another folder's turnover")
        #expect(sibling.subject == "Sibling folder subject")
        #expect(sibling.hasBody)

        let otherAccount = try await landed(world.pool, headerId: "acc2:INBOX:5")
        #expect(otherAccount.exists, "another account's staged row must be unaffected")
        #expect(otherAccount.subject == "Other account subject")
        #expect(otherAccount.hasBody)

        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - ARMS 3 & 4: the NULL-stamp tail

    @Test("A NULL-stamped staged row is never written onto an EXISTING durable row it cannot claim; with no durable row to poison the arrival still surfaces as a visible header whose body stays honestly unfetched and refetchable")
    func nullStampDropsOnExistingRowAndInsertsOnNewHeader() async throws {
        let world = try makeWorld()
        defer { teardown(world) }
        resetGlobals()

        // The folder HAS an epoch; the staged rows do not. With no usable rfc822 on
        // either side, neither identity door can open — which is exactly the tail
        // arms 1/2 alone leave uncovered.
        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "INBOX", epoch: Self.epochB)

        // (a) EXISTING durable row occupies UID 10 — content would land ON it.
        try await insertOccupant(world.pool, messageId: "10", rfc822: nil, subject: "Occupant A")
        try stageRow(world.stagingQueue, messageId: "10", rfc822: nil, observedUidValidity: nil)

        // (b) No durable row anywhere for UID 11 — nothing to poison.
        try stageRow(world.stagingQueue, messageId: "11", rfc822: nil, observedUidValidity: nil,
                     subject: "Brand new arrival")

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        try await Task.sleep(for: .milliseconds(200))

        let occupied = try await landed(world.pool, headerId: "acc1:INBOX:10")
        #expect(occupied == Landed(
            exists: true, subject: "Occupant A", snippet: "", summaryBlurb: nil,
            actionTag: nil, notified: false, hasBody: false
        ), "an unprovable staged row must not write onto the durable row already holding its address")
        #expect(try stagingRowExists(world.stagingQueue, id: "acc1:10") == false)

        // (b) The NEW-header arm. The ARRIVAL is never dropped — with no durable
        // row occupying UID 11 there is nothing to misattribute, so the header is
        // created from this same staged row and made inbox-VISIBLE. What IS
        // refused is the staged row's unprovable CONTENT: by the time the body/AI
        // pass runs, the row just created is itself the durable occupant of that
        // address, and an rfc-nil + epoch-nil pair proves nothing about it.
        //
        // That refusal is only tolerable because it leaves the message honestly
        // UNFETCHED instead of marked complete — so the ordinary body queue
        // fetches it and the AI recomputes. The staged row is scratch; the
        // message is not lost.
        let fresh = try await landed(world.pool, headerId: "acc1:INBOX:11")
        #expect(fresh.exists,
                "the arrival itself was dropped — there was no durable row to poison, so nothing justified refusing it")
        #expect(fresh.subject == "Brand new arrival")
        #expect(fresh.snippet?.isEmpty == false,
                "the visible row must carry a preview, not an empty snippet")
        #expect(fresh.hasBody == false,
                "unprovable staged CONTENT was written anyway — the epoch/rfc pair proves nothing about the occupant")
        #expect(fresh.summaryBlurb == nil, "unprovable staged AI was applied")
        #expect(fresh.actionTag == nil, "unprovable staged AI was applied")

        // 🚨 THE RETENTION HALF — this is what separates "refused a write" from
        // "dropped an arrival", and it is asserted through the body queue's OWN
        // selection predicate (`ActiveBodyQueue`: `headerComplete = 1 AND
        // bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 1`) rather
        // than through any single column. A row that satisfies it is one the body
        // fetch WILL pick up; any one of those four columns being wrong strands
        // the message body-less indefinitely, with its staging row already
        // consumed — and THAT would be a never-drop violation, not hardening.
        let refetchable = try await world.pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM messageHeader
                     WHERE id = ? AND headerComplete = 1 AND bodyComplete = 0
                       AND bodyEmptyConfirmed = 0 AND isInInbox = 1
                )
                """, arguments: ["acc1:INBOX:11"]) ?? false
        }
        #expect(refetchable, """
                the staged row was consumed while its message was left neither visible nor \
                eligible for a body fetch. Nothing else will ever fill that body in, so the \
                arrival is DROPPED rather than merely unproven — which the never-drop rule \
                forbids (an unresolvable identity is retryable, never authoritative).
                """)
        #expect(try stagingRowExists(world.stagingQueue, id: "acc1:11") == false,
                """
                the scratch staging row must be consumed rather than kept: `observedUidValidity` \
                is immutable staged data, so every retry re-reads the same NULL and can never \
                become provable. Deleting it is safe ONLY because the durable header above \
                carries the arrival and its body is still armed for fetch.
                """)

        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - ARM 2: quarantine ⇒ KEEP for retry, never delete

    @Test("A staged row in a QUARANTINED folder is kept for retry, never deleted, however its epochs compare")
    func quarantinedFolderKeepsTheStagedRowForRetry() async throws {
        let world = try makeWorld()
        defer { teardown(world) }
        resetGlobals()

        // Mid-reaction: the quarantine flag is armed and the STORED epoch is still
        // the OLD one (the reaction does not advance it until its step-5 stamp), so
        // the staged row's newer observation "disagrees" without that disagreement
        // proving anything yet.
        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "INBOX",
                           epoch: Self.epochA, quarantinedAt: Date())
        try stageRow(world.stagingQueue, messageId: "20",
                     rfc822: "rfc-quarantined@example.com", observedUidValidity: Self.epochB)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        try await Task.sleep(for: .milliseconds(200))

        // NEVER DROP: the row is still in staging, and nothing was written into the
        // folder being reset.
        #expect(try stagingRowExists(world.stagingQueue, id: "acc1:20") == true,
                "a quarantined folder's staged row must be KEPT for retry, not deleted")
        let duringQuarantine = try await landed(world.pool, headerId: "acc1:INBOX:20")
        #expect(duringQuarantine.exists == false,
                "nothing may be inserted into a folder that is mid-UIDVALIDITY-reset")

        // The reaction completes: quarantine cleared and the fresh epoch stamped in
        // the same write (`AccountManager.uidValidityResetStampFreshEpoch`). The
        // SAME kept row must now merge — this is what makes the KEEP a retry rather
        // than a stall.
        try await setFolderEpoch(world.pool, accountId: "acc1", folderPath: "INBOX",
                           epoch: Self.epochB, quarantinedAt: nil)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: world.stagingPath)
        try await Task.sleep(for: .milliseconds(200))

        let afterReset = try await landed(world.pool, headerId: "acc1:INBOX:20")
        #expect(afterReset.exists, "the retained row must merge once the reset settles on the epoch it observed")
        #expect(afterReset.hasBody)
        #expect(afterReset.summaryBlurb == "Staged summary")
        #expect(afterReset.actionTag == "reply")

        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - R11-B: the epoch door's operand must be the REF's folder
    //
    // INVARIANT (system property, not mechanism): a staged message may never be
    // merged onto a durable row in a DIFFERENT folder on epoch evidence alone.
    // `DurableIdentityLookup.find` step 2 is folder-blind and its rfc-nil tail is
    // deliberately retained, so it can hand the merge a ref from another folder;
    // on IMAP `messageId` IS the UID and UIDs are folder-scoped, so Inbox UID 7 and
    // Archive UID 7 are routinely different messages. `observedUidValidity` is the
    // STAGED folder's numbering — comparing it to any folder's stored epoch is only
    // meaningful when the durable row lives in that same folder.
    //
    // ⚠️ TWO-SIDED. Door (a), the RFC door, MUST keep resolving cross-folder
    // matches: an RFC 822 Message-ID is a global identity and a Gmail/Graph row
    // that moved folders between the NSE fetch and the merge has to reach its
    // durable row, or the duplicate-header class re-opens. Only door (b) is
    // folder-scoped. Both directions are asserted below.
    //
    // ⚑ REACHABILITY, stated honestly. `performMerge` runs `detectStaleByMoveRows`
    // BEFORE phase 1 and filters out every staged row whose durable ref is in a
    // different folder, so in the steady state a cross-folder ref does not reach
    // this door at all. It reaches it when that filter does not apply: the filter
    // reads through `AppDatabase.rawPool` inside `try? await` and yields an EMPTY
    // stale set on a read failure (fail-open), and it is a separate, earlier read
    // than the phase-1/phase-2 lookups, so a durable row moved by sync or by the
    // user in between is seen as same-folder by the filter and cross-folder by the
    // merge. That is why these tests drive the door directly instead of through
    // `mergeNSEStagingData`: an end-to-end assertion here would pass for the
    // filter's reason rather than the door's, and prove nothing about the door.
    // A guard whose correctness rests on a fail-open caller-side filter is not a
    // guard (C3 is in the non-recoverable set).

    /// A minimal staged row for driving `nseMergeIdentityConfirmed` directly.
    private func makeStaged(
        accountId: String = "acc1", folderPath: String, messageId: String,
        rfc822: String?, observedUidValidity: Int?
    ) -> NSEDataBridge.StagedMessage {
        NSEDataBridge.StagedMessage(
            id: "\(accountId):\(messageId)",
            accountId: accountId,
            accountEmail: "\(accountId)@example.com",
            provider: "imap_new_mail",
            messageId: messageId,
            rfc822MessageId: rfc822,
            threadId: nil,
            folderPath: folderPath,
            subject: "Staged subject",
            senderName: "Sender",
            senderEmail: "sender@example.com",
            snippet: "staged snippet",
            date: Date().timeIntervalSince1970,
            to: "one@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil,
            references: [],
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false,
            providerLabels: [],
            summaryBlurb: nil, summaryTodos: nil, actionTag: nil,
            reminderDate: nil, reminderTime: nil, reminderContent: nil,
            processedAt: Date().timeIntervalSince1970,
            aiCompleted: true, notified: false,
            htmlContent: nil, textContent: nil, attachmentsJSON: nil,
            icsText: nil, hasUnresolvedCIDs: false,
            observedUidValidity: observedUidValidity
        )
    }

    @Test("Epoch evidence alone never confirms a durable row in a different folder, and does confirm one in the same folder")
    func epochDoorIsScopedToTheRefsOwnFolder() {
        // rfc-less on BOTH sides, so the RFC door cannot adjudicate and door (b)
        // is the only one in play — the exact population step 2's retained
        // rfc-nil tail hands over.
        let staged = makeStaged(folderPath: "INBOX", messageId: "5",
                                rfc822: nil, observedUidValidity: Self.epochB)

        // CROSS-FOLDER: the ref is the Archive row that happens to share UID 5.
        // The epoch offered is INBOX's — correct for the staged row, and evidence
        // about a folder the ref does not live in.
        #expect(NSEDataBridge.nseMergeIdentityConfirmed(
            msg: staged, existingRfc: nil,
            existingFolderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "Archive"),
            folderEpoch: Self.epochB, folderQuarantined: false
        ) == false, "a UID-vs-epoch agreement in one folder says nothing about a row in another")

        // SAME FOLDER: unchanged behaviour — this is what makes the refusal above
        // attributable to the folder operand and not to a blanket denial.
        #expect(NSEDataBridge.nseMergeIdentityConfirmed(
            msg: staged, existingRfc: nil,
            existingFolderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
            folderEpoch: Self.epochB, folderQuarantined: false
        ) == true, "the rfc-less epoch door must still confirm a same-folder row under a settled epoch")

        // Same folder, DISAGREEING epoch — the pre-existing refusal is intact.
        #expect(NSEDataBridge.nseMergeIdentityConfirmed(
            msg: staged, existingRfc: nil,
            existingFolderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
            folderEpoch: Self.epochA, folderQuarantined: false
        ) == false)

        // Same folder, QUARANTINED — the pre-existing refusal is intact.
        #expect(NSEDataBridge.nseMergeIdentityConfirmed(
            msg: staged, existingRfc: nil,
            existingFolderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
            folderEpoch: Self.epochB, folderQuarantined: true
        ) == false)
    }

    @Test("The RFC door still resolves a cross-folder match, and still refuses a cross-folder disagreement")
    func rfcDoorRemainsCrossFolder() {
        let archiveFolderId = MessageIdentity.folderId(accountId: "acc1", folderPath: "Archive")

        // A Gmail/Graph-shaped row: global id, no observed epoch. It moved folders
        // between the NSE fetch and the merge, and MUST still reach its durable row
        // — folder-scoping the RFC door would re-open the duplicate-header class.
        let moved = makeStaged(folderPath: "INBOX", messageId: "7",
                               rfc822: "rfc-moved@example.com", observedUidValidity: nil)
        #expect(NSEDataBridge.nseMergeIdentityConfirmed(
            msg: moved, existingRfc: "rfc-moved@example.com",
            existingFolderId: archiveFolderId,
            folderEpoch: nil, folderQuarantined: false
        ) == true, "an RFC 822 Message-ID is a global identity — door (a) is not folder-scoped")

        // And a positive RFC disagreement still wins over everything, including an
        // epoch agreement in the staged row's own folder.
        let collided = makeStaged(folderPath: "INBOX", messageId: "7",
                                  rfc822: "rfc-staged@example.com", observedUidValidity: Self.epochB)
        #expect(NSEDataBridge.nseMergeIdentityConfirmed(
            msg: collided, existingRfc: "rfc-durable@example.com",
            existingFolderId: MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"),
            folderEpoch: Self.epochB, folderQuarantined: false
        ) == false, "RFC disagreement is proof of two different messages and outranks the epoch door")
    }
}
