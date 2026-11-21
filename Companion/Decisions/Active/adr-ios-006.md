
## ADR-IOS-006: Storage-Budget Retention with Progressive Crawling

> **Current note (2026-11-21, #1062): what was pruned is recorded, not inferred.** The lowest held UID
> is no evidence of what was pruned: an infinite-scroll page caches rows below the pruned UIDs, and a
> window UID whose header could not be read sits below the first local one. The IMAP prune now records
> the highest UID it deleted, with the folder's UIDVALIDITY (`CatchUpPruneCutoff`, `pruneCutoff` in
> the folder's `catchUpState` JSON, no migration), in its own write transaction, only for a UID prune
> order and only from rows that transaction deleted and that carried the folder's epoch; under a limit
> the catch-up loads nothing at or below it (ADR-IOS-107, *Storage limit, prune cutoff*). A folder
> pruned by a released version (no cutoff) gets ONE cutoff from the catch-up under a limit: the lower
> of its first local UID and its window floor, minus one. *Superseded in place:* in the note below,
> "its lowest held UID is a clean floor, and the IMAP catch-up loads only above the higher of it and
> the walk's start" and "the catch-up downloads them once (they sit above the lowest held UID)": a
> released store's date-holes above the seeded cutoff are downloaded once, as before; holes below it
> are not.
>
> **Current note (2026-11-20, #1062).** The prune deletes each folder oldest-first in that folder's
> SYNC ORDER, the fetch's ordering dimension (ADR-IOS-042): an IMAP folder loses its LOWEST UIDs
> first (`CAST(messageId AS INTEGER)`, the form `SyncEngine.selectStaleHeaders` uses); a Gmail or
> Exchange folder its oldest DATES first, as before. Bodies and headers are pruned in the same order.
> The order comes from each account's `EmailProvider.staleWindowMode`, resolved by the caller
> (`SyncEngine.pruneOrderByAccount`) and passed to `SyncEngine.runPruneIfOverBudget`; an account with
> no registered provider (it failed to register) is still pruned, oldest date first as before #1062. So an IMAP folder under a limit holds one
> contiguous top range of UIDs, its lowest held UID is a clean floor, and the IMAP catch-up loads
> only above the higher of it and the walk's start (ADR-IOS-107, #1062), so rows infinite scroll
> cached below the walk's cursor never pull the floor down; the catch-up insert's date skip is gone.
> **Trade-off (Archive):** an IMAP Archive keeps its most recently ARCHIVED mail (highest UIDs), not
> its newest-DATED mail: an old message archived today is kept, a recent one archived long ago may be
> pruned. **No migration and no cleanup:** a store already pruned by date keeps its date-holes; the
> catch-up downloads them once (they sit above the lowest held UID), and later prunes, now by UID,
> settle the store into one contiguous top range. *Superseded:* decision 2's "oldest messages are
> pruned" meant oldest by date for every provider; on IMAP that left pruned holes throughout the UID
> range that every catch-up listing downloaded again.
> **Gmail and Exchange under a limit (accepted):** their catch-up stops at the folder's oldest local
> row by `providerDate`, while the prune orders by `date`, so a loaded message older by `date` than the
> folder's oldest kept row can be inserted and pruned again at the next pass. Rare (those providers
> list again only after a lapse) and harmless: it costs one download, never a kept message.
>
> **Current note (2026-11-12).** While a storage limit is in force, a Gmail catch-up listing goes no
> lower than a folder's oldest local row, so the catch-up's direct load brings no pruned old mail
> back; the re-arm (and its decline) is gone (ADR-IOS-107 decision 8, "the direct load"). The
> 2026-11-11 note below is superseded and kept as written.
>
> **Current note (2026-11-11).** While a storage limit is in force (`StorageEstimator.budgetMB` finite;
> the code's default is `Int.max`, unlimited), the full sync's catch-up re-arms no backfill walk and
> lists no Gmail mail older than a folder's oldest local row, so mail the prune deleted is not loaded
> back every week. Trade-off: old mail moved into a folder under a limit is not loaded. ADR-IOS-107
> decision 8, "No old mail is loaded back under a storage limit". The text below is kept as written.

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
