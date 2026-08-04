## ADR-IOS-026B: PendingOperation Uses Stable IDs (rfc822MessageId) — SUPERSEDED by ADR-IOS-068

> **SUPERSEDED 2026-08-02 by ADR-IOS-068.** Retained verbatim below as evidence and history; it is
> no longer implementation authority. This record was authored under the number `ADR-IOS-026`,
> colliding with *"Proactive Local Notifications"* above; it is referred to elsewhere in this repo
> and in the reference line as **ADR-IOS-026B**, and the heading now carries both so either search
> term finds it. **Only its durable-mutation-authority layer is superseded.** Every other RFC use
> it names — fetch, normalize, dedup, stage, the AI cross-device cache probe, threading/references,
> Outbox send de-duplication — SURVIVES; see ADR-IOS-068's exempt list, which is normative.

**Context:** PendingOperation.messageIds stored numeric IMAP UIDs. If the server changes UIDVALIDITY (mailbox compaction, migration, backup restore), all UIDs are reassigned. Queued operations would reference stale UIDs — either failing silently or targeting wrong messages.

**Decision:** PendingOperation.messageIds now stores `rfc822MessageId` (RFC 2822 Message-ID header) for IMAP messages instead of numeric UIDs. The `MessageHeader.stableId` computed property returns `rfc822MessageId` when the messageId is numeric (IMAP UID) and rfc822MessageId is available, otherwise returns messageId. Gmail/Exchange use non-numeric stable provider IDs, so `stableId` returns messageId unchanged for those.

**Implementation:**
- `MessageHeader.stableId` — computed property: if `UInt32(messageId) != nil` and `rfc822MessageId` is non-empty, returns `rfc822MessageId`; otherwise returns `messageId`
- All PendingOperation queue sites use `stableId` instead of `messageId`
- `queueTagWrite` accepts optional `rfc822MessageId` parameter for the same logic
- `IMAPProvider.resolveUID()` already handles non-numeric IDs via IMAP `SEARCH` by Message-ID header — no provider changes needed
- `SyncEngineFullSync` pending-op matching checks both `info.messageId` and `info.rfc822MessageId` against pending sets (dual-match)
- Undo cancellation matching also checks both numeric and stable IDs

**Rationale:** UIDVALIDITY changes are rare but catastrophic for queued operations. RFC 2822 Message-ID is immutable and server-independent. The undo path already used `rfc822MessageId` for IMAP move-back operations — this extends the same pattern to all operations.

**Consequences:**
- PendingOps for IMAP messages without rfc822MessageId still fall back to numeric UID (some drafts, system notifications)
- Drain-time UID resolution does an extra IMAP SEARCH for non-numeric IDs — negligible cost since pending ops are low-volume
- Dual-matching in sync adds minimal overhead (one extra set lookup per message)

---

---

