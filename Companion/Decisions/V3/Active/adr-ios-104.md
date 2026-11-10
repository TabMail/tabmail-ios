## ADR-IOS-104: One Sync Pass at a Time per Account

**Status:** Active (2026-11-09; owner ruling, relayed by the coordinating session). Found while reviewing #427.

**Context:** a sync pass is `SyncEngine.sync(account:)` (the delta, then the full sync when it is due,
then its post-steps) or `SyncEngine.backgroundDeltaSync(account:)` (the delta alone, for push wakes and
background refresh). Neither had a per-account guard. `sync(account:)` said "ProviderWorkQueue handles
concurrency", but the work queue has several slots (Gmail and Exchange 10; IMAP as many as the pool),
so it serializes requests, not passes. `backgroundDeltaSync` said outright that background deltas "run
concurrently with foreground syncs", on the grounds that delta writes are idempotent and cursors only
grow. The foreground poll, launch, account setup, Settings and a push wake could therefore run one
pass's full sync while another pass's delta was in flight, and both write the account's delta cursor
(`Account.lastHistoryId`). The owner's model was always that this cannot happen.

**Decision:**
1. **One semaphore per account, first in first out** (`SyncEngine.oneSyncAtATime`). Both entry points
   run their whole pass inside it. A pass that arrives while another of the same account runs waits its
   turn and then runs; a caller's timeout includes the wait. The turn is released on every exit, a throw
   included, and handed straight to the oldest waiter, so a later arrival cannot overtake.
2. **A pass never acts on account sync state read before its turn** (owner, 2026-11-10, choosing the fix
   at the cause over blessing the gap). The pass's first step inside its turn re-reads the account row
   (`SyncEngine.accountAtTurnStart`), and the pass bodies (`foregroundPass`, `backgroundDeltaPass`) take
   only the account id, so no cursor path can reach the caller's copy. The delta cursor
   (`Account.lastHistoryId`), the full-sync-due decision (`lastFullSyncAt`) and the 15-second recent-sync
   check (`lastSyncedAt`) all come from that fresh row. So a pass that waited never clears or overwrites
   a cursor a pass ahead of it wrote, and two queued passes never both run a full sync only one was due
   for. Census at the ruling: every write of `lastHistoryId` runs inside a pass (the Gmail and Outlook
   delta's advance and clear, `captureSyncCursors`; the extension writes only its own mirror), so nothing
   moves the cursor while a pass holds the turn and no compare-and-set is needed. The writers of
   `lastFullSyncAt` outside a pass (`StartupMigrations`, the epoch rebuild, Settings' resync) only clear it
   to make a full sync due, which the fresh read honours when the clear lands before the pass's turn starts
   (`AppDatabase` also clears it at its release boundary, before any pass runs). A clear that lands while
   a foreground pass's full sync is in flight is stamped over by that pass's end write: a pre-existing
   race, tabmail-ios #572. This is live sync state, not a setting, so the
   snapshot-at-operation-start rule does not apply to it ("settings versus the world").
3. **Nothing else changes** (owner: "the full sync and delta sync work the same as right now ... If one
   is running, the other just waits. It's a simple semaphore. Do not change anything of the timing
   logic"). There is no joining, no coalescing and no new trigger. The 15-minute full-sync interval, the
   15-second recent-sync check (now on the fresh row, item 2), the delta-then-full-sync order inside a
   pass and every scheduler stay as they were.
4. **No time cap on the wait.** A waiter whose task was cancelled still takes its turn; its pass then
   stops at its first cancellation-aware step: the turn-start account read (GRDB's async reads throw
   `CancellationError` once the task is cancelled), or else its first work-queue call.
5. **Not inside it:** single-folder syncs (`SyncEngine.syncFolderMessages`: pull to refresh through
   `AccountManager.syncFolders`, message detail, the operation executor, the outbox, on-demand fetches,
   and the UIDVALIDITY reaction under its own per-folder single flight, ADR-IOS-061), backfill, FTS
   indexing and the AI queues. None of them runs a delta or a full sync, or writes the account's delta
   cursor (`Account.lastHistoryId`).

**Rejected:** joining a running pass or coalescing waiters into one trailing pass (the owner asked for a
plain semaphore, and both change what a caller's pass does); a wait cap that drops the waiter (a
skipped pass); relying on the work queue (it has several slots by design, for throughput).

**Consequence:** a push wake that arrives during a foreground full sync now waits for it, then runs its
delta from the cursor that full sync captured. A foreground pass that waited behind one that has just
synced skips (the 15-second check). The epoch rebuild's immediate resync, which clears `lastFullSyncAt`
and then passes accounts it read before the clear, now runs the full sync it exists to force, unless its turn starts
within 15 seconds of another pass's sync (the recent-sync check), in which case the full sync stays due
and the next foreground pass runs it; on the caller's copy it did not run when a full sync had run in
the last 15 minutes. The work queue is still looked up before the wait (tabmail-ios #573). No caller
calls a pass from inside a pass (census at the ruling: the account-manager entry points, account setup,
three Settings actions and the launch-time epoch-rebuild kick), so the non-reentrant semaphore cannot
deadlock; a new caller from inside a pass would. Tests: `OneSyncAtATimeTests` (a second pass, foreground
or background, waits until the first pass's full sync is done, and a waiting foreground pass then skips
rather than sync again; a delta that waited behind a full sync runs from the cursor it captured; a full
sync made due after the caller read the account still runs; a pass that throws hands the turn on; passes
waiting their turn run one at a time in arrival order, and one arriving during a handed-over turn waits
too; passes whose account was removed while they waited do nothing and hand the turn on; another
account's pass does not wait).
