/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114: the AI Suggestion in the chat, opened for real in a window.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The ready suggestion shows as a ghost of the user's next message, labelled "AI Suggestion",
///     with "AI Suggestion · Tap to use" under it; the field stays empty.
///  2. A tap on it opens the compose card with the suggestion written out, and sends nothing.
///  3. One copy: the ghost reads the email's row, so a new text version there rewrites it in place,
///     and the old text is gone.
///  4. The chat view says "AI Suggestion", never "AI Reply", in any string a user sees or hears.
@Suite("The chat's AI Suggestion", .serialized, .processGlobalState)
@MainActor
struct ChatSuggestionBubbleTests {
    private static let account = "acc-chat-ghost"
    private static let ready = "Yes, Tuesday works for me."
    private static let fullReply = "Hello Sam,\n\nYes, Tuesday works for me.\n\nThanks."

    private static func header() -> MessageHeader {
        var header = MessageHeader(
            messageId: "ghost-1", subject: "Lunch plans", from: "Sam Lee <sam@example.com>",
            fromAddress: "sam@example.com", to: "me@example.com", date: Date().addingTimeInterval(-600),
            snippet: "Lunch on Tuesday?",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<ghost-1@example.com>"
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        header.summaryTextMessage = "Lunch on Tuesday?"
        header.cachedReply = fullReply
        header.replyTextMessage = ready
        return header
    }

    @MainActor
    struct Chat {
        let controller: UIHostingController<AnyView>
        let pool: DatabasePool
        let email: MessageHeader
        var view: UIView { controller.view }
    }

    private func withChat(_ body: @MainActor (Chat) async throws -> Void) async throws {
        try await HostedAccessibility.withAutomation { try await withChatBody(body) }
    }

    private func withChatBody(_ body: @MainActor (Chat) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        ChatPillState.shared.removeAllSessions()
        defer {
            ChatPillState.shared.removeAllSessions()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        // Every exit, setup included, gives the queue back as it was.
        do {
            try await runChat(pool: pool, saved: saved, body)
        } catch {
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
            throw error
        }
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    private func runChat(
        pool: DatabasePool, saved: ChatSummaryQueueTests.SavedChatViewState,
        _ body: @MainActor (Chat) async throws -> Void
    ) async throws {
        saved.setChatView(on: true)
        _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        let email = Self.header()
        try await pool.write { db in try email.insert(db) }
        // The compose card reads the app's accounts from the navigation store, as in the app.
        let navigationStore = NavigationStore()
        navigationStore.accounts = try await pool.read { try Account.fetchAll($0) }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: AnyView(NavigationStack {
            ChatThreadView(messageId: email.id)
        }.environment(navigationStore).environment(\.hasTabMailSession, true)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let chat = Chat(controller: controller, pool: pool, email: email)
        try await Self.waitUntil { Self.ghost(in: chat.view) != nil }
        try await body(chat)
    }

    private static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func ghost(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first {
            HostedAccessibility.identifier(of: $0) == ChatSuggestionBubble.bubbleId
        }
    }

    private static func fieldTexts(_ view: UIView) -> [String] {
        let own = (view as? UITextView).map { [$0.text ?? ""] } ?? (view as? UITextField).map { [$0.text ?? ""] } ?? []
        return own + view.subviews.flatMap { fieldTexts($0) }
    }

    // MARK: - 1. The ghost

    @Test("The ready suggestion is a ghost labelled AI Suggestion, with its status line; the field stays empty")
    func ghostShowsTheSuggestion() async throws {
        try await withChat { chat in
            let ghost = try #require(Self.ghost(in: chat.view), "the chat shows the AI Suggestion")
            #expect(ghost.accessibilityLabel == "AI Suggestion: \(Self.ready)")
            let labels = HostedAccessibility.labels(in: chat.view)
            let texts = Self.fieldTexts(chat.view)
            #expect(!texts.isEmpty && texts.allSatisfy { $0.isEmpty }, "the field holds no AI text: \(texts)")
            #expect(HostedAccessibility.identifiers(in: chat.view).contains(DynamicIslandChat.exampleLineId),
                    "the empty field shows its e.g. line")
            let example = labels.first { $0.hasPrefix("e.g. ") }
            let picked = try #require(example.map { String($0.dropFirst("e.g. ".count)) }, "the line reads e.g.: \(labels)")
            #expect(ChatSuggestionConfig.replyExamples.contains(picked), "from the config set: \(picked)")
        }
    }

    // MARK: - 2. A tap opens the compose card

    @Test("A tap on the AI Suggestion opens the compose card with it written out, and sends nothing")
    func tapOpensTheComposeCard() async throws {
        try await withChat { chat in
            let ghost = try #require(Self.ghost(in: chat.view))
            #expect(chat.controller.presentedViewController == nil, "control: nothing open yet")
            #expect(ghost.accessibilityActivate(), "the ghost takes a tap")
            try await Self.waitUntil { chat.controller.presentedViewController != nil }
            let card = try #require(chat.controller.presentedViewController?.view, "the compose card opened")
            var found: [String] = []
            try await Self.waitUntil {
                found = HostedAccessibility.labels(in: card) + Self.fieldTexts(card)
                return found.contains { $0.contains("Yes, Tuesday works for me.") }
            }
            #expect(found.contains { $0.contains("Hello Sam") }, "the full email is on the card: \(found)")
            let queued = try await chat.pool.read { try OutboxMessage.fetchCount($0) }
            #expect(queued == 0, "nothing was sent")
            chat.controller.dismiss(animated: false)
            try await Self.waitUntil { chat.controller.presentedViewController == nil }
            #expect(Self.ghost(in: chat.view) != nil, "Close goes back with the ghost still there")
        }
    }

    // MARK: - 3. One copy, rewritten in place

    @Test("A new text version on the email's row rewrites the ghost in place; the old text is gone")
    func ghostFollowsTheRow() async throws {
        try await withChat { chat in
            let id = chat.email.id
            try await chat.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                               arguments: ["Hello Sam,\n\nI can't make Tuesday.\n\nThanks.", "Sorry, I can't make Tuesday.", id])
            }
            // The row-change event the AI's reply writers post after they store a reply.
            NotificationCenter.default.post(name: .messageDataDidChange, object: id)
            try await Self.waitUntil { Self.ghost(in: chat.view)?.accessibilityLabel == "AI Suggestion: Sorry, I can't make Tuesday." }
            let ghosts = HostedAccessibility.elements(under: chat.view).filter {
                HostedAccessibility.identifier(of: $0) == ChatSuggestionBubble.bubbleId
            }
            #expect(ghosts.count == 1, "one ghost")
            #expect(ghosts.first?.accessibilityLabel == "AI Suggestion: Sorry, I can't make Tuesday.")
            #expect(!HostedAccessibility.labels(in: chat.view).contains { $0.contains(Self.ready) }, "the old text is gone")
        }
    }

    @Test("An edit of the suggestion stored from compose takes the ghost away: its text no longer matches")
    func composeEditRetiresTheGhost() async throws {
        try await withChat { chat in
            #expect(Self.ghost(in: chat.view) != nil, "control: the ghost shows")
            // Compose's own writer, as when the user edits the suggestion in the card.
            await ComposeView.writeCachedReplyToDB("Hello Sam,\n\nMaybe Wednesday?", replyTo: chat.email, db: chat.pool)
            try await Self.waitUntil { Self.ghost(in: chat.view) == nil }
            #expect(Self.ghost(in: chat.view) == nil, "the stale suggestion is gone without leaving the chat")
            let stored = try await chat.pool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }
            #expect(stored?.cachedReply == "Hello Sam,\n\nMaybe Wednesday?", "control: the edit was stored")
        }
    }

    // MARK: - 4. The name

    @Test("No string in the chat view says AI Reply")
    func noAIReplyString() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "TabMail/Views/Chat", "TabMail/Views/Tutorial",
        ].flatMap { dir -> [URL] in
            let url = root.appendingPathComponent(dir)
            return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "swift" }
        } + [
            root.appendingPathComponent("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift"),
            root.appendingPathComponent("TabMail/Views/Inbox/DynamicIslandChatButton.swift"),
            root.appendingPathComponent("TabMail/Services/Tutorial/TutorialCoachContent.swift"),
            root.appendingPathComponent("TabMail/Services/ChatViewConfig.swift"),
        ]
        #expect(files.count > 8, "control: the chat view's sources were found")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("AI Reply") {
                let code = line.trimmingCharacters(in: .whitespaces)
                #expect(code.hasPrefix("//"), "\(file.lastPathComponent): \(code)")
            }
        }
    }
}
