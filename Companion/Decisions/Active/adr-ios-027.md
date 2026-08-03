
## ADR-IOS-027: Ever-Rolling FIFO Queues — Leave Only on Confirmed Success or Confirmed Stale

**Context:** Background processing queues (ActiveBodyQueue, ActiveAIQueue, BackfillEmbeddingQueue) handle work items that represent real user data — message bodies, AI summaries, vector embeddings. Fire-and-forget patterns risk silent data loss: if a task fails (connectivity drop, timeout, crash), the item vanishes from the queue and is never retried. The consolidation/self-heal pass on next launch should be a safety net, not the primary recovery mechanism.

**Decision — Ever-Rolling FIFO with In-Flight Safety:**

1. **Items NEVER leave the queue until confirmed done.** An item is removed ONLY on:
   - **Confirmed success** — the work completed and was persisted (FTS write, AI cache write, embedding stored).
   - **Confirmed stale** — the source data no longer exists (account deleted, header deleted, content permanently gone e.g. HTTP 404/410).
   - **Max retries exceeded** — transient failures exhausted the retry budget (`SyncConfig.maxQueueRetries`). Item is dropped from in-memory queue; `repopulateFromDatabase()` rediscovers it on next foreground.

2. **Dispatch = copy to back + mark in-flight.** When dispatching an item:
   - Move item from front to back of the FIFO array (item is always in the queue).
   - Mark item in the `inFlight` set (dispatch skips in-flight items).
   - Launch fire-and-forget task for the actual work.
   - On success: remove from queue. On failure: clear in-flight flag — item stays at back, will naturally cycle to front for retry.
   - **Candidate scan MUST skip past in-flight items** — use a `scanIdx` that advances past in-flight entries instead of breaking at the first one. Without this, newly-enqueued items get stuck behind wrapped-around in-flight items at the front of the queue, even when concurrency slots are available (dispatch starvation).

3. **Two-phase dispatch (actor reentrancy safety).** Phase 1 collects candidates synchronously (no `await` — safe from actor reentrancy). Phase 2 resolves async dependencies (provider lookup, DB reads) and launches tasks. This prevents queue mutation during iteration.

4. **Immediate dispatch on idle→active transition.** First item enqueued into an empty queue dispatches immediately (no debounce delay). Subsequent rapid enqueues are debounced (300ms body, 500ms embedding) to batch redundant dispatch calls.

5. **Boot-time recovery for every queue.** Each queue has `repopulateFromDatabase()` that discovers incomplete work from GRDB/FTS state (e.g., inbox headers missing FTS body, messages with body but no embedding). Called from `SyncScheduler` on foreground return and in `BGProcessingTask`. The queue itself is ephemeral (in-memory); the database is the durable source of truth.

6. **Failed items yield to others.** On failure, the item is already at the back of the FIFO — other items get their turn before the failed item cycles back to the front. This prevents one bad item from blocking the entire queue.

**Queues implementing this pattern:**
- `ActiveBodyQueue` — fetches message bodies from provider, writes plain text to FTS
- `BodyRenderQueue` — renders FullMessageInfo → MessageBody (CID, ICS, attachments). Background pre-cache path uses INSERT OR IGNORE; user-open path uses save() (upsert) to always win over background.
- `ActiveAIQueue` — generates summaries/actions/replies via backend LLM
- `BackfillEmbeddingQueue` — generates vector embeddings via CoreML

**Rationale:**
- No item is ever in a state where it's "not in the queue AND not confirmed done"
- Crash at any point loses only the in-memory queue — `repopulateFromDatabase()` rebuilds from durable state
- The self-heal/consolidation pass should never need to do real work — it's purely a safety net
- IMAP priority lock (`acquirePriorityLock()`) handles user-vs-background contention naturally — no pause mechanism needed

**Consequences:**
- Slightly more memory per queue (in-flight set, retry counts, dedup set)
- `repopulateFromDatabase()` is idempotent — safe to call multiple times (dedup set prevents duplicates)
- All four queues follow identical structure — any new processing queue must adopt the same pattern

---
