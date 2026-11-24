/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The statistics the planner has when the purge runs (file scope: a `@Test` argument
/// cannot name a member of its own suite).
enum AICacheExpiryStatistics: String, CaseIterable, Sendable {
    /// None: a device before its first `ANALYZE`.
    case none
    /// Taken while each table held one row, then the tables grew.
    case staleSmall
    /// Taken on the tables as they are.
    case fresh
}

/// The AI cache's expiry, `SyncEngine.runPurgeExpiredAICache`, run for real on a migrated
/// on-disk database. The AI queue runs it each time it drains and maintenance runs it on
/// its pass, so these are the properties both give the user (ADR-IOS-078):
/// - an entry nobody has written for `SyncConfig.aiCacheTTLDays` is deleted, unless its
///   message is in an inbox now, in any account, in which case it stays, results and all,
///   and its clock restarts;
/// - inbox membership comes from every copy of the message, never from the entry's key:
///   the key names the folder the AI ran in, which is still the inbox after an archive;
/// - one run handles every expired entry, however many batches that takes, and each
///   write transaction handles at most one batch;
/// - each batch decides on the entries as they are when it runs: an AI result written
///   between two batches is kept, and a batch that fails is undone whole and left to the
///   next run;
/// - the AI queue runs it once its work is done, and no other cache upkeep;
/// - an entry whose stored results no longer decode is expired like any other;
/// - every statement it runs reads through an index, whatever the statistics (ADR-IOS-029).
@Suite("AI cache expiry")
struct AICacheExpiryTests {

    private static let accountId = "acc1"
    private static let otherAccountId = "acc2"

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

    /// Changes to the AI cache per committed write transaction.
    private final class CacheWritesPerCommit: TransactionObserver, Sendable {
        private let state = Mutex<(current: Int, commits: [Int])>((current: 0, commits: []))
        var commits: [Int] { state.withLock { $0.commits } }
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageAICache.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            state.withLock { $0.current += 1 }
        }
        func databaseDidCommit(_ db: Database) {
            state.withLock { value in
                if value.current > 0 { value.commits.append(value.current) }
                value.current = 0
            }
        }
        func databaseDidRollback(_ db: Database) {
            state.withLock { $0.current = 0 }
        }
    }

    /// After the first commit that changes the AI cache, queues one write on the writer.
    /// The writer runs queued work in order, so it lands after that batch and before the
    /// next, the way an AI result can be written while a run is under way. It rewrites
    /// the first of `candidates` that is still there and still expired.
    private final class WriteAfterFirstBatch: TransactionObserver, Sendable {
        struct Outcome {
            var changed = false
            var queued = false
            var rewritten: String?
            var failure: String?
        }
        private let pool: DatabasePool
        private let candidates: [(rfc: String, key: String)]
        private let limit: Date
        private let state = Mutex<Outcome>(Outcome())
        init(pool: DatabasePool, candidates: [(rfc: String, key: String)], limit: Date) {
            self.pool = pool
            self.candidates = candidates
            self.limit = limit
        }
        var outcome: Outcome { state.withLock { $0 } }
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageAICache.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            state.withLock { $0.changed = true }
        }
        func databaseDidCommit(_ db: Database) {
            let queue = state.withLock { value -> Bool in
                defer { value.changed = false }
                guard value.changed, !value.queued else { return false }
                value.queued = true
                return true
            }
            guard queue else { return }
            pool.asyncWriteWithoutTransaction { [self] db in
                do {
                    try db.inTransaction {
                        for candidate in candidates {
                            guard let entry = try MessageAICache.fetchOne(db, key: candidate.key),
                                  entry.updatedAt < limit else { continue }
                            try MessageAICache.writeThrough(
                                accountId: AICacheExpiryTests.accountId, folderPath: "INBOX",
                                rfc822MessageId: candidate.rfc, summaryBlurb: "rewritten", db: db)
                            state.withLock { $0.rewritten = candidate.key }
                            break
                        }
                        return .commit
                    }
                } catch {
                    state.withLock { $0.failure = "\(error)" }
                }
            }
        }
        func databaseDidRollback(_ db: Database) {
            state.withLock { $0.changed = false }
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
            for (id, email) in [(Self.accountId, "user@example.com"), (Self.otherAccountId, "other@example.com")] {
                var account = Account(emailAddress: email, displayName: "User", provider: .imap)
                account.id = id
                try account.insert(db)
                try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: id).insert(db)
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: id).insert(db)
            }
        }
        return Env(pool: pool, directory: directory, tape: tape)
    }

    private func finish(_ env: Env) {
        TestDatabaseTeardown.closeThenUnlinkNow(pool: env.pool, directory: env.directory)
    }

    /// One copy of a message: a header in `folderPath` of `accountId`.
    private struct Copy {
        let uid: String
        let folderPath: String
        let rfc: String
        var date = Date()
        var accountId = AICacheExpiryTests.accountId
        var isInInbox: Bool { folderPath == "INBOX" }
    }

    private func insert(_ env: Env, copies: [Copy]) throws {
        try env.pool.write { db in
            for copy in copies {
                var header = MessageHeader(
                    messageId: copy.uid, subject: "s", from: "a@example.com",
                    fromAddress: "a@example.com", to: "user@example.com", date: copy.date,
                    snippet: "", folderId: "\(copy.accountId):\(copy.folderPath)",
                    accountId: copy.accountId, folderPath: copy.folderPath,
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
            entry.actionTag = .reply
            entry.updatedAt = updatedAt
            try entry.insert(db)
        }
        return entryKey
    }

    private func pool(_ env: Env) -> PrioritizedDatabase {
        PrioritizedDatabase(pool: env.pool, priority: .background)
    }

    private func purge(_ env: Env) {
        SyncEngine.runPurgeExpiredAICache(dbPool: pool(env))
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
        let kept = try env.pool.read { try MessageAICache.fetchOne($0, key: inboxKey) }
        #expect(kept?.summaryBlurb == "summary", "a kept entry lost its summary")
        #expect(kept?.actionTag == .reply, "a kept entry lost its action")
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

    @Test("A copy in another account's inbox keeps the entry")
    func inboxCopyInAnotherAccountKeepsTheEntry() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let rfc = "shared@example.com"
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: rfc),
            Copy(uid: "7", folderPath: "INBOX", rfc: rfc, accountId: Self.otherAccountId)
        ])
        let key = try insertEntry(env, rfc: rfc, updatedAt: expired)

        purge(env)

        let after = try entries(env)
        #expect(after[key] != nil, "the entry was deleted though another account's inbox holds the message")
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

    @Test("A write-through gives an entry without a Message-ID the one it is keyed by, and the expiry then keeps it")
    func writeThroughFillsAMissingMessageId() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let rfc = "legacy@example.com"
        try insert(env, copies: [Copy(uid: "2", folderPath: "INBOX", rfc: rfc)])
        let key = try #require(MessageAICache.cacheKey(accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: rfc))
        try insertEntry(env, rfc: nil, key: key, updatedAt: expired)

        try env.pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: rfc,
                cachedReply: "a reply", db: db)
            // Age it again, so only the Message-ID can keep it.
            try db.execute(sql: "UPDATE messageAICache SET updatedAt = ? WHERE key = ?", arguments: [expired, key])
        }
        purge(env)

        let after = try env.pool.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(after?.rfc822MessageId == rfc, "the write-through left the entry without a Message-ID")
        #expect(after?.cachedReply == "a reply", "the entry of a message in the inbox was deleted")
    }

    @Test("The TTL ends exactly SyncConfig.aiCacheTTLDays calendar days back")
    func ttlBoundary() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = Date()
        let edge = try #require(Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: now))
        let inside = edge.addingTimeInterval(3_600)
        let outside = edge.addingTimeInterval(-3_600)
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: "inside@example.com"),
            Copy(uid: "2", folderPath: "Archive", rfc: "outside@example.com")
        ])
        let insideKey = try insertEntry(env, rfc: "inside@example.com", updatedAt: inside)
        let outsideKey = try insertEntry(env, rfc: "outside@example.com", updatedAt: outside)

        purge(env)

        let after = try entries(env)
        #expect(after[insideKey] != nil, "an entry an hour inside the TTL was deleted")
        #expect(after[outsideKey] == nil, "an entry an hour past the TTL was kept")
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
        let counter = CacheWritesPerCommit()
        try env.pool.write { $0.add(transactionObserver: counter, extent: .databaseLifetime) }

        purge(env)

        let after = try entries(env)
        let stillExpired = after.values.filter { $0 < limit }.count
        let archivedLeft = archivedKeys.filter { after[$0] != nil }.count
        let inboxLeft = inboxKeys.filter { after[$0] != nil }.count
        #expect(stillExpired == 0, "one run left expired entries behind")
        #expect(archivedLeft == 0, "one run left archived messages' entries behind")
        #expect(inboxLeft == inboxKeys.count, "an inbox message's entry was deleted")
        let commits = counter.commits
        let largest = commits.max() ?? 0
        let written = commits.reduce(0, +)
        #expect(largest <= SyncConfig.pruneChunkSize, "one write transaction changed \(largest) entries: \(commits)")
        #expect(written == total, "the run did not change every expired entry once: \(commits)")
    }

    @Test("An AI result written between two batches of a run is kept")
    func writeBetweenBatchesIsKept() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let total = SyncConfig.pruneChunkSize * 2 + 10
        let base = expired
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Copy(uid: "\(i + 1)", folderPath: i % 2 == 0 ? "INBOX" : "Archive", rfc: "w\(i)@example.com"))
        }
        try insert(env, copies: copies)
        var archived: [(rfc: String, key: String)] = []
        for (i, copy) in copies.enumerated() {
            let key = try insertEntry(env, rfc: copy.rfc, updatedAt: base.addingTimeInterval(-Double(i)))
            if !copy.isInInbox { archived.append((rfc: copy.rfc, key: key)) }
        }
        let writer = WriteAfterFirstBatch(pool: env.pool, candidates: archived, limit: cutoff)
        try env.pool.write { $0.add(transactionObserver: writer, extent: .databaseLifetime) }

        purge(env)

        let outcome = writer.outcome
        #expect(outcome.failure == nil, "the write between batches failed: \(outcome.failure ?? "")")
        let rewritten = try #require(outcome.rewritten, "no archived entry was left after the first batch")
        let after = try env.pool.read { try MessageAICache.fetchAll($0) }
        let kept = after.first { $0.key == rewritten }
        #expect(kept?.summaryBlurb == "rewritten", "the run deleted an entry written after its first batch")
        let left = Set(after.map { $0.key })
        let otherArchived = archived.map { $0.key }.filter { $0 != rewritten }
        #expect(otherArchived.allSatisfy { !left.contains($0) }, "the run stopped after the write between batches")
    }

    @Test("A batch that fails is undone whole, and the next run finishes the expiry")
    func failedBatchIsFinishedByTheNextRun() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let copies = (0..<10).map { i in
            Copy(uid: "\(i + 1)", folderPath: i % 2 == 0 ? "INBOX" : "Archive", rfc: "f\(i)@example.com")
        }
        try insert(env, copies: copies)
        var keys: [String] = []
        for (i, copy) in copies.enumerated() {
            let key = try insertEntry(env, rfc: copy.rfc, updatedAt: expired.addingTimeInterval(-Double(i)))
            keys.append(key)
        }
        let limit = cutoff
        // Fewer entries than one batch, so the run is one batch. Deleting the second
        // archived entry fails, once.
        let failing = keys[3]
        try env.pool.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failExpiry BEFORE DELETE ON messageAICache
                WHEN OLD.key = '\(failing)' BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }

        purge(env)

        let afterFailure = try entries(env)
        #expect(Set(afterFailure.keys) == Set(keys), "the failed batch deleted entries")
        #expect(afterFailure.values.allSatisfy { $0 < limit }, "the failed batch restarted clocks")

        try env.pool.write { try $0.execute(sql: "DROP TRIGGER temp.failExpiry") }
        purge(env)

        let after = try entries(env)
        for (i, key) in keys.enumerated() {
            if i % 2 == 0 {
                let keptFresh = after[key].map { $0 >= limit } ?? false
                #expect(keptFresh, "the next run did not keep inbox entry \(i)")
            } else {
                #expect(after[key] == nil, "the next run did not expire archived entry \(i)")
            }
        }
    }

    @Test("An entry whose stored results no longer decode is expired, and so are the others")
    func undecodableEntryDoesNotStopExpiry() throws {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: "broken@example.com"),
            Copy(uid: "2", folderPath: "Archive", rfc: "plain@example.com")
        ])
        let brokenKey = try #require(MessageAICache.cacheKey(
            accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: "broken@example.com"))
        let oldest = expired.addingTimeInterval(-60)
        try env.pool.write { db in
            try db.execute(sql: """
                INSERT INTO messageAICache (key, rfc822MessageId, actionTag, updatedAt)
                VALUES (?, ?, 'not-an-action', ?)
                """, arguments: [brokenKey, "broken@example.com", oldest])
        }
        let plainKey = try insertEntry(env, rfc: "plain@example.com", updatedAt: expired)

        purge(env)

        let left = try env.pool.read { try String.fetchAll($0, sql: "SELECT key FROM messageAICache") }
        #expect(!left.contains(brokenKey), "the undecodable entry outlived the TTL")
        #expect(!left.contains(plainKey), "an undecodable entry stopped the expiry of the others")
    }

    @Test("A maintenance pass expires the cache")
    func maintenancePassExpires() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: "archived@example.com"),
            Copy(uid: "2", folderPath: "INBOX", rfc: "inbox@example.com")
        ])
        let archivedKey = try insertEntry(env, rfc: "archived@example.com", updatedAt: expired)
        let inboxKey = try insertEntry(env, rfc: "inbox@example.com", updatedAt: expired)

        await SyncEngine.runWALMaintenance(
            dbPool: pool(env), includePrune: false, undoProtectedBodyIds: [], pruneOrder: [:])

        let after = try entries(env)
        #expect(after[archivedKey] == nil, "maintenance left an archived message's expired entry")
        let inboxClock = after[inboxKey] ?? .distantPast
        #expect(inboxClock > cutoff, "maintenance deleted an inbox message's entry or left it expired")
    }

    // MARK: - How it reads

    /// A statement that reads or writes a mail-sized table, however GRDB or the source
    /// spelled it.
    private static func touchesMailTables(_ sql: String) -> Bool {
        let lower = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDML = ["select", "update", "delete", "insert", "with", "replace"].contains { lower.hasPrefix($0) }
        return isDML && (lower.contains("messageaicache") || lower.contains("messageheader"))
    }

    private static func plan(_ db: Database, _ sql: String) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql)
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    @Test("Every statement the purge runs reads through the index it names", arguments: AICacheExpiryStatistics.allCases)
    func everyStatementReadsThroughAnIndex(statistics: AICacheExpiryStatistics) throws {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, copies: [Copy(uid: "1", folderPath: "Archive", rfc: "archived@example.com")])
        try insertEntry(env, rfc: "archived@example.com", updatedAt: expired)
        if statistics == .staleSmall {
            try env.pool.write { try $0.execute(sql: "ANALYZE") }
        }
        try insert(env, copies: (2...40).map { Copy(uid: "\($0)", folderPath: $0 == 2 ? "INBOX" : "Archive", rfc: "m\($0)@example.com") })
        for uid in 2...40 {
            try insertEntry(env, rfc: "m\(uid)@example.com", updatedAt: uid == 2 ? expired : Date())
        }
        try env.pool.write { db in
            switch statistics {
            case .none:
                if try db.tableExists("sqlite_stat1") {
                    try db.execute(sql: "DELETE FROM sqlite_stat1")
                    try db.execute(sql: "ANALYZE sqlite_master")
                }
            case .staleSmall:
                break
            case .fresh:
                try db.execute(sql: "ANALYZE")
            }
        }
        _ = env.tape.drain()

        purge(env)

        let statements = env.tape.drain().filter(Self.touchesMailTables)
        let planned = try env.pool.read { db in
            try statements.map { (sql: $0, plan: try Self.plan(db, $0)) }
        }
        let scans = planned.filter { $0.plan.contains("SCAN messageAICache") || $0.plan.contains("SCAN messageHeader") }.map { "\($0.sql) -> \($0.plan)" }
        #expect(scans.isEmpty, "[\(statistics)] statements that scan:\n\(scans.joined(separator: "\n"))")

        func reads(_ marker: String) -> [(sql: String, plan: String)] { planned.filter { $0.sql.contains(marker) } }
        let counts = reads("SELECT COUNT(*) FROM messageAICache")
        let batches = reads("SELECT key, rfc822MessageId FROM messageAICache")
        let inboxChecks = reads("FROM messageHeader INDEXED BY")
        let updates = planned.filter { $0.sql.hasPrefix("UPDATE messageAICache") }
        let deletes = planned.filter { $0.sql.hasPrefix("DELETE FROM messageAICache") }
        // The gate, one batch with both expired entries, the empty batch that ends the
        // run; one inbox check per expired entry; one entry kept, one deleted.
        #expect(counts.count == 1)
        #expect(batches.count == 2)
        #expect(inboxChecks.count == 2)
        #expect(updates.count == 1)
        #expect(deletes.count == 1)
        #expect(planned.count == 7, "a statement on a mail table this test does not know: \(planned.map(\.sql))")
        for read in counts + batches {
            #expect(read.plan.contains("messageAICache_expiry (updatedAt<?)"), "\(read.sql): \(read.plan)")
        }
        for read in inboxChecks {
            #expect(read.plan.contains("messageHeader_rfc822MessageId (rfc822MessageId=?)"), "\(read.sql): \(read.plan)")
        }
        for write in updates + deletes {
            #expect(write.plan.contains("(key=?)"), "\(write.sql): \(write.plan)")
        }

        // Instrument check: the same reads with their index hint taken away scan, so the
        // assertions above can fail.
        let unhinted = try env.pool.read { db in
            try (counts + batches + inboxChecks).map { read in
                try Self.plan(db, read.sql
                    .replacingOccurrences(of: "INDEXED BY messageAICache_expiry", with: "NOT INDEXED")
                    .replacingOccurrences(of: "INDEXED BY messageHeader_rfc822MessageId", with: "NOT INDEXED"))
            }
        }
        for plan in unhinted {
            #expect(plan.contains("SCAN messageAICache") || plan.contains("SCAN messageHeader"),
                    "the probe cannot see a scan: \(plan)")
        }
    }

    /// The AI queue's drain is the expiry's other caller. It sits in a private actor method
    /// that only the whole AI pipeline reaches, so its wiring is pinned on the source: once
    /// no AI work is left (`repopulateOnDrain` found none) the drain runs the purge, and
    /// runs no other cache upkeep. A touch by key there, as the drain once ran, would keep
    /// every entry whose key names an inbox alive, archived messages included.
    @Test("the AI queue runs the expiry once its work is done, and no other cache upkeep")
    func theDrainRunsTheExpiry() throws {
        let sources = try DiagnosticPrintGateTests.appTargetSources()
        let queueFile = sources.first { $0.relativePath == "TabMail/Services/AI/ActiveAIQueue.swift" }
        let queueText = try #require(queueFile?.source)
        let queue = queueText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let startIndex = queue.firstIndex { $0.contains("private func jobCompleted(job: AIJob, report: ExecutorReport)") }
        let start = try #require(startIndex)
        let endIndex = queue[start...].firstIndex { $0.contains("private enum JobOutcome") }
        let end = try #require(endIndex)
        let body = Array(queue[start..<end])
        let idleIndex = body.firstIndex { $0.contains("if !repopulated {") }
        let idle = try #require(idleIndex)
        let purges = body.indices.filter {
            body[$0].contains("SyncEngine.runPurgeExpiredAICache(dbPool: AppDatabase.backgroundPool)")
        }
        #expect(purges.count == 1, "the drain runs the expiry once: \(purges.map { body[$0] })")
        #expect(purges.allSatisfy { $0 > idle }, "the expiry runs only once no AI work is left")

        let upkeep = queue.filter {
            $0.contains("SyncEngine.") && $0.range(of: "AICache|aiCache", options: .regularExpression) != nil
        }
        #expect(upkeep.count == 1, "cache upkeep in the AI queue besides the expiry: \(upkeep)")
        let cacheSQL = queue.filter { $0.contains("messageAICache") }
        #expect(cacheSQL.isEmpty, "SQL on the cache in the AI queue: \(cacheSQL)")
    }
}
