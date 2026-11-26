/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The proof harness (`DBProof`) is what later changes rely on to show a new statement
/// is no slower and reads no more than the old one, so its own numbers have to be
/// right: the database must have the shape it claims, the counters must tell a scan
/// from a seek, a write must be measured on a copy, and the report and manifest must
/// carry every result. These run on `DBProof.Shape.small`; the large build runs only
/// when the test runner sets `TABMAIL_DB_PROOF_DIR`.
@Suite("Database proof harness")
struct DBProofHarnessTests {

    // MARK: - Helpers

    private static func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dbproof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeBase(in directory: URL, anchor: Date = Date()) throws -> URL {
        let url = directory.appendingPathComponent("base.sqlite")
        try DBProof.build(at: url, shape: .small, anchor: anchor)
        return url
    }

    private static func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read(body)
    }

    private static let scanSQL = "SELECT id FROM messageHeader WHERE snippet LIKE '%Snippet 7%'"

    private static var seekID: String {
        MessageIdentity.headerId(accountId: DBProof.accountId(0), folderPath: "INBOX", messageId: "1")
    }

    private static var seekSQL: String { "SELECT id FROM messageHeader WHERE id = '\(seekID)'" }

    /// A write of exactly one row.
    private static var seekWriteSQL: String { "UPDATE messageHeader SET isRead = 1 - isRead WHERE id = '\(seekID)'" }

    private static let missingSQL = "SELECT id FROM messageHeader WHERE id = 'no such message'"
    private static let missingWriteSQL = "UPDATE messageHeader SET isRead = 1 WHERE id = 'no such message'"

    /// Most headers complete and a share incomplete, bodies only on complete headers and most of
    /// them in, and in every account's inbox complete rows with their body: what a read of
    /// complete headers (the inbox list, the label walk) needs to return rows.
    private static func expectCompletionMix(_ db: Database, shape: DBProof.Shape) throws {
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM messageHeader") ?? 0
        let complete = try Int.fetchOne(db, sql: "SELECT count(*) FROM messageHeader WHERE headerComplete = 1") ?? 0
        let bodies = try Int.fetchOne(db, sql: "SELECT count(*) FROM messageHeader WHERE bodyComplete = 1") ?? 0
        let bodyWithoutHeader = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM messageHeader WHERE bodyComplete = 1 AND headerComplete = 0
            """) ?? -1
        let incompleteInbox = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM messageHeader WHERE isInInbox = 1 AND headerComplete = 0
            """) ?? 0
        let headerShare = Double(complete) / Double(max(total, 1))
        let bodyShare = Double(bodies) / Double(max(complete, 1))
        #expect(total == shape.totalHeaders, "precondition: the whole build")
        #expect(abs(headerShare - DBProof.Config.headerCompleteShare) < 0.03, "complete headers: \(complete) of \(total)")
        #expect(abs(bodyShare - DBProof.Config.bodyCompleteShare) < 0.05, "bodies: \(bodies) of \(complete) complete headers")
        #expect(bodyWithoutHeader == 0, "a body only on a complete header")
        #expect(incompleteInbox > 0, "the inbox has incomplete rows too")
        for index in shape.accounts.indices {
            let readable = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messageHeader
                WHERE accountId = ? AND isInInbox = 1 AND headerComplete = 1 AND bodyComplete = 1
                """, arguments: [DBProof.accountId(index)]) ?? 0
            #expect(readable > 0, "account \(index): complete inbox rows with their body")
        }
    }

    /// One mode, no planner statistics, one timed run per side, in its own unit directory.
    private static func compareOne(_ mode: DBProof.Mode, base: URL, in directory: URL) throws -> [DBProof.Result] {
        try DBProof.compare(unit: "one-\(UUID().uuidString)", modes: [mode], base: base, in: directory,
                            statistics: [.none], repeats: 1)
    }

    private static func readMode(_ old: String, _ new: String, emptyResult: Bool = false) -> DBProof.Mode {
        DBProof.Mode(name: "read", kind: .read, old: DBProof.Variant(sql: [old]), new: DBProof.Variant(sql: [new]),
                     emptyResult: emptyResult)
    }

    // MARK: - Building

    @Test("The same shape, seed and anchor build the same database; another seed does not")
    func buildIsDeterministic() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchor = Date()
        let first = directory.appendingPathComponent("first.sqlite")
        let second = directory.appendingPathComponent("second.sqlite")
        let otherSeed = directory.appendingPathComponent("other.sqlite")
        try DBProof.build(at: first, shape: .small, anchor: anchor)
        try DBProof.build(at: second, shape: .small, anchor: anchor)
        try DBProof.build(at: otherSeed, shape: .small, seed: DBProof.Config.seed &+ 1, anchor: anchor)

        let firstPrint = try DBProof.fingerprint(of: first)
        let secondPrint = try DBProof.fingerprint(of: second)
        let otherPrint = try DBProof.fingerprint(of: otherSeed)
        #expect(firstPrint.split(separator: "\n").count > DBProof.Shape.small.accounts.count,
                "precondition: the fingerprint lists real groups")
        #expect(firstPrint == secondPrint)
        #expect(firstPrint != otherPrint)
    }

    @Test("A build has the shape's accounts, inbox shares, tags, read states, labels and deferred indexes")
    func buildHasTheRequestedShape() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchor = Date()
        let base = try Self.makeBase(in: directory, anchor: anchor)
        let shape = DBProof.Shape.small

        try Self.read(base) { (db: Database) -> Void in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM messageHeader") ?? 0
            #expect(total == shape.totalHeaders)

            let perFolder = try Row.fetchAll(db, sql: """
                SELECT accountId, folderPath, count(*) AS n FROM messageHeader GROUP BY accountId, folderPath
                """)
            var counts: [String: [String: Int]] = [:]
            for row in perFolder {
                let account: String = row["accountId"]
                let folder: String = row["folderPath"]
                counts[account, default: [:]][folder] = row["n"]
            }
            for (index, account) in shape.accounts.enumerated() {
                let folders = counts[DBProof.accountId(index)] ?? [:]
                let expectedInbox = Int((Double(account.headers) * account.inboxShare).rounded())
                let accountTotal = folders.values.reduce(0, +)
                #expect(folders["INBOX"] == expectedInbox, "account \(index) inbox")
                #expect(accountTotal == account.headers, "account \(index) total")
                #expect(Set(folders.keys) == ["INBOX", "Archive", "Sent", "Trash"], "account \(index) folders")
            }

            // isInInbox is exactly the inbox folders' rows.
            let strayInbox = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messageHeader
                WHERE (isInInbox = 1 AND folderPath != 'INBOX') OR (isInInbox = 0 AND folderPath = 'INBOX')
                """) ?? -1
            #expect(strayInbox == 0)

            // Every triage bucket, and untagged mail, in the inbox; sort order matches the tag.
            let inboxTags = try Set(String.fetchAll(db, sql: """
                SELECT DISTINCT COALESCE(actionTag, '-') FROM messageHeader WHERE isInInbox = 1
                """))
            let everyBucket = Set(ActionTag.allCases.map(\.rawValue) + ["-"])
            #expect(inboxTags == everyBucket)
            let wrongSortOrder = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messageHeader
                WHERE tagSortOrder != CASE actionTag WHEN 'reply' THEN 0 WHEN 'none' THEN 1
                                                     WHEN 'archive' THEN 2 WHEN 'delete' THEN 3 ELSE 99 END
                """) ?? -1
            #expect(wrongSortOrder == 0)

            let inboxReadStates = try Set(Int.fetchAll(db, sql: "SELECT DISTINCT isRead FROM messageHeader WHERE isInInbox = 1"))
            #expect(inboxReadStates == [0, 1])

            // Labels: every one has members, dense outnumbers sparse, members only in the inbox and archive.
            let labels: [(account: String, label: String, members: Int)] = try Row.fetchAll(db, sql: """
                SELECT u.accountId, u.providerLabelId, count(m.messageId) AS members
                FROM userLabel u LEFT JOIN messageUserLabel m ON m.userLabelId = u.id
                GROUP BY u.id
                """).map { ($0["accountId"], $0["providerLabelId"], $0["members"]) }
            let emptyLabels = labels.filter { $0.members == 0 }
            #expect(emptyLabels.isEmpty)
            for (index, account) in shape.accounts.enumerated() {
                let own = labels.filter { $0.account == DBProof.accountId(index) }
                let expected = shape.labels.filter { !$0.isSystem || account.provider == .gmail }.count
                #expect(own.count == expected, "account \(index) labels")
            }
            func members(_ label: String) -> Int {
                labels.first { $0.account == DBProof.accountId(0) && $0.label == label }?.members ?? 0
            }
            let dense = members("proof_dense")
            let sparse = members("proof_sparse")
            #expect(dense > sparse * 10, "dense \(dense), sparse \(sparse)")
            let misplaced = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messageUserLabel m JOIN messageHeader h ON h.id = m.messageId
                WHERE h.folderPath NOT IN ('INBOX', 'Archive')
                """) ?? -1
            #expect(misplaced == 0)

            for index in SyncEngine.deferredIndexes {
                let exists = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = ?",
                                              arguments: [index.name]) ?? 0
                #expect(exists == 1, "deferred index \(index.name)")
            }

            let oldest = try Date.fetchOne(db, sql: "SELECT min(date) FROM messageHeader")
            let newest = try Date.fetchOne(db, sql: "SELECT max(date) FROM messageHeader")
            let floor = anchor.addingTimeInterval(-DBProof.Config.archiveMaxDays * DBProof.Config.secondsPerDay - 1)
            #expect((oldest ?? .distantPast) >= floor)
            #expect((newest ?? .distantFuture) <= anchor.addingTimeInterval(1))

            try Self.expectCompletionMix(db, shape: shape)
        }
    }

    // MARK: - Statistics and setup

    @Test("Each statistics state leaves the planner statistics it names, in WAL mode")
    func statisticsStates() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try Self.makeBase(in: directory)
        let none = directory.appendingPathComponent("none.sqlite")
        let analyzed = directory.appendingPathComponent("analyzed.sqlite")
        try DBProof.prepareVariantFile(base: base, setupSQL: [], statistics: .none, at: none)
        try DBProof.prepareVariantFile(base: base, setupSQL: [], statistics: .analyzed, at: analyzed)

        let noneStats = try Self.read(none) { db in
            try db.tableExists("sqlite_stat1") ? (try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_stat1") ?? -1) : 0
        }
        let analyzedStats = try Self.read(analyzed) { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_stat1 WHERE tbl = 'messageHeader' AND idx IS NOT NULL") ?? 0
        }
        let modes = try [none, analyzed].map { url in
            try Self.read(url) { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        }
        #expect(noneStats == 0)
        #expect(analyzedStats > 0)
        #expect(modes == ["wal", "wal"])
    }

    @Test("A variant's setup reaches only that variant's file, and runs before its statistics")
    func setupReachesOnlyItsVariant() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try Self.makeBase(in: directory)
        let old = directory.appendingPathComponent("old.sqlite")
        let new = directory.appendingPathComponent("new.sqlite")
        let setup = ["CREATE INDEX proof_snippet ON messageHeader(snippet)"]
        try DBProof.prepareVariantFile(base: base, setupSQL: [], statistics: .analyzed, at: old)
        try DBProof.prepareVariantFile(base: base, setupSQL: setup, statistics: .analyzed, at: new)

        let indexSQL = "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'proof_snippet'"
        let statSQL = "SELECT count(*) FROM sqlite_stat1 WHERE idx = 'proof_snippet'"
        let oldIndex = try Self.read(old) { try Int.fetchOne($0, sql: indexSQL) ?? -1 }
        let newIndex = try Self.read(new) { try Int.fetchOne($0, sql: indexSQL) ?? -1 }
        let newStat = try Self.read(new) { try Int.fetchOne($0, sql: statSQL) ?? -1 }
        let baseIndex = try Self.read(base) { try Int.fetchOne($0, sql: indexSQL) ?? -1 }
        #expect(oldIndex == 0)
        #expect(baseIndex == 0)
        #expect(newIndex == 1)
        #expect(newStat == 1, "ANALYZE ran after the setup, so the new index has statistics")
    }

    // MARK: - Measuring

    @Test("A full scan reads more pages and visits every row; a primary-key seek does neither; a sort counts")
    func measurerTellsAScanFromASeek() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try Self.makeBase(in: directory)
        let file = directory.appendingPathComponent("read.sqlite")
        try DBProof.prepareVariantFile(base: base, setupSQL: [], statistics: .none, at: file)

        let scan = try DBProof.measure(DBProof.Variant(sql: [Self.scanSQL]), kind: .read, file: file)
        let scanAgain = try DBProof.measure(DBProof.Variant(sql: [Self.scanSQL]), kind: .read, file: file)
        let seek = try DBProof.measure(DBProof.Variant(sql: [Self.seekSQL]), kind: .read, file: file)
        let sorted = try DBProof.measure(
            DBProof.Variant(sql: ["SELECT id FROM messageHeader ORDER BY snippet"]), kind: .read, file: file)
        let rows = DBProof.Shape.small.totalHeaders

        #expect(scan.fullscanSteps >= rows - 1, "\(scan.fullscanSteps) full-scan steps over \(rows) rows")
        #expect(seek.fullscanSteps == 0)
        #expect(seek.pagesRead > 0, "the page counter really counts")
        #expect(scan.pagesRead > seek.pagesRead * 10, "scan \(scan.pagesRead) pages, seek \(seek.pagesRead)")
        #expect(scan.vmSteps > seek.vmSteps)
        #expect(scan.sorts == 0)
        #expect(sorted.sorts >= 1)
        #expect(scanAgain.pagesRead == scan.pagesRead, "a fresh connection per run: the second run is as cold")
        #expect(scan.pagesWritten == 0)
        #expect(seek.resultRows == 1)
        #expect(scan.resultRows > 0)
        #expect(sorted.resultRows == rows)
    }

    @Test("A write mode counts the pages its commit writes and never changes the variant file")
    func writeModeCountsPagesAndLeavesTheFile() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try Self.makeBase(in: directory)
        let file = directory.appendingPathComponent("write.sqlite")
        try DBProof.prepareVariantFile(base: base, setupSQL: [], statistics: .none, at: file)
        let before = try DBProof.fingerprint(of: file)

        let wide = try DBProof.measure(
            DBProof.Variant(sql: ["UPDATE messageHeader SET isRead = 1 - isRead WHERE isInInbox = 1"]),
            kind: .write, file: file)
        let none = try DBProof.measure(DBProof.Variant(sql: [Self.missingWriteSQL]), kind: .write, file: file)
        let inboxRows = try Self.read(file) {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM messageHeader WHERE isInInbox = 1") ?? 0
        }

        let after = try DBProof.fingerprint(of: file)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("run-") }
        #expect(wide.pagesWritten > 0)
        #expect(none.pagesWritten < wide.pagesWritten)
        #expect(wide.resultRows == inboxRows, "a write counts the rows it changed")
        #expect(none.resultRows == 0)
        #expect(after == before, "every write ran on its own clone")
        #expect(leftovers.isEmpty)
    }

    @Test("The time verdict uses the spread of the old runs as its noise band")
    func timeVerdictUsesTheOldSpread() {
        // Sorted old runs 10, 10, 11, 11, 12: median 11, p10 10, p90 12, spread 2, band 9...13.
        let old = DBProof.Distribution([11, 10, 12, 10, 11])
        #expect(old.median == 11)
        #expect(old.spread == 2)
        #expect(DBProof.timeVerdict(old: old, new: DBProof.Distribution([13.5])) == .slower)
        #expect(DBProof.timeVerdict(old: old, new: DBProof.Distribution([12.9])) == .withinNoise)
        #expect(DBProof.timeVerdict(old: old, new: DBProof.Distribution([9.1])) == .withinNoise)
        #expect(DBProof.timeVerdict(old: old, new: DBProof.Distribution([8.9])) == .faster)
    }

    // MARK: - Report and manifest

    @Test("compare writes one report block per mode and statistics state, and a manifest of the files and SQL")
    func compareWritesTheReportAndManifest() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try Self.makeBase(in: directory)
        let wideWrite = "UPDATE messageHeader SET isRead = 1 - isRead WHERE isInInbox = 1"
        let narrowWrite = Self.seekWriteSQL
        let modes = [
            DBProof.Mode(name: "scan vs seek", kind: .read,
                         old: DBProof.Variant(sql: [Self.scanSQL]), new: DBProof.Variant(sql: [Self.seekSQL])),
            DBProof.Mode(name: "wide vs narrow write", kind: .write,
                         old: DBProof.Variant(sql: [wideWrite]), new: DBProof.Variant(sql: [narrowWrite])),
        ]
        let repeats = 3
        let results = try DBProof.compare(unit: "harness-self-test", modes: modes, base: base, in: directory, repeats: repeats)

        #expect(results.count == modes.count * DBProof.Statistics.allCases.count)
        for result in results {
            #expect(result.old.runs.count == repeats)
            #expect(result.new.runs.count == repeats)
        }
        let readNone = results.first { $0.mode.name == "scan vs seek" && $0.statistics == .none }
        let writeNone = results.first { $0.mode.name == "wide vs narrow write" && $0.statistics == .none }
        let seekFullscan = readNone?.new.count(\.fullscanSteps).median ?? -1
        let scanFullscan = readNone?.old.count(\.fullscanSteps).median ?? 0
        let wideWritten = writeNone?.old.count(\.pagesWritten).median ?? 0
        let narrowWritten = writeNone?.new.count(\.pagesWritten).median ?? 0
        #expect(seekFullscan == 0)
        #expect(scanFullscan > 0)
        #expect(wideWritten > narrowWritten)
        let seekRows = readNone?.new.count(\.resultRows).median ?? 0
        let narrowRows = writeNone?.new.count(\.resultRows).median ?? 0
        #expect(seekRows == 1)
        #expect(narrowRows == 1)

        let unitDirectory = directory.appendingPathComponent("harness-self-test")
        let report = try String(contentsOf: unitDirectory.appendingPathComponent("report.txt"), encoding: .utf8)
        for mode in modes {
            for state in DBProof.Statistics.allCases {
                #expect(report.contains("== \(mode.name) (\(mode.kind.rawValue)), \(state.label)"))
            }
        }
        for label in ["median ms", "p90 ms", "old spread ms", "result rows", "pages read", "pages written", "VM steps",
                      "full-scan steps", "sorts", "autoindex inserts", DBProof.accountId(0)] {
            #expect(report.contains(label), "report line \(label)")
        }

        let manifestData = try Data(contentsOf: unitDirectory.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        let entries = manifest?["entries"] as? [[String: Any]] ?? []
        #expect(manifest?["repeats"] as? Int == repeats)
        #expect(entries.count == results.count)
        for entry in entries {
            for side in ["old", "new"] {
                let variant = entry[side] as? [String: Any]
                let path = variant?["file"] as? String ?? ""
                let sql = variant?["sql"] as? [String] ?? []
                #expect(FileManager.default.fileExists(atPath: path), "\(side) file \(path)")
                #expect(sql.count == 1)
            }
        }
    }

    @Test("compare refuses a mode with an empty side unless it is declared empty, and a declared-empty mode with rows")
    func compareRefusesAnEmptyComparison() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try Self.makeBase(in: directory)

        // Either side empty: two empty results, or nothing against something, prove nothing.
        #expect(throws: DBProof.DBProofError.self) {
            try Self.compareOne(Self.readMode(Self.missingSQL, Self.seekSQL), base: base, in: directory)
        }
        #expect(throws: DBProof.DBProofError.self) {
            try Self.compareOne(Self.readMode(Self.seekSQL, Self.missingSQL), base: base, in: directory)
        }
        #expect(throws: DBProof.DBProofError.self) {
            try Self.compareOne(Self.readMode(Self.missingSQL, Self.missingSQL), base: base, in: directory)
        }
        // A Swift body reports its own result; a write counts the rows it changed.
        let emptyBody = DBProof.Variant(run: { db in
            try MessageHeader.filter(Column("id") == "no such message").fetchAll(db).count
        })
        let bodyMode = DBProof.Mode(name: "body", kind: .read, old: emptyBody, new: DBProof.Variant(sql: [Self.seekSQL]))
        #expect(throws: DBProof.DBProofError.self) {
            try Self.compareOne(bodyMode, base: base, in: directory)
        }
        let writeMode = DBProof.Mode(name: "write", kind: .write, old: DBProof.Variant(sql: [Self.missingWriteSQL]),
                                     new: DBProof.Variant(sql: [Self.seekWriteSQL]))
        #expect(throws: DBProof.DBProofError.self) {
            try Self.compareOne(writeMode, base: base, in: directory)
        }
        // Declared empty: both sides must be empty.
        #expect(throws: DBProof.DBProofError.self) {
            try Self.compareOne(Self.readMode(Self.seekSQL, Self.seekSQL, emptyResult: true), base: base, in: directory)
        }
        let declared = try Self.compareOne(Self.readMode(Self.missingSQL, Self.missingSQL, emptyResult: true),
                                           base: base, in: directory)
        #expect(declared.count == 1)

        // A read of complete inbox headers with their bodies returns a full page on the base as built.
        let pageSize = 50
        let completeInbox = """
            SELECT id FROM messageHeader WHERE isInInbox = 1 AND headerComplete = 1 AND bodyComplete = 1
            ORDER BY date DESC LIMIT \(pageSize)
            """
        let inbox = try Self.compareOne(Self.readMode(completeInbox, completeInbox), base: base, in: directory)
        let inboxRows = inbox.first?.old.count(\.resultRows).median ?? 0
        #expect(inboxRows == pageSize)
    }

    // MARK: - The large build (opt-in)

    /// Not a check of a change: builds the large proof database into the directory the
    /// test runner names, for a unit's proof and for `Scripts/db-proof-mac.py`.
    @Test("Builds the large proof database into TABMAIL_DB_PROOF_DIR",
          .enabled(if: DBProof.outputDirectory != nil))
    func buildsTheLargeDatabase() throws {
        guard let directory = DBProof.outputDirectory else { return }
        let base = try DBProof.prepareBase(in: directory)
        let total = try Self.read(base) { try Int.fetchOne($0, sql: "SELECT count(*) FROM messageHeader") ?? 0 }
        #expect(total == DBProof.Shape.large.totalHeaders)
        #expect(total >= 100_000)
        try Self.read(base) { try Self.expectCompletionMix($0, shape: .large) }
    }
}
