<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** Post-compaction amendment; this current rule extends the frozen numbered list below.

11. **Provider loss after claim** — If the runtime provider disappears after the exact row is claimed but before provider I/O starts, return only that row from `sending` to `queued`, fenced by exact id, `status == sending`, and `sentAt IS NULL`, and require exactly one changed row. Never broaden or apply this rollback after provider I/O.
<!-- COMPANION-CURRENT-NOTE-END -->
## Outbox Reliability Rules

**A dropped send or double-send is a product-ending bug. These rules are non-negotiable.**

1. **Never drop a message** — `queueSend()` throws. The caller (ComposeView) MUST show the error and NOT dismiss. The compose view is the user's last chance.
2. **Never `try?` on outbox state transitions** — Every DB write that changes status (queued→sending, sending→failed, success→delete) uses `do/catch` with 3 retries. Silent swallowing = message loss or double-send.
3. **`sentAt` before delete** — After `provider.send()` succeeds, stamp `sentAt` FIRST, then delete. Crash between send and delete? `reconcileOutbox` sees `sentAt != nil` → deletes (not re-queues). This is the double-send firewall.
4. **Prefer double-send over drop** — Two-generals problem is inherent. When in doubt, re-queue and retry. Duplicate email >> lost email.
5. **No silent data corruption** — `loadAttachments()` throws if ANY file is unreadable. Never send an email with missing attachments. Mark as failed instead.
6. **File I/O outside DB transactions** — Attachment disk ops outside `dbPool.write`. File failure inside a transaction rolls back the DB too.
7. **No auto-discard, ever** — Outbox messages are NEVER automatically deleted. Failed messages stay visible. User always has agency.
8. **Only drain `.queued`** — `.failed` messages require explicit user Retry. Prevents infinite retry loops and spam.
9. **Auto-retry then escalate** — retryCount < 3 keeps as `queued` (auto-retry). retryCount >= 3 marks `failed` (user action). Manual Retry resets retryCount to 0.
10. **Discard guard** — Cannot discard a `sending` message. The email may have already left the server.

See `Companion/Decisions/Active/adr-ios-019.md` for the full **ADR-IOS-019** architectural context.

---
