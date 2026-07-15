/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Coverage for the boot paint gate (2026-07-03): first paint must wait only
/// for the merge's IN-MEMORY staged snapshot (`latestStagedRows` + queued
/// `.messagesStaged`), never for phase-1's durable write — measured 7.6s on a
/// cold-I/O boot (boot_logs 5) for a 2-row header upsert.
///
/// Drives the REAL `NSEDataBridge.mergeNSEStagingData` via the
/// `stagingPathOverride` test seam (same harness as `NSEGradualMergeTests`).
@Suite("NSE boot paint gate", .serialized, .processGlobalState)
@MainActor
struct NSEPaintGateTests {

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

    /// Header-only staged row (`populated=1, aiCompleted=0`), mirroring
    /// `NSEStagingDB.stageHeader`.
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

    nonisolated private func headerId(_ messageId: String = "msg-1") -> String {
        MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: messageId)
    }

    // MARK: - Snapshot-callback ordering

    @Test("onSnapshotPublished fires with the snapshot in memory, BEFORE the durable header write")
    func callbackFiresBeforeDurableWrite() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        let (path, q) = try makeStagingFile(in: dir)
        try stageHeaderRow(q)

        let hid = headerId()
        // Captured AT callback time: fire count, whether the snapshot held the
        // row, and whether the header was already durable (it must NOT be —
        // the callback's whole point is to precede the slow phase-1 write).
        let observed = Mutex<(fires: Int, snapshotHasRow: Bool, durableAtFire: Bool)>((0, false, false))
        await NSEDataBridge.mergeNSEStagingData(
            stagingPathOverride: path,
            onSnapshotPublished: {
                let snapshotHasRow = NSEDataBridge.latestStagedRows.withLock { rows in
                    rows.contains { $0.headerId == hid }
                }
                let durable = (try? pool.read { db in
                    try MessageHeader.fetchOne(db, key: hid) != nil
                }) ?? false
                observed.withLock {
                    $0.fires += 1
                    $0.snapshotHasRow = snapshotHasRow
                    $0.durableAtFire = durable
                }
            }
        )

        let (fires, snapshotHasRow, durableAtFire) = observed.withLock { $0 }
        #expect(fires == 1)
        #expect(snapshotHasRow, "snapshot must be published before the callback fires")
        #expect(!durableAtFire, "callback must fire BEFORE phase-1's durable write")
        // And after the merge completes, the header IS durable.
        let durableAfter = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: hid) != nil
        }
        #expect(durableAfter)
    }

    @Test("onSnapshotPublished fires even when the .messagesStaged post is suppressed (unchanged KEPT set)")
    func callbackFiresWhenPostSuppressed() async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            try? FileManager.default.removeItem(at: dir)
        }
        _ = pool
        let (path, q) = try makeStagingFile(in: dir)
        try stageHeaderRow(q)

        let fires = Mutex<Int>(0)
        // First merge posts; the KEPT gradual row (aiCompleted=0) survives, so
        // the second merge re-reads the SAME set and suppresses the re-post —
        // but the paint gate still needs its callback (the snapshot was
        // republished either way).
        await NSEDataBridge.mergeNSEStagingData(
            stagingPathOverride: path,
            onSnapshotPublished: { fires.withLock { $0 += 1 } }
        )
        await NSEDataBridge.mergeNSEStagingData(
            stagingPathOverride: path,
            onSnapshotPublished: { fires.withLock { $0 += 1 } }
        )
        let total = fires.withLock { $0 }
        #expect(total == 2)
    }

    @Test("paint gate returns promptly when no staging is pending")
    func paintGateReleasesWhenNothingPending() async {
        // Test host has no App Group container, so the pending probe answers
        // nil and no merge (hence no snapshot) ever runs — the gate must be
        // released by the completion path, not hang.
        await NSEDataBridge.mergeIfStagingPendingPaintGate()
        #expect(Bool(true), "gate released without a snapshot publication")
    }

    // MARK: - OneShotGate semantics

    @Test("OneShotGate: wait-then-open resumes; only the first open transitions")
    func oneShotGateWaitThenOpen() async {
        let gate = OneShotGate()
        let released = Mutex<Bool>(false)
        let waiter = Task {
            await gate.wait()
            released.withLock { $0 = true }
        }
        let first = gate.open()
        let second = gate.open()
        await waiter.value
        let didRelease = released.withLock { $0 }
        #expect(first)
        #expect(!second)
        #expect(didRelease)
    }

    @Test("OneShotGate: wait after open returns immediately")
    func oneShotGateOpenThenWait() async {
        let gate = OneShotGate()
        let first = gate.open()
        #expect(first)
        await gate.wait()
        #expect(Bool(true), "wait returned on an already-open gate")
    }
}
