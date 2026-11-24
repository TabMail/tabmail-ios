# 159. Prove a query or index change with the DBProof harness, old against new on one large database

**Rule.** A change to a query, an index, a trigger or a batch writer on a mail-sized table is shown to be
no slower with the shared harness `DBProof` (`TabMailTests/Helpers/DBProofHarness.swift`), not with a
one-off fixture: the same large database, the old and the new statements side by side, both statistics
states, and the counts that do not depend on the machine (pages read, rows visited) next to the time.

**Why.** A timing on a small fixture says nothing about a large inbox, and a single timing on any fixture
is noise. Pages read and rows visited are exact and repeatable, so they show a full scan or a lost index
even when the clock cannot. The query planner also chooses differently with and without `sqlite_stat1`,
and a phone runs both: before the maintenance pass has run `ANALYZE`, and after.

## How to apply

1. **Build the database once.** `DBProof.prepareBase(in: dir, shape: .large)` builds
   `proof-base.sqlite` through the production migrations (`AppDatabase.runMigrations(on:)`) and the
   deferred indexes (`SyncEngine.createDeferredIndexes`), then seeds it deterministically
   (`SeededGenerator`, a fixed seed): four accounts (Gmail, IMAP, Outlook, iCloud), 105,000 headers,
   a realistic inbox share per account, INBOX/Archive/Sent/Trash, read and unread, every action tag
   bucket plus untagged rows, user labels from dense (35%) to rare (0.05%), and a completion mix as on a
   synced phone: 95% of headers `headerComplete = 1`, 85% of those also `bodyComplete = 1`, the rest
   incomplete (`Config.headerCompleteShare`, `Config.bodyCompleteShare`; a body only on a complete
   header). So a read that shows only complete headers (the inbox list, the label walk) returns rows on
   the base as built. The same seed and shape give the same file contents (`DBProof.fingerprint(of:)`,
   which groups by both flags too).
2. **Describe each mode.** A `DBProof.Mode` has a name, a kind (`.read` or `.write`) and an old and a new
   `Variant`. A variant's `setupSQL` runs on its own copy of the base (for example the new index), its
   `sql` is the statements to measure; `run` is for a Swift body when the code under test is not plain
   SQL (the Mac side then skips that entry). A `run` body returns the number of rows its result holds
   (a read) or it wrote (a write): the rows the code under test gets, not a count statement's one row.
   For `sql` the harness counts them itself (rows stepped, rows changed).
3. **Compare.** `DBProof.compare(unit:modes:base:in:statistics:repeats:)` prepares one file per mode,
   statistics state and side (`.none` deletes `sqlite_stat1`/`sqlite_stat4`, `.analyzed` runs `ANALYZE`),
   then measures each on a fresh `DatabasePool` with the app's configuration
   (`AppDatabase.makeConfiguration()`): one warm-up, then old and new interleaved, `repeats` times. A
   write mode runs on an APFS clone per run, inside one transaction including the commit, so the
   prepared file never changes. **An empty comparison is refused:** after the warm-up, `compare` throws
   `DBProofError.resultRows` when either side's result is empty, because two empty results compare as
   equal whatever the statements cost and prove nothing (found 2026-11-24: the base once seeded every
   header `headerComplete = 0`, so an inbox read returned no rows on both sides). A mode that is meant to
   find nothing sets `Mode(..., emptyResult: true)`, and then both sides must be empty. The report
   prints the result rows of each side.
4. **Read the report.** `<dir>/<unit>/report.txt` gives, per mode and statistics state: median and p90
   time, the spread (p90 - p10) of the old runs as the noise, and pages read (`SQLITE_DBSTATUS_CACHE_MISS`),
   pages written (`CACHE_WRITE`), VM steps, full-scan steps, sorts and automatic-index inserts, summed
   over every statement the body ran (`sqlite3_stmt_status` read in a `SQLITE_TRACE_PROFILE` callback;
   GRDB's own trace does not expose the statement handle). Time is `SLOWER` only when the new median is
   above the old median by more than the noise; counts are compared exactly (`MORE`/`fewer`/`same`).
5. **Repeat on the Mac.** `python3 -I Scripts/db-proof-mac.py <dir>/<unit>` runs the same statements on
   the same files with the Mac's own `sqlite3` and `.stats on` (a new process per run, so a cold page
   cache) and writes `report-mac.txt`. `--self-test` checks the script on a small database.

The large build and the comparisons run only when `TABMAIL_DB_PROOF_DIR` is set (on the command line
`TEST_RUNNER_TABMAIL_DB_PROOF_DIR=<dir>`); `TABMAIL_DB_PROOF_REPEATS` overrides the default of 9 runs.
The suite `DBProofHarnessTests` keeps the harness honest on a small shape: the build is deterministic and
has the requested shape and completion mix, the statistics states differ only as intended, a variant's setup
reaches only its own file, the counters tell a scan from a seek, a write leaves the prepared file alone, and
an empty comparison is refused.

**Related.** The startup budget a launch query must fit: [042](042-syncstartup-budget-discipline-v50-v51-lesson.md).
