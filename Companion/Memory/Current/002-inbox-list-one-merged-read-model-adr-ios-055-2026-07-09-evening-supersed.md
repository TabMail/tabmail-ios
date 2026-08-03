
## Inbox list = ONE merged read-model (ADR-IOS-055, 2026-07-09 evening) — supersedes the same-day guard/carry-over fixes

**Every inbox-list read now goes through `InboxListReader` → pure `InboxListComposer.compose` over durable ∪ overlay-pinned ∪ staged.** The morning's display-side compensating fixes (Pass-1 eviction guard, tombstones, AI carry-over, `ForegroundActiveClock`, `.stagedRowsInvalidated` VM eviction) are DELETED — see ADR-IOS-055 + the ADR-IOS-049 evening amendment. Rules for new code:
- New list reads route through the reader; event inserts (`insertStagedRows`/`insertUndoneMessages`) are latency-only and use the in-memory subset of the composer's checks.
- Merge dedup identity = `DurableIdentityLookup.find` — shared by NSEDataBridge (4 sites) AND the reader; keep in lockstep.
- Staged-row suppression predicate is **stale-by-move + D∪P-visibility, never bare identity-existence** (phase-1 rows are `headerComplete=false` until the FTS flush — blanket suppression re-creates the vanish flicker).
- Lifecycle changes get a World-DSL step + invariant in `InboxComposeScenarioTests` (16 steps, I1–I7, named boot-log scenarios, seeded fuzz; the retro-fit check proved it catches all four 2026-07-09 bug classes).
- Still load-bearing on the WRITE path (unchanged): merge stale-by-move staging hygiene, `recentlyCompleted` per-entry expiry + `pushMergeStaleProtectionTTLSeconds` (120s) + prune-before-snapshot, stage-memo skip (`NSEMergeStageMemoTests`, `RecentlyCompletedTTLTests`).

Historical diagnosis (boot_logs 2/3): staged in-memory render instant; durable phase-1 mean 3.9s / p90 7s under load = **writer-thread starvation** (NOT WAL, NOT staging-DB contention, NOT writer-queue waits); merge-before-herd intact. State-change silent pushes re-staging acted-on mail are ROUTINE push-worker behavior (don't widen worker dedup). Debugging trick: `insertStagedRows: +N` logs only on ACTUAL insert — the same staged set inserting twice means the row vanished in between. Full trail: `PLAN_INBOX_UNIFIED_READ.md`, ADR-IOS-049 amendments, ADR-IOS-055.

---
