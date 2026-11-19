/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// ADR-IOS-114: an AI result lives as long as its email is on the device, and the orphan purge
/// finds the email by the cache entry's Message-ID alone. An existing entry an older build wrote
/// without one (that `v106_repairAICacheMessageIds` could not fill, because its email had moved)
/// must take the Message-ID from its next write, through either writer, so the purge keeps it while
/// its email is on the device. Neither writer may ever replace a stored Message-ID with NULL.
///
/// Drives the REAL writers (`NSEDataBridge.mergeNSEStagingData`, which reaches
/// `upsertAICacheFromStaging`, and `MessageAICache.writeThrough`) and the REAL
/// `SyncEngine.runPurgeOrphanedAICache`, run past the grace, so the tests pin the property (the
/// entry survives while its email is here), not the SQL.
@Suite("An AI cache entry without a Message-ID takes it from its next write and outlives the purge",
       .serialized, .processGlobalState)
@MainActor
struct AICacheMessageIdFillTests {

    nonisolated private static let accountId = "acc1"
    nonisolated private static let messageId = "msg-1"
    nonisolated private static let rfc822 = "fill-msg-1@example.com"

    private var cacheKey: String {
        MessageIdentity.aiCacheKey(
            accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: Self.rfc822
        )!
    }

    /// The Message-ID an older build left on the entry.
    enum StoredId: String, CaseIterable, CustomStringConvertible {
        case null
        case empty
        var value: String? { self == .null ? nil : "" }
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

    /// A complete staged row, as the extension leaves it, for the email under test.
    private func stageRow(_ q: DatabaseQueue) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId,
                     folderPath, subject, senderName, senderEmail, snippet, date,
                     summaryBlurb, summaryTodos, actionTag,
                     processedAt, aiCompleted, notified, populated)
                VALUES (?, ?, 'user@example.com', 'gmail', ?, ?, 'INBOX',
                        'Subject under test', 'Alice', 'alice@example.com', 'snippet preview', ?,
                        'A short summary', 'todo one', 'reply', ?, 1, 0, 1)
                """, arguments: [
                    "\(Self.accountId):\(Self.messageId)", Self.accountId, Self.messageId, Self.rfc822,
                    Date().timeIntervalSince1970, Date().timeIntervalSince1970
                ])
        }
    }

    /// The staged row, decoded as the merge decodes it.
    private static func decodeStaged(_ queue: DatabaseQueue) throws -> NSEDataBridge.StagedMessage {
        let row = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nse_processed_message")
        })
        return NSEDataBridge.StagedMessage(row: row)
    }

    /// An existing entry under the email's key. `sameResult`: its AI fields equal the staged
    /// result's, so only the Message-ID could make the extension's upsert write anything.
    private func insertPriorEntry(storedId: String?, sameResult: Bool, pool: DatabasePool) async throws {
        let key = cacheKey
        try await pool.write { db in
            var prior = MessageAICache(key: key, rfc822MessageId: storedId)
            prior.summaryBlurb = sameResult ? "A short summary" : "An older summary"
            prior.summaryTodos = "todo one"
            prior.actionTag = .reply
            prior.cachedReply = "An older reply"
            prior.updatedAt = Date().addingTimeInterval(-Double(SyncConfig.aiCacheOrphanGraceDays + 1) * 86_400)
            try prior.insert(db)
        }
    }

    /// Storage maintenance's purge, run once the orphan grace has passed since every write here.
    private func purgePastGrace(_ pool: DatabasePool) {
        SyncEngine.runPurgeOrphanedAICache(
            dbPool: PrioritizedDatabase(pool: pool),
            now: Date().addingTimeInterval(Double(SyncConfig.aiCacheOrphanGraceDays + 1) * 86_400)
        )
    }

    private func entry(_ pool: DatabasePool) async throws -> MessageAICache? {
        let key = cacheKey
        return try await pool.read { try MessageAICache.fetchOne($0, key: key) }
    }

    private func emailIsOnDevice(_ pool: DatabasePool) async throws -> Bool {
        try await pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == Self.accountId && Column("rfc822MessageId") == Self.rfc822)
                .fetchCount(db) > 0
        }
    }

    @Test("The extension's merge fills a missing Message-ID, and the entry outlives the purge while its email is here",
          arguments: StoredId.allCases, [true, false])
    func extensionMergeFillsMissingId(stored: StoredId, sameResult: Bool) async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        let q = try DatabaseQueue(path: path)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: [q], directory: dir)
        }
        try await insertPriorEntry(storedId: stored.value, sameResult: sameResult, pool: pool)
        try stageRow(q)

        await NSEDataBridge.mergeNSEStagingData(stagingPathOverride: path)

        #expect(try await emailIsOnDevice(pool), "the merge did not put the email on the device")
        let written = try await entry(pool)
        #expect(written?.summaryBlurb == "A short summary")
        #expect(written?.cachedReply == "An older reply")
        #expect(written?.rfc822MessageId == Self.rfc822,
                "\(stored), sameResult \(sameResult): the entry still has no Message-ID after the extension's write")

        purgePastGrace(pool)
        #expect(try await entry(pool) != nil,
                "\(stored), sameResult \(sameResult): the purge removed an entry whose email is on the device")
    }

    @Test("writeThrough fills a missing Message-ID, and the entry outlives the purge while its email is here",
          arguments: StoredId.allCases, ["summary", "action", "reply"])
    func writeThroughFillsMissingId(stored: StoredId, write: String) async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: [], directory: dir)
        }
        try await insertPriorEntry(storedId: stored.value, sameResult: true, pool: pool)
        try await pool.write { db in
            var header = MessageHeader(
                messageId: Self.messageId, subject: "Plans", from: "Alice", fromAddress: "alice@example.com",
                to: "user@example.com", date: Date(), snippet: "snippet",
                folderId: "\(Self.accountId):INBOX", accountId: Self.accountId, folderPath: "INBOX",
                isInInbox: true)
            header.rfc822MessageId = Self.rfc822
            try header.insert(db)

            switch write {
            case "summary":
                try MessageAICache.writeThrough(
                    accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: Self.rfc822,
                    summaryBlurb: "A new summary", summaryTextMessage: "A new text", db: db)
            case "action":
                try MessageAICache.writeThrough(
                    accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: Self.rfc822,
                    actionTag: .archive, db: db)
            default:
                try MessageAICache.writeThrough(
                    accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: Self.rfc822,
                    cachedReply: "A new reply", replyTextMessage: "A new reply text", db: db)
            }
        }

        #expect(try await emailIsOnDevice(pool))
        let written = try await entry(pool)
        #expect(written?.rfc822MessageId == Self.rfc822,
                "\(stored), \(write): the entry still has no Message-ID after writeThrough")

        purgePastGrace(pool)
        #expect(try await entry(pool) != nil,
                "\(stored), \(write): the purge removed an entry whose email is on the device")
    }

    @Test("The extension's upsert never replaces a stored Message-ID with NULL", arguments: [true, false])
    func extensionUpsertKeepsStoredId(sameResult: Bool) async throws {
        let (dir, pool, previous) = try makeAppDatabase()
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        AppDatabase.createNSEStagingDB(atPath: path)
        let q = try DatabaseQueue(path: path)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pools: [pool], queues: [q], directory: dir)
        }
        try await insertPriorEntry(storedId: Self.rfc822, sameResult: sameResult, pool: pool)
        try stageRow(q)
        let staged = try Self.decodeStaged(q)
        let key = cacheKey

        try await pool.write { db in
            try NSEDataBridge.upsertAICacheFromStaging(staged, cacheKey: key, rfc822MessageId: nil, db: db)
        }

        let written = try await entry(pool)
        // The write itself happened when the result differed, so the kept Message-ID is not a skipped write.
        #expect(written?.summaryBlurb == "A short summary")
        #expect(written?.rfc822MessageId == Self.rfc822)
    }
}
