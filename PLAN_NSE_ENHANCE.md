# PLAN_NSE_ENHANCE — settings-aware push registration + alert-visibility hint

> Self-contained. Read this directly for context, rules, the gates model, and the
> progress log. Goal: stop silently losing notifications when the user has the
> in-app push toggle ON but has disabled iOS visual alerts, and tell the user how
> to fix it. Plan only — implement after compaction + verification.

**Status:** IMPLEMENTED 2026-06-03 (pending on-device verification §8)
**Owner:** —
**Created:** 2026-06-03

---

## 0. TL;DR

The device currently decides "send me visible (NSE) vs silent push" from **TabMail's
own in-app toggle only** (`PushConfig.pushNotificationsEnabledKey`). It does **not**
consult the **iOS system notification settings**. So a user with the in-app toggle ON
but **Banners / Lock Screen / Notification Center all OFF** (sound/badge-only, or all
off) still registers as `nseCapable=true` → the worker sends a visible push → **iOS
refuses to run the NSE** (no visual surface to present) → no enrichment **and** no
background wake. The notification effectively does nothing.

Fix (iOS-side, no worker change required for the core):
1. Fold **"visual alerts available"** (from `UNUserNotificationCenter`) into the
   `nseCapable` decision: **visible/NSE registration only when a visual surface is
   enabled; otherwise register silent** (so the main app still gets woken to sync +
   badge, best-effort).
2. **Re-evaluate on every foreground** and re-register if the capability changed
   (idempotent; better than today).
3. **In-app hint**: if the user wants push but has no visual surface enabled, tell
   them clearly ("enable at least one of Banners / Lock Screen / Notification
   Center") and **deep-link to the app's notification settings**.

---

## 1. Background — the NSE execution gates (LESSONS LEARNED, read first)

A Notification Service Extension (`UNNotificationServiceExtension`) runs **only when
ALL of these hold**. Memorize this; we re-learned it the hard way:

1. **Payload gate:** the push has an `alert` dict **and** `mutable-content: 1`.
   - TabMail's new-mail push already satisfies this (`sendVisiblePush` in
     `tabmail-push-worker/src/helpers/apns.ts`). **Sound is irrelevant** — a
     visible-but-silent (no-sound) notification still runs the NSE.
   - Apple: *"Silent notifications, or those that only play a sound or badge the
     app's icon, cannot be modified."* → **sound/badge-only ≠ alert → NSE skipped.**
2. **Presentation gate (THE NEW FIX TARGET):** the notification will be **displayed
   visually** — i.e. at least one of **Lock Screen / Notification Center / Banners**
   is enabled in iOS Settings. `Sounds` and `Badges` toggles do **not** count.
3. **Resource gate:** the device is not under memory/thermal pressure or Low Power
   Mode. Under pressure iOS suppresses NSEs **device-wide** — not a TabMail bug.

### Hard platform facts that bound this work (do not relitigate)
- **A push is EITHER an alert OR a background wake — never both.** Adding
  `content-available` to the visible payload makes the worker label it
  `apns-push-type: background` (`apns.ts` derives type:
  `pushType = aps['content-available'] ? 'background' : 'alert'`) → iOS delivers it
  silently → **no banner, no NSE**. We shipped this by accident and reverted it
  (commit `776e286`). DO NOT re-add `content-available` to `sendVisiblePush`.
- **Silent / `content-available` pushes are unreliable**: throttled by a device-wide
  battery/data budget and suppressed under the same pressure that kills the NSE.
- **PushKit/VoIP** is the only guaranteed on-push wake, and Apple **forbids** it for
  non-VoIP apps (must report a call to CallKit). Not an option for mail.
- **There is no reliable push-time processing when the NSE can't run.** Guaranteed
  processing is foreground-on-open + BGTask (first-compute-wins AI, ADR-IOS-013) —
  deferred, never dropped. Push+NSE is an optimization, not the source of truth.
- **The worker sends ONE push per device per event** (`apns.ts` `pushToAllDevices`
  ternary: `nseCapable ? sendVisiblePush : sendSilentPush`). There is **no**
  silent-after-visible today.
- **The badge is set by the app, not the worker.** Worker is stateless/zero-retention
  (ADR-004) and has no unread count; `UnreadCountManager.setBadgeCount(totalUnread)`
  (`Services/UnreadCountManager.swift:137`) is the authoritative path. So waking the
  app (even silently) is what updates the badge.

### Diagnosing "NSE not running" (field playbook)
- If a **third-party app's** NSE also shows `can be modified: 0` at the same time
  (e.g. `com.google.Gmail`), it's **device-wide** → resource/Low-Power, not us.
- Unified-log signals: `duetexpertd … memory pressure … type: critical`,
  `kernel … stuck process … [usernotificationsd] … idle band`,
  `Thermal pressure level above 0`, `LowPowerModeActive = YES/NO`.
- SpringBoard line `… can be modified: 0` = NSE will NOT be invoked for that push.

---

## 2. Current behavior (code anchors — verify before editing)

- **`Services/PushNotificationService.swift`**
  - `subscribeAccount(_:updateDeviceRegistration:)` (≈193–281): the registration
    flow. Key lines:
    - `:224` IMAP/iCloud subscribe is gated by
      `nseEnabled = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false`.
    - `:252–257` per-account registration:
      `let providerTag = (account.provider == .icloud) ? "imap" : account.provider.rawValue`
      `let nseCapable = nseEnabled && NSEProviderSupport.isReady(providerTag)`  ← **no settings check today**
    - `:259–267` `pushClient.registerDeviceAccount(..., nseCapable:)`.
  - `subscribeAllAccounts()` (≈312–328): bulk re-subscribe; ends with
    `registerDeviceWithWorker()`.
  - `checkPushConsentStatusForForeground()` (≈545+): runs on foreground, **gated by
    `nseEnabled`**, scans provider consent — but does **not** re-evaluate iOS
    notification settings nor re-register on a settings change.
  - DI hook exists for tests: `_setConsentCheckerForTesting` / `PushConsentChecking`.
- **`Services/PushClient.swift`**
  - `registerDeviceAccount(... nseCapable:)` (≈78–108): picks
    `/register-account-device-nse` (true) vs `/register-account-device-silent`
    (false). **No change needed** — it already does the right thing per `nseCapable`.
- **`Shared/Notifications/NSEProviderSupport.swift`**: `readyProviders = [gmail,
  outlook, imap]`, `isReady(_)`. **No change.**
- **`Services/PushConfig.swift`**: keys — `pushNotificationsEnabledKey`,
  `lastDeviceTokenKey`, `deviceIdKey`, `isAPNsSandbox`.
- **`App/TabMailApp.swift:262`**: `onChange(of: scenePhase)` → `.active` currently
  only calls `NotificationCleanupService.sweepOnForeground()`. (Candidate foreground
  hook, but prefer the existing push foreground path — see §3.3.)
- **Worker (`tabmail-push-worker`)**: `register-account-device-{nse,silent}` handlers
  set `nseCapable` true/false (`src/handlers/deviceAccount.ts:81,111`).
  `pushToAllDevices` ternary (`src/helpers/apns.ts:417`). **No worker change for the
  core plan** — but see §4 verify item (IMAP "always visible-passive" comment).

---

## 3. The plan (iOS)

> **Simplicity / performance guardrail (read first).** This feature must add ~zero time
> to any launch/foreground path. The per-foreground work is exactly: **one Bool read +
> one `notificationSettings()` read + one compare.** Anything network (re-subscribe)
> happens ONLY on a real settings flip, which is rare. Everything runs in a detached,
> non-blocking `Task {}`. Reuse existing paths (`subscribeAllAccounts`, `PushHealthStore`
> banners) — do NOT invent parallel registration code or add caches/maps. If a step
> here starts to look clever, it's wrong.

### 3.1 "Visual alerts available" helper
Add one source of truth that reads the live iOS settings:

```swift
// PushNotificationService (or a small PushSettings helper)
static func visualAlertsEnabled() async -> Bool {
    let s = await UNUserNotificationCenter.current().notificationSettings()
    // Must be authorized AND have at least one VISUAL surface. Sound/Badge do NOT count.
    let authed = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
    let visual = s.lockScreenSetting == .enabled
              || s.notificationCenterSetting == .enabled
              || s.alertSetting == .enabled
    return authed && visual
}
```
**DECIDED (2026-06-03): include `.provisional`.** Provisional authorization is iOS's
quiet trial tier — granted with no permission dialog, notifications go straight to
**Notification Center** (a visual surface) with no banner/sound. Because that surface
satisfies the presentation gate, the **NSE can still run**, so a provisional user must
NOT be demoted to silent → count `.provisional` as "visual on". (TabMail asks for full
`[.alert,.sound,.badge]` consent at `PushNotificationService.swift:75`, so almost no
user is actually provisional — but the helper handles it correctly rather than
mis-bucketing the edge case.)

**Reuse note (VERIFIED 2026-06-03):** no existing per-surface "visual alerts
available" helper exists — add this one. Existing `notificationSettings()` readers to
match idiom (both only inspect `authorizationStatus`, not per-surface):
`ReminderTopCard.swift:105` and `DebugLogView.swift:144`. The new helper is the first
to check `lockScreenSetting`/`notificationCenterSetting`/`alertSetting`.

### 3.2 Fold into `nseCapable` (the core change)
In `subscribeAccount`:
```swift
let nseEnabled  = UserDefaults.standard.object(forKey: PushConfig.pushNotificationsEnabledKey) as? Bool ?? false
let visualOn    = await PushNotificationService.visualAlertsEnabled()
let providerTag = (account.provider == .icloud) ? "imap" : account.provider.rawValue
let nseCapable  = nseEnabled && NSEProviderSupport.isReady(providerTag) && visualOn
```
Behavior matrix (in-app toggle ON):
| Visual alerts | provider ready | → registers as | worker sends | result |
|---|---|---|---|---|
| enabled | yes | **nse** (`/…-nse`) | visible/mutable-content | banner + NSE (best path) |
| **disabled** | yes | **silent** (`/…-silent`) | content-available | main app wakes → sync + badge (no banner — user opted out) |
| any | no (provider not NSE-ready) | silent | content-available | sync + badge |

**Important:** when `nseEnabled == true` but `visualOn == false`, **still register
(as silent)** — do NOT skip. The IMAP subscribe `guard nseEnabled` (`:225`) stays
keyed to the in-app toggle (so the droplet still IDLEs); only the **per-account
registration's `nseCapable`** (`:257`) gains the `&& visualOn`. Confirmed: gmail/outlook
subscribe (`:211–219`) has no `nseEnabled` guard (Pub/Sub watch always runs); the
per-account registration block (`:247–272`) is what decides nse-vs-silent, so adding
`&& visualOn` there registers silent rather than skipping for all providers. ✅

**Notes (VERIFIED 2026-06-03):**
- `subscribeAllAccounts()` (`:312`) fans `subscribeAccount` out in a parallel
  `TaskGroup` (`:317–323`), so each call independently `await`s `visualAlertsEnabled()`
  (N reads of `notificationSettings()`). **Leave it — do NOT add the compute-once
  threading.** A `notificationSettings()` read is a single-digit-ms local IPC, run in
  parallel across ≤~5 accounts; the extra plumbing isn't worth it (see §3 guardrail).
- `pushNotificationsEnabledKey` is read with `?? false` at the call sites (`:224`,
  `:252`, `:546`) — i.e. **defaults OFF in code**, even though the `PushConfig` doc
  comment (`PushConfig.swift:41`) says "Default: true". Don't assume default-true when
  reasoning about the hint/registration gates.

### 3.3 Re-register on foreground — NO new code needed (REVISED 2026-06-03)
**Key invariant:** iOS notification settings (Banners / Lock Screen / Notification
Center) can **only** be changed in the iOS Settings app, which requires backgrounding
TabMail. So *any* settings change is **always** followed by a `scenePhase .active`
foreground return before it can matter — there is no "settings changed while
foregrounded" case.

**Decisive fact:** the app **already re-subscribes on every foreground return** —
`SyncScheduler.startForegroundPolling()` calls
`await PushNotificationService.shared.subscribeAllAccounts()` (`SyncScheduler.swift:390`,
comment "Re-subscribe push on foreground return"). Because §3.2 makes `subscribeAccount`
read `visualAlertsEnabled()` **live** at registration time, that existing resub already
re-registers with the current nse/silent value, and the worker upserts idempotently.

**Therefore the whole "reconcile" idea is redundant. Implemented as NOTHING extra:**
- ❌ NO `reconcilePushVisibility()` method.
- ❌ NO `lastRegisteredVisualAlertsKey` stored-state / Bool guard.
- ❌ NO scenePhase hook in `TabMailApp`.
- ✅ §3.2's live read + the existing foreground `subscribeAllAccounts()` IS the
  foreground re-register. The worker is idempotent, so re-POSTing the same value is
  harmless; on a real change it just updates.

Why no state check is needed: the only reason to track "last registered capability"
would be to *skip* the resub when unchanged — but the resub happens on foreground
anyway (it also reconnects sockets, syncs, renews watches), independent of this feature.
Adding a Bool to suppress part of it saves nothing and adds state to keep correct.
Document the coupling at both sites (done in code): `subscribeAccount`'s `visualOn`
comment and the `subscribeAllAccounts` call in `startForegroundPolling`.

Edge case checked: if a startup is mid-flight on return (`isStartupInFlight` guard at
`SyncScheduler.swift:362` no-ops the *new* call), the in-flight startup's own
`subscribeAllAccounts` still runs and reads settings live — so a change is never missed.

### 3.4 In-app hint + deep-link
- Condition to show: `pushNotificationsEnabledKey == true` **AND**
  `visualAlertsEnabled() == false` (user wants push but iOS won't present visually).
- Copy (make "at least one" explicit): *"To get email the moment it arrives, turn on
  at least one of **Banners**, **Lock Screen**, or **Notification Center** for
  TabMail. Sound or badge alone isn't enough."*
- Action button → deep-link to the app's **notification** settings page:
  ```swift
  if let url = URL(string: UIApplication.openNotificationSettingsURLString) { // iOS 16+ (target is 26)
      await UIApplication.shared.open(url)
  }
  ```
  Fallback `UIApplication.openSettingsURLString` not needed at iOS 26.
- **Placement (FINAL 2026-06-03 — two surfaces, not a sidebar banner):**
  1. **Email Accounts settings** (`SettingsView.swift`) — a warning row in the "Push
     Notifications" Section, directly **below the toggle**. Full copy + tappable
     deep-link to the notification settings page. This is the home of the fix (it's
     where the push toggle lives). Driven by a local `refreshVisualAlertsWarning()`
     (`.task` + scenePhase `.active` + on `pushEnabled` change), gated on
     `hasCheckedVisualAlerts` to avoid a flash.
  2. **Sidebar nav** (`MailNavigationView.swift`) — a small **leading** orange
     `exclamationmark.triangle.fill` in front of the **Email Accounts** row when the
     warning is active (`hasCheckedVisualAlerts && visualAlertsHintVisible`). Subtle
     attention marker that points the user into the settings screen where the full
     warning + fix lives. (Mirrors the existing trailing `isLargeInbox` warning on the
     same row.) Driven by the existing `refreshVisualAlertsHint()` (`.task` + scenePhase).
  - The earlier top-of-sidebar **banner Section was removed** — these two targeted
    surfaces replace it.
- **Both checks are purely LOCAL** (`notificationSettings()`, no network) — NOT inside
  `checkPushConsentStatusForForeground` (which early-returns when offline `:556`). An
  offline user with banners off still sees the warning.
- Deep-link: `UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)`
  — consistent with existing `UIApplication.shared.open` usage (e.g.
  `ToolSettingsView.swift:32`); first use of the notification-specific page. iOS 16+
  (target 26); no `openSettingsURLString` fallback needed.

---

## 4. Worker-side — VERIFIED 2026-06-03 (NO worker change needed)
- **Registration upserts on flip.** Both endpoints call `registerDeviceAccount`
  (`kv.ts:460`), which `KV_PUSH_TOKENS.put`s a fresh record on a stable key
  (`deviceAccountKey(userId, deviceId, accountEmail)`) — an unconditional overwrite. So a
  nse→silent (or silent→nse) flip from the foreground resub fully replaces the stored
  `nseCapable`. No insert-or-ignore; no schema/migration (KV is schemaless; `nseCapable`
  already on the record). This is the one thing that could've needed a backend fix — it
  doesn't.
- **gmail/outlook/imap new-mail all honor `nseCapable`.** All three webhook paths fan
  out via `pushToAllDevices` (`apns.ts:402`), whose ternary (`apns.ts:417`)
  `device.nseCapable ? sendVisiblePush : sendSilentPush` sends silent
  `content-available` for `nseCapable=false`. So registering **silent** is sufficient
  for every provider — a badge-only user still gets the silent wake. ✅
- **CORRECTION to the earlier draft:** the "ALWAYS visible-passive" comment is **not**
  on the IMAP new-mail path. It lives in `handleImapDisconnected` →
  `sendReconnectPush` (`imapWebhooks.ts:224`), the IMAP **reconnect/health** push,
  which force-sends visible-passive regardless of `nseCapable`. IMAP **new-mail**
  (`handleImapNewMail`, `imapWebhooks.ts:158`) uses the normal `pushToAllDevices`
  ternary — it already respects a silent registration. The "verify IMAP new-mail"
  open item is therefore **RESOLVED, not open**.
- The reconnect/health push being always-visible-passive means a visual-alerts-OFF
  user won't run the reconnect NSE either (no visual surface) — but the server-side
  retry ladder + cron (`imapRetryCron.ts`, seeded at `imapWebhooks.ts:244–252`) cover
  reconnection. Degrades gracefully. Out of scope; recorded only.
- **Regression guard intact:** `apns.spec.ts:349` asserts the visible push has NO
  `content-available` (`toBeUndefined()`); `sendVisiblePush` NOTE (`apns.ts:111–116`)
  forbids re-adding it; `pushType` is derived from it at `apns.ts:318`. Endpoints set
  the flag at `deviceAccount.ts:81` (silent ⇒ `nseCapable:false`) / `:111`
  (nse ⇒ `nseCapable:true`).

## 5. Follow-up silent push — DECIDED: NO (2026-06-03)
Considered a belt-and-suspenders "+10s silent push after the visible fan-out" for the
"NSE registered but didn't run on a healthy device" case. **Rejected — do NOT
implement.** It would double silent-push volume → spend the device-wide silent budget
faster → reduce reliability of *all* silent pushes; it's redundant when the NSE did run
and useless under the resource gate. §3.2 already covers the settings-gated case with
zero extra volume.

## 6. Non-goals (explicitly out of scope)
- Do NOT try to force the NSE to run (impossible under the resource gate).
- Do NOT add `content-available` to `sendVisiblePush` (reverts to the banner-killing bug).
- Do NOT use PushKit (forbidden for mail).
- Do NOT have the worker compute a badge (stateless; wrong source of truth).

## 7. Testing (CLAUDE.md: add/extend tests)
- iOS unit tests via the `NotificationSettingsProviding` seam + DEBUG
  `_setNotificationSettingsProviderForTesting` (so tests never touch the real
  `UNUserNotificationCenter`). Implemented in `PushVisibilityTests.swift`:
  - `visualAlertsEnabled()` decision matrix: authorized + a visual surface (Banner /
    Lock Screen / Notification Center) ⇒ true; authorized + sound/badge only ⇒ false;
    denied / notDetermined ⇒ false; provisional + Notification Center ⇒ true.
  - (No reconcile tests — §3.3 added no reconcile code; the foreground resub +
    `visualAlertsEnabled()` are what's exercised.)
- Worker: **no worker change in this plan** (§4 resolved). `apns.spec.ts:349` already
  guards "visible push has NO `content-available`" (commit `776e286`) — keep it; don't
  touch it.
- Xcode tests for iOS. No `npm test` needed unless a worker change is added later.

## 8. On-device verification
1. Settings → TabMail → turn OFF Banners + Lock Screen + Notification Center, leave
   Sound/Badge on, in-app toggle ON. Foreground app → expect: the existing foreground
   resub registers **silent**, hint banner appears, deep-link opens the notification
   settings page.
2. Send mail → expect: **no banner** (correct, user opted out) but the app **syncs +
   badge updates** (silent push wakes it) on a healthy device.
3. Re-enable Banners → foreground → expect: re-registers **nse**, hint disappears,
   next mail shows an enriched banner (NSE runs) — confirm SpringBoard logs
   `can be modified: 1` + a `NotificationService` process launch.
4. Sanity: under memory/thermal pressure, accept that nothing runs at push time
   (device gate) — verify mail still lands on next foreground/BGTask.

## 9. Decisions — ALL RESOLVED (2026-06-03)
- [x] `.provisional` counts as "visual on" — delivers to Notification Center → NSE can run. §3.1
- [x] Foreground re-register: **NO new code** — the existing foreground resub
      (`SyncScheduler.startForegroundPolling` → `subscribeAllAccounts`) + §3.2's live
      `visualAlertsEnabled()` read already cover it. Settings can't change without
      backgrounding the app, so a foreground resub always follows. §3.3
- [x] Stored-state / Bool guard / `reconcilePushVisibility` / scenePhase hook —
      DROPPED as redundant (worker upserts idempotently; resub happens anyway). §3.3
- [x] IMAP new-mail honors `nseCapable=silent`? — Already does; no worker change. §4
- [x] Follow-up silent (§5)? — NO. §5

## 10. Progress log
- 2026-06-03 (UI relocation — verified working on device): moved the warning off the
  top-of-sidebar banner to two targeted surfaces (§3.4): (1) a warning row under the
  push toggle in **Email Accounts settings** (`SettingsView` — `refreshVisualAlertsWarning`
  via `.task` + scenePhase + `pushEnabled` change, deep-links to notification settings),
  and (2) a **leading orange warning icon** on the Email Accounts row in
  `MailNavigationView` (driven by the retained `refreshVisualAlertsHint`). Removed the
  sidebar banner Section and the now-unused `import UIKit` from `MailNavigationView`.
  Build SUCCEEDED, zero new warnings. Registration behavior unchanged (subscription
  based on notification status confirmed working on device).
- 2026-06-03 (SIMPLIFIED — removed the reconcile machinery): realized §3.3 was
  redundant. `SyncScheduler.startForegroundPolling` ALREADY calls
  `subscribeAllAccounts()` on every foreground (`:390`), and §3.2 reads
  `visualAlertsEnabled()` live, so the foreground resub already re-registers with the
  current capability (worker upserts idempotently). Settings can't change without
  backgrounding the app → a foreground resub always follows. So **removed**:
  `reconcilePushVisibility()`, `PushConfig.lastRegisteredVisualAlertsKey`, the
  `TabMailApp` scenePhase hook, and the reconcile unit tests. Documented the coupling in
  `subscribeAccount` (live-read comment) and at the `subscribeAllAccounts` call in
  `startForegroundPolling`. Net iOS change is now just §3.2 (fold) + §3.4 (hint).
- 2026-06-03 (IMPLEMENTED — initial, since trimmed): landed all changes; build SUCCEEDED,
  zero new warnings; full suite **6939 tests / 952 suites all pass**. Final shape after
  the simplification above:
  - `PushNotificationService.swift` — test-injectable settings seam
    (`NotificationVisibilitySnapshot` / `NotificationSettingsProviding` /
    `SystemNotificationSettingsProvider` + DEBUG `_setNotificationSettingsProviderForTesting`),
    `visualAlertsEnabled()` (provisional counts), and the `&& visualOn` fold into
    `nseCapable` in `subscribeAccount` (live read).
  - `MailNavigationView.swift` — "Turn On Alerts" hint Section (deep-links via
    `UIApplication.openNotificationSettingsURLString`), `refreshVisualAlertsHint()` in its
    OWN `.task` + scenePhase `.active` (decoupled from the network consent scan), gated on
    `hasCheckedVisualAlerts` to avoid a flash.
  - `SyncScheduler.swift` — comment documenting the foreground resub keeps nse/silent fresh.
  - `TabMailTests/Services/PushVisibilityTests.swift` — `visualAlertsEnabled()` suite.
  No `PushConfig` / `TabMailApp` change. No worker change (§4). Next: on-device verify (§8).
- 2026-06-03 (simplicity pass): locked all decisions + de-sophisticated the re-register
  path. `.provisional` ⇒ visual-on (§3.1). §3.3 simplified: hook the single canonical
  scenePhase `.active` (`TabMailApp:262`) via a tiny `reconcilePushVisibility()`
  (flag check → one `notificationSettings()` read → compare to a single Bool →
  re-subscribe ONLY on a real flip, `nil` seeds without a round-trip) — **dropped** the
  `registerAccountForPush`/`reRegisterAllAccountsForPush` extraction and the
  ~6×/foreground consent-method hook; **reuse `subscribeAllAccounts()`** since flips are
  rare. Follow-up silent push (§5) = NO. Added §3 simplicity/perf guardrail. Net effect:
  per-foreground cost is one Bool read + one settings IPC + a compare, all in a detached
  `Task {}` — adds no measurable launch/foreground time. Still plan-only.
- 2026-06-03 (verification pass): Re-read the plan and cross-checked every code
  anchor against the live tree. **All iOS anchors confirmed EXACT** —
  `subscribeAccount` (`:193–281`), IMAP `guard nseEnabled` (`:225`), per-account
  `nseEnabled`/`providerTag`/`nseCapable` (`:252,256,257`), `registerDeviceAccount`
  call (`:259–267`), `subscribeAllAccounts` (`:312`), `checkPushConsentStatusForForeground`
  (`:545`, with the `nseEnabled`/offline early-returns at `:547`/`:556`),
  `_setConsentCheckerForTesting`/`PushConsentChecking` DEBUG seam; `PushClient.registerDeviceAccount`
  (`:78–108`) endpoint select (`:87–89`); `NSEProviderSupport.readyProviders=[gmail,outlook,imap]`;
  `PushConfig` keys; `UnreadCountManager.setBadgeCount` (`:137`); `TabMailApp` scenePhase
  onChange (`:262`). **Worker anchors confirmed:** `deviceAccount.ts:81/111`,
  `apns.ts:417` ternary, `:318` pushType, `:111–116` NOTE, `apns.spec.ts:349`.
  **One factual error fixed (§4):** IMAP new-mail ALREADY honors `nseCapable` (uses
  `pushToAllDevices`); the "ALWAYS visible-passive" comment is on the reconnect path
  (`imapWebhooks.ts:224`), not new-mail — that open item is now resolved. Also tightened
  §3.1 (reuse anchors: `ReminderTopCard:105`, `DebugLogView:144`; no per-surface helper
  exists), §3.2 (TaskGroup N-reads; `pushNotificationsEnabledKey` defaults OFF in code
  despite the doc comment), §3.3 (verified foreground callers; re-register must extract
  the `:247–272` block since no standalone helper exists; reuse/extend
  `lastRegisteredStateHash`), §3.4 (hint must be a LOCAL check, not behind the offline
  guard). Still plan-only; no code changes.
- 2026-06-03: Plan written. No code changes yet. Context: this followed a long
  debugging session where the NSE appeared broken after the
  tabmail-ios-archive → tabmail-ios migration; root causes turned out to be (a) a
  real but separate XcodeGen signing regression — fixed + shipped in 1.6.2 — and (b)
  the device being under memory/thermal pressure suppressing NSEs device-wide
  (Gmail's NSE failed identically). This plan addresses the *third* angle: the
  settings/presentation gate, so badge-only users still sync and users get told how
  to enable banners.
