# IOS-TEST-011

> Routed from `KNOWN_ISSUES.md` line 1135 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `7b4fd4c33a8367aa28f50577897669f1d14fe783a90555d509eee24176d3d8fa`

## Status

✅ **CLOSED AS A DECISION (2026-08-06, round-14 F10b)** — 96 of the 109 test files that create a per-run on-disk SQLite database under the temporary directory never remove it; the leak is test-host disk only, has no product surface and no user-visible state, and a 96-file mechanical edit is not being made at the end of an audit train

## Subsystem and search terms

Tests; test hygiene; temporary directory; `FileManager.default.temporaryDirectory`; `NSTemporaryDirectory()`; `UUID()`; `removeItem(`; per-run SQLite database; leftover files; simulator disk; cleanup pattern; `BodyAssetStoreTests.setupTest`; `BodyAssetStoreTests.teardown`; `TestDatabaseTeardown`; census; `MIS-007`

## Full detail

**The census, with its predicate, its number and its revision (`MIS-007`).** Over the 564 `.swift` files under `TabMailTests/` at `271d13334`: a file *creates a per-run on-disk database* if it matches (`FileManager.default.temporaryDirectory` OR `NSTemporaryDirectory()`) AND `UUID()` → **109** files (106 by the first spelling, 4 by the second; exactly one file uses both). Of those, **13** also contain `removeItem(` → **96** do not. Re-derived independently for this row rather than carried from the brief.

**What it costs.** Each such test leaves one directory containing a SQLite database (plus `-wal`/`-shm`) in the test host's temporary directory. The simulator reclaims it on erase, and the OS reclaims `tmp` under disk pressure; nothing in the product reads these paths, no shipped code path creates them, and no assertion in any suite depends on a previous run's leftovers (every path is `UUID()`-unique, which is precisely why the leak is invisible). It is not §5-actionable: there is no invariant, no user-visible state and no data at risk.

**The cleanup pattern a future sweep would adopt**, already in the tree and already proven by the 13 files that do it: `BodyAssetStoreTests.setupTest()` builds `NSTemporaryDirectory()/<name>-<UUID>` and `BodyAssetStoreTests.teardown(_:)` calls `try? FileManager.default.removeItem(at: dir)`; `TabMailTests/Infrastructure/TestDatabaseTeardown.swift` is the shared harness for the database half. A sweep adopts the pair per suite — it does not need a new mechanism.

**Why the 96-file edit is not being made now.** It touches 96 test files with no behavioural coverage of its own, at the end of an audit train whose remaining gates re-run the whole suite; a mechanical edit of that width is exactly where a stale-test-bundle or a silently-skipped suite hides (`MIS-013`), and it would buy disk that the simulator already reclaims. Registered so it is a decision with a number attached rather than an absence, and so a future hygiene pass has the predicate to re-run rather than re-derive.
