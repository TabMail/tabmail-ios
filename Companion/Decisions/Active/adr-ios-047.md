
## ADR-IOS-047: Two-Phase NSE Merge — Header+Snippet Visibility Is Decoupled From the Body-Blob Write

**Date:** 2026-06-29
**Status:** Accepted
**Related:** ADR-IOS-037 (NSE/main-app AI lease), ADR-IOS-013 (dual-path AI), ADR-IOS-001/003 (optimistic UI / crash recovery), the `PriorityGate` merge gate (ADR-IOS-046), ADR-IOS-008 (AI parity).

**Context:** On-device wifi-off `BootProfiler` captures showed a residual: after a push, a freshly-merged message sometimes took **1.3–8s** to appear in the inbox. A merge-write decomposition (`merge: GRDB writer ACQUIRED after Xms` / `main tx committed`) proved it was **NOT** writer contention (0ms wait) and **NOT** the network — it was the **actual in-transaction write of a single staged message**, strongly size-correlated (39 KB body → 2ms; multi-MB → seconds). The cause is structural: `NSEDataBridge.performMerge` wrote the `MessageBody` HTML blob **inside the same `dbPool.write` transaction whose commit (then `flushNSEBatchToFTS` → `headerComplete=1`) makes the message inbox-visible**. A sender that embeds images as inline `data:base64` directly in the HTML (not `cid:`, not remote — so the NSE stages it verbatim and the merge writes the whole blob) produces a multi-MB row; its write gated visibility. Confirmed the merge does NOT render and the renderer fetches NO remote content (`BodyRenderer` has no `URLSession`; remote `<img>` stays verbatim for the WebView), so the only lever was *where* the blob is written, not *whether*.

**Decision:** Split `performMerge` into two phases; visibility no longer waits on the blob.
- **Phase 1 (new, additive):** per staged message, ensure its `MessageHeader` EXISTS with snippet — refresh the snippet on an already-synced header, or insert a HEADER-ONLY row for a brand-new push via `insertNewHeaderFromStaging(headerOnly: true)` (header + computed thread + reference/label junctions + snippet; **no body blob, no AI fields**). Then `flushHeadersToFTS` (the header half — steps 1–3 — of `flushNSEBatchToFTS`) → `headerComplete=1` (inbox-visible) → post `.inboxDataDidChange` (immediate). **Phase 1 deletes nothing.**
- **Phase 2 (the pre-existing merge block, unchanged):** writes the body blob + summary/action/AI cache, FTS-indexes the body → `bodyComplete=1`, posts a second immediate `.inboxDataDidChange`, and **only then** deletes the staging row. Because phase 1 created the headers, phase 2 normally takes its existing-header branch; if phase 1 ever missed a row (per-message savepoint failed, or the outer tx threw), phase 2's new-header branch is the **full-merge fallback**.

So the user-visible sequence is: header+snippet → render → body+AI → render → (gate releases) → herd. The AI fields (`summaryBlurb`/`actionTag`) are tiny but were deliberately deferred to phase 2 too, keeping phase 1 the *minimal* "make it visible" write — simplicity over a field-by-field split.

**Rationale / why this is safe, not clever:**
- It reuses an invariant the codebase already ships: `headerComplete=1` (FTS has header → inbox-visible) is already DECOUPLED from `bodyComplete=1` (body present), and the unresolved-CID path **already** surfaces a header with `bodyComplete=0` and lets `ActiveBodyQueue` (`WHERE headerComplete=1 AND bodyComplete=0`) backstop it. Phase 1 just makes the non-CID body path behave the same way.
- **Staging is the durable source — deletion happens ONLY in phase 2.** A crash between phases self-heals on the next wake: phase 1's header upsert is idempotent, and the staging row is still present for phase 2 to write the body from. We do NOT carry the body across phases in memory and delete staging early (rejected — violates "delete only when confirmed correct").
- **No body-queue refetch race:** the whole `performMerge` runs inside `PriorityGate.privileged`, so `ActiveBodyQueue` yields until after phase 2 has flipped `bodyComplete=1` — it never observes the transient `bodyComplete=0` window.
- The double header-FTS-flush (phase 1's `flushHeadersToFTS` + phase 2's `flushNSEBatchToFTS` re-running the same IDs) is intentional and free — `indexHeaders` is idempotent and the `headerComplete=1` flip is a second-time no-op.

**Consequences:**
- The merge now emits **two** immediate `.inboxDataDidChange` posts per wake with new mail (header render, then body/AI render) instead of one — bounded at two; the inbox's single-flight reload coalesces them. `NSEGradualMergeTests` updated accordingly.
- A brief sub-second window exists where a just-surfaced message has no `MessageBody` yet; opening it in that window hits the same `bodyComplete=0` open path that already exists (and self-heals). Acceptable and pre-existing for CID bodies.
- `insertNewHeaderFromStaging` gained a trailing `headerOnly: Bool = false` (trailing on purpose — a defaulted param before the `inout ftsBatch` broke the cross-module test call's overload resolution).
- Also tuned `nseMergeHerdSettleSeconds` 1.0 → 0.5 (the detached post-merge reply/embedding-enqueue delay; off the display path, so purely shifts when the AI herd starts).

**Tests:** `NSEMergeFullHeaderTests.headerOnlyDefersBodyAndAI` (headerOnly writes NO `MessageBody` row + nil AI fields; the default writes both). `NSEGradualMergeTests` post-count updated to the two immediate renders. 54 NSE tests green.

---
