/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3
import Testing
@testable import TabMail

/// The query fence, plan half. `SEEK`, `N+1` and `SIM` are claims a query plan can refute,
/// so `seekVerdictsHoldInThePlan` explains every complete SQL literal that carries one, as
/// written (comments included), on the real schemas: the main database after every
/// migration and the deferred indexes (`SyncEngine.createDeferredIndexes`), the
/// notification extension's staging database, and the attachment manifest. Each statement
/// is explained twice, every placeholder bound to `%x` and then to `*x` (a leading `LIKE`
/// and `GLOB` wildcard), in two statistics regimes, and every plan must pass
/// `QueryPlanRules`. Literals with interpolations are held by the registry and review
/// only (their note names the shape; any edit changes their key). So are, by name, the
/// statements of the search index and chat memory databases (no test-built schema here)
/// and the fragments the code completes at run time.
extension DatabaseIndexTests {

    // MARK: - The shared plan reader

    /// The query plan of every statement of `sql`, in order, with that statement's text.
    /// Every placeholder is bound to `bind`; the count comes from the prepared statement,
    /// so a `?` inside a literal or a comment is not counted and a numbered or named
    /// parameter is. SQLite may plan a statement by its bound values (a `LIKE` or `GLOB`
    /// prefix), so a plan holds for that value only.
    static func queryPlans(_ db: Database, _ sql: String, bind: String = "x") throws -> [(sql: String, rows: [QueryPlanRules.PlanRow])] {
        var plans: [(sql: String, rows: [QueryPlanRules.PlanRow])] = []
        for statement in try Array(db.allStatements(sql: sql)) {
            let explain = try db.makeStatement(sql: "EXPLAIN QUERY PLAN " + statement.sql)
            let count = Int(sqlite3_bind_parameter_count(explain.sqliteStatement))
            explain.setUncheckedArguments(StatementArguments(Array(repeating: bind, count: count)))
            let rows = try Row.fetchAll(explain).map { row in
                QueryPlanRules.PlanRow(id: row["id"], parent: row["parent"], detail: row["detail"])
            }
            plans.append((statement.sql, rows))
        }
        return plans
    }

    // MARK: - Schemas and statistics

    /// The statistics the planner works from. `noStatistics` is a fresh database (the
    /// migrations' `ANALYZE` ran on empty tables, which leaves no rows in `sqlite_stat1`, so
    /// SQLite assumes its defaults), with the deferred indexes built as the first
    /// maintenance pass builds them; `largeMailbox` installs statistics for ADR-IOS-029's
    /// large profile, as the maintenance `ANALYZE` would leave them on a device with that
    /// much mail.
    enum StatisticsRegime: String, CaseIterable, Sendable {
        case noStatistics
        case largeMailbox
    }

    struct FenceSchema {
        let name: String
        let queue: DatabaseQueue
        let facts: QueryPlanRules.SchemaFacts
    }

    enum FenceSetupError: Error, CustomStringConvertible {
        case staging

        var description: String { "the notification extension's staging database could not be created" }
    }

    /// The three databases whose schemas the tests can build from production code.
    static func fenceSchemas(_ regime: StatisticsRegime, stagingDirectory: URL) throws -> [FenceSchema] {
        let main = try TestDatabase.make()
        try main.write { try SyncEngine.createDeferredIndexes($0) }

        let stagingPath = stagingDirectory.appendingPathComponent("nse_staging.sqlite").path
        guard AppDatabase.createNSEStagingDB(atPath: stagingPath) else { throw FenceSetupError.staging }
        let staging = try DatabaseQueue(path: stagingPath)
        // The columns and the table the extension adds on its own side.
        NSEStagingDB.ensureObservedUidValidityColumn(db: staging)
        NSEStagingDB.ensureProviderDateColumn(db: staging)
        NSEBadge.markCounted(db: staging, ids: ["query-fence"])

        let manifest = try BodyAssetStore._makeTestQueue()

        var schemas: [FenceSchema] = []
        for (name, queue) in [("main", main), ("staging", staging), ("manifest", manifest)] {
            if regime == .largeMailbox { try queue.write { try Self.installLargeMailboxStatistics($0) } }
            schemas.append(FenceSchema(name: name, queue: queue, facts: try queue.read { try QueryPlanRules.SchemaFacts.load($0) }))
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

    /// What a schema's `sqlite_stat1` says, for the regime check: the tables it has a row
    /// for, and the largest row count it gives `messageHeader` (nil when none; a partial
    /// index's row holds fewer rows than the table's).
    static func statistics(_ db: Database) throws -> (tables: Set<String>, headerRows: Int?) {
        guard try db.tableExists("sqlite_stat1") else { return ([], nil) }
        var tables: Set<String> = []
        var headerRows: Int?
        for row in try Row.fetchAll(db, sql: "SELECT tbl, stat FROM sqlite_stat1") {
            let table: String = row["tbl"]
            tables.insert(table)
            let stat: String? = row["stat"]
            if table == "messageHeader", let count = stat?.split(separator: " ").first.flatMap({ Int($0) }) {
                headerRows = max(headerRows ?? 0, count)
            }
        }
        return (tables, headerRows)
    }

    /// Nil when `schemas` carry `regime`'s statistics, else what is wrong. A fresh database
    /// has no statistics for a mail-sized table (they are empty when the migrations'
    /// `ANALYZE` runs); the large-mailbox one has a row for every table, and `messageHeader`'s
    /// count is the profile's.
    static func regimeProblem(_ regime: StatisticsRegime, _ schemas: [FenceSchema]) throws -> String? {
        for schema in schemas {
            let found = try schema.queue.read { try Self.statistics($0) }
            switch regime {
            case .noStatistics:
                let mail = found.tables.intersection(QueryPlanRules.mailSized)
                if !mail.isEmpty { return "\(schema.name) has statistics for \(mail.sorted())" }
            case .largeMailbox:
                let tables = try schema.queue.read {
                    try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                }
                let missing = Set(tables).subtracting(found.tables)
                if !missing.isEmpty { return "\(schema.name) has no statistics for \(missing.sorted())" }
                if schema.name == "main", found.headerRows != largeMailboxRows["messageHeader"] {
                    return "main gives messageHeader \(found.headerRows.map(String.init) ?? "no") rows"
                }
            }
        }
        return nil
    }

    @Test("Each statistics regime carries its own statistics", arguments: StatisticsRegime.allCases)
    func regimesCarryTheirStatistics(_ regime: StatisticsRegime) throws {
        let directory = try Self.makeFenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemas = try Self.fenceSchemas(regime, stagingDirectory: directory)
        let problem = try Self.regimeProblem(regime, schemas)
        #expect(problem == nil, "\(problem ?? "")")
        // The other regime's check refuses these schemas, so the check reads the statistics.
        let other: StatisticsRegime = regime == .noStatistics ? .largeMailbox : .noStatistics
        let otherProblem = try Self.regimeProblem(other, schemas)
        #expect(otherProblem != nil, "the \(other.rawValue) check passed \(regime.rawValue) schemas")
    }

    static func makeFenceDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Explaining a site

    enum Explained {
        /// The schema that prepared the SQL, and each statement's text with its two plans.
        case plans(FenceSchema, [(sql: String, plans: [[QueryPlanRules.PlanRow]])])
        case unprepared([String])
    }

    /// The placeholder values each statement is explained with.
    static let fenceBinds = ["%x", "*x"]

    /// The plans of `sql` on the first schema that prepares it.
    static func explain(_ sql: String, in schemas: [FenceSchema]) -> Explained {
        var errors: [String] = []
        for schema in schemas {
            do {
                let statements = try schema.queue.inDatabase { db -> [(sql: String, plans: [[QueryPlanRules.PlanRow]])] in
                    let byBind = try fenceBinds.map { try Self.queryPlans(db, sql, bind: $0) }
                    return byBind[0].indices.map { index in
                        (sql: byBind[0][index].sql, plans: byBind.map { $0[index].rows })
                    }
                }
                return .plans(schema, statements)
            } catch let error as DatabaseError {
                errors.append("\(schema.name): \(error.message ?? "\(error)")")
            } catch {
                errors.append("\(schema.name): \(error)")
            }
        }
        return .unprepared(errors)
    }

    /// A statement that reads or writes rows, after any leading comments.
    static func isDML(_ sql: String) -> Bool {
        let masked = QueryPlanRules.string(QueryPlanRules.mask(sql))
        return masked.range(of: #"^\s*(SELECT|INSERT|UPDATE|DELETE|WITH|REPLACE)\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Statements the plan cannot reach, by name

    /// The files that open the search index and the chat memory databases, with the tables
    /// of that database. This suite builds neither schema, so a statement in one of these
    /// files that SQLite refuses for one of these tables is held by the registry alone.
    static let separateDatabaseTables: [String: NSRegularExpression] = [
        "TabMail/Services/Search/SearchIndex.swift": QueryPlanRules.regex(#"^(?:message_meta|message_ids|messages_vec|messages_fts_\w+)$"#),
        "TabMail/Services/Search/MemoryIndex.swift": QueryPlanRules.regex(#"^(?:memory_meta|memory_fts|memory_vec)$"#),
    ]

    /// The literals the code completes at run time (an `IN (` list of placeholders), by file
    /// and declaration: SQLite reports them as `incomplete input`.
    static let runtimeCompletedFragments: Set<String> = [
        "TabMail/Helpers/ThreadUtils.swift\tThreadUtils.insertMessageReferences",
        "TabMail/Services/Sync/SyncEngineFTS.swift\tSyncEngine.reindexAndRequeueBodies",
        "TabMail/Services/Sync/SyncEngineFTS.swift\tSyncEngine.selfHealBackfillFTSMembership",
    ]

    /// Whether a statement no test schema prepares is one of the named ones above. Any
    /// other preparation error fails the fence.
    static func isHeldByTheRegistry(file: String, context: String, errors: [String]) -> Bool {
        guard let mainError = errors.first(where: { $0.hasPrefix("main: ") }) else { return false }
        if mainError == "main: incomplete input" { return runtimeCompletedFragments.contains(file + "\t" + context) }
        let missingTable = "main: no such table: "
        guard mainError.hasPrefix(missingTable), let tables = separateDatabaseTables[file] else { return false }
        var table = String(mainError.dropFirst(missingTable.count))
        if table.hasPrefix("main.") { table.removeFirst("main.".count) }
        return QueryPlanRules.matches(tables, table)
    }

    // MARK: - The plan check

    /// The verdicts a plan can refute.
    static func isPlanChecked(_ verdict: String) -> Bool {
        verdict == "SEEK" || verdict.hasPrefix("N+1: ") || verdict.hasPrefix("SIM: ")
    }

    struct PlanCheck {
        /// Sites whose SQL prepared on a schema.
        var explained = 0
        /// The SQL of every site sent to SQLite, in registry order.
        var reached: [String] = []
        /// Sites whose plan reads a mail-sized set with no stop.
        var walks: [String] = []
        /// Sites no schema prepares that are not held by the registry by name.
        var unexplained: [String] = []
    }

    /// Explains the SQL of every `sql` row with a plan-checked verdict whose site is a
    /// complete literal (no interpolation) that reads or writes rows.
    static func checkPlans(entries: [RegistryEntry], sites: [String: QueryCensusScanner.Site], schemas: [FenceSchema]) -> PlanCheck {
        var check = PlanCheck()
        for entry in entries where entry.kind == "sql" && isPlanChecked(entry.verdict) {
            // A row with no site is reported by `everySiteIsRegistered`.
            guard let site = sites[entry.key], !site.sql.contains("\\("), isDML(site.sql) else { continue }
            check.reached.append(site.sql)
            switch explain(site.sql, in: schemas) {
            case .plans(let schema, let statements):
                check.explained += 1
                var found: [String] = []
                for statement in statements {
                    for (bind, plan) in zip(fenceBinds, statement.plans) {
                        for finding in QueryPlanRules.findings(plan: plan, sql: statement.sql, schema: schema.facts) {
                            let line = "[\(bind)] \(finding)"
                            if !found.contains(line) { found.append(line) }
                        }
                    }
                }
                if !found.isEmpty {
                    let plan = statements.flatMap { $0.plans.first ?? [] }.map(\.detail).joined(separator: " | ")
                    check.walks.append("""
                        \(site.file):\(site.line) \(site.context) [\(entry.verdict)] on \(schema.name): \(found.joined(separator: "; "))
                            \(site.sql.prefix(240))
                            plan: \(plan)
                        """)
                }
            case .unprepared(let errors):
                if !isHeldByTheRegistry(file: site.file, context: site.context, errors: errors) {
                    check.unexplained.append("\(site.file):\(site.line) \(site.context): \(site.sql.prefix(200))\n    \(errors.joined(separator: "\n    "))")
                }
            }
        }
        return check
    }

    @Test("SEEK, N+1 and SIM verdicts hold in the query plan", arguments: StatisticsRegime.allCases)
    func seekVerdictsHoldInThePlan(_ regime: StatisticsRegime) throws {
        let directory = try Self.makeFenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemas = try Self.fenceSchemas(regime, stagingDirectory: directory)
        let regimeProblem = try Self.regimeProblem(regime, schemas)
        #expect(regimeProblem == nil, "[\(regime.rawValue)] the schemas do not carry the regime's statistics: \(regimeProblem ?? "")")

        var sites: [String: QueryCensusScanner.Site] = [:]
        for site in try QueryCensusScanner.scan(root: Self.repositoryRoot) { sites[site.key] = site }
        let check = Self.checkPlans(entries: try Self.registry(), sites: sites, schemas: schemas)

        #expect(check.explained > 0, "no statement was explained: the registry or the schemas did not load")
        #expect(check.walks.isEmpty, """
            [\(regime.rawValue)] Statements registered SEEK, N+1 or SIM whose plan reads a mail-sized set with \
            no proof that it stops (QueryPlanRules). Fix the query, or file the finding and register it as \
            SCAN #<issue>:
            \(check.walks.joined(separator: "\n"))
            """)
        #expect(check.unexplained.isEmpty, """
            [\(regime.rawValue)] Statements registered SEEK, N+1 or SIM that prepare on none of the test \
            schemas (main, staging, manifest) and are not a named search or memory database statement or \
            run-time fragment:
            \(check.unexplained.joined(separator: "\n"))
            """)
    }

    // MARK: - The plan check on a fixed registry

    /// Runs the plan loop on fixed rows: for each checked verdict one statement that passes
    /// and one that fails; the rows the loop must leave alone; the named waivers and the
    /// errors that are not waived. Asserts which SQL reached SQLite and what each row gave.
    @Test("The plan check sends exactly the checked complete statements to SQLite and judges each")
    func planCheckJudgesAFixedRegistry() throws {
        let directory = try Self.makeFenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schemas = try Self.fenceSchemas(.noStatistics, stagingDirectory: directory)

        var entries: [RegistryEntry] = []
        var sites: [String: QueryCensusScanner.Site] = [:]
        func add(_ sql: String, verdict: String, file: String = "TabMail/Fixture.swift", context: String = "Owner.read",
                 kind: String = "sql", hasSite: Bool = true) {
            let site = QueryCensusScanner.Site(file: file, context: context, kind: kind, text: sql, ordinal: entries.count,
                                               line: entries.count + 1, lastLine: entries.count + 1, sql: kind == "sql" ? sql : "")
            entries.append(RegistryEntry(file: file, context: context, kind: kind, ordinal: entries.count, verdict: verdict,
                                         note: "fixture", text: sql))
            if hasSite { sites[site.key] = site }
        }
        let seekPasses = "SELECT * FROM messageHeader WHERE id = ?"
        let seekFails = "SELECT * FROM messageHeader WHERE folderId = ?"
        let loopPasses = "SELECT * FROM messageBody WHERE id = ?"
        let loopFails = "SELECT id FROM messageHeader WHERE date > ?"
        let simPasses = "SELECT id FROM messageHeader WHERE folderId = ? ORDER BY date DESC LIMIT 50"
        let simFails = "SELECT id FROM messageHeader WHERE folderId = ? AND subject = ? ORDER BY date DESC LIMIT 50"
        let commented = "-- the folder's rows\nSELECT * FROM messageHeader WHERE folderId = ?"
        let globPrefix = "SELECT id FROM messageHeader WHERE rfc822MessageId GLOB ?"
        let searchTable = "SELECT rowid FROM message_ids WHERE headerId = ?"
        let fragment = "SELECT * FROM messageHeader WHERE id IN ("
        let malformed = "SELECT * FROM messageHeader WHERE"
        let misspelled = "SELECT * FROM messageHeaderz WHERE id = ?"
        add(seekPasses, verdict: "SEEK")
        add(seekFails, verdict: "SEEK")
        add(loopPasses, verdict: "N+1: the page")
        add(loopFails, verdict: "N+1: the page")
        add(simPasses, verdict: "SIM: does the folder's date index stop at the limit")
        add(simFails, verdict: "SIM: does the folder's date index stop at the limit")
        add(commented, verdict: "SEEK")
        add(globPrefix, verdict: "SEEK")
        add(searchTable, verdict: "SEEK", file: "TabMail/Services/Search/SearchIndex.swift", context: "SearchIndex.fetch")
        add(searchTable, verdict: "SEEK")
        add(fragment, verdict: "SEEK", file: "TabMail/Services/Sync/SyncEngineFTS.swift", context: "SyncEngine.reindexAndRequeueBodies")
        add(fragment, verdict: "SEEK", file: "TabMail/Services/Sync/SyncEngineFTS.swift", context: "SyncEngine.otherDeclaration")
        add(malformed, verdict: "SEEK")
        add(misspelled, verdict: "SEEK")
        // Left alone: not a plan-checked verdict, an interpolation, a call row, not DML, no site.
        add("DELETE FROM messageHeader", verdict: "SCAN #1")
        add("DELETE FROM messageHeader", verdict: "EXEMPT: wipe")
        add("SELECT * FROM messageHeader WHERE id = \\(id)", verdict: "SEEK")
        add("db.execute(sql: x)", verdict: "SEEK", kind: "call")
        add("CREATE INDEX x ON messageHeader(date)", verdict: "SEEK")
        add("SELECT * FROM messageHeader", verdict: "SEEK", hasSite: false)

        let check = Self.checkPlans(entries: entries, sites: sites, schemas: schemas)

        #expect(check.reached == [seekPasses, seekFails, loopPasses, loopFails, simPasses, simFails, commented, globPrefix,
                                  searchTable, searchTable, fragment, fragment, malformed, misspelled])
        #expect(check.explained == 8)
        // A walk starts with its site's file and line; the fixture's line is its row number.
        let walked = check.walks.map { $0.components(separatedBy: " ").first ?? "" }
        #expect(walked == [2, 4, 6, 7, 8].map { "TabMail/Fixture.swift:\($0)" }, "\(check.walks)")
        #expect(check.walks.last?.contains("[*x]") == true, "the GLOB prefix passes with `%x` and scans with `*x`: \(check.walks)")
        #expect(check.walks.last?.contains("[%x]") == false, "\(check.walks)")
        #expect(check.unexplained.count == 4, "\(check.unexplained)")
        #expect(check.unexplained.filter { $0.contains("TabMail/Fixture.swift") && $0.contains("message_ids") }.count == 1)
        #expect(check.unexplained.filter { $0.contains("otherDeclaration") }.count == 1)
        #expect(check.unexplained.filter { $0.contains(malformed) && $0.contains("incomplete input") }.count == 1)
        #expect(check.unexplained.filter { $0.contains(misspelled) }.count == 1)
    }

    /// Pins the named waivers apart from the loop: which preparation errors leave a
    /// statement to the registry alone.
    @Test("Only the named search and memory statements and run-time fragments are held by the registry alone")
    func registryWaiversAreNamed() {
        let search = "TabMail/Services/Search/SearchIndex.swift"
        let memory = "TabMail/Services/Search/MemoryIndex.swift"
        let fts = "TabMail/Services/Sync/SyncEngineFTS.swift"
        #expect(Self.isHeldByTheRegistry(file: search, context: "SearchIndex.x", errors: ["main: no such table: message_meta", "staging: no such table: message_meta"]))
        #expect(Self.isHeldByTheRegistry(file: search, context: "SearchIndex.x", errors: ["main: no such table: messages_fts_2031"]))
        #expect(Self.isHeldByTheRegistry(file: memory, context: "MemoryIndex.x", errors: ["main: no such table: main.memory_vec"]))
        #expect(Self.isHeldByTheRegistry(file: fts, context: "SyncEngine.selfHealBackfillFTSMembership", errors: ["main: incomplete input"]))
        #expect(!Self.isHeldByTheRegistry(file: memory, context: "MemoryIndex.x", errors: ["main: no such table: message_meta"]),
                "a search table outside the file that opens the search database")
        #expect(!Self.isHeldByTheRegistry(file: "TabMail/Other.swift", context: "Other.x", errors: ["main: no such table: memory_vec"]))
        #expect(!Self.isHeldByTheRegistry(file: search, context: "SearchIndex.x", errors: ["main: no such table: messageHeaderz"]))
        #expect(!Self.isHeldByTheRegistry(file: search, context: "SearchIndex.x", errors: ["main: no such column: observedUidValidity"]))
        #expect(!Self.isHeldByTheRegistry(file: fts, context: "SyncEngine.otherDeclaration", errors: ["main: incomplete input"]))
        #expect(!Self.isHeldByTheRegistry(file: fts, context: "SyncEngine.selfHealBackfillFTSMembership", errors: ["staging: incomplete input"]))
        #expect(!Self.isHeldByTheRegistry(file: fts, context: "SyncEngine.selfHealBackfillFTSMembership", errors: ["main: near \"WHERE\": syntax error"]))
    }

    @Test("A statement that starts with a comment is still a statement that reads rows")
    func leadingCommentsDoNotHideAStatement() {
        #expect(Self.isDML("-- note\nSELECT 1 FROM messageHeader"))
        #expect(Self.isDML("/* note */ DELETE FROM messageHeader WHERE id = ?"))
        #expect(Self.isDML("  with x AS (SELECT 1) SELECT * FROM x"))
        #expect(!Self.isDML("-- SELECT\nCREATE INDEX i ON messageHeader(date)"))
        #expect(!Self.isDML("PRAGMA table_info(messageHeader)"))
    }

    @Test("The plan reader counts the placeholders SQLite sees, not the question marks in the text")
    func planReaderBindsWhatTheStatementHas() throws {
        let db = try TestDatabase.make()
        let plans = try db.read { db in
            try Self.queryPlans(db, "SELECT id FROM messageHeader WHERE subject = '?' AND id = :id", bind: "x")
        }
        #expect(plans.count == 1)
        guard plans.count == 1 else { return }
        #expect(plans[0].rows.contains { $0.detail.contains("messageHeader") }, "\(plans[0].rows)")
        let two = try db.read { db in
            try Self.queryPlans(db, "SELECT 1 FROM folder WHERE id = ?1; SELECT id FROM messageHeader WHERE id = ?")
        }
        #expect(two.count == 2, "one plan per statement")
    }
}
