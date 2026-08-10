# IOS-QUEUE-001

> Routed from `KNOWN_ISSUES.md` line 155 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `a8a805e57c1af5d07673c3073ae65955e9758aa7087e172ab1246a8a59099d21`

## Status

Pre-existing; shipped verbatim in v1.6.38; ✅ **FIXED by `635cb78b1`** — ⚠️ and it was a **NEVER-DROP violation**, not the delay this row recorded

## Subsystem and search terms

Action queue; `buildLanes(_:)`; lane key; connected component; folder-less; UID collision; halt

## Full detail

`buildLanes(_:)` unions ops on `"accountId:msgId"`, **omitting the folder**. On IMAP a UID is mailbox-local, so UID 77 in INBOX and UID 77 in Archive — different physical messages — are treated as the same lane member. Two unrelated gestures then serialize against each other and, worse, can halt each other: a `.haltLane` caused by one message's unresolved op stops a queued gesture on a completely different message. The effect is delay and starvation, not a wrong-message mutation. **Do not redesign `buildLanes` opportunistically** — audit round 2 deliberately routed around it rather than through it.

✅ **FIXED by `635cb78b1`, "Key drain lanes by folder and finish moves on every retire path". ⚠️ THIS ROW'S SEVERITY WAS WRONG AND IS CORRECTED HERE: it was a NEVER-DROP violation, not "delay and starvation, not a wrong-message mutation".** A lane halts on the first evidence refusal, so an op permanently wedged on `(INBOX, 77)` also starved an unrelated message at `(Archive, 77)` — **the wedge corollary with a bystander**, which no sync pass recovers. The row's own sentence *"the effect is delay and starvation, not a wrong-message mutation"* correctly ruled out C3 and then treated the remainder as benign; a starved intention that never recovers is inside the non-recoverable set on its own account. **The invariant that now holds:** two ops whose addresses differ in the FOLDER are never merged into one lane, so one message's permanent evidence wedge cannot starve a different message that merely shares a UID. The lane key is now `"accountId:folderPath:messageId"`, matching the address a `PendingOperation` actually has. **Why the change is safe in the direction it can be wrong:** every one of the 22 `PendingOperation` producers takes `folderPath` from `Folder.path` or `MessageHeader.folderPath`, so the field is always populated, and a colon inside a folder path can only OVER-merge two lanes — the conservative direction, and exactly what the code did for every op before. Ops on the same `(account, folder, UID)` still share one lane, asserted by a control test, because that serialization is the whole reason lanes exist. **A1:** `buildLanes` is BYTE-IDENTICAL at `07a4bb703` — the shipped release has the same defect — so there was no behaviour to restore and the fix is authored, treating the release as a floor rather than a ceiling.
