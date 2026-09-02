# IOS-BODY-006 — the oversized-metadata quarantine is a one-strike latch on a non-deterministic signal, and two of its writers sit outside the UIDVALIDITY generation guard

**Class:** `open` · **Opened:** 2026-09-02 · **Register classification:** post-freeze amendment
(no row in the hash-pinned 2026-08-09 archive).
**Disposition:** filed `open`, NOT `accepted` — every limitation below is a deliberate design
choice with a stated rationale, and exactly TWO carry the owner's decision: item 2 (let "Sync
Complete" fire) and the fail-fast-on-open half of item 4, both dated 2026-09-01 and both
reversals of an earlier stance. The remainder — items 1, 3, 5, 6 and 7, and in particular item 7,
the one-strike latch on a non-deterministic signal — have NO blessing yet, and item 7 is the
question this record was filed to put in front of the owner. The accompanying pull request asks
for that decision explicitly. Do not reclassify without it.

## What this record is

When an IMAP metadata FETCH overflows `IMAPFetchMapping.responseBufferLimit`, the response is
unparseable and the folder connection has to be discarded. Before the stop-gap, that message was
retried by four background admission queries plus three code paths, on every launch, forever —
each attempt paying a full TCP + TLS + LOGIN + SELECT and tearing down a connection other work was
using — and `BackfillProgress.pendingBodyCount` never reached 0, so "Sync Complete" was
unsatisfiable for the account.

The stop-gap records the observation durably in `messageHeader.bodyMetadataOversized` and refuses
the row at the fetch funnel. This record collects what that costs.

## The accepted limitations of the flag

These are enumerated in full on `BodyFetchProcessor.markBodyMetadataOversized`, the single writer
both queues call — the source is the authority, this row is the tracker entry. (They were
duplicated verbatim on `ActiveBodyQueue.markOversizedDurably` and
`BackfillBodyQueue.markOversizedDurably` under an "edit both copies or neither" instruction; the
duplication was removed because an instruction in a comment is not load-bearing — `MIS-IOS-009`.
Both queue methods now carry a pointer to the single site.) In summary:

1. The body is unsearchable BY CONTENT until the parser bound is raised. The header stays
   FTS-indexed, so the message is still findable by subject and sender. The bound is **first-party**
   (`IMAPFetchMapping.responseBufferLimit`); nothing external gates the release.
2. Backfill progress counts a flagged row as RESOLVED, so "Sync Complete" fires on an account that
   still has an unfetchable body. **Owner decision 2026-09-01**, reversing the earlier stance: a
   banner that never clears is worse product behaviour than rounding an unfetchable message up to
   done.
3. `SyncEngineFTS.selfHealBackfillFTSMembership` deliberately does NOT carry the flag — it
   re-indexes headers, and a flagged row's header is healthy.
4. Opening an affected message reports a load failure immediately, without a wire attempt, and the
   detail view's body poll stops itself rather than retrying every 2s forever. The shipped sentence
   is `MessageCardView`'s generic "Unable to load message. Pull to retry."
5. The inbox snippet loader refuses the row at its network tier, so an affected row shows no snippet
   preview.
6. Expanding a collapsed thread bubble whose message is flagged yields nothing at all — no body, no
   error, no wire attempt. That function has always swallowed every failure into a debug print, so
   the user-visible outcome is unchanged; what changed is that the tap no longer buys a lucky
   re-roll on a different fragmentation.

## The two properties that need the owner's decision

**A. It is a ONE-STRIKE latch on a signal that is not deterministic.** The parser bound is on unread
AGGREGATE bytes measured after the decode loop stops, so the trigger is fragmentation-dependent: an
ordinary, perfectly fetchable message on a lossy link can roll into this state. The codebase's prior
art for the same shape is a counter (`emptyFetchCount >= 3` before `bodyEmptyConfirmed`). A strike
counter was deliberately not built — that is a new column and more mechanism for a case one gesture
already recovers — but the trade should be an explicit decision, not an implied one.

**B. Two writers sit outside the UIDVALIDITY `resetGeneration` guard.** The queue batch paths capture
a generation and no-op on mismatch. The two non-queue writers routed through
`BodyFetchProcessor.markOversizedDurably` — the user-open funnel and `InboxViewModel
.loadSnippetBatch`'s tier 2 — hold no batch and capture nothing. A metadata FETCH already on the wire
when a reset starts can surface its overflow after the reset's clear is enqueued and after the
resync has re-inserted a row reusing that UID; the mark then commits last and passes both of
`markBodyMetadataOversized`'s guards against a message that never overflowed.

## Reachability and attribution

- **A** needs a fragmentation roll on a message that would otherwise parse. Frequency unknown; the
  signal is by construction not size-deterministic, so it cannot be bounded from the message alone.
- **B** needs an in-flight overflow concurrent with a same-folder UIDVALIDITY reset AND UID reuse
  landing on the same id. Narrow.
- Neither drops a user intention (ADR-IOS-067 unaffected), mutates a wrong message (the write is
  scoped to one row's own flag), nor deletes anything. The server copy is intact throughout and the
  header stays searchable.

## Recovery

**Pull-to-refresh** — `MessageDetailViewModel.refetchBody` passes `replaceExistingBody: true`, which
is exempt at the funnel, so it performs a genuine wire fetch; its success write clears the flag. That
exemption is what keeps the quarantine falsifiable by the user, and it is load-bearing: without it
the flag would be a verdict rather than an observation.

Also released by: any body-fetch success write, a folder UIDVALIDITY reset, and Smart Reindex
(durable half). And exactly, in one statement, by the migration that ships a raised parser bound.

⚠️ Smart Reindex's clear runs OUTSIDE the queues' serialized durable-write chain, so a mark dispatched
microseconds before the gesture can commit after it and re-quarantine the row. One more tap recovers.

## When revisited

1. Raise `IMAPFetchMapping.responseBufferLimit` and ship the one-statement clearing migration. That
   retires this record's whole population and is entirely within this repository's control.
2. If **A** is judged unacceptable, the smallest change is a strike counter reusing the
   `emptyFetchCount` shape — a new column, and therefore a new migration.
3. If **B** is judged unacceptable, let `ActiveBodyQueue.markOversizedDurably` accept an optional
   captured generation and no-op on mismatch, giving the non-queue writers the guard the batch paths
   already have. That means threading a generation through the fetch path.

## Related

- `IOS-BODY-004` — the detail-view body poll does not self-heal across a re-key; same view model,
  different mechanism.
- `IOS-IMAP-006` / `IOS-IMAP-015` — the SwiftMail/IMAP parsing surface this bound belongs to.
- ADR-IOS-050 — asset eviction leaves `bodyComplete = 1`, which is why both the flag's writer and
  `MessageHeader.isBodyQuarantined` carry a `bodyComplete` term, and why
  `BodyFetchRefusal.endsPolling` exists to cover the row those terms hide.
