
### Ever-Rolling FIFO Queues (ADR-IOS-027)
- **Philosophy**: Items NEVER leave queue until confirmed success or confirmed stale. No fire-and-forget.
- **Dispatch pattern**: move to back → mark in-flight → fire task → on success: remove; on failure: clear in-flight, item stays at back for retry.
- **Two-phase dispatch**: Phase 1 synchronous (collect candidates, no await). Phase 2 async (resolve deps, launch tasks). Prevents actor reentrancy bugs.
- **Boot-time recovery**: Every queue has `repopulateFromDatabase()` called from `SyncScheduler` on foreground return + BGProcessingTask.
- **Queues**: `ActiveBodyQueue`, `ActiveAIQueue`, `BackfillEmbeddingQueue` — all follow identical pattern.
- **No pause mechanism** — IMAP pool priority checkout handles user-vs-background contention naturally.
- Self-heal/consolidation should never need to do real work — purely a safety net.
