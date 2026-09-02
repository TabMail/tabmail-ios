<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current amendment (2026-08-31, ADR-IOS-080):** `pendingBodyCount` now selects
> `headerComplete=1 AND bodyComplete=0 AND bodyEmptyConfirmed=0 AND
> bodyIndexingFailureReason IS NULL`. A deterministic failure to honor validated partial IMAP
> ranges is persisted as terminal-unindexed, counted separately by `unindexedBodyCount`, and shown
> as `Sync complete with N messages not indexed` once runnable work drains. Such rows are never
> confirmed empty and never marked indexed; Smart Reindex clears the reason for an explicit retry.
> This supersedes the preserved body's claim that every eligible row is self-terminating through
> success/empty and its reference to oversized bodies as confirmed-empty.
<!-- COMPANION-CURRENT-NOTE-END -->

### Backfill / Fast Sync Completion — gate on `pendingBodyCount`, NEVER a server total
- **`BackfillProgress.isFullyComplete` gates on `headersDone && totalEmails > 0 && pendingBodyCount == 0`** (`AccountManager.swift`). `pendingBodyCount` = body-eligible headers still awaiting fetch (`headerComplete=1 AND bodyComplete=0 AND bodyEmptyConfirmed=0`), the same criteria `BackfillBodyQueue`/`ActiveBodyQueue` select on. It is local and self-terminating (empty/404/oversized bodies confirm-empty), so it reaches 0 once the body queues have nothing fetchable left.
- **DO NOT gate completion on `ftsIndexed >= totalEmails`.** For Gmail/Exchange, `totalEmails` is a *server-reported* count that counts a **different population** than the mail headers we store, and can permanently exceed it → completion becomes unsatisfiable:
  - **Exchange**: `serverMessageTotal = SUM(folder.totalCount)` = sum of Graph `totalItemCount` across ALL folders, incl. Deleted Items, Junk, and hidden/system folders (`includeHiddenFolders=true` in `ExchangeProvider.fetchFolders`), plus non-mail items that `parseGraphMessage` drops (`compactMap` → nil). One row per message (folders don't overlap).
  - **Gmail**: `getMessagesTotal()` = `profile.messagesTotal`, **deduplicated** across labels (and includes Spam/Trash/Chat). But `grdbTotal` counts per-`(label, message)` rows (`MessageHeader.id` is keyed by `folderPath`), so the units don't match — Gmail "worked" only by accident when label memberships inflated `grdbTotal` past `messagesTotal`.
  - **IMAP**: unaffected — `uidTotal > 0`, so the server-total override is skipped and `totalEmails = grdbTotal`.
- **`totalEmails` (server total) is only the progress-BAR denominator while crawling** (`if uidTotal == 0 && !headersDone` in `SyncEngineBackfill.updateBackfillProgressForAccount`). Once `headersDone`, it falls back to `grdbTotal` so the bar reaches 100% consistently with completion. `serverMessageTotal` is cached once per session and never reconciled down.
- **Symptom of the old bug** (fixed): an Outlook/Exchange account that "never completes sync" — Fast Sync screen stuck below 100% / no "Sync Complete", Settings sync row unfinished, and the chat pill's "agent search results may be incomplete" banner (`DynamicIslandChatButton`, driven by `isBackfillInProgress`) stuck on forever. It is a **completion-criteria/reporting defect, not a runaway loop** — the backfill task itself exits on `isFolderWalkComplete` (headersDone), independent of `isFullyComplete`. The "deleted messages aren't counted right" intuition was exactly correct: `totalItemCount` over-counts deleted/hidden/non-mail items. Regression: `BackfillProgressCompletionTests`.
