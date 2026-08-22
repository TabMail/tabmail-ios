<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current amendment (2026-08-21):** Explicit **Save Draft** is also an adoption gesture when the
> suggestion bubble is actively visible. Close treats that visible, nonempty suggestion as unsaved
> content and offers Save/Discard/Cancel; Save synchronously applies the exact offered text through
> the same transition as **Use Suggestion** before taking the durable draft snapshot. Hidden/dismissed, nil,
> empty, or already-accepted suggestion state is never applied. Agent auto-save still skips the
> ephemeral bubble; only explicit Use or Save adopts it into `messageBody`. Current symbol authorities
> for the preserved historical citations below are `ComposeView.suggestionBubble(text:)`,
> `ComposeView.applyInlineEdit`, `ComposeView.prepopulate`, and `ComposeView.recomputeReply`; the
> frozen numeric line references remain provenance only.
<!-- COMPANION-CURRENT-NOTE-END -->

### Compose AI Suggestion — chat pill edits suggestion in place when bubble is visible
- Reply suggestion bubble (`ComposeView.swift:307-335`) and the body TextEditor are mutually exclusive — while the bubble is up, `messageBody` is empty.
- Chat pill ("Edit Draft") routes by `showingSuggestion`:
  - **Bubble visible:** input = `currentSuggestion`, output writes back to `currentSuggestion` AND `messageHeader.cachedReply` (DB) so reopens show the edited version. Bubble stays up.
  - **After Use Reply / Dismiss:** input/output is `messageBody` (existing flow, unchanged).
- `prepopulate()` re-reads `cachedReply` fresh from DB so prior edits survive in-memory staleness of caller's `MessageHeader` snapshot.
- Recompute (`ComposeView.swift:825`) still overwrites `cachedReply` — by design, "give me a fresh AI draft" discards edits.
- Subject / recipient deltas always go to compose state, regardless of whether bubble is up.
