# 160. Every database query site has a verdict in the query registry, and its plan is checked

**Rule.** Every database query site of the app, the notification extension and `Shared` has exactly one row
in `TabMailTests/Database/QueryFence/query-registry.tsv` saying why it does not read a set that grows with
the user's mail, or which open issue describes it. A new or changed query fails
`DatabaseIndexTests.everySiteIsRegistered` until its row is written, and every `sql` row with a `SEEK`,
`N+1` or `SIM` verdict whose statement is a complete literal is explained on the migration-built schema,
with and without planner statistics (`seekVerdictsHoldInThePlan`).

**Why.** A full read of a mail-sized table costs nothing on a test mailbox and seconds on a large one, and
it hides in rare paths (maintenance passes, start-up one-shots, Settings actions) as well as hot ones. A
census made once goes stale with the next query; a fence in the test suite makes every new query get a
verdict in review, and the plan check keeps a `SEEK` verdict from outliving the index it relied on.

## How to apply

1. **When a test names an unregistered site,** add one row: `file`, `context`, `kind`, `ordinal` and `text`
   exactly as the failure prints them, a verdict and a note that says why. The vocabulary is in the doc
   comment of `DatabaseIndexTests+QueryRegistry.swift`: `SEEK`, `BOUNDED: <bound>`, `N+1: <bound>`,
   `SIM: <question>`, `SCAN #<issue>`, `STOPS: <Suite.test>`, `EXEMPT: <reason>` from a fixed list, and
   `NOT-A-QUERY`. Rows are sorted by file, in scan order within a file.
2. **A stale row** (its site is gone or changed) is updated or removed in the same change. An edit above a
   site, or of its declaration, keeps its key; an edit of what it queries changes exactly its key.
3. **A query that does read a mail-sized set** is filed as its own issue first and registered as
   `SCAN #<issue>`; when that issue is fixed, its rows get the verdict of the fixed code.
4. **A walk that stops once it has what it needs** (no `LIMIT` in the statement, the code stops the cursor)
   is `STOPS: <Suite.test>`, naming a `@Test` that measures that its work does not grow with the set;
   `everyStopsVerdictNamesATest` fails when that test is renamed or removed.
5. **The mail-sized tables and what passes the plan check** live in `QueryPlanRules.swift`: a point read on
   an identity column, a range bounded on both sides, a set read only with a positive `LIMIT` and no
   `OFFSET`, no sort and no residual filter, a `COUNT`, or a lone `MIN`/`MAX`. The search and memory
   databases are separate files and are waived from the plan check (`separateDatabaseTables`).

Related: [ADR-IOS-029](../../Decisions/Active/adr-ios-029.md) (purpose-built indexes, drop what is superseded),
[159](159-prove-a-query-change-with-the-dbproof-harness.md) (proving a query change with numbers).
