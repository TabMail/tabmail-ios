/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The AI cache's expiry, `SyncEngine.runPurgeExpiredAICache`, run for real on a migrated
/// on-disk database. The AI queue runs it each time it drains and maintenance runs it on
/// its pass, so these are the properties both give the user (ADR-IOS-078):
/// - an entry nobody has written for `SyncConfig.aiCacheTTLDays` is deleted, unless its
///   message is in an inbox now, in which case it stays and its clock restarts;
/// - inbox membership comes from every copy of the message, never from the entry's key:
///   the key names the folder the AI ran in, which is still the inbox after an archive;
/// - one run handles every expired entry, however many batches that takes;
/// - every statement it runs reads through an index (ADR-IOS-029).
@Suite("AI cache expiry")
struct AICacheExpiryTests {

    private static let accountId = "acc1"

    /// Every statement the pool ran, with its bound values inlined so it can be planned
    /// afterwards. `expandedDescription`, not `description`: see
    /// `SearchScopedPageTests.SQLTape` for why. The fixtures hold only example.com data.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        func drain() -> [String] {
            statements.withLock { buffer in
                let all = buffer
                buffer = []
                return all
            }
        }
    }

    private struct Env {
        let pool: DatabasePool
        let directory: URL
        let tape: SQLTape
    }

    private func makeEnv() throws -> Env {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-cache-expiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tape = SQLTape()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            var account = Account(emailAddress: "user@example.com", displayName: "User", provider: .imap)
            account.id = Self.accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: Self.accountId).insert(db)
        }
        return Env(pool: pool, directory: directory, tape: tape)
    }

    private func finish(_ env: Env) {
        TestDatabaseTeardown.closeThenUnlinkNow(pool: env.pool, directory: env.directory)
    }

    /// One copy of a message: a header in `folderPath`.
    private struct Copy {
        let uid: String
        let folderPath: String
        let rfc: String
        var date = Date()
        var isInInbox: Bool { folderPath == "INBOX" }
    }

    private func insert(_ env: Env, copies: [Copy]) throws {
        try env.pool.write { db in
            for copy in copies {
                var header = MessageHeader(
                    messageId: copy.uid, subject: "s", from: "a@example.com",
                    fromAddress: "a@example.com", to: "user@example.com", date: copy.date,
                    snippet: "", folderId: "\(Self.accountId):\(copy.folderPath)",
                    accountId: Self.accountId, folderPath: copy.folderPath,
                    isInInbox: copy.isInInbox)
                header.rfc822MessageId = copy.rfc
                try header.insert(db)
            }
        }
    }

    /// An entry as the AI writes it: keyed by the folder the AI ran in, the inbox.
    @discardableResult
    private func insertEntry(_ env: Env, rfc: String?, key: String? = nil, updatedAt: Date) throws -> String {
        let entryKey = key ?? MessageAICache.cacheKey(
            accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: rfc) ?? ""
        try env.pool.write { db in
            var entry = MessageAICache(key: entryKey, rfc822MessageId: rfc)
            entry.summaryBlurb = "summary"
            entry.updatedAt = updatedAt
            try entry.insert(db)
        }
        return entryKey
    }

    private func purge(_ env: Env) {
        SyncEngine.runPurgeExpiredAICache(dbPool: PrioritizedDatabase(pool: env.pool, priority: .background))
    }

    /// Every entry left, key to `updatedAt`.
    private func entries(_ env: Env) throws -> [String: Date] {
        let all = try env.pool.read { try MessageAICache.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0.updatedAt) })
    }

    private var expired: Date {
        Date().addingTimeInterval(-Double(SyncConfig.aiCacheTTLDays + 1) * 86_400)
    }

    private var cutoff: Date {
        Date().addingTimeInterval(-Double(SyncConfig.aiCacheTTLDays) * 86_400)
    }

    // MARK: - What expires

    @Test("An archived message's expired entry is deleted though its key names the inbox; an inbox message's stays")
    func expiryFollowsTheMessageNotTheKey() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let fresh = Date().addingTimeInterval(-3_600)
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: "archived@example.com"),
            Copy(uid: "2", folderPath: "INBOX", rfc: "inbox@example.com"),
            Copy(uid: "3", folderPath: "Archive", rfc: "recent@example.com")
        ])
        let archivedKey = try insertEntry(env, rfc: "archived@example.com", updatedAt: expired)
        let inboxKey = try insertEntry(env, rfc: "inbox@example.com", updatedAt: expired)
        let recentKey = try insertEntry(env, rfc: "recent@example.com", updatedAt: fresh)
        let start = Date()

        purge(env)

        let after = try entries(env)
        #expect(after[archivedKey] == nil, "an archived message's entry outlived the TTL")
        let inboxClock = try #require(after[inboxKey], "an inbox message's entry was deleted")
        #expect(inboxClock >= start.addingTimeInterval(-1), "a kept inbox entry's clock did not restart")
        let recentClock = try #require(after[recentKey], "an entry inside the TTL was deleted")
        let recentDrift = abs(recentClock.timeIntervalSince(fresh))
        #expect(recentDrift < 0.002, "an entry inside the TTL was rewritten")
    }

    @Test("The inbox check reads every copy of the message, however many there are")
    func inboxCheckReadsEveryCopy() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let rfc = "many-copies@example.com"
        // Five older copies outside the inbox (as labels give on Gmail), then the inbox
        // copy, which sorts last in the message-id index.
        let now = Date()
        var copies = (1...5).map {
            Copy(uid: "\(10 + $0)", folderPath: "Archive", rfc: rfc, date: now.addingTimeInterval(-Double(100 - $0)))
        }
        copies.append(Copy(uid: "2", folderPath: "INBOX", rfc: rfc, date: now))
        try insert(env, copies: copies)
        let key = try insertEntry(env, rfc: rfc, updatedAt: expired)

        purge(env)

        let after = try entries(env)
        #expect(after[key] != nil, "the entry of a message that is in the inbox was deleted")
    }

    @Test("An expired entry with no Message-ID is deleted", arguments: [nil, ""] as [String?])
    func entryWithoutMessageIdIsDeleted(rfc: String?) throws {
        let env = try makeEnv()
        defer { finish(env) }
        let key = try insertEntry(env, rfc: rfc, key: "\(Self.accountId):INBOX:no-id", updatedAt: expired)

        purge(env)

        let after = try entries(env)
        #expect(after[key] == nil)
    }

    @Test("One run handles every expired entry, across batches, with kept entries among them")
    func oneRunHandlesEveryExpiredEntry() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let total = SyncConfig.pruneChunkSize * 2 + 10
        let base = expired
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Copy(uid: "\(i + 1)", folderPath: i % 2 == 0 ? "INBOX" : "Archive", rfc: "m\(i)@example.com"))
        }
        try insert(env, copies: copies)
        var inboxKeys: [String] = []
        var archivedKeys: [String] = []
        for (i, copy) in copies.enumerated() {
            // Distinct ages, so kept and deleted entries alternate in every read order.
            let key = try insertEntry(env, rfc: copy.rfc, updatedAt: base.addingTimeInterval(-Double(i)))
            if copy.isInInbox { inboxKeys.append(key) } else { archivedKeys.append(key) }
        }
        let limit = cutoff

        purge(env)

        let after = try entries(env)
        let stillExpired = after.values.filter { $0 < limit }.count
        let archivedLeft = archivedKeys.filter { after[$0] != nil }.count
        let inboxLeft = inboxKeys.filter { after[$0] != nil }.count
        #expect(stillExpired == 0, "one run left expired entries behind")
        #expect(archivedLeft == 0, "one run left archived messages' entries behind")
        #expect(inboxLeft == inboxKeys.count, "an inbox message's entry was deleted")
    }

    // MARK: - How it reads

    private static func readsMailTables(_ sql: String) -> Bool {
        let head = sql.trimmingCharacters(in: .whitespaces).uppercased()
        let isDML = ["SELECT", "UPDATE", "DELETE", "INSERT"].contains { head.hasPrefix($0) }
        return isDML && (sql.contains("\"messageAICache\"") || sql.contains("\"messageHeader\""))
    }

    /// No statistics: what a device has until its first `ANALYZE`, and the regime where
    /// the plan depends on the schema alone.
    private static func stripStatistics(_ db: Database) throws {
        if try db.tableExists("sqlite_stat1") {
            try db.execute(sql: "DELETE FROM sqlite_stat1")
            try db.execute(sql: "ANALYZE sqlite_master")
        }
    }

    private static func plan(_ db: Database, _ sql: String) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql)
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    @Test("Every statement the purge runs reads through an index")
    func everyStatementReadsThroughAnIndex() throws {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: "archived@example.com"),
            Copy(uid: "2", folderPath: "INBOX", rfc: "inbox@example.com")
        ])
        try insertEntry(env, rfc: "archived@example.com", updatedAt: expired)
        try insertEntry(env, rfc: "inbox@example.com", updatedAt: expired)
        _ = env.tape.drain()

        purge(env)

        let statements = env.tape.drain().filter(Self.readsMailTables)
        // Both outcomes ran, so the delete and the kept entry's update are on the tape.
        let deletes = statements.filter { $0.uppercased().hasPrefix("DELETE") }.count
        let updates = statements.filter { $0.uppercased().hasPrefix("UPDATE") }.count
        #expect(deletes == 1)
        #expect(updates == 1)

        let planned = try env.pool.write { db -> [(sql: String, plan: String)] in
            try Self.stripStatistics(db)
            return try statements.map { ($0, try Self.plan(db, $0)) }
        }
        for statement in planned {
            #expect(!statement.plan.contains("SCAN"), "\(statement.sql) scans: \(statement.plan)")
        }
        let expiredReads = planned.filter { $0.sql.contains("\"updatedAt\" <") }
        // The count, then one batch with both entries, then the empty batch that ends the run.
        #expect(expiredReads.count == 3)
        for read in expiredReads {
            #expect(read.plan.contains("messageAICache_expiry (updatedAt<?)"), "\(read.sql): \(read.plan)")
        }

        // Instrument check: without the index the same reads scan the cache, so the
        // assertions above can fail.
        let unindexed = try env.pool.write { db -> [String] in
            try db.execute(sql: "DROP INDEX messageAICache_expiry")
            return try expiredReads.map { try Self.plan(db, $0.sql) }
        }
        for plan in unindexed {
            #expect(plan.contains("SCAN messageAICache"), "the probe cannot see a scan: \(plan)")
        }
    }
}
