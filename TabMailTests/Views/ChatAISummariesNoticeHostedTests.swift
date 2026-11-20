/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// The AI summaries notice, hosted in a real window and read through its accessibility elements.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Once the chat lands on the install's first open, the popover is on screen by itself; while
///     tips are held back, or on a later open, nothing is presented.
///  2. "Report a concern" opens the report sheet over the popover, with the line saying the chat's
///     summaries are sent; Report sends exactly the content the chat hands it; once the report is
///     done no popover remains, and the notice never opens by itself again.
///  3. The glyph reads "AI summaries, may contain errors" with its hint, keeps a full-size tap
///     target, and leaves the subject centred.
@Suite("Chat AI summaries notice, hosted", .serialized, .processGlobalState)
@MainActor
struct ChatAISummariesNoticeHostedTests {
    private static let width: CGFloat = 393
    private static let subject = "Budget review"

    @MainActor
    final class Sent {
        var contents: [String] = []
        var reports: [(ReportContentType, String)] = []
        /// What the backend answers.
        var accepted = false

        var send: ReportConcernSend {
            { [self] type, content, _, _ in reports.append((type, content)); return accepted }
        }
    }

    /// Drives `landed` on one mounted button, as the chat's landing does.
    @MainActor @Observable
    final class Landing {
        var landed = false
    }

    private struct LandingHost: View {
        let landing: Landing
        let firstOpen: AISummariesNotice.FirstOpen

        var body: some View {
            AISummariesNoticeButton(landed: landing.landed, reportContent: { "" }, firstOpen: firstOpen, tipsAllowed: { true })
        }
    }

    /// Drives whether tips are allowed, as onboarding does.
    @MainActor @Observable
    final class Gate {
        var allowed = true
    }

    private struct GatedHost: View {
        let landing: Landing
        let gate: Gate
        let firstOpen: AISummariesNotice.FirstOpen

        var body: some View {
            AISummariesNoticeButton(landed: landing.landed, reportContent: { "" }, firstOpen: firstOpen,
                                    tipsAllowed: { [gate] in gate.allowed })
        }
    }

    /// Two chats mounted at once, sharing the install's flag.
    private struct TwoChatsHost: View {
        let first: Landing
        let second: Landing
        let firstOpen: AISummariesNotice.FirstOpen

        var body: some View {
            VStack {
                LandingHost(landing: first, firstOpen: firstOpen)
                LandingHost(landing: second, firstOpen: firstOpen)
                Spacer()
            }
        }
    }

    private static func freshFirstOpen() -> AISummariesNotice.FirstOpen {
        let name = "ChatAISummariesNoticeHostedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AISummariesNotice.FirstOpen(defaults: defaults)
    }

    /// Hosts `view` in a window and runs `body` with its controller, then takes the window down.
    private static func hosting(_ view: some View, _ body: @MainActor (UIHostingController<AnyView>) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
        let controller = UIHostingController(rootView: AnyView(view))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body(controller)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func element(_ label: String, in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == label }
    }

    /// The presentation on top: the report sheet sits on the popover that presents it.
    private static func topPresented(_ controller: UIViewController) -> UIViewController? {
        var top = controller.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private static func presentedLabels(_ controller: UIViewController) -> [String] {
        topPresented(controller).map { HostedAccessibility.labels(in: $0.view) } ?? []
    }

    /// Hosts a landed button on `firstOpen` and checks that it does not open by itself.
    private static func expectNeverOpensAgain(_ firstOpen: AISummariesNotice.FirstOpen) async throws {
        #expect(!firstOpen.isDue(landed: true, tipsAllowed: true), "the notice is used up")
        try await hosting(button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
            try await Task.sleep(for: .seconds(1))
            #expect(controller.presentedViewController == nil, "a later open presents nothing")
        }
    }

    private static func button(landed: Bool, firstOpen: AISummariesNotice.FirstOpen, tipsAllowed: Bool,
                               sent: Sent? = nil, content: String = "") -> AISummariesNoticeButton {
        AISummariesNoticeButton(landed: landed, reportContent: { sent?.contents.append(content); return content },
                                firstOpen: firstOpen, tipsAllowed: { tipsAllowed },
                                send: (sent ?? Sent()).send)
    }

    // MARK: - 1. Opening by itself

    @Test("The first landed open presents the notice by itself; a later open presents nothing")
    func presentsOnTheFirstOpenOnly() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                let shown = Self.presentedLabels(controller)
                #expect(shown.contains(AISummariesNotice.title) && shown.contains(AISummariesNotice.message),
                        "the popover is on screen by itself: \(shown)")
            }
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "a later open presents nothing")
            }
        }
    }

    @Test("While tips are held back, or before the landing, nothing is presented")
    func suppressedWhileHeldBack() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: false)) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "sample mail or the tutorial: nothing opens")
            }
            try await Self.hosting(Self.button(landed: false, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "before the landing: nothing opens")
            }
            // Neither used it up.
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title))
            }
        }
    }

    // MARK: - 2. Report a concern

    @Test("Report a concern hands over to the sheet with its line, and Report sends the chat's content")
    func reportHandsOverToTheSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let sent = Sent()
        let content = "Newest summary\n\nOldest summary"
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: false, firstOpen: firstOpen, tipsAllowed: true,
                                               sent: sent, content: content)) { controller in
                let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: controller.view))
                #expect(glyph.accessibilityActivate(), "the glyph takes a press")
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.reportTitle) }
                let popover = try #require(controller.presentedViewController?.view, "a tap opens the popover")
                let report = try #require(Self.element(AISummariesNotice.reportTitle, in: popover))
                #expect(report.accessibilityActivate(), "Report a concern takes a press")
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice) }
                let sheet = Self.presentedLabels(controller)
                #expect(sheet.contains(AISummariesNotice.reportNotice), "the sheet says the summaries are sent: \(sheet)")
                #expect(sheet.contains(ReportConcernSheetText.storedForReview), "and keeps the consent line: \(sheet)")
                #expect(!sheet.contains(AISummariesNotice.title), "the sheet is on top: \(sheet)")
                let sheetView = try #require(Self.topPresented(controller)?.view)
                let submit = try #require(Self.element("Report", in: sheetView), "\(sheet)")
                #expect(submit.accessibilityActivate(), "Report takes a press")
                try await Self.waitUntil { !sent.contents.isEmpty }
                #expect(sent.contents == [content], "Report sends the chat's content as handed over")
                try await Self.waitUntil { !sent.reports.isEmpty }
                #expect(sent.reports.count == 1)
                #expect(sent.reports.first?.0 == .summary, "a summary report")
                #expect(sent.reports.first?.1 == content, "with the newest-first content")
                try await Self.waitUntil { controller.presentedViewController == nil }
                #expect(controller.presentedViewController == nil,
                        "the sheet closed and no popover remains: \(String(describing: Self.topPresented(controller)))")
            }
            try await Self.expectNeverOpensAgain(firstOpen)
        }
    }

    @Test("The report covers the emails and the replies still sending or not sent, newest first")
    func reportIncludesUnsentReplies() {
        func item(_ id: String, _ summary: String?) -> ChatThread.Item {
            var header = MessageHeader(
                messageId: id, subject: Self.subject, from: "Alex", fromAddress: "alex@example.com",
                to: "me@example.com", date: Date(), snippet: "", folderId: "acc:INBOX",
                accountId: "acc", folderPath: "INBOX", isInInbox: true)
            header.summaryTextMessage = summary
            return ChatThread.Item(header: header, isOwn: false, sender: .init(address: "alex@example.com", name: "Alex"),
                                   repliedOnlyTo: nil, showsTimeStamp: false, showsUnreadLine: false)
        }
        let content = AISummariesNotice.reportContent(
            items: [item("1", "First email"), item("2", nil), item("3", "Second email")],
            unsent: [ChatUnsentReply(outboxId: "o1", failed: true, filed: false, textMessage: "Not sent reply"),
                     ChatUnsentReply(outboxId: "o2", failed: false, filed: false, textMessage: nil),
                     ChatUnsentReply(outboxId: "o3", failed: false, filed: false, textMessage: "Sending reply")])
        #expect(content == "Sending reply\n\nNot sent reply\n\nSecond email\n\nFirst email")
    }

    @Test("The long-press report is unchanged: no extra line, the pressed content")
    func longPressUnchanged() throws {
        #expect(ReportConcernSheetText.consentLines(contentNotice: nil) == [ReportConcernSheetText.storedForReview])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Components/ReportConcernModifier.swift"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(source.components(separatedBy: ".reportConcernSheet(isPresented: $showSheet, contentType: contentType, content: { content })").count == 2,
                "the long-press sheet sends the pressed content with no extra line")
    }

    // MARK: - 3. The glyph

    @Test("The glyph reads its label and hint, keeps a full-size target, and the subject stays centred")
    func glyphAccessibilityAndLayout() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        try await HostedAccessibility.withAutomation {
            let line = VStack { ChatSubjectLine(subject: Self.subject, labels: [], landed: false, reportContent: { "" }); Spacer() }
            try await Self.hosting(line) { controller in
                try await Self.waitUntil { Self.element(AISummariesNotice.accessibilityLabel, in: controller.view) != nil }
                let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: controller.view),
                                         "\(HostedAccessibility.labels(in: controller.view))")
                #expect(glyph.accessibilityHint == AISummariesNotice.accessibilityHint)
                let target = glyph.accessibilityFrame
                #expect(target.width >= ChatViewLayout.aiNoticeTapTarget && target.height >= ChatViewLayout.aiNoticeTapTarget,
                        "a full-size tap target: \(target)")
                #expect(ChatViewLayout.aiNoticeTapTarget >= 44, "Apple's minimum")
                #expect(target.maxX <= Self.width && target.midX > Self.width / 2, "at the trailing edge: \(target)")
                let title = try #require(Self.element(Self.subject, in: controller.view))
                #expect(abs(title.accessibilityFrame.midX - Self.width / 2) <= 1, "the subject stays centred: \(title.accessibilityFrame)")
                #expect(!title.accessibilityFrame.intersects(target), "the subject clears the glyph")
            }
        }
    }

    // MARK: - The landing, the default gate, and the long-press control

    @Test("The same mounted button opens the notice when its chat lands")
    func opensWhenTheSameViewLands() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        let landing = Landing()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(LandingHost(landing: landing, firstOpen: Self.freshFirstOpen())) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "control: nothing before the landing")
                landing.landed = true
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "the landing opens it")
            }
        }
    }

    @Test("The default gate holds the notice back until onboarding completes, without using it up")
    func defaultGateFollowsOnboarding() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        let saved = OnboardingTipGate.onboardingComplete
        defer { OnboardingTipGate.onboardingComplete = saved }
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            OnboardingTipGate.onboardingComplete = false
            try await Self.hosting(AISummariesNoticeButton(landed: true, reportContent: { "" }, firstOpen: firstOpen)) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "held back while onboarding is not complete")
            }
            OnboardingTipGate.onboardingComplete = true
            try await Self.hosting(AISummariesNoticeButton(landed: true, reportContent: { "" }, firstOpen: firstOpen)) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "shown once onboarding completes")
            }
        }
    }

    @Test("Control: the long-press sheet sends its own type and pressed content, with no extra line")
    func longPressSheetSendsItsOwnReport() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let sent = Sent()
        try await HostedAccessibility.withAutomation {
            let view = Color.clear.reportConcernSheet(isPresented: .constant(true), contentType: .suggestedReply,
                                                      content: { "pressed reply" }, send: sent.send)
            try await Self.hosting(view) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(ReportConcernSheetText.storedForReview) }
                let sheet = Self.presentedLabels(controller)
                #expect(!sheet.contains(AISummariesNotice.reportNotice), "no summaries line: \(sheet)")
                let sheetView = try #require(controller.presentedViewController?.view)
                let submit = try #require(Self.element("Report", in: sheetView), "\(sheet)")
                #expect(submit.accessibilityActivate())
                try await Self.waitUntil { !sent.reports.isEmpty }
                #expect(sent.reports.count == 1)
                #expect(sent.reports.first?.0 == .suggestedReply)
                #expect(sent.reports.first?.1 == "pressed reply")
            }
        }
    }

    /// The long-press report's sheet as its caller attaches it: no `onFinish`, closed by its own state.
    private struct LongPressHost: View {
        let send: ReportConcernSend
        @State private var shows = true

        var body: some View {
            Color.clear.reportConcernSheet(isPresented: $shows, contentType: .suggestedReply,
                                           content: { "pressed reply" }, send: send)
        }
    }

    @Test("A long-press report the backend takes closes the sheet and says it was submitted")
    func longPressSubmittedReportShowsTheAlert() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let sent = Sent()
        sent.accepted = true
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(LongPressHost(send: sent.send)) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(ReportConcernSheetText.storedForReview) }
                let sheetView = try #require(Self.topPresented(controller)?.view)
                let submit = try #require(Self.element("Report", in: sheetView), "\(Self.presentedLabels(controller))")
                #expect(submit.accessibilityActivate())
                try await Self.waitUntil { (Self.topPresented(controller) as? UIAlertController)?.title == "Report Submitted" }
                #expect((Self.topPresented(controller) as? UIAlertController)?.title == "Report Submitted",
                        "the sheet closed and the alert shows: \(String(describing: Self.topPresented(controller)))")
                #expect(sent.reports.count == 1)
                #expect(sent.reports.first?.0 == .suggestedReply)
            }
        }
    }

    /// Sends the test holds, each until it releases that send's answer.
    @MainActor
    final class HeldSend {
        var started = 0
        var categories: [ReportCategory] = []
        var reasons: [String?] = []
        private var answers: [Int: CheckedContinuation<Bool, Never>] = [:]

        var send: ReportConcernSend {
            { [self] _, _, category, reason in
                started += 1
                let call = started
                categories.append(category)
                reasons.append(reason)
                return await withCheckedContinuation { answers[call] = $0 }
            }
        }

        /// Answers the oldest send still held.
        func release(_ accepted: Bool) {
            if let oldest = answers.keys.min() { release(oldest, accepted) }
        }

        /// Answers send number `call` (1 for the first).
        func release(_ call: Int, _ accepted: Bool) {
            answers.removeValue(forKey: call)?.resume(returning: accepted)
        }
    }

    /// Whether a retained caller's sheet is open, driven from the test.
    @MainActor @Observable
    final class SheetState {
        var open = true
    }

    /// Counts the sheet's `onFinish` calls.
    @MainActor
    final class Finishes {
        var count = 0
    }

    /// A caller kept on screen across two reports, as a long-press caller is.
    private struct RetainedHost: View {
        @Bindable var state: SheetState
        let send: ReportConcernSend
        var finishes = Finishes()

        var body: some View {
            Color.clear.reportConcernSheet(isPresented: $state.open, contentType: .suggestedReply,
                                           content: { "pressed reply" }, send: send,
                                           onFinish: { [finishes] in finishes.count += 1 })
        }
    }

    /// Whether an owner is in the hierarchy; removing it destroys its state.
    @MainActor @Observable
    final class Alive {
        var on = true
    }

    /// A caller that owns its own presentation state, as the long-press wrapper does.
    private struct OwnedHost: View {
        let send: ReportConcernSend
        @State private var open = true

        var body: some View {
            Color.clear.reportConcernSheet(isPresented: $open, contentType: .suggestedReply,
                                           content: { "pressed reply" }, send: send)
        }
    }

    /// Removes and recreates `owner` as `alive` changes, as a reload or navigation change does.
    private struct OwnerSwitch<Owner: View>: View {
        let alive: Alive
        @ViewBuilder let owner: () -> Owner

        var body: some View {
            VStack {
                if alive.on { owner() }
                Spacer()
            }
        }
    }

    /// The first view of type `T` under `view`.
    private static func firstSubview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstSubview(type, in: child) { return match }
        }
        return nil
    }

    /// The sheet on top shows its defaults: the first category and no reason.
    private static func expectFreshForm(in controller: UIViewController, _ note: String) throws {
        let sheetView = try #require(topPresented(controller)?.view)
        let categories = try #require(firstSubview(UISegmentedControl.self, in: sheetView), "control: the category picker")
        #expect(categories.selectedSegmentIndex == 0, "\(note): the default category")
        let reason = try #require(firstSubview(UITextView.self, in: sheetView), "control: the reason field")
        #expect(reason.text.isEmpty, "\(note): an empty reason, got \(String(describing: reason.text))")
    }

    /// Picks Inaccurate and types a reason into the sheet on top.
    private static func fillForm(in controller: UIViewController, reason: String) async throws {
        let sheetView = try #require(topPresented(controller)?.view)
        let inaccurate = try #require(element(ReportCategory.inaccurate.displayName, in: sheetView))
        #expect(inaccurate.accessibilityActivate())
        let field = try #require(firstSubview(UITextView.self, in: sheetView), "control: the reason field")
        #expect(field.becomeFirstResponder())
        field.insertText(reason)
        try await waitUntil { firstSubview(UISegmentedControl.self, in: sheetView)?.selectedSegmentIndex == 1 }
        #expect(firstSubview(UISegmentedControl.self, in: sheetView)?.selectedSegmentIndex == 1, "control: Inaccurate is picked")
        #expect(field.text == reason, "control: the reason was typed")
    }

    /// Presses the alert's OK as the user does: UIKit dismisses the alert, then runs that
    /// button's own handler. An alert's action views do not answer `accessibilityActivate` in a
    /// hosted test, so this follows `UndoProviderIdentitySafetyTests.tapOK`.
    private static func pressOK(on alert: UIAlertController) throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let ok = try #require(alert.actions.first { $0.title == "OK" }, "the alert has an OK button")
        try #require(ok.responds(to: NSSelectorFromString("handler")), "UIAlertAction exposes its handler")
        let block = try #require(ok.value(forKey: "handler") as AnyObject?, "the OK button has a handler")
        let handler = unsafeBitCast(block, to: Handler.self)
        alert.dismiss(animated: false) { handler(ok) }
    }

    private static func sheetIsUp(_ controller: UIViewController) -> Bool {
        presentedLabels(controller).contains(ReportConcernSheetText.storedForReview)
    }

    private static func isEnabled(_ label: String, in view: UIView) -> Bool {
        element(label, in: view).map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
    }

    /// Presses Report on the sheet on top and waits for `held` to receive the send.
    private static func pressReport(in controller: UIViewController, held: HeldSend, sends: Int = 1) async throws {
        let sheetView = try #require(topPresented(controller)?.view, "control: the sheet appeared")
        let submit = try #require(element("Report", in: sheetView))
        #expect(submit.accessibilityActivate())
        try await waitUntil { held.started == sends }
        #expect(held.started == sends, "control: the send started")
    }

    /// Cancels the sheet on top and checks that nothing, no alert either, is presented after.
    private static func cancelShowsNothing(in controller: UIViewController) async throws {
        let sheetView = try #require(topPresented(controller)?.view, "control: a sheet to cancel")
        let cancel = try #require(element("Cancel", in: sheetView))
        #expect(cancel.accessibilityActivate())
        try await waitUntil { controller.presentedViewController == nil }
        try await Task.sleep(for: .seconds(1))
        #expect(controller.presentedViewController == nil,
                "a cancelled report shows nothing: \(String(describing: topPresented(controller)))")
    }

    @Test("While a report is sending the sheet stays; its answer shows once; a later cancelled report shows nothing")
    func aSendingReportKeepsTheSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let state = SheetState()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(RetainedHost(state: state, send: held.send)) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(ReportConcernSheetText.storedForReview) }
                let sheetView = try #require(Self.topPresented(controller)?.view, "control: the sheet appeared")
                let submit = try #require(Self.element("Report", in: sheetView))
                #expect(submit.accessibilityActivate())
                try await Self.waitUntil { held.started == 1 }
                #expect(held.started == 1, "control: the send started")
                // While the send is held, Cancel is disabled and the sheet stays.
                try await Self.waitUntil { Self.element("Cancel", in: sheetView)?.accessibilityTraits.contains(.notEnabled) == true }
                let cancel = try #require(Self.element("Cancel", in: sheetView))
                #expect(cancel.accessibilityTraits.contains(.notEnabled), "Cancel is disabled while sending")
                _ = cancel.accessibilityActivate()
                try await Task.sleep(for: .seconds(1))
                #expect(Self.presentedLabels(controller).contains(ReportConcernSheetText.storedForReview), "the sheet stays")
                // The answer arrives: exactly one alert.
                held.release(true)
                try await Self.waitUntil { (Self.topPresented(controller) as? UIAlertController)?.title == "Report Submitted" }
                let alert = try #require(Self.topPresented(controller) as? UIAlertController, "the alert shows")
                #expect(controller.presentedViewController === alert, "only the alert is presented: \(String(describing: controller.presentedViewController))")
                try Self.pressOK(on: alert)
                try await Self.waitUntil { controller.presentedViewController == nil }
                #expect(controller.presentedViewController == nil, "control: the alert closed")
                // The same caller reports again and cancels: no alert.
                state.open = true
                try await Self.waitUntil { Self.presentedLabels(controller).contains(ReportConcernSheetText.storedForReview) }
                let again = try #require(Self.topPresented(controller)?.view, "control: the sheet appeared again")
                let cancelAgain = try #require(Self.element("Cancel", in: again))
                #expect(cancelAgain.accessibilityActivate())
                try await Self.waitUntil { controller.presentedViewController == nil }
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil,
                        "a cancelled report shows no alert: \(String(describing: Self.topPresented(controller)))")
                #expect(held.started == 1, "the cancelled report sent nothing")
            }
        }
    }

    // MARK: - After a report

    /// Opens the popover with the glyph and presses "Report a concern"; returns once the sheet shows.
    /// The popover and its report sheet are both up, and neither is still being presented.
    private static func presentationSettled(_ controller: UIViewController) -> Bool {
        var chain: [UIViewController] = []
        var current = controller.presentedViewController
        while let next = current {
            chain.append(next)
            current = next.presentedViewController
        }
        return chain.count == 2 && chain.allSatisfy { !$0.isBeingPresented && !$0.isBeingDismissed }
    }

    private static func openReport(in controller: UIViewController) async throws {
        let glyph = try #require(element(AISummariesNotice.accessibilityLabel, in: controller.view))
        #expect(glyph.accessibilityActivate())
        try await waitUntil { presentedLabels(controller).contains(AISummariesNotice.reportTitle) }
        let popover = try #require(topPresented(controller)?.view)
        let report = try #require(element(AISummariesNotice.reportTitle, in: popover))
        #expect(report.accessibilityActivate())
        try await waitUntil { presentedLabels(controller).contains(AISummariesNotice.reportNotice) }
    }

    @Test("After one report, closing the popover again opens no sheet")
    func aClosedPopoverDoesNotReopenTheSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: false, firstOpen: firstOpen, tipsAllowed: true,
                                               sent: Sent())) { controller in
                try await Self.openReport(in: controller)
                let sheetView = try #require(Self.topPresented(controller)?.view)
                let cancel = try #require(Self.element("Cancel", in: sheetView))
                #expect(cancel.accessibilityActivate())
                try await Self.waitUntil { controller.presentedViewController == nil }
                #expect(controller.presentedViewController == nil, "Cancel closes the sheet and the popover")
                // Open the popover and close it without reporting.
                let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: controller.view))
                #expect(glyph.accessibilityActivate())
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "control: the second tap opens it")
                controller.presentedViewController?.dismiss(animated: false)
                try await Self.waitUntil { controller.presentedViewController == nil }
                try await Task.sleep(for: .seconds(1))
                #expect(!Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice),
                        "no sheet after a plain close: \(Self.presentedLabels(controller))")
            }
            try await Self.expectNeverOpensAgain(firstOpen)
        }
    }

    @Test("A report the backend takes closes the sheet and says it was submitted")
    func submittedReportClosesTheSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let sent = Sent()
        sent.accepted = true
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: false, firstOpen: firstOpen, tipsAllowed: true,
                                               sent: sent, content: "Summary")) { controller in
                try await Self.openReport(in: controller)
                let sheetView = try #require(Self.topPresented(controller)?.view)
                let submit = try #require(Self.element("Report", in: sheetView))
                #expect(submit.accessibilityActivate())
                try await Self.waitUntil { (Self.topPresented(controller) as? UIAlertController)?.title == "Report Submitted" }
                let alert = try #require(Self.topPresented(controller) as? UIAlertController,
                                         "the sheet closed and the alert shows: \(String(describing: Self.topPresented(controller)))")
                #expect(alert.title == "Report Submitted")
                #expect(!Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice), "the sheet is gone")
                try Self.pressOK(on: alert)
                try await Self.waitUntil { controller.presentedViewController == nil }
                #expect(controller.presentedViewController == nil,
                        "after OK no popover remains: \(String(describing: Self.topPresented(controller)))")
            }
            try await Self.expectNeverOpensAgain(firstOpen)
        }
    }

    // MARK: - A landing that cannot present

    @Test("A landing that could not present the notice leaves it for the next open; once shown it never opens again")
    func anUnpresentedNoticeIsNotUsedUp() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            // The chat lands while something else is presented (a push still running): the
            // popover cannot be presented.
            let blocker = UIViewController()
            try await Self.hosting(Color.clear) { controller in
                controller.present(blocker, animated: false)
                try await Self.waitUntil { controller.presentedViewController === blocker }
                let notice = UIHostingController(rootView: Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true))
                controller.addChild(notice)
                controller.view.addSubview(notice.view)
                notice.view.frame = controller.view.bounds
                notice.didMove(toParent: controller)
                try await Task.sleep(for: .seconds(1))
                #expect(!Self.presentedLabels(controller).contains(AISummariesNotice.title)
                        && !Self.presentedLabels(blocker).contains(AISummariesNotice.title),
                        "control: the notice was not on screen")
                notice.willMove(toParent: nil)
                notice.view.removeFromSuperview()
                notice.removeFromParent()
                blocker.dismiss(animated: false)
            }
            // The next open shows it.
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title),
                        "a notice that never showed is still due")
            }
            // Once shown, never by itself again.
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "shown once: never again")
            }
        }
    }

    // MARK: - At most once, across every mounted chat

    @Test("A notice the user already opened by hand does not open by itself when the chat lands")
    func aManualOpenUsesItUp() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let landing = Landing()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(LandingHost(landing: landing, firstOpen: Self.freshFirstOpen())) { controller in
                let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: controller.view))
                #expect(glyph.accessibilityActivate())
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "control: a tap opens it")
                controller.presentedViewController?.dismiss(animated: false)
                try await Self.waitUntil { controller.presentedViewController == nil }
                landing.landed = true
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "already seen: the landing opens nothing")
            }
        }
    }

    @Test("Two mounted chats landing open the notice at most once: one after the other exactly once; in one frame at most once, and a notice nobody saw opens on a later open")
    func twoChatsOpenItOnce() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        for order in [[0, 1], [1, 0], [nil]] as [[Int?]] {
            let chats = [Landing(), Landing()]
            let firstOpen = Self.freshFirstOpen()
            let sameFrame = order == [nil]
            try await HostedAccessibility.withAutomation {
                try await Self.hosting(TwoChatsHost(first: chats[0], second: chats[1], firstOpen: firstOpen)) { controller in
                    var opens = 0
                    for step in order {
                        if let step { chats[step].landed = true } else { chats.forEach { $0.landed = true } }
                        if sameFrame {
                            try await Task.sleep(for: .seconds(1))
                        } else {
                            try await Self.waitUntil { controller.presentedViewController != nil }
                        }
                        try await Task.sleep(for: .milliseconds(500))
                        if Self.presentedLabels(controller).contains(AISummariesNotice.title) {
                            opens += 1
                            controller.presentedViewController?.dismiss(animated: false)
                            try await Self.waitUntil { controller.presentedViewController == nil }
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                    #expect(controller.presentedViewController == nil, "order \(order): nothing more opens")
                    if sameFrame {
                        // Two popovers asked for in one update: UIKit may show neither. At most one,
                        // and a notice nobody saw is still due.
                        #expect(opens <= 1, "same frame: at most one open, got \(opens)")
                        if opens == 0 {
                            #expect(firstOpen.isDue(landed: true, tipsAllowed: true), "same frame: nothing shown, still due")
                        }
                    } else {
                        #expect(opens == 1, "order \(order): exactly one open, got \(opens)")
                    }
                }
                guard sameFrame, firstOpen.isDue(landed: true, tipsAllowed: true) else { return }
                // A later single open shows it, exactly once.
                try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                    try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                    #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "a later open shows it")
                }
                try await Self.expectNeverOpensAgain(firstOpen)
            }
        }
    }

    @Test("A pending landing whose chat is no longer eligible does not open later")
    func aWithdrawnLandingDoesNotOpen() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted view")
        let landing = Landing()
        let gate = Gate()
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            let blocker = UIViewController()
            try await Self.hosting(Color.clear) { controller in
                controller.present(blocker, animated: false)
                try await Self.waitUntil { controller.presentedViewController === blocker }
                let notice = UIHostingController(rootView: GatedHost(landing: landing, gate: gate, firstOpen: firstOpen))
                controller.addChild(notice)
                controller.view.addSubview(notice.view)
                notice.view.frame = controller.view.bounds
                notice.didMove(toParent: controller)
                // Lands while it cannot present: the request is pending.
                landing.landed = true
                try await Task.sleep(for: .seconds(1))
                // Re-entered while held back.
                gate.allowed = false
                landing.landed = false
                try await Task.sleep(for: .milliseconds(300))
                landing.landed = true
                try await Task.sleep(for: .milliseconds(300))
                blocker.dismiss(animated: false)
                try await Self.waitUntil { controller.presentedViewController == nil }
                try await Task.sleep(for: .seconds(1))
                #expect(!Self.presentedLabels(controller).contains(AISummariesNotice.title),
                        "held back on re-entry: the old request is gone")
                #expect(firstOpen.isDue(landed: true, tipsAllowed: true), "and it was never used up")
                notice.willMove(toParent: nil)
                notice.view.removeFromSuperview()
                notice.removeFromParent()
            }
        }
    }

    // MARK: - A tap always shows it

    @Test("After the notice was seen, a tap opens it and it stays open")
    func aTapReopensASeenNotice() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let firstOpen = Self.freshFirstOpen()
        firstOpen.markShown()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true)) { controller in
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "control: seen, so the landing opens nothing")
                let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: controller.view))
                #expect(glyph.accessibilityActivate())
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "the tap opens it")
                try await Task.sleep(for: .seconds(1))
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "and it stays open")
            }
        }
    }

    @Test("A chat that landed under another screen: once it closes, a tap opens the notice and it stays open, even though another chat showed it")
    func aTapAfterARefusedLandingStaysOpen() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            let blocker = UIViewController()
            try await Self.hosting(Color.clear) { controller in
                controller.present(blocker, animated: false)
                try await Self.waitUntil { controller.presentedViewController === blocker }
                // The chat lands while another screen is up: UIKit refuses the popover, and the
                // automatic request stays set.
                let notice = UIHostingController(rootView: Self.button(landed: true, firstOpen: firstOpen, tipsAllowed: true))
                controller.addChild(notice)
                controller.view.addSubview(notice.view)
                notice.view.frame = controller.view.bounds
                notice.didMove(toParent: controller)
                try await Task.sleep(for: .seconds(1))
                #expect(firstOpen.isDue(landed: true, tipsAllowed: true), "control: the refused popover did not use it up")
                blocker.dismiss(animated: false)
                try await Self.waitUntil { controller.presentedViewController == nil }
                firstOpen.markShown()  // another chat shows it
                // The user taps the glyph, now on screen.
                let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: notice.view))
                #expect(glyph.accessibilityActivate(), "the user taps")
                try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "the tap opens it")
                try await Task.sleep(for: .seconds(1))
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title), "and it stays open")
                controller.presentedViewController?.dismiss(animated: false)
                notice.willMove(toParent: nil)
                notice.view.removeFromSuperview()
                notice.removeFromParent()
            }
        }
    }

    // MARK: - An answer that outlives its sheet

    @Test("A sheet closed by its caller while sending: an answer before the next report changes nothing")
    func aClosedSheetsAnswerBeforeTheNextReport() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let state = SheetState()
        let finishes = Finishes()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(RetainedHost(state: state, send: held.send, finishes: finishes)) { controller in
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                try await Self.pressReport(in: controller, held: held)
                state.open = false  // the caller closes it while the report is sending
                try await Self.waitUntil { controller.presentedViewController == nil }
                #expect(controller.presentedViewController == nil, "control: the sheet closed")
                let finished = finishes.count
                held.release(true)
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "the old answer shows nothing")
                #expect(finishes.count == finished, "and finishes nothing")
                state.open = true
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                let sheetView = try #require(Self.topPresented(controller)?.view, "control: the next sheet appeared")
                #expect(Self.isEnabled("Report", in: sheetView) && Self.isEnabled("Cancel", in: sheetView),
                        "the next report starts afresh")
                try await Self.cancelShowsNothing(in: controller)
                #expect(finishes.count == finished + 1, "only the next report's own finish")
            }
        }
    }

    @Test("A sheet closed by its caller while sending: an answer during the next report leaves it alone")
    func aClosedSheetsAnswerDuringTheNextReport() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let state = SheetState()
        let finishes = Finishes()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(RetainedHost(state: state, send: held.send, finishes: finishes)) { controller in
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                try await Self.pressReport(in: controller, held: held)
                state.open = false
                try await Self.waitUntil { controller.presentedViewController == nil }
                state.open = true
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                #expect(Self.sheetIsUp(controller), "control: the next sheet appeared")
                let finished = finishes.count
                held.release(true)
                try await Task.sleep(for: .seconds(1))
                #expect(Self.sheetIsUp(controller) && state.open, "the old answer does not close the next sheet")
                let sheetView = try #require(Self.topPresented(controller)?.view)
                #expect(Self.isEnabled("Report", in: sheetView) && Self.isEnabled("Cancel", in: sheetView),
                        "nor changes its state")
                #expect(finishes.count == finished, "nor finishes it")
                try await Self.cancelShowsNothing(in: controller)
            }
        }
    }

    @Test("An owner removed while sending, then recreated: its old answer reaches nothing, before or after")
    func aRemovedOwnersAnswerReachesNothing() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        for answerFirst in [true, false] {
            let held = HeldSend()
            let alive = Alive()
            try await HostedAccessibility.withAutomation {
                try await Self.hosting(OwnerSwitch(alive: alive) { OwnedHost(send: held.send) }) { controller in
                    try await Self.waitUntil { Self.sheetIsUp(controller) }
                    try await Self.pressReport(in: controller, held: held)
                    alive.on = false  // a reload removes the owner while the report is sending
                    try await Self.waitUntil { controller.presentedViewController == nil }
                    #expect(controller.presentedViewController == nil, "control: the owner and its sheet are gone")
                    if answerFirst {
                        held.release(true)
                        try await Task.sleep(for: .seconds(1))
                        #expect(controller.presentedViewController == nil, "answer first: nothing shows")
                    }
                    alive.on = true
                    try await Self.waitUntil { Self.sheetIsUp(controller) }
                    #expect(Self.sheetIsUp(controller), "control: the recreated owner's sheet appeared")
                    if !answerFirst {
                        held.release(true)
                        try await Task.sleep(for: .seconds(1))
                        #expect(Self.sheetIsUp(controller), "answer after: the new sheet stays")
                    }
                    let sheetView = try #require(Self.topPresented(controller)?.view)
                    #expect(Self.isEnabled("Report", in: sheetView), "the new sheet starts afresh")
                    try await Self.cancelShowsNothing(in: controller)
                }
            }
        }
    }

    @Test("The notice's report: an answer from a removed notice never reaches the next notice's report")
    func aRemovedNoticesAnswerReachesNothing() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let alive = Alive()
        let firstOpen = Self.freshFirstOpen()
        try await HostedAccessibility.withAutomation {
            let notice = OwnerSwitch(alive: alive) {
                AISummariesNoticeButton(landed: false, reportContent: { "Summary" }, firstOpen: firstOpen,
                                        tipsAllowed: { true }, send: held.send)
            }
            try await Self.hosting(notice) { controller in
                try await Self.openReport(in: controller)
                try await Self.pressReport(in: controller, held: held)
                alive.on = false  // the chat is removed while the report is sending
                try await Self.waitUntil { controller.presentedViewController == nil }
                #expect(controller.presentedViewController == nil, "control: the notice and its report are gone")
                alive.on = true
                try await Self.waitUntil { Self.element(AISummariesNotice.accessibilityLabel, in: controller.view) != nil }
                try await Self.openReport(in: controller)
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice), "control: the next report's sheet")
                held.release(true)
                try await Task.sleep(for: .seconds(1))
                #expect(Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice),
                        "the old answer does not close the next report")
                try await Self.cancelShowsNothing(in: controller)
            }
        }
    }

    @Test("A report sending in another category cannot be cancelled either")
    func anotherCategoryCannotBeCancelledWhileSending() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let state = SheetState()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(RetainedHost(state: state, send: held.send)) { controller in
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                let sheetView = try #require(Self.topPresented(controller)?.view)
                let inaccurate = try #require(Self.element(ReportCategory.inaccurate.displayName, in: sheetView),
                                              "\(HostedAccessibility.labels(in: sheetView))")
                #expect(inaccurate.accessibilityActivate())
                try await Self.pressReport(in: controller, held: held)
                #expect(held.categories == [.inaccurate], "control: sent as Inaccurate")
                #expect(!Self.isEnabled("Cancel", in: sheetView), "Cancel is disabled while sending")
                _ = Self.element("Cancel", in: sheetView)?.accessibilityActivate()
                try await Task.sleep(for: .seconds(1))
                #expect(Self.sheetIsUp(controller) && state.open, "the sheet stays")
                held.release(false)
                try await Self.waitUntil { controller.presentedViewController == nil }
                try await Task.sleep(for: .seconds(1))
                #expect(controller.presentedViewController == nil, "a report not taken closes with no alert")
            }
        }
    }

    @Test("A swipe down while a report is sending does not close the sheet")
    func aSwipeCannotCloseASendingSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let state = SheetState()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(RetainedHost(state: state, send: held.send)) { controller in
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                let sheet = try #require(Self.topPresented(controller))
                #expect(!sheet.isModalInPresentation, "control: before sending, a swipe may close it")
                try await Self.pressReport(in: controller, held: held)
                try await Self.waitUntil { sheet.isModalInPresentation }
                #expect(sheet.isModalInPresentation, "while sending, a swipe cannot close it")
                try await Task.sleep(for: .seconds(1))
                #expect(Self.sheetIsUp(controller) && state.open, "the sheet stays")
                held.release(false)
                try await Self.waitUntil { controller.presentedViewController == nil }
            }
        }
    }

    // MARK: - Two sends in flight, the notice's own popover, and a fresh form

    @Test("An old answer, taken or not, leaves the next report's sending sheet open and disabled until its own answer")
    func anOldAnswerLeavesTheNextSendAlone() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        for oldAccepted in [true, false] {
            let held = HeldSend()
            let state = SheetState()
            try await HostedAccessibility.withAutomation {
                try await Self.hosting(RetainedHost(state: state, send: held.send)) { controller in
                    try await Self.waitUntil { Self.sheetIsUp(controller) }
                    try await Self.pressReport(in: controller, held: held)
                    state.open = false
                    try await Self.waitUntil { controller.presentedViewController == nil }
                    state.open = true
                    try await Self.waitUntil { Self.sheetIsUp(controller) }
                    try await Self.pressReport(in: controller, held: held, sends: 2)
                    let sheetView = try #require(Self.topPresented(controller)?.view)
                    #expect(!Self.isEnabled("Report", in: sheetView) && !Self.isEnabled("Cancel", in: sheetView),
                            "control: the second send is in flight")
                    held.release(1, oldAccepted)
                    try await Task.sleep(for: .seconds(1))
                    #expect(Self.sheetIsUp(controller) && state.open, "old answer \(oldAccepted): the sheet stays")
                    #expect(!Self.isEnabled("Report", in: sheetView) && !Self.isEnabled("Cancel", in: sheetView),
                            "old answer \(oldAccepted): both buttons stay disabled")
                    held.release(2, false)
                    try await Self.waitUntil { controller.presentedViewController == nil }
                    try await Task.sleep(for: .seconds(1))
                    #expect(controller.presentedViewController == nil, "its own refusal closes it, with no alert")
                }
            }
        }
    }

    @Test("An old refusal leaves an idle next report open and usable")
    func anOldRefusalLeavesAnIdleSheetAlone() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let held = HeldSend()
        let state = SheetState()
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(RetainedHost(state: state, send: held.send)) { controller in
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                try await Self.pressReport(in: controller, held: held)
                state.open = false
                try await Self.waitUntil { controller.presentedViewController == nil }
                state.open = true
                try await Self.waitUntil { Self.sheetIsUp(controller) }
                held.release(1, false)
                try await Task.sleep(for: .seconds(1))
                #expect(Self.sheetIsUp(controller) && state.open, "the old refusal does not close the next sheet")
                let sheetView = try #require(Self.topPresented(controller)?.view)
                #expect(Self.isEnabled("Report", in: sheetView) && Self.isEnabled("Cancel", in: sheetView), "and leaves it usable")
                try await Self.cancelShowsNothing(in: controller)
            }
        }
    }

    /// The system closes the popover while its report sheet is up and sending: nothing on the
    /// popover or the sheet runs, and the report's flag and presentation live on the button. The
    /// notice reopens with no sheet, and the next report's open retires the old presentation, so
    /// the old answer, before or after the next report starts sending, shows, closes and changes
    /// nothing.
    @Test("A popover the system closed while its report sends: the old answer never shows, closes or changes the next report")
    func aSystemClosedPopoversAnswerNeverReachesTheNext() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        // When the old answer arrives: after the notice reopens but before its report opens,
        // between the press on "Report a concern" and the sheet's open handler, after the next
        // report opens but before it sends, or after it sends.
        for answerAt in ["beforeReportOpens", "betweenPressAndOpen", "beforeNextSend", "afterNextSend"] {
            let held = HeldSend()
            try await HostedAccessibility.withAutomation {
                let button = AISummariesNoticeButton(landed: false, reportContent: { "Summary" }, firstOpen: Self.freshFirstOpen(),
                                                     tipsAllowed: { true }, send: held.send)
                try await Self.hosting(button) { controller in
                    try await Self.openReport(in: controller)
                    try await Self.pressReport(in: controller, held: held)
                    // Close only once the popover and its sheet have finished presenting: a dismiss
                    // that lands mid-presentation leaves them up.
                    try await Self.waitUntil { Self.presentationSettled(controller) }
                    #expect(Self.presentationSettled(controller), "control: the popover and its sheet are on screen")
                    // The system closes the popover and its sheet; the button stays mounted.
                    controller.presentedViewController?.dismiss(animated: false)
                    try await Self.waitUntil { controller.presentedViewController == nil }
                    #expect(controller.presentedViewController == nil, "control: the popover and its sheet closed")
                    let glyph = try #require(Self.element(AISummariesNotice.accessibilityLabel, in: controller.view))
                    #expect(glyph.accessibilityActivate())
                    try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.title) }
                    try await Task.sleep(for: .milliseconds(500))
                    #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title)
                            && !Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice),
                            "the notice opens afresh, with no report sheet: \(Self.presentedLabels(controller))")
                    if answerAt == "beforeReportOpens" {
                        held.release(1, true)
                        try await Task.sleep(for: .seconds(1))
                        #expect(Self.presentedLabels(controller).contains(AISummariesNotice.title)
                                && !Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice),
                                "answer before the report opens: the notice stays, with no sheet")
                        #expect(!(Self.topPresented(controller) is UIAlertController), "answer before the report opens: no alert")
                    }
                    let popover = try #require(Self.topPresented(controller)?.view)
                    let report = try #require(Self.element(AISummariesNotice.reportTitle, in: popover))
                    if answerAt == "betweenPressAndOpen" {
                        // The answer resumes on the main actor before SwiftUI's next update runs the
                        // sheet's open handler for the press below: nothing yields between the two.
                        held.release(1, true)
                    }
                    #expect(report.accessibilityActivate())
                    try await Self.waitUntil { Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice) }
                    #expect(Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice),
                            "\(answerAt): the press opens the next report's sheet")
                    let sheetView = try #require(Self.topPresented(controller)?.view, "control: the next report's sheet")
                    if answerAt == "beforeNextSend" {
                        held.release(1, true)
                        try await Task.sleep(for: .seconds(1))
                        #expect(Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice), "answer first: the new sheet stays")
                        #expect(Self.isEnabled("Report", in: sheetView) && Self.isEnabled("Cancel", in: sheetView),
                                "answer first: its controls are unchanged")
                        #expect(!(Self.topPresented(controller) is UIAlertController), "answer first: no alert")
                    }
                    try await Self.pressReport(in: controller, held: held, sends: 2)
                    if answerAt == "afterNextSend" {
                        held.release(1, true)
                        try await Task.sleep(for: .seconds(1))
                    }
                    #expect(Self.presentedLabels(controller).contains(AISummariesNotice.reportNotice), "the new report stays open")
                    #expect(!Self.isEnabled("Report", in: sheetView) && !Self.isEnabled("Cancel", in: sheetView),
                            "its own send's controls are unchanged")
                    #expect(!(Self.topPresented(controller) is UIAlertController), "no alert from the old answer")
                    held.release(2, false)
                    try await Self.waitUntil { controller.presentedViewController == nil }
                    try await Task.sleep(for: .seconds(1))
                    #expect(controller.presentedViewController == nil, "its own refusal closes it, with no alert")
                }
            }
        }
    }

    @Test("A new report starts with the default category and no reason, after a cancelled or a sent one")
    func aNewReportStartsWithAFreshForm() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted view")
        let reason = "Synthetic reason"
        for sendFirst in [false, true] {
            let held = HeldSend()
            let state = SheetState()
            try await HostedAccessibility.withAutomation {
                try await Self.hosting(RetainedHost(state: state, send: held.send)) { controller in
                    try await Self.waitUntil { Self.sheetIsUp(controller) }
                    try await Self.fillForm(in: controller, reason: reason)
                    if sendFirst {
                        try await Self.pressReport(in: controller, held: held)
                        #expect(held.categories == [.inaccurate] && held.reasons == [reason], "control: the first report as filled")
                        held.release(1, false)
                        try await Self.waitUntil { controller.presentedViewController == nil }
                    } else {
                        try await Self.cancelShowsNothing(in: controller)
                    }
                    state.open = true
                    try await Self.waitUntil { Self.sheetIsUp(controller) }
                    try Self.expectFreshForm(in: controller, sendFirst ? "after a sent report" : "after a cancelled report")
                    let before = held.started
                    try await Self.pressReport(in: controller, held: held, sends: before + 1)
                    #expect(held.categories.last == .offensive, "the next report sends the default category")
                    #expect(held.reasons.last == .some(nil), "and no reason")
                    held.release(before + 1, false)
                    try await Self.waitUntil { controller.presentedViewController == nil }
                }
            }
        }
    }
}
