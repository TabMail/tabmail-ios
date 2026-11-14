# The full suite ran out of file descriptors: exit-only fixtures were held until exit (#885)

**Keywords:** file descriptor; fd leak; descriptor exhaustion; `EMFILE`; `os_unix.c (24)`; SQLite
error 14; `unable to open database file`; test host restart; "Restarting after unexpected exit";
`TestDatabaseTeardown`; `TestDatabaseTeardown.swift:456` fatal error; `DirectoryLease`;
`.tabmail-test-fixture-owner-v1.lock`; `registerForProcessExit`; `InstalledTestDatabaseLifetime.finish`;
exit-only; weak; `reclaimReleasedExitGroups`; `openDescriptorPaths`; `F_GETPATH`; `close_v2` zombie;
`prepareFileDescriptorBudget`; `RLIMIT_NOFILE`; lsof; `/tmp/fd-sampler/sample.sh`; full suite.

## What happened

The full iOS suite on main (`5455cc40`) failed after several thousand tests: SQLite could no longer open
files (`os_unix.c (24)`, `SQLite error 14: unable to open database file`), about 25 later suites
failed (MemoryIndex, MemoryReadTool, MessageDetail, NSE...), and `DirectoryLease.acquire` could not
open a new fixture marker, so `TestDatabaseTeardown.makeEntry`'s precondition stopped the host.
xcodebuild restarted it and the summary counted only the second launch. Every failing suite passed alone.

## Measurement (how to repeat it)

`/tmp/fd-sampler/sample.sh <pool udid> <out> <seconds>` runs `lsof -p` on the test host every N
seconds (the device is the one `scripts/heavy-slot.py --status` shows leased to the run). lsof prints
descriptors above 9999 as `*NNN`, and memory-mapped `-shm` files as `txt`, so count real descriptors
with `$4 ~ /^\*?[0-9]+[urw]$/`. To attribute a held fixture directory to its suite, open its database
read-only and read `account.id`, then grep the tests for that id.

Baseline full run on `5455cc40` (pool-0, sampled every 15 s, heavy load):

| time into the test phase | open files (lsof total) |
|---|---|
| 0 min | 68 |
| 1 min | 542 (about 60 fixture directories in use at once) |
| 6 min | 2,359 |
| 10 min | 6,203 |
| 13 min | 10,281 |
| 38 min (7,089 tests done, run stopped) | 14,009: 12,164 real descriptors, 1,758 fixture directories held |

Every growing directory carried the fixture marker and belonged to an exit-only fixture
(`InstalledTestDatabaseLifetime.finish` or `registerForProcessExit`). Largest holders in one
mid-run sample: the calendar edit-kind suites 77 directories, calendar EXDATE 43, CalDAV
occurrence edit/delete to wire about 41, CalDAV organizer 35, guest change 31, calendar conflict
disposition 17, `AccountManagerQueueDrainTests` 16, `MemoryIndexTests` 8. Each held directory
cost about 7 descriptors: the marker, the writer's database and WAL, each reader's database and
WAL, and one shared SHM.

## Cause

`TestDatabaseTeardown`'s registry held every exit-only group's `DatabasePool`/`DatabaseQueue`
STRONGLY until the `atexit` flush. Exit-only exists because escaped production work (drains,
recounts) may still use a fixture after its test ends, so the registry may not close it early; but
holding it strongly also kept it open long after that work had finished, for every such fixture in the
run. The raised soft limit (`prepareFileDescriptorBudget`, 10,240) only postponed the failure.

## Fix

Exit-only groups are held WEAKLY (`Connection.weakened()` in `Retired.init`). The registry still never
closes such a group early: the escaped work, the global, or the test keep it alive for exactly as long
as they reference it, and GRDB closes each connection on deallocation. Every registry transition
(`retire`, `closeThenUnlinkNow`, `registerForProcessExit`) first runs `reclaimReleasedExitGroups`,
which unlinks a group's directory once all its connections are released AND no descriptor of the
process still names a file in it (`openDescriptorPaths`, `fcntl(F_GETPATH)` over the descriptor
table; a deallocated SQLite connection can stay a `close_v2` zombie). Connections still alive at exit
are closed at exit, before unlink, as before. The descriptor budget stays: it is for fixtures in use
at the same time, not for accumulation; do not raise it to absorb growth.

Why the descriptor proof and not "unlink when the pool deinits" (review round 1, 2026-11-14): a pool's
deallocation does not prove its files are closed. GRDB's `DatabasePool.asyncRead` captures the reader
pool and the reader `SerializedDatabase`, not the `DatabasePool`, so a read still queued or running
keeps a reader connection (and its descriptors) open after the pool is gone; `SerializedDatabase.deinit`
closes with `sqlite3_close_v2`, which leaves a zombie while a statement is unfinalized; and a Swift weak
reference reads nil as soon as the last strong reference goes, before the releasing thread has finished
the deinit's closes. The kernel's own list of open descriptors is the only direct evidence.

Round 1 hardening of the proof:
- The directory is spelled for comparison through `realpath(3)` of its parent (`kernelPath(of:)`),
  because `F_GETPATH` reports the kernel path and Foundation's `resolvingSymlinksInPath` strips a
  leading `/private` that the kernel keeps; under a `/private`-rooted temp path the old comparison
  never matched and the proof passed trivially. A directory whose spelling cannot be resolved counts
  as still open.
- When a live sibling's close fails, the released siblings' placeholders stay in the retried group, so
  the retry still owes the proof (they were dropped, and the later retry skipped the proof).
- The scan walks the whole descriptor table (never misses one), and `prepareFileDescriptorBudget` now
  sets the soft limit to exactly the budget (it only raised it before), which bounds the table. One
  scan of 10,240 slots costs about 2 ms (host benchmark, 30 to 1,000 open descriptors), and runs at
  most once per registry transition that has a released group.

  Superseded by iOS #898 (below): the soft limit is NOT pinned; it is only ever raised.

## iOS #898: the soft limit is not a fixed number (2026-11-14)

The first full suite on the fix (bd199344, 12,794 tests, one launch, no descriptor errors) failed
one test: the budget test asserted the soft limit was at most 10,240, and it was 12,544. Nothing in
our code or our packages calls `setrlimit` besides `prepareFileDescriptorBudget`. CFNetwork does:
the first `URLSession` task in a process adds 2,304 to the soft `RLIMIT_NOFILE` (host probe: 256 ->
2,560, 4,096 -> 6,400, 10,240 -> 12,544, 12,544 -> 14,848; the host cache images that import
`setrlimit` include CFNetwork, CoreFoundation, Foundation, Network and WebKit, and only the
`URLSession` probe moved the limit).

The descriptor walk was not wrong: it reads `getdtablesize()` (the current soft limit) on every
scan, so it covered descriptors above 10,240. What was wrong was the assumption around it: the round-1
change that SET the soft limit to exactly the budget could LOWER a limit another component had
raised, and a descriptor numbered above the new limit would then be outside the walk. The rule now:
`prepareFileDescriptorBudget` only raises (`budgetedSoftLimit(current:hard:)` = max(current,
min(budget, hard))). A descriptor can only be opened below the soft limit of its moment, so while
the limit never decreases every open descriptor is below the current one and the walk is complete.
Never lower `RLIMIT_NOFILE` in the test host, and never assert it equals or stays under the budget.

Tests: the budget never lowers a raised ceiling (`budgetedSoftLimit`); with the ceiling raised above
the budget, the walk sees a descriptor numbered above 10,240 on a fixture's file.

## Proof

- Red first (fix inverted: exit-only groups held strongly again; the teardown invariant suite plus
  the fence and invariant suites, 172 tests): the two new teardown tests fail and the host's open
  files grow from 83 to 3,519 in two minutes.
- With the fix (the same suites plus the leaking ones: queue drain, calendar edit-kind, EXDATE,
  CalDAV organizer, guest change, CalDAV occurrence edit/delete, conflict disposition, MemoryIndex,
  escaped-task sink, process-global state; 414 tests in 39 suites, all passing): open files stay
  between 100 and 127 for the whole run, sampled every 10 s.

Invariant tests (`TestDatabaseTeardownInvariantTests`): released exit-only fixtures leave no
descriptor and no directory after the next transition; a released fixture whose file is still open is
not unlinked until that descriptor closes; a still-referenced exit-only fixture stays open and usable;
an ordinary `retire` and a `closeThenUnlinkNow` each reclaim a released fixture; the proof sees a file
opened under a symlinked temp path that resolves through `/private`; a failed live close keeps a
released sibling's proof owed until its descriptor closes.

Rule text: `Companion/Rules/Active/data-integrity.md` rule 6.
