/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The chat view's notice that its messages are AI summaries: a gray sparkles glyph at the top
/// right of the chat header. A tap opens a popover with the note and "Report a concern". The same
/// popover opens by itself the first time a chat opens in the chat view, once per install.
enum AISummariesNotice {
    static let glyph = "sparkles"
    static let title = "AI summaries"
    static let message = "The messages in this chat are AI summaries of your emails. AI chat view may contain errors. Tap Details on a message to read the email."
    static let reportTitle = "Report a concern"
    static let accessibilityLabel = "AI summaries, may contain errors"
    static let accessibilityHint = "Opens the notice"
    /// The extra line the report sheet shows for this report, since it sends the whole chat.
    static let reportNotice = "This chat's AI summaries are sent with your report."
    /// Between two summaries in the report.
    static let reportSeparator = "\n\n"

    /// The once-per-install flag: the notice has opened by itself. Local, never synced.
    static let shownKey = "chatView.aiSummariesNotice.shownOnFirstOpen"

    /// Whether tips may show now: never on sample mail or in the tutorial, as every one-time tip
    /// (`OnboardingTipGate`). Not held back by the one-tip-a-day pacing of the other tips.
    static func tipsAllowed(onboardingComplete: Bool = OnboardingTipGate.onboardingComplete) -> Bool {
        onboardingComplete
    }

    /// The first open of the install. `claim` decides once per open, from what it is handed.
    struct FirstOpen {
        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        /// True exactly once per install: the first open that has landed while tips may show.
        /// Claiming records it, so the notice never opens by itself again, dismissed or not.
        func claim(landed: Bool, tipsAllowed: Bool) -> Bool {
            guard landed, tipsAllowed, !defaults.bool(forKey: AISummariesNotice.shownKey) else { return false }
            defaults.set(true, forKey: AISummariesNotice.shownKey)
            return true
        }
    }

    /// What "Report a concern" sends: every AI summary in the chat, newest first, so a cut at the
    /// backend's length limit drops the oldest. Emails still being summarized, and emails with
    /// nothing to summarize, carry no summary.
    static func reportContent(oldestFirst textMessages: [String?]) -> String {
        textMessages.reversed()
            .compactMap { $0 }
            .filter { $0 != MessageHeader.noContentSummary }
            .joined(separator: reportSeparator)
    }
}

/// The glyph and its popover. Sits at the trailing edge of the subject line.
struct AISummariesNoticeButton: View {
    /// The chat has landed: the popover may open by itself now.
    let landed: Bool
    /// The report's content, built when the report is sent.
    let reportContent: () -> String

    @State private var showsNotice = false
    @State private var reportRequested = false
    @State private var showsReport = false
    @ScaledMetric(relativeTo: .footnote) private var glyphSize = ChatViewLayout.aiNoticeGlyphSize

    var body: some View {
        Button { showsNotice = true } label: {
            Image(systemName: AISummariesNotice.glyph)
                .font(.system(size: glyphSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: ChatViewLayout.aiNoticeTapTarget, minHeight: ChatViewLayout.aiNoticeTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AISummariesNotice.accessibilityLabel)
        .accessibilityHint(AISummariesNotice.accessibilityHint)
        .popover(isPresented: $showsNotice, arrowEdge: .top) {
            popover
        }
        .onChange(of: showsNotice) { _, shows in
            // The sheet waits for the popover to close: one presentation at a time.
            if !shows, reportRequested {
                reportRequested = false
                showsReport = true
            }
        }
        .reportConcernSheet(isPresented: $showsReport, contentType: .summary,
                            content: reportContent, contentNotice: AISummariesNotice.reportNotice)
        .task(id: landed) {
            // One decision per open, read once from the flag and the tip gate.
            if AISummariesNotice.FirstOpen().claim(landed: landed, tipsAllowed: AISummariesNotice.tipsAllowed()) {
                showsNotice = true
            }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: ChatViewLayout.aiNoticeSpacing) {
            Text(AISummariesNotice.title)
                .font(.headline)
            Text(AISummariesNotice.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                reportRequested = true
                showsNotice = false
            } label: {
                Label(AISummariesNotice.reportTitle, systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.borderless)
            .tint(.red)
        }
        .padding()
        .frame(idealWidth: ChatViewLayout.aiNoticeWidth)
        .presentationCompactAdaptation(.popover)
    }
}
