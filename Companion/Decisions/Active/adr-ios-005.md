
## ADR-IOS-005: Progressive Background Backfill

> **Current note (2026-11-12, #766).** The backfill worker now also runs the catch-up of older mail
> (ADR-IOS-107 decision 2): `SyncEngine.runBackfill` is the folders' walk (`runBackfillWalk`) and then
> the catch-up run (`runCatchUpRun`), one slice per foreground cycle and slices until the deadline in
> the background processing job (`SyncConfig.backgroundBackfillDeadlineSeconds`, formerly the literal
> `5 * 60` in `SyncScheduler`). The worker's gates (battery, Wi-Fi-only, Low Power Mode) gate both.
> *Amended 2026-11-12:* Wi-Fi-only holds back the walk only; the catch-up ignores it and keeps its own
> network rules (ADR-IOS-107 decision 2). Battery and Low Power Mode still delay both. Catch-up progress
> picks the worker's active delay only once every walk of the account is complete.
> *Amended 2026-11-19 (#1063):* Wi-Fi-only, battery and Low Power Mode hold back the walk only; the
> catch-up always runs (ADR-IOS-107, amendment of that date). "Battery and Low Power Mode still delay
> both" above is superseded.
> The notes below say "the full sync's catch-up"; read "the catch-up".
>
> **Current note (2026-11-12).** The full sync's catch-up never re-arms or otherwise writes the walk:
> a Gmail check loads mail missing from a folder itself, through the page walk's own insert tail
> (`SyncEngine.insertFetchedBackfillMessages`), and under a storage limit lists nothing older than the
> folder's oldest local row (ADR-IOS-107 decision 8, "the direct load"). The 2026-11-11 note below is
> superseded and kept as written.
>
> **Amendment (2026-11-20, #1064).** The walk's download gates (the Wi-Fi-only setting on an
> expensive network, a battery below 20% off power, and Low Power Mode off power) now also hold
> older-mail body downloads (`BackfillBodyQueue`). A refused dispatch keeps its items pending without
> spending a retry and re-checks the gate on `SyncConfig.backfillBodyGateRecheckSeconds`. In the
> background processing job the job's walk decision applies; the job's synthetic Fast Sync is never
> treated as a user's (the job flag and Fast Sync change, and are read, in one MainActor step).
> Bodies the user opens and new mail (`ActiveBodyQueue`) and folder scans are not held. The text
> below is kept as written.
> *Corrected 2026-11-20 (#1064 review):* "the job's walk decision applies" held only when NetworkMonitor
> was running. A job that launches the app from terminated never starts it (only RootView's `.task`
> does), and its unset flag read as "not metered", so bodies downloaded on cellular while the job's walk
> was held. Now the job measures Wi-Fi once (`SyncScheduler.measureJobOnWiFi`, i.e. `isOnWiFi()`,
> bounded by `SyncConfig.wifiCheckTimeoutSeconds`) concurrently with its work: the job flag, its Fast
> Sync and the work start at once, so scans (listings, change checks, the catch-up) never wait for the
> reading. `SyncEngine.backgroundProcessingJobOnWiFi` is unknown (nil) until the reading lands, then
> true/false; while unknown, the body gate's job branch and the job's walk hold (the walk waits for
> the reading after its account's scans ran, `SyncScheduler.runBackgroundBackfill`; the body queue's
> gate watcher picks up the lift). Once it lands, the job's walk and the body gate's job branch both
> decide with that one value (2026-11-20). Outside the job, a network NetworkMonitor has not reported yet
> (`NetworkMonitor.checkExpensiveIfKnown() == nil`) counts as expensive, so Wi-Fi-only holds both the
> walk and the bodies until the first path update, as `isOnWiFi()` holds on its timeout.
> *Corrected again 2026-11-20 (#1064 review):* two rules replace parts of the correction above, which is
> kept as written. (1) For Wi-Fi-only, "on Wi-Fi" means unmetered Wi-Fi everywhere: one predicate,
> `SyncEngine.onUnmeteredWiFi(NetworkPathFacts)` (path satisfied, uses Wi-Fi, not expensive), is read by
> the foreground gate (`backfillDownloadsAllowed`, from `NetworkMonitor.checkPathFactsIfKnown()`) and by
> the job's measurement (`measureJobOnWiFi` over `measureJobPathFacts`, which replaces `isOnWiFi()`; its
> only caller), whose one value the job's body gate and walk share. A Personal Hotspot (satisfied Wi-Fi
> marked expensive) is therefore not Wi-Fi: the old `isOnWiFi()` returned true for it, so the job walked and
> downloaded on a metered hotspot. The job walk is deliberately tightened on hotspots too. The timeout
> and the hold while unknown are unchanged. (2) While the reading is unknown, each account's scan-only
> pre-pass is cancelled the moment the reading lands (at most `wifiCheckTimeoutSeconds`, seen within the
> re-check interval); then the account runs exactly what it would have run with the reading known at
> the start, the same pipeline (walk if allowed, then the catch-up) with the same budget
> (`runBackgroundBackfill(budget:)`, each run's deadline taken when it starts). Before, the pre-pass used
> the shared deadline and a productive catch-up could spend all of it, leaving the walk none. Tests:
> `BackfillBodyDownloadGateTests.pathFactsDecideEveryWiFiOnlyDownload`,
> `GmailCatchUpTests.jobWalkBudgetIsTheSameWhetherTheReadingIsEarlyOrLate`.

> **Current note (2026-11-11).** A completed walk can be re-armed by the full sync's catch-up when
> old mail moves into the folder (ADR-IOS-107 decision 8), but never while a storage limit is in
> force: then the catch-up loads no old mail back, because the limit means old mail is not kept
> (ADR-IOS-107, "No old mail is loaded back under a storage limit"). The text below is kept as written.

**Context:** Initial sync fetches only the latest N messages (50 inbox, 25 others) with a hardcoded 30-day age limit. Users with months of email history see a sparse mailbox. Opening a non-synced email could silently fail if the provider was disconnected.

**Decision:**
1. **Full sync depth** — Backfill always walks to completion: IMAP walks from UIDNEXT-1 to UID 1, Gmail/Exchange exhausts all pages. No date-based age cutoff — storage budget is the only gate.
2. **Progressive backfill** — After each initial sync, a background task fetches older messages. Uses IMAP UID range walking or Gmail `nextPageToken` pagination. Follows the same cooperative cancellation pattern as snippet fetching (ADR-IOS-002).
3. **Prioritized sync order** — Inbox first, then favorites, then secondary roles (sent/drafts/trash/archive/spam).
4. **No silent failures** — `fetchBody` throws descriptive errors instead of silently returning when provider/account is missing. Attempts reconnection if provider is nil.

**Rationale:**
- Users expect to see their full mailbox history, not just the latest 50
- Background backfill avoids blocking the initial sync/UI
- Cancellable backfill ensures user actions (opening messages) take priority
- Pure UID walk (no date-based cutoff) guarantees no messages are arbitrarily skipped — IMAP UIDs and message dates are not monotonically correlated

**Consequences:**
- Additional IMAP/API traffic after each sync cycle (one-time per folder until `backfillComplete`)
- `Folder.backfillComplete` and `Folder.oldestSyncedDate` track per-folder progress
- Backfill is cancelled alongside snippets before user-initiated provider calls

---
