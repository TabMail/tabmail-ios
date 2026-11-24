/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// Body-asset eviction's reads (ios#1382). The total (`BodyAssetStore.usedBytes`) and the choice of
/// victims (`BodyAssetStore.evictionVictims`) run in every maintenance run while a storage limit is
/// set. They used to read every row of `bodyAsset`, and to aggregate and sort every message that
/// has assets to find the oldest few.
///
/// The plan test records the statements the two calls really run, with `Database.trace` on a
/// manifest built by the production schema (`BodyAssetStore.migrateManifestSchema`), and plans each
/// one: no temporary B-tree, and the only scan allowed is of `idx_bodyAsset_lruSize`, the narrow
/// index the total reads and the walk follows in access order. The order tests pin that the walk
/// picks messages exactly as the aggregate did: by each message's latest access.
@Suite("Body-asset eviction reads the LRU index, not the whole table", .serialized, .processGlobalState)
struct BodyAssetEvictionTests {

    /// The SQL the manifest connection ran. `trace` fires on the queue's own thread, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
        func clear() { statements.withLock { $0.removeAll() } }
    }

    private static let walkedIndex = "idx_bodyAsset_lruSize"

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

    /// The plan lines of `sql` that break the rule: a temporary B-tree, or a scan of anything but
    /// `walkedIndex`.
    private static func violations(_ sql: String, in queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).compactMap { row -> String? in
                let detail: String = row["detail"]
                if detail.contains("TEMP B-TREE") { return detail }
                if detail.hasPrefix("SCAN ") && detail != "SCAN bodyAsset USING COVERING INDEX \(walkedIndex)" {
                    return detail
                }
                return nil
            }
        }
    }

    @Test("The total and the victim walk read only the LRU index, never every row or a sort")
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

    @Test("An existing manifest gains the covering index and drops the one it replaces, keeping every row")
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
        #expect(indexes == ["idx_bodyAsset_header", "idx_bodyAsset_lruSize", "idx_bodyAsset_attachmentLookup"],
                "indexes after the upgrade: \(indexes.sorted())")
        #expect(rows == 1)
    }
}
