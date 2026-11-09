# TabMail iOS — Test Reference

This file documents cross-cutting test architecture that spans multiple files/layers. It is not a full test inventory — see individual test files for detailed coverage of a given component.

---

## Interrupted action recovery

`GlobalFifoExecutorTests.interruptedMovesConvergeAfterRestart` captures a real
SQLite snapshot at the provider boundary after the FIFO claim and reopens it
through `AppDatabase.init`. It checks ordered effects across the restart with
zero or two earlier moves completed, plus preserved operation identity, position,
retry count and attempt history. It models process death through a snapshot;
it does not terminate the hosted test process.

`interruptedGraphMoveConverges`, `interruptedGmailMoveConverges`, and
`interruptedIMAPMoveRetainsAuthority` exercise
real providers against stateful servers before and after remote completion,
including changed/unknown IMAP epochs and untouched bystanders.
`interruptedGroupedGmailMoveConverges` snapshots a real claim for one or three
messages and reopens it through both testing and production startup modes, with
existing-release flags, both normally and after a refused recovery UPDATE clears.
It checks preserved intent/history, every target, the bystander and durable queue
settlement through the database returned as usable.
`AccountManagerQueueDrainTests` retains startup-only coverage of cancelled-row
cleanup and unrelated queued work.

## Inbox list — layered test architecture

the unified inbox read (ADR-IOS-055) replaced four disagreeing inbox-list read paths with one unified reader (`InboxListReader` → `InboxListComposer.compose`). Getting this right — and *keeping* it right as the code evolves — needs coverage at four distinct layers, each catching a different class of bug. A 5-round adversarial audit of the refactor found two HIGH-severity findings (F1, F2) that lived entirely *between* layers, invisible to any single layer's test suite — that's why the fourth layer (E2E) exists.

### Layer 1 — Pure composer harness (logic, thousands of cases)

**File:** `TabMailTests/ViewModels/InboxComposeScenarioTests.swift`

Drives `InboxListComposer.compose` — a pure function, no I/O, no GRDB, no clocks — over a value-type `SimWorld` state machine standing in for the whole pipeline (NSE staging → merge phases → sync → user actions → overlay drain). Each `SimWorld.Step` mirrors exactly one real-world event at FINE granularity (`stagePush`, `phase1Commit`, `ftsFlushCommit`, `phase2Commit`, `drainStaging`, `userMove`, `undo`, `uidRemap`, `reStage`, …).

Invariants I1–I7 (no-resurrection, no-vanish, AI-monotonic, undo-visible, no-duplicates, move-hides, window-sanity) are asserted after **every single step** of every named scenario, plus commutable-pair permutations and a seeded `SplitMix64` fuzz over hundreds of random legal step sequences per run. Because there's no I/O, this is cheap enough to run thousands of compositions per second — this layer is where lifecycle-interleaving bugs (the ones that would otherwise need a flaky on-device repro) get caught for pennies.

### Layer 2 — Reader integration (GRDB seams)

**File:** `TabMailTests/ViewModels/InboxListReaderIntegrationTests.swift`

Thin by design — only what the pure layer can't see: `DurableIdentityLookup` behavior against a real temp GRDB pool (exact-folder match, rfc822 fallback, UID-remap re-key), the P-step's by-id overlay fetch, and a contract-parity test asserting the shell's identity lookup matches the merge's own lookup helper over a shared fixture set (§4.4 risk 1 — divergence here reintroduces I1/I5-class bugs). One end-to-end smoke per fetch site (`fetchFullRange`/`fetchPage`/`resetMessages`) proves they all actually route through the reader.

### Layer 3 — Pinning suite (VM contracts)

**File:** `TabMailTests/ViewModels/InboxListBehaviorPinningTests.swift`

Exercises `InboxViewModel`'s public surface only (`insertStagedRows`/`reloadMessages`/`resetMessages`/`insertUndoneMessages`/`loadMoreMessages`/`lookupMessage` + `loadedMessages`/`displayGroups`) against a real temp `AppDatabase` swapped in for `AppDatabase.shared`. Originally written test-first (to pin current behavior) as the safety net for the composer refactor; now pins the reader's structural guarantees (staged-row survival, AI carry-over, undo-survives-reload, filter/pagination/triage-order parity) directly through the VM, independent of the pure layer's value-world model.

### Layer 4 — E2E invariant layer (orchestration + cross-layer ordering)

**File:** `TabMailTests/E2E/InboxEndToEndInvariantTests.swift`

The SAME scenario histories as Layer 1, driven through the REAL pipeline instead of a value world: a real temp `AppDatabase` + a real NSE staging SQLite file merged via `NSEDataBridge.mergeNSEStagingData(stagingPathOverride:)` + real `AccountManager` overlay mutations + real `NotificationCenter` posts + a real `InboxViewModel`. Assertions run against `vm.loadedMessages`/`displayGroups` (what the user's screen actually shows), not `compose`'s return value.

**Why this layer exists — F1 and F2.** Both were HIGH findings from the 5-round audit, and both slipped past Layers 1–3 with everything green:

- **F1 (signal-orchestration gap):** a "scrub-only" merge wake (re-staging an already-archived message finds nothing durable to write, only a staging scrub) has no `endOfMergeChanged` signal — before the fix, this left a phantom row the pre-detection `.messagesStaged` post had already inserted with no eviction trigger. Layer-local tests can't catch this because it's not about what `compose` returns or what the VM's *methods* do in isolation — it's about whether a *signal actually fires* to wake a real consumer after a mutation. **Invariant I8 (signal-liveness)** generalizes this: any step that changes what SHOULD be visible must be followed by an actual `.inboxDataDidChange`/`.messagesStaged` post — captured via a real `NotificationCenter` observer. The `scrubOnlyWakeStillConverges` scenario runs in WIRED mode (`vm.start()`, no manual reload) specifically so a regression shows up as "the screen never converges," not just "a flag was false."
- **F2 (cross-layer ordering gap):** `compose`'s `targetCount` trim and the VM's `loadedIds` pagination dedup were each tested individually, but their *composition* — trim running before dedup vs. after — was not. In triage mode (non-date-monotonic sort), an already-loaded row re-entering a later page's D query could eat a trim slot meant for a not-yet-loaded row, silently shrinking a page and flipping `hasMoreMessages` false with reachable mail still unread. **Invariant I9 (pagination-completeness)** generalizes this: driving `loadMoreMessages` to true exhaustion must surface every reachable id exactly once, with `hasMoreMessages` going false only at genuine exhaustion — dedicated scenarios (`paginationCompletenessNormal`, `paginationCompletenessTriage`) seed 2+ pages across multiple folders and drive to exhaustion rather than checking a single page transition.

**Invariant I10 (screen-truth convergence)**, checked at every settle point, is the general backstop for both classes: `Set(vm.loadedMessages.map(\.id))` must equal a fresh direct `InboxListReader.fetchSync` call built with the VM's own query shape. Running the SAME named scenarios at the pure (Layer 1) and E2E (Layer 4) layers turns any `SimWorld`-vs-reality fidelity drift into a loud, immediate disagreement instead of a silent blind spot.

**Granularity note:** the E2E step vocabulary is coarser than the pure layer's — staging a terminal (header+body+AI) row and running one `mergeNSEStagingData` call performs phase-1, the FTS flush, phase-2, and the staging drain all within one real "wake" (the merge awaits its own FTS flush). This is deliberate: Layer 1 proves invariants hold at every micro-step; Layer 4 proves they hold across real wake boundaries, which is the actual unit of observability a production reload/render cycle has. Scenarios that need to observe an in-between state (e.g. `aiNeverFlashesAcrossWakes`) drive two explicit gradual-staging wakes instead of relying on sub-wake granularity that doesn't exist at this layer.

**Retro-fit discipline:** a harness that can't re-catch a known bug isn't done. Both F1 and F2 were deliberately re-introduced (scrub-branch post disabled; `excludeIds` moved to post-trim) against this layer and confirmed to fail `scrubOnlyWakeStillConverges`/I8 and `paginationCompletenessTriage`/I9 respectively before the fixes were restored.

## Gmail moves and the labels Gmail maintains

Gmail keeps the `SENT` and `DRAFT` labels itself and refuses any
`messages.modify` that adds or removes them with 400 "Invalid label".
`TabMailTests/Infrastructure/StatefulGmailActionServer.swift` refuses them the
same way, refuses a new label on a draft's message, and serves
`/messages/{id}/trash` and `/untrash`.
`TabMailTests/Services/GmailMaintainedLabelMoveTests.swift` asserts, over every
source and destination pair, that the move reaches Gmail's end state (the kept
label stays, Trash is entered and left with trash/untrash, a draft's message
takes no new label) and that no request ever names a maintained label. It also
asserts that delete from Sent or Drafts and its Undo land on the server through
trash/untrash; that every real member of a delete from Sent and of its Undo
lands when the first member is an invalid or missing id;
the agent's draft delete lands; a move the server refuses stays queued rather
than counted as done; a delete from Sent, and its Undo, that Gmail refuses with a
503 or an unclassified 400 on trash/untrash stays queued with the server
unchanged and lands once the failure clears; a user move into Sent or Drafts is refused on Gmail and
queued on IMAP. `MoveFolderPickerTests.gmailOmitsTheLabelsGmailKeeps` covers the
picker, and `DraftDeletionTests` pins that an "Invalid label" body is not an
authoritative rejection.

## Server-draft dismissal UI

`TabMailScreenshots/ServerDraftCloseUITests.swift` runs in the existing
`TabMailScreenshots` UI-test scheme. Its six cases cover unavailable and failed
resolution in full-screen, pushed, and collapsed detail-column presentations.
The Debug fixture seeds disposable account, folder, and header rows and mounts the
production `MailNavigationView`. Cover cases tap the real Drafts row; push and detail
cases emit the existing email-pill and notification input events. No substitute
navigation stack or cover owns the loader. Each opens and closes twice, checks the
real mailbox is usable, and checks that the fixture rows remain intact. Failure
cases also verify that Try Again invokes the injected dependency again. The
resolver seam is a Debug-only environment value, defaulting to nil. These are
mailbox-presentation integration tests, not provider-resolution integration tests.

## Dictation upload — one bitstream pinned in two repositories

`FLACEncoderTests.writesTheStreamTheReferenceDecoderWasCheckedAgainst` pins the SHA-256 of the FLAC
stream for a deterministic speech-like signal; TabMail Voice's `apps/desktop/test/flac.test.ts`
pins the same hash for the same signal, which the reference `flac` decoder accepted. The signal is
computed in doubles with JavaScript's rounding so both produce identical samples. A change to either
encoder's choices fails its own suite, and the two apps keep uploading the same bytes. Losslessness
is checked by two independent decoders: `FLACTestDecoder` (every CRC checked) and Core Audio.
`decodesToTheSameSamplesWhateverLengthTheLastFrameIs` sweeps every last-frame length 1–40 and 127,
255, 1001, alone and after a full block, over noise, a tone (a high predictor order) and quiet audio
with a full-scale burst and a step (the largest Rice parameter): each of the encoder's predictor-order,
partition-order and Rice-parameter guards, removed, fails it (a trap or a stream that does not
decode to the samples). The size tests hold digital silence to a few bytes a frame (the constant
subframe) and full-scale audio to its PCM plus a frame's overhead (the verbatim fallback the upload's
size bound rests on).

## Device Sync — labelled bullets, shared with Thunderbird and Voice

`DeviceSyncVectorsTests` runs the conformance vectors Thunderbird and TabMail Voice run too
(`TabMailTests/Fixtures/DeviceSync/device-sync-vectors.json` and the bundled default catalog, both
SHA-256 pinned, so a change to the shared files fails all three suites until each re-pins). Each
scenario runs on simulated devices (`BulletDevices.swift`): every device runs the real `PromptBulletSync`,
`BulletSync`, `Bullets` and `UserDefaultsBulletStore` on its own `UserDefaults` suite, connected through a
relay the scenario delivers, reorders or drops. `DeviceSyncFuzzTests` runs seeded random devices, edits,
resets, failed saves, restores and deliveries, and asserts at every delivery that no bullet a user did not
delete is lost, at the end that the devices converge and stop sending, and that no message exceeds the
relay's budget (8 seeds by default; `DEVICE_SYNC_FUZZ_SEEDS` sets more, 30 pass).

`PromptSemaphoreTests` covers the prompt store's one semaphore: a hold is released when its body
returns, throws or is cancelled; a hold past its lease loses it, hands the semaphore on and does not move
the counter; a call made inside a hold, and from a child task of the holder, is refused as busy at once; a
task created under the cleared mark waits instead; waiters take the semaphore in the order they asked, a
request made as the holder releases queues behind the line, a cancelled waiter and one past its wait leave
the line and are never granted. `PromptStoreBoundaryTests` pins the AI write (read, call holding nothing,
write carrying the counter) being dropped after a local edit, a reset, a restore or a lapsed lease, with
the stored state, the rendered text and the history unchanged; the counter moving only on a saved change;
a hung model call blocking nothing; and the two gesture-order inversions (delete then add, add then
delete) ending as the user's last gesture. `DeviceSyncReceiveTests` covers arrival order with the busy
re-apply, the connection end dropping everything waiting, the bound (messages plus held parts) renewing
the connection, and an older `prompt_state` never landing on a newer edit. `DeviceSyncSocketBoundaryTests`
runs a loopback WebSocket server to show a message read after its connection was replaced is dropped.

## Gmail thread binding — Send and draft uploads

Gmail files a message or draft in a conversation only when the request's `message` resource names the
`threadId`, the raw message's In-Reply-To/References name the parent, and the Subject matches.
`GmailSendBodyTests` covers the Send body. `GmailReplyDraftThreadTests` drives production
`DraftStore.pushDraftToServer` against a real `GmailProvider` on `FakeHTTP` and reads both
`drafts.create` and `drafts.update` off the wire: each carries the `threadId` that
`ThreadUtils.outgoingThreadHeaders` gives Send for the same reply (the parent's id for a matching
subject, none for a changed one) beside the headers that name the parent. A reply draft saved in a
different Gmail account than its parent sends no `threadId` on either request, as Send from that
account would not, and still names the parent in its headers. Both cases run with and without a
stored attachment, so the multipart upload is held to the same binding and keeps the body and the
attachment bytes.

## Gmail history pages and the delta work bound

`GmailHistoryPaginationTests` drives production `SyncEngine.performDeltaSync` end to end against a
real `GmailProvider` on `FakeHTTP`. The property: the Gmail delta applies every history record after
the stored cursor before the cursor moves, and never moves it past a page it did not read. Covered:
every page applied with the first page's `historyId` as the cursor and the page token percent-encoded
on the wire; each of three page requests carrying the original query, a `maxResults` Gmail accepts and
only the current page token; a deletion on a later page applied (the deleted row removed, a bystander
kept, a message added then deleted never fetched or kept); a later page that fails (error status,
transport failure, cancellation, or a 200 whose body is not a history page) applies nothing and keeps
the cursor; a later-page 404 and a history past the page limit clear the cursor for the full sync. The
work bound, which stops a delta from committing to more message GETs than the sync deadline can
carry: the record budget on its own (records that name nothing to fetch), and the distinct-message
budget for every record kind that makes the delta fetch a message, on one page and across pages,
each at exactly the budget (applied) and one past it (no GET, cursor cleared); a message named by two records on different pages counts once. A page without
`history`, Gmail's answer to a quiet poll, is an empty delta that moves the cursor.

## Gmail search text on the wire

`GmailProviderMockTests.searchTextReachesGmailIntact` decodes the recorded
search request the way Gmail reads a query string (`&` separates parameters,
`=` splits name from value, `+` is a space) and asserts that the user's text,
including `&`, `+`, `=`, `%`, `#`, non-ASCII characters, literal percent escapes
such as `%26` (which must not be decoded first) and a `from:` address with a `+`
tag, comes back as exactly one `q`, with no stray parameter.

## Delta detail fetches — a failed fetch is never taken for a deleted message

`DeltaDetailFetchFailureTests` drives production `SyncEngine.performDeltaSync` end to end on
`FakeHTTP` for Gmail and Outlook, whose deltas fetch each changed message by id. A message whose
fetch fails (a 5xx, a non-gone 4xx, a transport failure, a body that does not decode, a 200 whose
record has no usable date) fails the delta and keeps the cursor (the Gmail history id, the Outlook delta link); on the next pass the
fetch succeeds and the change lands. A message that answers 404 is gone and is skipped: the rest of
the delta is applied and the cursor moves. A Graph refusal on the detail fetch is still logged with
its error code and message. Called directly with the gone message first (404 or 410), the detail fetch still
returns the readable one. Driving `performDeltaSync`, `fullSync` and `captureSyncCursors` in that order, a Gmail message whose fetch never
succeeds does not stop sync: the full sync completes past it (its row kept), moves the cursor, and
later changes land. A dropped connection, a 401 the token refresh does not cure, or a cancellation
during the rate-limit backoff still fails that folder's fetch. On Outlook, a message whose fetch
never succeeds is bounded by the cursor capture, which walks the inbox's delta pages to the final
link; a later delta from that link lands what changed after it.
