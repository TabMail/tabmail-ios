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

    /// The compose card the chat presented, captured once it is open: the chat's own presented
    /// view controller, never the top of the presentation chain, which can be something the
    /// card itself presents. Both card tests read this one view.
    private static func openCard(_ chat: Chat) async throws -> UIView {
        let tapped = ContinuousClock.now
        try await waitUntil { chat.controller.presentedViewController != nil }
        let card = try #require(chat.controller.presentedViewController?.view, "the compose card opened")
        BackgroundSyncLogger.logDebug("[ChatTest] card seen msSinceTap=\((tapped.duration(to: .now) / .milliseconds(1)).rounded()) isBeingPresented=\(chat.controller.presentedViewController?.isBeingPresented ?? false)")
        return card
    }

    /// What the card shows: its accessibility labels and the text of its fields, after a layout
    /// pass (the repo's hosted-poll pattern): the suggestion lands after the card opens, and the
    /// accessibility walk forces no layout of its own.
    private static func cardTexts(_ card: UIView) -> [String] {
        card.window?.layoutIfNeeded()
        card.layoutIfNeeded()
        return HostedAccessibility.labels(in: card) + fieldTexts(card)
    }

    /// What is on screen, for a failure message: the presentation chain from the chat, whether
    /// the card is in a window, whether Use Suggestion or a body text view is in its tree, and
    /// every label it holds.
    private static func cardReport(_ chat: Chat, _ card: UIView) -> String {
        var chain: [String] = []
        var next = chat.controller.presentedViewController
        while let current = next {
            chain.append(String(describing: type(of: current)))
            next = current.presentedViewController
        }
        let labels = HostedAccessibility.labels(in: card)
        let hasTextView = HostedAccessibility.elements(under: card).contains { $0 is UITextView }
        return "presented=\(chain) window=\(card.window != nil) useSuggestion=\(labels.contains("Use Suggestion")) "
            + "bodyTextView=\(hasTextView) labels=\(labels) fields=\(fieldTexts(card))"
    }

    /// Presses the card's button labelled `label`, as a VoiceOver double tap does.
    private static func press(_ label: String, in card: UIView) -> Bool {
        HostedAccessibility.elements(under: card).first { $0.accessibilityLabel == label }?.accessibilityActivate() ?? false
    }

    /// The alert titled `title` the card presented, if it is showing.
    private static func alert(_ title: String, from chat: Chat) -> UIAlertController? {
        var next = chat.controller.presentedViewController
        while let current = next {
            if let alert = current as? UIAlertController, alert.title == title { return alert }
            next = current.presentedViewController
        }
        return nil
    }

    /// Taps the alert button titled `button`, running its handler.
    private static func tap(_ button: String, on alert: UIAlertController) throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let action = try #require(alert.actions.first { $0.title == button }, "the alert has \(button)")
        try #require(action.responds(to: NSSelectorFromString("handler")), "UIAlertAction exposes its handler")
        let block = try #require(action.value(forKey: "handler") as AnyObject?, "\(button) has a handler")
        let handler = unsafeBitCast(block, to: Handler.self)
        alert.dismiss(animated: false) { handler(action) }
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
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        try await withChat { chat in
            let ghost = try #require(Self.ghost(in: chat.view))
            #expect(chat.controller.presentedViewController == nil, "control: nothing open yet")
            // The row's reply changes under the ghost with no refresh yet: the card still holds the
            // reply the user tapped, never a later read of the row.
            try await chat.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?",
                               arguments: ["Hello Sam,\n\nA different reply.", chat.email.id])
            }
            #expect(ghost.accessibilityLabel == "\(ChatSuggestionConfig.label): Yes, Tuesday works for me.",
                    "the ghost still reads as one element: \(String(describing: ghost.accessibilityLabel))")
            #expect(ghost.accessibilityActivate(), "the ghost takes a tap")
            let card = try await Self.openCard(chat)
            var found: [String] = []
            try await Self.waitUntil {
                found = Self.cardTexts(card)
                return found.contains { $0.contains("Yes, Tuesday works for me.") }
            }
            #expect(found.contains { $0.contains("Hello Sam") }, "the full email is on the card: \(found)")
            #expect(!found.contains { $0.contains("A different reply") }, "never the row's later reply: \(found)")
            let queued = try await chat.pool.read { try OutboxMessage.fetchCount($0) }
            #expect(queued == 0, "nothing was sent")
            chat.controller.dismiss(animated: false)
            try await Self.waitUntil { chat.controller.presentedViewController == nil }
            #expect(Self.ghost(in: chat.view) != nil, "Close goes back with the ghost still there")
        }
    }

    @Test("A saved reply draft stays as it is: the ghost's card shows the suggestion, and the draft keeps its words")
    func savedDraftStaysInDrafts() async throws {
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        try await withChat { chat in
            let now = Date().timeIntervalSince1970
            let key = Draft.draftKey(replyTo: "\(chat.email.accountId):\(chat.email.stableId)", isForward: false, newId: nil)
            let saved = Draft(
                id: key, accountId: Self.account,
                toJSON: "[\"sam@example.com\"]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "My own words, not sent yet",
                replyToId: chat.email.id, isForward: false, editHistoryJSON: nil,
                createdAt: now, updatedAt: now,
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            try await chat.pool.write { db in try saved.insert(db) }
            let ghost = try #require(Self.ghost(in: chat.view))
            #expect(ghost.accessibilityLabel == "\(ChatSuggestionConfig.label): Yes, Tuesday works for me.",
                    "the ghost still reads as one element: \(String(describing: ghost.accessibilityLabel))")
            #expect(ghost.accessibilityActivate(), "the ghost takes a tap")
            let card = try await Self.openCard(chat)
            var found: [String] = []
            try await Self.waitUntil {
                found = Self.cardTexts(card)
                return found.contains { $0.contains("Yes, Tuesday works for me.") }
            }
            #expect(found.contains { $0.contains("Yes, Tuesday works for me.") },
                    "the card holds the suggestion: \(Self.cardReport(chat, card))")
            #expect(found.contains { $0.contains("Hello Sam") }, "the full email is on the card: \(found)")
            #expect(!found.contains { $0.contains("My own words") }, "never the saved draft: \(found)")
            // Both sides: the suggestion saved from the card goes to a row of its own, and the
            // saved reply draft keeps its words.
            #expect(Self.press("Use Suggestion", in: card), "Use Suggestion takes a tap: \(Self.cardReport(chat, card))")
            try await Self.waitUntil { !Self.cardTexts(card).contains("Use Suggestion") }
            #expect(Self.press("Close", in: card), "Close takes a tap: \(Self.cardReport(chat, card))")
            try await Self.waitUntil { Self.alert("Save Draft?", from: chat) != nil }
            try Self.tap("Save", on: try #require(Self.alert("Save Draft?", from: chat), "Close asks to save"))
            try await Self.waitUntil { chat.controller.presentedViewController == nil }
            let after = try await chat.pool.read { try Draft.fetchOne($0, key: key) }
            #expect(after?.body == "My own words, not sent yet" && after?.updatedAt == now, "the saved draft is untouched")
            var own: [Draft] = []
            try await Self.waitUntil {
                own = try await chat.pool.read {
                    try Draft.filter(Column("id").like("\(Draft.separateReplyPrefix)%")).fetchAll($0)
                }
                return !own.isEmpty
            }
            #expect(own.count == 1, "one new row of its own: \(own.map(\.id))")
            #expect(own.first?.body.contains("Yes, Tuesday works for me.") == true,
                    "the new row holds the suggestion: \(String(describing: own.first?.body))")
        }
    }

    @Test("The card from the ghost shows the bubble, and Use Suggestion puts the suggestion in the body")
    func useSuggestionFillsTheBody() async throws {
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        try await withChat { chat in
            let ghost = try #require(Self.ghost(in: chat.view))
            #expect(ghost.accessibilityActivate(), "the ghost takes a tap")
            let card = try await Self.openCard(chat)
            try await Self.waitUntil { Self.cardTexts(card).contains("Use Suggestion") }
            #expect(Self.press("Use Suggestion", in: card), "the bubble is usable: \(Self.cardReport(chat, card))")
            try await Self.waitUntil { Self.fieldTexts(card).contains { $0.contains("Yes, Tuesday works for me.") } }
            #expect(Self.fieldTexts(card).contains { $0.contains("Yes, Tuesday works for me.") },
                    "Use Suggestion puts it in the body: \(Self.cardReport(chat, card))")
            chat.controller.dismiss(animated: false)
            try await Self.waitUntil { chat.controller.presentedViewController == nil }
        }
    }

    @Test("A separate reply key names the same parent as the reply's usual key, and never collides with it")
    func separateReplyKeyNamesTheParent() {
        let parent = "acc-1:<a@example.com>"
        let usual = Draft.draftKey(replyTo: parent, isForward: false, newId: nil)
        let own = Draft.separateReplyKey(replyTo: parent)
        #expect(own != usual && own != Draft.separateReplyKey(replyTo: parent), "a key of its own, every time")
        #expect(Draft.replyKeyTail(draftKey: own, isForward: false).map(String.init) == parent)
        #expect(Draft.replyKeyParent(draftKey: own, isForward: false)?.stableId == "<a@example.com>")
        #expect(Draft.replyKeyTail(draftKey: own, isForward: true) == nil, "never a forward")
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
