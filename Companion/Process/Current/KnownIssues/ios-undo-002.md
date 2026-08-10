# IOS-UNDO-002

> Routed from `KNOWN_ISSUES.md` line 312 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `698a6dc239228af3015115be7ee59d7611aee37a4e6d650a0ef913b789d9d5eb`

## Status

Surfaced by the final train; found **independently by BOTH reviewers**; **class A**; ✅ **FIXED by `635cb78b1`**, with an **accepted residual**

## Subsystem and search terms

Undo; drain; `AccountManagerQueue.executeSingleOp`; `MessageHeaderRekey.finishMove`; `UndoService.applyRekeys`; `SearchIndex.rekeyHeaders`; `@MainActor` hop; `originalHeaderId`; whole-command refusal

## Full detail

**An undo landing in the window between the drain's re-key commit and its publication to the undo stack is refused whole.** `executeSingleOp` commits the GRDB write (rows re-keyed to the destination address, pending operation deleted), then `await`s `SearchIndex.rekeyHeaders`, and only then calls `UndoService.applyRekeys`, which must hop to `UndoService`'s `@MainActor`. An `Undo` gesture inside that suspension pops a stack entry still naming the **stale** `originalHeaderId`; `AccountManager.undoMove` authenticates each member by that id, `MessageHeader.fetchOne` returns nil, and the whole command is refused — and the later `applyRekeys` cannot repair an entry already popped off the stack. **Why REGISTRABLE:** it is **fail-closed**. The message is correctly moved, nothing mutates the wrong message, no queued operation is dropped, and the user recovers by moving it back with an ordinary gesture. The cost is one undo that silently does nothing. Narrowing the window (publishing re-keys inside the same transaction, or before the FTS await) is the obvious direction but touches the drain's ordering, which is exactly the surface three audit rounds have already churned.

✅ **FIXED by `635cb78b1`, "Key drain lanes by folder and finish moves on every retire path".** **The invariant that now holds:** the undo stack learns a move's new addresses **before** the drain gives up the thread to anything on a separate database. The re-keys are published to the undo stack BEFORE the cross-database FTS round trip, and both the completion path and the narrowing path now go through one shared helper, `publishRekeys`, so the two orderings cannot drift apart later. The undo stack names its members by the same primary key the re-key just changed, so ordering the publication after an `await` on a separate SQLite pool meant a user who hit Undo in that window undid nothing. ⚠️ **ACCEPTED RESIDUAL, stated by that commit and NOT to be overclaimed away:** `UndoService` is `@MainActor`, so the publication still awaits **one actor hop**. The fix removes the **FTS round trip** from in front of the publication; **it does not remove every suspension**, and a sufficiently fast Undo inside that remaining hop still pops a stack entry naming the stale `originalHeaderId` and is refused whole — fail-closed, exactly as this row describes, and recovered by moving the message back with an ordinary gesture. **A1:** `finishMove`, `applyRekeys` and `rekeyHeaders` have ZERO occurrences in the shipped file — there is no drain-time re-key at all at `07a4bb703` — so the shipped architecture is NONEXISTENT here and the fix is authored.
