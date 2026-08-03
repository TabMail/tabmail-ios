
### Proactive Local Notifications (ADR-IOS-026)
- **Port of TB's `proactiveCheckin.js`** — two deterministic triggers, no LLM calls
- `ProactiveNotifyService` actor — singleton, called from `AccountManagerAI` (after AI drain) and `RootView` (foreground return)
- **Trigger 1 (`new_reminder`)**: after message processing, filters for reply-tagged reminders within window, debounced 1s, fires immediately via `UNNotificationRequest(trigger: nil)`
- **Trigger 2 (`due_approaching`)**: `UNCalendarNotificationTrigger` scheduled N minutes before due. Reschedules on every reminder list change. Works even when app is killed.
- **`ReachedOutStore`** — UserDefaults dedup keyed by `"{reminderHash}:{triggerType}"`. Prune splits on LAST colon (hashes contain colons like `m:msgId`).
- **`NotificationDelegate`** — separate class from `AppDelegate` (Swift 6 `@MainActor` isolation). Uses `@preconcurrency UNUserNotificationCenterDelegate`. Returns `[.banner, .sound, .list]` for foreground display.
- **Foreground return**: syncs `deliveredNotifications()` → `ReachedOutStore` (covers calendar triggers that fired while app was killed), then checks for overdue reminders
- **Rate limiting**: 60s minimum between immediate notifications
- **Settings**: toggle (`proactive.notify.enabled`), window days (default 7), advance minutes (default 30) — in TabMailSettingsView "Notifications" section. **Default ON.**
- **Default-ON migration**: TabMailApp init runs a one-shot migration keyed `didMigrateProactiveNotifyOnByDefault_v1` that writes `true` to the enabled key for all existing users. Reason: an earlier `.onReceive(UserDefaults.didChangeNotification)` handler in TabMailSettingsView used `bool(forKey:)` which returns false for missing keys, silently flipping the toggle off on the next UserDefaults change. Fix: that handler now treats missing key as `true` to match the AppStorage default.
- **Reminders panel warning**: `RemindersNotificationWarning` (in `ReminderTopCard.swift`) renders above the reminder cards in the chat pill when either the in-app toggle is off OR `UNUserNotificationCenter` authorization is `denied`/`notDetermined`. Uses `scenePhase` to refresh on foreground.
- **Deep link**: `.proactiveNotificationTapped` posted on tap — observer is `MailNavigationView.handleNotificationDeepLink` (see notification-tap resolve ladder notes below; this stale "not yet wired" note is superseded).
- **Notification-tap resolve exhaustion → inbox fallback (2026-07-09):** when `MessageDetailViewModel`'s tap resolve ladder (`resolveProviderTap`) exhausts — NSE never staged the message AND sync hasn't landed it yet — `loadBody()` posts `.notificationTapUnresolved` (`userInfo["messageId"]` = the VM's sentinel string) in addition to setting `messageNotFound = true`/`isLoading = false`. `MailNavigationView`'s `.onReceive` for it pops the detail view (`selectedMessageId = nil`) and lands on `.unified(.inbox)` when the posted id still matches `selectedMessageId` — the message appears at the top of the inbox once sync lands. `messageNotFound`/Message-Not-Found stays as a backstop for the observer-not-mounted edge and for non-tap opens (which never post this notification). Test seam: `_tapResolveWaitSecondsOverride`/`_tapResolvePollMsOverride` on the VM override `resolveProviderTap`'s bounded poll (prod default 1.5s/50ms via `SyncConfig`) for fast exhaustion tests.
- **Debug**: `#if DEBUG` test notification button in settings (fires in 5s)

---
