/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

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
    // A plain flag, not a TipKit tip: TipKit's store cannot be reset in-process (ADR-IOS-085).
    static let shownKey = "chatView.aiSummariesNotice.shownOnFirstOpen"

    /// Whether tips may show now: never on sample mail or in the tutorial, as every one-time tip
    /// (`OnboardingTipGate`). Not held back by the one-tip-a-day pacing of the other tips.
    static func tipsAllowed(onboardingComplete: Bool = OnboardingTipGate.onboardingComplete) -> Bool {
        onboardingComplete
    }

    /// The first open of the install. The notice is due until it has actually been on screen.
    struct FirstOpen {
        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        /// The notice should open by itself now: the chat has landed, tips may show, and the
        /// notice has never been on screen. Reading this records nothing.
        func isDue(landed: Bool, tipsAllowed: Bool) -> Bool {
            landed && tipsAllowed && !defaults.bool(forKey: AISummariesNotice.shownKey)
        }

        /// The popover is on screen: it never opens by itself again, dismissed or not. Recorded
        /// when UIKit puts it in a window, not when it is asked for, since a chat can land while its push is
        /// still running and the popover cannot be presented then.
        func markShown() {
            defaults.set(true, forKey: AISummariesNotice.shownKey)
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

    /// The report for a chat as it is shown: its emails, oldest first, then the user's replies
    /// still sending or not sent, which the chat shows after them.
    static func reportContent(items: [ChatThread.Item], unsent: [ChatUnsentReply]) -> String {
        reportContent(oldestFirst: items.map(\.textMessage) + unsent.map(\.textMessage))
    }
}

/// The glyph and its popover. Sits at the trailing edge of the subject line.
struct AISummariesNoticeButton: View {
    /// The chat has landed: the popover may open by itself now.
    let landed: Bool
    /// The report's content, built when the report is sent.
    let reportContent: () -> String
    /// The install's first-open flag and the tip gate, read once when the chat lands.
    var firstOpen = AISummariesNotice.FirstOpen()
    var tipsAllowed: () -> Bool = { AISummariesNotice.tipsAllowed() }
    /// Sends the report.
    var send: ReportConcernSend = ReportConcernService.sendReport

    @State private var showsNotice = false
    /// The report sheet over the popover. Kept here, not in the popover's content: SwiftUI did not
    /// reliably observe that state, so Cancel and the answer could not close the sheet.
    @State private var showsReport = false
    /// The report's presentation, owned with its flag: the popover, and the sheet on it, can be
    /// closed by the system while a report sends, and nothing on them runs then.
    @State private var reportPresentation = ReportPresentation()
    #if DEBUG
    /// Tells mounted buttons apart in the debug log.
    @State private var debugTag = String(UUID().uuidString.prefix(4))
    #endif
    @ScaledMetric(relativeTo: .footnote) private var glyphSize = ChatViewLayout.aiNoticeGlyphSize

    var body: some View {
        Button {
            // A tap always shows it. The glyph cannot be tapped while its popover is on screen, so a
            // request still set here is one UIKit refused (the chat landed under another screen),
            // and SwiftUI never retries it: clear it, then ask again on the next turn.
            if showsNotice {
                showsNotice = false
                Task { @MainActor in openNotice() }
            } else {
                openNotice()
            }
        } label: {
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
            AISummariesNoticePopover(reportContent: reportContent, send: send, tag: tag,
                                     showsReport: $showsReport, reportPresentation: reportPresentation) {
                noticeDebugLog(tag, "report finished, closing the popover")
                showsNotice = false
            }
            .background(WindowProbe {
                // Shown only once UIKit has put it in a window: SwiftUI runs a popover's
                // onAppear even when UIKit refuses the presentation.
                noticeDebugLog(tag, "probe attached; due=\(firstOpen.isDue(landed: true, tipsAllowed: true)) shows=\(showsNotice)")
                firstOpen.markShown()
                noticeDebugLog(tag, "marked shown")
            } onDetach: {
                noticeDebugLog(tag, "probe detached")
            })
        }
        #if DEBUG
        .onChange(of: showsNotice) { _, shows in noticeDebugLog(tag, "showsNotice -> \(shows)") }
        #endif
        .task(id: landed) {
            // One decision per open, read once from the flag and the tip gate, just before asking.
            if firstOpen.isDue(landed: landed, tipsAllowed: tipsAllowed()) {
                openNotice()
            }
        }
    }

    /// Opens the notice afresh, with no sheet up: the system may have closed the last popover with
    /// its sheet still up, so nothing cleared the flag.
    private func openNotice() {
        // The sheet's open handler retires the earlier report's presentation when the next opens.
        showsReport = false
        showsNotice = true
    }

    private var tag: String {
        #if DEBUG
        debugTag
        #else
        ""
        #endif
    }
}

/// The popover's content: the note, "Report a concern", and the report sheet it presents. An
/// answer from a report whose popover has gone cannot reach a later one: the shared sheet ties
/// each answer to its own presentation.
private struct AISummariesNoticePopover: View {
    let reportContent: () -> String
    let send: ReportConcernSend
    let tag: String
    @Binding var showsReport: Bool
    let reportPresentation: ReportPresentation
    /// The report is done: the popover closes.
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ChatViewLayout.aiNoticeSpacing) {
            Text(AISummariesNotice.title)
                .font(.headline)
            Text(AISummariesNotice.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showsReport = true
            } label: {
                Label(AISummariesNotice.reportTitle, systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.borderless)
            .tint(.red)
        }
        .padding()
        .frame(idealWidth: ChatViewLayout.aiNoticeWidth)
        .presentationCompactAdaptation(.popover)
        // The popover, which is on screen, presents the report sheet itself, so the two never
        // compete for one presenter. When the report is done, the popover closes.
        .reportConcernSheet(isPresented: $showsReport, contentType: .summary,
                            content: reportContent, contentNotice: AISummariesNotice.reportNotice,
                            send: send, onFinish: onFinish, presentation: reportPresentation)
        #if DEBUG
        .onChange(of: showsReport) { _, shows in noticeDebugLog(tag, "showsReport -> \(shows)") }
        #endif
    }
}

/// Debug-only trace of the notice's presentations, with what each key window has presented.
/// `@autoclosure`: a release build never builds the tag or the message, nor reads what they read.
@MainActor private func noticeDebugLog(_ tag: @autoclosure () -> String, _ message: @autoclosure () -> String) {
    #if DEBUG
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    let presented = windows.compactMap { window -> String? in
        var chain: [String] = []
        var controller = window.rootViewController?.presentedViewController
        while let current = controller {
            chain.append("\(type(of: current))\(current.isBeingDismissed ? "(dismissing)" : "")\(current.isBeingPresented ? "(presenting)" : "")")
            controller = current.presentedViewController
        }
        return chain.isEmpty ? nil : chain.joined(separator: ">")
    }
    print("[AINotice \(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] \(tag()) \(message()) | presented: \(presented)")
    #endif
}

/// Calls `onWindow` when UIKit puts this view in a window, which happens only for a presentation
/// that is actually shown.
private struct WindowProbe: UIViewRepresentable {
    let onWindow: () -> Void
    /// Runs when the probe leaves its window.
    var onDetach: () -> Void = {}

    final class Probe: UIView {
        var onWindow: () -> Void = {}
        var onDetach: () -> Void = {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow() } else { onDetach() }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onWindow = onWindow
        probe.onDetach = onDetach
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onWindow = onWindow
        probe.onDetach = onDetach
    }
}
