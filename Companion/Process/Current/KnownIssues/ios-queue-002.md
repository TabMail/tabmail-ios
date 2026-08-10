# IOS-QUEUE-002

> Routed from `KNOWN_ISSUES.md` line 192 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `9f1a23c6b29bfb09ccba9ad09bfd0cb974417188a01d8e7fb301e8914a396fff`

## Status

**NOT in the shipped release**; introduced PRE-candidate by `7cffc8309`; was unreachable; ✅ **FIXED by `635cb78b1`**

## Subsystem and search terms

Action queue; checkpoint A; draft/reset arm; bare inequality; non-zero guard

## Full detail

Checkpoint A's draft/reset arm compares epochs on **bare inequality**, without the non-zero guards its rewritten sibling now requires — so a zero on either side would read as a disagreement rather than as an absence of evidence. **Unreachable today** (no path supplies a zero to that arm), which is why it is recorded rather than fixed; it is one refactor away from being reachable.

✅ **FIXED by `635cb78b1`, "Key drain lanes by folder and finish moves on every retire path".** **The invariant that now holds:** checkpoint A's draft/reset arm routes through `SyncEngine.knownUidValidity` — the same normalizer its IMAP sibling already required — so a **zero** on either side is read as an ABSENCE of evidence, never as a positive epoch disagreement. That matters because exit 4 (the delete arm) is the only arm at that checkpoint permitted to delete an op, and **unknown is not proof**: a bare inequality would have let "we could not determine the epoch" take the one exit reserved for a *proven* turnover. The reachability that made it latent was real but thin — SwiftMail defaults `Mailbox.Selection.uidValidity` to `UIDValidity(0)` — and it was "one refactor away", which is why the fix pins the **guard** rather than the reachability. **A1:** `knownUidValidity` has zero occurrences in the shipped file, so the shipped architecture is NONEXISTENT here and the fix is authored, not restored.
