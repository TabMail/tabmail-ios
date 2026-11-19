/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 9: a chat reads every copy of its emails, opened for real in a window.
///
/// The chat shows each email once, but an email can sit on the device more than once: the Sent
/// copy of the user's own post and the copy a mailing list echoed into the Inbox, or one email
/// delivered to two of the user's accounts. THE SYSTEM PROPERTIES pinned here:
///  1. Once the chat has opened, no email of the thread is unread, in any folder or account.
///  2. The chat acts on the rows of its thread as it loaded them, each by its own row, never on
///     whatever else carries the same Message-ID (ADR-IOS-068 D4: a Message-ID is never mutation
///     authority): a copy the thread does not reach (Spam) keeps its unread state.
@Suite("Chat acts on every copy of its emails", .serialized, .processGlobalState)
@MainActor
struct ChatCopiesTests {
    private static let own = "acc-chat-copies"
    private static let second = "acc-chat-copies-two"
    private static func folderId(_ accountId: String, _ path: String) -> String {
        MessageIdentity.folderId(accountId: accountId, folderPath: path)
    }

    private struct Thread {
        /// The user's post: its Sent copy and the copy the list echoed into the Inbox.
        let postSent: MessageHeader
        let postEcho: MessageHeader
        /// A reply delivered to both accounts.
        let replyOwn: MessageHeader
        let replySecond: MessageHeader
        /// The newest email, opened.
        let newest: MessageHeader
        /// A copy of the reply in Spam: the thread never reaches it.
        let replySpam: MessageHeader

        /// Every row the chat loads.
        var loaded: [MessageHeader] { [postSent, postEcho, replyOwn, replySecond, newest] }
    }

    private static func header(
        _ uid: String, rfc: String, inReplyTo: String?, accountId: String, folder: String,
        from: String, date: Date, isRead: Bool
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Launch plan", from: from, fromAddress: from,
            to: "list@example.com", date: date, snippet: "Note \(uid)",
            folderId: folderId(accountId, folder), accountId: accountId, folderPath: folder,
            isInInbox: folder == "INBOX")
        header.rfc822MessageId = rfc
        header.inReplyTo = inReplyTo
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = isRead
        return header
    }

    private static func insertThread(pool: DatabasePool) throws -> Thread {
        for (account, folders) in [
            (own, [("INBOX", FolderRole.inbox), ("Sent", .sent), ("Archive", .archive), ("Trash", .trash), ("Spam", .spam)]),
            (second, [("INBOX", .inbox), ("Archive", .archive), ("Trash", .trash)]),
        ] {
            _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
            for (path, role) in folders {
                try FolderEpochTestFixture.insertFolder(accountId: account, path: path, role: role, pool: pool)
            }
        }
        let me = "\(own)@example.com"
        let now = Date()
        let post = "<copies-post@example.com>"
        let reply = "<copies-reply@example.com>"
        let newest = "<copies-newest@example.com>"
        let thread = Thread(
            postSent: header("post-sent", rfc: post, inReplyTo: nil, accountId: own, folder: "Sent",
                             from: me, date: now.addingTimeInterval(-3600), isRead: true),
            // The list's copy. One second older only so that the chat shows the Sent copy and hides
            // this one, as the review's case had it.
            postEcho: header("post-echo", rfc: post, inReplyTo: nil, accountId: own, folder: "INBOX",
                             from: me, date: now.addingTimeInterval(-3601), isRead: false),
            replyOwn: header("reply-own", rfc: reply, inReplyTo: post, accountId: own, folder: "INBOX",
                             from: "sam@example.com", date: now.addingTimeInterval(-1800), isRead: false),
            replySecond: header("reply-second", rfc: reply, inReplyTo: post, accountId: second, folder: "INBOX",
                                from: "sam@example.com", date: now.addingTimeInterval(-1800), isRead: false),
            newest: header("newest", rfc: newest, inReplyTo: reply, accountId: own, folder: "INBOX",
                           from: "jordan@example.com", date: now.addingTimeInterval(-600), isRead: false),
            replySpam: header("reply-spam", rfc: reply, inReplyTo: post, accountId: own, folder: "Spam",
                              from: "sam@example.com", date: now.addingTimeInterval(-1800), isRead: false))
        try pool.write { db in
            for row in thread.loaded + [thread.replySpam] { try row.insert(db) }
        }
        return thread
    }

    private static func rows(_ ids: [String]) async throws -> [String: MessageHeader] {
        try await AppDatabase.dbPool.read { db in
            Dictionary(uniqueKeysWithValues: try ids.compactMap { try MessageHeader.fetchOne(db, key: $0) }.map { ($0.id, $0) })
        }
    }

    /// The labels of the chat's bubbles, for a precondition: one bubble per email.
    private static func bubbleCount(in view: UIView) -> Int {
        HostedAccessibility.elements(under: view).filter { $0.accessibilityLabel?.contains(" said: ") == true }.count
    }

    /// Opens the chat on the thread's newest email, waits until its thread has loaded and the read
    /// flips have been written, runs `then`, and tears everything down.
    private func withOpenChat(
        _ then: @MainActor (Thread, UIView) async throws -> Void
    ) async throws {
        try await HostedAccessibility.withAutomation {
            let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
            let queue = ActiveAIQueue.shared
            await queue.setDispatchSuppressedForTesting(true)
            await queue.clearForTesting()
            defer {
                InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
            }
            let thread = try Self.insertThread(pool: pool)

            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            let controller = UIHostingController(rootView: NavigationStack {
                ChatThreadView(messageId: thread.newest.id)
            })
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            for _ in 0..<60 where Self.bubbleCount(in: controller.view) < 3 {
                try await Task.sleep(for: .milliseconds(150))
            }
            try await Task.sleep(for: .milliseconds(600))
            await AccountManager.shared.awaitWriteQueueDrain()
            #expect(Self.bubbleCount(in: controller.view) == 3, "control: the chat shows each of its three emails once")
            try await then(thread, controller.view)
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
        }
    }

    @Test("Opening a chat reads every copy of its emails, in any folder or account, and only the copies its thread holds")
    func openReadsEveryCopy() async throws {
        try await withOpenChat { thread, _ in
            let found = try await Self.rows((thread.loaded + [thread.replySpam]).map(\.id))
            for row in thread.loaded {
                #expect(found[row.id]?.isRead == true, "\(row.messageId) in \(row.accountId)/\(row.folderPath) is read")
            }
            #expect(found[thread.replySpam.id]?.isRead == false,
                    "a copy in Spam is not the chat's: it is not read by Message-ID")
        }
    }
}
