/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 11: who gets a reply the chat opens.
///
/// THE SYSTEM PROPERTY pinned here: the compose card the chat opens for the agent's reply goes to
/// the recipients the agent's request produced; the reply the chat's field writes
/// (`ChatFieldCompose`, ADR-IOS-114 decision 10) goes to the choice the user made in Reply to, as it
/// was when the words were sent. Whether the chat's sheet is open when the card arrives, which chat
/// receives it, and what Reply to shows by then never decide who the email goes to.
///
/// Each case opens the chat for real in a window, picks who gets the reply through the Reply to
/// sheet as the user does, holds the real reply request behind a compose already on screen,
/// releases it, and reads the recipients of the compose card the chat opens. Every request is asked
/// in this chat (`ComposeOrigin`, ADR-IOS-053 Phase 2), so this chat's pill takes it; the field's
/// reply runs the field's compose with the invocation the field's send builds (`ChatFieldReply`, its
/// building pinned in `ChatReplyFieldTests.recipientsWiring`), its email written by a stand-in
/// request that changes no recipients.
@Suite("Who gets the agent's reply in the chat", .serialized, .processGlobalState)
@MainActor
struct ChatReplyComposeOriginTests {
    private static let account = "acc-chat-origin"
    private static let me = "me@example.com"

    /// The chat's email: from Alex to the user and David, Cc Sam.
    private static func groupEmail() -> MessageHeader {
        var header = MessageHeader(
            messageId: "origin-a", subject: "Plans", from: "Alex Doe <alex@example.com>",
            fromAddress: "alex@example.com", to: "\(me), david@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Tuesday works.",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.cc = "sam@example.com"
        header.rfc822MessageId = "<origin-a@example.com>"
        header.headerComplete = true
        header.isRead = true
        return header
    }

    /// An email of another chat: from Carol to the user.
    private static func otherEmail() -> MessageHeader {
        var header = MessageHeader(
            messageId: "origin-b", subject: "Other plans", from: "Carol Roe <carol@example.com>",
            fromAddress: "carol@example.com", to: me,
            date: Date().addingTimeInterval(-1200), snippet: "Lunch?",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<origin-b@example.com>"
        header.headerComplete = true
        header.isRead = true
        return header
    }

    /// The open chat, the database it reads, and the agent's reply tool on that database.
    @MainActor
    struct Chat {
        let pool: DatabasePool
        let controller: UIHostingController<AnyView>
        let email: MessageHeader
        let other: MessageHeader
        let translator: MockChatIdTranslator
        /// This chat, as a turn sent in it names itself: where its compose cards open.
        let asked: ComposeOrigin

        var view: UIView { controller.view }

        /// The agent's reply tool, opening its compose through the app's router, as in the app.
        var tool: EmailReplyTool {
            EmailReplyTool(context: ToolContext(db: pool, translator: translator, router: AgentToolRouter.shared))
        }
    }

    /// Opens the chat on `groupEmail()` in a window and runs `body`, then closes everything.
    private func withChat(_ body: @MainActor (Chat) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        let router = AgentToolRouter.shared
        router.resetComposeQueueForTesting()
        defer {
            router.resetComposeQueueForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        var account = Account(emailAddress: Self.me, displayName: "Me", provider: .gmail)
        account.id = Self.account
        let accountRow = account
        let email = Self.groupEmail()
        let other = Self.otherEmail()
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.account)
        try await pool.write { db in
            try accountRow.insert(db)
            try inbox.insert(db)
            try email.insert(db)
            try other.insert(db)
        }
        let translator = MockChatIdTranslator()
        await translator.seed(email.id, as: 1)
        await translator.seed(other.id, as: 2)
        // The chat's pill is keyed by its email as stored (`ChatThreadKey`).
        let storedEmail = try await pool.read { db in try MessageHeader.fetchOne(db, key: email.id) }
        let stored = try #require(storedEmail, "control: the chat's email is stored")
        let asked = ComposeOrigin(sessionKey: ChatThreadKey.key(for: stored), screen: .chat)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        // The compose the chat opens reads the app's accounts from the navigation store, as in the app.
        let navigationStore = NavigationStore()
        navigationStore.accounts = [accountRow]
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack { ChatThreadView(messageId: email.id) }.environment(navigationStore)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Closes the chat and waits for the compose it opened to report itself gone, so its late
        // report never releases the next case's held request.
        func close() async throws {
            window.isHidden = true
            window.rootViewController = nil
            try await Self.waitUntil { router.composePresentationCount == 0 }
            try await Task.sleep(for: .milliseconds(300))
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
        }
        let chat = Chat(pool: pool, controller: controller, email: email, other: other, translator: translator, asked: asked)
        try await Self.waitUntil { Self.namesButton(in: chat.view) != nil }
        #expect(Self.namesButton(in: chat.view) != nil, "control: the chat shows its header: \(HostedAccessibility.labels(in: chat.view).prefix(12))")
        do {
            try await body(chat)
        } catch {
            try? await close()
            throw error
        }
        try await close()
    }

    /// The header's names, which open Reply to.
    private static func namesButton(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityHint == "Changes who gets your reply" }
    }

    /// Picks who gets the reply in the Reply to sheet, as the user does: unticks `untick`, then Done.
    private static func replyOnly(untick: [String], in chat: Chat) async throws {
        let names = try #require(namesButton(in: chat.view))
        #expect(names.accessibilityActivate(), "control: the header's names open Reply to")
        try await waitUntil { chat.controller.presentedViewController != nil }
        let sheet = try #require(chat.controller.presentedViewController?.view, "control: Reply to is open")
        try await waitUntil { row(untick[0], in: sheet) != nil }
        for address in untick {
            let person = try #require(row(address, in: sheet), "control: Reply to lists \(address): \(HostedAccessibility.labels(in: sheet))")
            #expect(person.accessibilityActivate(), "control: \(address) is unticked")
            try await Task.sleep(for: .milliseconds(200))
        }
        let done = try #require(HostedAccessibility.elements(under: sheet).first { $0.accessibilityLabel == "Done" },
                                "control: Reply to has Done: \(HostedAccessibility.labels(in: sheet))")
        #expect(done.accessibilityActivate(), "control: Done")
        try await waitUntil { chat.controller.presentedViewController == nil && replyingOnlyTo(in: chat.view) != nil }
        #expect(replyingOnlyTo(in: chat.view) != nil, "control: the chat replies only to the people left: \(HostedAccessibility.labels(in: chat.view).prefix(16))")
    }

    private static func row(_ address: String, in sheet: UIView) -> NSObject? {
        HostedAccessibility.elements(under: sheet).first { ($0.accessibilityLabel ?? "").contains(address) }
    }

    /// The "Replying only to" line above the field, if shown.
    private static func replyingOnlyTo(in view: UIView) -> String? {
        HostedAccessibility.labels(in: view).first { $0.hasPrefix("Replying only to") }
    }

    /// Runs a reply request (`run`: the agent's reply tool or the field's compose), holding its compose card behind a compose already
    /// on screen; `whileHeld` runs before the card is let through. Returns the card's recipients by
    /// field, read from the compose the chat opens once its `fields` all show addresses (a check
    /// that reads a field passes it: the card's rows join the accessibility tree one by one, #1498).
    private static func heldReply(
        in chat: Chat, run: @escaping @MainActor () async throws -> String,
        whileHeld: @MainActor () async throws -> Void = {}, showing fields: [String] = ["to"]
    ) async throws -> [String: String] {
        let router = AgentToolRouter.shared
        // A compose on screen holds the agent's request in the queue (ADR-IOS-030).
        router.composePresentationDidBegin()
        let task = Task { @MainActor in try await run() }
        defer { task.cancel() }
        try await waitUntil { router.composeQueueDepth == 1 }
        #expect(router.composeQueueDepth == 1, "control: the reply request waits behind the compose on screen")
        try await whileHeld()
        router.composePresentationDidEnd()
        var recipients: [String: String] = [:]
        try await waitUntil {
            recipients = composeRecipients(chat.controller.presentedViewController?.view)
            return fields.allSatisfy { recipients[$0]?.isEmpty == false }
        }
        return recipients
    }

    /// The compose's addresses by field ("to", "cc", "bcc"), as its recipient fields name them.
    private static func composeRecipients(_ view: UIView?) -> [String: String] {
        guard let view else { return [:] }
        var found: [String: String] = [:]
        for element in HostedAccessibility.elements(under: view) {
            guard let identifier = HostedAccessibility.identifier(of: element),
                  identifier.hasPrefix("recipientInput-") else { continue }
            found[String(identifier.dropFirst("recipientInput-".count))] = element.accessibilityLabel ?? ""
        }
        return found
    }

    private static func addresses(_ field: String?) -> Set<String> {
        Set((field ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// Polls `condition` for up to five seconds; the caller asserts on it afterwards.
    private static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The request as the reply field sends it about `email` in `chat`: who was chosen in Reply to
    /// when sent.
    private static func field(_ email: MessageHeader, onlyTo: [String]?, in chat: Chat) -> ToolInvocation {
        ToolInvocation(fieldReply: ChatFieldReply(email: email, onlyTo: onlyTo), composeOrigin: chat.asked)
    }

    /// The field's compose on the chat's database, opening its card through the app's router, as in
    /// the app; the request writes an email and changes no recipients.
    private static func fieldCompose(in chat: Chat) -> ChatFieldCompose {
        ChatFieldCompose(
            context: ToolContext(db: chat.pool, translator: chat.translator, router: AgentToolRouter.shared),
            composeText: { _, _, _, _ in
                guard let written = AIService.parseInlineEditResponse(ComposeEditJSON.make(
                    response: "Done.", subject: "Re: Plans", body: "Hi,\n\nFriday works.\n\nMe",
                    textMessage: "Friday works", changeCommand: "")) else {
                    throw InlineEditFailure(message: "control: the stand-in answer parses")
                }
                return written
            })
    }

    /// A request asked in `chat`'s open sheet: no field choice.
    private static func sheet(in chat: Chat) -> ToolInvocation {
        ToolInvocation(composeOrigin: chat.asked)
    }

    // MARK: - A request from elsewhere keeps its recipients

    @Test("A reply asked for in the open sheet keeps its recipients when the sheet closes before its card arrives")
    func panelClosedBeforeDelivery() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                try await Self.replyOnly(untick: ["alex@example.com", "sam@example.com"], in: chat)
                // The sheet opens, the reply is asked for there, and the sheet closes before the card.
                NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": chat.email.id])
                try await Task.sleep(for: .milliseconds(500))
                let tool = chat.tool
                let invocation = Self.sheet(in: chat)
                let card = try await Self.heldReply(in: chat, run: {
                    try await tool.execute(arguments: ["unique_id": .int(1), "body": .string("Friday works")], invocation: invocation)
                }, whileHeld: {
                    NotificationCenter.default.post(name: .emailPillTapped, object: nil)
                    try await Task.sleep(for: .milliseconds(500))
                }, showing: ["to", "cc"])
                #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"],
                        "the agent's To, not the chat's choice: \(card)")
                #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "the agent's Cc stays: \(card)")
            }
        }
    }

    @Test("A reply asked in this chat to another chat's email keeps that email's recipients")
    func requestFromAnotherChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                try await Self.replyOnly(untick: ["alex@example.com", "sam@example.com"], in: chat)
                let tool = chat.tool
                let invocation = Self.sheet(in: chat)
                let card = try await Self.heldReply(in: chat, run: {
                    try await tool.execute(arguments: ["unique_id": .int(2), "body": .string("Lunch works")], invocation: invocation)
                })
                #expect(Self.addresses(card["to"]) == ["carol@example.com"],
                        "the other chat's reply goes to its own people, never this chat's choice: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty, "\(card)")
            }
        }
    }

    // MARK: - The field's reply applies the choice made when it was sent

    @Test("A reply asked for in the field goes to the people chosen when it was sent, whatever the chat shows when it arrives")
    func fieldRequestUsesItsCapturedChoice() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                // Sent replying only to David; the chat is back at everyone when the card arrives.
                #expect(Self.replyingOnlyTo(in: chat.view) == nil, "control: the chat replies to everyone")
                let compose = Self.fieldCompose(in: chat)
                let invocation = Self.field(chat.email, onlyTo: ["david@example.com"], in: chat)
                let card = try await Self.heldReply(in: chat, run: {
                    _ = await compose.reply("Friday works", invocation: invocation)
                    return ""
                })
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only the people chosen: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
            }
        }
    }

    @Test("A reply asked for in the field with nobody chosen keeps its recipients after the chat narrows Reply to")
    func fieldRequestToEveryoneKeepsItsRecipients() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                let compose = Self.fieldCompose(in: chat)
                let invocation = Self.field(chat.email, onlyTo: nil, in: chat)
                let card = try await Self.heldReply(in: chat, run: {
                    _ = await compose.reply("Friday works", invocation: invocation)
                    return ""
                }, whileHeld: {
                    try await Self.replyOnly(untick: ["alex@example.com", "sam@example.com"], in: chat)
                }, showing: ["to", "cc"])
                #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"], "everyone, as when sent: \(card)")
                #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "\(card)")
            }
        }
    }
}
