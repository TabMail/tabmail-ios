/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Pins `QueryPlanRules` on fixed statements and plan lines over the real main schema, one
/// passing and one failing case per rule, so a rule that stopped matching cannot pass every
/// statement silently.
extension DatabaseIndexTests {

    /// A statement, the plan lines SQLite gave it (`parent` 0 unless the case builds a
    /// tree), and what the rules must say: nil for a pass, else a phrase of the finding.
    struct RuleCase {
        let name: String
        let sql: String
        let plan: [QueryPlanRules.PlanRow]
        let finding: String?

        init(_ name: String, _ sql: String, _ lines: [String], fails finding: String? = nil) {
            self.name = name
            self.sql = sql
            self.plan = lines.enumerated().map { QueryPlanRules.PlanRow(id: $0.offset + 2, parent: 0, detail: $0.element) }
            self.finding = finding
        }

        init(_ name: String, _ sql: String, tree: [(id: Int, parent: Int, detail: String)], fails finding: String? = nil) {
            self.name = name
            self.sql = sql
            self.plan = tree.map { QueryPlanRules.PlanRow(id: $0.id, parent: $0.parent, detail: $0.detail) }
            self.finding = finding
        }
    }

    static func mainSchemaFacts() throws -> QueryPlanRules.SchemaFacts {
        let db = try TestDatabase.make()
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        return try db.read { try QueryPlanRules.SchemaFacts.load($0) }
    }

    static let folderDate = "SEARCH messageHeader USING INDEX messageHeader_folderId_date (folderId=?)"
    static let embeddingQueue = "SELECT id FROM messageHeader WHERE embeddingComplete = 0 AND bodyComplete = 1 AND bodyEmptyConfirmed = 0"
    static let embeddingScan = "SCAN messageHeader USING INDEX messageHeader_embeddingIncomplete"

    static let ruleCases: [RuleCase] = [
        // Points and two-sided ranges.
        RuleCase("a row by its key", "SELECT * FROM messageHeader WHERE id = ?",
                 ["SEARCH messageHeader USING INDEX sqlite_autoindex_messageHeader_1 (id=?)"]),
        RuleCase("one message in a folder", "SELECT * FROM messageHeader WHERE folderId = ? AND messageId = ?",
                 ["SEARCH messageHeader USING INDEX messageHeader_folderId_messageId (folderId=? AND messageId=?)"]),
        RuleCase("one UID through the expression index", "SELECT * FROM messageHeader WHERE folderId = ? AND CAST(messageId AS INTEGER) = ?",
                 ["SEARCH messageHeader USING INDEX messageHeader_folderId_uidInt (folderId=? AND <expr>=?)"]),
        RuleCase("a two-sided date range", "SELECT * FROM messageHeader WHERE date > ? AND date < ?",
                 ["SEARCH messageHeader USING INDEX messageHeader_date (date>? AND date<?)"]),
        RuleCase("a two-sided UID window", "SELECT id FROM messageHeader WHERE folderId = ? AND CAST(messageId AS INTEGER) > ? AND CAST(messageId AS INTEGER) <= ?",
                 ["SEARCH messageHeader USING INDEX messageHeader_folderId_uidInt (folderId=? AND <expr>>? AND <expr><=?)"]),
        RuleCase("a row by rowid", "DELETE FROM messageBody WHERE rowid = ?",
                 ["SEARCH messageBody USING INTEGER PRIMARY KEY (rowid=?)"]),

        // Set reads.
        RuleCase("a whole folder", "SELECT id FROM messageHeader WHERE folderId = ?",
                 ["SEARCH messageHeader USING COVERING INDEX messageHeader_folderId_messageId (folderId=?)"], fails: "a set read of messageHeader"),
        RuleCase("a folder page in index order", "SELECT id FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT 50",
                 [folderDate]),
        RuleCase("a folder page with an OFFSET", "SELECT id FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT 50 OFFSET ?",
                 [folderDate], fails: "no LIMIT"),
        RuleCase("a folder page in the LIMIT a, b form", "SELECT id FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT ?, 50",
                 [folderDate], fails: "no LIMIT"),
        RuleCase("a zero LIMIT", "SELECT id FROM messageHeader WHERE folderId = ? LIMIT 0", [folderDate], fails: "no LIMIT"),
        RuleCase("a folder page sorted on another column", "SELECT * FROM messageHeader WHERE folderId = ? ORDER BY subject LIMIT 50",
                 [folderDate, "USE TEMP B-TREE FOR ORDER BY"], fails: "sorted before its LIMIT"),
        RuleCase("a folder page filtered past the seek", "SELECT id FROM messageHeader WHERE folderId = ? AND subject = ? ORDER BY date DESC LIMIT 50",
                 [folderDate], fails: "filtered on subject"),
        RuleCase("an update of a whole folder", "UPDATE OR IGNORE messageHeader SET isRead = 1 WHERE folderId = ?",
                 [folderDate], fails: "no LIMIT"),
        RuleCase("a count of a folder", "SELECT COUNT(*) FROM messageHeader WHERE folderId = ?",
                 ["SEARCH messageHeader USING COVERING INDEX messageHeader_folderId_date (folderId=?)"]),
        RuleCase("a count per folder", "SELECT folderId, COUNT(*) AS n FROM messageHeader WHERE accountId = ? GROUP BY folderId",
                 ["SEARCH messageHeader USING COVERING INDEX messageHeader_accountId_messageId (accountId=?)"]),
        RuleCase("a count of the whole table", "SELECT COUNT(*) FROM messageHeader",
                 ["SCAN messageHeader USING COVERING INDEX messageHeader_date"], fails: "a scan of messageHeader"),
        RuleCase("the newest date of a folder", "SELECT MAX(date) FROM messageHeader WHERE folderId = ?",
                 ["SEARCH messageHeader USING COVERING INDEX messageHeader_folderId_date (folderId=?)"]),
        RuleCase("the newest date of a folder among some subjects", "SELECT MAX(date) FROM messageHeader WHERE folderId = ? AND subject = ?",
                 [folderDate], fails: "no LIMIT"),
        RuleCase("an EXISTS probe of a folder", "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE folderId = ?)",
                 tree: [(2, 0, "SCALAR SUBQUERY 1"),
                        (5, 2, "SEARCH messageHeader USING COVERING INDEX messageHeader_folderId_date (folderId=?)"),
                        (10, 0, "SCAN CONSTANT ROW")]),

        // Cursors.
        RuleCase("a fixed-size page past a rowid", "SELECT * FROM messageHeader WHERE rowid > ? ORDER BY rowid LIMIT 50",
                 ["SEARCH messageHeader USING INTEGER PRIMARY KEY (rowid>?)"]),
        RuleCase("everything past a rowid", "DELETE FROM messageBody WHERE rowid > ?",
                 ["SEARCH messageBody USING INTEGER PRIMARY KEY (rowid>?)"], fails: "a cursor of messageBody"),
        RuleCase("everything after a date", "SELECT id FROM messageHeader WHERE date > ?",
                 ["SEARCH messageHeader USING INDEX messageHeader_date (date>?)"], fails: "a cursor of messageHeader"),

        // Partial indexes.
        RuleCase("a capped read of a partial index", embeddingQueue + " ORDER BY isInInbox DESC, date DESC LIMIT 500", [embeddingScan]),
        RuleCase("a partial index read whole", embeddingQueue, [embeddingScan], fails: "no LIMIT"),
        RuleCase("a partial index sorted before its cap", embeddingQueue + " ORDER BY subject LIMIT 500",
                 [embeddingScan, "USE TEMP B-TREE FOR ORDER BY"], fails: "sorted before its LIMIT"),
        RuleCase("a partial index filtered past its condition", embeddingQueue + " AND subject = ? ORDER BY isInInbox DESC, date DESC LIMIT 500",
                 [embeddingScan], fails: "filtered on subject"),
        RuleCase("a full index read in order", "SELECT id FROM messageHeader ORDER BY date DESC LIMIT 500",
                 ["SCAN messageHeader USING INDEX messageHeader_date"], fails: "a scan of messageHeader"),
        RuleCase("a plain table scan", "SELECT id FROM messageBody LIMIT 1", ["SCAN messageBody"], fails: "a scan of messageBody"),

        // Scopes: joins, subqueries, sorts.
        RuleCase("a mail alias on the right of a JOIN", "SELECT * FROM folder JOIN messageHeader AS m ON m.folderId = folder.id WHERE folder.accountId = ?",
                 ["SEARCH folder USING INDEX folder_accountId_role (accountId=?)",
                  "SEARCH m USING INDEX messageHeader_folderId_date (folderId=?)"], fails: "a set read of messageHeader"),
        RuleCase("a mail alias in a comma join", "SELECT * FROM folder f, messageHeader m WHERE m.folderId = f.id AND f.accountId = ?",
                 ["SEARCH f USING INDEX folder_accountId_role (accountId=?)",
                  "SEARCH m USING INDEX messageHeader_folderId_date (folderId=?)"], fails: "no LIMIT"),
        RuleCase("a JOIN filtered past the seek in its ON", "SELECT * FROM folder JOIN messageHeader AS m ON m.folderId = folder.id AND m.subject = ? WHERE folder.accountId = ? LIMIT 5",
                 ["SEARCH folder USING INDEX folder_accountId_role (accountId=?)",
                  "SEARCH m USING INDEX messageHeader_folderId_date (folderId=?)"], fails: "filtered on subject"),
        RuleCase("a LIMIT in a sibling subquery", "SELECT * FROM messageHeader WHERE folderId = ? AND id IN (SELECT messageHeaderId FROM messageReference WHERE referencedRfc822Id = ? LIMIT 5)",
                 tree: [(2, 0, "SEARCH messageHeader USING INDEX messageHeader_folderId_date (folderId=?)"),
                        (5, 0, "LIST SUBQUERY 1"),
                        (8, 5, "SEARCH messageReference USING INDEX messageReference_referencedRfc822Id (referencedRfc822Id=?)")],
                 fails: "a set read of messageHeader"),
        RuleCase("an outer sort over a capped inner read", "SELECT * FROM (SELECT * FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT 50) ORDER BY subject",
                 tree: [(2, 0, "CO-ROUTINE (subquery-1)"),
                        (5, 2, "SEARCH messageHeader USING INDEX messageHeader_folderId_date (folderId=?)"),
                        (20, 0, "SCAN (subquery-1)"),
                        (40, 0, "USE TEMP B-TREE FOR ORDER BY")]),
        RuleCase("an OR arm sorted by its SELECT", "SELECT * FROM messageHeader WHERE folderId = ? OR id = ? ORDER BY subject LIMIT 5",
                 tree: [(4, 0, "MULTI-INDEX OR"),
                        (5, 4, "INDEX 1"),
                        (13, 5, "SEARCH messageHeader USING INDEX messageHeader_folderId_date (folderId=?)"),
                        (18, 4, "INDEX 2"),
                        (26, 18, "SEARCH messageHeader USING INDEX sqlite_autoindex_messageHeader_1 (id=?)"),
                        (40, 0, "USE TEMP B-TREE FOR ORDER BY")],
                 fails: "sorted before its LIMIT"),
        RuleCase("a CTE over a capped read", "WITH recent AS (SELECT id FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT 20) SELECT * FROM recent",
                 tree: [(2, 0, "CO-ROUTINE recent"),
                        (5, 2, "SEARCH messageHeader USING INDEX messageHeader_folderId_date (folderId=?)"),
                        (20, 0, "SCAN recent")]),

        // What the rules cannot read fails.
        RuleCase("an automatic index", "SELECT * FROM folder JOIN messageHeader AS m ON m.subject = folder.name",
                 ["SCAN folder", "SEARCH m USING AUTOMATIC COVERING INDEX (subject=?)"], fails: "an automatic index of messageHeader"),
        RuleCase("an unknown seek term", "SELECT * FROM messageHeader WHERE folderId IN (?, ?) LIMIT 5",
                 ["SEARCH messageHeader USING INDEX messageHeader_folderId_date (ANY(folderId))"], fails: "unsupported plan text"),
        RuleCase("an unknown plan line", "SELECT * FROM messageHeader WHERE id = ?",
                 ["FROBNICATE messageHeader"], fails: "unsupported plan text"),
        RuleCase("an old-style plan line", "SELECT * FROM messageHeader WHERE id = ?",
                 ["SCAN TABLE messageHeader"], fails: "unresolved plan name TABLE"),
        RuleCase("a plan name the statement does not give", "SELECT * FROM messageHeader WHERE id = ?",
                 ["SCAN q"], fails: "unresolved plan name q"),
        RuleCase("a mail table the statement text does not name", "SELECT 1",
                 [folderDate], fails: "no reference to it"),
    ]

    @Test("Each plan rule passes its point, range and stopped reads and fails the reads that do not stop")
    func planRulesJudgeEachCase() throws {
        let facts = try Self.mainSchemaFacts()
        for ruleCase in Self.ruleCases {
            let findings = QueryPlanRules.findings(plan: ruleCase.plan, sql: ruleCase.sql, schema: facts)
            if let finding = ruleCase.finding {
                #expect(findings.count == 1 && findings[0].contains(finding),
                        "\(ruleCase.name): expected one finding with \"\(finding)\", got \(findings)")
            } else {
                #expect(findings.isEmpty, "\(ruleCase.name): expected a pass, got \(findings)")
            }
        }
    }

    @Test("The statement reader maps aliases without taking a keyword for one")
    func statementAliasesAreExact() throws {
        let facts = try Self.mainSchemaFacts()
        let joined = QueryPlanRules.StatementText("SELECT * FROM folder JOIN messageHeader AS m ON m.folderId = folder.id", schema: facts)
        #expect(joined.aliases == ["m": "messageHeader"])
        #expect(joined.references.map(\.table) == ["folder", "messageHeader"])
        let listed = QueryPlanRules.StatementText("SELECT * FROM folder f, messageHeader m WHERE m.folderId = f.id", schema: facts)
        #expect(listed.aliases == ["f": "folder", "m": "messageHeader"])
        let upsert = QueryPlanRules.StatementText(
            "INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET htmlContent = excluded.htmlContent",
            schema: facts)
        #expect(upsert.references.map(\.table) == ["messageBody"], "\(upsert.references.map(\.table))")
        let quoted = QueryPlanRules.StatementText(#"SELECT * FROM "messageHeader" WHERE subject = 'FROM folder x'"#, schema: facts)
        #expect(quoted.references.map(\.table) == ["messageHeader"] && quoted.aliases.isEmpty)
    }

    @Test("A statement's scope reads its own LIMIT, sort-free select list and filter columns")
    func statementScopesAreExact() throws {
        let facts = try Self.mainSchemaFacts()
        let sql = "SELECT id FROM messageHeader WHERE folderId = ? AND id IN (SELECT messageHeaderId FROM messageReference LIMIT 5) LIMIT ? OFFSET ?"
        let text = QueryPlanRules.StatementText(sql, schema: facts)
        let outer = text.references.first { $0.table == "messageHeader" }
        let inner = text.references.first { $0.table == "messageReference" }
        #expect(outer != nil && inner != nil)
        guard let outer, let inner else { return }
        #expect(!text.scope(at: outer.position).isLimited, "the outer LIMIT has an OFFSET; the inner LIMIT is not its own")
        #expect(text.scope(at: inner.position).isLimited)
        let columns = facts.columns["messageHeader"] ?? []
        #expect(text.scope(at: outer.position).filterColumns(of: "messageHeader", alias: nil, columns: columns) == ["folderid", "id"])
    }
}
