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
///  1. The popover opens by itself on the first chat-view open of the install, once the chat has
///     landed, and never again once it has been shown (dismissed or not).
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

    @Test("The first landed open shows the notice; every later open does not")
    func showsOnceOnTheFirstOpen() {
        let defaults = Self.freshDefaults()
        let first = AISummariesNotice.FirstOpen(defaults: defaults)
        #expect(first.claim(landed: true, tipsAllowed: true))
        #expect(!first.claim(landed: true, tipsAllowed: true))
        // A new chat, another screen instance: the flag is the install's, not the view's.
        #expect(!AISummariesNotice.FirstOpen(defaults: defaults).claim(landed: true, tipsAllowed: true))
    }

    @Test("Before the chat has landed nothing opens and nothing is used up")
    func waitsForTheLanding() {
        let defaults = Self.freshDefaults()
        let first = AISummariesNotice.FirstOpen(defaults: defaults)
        #expect(!first.claim(landed: false, tipsAllowed: true))
        #expect(first.claim(landed: true, tipsAllowed: true))
    }

    @Test("Sample mail and the tutorial never show it and never use it up")
    func neverOnSampleMailOrTheTutorial() {
        let defaults = Self.freshDefaults()
        let first = AISummariesNotice.FirstOpen(defaults: defaults)
        #expect(!first.claim(landed: true, tipsAllowed: false))
        #expect(!first.claim(landed: true, tipsAllowed: false))
        #expect(first.claim(landed: true, tipsAllowed: true))
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
