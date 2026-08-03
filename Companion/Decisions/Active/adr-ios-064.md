
## ADR-IOS-064: The F2b L-series is withdrawn — inert code is removed, applied migrations are not

**Date:** 2026-07-26.

**Context.** The F2b work shipped layers L0–L5 (plus F1a and F4) **deliberately dormant**, each awaiting a later activation layer: L5's disposition engine was to be activated by L8/L10, F4's `DraftOwnerProtection` by "F2", `.undoReopen`'s epoch mint by L6's re-key transfer. L6 was then fully implemented, reviewed eight times, and **withdrawn by the owner** after a lifetime-coupling sweep found 11 defects traceable to its central premise. With L6 withdrawn, L7–L10 will never be built, so every dormant layer became permanently unreachable rather than merely waiting.

**Decision.**
1. **Inert code is removed, not left waiting.** Owner directive: *"do not leave unused inert code that won't be activated."* A production symbol with no live production caller is deleted, together with the tests that exist only to cover it.
2. **A registered GRDB migration is NEVER removed, renamed, or edited** — Data Integrity rule 5. Migrations v80–v86 stay verbatim, and the columns they created stay in the schema even when nothing reads them. Orphan columns are the correct outcome; a fresh install and an existing database must converge on the same schema. The v84 partial index will index a permanently-empty table. Leave it.
3. **"Inert" and "live-but-purposeless" are different categories and get different treatment.** Inert (no production caller) is provable by grep and safe to delete. Live-but-purposeless (executes; its stated rationale is retired) requires a **consumer trace of the values it produces**, not a rationale argument — see ADR-IOS-065 for the case that proved this.
4. Everything removed is preserved on branch `wip/f2b-inert` before deletion.

**What was removed.**
- `OutboxDisposition.swift` (1065 lines) + its 3 suites — zero inbound production edges. Word-boundary grep over all 23 declared symbols; two apparent hits were substring false positives (`DraftEpochAdmissionError` matching `AdmissionError`, `advanceOwnerConfirmedB` matching `OwnerConfirmedB`).
- `DraftOwnerProtection.swift` + 6 guard sites across four sync engines + `OutboxMessage.disposition`. It was *reached at runtime* but gated nothing: `build` filtered on a column no production code has ever written, so it always returned `[]`. The removed code said so itself — *"Empty today … ⇒ every union below is a no-op on real data."*
- `OutboxStatus.undoReserved` and its always-zero `admitSave` gate; assorted orphan declarations.

**What was NOT removed, and why.**
- **The L5 `instanceEpoch` capture is LIVE.** Believed inert and refuted: `AccountManagerOutbox.swift` is the only production writer of `outboxMessage.instanceEpoch`, and `DraftStoreStageAB.swift` reads it in the exact-epoch owner lookup and the attempted-RFC/confirmed-B updates.
- **`DraftLineageReceipt`/`DraftLineageIdentity` "write-only" properties.** Proposed for removal on a raw-SQL-only-insert premise that is **false**: production GRDB-inserts `DraftLineageIdentity` using those very properties, and `phase` maps to a `NOT NULL` column with no default. Nothing reads their values, but the schema structurally requires them. Not dead code.
- **`cleanupState`** — participates in a live fetch→conditional→update path; removing it is a Stage-B behaviour change, not a dead-property deletion.

**Consequences.**
- ~3,600 lines of production + test code deleted with no behaviour change.
- Comments promising a withdrawn layer are worse than no comment, because they read as intent. A sweep of `L6`/`L7`/`L8`/`L10` forward-promises is required; several were found adjacent to correct code (e.g. "that is L8's job", "the full transfer txn is L6").
- Any future revival of this design starts from `wip/f2b-inert` and must re-justify itself from scratch.

---
