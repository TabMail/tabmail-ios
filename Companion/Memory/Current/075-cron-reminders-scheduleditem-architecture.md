
### Cron Reminders (ScheduledItem Architecture)

- **Crons are a subclass of reminders** in the architecture. Both flow through the same unified builder (`ReminderBuilder` / `reminderBuilder.js`), the same disable/enable store (`DisabledRemindersStore` with `c:` hash prefix for crons), and the same Device Sync fields.
- **`[Cron]` KB format**: `[Cron] Schedule <days> <HH:MM> [<timezone>], <instruction>` — stored in KB text, synced via Device Sync KB field, programmatically protected from LLM rewriting on the backend (`splitKbEntries` + `isProtectedEntry`)
- **`generateKBReminders()`** (TB only) handles the KB re-parse trigger for BOTH `[Reminder]` and `[Cron]` entries. TB cron tools call it after KB changes. On iOS, the re-parse cascade is automatic: `PromptStore.shared.rawKB` setter → Device Sync broadcast → `ChatPillState` observation → `ReminderBuilder` re-evaluates. No explicit `generateKBReminders()` call needed on iOS.
- **`KBCronParser`** (iOS) / `kbCronParser.js` (TB) — separate parsers for `[Cron]` entries. Returns raw `scheduleDays` string (not expanded array) — the scheduler resolves it.
- **`CronScheduler`** — evaluates `shouldFire()` and `detectMiss()` per cron. TB fires at T-5min, iOS at T-3min (staggered for LLM cost optimization). Both devices always notify independently.
- **`CronExecutionCache`** — stores LLM results keyed by `{cronHash}_{YYYY-MM-DD}`. Synced via Device Sync `cronCache` field. Occurrence-based eviction (last 10 per cron). iOS reuses TB's cached result when available (skips LLM call) but still delivers its own notification.
- **Execution state is device-local** — `lastFired`, `lastMissed`, `consecutiveErrors` are NOT synced. Both devices evaluate and notify independently.
- **Tools**: `cron_add` / `cron_del` (separate from `reminder_add` / `reminder_del`). `change_setting` extended with `cron.enabled` and `cron.advance_minutes`.
- **Push worker**: alarm registration with absolute UTC wake times. Client computes locally with timezone awareness. Server is a dumb alarm clock.

---
