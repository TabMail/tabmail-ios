/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1433: the evict that walks the headers (`HTMLCachePair`) against the evict it
/// replaced, which walked the bodies, on the same database.
///
/// THE PROPERTY: the new run evicts exactly what the old one did, minus the bodies
/// no header holds. The old run read every stale body and deleted the headerless ones
/// its ownership gate did not protect (its "orphan leg"); the new one never reads a
/// body without its header, and every rule for a body with a header is unchanged. So
/// `old − new` is the headerless bodies the old run took, and `new ⊆ old`.
///
/// `legacyEvict` is the old step, copied from `SyncEngine.runEvictStaleBodies` at
/// dd9150d13 (#1354's keyset walk on `messageBody(fetchedAt)`), run in one write and
/// rolled back, so the production step then runs on the same rows.
@Suite("Stale-body evict: the header walk against the body walk it replaced", .timeLimit(.minutes(2)))
struct StaleBodyEvictDifferentialTests {

    typealias Hold = StaleBodyEvictWriterHoldTests

    static let html = "<p>cached</p>"
    static let liveFolders = ["INBOX", "Archive", "Projects"]
    /// Under a UIDVALIDITY reset: the old gate protected its headerless bodies.
    static let heldFolder = "Held"
    /// No such folder: the old gate could not resolve it, and deleted.
    static let ghostFolder = "Ghost"
    /// A second account with the same live folders, for the seeded databases.
    static let secondAccountId = "evict-other"

    /// The old step's keyset position: the last body a page looked at, as stored.
    struct LegacyCursor {
        let fetchedAt: DatabaseValue
        let rowId: Int64
    }

    /// The old step's cutoff, computed as it did at the start of a run.
    static func legacyCutoff() -> Date {
        Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date()) ?? Date.distantPast
    }

    /// The old step's page (`staleBodyPageSQL` at dd9150d13): a seek on
    /// `messageBody_staleEvict`. Arguments: `[cutoff, limit]`, or
    /// `[cutoff, cursor fetchedAt, cursor rowid, limit]` after a cursor.
    static func legacyPageSQL(afterCursor: Bool) -> String {
        """
        SELECT rowid AS bodyRowId, id, fetchedAt FROM messageBody
        WHERE fetchedAt < ?\(afterCursor ? " AND (fetchedAt, rowid) > (?, ?)" : "")
        ORDER BY fetchedAt, rowid LIMIT ?
        """
    }

    /// One page of the old step, copied from dd9150d13: the next
    /// `SyncConfig.pruneChunkSize` bodies older than the cutoff in
    /// `messageBody_staleEvict` order, each one's header read by primary key, and its
    /// rules applied. The old step ran each page in its own write; `legacyEvict` runs
    /// them all in one. Returns the ids it deleted and the cursor after the page (nil
    /// when the page was empty).
    static func legacyEvictPage(
        _ db: Database, cutoff: Date, after cursor: LegacyCursor?,
        recentCache: inout [String: Set<String>], undoProtectedBodyIds: Set<String>
    ) throws -> (deleted: [String], last: LegacyCursor?) {
        let recentPerFolder = SyncConfig.bodyCacheRecentPerFolder
        let chunkSize = SyncConfig.pruneChunkSize
        let pageSQL = Self.legacyPageSQL(afterCursor: cursor != nil)
        let pageArguments: StatementArguments
        if let cursor {
            pageArguments = [cutoff, cursor.fetchedAt, cursor.rowId, chunkSize]
        } else {
            pageArguments = [cutoff, chunkSize]
        }
        let page = try Row.fetchAll(db, sql: pageSQL, arguments: pageArguments)
        guard let lastRow = page.last else { return ([], nil) }
        let batch: [ContentKey] = page.map { ContentKey(rawValue: $0["id"]) }
        let batchIds = batch.map(\.rawValue)
        let existingHeaderIds = try Set(String.fetchAll(
            db, MessageHeader.select(Column("id")).filter(batchIds.contains(Column("id")))))
        let orphanCandidates = batch.filter { !existingHeaderIds.contains($0.rawValue) }
        let protectedOrphans: Set<ContentKey>
        do {
            protectedOrphans = try MessageContentStore.protectedKeys(among: orphanCandidates, db: db)
        } catch {
            protectedOrphans = Set(orphanCandidates)
        }
        var deleted: [String] = []
        for key in batch {
            if undoProtectedBodyIds.contains(key.rawValue) {
                continue
            }
            guard let header = try MessageHeader.fetchOne(db, key: key.rawValue) else {
                guard !protectedOrphans.contains(key) else { continue }
                try MessageBody.deleteOne(db, key: key.rawValue)
                deleted.append(key.rawValue)
                continue
            }
            if header.isInInbox {
                continue
            }
            if recentCache[header.folderId] == nil {
                recentCache[header.folderId] = try Set(String.fetchAll(db,
                    MessageHeader
                        .select(Column("id"))
                        .filter(Column("folderId") == header.folderId)
                        .order(Column("date").desc)
                        .limit(recentPerFolder)))
            }
            if recentCache[header.folderId]?.contains(header.id) == true {
                continue
            }
            try MessageBody.deleteOne(db, key: key.rawValue)
            deleted.append(key.rawValue)
        }
        return (deleted, LegacyCursor(fetchedAt: lastRow["fetchedAt"], rowId: lastRow["bodyRowId"]))
    }

    /// The old step, copied from dd9150d13, in one transaction with no checkpoint.
    /// Returns the ids it deleted.
    static func legacyEvict(_ db: Database, undoProtectedBodyIds: Set<String>) throws -> Set<String> {
        let cutoff = Self.legacyCutoff()
        var recentCache: [String: Set<String>] = [:]
        var deleted: Set<String> = []
        var cursor: LegacyCursor?
        while true {
            let page = try Self.legacyEvictPage(
                db, cutoff: cutoff, after: cursor, recentCache: &recentCache,
                undoProtectedBodyIds: undoProtectedBodyIds)
            guard let last = page.last else { break }
            deleted.formUnion(page.deleted)
            cursor = last
        }
        return deleted
    }

    /// The fixture plus a second non-inbox folder and a quarantined one, and a second
    /// account with the same live folders.
    static func makeFixture() throws -> Hold.Fixture {
        let fixture = try Hold.makeFixture()
        try fixture.pool.write { db in
            try Folder(name: "Projects", path: "Projects", role: .custom, accountId: fixture.accountId).insert(db)
            var held = Folder(name: Self.heldFolder, path: Self.heldFolder, role: .custom, accountId: fixture.accountId)
            held.uidValidityResetPendingAt = Date()
            try held.insert(db)
            var other = Account(
                emailAddress: "\(Self.secondAccountId)@example.com", displayName: "T2", provider: .imap)
            other.id = Self.secondAccountId
            try other.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.secondAccountId).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: Self.secondAccountId).insert(db)
            try Folder(name: "Projects", path: "Projects", role: .custom, accountId: Self.secondAccountId).insert(db)
        }
        return fixture
    }

    static func hoursAgo(_ hours: Int) -> Date {
        Date().addingTimeInterval(-Double(hours) * 3_600)
    }

    static func insertHeader(
        _ db: Database, accountId: String, folderPath: String, uid: Int, date: Date
    ) throws -> String {
        let header = MessageHeader(
            messageId: String(uid), subject: "Differential \(uid)", from: "sender@example.com",
            fromAddress: "sender@example.com", to: "user@example.com", date: date, snippet: "",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: folderPath == "INBOX")
        try header.insert(db)
        return header.id
    }

    /// `replacing` saves over an existing body, as a re-fetch does.
    static func insertBody(_ db: Database, id: String, fetchedAt: Date, replacing: Bool = false) throws {
        var body = MessageBody(contentKey: ContentKey(rawValue: id), htmlContent: Self.html)
        body.fetchedAt = fetchedAt
        if replacing {
            try body.save(db)
        } else {
            try body.insert(db)
        }
    }

    struct Outcome {
        let old: Set<String>
        let new: Set<String>
        let headerless: Set<String>
    }

    /// The old step's deletes on the fixture's rows, rolled back.
    static func legacyEvictRolledBack(_ fixture: Hold.Fixture, undoProtected: Set<String>) throws -> Set<String> {
        try fixture.pool.write { db -> Set<String> in
            var deleted: Set<String> = []
            try db.inSavepoint {
                deleted = try Self.legacyEvict(db, undoProtectedBodyIds: undoProtected)
                return .rollback
            }
            return deleted
        }
    }

    static func headerlessBodyIds(_ fixture: Hold.Fixture) throws -> Set<String> {
        try fixture.pool.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM messageBody WHERE id NOT IN (SELECT id FROM messageHeader)"))
        }
    }

    static func pairMismatches(_ fixture: Hold.Fixture) throws -> [String] {
        try fixture.pool.read { db in try HTMLCachePairTests.mismatches(db) }
    }

    /// Runs the old step and rolls it back, then runs the production step, on the
    /// same rows.
    static func compare(_ fixture: Hold.Fixture, undoProtected: Set<String>) async throws -> Outcome {
        let before = try Hold.bodyIds(fixture)
        let headerless = try Self.headerlessBodyIds(fixture)
        let old = try Self.legacyEvictRolledBack(fixture, undoProtected: undoProtected)
        let restored = try Hold.bodyIds(fixture)
        #expect(restored == before, "setup: the old run was rolled back")
        await StaleBodyEvictRunTests.run(fixture, undoProtected: undoProtected)
        let after = try Hold.bodyIds(fixture)
        let mismatches = try Self.pairMismatches(fixture)
        #expect(mismatches.isEmpty, "the pair stays exact through the run: \(mismatches)")
        return Outcome(old: old, new: before.subtracting(after), headerless: headerless)
    }

    static func expectTheProperty(_ outcome: Outcome, _ label: String) {
        let extra = outcome.new.subtracting(outcome.old)
        let missed = outcome.old.subtracting(outcome.new)
        let orphansTaken = outcome.old.intersection(outcome.headerless)
        let difference = missed.symmetricDifference(orphansTaken).sorted()
        let headerlessDeleted = outcome.new.intersection(outcome.headerless).sorted()
        #expect(extra.isEmpty, "\(label): the new run evicted what the old did not: \(extra.sorted())")
        #expect(difference.isEmpty,
                "\(label): old minus new must be exactly the headerless bodies the old run took; differs by \(difference)")
        #expect(headerlessDeleted.isEmpty, "\(label): the new run never deletes a headerless body: \(headerlessDeleted)")
    }

    // MARK: - Named cases

    /// Every rule once. Returns the ids by case name.
    static func seedNamedCases(_ fixture: Hold.Fixture) throws -> [String: String] {
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let stale = SyncConfig.bodyCacheTTLHours + 24
        let fresh = max(SyncConfig.bodyCacheTTLHours - 24, 0)
        let accountId = fixture.accountId
        return try fixture.pool.write { db -> [String: String] in
            var ids: [String: String] = [:]
            // Archive: `recent + 3` messages, newest first, stale bodies; the oldest
            // three are victims unless another rule keeps them.
            var archive: [String] = []
            for index in 0..<(recent + 3) {
                let id = try Self.insertHeader(
                    db, accountId: accountId, folderPath: "Archive", uid: 1_000 + index, date: Self.hoursAgo(index + 1))
                try Self.insertBody(db, id: id, fetchedAt: Self.hoursAgo(stale + index))
                archive.append(id)
            }
            ids["newest kept"] = archive[0]
            ids["victim"] = archive[recent]
            ids["undo kept"] = archive[recent + 1]
            ids["victim 2"] = archive[recent + 2]
            let inbox = try Self.insertHeader(db, accountId: accountId, folderPath: "INBOX", uid: 2_000, date: Self.hoursAgo(5_000))
            try Self.insertBody(db, id: inbox, fetchedAt: Self.hoursAgo(stale))
            ids["inbox kept"] = inbox
            // Projects: the oldest of `recent + 1` messages, cached recently.
            let freshArchived = try Self.insertHeader(
                db, accountId: accountId, folderPath: "Projects", uid: 3_000, date: Self.hoursAgo(9_000))
            for index in 1...recent {
                _ = try Self.insertHeader(
                    db, accountId: accountId, folderPath: "Projects", uid: 3_000 + index, date: Self.hoursAgo(index))
            }
            try Self.insertBody(db, id: freshArchived, fetchedAt: Self.hoursAgo(fresh))
            ids["fresh kept"] = freshArchived
            let orphans: [(String, String, Int)] = [
                ("orphan, live folder", "Archive", stale),
                ("orphan, quarantined folder", Self.heldFolder, stale),
                ("orphan, no folder", Self.ghostFolder, stale),
                ("orphan, fresh", "Archive", fresh),
            ]
            for (offset, (name, folderPath, age)) in orphans.enumerated() {
                let id = MessageIdentity.headerId(accountId: accountId, folderPath: folderPath, messageId: String(4_000 + offset))
                try Self.insertBody(db, id: id, fetchedAt: Self.hoursAgo(age))
                ids[name] = id
            }
            return ids
        }
    }

    @Test("Named cases: each rule keeps or evicts the same body in both runs, and only headerless bodies differ")
    func namedCases() async throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        let ids = try Self.seedNamedCases(fixture)
        func id(_ name: String) -> String { ids[name] ?? "missing \(name)" }

        let outcome = try await Self.compare(fixture, undoProtected: [id("undo kept")])

        let expectedOld: Set<String> = [id("victim"), id("victim 2"), id("orphan, live folder"), id("orphan, no folder")]
        let expectedNew: Set<String> = [id("victim"), id("victim 2")]
        #expect(outcome.old == expectedOld, "the old run: \(outcome.old.sorted())")
        #expect(outcome.new == expectedNew, "the new run: \(outcome.new.sorted())")
        Self.expectTheProperty(outcome, "named cases")
    }

    // MARK: - Seeded

    /// A whole number of hours on either side of the TTL cutoff, never near it: the
    /// two runs compute their cutoffs moments apart.
    static func randomAge(using rng: inout DBProof.SeededGenerator) -> Int {
        let ttl = SyncConfig.bodyCacheTTLHours
        return Bool.random(using: &rng)
            ? ttl + Int.random(in: 1...2_000, using: &rng)
            : Int.random(in: 0..<max(ttl - 1, 1), using: &rng)
    }

    /// What a seed made, beyond its rows: the undo set, and how many of each change
    /// after caching it applied.
    struct Seeded {
        var undo: Set<String> = []
        var inboxMoves = 0
        var refetches = 0
        var carried = 0
    }

    /// Replaces the fixture's messages and bodies with seed `seed`'s.
    ///
    /// Per account and live folder, messages newest first; one in four shares the
    /// date of the message before it, so a folder's newest N can end inside a tie.
    /// Most messages get a body. Half the bodies share one of two stale cache times
    /// (bodies fetched in one batch), so a shared time spans more candidates than a
    /// page. Then, after caching: some messages move into or out of the inbox with
    /// their id kept (a label change), some bodies are fetched again, and some
    /// messages are moved optimistically and then carried to their canonical id by
    /// the full sync's canonicalize pass (`SyncEngine.canonicalizeLocalRows`, the
    /// production function), which carries the body with its cache time.
    static func seedRandom(_ fixture: Hold.Fixture, seed: Int) throws -> Seeded {
        let recent = SyncConfig.bodyCacheRecentPerFolder
        let accounts = [fixture.accountId, Self.secondAccountId]
        return try fixture.pool.write { db -> Seeded in
            var rng = DBProof.SeededGenerator(seed: UInt64(seed))
            try db.execute(sql: "DELETE FROM messageBody")
            try db.execute(sql: "DELETE FROM messageHeader")
            var seeded = Seeded()
            var uid = 0
            var cached: [String] = []
            let sharedTimes = (0..<2).map { _ in
                Self.hoursAgo(SyncConfig.bodyCacheTTLHours + Int.random(in: 1...2_000, using: &rng))
            }
            func nextDate(after previous: Date?) -> Date {
                if let previous, Int.random(in: 0..<4, using: &rng) == 0 { return previous }
                return Date().addingTimeInterval(-Double(uid) * 600 - Double(Int.random(in: 0..<500, using: &rng)))
            }
            func cacheTime() -> Date {
                Bool.random(using: &rng)
                    ? sharedTimes[Int.random(in: 0..<sharedTimes.count, using: &rng)]
                    : Self.hoursAgo(Self.randomAge(using: &rng))
            }
            for accountId in accounts {
                for folderPath in Self.liveFolders {
                    let count = Int.random(in: (recent / 2)...(recent * 3), using: &rng)
                    var previous: Date?
                    for _ in 0..<count {
                        uid += 1
                        let date = nextDate(after: previous)
                        previous = date
                        let id = try Self.insertHeader(db, accountId: accountId, folderPath: folderPath, uid: uid, date: date)
                        guard Int.random(in: 0..<10, using: &rng) < 8 else { continue }
                        try Self.insertBody(db, id: id, fetchedAt: cacheTime())
                        cached.append(id)
                        if Int.random(in: 0..<40, using: &rng) == 0 { seeded.undo.insert(id) }
                    }
                }
                // Optimistic moves from the inbox to the archive: the row keeps its
                // inbox id until the canonicalize pass carries it.
                for _ in 0..<Int.random(in: 0...4, using: &rng) {
                    uid += 1
                    let id = try Self.insertHeader(
                        db, accountId: accountId, folderPath: "INBOX", uid: uid, date: nextDate(after: nil))
                    try Self.insertBody(db, id: id, fetchedAt: cacheTime())
                    try db.execute(
                        sql: "UPDATE messageHeader SET folderId = ?, folderPath = 'Archive', isInInbox = 0 WHERE id = ?",
                        arguments: [MessageIdentity.folderId(accountId: accountId, folderPath: "Archive"), id])
                    let carry = try SyncEngine.canonicalizeLocalRows(
                        accountId: accountId, folderPath: "Archive",
                        folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "Archive"),
                        messageId: String(uid), isInInbox: false, windowMode: .date,
                        sourceBoundEpoch: nil, incomingRfc822Identity: nil, db: db)
                    if carry.ftsRekey != nil { seeded.carried += 1 }
                }
                let folders = Self.liveFolders + [Self.heldFolder, Self.ghostFolder]
                for index in 0..<Int.random(in: 0...8, using: &rng) {
                    let folderPath = folders[Int.random(in: 0..<folders.count, using: &rng)]
                    let id = MessageIdentity.headerId(
                        accountId: accountId, folderPath: folderPath, messageId: String(900_000 + index))
                    try Self.insertBody(db, id: id, fetchedAt: Self.hoursAgo(Self.randomAge(using: &rng)))
                    if Int.random(in: 0..<8, using: &rng) == 0 { seeded.undo.insert(id) }
                }
            }
            for id in cached {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0:
                    try db.execute(sql: "UPDATE messageHeader SET isInInbox = 1 - isInInbox WHERE id = ?", arguments: [id])
                    seeded.inboxMoves += 1
                case 1:
                    try Self.insertBody(db, id: id, fetchedAt: Self.hoursAgo(Self.randomAge(using: &rng)), replacing: true)
                    seeded.refetches += 1
                default:
                    break
                }
            }
            return seeded
        }
    }

    /// The most evict candidates sharing one cache time, and how many folders have a
    /// date tie across their newest-N boundary.
    static func ties(_ fixture: Hold.Fixture) throws -> (sharedCacheTime: Int, boundaryDateTies: Int) {
        let recent = SyncConfig.bodyCacheRecentPerFolder
        return try fixture.pool.read { db in
            let shared = try Int.fetchOne(db, sql: """
                SELECT MAX(n) FROM (
                    SELECT COUNT(*) AS n FROM messageHeader
                    WHERE isInInbox = 0 AND htmlCachedAt IS NOT NULL GROUP BY htmlCachedAt)
                """) ?? 0
            var boundaryTies = 0
            for folderId in try String.fetchAll(db, sql: "SELECT DISTINCT folderId FROM messageHeader") {
                let dates = try DatabaseValue.fetchAll(
                    db, sql: "SELECT date FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT 2 OFFSET ?",
                    arguments: [folderId, recent - 1])
                if dates.count == 2, dates[0] == dates[1] { boundaryTies += 1 }
            }
            return (shared, boundaryTies)
        }
    }

    /// 40 seeded databases (`seedRandom`): two accounts, three live folders each, a
    /// quarantined folder and a missing one; headers with and without bodies, bodies
    /// with and without headers, stale and fresh; inbox moves, re-fetches and carries
    /// after caching; and an undo set. Each seed checks the property; across the seeds
    /// both runs must have evicted something, the old run must have taken headerless
    /// bodies, and every shape must have occurred, or the comparison pins nothing.
    @Test("40 seeded databases: the new run evicts what the old did, minus the headerless bodies")
    func seededDatabases() async throws {
        let fixture = try Self.makeFixture()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.directory) }
        var evicted = 0
        var orphansTakenByOld = 0
        var shapes = Seeded()
        var widestSharedTime = 0
        var boundaryDateTies = 0
        for seed in 1...40 {
            let seeded = try Self.seedRandom(fixture, seed: seed)
            let ties = try Self.ties(fixture)
            let outcome = try await Self.compare(fixture, undoProtected: seeded.undo)
            Self.expectTheProperty(outcome, "seed \(seed)")
            evicted += outcome.new.count
            orphansTakenByOld += outcome.old.intersection(outcome.headerless).count
            shapes.inboxMoves += seeded.inboxMoves
            shapes.refetches += seeded.refetches
            shapes.carried += seeded.carried
            widestSharedTime = max(widestSharedTime, ties.sharedCacheTime)
            boundaryDateTies += ties.boundaryDateTies
        }
        #expect(evicted > 0, "setup: across the seeds the new run evicted something")
        #expect(orphansTakenByOld > 0, "setup: across the seeds the old run took headerless bodies")
        #expect(shapes.inboxMoves > 0 && shapes.refetches > 0 && shapes.carried > 0,
                "setup: inbox moves \(shapes.inboxMoves), re-fetches \(shapes.refetches), carries \(shapes.carried)")
        #expect(widestSharedTime > SyncConfig.pruneChunkSize,
                "setup: no cache time is shared by more candidates than a page holds: \(widestSharedTime)")
        #expect(boundaryDateTies > 0, "setup: no folder has a date tie across its newest-N boundary")
    }
}
