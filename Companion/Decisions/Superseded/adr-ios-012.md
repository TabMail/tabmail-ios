
## ADR-IOS-012: ~~Inbox Excluded from Stale Detection~~ (SUPERSEDED)

**Status:** Superseded — inbox stale detection is now enabled for all folders.

**Original context:** Concern that UIDVALIDITY changes could cause mass false-positive staleness, wiping AI state.

**Why superseded:** `MessageAICache` already preserves AI state (summary, action) for re-inserted messages via `restoreIfCached()`. The overlap-window approach limits stale detection to the date range covered by fetched messages, preventing mass deletion. Without inbox stale detection, messages moved out of inbox on the server persisted locally indefinitely — IMAP delta sync detected the change but never cleaned up the stale local copies.

**Current behavior:** All folders including inbox use the same stale detection logic (overlap-window when fetched count >= limit, full comparison otherwise).

---
