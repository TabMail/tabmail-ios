
### Two-Tier Sync (ADR-IOS-009)
- **Delta sync** (every 60s): lightweight check for changes since last sync
  - Gmail: `history.list` API with `lastHistoryId` cursor → returns adds/deletes/label changes
  - IMAP: `STATUS` command per folder → compares `uidNext` + `messageCount` with cached values
- **Full sync** (every 10 min): safety net, self-healing — runs `fullSync()` as before
- Delta sync skips unchanged folders entirely (IMAP) or processes only affected messages (Gmail)
- If delta fails (e.g., Gmail 404 expired cursor), falls through to full sync automatically
- `Account.lastFullSyncAt` tracks when last full sync ran (delta syncs don't update it)
- `Folder.lastKnownUidNext` caches IMAP uidNext for change detection
- `GmailProvider.fetchMessageDetails(ids:)` returns headers + labelIds for folder assignment during delta sync
- `IMAPProvider.folderStatus(path:)` returns quick STATUS without SELECT
- **Gmail `history.list` is paginated, and every page is read before the cursor moves (tabmail-ios #429).** A page holds at most 500 records (default 100), and Gmail says "If you receive no `nextPageToken` in the response, there are no updates to retrieve". Until #429, `GmailAPI.historyList` read one page and the delta's cursor was that response's `historyId` (the mailbox's CURRENT id), so once more than one page of changes had built up (a bulk archive on the web, a long background gap), every later record was skipped for good and only the full sync's recent window healed it. `GmailAPI.historyList` now follows `nextPageToken` (`maxResults` = `GmailAPI.historyPageSize`, 500) and returns one delta for all pages, with the FIRST page's `historyId` as the cursor (a record newer than that is re-read next time, which delta sync treats as harmless). The loop is bounded by `GmailAPI.historyMaxPages` (40): longer history returns nil exactly like the 404 expiry, so `gmailDeltaSync` clears `lastHistoryId` and the next sync is a full sync (point 3 above); it never advances past unread pages and never throws (a throw would fail identically on every retry). The NSE shares `historyList`; on nil its own cursor stays where it was, the same as on a 404. Tests: `GmailHistoryPaginationTests` (end to end through `performDeltaSync`).
