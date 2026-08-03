<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current routing note:** **Superseded on v3.** Durable operations key by the native provider id: IMAP `(UIDVALIDITY, UID)`, Gmail/Graph `message.id`. RFC 822 Message-ID is never mutation authority on this branch. Preserved as evidence for the identity history; do not implement from it. (Routing notes are ASCII-only: the wrapper is prepended to a byte-preserved fragment.)
<!-- COMPANION-CURRENT-NOTE-END -->

## ADR-IOS-026: PendingOperation Uses Stable IDs (rfc822MessageId)

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
