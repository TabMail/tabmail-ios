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
- **A sheet that leaves with nothing sent finishes only the presentation that was current when it
  reached its window (#1113, round 4, current):** when the sheet's `WindowProbe` reports a window,
  the sheet records the presentation then current (`ReportSheetLife.shownFor =
  ReportPresentation.current`); when it leaves with nothing sent, it finishes its caller only if
  that presentation is still current. A sheet that never had a window has no `shownFor` and
  finishes nothing. Why round 3 was not enough: the test logs of 2026-11-21 show that the closed
  popover's sheet SwiftUI presents again, at the system close while the report flag is still set,
  IS in a window for a moment (`report sheet … in a window: current 1` with nothing presented from
  the root, 15 to 25 ms after the close and before the reopen, then `left its window: current 2`
  once the notice reopened, then UIKit's refusal), so round 3's probe reported its departure and
  it closed the reopened notice (`aSystemClosedPopoversAnswerNeverChangesTheNext` and
  `aClosedPopoversSheetNeverClosesTheReopenedNotice`, red in two runs). The gate takes its
  presentation from the window, not from `.onChange(of: isPresented)` (round 2's `asked`), which
  does not reliably fire inside the popover's content; `openNotice` still advances the presentation
  on every open. **It holds by order, not by identity:** `shownFor` is the presentation current
  when the sheet reached its window, not the one it was presented for. The stray sheet reaches its
  window before any reopen a user can make; a reopen within a frame or two of an unexpected close,
  before the stray reaches its window, would count the stray for the reopened presentation and its
  departure would close the reopened notice (one more tap opens it again; nothing is lost; tracked
  as #1158). Cancel likewise holds while nothing calls `ReportPresentation.next()` between a sheet's
  window and its departure: the modifier's `onChange` fired, when it did, before the sheet had a
  window in every logged case (a late one would leave the popover up after Cancel; a tap outside
  closes it). Round 3's `attached` flag on `WindowProbe.Probe` is deleted with its test
  `aWindowlessProbeReportsNothing`: with the gate, a departure from a sheet that never had a window
  finishes nothing anyway, and that test stayed green with the flag removed, so UIKit sent the probe
  no nil-window call for a superview with no window. Pinned by
  `aSystemClosedPopoversAnswerNeverChangesTheNext` and
  `aClosedPopoversSheetNeverClosesTheReopenedNotice` (the gate), and by the Cancel tests
  `aClosedPopoverDoesNotReopenTheSheet` and `aRemovedNoticesTakenAnswerConfirmsOnce` (a sheet on
  screen for the current presentation still finishes its caller).
- **SUPERSEDED by round 4 above. A sheet UIKit refused reports nothing (#1113, round 3):** `WindowProbe` reports
  `onDetach` only after it has reported a window (one `attached` flag on `WindowProbe.Probe`).
  Apple's `UIView.didMoveToWindow()` note: the window "may be nil … when the receiver has just been
  removed from its superview or when the receiver has just been added to a superview that is not
  attached to a window". The round-1 probe turned every nil window into a departure, so a sheet
  UIKit refused (never in a window) reported one when SwiftUI added it and another when it removed
  it; the 6cfeecca7 test logs show one or two "report finished, closing the popover" lines right
  after each refusal. Now that sheet reports nothing, and a sheet that was on screen and leaves with
  nothing sent always finishes its caller, as in round 1. The round-2 gate below
  (`ReportPresentation.open`/`asked`, `ReportSheetLife.shownFor`) is deleted: it compensated for
  the probe's wrong signal, and it made the notice's Cancel depend on `.onChange(of: isPresented)`
  firing inside the popover's content, which the 6cfeecca7 logs showed not firing (0 of 8 report
  opens logged `showsReport -> true`). The old popover's own sheet can only race a reopen within
  one run-loop turn, which a tap cannot do. Debug builds log each report sheet's window attach,
  detach and finish as `[AINotice … report sheet …` lines. Pinned by `aWindowlessProbeReportsNothing`
  and `aClosedPopoversSheetNeverClosesTheReopenedNotice`.
- **SUPERSEDED by round 3 above. A sheet that leaves with nothing sent (#1113, round 2):** it finishes the caller (closes the
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
