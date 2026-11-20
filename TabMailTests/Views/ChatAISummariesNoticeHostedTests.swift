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
///  2. "Report a concern" closes the popover and opens the report sheet with the line saying the
///     chat's summaries are sent; Report sends exactly the content the chat hands it.
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

    private static func presentedLabels(_ controller: UIViewController) -> [String] {
        controller.presentedViewController.map { HostedAccessibility.labels(in: $0.view) } ?? []
    }

    private static func button(landed: Bool, firstOpen: AISummariesNotice.FirstOpen, tipsAllowed: Bool,
                               sent: Sent? = nil, content: String = "") -> AISummariesNoticeButton {
        AISummariesNoticeButton(landed: landed, reportContent: { sent?.contents.append(content); return content },
                                firstOpen: firstOpen, tipsAllowed: { tipsAllowed })
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
        try await HostedAccessibility.withAutomation {
            try await Self.hosting(Self.button(landed: false, firstOpen: Self.freshFirstOpen(), tipsAllowed: true,
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
                #expect(!sheet.contains(AISummariesNotice.title), "the popover has closed: \(sheet)")
                let sheetView = try #require(controller.presentedViewController?.view)
                let submit = try #require(Self.element("Report", in: sheetView), "\(sheet)")
                #expect(submit.accessibilityActivate(), "Report takes a press")
                try await Self.waitUntil { !sent.contents.isEmpty }
                #expect(sent.contents == [content], "Report sends the chat's content as handed over")
            }
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
}
