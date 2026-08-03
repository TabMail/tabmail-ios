
### AI Summary & Action Pipeline

- `AIService` actor — orchestrates summary generation + action classification via backend API
- `BackendClient.sendCompletions()` — calls `POST /completions/chat` with `X-Client-Type: ios`
- **Summary flow**: system message with `content: "system_prompt_summary"` + template variables (user_name, subject, from_sender, body, email_date, etc.) → backend expands into multi-message prompt → returns structured text
- **Action flow**: system message with `content: "system_prompt_action"` + variables → 3 parallel calls → mode (most common action wins)
- **Variable encoding**: `CompletionsMessage` uses dynamic coding keys to flatten vars into top-level JSON keys alongside role/content
- **Response parsing**: summary uses section-based text parsing (Todos/Two-line summary/Reminder); action uses JSON parsing (`{"action": "...", "justification": "..."}`)
- **Cross-instance dedup now via Device Sync probe** (ADR-IOS-036, supersedes ADR-IOS-004 "First Compute Wins"): `DeviceSyncService.probeAICache` queries connected peers before running the action LLM; hit = adopt, miss = compute.
- `AccountManager.processAIForAccount()`: gathers `AIMessageSnapshot`s on main actor, dispatches to AIService, updates `MessageHeader.actionTag` + `MessageAICache` locally. No provider-side tag write.
- `EmailFilter.isNoReply()` / `.hasUnsubscribeLink()` — lightweight heuristics for LLM prompt context. `hasUnsubscribe` is NOT used in reply skip (too aggressive for mailing lists) — only `isNoReply` drives `skipCachedReply`.
- `MessageHeader` summary fields: `summaryBlurb`, `summaryTodos`, `reminderDate`, `reminderTime`, `reminderContent`
- Provider `setActionTag` methods exist as no-op stubs (signature kept so legacy PendingOperation(.setTag) drain flushes cleanly). ADR-IOS-036.
