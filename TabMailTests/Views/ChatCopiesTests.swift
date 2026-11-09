/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decisions 9 and 12: a chat acts on every copy of its emails, opened for real in a
/// window.
///
/// The chat shows each email once, but an email can sit on the device more than once: the Sent
/// copy of the user's own post and the copy a mailing list echoed into the Inbox, or one email
/// delivered to two of the user's accounts. THE SYSTEM PROPERTIES pinned here:
///  1. Once the chat has opened, no email of the thread is unread, in any folder or account.
///  2. After a whole-chat Archive or Delete, no email of the thread is left in any Inbox; the
///     user's Sent copy stays in Sent.
///  3. The chat acts on the rows of its thread as it loaded them, each by its own row, never on
///     whatever else carries the same Message-ID (ADR-IOS-068 D4: a Message-ID is never mutation
///     authority): a copy the thread does not reach (Spam), and one that arrives after the chat
///     loaded, keep their folder and their unread state.
///  4. "Unread from here" and "Read up to here" leave each targeted email in one read state in
///     every folder and account the chat loaded it from: its copies change with it, and a copy the
///     thread does not reach does not.
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

    /// A copy of the user's post that reaches the second account after the chat loaded its thread.
    private static func lateCopy(of thread: Thread) -> MessageHeader {
        header("post-late", rfc: thread.postSent.rfc822MessageId!, inReplyTo: nil, accountId: second,
               folder: "INBOX", from: thread.postSent.fromAddress, date: thread.postSent.date, isRead: false)
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

    // MARK: - Whole-chat Archive and Delete

    enum WholeChatAction: String, CaseIterable, Sendable {
        case archive = "Archive chat"
        case delete = "Trash chat"

        func destination(_ accountId: String) -> String { self == .archive ? "Archive" : "Trash" }
    }

    /// Performs a bubble's named whole-chat action, as VoiceOver's actions rotor does.
    private static func perform(_ action: String, in view: UIView) -> Bool {
        for element in HostedAccessibility.elements(under: view) {
            guard let custom = element.accessibilityCustomActions?.first(where: { $0.name == action }) else { continue }
            if let handler = custom.actionHandler { return handler(custom) }
            guard let target = custom.target as? NSObject, target.responds(to: custom.selector) else { return false }
            _ = target.perform(custom.selector, with: custom)
            return true
        }
        return false
    }

    @Test("A whole-chat Archive or Delete moves every copy of its emails out of every Inbox, and nothing its thread did not hold",
          arguments: WholeChatAction.allCases)
    func wholeChatActionMovesEveryCopy(action: WholeChatAction) async throws {
        try await withOpenChat { thread, view in
            // The list's copy of the post reaches the second account after the chat loaded.
            let late = Self.lateCopy(of: thread)
            try await AppDatabase.dbPool.write { db in try late.insert(db) }

            #expect(Self.perform(action.rawValue, in: view), "a bubble offers \(action.rawValue)")
            let moved = thread.loaded.filter { $0.id != thread.postSent.id }
            for _ in 0..<80 {
                let now = try await Self.rows(moved.map(\.id))
                if moved.allSatisfy({ now[$0.id]?.folderPath == action.destination($0.accountId) }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            await AccountManager.shared.awaitWriteQueueDrain()

            let found = try await Self.rows((thread.loaded + [thread.replySpam, late]).map(\.id))
            for row in moved {
                #expect(found[row.id]?.folderPath == action.destination(row.accountId),
                        "\(row.messageId) in \(row.accountId) went to its own account's \(action.destination(row.accountId))")
            }
            #expect(found[thread.postSent.id]?.folderPath == "Sent", "the user's Sent copy stays in Sent")
            #expect(!thread.loaded.contains { found[$0.id]?.isInInbox == true }, "no email of the thread is left in any Inbox")
            #expect(found[thread.replySpam.id]?.folderPath == "Spam" && found[thread.replySpam.id]?.isRead == false,
                    "a copy the thread never reached is not moved by its Message-ID")
            #expect(found[late.id]?.folderPath == "INBOX" && found[late.id]?.isRead == false,
                    "a copy that arrived after the chat loaded is not acted on by its Message-ID")
        }
    }

    // MARK: - The read swipes

    /// Performs `action` on the bubble whose VoiceOver label starts with `sender` ("Sam said: …",
    /// "Sam replied only to …, said: …"), as the actions rotor does.
    private static func perform(_ action: String, onBubbleOf sender: String, in view: UIView) -> Bool {
        for element in HostedAccessibility.elements(under: view)
        where element.accessibilityLabel.map({ $0.hasPrefix("\(sender) ") && $0.contains("said: ") }) == true {
            guard let custom = element.accessibilityCustomActions?.first(where: { $0.name == action }) else { continue }
            if let handler = custom.actionHandler { return handler(custom) }
            guard let target = custom.target as? NSObject, target.responds(to: custom.selector) else { return false }
            _ = target.perform(custom.selector, with: custom)
            return true
        }
        return false
    }

    /// Each element that offers actions, with its label and its actions, for a failure message.
    private static func offeredActions(in view: UIView) -> [String] {
        HostedAccessibility.elements(under: view).compactMap { element in
            guard let actions = element.accessibilityCustomActions, !actions.isEmpty else { return nil }
            return "\(element.accessibilityLabel ?? "<no label>"): \(actions.map(\.name))"
        }
    }

    /// Waits (bounded) until every row in `ids` is in `isRead`, then takes the write-queue barrier.
    private static func settleRead(_ ids: [String], _ isRead: Bool) async throws {
        for _ in 0..<80 {
            let now = try await rows(ids)
            if ids.allSatisfy({ now[$0]?.isRead == isRead }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await AccountManager.shared.awaitWriteQueueDrain()
    }

    private static func setRead(_ id: String, _ isRead: Bool) async throws {
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = ? WHERE id = ?", arguments: [isRead, id])
        }
    }

    @Test("Unread from here and Read up to here change every copy the chat loaded of the emails they target, and no copy its thread did not reach")
    func readSwipesChangeEveryCopy() async throws {
        try await withOpenChat { thread, view in
            // The reply sits in two accounts' Inboxes: the chat shows one row and holds the other as
            // its copy. Its Spam copy is not the chat's.
            let reply = [thread.replyOwn.id, thread.replySecond.id]
            let sender = thread.replyOwn.from

            try await Self.setRead(thread.replySpam.id, true)
            #expect(Self.perform("Unread from here", onBubbleOf: sender, in: view),
                    "the reply's bubble offers Unread from here: \(Self.offeredActions(in: view))")
            try await Self.settleRead(reply, false)
            var found = try await Self.rows(reply + [thread.replySpam.id])
            for id in reply {
                #expect(found[id]?.isRead == false, "\(id): Unread from here leaves the email unread in every place the chat loaded it")
            }
            #expect(found[thread.replySpam.id]?.isRead == true, "a copy the thread never reached keeps its read state")

            try await Self.setRead(thread.replySpam.id, false)
            var offered = false
            for _ in 0..<40 {
                offered = Self.perform("Read up to here", onBubbleOf: sender, in: view)
                if offered { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(offered, "the now unread reply's bubble offers Read up to here: \(Self.offeredActions(in: view))")
            try await Self.settleRead(reply, true)
            found = try await Self.rows(reply + [thread.replySpam.id])
            for id in reply {
                #expect(found[id]?.isRead == true, "\(id): Read up to here reads the email in every place the chat loaded it")
            }
            #expect(found[thread.replySpam.id]?.isRead == false, "a copy the thread never reached keeps its unread state")
        }
    }
}
