# IOS-PUSH-001

> Routed from `KNOWN_ISSUES.md` line 1445 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `open`
- Original row SHA-256: `6f947e0a6d96e4f03abe0764e2e076a6b33d1a7ac7b868ca526b96535da8639d`

## Status

🔓 **OPEN (2026-08-09)** — account removal and the latent factory-reset path treat remote push unsubscribe, consent revocation, and device unregister as best-effort with no durable retry; a stale push can still produce an old-account warning after local removal

## Subsystem and search terms

push; unsubscribe; consent revocation; device unregister; account removal; `PushNotificationService`; `NSEDataBridge.mirrorAccountMap`; App Group defaults; stale notification; privacy

## Full detail

**MECHANISM.** `unsubscribeAccount` catches and logs every failure; `revokePushConsentForAccount` uses `try?`; `unregisterDevice` catches and returns. `AccountManager.removeAccount` then deletes local credentials/rows without recording remote-cleanup debt. A later push for the removed email cannot resolve the now-removed account through `NSEState.findAccountId`, and `NotificationService` deliberately delivers the passive fallback title `Connection to <email> lost` / `Open TabMail to reconnect`. Thus remote cleanup failure is not merely an invisible backend record: it can remain user-visible after removal and disclose which account used to be configured on the device. The currently uncalled `AppDataWiper.wipeAll` is worse if ever wired: it clears only standard `UserDefaults`, not the App-Group account map, and never remirrors an empty map.

**RECOVERY / BOUND.** Retrying account removal is not possible after the row has gone; re-adding then removing, disabling notification permission, backend subscription expiry/cleanup, or uninstalling the app ends delivery. Mail remains server-authoritative and no wrong message is mutated. A future fix should remain small: make remote cleanup return an outcome, clear the shared account/IMAP mirrors synchronously, and retain only a compact retry tombstone if worker cleanup truly must survive offline removal.
