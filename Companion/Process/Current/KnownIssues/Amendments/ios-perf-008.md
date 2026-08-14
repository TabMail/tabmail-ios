# IOS-PERF-008 — TabMail's sustained disk-write rate rose ~20× between v1.6.38 and v1.7.8

**Status:** 🔓 OPEN (2026-08-12) — observed, NOT diagnosed, deliberately not chased.

## Observation

Apple `diskwrites_resource` reports from two releases showed the app's normalized sustained-write
rate rise by roughly one order of magnitude. The public record intentionally omits the device name,
local report path, exact report windows, and per-device byte totals; they are not needed to preserve
the diagnostic question.

## What is and is NOT comparable — read before citing these numbers

**The absolute volumes are NOT comparable.** The report fires at `budget × 86400 s`, and the budgets
differ (12.43 vs 198.84 KB/s), which is exactly why one reads ~1 GiB and the other ~16 GiB. Quoting
raw byte totals as a regression ratio is wrong and inherits Apple's accounting rather than measuring
the app.

**The app's own normalized sustained rate IS comparable**, and it increased materially between the
two reports. That is app behaviour; the private device-specific values are deliberately not public.

## The benign hypothesis, which currently cannot be excluded

The leading hypothesis was that the device had been **re-syncing mail on a new build** — a fresh or
migrated install performs a full mailbox download, FTS indexing and embedding generation. That is a
large, legitimate, ONE-TIME write burst.

This survives the arithmetic: the report averages over its window, so a burst front-loaded into the
first hours of a long report window still reads as a sustained elevation. A single averaged data point
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

Observed during release diagnostics. The benign re-sync explanation remains a hypothesis rather than
a ruling; the steady-state discriminating test above can overturn it.
