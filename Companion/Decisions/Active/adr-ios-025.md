
## ADR-IOS-025: Backfill Crawl Progress Must Not Use Date-Based Anchors From Unrelated Queries

**Context:** In Feb 2026, we discovered that `fullSync` anchored `oldestSyncedDate` to `min(date)` across ALL messages in a folder, not just the sync batch. After a Smart Reindex (which resets `oldestSyncedDate` to nil), the next `fullSync` would re-anchor to the oldest message in the folder (potentially years old), causing backfill to start from that ancient date instead of from today. This created a massive unscanned gap between the latest-50 sync window and where backfill resumed.

**Root cause bugs found (all fixed):**
1. `fullSync` anchor used `min(date)` across entire folder — fixed to use the Nth most recent message
2. Deep backfill missing 1-day overlap for IMAP date boundary messages — fixed
3. Deep backfill terminated on `insertedCount == 0` instead of `found == 0` — fixed
4. Shallow backfill `<=` instead of `<` at age cutoff boundary — lost messages on exact cutoff date — fixed
5. `fetchOlderMessages` used `Calendar.current` instead of UTC — timezone-dependent gaps — fixed
6. `todayMidnight` used hardcoded `86400` seconds instead of Calendar API — fixed

**Decision:**
- **NEVER derive crawl progress pointers from aggregate queries over the full message store.** The anchor must reflect only the current operation's scope (e.g., the oldest date from the just-synced batch, or the window boundary that backfill just completed).
- **Date-based crawling is inherently fragile** — IMAP SINCE/BEFORE uses date-only granularity (no time component), sender dates can be wrong (clock skew), and midnight-aligned UTC windows can miss messages at boundaries. We mitigate with 1-day overlap between windows and self-healing (UID comparison), but this remains a known weakness.
- **UID-based tracking is not a complete solution either** — UIDs are folder-specific, can change on UIDVALIDITY change (mailbox compaction), and are not available for Gmail/Exchange. UIDs are used for gap detection (self-heal) but not as the primary crawl pointer.
- **Self-healing mechanism** (`SyncEngineSelfHeal.swift`) runs after full sync (rate-limited hourly) and on-demand folder refresh, comparing IMAP UIDs against GRDB and fetching any missing messages. This is the safety net for any crawl logic bugs.

**Additional bugs found and fixed (same investigation):**
7. **Duplicate backfill workers** — when `resetCrawlState()` cancels old tasks, the old task's `defer { headerBackfillTasks[accountId] = nil }` could fire AFTER a replacement task was placed in the dictionary, overwriting it. Next sync poll would see nil and spawn a duplicate. Fixed: defer only clears on non-cancelled exit.
8. **FTS body fetch — missing UIDs get retry** — `fetchTextBodiesParallel` silently drops UIDs for some messages (e.g., Deleted Messages, attachment-only). Added one-retry for transient drops. Permanently missing UIDs are NOT marked as fetched (headers exist = messages are real). The existing `ftsStalled`/`ftsSkipOffset` mechanism handles these without data loss.

**Consequences:**
- Smart Reindex now works correctly — backfill starts from just below the sync window and crawls the full history
- Self-heal catches any remaining gaps within the 90-day window
- No more duplicate workers racing on the same account
- FTS body retry catches transient IMAP FETCH drops; permanently missing UIDs handled by ftsStalled mechanism
- The fundamental tension between date-based and UID-based progress tracking remains unresolved — both have failure modes

---
