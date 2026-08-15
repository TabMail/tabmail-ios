# IOS-AI-006

- Register classification: `open`
- New post-freeze record (2026-08-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN — INTEGRATED FIX CANDIDATE (2026-08-15).** A selected AI
job is no longer re-gated by global inbox age. The candidate preserves the existing configured
newest-`SyncConfig.maxRecentEmails` automatic population in each inbox and adds durable uncapped
authority for direct open, push, and provider-proved move events. It does not change either
configuration value, bulk-archive policy/UI behavior, tutorial, Settings copy, or operation-queue
failure behavior. Whole-operation retirement failure retains the existing `.inFlight` launch-recovery
contract; partial narrowing failure retains the existing original-bundle requeue contract.

## Reachability and failure

`ActiveAIQueue.repopulationCandidates` selected the newest configured
`SyncConfig.maxRecentEmails` rows among
`isInInbox && bodyComplete && needs-AI`, while `executeJob` separately counted every newer inbox row.
Those populations differ. In a 500-row inbox with most newer rows already complete, an older
needs-AI row could enter the queue and then fail the executor gate.

That refusal returned `.ordinary(retry: false)`, but `jobCompleted` deliberately ignores the
executor's ordinary advisory and re-reads GRDB. The field was still missing, so the job became
`.needsRetry` with `maxRetries: .max`, eventually cycling every 30 seconds. It never reached the
structural-admission branch, so `unattributableJobs` could not memoize it; `awaitDrain` waited to its
safety timeout. A moved old message was a direct producer, but no move was required for reachability.

**Producer-boundary correction.** Removing that executor gate alone did not bound every
automatic producer. `ActiveBodyQueue.repopulateFromDatabase` and `repopulateOnDrain` intentionally
fetch every incomplete inbox body, with no `LIMIT`; `BodyFetchProcessor.flushBatch(enableAI: true)`
then enqueued every confirmed body into `ActiveAIQueue`. A restart with old incomplete-body residue
could therefore turn deep body backfill into unbounded model work even though ActiveAIQueue's own
repopulation SQL was bounded. `BackfillBodyQueue` is not the answer: it excludes inbox rows and calls
the same processor with AI disabled.

## Fix and invariant

The duplicate executor gate is removed. `repopulationCandidates` enumerates inbox-role folders and,
for each one, selects the newest `SyncConfig.maxRecentEmails` rows by `date DESC, id DESC` **before**
filtering body-complete missing-AI work. That order matches Thunderbird's
`processCandidatesInFolder` population semantics and prevents one account from consuming another
inbox's automatic population.

Direct authority is separate and durable. Migration `v85_addDirectAIPending` adds a schema-only
Boolean plus a sparse partial index. RFC-bearing intent is mirrored in the existing
`messageAICache` identity space, so a UIDVALIDITY purge can delete and renumber the live header
without erasing an old direct event; the first same-RFC resync insert restores the sparse marker.
RFC-less intent remains fail-closed because no content identity can safely carry it. The bit is
committed before or with every covered direct producer's fallible work: identity-guarded opened-message capture, identity-revalidated direct body
publication, NSE header admission, and whole/partial move retirement. Every automatic and direct
queue candidate captures its physical-message target in the same database read that admits it;
actor execution re-resolves that target, so a reused provider address cannot inherit X's automatic
slot or direct event. The direct body path also re-resolves the target before its GRDB body write,
body-complete flag, and actor enqueue. Repopulation unions every marked inbox row without a rank cap. The
bit survives ordinary model saves and is explicitly carried through identity-proved header re-key
paths; an unproved collision keeps authority on the source row instead of transferring it to an
unrelated destination-key occupant. It clears after summary, action, and reply are durable, when
the provider confirms an empty body, when the row leaves Inbox, or when its inbox folder vanishes.
The final AI mutation guard repeats both physical-message and live account-owned Inbox proof after
the model await; preflight is only a cost gate and never write authority.

The body producer retains its existing explicit scope. ActiveBodyQueue uses
`.automaticRecentWindow`, whose `BodyFetchProcessor.automaticAIEnqueueCandidates` intersects
confirmed automatic bodies with the same production selector. The user-open body path uses
`.directEvent`; inbox-list snippet prefetch remains automatic and cannot invent direct-event
authority. A marked old row with no body remains discoverable by the existing uncapped
incomplete-body queue; once the body becomes durable, the sparse direct selector admits it to AI.

`ActiveAIQueue.jobStartDisposition` is the production preflight for a job already selected by an
event or the automatic population. Its terminal states are field-complete, provider-confirmed empty,
and structurally unattributable; date rank is deliberately absent. Focused invariants cover
select-before-filter membership, per-inbox isolation, equal-date total ordering, old marked-row
recovery after an in-memory queue loss, RFC-keyed survival across UIDVALIDITY delete-and-resync,
selector-to-queue-job identity carry and replacement refusal, confirmed-empty termination, open and
push admission before body work, scope-exit clearing, whole-move marker/retirement rollback, partial-move
re-key/marker/narrowing rollback, opened-UID replacement refusal at the real GRDB body pipeline,
confirmed-empty replacement re-arming, live-folder/empty-body refusal at the final AI write, and
identity-safe re-key carry.

## Verification

The exact runtime/code snapshot passed 149/149 tests across the 11 executed suites, with zero
failures, skips, expected failures, build errors, warnings, or analyzer warnings. The focused
automatic/direct-policy pass was 63/63. Three conventional sensitivity inversions then failed only
their intended invariants: removing the uncapped direct union failed the three old-direct recovery
tests; removing marker idempotency failed the NSE terminal re-merge test; and removing the
canonical-survivor Inbox normalization failed the direct-marker carry test. Each inversion was
restored byte-for-byte before the final static gates (`git diff --check`, Swift frontend parsing,
known-issue verification, and iOS-rules verification).

## Reference and residuals

Thunderbird applies `maxRecentEmails` separately per inbox during startup, has no second recency gate
in `processMessage`, and persists direct jobs independently of that startup population. iOS keeps the
same division without changing the working configuration. This candidate does not reclassify every
provider-delta `newHeaders` row as direct new mail: iOS sync can discover old gaps there, and the
providers expose different event provenance. That narrower Thunderbird new-mail parity question is
left explicit rather than broadening this already-behavioral fix. The accepted `IOS-AI-004` RFC-less
same-wake resolution guard and structural write-admission rules are unchanged.

**Pre-existing cross-database residual, not claimed fixed here.** Body text publication into the
separate FTS database is keyed by `ContentKey` and is not atomic with GRDB identity. A UID turnover
between the guarded GRDB `MessageBody` write and `SearchIndex.updateBodies` can still put X's text
under a newly seated Y content key before the later GRDB finalizer refuses X. The candidate removes
the no-op FTS experiment and makes no false cross-store identity claim. The same residual includes
an automatic body fetch that was already in flight when the user opened its row: the durable direct
marker cannot retroactively identity-bind the separate FTS write. Closing that data-integrity
race needs a content-identity stamp or a broader cross-database publication protocol; it is a
non-trivial design decision and is not safe to smuggle into this queue-policy PR.
