# IOS-AI-006

- Register classification: `resolved`
- New post-freeze record (2026-08-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-15) — a selected AI job is no longer re-gated by global inbox age.**
The automatic backlog remains bounded at `SyncConfig.maxRecentEmails`; direct event jobs now match
Thunderbird's uncapped `processMessage` path.

## Reachability and failure

`ActiveAIQueue.repopulationCandidates` selected the newest 100 rows among
`isInInbox && bodyComplete && needs-AI`, while `executeJob` separately counted every newer inbox row.
Those populations differ. In a 500-row inbox with most newer rows already complete, an older
needs-AI row could enter the queue and then fail the executor gate.

That refusal returned `.ordinary(retry: false)`, but `jobCompleted` deliberately ignores the
executor's ordinary advisory and re-reads GRDB. The field was still missing, so the job became
`.needsRetry` with `maxRetries: .max`, eventually cycling every 30 seconds. It never reached the
structural-admission branch, so `unattributableJobs` could not memoize it; `awaitDrain` waited to its
safety timeout. A moved old message was a direct producer, but no move was required for reachability.

**Exact-review correction before merge.** Removing that executor gate alone did not bound every
automatic producer. `ActiveBodyQueue.repopulateFromDatabase` and `repopulateOnDrain` intentionally
fetch every incomplete inbox body, with no `LIMIT`; `BodyFetchProcessor.flushBatch(enableAI: true)`
then enqueued every confirmed body into `ActiveAIQueue`. A restart with old incomplete-body residue
could therefore turn deep body backfill into unbounded model work even though ActiveAIQueue's own
repopulation SQL was bounded. `BackfillBodyQueue` is not the answer: it excludes inbox rows and calls
the same processor with AI disabled.

## Fix and invariant

The duplicate executor gate is removed. `repopulationCandidates` now applies the recent-window
`LIMIT` to **all inbox rows first**, then filters that bounded window for body-complete unfinished AI
work. `repopulateOnDrain` calls the same production selector instead of maintaining a second SQL
copy. This preserves the intended automatic-backlog budget and prevents drain-time pagination from
walking older rows after each completed batch.

The body producer now carries an explicit enqueue scope. ActiveBodyQueue uses
`.automaticRecentWindow`, whose `BodyFetchProcessor.automaticAIEnqueueCandidates` intersects its
confirmed batch with the **same production** `ActiveAIQueue.repopulationCandidates` selector.
User-open and visible-snippet fetches use `.directEvent`; proved moves and NSE pushes already bypass
the body producer and enqueue directly. Thus old automatic body residue is capped without restoring
the executor gate for an explicitly selected message. A selector failure refuses only derived AI
enqueue; the durable nil fields preserve the ordinary retry/relaunch fallback.

`ActiveAIQueue.jobStartDisposition` is the production preflight for a job already selected by an
event or the bounded backlog. Its terminal states are field-complete and structurally unattributable;
date rank is deliberately absent. `LargeInboxTests` pins both halves through the production producer
boundary: an unfinished 101st row is excluded by
`BodyFetchProcessor.automaticAIEnqueueCandidates`, while the same directly selected row with 100
newer inbox rows proceeds through `jobStartDisposition`.

## Reference and residuals

Thunderbird applies `maxRecentEmails` in `processCandidatesInFolder` selection and has no second
recency gate in `processMessage`. The fix restores that division. The accepted `IOS-AI-004`
RFC-less immediate-resolution guard is unchanged, as are the structural AI write-admission rules.
