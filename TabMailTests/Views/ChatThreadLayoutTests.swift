/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Where the chat screen puts its reply field and header, measured in the real hosted chat.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The collapsed reply field's bottom edge sits `ChatViewLayout.fieldBottomGap` above the
///     bottom safe-area line, and its sides `ChatViewLayout.fieldSideInset` from the screen's
///     sides. The safe area is counted once.
///  2. The navigation bar stays while the pill is open, and the opened pill fits between the bar
///     and the safe-area line at the largest text size: its top (Close) is below the bar and
///     its input bar above the safe-area line.
///  3. The header is in the navigation bar, as in Messages: the names lie inside the bar, under its
///     middle (the avatars are above them, level with Back), and the subject line starts below the
///     bar, at the default and the largest text size.
///  4. The header is the chat's top bar: the scroll view's own safe area covers it at sampled scroll
///     positions, and at rest at the oldest email the first bubble sits below the subject, at the
///     default and the largest text size.
@Suite("Chat layout", .serialized, .processGlobalState)
@MainActor
struct ChatThreadLayoutTests {
    nonisolated private static let account = "acc-layout"

    private static func makeParent(_ pool: DatabasePool, earlier: Int = 0) async throws -> MessageHeader {
        _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
        try await insertEarlier(earlier, pool: pool)
        var header = MessageHeader(
            messageId: "layout-parent", subject: "Lunch plans", from: "sender@example.com",
            fromAddress: "sender@example.com", to: "someone@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Lunch?",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "layout-parent@example.com"
        if earlier > 0 {
            header.inReplyTo = "<layout-\(earlier - 1)@example.com>"
            // A finished summary, so a long chat's open queues no summary work beyond the test.
            header.summaryBlurb = "Lunch?"
            header.summaryTextMessage = "Lunch?"
        }
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        // Filtered (no tag to reply, the empty-reply sentinel), so no AI Suggestion row (the Writing
        // bubble or the ghost) joins the chat: the newest email's bubble is the last row, right above
        // the field, which is what the layout tests measure.
        header.actionTag = ActionTag.none
        header.cachedReply = ""
        let parent = header
        try await pool.write { db in try parent.insert(db) }
        return parent
    }

    /// `count` earlier emails of the same thread, each a bubble of several lines of text.
    private static func insertEarlier(_ count: Int, pool: DatabasePool) async throws {
        guard count > 0 else { return }
        let now = Date()
        for index in 0..<count {
            var header = MessageHeader(
                messageId: "layout-\(index)", subject: "Lunch plans", from: "Sender \(index % 3)",
                fromAddress: "sender\(index % 3)@example.com", to: "someone@example.com",
                date: now.addingTimeInterval(TimeInterval(index - count - 1) * 600), snippet: "Note \(index)",
                folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
                accountId: account, folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = "<layout-\(index)@example.com>"
            header.inReplyTo = index == 0 ? nil : "<layout-\(index - 1)@example.com>"
            header.headerComplete = true
            header.bodyComplete = true
            header.isRead = true
            // A finished summary (its blurb and text message), so the open queues no summary work.
            header.summaryBlurb = "Note \(index)"
            header.summaryTextMessage = "Note \(index): a few lines of text, long enough to wrap in the bubble and reach behind the header."
            let row = header
            try await pool.write { db in try row.insert(db) }
        }
    }

    /// Hosts the chat on `parent` in a phone-sized window, runs `body`, and tears it down.
    private static func hosted(
        textSize: DynamicTypeSize = .large,
        earlier: Int = 0,
        signedIn: Bool = false,
        _ body: (UIWindow, UIHostingController<AnyView>, MessageHeader) async throws -> Void
    ) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let parent = try await makeParent(pool, earlier: earlier)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack { ChatThreadView(messageId: parent.id) }
                .environment(NavigationStore())
                .environment(\.dynamicTypeSize, textSize)
                .environment(\.hasTabMailSession, signedIn)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body(window, controller, parent)
    }

    private static func frame(of identifier: String, in view: UIView) -> CGRect? {
        HostedAccessibility.elements(under: view)
            .first { HostedAccessibility.identifier(of: $0) == identifier }
            .map { $0.accessibilityFrame }
    }

    private static func waitFor(_ done: () -> Bool) async throws {
        for _ in 0..<80 where !done() { try await Task.sleep(for: .milliseconds(100)) }
    }

    /// The visible navigation bar under `view`, in screen coordinates.
    private static func navigationBarFrame(in view: UIView) -> CGRect? {
        func find(_ view: UIView) -> UINavigationBar? {
            if let bar = view as? UINavigationBar, !bar.isHidden, bar.alpha > 0 { return bar }
            for sub in view.subviews { if let bar = find(sub) { return bar } }
            return nil
        }
        guard let bar = find(view) else { return nil }
        return bar.convert(bar.bounds, to: nil)
    }

    @Test("The reply field sits just above the safe area, inset from the sides as in Messages")
    func fieldGeometry() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted { window, controller, _ in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: id, in: controller.view).map { $0.height > 0 } ?? false }
                let pill = try #require(Self.frame(of: id, in: controller.view),
                                        "ids: \(HostedAccessibility.identifiers(in: controller.view))")
                let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
                #expect(window.safeAreaInsets.bottom > 0, "control: a phone with a home indicator")
                #expect(abs(pill.maxY - (safeBottom - ChatViewLayout.fieldBottomGap)) < 1,
                        "bottom \(pill.maxY), safe-area line \(safeBottom)")
                #expect(abs(pill.minX - ChatViewLayout.fieldSideInset) < 1, "left \(pill.minX)")
                #expect(abs((window.bounds.maxX - pill.maxX) - ChatViewLayout.fieldSideInset) < 1, "right \(pill.maxX)")
            }
        }
    }

    @Test("A one-line field is 42 tall, with the mic and Send centred on its line, inset as drawn")
    func fieldButtonsOnTheLastLine() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted { _, controller, _ in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: "chatSend", in: controller.view) != nil }
                try await Task.sleep(for: .milliseconds(300))
                let field = try #require(Self.frame(of: id, in: controller.view))
                let send = try #require(Self.frame(of: "chatSend", in: controller.view))
                let mic = try #require(HostedAccessibility.elements(under: controller.view)
                    .first { $0.accessibilityLabel == "Dictate" }?.accessibilityFrame,
                    "labels: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
                // No TabMail session here, so no "e.g." line: one line.
                #expect(abs(field.height - 42) < 1, "one-line field \(field.height)")
                let lineMid = field.maxY - ChatViewLayout.fieldVerticalPadding - ChatViewLayout.fieldLineHeight / 2
                #expect(abs(send.midY - lineMid) < 1, "Send \(send) on the line at \(lineMid)")
                #expect(abs(mic.midY - lineMid) < 1, "mic \(mic) on the line at \(lineMid)")
                #expect(abs(send.midX - (field.maxX - ChatViewLayout.fieldSendInset - ChatViewLayout.fieldSendSize / 2)) < 1,
                        "Send circle 6 in from the edge: \(send), field \(field)")
                #expect(abs(mic.midX - (field.minX + ChatViewLayout.fieldMicInset + ChatViewLayout.fieldMicGlyphWidth / 2)) < 1,
                        "mic 12 in from the edge: \(mic), field \(field)")
                #expect(send.height >= 44 && mic.height >= 44, "tap areas stay 44 tall")
            }
        }
    }

    @Test("At the largest text size the mic and Send still centre on the field's last line, which grows with the text")
    func fieldButtonsOnTheLastLineAtTheLargestTextSize() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(textSize: .accessibility5) { _, controller, _ in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: "chatSend", in: controller.view) != nil }
                try await Task.sleep(for: .milliseconds(300))
                let field = try #require(Self.frame(of: id, in: controller.view))
                let send = try #require(Self.frame(of: "chatSend", in: controller.view))
                let mic = try #require(HostedAccessibility.elements(under: controller.view)
                    .first { $0.accessibilityLabel == "Dictate" }?.accessibilityFrame,
                    "labels: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
                // One body line at this text size, scaled as the text is (ADR-IOS-114 decision 19).
                let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
                let line = UIFontMetrics(forTextStyle: .body).scaledValue(
                    for: ChatViewLayout.fieldLineHeight, compatibleWith: largest)
                let grows = line > 2 * ChatViewLayout.fieldLineHeight
                #expect(grows, "control: the line is far taller than at the default size: \(line)")
                let lineMid = field.maxY - ChatViewLayout.fieldVerticalPadding - line / 2
                #expect(abs(send.midY - lineMid) < 1, "Send \(send) on the last line at \(lineMid)")
                #expect(abs(mic.midY - lineMid) < 1, "mic \(mic) on the last line at \(lineMid)")
            }
        }
    }

    @Test("Signed in, the empty field shows its \"e.g.\" line: 60 tall, the mic and Send on its last line")
    func signedInEmptyField() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(signedIn: true) { _, controller, _ in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: "chatSend", in: controller.view) != nil }
                try await Task.sleep(for: .milliseconds(300))
                let labels = HostedAccessibility.labels(in: controller.view)
                #expect(labels.contains { $0.hasPrefix("e.g.") }, "control: the \"e.g.\" line shows: \(labels.prefix(30))")
                let field = try #require(Self.frame(of: id, in: controller.view))
                let send = try #require(Self.frame(of: "chatSend", in: controller.view))
                let mic = try #require(HostedAccessibility.elements(under: controller.view)
                    .first { $0.accessibilityLabel == "Dictate" }?.accessibilityFrame)
                // Option B: the hint line, the "e.g." line under it, 10 above and below. The design
                // mock's 60 assumed a 16-pt caption line; the real caption line at this text size is
                // 14.33, so the field is 58.33: the padding, one body line, the column's spacing
                // (`spacing: 2` in `liveReplyFieldBar`), one caption line, the padding.
                let captionLine = UIFont.preferredFont(
                    forTextStyle: .caption1,
                    compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight
                let expected = ChatViewLayout.fieldVerticalPadding + ChatViewLayout.fieldLineHeight + 2
                    + captionLine + ChatViewLayout.fieldVerticalPadding
                #expect(abs(field.height - expected) < 1, "empty signed-in field \(field.height), expected \(expected)")
                let lineMid = field.maxY - ChatViewLayout.fieldVerticalPadding - ChatViewLayout.fieldLineHeight / 2
                #expect(abs(send.midY - lineMid) < 1, "Send \(send) on the last line at \(lineMid)")
                #expect(abs(mic.midY - lineMid) < 1, "mic \(mic) on the last line at \(lineMid)")
            }
        }
    }

    @Test("VoiceOver's \"Show TabMail chat\" opens the panel, is gone once it is open, and sits on an element VoiceOver can focus")
    func showChatActionOpensThePanel() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted { _, controller, _ in
                let id = ChatThreadView.replyPillId
                let name = ChatViewConfig.showChatActionName
                try await Self.waitFor { Self.frame(of: id, in: controller.view) != nil }
                let carriers = HostedAccessibility.elements(under: controller.view)
                    .filter { $0.accessibilityCustomActions?.contains { $0.name == name } ?? false }
                @MainActor func describe(_ element: NSObject) -> String {
                    "\(type(of: element)) isAccessibilityElement=\(element.isAccessibilityElement) id=\(HostedAccessibility.identifier(of: element) ?? "none")"
                }
                // VoiceOver offers an element's actions only while that element has its focus: some
                // element VoiceOver can focus (the reply field's text field) carries it. SwiftUI may
                // also put it on a wrapper node that is no element; that one alone would not do.
                // Plain values only inside the macro: closures in its arguments do not compile.
                let focusable = carriers.first(where: { $0.isAccessibilityElement })
                let carrierList = carriers.map { describe($0) }.joined(separator: "; ")
                // Known issue tabmail-ios#1169: today the only carrier is SwiftUI's VerticalTextView,
                // which VoiceOver cannot focus. Remove this wrapper when #1169 is fixed.
                withKnownIssue("#1169 the action sits on an element VoiceOver cannot focus") {
                    #expect(focusable != nil, "an element VoiceOver can focus carries the action; carriers: \(carrierList)")
                }
                let carrier = try #require(focusable ?? carriers.first, "the action is offered; carriers: \(carrierList)")
                #expect(HostedAccessibility.identifier(of: carrier) != id, "not the field's container")
                #expect(Self.frame(of: "chatClose", in: controller.view) == nil, "control: the panel starts closed")
                // Run it as VoiceOver's actions rotor does (the text field has no identifier to
                // look it up by).
                let action = try #require(carrier.accessibilityCustomActions?.first { $0.name == name })
                let handler = try #require(action.actionHandler, "control: a SwiftUI action has a handler")
                #expect(handler(action), "the action runs")
                try await Self.waitFor { Self.frame(of: "chatClose", in: controller.view) != nil }
                #expect(Self.frame(of: "chatClose", in: controller.view) != nil, "the panel opened")
                @MainActor func stillOffered() -> Bool {
                    HostedAccessibility.elements(under: controller.view)
                        .contains { $0.accessibilityCustomActions?.contains { $0.name == name } ?? false }
                }
                // The collapsed field's element may linger through its removal animation.
                try await Self.waitFor { !stillOffered() }
                #expect(!stillOffered(), "the action is gone while the panel is open")
            }
        }
    }

    @Test("The chat scrolls behind the reply field: the field is the scroll view's bottom bar")
    func chatScrollsBehindTheField() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(earlier: 2) { window, controller, _ in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: id, in: controller.view).map { $0.height > 0 } ?? false }
                try await Task.sleep(for: .milliseconds(500))
                let field = try #require(Self.frame(of: id, in: controller.view))
                let scroll = try #require(Self.scrollViews(controller.view).max { $0.contentSize.height < $1.contentSize.height })
                let scrollBottom = scroll.convert(scroll.bounds, to: nil).maxY
                // The scroll view's content area ends at the field's top: the system knows the
                // field is a bar (which is what draws the edge blur under it), not a spacer row.
                #expect(scroll.adjustedContentInset.bottom >= scrollBottom - field.minY - 1,
                        "inset \(scroll.adjustedContentInset.bottom), scroll bottom \(scrollBottom), field top \(field.minY)")
                let newest = try #require(HostedAccessibility.elements(under: controller.view)
                    .last { $0.accessibilityLabel?.contains(" said: Lunch?") == true }?.accessibilityFrame,
                    "labels: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
                #expect(newest.maxY <= field.minY + 0.5 && newest.maxY >= field.minY - ChatViewLayout.pillGap - ChatViewLayout.bubbleSpacing - 1,
                        "the newest row \(newest) sits right above the field \(field)")
                _ = window
            }
        }
    }

    @Test("A new email arriving in the open chat ends below the one before and fully above the field")
    func arrivalEndsAboveTheField() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(earlier: 2) { _, controller, parent in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: id, in: controller.view).map { $0.height > 0 } ?? false }
                try await Task.sleep(for: .milliseconds(500))
                @MainActor func bubble(_ words: String) -> CGRect? { Self.bubbleFrame(saying: words, in: controller.view) }
                _ = try #require(bubble("Lunch?"), "control: the newest before the arrival")
                try await Self.arrive(after: parent)
                try await Self.waitFor { bubble("Noon works") != nil }
                // Past the rise.
                try await Task.sleep(for: .seconds(ChatViewLayout.arrivalRiseDuration + 0.6))
                let new = try #require(bubble("Noon works"), "labels: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
                let before = try #require(bubble("Lunch?"))
                let field = try #require(Self.frame(of: id, in: controller.view))
                #expect(new.minY >= before.maxY - 0.5, "the arrival \(new) is below the one before \(before)")
                #expect(new.maxY <= field.minY + 0.5, "the arrival \(new) is fully above the field \(field)")
            }
        }
    }

    /// The short chat above has nothing to scroll, so it cannot tell how the chat moves. In a chat
    /// longer than the screen, held at its bottom by the landing, the chat moves up with the rise
    /// (decision 23: "the rows above move up with it"): its scroll position as drawn passes through
    /// places between where it was and where it ends, rather than jumping there in one frame, and
    /// the new email ends at the bar, on screen, where the newest email ended before it. This
    /// measures how the chat moves, not the new row's own transition.
    @Test("In a chat longer than the screen, an arrival moves the chat up through the rise, not in one jump, and ends at the bar")
    func arrivalInALongChatMovesItUpWithTheRise() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(earlier: Self.longChatEarlier) { window, controller, parent in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: id, in: controller.view).map { $0.height > 0 } ?? false }
                try await Task.sleep(for: .milliseconds(500))
                let scroll = try #require(Self.scrollViews(controller.view).max { $0.contentSize.height < $1.contentSize.height })
                let contentHeight = scroll.contentSize.height
                try #require(contentHeight > window.bounds.height, "control: the chat is longer than the screen, \(contentHeight)")
                let start = Self.shownOffset(of: scroll)
                // Where the newest email ends above the field before the arrival: the place at the
                // bar the arrival takes over.
                let lastBefore = try #require(Self.bubbleFrame(saying: "Lunch?", in: controller.view), "control: the newest before the arrival")
                let fieldBefore = try #require(Self.frame(of: id, in: controller.view))
                let gap = fieldBefore.minY - lastBefore.maxY
                #expect(gap >= 0, "control: held at its bottom, the newest email ends above the field: \(gap)")
                try await Self.arrive(after: parent)
                var shown: [CGFloat] = []
                for _ in 0..<Self.arrivalSamples {
                    shown.append(Self.shownOffset(of: scroll))
                    try await Task.sleep(for: Self.arrivalSampleInterval)
                }
                let end = Self.shownOffset(of: scroll)
                #expect(end > start + Self.arrivalLeastRise, "control: the chat moved up for the new email, from \(start) to \(end)")
                let between = shown.filter { $0 > start + 1 && $0 < end - 1 }
                #expect(!between.isEmpty, "the chat moved up through the rise, not in one jump, from \(start) to \(end): \(shown)")
                let new = try #require(Self.bubbleFrame(saying: "Noon works", in: controller.view), "the arrival shows")
                let field = try #require(Self.frame(of: id, in: controller.view))
                #expect(new.maxY <= field.minY + 0.5, "the arrival \(new) is fully above the field \(field)")
                // And at the bar, on screen: it ends where the newest email ended before it, not
                // anywhere above.
                let newGap = field.minY - new.maxY
                #expect(abs(newGap - gap) <= Self.arrivalAtTheBar, "the arrival ends at the bar, \(newGap) above the field, as the newest did at \(gap)")
                #expect(new.minY >= window.bounds.minY, "the arrival \(new) is on screen")
            }
        }
    }

    /// Earlier emails enough to make the chat longer than the screen; the samples, a frame or two
    /// apart, that cover the merge's read, the rise and a margin; and the least the chat must move
    /// up for a one-line email.
    private static let longChatEarlier = 12
    private static let arrivalSamples = 250
    private static let arrivalSampleInterval: Duration = .milliseconds(8)
    private static let arrivalLeastRise: CGFloat = 20
    /// How closely the arrival must end where the newest email ended above the field.
    private static let arrivalAtTheBar: CGFloat = 1

    /// The chat's scroll position as drawn: an animated scroll's in-between position, read from the
    /// presentation layer, or the position itself when nothing animates.
    private static func shownOffset(of scroll: UIScrollView) -> CGFloat {
        scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
    }

    /// The screen frame of the newest bubble that says `words`.
    private static func bubbleFrame(saying words: String, in view: UIView) -> CGRect? {
        HostedAccessibility.elements(under: view)
            .last { $0.accessibilityLabel?.contains(" said: \(words)") == true }?.accessibilityFrame
    }

    /// A one-line email from someone else that joins `parent`'s thread, as a sync's merge brings it
    /// in and announces it.
    private static func arrive(after parent: MessageHeader) async throws {
        var arrived = MessageHeader(
            messageId: "layout-arrived", subject: "Lunch plans", from: "Sender 1",
            fromAddress: "sender1@example.com", to: "someone@example.com",
            date: Date(), snippet: "Noon works",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        arrived.rfc822MessageId = "<layout-arrived@example.com>"
        // The parent's own id, as stored: thread detection matches ids exactly, so a
        // bracketed copy of an unbracketed id never joins the thread.
        arrived.inReplyTo = parent.rfc822MessageId
        arrived.headerComplete = true
        arrived.bodyComplete = true
        arrived.isRead = true
        arrived.summaryBlurb = "Noon works"
        arrived.summaryTextMessage = "Noon works"
        // Filtered like the parent, so the arrival is the last row and nothing sits between
        // it and the field.
        arrived.actionTag = ActionTag.none
        arrived.cachedReply = ""
        let row = arrived
        try await AppDatabase.dbPool.write { db in try row.insert(db) }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
    }

    @Test("Opening the pill does not move the chat under it")
    func openingThePillKeepsTheChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(earlier: 2) { _, controller, parent in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: id, in: controller.view).map { $0.height > 0 } ?? false }
                try await Task.sleep(for: .milliseconds(500))
                @MainActor func newest() -> CGRect? {
                    HostedAccessibility.elements(under: controller.view)
                        .last { $0.accessibilityLabel?.contains(" said: Lunch?") == true }?.accessibilityFrame
                }
                let before = try #require(newest(), "labels: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
                NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": parent.id])
                try await Self.waitFor { Self.frame(of: "chatClose", in: controller.view) != nil }
                try await Task.sleep(for: .seconds(1))
                let after = try #require(newest(), "the newest bubble is still there under the panel")
                #expect(abs(after.minY - before.minY) < 1, "before \(before), after \(after)")
            }
        }
    }

    @Test("With the largest text, the opened pill fits between the navigation bar, which stays, and the safe area")
    func openedPillFitsUnderTheBar() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(textSize: .accessibility5) { window, controller, parent in
                let id = ChatThreadView.replyPillId
                try await Self.waitFor { Self.frame(of: id, in: controller.view).map { $0.height > 0 } ?? false }
                NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": parent.id])
                try await Self.waitFor { Self.frame(of: "chatClose", in: controller.view) != nil }
                // Let the opening spring settle.
                try await Task.sleep(for: .seconds(1))
                // The opened pill's own top (Close) and bottom: with no TabMail session, as here, the
                // sign-in line stands where the input bar goes. Its container's frame also spans the
                // scrolled-away chat inside it, so it is not measured.
                let close = try #require(Self.frame(of: "chatClose", in: controller.view), "the pill opened")
                let bottomLine = HostedAccessibility.elements(under: controller.view)
                    .last { $0.accessibilityLabel?.hasPrefix("Sign in to TabMail") == true }
                let bottom = try #require(bottomLine?.accessibilityFrame,
                    "the pill's bottom line: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
                let bar = try #require(Self.navigationBarFrame(in: controller.view), "the bar stays while the pill is open")
                let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
                #expect(close.minY >= bar.maxY - 0.5, "Close top \(close.minY) under the bar's bottom \(bar.maxY)")
                #expect(bottom.maxY <= safeBottom + 0.5 && bottom.minY > close.maxY,
                        "bottom line \(bottom), Close \(close), safe-area line \(safeBottom)")
            }
        }
    }

    @Test("The people are in the navigation bar and the subject line under it", arguments: [DynamicTypeSize.large, .accessibility5])
    func headerInTheBar(textSize: DynamicTypeSize) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(textSize: textSize) { _, controller, _ in
                @MainActor func element(_ match: @MainActor (NSObject) -> Bool) -> CGRect? {
                    HostedAccessibility.elements(under: controller.view).first(where: match)?.accessibilityFrame
                }
                let isNames: @MainActor (NSObject) -> Bool = { $0.accessibilityHint == "Changes who gets your reply" }
                try await Self.waitFor { element(isNames) != nil && Self.navigationBarFrame(in: controller.view) != nil }
                try await Task.sleep(for: .milliseconds(500))
                let names = try #require(element(isNames), "labels: \(HostedAccessibility.labels(in: controller.view))")
                let subject = try #require(element { $0.accessibilityLabel == "Lunch plans" && $0.accessibilityHint == nil })
                let bar = try #require(Self.navigationBarFrame(in: controller.view))
                #expect(names.minY >= bar.minY - 0.5 && names.maxY <= bar.maxY + 0.5, "names \(names) in the bar \(bar)")
                #expect(names.midY > bar.midY, "names under the avatars: \(names) in \(bar)")
                #expect(subject.minY >= bar.maxY - 0.5, "subject \(subject) under the bar \(bar)")
            }
        }
    }

    /// Earlier emails in the scrolled-chat test: several screens of bubbles.
    private static let scrolledEarlier = 20
    /// Scroll positions the scrolled-chat test reads, a bubble's part apart.
    private static let scrollSteps = 8
    private static let scrollStep: CGFloat = 37

    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }

    // The header (names in the navigation bar, the subject line under it) is the chat's top bar:
    // the scroll view's own safe area must cover it, so the chat scrolls under it; at rest at the
    // oldest email the first bubble sits below the subject. A plain top inset also adds to the safe
    // area, so this does not tell a bar from an inset.
    // Whether the system draws its scroll-edge backdrop behind a bar is not observable from UIKit
    // (no public property reports it), so it is not asserted here; screenshots show it.
    @Test("The chat's scroll area clears the header at sampled scroll positions; at rest its first bubble does too",
          arguments: [DynamicTypeSize.large, .accessibility5])
    func scrolledContentStaysUnderTheHeader(textSize: DynamicTypeSize) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await Self.hosted(textSize: textSize, earlier: Self.scrolledEarlier) { window, controller, _ in
                let isSubject: @MainActor (NSObject) -> Bool = { $0.accessibilityLabel == "Lunch plans" && $0.accessibilityHint == nil }
                try await Self.waitFor {
                    HostedAccessibility.elements(under: controller.view).contains(where: isSubject)
                        && Self.scrollViews(controller.view).contains { $0.contentSize.height > window.bounds.height * 2 }
                }
                try await Task.sleep(for: .milliseconds(500))
                let scroll = try #require(Self.scrollViews(controller.view).max { $0.contentSize.height < $1.contentSize.height })
                let top = -scroll.adjustedContentInset.top
                try #require(scroll.contentSize.height > window.bounds.height * 2, "control: a chat several screens long, \(scroll.contentSize)")
                try #require(scroll.contentOffset.y > top + window.bounds.height + CGFloat(Self.scrollSteps) * Self.scrollStep,
                             "control: it opens at the newest, far enough from the top for every step, \(scroll.contentOffset.y)")
                @MainActor func subjectFrame() throws -> CGRect {
                    try #require(HostedAccessibility.elements(under: controller.view).first(where: isSubject)?.accessibilityFrame)
                }
                @MainActor func scrollFrame() -> CGRect { scroll.convert(scroll.bounds, to: nil) }
                @MainActor func checkInsets(_ at: String) throws {
                    let subject = try subjectFrame()
                    let frame = scrollFrame()
                    #expect(frame.minY + scroll.adjustedContentInset.top >= subject.maxY + ChatViewLayout.subjectLineBottomGap - 0.5,
                            "\(at): the scroll area's top \(frame.minY + scroll.adjustedContentInset.top) clears the subject \(subject) by its gap")
                }
                // Where the chat opens, at the newest email.
                try checkInsets("at the newest")

                // Scrolled, at several positions.
                let start = scroll.contentOffset.y
                for step in 0..<Self.scrollSteps {
                    let target = start - window.bounds.height - CGFloat(step) * Self.scrollStep
                    scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(abs(scroll.contentOffset.y - target) < 1, "control: step \(step) is at \(target), got \(scroll.contentOffset.y)")
                    try checkInsets("scrolled step \(step)")
                }

                // At rest at the oldest email.
                scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
                try await Task.sleep(for: .milliseconds(500))
                try checkInsets("at the oldest")
                let oldest = try #require(HostedAccessibility.elements(under: controller.view).first {
                    $0.accessibilityLabel?.contains(" said: Note 0") == true
                }?.accessibilityFrame, "the oldest email's bubble shows: \(HostedAccessibility.labels(in: controller.view).prefix(20))")
                #expect(oldest.minY >= (try subjectFrame()).maxY - 0.5, "at the oldest: the first bubble \(oldest) sits below the subject")
            }
        }
    }
}
