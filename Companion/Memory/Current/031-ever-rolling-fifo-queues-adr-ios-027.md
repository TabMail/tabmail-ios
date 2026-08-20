<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **⚠️ Current routing note (2026-08-20, iOS #66) — "Boot-time recovery: Every queue has `repopulateFromDatabase()`" is TRUE OF THE METHOD and NOT of its COVERAGE for `ActiveAIQueue`.** The preserved body is unedited (its bytes are pinned); read this note alongside it.
>
> `ActiveAIQueue.repopulateFromDatabase` runs `ActiveAIQueue.repopulationCandidates`, which is **window-bounded in SQL** to the newest `SyncConfig.maxRecentEmails` Inbox rows. ADR-IOS-078's **pathway regating** (owner directive 2026-08-19) also gave that queue **WINDOW-EXEMPT** jobs — manual open, push/NSE merge, moved-into-inbox, flagged `AIJob.windowExempt` — so for an exempt job on an **out-of-window** row, boot/foreground recovery does not reach it and neither does the drain-time `repopulateOnDrain`. `ActiveBodyQueue`'s sweep is Inbox-wide and **unbounded**, and `BackfillAIQueue`'s reloads durable `pendingAIRefinement` rows, so the body's bullet holds for them as written. The per-queue distinction is the point — do not flatten it.
>
> **Accepted, per ADR-IOS-078's residual invariant:** for an out-of-window row, exempt AI work can fail to be scheduled or be discarded before it runs — never silently wrong, never durable, always repairable by one ordinary gesture (reopen/Retry re-enters the exempt direct path). ⛔ Do **NOT** widen `repopulationCandidates` to "fix" it, and do **NOT** re-gate an exempt producer to "restore" a global bound — the AI window is the install-flood door. Fuller version of this note sits on the routed ADR-IOS-027 fragment; canonical statements are ADR-IOS-078 (§ Pathway regating) and the `IOS-AI-004` amendment.
<!-- COMPANION-CURRENT-NOTE-END -->

### Ever-Rolling FIFO Queues (ADR-IOS-027)
- **Philosophy**: Items NEVER leave queue until confirmed success or confirmed stale. No fire-and-forget.
- **Dispatch pattern**: move to back → mark in-flight → fire task → on success: remove; on failure: clear in-flight, item stays at back for retry.
- **Two-phase dispatch**: Phase 1 synchronous (collect candidates, no await). Phase 2 async (resolve deps, launch tasks). Prevents actor reentrancy bugs.
- **Boot-time recovery**: Every queue has `repopulateFromDatabase()` called from `SyncScheduler` on foreground return + BGProcessingTask.
- **Queues**: `ActiveBodyQueue`, `ActiveAIQueue`, `BackfillEmbeddingQueue` — all follow identical pattern.
- **No pause mechanism** — IMAP pool priority checkout handles user-vs-background contention naturally.
- Self-heal/consolidation should never need to do real work — purely a safety net.
