
## ADR-IOS-009: Two-Tier Delta + Full Sync

**Context:** Sync ran a full sync every 60 seconds — fetching all messages, diffing against local state, updating folders. This was slow and wasteful, especially for accounts with many folders. Gmail's `history.list` API was previously tried but abandoned because the `historyId` cursor expires after ~7 days. IMAP had no incremental sync at all.

**Decision:**
1. **Delta sync (frequent, every 60s)** — Lightweight check for changes since last sync. Gmail uses `history.list` with `lastHistoryId` cursor. IMAP uses `STATUS` command per folder to compare `uidNext` and `messageCount` against cached values.
2. **Full sync (periodic, every 10 min)** — Safety net and self-healing. Runs the existing `fullSync()` with complete message diffing. Also captures fresh sync cursors (Gmail historyId, IMAP uidNext per folder).
3. **Graceful fallback** — If delta sync fails for any reason (Gmail 404 expired cursor, IMAP errors, missing cursors), falls through to full sync automatically. The expired historyId is cleared so the next full sync captures a fresh one.
4. **Cursor management** — Gmail: `Account.lastHistoryId` captured after full sync via `getCurrentHistoryId()`. IMAP: `Folder.lastKnownUidNext` captured from `FolderInfo.uidNext` during full sync.

**Rationale:**
- Full sync every 60s is unnecessarily expensive — most polls find zero changes
- Gmail history expiry (~7 days) isn't catastrophic if handled as a fallback trigger
- IMAP `STATUS` is cheap (no `SELECT` needed) and reliably detects new/deleted messages
- Two-tier approach gives fast responsiveness (delta) with guaranteed consistency (periodic full)
- Background tasks (snippets, backfill, AI) only run after full syncs — delta is fast-path only

**Consequences:**
- Delta sync skips background work (snippets, backfill, AI processing) — these run after full syncs
- Gmail delta sync processes message adds/deletes/label changes individually (more API calls per changed message, but rare)
- IMAP delta still runs `syncMessages()` for changed folders — STATUS only detects change, not what changed
- New model fields: `Account.lastFullSyncAt`, `Folder.lastKnownUidNext`, `FolderInfo.uidNext`
- `GmailProvider.fetchHistory` returns nil on 404 instead of throwing

---
