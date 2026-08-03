
## ADR-IOS-006: Storage-Budget Retention with Progressive Crawling

**Context:** ADR-IOS-005 used age-based message eviction — messages older than `maxSyncAgeDays` were actively deleted during sync. This caused emails to disappear after being fetched, wasting bandwidth and confusing users. Users expect their mail client to keep downloaded messages, similar to Apple Mail which stores ~2GB of data.

**Decision:**
1. **No age-based eviction** — Once a message is fetched, it stays in local storage. Storage budget is the only limiting factor.
2. **Global storage budget** — `StorageEstimator.budgetMB` (UserDefaults, default 2048 = 2GB) is a global soft cap across all accounts. When exceeded, oldest messages are pruned across all accounts — bodies first (re-fetchable), then headers. Always keeps minimum 50 messages per folder.
3. **Complete backfill** — Backfill walks to completion (UID 1 for IMAP, last page for Gmail/Exchange). Storage budget gates whether backfill proceeds, but never prematurely marks folders as complete.
4. **Actual file size measurement** — `StorageEstimator` measures actual disk usage of GRDB database (`tabmail.sqlite` + WAL/SHM) and FTS files (`fts.db` + WAL/SHM) via recursive directory enumeration. No formula estimation.
5. **Infinite scroll** — When users scroll to the bottom of a mailbox, older messages are fetched on-demand via `fetchOlderMessages` regardless of age settings.
6. **50-message floor per folder** — Every folder always syncs at least 50 recent messages, regardless of age settings or storage budget.
7. **No body duplication** — `MessageBody` stores only `htmlContent` (plain-text-only emails are wrapped in HTML on ingest). FTS stores stripped plain text for search. No `textContent` field.

**Rationale:**
- Users don't expect fetched emails to disappear
- Apple Mail stores ~2GB — users accept this storage usage
- Progressive crawling fills storage naturally without aggressive initial downloads
- Actual file measurement is fast (3 `attributesOfItem` calls) and accurate
- Global budget is simpler UX (one setting in app settings) and matches single-file SQLite reality
- Eliminating `textContent` removes body duplication between main database and FTS
- Infinite scroll makes any historical email accessible without configuration

**Consequences:**
- Storage UI in SettingsView (global) shows actual usage and limit picker
- Pruning works globally across all accounts, oldest messages first
- Deep backfill increases IMAP/API traffic but runs at low priority with throttling

---
