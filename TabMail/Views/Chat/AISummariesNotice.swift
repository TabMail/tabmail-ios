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
    /// The popover was asked for by the landing, not by a tap.
    @State private var autoRequested = false
    @State private var reportRequested = false
    @State private var showsReport = false
    /// UIKit has put the popover in a window. SwiftUI runs the popover's `onAppear` even when UIKit
    /// refuses the presentation (something else is presented), so only this counts as shown.
    @State private var onScreen = false
    #if DEBUG
    /// Tells mounted buttons apart in the debug log.
    @State private var debugTag = String(UUID().uuidString.prefix(4))
    #endif
    @ScaledMetric(relativeTo: .footnote) private var glyphSize = ChatViewLayout.aiNoticeGlyphSize

    var body: some View {
        Button {
            // A tap always shows it, whatever the landing asked for.
            autoRequested = false
            if showsNotice, !onScreen {
                // A refused presentation left the request set with nothing on screen, and SwiftUI
                // never retries it: clear it, then ask again on the next turn.
                showsNotice = false
                Task { @MainActor in showsNotice = true }
            } else {
                showsNotice = true
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
            popover
                .background(WindowProbe {
                    noticeDebugLog(tag, "probe attached; auto=\(autoRequested) due=\(firstOpen.isDue(landed: true, tipsAllowed: true)) shows=\(showsNotice)")
                    onScreen = true
                    // Another chat may have shown it since this one asked: then this one closes
                    // unseen, so it opens by itself at most once across every mounted chat.
                    if autoRequested, !firstOpen.isDue(landed: true, tipsAllowed: true) {
                        noticeDebugLog(tag, "at-most-once: already shown, closing")
                        autoRequested = false
                        showsNotice = false
                        return
                    }
                    autoRequested = false
                    firstOpen.markShown()
                    noticeDebugLog(tag, "marked shown")
                } onDetach: {
                    noticeDebugLog(tag, "probe detached")
                })
                .onDisappear {
                    noticeDebugLog(tag, "popover onDisappear; reportRequested=\(reportRequested)")
                    onScreen = false
                    // The sheet waits until the popover has gone: UIKit refuses a second
                    // presentation while the popover is still closing.
                    if reportRequested {
                        reportRequested = false
                        showsReport = true
                        noticeDebugLog(tag, "sheet requested")
                    }
                }
        }
        .onChange(of: showsNotice) { _, shows in noticeDebugLog(tag, "showsNotice -> \(shows)") }
        .onChange(of: showsReport) { _, shows in noticeDebugLog(tag, "showsReport -> \(shows)") }
        .reportConcernSheet(isPresented: $showsReport, contentType: .summary,
                            content: reportContent, contentNotice: AISummariesNotice.reportNotice, send: send)
        .task(id: landed) {
            // One decision per open, read once from the flag and the tip gate, just before asking.
            if firstOpen.isDue(landed: landed, tipsAllowed: tipsAllowed()) {
                autoRequested = true
                showsNotice = true
            } else if autoRequested {
                // A request still waiting to present is dropped once it is no longer due.
                autoRequested = false
                showsNotice = false
            }
        }
    }

    private var tag: String {
        #if DEBUG
        debugTag
        #else
        ""
        #endif
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

/// Debug-only trace of the notice's presentations, with what each key window has presented.
private func noticeDebugLog(_ tag: String, _ message: String) {
    #if DEBUG
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    let presented = windows.compactMap { window -> String? in
        var chain: [String] = []
        var controller = window.rootViewController?.presentedViewController
        while let current = controller {
            chain.append("\(type(of: current))\(current.isBeingDismissed ? "(dismissing)" : "")\(current.isBeingPresented ? "(presenting)" : "")")
            controller = current.presentedViewController
        }
        return chain.isEmpty ? nil : chain.joined(separator: ">")
    }
    print("[AINotice \(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] \(tag) \(message) | presented: \(presented)")
    #endif
}

/// Calls `onWindow` when UIKit puts this view in a window, which happens only for a presentation
/// that is actually shown.
private struct WindowProbe: UIViewRepresentable {
    let onWindow: () -> Void
    /// Debug trace only.
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
