
## Delivered-Notification Cleanup

`NotificationCleanupService` (`Shared/Notifications/`) sweeps stale delivered notifications. Wired at four entry points: NSE `didReceive`, silent-push `application(_:didReceiveRemoteNotification:)`, BGAppRefresh `SyncScheduler.handleBackgroundSync`, and app foreground (`scenePhase == .active` in `TabMailApp`). Policy:

- **Active** (interruption-level `.active`) — TTL 24h. Survives FG.
- **Passive** (interruption-level `.passive`) — TTL 24h, OR all cleared on FG.
- **`consent_error`** — never auto-cleared. Re-auth is user-actionable; user must tap or dismiss.
- **`imap_reconnect`** failure / in-progress — kept until `PushHealthStore.lastNonReconnectPushAt[accountEmail]` is newer than the notification's delivery date (push proven restored, per-account). Two stamping sources: (a) **strong** — NSE + silent-push handlers stamp on receipt of any non-error push (`provider not in {imap_reconnect, consent_error}`); (b) **weaker** — NSE stamps on successful silent re-subscribe (2xx from `/subscribe-imap` inside `attemptSilentResubscribe`). The weaker proof means: push-worker accepted the enrollment, but the IDLE socket may still drop afterwards — push-worker's retry ladder is the safety net.
- **`imap_reconnect`** success-ack ("Restored push notification connection") — distinguished by NSE-stamped `userInfo["reconnect_state"] = "ok"` at `NotificationService.swift:631-641`. Treated as normal active (1h TTL).

`PushHealthStore` lives in shared App Group UserDefaults (`group.ai.tabmail`, same suite as `AIService.optOutStore`) so NSE + main app share the timestamp map.

The bucketing logic is the pure function `NotificationCleanupService.identifiersToRemove(_:now:passiveAllAges:lastNonReconnectPushAt:)` — fully covered by `TabMailTests/Notifications/NotificationCleanupServiceTests.swift` (20 tests, 100% on `identifiersToRemove` + `shouldExclude`). Side-effect wrappers (`sweep`, `snapshot(from:)`, `PushHealthStore`) are validated manually.

### State-based clear: `InboxNotificationObserver`

Complementary axis: when a row leaves the inbox (`isInInbox` flips `true → false`, OR a previously-inbox row is deleted), `InboxNotificationObserver` clears `email-{accountId}-{messageId}` immediately — no waiting on TTL. Covers BOTH local actions (`AccountManagerActions.move`/`archive`/`delete` via `optimisticMoveToFolder`) AND remote sync paths (`SyncEngineDeltaSync`, `SyncEngineMaintenance`, `SyncEngineSelfHeal`, full sync) without per-site discipline — single GRDB `TransactionObserver` on `messageHeader`.

Performance: per-commit cost is one rowid B-tree `SELECT … WHERE rowid IN (touched rowids)` (sub-millisecond, scoped to the write batch). Startup populate via `WHERE isInInbox = 1` once during `AppDatabase.init`, served by index `messageHeader_isInInbox_date`. Callbacks fire on the GRDB writer queue (background, never main); in-memory `[rowid: (acct, mid)]` map is touched only by callbacks → no Mutex needed.

GRDB holds observers **weakly** at `.observerLifetime` — `AppDatabase.inboxNotificationObserver` provides the strong ref. Tests bypassing `AppDatabase` MUST capture the observer too (see helper in `InboxNotificationObserverTests`).

`clear` is invoked synchronously on the writer queue (`UNUserNotificationCenter.removeDeliveredNotifications` is non-blocking IPC). Contract: clients injecting `clear` MUST NOT re-enter GRDB writes.

---
