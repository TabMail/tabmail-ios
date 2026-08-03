
### Gmail Label System
- Gmail folder paths are label IDs: `"INBOX"`, `"SENT"`, `"TRASH"`, `"SPAM"`, `"DRAFT"`
- Gmail has no explicit archive label — archiving = removing `"INBOX"` label
- Gmail undo archive: `move(from: "", to: "INBOX")` — removing "" is a no-op, adding INBOX works
- IMAP undo: must pass real folder paths (e.g., `"Archive"`, `"Trash"`) from `account.folders`
- Gmail delta sync uses `history.list` API — returns nil on 404 (expired historyId), falls back to full sync
- `Account.lastHistoryId` stores the Gmail history cursor; captured after each full sync via `getCurrentHistoryId()`
- **Gmail IMAP keywords ≠ Gmail REST API labels**: Gmail does NOT create REST API labels from IMAP keywords set via `STORE +FLAGS`. (Historical context — iOS no longer writes either; see ADR-IOS-036.)
- **Action tags are local-only (ADR-IOS-036).** iOS does NOT write `tm_*` Gmail labels / IMAP keywords / Exchange categories. `MessageHeader.actionTag` is populated by `MessageAICache.restoreIfCached` + AIService only; never from provider labels. Cross-instance state is served by Device Sync `ai_cache_probe` when peers are online, and iOS re-runs the LLM when they're not. Any `tm_*` labels still present on user servers from prior TabMail versions are treated as residue and filtered by `UserLabelStore.shouldExcludeLabel` (which matches the `tm_` prefix).
- **Synthetic `__GMAIL_ALL_MAIL__` must NEVER reach the Gmail API** — it is TabMail's internal All Mail/archive folder path (`GmailProvider.archivePath`), not a real label ID; Gmail returns 400 "Invalid label". Every method that scopes by folder must translate it: omit `labelIds` and add `GmailProvider.allMailExclusionQuery` to `q` (see `fetchMessages`, `search`, `listBackfillMessageIds`, `listOlderMessageIds`, `listMessageIdsPage`, `fetchOlderMessages`). `GmailProvider.request()` has a boundary guard that throws `ProviderError.syntheticFolderPath` if the sentinel leaks into an API path (caught a real bug 2026-06-09: `search()` was missing the translation, breaking remote search and contributing to a search-mode hang).
