
### Sync-status subtitle ("Updated N min ago")

- Rendered by `SyncStatusFormatter.statusText` (`SyncStatusSubtitle.swift`) from `AccountManagerState.shared.lastSyncCompletedAt` + `lastSyncFailed` + a `now` ticked by a 60s timer in `SyncStatusObservationModifier` (attached once at RootView, fanned out via Environment).
- **THREE tiers write `lastSyncCompletedAt`, all on success only**: (1) pull-to-refresh / on-appear debounced sync — `InboxViewModel.performSync` (`:1226`); (2) foreground poll tier — `SyncScheduler.poll()` (`:676`); (3) **background/push/startup (NSE-coalesce) tier — `SyncScheduler.backgroundPoll`** (added 2026-06-15; the no-network early-return is correctly skipped). Before (3), a successful silent-push/NSE wake left the subtitle stale ("Updated 48 min ago" after a coalesce) because that tier never stamped — that was the bug, not a freeze.
- On a *failed* sync only `lastSyncFailed=true` is set (timestamp preserved, prefix flips to "Last updated …") — by design (ADR-003, no fallbacks). A genuinely failing pull-to-refresh therefore won't reset the subtitle.
- `InboxViewModel.performSync` clears `isRefreshing` in a `defer` (2026-06-15) — a cancelled/torn-down sync used to be able to leave it stuck `true`, which makes `refreshSync()` silently no-op (wait-then-return) for ALL future pull-to-refreshes → a stuck-stale subtitle with no way to refresh.
- Latent fragility (not the active bug): the `minuteTimer` is recreated whenever RootView's body re-runs (classic `Timer.publish().autoconnect()`-in-modifier reset); a *successful* sync still resets the text via the observation `.task`, so it manifests at most as a non-advancing minute counter, not a failure-to-reset.

---
