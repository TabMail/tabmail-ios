
## ADR-IOS-026: Proactive Local Notifications (Replicating TB's Nudge System)

**Context:** TB's `proactiveCheckin.js` delivers browser notifications for reminders via two deterministic triggers. iOS needs the same functionality using `UNUserNotificationCenter` local notifications, which work even when the app is killed (via `UNCalendarNotificationTrigger`).

**Decision:**
1. **Two triggers matching TB:**
   - `new_reminder` — fired after AI message processing detects new reply-tagged reminders within the configured window. Debounced 1s.
   - `due_approaching` — scheduled via `UNCalendarNotificationTrigger` N minutes before a reminder's due date/time. Reschedules on every reminder list change.
2. **`ProactiveNotifyService` actor** — singleton orchestrator. Called from `AccountManagerAI.processMessagesForAccount()` (after drain) and `RootView` on foreground return.
3. **`ReachedOutStore`** — UserDefaults-backed dedup keyed by `"{reminderHash}:{triggerType}"`. Prune splits on LAST colon (reminder hashes contain colons like `m:msgId`).
4. **Separate `NotificationDelegate`** — `UNUserNotificationCenterDelegate` extracted from `AppDelegate` into its own class because `UIApplicationDelegate` makes `AppDelegate` implicitly `@MainActor`, conflicting with the delegate's arbitrary-thread callbacks in Swift 6.
5. **Foreground return delivered-notification sync** — `onForegroundReturn()` syncs `deliveredNotifications()` to `ReachedOutStore` before checking for overdue reminders. Covers the case where `UNCalendarNotificationTrigger` fired while the app was killed (delegate never ran).
6. **No LLM calls** — notification content is template-based string interpolation, matching TB.
7. **Rate limiting** — 60s minimum between immediate notifications, matching TB's `MIN_INTERVAL`.

**Consequences:**
- Notifications work even when app is killed (calendar triggers are OS-managed)
- Deep link on notification tap posts `.proactiveNotificationTapped` — observer not yet implemented (follow-up)
- Settings: toggle, window days, advance minutes — all in TabMailSettingsView "Notifications" section

---
