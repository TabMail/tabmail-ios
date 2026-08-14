# IOS-PERF-008 — TabMail's sustained disk-write rate rose ~20× between v1.6.38 and v1.7.8

**Status:** 🔓 OPEN (2026-08-12) — observed, NOT diagnosed, deliberately not chased.

## Observation

Two `diskwrites_resource` reports from the owner's iPhone 14 Pro (iOS 26.5.2), which is Apple's
watchdog reporting that the app exceeded its disk-write budget:

| build | dirtied | window | **app's rate** | budget |
|---|---|---|---|---|
| v1.6.38 (347), 2026-08-06 | 1.07 GB | 85,167 s | **12.61 KB/s** | 12.43 KB/s |
| v1.7.8 (356), 2026-08-11 | 17.18 GB | 68,490 s | **250.84 KB/s** | 198.84 KB/s |

Source: `~/Library/Logs/CrashReporter/MobileDevice/<device-name>/TabMail.diskwrites_resource-*.ips`.
The v1.7.8 report is on a TestFlight build (`is_beta: 1`, `distributor_id: com.apple.TestFlight`).

## What is and is NOT comparable — read before citing these numbers

**The absolute volumes are NOT comparable.** The report fires at `budget × 86400 s`, and the budgets
differ (12.43 vs 198.84 KB/s), which is exactly why one reads ~1 GiB and the other ~16 GiB. Quoting
"1 GB → 17 GB" as a 16× regression is wrong and inherits Apple's accounting rather than measuring the
app.

**The app's own sustained rate IS comparable**: 12.61 → 250.84 KB/s, ~20×. That is app behaviour.

## The benign hypothesis, which currently cannot be excluded

Owner's reading (2026-08-12): the device had been **re-syncing mail on a new build** — a fresh or
migrated install performs a full mailbox download, FTS indexing and embedding generation. That is a
large, legitimate, ONE-TIME write burst.

This survives the arithmetic: the report averages over its window, so a burst front-loaded into the
first hours of a 19-hour window still reads as a sustained 250 KB/s. A single averaged data point
**cannot distinguish a one-time migration burst from a steady-state regression**, and no attempt was
made to claim otherwise.

## THE DISCRIMINATING TEST — this is the load-bearing part of this entry

Do not re-argue the hypothesis from the same data. It is settled by one observation:

> **A `diskwrites_resource` report on a build where NO migration ran and NO full re-sync occurred.**

- If a report appears in **steady state** — app installed for days, mailbox settled, no schema
  migration, no re-index — the benign explanation is dead and this is a real write-amplification
  regression worth diagnosing.
- If reports only ever appear in the days following an install/migration, the behaviour is expected
  and this entry should be closed as not-a-defect, recording that outcome.

Cheapest way to get that data point: note the install/migration date of the build, then check for a
new `.ips` more than ~72 h later.

## If it turns out to be real — where to look, in order

Bounded by what changed between v1.6.38 and v1.7.8, so this is a starting set and not a diagnosis:
the provider-id action queue (shipped v1.7.0), the FTS year-shard work including a `DROP`+`CREATE`
migration, WAL checkpoint frequency, repeated `messageHeader` rewrites during sync, and embedding
writes. Instrument which tables and code paths dominate; do not guess from the changelog.

## Why it is not being chased now

Owner directive, 2026-08-12: *"you could put that on known issues, but I don't think it's what we
should do now."* Recoverable and non-destructive — the cost is battery, flash wear and a watchdog
report, not data loss — so per THE MANTRA it is registered rather than mechanised.

## Attribution

Observed by the coordinator session while checking a connected device at the owner's request. The
benign re-sync hypothesis is the **owner's**, offered as a hypothesis rather than a ruling; the
discriminating test is agent-side and overturnable.
