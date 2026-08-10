# IOS-THREAD-001

> Routed from `KNOWN_ISSUES.md` line 586 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `b750134ce36bc07bb56672deb22df0d6cf853d17f285026760171f44f39c9473`

## Status

✅ **CLOSED AS A DECISION (2026-08-05)** — display-only, and the only production caller is an IMMUTABLE applied migration (`v54`), so a fix needs a NEW migration plus a historic re-walk, which is disproportionate; the cell below states all five closure elements, and names the non-recovering set (rows already in the DB at the `v54` upgrade). **Its full statement is preserved verbatim below. Original disposition, retained as history:** 🔓 **OPEN** — same class, third member; **registered rather than fixed because the only production caller is an IMMUTABLE applied migration**

## Subsystem and search terms

Threading; `ThreadUtils.runFragmentMergeToFixpoint`; `runFragmentMergeOnce`; `findAdoptableThreadId`; `LIMIT 1`; fixpoint; `merged == 0`; migration `v54`; Gmail thread fragments; split inbox thread

## Full detail

`runFragmentMergeToFixpoint` declares convergence the first time a pass reports `merged == 0`. That reads as candidate coverage and is not: the per-row probe `findAdoptableThreadId` returns the FIRST connected `computedThreadId` it finds (`LIMIT 1`, across three prioritised queries with no `ORDER BY`), so when a row is connected to two fragments and the probe happens to name the one it ALREADY carries, the row does not adopt — and because the probe is deterministic on unchanged state, every later pass returns the same answer. Convergence is declared with cross-fragment candidates still unmerged, and the user sees an inbox thread that stays split. **Why this is not fixed here:** the only production caller is `AppDatabase`'s `v54` migration, and **a registered migration is immutable the moment any database has run it** (global `CLAUDE.md` Data Integrity rule 5 / `MIS-IOS-001`) — including every dev simulator. A real fix therefore needs a NEW migration (v83 is the next free number) plus a re-walk of historic rows, which is disproportionate to a cosmetic threading defect in already-migrated data. **Blast radius:** display-only. `computedThreadId` groups rows for the thread list; no message is deleted, mis-addressed or dropped, and no wire operation depends on it. **Recoverability:** newly-arrived mail is threaded by `ThreadUtils.assignComputedThreadId` at insert time and is unaffected; only rows already in the DB at the v54 upgrade can carry the split. **If it is fixed later, fix the probe, not the loop** — the loop's termination is sound once the probe covers all candidates (return the full connected set and adopt a deterministic minimum, rather than the first row SQLite happens to hand back).
