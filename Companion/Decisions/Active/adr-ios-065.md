
## ADR-IOS-065: Undo-Send close decision — restore the shipped prompt without rotating the epoch

**Date:** 2026-07-26. **Spec:** `PLAN_F2B_SPEC_V5_CLOSE_STATE.md`.

**Context.** After Undo Send, closing compose without typing **silently discarded the user's draft**. Send initiation removes the Drafts header and admits a `.deleteDraft` for the server copy; nothing restored either. `UndoReopenCompose` passes `prefillTreatAsUnsavedChanges: true` AND `prefillDraftId`, but with the retained row present the row-load branch snapshotted the loaded content as baseline and returned before reaching the guard honouring that flag — so `hasChanges` was false and the close resolved to `.dismiss`.

At `v1.6.38` this was impossible: `undo()` **deleted** the Draft row, making the reopen prefill-based with no baseline, so close prompted and the save recreated both copies. Retaining the row is a deliberate later improvement (it preserves `serverDraftId`/`rfc822`/`serverPushStatus` and survives the crash window) — but it removed that mechanism without replacing it.

**Decision.** The close decision moves into a production reducer, `ComposeCloseState`, which **owns the baseline** and derives its inputs: `hasContent` via the existing `ComposeDraftGuards.hasContent`, `hasChanges` as `current != baseline`. Neither its constructors nor `decision(current:)` accept `hasChanges` or `hasContent`. Every outcome except one delegates to the unchanged `ComposeDraftGuards.closeAction`, so the two cannot drift.

One new rule: an `.undoReopen`-loaded draft still holding its loaded content resolves to `.promptSave(.readmitRetained)` instead of `.dismiss`. That Save re-admits the already-durable row via `queueDraftSave` and **must not** call `DraftStore.saveAsync`, `DraftStore.admitSave`, or `admissionCursor.admit`.

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
