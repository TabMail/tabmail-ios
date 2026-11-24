import Foundation
import GRDB
import SQLite3
import Testing
@testable import TabMail

/// The query-plan fence. Every database query site of the production sources (found by
/// `QueryCensusScanner`: the app, the notification extension and `Shared`) has exactly one
/// row in `query-registry.tsv`, next to this file, saying why it does not read a set that
/// grows with the user's mail, or which filed issue describes it. A new or changed query
/// fails `everySiteIsRegistered` until its row is written, so every query gets a verdict
/// in review.
///
/// The bar: no query reads a set that grows with the user's mail, on any path (hot,
/// rare, one-shot, maintenance). It seeks through an index, or reads a table that is
/// provably small. A whole-folder or whole-inbox read through an index still grows with
/// mail, and so does a sort, an `OFFSET` or a key-range walk over a mail-sized set.
///
/// Verdicts (column `verdict`, one per row):
/// - `SEEK`: every statement the site runs seeks through an index, or writes one row by key.
/// - `BOUNDED: <bound>`: reads a provably small set; the bound is named (accounts,
///   folders, a capped table, a configured limit).
/// - `N+1: <bound>`: one seeking statement per item of a loop whose items are bounded.
/// - `SIM: <question>`: an index exists; whether the planner takes it is settled by the
///   plan check below.
/// - `SCAN #<issue>`: one of the statements a filed issue describes.
/// - `EXEMPT: <reason>`, the reason one of: `wipe` (deletes everything by design: account
///   removal, sign-out, a Settings clear), `user rebuild` (the user asked to rebuild
///   everything), `debug/test scene` (`#if DEBUG` or a UI-test scene), `debug tool` (runs
///   only from the hidden debug menu or while debug logging is switched on), `demo`,
///   `test-only` (no production caller), `search by method` (the AI email search and the
///   chat memory search read every candidate by design), `shipped migration` (a
///   registered migration: frozen once released), `inherent: <why>`, or
///   `shipped one-shot: <name>` (a startup one-shot every device past it already ran).
/// - `NOT-A-QUERY`: runs no statement (transaction control, a pass-through, a same-named
///   method that is not GRDB's).
///
/// `SEEK`, `N+1` and `SIM` are claims a query plan can refute, so
/// `seekVerdictsHoldInThePlan` explains every complete SQL literal that carries one, on
/// the real schemas (the main database after every migration and the deferred indexes,
/// the notification extension's staging database, the attachment manifest), in two
/// statistics regimes, and fails when the plan walks a mail-sized table: a `SCAN` of it,
/// or a one-sided range on its key (a cursor walk, which checks its other terms row by
/// row). Literals with interpolations, and the statements of the search and chat memory
/// databases (no test-built schema here), are held by the registry and review only.
@Suite("Query registry fence: every query site has a verdict, and seeks seek")
struct QueryRegistryFenceTests {

    // MARK: - Registry

    struct Entry: Sendable {
        let file: String
        let context: String
        let kind: String
        let ordinal: Int
        let verdict: String
        let note: String
        let text: String

        /// Same identity as `QueryCensusScanner.Site.key`.
        var key: String { [file, context, kind, String(ordinal), text].joined(separator: "\t") }
        var label: String { "\(file) [\(kind)] \(context) #\(ordinal): \(text.prefix(160))" }
    }

    enum FenceError: Error, CustomStringConvertible {
        case malformedRegistry(line: Int, text: String)
        case setup(String)

        var description: String {
            switch self {
            case .malformedRegistry(let line, let text): "query-registry.tsv line \(line) is not 7 tab-separated fields: \(text.prefix(200))"
            case .setup(let what): "fence setup failed: \(what)"
            }
        }
    }

    static let registryHeader = "file\tcontext\tkind\tordinal\tverdict\tnote\ttext"

    static var registryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("query-registry.tsv")
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QueryFence
            .deletingLastPathComponent() // Database
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
    }

    static func registry() throws -> [Entry] {
        let lines = try String(contentsOf: registryURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first, header == registryHeader else {
            throw FenceError.malformedRegistry(line: 1, text: lines.first.map(String.init) ?? "")
        }
        return try lines.dropFirst().enumerated().map { index, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let ordinal = Int(fields[3]) else {
                throw FenceError.malformedRegistry(line: index + 2, text: String(line))
            }
            return Entry(file: fields[0], context: fields[1], kind: fields[2], ordinal: ordinal,
                         verdict: fields[4], note: fields[5], text: fields[6])
        }
    }

    // MARK: - The scan equals the registry

    @Test("Every query site of the production sources has exactly one registry row, and every row a site")
    func everySiteIsRegistered() throws {
        let sites = try QueryCensusScanner.scan(root: Self.repoRoot)
        let entries = try Self.registry()

        let scanned = Set(sites.map(\.key))
        let registered = Set(entries.map(\.key))
        let unregistered = sites.filter { !registered.contains($0.key) }
            .map { "\($0.file):\($0.line) [\($0.kind)] \($0.context): \($0.text.prefix(160))" }
        let stale = entries.filter { !scanned.contains($0.key) }.map(\.label)
        let duplicated = Dictionary(grouping: entries, by: \.key).values.filter { $0.count > 1 }.map { $0[0].label }

        #expect(unregistered.isEmpty, """
            Query sites with no row in TabMailTests/Database/QueryFence/query-registry.tsv. Add one row per \
            site with its verdict (vocabulary: QueryRegistryFenceTests):
            \(unregistered.joined(separator: "\n"))
            """)
        #expect(stale.isEmpty, """
            Registry rows whose site is gone or changed (file, context, kind, ordinal and text must match \
            the source). Update or remove them:
            \(stale.joined(separator: "\n"))
            """)
        #expect(duplicated.isEmpty, "Registry rows listed twice:\n\(duplicated.joined(separator: "\n"))")
    }

    // MARK: - Verdicts are from the vocabulary

    static let verdictGrammar = try! NSRegularExpression(
        pattern: #"^(SEEK|NOT-A-QUERY|SCAN #[0-9]+|(BOUNDED|N\+1|SIM): \S.*|EXEMPT: (wipe|user rebuild|debug/test scene|debug tool|demo|test-only|search by method|shipped migration|(inherent|shipped one-shot): \S.*))$"#)

    static func isWellFormed(_ verdict: String) -> Bool {
        verdictGrammar.firstMatch(in: verdict, range: NSRange(verdict.startIndex..., in: verdict)) != nil
    }

    @Test("Every registry row carries one verdict from the vocabulary and a note")
    func everyVerdictIsWellFormed() throws {
        let malformed = try Self.registry()
            .filter { !Self.isWellFormed($0.verdict) || $0.note.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.verdict) | \($0.note) | \($0.label)" }
        #expect(malformed.isEmpty, """
            Registry rows with a verdict outside the vocabulary or no note. A new finding is filed as an \
            issue first and registered as SCAN #<issue>:
            \(malformed.joined(separator: "\n"))
            """)
    }

    /// Pins the grammar itself, so a loosened pattern cannot let every verdict through.
    @Test("The verdict grammar accepts the vocabulary and nothing else")
    func verdictGrammarIsExact() {
        for verdict in ["SEEK", "NOT-A-QUERY", "SCAN #1364", "BOUNDED: folders", "N+1: the page size",
                        "SIM: does the range seek", "EXEMPT: wipe", "EXEMPT: debug tool",
                        "EXEMPT: shipped migration", "EXEMPT: inherent: why", "EXEMPT: shipped one-shot: name"] {
            #expect(Self.isWellFormed(verdict), "\(verdict) is part of the vocabulary")
        }
        for verdict in ["", "SEEK ", "SCAN", "SCAN #", "SCAN-CANDIDATE: messageHeader", "BOUNDED:", "BOUNDED: ",
                        "EXEMPT: other", "EXEMPT: inherent:", "seek", "SIM:question"] {
            #expect(!Self.isWellFormed(verdict), "\(verdict) is not part of the vocabulary")
        }
    }

    // MARK: - Seeks seek

    /// The statistics the planner works from. `noStatistics` is a fresh database (the
    /// migrations' `ANALYZE` ran on empty tables, which leaves no rows in
    /// `sqlite_stat1`, so SQLite assumes its defaults); `largeMailbox` installs
    /// statistics for ADR-IOS-029's large profile, as the maintenance `ANALYZE` would
    /// leave them on a device with that much mail.
    enum Regime: String, CaseIterable, Sendable {
        case noStatistics
        case largeMailbox
    }

    /// Tables whose rows grow with the user's mail. Every other table of the three test
    /// databases is bounded: by accounts or folders, by a cap the app enforces (`chatTurn`,
    /// `draft`, `chatIdMapping`), or by being drained as it is processed (the staging
    /// tables, `bodyAssetPreparation`).
    static let mailSized: Set<String> = [
        "messageHeader", "messageBody", "messageUserLabel", "messageAICache", "messageReference",
        "bodyAsset", "chatHistory", "chatEventCalendar", "pendingRender",
    ]

    /// The verdicts a plan can refute.
    static func planChecked(_ verdict: String) -> Bool {
        verdict == "SEEK" || verdict.hasPrefix("N+1: ") || verdict.hasPrefix("SIM: ")
    }

    @Test("SEEK, N+1 and SIM verdicts hold in the query plan", arguments: Regime.allCases)
    func seekVerdictsHoldInThePlan(_ regime: Regime) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databases = try Self.databases(regime, stagingDirectory: directory)
        let partialIndexes = try Self.partialIndexes(in: databases)
        #expect(!partialIndexes.isEmpty, "the main schema has partial indexes; none were found")

        var sites: [String: QueryCensusScanner.Site] = [:]
        for site in try QueryCensusScanner.scan(root: Self.repoRoot) { sites[site.key] = site }

        var walks: [String] = []
        var unexplained: [String] = []
        var explained = 0
        for entry in try Self.registry() where entry.kind == "sql" && Self.planChecked(entry.verdict) {
            // A row with no site is reported by `everySiteIsRegistered`.
            guard let site = sites[entry.key], !site.sql.contains("\\("), Self.isDML(site.sql) else { continue }
            switch Self.explain(site.sql, in: databases) {
            case .plan(let plan):
                explained += 1
                let found = Self.mailWalks(plan: plan, sql: site.sql, partialIndexes: partialIndexes)
                if !found.isEmpty {
                    walks.append("""
                        \(site.file):\(site.line) \(site.context) [\(entry.verdict)] walks \(found.joined(separator: ", "))
                            \(site.sql.prefix(240))
                            plan: \(plan.joined(separator: " | "))
                        """)
                }
            case .unprepared(let errors):
                if !Self.isRegistryOnly(errors) {
                    unexplained.append("\(site.file):\(site.line) \(site.sql.prefix(200))\n    \(errors.joined(separator: "\n    "))")
                }
            }
        }

        #expect(explained > 0, "no statement was explained: the registry or the schemas did not load")
        #expect(walks.isEmpty, """
            [\(regime.rawValue)] Statements registered SEEK, N+1 or SIM whose plan walks a mail-sized table. \
            Fix the query, or file the finding and register it as SCAN #<issue>:
            \(walks.joined(separator: "\n"))
            """)
        #expect(unexplained.isEmpty, """
            [\(regime.rawValue)] Statements registered SEEK, N+1 or SIM that prepare on none of the test \
            schemas (main, staging, manifest) and do not name a search or memory database table:
            \(unexplained.joined(separator: "\n"))
            """)
    }

    // MARK: Schemas

    struct Schema {
        let name: String
        let queue: DatabaseQueue
    }

    /// The three databases whose schemas the tests can build from production code.
    static func databases(_ regime: Regime, stagingDirectory: URL) throws -> [Schema] {
        let main = try TestDatabase.make()
        try main.write { try SyncEngine.createDeferredIndexes($0) }

        let stagingPath = stagingDirectory.appendingPathComponent("nse_staging.sqlite").path
        guard AppDatabase.createNSEStagingDB(atPath: stagingPath) else { throw FenceError.setup("staging database") }
        let staging = try DatabaseQueue(path: stagingPath)
        // The columns and the table the extension adds on its own side.
        NSEStagingDB.ensureObservedUidValidityColumn(db: staging)
        NSEStagingDB.ensureProviderDateColumn(db: staging)
        NSEBadge.markCounted(db: staging, ids: ["query-fence"])

        let manifest = try BodyAssetStore._makeTestQueue()

        let schemas = [Schema(name: "main", queue: main), Schema(name: "staging", queue: staging),
                       Schema(name: "manifest", queue: manifest)]
        if regime == .largeMailbox {
            for schema in schemas { try schema.queue.write { try Self.installLargeMailboxStatistics($0) } }
        }
        return schemas
    }

    /// Rows per table in the large-mailbox regime: ADR-IOS-029's large profile (500,000
    /// headers) and the tables that grow with it; every other table at `smallTableRows`.
    static let largeMailboxRows: [String: Int] = [
        "messageHeader": 500_000, "messageBody": 500_000, "messageAICache": 500_000,
        "messageUserLabel": 500_000, "messageReference": 1_000_000, "bodyAsset": 250_000,
        "chatHistory": 50_000, "chatEventCalendar": 10_000, "pendingRender": 1_000, "folder": 300,
    ]
    static let smallTableRows = 100
    /// Share of a table's rows a partial index is assumed to hold.
    static let partialIndexDivisor = 10

    /// Distinct values assumed for an index column, by its name: a few accounts, a few
    /// hundred folders, two values for a flag, and near-unique for ids, keys and dates.
    static func assumedDistinct(_ column: String?, rows: Int) -> Int {
        guard let column = column?.lowercased() else { return rows } // an expression: near-unique
        if column == "accountid" { return 3 }
        if column == "folderid" || column == "folderpath" { return 300 }
        if column.hasPrefix("is") || column.hasPrefix("has") || column.hasSuffix("complete")
            || column.hasSuffix("confirmed") || column.hasSuffix("oversized")
            || ["kind", "role", "type", "status", "provider"].contains(column) {
            return 2
        }
        return rows
    }

    /// Replaces `sqlite_stat1` with the large-mailbox statistics and makes the planner
    /// reload them (`ANALYZE sqlite_master`).
    static func installLargeMailboxStatistics(_ db: Database) throws {
        try db.execute(sql: "ANALYZE") // creates sqlite_stat1; the tables are empty
        try db.execute(sql: "DELETE FROM sqlite_stat1")
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        for table in tables {
            let rows = largeMailboxRows[table] ?? smallTableRows
            let indexes = try Row.fetchAll(db, sql: #"SELECT name, "unique", partial FROM pragma_index_list(?)"#, arguments: [table])
            if indexes.isEmpty {
                try db.execute(sql: "INSERT INTO sqlite_stat1 (tbl, idx, stat) VALUES (?, NULL, ?)", arguments: [table, "\(rows)"])
                continue
            }
            for index in indexes {
                let name: String = index["name"]
                let unique: Bool = index["unique"]
                let partial: Bool = index["partial"]
                let columns = try Row.fetchAll(
                    db, sql: "SELECT name FROM pragma_index_xinfo(?) WHERE key = 1 ORDER BY seqno", arguments: [name]
                ).map { $0["name"] as String? }
                let indexRows = partial ? max(1, rows / partialIndexDivisor) : rows
                var distinct = 1
                var averages: [Int] = []
                for column in columns {
                    distinct = min(indexRows, distinct * assumedDistinct(column, rows: indexRows))
                    averages.append(max(1, indexRows / distinct))
                }
                if unique, !averages.isEmpty { averages[averages.count - 1] = 1 }
                let stat = ([indexRows] + averages).map(String.init).joined(separator: " ")
                try db.execute(sql: "INSERT INTO sqlite_stat1 (tbl, idx, stat) VALUES (?, ?, ?)", arguments: [table, name, stat])
            }
        }
        try db.execute(sql: "ANALYZE sqlite_master")
    }

    // MARK: Explaining

    enum Explained {
        case plan([String])
        case unprepared([String])
    }

    static let dmlStart = try! NSRegularExpression(pattern: #"^\s*(SELECT|INSERT|UPDATE|DELETE|WITH|REPLACE)\b"#, options: [.caseInsensitive])

    static func isDML(_ sql: String) -> Bool {
        dmlStart.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)) != nil
    }

    /// The plan of every statement of `sql` on the first schema that prepares it, each
    /// placeholder bound to a throwaway value (the plan does not depend on it).
    static func explain(_ sql: String, in schemas: [Schema]) -> Explained {
        var errors: [String] = []
        for schema in schemas {
            do {
                let plan = try schema.queue.inDatabase { db -> [String] in
                    var plan: [String] = []
                    for statement in try Array(db.allStatements(sql: sql)) {
                        let explain = try db.makeStatement(sql: "EXPLAIN QUERY PLAN " + statement.sql)
                        let count = Int(sqlite3_bind_parameter_count(explain.sqliteStatement))
                        explain.setUncheckedArguments(StatementArguments(Array(repeating: "x", count: count)))
                        plan += try Row.fetchAll(explain).map { $0["detail"] as String }
                    }
                    return plan
                }
                return .plan(plan)
            } catch let error as DatabaseError {
                errors.append("\(schema.name): \(error.message ?? "\(error)")")
            } catch {
                errors.append("\(schema.name): \(error)")
            }
        }
        return .unprepared(errors)
    }

    /// Tables of the search index and chat memory databases, which this suite does not
    /// build. A statement on one of them prepares nowhere here and is held by the
    /// registry alone.
    static let registryOnlyTable = try! NSRegularExpression(
        pattern: #"no such table: (?:main\.)?(message_meta|message_ids|messages_vec|messages_fts\w*|message_embeddings|memory_\w+)$"#)

    /// Also held by the registry alone: a literal SQLite reports as `incomplete input`, a
    /// fragment the code completes at run time (an `IN (` list built from placeholders).
    static func isRegistryOnly(_ errors: [String]) -> Bool {
        guard let mainError = errors.first(where: { $0.hasPrefix("main: ") }) else { return false }
        if mainError == "main: incomplete input" { return true }
        return registryOnlyTable.firstMatch(in: mainError, range: NSRange(mainError.startIndex..., in: mainError)) != nil
    }

    /// The partial indexes of the test schemas (`CREATE INDEX … WHERE …`).
    static func partialIndexes(in schemas: [Schema]) throws -> Set<String> {
        var names: Set<String> = []
        for schema in schemas {
            let found = try schema.queue.inDatabase { db in
                try String.fetchAll(db, sql: """
                    SELECT il.name FROM sqlite_master AS m, pragma_index_list(m.name) AS il
                    WHERE m.type = 'table' AND il.partial = 1
                    """)
            }
            names.formUnion(found)
        }
        return names
    }

    // MARK: Plan rules

    /// `SCAN|SEARCH <table or alias> [AS <alias>]<rest>`, one line of `EXPLAIN QUERY PLAN`.
    static let planLine = try! NSRegularExpression(pattern: #"^(SCAN|SEARCH) (\w+)(?: AS (\w+))?(.*)$"#)
    /// A seek whose only term is a one-sided range on the table's key: a cursor walk.
    static let keyRangeOnly = try! NSRegularExpression(
        pattern: #"USING (?:INTEGER PRIMARY KEY|PRIMARY KEY|(?:COVERING )?INDEX sqlite_autoindex_\w+) \(\w+[<>]=?\?\)$"#)
    /// `FROM|JOIN|UPDATE|INTO <table> [[AS] <alias>]`.
    static let tableReference = try! NSRegularExpression(
        pattern: #"\b(?:FROM|JOIN|UPDATE|INTO)\s+"?([A-Za-z_]\w*)"?(?:\s+(?:AS\s+)?([A-Za-z_]\w*))?"#, options: [.caseInsensitive])
    static let notAnAlias: Set<String> = [
        "WHERE", "SET", "ON", "USING", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "NATURAL", "JOIN",
        "ORDER", "GROUP", "LIMIT", "VALUES", "SELECT", "INDEXED", "NOT", "HAVING", "UNION", "EXCEPT",
        "INTERSECT", "WINDOW", "RETURNING", "DEFAULT", "AS",
    ]

    /// The aliases `sql` gives its tables (`FROM messageHeader m` maps `m`).
    static func tableAliases(_ sql: String) -> [String: String] {
        var aliases: [String: String] = [:]
        for match in tableReference.matches(in: sql, range: NSRange(sql.startIndex..., in: sql)) {
            guard let table = Range(match.range(at: 1), in: sql).map({ String(sql[$0]) }),
                  let alias = Range(match.range(at: 2), in: sql).map({ String(sql[$0]) }),
                  !notAnAlias.contains(alias.uppercased()) else { continue }
            aliases[alias] = table
        }
        return aliases
    }

    /// `USING [COVERING] INDEX <name>` on a plan line.
    static let indexUsed = try! NSRegularExpression(pattern: #"USING (?:COVERING )?INDEX (\w+)"#)
    static let limitClause = try! NSRegularExpression(pattern: #"\bLIMIT\b"#, options: [.caseInsensitive])

    /// A `SCAN` that reads a partial index in its own order and stops at the statement's
    /// `LIMIT`: SQLite reads only the rows inside the index's `WHERE`, and no sort sits
    /// between that read and the limit. (A `WHERE` term beyond the index's own condition
    /// can still make the read skip rows past the limit; the registry note names the index.)
    static func isLimitedPartialIndexRead(rest: String, plan: [String], sql: String, partialIndexes: Set<String>) -> Bool {
        guard let match = indexUsed.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let index = Range(match.range(at: 1), in: rest).map({ String(rest[$0]) }),
              partialIndexes.contains(index) else { return false }
        guard limitClause.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)) != nil else { return false }
        return !plan.contains { $0.contains("USE TEMP B-TREE") }
    }

    /// The plan lines that walk a mail-sized table: a `SCAN` of it (with or without an
    /// index), or a seek on a one-sided range of its key. Not a walk: a limited in-order
    /// read of a partial index (`isLimitedPartialIndexRead`).
    static func mailWalks(plan: [String], sql: String, partialIndexes: Set<String> = []) -> [String] {
        let aliases = tableAliases(sql)
        var walks: [String] = []
        for line in plan {
            guard let match = planLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let verb = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                  let name = Range(match.range(at: 2), in: line).map({ String(line[$0]) }),
                  let rest = Range(match.range(at: 4), in: line).map({ String(line[$0]) }) else { continue }
            let table = mailSized.contains(name) ? name : aliases[name] ?? name
            guard mailSized.contains(table) else { continue }
            if verb == "SCAN" {
                if isLimitedPartialIndexRead(rest: rest, plan: plan, sql: sql, partialIndexes: partialIndexes) { continue }
                walks.append("SCAN \(table)")
            } else if keyRangeOnly.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil {
                walks.append("a cursor walk of \(table) (\(rest.trimmingCharacters(in: .whitespaces)))")
            }
        }
        return walks
    }

    /// Pins the plan rules on fixed plan lines, so a rule that stopped matching cannot
    /// pass every statement silently.
    @Test("The plan rules find full scans and cursor walks of mail-sized tables, and nothing else")
    func planRulesAreExact() {
        let sql = "SELECT * FROM messageHeader m JOIN folder f ON f.id = m.folderId WHERE m.rowid > ?"
        #expect(Self.mailWalks(plan: ["SCAN m"], sql: sql) == ["SCAN messageHeader"])
        #expect(Self.mailWalks(plan: ["SCAN messageHeader USING COVERING INDEX messageHeader_date"], sql: sql) == ["SCAN messageHeader"])
        #expect(Self.mailWalks(plan: ["SEARCH m USING INTEGER PRIMARY KEY (rowid>?)"], sql: sql).count == 1)
        #expect(Self.mailWalks(plan: ["SEARCH messageBody USING INDEX sqlite_autoindex_messageBody_1 (id<?)"], sql: "DELETE FROM messageBody WHERE id < ?").count == 1)
        #expect(Self.mailWalks(plan: ["SCAN f"], sql: sql).isEmpty, "folder is bounded")
        #expect(Self.mailWalks(plan: ["SEARCH m USING INDEX messageHeader_folderId_date (folderId=?)"], sql: sql).isEmpty)
        #expect(Self.mailWalks(plan: ["SEARCH m USING INTEGER PRIMARY KEY (rowid>? AND rowid<?)"], sql: sql).isEmpty,
                "a two-sided key range is a bounded slice")
        #expect(Self.mailWalks(plan: ["SEARCH m USING INTEGER PRIMARY KEY (rowid=?)"], sql: sql).isEmpty)
        #expect(Self.mailWalks(plan: ["SCAN CONSTANT ROW", "SCAN recentInbox"], sql: sql).isEmpty)

        let partial: Set<String> = ["messageHeader_embeddingIncomplete"]
        let limited = "SELECT id FROM messageHeader WHERE embeddingComplete = 0 ORDER BY date DESC LIMIT 500"
        let partialScan = "SCAN messageHeader USING INDEX messageHeader_embeddingIncomplete"
        #expect(Self.mailWalks(plan: [partialScan], sql: limited, partialIndexes: partial).isEmpty,
                "an in-order read of a partial index, stopped by LIMIT")
        #expect(Self.mailWalks(plan: [partialScan], sql: "SELECT id FROM messageHeader WHERE embeddingComplete = 0",
                               partialIndexes: partial).count == 1, "no LIMIT: the whole partial set")
        #expect(Self.mailWalks(plan: [partialScan, "USE TEMP B-TREE FOR ORDER BY"], sql: limited,
                               partialIndexes: partial).count == 1, "a sort reads the whole partial set first")
        #expect(Self.mailWalks(plan: ["SCAN messageHeader USING INDEX messageHeader_date"], sql: limited,
                               partialIndexes: partial).count == 1, "a full index is not a partial one")
    }

    /// Pins which preparation errors leave a statement to the registry alone.
    @Test("Only search and memory tables and incomplete fragments are held by the registry alone")
    func registryOnlyIsExact() {
        #expect(Self.isRegistryOnly(["main: no such table: message_meta", "staging: no such table: message_meta"]))
        #expect(Self.isRegistryOnly(["main: no such table: memory_vec"]))
        #expect(Self.isRegistryOnly(["main: incomplete input", "staging: incomplete input"]))
        #expect(!Self.isRegistryOnly(["main: no such table: messageHeaderz"]))
        #expect(!Self.isRegistryOnly(["main: no such column: observedUidValidity"]))
        #expect(!Self.isRegistryOnly(["staging: incomplete input"]))
    }
}
