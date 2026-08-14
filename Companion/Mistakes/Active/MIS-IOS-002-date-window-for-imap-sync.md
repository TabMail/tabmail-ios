# MIS-IOS-002 — I windowed an IMAP sync query by date and deleted months of Archive

**Class:** data-integrity
**Severity:** critical (data loss)
**First seen:** 2026 · **Recurrences:** 2 · **Status:** Active
**Related:** [MIS-IOS-001](MIS-IOS-001-appended-to-an-already-applied-migration.md), [MIS-IOS-003](MIS-IOS-003-reconstructed-an-address-the-wire-already-gave-us.md) · **Rule owner:** ADR-IOS-042

## The tell

I need a stale-detection overlap window for a folder sync. A **date window** is the natural unit —
the user thinks in dates, the UI sorts by date, and the column is right there. Any date window, date
cursor, or date-based floor on an IMAP folder is this mistake.

## What actually happened

Real, multi-month Archive **data loss** requiring a forced re-sync of affected users (commit
`4145d2a`, migration `v59`). IMAP `fetchMessages(limit:)` returns the **highest UIDs**, and a UID is
**archive-time**, not message-date: archiving one old-dated email gives it a fresh high UID. A
date-based overlap window therefore drags its floor back to that old date and sweeps in months of
mid-range Archive mail the fetch never returned — then deletes them. Users saw
searchable-but-unopenable orphans and multi-month gaps.

## Why it is not obvious

UID and message-date feel correlated because for the common case they are — mail usually arrives in
date order. The decorrelation only shows up on the archive path, and then it is catastrophic rather
than gradual.

## Instance 2 (2026-08-04) — same outcome, different door: the wrong PROVENANCE, not the wrong unit

`selectStaleHeaders`' complete-knowledge branch decided whole-folder coverage from
`if fetched.count < limit` — where `fetched` is every provider's `infos.compactMap { … }`, i.e. what
was returned **and parseable**. One record with an unparseable INTERNALDATE on a full page makes the
count fall short of `limit`, the branch concludes it holds the entire folder, and it returns the
survivors **with no floor at all**. Red evidence: *7 of 12 local rows destroyed by one unparseable
sibling.* Same class of end state as instance 1 — mass deletion of mail the server still holds, past
the 90-day `selfHealRecentMessages` reach.

Instance 1 was the wrong **unit** (date where UID was meant). Instance 2 was the wrong
**provenance** (a client-side parse survivor count where a server-reported record count was meant).
The rule as written only forbade the first, so the second walked straight through it — and shipped
with a comment (`COVERAGE — what the SERVER returned`) confidently asserting the very property that
was false. **A second trigger nobody briefed** also produces it: a short FETCH — `EXISTS n` with
fewer than n records returned — already logged in production as `[IMAP-FETCH-GAP]`.

Closed structurally by `6d460aa99`: `selectStaleHeaders` now takes `coverage:` **instead of**
`limit:`, so the survivor count is not in scope at the decision point at all. `FetchCoverage` is
bound to the fetch the way `observedEpoch` is, and IMAP proves whole-folder coverage with **two**
terms — `EXISTS <= limit` **and** `rawRecordCount == messageCount` — so neither trigger can forge it.

## The rule

Any sync query that decides **what to fetch, keep, delete, or where the cursor sits** for an IMAP
folder windows by **UID** (`CAST(messageId AS INTEGER)`), never by `date`.

**And the number that gates a deletion must come from the SERVER, not from what the client managed to
parse.** Before a count decides coverage, name where it came from: a `compactMap`/`filter`/decode
survivor count is a statement about the client, and any per-record failure silently converts it into
a false claim of complete knowledge. Server-reported cardinality (`EXISTS`, `messageCount`,
`nextPageToken`/`@odata.nextLink` absence) is the only admissible evidence, and it must travel bound
to the fetch rather than be re-derived downstream.

## Mechanical check

```bash
# Sync/stale/cursor decisions must not reference the date column:
rg -n 'date' --type swift TabMail/Services/Sync/ | rg -v 'order by date|sortBy|display'

# Instance 2: no count that gates a deletion may be a client-side survivor count.
# Every provider's fetch reduces with compactMap; trace any `.count` fed to a coverage decision
# back to its producer before trusting it:
rg -n 'compactMap|\.count < |\.count >= ' --type swift TabMail/Providers/ TabMail/Services/Sync/
```

**Display ordering is exempt** — the inbox and folder lists order by `date` for human reading, and
the `messageHeader_folderId[_isRead]_date` composite indexes accelerate that. The distinction:
*display* may use date; *sync/stale/cursor* decisions on IMAP must use UID. The single source of
truth is `SyncEngine.selectStaleHeaders` gated on `provider.staleWindowMode`; do not bypass it or add
a parallel date-based sync path.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-002](Companion/Mistakes/Active/MIS-IOS-002-date-window-for-imap-sync.md)** — windowed an IMAP sync query by date; UID is archive-time, not message-date → multi-month Archive data loss (ADR-IOS-042, `4145d2a`, `v59`). Display ordering is exempt. Instance 2: same mass-deletion outcome through a different door — the wrong **provenance** rather than the wrong unit. `if fetched.count < limit` read a `compactMap` **parse-survivor** count as server coverage, so one unparseable INTERNALDATE on a full page claimed whole-folder knowledge and returned survivors with no floor (red: 7 of 12 rows destroyed by one bad sibling); a short FETCH (`[IMAP-FETCH-GAP]`) forges it too. **A count that gates a deletion must be SERVER-reported and travel bound to the fetch — a client-side survivor count is a statement about the client.** Closed structurally by `6d460aa99` (`coverage:` replaces `limit:`). (×2)
```
