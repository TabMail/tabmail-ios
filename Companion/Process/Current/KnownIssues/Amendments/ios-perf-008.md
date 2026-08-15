# IOS-PERF-008 — TabMail's sustained disk-write rate rose ~20× between v1.6.38 and v1.7.8

**Status:** ✅ NOT A DEFECT (2026-08-14) — the reports were captured during initial sync.

## Observation

Apple `diskwrites_resource` reports from two releases showed the app's normalized sustained-write
rate rise by roughly one order of magnitude. The public record intentionally omits the device name,
local report path, exact report windows, and per-device byte totals; they are not needed to preserve
the diagnostic question.

## Disposition

The owner confirmed on 2026-08-14 that the elevated write windows coincided with initial sync. A
fresh or migrated install necessarily writes the downloaded mailbox plus its FTS and embedding
derivatives, so this observation does not establish a steady-state write-amplification regression.
GitHub issue #11 was closed as not planned with that explanation.

This is a narrow disposition, not a claim that initial-sync volume is inherently optimal or
unbounded. Reopen only if elevated writes persist after initial sync, migrations, indexing, and
embedding backfill have settled.

## What is and is NOT comparable — read before citing these numbers

**The absolute volumes are NOT comparable.** The report fires at `budget × 86400 s`, and the budgets
differ (12.43 vs 198.84 KB/s), which is exactly why one reads ~1 GiB and the other ~16 GiB. Quoting
raw byte totals as a regression ratio is wrong and inherits Apple's accounting rather than measuring
the app.

**The app's own normalized sustained rate IS comparable**, and it increased materially between the
two reports. That is app behaviour; the private device-specific values are deliberately not public.

## The benign explanation confirmed for these reports

The device had been **syncing mail on a new build** — a fresh or migrated install performs a full
mailbox download, FTS indexing and embedding generation. That is a large, legitimate, ONE-TIME write
burst.

This fits the arithmetic: the report averages over its window, so a burst front-loaded into the first
hours of a long report window still reads as a sustained elevation. A single averaged data point
**cannot distinguish a one-time migration burst from a steady-state regression**; the owner's sync
correlation supplies the missing context for these reports.

## Reopen predicate

Do not re-open from these same initial-sync reports. The future discriminating observation is:

> **A `diskwrites_resource` report on a build where NO migration ran and NO full re-sync occurred.**

- If a report appears in **steady state** — app installed for days, mailbox settled, no schema
  migration, no re-index — this disposition no longer explains it and the write-amplification
  question should be reopened.
- Reports confined to the days following an install, migration, or full re-sync remain expected.

Cheapest way to get that data point: note the install/migration date of the build, then check for a
new `.ips` more than ~72 h later.

## If it turns out to be real — where to look, in order

Bounded by what changed between v1.6.38 and v1.7.8, so this is a starting set and not a diagnosis:
the provider-id action queue (shipped v1.7.0), the FTS year-shard work including a `DROP`+`CREATE`
migration, WAL checkpoint frequency, repeated `messageHeader` rewrites during sync, and embedding
writes. Instrument which tables and code paths dominate; do not guess from the changelog.

## Why it is closed

Owner disposition, 2026-08-14: close because the reports came from initial sync. Recoverable and
non-destructive — the cost is battery, flash wear and a watchdog report, not data loss — and the
available observation contains no steady-state defect to mechanise.

## Attribution

Observed during release diagnostics and dispositioned by the owner after correlating the report
window with initial sync. The steady-state reopen predicate above can overturn the disposition.
