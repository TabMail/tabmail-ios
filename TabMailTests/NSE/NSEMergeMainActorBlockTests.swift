/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Reproduces — and then guards against regression of — the foreground-return UI
/// freeze (field report ~20s on iOS 26.5 / iPhone 16 Pro, Gmail, app opened only
/// every few days).
///
/// Root cause: `NSEDataBridge.mergeNSEStagingData` runs its
/// `AppDatabase.dbPool.write` **synchronously on the `@MainActor` caller**
/// (`SyncScheduler.startForegroundPolling` and the other foreground/push entry
/// points). GRDB's `DatabasePool` serializes ALL writes through a single writer
/// connection, so when a sync/backfill/FTS write is already in flight on
/// foreground return, the merge's write waits behind it — and because that wait
/// is a synchronous call on the main actor, it FREEZES the UI for the full
/// duration (the writer-serialization wait is NOT capped by `busyMode`). The
/// merge's own row work is trivial (a few hundred rows merge in <200ms); the
/// freeze is the contention wait, not the row count.
///
/// The fix routes the merge through the async `dbPool.write` overload, which
/// suspends the caller instead of blocking the thread — the main actor stays
/// live while the writer wait happens on GRDB's own writer queue.
///
/// This drives the REAL `NSEDataBridge.mergeNSEStagingData` against a real
/// pool-backed `AppDatabase` and a real staging DB (built at a temp path via the
/// `stagingPathOverride` test seam — the unit-test host has no App Group
/// entitlement). A `@MainActor` heartbeat measures whether the UI could make any
/// progress while a background writer held the single writer connection:
///   • BEFORE the fix (synchronous write): ~0 heartbeats → main actor frozen.
///   • AFTER the fix (async write): heartbeat keeps ticking → main actor live.
@Suite("NSE merge must not block the main actor", .serialized)
@MainActor
struct NSEMergeMainActorBlockTests {

    /// Heartbeat on the main actor. The loop increments `ticks` every ~20ms — but
    /// it can ONLY run when the main actor is free. While the main actor is blocked
    /// (a synchronous `dbPool.write` waiting behind an in-flight writer), the loop
    /// is starved and `ticks` stops advancing. So the number of ticks accrued
    /// during the merge window is the robust freeze probe: ≈ window/20ms if the UI
    /// stayed responsive, ~0 if it was frozen. (A max-gap *duration* metric is NOT
    /// used: the post-unblock heartbeat resume races the test reading it, so a gap
    /// value reports a stale ~20ms — the tick count, read immediately after the
    /// merge returns, does not have that race.)
    @MainActor
    final class Heartbeat {
        private(set) var ticks = 0
        private var running = true
        private var task: Task<Void, Never>?
        func start() {
            task = Task { @MainActor in
                while running {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        func stop() { running = false; task?.cancel() }
    }

    /// Build a real temp-file `DatabasePool` (WAL, single writer, busyMode 5s —
    /// matching `AppDatabase.makePool`) and register it as `AppDatabase.shared`
    /// so the merge's `AppDatabase.dbPool.write` hits it. Returns the previous
    /// shared instance for restoration.
    private func makeAppDatabase() throws -> (dir: URL, pool: DatabasePool, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 64
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)   // runs schema migrations
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        // Seed the account + INBOX folder the merge's insert path expects
        // (FK accountId -> account; inbox detection for the recount).
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
        }
        return (dir, pool, previous)
    }

    /// Build a REAL staging DB at `dir` (real schema via `AppDatabase`'s creator)
    /// and stage `count` `populated=1` rows the merge will SELECT and insert.
    private func makeStagingDB(in dir: URL, count: Int) throws -> String {
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            for i in 0..<count {
                try db.execute(sql: """
                    INSERT INTO nse_processed_message
                        (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                         folderPath, subject, senderName, senderEmail, snippet, date,
                         processedAt, populated)
                    VALUES (?, 'acc1', 'user@example.com', 'gmail', ?, ?, 'INBOX', ?,
                            'Alice', 'alice@example.com', 'snippet preview', ?, ?, 1)
                    """, arguments: [
                        "acc1:msg-\(i)", "msg-\(i)", "rfc-\(i)@example.com",
                        "Subject under test \(i)", Double(1_710_000_000 + i),
                        Date().timeIntervalSince1970
                    ])
            }
        }
        return path
    }

    @Test("Real mergeNSEStagingData keeps the main actor responsive under writer contention")
    func mergeDoesNotFreezeMainActor() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let stagedCount = 200   // realistic foreground catch-up volume (hundreds)
        let stagingPath = try makeStagingDB(in: dir, count: stagedCount)

        let hb = Heartbeat()
        hb.start()
        try await Task.sleep(for: .milliseconds(120))   // let the heartbeat settle

        // REAL foreground-return maintenance contention — NO Thread.sleep. A
        // background bulk write of `maintenanceRows` header+body rows into the
        // SAME main pool, representing the sync / backfill / FTS-membership
        // self-heal pass that runs over the EXISTING mailbox at foreground return
        // and holds GRDB's single writer connection. This is the real contention
        // source (the new-mail catch-up is only hundreds of rows; the writer is
        // held by maintenance over the archive). The merge's write must queue
        // behind it. NOTE: the simulator runs on Mac-class storage, so the
        // absolute duration here is a FRACTION of a real device's — this proves
        // the SHAPE (merge inherits the maintenance wait), not the 20s magnitude.
        let maintenanceRows = 18_000
        let bodyHTML = "<html><body>"
            + String(repeating: "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod.</p>", count: 60)
            + "</body></html>"
        let bg = Task.detached {
            try? await pool.write { db in
                for i in 0..<maintenanceRows {
                    var h = MessageHeader(
                        messageId: "arch-\(i)", subject: "Archived message \(i)",
                        from: "Sender \(i)", fromAddress: "s\(i)@example.com",
                        to: "user@gmail.com",
                        date: Date(timeIntervalSince1970: Double(1_600_000_000 + i)),
                        snippet: "archived snippet \(i)",
                        folderId: "acc1:INBOX", accountId: "acc1",
                        folderPath: "INBOX", isInInbox: true)
                    h.isRead = true
                    try h.insert(db)
                    try MessageBody(headerId: h.id, htmlContent: bodyHTML).insert(db)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))   // let the maintenance write grab the writer first

        // THE REAL FLOW: foreground NSE merge invoked DIRECTLY on the main actor.
        // CRITICAL: do NOT wrap this in `clock.measure { }` or any async helper —
        // a nonisolated async wrapper hops execution onto the generic executor and
        // would move the merge OFF the main actor, masking the very freeze we're
        // measuring (it gave a false 22ms for the synchronous merge). Time it with
        // CFAbsoluteTimeGetCurrent, which never hops executors.
        let ticksBefore = hb.ticks
        let t0 = CFAbsoluteTimeGetCurrent()
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: stagingPath)
        let mergeWallMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        // ROBUST freeze probe: heartbeats that accrued DURING the merge window.
        // A responsive main actor ticks the ~20ms heartbeat ≈ mergeWallMs/20 times;
        // a frozen one can't tick at all (~0). (We assert on this COUNT, not a
        // gap duration — the post-unblock heartbeat resume races the test reading
        // a max-gap value, so a gap metric reports a stale ~20ms. The count is read
        // immediately after the merge returns, before the heartbeat resumes.)
        let ticksDuringMerge = hb.ticks - ticksBefore
        _ = await bg.value
        hb.stop()

        let expectedTicks = max(1, mergeWallMs / 20)
        print("[NSEMergeTest] maintenance=\(maintenanceRows) rows | catch-up=\(stagedCount) mails | "
              + "merge wall-clock=\(mergeWallMs)ms (waited behind maintenance) | "
              + "heartbeats during merge=\(ticksDuringMerge) (≈\(expectedTicks) if responsive, ~0 if frozen)")

        // Correctness: the merge landed every staged header. Merged rows have
        // messageId 'msg-*'; the maintenance archive rows are 'arch-*'.
        let merged = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE messageId LIKE 'msg-%'") ?? 0
        }
        #expect(merged == stagedCount, "merge should insert all \(stagedCount) staged headers, got \(merged)")

        // Guard the test actually created contention — the merge must have WAITED
        // behind the maintenance write (else mergeWallMs is tiny and the
        // responsiveness check is vacuous). 18k header+body rows reliably hold the
        // writer >0.5s on the simulator.
        #expect(mergeWallMs > 500, "test did not create writer contention (merge wall \(mergeWallMs)ms)")

        // The merge's write still WAITS behind the maintenance write (GRDB's
        // writer is serial — unavoidable; see merge wall-clock). What must NOT
        // happen is the MAIN ACTOR being frozen for that wait. A responsive main
        // actor ticks the ~20ms heartbeat ~mergeWallMs/20 times during the merge
        // (~140 over ~2.9s); a frozen one ticks ~0. A fixed floor of 10 (=200ms of
        // responsiveness) cleanly separates the two without the expectedTicks/4
        // degenerate-to-0 window when mergeWallMs is small.
        #expect(
            ticksDuringMerge > 10,
            "main actor was STARVED: only \(ticksDuringMerge) heartbeats during a \(mergeWallMs)ms merge (~\(expectedTicks) expected if responsive) — the merge blocked the UI"
        )

        // Drain the merge's fire-and-forget side-effect Tasks (recountInboxFolders,
        // .inboxDataDidChange) against the TEST database BEFORE `defer` restores
        // AppDatabase.shared. Otherwise a late recount reads AppDatabase.dbPool
        // (force-unwraps `shared!`) after it's been restored to nil and crashes the
        // whole test process (CLAUDE.md Testing Rule 9).
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Data-integrity regression: a background `task_alarm` merge can run
    /// concurrently with a foreground merge and both read the same
    /// `nse_pending_task_result` row before either deletes it. The pre-fix code
    /// inserted the result turn with a fresh `UUID()`, so the two writers produced
    /// TWO identical `chatTurn` rows. The fix uses a deterministic id derived from
    /// the staging row + `INSERT OR IGNORE`. This test simulates the overlap by
    /// consuming the SAME staging row twice and asserts exactly ONE turn lands.
    @Test("Task-result consumption dedups to ONE chatTurn (deterministic id, not UUID)")
    func taskResultConsumptionIsIdempotent() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let stagingPath = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: stagingPath)

        // Stage the SAME task-result row (explicit id=1 + fixed timestamp) so both
        // merge passes see identical content — exactly what two concurrent merges
        // reading the row before either deletes it would see.
        func stageTaskResult() throws {
            let q = try DatabaseQueue(path: stagingPath)
            try q.write { db in
                try db.execute(sql: """
                    INSERT INTO nse_pending_task_result (id, taskName, taskInstruction, result, timestamp)
                    VALUES (1, 'Daily digest', 'summarize inbox', 'Your daily digest is ready.', ?)
                    """, arguments: [1_710_000_000.0])
            }
        }

        func taskTurnCount() async throws -> Int {
            try await pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatTurn WHERE type = 'task'") ?? 0
            }
        }

        // First merge: consumes the row -> one turn, staging row deleted.
        try stageTaskResult()
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: stagingPath)
        let after1 = try await taskTurnCount()
        #expect(after1 == 1, "first merge should write exactly one task chatTurn, got \(after1)")

        // Re-stage the identical row and merge again (the "second concurrent merge"
        // that read the same row). With the UUID bug this produced a 2nd turn;
        // with the deterministic id + INSERT OR IGNORE it must stay at one.
        try stageTaskResult()
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: stagingPath)
        let after2 = try await taskTurnCount()
        #expect(after2 == 1, "re-consuming the same task result must dedup to ONE chatTurn, got \(after2)")

        try? await Task.sleep(for: .milliseconds(300))   // drain fire-and-forget tasks before teardown
    }
}
