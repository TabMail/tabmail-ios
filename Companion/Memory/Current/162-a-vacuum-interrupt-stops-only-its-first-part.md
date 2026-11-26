# 162 — A `VACUUM`'s interrupt stops only its first part; the copy-back cannot be stopped

**Status:** Current (2026-11-24; the step-wise pieces measured 2026-11-25). Applies to every `VACUUM` of the email
or search database, in the background job or the foreground (#1450 overnight reclaim, #1448 Optimize Storage,
anything later).

## What SQLite does

A plain `VACUUM` (SQLite 3.54.x) runs in two parts:

1. **Build.** It builds a compacted copy in a temporary database with ordinary statements
   (`INSERT … SELECT` loops). These check the interrupt flag and run the progress handler, so
   `sqlite3_interrupt` stops this part: the `VACUUM` fails with "interrupted", rolls back, and the database is
   unchanged.
2. **Copy-back.** It writes the copy back into the database (`sqlite3BtreeCopyFile`, a backup step) and commits.
   This part never checks the interrupt flag and runs no progress handler. An interrupt that arrives now is
   ignored, and the `VACUUM` commits.

Also: an interrupt that arrives while no statement is running is dropped, so a stop flag set just before the
`VACUUM`'s first step is lost and that `VACUUM` runs to its end.

## Measured

Python `sqlite3` 3.54.1 on a Mac, WAL mode, `wal_autocheckpoint = 0` (as `AppDatabase.makePool` sets),
`temp_store = FILE`, about 10% of the rows deleted before the `VACUUM`:

| Database | Whole `VACUUM` | Interruptible part | Copy-back | WAL after | Checkpoint of that WAL |
|---|---|---|---|---|---|
| 157 MB, 64 KB rows | 3.1-3.5 s | up to about 2.0 s | about 0.5-1 s | 142 MB | 0.8-0.95 s |
| 1,140 MB, header-like rows (560k) | 8.5-10.3 s | 3.0-3.6 s | 5.5-6.7 s | 964 MB | 2.4-5.2 s (TRUNCATE) |
| 1,071 MB, blobs | 7.9-8.9 s | 3.0-3.1 s | 4.9-5.8 s | 970 MB | 2.0-2.2 s |

So at about 1 GB only the first 35-40% of the run can be stopped. A stop requested later waits for the rest of
the copy-back (5-7 s on a Mac, more on a phone) while the `VACUUM` holds the single writer.

With SQLite's default autocheckpoint (not the app's setting) the commit's automatic checkpoint also runs inside
the `VACUUM`, so even less of it can be stopped (157 MB: 1.37 s in all, interrupts from 0.6 s on ignored).

## After a committed `VACUUM`

The WAL holds the whole copy: the disk grows by about the database's size until a checkpoint copies it back,
and that checkpoint takes about 2-6 ms per MB. A checkpoint run inside a write (the throttled foreground one in
`backgroundPool.writeWithoutTransaction`) holds the writer for all of it.

## Rule

Never design on "interrupting a `VACUUM` rolls it back" or "a `VACUUM` stops when the app opens". A plain
`VACUUM` holds the writer through its whole copy-back, seconds at about 1 GB, whatever the interrupt does.

A rewrite that must stop within a bound (for example, no single writer hold over about one second at about
1 GB, and a return to the app stopping the work within that bound) has to be built from steps that can each be
stopped:

- `VACUUM INTO` a temporary file: ordinary statements, interruptible, the live database untouched;
- copy that file back with the backup API a few pages per step, checking between steps (stopping rolls the
  destination back);
- shrink the WAL afterwards in short steps as well.

> **Amended 2026-11-25 (measured, below):** the backup copy-back holds the writer for its whole run however small
> its steps are. Steps bound only how soon a stop takes effect, so this piece cannot meet a bound on the writer
> hold. The WAL shrink cannot be split into steps either (a PASSIVE checkpoint has no page count), but a PASSIVE
> checkpoint does not hold the writer, and the TRUNCATE after it holds it about 0.2 s at about 1.2 GB.

Measure each piece at about 1 GB before relying on it: rowids, `schema_version` and the planner statistics
marker, the transaction observers on the live pool, the final step's commit, and the checkpoint. All but the
transaction observers are measured below; the observers (GRDB's hooks on the writer connection) need the app's
own code to measure.

## The step-wise pieces, measured (2026-11-25)

Python `sqlite3` 3.54.1 on a Mac, the app's settings (WAL, `wal_autocheckpoint = 0`, `synchronous = NORMAL`,
busy timeout 5 s, `temp_store = FILE`). Database: 1.48 GB of header-like rows with 179 MB of empty pages; its
compacted copy is 1.24 GB. A second connection wrote one row every 25 ms and a third read every 25 ms; the
writer's longest wait is the writer hold a piece imposes on the rest of the app. Times varied up to 2x between
two runs with the machine's load. A phone was not measured.

| Piece | Time | Holds the writer | A stop |
|---|---|---|---|
| `VACUUM INTO` a temporary file | 9.7-28 s | never (other writer's longest wait 4 ms; up to 0.29 s in a run where the test writer ran its own checkpoints) | returns in 3-58 ms; leaves an empty target file; the live database is untouched |
| Backup copy-back of the 1.24 GB copy | 5.5-8.9 s | **for the whole copy-back, whatever the step size** | returns 2-3 ms after a stop between steps; the live database is unchanged |
| `wal_checkpoint(PASSIVE)` of the 1.24 GB WAL | 6.1-8.4 s | no (other writer's longest wait 1 ms) | returns at once; the next full PASSIVE still took 8.4 s |
| `wal_checkpoint(TRUNCATE)` after a full PASSIVE | 0.16-0.20 s | for its whole run | not measured |
| `wal_checkpoint(TRUNCATE)` straight after the copy-back | 6.8 s | for its whole run | not measured |

- **The backup keeps the destination's write lock from its first step to its last.** Each step returns, but the
  write transaction stays open until the copy is complete or the backup is finished early
  (`sqlite3_backup_finish`), which rolls it back. The other writer waited 5.7-6.5 s in completed runs, 2.5 s for
  a copy-back stopped at 50% and 5.1 s for one stopped at 95%. The step size sets only how soon a stop takes
  effect: the longest step was 0.06-0.21 s at 256 pages (1 MB), 0.06 s at 1,024 pages (4 MB; one 0.57 s outlier
  in about a thousand steps), 0.15-0.16 s at 4,096 pages and 0.67 s at 16,384 pages. The last step, which
  commits, took 0.007-0.23 s. Readers were not held up (longest read 8 ms). No step returned `SQLITE_BUSY`.
- **On a separate destination connection, other writers time out:** they wait longer than the pool's 5 s busy
  timeout. On the pool's own writer connection they wait in its queue instead.
- **A completed copy-back replaces the database with the copy,** so every write committed after the
  `VACUUM INTO` began is gone (all of them, in every completed run). `PRAGMA data_version`, read on another
  connection before the `VACUUM INTO` and again once the copy-back holds the write lock, changed in every run
  that had such a write and stayed the same in the run that had none.
- **A stopped copy-back** leaves the database and every write intact (`quick_check` ok, `schema_version`
  unchanged), but the WAL file keeps the size it reached (622 MB at 50%, 1,181 MB at 95%) until a TRUNCATE
  checkpoint, which took 0.22-0.34 s.
- **After a completed copy-back:** rowids were unchanged in a 71-row sample of a table without an
  `INTEGER PRIMARY KEY` (SQLite does not promise this); `schema_version` is the live database's old value plus
  one (the backup sets it); `user_version` and `sqlite_stat1` are carried over.
- **Disk:** during the copy-back the copy (1.24 GB) and the WAL (growing to 1.24 GB) sit beside the unchanged
  1.48 GB database file: 2.48 GB extra, 1.7x the database or 2x the compacted size. The database file shrinks
  only when a checkpoint has copied the whole WAL back.
- **Connections:** `VACUUM INTO` also runs on a read-only connection. A read-only connection cannot checkpoint
  ("disk I/O error"). A checkpoint run inside a write holds the writer for its whole run (see above).
- **Measuring traps:** give every test connection `wal_autocheckpoint = 0`, as the app does, or its first commit
  after the copy-back checkpoints the whole WAL and its wait looks like a writer hold; and keep one connection
  open, because closing the last connection checkpoints and deletes the WAL.

Related: [158](158-every-batch-writer-checkpoints-the-wal-after-each-batch.md) (WAL checkpoints after batch
writers), [157](157-a-keyset-tie-break-must-be-in-the-index.md) (rowids and keyset cursors).
