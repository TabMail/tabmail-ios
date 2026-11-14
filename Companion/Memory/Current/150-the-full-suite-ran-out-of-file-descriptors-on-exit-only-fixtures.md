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
not unlinked until that descriptor closes; a still-referenced exit-only fixture stays open and usable.

Rule text: `Companion/Rules/Active/data-integrity.md` rule 6.
