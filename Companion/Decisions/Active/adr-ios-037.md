
## ADR-IOS-037: NSE/Main-App AI Ownership Lease (Cross-Process Coordination)

**Context:** APNs pushes with `mutable-content: 1` always dispatch to the Notification Service Extension in its own process, regardless of main-app state (foreground / background / suspended / terminated). There is no Apple API to suppress NSE when the main app is foreground. Historically the NSE unconditionally called backend `/completions/chat` for summary + action on every push, and the main-app `ActiveAIQueue` also ran summary + action for the same message seconds later — two identical backend calls per push. Additionally, the main-app privacy opt-out flag (`privacy_opt_out_all_ai`) lived in `UserDefaults.standard`, which is a different namespace in the NSE process, so the NSE silently bypassed the toggle and kept calling backend AI after the user opted out.

**Decision:**

1. **Opt-out flag moves to the App Group shared suite** (`group.ai.tabmail`). `AIService.optOutStore` is the single source of truth. All `@AppStorage` usages and any direct `UserDefaults.standard.bool(forKey: optOutAllAIKey)` reads now go through `AIService.optOutStore`. `NSEState.isAIDisabled()` reads the same store. A one-time `AppDelegate.migrateOptOutFlagToSharedSuite()` copies any pre-existing value from `.standard` on first launch.
2. **AI ownership lease on `nse_processed_message`**. Two new columns — `aiOwner TEXT` (`"nse"` | `"mainApp"` | NULL) and `aiHeartbeatMs INTEGER` — added in staging-DB migration v5. The holder refreshes `aiHeartbeatMs` every `AIOwnershipLease.heartbeatIntervalMs` (1s) while AI runs. A gap > `staleMs` (4s) means the holder died and the other side may take over. Claim is atomic via conditional UPDATE (`WHERE aiOwner IS NULL OR aiOwner = :me OR (now - heartbeat) > staleMs`) with `db.changesCount` as the win check.
3. **NSE gate + claim**. `NotificationService.process` step 6 is gated: skip if `NSEState.isAIDisabled()`; skip if main app holds a fresh claim; otherwise `tryClaim(owner: .nse)` + spawn heartbeat Task + run AI + cancel heartbeat + `release(owner: .nse)` (conditional on still owning).
4. **Main-app poll + claim**. `ActiveAIQueue.executeJob` opens the NSE staging DB (via `NSEDataBridge.openStagingDB()`), checks `AIOwnershipLease.state`, and if NSE holds a fresh claim polls every `mainAppPollIntervalMs` (1s) up to `mainAppPollMaxMs` (28s). Once NSE publishes a result (`summaryBlurb` set or `aiCompleted=1`), main app triggers `NSEDataBridge.mergeNSEStagingData` and re-reads the `MessageHeader` — if the job's field is now populated, it returns without running the LLM. Otherwise main app `tryClaim(owner: .mainApp)` + heartbeat + runs AI + releases. Reply always runs on main-app side regardless of lease (NSE has no Reply pass).
5. **Shared helper in `Shared/Persistence/AIOwnershipLease.swift`** so both targets use identical lock semantics without file-target duplication.

**Rationale:**

- **Staging DB as coordinator is the ground truth.** No process-state guessing (main-app heartbeat timestamps, Darwin notifications). Both sides inspect the same row; claim race is decided by SQLite's atomic UPDATE.
- **Lease-with-heartbeat handles crash recovery for free.** If NSE is killed mid-AI (OOM, 30 s hard budget), the heartbeat goes stale after 4 s and main app takes over on its next dispatch tick. Symmetric for a main-app crash.
- **1 s heartbeat is cheap at local-only scope.** Both reader and writer are the same on-device DB; the cost is a single conditional UPDATE per second per active message. At most one message is "active" in NSE at a time, and main-app AI queue processes serially per message.
- **Max 28 s poll keeps main-app AI from deadlocking on a stuck NSE.** Ceiling is below NSE's 30 s iOS budget — if NSE hasn't produced a result in 28 s, main app takes over.
- **Privacy gate separated from lease.** NSE can check opt-out before doing anything, including claiming. Main app also gates on opt-out as today — the lease just prevents duplicated work when opt-out is OFF.
- **No protocol version bump required on the staging table.** Columns are additive (SQLite `ALTER TABLE ADD COLUMN`), default NULL — older main-app versions reading the staging DB just see nullable columns they ignore.

**What still works:**

- `NSEDataBridge.mergeNSEStagingData` still brings NSE-produced AI fields into `MessageHeader` + `MessageAICache` on next wake; the lease just ensures the NSE is the one producing them instead of both sides.
- Device Sync probe (`DeviceSyncService.probeAICache`) still runs before the lease check, so TB peer results short-circuit both NSE and main-app work.
- `MessageAICache` dedup still catches "already computed" cases at the field level after any cross-process race.

**Consequences:**

- **Existing opt-out users whose flag lived only in `.standard`** get auto-migrated to the shared suite on first launch. If the migration runs after some pushes, those pushes' NSE wakes briefly bypass opt-out (NSE can't see the flag until the main app runs). Migration is one-shot and idempotent via `guard shared.object(forKey:) == nil`.
- **One schema migration** (staging DB v5). Additive; no data loss on downgrade (older app simply ignores the columns).
- **Main-app wait up to 28 s for NSE results** on the very-first job per message. Typical NSE completion is ~9 s, so worst-case user-visible delay is bounded by NSE's own budget.

**Tuning** (`AIOwnershipLease`):

- `heartbeatIntervalMs = 1000`
- `staleMs = 4000` (4 × interval, tolerates scheduling jitter)
- `mainAppPollIntervalMs = 1000`
- `mainAppPollMaxMs = 28000` (NSE's 30 s budget minus a safety margin)

**Related:** ADR-IOS-008 (AI processing architecture), ADR-IOS-010 (Device Sync).
