# 162 — A `VACUUM`'s interrupt stops only its first part; the copy-back cannot be stopped

**Status:** Current (2026-11-24). Applies to every `VACUUM` of the email or search database, in the background
job or the foreground (#1450 overnight reclaim, #1448 Optimize Storage, anything later).

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

Measure each piece at about 1 GB before relying on it: rowids, `schema_version` and the planner statistics
marker, the transaction observers on the live pool, the final step's commit, and the checkpoint.

Related: [158](158-every-batch-writer-checkpoints-the-wal-after-each-batch.md) (WAL checkpoints after batch
writers), [157](157-a-keyset-tie-break-must-be-in-the-index.md) (rowids and keyset cursors).
