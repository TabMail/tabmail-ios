# Pre-compaction index-row abstracts — `PROJECT_MEMORY.md` topic cells

**Status:** Historical (preserved source text) · **Routed:** 2026-08-05 · **Source:** `tabmail-ios/PROJECT_MEMORY.md` at `286697392`

These are the **verbatim** *Topic / search terms* cells that the index carried inline
before the 2026-08-05 `companion-compact` pass. Each had grown from a routing line into a
full abstract of its own detail file — 22.8 KB across 16 rows, 55% of an always-loaded
file, paid on every task by every agent. The index now carries a shortened line for each;
the text below is what those lines were compressed from, kept byte-for-byte so nothing a
past plan, review prompt, or commit body quoted has become unsearchable.

**The detail these abstracts summarise was never here** — it lives in the linked
`Companion/Memory/` topic file named in each section heading, which remains the normative
source. Read this file only to recover the exact pre-compaction index wording.

Markers delimit each preserved cell so the round trip stays mechanical; the wording
between them is untouched, including emphasis, emoji, and inline code spans.

---

## Source line 137 — Current → `093-the-wrong-message-wire-oracle-is-blind-to-shared-message-id-defects.md`

<!-- BEGIN VERBATIM ROW 137 -->
⚠️ The `FakeIMAPServer` wrong-message wire oracle (`wrongMessageViolations` / `expectMutation` / `expectedMutationRfcs`) is STRUCTURALLY BLIND to any C3 defect whose precondition is that target and bystander share one RFC 822 Message-ID — it discriminates by RFC-identity set membership, so such a mutation is declared correct and the assertion is vacuous while looking rigorous; pin on physical wire state + the `UID STORE`/`EXPUNGE` command log instead, and do NOT re-base the oracle on UID (2026-08-04, from the B1 draft-SEARCH fix `459786db1`)
<!-- END VERBATIM ROW 137 -->

---

## Source line 148 — Current → `095-v3-provider-id-action-queue-forward-port-resume-state.md`

<!-- BEGIN VERBATIM ROW 148 -->
v3 provider-id action-queue forward-port — authoritative resume state (2026-08-02): branch `v3`, HEAD `583de7a5d`, **PAUSED BY OWNER**, never pushed; `PLAN_IOS_REFACTOR_V3.md` ROUTING INDEX first then `PLAN_V3_*.md` on demand, never re-merged; T4.T2 landed / T5.9 / T4.T1 next, T4.O5 deferred; baseline 7,994 tests / 1,085 suites @ `35d5b2814`; rules R0–R4; the `v2final` PORT / SUBTRACT / `⚑ NO REFERENCE — INVENTED` classification and its exactly-two invention census (`v74` blanket `PendingOperation` purge)
<!-- END VERBATIM ROW 148 -->

---

## Source line 149 — Current → `096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md`

<!-- BEGIN VERBATIM ROW 149 -->
T1.3 — a NEW gesture fails CLOSED when the folder's UIDVALIDITY epoch is unknown (2026-07-30/31): `AccountManager.newGestureRefusedForUnknownEpoch` is a **silent no-op** (`IOS-EPOCH-001`, constraint C3), NOT to be "fixed" back to fail-open unlike `v2final`; provider-scoped carve-outs (`Folder.lastKnownUidValidity` nil FOREVER on Gmail/Exchange, `.icloud` stays IMAP, `DemoSeed.demoAccountId` by id, missing `Folder` row fails closed, drafts re-classified at EXECUTION by `DraftStore.pushDraftToServer`); the crawl-epoch machinery (`IMAPProvider.selectMailboxTracked`, `getUidNextWithEpoch`, `crawlEpochGate`, `crawlWalkWriteAllowed`, `verifyAndBootstrapPrePopulatedFolderEpoch`); the round 7/8/10 **RETRACTIONS** — say *indefinite* never *permanent*, and a TRANSIENT container plus a DURABLE re-entry condition IS a permanent refusal; the consumer-direction inversion (a comparison that ABORTS in the reference became a first-epoch WRITE); and on a refused optimistic write RECONCILE FROM THE DATABASE, never restore a snapshot (`UserLabelMenuModel.reconcileAppliedIdsFromDatabase`)
<!-- END VERBATIM ROW 149 -->

---

## Source line 150 — Historical → `097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md`

<!-- BEGIN VERBATIM ROW 150 -->
T4.S6 follow-up — **SUPERSEDED v3 intermediate; retain for history, never implement from it** (2026-07-31): the `v69` `PendingOperation.observedUidValidity` draft-op stamp and later `v72` draft-specific queue epoch as derivation only; *"carries a non-numeric id" is a property of the ROW, "resolves by SEARCH" is a property of the EXECUTOR* — `AccountManager.opIsAddressOnly` versus `queueDraftDelete`; the owner directive that a delete op must NOT survive a UIDVALIDITY reset; widening the sweep's classifier REJECTED; ⛔ the **RETRACTED** bare mailbox-wide `EXPUNGE` — `IMAPProvider.expungeScopedToTargets` is UIDPLUS-conditional and the no-UIDPLUS path fails closed, do not restore the fallback; tests `DraftDeleteEpochBoundaryTests` / `IMAPDraftExpungeScopeTests` and the `drainUntilSettled` versus `isDraining` harness trap
<!-- END VERBATIM ROW 150 -->

---

## Source line 151 — Current → `098-imap-external-deletion-blind-spot-amended-adr-ios-051.md`

<!-- BEGIN VERBATIM ROW 151 -->
IMAP external-deletion blind spot — old server-deleted messages linger forever (audit 2026-07-02), **FIXED 2026-07-03 by ADR-IOS-051** Phases 1+2, with every post-fix amendment: `SyncEngineDeletionReconcile`, `handleVanishedUIDs`, `IMAPProvider.searchExistingUIDs`, the `SyncConfig.deletionReconcileChunkSize` / `deletionReconcileCapSlack` deletion circuit breaker, first-walk UIDVALIDITY bootstrap caveat and the body-fetch "gone" UX follow-up; IDLE `.vanished` is CONSUMED while `.expunge` still degrades to a poll (the "both DISCARDED" claim was falsified); the thrice-corrected modseq wiring — `IMAPProvider.folderStatus` → `SyncEngine.modSeqIndicatesChange` (delta, can only FORCE a fetch) versus `FolderInfo.highestModSeq` → `SyncEngine.shouldSkipFolderFetch` (the only skip-capable gate), the shared `Folder.lastKnownHighestModSeq` column and the UPDATE/INSERT asymmetry; no CONDSTORE `CHANGEDSINCE`, no QRESYNC, no `VANISHED (EARLIER)`, `IMAPProvider.fetchHistory` returns nil
<!-- END VERBATIM ROW 151 -->

---

## Source line 152 — Current → `099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md`

<!-- BEGIN VERBATIM ROW 152 -->
Persistent NSE log file + watchdog partial-result delivery (2026-07-09) and audit rounds 1–7: `NSELogStore` / `nse.log` synchronous append, inode-preserving `clear()` and `trimIfNeeded` (never an atomic replace), `NSELog.step` and the `NSE stepN` / `NSE ━━━` grep contract, `NSELog.$runTag` per-run attribution, `NSEProviderSupport.logLine`; `PartialSignalHolder` and `NotificationService.applyPartialOrBareFallback`; the **idle-timer-versus-SSE** root cause (a summary ran 26.4 s and missed the 27 s watchdog by 9 ms), `BackendNSEClient.performRequestWithDeadline`, `NSEProviderSupport.llmCallBudget`, the action-requires-summary parity gate (ADR-IOS-008); the **zombie-resume** class — `OneShotFlag.hasFired()` and all NINE abandon checkpoints incl. the two corrected exemptions (peer-cache probe, `handleTaskAlarm`); and notification-tap pop suppression — `MessageDetailViewModel.retryLoad`, `shouldPopForUnresolvedTap`, `isViewVisible`, `hasActivePresentation`, `PreviewFreezeGate` (covers do NOT fire `onDisappear`)
<!-- END VERBATIM ROW 152 -->

---

## Source line 154 — Current → `101-isdeletedonserver-has-four-materialisation-paths.md`

<!-- BEGIN VERBATIM ROW 154 -->
`isDeletedOnServer` — FOUR materialisation paths (`selectStaleHeaders`, `runSyncMessages`, `insertBackfillBatchGuardable` funnel, `fetchOlderMessages`) **plus a FIFTH PRESENTATION path the census could not see** — `SearchView.searchAccount` renders `MessageHeaderInfo` into `SearchResult` without building a `MessageHeader`, `IMAPProvider.searchOnConnection` sends no `NOT DELETED`, `openResult`'s remote branch has no stale alert (`IOS-IMAP-001` ✅ **FIXED by `afa7889ee`** — state the census NOUN: the closing census enumerated **CONSUMERS of `MessageHeaderInfo`**, **EIGHT** of them, not producers of `MessageHeader`; `SearchView.presentableRemoteResults` drops the flagged records and `SearchView.tapOutcome`/`ResultTapOutcome` has NO silent case, so no tap is a no-op; the `NOT DELETED` term was deliberately NOT added to the SEARCH criteria); crawls advance on COVERAGE, never `inserted`; infinite-scroll exhaustion / `hasMoreMessages` / `mayHaveMore` is SERVER COVERAGE + progress, never materialised rows; ⚠️ **ERRATUM — `deepBackfillFolder` / `backfillWindow` / the whole date-window deep crawl is DEAD CODE (zero callers)**, so `e4dd08e92`'s commit body cited a mechanism that does not run; the live cover is `SyncEngine.runBackfill` + `UIDWalkCursor.confirmRange`, invoked by `startBackfill` and `SyncScheduler` → `performBackfill`
<!-- END VERBATIM ROW 154 -->

---

## Source line 155 — Current → `102-there-are-four-irreversible-wire-operations-not-one.md`

<!-- BEGIN VERBATIM ROW 155 -->
⚠️ **FOUR irreversible wire operations, not one** — the `COPYUID`-gated move source expunge **plus the draft family, which DESTROYS a draft rather than moving it to Trash**: `IMAPProvider.deleteDraftStrong`, `saveDraft`'s old-copy replacement (both `STORE \Deleted` + `expungeScopedToTargets`, UIDPLUS-only, fail closed otherwise) and `GmailProvider.deleteDraft`'s `DELETE /drafts/{id}` resource arm ("permanently deletes … does not simply trash"); so *"TabMail never permanently deletes"* is FALSE FOR DRAFTS and *"the single irreversible wire operation"* walks reviewers past three. TRUE half kept: v3 has **zero** bare `server.expunge()` sites, shipped `07a4bb703` had **four bare of five**, and the `COPYUID` gate's evidence is never widened. `ExchangeProvider.deleteDraft` is provider-defined, not counted
<!-- END VERBATIM ROW 155 -->

---

## Source line 156 — Current → `103-await-dbpool-read-is-not-a-short-suspension.md`

<!-- BEGIN VERBATIM ROW 156 -->
🚨 **`await dbPool.read` is NOT a short suspension** — `PrioritizedDatabase`'s "Read (passthrough)" banner is true only of the SYNC overload; the ASYNC one first `await`s `NSEDataBridge.mergeIfStagingPending()`, a full staging merge whose phase-1 durable write is **measured 7.6 s** cold-boot, and staging is pending exactly on foreground return / after push. Any check-then-act across an `await` on a read is a real race window, not an instant one; fast paths (recursion guard, empty-staging signature, KEPT-row TTL skip) make it usually µs but never BOUNDED
<!-- END VERBATIM ROW 156 -->

---

## Source line 157 — Current → `104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md`

<!-- BEGIN VERBATIM ROW 157 -->
🚨 **A latch that AUTHORISES a state transition must be HELD across the write that performs it** — reading `isDrainingOutbox` / `isDraining` / any ownership flag and then `await`ing proves nothing on an actor; ACQUIRE it, never "re-check after the await" (the same race one frame later). Instance `IOS-OUTBOX-006`: `AccountManager.reconcileOutbox` reset a row whose SMTP was on the wire, so `discardOutboxMessageConfirmed` accepted a Discard, `stampSentAt` matched 0 rows and the mail was delivered with no Sent APPEND. TWO production entries (launch `reconcilePendingOperations` — unguarded and PRE-EXISTING in `v2final`/`v1.6.38`; foreground `reconcileOutboxOnForeground` — candidate `792048ebd`); why v2final's one-transaction reconcile does NOT close it; the fail-closed liveness argument in both directions; and what could not be red-proven
<!-- END VERBATIM ROW 157 -->

---

## Source line 158 — Current → `105-a-print-is-not-production-observability-on-ios.md`

<!-- BEGIN VERBATIM ROW 158 -->
🚨 **A BARE `print` IS NOT PRODUCTION OBSERVABILITY ON iOS** — there is no `freopen`/`dup2` anywhere in this tree, so on a device `stdout` is DISCARDED and a rule-12 `🚨 UNGATED BY DECISION` production-observability exemption buys **ZERO**; the correct shape is a GATED `print` for the console **plus** an ungated durable write (`BackgroundSyncLogger.logError` → `error.log`, exported by `DebugLogView`'s "Error Logs"), which is what `AccountManagerQueue`'s three sites (delete-of-completed-op failed, partially-completed bundle requeued whole, F2b L4 terminal identity drop — `IOS-QUEUE-003` item 4's *"bounded and VISIBLE"*) now do. Before claiming an exemption, NAME THE CHANNEL AND CHECK IT EXISTS ON THE DEVICE. Also: *"this line is its only witness"* is FALSE wherever the durable `PendingOperation` row survives the failure — literally true only at the terminal drop, which deletes the row (`MIS-019`; the second site had inherited the first's claim); and **a `DebugModeManager.isLoggingEnabled()` gate placed inside a BRANCH CONDITION decides WHICH BRANCH IS TAKEN**, so debug and release builds stop sharing one control-flow graph (`SyncEngine.fetchOlderMessages`' `[InfiniteScroll]` arms) — hoist it into the body, and only after proving the arm is log-only. `InboxViewModel`'s fourth `[InfiniteScroll]` print is LEFT ALONE and recorded
<!-- END VERBATIM ROW 158 -->

---

## Source line 159 — Current → `106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md`

<!-- BEGIN VERBATIM ROW 159 -->
🚨 **A FILTER APPLIED AFTER A QUERY'S `LIMIT` NARROWS THE PAGE INSTEAD OF SELECTING IT** — and every downstream "is there more" decision inherits the lie; the display-layer and crawl-layer members of `6d460aa99`'s survivor-count class, both shared VERBATIM by `v2final` and shipped `07a4bb703`. (1) the inbox **label filter** ran in `InboxListComposer.compose` step 6 AFTER `InboxListReader.gather`'s per-folder SQL `LIMIT`, so `InboxViewModel.hasMoreMessages`' three sites (`resetMessages`, `reloadMessages`, `loadMoreMessages` phase 1) AND the pagination cursor `loadedMessages.last?.date` read a post-filter SURVIVOR count — 2 hits in the newest 50 rows reported the folder exhausted; fixed by ANDing one `EXISTS` per `filterLabelIds` id into the D query BEFORE the `LIMIT` (A3: fix the sibling's ordering, never plumb a coverage flag past it — `InboxView`'s `hasMoreMessages` sentinel would re-arm forever on an empty page, `MIS-005`), covering-index seek on `messageUserLabel`'s PK, no migration. (2) `IMAPProvider.getUidNextWithEpoch` normalised the EPOCH's zero and NOT the UIDNEXT's, so a SELECT carrying no `* OK [UIDNEXT n]` (SwiftMail `Mailbox.uidNext = UID(0)`) reached `SyncEngineBackfillWalk`'s `.fresh` branch as 0, gave `initialCursor == -1`, took the `< 1` early-out written for UIDNEXT 1 and marked the folder `backfillComplete` FOREVER — `MIS-IOS-004`; fixed by returning `uidNext: Int?` and DECLINING, with the empty-mailbox settle path untouched. `FakeIMAPServer.suppressSelectUidNext`; `IOS-BACKFILL-001` / `IOS-SCROLL-002`; ⚠️ `IOS-SCROLL-001`'s "registered separately" named a row that never existed
<!-- END VERBATIM ROW 159 -->

---

## Source line 160 — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 160 -->
🚨 **A STAGING KEY THAT NAMES AN ADDRESS MUST RE-PROVE IDENTITY BEFORE IT REUSES PAYLOAD** — `nse_processed_message`'s PK is `"<accountId>:<messageId>"` and on IMAP that `messageId` is a UID, an ADDRESS in a numbering space; a UIDVALIDITY turnover reissues it to a DIFFERENT message, so `NSEStagingDB.stageHeader`'s `ON CONFLICT` — which overwrites IDENTITY and deliberately RETAINS the body/AI payload — spliced the predecessor's body, summary, todos, reminder and `actionTag` onto the successor (`IOS-NSE-005`, BLOCKING C3 misattribution). `getCachedResult` (`WHERE id = ? AND aiCompleted = 1`, no RFC/epoch term) served it as the successor's NOTIFICATION on ANY IMAP account and returned before run 2's terminal write; the merge's NEW-HEADER arm (`insertNewHeaderFromStaging`, which does NOT call `nseMergeIdentityConfirmed`) then wrote it durably, poisoned `messageAICache` under the SUCCESSOR's RFC key and queued a `setTag` keyword write against it. FIXED by clearing on POSITIVE identity disagreement inside `stageHeader`'s own transaction, reusing `nseMergeIdentityConfirmed`'s two doors (RFC first and unconditional; epoch only when RFC cannot adjudicate; nil either side RETAINS) — one write closes both halves because `stageHeader` precedes the cache probe. ⚠️ **RETRACTED 2026-08-05: "the ORDERING is the guard" for `getCachedResult` was FALSE and the probe is now guarded too (`IOS-NSE-006` 4th member)** — `stageHeader` returns `Void` and SWALLOWS a thrown write (non-WAL cross-process App Group DB ⇒ `SQLITE_BUSY` is live), so an ordering proves the writer was CALLED, never that it LANDED (`MIS-024`); `getCachedResult` now takes the `NSEMessageMetadata` and consults `stagedIdentityPositivelyDiffers` with `stageHeader`'s fail direction (unanswerable ⇒ still SERVES). ⚠️ `abandonedCutoff` is a **DELETION** predicate applied AFTER the merge commits, never an ADMISSION predicate on the step-1 `SELECT … WHERE populated = 1` (`MIS-024` ×5); an age predicate there would convert the misattribution into a DROPPED message (`MIS-005`); clearing on ANY conflict would destroy gradual staging and the `AIOwnershipLease` placeholder (`MIS-IOS-004`). Both `v2final` `e28dd4edb` and shipped `07a4bb703` SHARE the defect — AUTHORED, not restored. Also: `TabMailTests` reached NO NSE-target symbol until `project.yml` compiled five NSE files into it behind `#if TABMAIL_TESTS`, which is why every older NSE staging test hand-mirrors the production SQL; and `AppDatabase.createNSEStagingDB` does NOT own `observedUidValidity`
<!-- END VERBATIM ROW 160 -->

---

## Source line 161 — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 161 -->
🚨 **THE SAME STAGING KEY HAS FOUR WRITERS, AND "SAFE" POINTS THE OPPOSITE WAY FOR THREE OF THEM** — `IOS-NSE-006`, the second half of `IOS-NSE-005`. `stageHeader` was guarded by `5813e44b1`; **`NSEStagingDB.stageBody`, `stageSummary` and `persistProcessedMessage` were not** — the first two bare `UPDATE … WHERE id = ?` with no identity term, the third an `INSERT OR REPLACE` whose damage differs in KIND (it does not splice mixed identities, it **destroys the successor's staged push outright and resurrects a predecessor**). All four now call `stagedIdentityPositivelyDiffers` inside their own write transaction — no new predicate, no schema change, **no migration**. ⚠️ **THE FAIL DIRECTION INVERTS between the two halves, and copying `stageHeader`'s nil-handling into a writer is the mirror image of the bug** (`MIS-005`): `stageHeader` asks *"may I KEEP payload already here"* ⇒ unanswerable identity **RETAINS** (clearing on absence of evidence destroys a live `AIOwnershipLease` claim); these three ask *"may I ADD payload"* ⇒ unanswerable identity **WRITES**. Demonstrated mechanically, not asserted — one wrong nil-answer reds the two halves' anchors in OPPOSITE directions (inversion A reds the 3 defect tests with all 6 anchors green; inversion B reds exactly the two "cannot adjudicate" anchors with the defect tests green). Refusals go to `NSELog`, a durable file channel, because a refusal that leaves no trace is how this class stays invisible. ⚠️ **The `AIOwnershipLease` is NOT the fix and never was the serializer** — its predicates are `WHERE id = ? AND aiOwner = ?` and BOTH generations use `.nse`, so it is generation-blind and a predecessor can refresh or release the successor's lease; it gates the right to COMPUTE, not to WRITE (refuted twice, do not re-derive). ⚠️ **A test that is already red POST-fix is red under every inversion and proves nothing** — a harness querying `messageBody.textContent` (a column v70 removed; staged text goes to FTS and the header snippet) produced a false red under BOTH inversions before it was caught; phase 1 now aborts on any failed marker so it cannot be banked
<!-- END VERBATIM ROW 161 -->

---

## Source line 162 — Current → `109-an-enum-with-no-silent-case-does-not-prevent-a-silent-path.md`

<!-- BEGIN VERBATIM ROW 162 -->
🚨 **AN ENUM WITH NO SILENT CASE DOES NOT PREVENT A SILENT PATH — Swift exhaustiveness forces a case to EXIST, not to DO anything** — `SearchView.ResultTapOutcome` carried the comment *"THERE IS DELIBERATELY NO SILENT CASE… a future re-implementation cannot reintroduce silence without adding a case here"*, and that claim was **FALSE AND LOAD-BEARING**: it was the written reason the wiring needed no test. `case .explainRemoteResultNotOnThisDevice: break` compiles, adds no case, removes no case, and restores the exact dead silent tap the type was introduced to abolish. **Disproved by running it, not by arguing**: with the consumer branch replaced by `break`, the ENTIRE old tap suite stayed GREEN (`Test run with 5 tests in 1 suite passed`) — the four `SearchResultTapOutcomeTests` cases pinned the CLASSIFIER's return value while nothing asserted the user ever sees anything, so the system property (*the user sees something*) lived one hop later in `SearchView.swift:450`/`:456`/`:109` and was unpinned. FIXED by `438f632cf` with `TapEffect` + `effect(of:)` — the mapping from outcome to visible consequence becomes a VALUE a test can assert, and `openResult` applies it by unconditional assignment rather than re-deciding in its own `switch`; sibling `presentableRemoteResults` got the same treatment via an injected-fetch seam (`remoteResults(…fetch:)`), because nothing asserted `searchAccount` CALLS the `\Deleted` filter either. ⚠️ **THE BOUNDARY IS STATED, because the claim it replaces was an unfalsifiable absolute (`MIS-019`)**: `effect(of:)` is pure and exhaustively asserted, but `openResult`→`@State` and `searchAccount`→`remoteResults` remain uncovered hops — a REDUCTION IN EXPOSURE, not a proof. **The transferable rule: "the type system makes this impossible" is a claim about the COMPILER and must be checked against what the compiler enforces, not against what the type was designed to express** — Testing rule 12's pin-the-invariant-not-the-mechanism, in the one costume where the mechanism looks like a structural guarantee. `v2final` `e28dd4edb` and shipped `07a4bb703` both return SILENTLY on a nil remote resolve — NONEXISTENT, no shipped behaviour to restore
<!-- END VERBATIM ROW 162 -->

---

## Source line 163 — Current → `108-the-address-problem-has-two-address-spaces-graph-move-response-is-the-copyuid.md`

<!-- BEGIN VERBATIM ROW 163 -->
🚨 **THE ADDRESS PROBLEM HAS TWO ADDRESS SPACES — Graph's `/move` RESPONSE IS THE `COPYUID`** — `59423bb7d` fixed one coordinate system; `ExchangeProvider.moveMessage` was `let _ = try await request("/messages/{id}/move")` and Microsoft Graph returns the moved message **with its new `id`**, so on the default mutable-id scheme (no `Prefer: IdType="ImmutableId"` anywhere in the tree) the next gesture named a dead address, Graph 404'd, `isMessageNotFoundError` read it as exit 2 and `PendingOperation.deleteOne` destroyed a durable intention whose optimistic local move had already landed (`IOS-GRAPH-002`, BLOCKING). FIXED by decoding the response id and carrying it through `moveProvingDestinations -> MoveOutcome` → `ExecutedOperation.provenDestinations` → the **existing** `MessageHeaderRekey.finishMove`; `ProvenDestinationAddress` became provider-neutral (`sourceProviderId`/`destinationProviderId` as `String`, optional epoch). **The `COPYUID` census missed it because it enumerated the MECHANISM, not the PROPERTY** (`MIS-006` ×5, `MIS-IOS-003` ×5) — enumerate by *"which provider ops RETURN the mutated resource and what do we do with the return?"*, then intersect with all three arms: IMAP fixed and fail-CLOSED (its admission gate hid the same root cause), **Gmail genuinely EXEMPT** (`messages.modify` never changes the id), Exchange fail-OPEN. ⚠ Reclassifying the 404 as retryable **without** re-keying is a LANE WEDGE (`buildLanes` keys on `accountId:folderPath:messageId`) — the re-key is what makes retry TERMINATE; `Prefer: IdType="ImmutableId"` changes id format ACCOUNT-WIDE (every `MessageHeader.messageId`, `MessageIdentity.headerId`, `PendingOperation.messageIds`, `aiCacheKey`, `nse_processed_message.id`, Graph `Folder.path`, plus the NSE's separate `Shared/API/GraphAPI`) and is a follow-up ON TOP, never instead. Epoch stays NIL for Graph (an invented stamp is the `.terminalStale` positive disagreement). `v2final` `e28dd4edb` shares the discard and dodges only the consequence via an RFC `$filter` search **banned in v3** (ADR-IOS-068/D4, `IOS-IMAP-002`); shipped `07a4bb703` shares the defect byte-for-byte — A1 step 3 is **INAPPLICABLE, not nonexistent**
<!-- END VERBATIM ROW 163 -->


---

# Second pass — 2026-08-05, source `e3bd752b8`

The 2026-08-05 pass above brought `PROJECT_MEMORY.md` to 24,552 B against a 25,000 B
budget — 1.8% headroom over a ~21 KB structural floor of link rows. Five ordinary topic
additions later the file stood at 25,243 B, over budget again, exactly as that pass
predicted. This second pass routes the eight most verbose remaining *Topic / search terms*
cells by the same mechanical rule, with two rows deliberately exempt: source line 155
(the five-irreversible-wire-operations row, corrected hours earlier and whose keywords are
load-bearing) and its neighbour source line 154, whose *FOUR… plus a FIFTH* phrasing is
confusable with 155's count.

Cells below are byte-for-byte as the index carried them at `e3bd752b8`; some already have a
*first pass* section earlier in this file holding their pre-2026-08-05 wording, so the
markers here are qualified with the source revision. The linked topic file named in each
heading remains the normative source for the underlying knowledge.

---

## Source line 152 — Current → `099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md`

<!-- BEGIN VERBATIM ROW 152 @ e3bd752b8 -->
Persistent NSE log + watchdog partial-result delivery, audit rounds 1–7: `NSELogStore`/`nse.log`, `PartialSignalHolder`; **idle-timer-vs-SSE** root cause (a 26.4 s summary missed the 27 s watchdog by 9 ms); zombie-resume `OneShotFlag.hasFired()`
<!-- END VERBATIM ROW 152 @ e3bd752b8 -->

---

## Source line 156 — Current → `103-await-dbpool-read-is-not-a-short-suspension.md`

<!-- BEGIN VERBATIM ROW 156 @ e3bd752b8 -->
🚨 **`await dbPool.read` is NOT a short suspension** — the ASYNC overload first `await`s `NSEDataBridge.mergeIfStagingPending()`, a **measured 7.6 s** cold-boot write pending on foreground return; check-then-act across it is never BOUNDED
<!-- END VERBATIM ROW 156 @ e3bd752b8 -->

---

## Source line 157 — Current → `104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md`

<!-- BEGIN VERBATIM ROW 157 @ e3bd752b8 -->
🚨 **A latch that AUTHORISES a transition must be HELD across the write** — reading `isDrainingOutbox` then `await`ing proves nothing; ACQUIRE it. `IOS-OUTBOX-006`: `reconcileOutbox` reset a row whose SMTP was on the wire ⇒ no Sent APPEND
<!-- END VERBATIM ROW 157 @ e3bd752b8 -->

---

## Source line 158 — Current → `105-a-print-is-not-production-observability-on-ios.md`

<!-- BEGIN VERBATIM ROW 158 @ e3bd752b8 -->
🚨 **A BARE `print` IS NOT PRODUCTION OBSERVABILITY ON iOS** — no `freopen`/`dup2`, so `stdout` is DISCARDED on device; use a GATED `print` **plus** `BackgroundSyncLogger.logError`. An `isLoggingEnabled()` gate inside a BRANCH CONDITION picks the branch (`MIS-019`)
<!-- END VERBATIM ROW 158 @ e3bd752b8 -->

---

## Source line 159 — Current → `106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md`

<!-- BEGIN VERBATIM ROW 159 @ e3bd752b8 -->
🚨 **A FILTER APPLIED AFTER A QUERY'S `LIMIT` NARROWS THE PAGE INSTEAD OF SELECTING IT** (`6d460aa99`): the label filter ran after `InboxListReader.gather`'s `LIMIT` so `hasMoreMessages` read a survivor count (`IOS-SCROLL-002`, `IOS-BACKFILL-001`)
<!-- END VERBATIM ROW 159 @ e3bd752b8 -->

---

## Source line 160 — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 160 @ e3bd752b8 -->
🚨 **A STAGING KEY THAT NAMES AN ADDRESS MUST RE-PROVE IDENTITY BEFORE IT REUSES PAYLOAD** — `nse_processed_message`'s PK holds a UID, so `stageHeader`'s `ON CONFLICT` spliced a predecessor's payload onto the successor (`IOS-NSE-005`, BLOCKING C3 misattribution)
<!-- END VERBATIM ROW 160 @ e3bd752b8 -->

---

## Source line 163 — Current → `108-the-address-problem-has-two-address-spaces-graph-move-response-is-the-copyuid.md`

<!-- BEGIN VERBATIM ROW 163 @ e3bd752b8 -->
🚨 **THE ADDRESS PROBLEM HAS TWO ADDRESS SPACES — Graph's `/move` RESPONSE IS THE `COPYUID`** — `ExchangeProvider.moveMessage` discarded the new `id`, so Graph 404'd and `PendingOperation.deleteOne` destroyed a durable intention (`IOS-GRAPH-002`, `MIS-006`)
<!-- END VERBATIM ROW 163 @ e3bd752b8 -->

---

## Source line 164 — Current → `112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md`

<!-- BEGIN VERBATIM ROW 164 @ e3bd752b8 -->
🚨 **`uidValidityResetPendingAt` STAYS ARMED ON PURPOSE — NEVER DEMAND PROOF OF TRANSIENCE** — every abort leg leaves the re-drive flag SET; discharge via "a refusal writes nothing" + `crawlWalkWriteAllowed` was the LAST consumer writing under an armed flag (`16ecafd93`)
<!-- END VERBATIM ROW 164 @ e3bd752b8 -->

---

## Pass 3 (2026-08-06 `companion-compact`) — clause-level row trims

These are the **verbatim** index lines that `tabmail-ios/PROJECT_MEMORY.md` carried before the
2026-08-06 `companion-compact` pass. That pass was clause-level: every row was already a single
line, but individual lines had grown into abstracts of their own detail file. Each clause removed
below is either already stated at greater length in the linked `Companion/Memory/` topic — which
remains the normative source — or preserved here. Nothing was summarised, merged, or dropped.

### Source line 131 — `(section preamble)`

<!-- BEGIN VERBATIM ROW 131 (pass 3) -->
These topics exist only on the mature pre-v3 line and are therefore not in `v1.6.38:PROJECT_MEMORY.md`. The bodies are preserved byte-for-byte with their provenance in [`Companion/Memory/ported-manifest.tsv`](../ported-manifest.tsv). They are excluded from the source-document reconstruction manifest.
<!-- END VERBATIM ROW 131 (pass 3) -->

### Source line 143 — `(section preamble)`

<!-- BEGIN VERBATIM ROW 143 (pass 3) -->
Authored after `v1.6.38`, so the pinned compaction has no byte-identical twin. Deliberately **not** rows in [`manifest.tsv`](../manifest.tsv), which reconstructs `v1.6.38:PROJECT_MEMORY.md` exactly; provenance, source line ranges and per-fragment `sha256` are in [`amendments-manifest.tsv`](../amendments-manifest.tsv).
<!-- END VERBATIM ROW 143 (pass 3) -->

### Source line 147 — `094-retained-inline-no-byte-identical-routed-twin.md`

<!-- BEGIN VERBATIM ROW 147 (pass 3) -->
| Historical | Compaction drift list — the retired *Retained inline — no byte-identical routed twin* preamble: why a post-`v1.6.38` amendment can differ from its `Companion/Memory/` twin, and the check-the-routed-twin-before-editing rule | [read in full](094-retained-inline-no-byte-identical-routed-twin.md) |
<!-- END VERBATIM ROW 147 (pass 3) -->

### Source line 148 — `095-v3-provider-id-action-queue-forward-port-resume-state.md`

<!-- BEGIN VERBATIM ROW 148 (pass 3) -->
| Current | v3 provider-id action-queue forward-port — resume state: branch `v3`, HEAD `583de7a5d`, **PAUSED BY OWNER**, never pushed; `PLAN_IOS_REFACTOR_V3.md` routing index; T4.T2 landed, T5.9/T4.T1 next; rules R0–R4; `v2final` PORT/SUBTRACT/INVENTED census | [read in full](../Current/095-v3-provider-id-action-queue-forward-port-resume-state.md) |
<!-- END VERBATIM ROW 148 (pass 3) -->

### Source line 149 — `096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md`

<!-- BEGIN VERBATIM ROW 149 (pass 3) -->
| Current | T1.3 — a NEW gesture fails CLOSED on an unknown UIDVALIDITY epoch: `newGestureRefusedForUnknownEpoch` is a silent no-op (`IOS-EPOCH-001`, C3), never "fixed" back to fail-open; on a refused write RECONCILE FROM THE DATABASE | [read in full](../Current/096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md) |
<!-- END VERBATIM ROW 149 (pass 3) -->

### Source line 150 — `097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md`

<!-- BEGIN VERBATIM ROW 150 (pass 3) -->
| Historical | T4.S6 — **SUPERSEDED v3 intermediate, never implement from it**: `v69` `observedUidValidity` draft stamp, `v72` draft queue epoch; ⛔ the RETRACTED bare mailbox-wide `EXPUNGE` — `expungeScopedToTargets` is UIDPLUS-conditional | [read in full](097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md) |
<!-- END VERBATIM ROW 150 (pass 3) -->

### Source line 151 — `098-imap-external-deletion-blind-spot-amended-adr-ios-051.md`

<!-- BEGIN VERBATIM ROW 151 (pass 3) -->
| Current | IMAP external-deletion blind spot — server-deleted messages linger forever; FIXED by **ADR-IOS-051** Ph1+2: `SyncEngineDeletionReconcile`, `handleVanishedUIDs`, the `deletionReconcileChunkSize` breaker; no CONDSTORE/QRESYNC | [read in full](../Current/098-imap-external-deletion-blind-spot-amended-adr-ios-051.md) |
<!-- END VERBATIM ROW 151 (pass 3) -->

### Source line 154 — `101-isdeletedonserver-has-four-materialisation-paths.md`

<!-- BEGIN VERBATIM ROW 154 (pass 3) -->
| Current | `isDeletedOnServer` — FOUR materialisation paths **plus a FIFTH PRESENTATION path the census missed** (`SearchView.searchAccount` sends no `NOT DELETED`), `IOS-IMAP-001` FIXED `afa7889ee` — state the census NOUN; ⚠️ ERRATUM `deepBackfillFolder` is DEAD CODE | [read in full](../Current/101-isdeletedonserver-has-four-materialisation-paths.md) |
<!-- END VERBATIM ROW 154 (pass 3) -->

### Source line 155 — `102-there-are-four-irreversible-wire-operations-not-one.md`

<!-- BEGIN VERBATIM ROW 155 (pass 3) -->
| Current | ⚠️ **FIVE irreversible wire operations, not one** (FOUR until 2026-08-05; the `…four…` filename is a frozen id, not the count) — `COPYUID`-gated source expunge, **the draft family which DESTROYS a draft** (`deleteDraftStrong`, `saveDraft`, `GmailProvider.deleteDraft`), **plus `CalDAVProvider.deleteEvent`** — `CalDAVClient` sets `httpMethod = "DELETE"`, invisible to a `method: "DELETE"` census, and CalDAV has no trash. Enumerate BOTH spellings. "Never permanently deletes" is FALSE for drafts **and calendar events**. ⚠️ TWO FAMILIES: the five are the **deletion family**; a verb search is blind to the **replacement family** — `CalDAVProvider.splitSeries`'s cap `PUT` destroys every post-split occurrence and IS in the set (not a sixth member); also run `httpMethod = "PUT"` / `method: "PUT"`; `GmailProvider.saveDraft`'s draft PUT is the excluded negative case | [read in full](../Current/102-there-are-four-irreversible-wire-operations-not-one.md) |
<!-- END VERBATIM ROW 155 (pass 3) -->

### Source line 161 — `113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation.md`

<!-- BEGIN VERBATIM ROW 161 (pass 3) -->
| Current | 🚨 a Swift `String` comparison does NOT reproduce SQLite **BINARY** collation and is not even a total order (NFC/NFD are equal in Swift, distinct primary keys in SQLite) — compare `utf8.lexicographicallyPrecedes`; `InboxOrdering`, keyset cursor, `IOS-SCROLL-002` | [read in full](../Current/113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation.md) |
<!-- END VERBATIM ROW 161 (pass 3) -->

### Source line 162 — `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 162 (pass 3) -->
| Current | 🚨 **THE SAME STAGING KEY HAS FOUR WRITERS, AND "SAFE" POINTS THE OPPOSITE WAY FOR THREE** (`IOS-NSE-006`) — all four now call `stagedIdentityPositivelyDiffers`; ⚠️ **THE FAIL DIRECTION INVERTS**: KEEP-payload RETAINS, ADD-payload WRITES | [read in full](../Current/107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md) |
<!-- END VERBATIM ROW 162 (pass 3) -->

### Source line 163 — `109-an-enum-with-no-silent-case-does-not-prevent-a-silent-path.md`

<!-- BEGIN VERBATIM ROW 163 (pass 3) -->
| Current | 🚨 **AN ENUM WITH NO SILENT CASE DOES NOT PREVENT A SILENT PATH** — `ResultTapOutcome`'s "cannot reintroduce silence" comment was FALSE AND LOAD-BEARING (`case …: break` compiles); the old tap suite stayed GREEN under it (`438f632cf`) | [read in full](../Current/109-an-enum-with-no-silent-case-does-not-prevent-a-silent-path.md) |
<!-- END VERBATIM ROW 163 (pass 3) -->

---

# Pass 4 — 2026-08-13 `companion-compact`, source `working-tree`

`tabmail-ios/PROJECT_MEMORY.md` had grown to **31,036 B, 24% over its 25,000 B budget**, almost
entirely in the *Post-`v1.6.38` topics* table, whose cells had again become abstracts rather than
routing lines (one cell alone was **4,957 B**). The index now carries a shortened cell for each row
below; the text here is what those cells were compressed from, **byte-for-byte**, so nothing a past
plan, review prompt, or commit body quoted has become unsearchable.

As in passes 1–3, only the *Topic / search terms* cell is preserved — the `Status` and
`[read in full]` cells were not modified, and the normative detail was always the linked
`Companion/Memory/` topic file named in each heading, never this file.


### Source line 143 — Historical → `094-retained-inline-no-byte-identical-routed-twin.md`

<!-- BEGIN VERBATIM ROW 143 (pass 4) -->
Compaction drift list — why a post-`v1.6.38` amendment can differ from its `Companion/Memory/` twin, and the check-the-routed-twin-before-editing rule
<!-- END VERBATIM ROW 143 (pass 4) -->

### Source line 144 — Current → `095-v3-provider-id-action-queue-forward-port-resume-state.md`

<!-- BEGIN VERBATIM ROW 144 (pass 4) -->
v3 provider-id action-queue forward-port — ✅ **COMPLETE, SHIPPED as v1.7.0 (2026-08-07)**; the `v3` branch is **DELETED and `main` IS that line**; rules **R0/R3 RETIRED** — no mandatory `v2final` consult; ⛔ **`v2final` is preserved history, NOT a reference** (a `v1.6.38` SIBLING that never shipped; in-code `PORT — v2final:…` comments are PROVENANCE only); `PLAN_IOS_REFACTOR_V3.md`
<!-- END VERBATIM ROW 144 (pass 4) -->

### Source line 145 — Current → `096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md`

<!-- BEGIN VERBATIM ROW 145 (pass 4) -->
T1.3 — a NEW gesture fails CLOSED on an unknown UIDVALIDITY epoch: `newGestureRefusedForUnknownEpoch` is a silent no-op (`IOS-EPOCH-001`, C3), never "fixed" back to fail-open
<!-- END VERBATIM ROW 145 (pass 4) -->

### Source line 146 — Historical → `097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md`

<!-- BEGIN VERBATIM ROW 146 (pass 4) -->
T4.S6 — **SUPERSEDED v3 intermediate, never implement from it**: `v69` `observedUidValidity` draft stamp, `v72` draft queue epoch; ⛔ the RETRACTED bare mailbox-wide `EXPUNGE`
<!-- END VERBATIM ROW 146 (pass 4) -->

### Source line 147 — Current → `098-imap-external-deletion-blind-spot-amended-adr-ios-051.md`

<!-- BEGIN VERBATIM ROW 147 (pass 4) -->
IMAP external-deletion blind spot — server-deleted messages linger forever; FIXED by **ADR-IOS-051** Ph1+2: `SyncEngineDeletionReconcile`, `handleVanishedUIDs`, `deletionReconcileChunkSize`
<!-- END VERBATIM ROW 147 (pass 4) -->

### Source line 148 — Current → `099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md`

<!-- BEGIN VERBATIM ROW 148 (pass 4) -->
Persistent NSE log + watchdog partial-result delivery, audit rounds 1–7: `NSELogStore`/`nse.log`, `PartialSignalHolder`; **idle-timer-vs-SSE** root cause; zombie-resume `OneShotFlag.hasFired()`
<!-- END VERBATIM ROW 148 (pass 4) -->

### Source line 149 — Current → `100-two-instant-wake-handoff-elapsed-means-do-it-now.md`

<!-- BEGIN VERBATIM ROW 149 (pass 4) -->
Two-instant wake handoff — deadline elapses between the query and the re-check ⇒ arm nothing; "elapsed" means DO IT NOW (`AccountManager.wakeUpDelay`, `holdUntil`, `IOS-OUTBOX-005`, `UInt64(negative)` traps)
<!-- END VERBATIM ROW 149 (pass 4) -->

### Source line 150 — Current → `101-isdeletedonserver-has-four-materialisation-paths.md`

<!-- BEGIN VERBATIM ROW 150 (pass 4) -->
`isDeletedOnServer` — FOUR materialisation paths **plus a FIFTH PRESENTATION path the census missed** (`SearchView.searchAccount` sends no `NOT DELETED`), `IOS-IMAP-001`; ⚠️ ERRATUM `deepBackfillFolder` is DEAD CODE
<!-- END VERBATIM ROW 150 (pass 4) -->

### Source line 151 — Current → `102-there-are-four-irreversible-wire-operations-not-one.md`

<!-- BEGIN VERBATIM ROW 151 (pass 4) -->
⚠️ **SIX irreversible wire operations at `967e5b3c5`, not one** — the five deletion-family members plus `CalDAVProvider.splitSeries`'s cap `PUT`. Membership is defined by loss of server-side authored content without a reached per-item recovery path, not by a verb. Atomic `UID MOVE` is excluded: success retains each member in the destination and the fork has no destructive fallback. Current lower-bound census A/B/C/D/E = 7/3/5/2/2 (C has 2 live scoped calls + 3 comments); `CLAUDE.md`'s six-member MANTRA is current.
<!-- END VERBATIM ROW 151 (pass 4) -->

### Source line 154 — Current → `105-a-print-is-not-production-observability-on-ios.md`

<!-- BEGIN VERBATIM ROW 154 (pass 4) -->
🚨 a bare `print` is NOT production observability on iOS — `stdout` is DISCARDED on device; use `BackgroundSyncLogger.logError`; a gate inside a BRANCH CONDITION picks the branch (`MIS-019`); **a RESIDUAL RECORD ("not changed: …") is an absolute in humility's clothing** — `f947acb4c`'s named only `ComposeView` while 6 release-executing render-path sinks went unchecked; corrected non-exhaustive list of remaining ungated/unescaped print sinks + `RenderPathLogSinkTests` scope lives here
<!-- END VERBATIM ROW 154 (pass 4) -->

### Source line 162 — Current → `114-both-uidvalidity-redrive-owners-iterate-syncablefolders.md`

<!-- BEGIN VERBATIM ROW 162 (pass 4) -->
🚨 **BOTH UIDVALIDITY RE-DRIVE OWNERS ITERATED `syncableFolders`** (`fullSync` + `imapDeltaSync`), so an armed CUSTOM NON-FAVOURITE folder had NO re-drive — quarantined forever, mail purged; 26 folders / 145,754 rows (85%) on the reference device. `syncFolderMessages` is now the third owner. Count PREDICATES, not call sites
<!-- END VERBATIM ROW 162 (pass 4) -->

### Source line 163 — Current → `115-known-issues-register-is-byte-frozen-and-has-no-append-path.md`

<!-- BEGIN VERBATIM ROW 163 (pass 4) -->
✅ **`KNOWN_ISSUES.md` APPEND PATH — RESOLVED 2026-08-12** (was: byte-frozen, no append path) — `compact_known_issues.rb generate` re-sources from the hash-pinned `known-issues-pre-hierarchy-2026-08-09.txt` whenever it exists, and `verify` byte-compares, so an appended row is `content mismatch` and a new detail file is `orphan detail`. THE MANTRA's "register it in `KNOWN_ISSUES.md`" was unexecutable until `compact_known_issues.rb` gained a strip-before-compare amendment block (`KNOWN-ISSUES-AMENDMENT-BEGIN`/`-END`) plus a non-globbed `KnownIssues/Amendments/` dir — first used by `IOS-IMAP-015`; the 4 unregistered `RRULE UNTIL` residuals (all-day `Z`-drop, `.floating` DTSTART, explicit `all_day` honoured, and the resolving-GET-vs-merge-GET type-of-check/type-of-use race) are recorded there instead
<!-- END VERBATIM ROW 163 (pass 4) -->

### Source line 164 — Current → `116-a-path-component-is-capped-in-nfd-utf16-units-not-bytes-or-characters.md`

<!-- BEGIN VERBATIM ROW 164 (pass 4) -->
🚨 **ATTACHMENT FILENAMES REJECTED, NOT REDUCED** (owner 2026-08-12) — reducer + co-edit twin DELETED; one predicate `AttachmentFilename.isSafeFileComponent` (6 rules), `AttachmentFilenameError` thrown by both `saveAttachments` + `AttachmentPreviewStager.createAttempt`, display via `displayLabel`; message REASON-AGNOSTIC, long-Hangul false rejection ACCEPTED with no breadcrumb; `metaBase`/`afterIndexPrefix` STAY (the merging char is one the STORE adds). Everything below is now the ACCEPTANCE BOUNDARY — read "stripped"/"truncated" as "refused". **A path COMPONENT is capped at 255 NFD UTF-16 units — NOT 255 UTF-8 bytes, NOT 255 `Character`s**, and the two wrong guesses fail in OPPOSITE directions (86×`U+6F22` = 258 bytes STORES; 128×`U+00E9` = 128 characters is REFUSED because APFS decomposes to 256 units). Over-length write = `NSCocoaErrorDomain` 514 / `NSPOSIXErrorDomain` 63 `File name too long`. Bisected on APFS + the simulator, 0/400 randomised-mixed-string disagreements. Overlong attachment filenames are now TRUNCATED (owner, 2026-08-12), stem cut on whole grapheme clusters, extension preserved, budget = `255 - String(Int.max).count - 1 - ".meta".count` = 230 because the `.meta` SIDECAR is the longest derived name (sidecar overflows 5 units before the data file does). ⚠️ also records the CLOSED filename control-strip defect: `CharacterSet.controlCharacters` is **24,970 scalars — NOT Cc, NOT Cc ∪ Cf** (Cc 65 + Cf 170 + 97 Mn + 24,638 unassigned plane-14), so `.subtracting(Cf)` does NOT recover Cc — **ROOT CAUSE: SOME set operators on a BUILT-IN `CharacterSet` materialise it and WHICH IS NOT PREDICTABLE FROM THE EXPRESSION — `.subtracting(CharacterSet())` collapses `controlCharacters` to Cc∪Cf=235 but `.union(CharacterSet())`, `formUnion(empty)` and `.inverted.inverted` PRESERVE 24,970 (same identity, opposite answers); `union(self)`/`intersection(self)` collapse.** Exactly 2 of 20 built-ins are unstable and they move OPPOSITE ways: `controlCharacters` −24,735, **`illegalCharacters` +24,499 (EXPANDS, so `x.subtracting(.illegalCharacters)` is broader than predicted — dangerous for a rejection predicate)**; `nonBaseCharacters` and the other 17 are stable. Bare `controlCharacters` is INCOHERENT in plane 14 — contains `U+E0101` but NOT `U+E0100`/`U+E0102`–`U+E011F`, matching no Unicode property — so a red proof using a GENERIC variation selector had a 143-in-240 chance of proving nothing and blessing the bug; the suite is safe only because its exemplars came from the OBSERVED defect. The `MessageIdentity` RFC-id guard's `whitespacesAndNewlines.union(.controlCharacters)` is only 254 and never reaches plane 14, and it is fail-OPEN at the consumer (no witness ⇒ header KEPT ⇒ address-only auth), so widening it enlarges the witness-less population — the direction `IOS-IDENTITY-001` forbids. Constructed-set unions are exact (`strippedFilenameScalars`=74, re-measured on the SHIPPED expression after a probe verified a MIRROR instead). It stripped `U+200D` ZWJ (flattening `👨‍👩‍👦` to `👨👩👦`) and the `U+E0020`–`U+E007F` TAG chars (Scotland flag → plain black flag at the SAME char count). Narrowed to `strippedFilenameScalars` = Cc ranges + enumerated bidi `U+202A`–`U+202E` / `U+2066`–`U+2069`; ~~RLM/LRM/ALM KEPT~~ — 🚨 **OVERRULED 2026-08-12 `592bd9922`: `U+200E`/`U+200F`/`U+061C` ARE STRIPPED (owner, "strip them everywhere"), because a mark reorders the RUNS rather than reversing one — `"\u{200F}pdf\u{200F}.exe"` renders `exe.pdf`; the KEEP decision was measured but every fixture was `report`-PREFIXED, which anchors paragraph direction and makes the spoof structurally impossible (`MIS-030` recurrence — fixture never held the precondition). `U+2028`/`U+2029` added too: mandatory line breaks, `"invoice.pdf\u{2028}.exe"` hides `.exe` on line 2 (`CTTypesetterSuggestLineBreak` @100,000pt); they are the only two outside Cc. AND every `unassigned` scalar is stripped — swept on APFS, the FS-REFUSED set is EXACTLY the 814,730 unassigned scalars, 0 disagreements either way, `open(2)` raises `EILSEQ`/errno 92, so `"invoice\u{0378}.pdf"` made `saveAttachments` THROW; the narrowing WIDENED that (old bare set covered 24,638, narrowed covers 0, 790,092 never covered). Post-fix sweep: 1,112,064 scalars reduced then written as `<Int.max>_<reduced>.meta`, 0 failures. Shipped set is now 79 scalars. ALSO: length truncation CAN yield `Attachment` — one grapheme cluster wider than the budget (`"a"`+300×`U+0301`+`.pdf`) left no stem and returned `".pdf"`, whose `pathExtension` is EMPTY; the stem now becomes `Attachment` and the extension survives.** `report\u{202E}fdp.exe` renders `reportexe.pdf` (CoreText-measured) so the bidi half must never be re-narrowed; the containment probe was never dependent on the Cf half. The suite's multi-byte test had been BLESSING it via a baseline recomputed from the defect's own predicate
<!-- END VERBATIM ROW 164 (pass 4) -->

---

# Pass 4b — 2026-08-13 `companion-compact`, source `working-tree`

Pass 4 left the index at 25,841 B, still over its 25,000 B budget, so the remaining
*Post-`v1.6.38`* cells were tightened too. Rows already routed by pass 4 are **not** repeated here:
their pre-pass originals are above, and only my own pass-4 replacement text was shortened. The five
cells below had never been routed and are preserved byte-for-byte before trimming.


### Source line 152 — Current → `103-await-dbpool-read-is-not-a-short-suspension.md`

<!-- BEGIN VERBATIM ROW 152 (pass 4b) -->
🚨 `await dbPool.read` is NOT a short suspension — the ASYNC overload first `await`s `NSEDataBridge.mergeIfStagingPending()`, a measured 7.6 s cold-boot write; check-then-act across it is never BOUNDED
<!-- END VERBATIM ROW 152 (pass 4b) -->

### Source line 153 — Current → `104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md`

<!-- BEGIN VERBATIM ROW 153 (pass 4b) -->
🚨 a latch that AUTHORISES a transition must be HELD across the write — reading `isDrainingOutbox` then `await`ing proves nothing; ACQUIRE it (`IOS-OUTBOX-006`, `reconcileOutbox`, no Sent APPEND)
<!-- END VERBATIM ROW 153 (pass 4b) -->

### Source line 155 — Current → `106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md`

<!-- BEGIN VERBATIM ROW 155 (pass 4b) -->
🚨 a filter applied AFTER a query's `LIMIT` narrows the page instead of selecting it — `InboxListReader.gather`, `hasMoreMessages` (`IOS-SCROLL-002`, `IOS-BACKFILL-001`, `6d460aa99`)
<!-- END VERBATIM ROW 155 (pass 4b) -->

### Source line 156 — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 156 (pass 4b) -->
🚨 a staging key that names an ADDRESS must re-prove identity before it reuses payload — `nse_processed_message`'s PK holds a UID, `stageHeader`'s `ON CONFLICT` (`IOS-NSE-005`, C3)
<!-- END VERBATIM ROW 156 (pass 4b) -->

### Source line 157 — Current → `113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation.md`

<!-- BEGIN VERBATIM ROW 157 (pass 4b) -->
🚨 a Swift `String` comparison does NOT reproduce SQLite **BINARY** collation and is not even a total order — compare `utf8.lexicographicallyPrecedes`; `InboxOrdering`, keyset cursor, `IOS-SCROLL-002`
<!-- END VERBATIM ROW 157 (pass 4b) -->

---

# `PROJECT_MEMORY.md` cells and prose (2026-08-20 `companion-compact` pass 5)

`PROJECT_MEMORY.md` was 27,851 B against its 25,000 B budget (+11%). Below are the **verbatim**
*Topic / search terms* cells, and the preamble prose, that the index carried inline before this
pass. Rows 164, 166 and 167 were authored after the 2026-08-13 pass and had never been compacted:
166 and 167 alone were 2.9 KB of an always-loaded file. The index now carries a shortened,
keyword-bearing line for each. Kept byte-for-byte — nothing was summarised, merged, or dropped.

## Source line 133 — Current → `093-the-wrong-message-wire-oracle-is-blind-to-shared-message-id-defects.md`

<!-- BEGIN VERBATIM ROW 133 (pass 5) -->
⚠️ `FakeIMAPServer`'s `wrongMessageViolations` wire oracle is BLIND when target and bystander share an RFC 822 Message-ID — the C3 assertion goes vacuous; pin on the `UID STORE`/`EXPUNGE` log, never UID
<!-- END VERBATIM ROW 133 (pass 5) -->

---

## Source line 144 — Current → `095-v3-provider-id-action-queue-forward-port-resume-state.md`

<!-- BEGIN VERBATIM ROW 144 (pass 5) -->
v3 provider-id action-queue forward-port — ✅ SHIPPED **v1.7.0**; branch `v3` DELETED, `main` IS that line; **R0/R3 RETIRED**; ⛔ `v2final` = never-shipped SIBLING, PROVENANCE only
<!-- END VERBATIM ROW 144 (pass 5) -->

---

## Source line 145 — Current → `096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md`

<!-- BEGIN VERBATIM ROW 145 (pass 5) -->
T1.3 — a NEW gesture fails CLOSED on an unknown UIDVALIDITY epoch: `newGestureRefusedForUnknownEpoch` is a silent no-op (`IOS-EPOCH-001`, C3), never fail-open
<!-- END VERBATIM ROW 145 (pass 5) -->

---

## Source line 148 — Current → `099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md`

<!-- BEGIN VERBATIM ROW 148 (pass 5) -->
Persistent NSE log + watchdog partial delivery, rounds 1–7: `NSELogStore`/`nse.log`, `PartialSignalHolder`; **idle-timer-vs-SSE**; `OneShotFlag.hasFired()`
<!-- END VERBATIM ROW 148 (pass 5) -->

---

## Source line 149 — Current → `100-two-instant-wake-handoff-elapsed-means-do-it-now.md`

<!-- BEGIN VERBATIM ROW 149 (pass 5) -->
Two-instant wake handoff — "elapsed" means DO IT NOW: `AccountManager.wakeUpDelay`, `holdUntil`, `IOS-OUTBOX-005`, `UInt64(negative)` traps
<!-- END VERBATIM ROW 149 (pass 5) -->

---

## Source line 150 — Current → `101-isdeletedonserver-has-four-materialisation-paths.md`

<!-- BEGIN VERBATIM ROW 150 (pass 5) -->
`isDeletedOnServer` — FOUR materialisation paths **plus a FIFTH PRESENTATION path** (`SearchView.searchAccount` sends no `NOT DELETED`), `IOS-IMAP-001`; `deepBackfillFolder` is DEAD CODE
<!-- END VERBATIM ROW 150 (pass 5) -->

---

## Source line 151 — Current → `102-there-are-four-irreversible-wire-operations-not-one.md`

<!-- BEGIN VERBATIM ROW 151 (pass 5) -->
⚠️ **SIX irreversible wire operations at `967e5b3c5`, not one** — deletion family + `CalDAVProvider.splitSeries` cap `PUT`; membership = **no reached per-item recovery**, NOT the verb; census 7/3/5/2/2
<!-- END VERBATIM ROW 151 (pass 5) -->

---

## Source line 152 — Current → `103-await-dbpool-read-is-not-a-short-suspension.md`

<!-- BEGIN VERBATIM ROW 152 (pass 5) -->
🚨 `await dbPool.read` is NOT a short suspension — the ASYNC overload first `await`s `NSEDataBridge.mergeIfStagingPending()` (measured 7.6 s cold boot); check-then-act across it is UNBOUNDED
<!-- END VERBATIM ROW 152 (pass 5) -->

---

## Source line 153 — Current → `104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md`

<!-- BEGIN VERBATIM ROW 153 (pass 5) -->
🚨 a latch that AUTHORISES a transition must be HELD across the write — reading `isDrainingOutbox` then `await`ing proves nothing; ACQUIRE it (`IOS-OUTBOX-006`, `reconcileOutbox`)
<!-- END VERBATIM ROW 153 (pass 5) -->

---

## Source line 154 — Current → `105-a-print-is-not-production-observability-on-ios.md`

<!-- BEGIN VERBATIM ROW 154 (pass 5) -->
🚨 a bare `print` is NOT production observability on iOS — `stdout` is DISCARDED on device; use `BackgroundSyncLogger.logError`; a gate inside a BRANCH CONDITION picks the branch (`MIS-019`); **a RESIDUAL RECORD is an absolute in humility's clothing**
<!-- END VERBATIM ROW 154 (pass 5) -->

---

## Source line 155 — Current → `106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md`

<!-- BEGIN VERBATIM ROW 155 (pass 5) -->
🚨 a filter applied AFTER a query's `LIMIT` narrows the page instead of selecting it — `InboxListReader.gather`, `hasMoreMessages` (`IOS-SCROLL-002`, `IOS-BACKFILL-001`)
<!-- END VERBATIM ROW 155 (pass 5) -->

---

## Source line 156 — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 156 (pass 5) -->
🚨 a staging key that names an ADDRESS must re-prove identity before it reuses payload — `nse_processed_message`'s PK holds a UID, `stageHeader`'s `ON CONFLICT` (`IOS-NSE-005`, C3)
<!-- END VERBATIM ROW 156 (pass 5) -->

---

## Source line 157 — Current → `113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation.md`

<!-- BEGIN VERBATIM ROW 157 (pass 5) -->
🚨 a Swift `String` comparison does NOT reproduce SQLite **BINARY** collation and is not a total order — use `utf8.lexicographicallyPrecedes`; `InboxOrdering`, keyset cursor, `IOS-SCROLL-002`
<!-- END VERBATIM ROW 157 (pass 5) -->

---

## Source line 158 — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 158 (pass 5) -->
🚨 **THE SAME STAGING KEY HAS FOUR WRITERS, AND "SAFE" POINTS THE OPPOSITE WAY FOR THREE** (`IOS-NSE-006`, `stagedIdentityPositivelyDiffers`) — ⚠️ **THE FAIL DIRECTION INVERTS**
<!-- END VERBATIM ROW 158 (pass 5) -->

---

## Source line 159 — Current → `109-an-enum-with-no-silent-case-does-not-prevent-a-silent-path.md`

<!-- BEGIN VERBATIM ROW 159 (pass 5) -->
🚨 **AN ENUM WITH NO SILENT CASE DOES NOT PREVENT A SILENT PATH** — `ResultTapOutcome`'s "cannot reintroduce silence" comment was FALSE AND LOAD-BEARING (`case …: break` compiles)
<!-- END VERBATIM ROW 159 (pass 5) -->

---

## Source line 160 — Current → `108-the-address-problem-has-two-address-spaces-graph-move-response-is-the-copyuid.md`

<!-- BEGIN VERBATIM ROW 160 (pass 5) -->
🚨 THE ADDRESS PROBLEM HAS TWO ADDRESS SPACES — Graph's `/move` response IS the `COPYUID`; `ExchangeProvider.moveMessage` discarded the new `id` (`IOS-GRAPH-002`, `MIS-006`)
<!-- END VERBATIM ROW 160 (pass 5) -->

---

## Source line 161 — Current → `112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md`

<!-- BEGIN VERBATIM ROW 161 (pass 5) -->
🚨 `uidValidityResetPendingAt` STAYS ARMED ON PURPOSE — never demand proof of transience; `crawlWalkWriteAllowed` was the LAST consumer writing under an armed flag (`16ecafd93`)
<!-- END VERBATIM ROW 161 (pass 5) -->

---

## Source line 162 — Current → `114-both-uidvalidity-redrive-owners-iterate-syncablefolders.md`

<!-- BEGIN VERBATIM ROW 162 (pass 5) -->
🚨 **BOTH UIDVALIDITY RE-DRIVE OWNERS ITERATED `syncableFolders`** (`fullSync` + `imapDeltaSync`) — an armed CUSTOM NON-FAVOURITE folder had NO re-drive: quarantined, mail purged (26 folders / 145,754 rows). Count PREDICATES
<!-- END VERBATIM ROW 162 (pass 5) -->

---

## Source line 163 — Current → `115-known-issues-register-is-byte-frozen-and-has-no-append-path.md`

<!-- BEGIN VERBATIM ROW 163 (pass 5) -->
✅ **`KNOWN_ISSUES.md` APPEND PATH — RESOLVED 2026-08-12** — strip-before-compare `KNOWN-ISSUES-AMENDMENT-BEGIN`/`-END` + non-globbed `KnownIssues/Amendments/` dir; first user `IOS-IMAP-015`; the 4 `RRULE UNTIL` residuals live there
<!-- END VERBATIM ROW 163 (pass 5) -->

---

## Source line 164 — Current → `116-a-path-component-is-capped-in-nfd-utf16-units-not-bytes-or-characters.md`

<!-- BEGIN VERBATIM ROW 164 (pass 5) -->
🚨 **ATTACHMENT FILENAMES REJECTED, NOT REDUCED** — `AttachmentFilename.isSafeFileComponent`, `AttachmentFilenameError`; **255 NFD UTF-16 unit** path-component cap (NOT bytes, NOT `Character`s); `CharacterSet.controlCharacters` = 24,970 scalars and BUILT-IN set operators materialise it unpredictably; `strippedFilenameScalars` = 79
<!-- END VERBATIM ROW 164 (pass 5) -->

---

## Source line 166 — Current → `118-trial-ended-is-derived-never-a-new-whoami-flag.md`

<!-- BEGIN VERBATIM ROW 166 (pass 5) -->
🚨 **"TRIAL ENDED" IS DERIVED, NEVER A NEW `/whoami` FLAG** — `has_subscription:false` + the `trial` KEY present (value may be **explicit `null`**; `trialKeyPresent`, `container.contains`) ; `trial_expired`/`trial_blocked` were CUT as reinvention. `.active` REQUIRES `plan_tier == "Trial"` — a legacy Stripe/Apple **CARD trial** also carries a `trial` object and must stay a plain subscriber. `trial_end` is `string \| number` upstream so `TrialInfo` decodes LENIENTLY (a String would fail the WHOLE parse). `AccountInfo.trialState(now:)`, `TrialState.noTrial` (not `.none`), `AISubscriptionGate.apply`/`trialHasEnded` (bare `openGate`/`closeGate` must NOT write it; flag is GLOBAL not account-scoped; test restore order flag-BEFORE-isActive), `ZeroBudgetPlan` per-plan quota captions, `dailyQuotaChartDenominator` explicit-zero budget, `displayPlanName` `Trial → "Free Trial"`, signup trial, plan picker, account deletion `case "signup" → .scheduleDeletion`; ⚠️ intro-offer machinery (`PlanCardIntroOffer`/`suppressesIntroOffer`/`checkTrialEligibility`/`showsTrialBadge`) DELETED 2026-08-19 issue #55 — survivor `PlanCardCTA.buttonLabel`
<!-- END VERBATIM ROW 166 (pass 5) -->

---

## Source line 167 — Current → `119-post-login-routing-waits-for-an-authoritative-whoami.md`

<!-- BEGIN VERBATIM ROW 167 (pass 5) -->
🚨 **POST-LOGIN ROUTING WAITS FOR AN AUTHORITATIVE `/whoami`** (issue #56: active subscriber sent to paywall; already-configured Gmail re-offered) — `PendingPlanNavigationLatch` is the SOLE owner of `pending_plan_navigation` (4-case `consume`: `noLatch` ≠ `clearedWithoutNavigation`; `waitForAuthoritativeGate` PRESERVES the latch; `clear` writes explicit `false` never `removeObject`), `AISubscriptionGate.lastAuthoritativeApplyAt` in-memory freshness marker (ONLY `apply` stamps; `openGate`/`closeGate`/`refreshAfterLocalPurchase` do NOT; `noteSignedOut` clears on sign-out), `MailNavigationView` consumes via `.onChange(initial: true)` not timers, NO new `fetchAccountInfo` sites (118 census + ADR-IOS-044 hold); `Account.existing(forEmail:provider:in:)` = single existing-account predicate — CASE-FOLDED (`folding(.caseInsensitive)`, NOT `lowercased()`: final-sigma) + deterministic under wild duplicates (mail row > calendarOnly, then oldest) — for login add-gate + `setupOAuthAccount` dedupe + `CalendarSetupView` (IDENTITY equality, deliberately diverges from BINARY — NOT a topic-113 ordering case; calendarOnly rows MATCH, upgrade arm clears `calendarOnly` + promotes primary; never substitute `navigationStore.accounts`); `signInGeneration`/`applyIfCurrentEpoch` epoch guard on ALL 3 fetch→apply pipelines (RootView, SyncScheduler, AccountDashboardView — stale cross-account /whoami never applies); `recordAfterAIConsent` requires AUTHORITY to disarm; signed-out `waitForAuthoritativeGate` restores inbox, latch survives
<!-- END VERBATIM ROW 167 (pass 5) -->

---

## Source lines 139-139 — preamble prose

<!-- BEGIN VERBATIM LINES 139-139 (pass 5) -->
```text
Authored after `v1.6.38`, so deliberately **not** rows in [`manifest.tsv`](Companion/Memory/manifest.tsv); provenance, source line ranges and per-fragment `sha256` in [`amendments-manifest.tsv`](Companion/Memory/amendments-manifest.tsv).
```
<!-- END VERBATIM LINES 139-139 (pass 5) -->

---

## Source lines 127-127 — preamble prose

<!-- BEGIN VERBATIM LINES 127-127 (pass 5) -->
```text
Pre-v3-line topics absent from `v1.6.38:PROJECT_MEMORY.md`; bodies preserved byte-for-byte, provenance in [`ported-manifest.tsv`](Companion/Memory/ported-manifest.tsv).
```
<!-- END VERBATIM LINES 127-127 (pass 5) -->

---

## Source lines 119-119 — preamble prose

<!-- BEGIN VERBATIM LINES 119-119 (pass 5) -->
```text
These files preserve source history. Read them when a current topic, ADR, plan, or shipped-release comparison points to the older design.
```
<!-- END VERBATIM LINES 119-119 (pass 5) -->

---

## Source lines 11-19 — preamble prose

<!-- BEGIN VERBATIM LINES 11-19 (pass 5) -->
```text
**This file is a router, not an archive.** Every topic below is preserved in full under
[`Companion/Memory/`](Companion/Memory/manifest.tsv) (`sha256` per fragment); load only the topics
your task mechanically matches. Routing protocol — derive terms → `rg -ni` → read in full → enumerate
in the brief → update the detail — is **normative in root [`../CLAUDE.md`](../CLAUDE.md) § *Companion
Routing***; this file's own wording is preserved in
[`Companion/Process/Current/project-memory-index-usage-protocol.md`](Companion/Process/Current/project-memory-index-usage-protocol.md).

Current entries govern. Historical entries preserve evidence but do not override current rules or active ADRs.

```
<!-- END VERBATIM LINES 11-19 (pass 5) -->

---

# `PROJECT_MEMORY.md` cells (2026-08-20 `companion-compact` pass 5b)

Pass 5 landed the file at 25,288 B — still 288 B over its 25,000 B budget. This sub-pass
shortens the remaining over-length *Topic* cells of the forward-ported and post-`v1.6.38`
tables. **Line numbers below are post-pass-5**, so a Stage 4a rebuild must undo 5b BEFORE
pass 5. Kept byte-for-byte — nothing was summarised, merged, or dropped.

⚠️ **The Current-topics table's titles were deliberately NOT touched.** `verify`'s
*"memory routing: 91 detailed fragments, each title bound to exactly one manifest route and
index row"* check binds each of those titles to `Companion/Memory/manifest.tsv`; shortening
one fails with `memory index route differs from manifest`. Proven here by doing it and
reverting.

**Structural note for the next pass: this index is at its practical floor.** 119 routed
topics each cost ~85-110 B of `[read in full](Companion/Memory/…)` path plus a status cell —
roughly 14 KB that no compaction can remove without renaming routed files, which would
invalidate the manifests and the 524 tracked `Companion/…` pointers `verify` checks. Against
a 25,000 B budget that leaves about one row of slack; consider raising this file's budget
rather than thinning its search surface further.

## Source line 129 (post-pass-5) — Historical → `090-historical-intention-journal-fold-at-drain-adr-ios-058-2026-07-11-queue.md`

<!-- BEGIN VERBATIM ROW 129 (pass 5b) -->
HISTORICAL — Intention journal + fold-at-drain (ADR-IOS-058, 2026-07-11; queue/Undo mechanics superseded by ADR-IOS-060)
<!-- END VERBATIM ROW 129 (pass 5b) -->

---

## Source line 131 (post-pass-5) — Current → `093-the-wrong-message-wire-oracle-is-blind-to-shared-message-id-defects.md`

<!-- BEGIN VERBATIM ROW 131 (pass 5b) -->
⚠️ `FakeIMAPServer`'s `wrongMessageViolations` wire oracle is BLIND when target and bystander share an RFC 822 Message-ID — the C3 assertion goes vacuous; pin on the `UID STORE`/`EXPUNGE` log
<!-- END VERBATIM ROW 131 (pass 5b) -->

---

## Source line 141 (post-pass-5) — Historical → `094-retained-inline-no-byte-identical-routed-twin.md`

<!-- BEGIN VERBATIM ROW 141 (pass 5b) -->
Compaction drift list — a post-`v1.6.38` amendment can differ from its `Companion/Memory/` twin; check the routed twin BEFORE editing
<!-- END VERBATIM ROW 141 (pass 5b) -->

---

## Source line 142 (post-pass-5) — Current → `095-v3-provider-id-action-queue-forward-port-resume-state.md`

<!-- BEGIN VERBATIM ROW 142 (pass 5b) -->
v3 provider-id action-queue forward-port — ✅ SHIPPED **v1.7.0**; branch `v3` DELETED, `main` IS that line; **R0/R3 RETIRED**; ⛔ `v2final` = never-shipped SIBLING
<!-- END VERBATIM ROW 142 (pass 5b) -->

---

## Source line 143 (post-pass-5) — Current → `096-t1-3-new-gesture-fails-closed-on-unknown-uidvalidity-epoch.md`

<!-- BEGIN VERBATIM ROW 143 (pass 5b) -->
T1.3 — a NEW gesture fails CLOSED on an unknown UIDVALIDITY epoch: `newGestureRefusedForUnknownEpoch` is a silent no-op (`IOS-EPOCH-001`, C3)
<!-- END VERBATIM ROW 143 (pass 5b) -->

---

## Source line 144 (post-pass-5) — Historical → `097-t4-s6-follow-up-superseded-v3-intermediate-draft-epoch-stamp.md`

<!-- BEGIN VERBATIM ROW 144 (pass 5b) -->
T4.S6 — ⛔ **SUPERSEDED v3 intermediate, never implement from it**: `v69`/`v72` draft epoch stamps; the RETRACTED bare mailbox-wide `EXPUNGE`
<!-- END VERBATIM ROW 144 (pass 5b) -->

---

## Source line 145 (post-pass-5) — Current → `098-imap-external-deletion-blind-spot-amended-adr-ios-051.md`

<!-- BEGIN VERBATIM ROW 145 (pass 5b) -->
IMAP external-deletion blind spot — server-deleted messages linger forever; FIXED by **ADR-IOS-051** Ph1+2: `SyncEngineDeletionReconcile`, `handleVanishedUIDs`
<!-- END VERBATIM ROW 145 (pass 5b) -->

---

## Source line 146 (post-pass-5) — Current → `099-persistent-nse-log-file-watchdog-partial-delivery-audit-rounds.md`

<!-- BEGIN VERBATIM ROW 146 (pass 5b) -->
Persistent NSE log + watchdog partial delivery, rounds 1–7: `NSELogStore`/`nse.log`, `PartialSignalHolder`; **idle-timer-vs-SSE**; `OneShotFlag.hasFired()`
<!-- END VERBATIM ROW 146 (pass 5b) -->

---

## Source line 147 (post-pass-5) — Current → `100-two-instant-wake-handoff-elapsed-means-do-it-now.md`

<!-- BEGIN VERBATIM ROW 147 (pass 5b) -->
Two-instant wake handoff — "elapsed" means DO IT NOW: `AccountManager.wakeUpDelay`, `holdUntil`, `IOS-OUTBOX-005`, `UInt64(negative)` traps
<!-- END VERBATIM ROW 147 (pass 5b) -->

---

## Source line 148 (post-pass-5) — Current → `101-isdeletedonserver-has-four-materialisation-paths.md`

<!-- BEGIN VERBATIM ROW 148 (pass 5b) -->
`isDeletedOnServer` — FOUR materialisation paths **plus a FIFTH PRESENTATION path** (`SearchView.searchAccount` sends no `NOT DELETED`), `IOS-IMAP-001`
<!-- END VERBATIM ROW 148 (pass 5b) -->

---

## Source line 149 (post-pass-5) — Current → `102-there-are-four-irreversible-wire-operations-not-one.md`

<!-- BEGIN VERBATIM ROW 149 (pass 5b) -->
⚠️ **SIX irreversible wire operations at `967e5b3c5`, not one** — deletion family + `CalDAVProvider.splitSeries` cap `PUT`; membership = **no reached per-item recovery**, NOT the verb
<!-- END VERBATIM ROW 149 (pass 5b) -->

---

## Source line 150 (post-pass-5) — Current → `103-await-dbpool-read-is-not-a-short-suspension.md`

<!-- BEGIN VERBATIM ROW 150 (pass 5b) -->
🚨 `await dbPool.read` is NOT a short suspension — the ASYNC overload first `await`s `NSEDataBridge.mergeIfStagingPending()` (7.6 s cold boot); check-then-act is UNBOUNDED
<!-- END VERBATIM ROW 150 (pass 5b) -->

---

## Source line 151 (post-pass-5) — Current → `104-a-latch-that-authorises-a-transition-must-be-held-across-the-write.md`

<!-- BEGIN VERBATIM ROW 151 (pass 5b) -->
🚨 a latch that AUTHORISES a transition must be HELD across the write — reading `isDrainingOutbox` then `await`ing proves nothing (`IOS-OUTBOX-006`, `reconcileOutbox`)
<!-- END VERBATIM ROW 151 (pass 5b) -->

---

## Source line 152 (post-pass-5) — Current → `105-a-print-is-not-production-observability-on-ios.md`

<!-- BEGIN VERBATIM ROW 152 (pass 5b) -->
🚨 a bare `print` is NOT production observability on iOS — `stdout` is DISCARDED on device; use `BackgroundSyncLogger.logError`; **a RESIDUAL RECORD is an absolute in humility's clothing**
<!-- END VERBATIM ROW 152 (pass 5b) -->

---

## Source line 153 (post-pass-5) — Current → `106-a-filter-after-the-limit-narrows-the-page-instead-of-selecting-it.md`

<!-- BEGIN VERBATIM ROW 153 (pass 5b) -->
🚨 a filter applied AFTER a query's `LIMIT` narrows the page instead of selecting it — `InboxListReader.gather`, `hasMoreMessages` (`IOS-SCROLL-002`, `IOS-BACKFILL-001`)
<!-- END VERBATIM ROW 153 (pass 5b) -->

---

## Source line 154 (post-pass-5) — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 154 (pass 5b) -->
🚨 a staging key that names an ADDRESS must re-prove identity before reusing payload — `nse_processed_message` PK holds a UID, `stageHeader` `ON CONFLICT` (`IOS-NSE-005`, C3)
<!-- END VERBATIM ROW 154 (pass 5b) -->

---

## Source line 155 (post-pass-5) — Current → `113-a-swift-string-comparison-does-not-reproduce-sqlite-binary-collation.md`

<!-- BEGIN VERBATIM ROW 155 (pass 5b) -->
🚨 a Swift `String` comparison does NOT reproduce SQLite **BINARY** collation — use `utf8.lexicographicallyPrecedes`; `InboxOrdering`, keyset cursor, `IOS-SCROLL-002`
<!-- END VERBATIM ROW 155 (pass 5b) -->

---

## Source line 156 (post-pass-5) — Current → `107-a-staging-key-that-names-an-address-must-re-prove-identity-before-reusing-payload.md`

<!-- BEGIN VERBATIM ROW 156 (pass 5b) -->
🚨 **THE SAME STAGING KEY HAS FOUR WRITERS, AND "SAFE" POINTS THE OPPOSITE WAY FOR THREE** (`IOS-NSE-006`, `stagedIdentityPositivelyDiffers`) — **THE FAIL DIRECTION INVERTS**
<!-- END VERBATIM ROW 156 (pass 5b) -->

---

## Source line 157 (post-pass-5) — Current → `109-an-enum-with-no-silent-case-does-not-prevent-a-silent-path.md`

<!-- BEGIN VERBATIM ROW 157 (pass 5b) -->
🚨 **AN ENUM WITH NO SILENT CASE DOES NOT PREVENT A SILENT PATH** — `ResultTapOutcome`'s "cannot reintroduce silence" comment was FALSE AND LOAD-BEARING (`case …: break`)
<!-- END VERBATIM ROW 157 (pass 5b) -->

---

## Source line 158 (post-pass-5) — Current → `108-the-address-problem-has-two-address-spaces-graph-move-response-is-the-copyuid.md`

<!-- BEGIN VERBATIM ROW 158 (pass 5b) -->
🚨 THE ADDRESS PROBLEM HAS TWO ADDRESS SPACES — Graph's `/move` response IS the `COPYUID`; `ExchangeProvider.moveMessage` discarded the new `id` (`IOS-GRAPH-002`, `MIS-006`)
<!-- END VERBATIM ROW 158 (pass 5b) -->

---

## Source line 159 (post-pass-5) — Current → `112-uidvalidityresetpendingat-is-a-redrive-flag-that-stays-armed-on-purpose.md`

<!-- BEGIN VERBATIM ROW 159 (pass 5b) -->
🚨 `uidValidityResetPendingAt` STAYS ARMED ON PURPOSE — never demand proof of transience; `crawlWalkWriteAllowed` was the LAST consumer writing under an armed flag (`16ecafd93`)
<!-- END VERBATIM ROW 159 (pass 5b) -->

---

## Source line 160 (post-pass-5) — Current → `114-both-uidvalidity-redrive-owners-iterate-syncablefolders.md`

<!-- BEGIN VERBATIM ROW 160 (pass 5b) -->
🚨 **BOTH UIDVALIDITY RE-DRIVE OWNERS ITERATED `syncableFolders`** (`fullSync` + `imapDeltaSync`) — an armed CUSTOM NON-FAVOURITE folder had NO re-drive: 26 folders / 145,754 rows. Count PREDICATES
<!-- END VERBATIM ROW 160 (pass 5b) -->

---

## Source line 161 (post-pass-5) — Current → `115-known-issues-register-is-byte-frozen-and-has-no-append-path.md`

<!-- BEGIN VERBATIM ROW 161 (pass 5b) -->
✅ **`KNOWN_ISSUES.md` APPEND PATH — RESOLVED 2026-08-12** — strip-before-compare `KNOWN-ISSUES-AMENDMENT-BEGIN`/`-END` + non-globbed `KnownIssues/Amendments/`; first user `IOS-IMAP-015`
<!-- END VERBATIM ROW 161 (pass 5b) -->

---

## Source line 162 (post-pass-5) — Current → `116-a-path-component-is-capped-in-nfd-utf16-units-not-bytes-or-characters.md`

<!-- BEGIN VERBATIM ROW 162 (pass 5b) -->
🚨 **ATTACHMENT FILENAMES REJECTED, NOT REDUCED** — `AttachmentFilename.isSafeFileComponent`, `AttachmentFilenameError`; **255 NFD UTF-16 unit** path-component cap (NOT bytes, NOT `Character`s)
<!-- END VERBATIM ROW 162 (pass 5b) -->

---

## Source line 163 (post-pass-5) — Current → `117-swiftmail-move-post-completion-contract.md`

<!-- BEGIN VERBATIM ROW 163 (pass 5b) -->
SwiftMail PR #208 MOVE post-completion contract — typed partial completion is non-retryable; retain COPYUID and reconcile both folders
<!-- END VERBATIM ROW 163 (pass 5b) -->

---

## Source line 164 (post-pass-5) — Current → `118-trial-ended-is-derived-never-a-new-whoami-flag.md`

<!-- BEGIN VERBATIM ROW 164 (pass 5b) -->
🚨 **"TRIAL ENDED" IS DERIVED, NEVER A NEW `/whoami` FLAG** — `has_subscription:false` + the `trial` KEY present (may be explicit `null`; `trialKeyPresent`); `.active` REQUIRES `plan_tier == "Trial"`, so a legacy Stripe/Apple **CARD trial** stays a plain subscriber; `AccountInfo.trialState(now:)`, `TrialState.noTrial`, `AISubscriptionGate.trialHasEnded`; intro-offer machinery DELETED (issue #55)
<!-- END VERBATIM ROW 164 (pass 5b) -->

---

## Source line 165 (post-pass-5) — Current → `119-post-login-routing-waits-for-an-authoritative-whoami.md`

<!-- BEGIN VERBATIM ROW 165 (pass 5b) -->
🚨 **POST-LOGIN ROUTING WAITS FOR AN AUTHORITATIVE `/whoami`** (issue #56: active subscriber sent to paywall; configured Gmail re-offered) — `PendingPlanNavigationLatch` / `pending_plan_navigation`, `AISubscriptionGate.lastAuthoritativeApplyAt`, `Account.existing(forEmail:provider:in:)` CASE-FOLDED, `signInGeneration`/`applyIfCurrentEpoch`
<!-- END VERBATIM ROW 165 (pass 5b) -->

---

## Source line 161 (post-pass-5 numbering; pass 7 at a3ac432e5) — Current → `118-trial-ended-is-derived-never-a-new-whoami-flag.md`

<!-- BEGIN VERBATIM ROW 161 (pass 7) -->
🚨 **"TRIAL ENDED" IS DERIVED, NEVER A NEW `/whoami` FLAG** — `has_subscription:false` + the `trial` KEY present; `.active` REQUIRES `plan_tier == "Trial"` (a legacy **CARD trial** stays a plain subscriber); `AccountInfo.trialState(now:)`, `AISubscriptionGate.trialHasEnded`; intro-offer DELETED (#55)
<!-- END VERBATIM ROW 161 (pass 7) -->

---

## Source line 162 (post-pass-5 numbering; pass 7 at a3ac432e5) — Current → `119-post-login-routing-waits-for-an-authoritative-whoami.md`

<!-- BEGIN VERBATIM ROW 162 (pass 7) -->
🚨 **POST-LOGIN ROUTING WAITS FOR AN AUTHORITATIVE `/whoami`** (issue #56) — `PendingPlanNavigationLatch` / `pending_plan_navigation`, `AISubscriptionGate.lastAuthoritativeApplyAt`, `Account.existing(forEmail:provider:in:)` CASE-FOLDED, `signInGeneration`/`applyIfCurrentEpoch`
<!-- END VERBATIM ROW 162 (pass 7) -->

---

## Source line 165 (post-pass-5 numbering; pass 7 at a3ac432e5) — Current → `123-a-durable-write-to-a-mirrored-identity-column-must-refresh-the-nse-mirrors.md`

<!-- BEGIN VERBATIM ROW 165 (pass 7) -->
🚨 **A DURABLE WRITE TO A MIRRORED IDENTITY COLUMN MUST REFRESH THE NSE MIRRORS** — `nse.accountMap`/`nse.imapAccounts` are the extension's ONLY resolver; `addIMAPAccount`/`addICloudAccount` refreshed neither, so `handleIMAPReconnect` early-returned till cold launch. `mirrorAccountIdentity()` never a half; `startForegroundPolling` re-derives ungated at `.medium`; removal clears pre-commit AND converges post-commit; `calendarOnly` never wins an address; straddle = `IOS-NSE-008`
<!-- END VERBATIM ROW 165 (pass 7) -->

---

## Source line 166 (post-pass-5 numbering; pass 7 at a3ac432e5) — Current → `124-ordinary-sign-out-releases-the-device-push-registration-and-ends-the-auth-session.md`

<!-- BEGIN VERBATIM ROW 166 (pass 7) -->
🚨 **ORDINARY SIGN-OUT RELEASES THE DEVICE PUSH REGISTRATION AND ENDS THE AUTH SESSION** — `TabMailAuthService.signOut()` runs `unregisterDeviceForSignOut()` FIRST (the worker's check needs the live session), then GoTrue `logout?scope=local` — **BOTH legs always**, the old "only after a successful release" coupling is RETIRED; ONE identity chokepoint `guard getSession()?.userId == subject` after `validToken()` so a mid-flush sign-in makes the handshake REFUSE; one bound `PushConfig.signOutHandshakeTimeoutSeconds` with `guard !Task.isCancelled` between the legs; handshake Task cancelled BEFORE `completeSession`; 401 silent; release-failure log uses `\(error)` not `localizedDescription`; `unregisterDeviceForSignOut`'s cache clears sit in a `defer` and `lastDeviceTokenKey` SURVIVES; never reuse `unregisterDeviceForReset`; sign-in re-registers via `TabMailAuthService.restorePushRegistrationAfterSignIn()` from RootView's `.tabMailDidSignIn` receiver; account-deletion and "account no longer available" call `completeSession` directly and never reach `signOut()`; supersedes IOS-PUSH-001 §3; push#42; `SignOutHandshakeTests`
<!-- END VERBATIM ROW 166 (pass 7) -->
