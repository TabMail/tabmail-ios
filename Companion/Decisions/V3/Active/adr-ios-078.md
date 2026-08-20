## ADR-IOS-078: The Newest-100 Window Bounds Processing Only — Existing AI Content Is Never Gated From Display

**Date:** 2026-08-19

**Status:** Active. Owner decision, recorded verbatim in intent: *"what we intentionally intended
was that the AI processing does not happen for things in inbox that are beyond the 100 limit.
However, there is no reason whatsoever to gate AI that already exists … if an AI summary exists,
there's never a reason to gate it."*

**Context.** `7a31f1d22` ("Restore bounded queue behavior", shipped in `v1.7.11`) implemented the
IOS-AI-004 bounded-processing policy: only the newest `SyncConfig.maxRecentEmails` Inbox rows are
eligible for AI work (`ActiveAIQueue.recentInboxWindowContains`, migration `v87`). In the same
commit the bound leaked into DISPLAY: `SummaryBubbleView` gained a `recentInboxEligible` window
query and a "AI work is suppressed for older messages in large inboxes" notice that replaced the
bubble — including for messages whose summary **already existed**. That display half also carried a
lifecycle defect (the unresolved gate hid the view hosting its own resolver — `MIS-IOS-017`), which
PR #59 hot-fixed by making the gate resolve correctly. The owner then ruled the display gate itself
was designed in error. Separately, the shipped `v1.7.9` display had always gated the summary bubble
on inbox membership (`if !isInInbox { return .hidden }` ran before the content check), hiding a
retained summary when a Sent/Archive/Trash message was opened via search.

**Decision.**

1. **Summaries: never gated.** An AI summary that exists renders in every folder — no newest-100
   window check, no inbox-membership check, nothing beyond "the summary exists". The only remaining
   `.hidden` outcomes in `SummaryBubbleView.displayMode` are presentation states: demo-with-AI-
   declined, and the ABSENT-summary empty state outside the Inbox (where
   `AccountManager.processOpenedMessage` guards on `isInInbox`, so a loading spinner would
   advertise work that never happens). The absent-summary state sits after the content check, so it
   can never hide existing AI content. The demo consent state is deliberately checked FIRST — a demo
   user who declined AI sees no AI output at all, even pre-baked demo content: it is a consent
   surface, not an eligibility policy. This deliberately goes one step past a `v1.7.9` restoration: `v1.7.9`'s
   inbox-membership display gate on the summary is removed, not restored.
2. **Action pill / tag buttons: inbox-membership only.** `ActionTagDisplay.displayedTag` remains
   the single display decision — tag rendered in the Inbox, hidden outside it (tags are meaningless
   outside the Inbox; ADR-IOS-036 retention is unchanged). No newest-100 gating exists on this
   surface and none may be added. Verified already compliant at `785138481`; no code change.
3. **Processing: unchanged.** `ActiveAIQueue.recentInboxWindowContains` stays the sole admission
   seam for direct enqueue, opened-message processing and job execution (IOS-AI-004). Display never
   consults it.

**Consequences.**

- An out-of-window Inbox message with no summary shows the ordinary `v1.7.9` empty state — loading,
  then after 20 s the failure/retry bubble — even though the bounded queue will never process it,
  and Retry is a no-op outside the window. Accepted by the owner in the same decision; the previous
  suppression notice is gone.
- A Sent/Archive/Trash message opened via search now renders its retained summary (`v1.7.9` hid it).
- The `.suppressed` display state, the `recentInboxEligible` view state and the view-side window
  query are deleted; `SummaryBubbleViewTests` pins exists⇒shown across the folder axis, and the
  window axis is gone from `displayMode`'s signature by construction.
- IOS-AI-004's display clause is replaced (see its amendment); its processing clause is untouched.
- The mistake class "a processing bound leaked into display semantics" is recorded as `MIS-IOS-018`.
