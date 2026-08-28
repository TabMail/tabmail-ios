# Pre-compaction catalog bullets — ADR-IOS-078 and ADR-IOS-079

**Status:** Historical (preserved source text) · **Routed:** 2026-08-28 `companion-compact` ·
**Source:** `tabmail-ios/DECISIONS.md` at `8577bcb9c`

These two catalog bullets had become second copies of their linked ADR bodies. The compact
`DECISIONS.md` lines retain the status, the discriminating policy boundary, and the symbols needed
for search; the normative records remain ADR-IOS-078 and ADR-IOS-079. The original catalog bytes
are preserved below so no prior citation or search term is lost.

The bullets are fenced because their links are relative to `DECISIONS.md`; the companion verifier
ignores links inside code fences, preserving the source bytes without rewriting their paths.

## Source line 150 — `ADR-IOS-078`

<!-- BEGIN VERBATIM BULLET ADR-IOS-078 -->

```text
- **[ADR-IOS-078](Companion/Decisions/V3/Active/adr-ios-078.md)** — Active. **The newest-100 window bounds SYNC-ORIGIN processing only — existing AI content is NEVER gated from display** (owner, 2026-08-19): summary bubble renders any existing summary in EVERY folder (no window check, no inbox check — `v1.7.9`'s inbox display gate is removed, not restored); action pill/tag buttons stay inbox-membership-only (`ActionTagDisplay.displayedTag`, no window gating). ⛔ `ActiveAIQueue.recentInboxWindowContains` bounds **sync-origin admission + the repopulation sweep ONLY** — manual open, push/NSE merge and moved-into-inbox are window-EXEMPT (`AIJob.windowExempt`, pathway regating, owner directive); **never re-gate an exempt producer to "restore" a global bound.** The `7a31f1d22`/`v1.7.11` display gate + suppression notice were designed in error (`MIS-IOS-018`). Delta sync stays gated, so a message another client moves into the Inbox keeps its INTERNALDATE and may get no automatic summary until opened — accepted (#68).
```

<!-- END VERBATIM BULLET ADR-IOS-078 -->

## Source line 151 — `ADR-IOS-079`

<!-- BEGIN VERBATIM BULLET ADR-IOS-079 -->

```text
- **[ADR-IOS-079](Companion/Decisions/V3/Active/adr-ios-079.md)** — Active. **Scheduled tasks are DELETED from iOS; Thunderbird keeps them.** Background execution and wake-up pushes are not guaranteed here, so `TaskEvaluationService` / `TaskScheduler` / `TaskExecutionCache` / `KBTaskParser` / `ScheduledTasksSettingsView` / `TaskAddTool`+`TaskDelTool`+`TaskEditTool` / `PushClient.registerAlarms` / the NSE `task_alarm` route are gone, and the engine no longer starts. ⛔ **Do NOT extend this to the desktop side:** `[Task]` KB lines, the `kb` sync field and the unattended prompt tier are Thunderbird's live feature input and are untouched — never write code that strips or migrates `[Task]` prose. **`SyncField.taskCache` is GONE too** (case, `CodingKeys`, property, decode, entry type) — safe because a `KeyedDecodingContainer` never reads an undeclared key, so a desktop payload carrying it still decodes, and the desktop gates its merge on `undefined`, so omitting the key skips it; `PromptStateDataUnknownFieldTests` pins *an undeclared key is ignored*. `"task_result"` chat turns **no longer render** (display predicate only — rows stay, no migration). **KEEPS:** `disabledReminders` incl. `t:` hashes — and `gcStaleEntries` now SKIPS every `t:` hash unconditionally, because GC may only collect namespaces this device can re-derive (absent = enabled, Device Sync retains nothing, so collecting the surviving copy loses the user's disable); the `nse_pending_task_result` `CREATE TABLE` (producer+consumer deleted, no cleanup migration); the `Reminder` struct's now-always-nil schedule fields. **User-visible loss:** a Thunderbird-created task no longer fires on iPhone.
```

<!-- END VERBATIM BULLET ADR-IOS-079 -->
