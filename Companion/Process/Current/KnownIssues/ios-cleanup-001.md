# IOS-CLEANUP-001

> Routed from `KNOWN_ISSUES.md` line 1444 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `open`
- Original row SHA-256: `83ad381f623091bade272b91d9dfd3d8e2c8d296d7134695fd79c7c984cd0c5e`

## Status

🔓 **OPEN (2026-08-09)** — several live destructive settings paths swallow the authoritative GRDB transaction and continue with later cleanup or success presentation, so a database failure can leave a partial local reset/removal

## Subsystem and search terms

account removal; Reset Message Data; Delete All Email Index Data; `AccountManager.removeAccount`; `AccountDetailView.resetMessageData`; `SettingsView.nukeDatabase`; `try?`; partial cleanup; recovery by retry/sync

## Full detail

**LIVE MECHANISMS.** `AccountManager.removeAccount` deletes credentials and disconnects the provider before `try? await dbPool.write { removeAccountRowsTxn(...) }`; if that write throws, it still posts the database-change notification, mirrors the still-present account map, launches FTS deletion, and returns `Void` to a Settings button that already dismissed its confirmation. `AccountDetailView.resetMessageData` and `SettingsView.nukeDatabase` similarly ignore their main deletion transaction and continue with independent AI/FTS/memory/asset cleanup and sync restart. `AppDataWiper.wipeAll` has the same shape but has no production caller at this revision, so it is a latent instance rather than part of current reachability.

**USER EFFECT.** The result is bounded to local state: an account can remain after its credentials and FTS entries are removed, or headers/chat rows can remain while sibling indexes were cleared. The server is not mutated by these failed local deletes. The screen may republish the surviving account/rows, but there is no error explaining the partial outcome.

**RECOVERY.** Repeating the removal/reset after GRDB becomes writable, reopening the app, or ordinary sync repairs server-backed mail/index state. Agent Chat rows are local-only, so a partial index wipe can require repeating the same destructive gesture. No migration or cleanup journal is justified by this evidence; the minimal future correction is to return the transaction error and stop later success-only cleanup/presentation.
