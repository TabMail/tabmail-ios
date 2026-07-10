# TabMail iOS — Test Reference

This file documents cross-cutting test architecture that spans multiple files/layers. It is not a full test inventory — see individual test files for detailed coverage of a given component.

---

## Inbox list — layered test architecture

`PLAN_INBOX_UNIFIED_READ.md` replaced four disagreeing inbox-list read paths with one unified reader (`InboxListReader` → `InboxListComposer.compose`). Getting this right — and *keeping* it right as the code evolves — needs coverage at four distinct layers, each catching a different class of bug. A 5-round adversarial audit of the refactor found two HIGH-severity findings (F1, F2) that lived entirely *between* layers, invisible to any single layer's test suite — that's why the fourth layer (E2E) exists.

### Layer 1 — Pure composer harness (logic, thousands of cases)

**File:** `TabMailTests/ViewModels/InboxComposeScenarioTests.swift`

Drives `InboxListComposer.compose` — a pure function, no I/O, no GRDB, no clocks — over a value-type `SimWorld` state machine standing in for the whole pipeline (NSE staging → merge phases → sync → user actions → overlay drain). Each `SimWorld.Step` mirrors exactly one real-world event at FINE granularity (`stagePush`, `phase1Commit`, `ftsFlushCommit`, `phase2Commit`, `drainStaging`, `userMove`, `undo`, `uidRemap`, `reStage`, …).

Invariants I1–I7 (no-resurrection, no-vanish, AI-monotonic, undo-visible, no-duplicates, move-hides, window-sanity) are asserted after **every single step** of every named scenario, plus commutable-pair permutations and a seeded `SplitMix64` fuzz over hundreds of random legal step sequences per run. Because there's no I/O, this is cheap enough to run thousands of compositions per second — this layer is where lifecycle-interleaving bugs (the ones that would otherwise need a flaky on-device repro) get caught for pennies.

### Layer 2 — Reader integration (GRDB seams)

**File:** `TabMailTests/ViewModels/InboxListReaderIntegrationTests.swift`

Thin by design — only what the pure layer can't see: `DurableIdentityLookup` behavior against a real temp GRDB pool (exact-folder match, rfc822 fallback, UID-remap re-key), the P-step's by-id overlay fetch, and a contract-parity test asserting the shell's identity lookup matches the merge's own lookup helper over a shared fixture set (§4.4 risk 1 — divergence here reintroduces I1/I5-class bugs). One end-to-end smoke per fetch site (`fetchFullRange`/`fetchPage`/`resetMessages`) proves they all actually route through the reader.

### Layer 3 — Pinning suite (VM contracts)

**File:** `TabMailTests/ViewModels/InboxListBehaviorPinningTests.swift`

Exercises `InboxViewModel`'s public surface only (`insertStagedRows`/`reloadMessages`/`resetMessages`/`insertUndoneMessages`/`loadMoreMessages`/`lookupMessage` + `loadedMessages`/`displayGroups`) against a real temp `AppDatabase` swapped in for `AppDatabase.shared`. Originally written test-first (PLAN §5 Phase 1, "pin current behavior") as the safety net for the composer refactor; now pins the reader's structural guarantees (staged-row survival, AI carry-over, undo-survives-reload, filter/pagination/triage-order parity) directly through the VM, independent of the pure layer's value-world model.

### Layer 4 — E2E invariant layer (orchestration + cross-layer ordering)

**File:** `TabMailTests/E2E/InboxEndToEndInvariantTests.swift`

The SAME scenario histories as Layer 1, driven through the REAL pipeline instead of a value world: a real temp `AppDatabase` + a real NSE staging SQLite file merged via `NSEDataBridge.mergeNSEStagingData(stagingPathOverride:)` + real `AccountManager` overlay mutations + real `NotificationCenter` posts + a real `InboxViewModel`. Assertions run against `vm.loadedMessages`/`displayGroups` (what the user's screen actually shows), not `compose`'s return value.

**Why this layer exists — F1 and F2.** Both were HIGH findings from the 5-round audit, and both slipped past Layers 1–3 with everything green:

- **F1 (signal-orchestration gap):** a "scrub-only" merge wake (re-staging an already-archived message finds nothing durable to write, only a staging scrub) has no `endOfMergeChanged` signal — before the fix, this left a phantom row the pre-detection `.messagesStaged` post had already inserted with no eviction trigger. Layer-local tests can't catch this because it's not about what `compose` returns or what the VM's *methods* do in isolation — it's about whether a *signal actually fires* to wake a real consumer after a mutation. **Invariant I8 (signal-liveness)** generalizes this: any step that changes what SHOULD be visible must be followed by an actual `.inboxDataDidChange`/`.messagesStaged` post — captured via a real `NotificationCenter` observer. The `scrubOnlyWakeStillConverges` scenario runs in WIRED mode (`vm.start()`, no manual reload) specifically so a regression shows up as "the screen never converges," not just "a flag was false."
- **F2 (cross-layer ordering gap):** `compose`'s `targetCount` trim and the VM's `loadedIds` pagination dedup were each tested individually, but their *composition* — trim running before dedup vs. after — was not. In triage mode (non-date-monotonic sort), an already-loaded row re-entering a later page's D query could eat a trim slot meant for a not-yet-loaded row, silently shrinking a page and flipping `hasMoreMessages` false with reachable mail still unread. **Invariant I9 (pagination-completeness)** generalizes this: driving `loadMoreMessages` to true exhaustion must surface every reachable id exactly once, with `hasMoreMessages` going false only at genuine exhaustion — dedicated scenarios (`paginationCompletenessNormal`, `paginationCompletenessTriage`) seed 2+ pages across multiple folders and drive to exhaustion rather than checking a single page transition.

**Invariant I10 (screen-truth convergence)**, checked at every settle point, is the general backstop for both classes: `Set(vm.loadedMessages.map(\.id))` must equal a fresh direct `InboxListReader.fetchSync` call built with the VM's own query shape. Running the SAME named scenarios at the pure (Layer 1) and E2E (Layer 4) layers turns any `SimWorld`-vs-reality fidelity drift into a loud, immediate disagreement instead of a silent blind spot.

**Granularity note:** the E2E step vocabulary is coarser than the pure layer's — staging a terminal (header+body+AI) row and running one `mergeNSEStagingData` call performs phase-1, the FTS flush, phase-2, and the staging drain all within one real "wake" (the merge awaits its own FTS flush). This is deliberate: Layer 1 proves invariants hold at every micro-step; Layer 4 proves they hold across real wake boundaries, which is the actual unit of observability a production reload/render cycle has. Scenarios that need to observe an in-between state (e.g. `aiNeverFlashesAcrossWakes`) drive two explicit gradual-staging wakes instead of relying on sub-wake granularity that doesn't exist at this layer.

**Retro-fit discipline:** per PLAN §5A.4, a harness that can't re-catch a known bug isn't done. Both F1 and F2 were deliberately re-introduced (scrub-branch post disabled; `excludeIds` moved to post-trim) against this layer and confirmed to fail `scrubOnlyWakeStillConverges`/I8 and `paginationCompletenessTriage`/I9 respectively before the fixes were restored.
