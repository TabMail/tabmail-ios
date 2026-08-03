
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
