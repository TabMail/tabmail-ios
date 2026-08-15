# IOS-CLEANUP-001

<!-- KNOWN-ISSUES-AMENDMENT-BEGIN -->
## ✅ CLOSED — FIXED (2026-08-14)

Every reachable destructive settings path now treats its GRDB transaction as the authoritative boundary: failure is thrown to a visible alert and no credential, provider, FTS, memory, asset, or success-only cleanup continues.

`AccountManager.removeAccount` now preflights only the identifiers it will need after commit, fail-closed evicts reversible NSE mirrors, prepares exact-generation cleanup debt, and runs the account-row transaction before deleting Keychain credentials, detaching providers, deleting attachments, publishing navigation changes, or touching FTS. Its inline `do`/`catch` cancels only that generation, re-derives both mirrors from the still-authoritative database, and rethrows. `SettingsView` surfaces that precommit error and truthfully states that nothing was removed. A postcommit FTS failure is awaited and reported as the truthful partial result “account removed, search index not cleared,” rather than being detached and silently discarded.

The latent `AppDataWiper.wipeAll` factory-reset utility now inventories every account's CalDAV and outbox owners, pre-evicts/prepares them, and attempts its database transaction before runtime, credential, file, index, or sign-out cleanup. A write failure cancels each exact generation and re-derives the mirrors off the main actor. After commit it publishes the authoritative row change and runs every local privacy wipe even if remote cleanup is offline. Local FTS/memory failure is thrown; incomplete durable worker cleanup or final device unregister gates only session/default clearing and the success report, preserving the authentication and debt needed for retry.

`AccountDetailView.resetMessageDataTxn` now combines header, body, AI-cache, account-cursor, and folder-cursor mutations in one transaction. `SettingsView.localIndexWipeTxn` remains one transaction but its caller no longer suppresses the throw or continues into memory/FTS cleanup. Both views surface authoritative-write failure. `MemoryIndex.deleteAllThrowing` closes the remaining local-only arm: a later memory or FTS failure is reported as a partial result that requires retry rather than false success.

Failure-injection coverage in `DestructiveCleanupReliabilityTests` drives the real `AccountManager.removeAccount` path: an SQLite `RAISE(ABORT)` proves the account row, Keychain credentials, outbox attachment, and prepared debt remain unchanged. A focused transaction test also pins account reset rollback. The focused simulator gate passed 45/45 tests on 2026-08-14.
<!-- KNOWN-ISSUES-AMENDMENT-END -->
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
