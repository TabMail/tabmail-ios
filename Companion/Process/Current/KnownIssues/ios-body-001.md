# IOS-BODY-001

> Routed from `KNOWN_ISSUES.md` line 1418 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `165e3200538b4c72acb7af0229577783a95edc6a5243d88da7851e0e86a977b7`

## Status

📋 **ACCEPTED LIMITATION (2026-08-08)** — bodies ALREADY corrupted by shipped `v1.6.38` keep their wrong content; the gate protects new fetches only, and there is no remediation pass

## Subsystem and search terms

Body fetch; `BodyAddressGate`; `BodyFetchProcessor.process`; `optimisticMoveToFolder`; `MessageHeaderRekey.finishMove`; wrong body; wrong FTS entry; forward-fix-only; cached body; `bodyComplete`; THE ADDRESS PROBLEM

## Full detail

**THE MECHANISM.** `optimisticMoveToFolder` leaves the primary key and `messageId` at their SOURCE values while rewriting `folderPath` to the destination, so until `finishMove` re-keys the row its address is (destination folder, SOURCE UID) — a DIFFERENT message on IMAP. `BackfillBodyQueue` selects exactly those rows, and shipped `v1.6.38` fetched the stranger and stored its body plus FTS text under the moved message's content key.

**WHY IT SURVIVES THE FIX.** Every new refusal point sits on a FETCH path, and a row that already has a body never takes one: `MessageDetailViewModel.loadBody` accepts the cached body before its address pre-gate, `AccountManager.fetchBody` returns at its `hasBody` guard before the new check, `refetchBody` now declines to delete a cached body mid-move (see `IOS-BODY-002`), and once the move completes `MessageHeaderRekey.apply` carries the body and `publishRekeys` moves the FTS entry to the destination key intact. `bodyComplete` stays 1, so neither body queue revisits the row. The wrong content is stable and silent.

**WHY REGISTERED RATHER THAN REMEDIATED — AN EXPLICIT OWNER DECISION.** Forward-fix-only was chosen by the owner. Note the premise moved during the work and the decision did not: the original reasoning was that the affected builds had not reached users, and `git show v1.6.38:` later proved the identical hazard IS in the shipped release. The decision was re-affirmed on the corrected premise; only this row's scope changed, from "unreleased builds" to "shipped `v1.6.38` and earlier".

**THE COUNTERFACTUAL.** Invalidating every in-flight-addressed cached body on upgrade would also discard legitimate pre-move caches and force re-downloads, and distinguishing the two after the fact is not possible from local state — the evidence that would have identified them (the key/folder disagreement) is erased by the rekey. A blanket body-cache purge is the only mechanically sound version, and its cost is a full re-fetch for every user.

**RECOVERABILITY, WITH THE NON-RECOVERING CASE NAMED.** Not recoverable by sync: nothing re-fetches a row whose `bodyComplete` is 1. Recoverable by user gesture — pull-to-refresh on the affected message, once its address has settled — but only for a message the user happens to notice, and wrong FTS text is not noticeable at all. ⚠️ **It is ONE gesture only from a view opened AFTER the address settled.** This row said "ONE user gesture" flatly until an audit round applied the stale-open-view closure (`BodyAddressGate`): a detail view that was already showing the corrupt cached body keeps the pre-move header, `publishRekeys` never refreshes it, and its pull is declined by `refetchBody`'s own pre-gate no matter how long the user waits. From there it is back out, reopen, THEN pull — two gestures, both ordinary. Reachability is bounded by how often a body fetch overlapped an undrained move on `v1.6.38`.

**WHAT WOULD RE-OPEN THIS ROW:** a remediation pass landing (a one-shot body+FTS invalidation for IMAP rows, gated on an upgrade marker), or evidence that the affected population is larger than the overlap window implies.
