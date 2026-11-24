/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The simulator proof for the search self-check's candidate read (#1397): the read with
/// the deferred partial index `messageHeader_completeByDate` against the same read without
/// it (what a device runs before the maintenance pass builds it, and what every device ran
/// before); the two other reads on the same columns, which must read no more pages with
/// it; and what the index costs the sync pass's header writes: a batch of new
/// headers, a search-index batch marking headers complete, and a body flush marking
/// bodies complete. On the large proof database (about 100,000 headers), on one five
/// times its size, and on a small one (`Shape.small`, about 2,100 headers). Writes
/// `report.txt` per database, `ratios.txt` (old over new for time, pages read and rows
/// visited; pages written for the writes) and `index-size.txt` under
/// `<TABMAIL_DB_PROOF_DIR>/ios-scan-fts-selfheal-candidates/`. Runs only when the test
/// runner sets `TABMAIL_DB_PROOF_DIR`.
@Suite("FTS self-heal candidate read: the covering index's read and write cost on the proof databases",
       .serialized, .enabled(if: DBProof.outputDirectory != nil))
struct FTSSelfHealCandidateProofTests {

    enum ProofSetupError: Error { case noInbox }

    static let unit = "ios-scan-fts-selfheal-candidates"
    static let indexName = "messageHeader_completeByDate"
    static let dropIndex = "DROP INDEX IF EXISTS \(indexName)"
    /// One IMAP header fetch batch at the largest sync setting (`SyncConfig.imapFetchBatchSize`, `.turbo`).
    static let newHeaders = 500
    /// One search-index batch (`SyncConfig.ftsIndexBatchSize`).
    static let headersMarkedComplete = SyncConfig.ftsIndexBatchSize
    /// One body write flush (`SyncConfig.ftsWriteBatchSize`).
    static let bodiesMarkedComplete = SyncConfig.ftsWriteBatchSize

    /// The large shape at `factor` times its size, same proportions.
    static func scaled(_ factor: Int) -> DBProof.Shape {
        DBProof.Shape(
            accounts: DBProof.Shape.large.accounts.map {
                DBProof.AccountShape(provider: $0.provider, headers: $0.headers * factor, inboxShare: $0.inboxShare)
            },
            labels: DBProof.Shape.defaultLabels,
            otherFolders: DBProof.Shape.defaultOtherFolders)
    }

    // MARK: - Modes

    /// A read measured without and with the index, and the statement whose plan the report shows,
    /// with the arguments its placeholders take.
    struct ReadCase: Sendable {
        let mode: DBProof.Mode
        let statement: @Sendable (Database) throws -> (sql: String, arguments: StatementArguments)
        /// The read this unit changes must read fewer pages on a large mailbox once the
        /// app's statistics are taken (with none, the planner keeps the plan it had without
        /// the index); every other read, and this one with no statistics, must never read more.
        let mustImprove: Bool
    }

    /// A read with the same statement on both sides. The base has every deferred index
    /// (`DBProof.prepareBase` builds them), so the old side drops this one.
    static func readCase(_ name: String, sql: String, mustImprove: Bool) -> ReadCase {
        ReadCase(
            mode: DBProof.Mode(name: name, kind: .read,
                               old: DBProof.Variant(setupSQL: [dropIndex], sql: [sql]),
                               new: DBProof.Variant(sql: [sql])),
            statement: { _ in (sql, StatementArguments()) },
            mustImprove: mustImprove)
    }

    /// `SyncEngine.recoverIncompleteHeaders`' read, as it builds it.
    static func incompleteHeadersRequest() -> QueryInterfaceRequest<MessageHeader> {
        MessageHeader.filter(Column("headerComplete") == false).limit(500)
    }

    static var readCases: [ReadCase] {
        let recovery: @Sendable (Database) throws -> Int = { db in
            try Self.incompleteHeadersRequest().fetchAll(db).count
        }
        return [
            readCase("candidate read", sql: SyncEngine.ftsBodyMembershipCandidateSQL, mustImprove: true),
            // The two other reads that filter on the same columns: the start-up recovery read
            // (`headerComplete = 0`, which a partial index on complete headers cannot serve)
            // and the one-time sweep page (whose WHERE implies the index's own).
            ReadCase(
                mode: DBProof.Mode(name: "census: incomplete-header recovery read", kind: .read,
                                   old: DBProof.Variant(setupSQL: [dropIndex], run: recovery),
                                   new: DBProof.Variant(run: recovery)),
                statement: { db in
                    let statement = try Self.incompleteHeadersRequest()
                        .makePreparedRequest(db, forSingleResult: false).statement
                    return (statement.sql, statement.arguments)
                },
                mustImprove: false),
            readCase("census: full-history sweep page",
                     sql: """
                         SELECT rowid, id FROM messageHeader
                         WHERE rowid > 0 AND bodyComplete = 1 AND headerComplete = 1
                         ORDER BY rowid LIMIT \(SyncConfig.ftsOrphanPruneChunk)
                         """,
                     mustImprove: false),
        ]
    }

    /// The plan of `statement` in a variant file `compare` left.
    static func plan(_ statement: @Sendable (Database) throws -> (sql: String, arguments: StatementArguments),
                     in file: URL) throws -> String {
        let queue = try DatabaseQueue(path: file.path)
        defer { try? queue.close() }
        return try queue.read { db in
            let (sql, arguments) = try statement(db)
            return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String? ?? "?" }
                .joined(separator: " | ")
        }
    }

    /// A batch of new headers in the first inbox, newest of all, as the pass inserts them.
    static let insertHeaders: @Sendable (Database) throws -> Int = { db in
        guard let inbox = try Folder.filter(Column("role") == FolderRole.inbox.rawValue)
            .order(Column("id")).fetchOne(db) else { throw ProofSetupError.noInbox }
        let now = Date()
        for i in 0..<newHeaders {
            let uid = String(9_000_000 + i)
            let header = MessageHeader(
                messageId: uid, subject: "New \(uid)", from: "Sender <sender@example.com>",
                fromAddress: "sender@example.com", to: "proof@example.com",
                date: now.addingTimeInterval(-Double(i)), snippet: "Snippet \(uid)",
                folderId: inbox.id, accountId: inbox.accountId, folderPath: inbox.path, isInInbox: true)
            try header.insert(db)
        }
        return newHeaders
    }

    /// `targets` holds the ids to update, chosen once in the variant's setup (the same rows on both
    /// sides), so the timed run is the updates alone, one statement per header as the pass runs them.
    static func update(_ sql: String, targets: String, arguments: @escaping @Sendable (String) -> StatementArguments)
        -> @Sendable (Database) throws -> Int {
        { db in
            var changed = 0
            for id in try String.fetchAll(db, sql: "SELECT id FROM \(targets) ORDER BY id") {
                try db.execute(sql: sql, arguments: arguments(id))
                changed += db.changesCount
            }
            return changed
        }
    }

    static func writeMode(_ name: String, setup: [String], run: @escaping @Sendable (Database) throws -> Int) -> DBProof.Mode {
        DBProof.Mode(name: name, kind: .write,
                     old: DBProof.Variant(setupSQL: [dropIndex] + setup, run: run),
                     new: DBProof.Variant(setupSQL: setup, run: run))
    }

    static var writeModes: [DBProof.Mode] {
        [
            writeMode("insert \(newHeaders) new headers", setup: [], run: insertHeaders),
            writeMode(
                "mark \(headersMarkedComplete) headers complete (search-index batch)",
                setup: ["""
                    CREATE TABLE proofHeaderTargets AS SELECT id FROM messageHeader
                    WHERE headerComplete = 0 ORDER BY rowid LIMIT \(headersMarkedComplete)
                    """],
                run: update("UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                            targets: "proofHeaderTargets", arguments: { [$0] })),
            writeMode(
                "mark \(bodiesMarkedComplete) bodies complete (body write flush)",
                setup: ["""
                    CREATE TABLE proofBodyTargets AS SELECT id FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 ORDER BY rowid LIMIT \(bodiesMarkedComplete)
                    """],
                run: update("""
                    UPDATE messageHeader
                    SET snippet = ?, bodyComplete = 1, missFetchCount = 0, bodyMetadataOversized = 0
                    WHERE id = ?
                    """, targets: "proofBodyTargets", arguments: { ["Fetched snippet", $0] })),
        ]
    }

    // MARK: - The index's size

    /// The bytes the index takes in `base`: pages in use before and after dropping it, on a copy.
    static func indexSize(of base: URL) throws -> (bytes: Int, headers: Int) {
        let copy = base.deletingLastPathComponent().appendingPathComponent("size-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: base, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let queue = try DatabaseQueue(path: copy.path)
        defer { try? queue.close() }
        return try queue.writeWithoutTransaction { db in
            func pagesInUse() throws -> Int {
                (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0) - (try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
            }
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let headers = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader") ?? 0
            let before = try pagesInUse()
            try db.execute(sql: dropIndex)
            return ((before - (try pagesInUse())) * pageSize, headers)
        }
    }

    // MARK: - The proof

    @Test("Old against new: the read's time, pages and rows visited; the writes' time and pages written; the index's size")
    func proof() throws {
        guard let output = DBProof.outputDirectory else { return }
        let root = output.appendingPathComponent(Self.unit, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let databases: [(name: String, shape: DBProof.Shape, large: Bool)] = [
            ("large", .large, true),
            ("large-x5", Self.scaled(5), true),
            ("small", .small, false),
        ]
        var ratioLines = ["Old (no index) over new (index) for the read; old over new for the writes",
                          "(below 1: the write costs more with the index). Rows visited = VM steps.", ""]
        var sizeLines: [String] = []
        for database in databases {
            let directory = root.appendingPathComponent("db-\(database.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = try DBProof.prepareBase(in: directory, shape: database.shape)

            let size = try Self.indexSize(of: base)
            #expect(size.bytes > 0, "precondition: the base holds \(Self.indexName)")
            sizeLines.append("\(database.name): \(size.headers) headers, \(Self.indexName) \(size.bytes) bytes, "
                             + "\(size.bytes * 100_000 / max(size.headers, 1)) bytes per 100,000 headers")

            let unit = "\(Self.unit)/\(database.name)"
            let readCases = Self.readCases
            let results = try DBProof.compare(unit: unit, modes: readCases.map(\.mode) + Self.writeModes,
                                              base: base, in: output)
            for result in results {
                let old = result.old, new = result.new
                ratioLines.append("== \(database.name): \(result.mode.name), \(result.statistics.label)")
                ratioLines.append(Self.ratioLine("median ms", old.wallMs.median, new.wallMs.median))
                if let readCase = readCases.first(where: { $0.mode.name == result.mode.name }) {
                    let files = DBProof.variantFiles(unit: unit, mode: result.mode.name,
                                                     statistics: result.statistics, in: output)
                    let oldPlan = try Self.plan(readCase.statement, in: files.old)
                    let newPlan = try Self.plan(readCase.statement, in: files.new)
                    ratioLines.append("  plan old: \(oldPlan)")
                    ratioLines.append("  plan new: \(newPlan)")
                    let oldPages = old.count(\.pagesRead).median, newPages = new.count(\.pagesRead).median
                    ratioLines.append(Self.ratioLine("pages read", Double(oldPages), Double(newPages)))
                    ratioLines.append(Self.ratioLine("rows visited", Double(old.count(\.vmSteps).median),
                                                     Double(new.count(\.vmSteps).median)))
                    ratioLines.append(Self.ratioLine("sorts", Double(old.count(\.sorts).median),
                                                     Double(new.count(\.sorts).median)))
                    let context = "\(database.name), \(result.mode.name), \(result.statistics.label): "
                        + "pages old \(oldPages), new \(newPages)"
                    if readCase.mustImprove && database.large && result.statistics == .analyzed {
                        #expect(newPages < oldPages, "fewer pages on a large mailbox: \(context)")
                    } else {
                        #expect(newPages <= oldPages, "never more pages: \(context)")
                    }
                } else {
                    ratioLines.append(Self.ratioLine("pages written", Double(old.count(\.pagesWritten).median),
                                                     Double(new.count(\.pagesWritten).median)))
                }
                ratioLines.append("  time verdict: \(result.timeVerdict.rawValue)")
                ratioLines.append("")
            }
        }
        try ratioLines.joined(separator: "\n").write(
            to: root.appendingPathComponent("ratios.txt"), atomically: true, encoding: .utf8)
        try (sizeLines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("index-size.txt"), atomically: true, encoding: .utf8)
    }

    private static func ratioLine(_ label: String, _ old: Double, _ new: Double) -> String {
        let ratio = new > 0 ? String(format: "%.2f", old / new) : "n/a"
        let format = { (value: Double) in value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value) }
        return "  \(label): old \(format(old)), new \(format(new)), old/new \(ratio)"
    }
}
