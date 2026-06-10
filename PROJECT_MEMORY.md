# TabMail iOS - Project Memory

> **iOS-specific knowledge.** Claude reads this before every task and updates it when discovering something new. For cross-cutting knowledge, see `../PROJECT_MEMORY.md`.

**Last updated:** 2026-04-20

---

## Key Files

| What | Where |
|------|-------|
| Project definition | `project.yml` (XcodeGen) |
| App entry | `TabMail/` |
| Secrets | `Secrets.xcconfig` (gitignored) |

---

## OAuth / Google Cloud

- **iOS OAuth client ID**: iOS type, bundle ID `ai.tabmail.ios`, stored in `Secrets.xcconfig`
- **Credentials flow**: `Secrets.xcconfig` → loaded via `project.yml` configFiles → exposed in `Info.plist` → read at runtime by `OAuthConfig` in `GoogleAuthService.swift`
- Shares GCP project with Thunderbird (see `../PROJECT_MEMORY.md` for GCP details)
- **Merged OAuth flow (single prompt)**: Google/Microsoft sign-in uses direct OAuth → `signInWithIdToken` → auto-create email account. Google requires adding the iOS `GOOGLE_CLIENT_ID` as an Additional Client ID in Supabase dashboard (Auth → Providers → Google). Microsoft needs no extra setup — same application ID across platforms. See `SETUP.md` for details.

---

## Architecture Patterns

### IMAP Connection Pool (supersedes ADR-IOS-014)
- `IMAPProvider` is a Swift `actor` with an `IMAPConnectionPool` (also an actor) managing multiple concurrent connections
- **Connection pool** (`IMAPConnectionPool.swift`) replaces the old serial lock AND temp connection infrastructure
- Operations checkout a connection via `withPoolConnection(priority:) { server in ... }` — each gets its own connection, SELECTs independently
- **Priority checkout**: user-initiated ops (move, markRead, fetchMessage) use `priority: true` — jump to front of waiter queue ahead of background ops
- **Adaptive concurrency**: detects server connection limits from `mail_max_userip_connections=N` rejections, adjusts automatically (cooldown on full rejection, gradual recovery)
- **Connection reuse**: idle connections persist in the pool across operations (no create/destroy per batch)
- **Liveness checks**: NOOP before reuse if idle > 2 minutes, dead connections discarded
- **Idle pruning**: connections unused > 5 minutes are closed (called during reconnect)
- **Batch checkout**: `pool.checkoutBatch(count:)` for parallel body fetch — replaces `createTempConnections`
- Gmail/Exchange HTTP providers unaffected — URLSession handles connection pooling natively

### ProviderWorkQueue Cancellation Semantics (2026-06-09)
- The **throwing** `execute<T>` overload is cancellation-aware: a task cancelled while waiting for a slot throws `CancellationError` immediately — the waiter entry is removed, no slot is consumed, and `work` never runs. Before this, cancelled waiters (e.g. abandoned remote searches) queued up in tier 0 ahead of real user actions and still executed doomed network calls — the cause of the 2026-06 search-mode hang.
- The **non-throwing** (fire-and-forget) `execute` overload intentionally keeps the old behavior: always waits, always runs.
- **Overload-resolution gotcha:** a non-throwing `Void` closure resolves to the fire-and-forget overload even when written with `try await`. To get the cancellation-aware path, the closure must throw or return a value (tests force this with `let _: Int = try await queue.execute { ...; return 1 }`).

### Remote Search (SearchView)
- Typing only searches locally (legacy string match + FTS after 150 ms debounce). **Remote search fires only on keyboard submit** (`triggerRemoteSearch`) — never per keystroke.
- The per-folder remote fan-out runs as child tasks whose cancellation is propagated manually from `searchTask` (the Swift 6 region-isolation checker rejects `group.addTask` closures capturing a SwiftUI view). Cancelled/failed/timed-out folder searches resolve as empty results; whatever completed is merged.
- `triggerRemoteSearch` bumps `searchGeneration` so a re-submit of the same query invalidates the previous wave (otherwise stale children corrupt the `pendingAccounts` counter).

### GRDB Persistence
- All persistence via GRDB `DatabasePool` (`AppDatabase.swift`) — thread-safe concurrent readers, serialized writers via WAL journal mode
- `dbPool.write { db in ... }` for mutations, `dbPool.read { db in ... }` for queries
- No background `DispatchQueue` needed — GRDB handles thread safety internally
- Stale detection runs for **all folders including inbox** — `MessageAICache` preserves AI state for re-inserted messages
- `NavigationStore` provides reactive UI updates (replaces SwiftUI `@Query`)

### GRDB ValueObservation — DO NOT put on `messageHeader`
- **NEVER** use `ValueObservation` to drive the inbox list off the `messageHeader` table. `messageHeader` is written on every sync commit, every AI field update (`actionTag`, `summary`), every unread recount, every backfill batch. A row-level observation would re-emit on every one of those writes, causing full list re-fetch + diff + @Observable invalidation + SwiftUI re-render many times per second during sync bursts. This is strictly worse than the current design.
- **Current design is load-bearing and correct:** explicit `.inboxDataDidChange` notifications fire at deliberate checkpoints; the observer has a 500ms throttle + dirty-bit coalescer; AI updates route through `.messageDataDidChange` into `flushAIBatch` (per-row in-place snapshot replacement, no full reload).
- **`ValueObservation` IS appropriate for `folder` table** — small set (5–50 rows), rarely changes (only at startup classification and folder add/remove), cheap per emission. `InboxViewModel.startFolderObservation()` uses it to drive `VM.folders` authoritatively; dedup on `(id, role)` keeps `unreadCount` churn from reaching the sink.
- `NavigationStore.outboxMessages` correctly uses `ValueObservation` on the outbox table — small set, user-driven writes only.
- Rule of thumb: `ValueObservation` is only OK on tables where write frequency is low (user-initiated, not sync-driven) AND the tracked set is small.

### AI Priority Processing (ADR-IOS-013)
- **Dual-path architecture** (matching TB's `onMessagesDisplayed`):
  - Direct path: `processOpenedMessage()` — when user opens a message in MessageDetailView, AI runs immediately bypassing queue
  - Queue path: `processMessagesForAccount()` — background batch processing with semaphore (32 workers)
- Per-message dedup in AIService prevents duplicate LLM calls between paths
- `fetchBody` also triggers `processMessage` for inbox messages after body is fetched

### IMAP Message IDs & UID Resolution
- `info.messageId` from SwiftMail is often `nil` (many messages lack Message-ID header)
- Fallback chain: `info.messageId ?? UID ?? sequenceNumber` — stored in `MessageHeader.messageId`
- `resolveUID()` helper in IMAPProvider: numeric IDs → construct `UIDSet(UID(...))` directly; non-numeric → search by `Message-ID` header
- All IMAP operations use `resolveUID()` — never raw `server.search(criteria: [.header("Message-ID", id)])`
- **CRITICAL: IMAP MOVE changes UIDs.** When a message is moved between folders via IMAP, it gets a NEW UID in the destination folder. The old UID is invalid. For any undo/move-back operation on IMAP accounts, ALWAYS use `rfc822MessageId` (RFC 2822 Message-ID header) — NEVER the numeric UID. This ensures `resolveUID` does a header search in the destination folder and finds the correct UID. Gmail uses stable IDs (no fix needed).
- **Stale detection UID remap check**: Before deleting a "stale" local message (not in remote set), fullSync checks if any NEW remote message in the same folder has matching `rfc822MessageId`. If found, it's a UID remap (not stale) — local row is migrated in-place to preserve body/AI cache.
- **Self-send appears as two `MessageHeader` rows (INBOX + Sent) with the same `rfc822MessageId`.** Gmail (and other shared-storage IMAP servers) represents this as one underlying message; iOS materializes it as two rows keyed by `folderId`. `markRead`/`markUnread` use `expandWithSiblingsByRfc822` (in `AccountManagerActions.swift`) to flip BOTH rows in one transaction, decrement BOTH folders' `unreadCount`, and queue ONE `PendingOperation` per folder. For Gmail the second op is a no-op server-side; for plain IMAP it correctly issues a `STORE \Seen` against the sibling folder's UID. Sync is the safety net if rfc822 is missing.
- **`MessageHeader.id` vs `stableId` — CRITICAL distinction**:
  - `MessageHeader.id` (GRDB PK) = `"{accountId}:{folderPath}:{messageId}"`. For IMAP, `messageId` = UID which **changes on MOVE**. For Gmail/Exchange, `messageId` is a stable provider ID.
  - `MessageHeader.stableId` (computed) = `rfc822MessageId` for IMAP (survives folder moves), `messageId` for Gmail/Exchange (already stable). Falls back to raw UID if no rfc822MessageId.
  - **Rule**: Any key that must survive folder moves (PendingOperation messageIds, chat session keys, draft keys) MUST use `stableId`, NEVER `message.id`. Using `message.id` causes orphaned records when IMAP messages move folders.
  - **Pattern**: `"{accountId}:{stableId}"` for unique-per-account keys (chat sessions use `"msg:{accountId}:{stableId}"`, drafts use `"reply:{accountId}:{stableId}"`).
  - See `MessageHeader.swift:108` for the stableId implementation.
- **Body architecture (3 layers)**:
  1. **FTS** = persistent body store. Backfill indexes body text via `indexBodiesForFTS` (one chunk per folder per cycle, no MessageBody created). Embeddings handled separately by `startEmbeddingRebuild`.
  2. **MessageBody (disk cache)** = created ONLY when user opens a message (`fetchBody`), or by AI queue for inbox. Evicted aggressively by `evictStaleBodies`: TTL=4h non-inbox, inbox always retained, 20 most recent per folder retained.
  3. **Memory** = zero bodies in memory except the one currently displayed. No body fetching during sync — sync only syncs headers.
- Snippets derived from body text during FTS indexing. Failed fetches get sentinel `" "` to prevent retry.
- **NEVER fetch bodies inline during sync or backfill header insertion** — body FTS indexing runs as bounded background pass after header backfill completes.
- **Calendar invite ICS resolution is on-demand for Gmail/Exchange + IMAP-batch (race fixed 2026-05-26)**: A `text/calendar` part is classified as an *attachment*, and its ICS bytes are resolved via a SEPARATE network round-trip (`attachmentFetcher`) for Gmail/Exchange (their `FullMessageInfo.icsData` is always `nil`) and for IMAP *batch* fetch when the pipelined part-fetch drops the calendar section. The IMAP *single* user-open fetch (`fetchMessageOnConnection`) reliably prefetches all parts via `fetchAllMessageParts`, which is why **reloading an invite fixes the display**. Previously `BodyRenderer.render` swallowed that on-demand fetch failure with `try?` → empty HTML → `BodyFetchProcessor.process` hit the `else if hasAttachments` branch (true, the invite IS an attachment) → persisted an empty body + `bodyComplete=1` → MessageCardView showed "This message has no content." permanently. Fix: `RenderedBody.hasUnresolvedICS` is set when this render *owned* ICS resolution (fetcher present, no prefetch) but got no usable bytes (`do/catch`, not `try?`); `process` excludes that case from the attachment-only write (`hasAttachments && !hasUnresolvedICS`) and routes it to the retry path bounded by the 3-strike `emptyFetchCount`. NSE passes no fetcher → never flagged (it defers ICS to the main app by design). Tests: `BodyRendererTests` `unresolvedICSWhenFetchThrows` / `resolvedICSOnDemand` / `noFlagWithoutFetcher`.

### iOS Keychain Persistence
- Keychain items survive app deletion/reinstall
- Must detect fresh installs via UserDefaults flag and clear stale Keychain data

### Persistent Offline Action Queue (ADR-IOS-003, ADR-IOS-018)
- **Core principle: Never Drop User Intention** — see CLAUDE.md and DECISIONS.md foundational principle. Both PendingOperation and OutboxMessage implement the same contract: persist before acknowledge, execute asynchronously, survive crashes/kills/disconnections.
- `PendingOperation` GRDB model with `status` (queued/inFlight), supports `setTag`/`removeTag` ops
- Pattern: optimistic local update → `queuePending()` → async `drainPendingQueue()` (AccountManager)
- Queue drains on: network restore (`NetworkMonitor`), foreground return, after each sync poll, app launch
- Conflict detection: "message not found" errors during drain → drop op (server wins)
- **Remote state wins on conflict** — IMAP tag changes from other instances (TB addon) override queued local tags. The most recent writer wins regardless of device origin.
- Sync protection: messages with pending ops skipped during stale detection and re-insertion
- Tag writes (AI + manual) go through queue — replaces `writeActionTagWithRetry`
- Undo: cancels queued ops if still pending, otherwise queues counter-operation (move-back)
- All action methods are synchronous (no async/throws) — queue handles remote execution

### Progressive Backfill & Storage Budget (ADR-IOS-005, ADR-IOS-006)
- **No age cutoff** — backfill always walks to completion: IMAP walks UID range from UIDNEXT-1 to UID 1, Gmail/Exchange exhausts all page tokens. Storage budget is the only gate.
- `StorageEstimator.budgetMB` (UserDefaults, default 2048) — global storage soft cap across all accounts
- After initial sync, `SyncEngine.startBackfill()` fetches older messages in background
- **Backfills ALL folders** (not just primary/secondary) — sorted by priority: inbox → favorites → secondary → custom
- IMAP backfill uses UID range walking (no SEARCH, avoids NIO 8KB buffer limit)
- Gmail/Exchange uses page-token cursor walk from newest to oldest
- **Backfill inserts via GRDB**: `insertBackfillBatch` uses `dbPool.write { }` — GRDB's `DatabasePool` is thread-safe, no background DispatchQueue or ModelContext needed.
- **Strictly incremental backfill** (no large object materialization): Two-step approach — (1) provider SEARCH/LIST returns lightweight IDs, (2) batch `fetchSet` existence checks via GRDB (never materializes objects), (3) FETCH only missing IDs. `insertBackfillBatch` uses a batch `fetchSet` for final dedup (one query, not per-row). Returns `(inserted, ftsRecords)` — FTS indexing coalesced per window by caller.
- `Folder.backfillComplete` / `Folder.oldestSyncedDate` track per-folder progress
- Backfill pauses for user activity via `signalUserActivity()` → `waitForIdle()` at folder, window, deep-crawl, BodyFTS, and SnippetFill boundaries. Inner loops also check `isUserActive` per-iteration for near-immediate yield. Views signal activity via `.onScrollPhaseChange` → `AccountManager.signalViewActivity()`
- **IMAP pool priority checkout**: `pool.checkout(priority: true)` inserts at FRONT of waiter queue — used by all user-initiated IMAP methods (fetchMessage, markRead, archive, delete, move, search, fetchAttachment, fetchOlderMessages). Background backfill batches use `priority: false` (FIFO). Ensures user ops never wait behind multiple background batches.
- **fullSync**: GRDB writes are immediate and don't trigger SwiftUI re-renders directly — `NavigationStore` handles UI refresh.
- **No age-based eviction** — fetched messages are never deleted based on age
- **Storage pruning**: `pruneIfOverBudget()` runs after sync — deletes bodies first (re-fetchable), then headers, oldest-first across ALL accounts, but keeps ≥50 messages per folder
- **StorageEstimator**: measures actual file sizes (GRDB `tabmail.sqlite` + FTS `fts.db` + WAL/SHM files) across Application Support
- **MessageBody**: only stores `htmlContent` (no `textContent`). Plain-text-only emails converted via `plainTextToHTML` on ingest using RFC 3676 format=flowed: trailing space before line break = soft wrap (join with next line), no trailing space = hard break (preserve). `white-space: pre-wrap` on container preserves multiple spaces. FTS holds stripped plain text for search.
- **Infinite scroll**: `fetchOlderMessages()` in SyncEngine/AccountManager, triggered by sentinel view at bottom of inbox list. IMAP uses bounded SEARCH windows to avoid buffer overflow.
- **Power-aware backfill (BackfillProfile)**: Two profiles — `normal` (default) and `aggressive` (on power + user idle 30s+ + not low-power + not thermally throttled). Aggressive mode uses larger chunks (1000 vs 500), higher batch sizes, and much shorter delays (0.1s vs 0.5s between batches, 0.5s vs 3s between cycles). `UIDevice.current.isBatteryMonitoringEnabled = true` set in TabMailApp.init. Profile checked dynamically at each decision point via `SyncEngine.backfillProfile`. **Battery gate**: backfill pauses entirely when battery < 20% and not charging (`shouldPauseBackfill`). **Cellular gate**: on metered connections (`NetworkMonitor.isExpensive`), only inbox-role folders are backfilled.
- **Per-batch pool checkout**: `fetchMessageHeaders` checks out a pool connection per batch (100/200 UIDs) instead of holding one for the entire call. Each batch gets a fresh connection, re-SELECTs the folder, and returns it. Other operations can use the pool between batches.
- **Connection failure backoff**: After 3 consecutive connection failures within a backfill cycle, the cycle aborts. Next sync poll restarts backfill with a fresh connection.

### Backfill / Fast Sync Completion — gate on `pendingBodyCount`, NEVER a server total
- **`BackfillProgress.isFullyComplete` gates on `headersDone && totalEmails > 0 && pendingBodyCount == 0`** (`AccountManager.swift`). `pendingBodyCount` = body-eligible headers still awaiting fetch (`headerComplete=1 AND bodyComplete=0 AND bodyEmptyConfirmed=0`), the same criteria `BackfillBodyQueue`/`ActiveBodyQueue` select on. It is local and self-terminating (empty/404/oversized bodies confirm-empty), so it reaches 0 once the body queues have nothing fetchable left.
- **DO NOT gate completion on `ftsIndexed >= totalEmails`.** For Gmail/Exchange, `totalEmails` is a *server-reported* count that counts a **different population** than the mail headers we store, and can permanently exceed it → completion becomes unsatisfiable:
  - **Exchange**: `serverMessageTotal = SUM(folder.totalCount)` = sum of Graph `totalItemCount` across ALL folders, incl. Deleted Items, Junk, and hidden/system folders (`includeHiddenFolders=true` in `ExchangeProvider.fetchFolders`), plus non-mail items that `parseGraphMessage` drops (`compactMap` → nil). One row per message (folders don't overlap).
  - **Gmail**: `getMessagesTotal()` = `profile.messagesTotal`, **deduplicated** across labels (and includes Spam/Trash/Chat). But `grdbTotal` counts per-`(label, message)` rows (`MessageHeader.id` is keyed by `folderPath`), so the units don't match — Gmail "worked" only by accident when label memberships inflated `grdbTotal` past `messagesTotal`.
  - **IMAP**: unaffected — `uidTotal > 0`, so the server-total override is skipped and `totalEmails = grdbTotal`.
- **`totalEmails` (server total) is only the progress-BAR denominator while crawling** (`if uidTotal == 0 && !headersDone` in `SyncEngineBackfill.updateBackfillProgressForAccount`). Once `headersDone`, it falls back to `grdbTotal` so the bar reaches 100% consistently with completion. `serverMessageTotal` is cached once per session and never reconciled down.
- **Symptom of the old bug** (fixed): an Outlook/Exchange account that "never completes sync" — Fast Sync screen stuck below 100% / no "Sync Complete", Settings sync row unfinished, and the chat pill's "agent search results may be incomplete" banner (`DynamicIslandChatButton`, driven by `isBackfillInProgress`) stuck on forever. It is a **completion-criteria/reporting defect, not a runaway loop** — the backfill task itself exits on `isFolderWalkComplete` (headersDone), independent of `isFullyComplete`. The "deleted messages aren't counted right" intuition was exactly correct: `totalItemCount` over-counts deleted/hidden/non-mail items. Regression: `BackfillProgressCompletionTests`.

### Ever-Rolling FIFO Queues (ADR-IOS-027)
- **Philosophy**: Items NEVER leave queue until confirmed success or confirmed stale. No fire-and-forget.
- **Dispatch pattern**: move to back → mark in-flight → fire task → on success: remove; on failure: clear in-flight, item stays at back for retry.
- **Two-phase dispatch**: Phase 1 synchronous (collect candidates, no await). Phase 2 async (resolve deps, launch tasks). Prevents actor reentrancy bugs.
- **Boot-time recovery**: Every queue has `repopulateFromDatabase()` called from `SyncScheduler` on foreground return + BGProcessingTask.
- **Queues**: `ActiveBodyQueue`, `ActiveAIQueue`, `BackfillEmbeddingQueue` — all follow identical pattern.
- **No pause mechanism** — IMAP pool priority checkout handles user-vs-background contention naturally.
- Self-heal/consolidation should never need to do real work — purely a safety net.

### Bounded Memory (CRITICAL)
- **Every loop/batch operation MUST process a bounded number of items** — never accumulate unbounded arrays or materialize all objects
- All chunk/batch sizes are centralized in `SyncConfig` enum (`Services/Sync/SyncConfig.swift`) and `BackfillProfile` enum — never hardcode numeric limits elsewhere
- Current defaults (normal profile): sync=50, snippets=25, backfill=500, prune=50, FTS index=200, embeddings=50, body FTS=20
- Aggressive profile: backfill=1000, IMAP fetch batch=200 (per-lock), Gmail fetch batch=100, body FTS=50
- GRDB queries: use `Column("folderId") == fid` where `folder.id` is `"accountId:path"`, unique across accounts

### Optimistic UI Rollback
- `toggleRead`/`toggleFlag`: change local state first, revert on remote failure
- `archive`/`delete`/`move`: local state only updates after remote success — no rollback needed, but error shown
- **Never use `try?`** for remote operations — always `do/catch` to show errors and revert
- **Same-role actions are no-ops (2026-06-09): archive-from-Archive AND delete-from-Trash, guarded at three layers**: (1) `AccountManager.move` filters out messages whose `folderPath == destinationPath`, and `AccountManager.archive/delete` drop messages via `messagesNotInRole` (choke points for ALL surfaces incl. agent tools); (2) `InboxViewModel.archive`/`archiveThread`/`delete`/`deleteThread` early-return (no undo entry, no overlay) and expose `archiveIsNoOp(_:)` / `deleteIsNoOp(_:)`; (3) the eight InboxView archive/delete handlers guard on those predicates BEFORE inserting into `dismissedMessages` — the dismiss-then-act ordering means a VM-only guard would still make the row vanish. `MessageDetailViewModel.archive()/archiveMessage()/delete()/deleteMessage()` return `@discardableResult Bool` ("performed") so detail-view call sites skip dismiss/flash on no-op.
  - **The check MUST be role-based first, path-comparison second.** Accounts can carry MORE THAN ONE folder per role (e.g. iCloud "Trash" + "Deleted Messages" — the v48 dedup migration left edge cases; Account Detail shows a ⚠ icon). `lookupFolderPath(accountId:role:)` is `fetchOne`-arbitrary among duplicates, so a path-only no-op check fails in the folder the user is viewing AND the "delete" silently moves the message to the OTHER trash folder — which in the unified Trash view keeps it inside the folder set, so `loadedMessages` never shrinks, the `expandedThreads` prune never fires, and the expansion/selection visuals linger. This was the trash-only bug report of 2026-06-09; archive worked only because that account had a single archive-role folder.
  - Drafts unaffected (draft deletion goes through `deleteDraftMessage`, not move-to-trash). Delete-in-Trash does NOT perma-delete — it's a plain no-op by design. Tests: `SameFolderNoOpTests` (incl. duplicate-trash scenarios).
  - **A no-op `Button(role: .destructive)` in `.swipeActions` still ghosts the row.** SwiftUI plays its automatic destructive row-removal animation when the button activates, REGARDLESS of what the action closure does — a guard-and-return closure leaves the row yanked-then-snapped-back with selection-looking artifacts (the residual "trash still broken" report of 2026-06-09; archive looked fine only because its button has no destructive role).
  - **UX decision (user, 2026-06-09): same-role no-op swipe buttons stay VISIBLE but GRAYED OUT** (`disabledSwipeTint` = systemGray3); tapping just closes the swipe menu (action no-ops via the handler guards). Do NOT hide the buttons (tried, rejected). In trash contexts the Trash button drops its `.destructive` role (ghost-animation above) — `Button(role: isTrashContext ? nil : .destructive)` + conditional tint via `isTrashContext`/`isArchiveContext` (mirrors `isDraftsContext`). Handler guards log `[NoOpGuard] …` via `BackgroundSyncLogger.logInbox` (console + inbox.log) for repro confirmation.
  - **FIXED (2026-06-09): Gmail optimistic move left a duplicate row.** Optimistic move keeps the PK (`acct:INBOX:gid`) while setting folderId/folderPath=TRASH; for stable-id providers the remnant's messageId stays in the remote set forever, so it never reaches the stale/UID-remap path that re-keys IMAP rows — and historical insert paths left BOTH the remnant AND a canonical `acct:TRASH:gid` row → phantom 2-member self-threads in Trash (evidence: logmain.log 2026-06-09 `[UndoStack] DB state` dump for msgId 19eaf470a1c6e217). Fix: `SyncEngine.canonicalizeLocalRows` runs in the fullSync upsert loop — merges duplicates (preferring the canonical-PK row, keeping AI fields + richest body; `bodyComplete`/`bodyEmptyConfirmed` are NOT OR-merged — they must describe the survivor's OWN FTS row) and re-keys remnants to the canonical PK (delete+reinsert since `messageBody` FK CASCADE forbids PK UPDATE; body reattached; canonical-PK-held-by-another-folder collision skips the re-key). Merge-loser ids ride `staleIds` out of FTS. Drafts/Sent exempt (DraftStore manages row identity). Trash is in `secondaryRoles` → existing duplicates self-heal on the next periodic fullSync or on opening the folder. The synthetic `__GMAIL_ALL_MAIL__` archive heals too — `GmailProvider.fetchMessages` implements the All-Mail query, so on-demand/periodic sync runs the canonicalizer there (field-verified 2026-06-09: 86 trash + 75 archive re-keys + the phantom merge, 0 collisions). Known residual: FTS→GRDB orphans from the pre-fix era (FTS entries whose header id no longer exists) have no pruning pass — occasional stale search hit with degraded display; bounded, can't grow anymore. Tests: `HeaderCanonicalizeTests`, `SearchIndexRekeyTests`.
  - **Header re-keys go through `SearchIndex.rekeyHeaders` — IN-PLACE id update, never delete+reindex.** FTS rows are keyed by `message_ids.headerId` (PK) → rowid; the rowid carries the indexed BODY text and the `messages_vec` embedding. Deleting + re-indexing loses both (body refetch + re-embed churn; the PLAN_FTS_BODY_LOSS class). `rekeyHeaders` UPDATEs `message_ids.headerId` + `message_meta.headerId` (+ FTS `msgId` column on UID remaps), with a collision fallback (newId already indexed → drop the old entry). The `SyncMessagesResult.ftsRekeys` channel feeds it from both consumers (`processSyncResult` + instance `syncMessages`). The pre-existing **UID-remap path never touched FTS at all** (ghost entries under dead header ids + new ids invisible until backfill self-heal) — it now emits `ftsRekeys` too. Beware: `staleIds` was ASSIGNED (`= staleFiltered.map(\.id)`) mid-function — it's now `append(contentsOf:)` so earlier appends survive.

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

### SwiftUI Observable Array Mutation Safety
- **NEVER remove items from an `@Observable` array synchronously during a lifecycle callback (`onAppear`/`onDisappear`) when that array feeds the same `ForEach`** — SwiftUI is mid-layout and will crash
- **Safe pattern for removals**: defer to the next run loop via `Task { @MainActor in ... }` — this lets the current layout pass complete before the mutation fires
- **Appending is generally safe** from lifecycle callbacks — new items don't invalidate existing layout
- **User action handlers** (button press, swipe action, gesture) are safe for both append and remove — SwiftUI processes these between layout passes
- When evicting from a paginated array, keep evicted IDs in the dedup set to prevent infinite re-fetch cycles — reset the set on full reload only
- Example safe eviction:
  ```swift
  // Called from onAppear flow — must defer
  private func scheduleEvictionIfNeeded() {
      guard loadedMessages.count > maxLoaded else { return }
      Task { @MainActor in  // Deferred — safe
          self.loadedMessages.removeFirst(trimCount)
      }
  }
  ```

### SwiftUI Layout Gotchas
- **Label width in compose rows**: `labelWidth` constant in ComposeView must accommodate the longest label ("From" = 4 chars). Currently 42pt at `.subheadline`. If adding longer labels, increase this.
- **Custom Layout (FlowLayout)**: Unlike built-in views, custom `Layout` protocol implementations don't fill available width. Always add `.frame(maxWidth: .infinity, alignment: .leading)` on the container.
- **HStack baseline alignment**: Use `.firstTextBaseline` (not `.top`) when mixing labels with text fields of different font sizes — avoids manual padding hacks.
- **Menu vs Picker for full-width dropdowns**: Use `Menu` instead of `Picker` when you need the collapsed label to fill available width with truncation. `Picker` auto-sizes its label to content width.
- **Menu tint override**: SwiftUI `Menu` applies the default accent (blue) tint to its label, overriding any `.foregroundStyle()` on the label content. Always add `.tint(.primary)` on the `Menu` itself when you want non-blue icons.
- **NEVER nest `.animation(_:value:)` modifiers** on ancestor views of a ScrollView+LazyVStack — multiple parent `.animation()` modifiers create competing animation contexts that cause layout feedback loops (infinite hang). Use explicit `withAnimation` at state change sites instead. ComposeView (one `.animation()` at root) works; InboxView/MessageDetailView (multiple nested `.animation()`) caused hangs.
- **ScrollView bottom-pinning**: Use `.defaultScrollAnchor(.bottom)` + `ScrollPosition` with `.scrollPosition($pos)` for chat-style scroll. Use `pos.scrollTo(edge: .bottom)` in `onChange` handlers for discrete events (message count, isWorking, expand, keyboard focus). Avoids manual per-line `scrollTo` which causes layout feedback at high frequency.
- **NEVER use LazyVStack in chat-style ScrollView with `scrollTo`**: LazyVStack recycles off-screen cells, causing `contentHeight` to fluctuate wildly (e.g. 4513→917→3148) when scroll position changes. This creates visible jumps. Use regular `VStack` instead — chat pills have <20 messages so lazy loading provides no benefit. ([Apple Forums thread](https://developer.apple.com/forums/thread/685461))
- **ProgressView + `.geometryGroup()` + `.background(.regularMaterial)` in ScrollView**: this combination can cause layout loops. Removing `.geometryGroup()` and parent `.animation()` modifiers fixes it. `.geometryGroup()` is rarely needed if expand/collapse uses explicit `withAnimation`.
- **No sticky/floating section headers** — `List` pins section headers on scroll; `Form` does not. Always use `Form` (not `List`) for settings-style screens to avoid floating headers. This is a design rule.

### HTML Email Render Pipeline (AutoSizingHTMLView) — MUST stay idempotent (ADR-IOS-039)
- The render is a measure→mutate→re-measure pipeline with **two feedback-loop arms**, both now closed. Do not reopen either:
  - **Height arm** (closed earlier): `html,body{height:auto;min-height:0;max-height:none}` in `EmailHTMLWrapper` stops `scrollHeight` inheriting the layout-viewport floor; `monitorHeightJS` reads `window.__tmLayoutVp` (not `innerWidth`, WebKit bug 170595).
  - **Width arm** (closed 2026-06): `fitViewportJS` has an **idempotency guard** — bails if `window.__tmLayoutVp` is already set. Without it, every re-entry (esp. the `didBecomeActive` foreground re-fit) re-measured a widened document against an unreliable `innerWidth` and re-mutated it → fonts shrank on every background→foreground cycle.
- `fit()` stamps `window.__tmDeviceWidth` from `webView.bounds.width` before running the script — **never trust `window.innerWidth`** anywhere in this pipeline (bug 170595). `monitorHeightJS` vp fallback chain: `__tmLayoutVp || __tmDeviceWidth || innerWidth`.
- Re-fit after a REAL width change (rotation/sheet resize) goes through `viewportResetJS(deviceWidth:)` which clears `__tmLayoutVp` + restores `width=device-width` BEFORE `fit()` — required or the guard bails and heights scale against the stale viewport.
- **ScrollFreezeGate** (in AutoSizingHTMLView.swift; Mutex-based, NOT @MainActor — the Coordinator is nonisolated): while the detail List scroll phase is non-idle, Coordinators buffer changed heights in `pendingHeight` and flush on `.scrollFreezeReleased`. Prevents row resize mid-pan → List self-sizing repositioning rows under the finger → overlapping cards. Driver: `MessageDetailView` `.onScrollPhaseChange`; `end()` also called in `onDisappear` (a stuck gate freezes height application process-wide). Exception: `height <= 1` (never-sized row) applies immediately.
- Key invariant making this work: `handleHeightMessage` only writes `height` when the value CHANGED — so idempotent re-measurement is free, and only genuine changes (late image loads) ever hit the freeze buffer.
- **HeightSeedCache** (in-memory, NOT disk — ADR-004): List dismantles far-offscreen rows and **`@State height` does NOT survive** recreation (log-proven 2026-06-09: same message reloaded 5×/session with `frameH=1` at onload — row collapsed to 1pt and re-inflated mid-scroll = the residual overlap). `AutoSizingHTMLView.init` seeds `@State` from the cache (keyed by `headerId`); Coordinator writes on every applied height. Seeded row re-enters at its real height; the idempotent re-measure returns the identical value → `!=` guard drops it → row never moves. Seeding is only sound BECAUSE the fit is idempotent — never add a seed/persist layer to a non-convergent measurement pipeline.
- Regression tests: `EmailRenderPipelineTests` (JS pattern asserts incl. idempotency guard) + `ScrollFreezeGateTests` + `HeightSeedCacheTests`.

### Swift Gotchas
- `ActionTag.none` must be fully qualified in `ActionTag?` contexts — bare `.none` resolves to `Optional.none` (nil)

### Folder.== must include every UI-visible field
- `Folder` overrides `==` (Models/Folder.swift) to compare *visible* fields, because SwiftUI's ForEach diff uses Equatable to decide whether to re-render a row even after the underlying `@State`/`@Observable` array reassignment.
- If a UI-visible field is omitted, the row stays cached with stale data even though the DB write succeeded. This bit us on `role` (Settings → Account Detail folder/role rows didn't refresh after re-assignment or "No Role"). Tests: `FolderEqualityTests.differentRole`.
- Rule: when adding any field that the UI reads off `Folder`, add it to `==`. Sync-only fields (cursors, `lastKnownUidNext`) stay out.

### IMAP Folder Role Detection & Dedup (iCloud "Trash" + "Deleted Messages")
- `IMAPProvider.mapRole(attributes:name:)` returns a single role per folder via SPECIAL-USE first, then a name-based fallback. Both "Trash" and "Deleted Messages" match the trash heuristic — without dedup, iCloud accounts ended up with two `.trash` folders (and a confusing/empty unified Trash view).
- `IMAPProvider.dedupRoles(_:)` runs at the end of `fetchFolders()` and demotes losers to `.custom`. Tiebreak: SPECIAL-USE flag first, then `canonicalNameRank` (the position in the canonical-name list — lower wins), then shorter name.
- `fullSync` deliberately does NOT update `role` on existing folders (it only refreshes `name`/`totalCount`/`uidNext`). This protects user manual reassignments — but it also means existing duplicate state needs a one-shot migration.
- Migration `v48_dedupFolderRoles` in `AppDatabase.swift` mirrors the same canonical-name preference (no SPECIAL-USE info on disk) and runs once to heal pre-fix accounts.
- UI: `AccountDetailView`'s "Folder Roles" section shows ALL folders for a role (joined) plus a `exclamationmark.triangle` warning icon when >1 — surfaces edge cases the migration didn't catch.

### Two-Tier Sync (ADR-IOS-009)
- **Delta sync** (every 60s): lightweight check for changes since last sync
  - Gmail: `history.list` API with `lastHistoryId` cursor → returns adds/deletes/label changes
  - IMAP: `STATUS` command per folder → compares `uidNext` + `messageCount` with cached values
- **Full sync** (every 10 min): safety net, self-healing — runs `fullSync()` as before
- Delta sync skips unchanged folders entirely (IMAP) or processes only affected messages (Gmail)
- If delta fails (e.g., Gmail 404 expired cursor), falls through to full sync automatically
- `Account.lastFullSyncAt` tracks when last full sync ran (delta syncs don't update it)
- `Folder.lastKnownUidNext` caches IMAP uidNext for change detection
- `GmailProvider.fetchMessageDetails(ids:)` returns headers + labelIds for folder assignment during delta sync
- `IMAPProvider.folderStatus(path:)` returns quick STATUS without SELECT

### `syncStartup` Budget Discipline (v50/v51 lesson)
- **`syncStartup` is the shared entry point** for FG return, BGAppRefresh, silent push, and BGProcessing. Any blocking work before the `syncTask` spawns is paid by ALL four paths.
- **BGAppRefresh (~25s) and silent push (~30s) have iOS-imposed budgets.** Pre-sync work eats directly into message-fetching/AI-processing time. A 3s pre-sync scan = 10% of push budget burned before a single byte is fetched. When NSE classification or delta sync gets cut off mid-flight, passive "Inbox updated" notifications appear instead of the AI-classified ones.
- **Every pre-`syncTask` step must be cheap at steady state** (<10ms each). Currently: NSE merge (0ms if unchanged), `cancelAllInFlight` (parallel, ~1-5ms), `recoverIncompleteHeaders` (partial-index seek, ~ms). Self-heal 2b/2c and repopulate are detached post-spawn.
- **Adding DB reads to the pre-sync path requires a purpose-built index.** Test with `EXPLAIN QUERY PLAN` — if you see `SCAN messageHeader`, `ANY(...)`, or `USE TEMP B-TREE FOR ORDER BY`, fix before landing. See ADR-IOS-029.
- **Prefer partial indexes for "drain to empty" queries** (crash recovery, orphan repair, queue repopulate). At steady state the index has ~0 rows, seek is free regardless of stats.
- **Incident history**: `BackfillEmbeddingQueue.repopulate` (v50 fix) burned 1.4-4.2s; `recoverIncompleteHeaders` (v51 fix) burned 2-2.6s. Both for 0-row results. Both were planner confusion from overlapping indexes + stale stats. Partial indexes + dropping the superseded full indexes eliminated both.
- **Future verification**: a seeded 100K-row in-memory harness with EXPLAIN + wall-clock assertions per hot query (planned). Until that exists, manual `EXPLAIN QUERY PLAN` probe on any new pre-sync query.

### Stale Message Detection (syncMessages)
- If `messages.count < limit`, we fetched ALL messages in the folder — any local message not in the remote set is stale
- If `messages.count == limit`, only delete local messages with `date >= oldestFetchedDate` (within fetch window)
- Prevents archived/deleted messages from persisting locally in IMAP accounts

### ICS Calendar Import — Invisible SFSafariViewController Hack
- **Problem**: iOS only shows the native "Add to Calendar" dialog (with attendees, RSVP, calendar picker) when Safari navigates to a `text/calendar` MIME type. Third-party apps can't trigger this natively.
- **Solution**: Start a tiny localhost `NWListener` HTTP server serving the ICS data with `Content-Type: text/calendar`, then open it via `SFSafariViewController` configured as an invisible sub-pixel sheet.
- **Key trick — invisible sheet**: Use a custom sheet detent of `0.01` points (sub-pixel, completely invisible). Set `largestUndimmedDetentIdentifier` to match the custom detent's identifier — this prevents background dimming.
- **Shadow removal**: Walk Safari's view hierarchy up from `safari.view.superview` looking for `UIDropShadowView` (internal UIKit class), set `layer.shadowOpacity = 0` to remove the thin line at the sheet edge.
- **Why this works**: iOS intercepts the `text/calendar` MIME type in Safari and presents the native calendar dialog *on top of* the Safari sheet. The calendar dialog lives inside Safari's view hierarchy, so the invisible Safari stays alive underneath.
- **Dismissal**: No auto-dismiss needed since the sheet is invisible. Tear down on: (1) re-tap on ICS attachment, (2) navigating away from message (`onDisappear`), (3) scene entering background.
- **Strong reference required**: `activeSafari` must be a strong (not `weak`) reference — `weak` causes premature deallocation after teardown, making subsequent presentations fail because `topViewController()` returns the zombie Safari.
- **Re-presentation**: Always teardown first, then present after a delay (0.3s if had active session, 0.05s otherwise) to let UIKit process the dismiss animation.
- **Port reuse**: Server tries port 18942 first, falls back to `.any` if in use (TIME_WAIT from previous session).
- **Reusable pattern**: This localhost-server + invisible-SFSafariViewController trick can be adapted for any iOS feature that requires Safari to trigger native system behavior (e.g., `.pkpass` wallet passes, `.mobileconfig` profiles, other MIME-triggered system dialogs).
- **App Store safety**: No private APIs used — just cosmetic `layer.shadowOpacity` changes and standard sheet detent configuration.
- **Implementation**: `ICSCalendarImporter.swift` — `NWListener` server + `SFSafariViewController` + 0.01pt detent

### Attachment Support
- `AttachmentInfo` (filename, contentType, section, size) stored as JSON in `MessageBody.attachmentsJSON`
- IMAP: `IMAPProvider.fetchAttachment` fetches by MIME section via `server.fetchPart(section:of:)`
- Gmail: `GmailProvider.fetchAttachment` fetches by `attachmentId` via REST API (`/messages/{id}/attachments/{attachmentId}`). `AttachmentInfo.section` stores the `attachmentId` for Gmail.
- Gmail attachment metadata extracted in `fetchMessage` via `extractAttachments(from:)` — recursively walks the `GmailPart` tree for parts with non-empty `filename` and `body.attachmentId`
- **Walk from the TOP-LEVEL `payload`, not just `payload.parts`** — a single-part message (e.g. a Google **DMARC aggregate report** = one `application/zip`, no text body, no `parts`) carries its attachment on the payload node itself. `fetchMessage` builds a synthetic root `GmailPart` from `msg.payload` (mimeType/filename/headers/body/parts) and passes that to `extractAttachments`, mirroring the shared NSE parser `GmailParse.walkParts` (which is why the inbox `hasAttachments` paperclip was already correct via `GmailParse.parseMessage`). `GmailPayload` gained a `filename` field (with a defaulted memberwise init) for this. Regression test: `GmailProviderMockTests.singlePartAttachmentOnlyMessage`.
  - **Why it mattered (infinite-loop bug, fixed 2026-06):** before the fix, such a message came back with empty body AND `attachments=0` → `BodyFetchProcessor` confirmed it empty (`bodyComplete=1`, FTS body empty) → the AI **reply** job (`ActiveAIQueue`, `WHERE isInInbox=1 AND bodyComplete=1 AND cachedReply IS NULL`) re-enqueued forever, dropping at the "No FTS body" guard each time (`maxRetries:.max`). The no-reply filter never ran (reply dropped before reaching `processReply`), so the inbox kept showing the reply as pending. Root-cause fix = surface the attachment so it routes through the `[attachment]` body path instead of confirmed-empty. (`cachedReply=''` on confirmed-empty was the considered loop-stopper alternative; not needed once the parse is fixed.)
- `Section` type in SwiftMail: construct with `Section("1.2")` (dot-separated string) or `Section([1, 2])` (array)
- QuickLook preview: write to temp file → `.quickLookPreview($previewURL)`
- Share/save: `ShareLink(item: fileURL)` on downloaded attachment rows in `AttachmentListView`
- Downloaded files cached in `downloadedFiles: [String: URL]` — re-tap shows QuickLook without re-download

### Compose AI Suggestion — chat pill edits suggestion in place when bubble is visible
- Reply suggestion bubble (`ComposeView.swift:307-335`) and the body TextEditor are mutually exclusive — while the bubble is up, `messageBody` is empty.
- Chat pill ("Edit Draft") routes by `showingSuggestion`:
  - **Bubble visible:** input = `currentSuggestion`, output writes back to `currentSuggestion` AND `messageHeader.cachedReply` (DB) so reopens show the edited version. Bubble stays up.
  - **After Use Reply / Dismiss:** input/output is `messageBody` (existing flow, unchanged).
- `prepopulate()` re-reads `cachedReply` fresh from DB so prior edits survive in-memory staleness of caller's `MessageHeader` snapshot.
- Recompute (`ComposeView.swift:825`) still overwrites `cachedReply` — by design, "give me a fresh AI draft" discards edits.
- Subject / recipient deltas always go to compose state, regardless of whether bubble is up.

### Compose body — caret-aware scroll, NO input gating
- Compose body uses `TextEditor` with `.scrollDisabled(true)` inside the parent SwiftUI `ScrollView`. UIKit propagates scroll-to-cursor via `scrollRectToVisible` on the enclosing UIScrollView, passing the **whole TextEditor frame** (often hundreds of pt) — so we swap the scroll view's class to `CaretAwareUIScrollView` (`ComposeView.swift`) which substitutes the caret rect, no-ops if already visible, and animates with a `UIViewPropertyAnimator`.
- **DO NOT gate text input during scroll.** A previous version (commit 755fe97, removed) class-swapped the focused UITextView to a `GatedUITextView` and dropped `insertText`/`deleteBackward`/`paste` for 500 ms after every `scrollRectToVisible`. UIKit fires that on every line wrap / Enter / keyboard frame change during normal typing — so a fast typist lost 4-6 keystrokes whenever the body scrolled. There are no real "accidental keystrokes" to drop (UIKit doesn't pre-queue keypresses); the gate is purely destructive.
- If you ever feel the urge to "block input briefly while the UI settles" in compose, stop and re-read this note.

### Compose Attachments
- `DraftAttachment` (filename, mimeType, data) in `DraftMessage.swift`
- ComposeView: bottom-right `Menu` with `PhotosPicker`, file importer (`.item`), camera (`CameraPickerView`)
- IMAP send: `DraftAttachment` → SwiftMail `Attachment(filename:mimeType:data:)` → `Email(... attachments:)` — SwiftMail `constructContent()` handles MIME multipart
- Gmail send: `buildMIMEMessage(draft:)` produces `multipart/mixed` with base64 attachment parts, base64url-encoded for `messages/send` API
- `CameraPickerView.swift`: `UIImagePickerController` wrapper via `UIViewControllerRepresentable`
- `NSCameraUsageDescription` in `Info.plist` for camera access

### SwiftMail Types
- `Section` — top-level struct (NOT `MessagePart.Section`)
- `UID(_ value: UInt32)` — construct UID from UInt32
- `UIDSet(UID(...))` — construct from single UID
- `Mailbox.Selection` — returned by `server.selectMailbox()`
- `Mailbox.Info.Attributes` — folder attributes (`.inbox`, `.sent`, etc.)

### Hybrid FTS5 + Vector Search (Local)
- **Separate SQLite database** (`fts.db` in Application Support) using GRDB — separate from main `tabmail.sqlite`
- **FTS5 schema**: 7 columns matching TB — `messages_fts_YYYY` (msgId, subject, from_, to_, cc, bcc, body) year-sharded
- **BM25 weights**: msgId=0, subject=5, from_=3, to_=2, cc=1, bcc=1, body=1
- **UNION ALL search**: single query across all year shards (not per-year loop). Date filtering in SQL.
- **Synonym expansion**: ~65 email synonym groups (ported from Rust `synonyms.rs`)
- **Query parser**: field aliases (`from:` → `from_:`), auto-wildcards for tokens ≥4 chars, OR groups for synonyms
- **Vector search**: sqlite-vec KNN (v0.1.7-alpha.2), embeddings in `messages_vec` virtual table
- **sqlite-vec safety**: ALL `messages_vec` access MUST go through the writer connection (`writeWithoutTransaction` for reads). Reader pool connections create vec0 vtab instances that crash in `vec0_free_resources` on disconnect. No `sqlite3_auto_extension` — registered per-connection in SearchIndex only.
- **Hybrid merge**: 70% vector / 30% keyword scoring, min score 0.1, 4× candidate multiplier
- **FTS-only fallback**: when vec table empty (embedding rebuild), uses `searchFTSOnly()` — sorts by dateMs DESC, rank ASC
- **Date-range scan**: `query="*"` with date params → `scanByDateRange()` (no FTS MATCH, just date filter on message_meta)
- **Column-scope filter-first**: `from:"email"` queries pre-filter vec candidates to matching rowids
- **Indexing pipeline**: headers indexed synchronously (`await indexHeadersForFTS`) — no `Task.detached`, eliminating body race condition. Body + embedding on fetchBody (AccountManager hook).
- **Bulk index**: runs after sync if FTS index is sparse (first-launch catch-up). Phase 1: headers, Phase 2: body backfill from GRDB.
- **Background embedding rebuild**: generates embeddings for messages with bodies but no embeddings, low priority
- **Model conversion**: `Scripts/convert_model.py` → `AllMiniLML6v2.mlmodelc` + `tokenizer.json` in Resources
- **Graceful degradation**: if model/tokenizer not in bundle, falls back to FTS-only (keyword search)

### Device Prompt Sync & AI Cache Probe
- `DeviceSyncService` — always-on WebSocket to Cloudflare DO relay (`sync-dev.tabmail.ai`)
- Auto-connect in `RootView.task`, reconnect in `.active`, disconnect in `.background`
- **Text fields (composition, action, kb)**: State-based delta merge with **peer-received base** as common ancestor. Steps: (1) epoch-zero → skip, (2) stale → skip, (3) first sync (no peer base) → LWW, (4) fast-forward (no local changes) → accept incoming, (5) both changed → 3-way bullet merge using `peer_base` as ancestor. **Critical**: `peer_base = incoming` (what peer sent), NOT merged result. Peer base stored in UserDefaults (`device_peer_base:*` / `device_peer_base_ts:*` keys). One-time migration from old `syncBase*` keys.
- **Templates**: per-template CRDT merge by id (newer `updatedAt` wins per template)
- **DisabledReminders**: per-hash CRDT merge (newer `ts` wins per hash)
- **Epoch-zero protection**: defaults and resets get epoch-zero timestamps — never overwrite customized content
- **Virgin device detection**: all timestamps epoch-zero → skip broadcast, probe peers instead
- `isSyncApplying` flag prevents echo loops when applying incoming sync
- 500ms debounce on outgoing broadcasts to prevent flooding during typing
- **AI cache probe**: before LLM, ask connected peers for cached results via `probeAICache(keys:)` (2s timeout, always probes)
- Probe key = RFC 2822 Message-ID header without angle brackets (device-independent, matches TB's `headerMessageId`)
- `rfc822MessageId` field on `MessageHeader` — populated from IMAP ENVELOPE or Gmail `Message-Id` header
- TB IDB keys: `summary:<accountId>:<folderPath>:<cleanHeaderMessageId>` — iOS probe handler searches by `rfc822MessageId.contains(key)`
- Date encoding: `.iso8601` for cross-platform template sync (TB sends ISO strings, not timestamps)
- Backend SSE: `BackendClient.extractSSEFinalData()` parses `event: final` from `text/event-stream` responses

### Cross-Instance Action Tag Sync (ADR-IOS-036, supersedes ADR-IOS-004 "First Compute Wins")
- Action tags are **local-only** on iOS. No `tm_*` IMAP keyword, Gmail label, or Exchange category is written or read. `MessageHeader.actionTag` is driven by `MessageAICache.restoreIfCached` + AIService classification only.
- Cross-device parity on overlapping inboxes uses **Device Sync** (`DeviceSyncService.probeAICache`): iOS probes peers on cache miss before running the LLM. Peers that have the classification respond with `AICacheResult(summary, action, reply)`.
- Async cross-device pickup (device A offline when device B processes) is intentionally **not** covered — device B runs the LLM independently. Cost = one duplicate LLM call per miss. Accepted tradeoff.
- User manual overrides (long-press menu → pick action) go through `AccountManagerAI.setManualTag`: optimistic local `MessageHeader.actionTag` + `MessageAICache` write, plus a PendingOperation(.setTag) that drains to a no-op (legacy queue rows flush cleanly).
- Legacy `tm_*` keywords/labels/categories still present on user servers from prior versions are **not scrubbed** (too risky); they decay naturally as messages turn over. `UserLabelStore.shouldExcludeLabel` (matches `tm_` prefix) keeps them out of user-visible label chips.

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

### Background AI Processing (Tier 3)
- **BGProcessingTask** (`ai.tabmail.ai-processing`) — long-running background task for AI processing (up to ~10 min)
- Requires `processing` in `UIBackgroundModes` and task ID in `BGTaskSchedulerPermittedIdentifiers`
- Registered in `TabMailApp.init`, handled in `SyncScheduler.handleBackgroundAIProcessing()`
- Scheduled on app background in `RootView.onChange(of: scenePhase)`, 5 min earliest begin date
- Flow: WiFi check → poll (sync) → processMessagesForAccount per active account → embeddings → badge update
- **`beginBackgroundTask`** protects in-flight AI calls in both `processMessagesForAccount` (queue path) and `processMessage` (priority path) — ~30s grace period when app backgrounds

### Swift 6 BGTask Isolation Pattern (ADR-IOS-020) — CRITICAL
- **BGTask expiration handlers run on arbitrary Apple threads** — NOT the main thread
- In Swift 6, ALL locals in `@MainActor` methods are main-actor-isolated — accessing them from `@Sendable` expiration closures causes `EXC_BREAKPOINT` at runtime, even for `Sendable` types like `Mutex<Bool>`
- **`nonisolated(unsafe)` on locals does NOT help** — only works on stored properties (SE-0412)
- **Required pattern for BGTask handlers in `@MainActor` classes:**
  1. Handler method must be `nonisolated func` (strips isolation from locals)
  2. Shared state via `BGTaskContext` class (`@unchecked Sendable` + `NSLock`)
  3. `@preconcurrency import BackgroundTasks` (ObjC types lack Sendable annotations)
  4. Set `task.expirationHandler` BEFORE creating `Task { @MainActor in }` (use-then-send ordering for SE-0414)
  5. Only the `Task { @MainActor in }` body calls `task.setTaskCompleted` — expiration handler only sets flag + cancels task
- **`CheckedContinuation` double-resume guard**: `NWPathMonitor.pathUpdateHandler` can fire multiple times racing with `cancel()`. Always guard with `Mutex<Bool>` before `continuation.resume()`
- **`requestBackgroundGracePeriod`**: expiration handler must not access `@MainActor` state — use a safety-timeout `Task { @MainActor in }` to call `endBackgroundTask` instead

### SSE Streaming & Tool Execution Loop
- `BackendClient.sendCompletionsWithTools()` — full multi-turn tool execution loop matching TB's `sendChatCompletions()` + `onToolExecution` pattern
- Parses SSE events: `keepalive`, `tool_started`, `tool_completed`, `tool_failed`, `final`, `error`
- When `final` contains `tool_calls`: executes tools via `ToolRegistry`, appends results to `conversation_state.harmony_messages`, sends next round
- `CompletionsRequest` now includes optional `conversation_state` for multi-turn continuation
- Max 10 tool rounds before forcing a final response with `disable_tools: true`
- `AIService.sendWithTools()` — entry point for tool-enabled completions (used by future chat/reply features)
- Existing summary/action pipeline unchanged (still uses `sendCompletions` — single-shot, no tools)

### Thread (ThreadGroup) Actions — tag-tap dispatch & grouped undo
- A collapsed thread row's badge shows `group.threadTag` = the **highest-priority** tag across all members (`reply`＞`none`＞`archive`＞`delete` by `ActionTag.sortOrder`, computed in `ThreadGroupBuilder.buildDisplayGroups`). This can differ from the representative/head message's own `actionTag`.
- **`InboxView.executeTaggedAction` MUST act on `group.threadTag` for a collapsed thread, NOT `snapshot.actionTag`.** The `snapshot` arg is `group.representative` (the most-recent/head message); using its tag was a bug — tapping a surfaced "reply" badge archived the whole thread when the head happened to be tagged archive. Single messages and expanded-thread child rows still use `snapshot.actionTag`. The `.reply` case targets `snapshot.id` (the head = most recent), which is the intended reply target.
- **All multi-message thread actions push ONE grouped `UndoableAction`** carrying every member, so the whole thread restores in a single undo: `archiveThread` / `deleteThread` / `moveThread` in `InboxViewModel`. `UndoService.undo` + `AccountManagerActions.undoDestructiveAction` restore all members in one write txn + one move-back op. When adding a new whole-thread action, mirror this pattern — never loop a per-message action (that yields N undo entries). Move was the last gap; fixed via `moveThread` + `moveThreadGroup` sheet state (collapsed-thread Move swipe). Expanded-thread child actions stay per-message by design.
- **`InboxView.body` is at the SwiftUI type-checker limit.** Adding another `.sheet`/`.fullScreenCover` modifier triggers "unable to type-check this expression in reasonable time" (error points at an *unrelated* existing modifier). Fold new sheet content into the existing sheet via a `@ViewBuilder` computed property (e.g. `moveSheetContent`) and extract closures into private methods — don't append more top-level modifiers to `body`.
- **`expandedThreads` is pruned in `rebuildDisplayGroups()` (2026-06-09).** Only the head-row swipe/chip paths call `evictAndRebuild` (which removes the group id); every OTHER removal pathway (expanded-child swipe/chip, detail-view archive/delete via `.messageDismissedFromDetail`, agent tools, sync from another device) shrinks the thread without touching `expandedThreads`. A stale id on a group that dropped to `memberCount == 1` permanently painted `Color(.tertiarySystemFill)` listRowBackground (reads as a stuck selection highlight) + hidden separators on the remaining row, with no chevron to clear it (`MessageRowView` renders the toggle only for `isThread`). The prune intersects `expandedThreads` with the rebuilt multi-member group ids — the rebuild choke point covers all pathways. Rule: any UI state keyed by ThreadGroup id must be pruned/validated in `rebuildDisplayGroups`, not at individual call sites. Tests: `InboxViewModelThreadEvictTests` (`childRemovalPrunesExpandedThreads`, `threadRemovalPrunesExpandedThreads`, `survivingThreadKeepsExpansion`).

### Manual Tag Teaching (Long-Press Context Menu)
- Long-press on message rows (both normal and triage view) shows "Tag as Reply/Archive/Delete" + "Remove Tag" context menu
- `InboxView.tagContextMenu(for:)` builds the menu; `InboxViewModel.applyManualTag()` dispatches to `AccountManager.applyManualTag()`
- `AccountManager.applyManualTag()` handles the full flow: optimistic UI → IMAP/Gmail write → AI cache update → fire-and-forget auto-prompt update
- **Auto-prompt refinement**: `AIService.autoUpdateUserPromptOnTag()` sends email metadata + summary + original action + user's correction to backend (`system_prompt_action_refine`), gets an ADD/DEL patch, applies it via `ActionPatchApplier` to `PromptStore.rawAction`
- `ActionPatchApplier` — port of TB's `patchApplier.js`: parses multi-operation patches, finds section headers, handles duplicate detection, case-insensitive DEL matching
- Self-sent emails are blocked from manual tagging (matches TB's `isInternalSender` check)
- Updated user_action.md auto-syncs to TB via Device Sync (PromptStore setter triggers `DeviceSyncService.debouncedBroadcast`)

### Tool Registry (Scaffold)
- `ToolRegistry.swift` — `AgentTool` protocol + `ToolRegistry` actor (central registry matching TB's `core.js`)
- Tools registered at startup, looked up by name during tool execution loop
- Types defined: `CompletionsSSEEvent`, `ToolStatusEvent`, `CompletionsFinalEvent`, `CompletionsToolCall`, `ConversationState`, `HarmonyMessage`, `ToolTrace`, `ToolResult`
- No tool implementations yet — scaffold only. Tools added incrementally (memory_search → email tools → calendar/contacts)

### Agent Chat (ADR-IOS-022, ADR-IOS-023)
- **Mobile-native UX (ADR-IOS-023)**: iOS departs from TB's "infinite chat" UI while keeping backend architecture identical:
  - **No welcome-back/greeting bubbles** — reminders shown as top-of-chat cards instead
  - **Session history with swipe navigation** — past K sessions (configurable, default 10) shown as horizontally swipeable pages in TabView(.page). Rightmost = current/newest. Resuming an old session swaps the conversation history sent to the API.
  - **Multi-turn within session** — `sessionTurns` sent as `history` to API. When resuming an old session, that session's persisted turns become the history.
  - **Nudges become reminder cards** — urgent reminders get accent highlighting, tap to expand, dismiss to snooze
- **ChatStore** (`Services/AI/ChatStore.swift`) — `actor` with GRDB-backed `chatTurn` table. Matches TB's `persistentChatStore.js`.
  - `ChatTurn` model: id, timestamp (epoch ms), role, content, userMessage, type, chars, renderedContent, sessionId
  - Budget enforcement: 50 exchanges max (100 turns), 25K chars max, FIFO eviction in atomic write transaction
  - Turns still persisted for Settings > Chat History view, just not loaded back into live chat
- **AIChat** (`Services/AI/AIChat.swift`) — `AIService` extension for agent chat via completions API
  - Builds: system message (`system_prompt_agent`) + user message (`chat_converse`). History is current session's turns (multi-turn).
  - KB + reminders refreshed per turn (matches TB parity)
  - Sends via `sendWithTools()` — server-side tools auto-execute in backend. Client-side tools registered in ToolRegistry.
  - `chatUserName()` queries GRDB directly for primary account display name (no MainActor dependency)
- **DynamicIslandChatButton** — chat pill UI. On expand: loads reminder cards (InboxView only), registers email context ID. Persists turns on send/receive. `enrichedText` built inside Task block (after awaiting ID registration) to prevent race.
- **ChatHistoryView** (`Views/Settings/ChatHistoryView.swift`) — searchable history in Settings > AI > History > Chat History. Pairs user+assistant turns into exchanges. Debounced GRDB search, expand/collapse on tap, debug stats in toolbar menu.
- **ChatIdTranslator** (`Services/AI/ChatIdTranslator.swift`) — in-memory actor mapping numeric IDs ↔ real MessageHeader.id. Matches TB's `idTranslator.js`. `processResponseForDisplay()` resolves `[Email](N)` patterns to tappable pills with subject text. Cleared when chat history is cleared.
- **Client-Side Tools** (registered in `ToolRegistry` at app startup via `TabMailApp.init()`):
  - `InboxReadTool` (`Services/AI/Tools/InboxReadTool.swift`) — queries GRDB inbox, assigns numeric IDs via ChatIdTranslator, formats matching TB's `formatMailList`. Page size 10.
  - `MemorySearchTool` (`Services/AI/Tools/MemorySearchTool.swift`) — per-turn hybrid FTS5 + sqlite-vec search via `MemoryIndex` (memory.db sidecar). Role-tagged output (USER/AGENT). Page size 5. See ADR-IOS-034.
  - `MemoryReadTool` (`Services/AI/Tools/MemoryReadTool.swift`) — returns session-bounded context window (±N turns from matched timestamp, clamped to matched turn's session). TB parity.
  - Tool definitions live in the backend repo (`src/tools/ios/inbox_read-v1.0.0.json`, `memory_search-v1.0.0.json`)
- **MarkdownChatText** (`Views/Agent/MarkdownChatText.swift`) — SwiftUI view rendering markdown + email pills + reminder cards. Uses `AttributedString(markdown:)` with `inlineOnlyPreservingWhitespace`. Pre-processes `[Email](N)` → `[📧 Subject](tabmail://email/N)` for tappable links. Handles URL taps via NotificationCenter (`.emailPillTapped`).
- **Backend templates** (in the backend repo, `src/prompts/ios/`):
  - `system_prompt_agent-v1.0.0.md` — full iOS agent system prompt (identical to TB v1.2.0 for tool sections, with iOS-specific intro and mobile response formatting)
  - `chat_converse_user_message-v1.0.0.md` → aliased to `chat_converse` in registry (security reminder + `[timestamp] user_message`)
  - `chat_converse_history-v1.0.0.md` — prior session history wrapper (background memory only)
  - `chat_converse_reminders-v1.0.0.md` — reminders injection (currently unused, iOS sends empty string)
- **KB Refinement** (`Services/AI/KBRefinementService.swift`) — `actor` matching TB's `knowledgebase.js`:
  - Triggered on chat session expiry (idle > 30s) with session turns via fire-and-forget Task
  - Sends `system_prompt_kb_refine` + current KB + chat history to backend orchestrator
  - Backend returns `refined_kb` (multi-step: chat summarize → reminder extract → KB refine → trim)
  - Persists refined KB to `PromptStore.shared.rawKB` (triggers Device Sync broadcast + reminder re-parse)
  - Guards: privacy opt-out check, minimum 3 exchanges, serialized execution (drops concurrent calls)
  - Compose mode sessions excluded (no KB value from draft edits)
  - `CompletionsResponse.refined_kb` field decodes the backend orchestrator's response
- **GRDB migration**: v6 (`v6_createChatTurn`) adds `chatTurn` table with timestamp index; v7 adds `renderedContent` column; v11 adds `sessionId` column + index; v12 creates `chatIdMapping` table (numericId PK, realId UNIQUE) for persisting ChatIdTranslator mappings across app restarts
- **ChatIdTranslator persistence**: ID mappings (numeric ↔ real) persisted to GRDB `chatIdMapping` table. Lazy-loaded on first `toNumericId()` call. New mappings written on creation, deleted on eviction/sweep/clear. Ensures `[Email](N)` pill references in old chat sessions remain resolvable
- **Event pill detail must carry notes AND attendees at every cache site**: the `[📅 Title](tabmail://event/N)` popover (`EventPillPopover` in `MarkdownChatText.swift`) renders title/time/recurrence/availability/location/**notes**/attendees/tz/calendar. `EventPillDetail.notes` ← `GCalEvent.description` (Zoom/Meet links live here). Every `cacheEventDetail` call site MUST pass real `notes` + `attendees` — NEVER hardcode `attendees: []` when the data is available. Sites: `CalendarEventCreateTool` (from tool args via `CalendarToolHelpers.eventPillAttendees(fromArguments:)` + `description` arg), both `CalendarEventReadTool` direct-lookup paths and `cacheEventDetailsForPills` (from the `GCalEvent` via `eventPillAttendees(from:)` + `event.description`). `resolveEventDetail`'s live re-fetch also reads `event.description`. Hardcoding empty attendees in the create/read cache is a bug: the in-memory cache HIT short-circuits the live re-fetch, so the pill shows empty until the entry is evicted. (Fixed 2026-05-27; regression tests in `ToolCachingTests` + `CalendarToolHelpersTests`.) Free/busy-reader events intentionally keep `notes: nil` / `attendees: []` (server strips them).
- **Factory reset**: `DELETE FROM chatTurn` included in SettingsView nuke

### Screen Keep-Awake (chat pill)
- `Theme/ScreenKeepAwake.swift` — reference-counted wrapper around `UIApplication.isIdleTimerDisabled` + `.keepScreenAwake(while:)` view modifier. The idle-timer flag is a single global, so holders are counted; the modifier tracks its own held state (`@State holding`) so acquire/release fire exactly once per transition regardless of `onChange` vs `onDisappear` teardown ordering.
- Applied once in `DynamicIslandChatButton.swift` on the pill root: `isExpanded || isWorking || ActiveAgentTracker.shared.anyWorking || speechRecognizer.isRecording` (same scope as the wand-glow indicator). Covers all three host screens (Inbox/Compose/MessageDetail) with no per-screen wiring.
- No `scenePhase` handling needed — iOS only honors `isIdleTimerDisabled` while the app is foreground; the hold resumes automatically on return. Reuse `.keepScreenAwake(while:)` for any future keep-awake need (never set `isIdleTimerDisabled` directly).

### Agent Compose FIFO Queue (ADR-IOS-030)
- **Problem solved**: Agent compose tools (`email_compose`, `email_reply`, `email_forward`) used to write directly to `AgentToolRouter.pendingCompose` (single slot). If a compose window was already presented (manual or prior agent), the second request was silently dropped because SwiftUI cannot stack two `fullScreenCover`s from one source view. The LLM still got a success string back.
- **Fix**: In-memory FIFO queue on `AgentToolRouter`. Tools call `enqueueCompose(_:)` (synchronous, fire-and-forget). Tools' return strings are unchanged.
- **Manual compose blocks the queue**: Tracking lives inside `ComposeView` itself via `.onAppear { composePresentationDidBegin() }` / `.onDisappear { composePresentationDidEnd() }`. Counts every presentation path automatically — manual New, contact, reply, replyAll, forward, agent compose, agent draft. No per-cover-site instrumentation. `DraftComposePresenter` carries the same hook on its body root to close the loading-window race before the inner `ComposeView` renders.
- **Dispatch guard has 4 conditions**: `!awaitingAppear`, `pendingCompose == nil`, `presentationCount == 0`, queue non-empty. `awaitingAppear` is the race-window guard — set to `true` at dispatch, cleared in `composePresentationDidBegin`. Without it, a second `enqueueCompose` arriving between "view nils `pendingCompose` after capture" and "ComposeView's `onAppear` fires" would overwrite the in-flight request via `fullScreenCover(item:)`'s undefined behavior when the binding swaps non-nil identifiables mid-presentation.
- **Decrement-to-zero triggers next dispatch**: `composePresentationDidEnd` clamps at 0 and only calls `dispatchNextIfIdle` when count returns to 0, so the next request appears immediately after the previous window's dismiss animation completes.
- **Lifecycle hooks safe against ComposeView's internal modals**: Apple Forums thread 655338 confirms parent view's `onAppear`/`onDisappear` do NOT fire when parent presents `.alert`, `.popover`, `.photosPicker`, `.fileImporter`, `.sheet`, or `.fullScreenCover`. ComposeView contains all of these (camera fullScreenCover at line 541, alerts, photo picker, etc.) — count does not drift.
- **In-memory only**: Lost on app kill (acceptable — agent compose is session UI intent, not durable user action).
- **No cancellation needed**: User can't tap Stop while a compose `fullScreenCover` is up (chat surface is hidden behind it).
- **`@ObservationIgnored` on private fields**: `composeQueue`, `presentationCount`, `awaitingAppear` are marked `@ObservationIgnored` so they don't create false observation dependencies. Only `pendingCompose` is observed (by view `onChange` handlers).
- **Known limitation**: If neither InboxView nor MessageDetailView is alive when the queue dispatches, `pendingCompose` stalls. Recoverable — opening any compose window clears `awaitingAppear` and resumes draining on the next dismiss.

### Outbox — Persistent Offline Send Queue (ADR-IOS-019)
- `OutboxMessage` GRDB model in `outboxMessage` table — stores full draft (to/cc/bcc/subject/body/isHTML/inReplyTo/references) with status (queued/sending/failed) and `sentAt` timestamp
- Attachments stored on disk under `Application Support/TabMail/outbox_attachments/{id}/` — NOT in DB blob. Files use index prefix for ordering, `.meta` sidecar for MIME type
- `AccountManager.queueSend()` — throws on failure. Persists to GRDB + disk, fires `drainOutbox()` async. ComposeView only dismisses on success; shows error if persistence fails
- `AccountManager.drainOutbox()` — only drains `.queued` messages (not `.failed`). Mirrors `drainPendingQueue()` pattern: isDrainingOutbox guard, NetworkMonitor gate, FIFO by createdAt. All DB writes use `do/catch` with 3 retries (never `try?`)
- **Message-ID pre-generation**: Before SMTP send, a stable RFC822 Message-ID is generated (`sentMessageId` column) and injected into the draft. Both SMTP send and IMAP Sent append use the same ID. SwiftMail fork's `constructContent` respects pre-set `Message-Id` in `additionalHeaders`.
- **Send success path**: provider.send() → stamp `sentAt` → IMAP APPEND to Sent folder (dedup by Message-ID SEARCH) → stamp `appendedToSent` → delete from DB → delete attachments from disk. Gmail/Exchange auto-save to Sent (no-op append). IMAP requires explicit APPEND.
- **Persistent Sent append**: If IMAP APPEND fails, outbox message stays with `sentAt != nil`, `appendedToSent == false`. `drainPendingSentAppends()` retries on next drain. Message only finalized when both send AND append succeed.
- **Send failure path**: retryCount < 3 keeps as `queued` (auto-retry next drain). retryCount >= 3 marks `failed` (user must tap Retry, which resets retryCount to 0)
- **Crash recovery**: `reconcileOutbox()` — sentAt!=nil + appendedToSent → delete (fully done). sentAt!=nil + !appendedToSent → keep for append retry. sentAt==nil + status=sending → reset to queued. Also cleans orphaned attachment dirs
- Drain triggers: NetworkMonitor reconnect, app launch (reconcileOutbox), after queueSend, SyncScheduler foreground polling + after each poll
- `toDraftMessage()` and `loadAttachments()` throw — prevents sending email with missing/corrupted attachments
- Discard refused for `sending` messages (UI hides button + backend guard). Discard uses atomic single-write-transaction fetch+delete
- UI: `NavigationStore.outboxMessages` via GRDB `ValueObservation`. `OutboxView` with retry (swipe left, only for failed) and discard (swipe right + confirmation, hidden for sending). Sidebar shows "Outbox" in unified section + per-account sections with count badge (red if failures)
- v3 migration adds the table; v4 adds `sentAt` column; v18 adds `sentMessageId` + `appendedToSent` columns. FK on accountId→account with CASCADE
- **Core philosophy**: never drop a message, never `try?` on state transitions, `sentAt` before delete, prefer double-send over drop, no auto-discard ever. See CLAUDE.md "Outbox Reliability Rules"

---

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
- **Deep link**: `.proactiveNotificationTapped` posted on tap — observer not yet wired (follow-up task)
- **Debug**: `#if DEBUG` test notification button in settings (fires in 5s)

---

### App Icon Badge Routine (NSE counter + main-app recount)

- **Two mechanisms**: (1) NSE best-effort incremental counter in App Group key `nse.unreadBadge` (`NSEBadge.badgeCountKey`), attached as an *absolute* value via `c.badge` on each delivered push; (2) main app's `UnreadCountManager.updateBadge()` — authoritative `SUM(folder.unreadCount) WHERE role=inbox`, calls `setBadgeCount` and **overwrites the mirror**. The counter only has to stay reasonable between main-app wakes; every recount self-heals drift.
- **All per-delivery badge values MUST go through `NSEBadge.badgeForDelivery`** (`Shared/Persistence/NSEBadge.swift`, compiled into app + NSE) — never raw increments. Two gates (fix for the 2026-06 double-increment bug):
  - **Gate 1 (duplicate pushes)**: per-`(accountId, messageId)` idempotency arbitrated by atomic `INSERT OR IGNORE` into `nse_badge_counted` in the shared staging DB. Deliberately a separate table (NOT a column on `nse_processed_message` — those rows get `INSERT OR REPLACE`d by re-runs and deleted by the merge). Created lazily by `NSEBadge`; 7-day retention pruned opportunistically.
  - **Gate 2 (main-app overlap)**: when the main app holds a *fresh* `AIOwnershipLease` on the message, the NSE delivers the current counter without bumping — the awake main app sets the badge authoritatively. Residual window (main app finished + slept before the push arrives) is accepted; wake-time recount heals it.
- `NSEState.incrementBadgeCount`/`decrementBadgeCount` remain ONLY for the legacy Gmail history.list delta-adjust path (label flips on existing messages — disjoint from delivered-message counting).
- **Foreground is safe by construction**: `NotificationDelegate.willPresent` returns `[]` for email pushes (badge never applied) and triggers merge + sync recount.
- Push-worker sets **no `apns-collapse-id`** — a true APNs duplicate shows two banners; badge dedup is entirely client-side via Gate 1.
- Tests: `TabMailTests/NSE/NSEBadgeTests.swift`.

---

---

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

## Banner Flash Prevention (MailNavigationView)

Two notification banners (Subscription / NSE consent) must stay hidden on boot until their backing state is confirmed — otherwise default-closed state flashes a false-positive banner before async checks complete. **Pattern:** use a `hasCheckedOnce`-style gate (persisted for subscription, per-process for consent) and only render the banner once an authoritative response is in.

- **Subscription banner** — `AISubscriptionGate` hydrates `isActive` + `hasCheckedOnce` from UserDefaults (keys `ai_subscription_last_known_active` / `ai_subscription_has_checked_once`). Both are stamped on every `openGate`/`closeGate`. MailNavigationView mirrors `hasCheckedOnce` via `@State` + `.onChange`. Banner condition: `!hasTabMailSession || (hasCheckedSubscription && !hasActiveSubscription)`. First-ever launch: banner hidden until whoami responds. Returning user: last-known state surfaces immediately (no flash).
- **NSE consent banner** — `PushNotificationService.checkPushConsentStatusForForeground` (renamed from `checkGmailConsentStatusForForeground` since the scan covers Gmail + Outlook) tracks `hasSucceededConsentScanOnce` (per-process). On first scan, thrown errors → `nil` (unknown, not broken) — cold-launch timeouts no longer populate the banner. Sticky-on-error resumes only after the first authoritative probe. Per-account timeout raised from 3s → `PushConfig.consentStatusCheckTimeoutSeconds = 10s` since cold-launch RTT regularly exceeded 3s. If zero probes are authoritative, the notification post is suppressed entirely (banner state untouched). View gate: `hasCompletedFirstConsentScan` flips true only when a definite post arrives or when `PendingConsentErrorStore.consume()` returns cold-start tap data. **Offline gates (two layers):** (1) `checkPushConsentStatusForForeground` returns early when `NetworkMonitor.checkConnected() == false` — every probe would throw while offline, which either leaves the banner empty (pre-priming) or pins a stale banner (post-priming) that misattributes "no internet" as "consent broken". (2) `MailNavigationView` banner render gates on `NetworkMonitor.shared.isConnected` too, so a banner raised while online disappears when connectivity drops (the tap launches OAuth which can't complete offline — showing the CTA is misleading). Next foreground / reconnect re-runs the scan and the `@Observable` `isConnected` re-renders the view.
- **Naming rule**: the push-consent route is provider-agnostic. State/notification names covering both Gmail + Outlook use `push` prefix (`pushConsentErrorsDetected`, `pushConsentErrorEmails`, `isFixingPushConsent`, `checkPushConsentStatusForForeground`). Per-provider flows keep `gmail`/`outlook` prefix (e.g., `.gmailPushConsentExplainerNeeded` + `.outlookPushConsentExplainerNeeded`, `GmailPushConsentExplainerAlert`).
- **Non-blocking**: all 5 callers of `checkPushConsentStatusForForeground` wrap in `.task` / `Task {}`. Never awaited inline with sync work.

---

## Test Isolation for `UserDefaults`-Backed State

`UserDefaults.standard` is a process-wide singleton. Using it directly in tests creates cross-suite races — Swift Testing runs different `@Suite`s in parallel, and even `.serialized` only orders tests *within* one suite. The pattern adopted for `DisabledRemindersStore` + `ReminderBuilder.autoDisableOverdueOnFirstLaunch`:

- Production code reads from an overridable static: `DisabledRemindersStore.defaults` (falls back to `.standard`). A `Mutex<DefaultsRef?>` (with a `@unchecked Sendable` class wrapper around the thread-safe `UserDefaults`) holds the override so it's Swift 6-safe.
- `DisabledRemindersStore._setTestDefaults(_:)` swaps in a per-test `UserDefaults(suiteName: UUID().uuidString)`.
- Entry points that read *ambient* keys on their own (`firstLaunchDate`, `didAutoDisableOverdueReminders`) take `defaults: UserDefaults = .standard` as a default parameter so tests can pass the isolated instance through.
- Tests wrap the body in a `withIsolatedDefaults { defaults in ... }` helper that sets up, runs, and tears down (including `removePersistentDomain`) the per-test `UserDefaults`. This lets the suite drop `.serialized` entirely — tests run in parallel.

Apply this same pattern to any future `UserDefaults`-backed service before introducing tests for it.

---

## Delivered-Notification Cleanup

`NotificationCleanupService` (`Shared/Notifications/`) sweeps stale delivered notifications. Wired at four entry points: NSE `didReceive`, silent-push `application(_:didReceiveRemoteNotification:)`, BGAppRefresh `SyncScheduler.handleBackgroundSync`, and app foreground (`scenePhase == .active` in `TabMailApp`). Policy:

- **Active** (interruption-level `.active`) — TTL 24h. Survives FG.
- **Passive** (interruption-level `.passive`) — TTL 24h, OR all cleared on FG.
- **`consent_error`** — never auto-cleared. Re-auth is user-actionable; user must tap or dismiss.
- **`imap_reconnect`** failure / in-progress — kept until `PushHealthStore.lastNonReconnectPushAt[accountEmail]` is newer than the notification's delivery date (push proven restored, per-account). Two stamping sources: (a) **strong** — NSE + silent-push handlers stamp on receipt of any non-error push (`provider not in {imap_reconnect, consent_error}`); (b) **weaker** — NSE stamps on successful silent re-subscribe (2xx from `/subscribe-imap` inside `attemptSilentResubscribe`). The weaker proof means: push-worker accepted the enrollment, but the IDLE socket may still drop afterwards — push-worker's retry ladder is the safety net.
- **`imap_reconnect`** success-ack ("Restored push notification connection") — distinguished by NSE-stamped `userInfo["reconnect_state"] = "ok"` at `NotificationService.swift:631-641`. Treated as normal active (1h TTL).

`PushHealthStore` lives in shared App Group UserDefaults (`group.ai.tabmail`, same suite as `AIService.optOutStore`) so NSE + main app share the timestamp map.

The bucketing logic is the pure function `NotificationCleanupService.identifiersToRemove(_:now:passiveAllAges:lastNonReconnectPushAt:)` — fully covered by `TabMailTests/Notifications/NotificationCleanupServiceTests.swift` (20 tests, 100% on `identifiersToRemove` + `shouldExclude`). Side-effect wrappers (`sweep`, `snapshot(from:)`, `PushHealthStore`) are validated manually.

### State-based clear: `InboxNotificationObserver`

Complementary axis: when a row leaves the inbox (`isInInbox` flips `true → false`, OR a previously-inbox row is deleted), `InboxNotificationObserver` clears `email-{accountId}-{messageId}` immediately — no waiting on TTL. Covers BOTH local actions (`AccountManagerActions.move`/`archive`/`delete` via `optimisticMoveToFolder`) AND remote sync paths (`SyncEngineDeltaSync`, `SyncEngineMaintenance`, `SyncEngineSelfHeal`, full sync) without per-site discipline — single GRDB `TransactionObserver` on `messageHeader`.

Performance: per-commit cost is one rowid B-tree `SELECT … WHERE rowid IN (touched rowids)` (sub-millisecond, scoped to the write batch). Startup populate via `WHERE isInInbox = 1` once during `AppDatabase.init`, served by index `messageHeader_isInInbox_date`. Callbacks fire on the GRDB writer queue (background, never main); in-memory `[rowid: (acct, mid)]` map is touched only by callbacks → no Mutex needed.

GRDB holds observers **weakly** at `.observerLifetime` — `AppDatabase.inboxNotificationObserver` provides the strong ref. Tests bypassing `AppDatabase` MUST capture the observer too (see helper in `InboxNotificationObserverTests`).

`clear` is invoked synchronously on the writer queue (`UNUserNotificationCenter.removeDeliveredNotifications` is non-blocking IPC). Contract: clients injecting `clear` MUST NOT re-enter GRDB writes.

---

## Startup Data Migrations (`StartupMigrations.swift`)

NOT GRDB schema migrations (those are in `AppDatabase.runMigrations`, the `DatabaseMigrator` v1…vN). `StartupMigrations.run(_ writer:resetFTS:)` is a separate set of **one-time destructive cached-mail resets**, each gated by its own `UserDefaults` bool (`didMigrateHeaderIds_v2`, `didClearBodiesForAttachmentEncoding_v1`, `didResetImapDatesForInternalDate_v1`, `didCleanResetMessageData_v1`). They `DELETE FROM messageHeader/messageBody` + reset backfill cursors + (clean reset) delete the FTS dir, to recover from cache-format changes across app upgrades; safe for real accounts because the server re-syncs. Kept `UserDefaults`-gated (not folded into the GRDB migrator) specifically so existing users who already ran them aren't re-wiped.

- **Where called (2026-06-04):** **synchronously in `AppDatabase.init()`**, right after `runMigrations` and BEFORE the pool is exposed (`AppDatabase.shared` set in `TabMailApp.init`) or the inbox observer is wired. So: DB opens → schema migrates → data resets → only THEN can sync / NSE merge / demo+screenshot seed touch the DB. **NOT** run in the test `init(dbPool:)` (would hit global flags + the real FTS dir). The only production caller of `AppDatabase()` is `TabMailApp.swift`.
- **No async gate anymore:** because nothing can race the resets, the old `SyncScheduler.migrationsComplete` / `awaitMigrations()` / `signalMigrationsComplete()` latch and RootView's `async let migrations` were **deleted**. `DemoModeService.completeSetup` no longer runs migrations either.
- **FTS reset = delete the dir.** At DB-open SearchIndex hasn't initialized (no open pool), so the clean reset just `removeItem`s `Application Support/tabmail_fts`; `SearchIndex.initialize()` recreates it fresh. `resetFTS` is injected into `run(...)` so tests don't touch the real FS; it's invoked in lockstep with the main-DB deletes so the flag is set only once both halves are done (crash → re-run next launch).
- **Cost note:** the first launch after a new reset is introduced runs its DELETE synchronously at launch (blocks first frame briefly, one-time). Correctness (don't show-then-wipe) was chosen over that one-time delay.

---

## Knowledge Gaps

(none currently)
