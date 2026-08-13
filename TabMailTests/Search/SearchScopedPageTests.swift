/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// `SearchView.recentHeaders` — the page the substring scan runs over, and the
/// query shape that made typing in the Archive folder stall the main thread.
///
/// **What went wrong.** `legacyLocalSearch` expressed its folder scope as one
/// `folderId IN (…)` with `ORDER BY date DESC LIMIT 200`, and it is called
/// SYNCHRONOUSLY on the main actor from `onQueryChanged` — once per keystroke.
/// SQLite cannot satisfy that `ORDER BY` from any index across an `IN`-list: an
/// `IN`-list yields *k separate date-ordered runs* and there is no merge operator
/// to interleave them, so the planner emits `USE TEMP B-TREE FOR ORDER BY`. **The
/// sorter defeats the `LIMIT`** — every row in the scoped folders is materialised
/// and sorted before the first 200 are taken. Scoped to the INBOX folders that is
/// a few thousand rows and invisible; scoped to Archive / Gmail All Mail it is the
/// whole mailbox, and on the reporting device it cost 1.4–1.9 s of main-thread
/// stall per character typed. The *unscoped* ("all" flag) query has no `WHERE`
/// clause at all, so it walks `messageHeader_date` and stops after 200 rows — which
/// is why searching everything stayed fast while searching Archive did not.
///
/// **The invariant these tests pin, stated as a system property:** *selecting the
/// scoped most-recent page returns exactly the page the `IN`-list form returned, and
/// requires SQLite to sort nothing.*
///
/// Both halves are load-bearing and neither implies the other:
///
/// - The **result-set** half is the real risk in this class of fix. A cheaper query
///   shape that quietly returns a different page would silently change what search
///   shows the user, and no perf measurement would catch it. So the page is compared
///   ORDERED, position for position, against the `IN`-list form it replaces — which
///   is the definition of correct here, not an approximation of it.
/// - The **no-sorter** half is what actually fails on the pre-fix code, and it is
///   asserted against the SQL the production function really issued (captured with
///   `db.trace`), not against SQL the test re-derives. A fix that kept the `IN`-list
///   and merely renamed something would not turn it green.
///
/// **Two-sided, so neither half can pass vacuously.**
/// `theInListShapeIsTheOneThatSorts` is the negative control: it asserts the OLD
/// shape's plan *does* contain the sorter through the same predicate. Without it, a
/// `TEMP B-TREE` assertion would also pass if the predicate simply never matched
/// anything — e.g. if a future SQLite spelled the sorter differently. It is also the
/// standing red-first evidence for a shape change, where the pre-fix function does
/// not exist to run: it demonstrates, on the current migrated schema, that the query
/// this fix removed fails the property the fix installs.
///
/// Fixture scale is deliberately small, and that is safe: the plans were confirmed
/// identical at 30 rows without `ANALYZE` and at 250,000 rows with it — `IN`-list
/// sorts, per-folder `= ?` does not. The defect was never scale-dependent in SHAPE,
/// only in COST.
@Suite("Search scoped most-recent page — result set and query plan")
struct SearchScopedPageTests {

    // MARK: - Fixture

    /// Collects the SQL GRDB actually executed. `trace` fires on the database's own
    /// queue, so the buffer is `Mutex`-protected per the project resilience rules.
    ///
    /// ⚠️ Recorded from **`event.expandedDescription`, never `event.description`.**
    /// `TraceEvent.description` returns `expandedSQL` only when the configuration sets
    /// `publicStatementArguments`, and otherwise returns the UNEXPANDED SQL — so it hands
    /// back `WHERE "folderId" = ?` with the bindings stripped. Feeding that to
    /// `EXPLAIN QUERY PLAN` fails with *SQLite error 21: wrong number of statement
    /// arguments: 0*, because SQLite requires parameters bound even when it will only
    /// plan the statement. That is exactly how the first version of this suite failed,
    /// and it failed in BOTH directions at once — the positive assertion and its negative
    /// control errored identically, so the pair proved nothing either way. A plan
    /// assertion that cannot execute is worse than absent: it looks like coverage.
    ///
    /// Substituting the real values as literals does not change the verdict — verified
    /// on the migrated schema with stats cleared, `WHERE "folderId" = ?` and
    /// `WHERE "folderId" = 'literal'` plan identically (`SEARCH … messageHeader_folderId_date`),
    /// as do the two `IN`-list forms (both `USE TEMP B-TREE FOR ORDER BY`). If anything
    /// the literal form is the more faithful probe: an unbound `?` plans as NULL, which
    /// is a value production never passes.
    ///
    /// GRDB documents `expandedDescription` as carrying a sensitive-data warning, since
    /// bound values land in the string. That is acceptable here and nowhere else: this is
    /// a throwaway on-disk test database whose only content is `example.com` fixtures.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        /// Returns the row-selecting statements seen since the last drain, and clears.
        func drainSelects() -> [String] {
            statements.withLock { buffer in
                let all = buffer
                buffer = []
                return all.filter {
                    $0.contains("SELECT") && $0.contains("messageHeader") && $0.contains("ORDER BY")
                }
            }
        }
        func reset() { statements.withLock { $0 = [] } }
    }

    private struct Env {
        let pool: DatabasePool
        let directory: URL
        let tape: SQLTape
        /// Two "archive-like" folders and one inbox, so a scope can be a strict subset.
        let archiveA: String
        let archiveB: String
        let inbox: String
    }

    /// 36 headers round-robined across 3 folders (12 each) with strictly distinct,
    /// descending dates. Round-robin matters: it puts the global newest rows in
    /// DIFFERENT folders, so a per-folder merge that dropped or mis-ordered one arm
    /// cannot coincidentally reproduce the reference page.
    ///
    /// Dates are derived from `Date()` — never hardcoded — so the fixture cannot go
    /// stale.
    private func makeEnv() throws -> Env {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-scoped-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tape = SQLTape()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)

        try pool.write { db in
            var account = Account(
                emailAddress: "user@example.com", displayName: "User", provider: .imap)
            account.id = "acc1"
            try account.insert(db)
        }

        // Paths chosen to mirror the reported scopes without naming any real service.
        let folders = [
            Folder(name: "All Mail", path: "ArchiveA", role: .archive, accountId: "acc1"),
            Folder(name: "Archive", path: "ArchiveB", role: .archive, accountId: "acc1"),
            Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        ]
        try pool.write { db in for f in folders { try f.insert(db) } }

        let now = Date()
        try pool.write { db in
            for i in 0..<36 {
                let folder = folders[i % folders.count]
                var header = MessageHeader(
                    messageId: "\(1000 + i)",
                    subject: "message \(i)",
                    from: "Sender \(i)",
                    fromAddress: "sender\(i)@example.com",
                    to: "user@example.com",
                    date: now.addingTimeInterval(-Double(i) * 60),
                    snippet: "snippet \(i)",
                    folderId: folder.id,
                    accountId: "acc1",
                    folderPath: folder.path,
                    isInInbox: folder.role == .inbox
                )
                header.headerComplete = true
                try header.insert(db)
            }
        }

        return Env(
            pool: pool, directory: directory, tape: tape,
            archiveA: folders[0].id, archiveB: folders[1].id, inbox: folders[2].id)
    }

    private func finish(_ env: Env) {
        try? env.pool.close()
        try? FileManager.default.removeItem(at: env.directory)
    }

    /// The query shape this fix REMOVED, kept here as the reference definition of a
    /// correct page and as the negative control for the plan assertion.
    private func inListPage(
        folderIds: [String], budget: Int
    ) -> QueryInterfaceRequest<MessageHeader> {
        MessageHeader
            .filter(folderIds.contains(Column("folderId")))
            .order(Column("date").desc)
            .limit(budget)
    }

    /// ⚠️ **`sqlite_stat1` MUST be cleared before any plan assertion here, and this is
    /// not boilerplate — it is the instrument check.** `AppDatabase.runMigrations` ends
    /// in `ANALYZE`, and with real statistics on a 36-row table the planner correctly
    /// decides that walking `messageHeader_date` and testing `folderId` per row beats
    /// the sorter — so the `IN`-list shape plans as `SCAN … USING INDEX
    /// messageHeader_date` with **no** `TEMP B-TREE`, and the negative control below
    /// would report that the shipped bug does not exist. Measured, not assumed: at 36
    /// rows *with* stats the `IN`-list does not sort; at 36 rows *without* stats and at
    /// 250,000 rows *with* stats it does. Deciding the plan on the schema alone is what
    /// makes a small fixture speak about the device.
    ///
    /// (That scale-sensitivity is itself consistent with the bug: the sorter is a
    /// large-table decision, and on a 250k-row device BOTH the inbox and the archive
    /// scope get it — the inbox scope is merely cheap, ~7.5k rows, while the archive
    /// scope is the whole mailbox.)
    private func stripStats(_ db: Database) throws {
        if try db.tableExists("sqlite_stat1") {
            try db.execute(sql: "DELETE FROM sqlite_stat1")
        }
    }

    private func plan(_ db: Database, sql: String) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
            .map { $0["detail"] as String }
            .joined(separator: " | ")
    }

    // MARK: - The result-set half

    @Test("Scoped page is the IN-list page, position for position — strict subset scope")
    func scopedPageMatchesInListPageForSubsetScope() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let scope = [env.archiveA, env.archiveB]
        let budget = 5

        try env.pool.read { db in
            let produced = try SearchView.recentHeaders(db, folderIds: scope, budget: budget)
            let reference = try inListPage(folderIds: scope, budget: budget).fetchAll(db)

            // A page of exactly `budget` rows, drawn from BOTH scoped folders and from
            // neither the inbox — otherwise the comparison below could hold trivially.
            #expect(produced.count == budget)
            #expect(reference.count == budget)
            #expect(Set(produced.map(\.folderId)) == Set(scope))
            #expect(!produced.contains(where: { $0.folderId == env.inbox }))

            #expect(produced.map(\.id) == reference.map(\.id))
            #expect(produced.map(\.date) == reference.map(\.date))
        }
    }

    @Test("Scoped page is the IN-list page when the scope covers every folder")
    func scopedPageMatchesInListPageForFullScope() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let scope = [env.archiveA, env.archiveB, env.inbox]
        let budget = 5

        try env.pool.read { db in
            let produced = try SearchView.recentHeaders(db, folderIds: scope, budget: budget)
            let reference = try inListPage(folderIds: scope, budget: budget).fetchAll(db)
            #expect(produced.count == budget)
            #expect(Set(produced.map(\.folderId)).count == 3)
            #expect(produced.map(\.id) == reference.map(\.id))
        }
    }

    @Test("A scope smaller than the budget returns that folder's whole tail, still ordered")
    func scopeSmallerThanBudgetIsNotTruncatedOrReordered() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let scope = [env.inbox]
        let budget = 200  // larger than the 12 rows the folder holds

        try env.pool.read { db in
            let produced = try SearchView.recentHeaders(db, folderIds: scope, budget: budget)
            let reference = try inListPage(folderIds: scope, budget: budget).fetchAll(db)
            #expect(produced.count == 12)
            #expect(produced.map(\.id) == reference.map(\.id))
            #expect(produced.map(\.date) == produced.map(\.date).sorted(by: >))
        }
    }

    @Test("Unscoped page is unchanged — the 'all' flag path keeps its shipped behaviour")
    func unscopedPageIsUnchanged() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let budget = 5

        try env.pool.read { db in
            let produced = try SearchView.recentHeaders(db, folderIds: nil, budget: budget)
            let reference = try MessageHeader
                .order(Column("date").desc).limit(budget).fetchAll(db)
            #expect(produced.map(\.id) == reference.map(\.id))

            // nil and [] are the same request: `legacyLocalSearch` treats an empty
            // scope as "no scope", and that must not silently become "no rows".
            let emptyScope = try SearchView.recentHeaders(db, folderIds: [], budget: budget)
            #expect(emptyScope.map(\.id) == reference.map(\.id))
        }
    }

    // MARK: - The no-sorter half

    /// Plans every statement in `issued`, with `sqlite_stat1` cleared first.
    ///
    /// **Both halves of the pair go through THIS function and nothing else.** That is
    /// deliberate: a control only controls if it fails through the same predicate the
    /// assertion passes through. The first version of this suite got that wrong in a way
    /// worth remembering — the positive test captured its SQL from `db.trace` while the
    /// control took a different route through `makePreparedRequest`, and when a single
    /// shared defect (unbound `?` placeholders) broke both, the two failed *identically*
    /// and the pair proved nothing in either direction. Same predicate, one variable —
    /// the query shape — is what makes the control mean anything.
    private func planAll(_ env: Env, issued: [String]) throws -> [String] {
        try env.pool.write { db in
            try stripStats(db)
            return try issued.map { try plan(db, sql: $0) }
        }
    }

    @Test("No statement the scoped page issues requires SQLite to sort")
    func scopedPageIssuesNoSorter() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let scope = [env.archiveA, env.archiveB]

        // Capture the SQL the PRODUCTION function really executed.
        env.tape.reset()
        let issued: [String] = try env.pool.read { db in
            _ = try SearchView.recentHeaders(
                db, folderIds: scope, budget: SearchConfig.legacySubstringScanRows)
            return env.tape.drainSelects()
        }

        // One statement per scoped folder — the shape itself, not just its cost. This
        // also proves the capture worked at all, so an empty `issued` cannot make the
        // per-statement assertions below pass by iterating over nothing.
        #expect(issued.count == scope.count)
        #expect(!issued.contains(where: { $0.contains(" IN (") }))

        for detail in try planAll(env, issued: issued) {
            #expect(
                !detail.contains("TEMP B-TREE"),
                "scoped page statement plans with a sorter — the LIMIT cannot early-terminate: \(detail)")
            #expect(
                detail.contains("messageHeader_folderId_date"),
                "scoped page statement no longer rides the (folderId, date) composite: \(detail)")
        }
    }

    @Test("NEGATIVE CONTROL: the IN-list shape is the one that sorts")
    func theInListShapeIsTheOneThatSorts() throws {
        let env = try makeEnv()
        defer { finish(env) }
        let scope = [env.archiveA, env.archiveB]

        // Captured the SAME way as the assertion above — by EXECUTING the shape under
        // trace — so the only difference between the two tests is the query shape.
        env.tape.reset()
        let issued: [String] = try env.pool.read { db in
            _ = try inListPage(
                folderIds: scope, budget: SearchConfig.legacySubstringScanRows).fetchAll(db)
            return env.tape.drainSelects()
        }

        // The `IN`-list is ONE statement where the fix issues one per folder.
        #expect(issued.count == 1)
        #expect(issued.first?.contains(" IN (") == true)

        let details = try planAll(env, issued: issued)
        #expect(details.count == 1)

        // If this ever stops holding, the assertion in `scopedPageIssuesNoSorter`
        // has stopped being able to fail and must be re-derived before it is
        // trusted again — not merely left green.
        #expect(
            details.first?.contains("TEMP B-TREE") == true,
            "the IN-list shape no longer sorts, so the no-sorter assertion is now vacuous: \(details)")
    }
}
