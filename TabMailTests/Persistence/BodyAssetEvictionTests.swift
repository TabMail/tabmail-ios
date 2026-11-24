/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SQLite3
import Synchronization
@testable import TabMail

/// The two maintenance entry points that share the eviction loop. File scope: a test's arguments
/// cannot name a member of the suite type they are attached to.
enum BodyAssetEvictionEntry: String, Sendable, CaseIterable {
    case overCap
    case pressure
}

/// Body-asset eviction's reads (ios#1382). The total (`BodyAssetStore.usedBytes`) and the choice of
/// victims (`BodyAssetStore.evictionVictims`) run in every maintenance run while a storage limit is
/// set. They used to read every row of `bodyAsset`, and to aggregate and sort every message that
/// has assets to find the oldest few.
///
/// The plan test records the statements the two calls really run, with `Database.trace` on a
/// manifest built by the production schema (`BodyAssetStore.migrateManifestSchema`), and plans each
/// one: no temporary B-tree, the only scan allowed is of `idx_bodyAsset_lruSize`, the narrow index
/// the total reads and the walk follows in access order, and a message's latest access is one
/// covering seek of `idx_bodyAsset_headerAccess`, which reads none of the message's rows. The
/// workload tests count what the walk really does: its steps do not grow with the manifest when
/// the first message is enough, and a message passed over is never summed. The order tests pin
/// that the walk picks messages exactly as the aggregate did: by each message's latest access,
/// each message once. The maintenance test drives the real entry points down to their targets.
@Suite("Body-asset eviction reads the LRU index, not the whole table", .serialized, .processGlobalState)
struct BodyAssetEvictionTests {

    /// The SQL the manifest connection ran. `trace` fires on the queue's own thread, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
        func clear() { statements.withLock { $0.removeAll() } }
    }

    /// Virtual-machine steps SQLite reports through `sqlite3_progress_handler`, which fires on the
    /// queue's own thread, hence the `Mutex`.
    private final class StepCounter: Sendable {
        private let ticks = Mutex(0)
        func tick() { ticks.withLock { $0 += 1 } }
        var count: Int { ticks.withLock { $0 } }
    }

    private static let walkedIndex = "idx_bodyAsset_lruSize"

    /// The one plan a message's latest-access read may have: a seek of the covering index.
    private static let latestAccessSeek = "SEARCH bodyAsset USING COVERING INDEX idx_bodyAsset_headerAccess (headerId=?)"

    /// An asset id in the production shape, `<header hash>/<asset hash>`.
    private static func assetId(_ message: Int, _ asset: Int) -> String {
        func hex(_ value: Int) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
        }
        return hex(message) + "/" + hex(asset)
    }

    /// The virtual-machine steps the manifest connection runs inside `body`. The handler belongs to
    /// the connection, and a `DatabaseQueue` has one, so it counts every statement `body` runs.
    private static func vmSteps(on queue: DatabaseQueue, _ body: () -> Void) -> Int {
        let counter = StepCounter()
        let context = Unmanaged.passRetained(counter)
        defer { context.release() }
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { raw in
            guard let raw else { return 0 }
            Unmanaged<StepCounter>.fromOpaque(raw).takeUnretainedValue().tick()
            return 0
        }
        queue.inDatabase { db in
            sqlite3_progress_handler(db.sqliteConnection, 1, callback, context.toOpaque())
        }
        body()
        queue.inDatabase { db in
            sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil)
        }
        return counter.count
    }

    private static func makeManifest(trace tape: SQLTape? = nil) throws -> (URL, DatabaseQueue) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bodyAssetEviction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        if let tape {
            config.prepareDatabase { db in
                db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
            }
        }
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { db in try BodyAssetStore.migrateManifestSchema(db) }
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: queue)
        return (dir, queue)
    }

    private static func teardown(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    /// One manifest row. `access` is `lastAccessedAt` in ms (nil = never opened).
    private static func insert(
        _ db: Database, id: String, key: ContentKey, kind: BodyAssetKind = .attachment,
        bytes: Int, access: Int64?
    ) throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute(
            sql: """
            INSERT INTO bodyAsset (id, headerId, kind, contentId, attachmentSection, contentType,
                                   sizeBytes, createdAt, lastAccessedAt, identityStamp)
            VALUES (?, ?, ?, NULL, ?, 'application/octet-stream', ?, ?, ?, NULL)
            """,
            arguments: [id, key, kind.rawValue, id, bytes, nowMs, access]
        )
    }

    /// The plan lines of `sql` that break the rule: a temporary B-tree, a scan of anything but
    /// `walkedIndex`, or, for a message's latest-access read, anything but `latestAccessSeek`.
    private static func violations(_ sql: String, in queue: DatabaseQueue) throws -> [String] {
        let isLatestAccessRead = sql.contains("MAX(lastAccessedAt)")
        return try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).compactMap { row -> String? in
                let detail: String = row["detail"]
                if detail.contains("TEMP B-TREE") { return detail }
                if isLatestAccessRead && detail != latestAccessSeek { return detail }
                if detail.hasPrefix("SCAN ") && detail != "SCAN bodyAsset USING COVERING INDEX \(walkedIndex)" {
                    return detail
                }
                return nil
            }
        }
    }

    @Test("The total and the victim walk read only the LRU index and one covering seek per message, never every row or a sort")
    func eachReadPlansOnTheIndex() throws {
        let tape = SQLTape()
        let (dir, queue) = try Self.makeManifest(trace: tape)
        defer { Self.teardown(dir) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.write { db in
            try Self.insert(db, id: "a/1", key: ContentKey(rawValue: "acct:INBOX:1"), bytes: 10, access: nil)
            try Self.insert(db, id: "b/1", key: ContentKey(rawValue: "acct:INBOX:2"), bytes: 20, access: nowMs)
        }
        BodyAssetStore.invalidateUsedBytesCachePublic()
        tape.clear()

        let total = BodyAssetStore.usedBytes
        let victims = BodyAssetStore.evictionVictims(coveringBytes: 1_000, limit: 10)

        #expect(total == 30, "precondition: the total read the rows (\(total))")
        #expect(victims.count == 2, "precondition: the walk reached both messages (\(victims.count))")
        let reads = tape.all.filter { $0.uppercased().hasPrefix("SELECT") && $0.contains("bodyAsset") }
        #expect(reads.contains { $0.contains("SUM(sizeBytes)") && !$0.contains("WHERE") },
                "precondition: the trace recorded the total (\(tape.all))")
        #expect(reads.contains { $0.contains("ORDER BY lastAccessedAt") },
                "precondition: the trace recorded the walk (\(tape.all))")
        #expect(reads.contains { $0.contains("MAX(lastAccessedAt)") },
                "precondition: the trace recorded a latest-access read (\(tape.all))")

        var broken: [String] = []
        for sql in reads {
            let lines = try Self.violations(sql, in: queue)
            if !lines.isEmpty { broken.append("\(lines) by \(sql)") }
        }
        #expect(broken.isEmpty, "an eviction read scanned the table or sorted: \(broken)")
    }

    @Test("Negative control: the aggregate this fix replaced breaks the same rule")
    func theReplacedAggregateBreaksTheRule() throws {
        let (dir, queue) = try Self.makeManifest()
        defer { Self.teardown(dir) }
        let replaced = """
            SELECT headerId, SUM(sizeBytes) AS totalBytes,
                   SUM(CASE WHEN kind = 0 THEN 1 ELSE 0 END) AS inlineCount
            FROM bodyAsset GROUP BY headerId HAVING totalBytes > 0
            ORDER BY MAX(COALESCE(lastAccessedAt, 0)) ASC LIMIT 100
            """
        let lines = try Self.violations(replaced, in: queue)
        #expect(lines.contains { $0.contains("TEMP B-TREE") }, "the predicate must catch the replaced sort; it saw \(lines)")
    }

    @Test("Victims come in order of each message's latest access, never by an older row of a recently opened message")
    func victimsFollowEachMessagesLatestAccess() throws {
        let (dir, queue) = try Self.makeManifest()
        defer { Self.teardown(dir) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let openedLast = ContentKey(rawValue: "acct:INBOX:1")
        let openedEarlier = ContentKey(rawValue: "acct:INBOX:2")
        let neverOpened = ContentKey(rawValue: "acct:INBOX:3")
        let empty = ContentKey(rawValue: "acct:INBOX:4")
        try queue.write { db in
            // Opened most recently; its second asset was written after that, so it is still NULL.
            // A walk that took a message at its OLDEST row would take this one first: its NULL row
            // sorts before `neverOpened`'s (same NULL, lower headerId).
            try Self.insert(db, id: "a/1", key: openedLast, bytes: 100, access: nowMs - 1_000)
            try Self.insert(db, id: "a/2", key: openedLast, bytes: 100, access: nil)
            try Self.insert(db, id: "b/1", key: openedEarlier, kind: .inlineImage, bytes: 100, access: nowMs - 60_000)
            try Self.insert(db, id: "c/1", key: neverOpened, kind: .inlineImage, bytes: 100, access: nil)
            try Self.insert(db, id: "c/2", key: neverOpened, bytes: 100, access: nil)
            try Self.insert(db, id: "d/1", key: empty, bytes: 0, access: nil)
        }

        let all = BodyAssetStore.evictionVictims(coveringBytes: .max, limit: 100)
        #expect(all.map(\.contentKey) == [neverOpened, openedEarlier, openedLast],
                "order by latest access, zero-byte message skipped: \(all.map(\.contentKey.rawValue))")
        #expect(all.map(\.totalBytes) == [200, 100, 200])
        #expect(all.map(\.inlineCount) == [1, 1, 0])
    }

    @Test("The walk stops once the victims cover the bytes asked for, or at the limit")
    func walkStopsWhenEnoughIsChosen() throws {
        let (dir, queue) = try Self.makeManifest()
        defer { Self.teardown(dir) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let first = ContentKey(rawValue: "acct:INBOX:1")
        let second = ContentKey(rawValue: "acct:INBOX:2")
        let third = ContentKey(rawValue: "acct:INBOX:3")
        try queue.write { db in
            try Self.insert(db, id: "a/1", key: first, bytes: 100, access: nowMs - 30_000)
            try Self.insert(db, id: "b/1", key: second, bytes: 100, access: nowMs - 20_000)
            try Self.insert(db, id: "c/1", key: third, bytes: 100, access: nowMs - 10_000)
        }

        #expect(BodyAssetStore.evictionVictims(coveringBytes: 100, limit: 100).map(\.contentKey) == [first])
        #expect(BodyAssetStore.evictionVictims(coveringBytes: 101, limit: 100).map(\.contentKey) == [first, second])
        #expect(BodyAssetStore.evictionVictims(coveringBytes: 1_000, limit: 2).map(\.contentKey) == [first, second])
        #expect(BodyAssetStore.evictionVictims(coveringBytes: 0, limit: 100).isEmpty)
    }

    @Test("When the first message is enough, the walk's work does not grow with the manifest")
    func walkWorkDoesNotGrowWithTheManifest() throws {
        let smallMessages = 20
        let largeMessages = 2_000
        func walk(messages: Int) throws -> (steps: Int, victims: Int) {
            let (dir, queue) = try Self.makeManifest()
            defer { Self.teardown(dir) }
            try queue.write { db in
                for message in 0..<messages {
                    let key = ContentKey(rawValue: "acct:INBOX:\(message)")
                    try Self.insert(db, id: Self.assetId(message, 0), key: key, kind: .inlineImage, bytes: 100, access: nil)
                    try Self.insert(db, id: Self.assetId(message, 1), key: key, bytes: 100, access: nil)
                }
            }
            var victims: [BodyAssetStore.VictimSummary] = []
            let steps = Self.vmSteps(on: queue) {
                victims = BodyAssetStore.evictionVictims(coveringBytes: 1, limit: 1)
            }
            return (steps, victims.count)
        }

        let small = try walk(messages: smallMessages)
        let large = try walk(messages: largeMessages)

        #expect(small.victims == 1, "precondition: the small walk chose one victim (\(small.victims))")
        #expect(large.victims == 1, "precondition: the large walk chose one victim (\(large.victims))")
        #expect(small.steps > 0, "precondition: the progress handler counted the walk")
        let addedRows = (largeMessages - smallMessages) * 2
        let growth = large.steps - small.steps
        #expect(growth < addedRows / 20,
                "the walk read rows it did not need: \(small.steps) steps for \(smallMessages) messages, \(large.steps) for \(largeMessages)")
    }

    @Test("A message passed over is never summed: one summary per victim, one covering seek per message met")
    func onlyVictimsAreSummed() throws {
        let tape = SQLTape()
        let (dir, queue) = try Self.makeManifest(trace: tape)
        defer { Self.teardown(dir) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let mixed = 30
        try queue.write { db in
            for message in 0..<mixed {
                let key = ContentKey(rawValue: "acct:INBOX:\(message)")
                // Opened (`bumpMessageAccess` stamps every row), then given a new asset, which
                // `publish` writes with no access yet. The NULL row sorts first, but the message's
                // place is its stamp, so the walk meets every message before its first victim.
                try Self.insert(db, id: Self.assetId(message, 0), key: key, bytes: 100,
                                access: nowMs - Int64(mixed - message) * 1_000)
                try Self.insert(db, id: Self.assetId(message, 1), key: key, kind: .inlineImage, bytes: 100, access: nil)
            }
        }
        tape.clear()

        let victims = BodyAssetStore.evictionVictims(coveringBytes: 1, limit: 1)

        #expect(victims.map(\.contentKey) == [ContentKey(rawValue: "acct:INBOX:0")],
                "the least recently opened message: \(victims.map(\.contentKey.rawValue))")
        #expect(victims.map(\.totalBytes) == [200])
        #expect(victims.map(\.inlineCount) == [1])
        let statements = tape.all
        let summaries = statements.filter { $0.contains("SUM(sizeBytes)") && $0.contains("WHERE headerId") }.count
        let seeks = statements.filter { $0.contains("MAX(lastAccessedAt)") }.count
        #expect(seeks >= mixed, "precondition: the walk met every message in the NULL prefix (\(seeks) seeks)")
        #expect(summaries == victims.count, "only a victim is summed: \(summaries) summaries for \(victims.count) victims")
        #expect(seeks <= mixed + victims.count, "at most one seek per message met: \(seeks)")
    }

    @Test("Messages tied at the same latest access each come once, whole, before any later message")
    func tiedMessagesEachComeOnce() throws {
        let (dir, queue) = try Self.makeManifest()
        defer { Self.teardown(dir) }
        let shared = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        func key(_ message: Int) -> ContentKey { ContentKey(rawValue: "acct:INBOX:\(message)") }
        try queue.write { db in
            // Never opened: tied at NULL.
            try Self.insert(db, id: Self.assetId(1, 0), key: key(1), kind: .inlineImage, bytes: 50, access: nil)
            try Self.insert(db, id: Self.assetId(1, 1), key: key(1), bytes: 100, access: nil)
            try Self.insert(db, id: Self.assetId(2, 0), key: key(2), bytes: 100, access: nil)
            try Self.insert(db, id: Self.assetId(2, 1), key: key(2), bytes: 125, access: nil)
            try Self.insert(db, id: Self.assetId(3, 0), key: key(3), kind: .inlineImage, bytes: 100, access: nil)
            try Self.insert(db, id: Self.assetId(3, 1), key: key(3), bytes: 200, access: nil)
            // Opened at the same moment: tied at `shared`. Message 5 also has an asset published
            // after that, still NULL.
            try Self.insert(db, id: Self.assetId(4, 0), key: key(4), bytes: 10, access: shared)
            try Self.insert(db, id: Self.assetId(4, 1), key: key(4), bytes: 20, access: shared)
            try Self.insert(db, id: Self.assetId(5, 0), key: key(5), kind: .inlineImage, bytes: 20, access: shared)
            try Self.insert(db, id: Self.assetId(5, 1), key: key(5), bytes: 25, access: nil)
            try Self.insert(db, id: Self.assetId(6, 0), key: key(6), kind: .inlineImage, bytes: 30, access: shared)
            try Self.insert(db, id: Self.assetId(6, 1), key: key(6), bytes: 30, access: shared)
            // Opened later.
            try Self.insert(db, id: Self.assetId(7, 0), key: key(7), bytes: 70, access: shared + 30_000)
        }
        let neverOpened: Set<String> = ["acct:INBOX:1", "acct:INBOX:2", "acct:INBOX:3"]
        let openedTogether: Set<String> = ["acct:INBOX:4", "acct:INBOX:5", "acct:INBOX:6"]
        let expectedSummaries: [String: String] = [
            "acct:INBOX:1": "150/1", "acct:INBOX:2": "225/0", "acct:INBOX:3": "300/1",
            "acct:INBOX:4": "30/0", "acct:INBOX:5": "45/1", "acct:INBOX:6": "60/1",
            "acct:INBOX:7": "70/0",
        ]

        // The replaced aggregate had no order within a tie, so only membership is pinned there.
        let all = BodyAssetStore.evictionVictims(coveringBytes: .max, limit: 100)
        let keys = all.map(\.contentKey.rawValue)
        let summaries = Dictionary(all.map { ($0.contentKey.rawValue, "\($0.totalBytes)/\($0.inlineCount)") },
                                   uniquingKeysWith: { first, _ in first })
        #expect(keys.count == 7, "every message once: \(keys)")
        #expect(Set(keys).count == keys.count, "no message twice: \(keys)")
        #expect(summaries == expectedSummaries)
        guard keys.count == 7 else { return }
        let firstTie = Set(keys[0..<3])
        let secondTie = Set(keys[3..<6])
        #expect(firstTie == neverOpened, "the never-opened messages first: \(keys)")
        #expect(secondTie == openedTogether, "then the messages opened together: \(keys)")
        #expect(keys[6] == "acct:INBOX:7")

        let firstTwo = BodyAssetStore.evictionVictims(coveringBytes: .max, limit: 2).map(\.contentKey.rawValue)
        let firstTwoSet = Set(firstTwo)
        #expect(firstTwo.count == 2 && firstTwoSet.count == 2, "two distinct messages at the limit: \(firstTwo)")
        #expect(firstTwoSet.isSubset(of: neverOpened), "both from the first tie: \(firstTwo)")

        let enough = BodyAssetStore.evictionVictims(coveringBytes: 151, limit: 100)
        let enoughKeys = Set(enough.map(\.contentKey.rawValue))
        let covered = enough.reduce(Int64(0)) { $0 + $1.totalBytes }
        let beforeLast = covered - (enough.last?.totalBytes ?? 0)
        #expect(enoughKeys.count == enough.count && enoughKeys.isSubset(of: neverOpened),
                "distinct messages from the first tie: \(enough.map(\.contentKey.rawValue))")
        #expect(covered >= 151, "the victims cover the bytes asked for: \(covered)")
        #expect(beforeLast < 151, "the walk stopped at the first victim that covered them: \(beforeLast)")
    }

    @Test("Maintenance evicts the least recently opened messages down to its target, through the real entry point",
          arguments: BodyAssetEvictionEntry.allCases)
    func maintenanceEvictsDownToItsTarget(_ entry: BodyAssetEvictionEntry) async throws {
        let (dir, queue) = try Self.makeManifest()
        defer { Self.teardown(dir) }
        let defaults = try #require(UserDefaults(suiteName: BodyAssetConfig.appGroup))
        let budgetKey = BodyAssetConfig.attachmentsBudgetMBKey
        let savedBudget = defaults.object(forKey: budgetKey)
        defer {
            if let savedBudget { defaults.set(savedBudget, forKey: budgetKey) } else { defaults.removeObject(forKey: budgetKey) }
        }
        BodyAssetStore.attachmentsBudgetMB = 1
        let budget = BodyAssetStore.attachmentsBudgetMB
        #expect(budget == 1, "precondition: a 1 MB budget (\(budget))")
        let active = DatabaseSuspension.isAppActive && !DatabaseSuspension.isSuspended
        try #require(active, "precondition: maintenance runs only while the app is active")

        // Six messages of 300,000 bytes, the first opened longest ago. The first and the last
        // carry inline images and cached HTML. 1,800,000 bytes against a 1 MB cap: over cap, the
        // run goes down to 0.9 of it and keeps the three newest; under pressure, to 0.5 of it
        // and keeps the newest.
        let accountId = "bae-\(UUID().uuidString.prefix(8))"
        let folderPath = "Archive"
        let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: folderPath)
        let headerIds = (1...6).map {
            MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: "m\($0)")
        }
        let withHTML: Set<String> = [headerIds[0], headerIds[5]]
        try await AppDatabase.dbPool.write { db in
            var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .gmail)
            account.id = accountId
            try account.insert(db)
            let folder = Folder(name: folderPath, path: folderPath, role: .archive, accountId: accountId)
            try folder.insert(db)
            for (index, headerId) in headerIds.enumerated() {
                var header = MessageHeader(
                    messageId: "m\(index + 1)",
                    subject: "eviction test",
                    from: "a@example.com", fromAddress: "a@example.com", to: "b@example.com",
                    date: Date(), snippet: "",
                    folderId: folderId, accountId: accountId, folderPath: folderPath,
                    isInInbox: false
                )
                header.headerComplete = true
                header.bodyComplete = true
                try header.insert(db)
                if withHTML.contains(headerId) {
                    let body = MessageBody(contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>cached</p>")
                    try body.insert(db)
                }
            }
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await queue.write { db in
            for (index, headerId) in headerIds.enumerated() {
                let key = ContentKey(rawValue: headerId)
                let access = nowMs - Int64(headerIds.count - index) * 60_000
                if withHTML.contains(headerId) {
                    try Self.insert(db, id: Self.assetId(index, 0), key: key, kind: .inlineImage, bytes: 100_000, access: access)
                    try Self.insert(db, id: Self.assetId(index, 1), key: key, bytes: 200_000, access: access)
                } else {
                    try Self.insert(db, id: Self.assetId(index, 0), key: key, bytes: 300_000, access: access)
                }
            }
        }
        BodyAssetStore.invalidateUsedBytesCachePublic()
        let before = BodyAssetStore.usedBytes
        #expect(before == 1_800_000, "precondition: the manifest holds 1,800,000 bytes (\(before))")

        switch entry {
        case .overCap: await BodyAssetMaintenance.evictIfOverCap()
        case .pressure: await BodyAssetMaintenance.pruneForPressure()
        }

        let kept = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT headerId FROM bodyAsset")
        }
        BodyAssetStore.invalidateUsedBytesCachePublic()
        let after = BodyAssetStore.usedBytes
        let expectedKept = entry == .overCap ? Set(headerIds.suffix(3)) : Set(headerIds.suffix(1))
        let expectedBytes: Int64 = entry == .overCap ? 900_000 : 300_000
        #expect(Set(kept) == expectedKept, "\(entry): kept \(kept.count) messages")
        #expect(after == expectedBytes, "\(entry): \(after) bytes left")

        // Dropping the first message's inline images drops its cached HTML; the newest keeps
        // both. No message loses `bodyComplete`.
        let state = try await AppDatabase.dbPool.read { db -> [String] in
            try headerIds.map { headerId in
                let cached = try MessageBody.fetchOne(db, key: headerId) != nil
                let complete = try Bool.fetchOne(
                    db, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [headerId]
                ) ?? false
                return "\(cached ? "html" : "-")/\(complete ? "complete" : "-")"
            }
        }
        #expect(state == ["-/complete", "-/complete", "-/complete", "-/complete", "-/complete", "html/complete"],
                "\(entry): \(state)")

        try await AppDatabase.dbPool.write { db in
            try MessageBody.deleteAll(db, keys: headerIds)
            try MessageHeader.filter(Column("accountId") == accountId).deleteAll(db)
            try Folder.filter(Column("accountId") == accountId).deleteAll(db)
            try Account.deleteOne(db, key: accountId)
        }
    }

    @Test("An existing manifest gains the covering indexes and drops the ones they replace, keeping every row")
    func existingManifestConverges() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            // The manifest as devices hold it before this change.
            try db.execute(sql: """
                CREATE TABLE bodyAsset (
                    id TEXT PRIMARY KEY, headerId TEXT NOT NULL, kind INTEGER NOT NULL, contentId TEXT,
                    attachmentSection TEXT, contentType TEXT NOT NULL, sizeBytes INTEGER NOT NULL,
                    createdAt INTEGER NOT NULL, lastAccessedAt INTEGER, identityStamp TEXT)
                """)
            try db.execute(sql: "CREATE INDEX idx_bodyAsset_header ON bodyAsset (headerId)")
            try db.execute(sql: "CREATE INDEX idx_bodyAsset_lru ON bodyAsset (lastAccessedAt)")
            try db.execute(sql: "CREATE INDEX idx_bodyAsset_attachmentLookup ON bodyAsset (headerId, kind, attachmentSection)")
            try Self.insert(db, id: "a/1", key: ContentKey(rawValue: "acct:INBOX:1"), bytes: 10, access: nil)
        }

        try queue.write { db in try BodyAssetStore.migrateManifestSchema(db) }
        try queue.write { db in try BodyAssetStore.migrateManifestSchema(db) }

        let (indexes, rows) = try queue.read { db -> (Set<String>, Int) in
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'bodyAsset' AND sql IS NOT NULL"
            )
            return (Set(names), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bodyAsset") ?? -1)
        }
        #expect(indexes == ["idx_bodyAsset_headerAccess", "idx_bodyAsset_lruSize", "idx_bodyAsset_attachmentLookup"],
                "indexes after the upgrade: \(indexes.sorted())")
        #expect(rows == 1)
    }
}
