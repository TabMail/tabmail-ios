/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
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

    /// How the extension staged the row before the merge. Both reach the cache write of the
    /// merge's existing-header branch (the header phase creates the header first); the
    /// new-header fallback branch has its own tests below.
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

/// Rejects the first commit that inserts a message header, as a transient failure of the
/// merge's header phase would, so the merge takes its full per-message fallback.
private final class FailFirstHeaderCommit: TransactionObserver, @unchecked Sendable {
    private let state = Mutex((pending: false, rejected: 0))
    var rejected: Int { state.withLock { $0.rejected } }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "messageHeader"
    }
    func databaseDidChange(with event: DatabaseEvent) {
        if case .insert = event.kind { state.withLock { $0.pending = true } }
    }
    func databaseWillCommit() throws {
        let refuse = state.withLock { value -> Bool in
            guard value.pending, value.rejected == 0 else { return false }
            value.rejected = 1
            return true
        }
        if refuse { throw NSError(domain: "PhaseOneTransientFailure", code: 1) }
    }
    func databaseDidCommit(_ db: Database) { state.withLock { $0.pending = false } }
    func databaseDidRollback(_ db: Database) { state.withLock { $0.pending = false } }
}

/// The merge's other cache-write leg (header phase failed, the full fallback creates the
/// header), and the update-in-place semantics of an entry that already exists.
extension NSEAICacheUpdatedAtEncodingTests {

    private func openScenario() throws -> (dir: URL, pool: DatabasePool, previous: AppDatabase?, q: DatabaseQueue, path: String) {
        let (dir, pool, previous) = try makeAppDatabase()
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        return (dir, pool, previous, try DatabaseQueue(path: path), path)
    }

    @Test("A header-phase failure still caches the AI result with its own age and cleans staging",
          arguments: [true, false])
    func fallbackLegCachesWithSourceAge(fresh: Bool) async throws {
        let (dir, pool, previous, q, path) = try openScenario()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: [q], directory: dir)
        }
        let failure = FailFirstHeaderCommit()
        try await pool.write { $0.add(transactionObserver: failure, extent: .databaseLifetime) }
        let age = fresh ? 0 : -Double(SyncConfig.aiCacheTTLDays + 1) * 86_400
        let processedAt = Date().timeIntervalSince1970 + age
        try stageRow(q, processedAt: processedAt, aiCompleted: true)
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        #expect(failure.rejected == 1, "the header phase was not made to fail, so this is not the fallback leg")
        let key = cacheKey
        let cached = try await pool.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(cached?.summaryBlurb == "A short summary")
        #expect(cached?.actionTag == .reply)
        #expect(abs((cached?.updatedAt.timeIntervalSince1970 ?? 0) - processedAt) < 0.002)
        #expect(try await pool.read { try MessageHeader.fetchOne($0) } != nil)
        #expect(try await q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_processed_message") } == 0)

        try await pool.write { try $0.execute(sql: "DELETE FROM messageHeader") }
        purge(pool)
        #expect(try await entryExists(pool) == fresh)
    }

    @Test("A staged result updates exactly the AI fields that changed and keeps every peer field",
          arguments: ["summaryBlurb", "summaryTodos", "actionTag", "replyOnlyCache", "blurbNull", "todosNull", "actionNull"])
    func existingEntryUpdatesAIFieldsOnly(changedField: String) async throws {
        let (dir, pool, previous, q, path) = try openScenario()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: [q], directory: dir)
        }
        let key = cacheKey
        let oldDate = Date().addingTimeInterval(-Double(SyncConfig.aiCacheTTLDays + 1) * 86_400)
        // The entry as the main app left it, differing from the staged result in one field only
        // (or holding nothing but a reply).
        let replyOnly = changedField == "replyOnlyCache"
        let incomingTodosNil = changedField == "blurbNull" || changedField == "todosNull"
        let keepsReminder = !replyOnly && changedField != "blurbNull"
        try await pool.write { db in
            var prior = MessageAICache(key: key, rfc822MessageId: Self.rfc822)
            prior.summaryBlurb = (replyOnly || changedField == "blurbNull") ? nil
                : (changedField == "summaryBlurb" ? "An older summary" : "A short summary")
            prior.summaryTodos = (replyOnly || changedField == "blurbNull") ? nil
                : ((changedField == "summaryTodos" || changedField == "todosNull") ? "an older todo" : "todo one")
            prior.actionTag = (replyOnly || changedField == "actionNull") ? nil
                : (changedField == "actionTag" ? .archive : .reply)
            prior.cachedReply = "preserved peer reply"
            prior.replyGeneratedAt = oldDate
            prior.reminderDate = keepsReminder ? "2099-01-01" : nil
            prior.reminderTime = keepsReminder ? "09:00" : nil
            prior.reminderContent = keepsReminder ? "preserved reminder" : nil
            prior.updatedAt = oldDate
            try prior.insert(db)
        }
        let processedAt = Date().timeIntervalSince1970
        try stageRow(q, processedAt: processedAt, aiCompleted: true)
        if incomingTodosNil {
            try await q.write { try $0.execute(sql: "UPDATE nse_processed_message SET summaryTodos = NULL") }
        }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        let after = try await pool.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(after?.summaryBlurb == "A short summary")
        #expect(after?.summaryTodos == (incomingTodosNil ? nil : "todo one"))
        #expect(after?.actionTag == .reply)
        #expect(abs((after?.updatedAt.timeIntervalSince1970 ?? 0) - processedAt) < 0.002)
        #expect(after?.cachedReply == "preserved peer reply")
        #expect(abs((after?.replyGeneratedAt?.timeIntervalSince1970 ?? 0) - oldDate.timeIntervalSince1970) < 0.002)
        #expect(after?.reminderDate == (keepsReminder ? "2099-01-01" : nil))
        #expect(after?.reminderTime == (keepsReminder ? "09:00" : nil))
        #expect(after?.reminderContent == (keepsReminder ? "preserved reminder" : nil))
        #expect(after?.rfc822MessageId == Self.rfc822)
    }

    @Test("A staged summary without its terminal action leaves a known cached action alone",
          arguments: [false, true])
    func incompleteStageKeepsKnownAction(headerPhaseFails: Bool) async throws {
        let (dir, pool, previous, q, path) = try openScenario()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: [q], directory: dir)
        }
        let key = cacheKey
        try await pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: Self.rfc822,
                summaryBlurb: "Prior complete summary", summaryTodos: "prior todo",
                actionTag: .archive, cachedReply: "preserved peer reply", db: db)
        }
        let failure = FailFirstHeaderCommit()
        if headerPhaseFails {
            try await pool.write { $0.add(transactionObserver: failure, extent: .databaseLifetime) }
        }
        try stageRow(q, processedAt: Date().timeIntervalSince1970, aiCompleted: false)
        // The summary is staged before the terminal action vote.
        try await q.write { db in
            try db.execute(sql: """
                UPDATE nse_processed_message SET summaryBlurb = 'A partial summary',
                    summaryTodos = 'todo one', aiCompleted = 0
                """)
        }
        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        #expect(failure.rejected == (headerPhaseFails ? 1 : 0))
        let cached = try await pool.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(cached?.actionTag == .archive)
        #expect(cached?.summaryBlurb == "Prior complete summary")
        #expect(cached?.cachedReply == "preserved peer reply")
        // The staged row is still pending, so the terminal result can land later.
        #expect(try await q.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nse_processed_message WHERE aiCompleted = 0")
        } == 1)
    }
}
