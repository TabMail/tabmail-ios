
## ADR-IOS-001: Optimistic UI with Hardened Sync

**Context:** Mobile apps operate in unreliable environments — connections drop, users close the app mid-operation, processes get killed by the OS. Email operations (archive, delete, move, sync) involve both local state and remote IMAP/provider state that must stay consistent.

**Decision:**
1. **Optimistic UI** — All user-initiated actions (archive, delete, move, mark read) update local database state (GRDB) and animate immediately using native iOS animations (swipe-to-zap). The user never waits for a server round-trip.
2. **Verified state persistence** — Backend state markers (history IDs, sync cursors, IMAP UIDs) are only persisted after verified completion of the remote operation. Never write state ahead of confirmation.
3. **Idempotent operations** — Every operation that touches remote state must be idempotent. Re-executing the same operation after a crash or disconnect must produce the same result without side effects.
4. **Self-healing on launch** — On app launch and sync resume, detect incomplete operations (local state says "archived" but IMAP move never completed) and either retry the remote operation or roll back local state.

**Rationale:**
- Users expect instant responsiveness — waiting for IMAP round-trips feels broken on mobile
- Connections are fundamentally unreliable on mobile (cellular handoffs, tunnels, airplane mode)
- The OS can kill the app at any time (memory pressure, user swipe-to-close)
- Pre-writing state markers before confirmation causes stale entries that corrupt future syncs
- Idempotency + self-healing means the app always converges to a correct state

**Consequences:**
- Every sync operation needs a "pending" → "confirmed" state machine
- Local database model needs fields to track operation completion status
- Launch/resume path must include an incomplete-operation scan
- Slightly more complex code, but dramatically more reliable UX
- No "ghost" messages that were deleted locally but never synced

---
