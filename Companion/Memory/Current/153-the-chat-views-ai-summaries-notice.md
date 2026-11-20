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
- **Report:** "Report a concern" opens the shared report sheet (`reportConcernSheet`, extracted from
  the long-press `ReportConcernModifier`) with type `.summary` and every summary in the chat, the
  emails and the replies still sending or not sent, newest first
  (`AISummariesNotice.reportContent(items:unsent:)`), so the backend's 5,000-character cut drops the
  oldest. For this report only the sheet adds "This chat's AI summaries are sent with your report."
  The sheet's `send` parameter defaults to `ReportConcernService.sendReport`; tests pass a recorder.

Tests: `ChatAISummariesNoticeTests`, `ChatAISummariesNoticeHostedTests` (TESTS.md, "Chat view — the
AI summaries notice").
