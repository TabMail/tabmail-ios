
## ADR-IOS-003: Pending Operation Queue for Crash Recovery

**Context:** ADR-IOS-001 requires self-healing on launch — detecting and retrying incomplete operations. Operations like archive, delete, and move modify both remote (IMAP/Gmail) and local (GRDB) state. If the app crashes between the remote operation succeeding and the local state update, the states drift permanently.

**Decision:**
1. **PendingOperation GRDB model** — Before any remote state-changing operation, insert a `PendingOperation` record. After success, delete it. Leftover records indicate operations that started but didn't complete.
2. **Launch reconciliation** — On app launch, before the first sync, query for `PendingOperation` records and retry them (up to 3 times). After max retries, discard the record.
3. **Optimistic UI with rollback** — `toggleRead` and `toggleFlag` update local state immediately. If the remote operation fails, the optimistic change is reverted and an error is shown. Archive/delete/move show errors but don't need rollback (local state only updates after remote success).

**Rationale:**
- Without a pending queue, crashed operations are invisible to the system
- Retry with a limit prevents infinite loops on permanently failing operations
- Optimistic UI rollback prevents local/remote state drift for flag operations

**Consequences:**
- Slight overhead per operation (two GRDB writes: insert + delete)

---
