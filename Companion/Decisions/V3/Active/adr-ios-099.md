## ADR-IOS-099: One Anonymous Feedback Sheet After the Signup Trial Ends

**Status:** Active (2026-11-03). Owner decisions 2026-11-03: optional, anonymous, a sheet rather than
an inbox row ("Shouldn't it be a popup?"). Builds on ADR-IOS-044 (inbox banner, `trialState`) and the
derived "trial ended" fact (`AccountInfo.trialState(now:)`, project memory 118).

**Context:** a user whose card-free signup trial ends without a subscription leaves without telling
us why. One optional question, answered anonymously, is the cheapest signal.

**Decision:**
1. **When.** `TrialFeedback.shouldPresent`: an inbox view, signed in, not demo,
   `UsageThrottleStore.shared.trialState == .ended` (already means no subscription), not asked yet
   on this install, and nothing else presented. The presenter (`trialFeedbackSheet(isInbox:)` on
   `InboxView`) checks on inbox appearance and again when eligibility turns true while the inbox
   shows (a late `/whoami`). If something is already presented it waits for the next appearance;
   it never stacks over another sheet.
2. **Once per install.** The flag `trial_feedback_asked` (UserDefaults, not user data) is set when the
   sheet APPEARS, so Send, Not now, a swipe down, and the app being killed while it is open all end
   it for good. Awaiting owner blessing: the kill-while-open case counts as asked.
3. **Layout.** Native `NavigationStack` + `Form`, `.presentationDetents([.medium, .large])`; inline
   title "Your free trial ended"; section "What held you back?" over five choices with a checkmark
   on the picked one, with the footer "Anonymous. Not linked to your account." right under the
   choices (owner 2026-11-03: visible at the medium detent before Send; under the comment field it
   was clipped below the medium detent); an optional vertical comment field; toolbar "Not now" (cancellation) and "Send" (confirmation, disabled until a choice).
4. **What is sent.** Exactly `{version: 1, reason, comment?}` as `application/json` to
   `https://forms.tabmail.ai/feedback/trial` (dev servers: `forms-dev.tabmail.ai`), built from
   scratch on the shared ephemeral session: no Authorization or client headers, cookies off. A blank
   comment is left out; any other is sent exactly as typed. Sent once, never retried; a lost answer
   is acceptable.
5. **Comment cap.** 500 Unicode code points, measured as the worker measures. `TrialFeedbackForm.edit`
   refuses an edit that would pass it whole (never cuts). The field is bound to the sheet's own
   `@State` text, and `onChange` puts the previous text back when the form refuses, a real change of
   that state, so the text view redraws. Two designs were rejected because the refused text stays
   on screen while Send sends the older value: a binding whose setter only refuses, and a setter
   that writes the proposed text then the previous one (SwiftUI can coalesce the two writes; it
   failed 1 run in 4 under load).
6. **Logs.** Debug-gated status only (`[TrialFeedback] sent: HTTP n`, `send failed: <code>`); never
   the reason or the comment.

**Launch facts (not code):**
- The App Store privacy label declares it: **User Content > Other User Content, Not Linked to You,
  purpose Analytics.** The optional-disclosure exemption does not apply because the form does not
  carry the user's name. The owner published this label on 2026-11-03 (nine data types in all; this
  form is the Other User Content entry), so it is already in place before the release that ships
  the sheet.
- The forms worker's endpoint (migration plus its enable flag) goes live before the iOS build is
  released.

**Consequences:** at most one sheet per install, no identity in the answer, no retry. Tests:
`TrialFeedbackTests` (presentation matrix, hosted presenter: presents and marks asked, not over
another sheet, late `/whoami`; real-control comment cap; send once over every status, transport
error, and a lost reply; log privacy).
