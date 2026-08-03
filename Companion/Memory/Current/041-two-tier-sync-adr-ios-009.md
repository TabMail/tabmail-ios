
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
