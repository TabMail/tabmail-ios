/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The query fence, registry half. Every database query site of the production sources
/// (found by `QueryCensusScanner`: the app, the notification extension and `Shared`) has
/// exactly one row in `query-registry.tsv`, next to this file, saying why it does not read
/// a set that grows with the user's mail, or which filed issue describes it. A new or
/// changed query fails `everySiteIsRegistered` until its row is written, so every query
/// gets a verdict in review. The plan half is `DatabaseIndexTests+QueryPlanFence.swift`.
///
/// The bar: no query reads a set that grows with the user's mail, on any path (hot, rare,
/// one-shot, maintenance). It seeks through an index, or reads a table that is provably
/// small. A whole-folder or whole-inbox read through an index still grows with mail, and so
/// does a sort, an `OFFSET` or a key-range walk over a mail-sized set.
///
/// Verdicts (column `verdict`, one per row):
/// - `SEEK`: every statement the site runs seeks through an index, or writes one row by key.
/// - `BOUNDED: <bound>`: reads a provably small set; the bound is named (accounts,
///   folders, a capped table, a configured limit).
/// - `N+1: <bound>`: one seeking statement per item of a loop whose items are bounded.
/// - `SIM: <question>`: an index exists; whether the planner takes it is settled by the
///   plan check.
/// - `SCAN #<issue>`: one of the statements a filed issue describes.
/// - `STOPS: <Suite.test>`: a walk over a mail-sized set that stops once it has what it
///   needs; the named `@Test` measures that its work does not grow with the set.
/// - `EXEMPT: <reason>`, the reason one of: `wipe` (deletes everything by design: account
///   removal, sign-out, a Settings clear), `user rebuild` (the user asked to rebuild
///   everything), `debug/test scene` (`#if DEBUG` or a UI-test scene), `debug tool` (runs
///   only from the hidden debug menu or while debug logging is switched on), `demo` (the
///   demo account's own data), `test-only` (no production caller), `search by method` (the
///   AI email search and the chat memory search read every candidate by design), `shipped
///   migration` (a registered migration: frozen once released), `inherent: <why>`, or
///   `shipped one-shot: <name>` (a startup one-shot every device past it already ran).
/// - `NOT-A-QUERY`: runs no statement (transaction control, a pass-through, a same-named
///   method that is not GRDB's).
///
/// A `sql` row carries the statement's plan obligation (the plan half checks it); the `call`
/// row of the code that runs it carries how often and where (a loop makes it `N+1`, a
/// forwarder runs it on another path), so a literal run once has the same verdict on both.
extension DatabaseIndexTests {

    // MARK: - Registry rows

    struct RegistryEntry: Sendable, Equatable {
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

    enum RegistryError: Error, CustomStringConvertible, Equatable {
        case malformedRow(line: Int, text: String)

        var description: String {
            switch self {
            case .malformedRow(let line, let text):
                "query-registry.tsv line \(line) is not the header or 7 tab-separated fields with an integer ordinal: \(text.prefix(200))"
            }
        }
    }

    static let registryHeader = "file\tcontext\tkind\tordinal\tverdict\tnote\ttext"

    static var queryFenceDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    static var registryURL: URL { queryFenceDirectory.appendingPathComponent("query-registry.tsv") }

    static var repositoryRoot: URL {
        queryFenceDirectory
            .deletingLastPathComponent() // Database
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repository root
    }

    /// The rows of a registry text. A wrong header, a row that is not 7 tab-separated
    /// fields, or an ordinal that is not an integer throws, naming its line.
    static func parseRegistry(_ text: String) throws -> [RegistryEntry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first, header == registryHeader else {
            throw RegistryError.malformedRow(line: 1, text: lines.first.map(String.init) ?? "")
        }
        return try lines.dropFirst().enumerated().map { index, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let ordinal = Int(fields[3]) else {
                throw RegistryError.malformedRow(line: index + 2, text: String(line))
            }
            return RegistryEntry(file: fields[0], context: fields[1], kind: fields[2], ordinal: ordinal,
                                 verdict: fields[4], note: fields[5], text: fields[6])
        }
    }

    static func registry() throws -> [RegistryEntry] {
        try parseRegistry(String(contentsOf: registryURL, encoding: .utf8))
    }

    // MARK: - Comparing the scan with the registry

    struct RegistryDiff: Equatable {
        /// Sites with no row.
        var unregistered: [String] = []
        /// Rows with no site (the site is gone or changed).
        var stale: [String] = []
        /// Rows listed more than once.
        var duplicated: [String] = []
        /// Rows whose verdict is outside the vocabulary, or whose note is blank.
        var malformed: [String] = []
    }

    static func compare(sites: [QueryCensusScanner.Site], entries: [RegistryEntry]) -> RegistryDiff {
        let scanned = Set(sites.map(\.key))
        let registered = Set(entries.map(\.key))
        var diff = RegistryDiff()
        diff.unregistered = sites.filter { !registered.contains($0.key) }
            .map { "\($0.file):\($0.line) [\($0.kind)] \($0.context): \($0.text.prefix(160))" }
        diff.stale = entries.filter { !scanned.contains($0.key) }.map(\.label)
        var seen: Set<String> = []
        var reported: Set<String> = []
        for entry in entries where !seen.insert(entry.key).inserted && reported.insert(entry.key).inserted {
            diff.duplicated.append(entry.label)
        }
        diff.malformed = entries
            .filter { !isWellFormed($0.verdict) || $0.note.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.verdict) | \($0.note) | \($0.label)" }
        return diff
    }

    @Test("Every query site of the production sources has exactly one registry row, and every row a site")
    func everySiteIsRegistered() throws {
        let diff = Self.compare(sites: try QueryCensusScanner.scan(root: Self.repositoryRoot), entries: try Self.registry())
        #expect(diff.unregistered.isEmpty, """
            Query sites with no row in TabMailTests/Database/QueryFence/query-registry.tsv. Add one row per \
            site with its verdict (vocabulary: DatabaseIndexTests+QueryRegistry.swift):
            \(diff.unregistered.joined(separator: "\n"))
            """)
        #expect(diff.stale.isEmpty, """
            Registry rows whose site is gone or changed (file, context, kind, ordinal and text must match \
            the source). Update or remove them:
            \(diff.stale.joined(separator: "\n"))
            """)
        #expect(diff.duplicated.isEmpty, "Registry rows listed twice:\n\(diff.duplicated.joined(separator: "\n"))")
    }

    // MARK: - Verdicts are from the vocabulary

    static let verdictGrammar = QueryPlanRules.regex(
        #"^(SEEK|NOT-A-QUERY|SCAN #[0-9]+|STOPS: [A-Za-z_]\w*\.[A-Za-z_]\w*|(BOUNDED|N\+1|SIM): \S.*|EXEMPT:(wipe|user rebuild|debug/test scene|debug tool|demo|test-only|search by method|shipped migration|(inherent|shipped one-shot): \S.*))$"#)

    static func isWellFormed(_ verdict: String) -> Bool { QueryPlanRules.matches(verdictGrammar, verdict) }

    @Test("Every registry row carries one verdict from the vocabulary and a note")
    func everyVerdictIsWellFormed() throws {
        let malformed = Self.compare(sites: [], entries: try Self.registry()).malformed
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
                        "SIM: does the range seek", "EXEMPT: wipe", "EXEMPT: user rebuild", "EXEMPT: debug/test scene",
                        "EXEMPT: debug tool", "EXEMPT: demo", "EXEMPT: test-only", "EXEMPT: search by method",
                        "EXEMPT: shipped migration", "EXEMPT: inherent: why", "EXEMPT: shipped one-shot: name",
                        "STOPS: WalkTests.walkStops"] {
            #expect(Self.isWellFormed(verdict), "\(verdict) is part of the vocabulary")
        }
        for verdict in ["", "SEEK ", " SEEK", "SCAN", "SCAN #", "SCAN #12a", "SCAN-CANDIDATE: messageHeader", "BOUNDED:",
                        "BOUNDED: ", "EXEMPT: other", "EXEMPT: inherent:", "EXEMPT: wipe ", "seek", "SIM:question",
                        "N+1 the page size", "STOPS:", "STOPS: ", "STOPS: walkStops", "STOPS: WalkTests.",
                        "STOPS: WalkTests.walkStops()", "STOPS: WalkTests.walkStops extra", "STOPS: A.b.c"] {
            #expect(!Self.isWellFormed(verdict), "\(verdict) is not part of the vocabulary")
        }
    }

    // MARK: - A STOPS verdict names its workload test

    static let stopsVerdict = QueryPlanRules.regex(#"^STOPS: ([A-Za-z_]\w*)\.([A-Za-z_]\w*)$"#)

    /// Whether `source` declares or extends `suite` and has a `@Test` function named `test`:
    /// the nearest `@Test` before that `func` comes after every earlier `func`, so the
    /// attribute is that function's. Both names are identifiers (the verdict grammar).
    static func declaresTest(_ source: String, suite: String, test: String) -> Bool {
        let suiteDeclaration = QueryPlanRules.regex(#"\b(?:struct|class|enum|actor|extension)\s+"# + suite + #"(?:\s*[:{<]|\s+where\b)"#)
        guard QueryPlanRules.matches(suiteDeclaration, source) else { return false }
        let text = source as NSString
        for function in QueryPlanRules.allMatches(QueryPlanRules.regex(#"\bfunc\s+"# + test + #"\s*\("#), source) {
            let before = text.substring(to: function.location) as NSString
            let attribute = before.range(of: "@Test", options: .backwards).location
            let earlierFunction = before.range(of: "func ", options: .backwards).location
            if attribute != NSNotFound && (earlierFunction == NSNotFound || earlierFunction < attribute) { return true }
        }
        return false
    }

    /// The text of every Swift file under TabMailTests.
    static func testSources() throws -> [String] {
        let base = repositoryRoot.appendingPathComponent("TabMailTests")
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var sources: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append(try String(contentsOf: url, encoding: .utf8))
        }
        return sources
    }

    @Test("Every STOPS verdict names a @Test function of its suite in TabMailTests")
    func everyStopsVerdictNamesATest() throws {
        let named = Set(try Self.registry().map(\.verdict).filter { QueryPlanRules.matches(Self.stopsVerdict, $0) })
        let sources = try Self.testSources()
        #expect(sources.count > 1)
        let missing = named.sorted().filter { verdict in
            guard let groups = QueryPlanRules.firstMatch(Self.stopsVerdict, verdict),
                  let suite = groups[1], let test = groups[2] else { return true }
            return !sources.contains { Self.declaresTest($0, suite: suite, test: test) }
        }
        #expect(missing.isEmpty, """
            STOPS verdicts whose test is not a @Test function of that suite in TabMailTests (renamed or removed?):
            \(missing.joined(separator: "\n"))
            """)
    }

    /// Pins the lookup, so a lookup that found any name would not let every STOPS verdict through.
    @Test("A STOPS test is found only as a @Test function in a file of its suite")
    func stopsTestLookupIsExact() {
        let source = """
            @Suite(.serialized)
            struct WalkTests {
                @Test("The walk stops")
                @MainActor
                func walkStops() throws {}

                func helper() {}
            }
            """
        #expect(Self.declaresTest(source, suite: "WalkTests", test: "walkStops"))
        #expect(!Self.declaresTest(source, suite: "WalkTests", test: "helper"), "a function with no @Test")
        #expect(!Self.declaresTest(source, suite: "OtherTests", test: "walkStops"), "a file of another suite")
        #expect(!Self.declaresTest(source, suite: "WalkTests", test: "walk"), "a prefix of a test name")
        #expect(!Self.declaresTest(source, suite: "Walk", test: "walkStops"), "a prefix of a suite name")
    }

    // MARK: - The comparison on fixed registries

    static func fixtureSite(_ text: String, context: String = "Owner.read", ordinal: Int = 0, line: Int = 1) -> QueryCensusScanner.Site {
        QueryCensusScanner.Site(file: "TabMail/Fixture.swift", context: context, kind: "sql", text: text, ordinal: ordinal,
                                line: line, lastLine: line, sql: text)
    }

    static func fixtureRow(_ site: QueryCensusScanner.Site, verdict: String = "SEEK", note: String = "one row by key") -> String {
        [site.file, site.context, site.kind, String(site.ordinal), verdict, note, site.text].joined(separator: "\t")
    }

    static func fixtureRegistry(_ rows: [String]) -> String {
        ([registryHeader] + rows).joined(separator: "\n") + "\n"
    }

    /// Runs the comparator on fixed registries: one defect each, so a comparator that
    /// stopped seeing one kind of defect fails here rather than passing every registry.
    @Test("The registry comparison reports a missing, stale, duplicated, malformed or unexplained row")
    func registryComparisonReportsEachDefect() throws {
        let first = Self.fixtureSite("SELECT * FROM messageHeader WHERE id = ?")
        let second = Self.fixtureSite("SELECT * FROM messageBody WHERE id = ?", line: 2)
        let sites = [first, second]

        let clean = try Self.parseRegistry(Self.fixtureRegistry([Self.fixtureRow(first), Self.fixtureRow(second)]))
        #expect(Self.compare(sites: sites, entries: clean) == RegistryDiff(), "a registry with one good row per site is clean")

        let missing = Self.compare(sites: sites, entries: try Self.parseRegistry(Self.fixtureRegistry([Self.fixtureRow(first)])))
        #expect(missing.unregistered.count == 1 && missing.unregistered[0].contains("messageBody"), "\(missing)")
        #expect(missing.stale.isEmpty && missing.duplicated.isEmpty && missing.malformed.isEmpty)

        let edited = Self.fixtureSite("SELECT * FROM messageBody WHERE id = ? AND 1", line: 2)
        let stale = Self.compare(sites: sites, entries: try Self.parseRegistry(Self.fixtureRegistry(
            [Self.fixtureRow(first), Self.fixtureRow(second), Self.fixtureRow(edited)])))
        #expect(stale.stale.count == 1 && stale.stale[0].contains("AND 1"), "\(stale)")
        #expect(stale.unregistered.isEmpty)

        let twice = Self.compare(sites: sites, entries: try Self.parseRegistry(Self.fixtureRegistry(
            [Self.fixtureRow(first), Self.fixtureRow(second), Self.fixtureRow(second, verdict: "N+1: the page")])))
        #expect(twice.duplicated.count == 1 && twice.duplicated[0].contains("messageBody"), "\(twice)")

        let blankNote = Self.compare(sites: sites, entries: try Self.parseRegistry(Self.fixtureRegistry(
            [Self.fixtureRow(first, note: " "), Self.fixtureRow(second)])))
        #expect(blankNote.malformed.count == 1 && blankNote.malformed[0].contains("messageHeader"), "\(blankNote)")

        let badVerdict = Self.compare(sites: sites, entries: try Self.parseRegistry(Self.fixtureRegistry(
            [Self.fixtureRow(first), Self.fixtureRow(second, verdict: "SCAN-CANDIDATE: messageBody")])))
        #expect(badVerdict.malformed.count == 1 && badVerdict.malformed[0].contains("SCAN-CANDIDATE"), "\(badVerdict)")
    }

    @Test("A registry row that is not 7 fields with an integer ordinal, or a wrong header, is refused with its line")
    func malformedRegistryRowsAreRefused() {
        let site = Self.fixtureSite("SELECT * FROM messageHeader WHERE id = ?")
        let good = Self.fixtureRow(site)
        let sixFields = good.split(separator: "\t", omittingEmptySubsequences: false).dropLast().joined(separator: "\t")
        let badOrdinal = good.replacingOccurrences(of: "\tsql\t0\t", with: "\tsql\tx\t")
        for (row, line) in [(sixFields, 3), (good + "\textra", 3), (badOrdinal, 3)] {
            #expect(throws: RegistryError.malformedRow(line: line, text: row)) {
                try Self.parseRegistry(Self.fixtureRegistry([good, row]))
            }
        }
        #expect(throws: RegistryError.self) {
            try Self.parseRegistry("file\tcontext\tkind\tordinal\tverdict\tnote\n" + good + "\n")
        }
    }
}
