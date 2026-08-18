# IOS-BODY-003

<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
## 📋 PARTIALLY RESOLVED (2026-08-17)

`ActiveBodyQueue` now remembers an ordinary retry exhaustion for the remainder of the
current drain. Its private drain-time recovery query may continue to report the honestly
incomplete GRDB row, but admission refuses to manufacture another retry budget during that
same drain. Once the item leaves the background queue,
`MessageDetailViewModel.loadBody` no longer sees it as queued/in-flight and takes the
foreground on-demand fetch path instead of polling behind a self-resurrecting background
item.

The refusal is deliberately not durable. An explicit enqueue, launch/foreground/sync
repopulation, cancellation recovery, or UIDVALIDITY reset clears the drain-local memory and
grants one later attempt. A different message remains admissible. A one-message RED reproduced
12 consecutive resurrection cycles and a non-terminating drain before the fix; the same
three-test suite is green afterward, and 73 neighboring body-queue/on-demand tests remain
green.

The original record remains `accepted`: `BackfillBodyQueue` still carries the bounded
move-address retry behavior described below, and this change does not route provider batch
fetches through `ProviderWorkQueue` or claim a general timeout for a provider call that never
returns.
<!-- KNOWN-ISSUES-AMENDMENT-END -->
> Routed from `KNOWN_ISSUES.md` line 1420 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `da0f346a170c1e0e836060eb2d7690d4d1d976946c2272391cfc5feeb899bdd0`

## Status

📋 **ACCEPTED LIMITATION (2026-08-08)** — the BATCH body path still pays one provider round trip per retry cycle while a move stays undrained

## Subsystem and search terms

Body fetch; `BackfillBodyQueue`; `ActiveBodyQueue`; `fetchMessagesBatch`; `renderFetched`; `repopulateOnDrain`; `QueueStorage.batchItemCompleted`; retry loop; `BodyAddressGate`

## Full detail

**THE MECHANISM.** A refused row deliberately keeps `bodyComplete = 0` and `bodyEmptyConfirmed = 0` — that is what makes the refusal non-destructive — so `repopulateOnDrain` re-admits it on the next cycle with a fresh retry count, and `maxQueueRetries` bounds one cycle rather than the job. The single-item path no longer pays for this: `BodyFetchProcessor.fetch` refuses BEFORE `provider.fetchMessage`. The batch path does, because the queues call `fetchMessagesBatch` for the whole batch before `renderFetched` can refuse any individual item.

**THE BOUND, WORKED RATHER THAN ASSERTED.** Offline, no round trip occurs at all — the connection fails first. So the loop requires being ONLINE with an undrained move, which is the state the drain clears in seconds. At the backfill profile's 3s pacing that is roughly 0.3 fetch/s, it blocks no other row (the queue keeps serving everything else), it writes nothing, and it stops being re-admitted the moment `finishMove` re-keys. ⚠️ **"Ends the moment `finishMove` re-keys" was too strong** (audit): a batch `Item` is an in-memory snapshot of the OLD headerId/folder/UID, and after the re-key `BodyFetchProcessor.addressRefusal` cannot read that old-key row at all, so it returns `.verificationUnavailable` → `.retry` and the already-admitted item keeps its place through the rest of its bounded `maxQueueRetries` cycle — one or more round trips AFTER the durable address settled. What the re-key ends is the re-admission: the next repopulation selects the destination-key row, which is fetchable. An online device whose drain is permanently wedged is a separate pre-existing defect, not this one.

**WHY NOT FIXED HERE.** The clean fix is to exclude in-flight-addressed rows from the queues' candidate SELECTs, which needs an `account` join for provider scoping — and an UNSCOPED filter would permanently exclude Gmail mid-move rows from body fetching, which is precisely the never-loads-never-recovers failure that got this gate's first revision rejected. That is a change deserving its own review round, not a tail-end edit to a release candidate.

**WHAT WOULD RE-OPEN THIS ROW:** the queue SELECTs gaining the scoped exclusion (it becomes FIXED), or evidence of undrained moves persisting long enough for the round trips to matter.
