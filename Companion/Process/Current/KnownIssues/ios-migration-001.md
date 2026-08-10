# IOS-MIGRATION-001

> Routed from `KNOWN_ISSUES.md` line 316 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `not-defect`
- Original row SHA-256: `45952ccfc85447f582280543f791e44595159d841aa71fbc85114294e75d61e9`

## Status

✅ **NOT A DEFECT (adjudication RE-VERIFIED against source 2026-08-04)** — raised by the final train (Codex), adjudicated by the coordinator; recorded so it is not re-raised every round

## Subsystem and search terms

Migrations; `registerMigration`; `registerTimedMigration`; `c1ca55a54`; v1–v67; immutability; GRDB identifier

## Full detail

⚠️ **NOT A DEFECT — recorded because it LOOKS like one and has now cost one reviewer's attention.** Every shipped registration `v1_createTables` … `v67_addUidResolutionRetryCount` was changed from GRDB's `registerMigration` to the project's `registerTimedMigration` wrapper (`c1ca55a54`, before `2d85b8729`, absent from `07a4bb703`), which reads at a glance like editing applied migrations — the rule in `tabmail-ios/CLAUDE.md` § *Data Integrity Rules* 5. **It is not.** GRDB records applied state by the migration's **identifier**, and the wrapper forwards the identifier, the foreign-key mode and the closure unchanged; GRDB then skips the body of any already-applied identifier. Neither the identifier nor the executed body changed, so a fresh install and an existing database still converge. The reviewer that raised it reached the same conclusion (*"I found no concrete brick"*) and filed it as registrable. **What the immutability rule actually protects is the identifier and the body — not the name of the function used to register them.** A comment inside `v67`'s body was also reworded, which likewise cannot affect an applied database.

✅ **RE-VERIFIED AGAINST THE ACTUAL SOURCE, 2026-08-04, and the adjudication HOLDS — this row now carries an explicit disposition rather than reading as Open.** It was carried without a disposition marker through the previous register pass, which under this file's own legend (*"**Open** — no ✅ marker"*) made it read as a live finding: exactly the failure mode the completeness audit exists to eliminate, on the one row where the consequence of being wrong is a **brick** (launch crash), which is in the non-recoverable set. **The evidence, read from `AppDatabase.swift` rather than inherited from the prior adjudication:** `registerTimedMigration(_:foreignKeyChecks:migrate:)` forwards **the identifier unchanged** and **the `foreignKeyChecks` mode unchanged** to GRDB's own `registerMigration`, and calls `try migrate(db)` — the caller's closure, unchanged — on **both** branches of its `guard DebugModeManager.isLoggingEnabled()`. The only difference between the two branches is a `ContinuousClock` sample and two `BackgroundSyncLogger.log` lines around the identical `try migrate(db)`, and the `catch` **rethrows**, so a failing migration still fails. GRDB records applied state by the **identifier**, so every already-applied `v1_createTables` … `v67_addUidResolutionRetryCount` is still skipped by identifier and no already-applied body is re-executed. A fresh install and an existing database therefore still converge. **Nothing to fix, and nothing to re-raise:** the immutability rule (`tabmail-ios/CLAUDE.md` § *Data Integrity Rules* 5) protects the identifier and the executed body, and the wrapper changes neither.
