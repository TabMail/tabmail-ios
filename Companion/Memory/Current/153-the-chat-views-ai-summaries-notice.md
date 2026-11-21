## The chat view's AI summaries notice (2026-11-19)

**What:** a gray `sparkles` glyph at the trailing edge of the chat view's subject line
(`ChatSubjectLine`, `AISummariesNoticeButton` in `Views/Chat/AISummariesNotice.swift`). A tap opens a
popover: "AI summaries", the note that the chat's messages are AI summaries and may contain errors,
and "Report a concern". The chat pill keeps its own "AI responses may contain errors" line.

- **First open:** the same popover opens by itself once per install, the first time a chat lands in
  the chat view (`ChatThreadView.didInitialScroll` passed as `landed`). The record is a plain
  UserDefaults flag (`AISummariesNotice.shownKey`), claimed once when shown, so it never opens by
  itself again, dismissed or not. It follows `OnboardingTipGate.onboardingComplete`: never on sample
  mail or in the tutorial, and those opens do not use it up. It is not held back by the one-tip-a-day
  pacing.
- **Why not a TipKit tip:** TipKit's datastore is configured by the test host and cannot be reset
  in-process (ADR-IOS-085), so a tip's show-once behaviour cannot be tested. A plain flag with an
  injectable `UserDefaults` can.
- **Presentation:** the shown flag is set only when UIKit puts the popover in a window (a small
  `WindowProbe`), because SwiftUI runs a popover's `onAppear` and `onDisappear` even when UIKit
  refuses or has not finished the presentation. The popover itself presents the report sheet, so
  the two never compete for one presenter; when the report is done (Cancel, a swipe down, a report
  not taken, or OK on "Report Submitted", via the sheet's `onFinish`) the popover closes. Two
  popovers asked for in the same frame may both be refused: then nothing shows and the notice stays
  due. Debug builds trace all of this with `[AINotice` lines.
- **"Report Submitted" (2026-11-21, #1113):** the confirmation belongs to the report, not to the
  view that asked for it (`ReportConcernSubmission` in `ReportConcernModifier.swift`). Once the
  backend has taken the report and the sheet's own `WindowProbe` says the sheet has gone, UIKit
  shows it from the top of the key window (`ReportConcernConfirmation`), after any presentation
  still moving there, because UIKit refuses an alert while its presenter is still closing the
  sheet. A report not taken shows nothing. This covers the long-press report too. Before #1113 the
  shared sheet showed it as a SwiftUI alert from its `onDismiss`, and it was lost when the
  reporting row was recycled or removed, or the system closed the notice's popover, while the
  report sent. An old answer still shows it once, over whatever is up, but never closes, changes
  or finishes a later report (`ReportPresentation`), so its OK never closes a popover the user has
  reopened.
  Pinned by `reportSubmittedWaitsForTheSheetToLeave` (no alert until the sheet has gone, then once; finish once) and `submittedReportClosesTheSheet` (the popover stays under the alert until OK).
- **A sheet that leaves with nothing sent (#1113, round 2):** it finishes the caller (closes the
  popover) only if it was in a window for a report the caller asked for (`ReportPresentation.open`)
  and still shows. Once the system has closed the popover with its sheet up, the next change of
  the report flag (the notice reopening clears it) makes SwiftUI present that sheet again from the
  closed popover: a fresh sheet, which UIKit refuses ("whose view is not in the window hierarchy").
  Before this rule that sheet's probe finished the caller and closed the reopened notice about
  150 ms after it opened. The reopen retires the old report (`ReportPresentation.next`), so that
  sheet, and the old sheet's own late departure, finish nothing. Debug builds log each report
  sheet's window attach, detach and decision as `[AINotice … report sheet …` lines. Pinned by
  `aRetiredPresentationsSheetFinishesNothing` and `aClosedPopoversSheetNeverClosesTheReopenedNotice`.
- **List rows:** a sheet presented from a SwiftUI `List` row stays up when the row is removed
  (still up five seconds later in both logged test runs), so a report sheet from a removed list row carries on as if the row
  were there; a row in a `VStack` takes its sheet with it.
- **Report:** "Report a concern" opens the shared report sheet (`reportConcernSheet`, extracted from
  the long-press `ReportConcernModifier`) with type `.summary` and every summary in the chat, the
  emails and the replies still sending or not sent, newest first
  (`AISummariesNotice.reportContent(items:unsent:)`), so the backend's 5,000-character cut drops the
  oldest. For this report only the sheet adds "This chat's AI summaries are sent with your report."
  The sheet's `send` parameter defaults to `ReportConcernService.sendReport`; tests pass a recorder.

Tests: `ChatAISummariesNoticeTests`, `ChatAISummariesNoticeHostedTests` (TESTS.md, "Chat view — the
AI summaries notice").
