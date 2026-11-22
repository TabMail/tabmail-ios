
## ADR-IOS-065: Undo-Send close decision — restore the shipped prompt without rotating the epoch

**Date:** 2026-07-26. **Spec:** the close-state design.

**Status:** **Superseded on v3 by saving the draft when Undo Send is confirmed (#1086).** Why: the
email returns to Drafts at once, as most mail clients do, so no close prompt is needed.
- `PendingSendService.undo()`'s confirmed arm calls
  `AccountManager.discardOutboxMessageReturningDraftConfirmed`, which in ONE synchronous write (the Undo
  tap's own turn, before the drain's claim) cancels the held Outbox row and, in a savepoint, saves the
  kept row at its own generation (`DraftStore.admitSave` with that generation as both new and expected,
  so it neither rotates nor is re-minted) and admits it to Drafts (`admitDraftToDrafts`, the database
  half of `queueDraftSave`). No committed state has the Outbox row gone and the message half-returned.
- The Drafts entry and the server save carry the words that were sent, also over an older server copy.
  Closing without typing just closes; editing afterwards is editing an ordinary draft.
- If the savepoint fails, the cancellation still commits and the compose reopens as unsaved
  (`ReopenSnapshot.returnedToDrafts == false` -> `prefillTreatAsUnsavedChanges`), so Close shows the
  existing save prompt. A failure followed by the process ending before the user acts is tracked as a
  P4 to measure (#1091).
- A draft already uploaded keeps its one Drafts entry: the admission updates the entry under the row's
  server id (the same exact header id `queueDraftDelete` derives) instead of adding a placeholder. This
  also fixes the duplicate on an offline edit-save. Gmail's uploaded entry is keyed by the contained
  message id, which the row does not store, so Gmail still gets a placeholder (#1094).
- The close decision is the pure function `ComposeDraftGuards.closeDecision(CloseState)`, which the
  compose's Close calls. `CloseState` carries the read state, the fields as loaded, the fields now,
  `loadedIsUnsaved`, `hasContent` and any unsettled work (an attachment still being prepared, or a
  visible suggestion). The `loadedIsUnsaved` rule: unsaved content compares against an empty baseline,
  so loaded content closed untouched asks to save; otherwise the fields are compared with what was
  loaded. This replaces the `.promptSave(.readmitRetained)` rule below. The caller supplies
  `hasContent` because it depends on half-typed recipient fields and attachment state that `Baseline`
  does not hold. Every outcome then comes from the unchanged `ComposeDraftGuards.closeAction`.
- The close prompt and its wording are unchanged. Pinned by `UndoSendReturnsToDraftsTests` and
  `UploadedDraftSingleEntryTests`.

The text below is the original 2026-07-26 decision, kept as written.

**Context.** After Undo Send, closing compose without typing **silently discarded the user's draft**. Send initiation removes the Drafts header and admits a `.deleteDraft` for the server copy; nothing restored either. `UndoReopenCompose` passes `prefillTreatAsUnsavedChanges: true` AND `prefillDraftId`, but with the retained row present the row-load branch snapshotted the loaded content as baseline and returned before reaching the guard honouring that flag — so `hasChanges` was false and the close resolved to `.dismiss`.

At `v1.6.38` this was impossible: `undo()` **deleted** the Draft row, making the reopen prefill-based with no baseline, so close prompted and the save recreated both copies. Retaining the row is a deliberate later improvement (it preserves `serverDraftId`/`rfc822`/`serverPushStatus` and survives the crash window) — but it removed that mechanism without replacing it.

**Decision.** The close decision moves into production code that owns the comparison with the loaded content, and every outcome delegates to the unchanged `ComposeDraftGuards.closeAction`, so the two cannot drift. (The reducer type and the `.promptSave(.readmitRetained)` rule this paragraph originally named were not built on v3; the Status section above describes the decision as it stands.)

**Rationale — why the epoch must not rotate.** `queueDraftSave` stamps its `.saveDraft` op from the ROW (`saveDraftOp.instanceEpoch = draft.instanceEpoch`) and builds the optimistic header PK from the same value, so an unchanged row yields a header and an op at its own epoch — epoch-aligned and executable. Routing the same Save through the admission cursor would rotate the row to the reopened generation's fresh epoch *before* the queue admission; since `queueDraftSave` swallows admission failures, a failure would strand the row at the new epoch with only an old-epoch producer.

**Rejected alternatives.**
1. **Re-admit a `.saveDraft` on Undo/Discard (spec v3).** A compensating mechanism (rule 2e). One blocker was fatal: putting `draftId` in `.deleteDraft.messageIds` decodes `.malformed` ⇒ terminal drop, silently disabling every server-draft delete in the app.
2. **Move the server-draft delete to send completion.** `v1.6.38` deleted at initiation too, so this is a change *away* from proven behaviour (rule 2c).
3. **The bare snapshot guard alone.** Makes one path worse: it strands the row at the new epoch when admission fails, whereas the broken silent close left it at the old epoch with its producer still executable.
4. **Making `.undoReopen` adopt the persisted epoch.** Refuted. Its mint is *not* vestigial L6 scaffolding: the epoch also feeds `ActiveAgentTracker.composeSessionKey`, which **generation-fences a compose AI agent that outlives the send** (sending never cancels it). Adoption would let a stale agent's late autosave overwrite the reopened draft as a same-generation save. A surviving `.failed` outbox row can also share the old epoch, and Stage-A owner lookup has no status restriction.

**Consequences.**
- Changed content still uses the ordinary fresh-epoch save path, so the AI generation fence is untouched.
- `saveFromClosePrompt` re-commits recipient input and **re-computes** the decision rather than caching the plan, because a background AI update can change content while the alert is visible.
- The alert message becomes "Save this draft before closing?" — "You have unsaved changes" is false in the new unchanged case.
- **Not fixed, pre-existing, and no worse:** `queueDraftSave` still swallows admission failures (as at `v1.6.38`); IMAP with a confirmed-absent Drafts mailbox still creates no server copy; the crash-before-close window remains, though strictly better than `v1.6.38`, which deleted the row outright.
- The cross-epoch stale-producer FIFO starvation is a genuine refactor regression (`instanceEpoch` did not exist at `v1.6.38`) and is filed separately. The close decision and the admission do not depend on it; "the server copy eventually appears" does.

**Relates:** ADR-IOS-019 (outbox), ADR-IOS-060 (durable FIFO), ADR-IOS-064 (the L-series withdrawal).

---
