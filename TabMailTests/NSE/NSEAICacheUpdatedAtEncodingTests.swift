/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// #395 — an AI cache entry the notification extension staged and the main app merged
/// must age like every other entry: the TTL purge (`updatedAt < cutoff`) may only
/// remove it once it is actually older than the TTL.
///
/// The merge used to bind `updatedAt` as the staged `processedAt` NUMBER while every
/// other writer stores GRDB's `Date` TEXT. SQLite orders every number below every
/// text value, so the purge counted a fresh extension-written entry as expired at once.
///
/// Drives the REAL `NSEDataBridge.mergeNSEStagingData` (through the staging-path test
/// seam) and the REAL `SyncEngine.runPurgeExpiredAICache`, so it pins the property
/// (a fresh entry survives, an old one does not), not the column's storage class.
@Suite("NSE-written AI cache entries age like any other (#395)", .serialized, .processGlobalState)
@MainActor
struct NSEAICacheUpdatedAtEncodingTests {

    nonisolated private static let accountId = "acc1"
    nonisolated private static let messageId = "msg-1"
    nonisolated private static let rfc822 = "rfc-msg-1@example.com"

    private var cacheKey: String {
        MessageIdentity.aiCacheKey(
            accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: Self.rfc822
        )!
    }

    /// How the extension staged the row before the merge. Both reach the cache write in
    /// the merge's AI phase (the header is created by the header phase first, so the
    /// merge's "header not in main DB" branch is not reachable through this seam; it
    /// calls the same `upsertAICacheFromStaging`).
    enum Branch: String, CaseIterable, CustomStringConvertible {
        /// Header-only stage merged first, the AI result merged on a later wake.
        case headerThenResult
        /// One row, already complete, merged in a single pass.
        case completeInOneStage
        var description: String { rawValue }
    }

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
            acc.id = Self.accountId
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId).insert(db)
        }
        return (dir, pool, previous)
    }

    /// A staged row as the extension leaves it: populated, with its AI result done.
    /// `aiCompleted` is set last in production; here it is written in one INSERT.
    private func stageRow(
        _ q: DatabaseQueue, processedAt: Double, aiCompleted: Bool
    ) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     summaryBlurb, summaryTodos, actionTag,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, ?, 'user@example.com', 'gmail', ?, ?, 'INBOX',
                        'Subject under test', 'Alice', 'alice@example.com', 'snippet preview', ?,
                        ?, ?, ?, ?, ?, 0, 1)
                """, arguments: [
                    "\(Self.accountId):\(Self.messageId)", Self.accountId, Self.messageId, Self.rfc822,
                    Double(1_710_000_000),
                    aiCompleted ? "A short summary" : nil, aiCompleted ? "todo one" : nil,
                    aiCompleted ? "reply" : nil,
                    processedAt, aiCompleted ? 1 : 0
                ])
        }
    }

    /// Merge the extension's AI result into the main DB through `branch`, leaving the
    /// cache entry stamped from `processedAt`.
    private func mergeAIResult(
        branch: Branch, processedAt: Double, pool: DatabasePool, q: DatabaseQueue, path: String
    ) async throws {
        switch branch {
        case .headerThenResult:
            // Header-only first (creates the header), then the AI result lands on it.
            // The header stage is stamped now (an old header-only row would be treated
            // as abandoned); `processedAt` is applied with the AI result.
            try stageRow(q, processedAt: Date().timeIntervalSince1970, aiCompleted: false)
            await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
            try await q.write { db in
                try db.execute(sql: """
                    UPDATE nse_processed_message SET
                        summaryBlurb = 'A short summary', summaryTodos = 'todo one',
                        actionTag = 'reply', aiCompleted = 1, processedAt = ?
                    """, arguments: [processedAt])
            }
            await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        case .completeInOneStage:
            try stageRow(q, processedAt: processedAt, aiCompleted: true)
            await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)
        }
    }

    private func purge(_ pool: DatabasePool) {
        SyncEngine.runPurgeExpiredAICache(dbPool: PrioritizedDatabase(pool: pool))
    }

    private func entryExists(_ pool: DatabasePool) async throws -> Bool {
        let key = cacheKey
        return try await pool.read { try MessageAICache.fetchOne($0, key: key) != nil }
    }

    /// Run one scenario: merge an AI result stamped `processedAt` through `branch`,
    /// drop the header (a move in flight, a UIDVALIDITY reset), purge, and report
    /// whether the cache entry is still there.
    private func entrySurvivesPurge(branch: Branch, processedAt: Double) async throws -> Bool {
        let (dir, pool, previous) = try makeAppDatabase()
        var ownedQueues: [DatabaseQueue] = []
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: ownedQueues, directory: dir)
        }
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        let q = try DatabaseQueue(path: path)
        ownedQueues.append(q)

        try await mergeAIResult(branch: branch, processedAt: processedAt, pool: pool, q: q, path: path)

        // Precondition: the merge wrote the entry (otherwise "survives" proves nothing).
        guard try await entryExists(pool) else {
            Issue.record("\(branch): the merge did not write the AI cache entry")
            return false
        }
        // The header goes missing, so the purge's inbox rescue cannot save the entry.
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = ?", arguments: [Self.accountId])
        }
        purge(pool)
        return try await entryExists(pool)
    }

    @Test("A fresh extension-written entry survives the TTL purge when its header is missing",
          arguments: Branch.allCases)
    func freshEntrySurvives(branch: Branch) async throws {
        let survived = try await entrySurvivesPurge(
            branch: branch, processedAt: Date().timeIntervalSince1970
        )
        #expect(survived, "\(branch): a just-written entry was purged inside the TTL")
    }

    @Test("An extension-written entry older than the TTL is still purged (the purge can say no)",
          arguments: Branch.allCases)
    func expiredEntryIsPurged(branch: Branch) async throws {
        let expired = Date().addingTimeInterval(-Double(SyncConfig.aiCacheTTLDays + 1) * 86_400)
        let survived = try await entrySurvivesPurge(
            branch: branch, processedAt: expired.timeIntervalSince1970
        )
        #expect(!survived, "\(branch): an entry older than the TTL was kept")
    }
}
