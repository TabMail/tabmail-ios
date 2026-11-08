/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// The inbox's Reply tag, tapped for real in the real inbox (`InboxView`), through accessibility
/// the way VoiceOver taps it (`HostedAccessibility`).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. With the chat view on, tapping an email's Reply tag opens that email in the chat (TQ2):
///     the inbox selects it, and the chat marks it read as it shows.
///  2. With the chat view off, the same tap keeps today's Reply: the email is marked read at once
///     and nothing is selected.
@Suite("Reply tag in the inbox", .serialized, .processGlobalState)
@MainActor
struct InboxReplyTagTests {
    nonisolated private static let account = "acc-reply-tag"

    /// The inbox's selected email, as `RootView` holds it.
    private final class Selection {
        var id: String?
    }

    @Test("The Reply tag opens the chat with the chat view on, and today's Reply with it off", arguments: [true, false])
    func replyTagRoutes(chatView: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted inbox")
        try await HostedAccessibility.withAutomation { try await replyTagRoutesBody(chatView: chatView) }
    }

    private func replyTagRoutesBody(chatView: Bool) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: chatView)
        #expect(ChatViewConfig.opensInChat == chatView, "control: the chat view is \(chatView ? "on" : "off")")
        _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        var header = MessageHeader(
            messageId: "reply-tag", subject: "Lunch on Friday?", from: "Sender", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(), snippet: "Are you free?",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<reply-tag@example.com>"
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = false
        header.actionTag = .reply
        let seeded = header
        try await pool.write { db in try seeded.insert(db) }
        let folder = try #require(try await pool.read { db in
            try Folder.filter(Column("accountId") == Self.account && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        })

        let selection = Selection()
        let root = NavigationStack {
            InboxView(title: "Inbox", folders: [folder], selection: .unified(.inbox),
                      selectedMessageId: Binding(get: { selection.id }, set: { selection.id = $0 }),
                      pushedMessageId: .constant(nil))
        }
        .environment(NavigationStore())
        .environment(\.hasTabMailSession, true)
        let controller = UIHostingController(rootView: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        func replyTag() -> NSObject? {
            HostedAccessibility.elements(under: controller.view).first { $0.accessibilityLabel == ActionTag.reply.displayName }
        }
        for _ in 0..<100 where replyTag() == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let tag = try #require(replyTag(), "control: the row shows its Reply tag: \(HostedAccessibility.labels(in: controller.view).prefix(30))")
        #expect(tag.accessibilityActivate(), "control: the tag took the tap")

        func isRead() async throws -> Bool {
            try await pool.read { db in try MessageHeader.fetchOne(db, key: seeded.id)?.isRead ?? false }
        }
        if chatView {
            for _ in 0..<50 where selection.id == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(selection.id == seeded.id, "the tap opens the email in the chat")
        } else {
            for _ in 0..<50 where try await !isRead() {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try await isRead(), "today's Reply marks the email read")
            #expect(selection.id == nil, "today's Reply selects nothing")
        }
        await AccountManager.shared.awaitWriteQueueDrain()
    }
}
