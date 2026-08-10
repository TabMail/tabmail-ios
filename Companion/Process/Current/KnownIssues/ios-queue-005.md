# IOS-QUEUE-005

> Routed from `KNOWN_ISSUES.md` line 314 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `23fa1474d8fca703dfbf0c6ddf4c5eefb3fdd398348f632bdbc375f39f3be603`

## Status

Surfaced by the final train (Claude reviewer); **class A**; was **LATENT — not reachable at the tip**; ✅ **FIXED by `635cb78b1`**

## Subsystem and search terms

Action queue; `retirePartiallyCompletedOp`; `executed.provenDestinations`; `IMAPProvider.move`; narrowing pass; drain contract

## Full detail

**The partial-retirement leg discards `executed.provenDestinations`.** `retirePartiallyCompletedOp` returns before the delete/re-key write, so members retired in a narrowing pass keep their **source** address and stay dead to the next gesture until a sync repairs them. **Not live today:** `IMAPProvider.move` returns `provenIds = ids`, so the strict-subset test never fires for an IMAP move — no current provider reaches it. It is registered because it is a gap in the drain's *stated standing contract*, which any future provider returning a strict subset would fall into silently. **Why REGISTRABLE:** unreachable at the tip, and recoverable by sync if it ever became reachable.

✅ **FIXED by `635cb78b1`.** **The invariant that now holds:** a member retired in a NARROWING pass ends the drain carrying the destination address `COPYUID` proved — the drain's stated standing contract is now whole rather than a trap laid for a future provider. `executed.provenDestinations` is passed into `retirePartiallyCompletedOp`, which finishes the move for the members `COPYUID` actually proved, **freezing the op to those members first so an unproven member keeps its source address**. Without it a narrowed retirement left every proven member optimistically moved but still keyed to its SOURCE UID, i.e. refused by `admittedOrdinaryActionTargets` — so the user's next gesture on it would be a silent dead no-op, which is exactly the defect `59423bb7d`/`f7c3354c5` exist to remove. ⚠️ **THE SAFETY BRANCH WAS NOT DELETED, AND MUST NOT BE:** deleting it would make a strict-subset return retire the WHOLE op, re-opening a never-drop hole for any future provider — the precise thing `4e08ff720` added it to prevent. `retirePartiallyCompletedOp` became `internal` for the same reason `executeSingleOp` and `DrainContext` already are: no production provider returns a strict subset, so a test is this path's only reachability.
