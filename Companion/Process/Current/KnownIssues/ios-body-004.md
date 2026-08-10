# IOS-BODY-004

> Routed from `KNOWN_ISSUES.md` line 1421 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `accepted`
- Original row SHA-256: `bba0b6a8bf072bdbd9ec6619f044ba155a645e642a255079130bf5ef985ac05e`

## Status

📋 **ACCEPTED LIMITATION (2026-08-08)** — an open message whose row is re-keyed by `finishMove` WHILE the detail view is polling for its body stops loading until the user leaves and reopens it; the automatic recovery was removed rather than repaired

## Subsystem and search terms

Body fetch; `MessageDetailViewModel.startBodyPoll`; `MessageHeaderRekey.finishMove`; `MessageHeaderRekey.apply`; rekey recovery; `resolveMessageAsync`; `rfc822MessageId`; primary key vanished; C3 misattribution; spinner; reopen the message; A2

## Full detail

**THE MECHANISM.** `MessageHeaderRekey.finishMove` re-keys a moved row by DELETING it under its old primary key and re-inserting it under the destination key. A detail view that is polling holds the OLD key, so from the moment the rekey lands every `fetchBody` call in `startBodyPoll` throws — the row is gone from under it — and the view spins. ⚠️ **This row said "until the poll's attempt budget runs out"; there is no such budget** (audit) — `startBodyPoll` loops `while !Task.isCancelled` on a 2s cadence and `fetchAttempt` is a bare counter it only logs, so the spinner lasts as long as the view does. That is worse than the original wording implied, and it is stated plainly because a bounded-looking spinner reads as self-limiting when it is not. Nothing is wrong with the message: reopening it resolves fresh against the re-keyed row, and the body renders at once if it is cached or after an ordinary fetch if it is not — "immediately" was the same overclaim one notch smaller.

**WHY THE AUTOMATIC RECOVERY WAS REMOVED RATHER THAN FIXED — A2, WITH BOTH FAILED REVISIONS NAMED.** Rounds 3 and 4 of the audit each found a WRONG-MESSAGE (C3) hole in an attempt to self-heal this, and the second was found in the fix for the first. Revision 1 matched account-wide on `rfc822MessageId` and could adopt a DIFFERENT copy of the same message — the Sent copy of a thread — silently swapping what the user is reading. Revision 2 scoped to (account, folder, RFC id) and required a unique match, and still adopts the wrong row when the primary key vanished for a reason OTHER than a move: `MessageHeaderRekey.apply`'s collision path DELETES the losing row, so the "sole remaining RFC match" is a different message. The shared root is that **post-deletion cardinality is not evidence that a rekey is what happened** — every candidate for "find the row it became" is a guess, and a guess that resolves to a stranger is exactly the C3 class this whole change exists to close.

**THE COUNTERFACTUAL.** Keeping a recovery means accepting a path that can render someone else's mail into an open message, automatically and silently, in exchange for saving one tap. A guaranteed-correct one-gesture recovery beats an automatic one that can be wrong at any probability. Removing it also matches shipped `v1.6.38`, which has no such recovery — the spiral was in the new code, not in the shipped behaviour (A2).

**RECOVERABILITY — THE RECOVERING EVENT, NAMED.** Back out of the message and reopen it: one ordinary gesture, and resolution then runs against the current key and succeeds. Nothing is lost or corrupted meanwhile; the body was never written, `bodyComplete` stays 0, and the row is fetched normally by the queues once its address settles. THE MANTRA's fail-closed-and-let-it-be case. Reachability is bounded by the overlap between having a message open with no cached body AND its move draining in that same window — moves drain in seconds, and the common case (the user moves the message they are reading) dismisses the detail view anyway.

**WHAT WOULD RE-OPEN THIS ROW:** `finishMove` gaining a durable, positive record of the old-key → new-key mapping (a rekey journal or an alias row), which would turn re-resolution from a guess into a lookup and make an automatic recovery sound; or evidence that the spin is reachable often enough to look like a hang. The removal is guarded by a `DO NOT RE-ADD` comment at the `startBodyPoll` catch — a re-added recovery that resolves by matching rather than by a recorded mapping is this row regressing, not this row being fixed.
