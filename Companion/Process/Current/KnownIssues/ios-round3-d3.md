# IOS-ROUND3-D3

> Routed from `KNOWN_ISSUES.md` line 232 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `efc66a2f7e612f93d442e033b70501927129539b49befe8e1b7fe66615b976f5`

## Status

✅ **CLOSED AS A DECISION (2026-08-04)** — surfaced round 3; pre-candidate; abort-after-purge is the DELIBERATE fail-closed ordering

## Subsystem and search terms

NSE; staging; `.unreachable`; abort after purge; UIDVALIDITY reset reaction; `runUidValidityResetReaction`; `NSEDataBridge.stagingPurgeTarget`; App Group container; data protection before first unlock

## Full detail

The NSE staging-purge companion can abort on `.unreachable` AFTER a purge has already committed, leaving the reaction partially applied. Pre-candidate (it predates the round-3 band) and recoverable — the reaction re-runs and the folder stays at its old epoch and quarantined, which is the fail-closed direction.

✅ **CLOSED AS A DECISION (2026-08-04) — the abort-after-purge ordering is deliberate, and the code already argues for it.** **Verified at the tip**, `runUidValidityResetReaction`'s order is: step 3 purge transaction (**commits**) → step 3b `ChatIdTranslator.purgeMappingsForFolder` → step 3c `NSEDataBridge.purgeInboxRemovalMarkersForAccount` (**aborts** on false) → step 4 FTS purge (**aborts** on throw) → `NSEDataBridge.purgeStagedStateForFolder` (**aborts** on false) → step 4b releases → step 5 stamp. So yes: an abort can leave the reaction partially applied with headers already purged — and the code states why that is the right way round: *"Quarantine is bounded, visible and retryable; a deleted message is not."* **Basis:** making the purge atomic across two databases and a separate process is exactly the cross-process fence `IOS-NSE-002` asks for and declines — a new mechanism for an edge the epoch model already closes, which THE MANTRA forbids. **Accepted cost:** a partially-applied reaction, with the folder held at its old epoch and quarantined. **Recoverability:** the folder keeps `uidValidityResetPendingAt != nil`, and `SyncEngineDeltaSync`'s per-folder loop (and the full-sync loop) re-drives the reaction on **every** pass. **The state where the re-drive cannot succeed is named rather than waved away:** a permanently-unresolvable App Group container, so `NSEDataBridge.stagingPurgeTarget` returns `.unreachable` forever, leaving the folder quarantined with its rows purged and never resyncing — the user's mail in that folder locally gone. **And it is then discharged:** a permanently-nil App Group container in a correctly-signed build is a provisioning/entitlement **brick** (the NSE would not run at all either), not a state this row can reach; the **reachable** form is the transient one — before first unlock, data protection returns nil — and it clears on unlock, after which the next sync pass re-drives and completes.
