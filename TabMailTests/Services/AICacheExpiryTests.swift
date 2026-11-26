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

/// The AI cache's purge, `SyncEngine.runPurgeOrphanedAICache`, run for real on a migrated
/// on-disk database. Maintenance runs it on its pass, so these are the properties it gives
/// the user (ADR-IOS-114's rule on ADR-IOS-078's batches):
/// - an entry nobody has written for `SyncConfig.aiCacheOrphanGraceDays` is deleted, unless
///   its email is still on the device in the entry's own account, in any folder, in which
///   case it stays, results and all, and its clock restarts;
/// - that check reads every copy of the email, never the entry's key: the key names the
///   folder the AI ran in, which is still the inbox after an archive; another account's
///   copy keeps nothing;
/// - one run handles every entry past the grace, however many batches that takes, and each
///   write transaction handles at most one batch;
/// - each batch decides on the entries as they are when it runs: an AI result written
///   between two batches is kept, and a batch that fails is undone whole and left to the
///   next run;
/// - the AI queue runs no cache upkeep: the purge is maintenance's;
/// - an entry whose stored results no longer decode is purged like any other;
/// - it checkpoints the app's WAL between two batches, once the earlier one has
///   committed, and never after its last batch, so the TRUNCATE the maintenance pass
///   asks for right after a run of one batch still empties the WAL file;
/// - every statement it runs reads through an index, whatever the statistics (ADR-IOS-029).
@Suite("AI cache expiry")
struct AICacheExpiryTests {

    private static let accountId = "acc1"
    private static let otherAccountId = "acc2"

    /// Every statement the pool ran, with its bound values inlined so it can be planned
    /// afterwards, and whether the writer ran it (a pool's readers are read-only
    /// connections). `expandedDescription`, not `description`: see
    /// `SearchScopedPageTests.SQLTape` for why. The fixtures hold only example.com data.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[(sql: String, onWriter: Bool)]>([])
        func record(_ sql: String, onWriter: Bool) { statements.withLock { $0.append((sql: sql, onWriter: onWriter)) } }
        func drain() -> [String] { drainWithConnection().map { $0.sql } }
        func drainWithConnection() -> [(sql: String, onWriter: Bool)] {
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

    /// How many cache-changing commits had happened at each WAL checkpoint call.
    private final class CheckpointLog: Sendable {
        private let calls = Mutex<[Int]>([])
        func record(_ committed: Int) { calls.withLock { $0.append(committed) } }
        var all: [Int] { calls.withLock { $0 } }
    }

    private struct Env {
        let pool: DatabasePool
        let directory: URL
        let tape: SQLTape
    }

    private func makeEnv(configuration base: Configuration = Configuration()) throws -> Env {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-cache-expiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tape = SQLTape()
        var configuration = base
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            let onWriter = !db.configuration.readonly
            db.trace(options: .statement) { event in tape.record(event.expandedDescription, onWriter: onWriter) }
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
        /// Whether this copy keeps the entry `insertEntry` writes for its email: a copy in
        /// the entry's own account, in any folder.
        var keepsItsEntry: Bool { accountId == AICacheExpiryTests.accountId }
    }

    /// The i-th email of a run: the even ones are in the account's Archive, so their
    /// entries stay; the odd ones are only in another account's inbox, so theirs go.
    private static func alternating(_ i: Int, rfc: String) -> Copy {
        i % 2 == 0
            ? Copy(uid: "\(i + 1)", folderPath: "Archive", rfc: rfc)
            : Copy(uid: "\(i + 1)", folderPath: "INBOX", rfc: rfc, accountId: otherAccountId)
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

    /// One run of the purge. Its WAL checkpoint is a no-op here: the real one acts on
    /// the app's own database, not on this test's (`checkpointsRunBetweenBatchesOnly`
    /// checks where the run calls it; `purgeCheckpointsTheAppDatabase` and
    /// `oneBatchPurgeLeavesTheTruncateItsTurn` run the real one with a test database
    /// installed as the app's).
    private func purge(_ env: Env) async {
        await SyncEngine.runPurgeOrphanedAICache(dbPool: pool(env), checkpointWAL: {})
    }

    /// Every entry left, key to `updatedAt`.
    private func entries(_ env: Env) throws -> [String: Date] {
        let all = try env.pool.read { try MessageAICache.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0.updatedAt) })
    }

    private var expired: Date {
        Date().addingTimeInterval(-Double(SyncConfig.aiCacheOrphanGraceDays + 1) * 86_400)
    }

    private var cutoff: Date {
        Date().addingTimeInterval(-Double(SyncConfig.aiCacheOrphanGraceDays) * 86_400)
    }

    // MARK: - What expires

    @Test("An entry past the grace stays while its email is in any folder of its account, though its key names the inbox; a gone email's is deleted")
    func purgeFollowsTheEmailNotTheKey() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let fresh = Date().addingTimeInterval(-3_600)
        try insert(env, copies: [
            Copy(uid: "1", folderPath: "Archive", rfc: "archived@example.com"),
            Copy(uid: "3", folderPath: "Archive", rfc: "recent@example.com")
        ])
        let archivedKey = try insertEntry(env, rfc: "archived@example.com", updatedAt: expired)
        let goneKey = try insertEntry(env, rfc: "gone@example.com", updatedAt: expired)
        let recentKey = try insertEntry(env, rfc: "recent@example.com", updatedAt: fresh)
        let start = Date()

        await purge(env)

        let after = try entries(env)
        #expect(after[goneKey] == nil, "a gone email's entry outlived the grace")
        let archivedClock = try #require(after[archivedKey], "an archived email's entry was deleted")
        #expect(archivedClock >= start.addingTimeInterval(-1), "a kept entry's clock did not restart")
        let recentClock = try #require(after[recentKey], "an entry inside the grace was deleted")
        let recentDrift = abs(recentClock.timeIntervalSince(fresh))
        #expect(recentDrift < 0.002, "an entry inside the grace was rewritten")
        let kept = try await env.pool.read { try MessageAICache.fetchOne($0, key: archivedKey) }
        #expect(kept?.summaryBlurb == "summary", "a kept entry lost its summary")
        #expect(kept?.actionTag == .reply, "a kept entry lost its action")
    }

    @Test("The check reads every copy of the email, however many there are")
    func checkReadsEveryCopy() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let rfc = "many-copies@example.com"
        // Five older copies in another account, then the account's own copy, which sorts
        // last in the message-id index.
        let now = Date()
        var copies = (1...5).map {
            Copy(uid: "\(10 + $0)", folderPath: "INBOX", rfc: rfc, date: now.addingTimeInterval(-Double(100 - $0)),
                 accountId: Self.otherAccountId)
        }
        copies.append(Copy(uid: "2", folderPath: "Archive", rfc: rfc, date: now))
        try insert(env, copies: copies)
        let key = try insertEntry(env, rfc: rfc, updatedAt: expired)

        await purge(env)

        let after = try entries(env)
        #expect(after[key] != nil, "the entry of an email still in its account was deleted")
    }

    @Test("A copy in another account, even in its inbox, keeps nothing")
    func copyInAnotherAccountKeepsNothing() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let rfc = "shared@example.com"
        try insert(env, copies: [
            Copy(uid: "7", folderPath: "INBOX", rfc: rfc, accountId: Self.otherAccountId)
        ])
        let key = try insertEntry(env, rfc: rfc, updatedAt: expired)

        await purge(env)

        let after = try entries(env)
        #expect(after[key] == nil, "another account's copy kept the entry")
    }

    @Test("An expired entry with no Message-ID is deleted", arguments: [nil, ""] as [String?])
    func entryWithoutMessageIdIsDeleted(rfc: String?) async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let key = try insertEntry(env, rfc: rfc, key: "\(Self.accountId):INBOX:no-id", updatedAt: expired)

        await purge(env)

        let after = try entries(env)
        #expect(after[key] == nil)
    }

    @Test("A write-through gives an entry without a Message-ID the one it is keyed by, and the expiry then keeps it")
    func writeThroughFillsAMissingMessageId() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let rfc = "legacy@example.com"
        try insert(env, copies: [Copy(uid: "2", folderPath: "INBOX", rfc: rfc)])
        let key = try #require(MessageAICache.cacheKey(accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: rfc))
        try insertEntry(env, rfc: nil, key: key, updatedAt: expired)

        try await env.pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: rfc,
                reply: ReplyResult(body: "a reply", textMessage: nil), db: db)
            // Age it again, so only the Message-ID can keep it.
            try db.execute(sql: "UPDATE messageAICache SET updatedAt = ? WHERE key = ?", arguments: [expired, key])
        }
        await purge(env)

        let after = try await env.pool.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(after?.rfc822MessageId == rfc, "the write-through left the entry without a Message-ID")
        #expect(after?.cachedReply == "a reply", "the entry of an email on the device was deleted")
    }

    @Test("The grace ends exactly SyncConfig.aiCacheOrphanGraceDays calendar days back")
    func graceBoundary() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let now = Date()
        let edge = try #require(Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheOrphanGraceDays, to: now))
        let inside = edge.addingTimeInterval(3_600)
        let outside = edge.addingTimeInterval(-3_600)
        // Neither email is on the device.
        let insideKey = try insertEntry(env, rfc: "inside@example.com", updatedAt: inside)
        let outsideKey = try insertEntry(env, rfc: "outside@example.com", updatedAt: outside)

        await purge(env)

        let after = try entries(env)
        #expect(after[insideKey] != nil, "an entry an hour inside the grace was deleted")
        #expect(after[outsideKey] == nil, "an entry an hour past the grace was kept")
    }

    @Test("One run handles every entry past the grace, across batches, with kept entries among them")
    func oneRunHandlesEveryEntryPastTheGrace() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let total = SyncConfig.pruneChunkSize * 2 + 10
        let base = expired
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Self.alternating(i, rfc: "m\(i)@example.com"))
        }
        try insert(env, copies: copies)
        var keptKeys: [String] = []
        var goneKeys: [String] = []
        for (i, copy) in copies.enumerated() {
            // Distinct ages, so kept and deleted entries alternate in every read order.
            let key = try insertEntry(env, rfc: copy.rfc, updatedAt: base.addingTimeInterval(-Double(i)))
            if copy.keepsItsEntry { keptKeys.append(key) } else { goneKeys.append(key) }
        }
        let limit = cutoff
        let counter = CacheWritesPerCommit()
        try await env.pool.write { $0.add(transactionObserver: counter, extent: .databaseLifetime) }

        await purge(env)

        let after = try entries(env)
        let stillExpired = after.values.filter { $0 < limit }.count
        let goneLeft = goneKeys.filter { after[$0] != nil }.count
        let keptLeft = keptKeys.filter { after[$0] != nil }.count
        #expect(stillExpired == 0, "one run left entries past the grace behind")
        #expect(goneLeft == 0, "one run left gone emails' entries behind")
        #expect(keptLeft == keptKeys.count, "the entry of an email still in its account was deleted")
        let commits = counter.commits
        let largest = commits.max() ?? 0
        let written = commits.reduce(0, +)
        #expect(largest <= SyncConfig.pruneChunkSize, "one write transaction changed \(largest) entries: \(commits)")
        #expect(written == total, "the run did not change every entry past the grace once: \(commits)")
    }

    @Test("An AI result written between two batches of a run is kept")
    func writeBetweenBatchesIsKept() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let total = SyncConfig.pruneChunkSize * 2 + 10
        let base = expired
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Self.alternating(i, rfc: "w\(i)@example.com"))
        }
        try insert(env, copies: copies)
        var gone: [(rfc: String, key: String)] = []
        for (i, copy) in copies.enumerated() {
            let key = try insertEntry(env, rfc: copy.rfc, updatedAt: base.addingTimeInterval(-Double(i)))
            if !copy.keepsItsEntry { gone.append((rfc: copy.rfc, key: key)) }
        }
        let writer = WriteAfterFirstBatch(pool: env.pool, candidates: gone, limit: cutoff)
        try await env.pool.write { $0.add(transactionObserver: writer, extent: .databaseLifetime) }

        await purge(env)

        let outcome = writer.outcome
        #expect(outcome.failure == nil, "the write between batches failed: \(outcome.failure ?? "")")
        let rewritten = try #require(outcome.rewritten, "no gone email's entry was left after the first batch")
        let after = try await env.pool.read { try MessageAICache.fetchAll($0) }
        let kept = after.first { $0.key == rewritten }
        #expect(kept?.summaryBlurb == "rewritten", "the run deleted an entry written after its first batch")
        let left = Set(after.map { $0.key })
        let otherGone = gone.map { $0.key }.filter { $0 != rewritten }
        #expect(otherGone.allSatisfy { !left.contains($0) }, "the run stopped after the write between batches")
    }

    /// The write between batches above lands before the next batch is read, so it cannot
    /// tell where that read runs. Each batch must be read in the write transaction that
    /// deletes or keeps its entries: a read before that transaction leaves a moment in
    /// which an AI result can be written and then deleted by a decision made without it.
    @Test("Each batch is read in the write transaction that deletes or keeps its entries")
    func eachBatchIsReadInTheWriteThatHandlesIt() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let total = SyncConfig.pruneChunkSize + 10
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Self.alternating(i, rfc: "t\(i)@example.com"))
        }
        try insert(env, copies: copies)
        for (i, copy) in copies.enumerated() {
            try insertEntry(env, rfc: copy.rfc, updatedAt: expired.addingTimeInterval(-Double(i)))
        }
        _ = env.tape.drain()

        await purge(env)

        let statements = env.tape.drainWithConnection()
        let batchReads = statements.filter { $0.sql.contains("SELECT key, rfc822MessageId FROM messageAICache") }
        let allOnWriter = batchReads.allSatisfy { $0.onWriter }
        #expect(!batchReads.isEmpty, "the run read no batch")
        #expect(allOnWriter, "a batch was read on a reader, outside the write that handles it")

        // The writer's statements, split into its transactions.
        var transactions: [[String]] = []
        var current: [String]?
        for statement in statements where statement.onWriter {
            let upper = statement.sql.uppercased()
            if upper.hasPrefix("BEGIN") {
                current = []
            } else if upper.hasPrefix("COMMIT") || upper.hasPrefix("ROLLBACK") {
                if let done = current { transactions.append(done) }
                current = nil
            } else {
                current?.append(statement.sql)
            }
        }
        func isDisposition(_ sql: String) -> Bool {
            sql.hasPrefix("UPDATE messageAICache") || sql.hasPrefix("DELETE FROM messageAICache")
        }
        let handling = transactions.filter { $0.contains(where: isDisposition) }
        // One full batch, then the last ten entries.
        #expect(handling.count == 2, "write transactions that keep or delete entries: \(handling.count)")
        for transaction in handling {
            let read = transaction.firstIndex { $0.contains("SELECT key, rfc822MessageId FROM messageAICache") }
            let write = transaction.firstIndex(where: isDisposition)
            let readFirst = read.flatMap { r in write.map { r < $0 } } ?? false
            #expect(readFirst, "a transaction kept or deleted entries it did not read: \(transaction.prefix(3))")
        }
    }

    /// SQLite's own checkpoint is off in the app, so a batch writer bounds the WAL itself:
    /// the run checkpoints between two batches, once the earlier one's write has
    /// committed. It never checkpoints after its last batch, which leaves the TRUNCATE
    /// the maintenance pass asks for right after the run its turn in the throttle; so a
    /// run of one batch, a full one included, takes no checkpoint.
    @Test("A WAL checkpoint runs between two batches, after the earlier one commits, and never after the last",
          arguments: [10, SyncConfig.pruneChunkSize, SyncConfig.pruneChunkSize + 1, SyncConfig.pruneChunkSize * 2 + 10])
    func checkpointsRunBetweenBatchesOnly(total: Int) async throws {
        let env = try makeEnv()
        defer { finish(env) }
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Self.alternating(i, rfc: "c\(i)@example.com"))
        }
        try insert(env, copies: copies)
        for (i, copy) in copies.enumerated() {
            try insertEntry(env, rfc: copy.rfc, updatedAt: expired.addingTimeInterval(-Double(i)))
        }
        let counter = CacheWritesPerCommit()
        try await env.pool.write { $0.add(transactionObserver: counter, extent: .databaseLifetime) }
        let log = CheckpointLog()

        await SyncEngine.runPurgeOrphanedAICache(dbPool: pool(env), checkpointWAL: {
            log.record(counter.commits.count)
        })

        let commits = counter.commits
        let seen = log.all
        // Every batch changes the cache. A checkpoint follows each batch but the last,
        // before the next batch commits.
        let batches = (total + SyncConfig.pruneChunkSize - 1) / SyncConfig.pruneChunkSize
        let between = Array(1..<batches)
        #expect(commits.count == batches, "[\(total) entries] batches that changed the cache: \(commits)")
        #expect(seen == between, "[\(total) entries] cache-changing commits seen at each checkpoint: \(seen)")
    }

    @Test("A batch that fails is undone whole, and the next run finishes the purge")
    func failedBatchIsFinishedByTheNextRun() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        let copies = (0..<10).map { i in Self.alternating(i, rfc: "f\(i)@example.com") }
        try insert(env, copies: copies)
        var keys: [String] = []
        for (i, copy) in copies.enumerated() {
            let key = try insertEntry(env, rfc: copy.rfc, updatedAt: expired.addingTimeInterval(-Double(i)))
            keys.append(key)
        }
        let limit = cutoff
        // Fewer entries than one batch, so the run is one batch. Deleting the second
        // gone email's entry fails, once.
        let failing = keys[3]
        try await env.pool.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER failExpiry BEFORE DELETE ON messageAICache
                WHEN OLD.key = '\(failing)' BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
        }

        let checkpoints = CheckpointLog()
        await SyncEngine.runPurgeOrphanedAICache(dbPool: pool(env), checkpointWAL: { checkpoints.record(0) })

        let afterFailure = try entries(env)
        #expect(Set(afterFailure.keys) == Set(keys), "the failed batch deleted entries")
        #expect(checkpoints.all.isEmpty, "the run checkpointed after a batch that failed: \(checkpoints.all.count)")
        #expect(afterFailure.values.allSatisfy { $0 < limit }, "the failed batch restarted clocks")

        try await env.pool.write { try $0.execute(sql: "DROP TRIGGER temp.failExpiry") }
        await purge(env)

        let after = try entries(env)
        for (i, key) in keys.enumerated() {
            if i % 2 == 0 {
                let keptFresh = after[key].map { $0 >= limit } ?? false
                #expect(keptFresh, "the next run did not keep entry \(i), whose email is in its account")
            } else {
                #expect(after[key] == nil, "the next run did not purge entry \(i), whose email is gone")
            }
        }
    }

    @Test("An entry whose stored results no longer decode is purged, and so are the others")
    func undecodableEntryDoesNotStopThePurge() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        // Neither email is on the device.
        let brokenKey = try #require(MessageAICache.cacheKey(
            accountId: Self.accountId, folderPath: "INBOX", rfc822MessageId: "broken@example.com"))
        let oldest = expired.addingTimeInterval(-60)
        try await env.pool.write { db in
            try db.execute(sql: """
                INSERT INTO messageAICache (key, rfc822MessageId, actionTag, updatedAt)
                VALUES (?, ?, 'not-an-action', ?)
                """, arguments: [brokenKey, "broken@example.com", oldest])
        }
        let plainKey = try insertEntry(env, rfc: "plain@example.com", updatedAt: expired)

        await purge(env)

        let left = try await env.pool.read { try String.fetchAll($0, sql: "SELECT key FROM messageAICache") }
        #expect(!left.contains(brokenKey), "the undecodable entry outlived the grace")
        #expect(!left.contains(plainKey), "an undecodable entry stopped the purge of the others")
    }

    /// The pass runs the purge with its real WAL checkpoint, which acts on
    /// `AppDatabase.backgroundPool`; `.processGlobalState` makes sure that database
    /// exists and that no other suite swaps it while the checkpoint runs.
    @Test("A maintenance pass purges the cache", .processGlobalState)
    func maintenancePassPurges() async throws {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, copies: [Copy(uid: "1", folderPath: "Archive", rfc: "archived@example.com")])
        let goneKey = try insertEntry(env, rfc: "gone@example.com", updatedAt: expired)
        let archivedKey = try insertEntry(env, rfc: "archived@example.com", updatedAt: expired)

        await SyncEngine.runWALMaintenance(
            dbPool: pool(env), prune: nil, undoProtectedBodyIds: [], pruneOrder: [:])

        let after = try entries(env)
        #expect(after[goneKey] == nil, "maintenance left a gone email's entry past the grace")
        let archivedClock = after[archivedKey] ?? .distantPast
        #expect(archivedClock > cutoff, "maintenance deleted an archived email's entry or left it past the grace")
    }

    /// The size of the file at `path`, in bytes.
    private func fileSize(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    /// A test database configured as the app's (SQLite's own checkpoint off), with
    /// `total` entries past the grace, half of them for emails still in their account.
    private func makeAppConfiguredEnv(total: Int, rfcPrefix: String) throws -> Env {
        let env = try makeEnv(configuration: AppDatabase.makeConfiguration())
        var copies: [Copy] = []
        for i in 0..<total {
            copies.append(Self.alternating(i, rfc: "\(rfcPrefix)\(i)@example.com"))
        }
        try insert(env, copies: copies)
        for (i, copy) in copies.enumerated() {
            try insertEntry(env, rfc: copy.rfc, updatedAt: expired.addingTimeInterval(-Double(i)))
        }
        return env
    }

    /// Installs `env`'s database as the app's; returns the one it replaced, to put back.
    private func installAsAppDatabase(_ env: Env) throws -> AppDatabase? {
        let appDatabase = try AppDatabase(dbPool: env.pool)
        return AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDatabase
            return prev
        }
    }

    /// Whether a statement keeps or deletes an AI cache entry.
    private static func changesAnEntry(_ sql: String) -> Bool {
        sql.hasPrefix("UPDATE messageAICache") || sql.hasPrefix("DELETE FROM messageAICache")
    }

    /// The purge's real WAL checkpoint, end to end, on a database configured as the
    /// app's and installed as the app's database: a run of several batches checkpoints
    /// that database after a batch it committed.
    @Test("The purge checkpoints the app's database between its batches", .processGlobalState)
    func purgeCheckpointsTheAppDatabase() async throws {
        let env = try makeAppConfiguredEnv(total: SyncConfig.pruneChunkSize * 2 + 10, rfcPrefix: "k")
        defer { finish(env) }
        let previous = try installAsAppDatabase(env)
        defer { AppDatabase.shared.withLock { $0 = previous } }
        // A checkpoint another test took a moment ago would hold the throttle's window.
        try await Task.sleep(for: .seconds(SyncConfig.walCheckpointMinIntervalSeconds))
        _ = env.tape.drain()

        await SyncEngine.runPurgeOrphanedAICache(dbPool: AppDatabase.backgroundPool)

        let writer = env.tape.drainWithConnection().filter { $0.onWriter }.map { $0.sql }
        let firstChange = writer.firstIndex(where: Self.changesAnEntry)
        let change = try #require(firstChange, "the run changed no entry")
        let checkpointed = writer[change...].contains { $0.contains("wal_checkpoint(PASSIVE)") }
        let checkpoints = writer.filter { $0.contains("wal_checkpoint") }
        #expect(checkpointed, "no checkpoint of the app's database after a batch: \(checkpoints)")
    }

    /// The common run is one batch, and the foreground maintenance pass asks for a
    /// TRUNCATE checkpoint right after it. The checkpoint throttle lets one checkpoint
    /// through per window, so a checkpoint the run took a moment before would make it
    /// skip that TRUNCATE and leave the WAL file at its full size. A run of one batch
    /// takes none, and the TRUNCATE empties the file.
    @Test("After a purge of one batch, the maintenance pass's TRUNCATE empties the WAL file", .processGlobalState)
    func oneBatchPurgeLeavesTheTruncateItsTurn() async throws {
        let env = try makeAppConfiguredEnv(total: 10, rfcPrefix: "o")
        defer { finish(env) }
        let previous = try installAsAppDatabase(env)
        defer { AppDatabase.shared.withLock { $0 = previous } }
        // A checkpoint another test took a moment ago would hold the throttle's window.
        try await Task.sleep(for: .seconds(SyncConfig.walCheckpointMinIntervalSeconds))
        _ = env.tape.drain()

        await SyncEngine.runPurgeOrphanedAICache(dbPool: AppDatabase.backgroundPool)

        let writer = env.tape.drainWithConnection().filter { $0.onWriter }.map { $0.sql }
        let changed = writer.contains(where: Self.changesAnEntry)
        let checkpoints = writer.filter { $0.contains("wal_checkpoint") }
        #expect(changed, "the run changed no entry")
        #expect(checkpoints.isEmpty, "a run of one batch checkpointed: \(checkpoints)")
        let walPath = env.pool.path + "-wal"
        let walBefore = try fileSize(walPath)
        #expect(walBefore > 0, "the WAL file was already empty, so the TRUNCATE below proves nothing")

        await SyncEngine.checkpointWALThrottled(truncate: true)

        let walAfter = try fileSize(walPath)
        #expect(walAfter == 0, "the TRUNCATE right after a run of one batch left the WAL file at \(walAfter) bytes")
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
    func everyStatementReadsThroughAnIndex(statistics: AICacheExpiryStatistics) async throws {
        let env = try makeEnv()
        defer { finish(env) }
        try insert(env, copies: [Copy(uid: "1", folderPath: "Archive", rfc: "elsewhere@example.com", accountId: Self.otherAccountId)])
        try insertEntry(env, rfc: "elsewhere@example.com", updatedAt: expired)
        if statistics == .staleSmall {
            try await env.pool.write { try $0.execute(sql: "ANALYZE") }
        }
        try insert(env, copies: (2...40).map { Copy(uid: "\($0)", folderPath: $0 == 2 ? "INBOX" : "Archive", rfc: "m\($0)@example.com") })
        for uid in 2...40 {
            try insertEntry(env, rfc: "m\(uid)@example.com", updatedAt: uid == 2 ? expired : Date())
        }
        try await env.pool.write { db in
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

        await purge(env)

        let statements = env.tape.drain().filter(Self.touchesMailTables)
        let planned = try await env.pool.read { db in
            try statements.map { (sql: $0, plan: try Self.plan(db, $0)) }
        }
        let scans = planned.filter { $0.plan.contains("SCAN messageAICache") || $0.plan.contains("SCAN messageHeader") }.map { "\($0.sql) -> \($0.plan)" }
        #expect(scans.isEmpty, "[\(statistics)] statements that scan:\n\(scans.joined(separator: "\n"))")

        func reads(_ marker: String) -> [(sql: String, plan: String)] { planned.filter { $0.sql.contains(marker) } }
        let counts = reads("SELECT COUNT(*) FROM messageAICache")
        let batches = reads("SELECT key, rfc822MessageId FROM messageAICache")
        let keepChecks = reads("FROM messageHeader INDEXED BY")
        let updates = planned.filter { $0.sql.hasPrefix("UPDATE messageAICache") }
        let deletes = planned.filter { $0.sql.hasPrefix("DELETE FROM messageAICache") }
        // The gate, then one batch with both entries past the grace, which reads one entry
        // more than it handles and so finds it is the last; one keep check per entry past
        // the grace; one entry kept, one deleted.
        #expect(counts.count == 1)
        #expect(batches.count == 1)
        #expect(keepChecks.count == 2)
        #expect(updates.count == 1)
        #expect(deletes.count == 1)
        #expect(planned.count == 6, "a statement on a mail table this test does not know: \(planned.map(\.sql))")
        for read in counts + batches {
            #expect(read.plan.contains("messageAICache_expiry (updatedAt<?)"), "\(read.sql): \(read.plan)")
        }
        for read in keepChecks {
            #expect(read.plan.contains("messageHeader_rfc822MessageId (rfc822MessageId=?)"), "\(read.sql): \(read.plan)")
        }
        for write in updates + deletes {
            #expect(write.plan.contains("(key=?)"), "\(write.sql): \(write.plan)")
        }

        // Instrument check: the same reads with their index hint taken away scan, so the
        // assertions above can fail.
        let unhinted = try await env.pool.read { db in
            try (counts + batches + keepChecks).map { read in
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

    /// The purge is maintenance's alone (ADR-IOS-114): the AI queue's drain runs no cache
    /// upkeep. A touch by key there, as the drain once ran, would keep every entry whose key
    /// names an inbox alive. The drain sits in a private actor method that only the whole AI
    /// pipeline reaches, so this is pinned on the source.
    @Test("the AI queue runs no AI cache upkeep")
    func theAIQueueRunsNoCacheUpkeep() throws {
        let sources = try DiagnosticPrintGateTests.appTargetSources()
        let queueFile = sources.first { $0.relativePath == "TabMail/Services/AI/ActiveAIQueue.swift" }
        let queueText = try #require(queueFile?.source)
        let queue = queueText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        // The file this pins still holds the drain.
        let drain = queue.contains { $0.contains("private func jobCompleted(job: AIJob, report: ExecutorReport)") }
        #expect(drain, "the AI queue's drain moved; this test reads the wrong file")

        let upkeep = queue.filter {
            $0.contains("SyncEngine.") && $0.range(of: "AICache|aiCache", options: .regularExpression) != nil
        }
        #expect(upkeep.isEmpty, "AI cache upkeep in the AI queue: \(upkeep)")
        let cacheSQL = queue.filter { $0.contains("messageAICache") }
        #expect(cacheSQL.isEmpty, "SQL on the cache in the AI queue: \(cacheSQL)")
    }
}
