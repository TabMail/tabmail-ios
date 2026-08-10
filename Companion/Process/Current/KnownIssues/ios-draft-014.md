# IOS-DRAFT-014

> Routed from `KNOWN_ISSUES.md` line 1015 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `89611241d7f5a4313c33cdcc566de8e5342d640393ef8e0c9ab728781cc2ca1d`

## Status

✅ **CLOSED AS A DECISION (2026-08-05)** — a **pre-upgrade population**, deliberately not backfilled; recoverability stated per `MIS-IOS-008` including the case that does **not** recover

## Subsystem and search terms

Drafts; compose; `Draft.instanceEpoch`; `v76_addDraftGenerationAndTypedIdentity`; no backfill; `LocallyAuthoredDraftOpenAuthority.resolve`; generation CAS; `DraftStore.admitSave`; single-writer column; upgrade from `v1.6.38`

## Full detail

**What the user observes:** after upgrading from `v1.6.38`, a draft that already existed before the upgrade cannot be reopened by tapping it in the Drafts folder — the card says *"No editable copy of this draft was found on this device."* **Why:** `v76_addDraftGenerationAndTypedIdentity` adds `Draft.instanceEpoch` with **no backfill**, and every reopen path's first guard is `guard let instanceEpoch = draft.instanceEpoch, !instanceEpoch.isEmpty`. **Why it is not backfilled:** `instanceEpoch` is a **single-writer CAS guard** (`DraftStore.admitSave`'s observed-predecessor compare-and-swap). Fabricating a value adds a second writer to the exact column whose safety property is that only the admission path writes it — the `feedback_single_writer_column_is_a_guard` failure this repo has already been bitten by. Admitting these rows any other way would mean weakening the CAS, which is a strictly worse trade than the refusal. **Recoverability, both directions stated:** a **reply or forward** draft recovers in ONE ordinary gesture — reopen the parent message and tap Reply/Forward, because `Draft.draftKey(replyTo:isForward:newId:)` is deterministic and the compose admission re-stamps the generation on its first save. A **new-compose** draft (`new:<UUID>`) does **NOT** recover: the UUID has no other handle in the UI, and `Draft` rows have zero sync-engine construction sites, so no sync pass rebuilds it. The population is bounded (it is exactly the drafts open at upgrade time) and shrinks to zero as each one is re-saved.
