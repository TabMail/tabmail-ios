# IOS-PERF-007

> Routed from `KNOWN_ISSUES.md` line 1209 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `4204ba8e52ce3c44d4f607f9e72793b8823ef088f0bb64144695d1137847e8e5`

## Status

✅ **CLOSED AS A DECISION (2026-08-06, round-15 FIX-7)** — `MigrationTimingLedger.measureChainScale` runs **ungated in release builds** on every upgrade launch, costing ~160 ms of Mac time (~320–640 ms of device time) before the first migration body runs. **It stays.** Deleting it removes the denominator that made the chain's 27,601 ms attributable at all

## Subsystem and search terms

Performance; migrations; upgrade launch; `AppDatabase.runMigrations`; `MigrationTimingLedger.measureChainScale`; `logChainScale`; `MigrationTimingGate.isRecording`; `unapplied.isEmpty`; `BackgroundSyncLogger.log`; `COUNT(*)`; `PRAGMA page_count`; `PRAGMA page_size`; covering-index scan; global rule 12; production observability; `IOS-PERF-005` sibling; `IOS-MIGRATION-002`; `IOS-MIGRATION-003`

## Full detail

**The cost, measured rather than asserted.** R15 A4 ran it on a 200,000-header / 120,000-body / 670 MB fixture carrying the real `v83` index set: **160.9 ms with stale statistics, 159.4 ms fresh**, 2.3–2.5 ms warm. The plan is identical in both statistics regimes — two full covering-index scans — so `ANALYZE` neither helps nor hurts, and the cost scales linearly with mailbox size. At this repo's standing Mac-understates-device factor of 2–4× that is roughly **320–640 ms added to an upgrade launch**, paid behind the "Updating…" splash before any UI appears. Four `COUNT(*)`s (`messageHeader`, `messageBody`, `account`, `folder`) plus `PRAGMA page_count`/`page_size`.

**Why removing it is the wrong move, and this row exists to say so before someone tries.** The owner's device measurement (see *Migration-chain cost* below) reported a **27,601 ms** chain that nobody could attribute: *"slow migrations"* and *"a very large mailbox"* have **opposite remedies**, and this is the only line that separates them. `IOS-MIGRATION-002`, `IOS-MIGRATION-003` and `IOS-PERF-005` are all consequences of having had the denominator. Removing it to save 320 ms would cost the ability to diagnose the next 27 seconds.

**Two facts that bound the exposure, both checked.** (i) The measurement sits inside `try? writer.read { … }` behind `guard !unapplied.isEmpty else { return nil }`, and `unapplied` is derived from the SAME `migrator.completedMigrations(db)` read the chain is about to do anyway — so an ordinary launch of an already-migrated database pays one read of `grdb_migrations` and emits nothing. The four `COUNT(*)`s are paid **at most once per app upgrade**. (ii) The emission is `BackgroundSyncLogger.log`, which is the same ungated durable-log call the **shipped** release already makes for the chain total (`07a4bb703:TabMail/Services/AppDatabase.swift:127`, quoted against an immutable tag) — so the line joins an already-shipped, already-ungated class, and global rule 12's production-observability exception plausibly covers it. `MigrationTimingGate.isRecording` deliberately guards only the per-migration attribution lines and the chain-completion aggregate; the calibration read is outside it **on purpose**, because a denominator that only exists in debug builds cannot explain a field report.

**Fail-safety.** The whole block is `try?` and every read inside `measureChainScale` is individually optional, because a diagnostic that can fail a migration chain is a brick — the non-recoverable set — while a missing number is not. On a fresh install `messageHeader` does not exist yet and `count(_:)` returns `nil` rather than throwing.

**Recoverability, with the non-recovering case named (`MIS-IOS-008`).** There is nothing to recover: the cost is one-time latency on an upgrade launch, the same rows in the same state afterwards, no user intention involved and nothing mutated. The non-recovering case is therefore vacuous **by measurement, not by assertion** — the log line itself states `[measured in Xms, included in the chain total]`, so the cost is never double-counted or hidden inside a migration's attribution. **What would re-open this row:** the guard moving off `unapplied.isEmpty` (which would put it on every ordinary launch), a fifth `COUNT(*)` or any table scan being added to it, or a measurement showing it has grown to a material fraction of a post-`IOS-PERF-005` chain (projected 3,241 ms) rather than the ~5% it is now.
