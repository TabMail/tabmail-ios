
## ADR-IOS-005: Progressive Background Backfill

**Context:** Initial sync fetches only the latest N messages (50 inbox, 25 others) with a hardcoded 30-day age limit. Users with months of email history see a sparse mailbox. Opening a non-synced email could silently fail if the provider was disconnected.

**Decision:**
1. **Full sync depth** — Backfill always walks to completion: IMAP walks from UIDNEXT-1 to UID 1, Gmail/Exchange exhausts all pages. No date-based age cutoff — storage budget is the only gate.
2. **Progressive backfill** — After each initial sync, a background task fetches older messages. Uses IMAP UID range walking or Gmail `nextPageToken` pagination. Follows the same cooperative cancellation pattern as snippet fetching (ADR-IOS-002).
3. **Prioritized sync order** — Inbox first, then favorites, then secondary roles (sent/drafts/trash/archive/spam).
4. **No silent failures** — `fetchBody` throws descriptive errors instead of silently returning when provider/account is missing. Attempts reconnection if provider is nil.

**Rationale:**
- Users expect to see their full mailbox history, not just the latest 50
- Background backfill avoids blocking the initial sync/UI
- Cancellable backfill ensures user actions (opening messages) take priority
- Pure UID walk (no date-based cutoff) guarantees no messages are arbitrarily skipped — IMAP UIDs and message dates are not monotonically correlated

**Consequences:**
- Additional IMAP/API traffic after each sync cycle (one-time per folder until `backfillComplete`)
- `Folder.backfillComplete` and `Folder.oldestSyncedDate` track per-folder progress
- Backfill is cancelled alongside snippets before user-initiated provider calls

---
