## ADR-IOS-100: Send With an Empty Body and a Visible Suggestion Accepts the Suggestion and Sends

**Status:** Active (2026-11-04). Owner request relayed 2026-11-04 (issue #384): "in Compose, Send with an
empty body and a visible AI suggestion should just accept the suggestion and send. No 'Empty Body'
dialog in that case." Builds on ADR-IOS-065 (the single `acceptingVisibleSuggestion` transition) and
project memory 049 (the suggestion bubble and the body editor are mutually exclusive, so a visible
suggestion always sits over an empty body).

**Context:** Send with an empty body always raised the "Empty Body" alert, which for a visible suggestion
offered "Use Suggestion & Send". The user had already seen the suggestion and tapped Send; the extra
prompt was friction.

**Decision:**
1. `ComposeDraftGuards.sendTap(_:isHydratingPreparedDraft:)` is the one pure decision behind the Send
   button, returning `SendTap`: `.ignore` (prepared draft hydrating, #309, checked first),
   `.sendAsTyped` (non-blank body: the suggestion is never appended or merged into typed text),
   `.sendAcceptingSuggestion` (blank body, `showingSuggestion`, non-blank suggestion), else
   `.promptEmptyBody` (unchanged "Empty Body" / "Send Anyway" / Cancel).
2. `.sendAcceptingSuggestion` runs `acceptVisibleSuggestionIfOffered()` (the ADR-IOS-065 transition) and
   then `send()`. No prompt. The alert's "Use Suggestion & Send" button and its suggestion-specific
   message text are deleted; the card's own "Use Suggestion" button stays.
3. **Stricter than the old alert on purpose:** the suggestion must be non-blank after trimming (the old
   alert tested `!isEmpty`). A whitespace-only suggestion would send an empty email without the prompt,
   so it falls to `.promptEmptyBody`.
4. **Guided tutorial:** accept-and-send on the practice reply goes through the same gate as the card's
   Use Suggestion, `TutorialCoordinator.admits(.useSuggestion, ...)`, which unlocks only after the
   scripted edit (ADR-IOS-038). Before the edit, Send with the visible suggestion shows the locked
   notice and does nothing. (The old alert's button bypassed that lock.) After the edit the coach card
   still says "Tap Use Suggestion", which remains correct.

**Invariant pinned by tests:** Send with an empty body and a visible suggestion sends exactly the
suggestion text and never shows a prompt; empty body with no usable suggestion prompts; a typed body
sends only the typed body (`ComposeSuggestionPersistTests`).
