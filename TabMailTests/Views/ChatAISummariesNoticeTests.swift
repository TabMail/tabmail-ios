/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The chat view's "AI summaries" notice: a sparkles glyph at the top right of the chat header that
/// opens a popover saying the chat's messages are AI summaries, with "Report a concern".
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The popover is due on every landed open until it has actually been on screen, and never
///     after (dismissed or not).
///  2. It never opens by itself while tips are held back (sample mail, the tutorial), and such an
///     open does not use it up.
///  3. "Report a concern" sends every AI summary in the chat, newest first, so a cut at the
///     backend's length limit drops the oldest. Emails with nothing to summarize are not summaries.
///  4. The report sheet says plainly that the chat's AI summaries are sent; other reports do not.
///  5. The wording is exactly as specified.
@Suite("Chat AI summaries notice")
struct ChatAISummariesNoticeTests {

    private static func freshDefaults() -> UserDefaults {
        let name = "ChatAISummariesNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 1 and 2. When it opens by itself

    @Test("The notice is due until it has been on screen, and never after")
    func dueUntilShown() {
        let defaults = Self.freshDefaults()
        let first = AISummariesNotice.FirstOpen(defaults: defaults)
        #expect(first.isDue(landed: true, tipsAllowed: true))
        // Asked for but never on screen (a landing during the push): still due on the next open.
        #expect(first.isDue(landed: true, tipsAllowed: true))
        first.markShown()
        #expect(!first.isDue(landed: true, tipsAllowed: true))
        // A new chat, another screen instance: the flag is the install's, not the view's.
        #expect(!AISummariesNotice.FirstOpen(defaults: defaults).isDue(landed: true, tipsAllowed: true))
    }

    @Test("Before the landing, and while tips are held back, it is not due")
    func notDueBeforeLandingOrWhileHeldBack() {
        let first = AISummariesNotice.FirstOpen(defaults: Self.freshDefaults())
        #expect(!first.isDue(landed: false, tipsAllowed: true))
        #expect(!first.isDue(landed: true, tipsAllowed: false))
        #expect(first.isDue(landed: true, tipsAllowed: true))
    }

    @Test("Tips are held back exactly while onboarding is not complete")
    func tipsAllowedFollowsTheOnboardingGate() {
        #expect(AISummariesNotice.tipsAllowed(onboardingComplete: true))
        #expect(!AISummariesNotice.tipsAllowed(onboardingComplete: false))
    }

    // MARK: - 3. What the report sends

    @Test("The report carries the chat's summaries newest first, without no-content bubbles or pending ones")
    func reportIsNewestFirst() {
        let content = AISummariesNotice.reportContent(
            oldestFirst: ["Oldest summary", nil, MessageHeader.noContentSummary, "Middle summary", "Newest summary"])
        #expect(content == "Newest summary\n\nMiddle summary\n\nOldest summary")
    }

    @Test("A chat with no summaries yet reports nothing")
    func reportWithNoSummaries() {
        #expect(AISummariesNotice.reportContent(oldestFirst: [nil, MessageHeader.noContentSummary]).isEmpty)
    }

    // MARK: - 4. The report sheet's line

    @Test("The sheet says the chat's AI summaries are sent, only for this report")
    func sheetNoticeLine() {
        let standard = ReportConcernSheetText.consentLines(contentNotice: nil)
        #expect(standard == [ReportConcernSheetText.storedForReview])
        let withNotice = ReportConcernSheetText.consentLines(contentNotice: AISummariesNotice.reportNotice)
        #expect(withNotice == [AISummariesNotice.reportNotice, ReportConcernSheetText.storedForReview])
        #expect(AISummariesNotice.reportNotice == "This chat's AI summaries are sent with your report.")
    }

    // MARK: - 5. Wording

    @Test("The popover and VoiceOver wording")
    func wording() {
        #expect(AISummariesNotice.title == "AI summaries")
        #expect(AISummariesNotice.message
                == "The messages in this chat are AI summaries of your emails. AI chat view may contain errors. Tap Details on a message to read the email.")
        #expect(AISummariesNotice.reportTitle == "Report a concern")
        #expect(AISummariesNotice.accessibilityLabel == "AI summaries, may contain errors")
        #expect(AISummariesNotice.accessibilityHint == "Opens the notice")
        #expect(AISummariesNotice.glyph == "sparkles")
    }
}
