## ADR-IOS-096: Discard Drops Only This Session's Unsaved Edits

**Status:** Active (2026-10-24). tabmail-ios#254; owner decision 2026-10-22. Builds on ADR-IOS-083
(draft deletion) and ADR-IOS-074 (compose dispositions are mutually exclusive).

**Context:** the Discard button of the "Save Draft?" prompt deleted the whole draft. Opening a draft
that is on the server, typing a word and tapping Discard queued the server copy's delete, so the
draft vanished from every device. The user meant to drop the word, not the draft.

**Decision:**
1. Discard has a scope (`ComposeDraftGuards.DiscardScope`). The "Save Draft?" Discard is
   `.unsavedEdits`; the confirmed Delete of a loaded draft cleared to nothing
   (`deleteClearedDraftAndDismiss`) is `.wholeDraft`.
2. `ComposeDraftGuards.discardDisposition` decides: a draft with a `serverDraftId` is kept as last
   saved under `.unsavedEdits` (`.keepDraft`, nothing written or queued) and its server copy's
   delete is queued under `.wholeDraft`; a draft that never reached the server is deleted under
   either scope, as before.
3. Keeping needs no write: compose writes the draft row only on Save, Send and agent autosave, so
   closing without a write leaves exactly the last saved copy, on the device and on the server.
4. The guards before the decision stay for every scope: a draft that did not finish loading, a
   failed metadata read and an instance-epoch mismatch still refuse the discard.
5. The discard runs in `ComposeDraftDiscard.run`, outside the view, which only shows its outcome
   (ignored, refused with a message, or dismiss). `ComposeDraftDiscardTests` drive it against a real
   database and the fake IMAP server.

**Consequences:** deleting a server draft from compose takes the explicit cleared-draft Delete (or
the mailbox's delete); Discard never destroys server content. Edits an agent autosave already wrote
in this session are saved edits and stay.
