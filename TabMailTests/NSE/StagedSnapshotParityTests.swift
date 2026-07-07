/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Refactor safety for the `StagedMessage(row:)` / `.toInboxRow()` /
/// `.toBodySnapshot()` extraction: the merge must build the SAME
/// `latestStagedRows` / `latestStagedBodies` snapshot the inline code built
/// before the extraction. These snapshots are the single read-model every
/// staged-not-yet-durable consumer relies on (inbox `insertStagedRows`, the
/// detail view's `seedAtInit` + `.messagesStaged` seed, `stagedBodyFallback`),
/// so a field drift here silently breaks the reveal path.
///
/// Drives the REAL merge + REAL staging file via the `stagingPathOverride` seam
/// (unit-test host has no App Group entitlement), same harness as
/// `NSEGradualMergeTests`.
@Suite("Merge staged-snapshot parity", .serialized)
@MainActor
struct StagedSnapshotParityTests {

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
            let prev = current; current = appDb; return prev
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

    /// Stage 1 — header only (`populated=1`), mirroring `NSEStagingDB.stageHeader`.
    private func stageHeaderRow(
        _ q: DatabaseQueue, accountId: String = "acc1", messageId: String = "msg-1",
        subject: String = "Subject under test"
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, ?, 'user@example.com', 'gmail', ?, ?, 'INBOX',
                        ?, 'Alice', 'alice@example.com', 'snippet preview', ?,
                        ?, 0, 0, 1)
                """, arguments: [
                    "\(accountId):\(messageId)", accountId, messageId, "rfc-\(messageId)@example.com",
                    subject, Double(1_710_000_000), Date().timeIntervalSince1970
                ])
        }
    }

    /// Stage 2 — a usable rendered body (mirrors `NSEStagingDB.stageBody`).
    private func stageBodyRow(
        _ q: DatabaseQueue, accountId: String = "acc1", messageId: String = "msg-1",
        html: String = "<p>Hello body</p>"
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET
                    htmlContent = ?, textContent = 'Hello body', hasUnresolvedCIDs = 0
                WHERE id = ?
                """, arguments: [html, "\(accountId):\(messageId)"])
        }
    }

    /// Stage 2 — a body left with an unresolved inline CID (must be excluded).
    private func stageCIDBodyRow(
        _ q: DatabaseQueue, accountId: String = "acc1", messageId: String = "msg-1"
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET
                    htmlContent = ?, textContent = 'Newsletter', hasUnresolvedCIDs = 1
                WHERE id = ?
                """, arguments: [
                    "<p>Newsletter</p><img src=\"cid:logo@x\">", "\(accountId):\(messageId)"
                ])
        }
    }

    private func headerId(_ messageId: String, accountId: String = "acc1") -> String {
        MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: messageId)
    }

    // MARK: - Snapshot parity

    @Test("merge builds the staged row + body snapshot for a header+body row")
    func mergeParityHeaderAndBody() async throws {
        let (dir, _, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            try? FileManager.default.removeItem(at: dir)
        }
        let staging = try makeStagingFile(in: dir)
        try stageHeaderRow(staging.queue, subject: "Parity subject")
        try stageBodyRow(staging.queue, html: "<p>parity body</p>")

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: staging.path)

        let rows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].accountId == "acc1")
        #expect(rows[0].messageId == "msg-1")
        #expect(rows[0].subject == "Parity subject")
        #expect(rows[0].headerId == headerId("msg-1"))

        let bodies = NSEDataBridge.latestStagedBodies.withLock { $0 }
        #expect(bodies[headerId("msg-1")]?.htmlContent == "<p>parity body</p>")
    }

    @Test("merge excludes an unresolved-CID body from the body snapshot but keeps the header")
    func mergeParityExcludesCID() async throws {
        let (dir, _, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            try? FileManager.default.removeItem(at: dir)
        }
        let staging = try makeStagingFile(in: dir)
        try stageHeaderRow(staging.queue)
        try stageCIDBodyRow(staging.queue)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: staging.path)

        let rows = NSEDataBridge.latestStagedRows.withLock { $0 }
        #expect(rows.count == 1, "header still surfaces")
        let bodies = NSEDataBridge.latestStagedBodies.withLock { $0 }
        #expect(bodies[headerId("msg-1")] == nil, "CID body excluded from snapshot")
    }
}
