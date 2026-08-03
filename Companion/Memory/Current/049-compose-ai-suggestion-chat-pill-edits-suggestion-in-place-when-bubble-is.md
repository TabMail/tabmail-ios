
### Compose AI Suggestion — chat pill edits suggestion in place when bubble is visible
- Reply suggestion bubble (`ComposeView.swift:307-335`) and the body TextEditor are mutually exclusive — while the bubble is up, `messageBody` is empty.
- Chat pill ("Edit Draft") routes by `showingSuggestion`:
  - **Bubble visible:** input = `currentSuggestion`, output writes back to `currentSuggestion` AND `messageHeader.cachedReply` (DB) so reopens show the edited version. Bubble stays up.
  - **After Use Reply / Dismiss:** input/output is `messageBody` (existing flow, unchanged).
- `prepopulate()` re-reads `cachedReply` fresh from DB so prior edits survive in-memory staleness of caller's `MessageHeader` snapshot.
- Recompute (`ComposeView.swift:825`) still overwrites `cachedReply` — by design, "give me a fresh AI draft" discards edits.
- Subject / recipient deltas always go to compose state, regardless of whether bubble is up.
