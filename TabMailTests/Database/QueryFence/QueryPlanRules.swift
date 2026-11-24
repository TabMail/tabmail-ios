/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The plan rules of the query fence (`DatabaseIndexTests`, files in `QueryFence/`): which
/// lines of `EXPLAIN QUERY PLAN` read a set that grows with the user's mail.
///
/// Every access to a mail-sized table (`mailSized`) is one of:
/// - a point: an equality on an identity column (`identityColumns`, or an index expression
///   over one), or a range bounded on both sides of one column. It passes. (The width of a
///   two-sided range is not in the plan; the registry note names it.)
/// - a set read (equalities only on columns many rows share, such as `folderId`), a cursor
///   (a range bounded on one side) or a `SCAN` of a partial index. It passes only with a
///   proof that it stops, in its own `SELECT`: a positive `LIMIT` with no `OFFSET` (or the
///   `SELECT` is an `EXISTS` operand), no sort in that `SELECT` (a sort reads the whole set
///   before the limit applies), and no filter column outside the seek terms and the partial
///   index's condition (a residual filter can skip rows past the limit). Without that proof
///   it passes as a `COUNT` whose filter is all in the seek terms and the partial index's
///   condition (it reads the set once, through the index, and no table row), or as a lone
///   `MIN`/`MAX` with no residual filter (SQLite reads one end of the index). A covering
///   `COUNT` of a whole folder or account still passes, so its bound lives only in its
///   registry note.
/// - any other `SCAN`, or a seek through an automatic index (SQLite builds it with a scan):
///   it fails.
///
/// A plan name that is no table, alias, CTE or subquery of the statement, a seek or plan
/// line of an unknown form, and a mail-sized access with no reference in the statement
/// text fail as unverified. When the plan names a table the statement references more than
/// once with no alias, every one of those references must prove the stop.
enum QueryPlanRules {

    /// One row of `EXPLAIN QUERY PLAN`: its id in the plan tree, its parent's id, its text.
    struct PlanRow: Sendable, Equatable {
        let id: Int
        let parent: Int
        let detail: String
    }

    /// What the rules read from a schema.
    struct SchemaFacts: Sendable {
        /// Table and view names.
        let tables: Set<String>
        /// Lowercased column names per table, `rowid` included.
        let columns: [String: Set<String>]
        /// The `CREATE INDEX` text of each named index.
        let indexSQL: [String: String]

        static func load(_ db: Database) throws -> SchemaFacts {
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")
            var columns: [String: Set<String>] = [:]
            for table in tables {
                let names = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table])
                columns[table] = Set(names.map { $0.lowercased() }).union(["rowid"])
            }
            var indexSQL: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL") {
                indexSQL[row["name"]] = row["sql"]
            }
            return SchemaFacts(tables: Set(tables), columns: columns, indexSQL: indexSQL)
        }
    }

    /// Tables whose rows grow with the user's mail. Every other table of the three test
    /// databases is bounded: by accounts or folders, by a cap the app enforces (`chatTurn`,
    /// `draft`, `chatIdMapping`), or by being drained as it is processed (the staging
    /// tables, `bodyAssetPreparation`).
    static let mailSized: Set<String> = [
        "messageHeader", "messageBody", "messageUserLabel", "messageAICache", "messageReference",
        "bodyAsset", "chatHistory", "chatEventCalendar", "pendingRender",
    ]

    /// Columns (lowercased) whose equality names one row or one message's rows. An equality
    /// on any other column is a set read.
    static let identityColumns: Set<String> = [
        "rowid", "id", "messageid", "rfc822messageid", "headerid", "messageheaderid", "key", "compoundid",
    ]

    // MARK: - Findings

    /// The accesses of one statement's plan that read a mail-sized set with no proof that
    /// they stop, one line each. Empty when the plan passes.
    static func findings(plan: [PlanRow], sql: String, schema: SchemaFacts) -> [String] {
        let statement = StatementText(sql, schema: schema)
        var findings: [String] = []
        for row in plan {
            let detail = row.detail
            if detail == "SCAN CONSTANT ROW" || matches(knownLine, detail) { continue }
            guard let line = firstMatch(planLine, detail) else {
                findings.append("unsupported plan text: \(detail)")
                continue
            }
            let verb = line[1] ?? ""
            let name = line[2] ?? ""
            let planAlias = line[3]
            let rest = line[4] ?? ""

            let table: String
            let alias: String?
            if schema.tables.contains(name) {
                table = name
                alias = planAlias
            } else if let aliased = statement.aliases[name] {
                table = aliased
                alias = name
            } else if statement.derivedNames.contains(name) {
                continue // a CTE or a subquery of the statement
            } else {
                findings.append("unresolved plan name \(name): \(detail)")
                continue
            }
            guard mailSized.contains(table) else { continue }
            if let finding = check(row: row, verb: verb, table: table, alias: alias, rest: rest, plan: plan,
                                   statement: statement, schema: schema) {
                findings.append(finding)
            }
        }
        return findings
    }

    /// One access to a mail-sized table: nil when it passes.
    private static func check(row: PlanRow, verb: String, table: String, alias: String?, rest: String,
                              plan: [PlanRow], statement: StatementText, schema: SchemaFacts) -> String? {
        let access = rest.trimmingCharacters(in: .whitespaces)
        if rest.contains("AUTOMATIC") { return "an automatic index of \(table), built by a scan (\(access))" }
        guard let seek = Seek(rest) else { return "unsupported plan text: \(row.detail)" }
        let index = seek.index.flatMap { schema.indexSQL[$0] }.map { IndexFacts($0) } ?? IndexFacts.none

        let shape: String
        if verb == "SEARCH" {
            guard seek.index != nil else { return "unsupported plan text: \(row.detail)" }
            let point = seek.terms.contains { term in
                term.op == "=" && (identityColumns.contains(term.column.lowercased())
                    || (term.column == "<expr>" && !index.expressionColumns.isDisjoint(with: identityColumns)))
            }
            if point { return nil }
            if seek.isTwoSided { return nil }
            shape = seek.terms.contains { $0.op != "=" } ? "a cursor" : "a set read"
        } else {
            guard index.isPartial else { return "a scan of \(table) (\(access))" }
            shape = "a scan of a partial index"
        }

        var used = Set(seek.terms.map { $0.column.lowercased() }.filter { $0 != "<expr>" }).union(index.predicateColumns)
        if seek.terms.contains(where: { $0.column == "<expr>" }) { used.formUnion(index.expressionColumns) }
        let tableColumns = schema.columns[table] ?? []
        let sorted = isSortedInItsSelect(row, plan: plan)

        let own = statement.references.filter { $0.table == table && (alias == nil || $0.alias == alias) }
        guard !own.isEmpty else { return "\(shape) of \(table) (\(access)): no reference to it in the statement" }
        for reference in own {
            let scope = statement.scope(at: reference.position)
            let residual = scope.filterColumns(of: table, alias: reference.alias, columns: tableColumns).subtracting(used)
            if scope.isCount {
                if residual.isEmpty { continue }
                return "\(shape) of \(table) (\(access)): a count filtered on \(residual.sorted().joined(separator: ", ")) past the seek"
            }
            if scope.isLoneMinMax, verb == "SEARCH", residual.isEmpty { continue }
            if !scope.isLimited { return "\(shape) of \(table) (\(access)): no LIMIT stops it" }
            if sorted { return "\(shape) of \(table) (\(access)): sorted before its LIMIT" }
            if !residual.isEmpty {
                return "\(shape) of \(table) (\(access)): filtered on \(residual.sorted().joined(separator: ", ")) past the seek"
            }
        }
        return nil
    }

    /// A full sort (`USE TEMP B-TREE FOR ORDER BY|GROUP BY|DISTINCT`) in the same `SELECT`
    /// as `row`. The arms of a `MULTI-INDEX OR` belong to the `SELECT` above it. A partial
    /// sort (`… FOR LAST n TERMS OF ORDER BY`) reads the index in order and is not one.
    static func isSortedInItsSelect(_ row: PlanRow, plan: [PlanRow]) -> Bool {
        let byId = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parent = row.parent
        while let up = byId[parent], matches(orArm, up.detail) { parent = up.parent }
        return plan.contains { $0.parent == parent && matches(fullSort, $0.detail) }
    }

    // MARK: - Plan text

    /// `SCAN|SEARCH <table or alias> [AS <alias>]<rest>`.
    static let planLine = regex(#"^(SCAN|SEARCH) (\w+)(?: AS (\w+))?(.*)$"#)
    /// The plan lines that access no table.
    static let knownLine = regex(#"^(?:USE TEMP B-TREE FOR .+|(?:CORRELATED )?(?:SCALAR|LIST) SUBQUERY \d+|(?:CO-ROUTINE|MATERIALIZE) \S+|COMPOUND QUERY|LEFT-MOST SUBQUERY|UNION ALL|(?:UNION|INTERSECT|EXCEPT) USING TEMP B-TREE|MERGE \(.+\)|MULTI-INDEX OR|INDEX \d+|BLOOM FILTER ON .+|(?:SCAN|SEARCH) \(subquery-\d+\).*)$"#)
    static let orArm = regex(#"^(?:MULTI-INDEX OR|INDEX \d+)$"#)
    static let fullSort = regex(#"^USE TEMP B-TREE FOR (?:ORDER BY|GROUP BY|DISTINCT)$"#)

    /// The seek of a plan line: the index it reads (`#rowid` for the integer primary key,
    /// `#pk` for a `WITHOUT ROWID` key) and its terms. Nil for a term of an unknown form.
    struct Seek {
        struct Term {
            let column: String
            /// `=` (also `IS` and `IN`), `<`, `<=`, `>`, `>=`.
            let op: String
        }

        let index: String?
        let terms: [Term]

        static let named = QueryPlanRules.regex(#"USING (?:COVERING )?INDEX (\w+)"#)
        static let termList = QueryPlanRules.regex(#"\((.*)\)\s*$"#)
        static let term = QueryPlanRules.regex(#"^\s*(?:\(([\w,]+)\)|(<expr>)|(\w+))\s*(=|>=|<=|>|<|IS\b|IN\b)"#)

        init?(_ rest: String) {
            if let named = QueryPlanRules.firstMatch(Self.named, rest) {
                index = named[1]
            } else if rest.contains("USING INTEGER PRIMARY KEY") {
                index = "#rowid"
            } else if rest.contains("USING PRIMARY KEY") {
                index = "#pk"
            } else {
                index = nil
            }
            var terms: [Term] = []
            if index != nil, let list = QueryPlanRules.firstMatch(Self.termList, rest)?[1] {
                for text in list.components(separatedBy: " AND ") {
                    guard let parts = QueryPlanRules.firstMatch(Self.term, text), let op = parts[4] else { return nil }
                    let normalized = op == "IS" || op == "IN" ? "=" : op
                    let columns = parts[1].map { $0.components(separatedBy: ",") } ?? [parts[2] ?? parts[3] ?? ""]
                    terms += columns.map { Term(column: $0, op: normalized) }
                }
            }
            self.terms = terms
        }

        /// One column with a lower and an upper bound.
        var isTwoSided: Bool {
            Dictionary(grouping: terms, by: \.column).values.contains { group in
                group.contains { $0.op.hasPrefix("<") } && group.contains { $0.op.hasPrefix(">") }
            }
        }
    }

    /// What an index's `CREATE INDEX` text says: the columns of its `WHERE` (a partial
    /// index) and of its key (read for an `<expr>` term).
    struct IndexFacts {
        let isPartial: Bool
        let predicateColumns: Set<String>
        let expressionColumns: Set<String>

        static let none = IndexFacts(isPartial: false, predicateColumns: [], expressionColumns: [])
        static let predicate = QueryPlanRules.regex(#"\bWHERE\b(.*)$"#, [.caseInsensitive, .dotMatchesLineSeparators])
        static let key = QueryPlanRules.regex(#"\bON\s+["`\[]?\w+["`\]]?\s*\((.*?)\)\s*(?:WHERE\b.*)?$"#, [.caseInsensitive, .dotMatchesLineSeparators])

        init(isPartial: Bool, predicateColumns: Set<String>, expressionColumns: Set<String>) {
            self.isPartial = isPartial
            self.predicateColumns = predicateColumns
            self.expressionColumns = expressionColumns
        }

        init(_ sql: String) {
            let predicate = QueryPlanRules.firstMatch(Self.predicate, sql)?[1]
            isPartial = predicate != nil
            predicateColumns = QueryPlanRules.identifiers(predicate ?? "")
            expressionColumns = QueryPlanRules.identifiers(QueryPlanRules.firstMatch(Self.key, sql)?[1] ?? "")
        }
    }

    // MARK: - Statement text

    /// The statement text the rules read: string literals and comments blanked, identifier
    /// quotes removed, every offset kept (UTF-16).
    struct StatementText {
        struct Reference {
            let table: String
            let alias: String?
            let position: Int
        }

        let masked: [unichar]
        let pairs: [(open: Int, close: Int)]
        let references: [Reference]
        let aliases: [String: String]
        /// CTE names and the names given to subqueries.
        let derivedNames: Set<String>

        static let reference = QueryPlanRules.regex(
            #"\b(?:FROM|JOIN|UPDATE(?:\s+OR\s+\w+)?|INTO)\s+(?!(?:"# + keywords + #")\b)([A-Za-z_]\w*)(?:\s+(?:AS\s+)?(?!(?:"# + keywords + #")\b)([A-Za-z_]\w*))?"#,
            [.caseInsensitive])
        /// A further table of a comma join (`FROM folder f, messageHeader m`): kept only when
        /// the name is a table.
        static let listedReference = QueryPlanRules.regex(
            #",\s*([A-Za-z_]\w*)(?:\s+(?:AS\s+)?(?!(?:"# + keywords + #")\b)([A-Za-z_]\w*))?"#, [.caseInsensitive])
        static let cte = QueryPlanRules.regex(#"(?:\bWITH\b(?:\s+RECURSIVE)?|,)\s*([A-Za-z_]\w*)\s*(?:\([^)]*\))?\s+AS\s*\("#, [.caseInsensitive])
        static let subqueryName = QueryPlanRules.regex(#"\)\s*(?:AS\s+)?([A-Za-z_]\w*)"#, [.caseInsensitive])
        static let keywords = "WHERE|SET|ON|USING|LEFT|RIGHT|FULL|INNER|OUTER|CROSS|NATURAL|JOIN|ORDER|GROUP|LIMIT|OFFSET|VALUES|SELECT|INDEXED|NOT|HAVING|UNION|EXCEPT|INTERSECT|WINDOW|RETURNING|DEFAULT|AS|DO|AND|OR"
        static let keywordSet = Set(keywords.components(separatedBy: "|"))

        init(_ sql: String, schema: SchemaFacts) {
            masked = QueryPlanRules.mask(sql)
            var stack: [Int] = []
            var pairs: [(open: Int, close: Int)] = []
            for (offset, unit) in masked.enumerated() {
                if unit == 40 { stack.append(offset) } // (
                else if unit == 41, let open = stack.popLast() { pairs.append((open, offset)) } // )
            }
            self.pairs = pairs

            let text = QueryPlanRules.string(masked)
            var references: [Reference] = []
            for match in QueryPlanRules.allMatches(Self.reference, text) {
                guard let table = match.groups[1] else { continue }
                references.append(Reference(table: table, alias: match.groups[2], position: match.location))
            }
            for match in QueryPlanRules.allMatches(Self.listedReference, text) {
                guard let table = match.groups[1], schema.tables.contains(table) else { continue }
                references.append(Reference(table: table, alias: match.groups[2], position: match.location))
            }
            self.references = references
            var aliases: [String: String] = [:]
            for reference in references { if let alias = reference.alias { aliases[alias] = reference.table } }
            self.aliases = aliases
            var derived = Set(QueryPlanRules.allMatches(Self.cte, text).compactMap { $0.groups[1] })
            for match in QueryPlanRules.allMatches(Self.subqueryName, text) {
                if let name = match.groups[1], !Self.keywordSet.contains(name.uppercased()) { derived.insert(name) }
            }
            derivedNames = derived
        }

        /// The innermost bracket around `position` (the whole statement when none).
        func scope(at position: Int) -> Scope {
            var open = -1
            var close = masked.count
            for pair in pairs where pair.open < position && position < pair.close && pair.open > open {
                open = pair.open
                close = pair.close
            }
            return Scope(statement: self, open: open, close: close)
        }
    }

    /// One `SELECT` (or the whole statement): the text between `open` and `close`.
    struct Scope {
        /// Nested brackets blanked: the scope's own clauses.
        let top: String
        /// Nested subqueries blanked, other brackets kept: the scope's own filter terms.
        let flat: String
        let followsExists: Bool

        static let whereClause = QueryPlanRules.regex(#"\bWHERE\b"#, [.caseInsensitive])
        static let whereEnd = QueryPlanRules.regex(#"\b(?:GROUP|ORDER|LIMIT|HAVING|WINDOW|UNION|EXCEPT|INTERSECT|RETURNING)\b"#, [.caseInsensitive])
        static let onClause = QueryPlanRules.regex(#"\bON\b"#, [.caseInsensitive])
        static let onEnd = QueryPlanRules.regex(#"\b(?:JOIN|WHERE|GROUP|ORDER|LIMIT|LEFT|INNER|CROSS)\b"#, [.caseInsensitive])
        static let limit = QueryPlanRules.regex(#"\bLIMIT\s+(\?\d*|:\w+|\d+)\s*(,|\bOFFSET\b)?"#, [.caseInsensitive])
        static let selectList = QueryPlanRules.regex(#"\bSELECT\b(.*?)\bFROM\b"#, [.caseInsensitive, .dotMatchesLineSeparators])
        static let groupBy = QueryPlanRules.regex(#"\bGROUP\s+BY\b"#, [.caseInsensitive])
        static let minMax = QueryPlanRules.regex(#"^(?:MIN|MAX)\s*\(\s*\)(?:\s+(?:AS\s+)?\w+)?$"#, [.caseInsensitive])
        static let count = QueryPlanRules.regex(#"^COUNT\s*\(\s*\)(?:\s+(?:AS\s+)?\w+)?$"#, [.caseInsensitive])
        static let plainColumn = QueryPlanRules.regex(#"^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?$"#)
        static let exists = QueryPlanRules.regex(#"\bEXISTS\s*$"#, [.caseInsensitive])
        static let column = QueryPlanRules.regex(#"(?:([A-Za-z_]\w*)\s*\.\s*)?([A-Za-z_]\w*)"#)

        init(statement: StatementText, open: Int, close: Int) {
            let inner = Array(statement.masked[(open + 1)..<close])
            var top = inner
            var flat = inner
            for pair in statement.pairs where open < pair.open && pair.close < close && pair.open + 1 < pair.close {
                let from = pair.open + 1 - (open + 1)
                let to = pair.close - (open + 1)
                for offset in from..<to { top[offset] = 32 }
                let content = QueryPlanRules.string(Array(statement.masked[(pair.open + 1)..<pair.close]))
                if content.range(of: #"^\s*(?:SELECT|WITH)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    for offset in from..<to { flat[offset] = 32 }
                }
            }
            self.top = QueryPlanRules.string(top)
            self.flat = QueryPlanRules.string(flat)
            followsExists = open >= 0
                && QueryPlanRules.matches(Self.exists, QueryPlanRules.string(Array(statement.masked[0..<open])))
        }

        /// A positive `LIMIT` with no `OFFSET`, or an `EXISTS` operand.
        var isLimited: Bool {
            if followsExists { return true }
            guard let limit = QueryPlanRules.firstMatch(Self.limit, top) else { return false }
            return limit[2] == nil && limit[1] != "0"
        }

        var selectItems: [String] {
            guard let list = QueryPlanRules.firstMatch(Self.selectList, top)?[1] else { return [] }
            return list.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        var isGrouped: Bool { QueryPlanRules.matches(Self.groupBy, top) }

        var isLoneMinMax: Bool {
            let items = selectItems
            return items.count == 1 && QueryPlanRules.matches(Self.minMax, items[0]) && !isGrouped
        }

        /// Counts, and grouping columns beside them.
        var isCount: Bool {
            let items = selectItems
            return items.contains { QueryPlanRules.matches(Self.count, $0) }
                && items.allSatisfy { QueryPlanRules.matches(Self.count, $0) || QueryPlanRules.matches(Self.plainColumn, $0) }
        }

        /// The `WHERE` and `ON` text of the scope, nested subqueries left out.
        var filterText: String {
            var spans: [String] = []
            let flatText = flat as NSString
            if let start = QueryPlanRules.allMatches(Self.whereClause, top).first {
                let from = start.location + start.length
                let end = QueryPlanRules.firstLocation(Self.whereEnd, top, from: from) ?? (top as NSString).length
                spans.append(flatText.substring(with: NSRange(location: from, length: end - from)))
            }
            for on in QueryPlanRules.allMatches(Self.onClause, top) {
                let from = on.location + on.length
                let end = QueryPlanRules.firstLocation(Self.onEnd, top, from: from) ?? (top as NSString).length
                spans.append(flatText.substring(with: NSRange(location: from, length: end - from)))
            }
            return spans.joined(separator: " ")
        }

        /// The columns of `table` the scope filters on (unqualified, or qualified by the
        /// table or its alias), lowercased.
        func filterColumns(of table: String, alias: String?, columns: Set<String>) -> Set<String> {
            var found: Set<String> = []
            for match in QueryPlanRules.allMatches(Self.column, filterText) {
                guard let name = match.groups[2]?.lowercased(), columns.contains(name) else { continue }
                if let qualifier = match.groups[1], qualifier != table, qualifier != alias { continue }
                found.insert(name)
            }
            return found
        }
    }

    // MARK: - Text helpers

    /// `sql` with string literal contents, comments and identifier quotes blanked, one
    /// space per UTF-16 unit, so every offset stays.
    static func mask(_ sql: String) -> [unichar] {
        let source = Array(sql.utf16)
        var out = source
        let count = source.count
        let space: unichar = 32
        var index = 0
        while index < count {
            let unit = source[index]
            if unit == 39 { // '
                var end = index + 1
                while end < count {
                    if source[end] == 39 {
                        if end + 1 < count, source[end + 1] == 39 { end += 2; continue }
                        break
                    }
                    end += 1
                }
                for offset in (index + 1)..<min(end, count) { out[offset] = space }
                index = end + 1
                continue
            }
            if unit == 45, index + 1 < count, source[index + 1] == 45 { // --
                var end = index
                while end < count, source[end] != 10, source[end] != 13 { out[end] = space; end += 1 }
                index = end
                continue
            }
            if unit == 47, index + 1 < count, source[index + 1] == 42 { // /*
                var end = index + 2
                while end + 1 < count, !(source[end] == 42 && source[end + 1] == 47) { end += 1 }
                let stop = end + 1 < count ? end + 2 : count
                for offset in index..<stop { out[offset] = space }
                index = stop
                continue
            }
            if unit == 34 || unit == 96 || unit == 91 || unit == 93 { out[index] = space } // " ` [ ]
            index += 1
        }
        return out
    }

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // A pattern of this file that does not compile is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func string(_ units: [unichar]) -> String { String(utf16CodeUnits: units, count: units.count) }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The capture groups of the first match (index 0 is the whole match), nil when none.
    static func firstMatch(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        allMatches(regex, text).first?.groups
    }

    struct Match {
        let location: Int
        let length: Int
        let groups: [String?]
    }

    static func allMatches(_ regex: NSRegularExpression, _ text: String) -> [Match] {
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { result in
            let groups = (0..<result.numberOfRanges).map { index -> String? in
                let range = result.range(at: index)
                return range.location == NSNotFound ? nil : string.substring(with: range)
            }
            return Match(location: result.range.location, length: result.range.length, groups: groups)
        }
    }

    static func firstLocation(_ regex: NSRegularExpression, _ text: String, from: Int) -> Int? {
        let length = (text as NSString).length
        guard from <= length else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: from, length: length - from))?.range.location
    }

    static let identifier = regex(#"[A-Za-z_]\w*"#)

    /// The identifiers of `text`, lowercased.
    static func identifiers(_ text: String) -> Set<String> {
        Set(allMatches(identifier, text).compactMap { $0.groups[0]?.lowercased() })
    }
}
