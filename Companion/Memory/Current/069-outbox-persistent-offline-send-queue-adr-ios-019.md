<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** The preserved final reference to the old `CLAUDE.md` heading now routes to `Companion/Rules/Active/outbox-reliability.md`.
<!-- COMPANION-CURRENT-NOTE-END -->

### Outbox — Persistent Offline Send Queue (ADR-IOS-019)
- `OutboxMessage` GRDB model in `outboxMessage` table — stores full draft (to/cc/bcc/subject/body/isHTML/inReplyTo/references/threadId) with status (queued/sending/failed) and `sentAt` timestamp
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
