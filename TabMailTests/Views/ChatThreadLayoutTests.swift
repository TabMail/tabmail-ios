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
@Suite("Chat layout", .serialized, .processGlobalState)
@MainActor
struct ChatThreadLayoutTests {
    nonisolated private static let account = "acc-layout"

    private static func makeParent(_ pool: DatabasePool) async throws -> MessageHeader {
        _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
        var header = MessageHeader(
            messageId: "layout-parent", subject: "Lunch plans", from: "sender@example.com",
            fromAddress: "sender@example.com", to: "someone@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Lunch?",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "layout-parent@example.com"
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        let parent = header
        try await pool.write { db in try parent.insert(db) }
        return parent
    }

    /// Hosts the chat on `parent` in a phone-sized window, runs `body`, and tears it down.
    private static func hosted(
        textSize: DynamicTypeSize = .large,
        _ body: (UIWindow, UIHostingController<AnyView>, MessageHeader) async throws -> Void
    ) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let parent = try await makeParent(pool)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack { ChatThreadView(messageId: parent.id) }.environment(\.dynamicTypeSize, textSize)))
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
}
