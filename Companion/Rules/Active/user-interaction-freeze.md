## User Interaction Freeze Rule

**While the user is interacting (swiping, tapping, any animation in-flight), NO background updates may mutate `@Observable` state that feeds the visible view. This is a fundamental UX rule — no exceptions.**

- Background data changes (`backgroundDataDidChange`, AI updates, snippet loading, sync completions) MUST be deferred while the user is interacting.
- Use `InboxViewModel.beginInteraction()` / `endInteraction()` to gate the interaction window. All swipe action handlers, button taps, and gesture callbacks MUST bracket with these calls.
- `endInteraction()` starts a cooldown (200ms) to let SwiftUI animations settle before flushing deferred updates.
- Deferred updates are applied in one batch after cooldown: pending reloads take priority over individual snapshot refreshes.
- Snippet loading collects all updates into a batch and applies them in a single synchronous loop (one `@Observable` mutation → one re-render, not N).
- **Rationale:** The user acts on the *visualized* state. Re-laying out the list mid-swipe causes jank, dropped gestures, and animation conflicts. All pending updates come AFTER the interaction completes.

---
