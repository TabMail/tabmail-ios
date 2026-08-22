<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** Issue #76 deleted the unused void `discardOutboxMessage` wrapper. The live mutating surface is `discardOutboxMessageConfirmed`, whose committed deletion still triggers `drainOutbox`; read Decision item 4's preserved historical symbol name through that amendment.
<!-- COMPANION-CURRENT-NOTE-END -->

## ADR-IOS-019: Outbox — Persistent Offline Send Queue

**Context:** Email sending was synchronous — `AccountManager.send()` directly called `provider.send(draft:)`. If offline, the send failed with an error and the user's composed message was lost. This was inconsistent with ADR-IOS-018 (all actions go through a persistent queue) and ADR-IOS-001 (optimistic UI). Users expected to compose and "send" even without connectivity.

**Decision:**
1. **OutboxMessage GRDB model** — `outboxMessage` table persists the full draft (recipients, subject, body, isHTML, inReplyTo, references) with status (queued/sending/failed) and `sentAt` timestamp. Attachments stored on disk under `Application Support/TabMail/outbox_attachments/{id}/` (not in DB — avoids blob bloat). v3 migration adds the table, v4 adds `sentAt`.
2. **Always queue, never direct send** — `ComposeView.send()` calls `AccountManager.queueSend()` which persists to GRDB + disk, then fires `drainOutbox()` async. ComposeView dismisses only on success. If persistence fails, error is shown and compose stays open.
3. **drainOutbox() pattern** — Mirrors `drainPendingQueue()`: isDrainingOutbox guard, NetworkMonitor gate, FIFO by createdAt, marks `sending` before attempt. Messages are sent in parallel — each gets its own Task, with provider-level concurrency managed by PriorityWorkQueue. A failure for one account does not block other accounts or messages. Only processes `.queued` messages — `.failed` requires explicit user Retry. Max 3 passes.
4. **Drain triggers** — NetworkMonitor reconnect, app launch (reconcileOutbox), after queueSend, after discardOutboxMessage (so remaining queued messages proceed immediately), SyncScheduler foreground polling + after each poll.
5. **Post-send: Sent folder append** — After `provider.send()` succeeds: (1) stamp `sentAt` timestamp, (2) attempt IMAP APPEND to Sent folder with dedup check, (3) on success: delete from DB + update isReplied/isForwarded + delete attachments. Gmail/Exchange auto-save to Sent — their `appendToSentFolder` is a no-op. IMAP requires explicit APPEND because SMTP only delivers; it does NOT store a copy on the sender's server.
6. **Message-ID pre-generation** — Before SMTP send, a stable RFC822 Message-ID is generated and persisted to `outboxMessage.sentMessageId`. Both SMTP send and IMAP APPEND use this same ID (via `DraftMessage.messageId` → `Email.additionalHeaders["Message-Id"]`). On retry, the Sent folder is searched by `HEADER Message-ID <id>` to prevent duplicate appends.
7. **Persistent Sent append** — If the IMAP APPEND fails (connection drop, app kill), the outbox message stays with `sentAt != nil` and `appendedToSent == false`. `drainPendingSentAppends()` retries on next drain cycle. The message is only finalized (deleted + flags updated) when BOTH send and append succeed. v18 migration adds `sentMessageId` and `appendedToSent` columns.
8. **Crash recovery (reconcileOutbox)** — On launch: messages with `sentAt != nil` AND `appendedToSent == true` → delete (fully completed). Messages with `sentAt != nil` AND `appendedToSent == false` → keep for append retry (already sent, don't re-send). Messages with `sentAt == nil` and status `sending` → reset to `queued` (retry). Also cleans orphaned attachment dirs.
9. **Auto-retry + escalation** — Transient failures (retryCount < 3) keep status as `queued` for automatic retry on next drain. Persistent failures (retryCount >= 3) mark as `failed` — user must tap Retry (which resets retryCount to 0 for a fresh set of attempts).
8. **User actions** — Retry: resets failed→queued + retryCount→0, triggers drain. Discard: atomic fetch+delete in single write transaction, refused if status==sending.
9. **Reactive UI** — `NavigationStore` observes `outboxMessage` table via GRDB `ValueObservation`. Sidebar shows "Outbox" in unified section + per-account sections, with count badge (red if failures). `OutboxView` hides discard button for sending messages.

**Core reliability philosophy — a dropped send or double-send is near end-of-product:**

- **Never drop a message.** `queueSend` throws on failure. ComposeView MUST show the error and NOT dismiss. The compose view is the user's last chance to preserve their message.
- **Never `try?` on state transitions.** Every DB write that changes outbox status (queued→sending, sending→failed, success→delete) MUST use `do/catch` with retries (3 attempts, 100ms backoff). A silently swallowed failure leads to message loss or double-send via crash recovery.
- **`sentAt` before delete.** After successful send, stamp `sentAt` BEFORE attempting the delete. If the app crashes between send-success and delete, `reconcileOutbox` sees `sentAt != nil` → deletes (not re-queues). Without this marker, the message would be re-sent.
- **Prefer double-send over drop.** The two-generals problem is inherent. When in doubt (crash mid-send, no sentAt), we re-queue and retry. A rare duplicate email is vastly preferable to a silently lost message.
- **No silent data corruption.** `loadAttachments()` throws if ANY file can't be read. Never send an email with missing attachments — mark as failed with a clear error instead.
- **File I/O outside DB transactions.** Attachment disk operations (delete, cleanup) MUST happen outside write transactions. File I/O failure inside a transaction rolls back the DB changes.
- **No auto-discard, ever.** Outbox messages are NEVER automatically deleted. Failed messages stay visible until the user explicitly discards. The user always has agency.

**Rationale:** Matches the established pattern from ADR-IOS-018. Users expect "send" to succeed instantly regardless of connectivity. The outbox completes the "every user change is recorded and executed upon connection" guarantee. Attachments on disk avoid GRDB row size bloat. The reliability philosophy reflects that email sending is the single highest-stakes operation — a lost email can mean lost business, lost relationships, lost trust.

**Consequences:**
- Sends never fail from the user's perspective — worst case, they execute on next reconnect
- ComposeView only dismisses after successful persistence — never before
- Failed sends stay visible in Outbox UI with error + retry/discard options
- Auto-retry handles transient errors (3 attempts) before bothering the user
- `sentAt` marker closes the main double-send crash window (irreducible ~microsecond gap remains between provider.send() and sentAt write — inherent two-generals problem)
- Orphaned attachment dirs cleaned on every app launch
- Account deletion cascades via FK — attachment dirs cleaned before cascade

---
