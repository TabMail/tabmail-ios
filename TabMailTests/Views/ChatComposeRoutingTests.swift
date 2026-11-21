/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-053 Phase 2: where the agent's compose card opens, and to whom, with the chat open over
/// another screen.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. With the chat pushed over the inbox, or over the email screen of the same email, a reply
///     asked for in the chat's reply field with only David chosen opens a card to David alone, with
///     no Cc and no Bcc; with nobody chosen, a Reply All to everyone. The screen under the chat,
///     whose own cards are Reply All, never takes the chat's request.
///  2. A request whose chat is not showing opens nothing on the screen under it, and opens as asked
///     when the chat shows again, once: closing the chat and showing it again opens no second card.
///  3. After the card for a field request closes, the agent's closing words leave the chat's sheet
///     closed (`fieldComposeOpened`); a field request the agent answers without a card opens it.
///  4. A screen's pill takes its requests only while the screen is on screen: the inbox's request
///     waits while the chat is pushed over the inbox (whose pill stays mounted under it), and opens
///     when the inbox shows again.
///  5. The inbox's and the email screen's own pills stamp their requests with their own screen, and
///     the card opens there.
///
/// Each case mounts the real screens in a window: a NavigationStack with the inbox (or the email
/// screen) at its root and the chat pushed over it, both mounted as in the app (case 5 mounts the
/// root screen alone). The requests go to a fake backend that asks for `email_reply` on the email
/// the request names, and answers "Done" once the tool has returned. The user picks who gets the
/// reply in Reply to and taps the field's Send (or the open pill's Send) for real; the reply's
/// request is held behind a compose already on screen, checked, then let through, and the
/// recipients of the card that opens are read from its fields.
///
/// Cases 1 to 3 use only the router's test hooks (`composePresentationDidBegin/End`,
/// `composeQueueDepth`, `firstQueuedRequestForTesting`), never its handoff, so apart from case 1's
/// origin check they also ran on the code before the fix. There, case 2 failed every time: the screen under the chat was the only one
/// left to take the request, and opened a Reply All card. Cases 1 and 3 failed whenever the screen
/// under the chat took the request before the chat did, which SwiftUI's update order decided.
/// Cases 4 and 5 read the request's `ComposeOrigin`, which that code did not have.
@Suite("Where the agent's compose card opens", .serialized, .processGlobalState)
@MainActor
struct ChatComposeRoutingTests {
    private static let account = "acc-compose-routing"
    private static let me = "me@example.com"

    /// The chat's email: from Alex to the user and David, Cc Sam. One per case, so no case meets
    /// another's chat.
    private static func groupEmail(_ tag: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: "routing-\(tag)", subject: "Plans", from: "Alex Doe <alex@example.com>",
            fromAddress: "alex@example.com", to: "\(me), david@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Tuesday works.",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.cc = "sam@example.com"
        header.rfc822MessageId = "<routing-\(tag)@example.com>"
        header.headerComplete = true
        header.isRead = true
        return header
    }

    /// The screen the chat is pushed over.
    enum Root: String, CaseIterable, Sendable {
        case inbox
        case email
    }

    /// The fake backend: a request with no saved state asks for `email_reply` on the email it names
    /// (unless `asksForReply` is false), or on the email set with `reply(to:)` for a request that
    /// names none (the inbox's chat); one carrying the tool's result is answered "Done".
    final class Backend: @unchecked Sendable {
        let http = FakeHTTP.Scenario()
        final class Record: Sendable {
            let bodies = Mutex<[String]>([])
            let emailNumber = Mutex<Int?>(nil)
        }
        private let record = Record()

        init(asksForReply: Bool = true) {
            http.register(path: "/completions/chat", method: "POST") { [record] request in
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                record.bodies.withLock { $0.append(body) }
                let final: [String: Any]
                if body.contains("conversation_state") || !asksForReply {
                    final = ["assistant": "Done"]
                } else {
                    let number = ChatReplyRecoveryTests.Backend.emailNumber(in: body)
                        ?? record.emailNumber.withLock { $0 } ?? 0
                    let arguments: [String: Any] = ["unique_id": number, "body": "Friday works"]
                    let argumentsText = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    final = [
                        "assistant": "",
                        "tool_calls": [["id": "tc-reply", "function": ["name": "email_reply", "arguments": argumentsText]]],
                        "conversation_state": ["harmony_messages": [], "current_round": 1],
                    ]
                }
                let text = String(decoding: try! JSONSerialization.data(withJSONObject: final), as: UTF8.self)
                return .bytes(Data("event: final\ndata: \(text)\n\n".utf8), contentType: "text/event-stream")
            }
        }

        var service: AIService {
            AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        }

        var bodies: [String] { record.bodies.withLock { $0 } }

        /// The email, by its number in the chat, a request that names none asks to reply to.
        func reply(to number: Int) {
            record.emailNumber.withLock { $0 = number }
        }
    }

    /// Whether the chat is pushed over the root screen.
    @MainActor @Observable
    final class Route {
        var chatShown = false
    }

    /// The root screen with the chat pushed over it while `route.chatShown`.
    private struct Stack<Content: View>: View {
        @Bindable var route: Route
        let chatId: String
        let root: Content

        var body: some View {
            let _ = route.chatShown
            NavigationStack {
                root.navigationDestination(isPresented: $route.chatShown) {
                    ChatThreadView(messageId: chatId)
                }
            }
        }
    }

    /// The mounted screens.
    @MainActor
    struct Screens {
        let controller: UIHostingController<AnyView>
        let route: Route
        let email: MessageHeader
        /// The key of the email's thread, as stored: the chat of the email screen and the chat view.
        let threadKey: String
        var view: UIView { controller.view }

        /// Every view controller presented over the screens, bottom first.
        var presented: [UIViewController] {
            var chain: [UIViewController] = []
            var next = controller.presentedViewController
            while let current = next {
                chain.append(current)
                next = current.presentedViewController
            }
            return chain
        }
    }

    /// Mounts `root` with the chat on `groupEmail(tag)` pushed over it (unless `chat` is false), its
    /// requests going to `backend`, and runs `body`.
    private func withScreens(
        _ root: Root, _ backend: Backend, tag: String, chat: Bool = true, _ body: @MainActor (Screens) async throws -> Void
    ) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        let router = AgentToolRouter.shared
        router.resetComposeQueueForTesting()
        ChatPillState.shared.removeAllSessions()
        ChatPillState.shared.aiService = backend.service
        defer {
            ChatPillState.shared.aiService = .shared
            ChatPillState.shared.removeAllSessions()
            backend.http.close()
            router.resetComposeQueueForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        var account = Account(emailAddress: Self.me, displayName: "Me", provider: .gmail)
        account.id = Self.account
        let accountRow = account
        let email = Self.groupEmail(tag)
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.account)
        try await pool.write { db in
            try accountRow.insert(db)
            try inbox.insert(db)
            try email.insert(db)
        }
        let storedFolder = try await pool.read { db in
            try Folder.filter(Column("accountId") == Self.account && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        }
        let folder = try #require(storedFolder, "control: the inbox folder is stored")
        let storedEmail = try await pool.read { db in try MessageHeader.fetchOne(db, key: email.id) }
        let stored = try #require(storedEmail, "control: the email is stored")
        let threadKey = ChatThreadKey.key(for: stored)

        let route = Route()
        let chatId = email.id
        let rootView: AnyView
        switch root {
        case .inbox:
            rootView = AnyView(Stack(route: route, chatId: chatId, root: InboxView(
                title: "Inbox", folders: [folder], selection: .unified(.inbox),
                selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))))
        case .email:
            rootView = AnyView(Stack(route: route, chatId: chatId, root: MessageDetailView(messageId: chatId)))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [accountRow]
        let controller = UIHostingController(rootView: AnyView(
            rootView
                .environment(navigationStore)
                .environment(\.hasTabMailSession, true)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // The registry's tools keep the database they were made with, which is an earlier test's
        // once one has run; the agent's email_reply reads this database.
        let registry = ToolRegistry.shared
        await registry.ensureDefaultToolsRegistered()
        let registeredReply = await registry.tool(named: "email_reply")
        await registry.register(EmailReplyTool(context: ToolContext(db: pool, translator: ChatIdTranslator.shared)))
        // A card left open keeps its turn going: closing cancels it, and clears the working mark a
        // cancelled turn leaves.
        func close() async throws {
            ChatPillState.shared.removeAllSessions()
            ActiveAgentTracker.shared.clearWorking(ChatThreadKey.key(for: email))
            ActiveAgentTracker.shared.clearWorking(threadKey)
            ActiveAgentTracker.shared.clearWorking("inbox")
            window.isHidden = true
            window.rootViewController = nil
            try await Self.waitUntil { router.composePresentationCount == 0 }
            try await Task.sleep(for: .milliseconds(300))
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
            if let registeredReply { await registry.register(registeredReply) }
        }
        let screens = Screens(controller: controller, route: route, email: email, threadKey: threadKey)
        do {
            // The root screen shows first, then the chat is pushed over it.
            try await Task.sleep(for: .seconds(1))
            if chat {
                route.chatShown = true
                try await Self.waitForChat(in: screens)
            }
            try await body(screens)
        } catch {
            try? await close()
            throw error
        }
        try await close()
    }

    /// Waits for the pushed chat's header and reply field.
    private static func waitForChat(in screens: Screens) async throws {
        try await waitUntil { namesButton(in: screens.view) != nil }
        #expect(namesButton(in: screens.view) != nil, "control: the chat shows its header: \(HostedAccessibility.labels(in: screens.view).prefix(12))")
        try await waitUntil { type("", in: screens.view) }
        #expect(type("", in: screens.view), "control: the chat shows its reply field")
        try await Task.sleep(for: .milliseconds(300))
    }

    /// The header's names, which open Reply to.
    private static func namesButton(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityHint == "Changes who gets your reply" }
    }

    /// Toggles `addresses` in the Reply to sheet, as the user does, then Done.
    private static func toggle(_ addresses: [String], in screens: Screens) async throws {
        let names = try #require(namesButton(in: screens.view))
        #expect(names.accessibilityActivate(), "control: the header's names open Reply to")
        try await waitUntil { !screens.presented.isEmpty }
        let sheet = try #require(screens.presented.last?.view, "control: Reply to is open")
        try await waitUntil { row(addresses[0], in: sheet) != nil }
        for address in addresses {
            let person = try #require(row(address, in: sheet), "control: Reply to lists \(address): \(HostedAccessibility.labels(in: sheet))")
            #expect(person.accessibilityActivate(), "control: \(address) is toggled")
            try await Task.sleep(for: .milliseconds(200))
        }
        let done = try #require(HostedAccessibility.elements(under: sheet).first { $0.accessibilityLabel == "Done" },
                                "control: Reply to has Done: \(HostedAccessibility.labels(in: sheet))")
        #expect(done.accessibilityActivate(), "control: Done")
        try await waitUntil { screens.presented.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
    }

    private static func row(_ address: String, in sheet: UIView) -> NSObject? {
        HostedAccessibility.elements(under: sheet).first { ($0.accessibilityLabel ?? "").contains(address) }
    }

    /// The "Replying only to" line above the field, if shown.
    private static func replyingOnlyTo(in view: UIView) -> String? {
        HostedAccessibility.labels(in: view).first { $0.hasPrefix("Replying only to") }
    }

    /// Types `words` into the field, as UIKit reports an edit.
    private static func type(_ words: String, in view: UIView) -> Bool {
        ThreadChatTests.type(words, in: view)
    }

    /// Asks for a reply in the field (or in the open pill's input), its card held behind a compose
    /// already on screen, and returns the request as the chat's tools queued it.
    private static func askHeld(in screens: Screens, backend: Backend) async throws -> AgentToolRouter.ComposeRequest {
        let router = AgentToolRouter.shared
        // A compose on screen holds the agent's request in the queue (ADR-IOS-030).
        router.composePresentationDidBegin()
        #expect(type("Tell them Friday works", in: screens.view), "control: the field takes words")
        try await Task.sleep(for: .milliseconds(300))
        #expect(HostedAccessibility.activate("chatSend", in: screens.view),
                "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: screens.view))")
        try await waitUntil { router.composeQueueDepth == 1 }
        #expect(router.composeQueueDepth == 1, "control: the agent asked for a reply: \(backend.bodies.map { $0.suffix(400) })")
        return try #require(router.firstQueuedRequestForTesting, "control: the reply request waits behind the compose on screen")
    }

    /// Runs `body` with nothing presented over a pill as it opens: no one-time dictation prompt, no
    /// dictation starting by itself, no tip; and with AI available, so the open pill has its input.
    /// Puts every setting back.
    private static func withOpenablePill(_ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let savedPrompt = defaults.object(forKey: ChatPillState.dictationPromptShownKey)
        let savedAuto = defaults.object(forKey: ChatPillState.autoDictationKey)
        let savedTips = OnboardingTipGate.onboardingComplete
        let gate = AISubscriptionGate.shared
        let gateWasActive = gate.isActive
        defer {
            defaults.set(savedPrompt, forKey: ChatPillState.dictationPromptShownKey)
            defaults.set(savedAuto, forKey: ChatPillState.autoDictationKey)
            OnboardingTipGate.onboardingComplete = savedTips
            if gateWasActive { gate.openGate() } else { gate.closeGate() }
        }
        defaults.set(true, forKey: ChatPillState.dictationPromptShownKey)
        defaults.set(false, forKey: ChatPillState.autoDictationKey)
        OnboardingTipGate.onboardingComplete = false
        gate.openGate()
        try await body()
    }

    /// Opens the root screen's own pill, as the user taps it.
    private static func openPill(in screens: Screens) async throws {
        #expect(HostedAccessibility.activate("chatPill", in: screens.view),
                "control: the screen shows its pill: \(HostedAccessibility.identifiers(in: screens.view))")
        try await waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatClose") }
        #expect(HostedAccessibility.identifiers(in: screens.view).contains("chatClose"),
                "control: the pill opened: \(HostedAccessibility.identifiers(in: screens.view))")
        try await Task.sleep(for: .milliseconds(600))
    }

    /// The recipients by field ("to", "cc", "bcc") of the compose card open over the screens, empty
    /// when none is open.
    private static func card(in screens: Screens) -> [String: String] {
        for presented in screens.presented {
            let found = composeRecipients(presented.view)
            if !found.isEmpty { return found }
        }
        return [:]
    }

    /// Waits for a compose card and returns its recipients.
    private static func openedCard(in screens: Screens) async throws -> [String: String] {
        var found: [String: String] = [:]
        try await waitUntil {
            found = card(in: screens)
            return found["to"]?.isEmpty == false
        }
        return found
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

    /// Polls `condition` for up to ten seconds; the caller asserts on it afterwards.
    private static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 1. The chat over another screen opens its own card, addressed as asked

    @Test("A field reply for only David, asked in a chat over another screen, opens a card to David alone",
          arguments: Root.allCases)
    func chatOverAScreenRepliesOnlyToTheChosen(root: Root) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await withScreens(root, backend, tag: "only-\(root.rawValue)") { screens in
                let router = AgentToolRouter.shared
                try await Self.toggle(["alex@example.com", "sam@example.com"], in: screens)
                #expect(Self.replyingOnlyTo(in: screens.view) != nil, "control: the chat replies only to David: \(HostedAccessibility.labels(in: screens.view).prefix(16))")
                let request = try await Self.askHeld(in: screens, backend: backend)
                #expect(request.fieldReply == ChatFieldReply(emailKey: ChatThread.copyKey(screens.email), onlyTo: ["david@example.com"]),
                        "control: the request carries the choice made when it was sent: \(String(describing: request.fieldReply))")
                #expect(request.origin == ComposeOrigin(sessionKey: screens.threadKey, screen: .chat),
                        "the field's request names the chat view that asked: \(request.origin)")

                router.composePresentationDidEnd()
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David, never the \(root.rawValue) screen's Reply All: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else, seen or hidden: \(card)")
            }
        }
    }

    @Test("A field reply with nobody chosen, asked in a chat over another screen, opens a Reply All to everyone",
          arguments: Root.allCases)
    func chatOverAScreenRepliesToEveryone(root: Root) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await withScreens(root, backend, tag: "all-\(root.rawValue)") { screens in
                let router = AgentToolRouter.shared
                #expect(Self.replyingOnlyTo(in: screens.view) == nil, "control: nobody is chosen: \(HostedAccessibility.labels(in: screens.view).prefix(16))")
                let request = try await Self.askHeld(in: screens, backend: backend)
                #expect(request.fieldReply == ChatFieldReply(emailKey: ChatThread.copyKey(screens.email), onlyTo: nil),
                        "control: the request names nobody: \(String(describing: request.fieldReply))")

                router.composePresentationDidEnd()
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"], "the sender and the other To: \(card)")
                #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "the Cc stays: \(card)")
                #expect(Self.addresses(card["bcc"]).isEmpty, "\(card)")
            }
        }
    }

    // MARK: - 2. A request whose chat is closed waits for it

    @Test("A field reply whose chat closed before its card opens nothing on the screen under it, and opens as asked, once, when the chat shows again",
          arguments: Root.allCases)
    func requestWaitsForItsChat(root: Root) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await withScreens(root, backend, tag: "closed-\(root.rawValue)") { screens in
                let router = AgentToolRouter.shared
                try await Self.toggle(["alex@example.com", "sam@example.com"], in: screens)
                _ = try await Self.askHeld(in: screens, backend: backend)

                // The chat closes; then the compose on screen goes, letting the request through.
                screens.route.chatShown = false
                try await Self.waitUntil { Self.namesButton(in: screens.view) == nil }
                #expect(Self.namesButton(in: screens.view) == nil, "control: the chat is closed")
                try await Task.sleep(for: .milliseconds(500))
                router.composePresentationDidEnd()
                try await Task.sleep(for: .seconds(2))
                let under = Self.card(in: screens)
                #expect(under.isEmpty, "nothing opens on the \(root.rawValue) screen under the closed chat: \(under)")
                #expect(router.composeQueueDepth == 1, "the request waits for its chat")

                // The chat shows again and opens the card it asked for.
                screens.route.chatShown = true
                try await Self.waitForChat(in: screens)
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
                #expect(router.composeQueueDepth == 0, "the request left the queue as its card opened")

                // The card closes; the tool returns and the agent closes with "Done".
                screens.controller.dismiss(animated: false)
                try await Self.waitUntil { screens.presented.isEmpty && router.composePresentationCount == 0 }
                try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 2, "control: the tool returned and the agent answered: \(backend.bodies.count)")

                // The chat closes and shows again: the card it already opened never opens again.
                screens.route.chatShown = false
                try await Self.waitUntil { Self.namesButton(in: screens.view) == nil }
                try await Task.sleep(for: .milliseconds(500))
                screens.route.chatShown = true
                try await Self.waitForChat(in: screens)
                try await Task.sleep(for: .seconds(2))
                let again = Self.card(in: screens)
                #expect(again.isEmpty, "the card opens once, never again when its chat shows again: \(again)")
                #expect(router.composePresentationCount == 0, "no compose is on screen")
                #expect(router.composeQueueDepth == 0)
                #expect(backend.bodies.count == 2, "the turn is over: nothing asked again")
            }
        }
    }

    // MARK: - 3. The chat knows its field opened a card

    @Test("After a field reply's card closes, the agent's closing words leave the chat's sheet closed")
    func closingWordsAfterTheCardOpenNoSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "after-card") { screens in
                let router = AgentToolRouter.shared
                try await Self.toggle(["alex@example.com", "sam@example.com"], in: screens)
                _ = try await Self.askHeld(in: screens, backend: backend)
                router.composePresentationDidEnd()
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "control: the chat opened the card: \(card)")

                // The card closes; the tool returns and the agent closes with "Done".
                screens.controller.dismiss(animated: false)
                try await Self.waitUntil { screens.presented.isEmpty }
                try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 2, "control: the agent answered after the card closed")
                try await Task.sleep(for: .milliseconds(800))
                #expect(!HostedAccessibility.identifiers(in: screens.view).contains("chatClose"),
                        "the reply was the point: the closing words open no sheet: \(HostedAccessibility.identifiers(in: screens.view))")
            }
        }
    }

    @Test("Control: a field request the agent answers without a card opens the chat's sheet")
    func answerWithoutACardOpensTheSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "no-card") { screens in
                #expect(Self.type("What did they say", in: screens.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: screens.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: screens.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatClose") }
                #expect(HostedAccessibility.identifiers(in: screens.view).contains("chatClose"),
                        "the answer opens the sheet: \(HostedAccessibility.identifiers(in: screens.view))")
            }
        }
    }

    // MARK: - 4. A screen's pill takes requests only while the screen is on screen

    @Test("The inbox's request waits while the chat is pushed over the inbox, and opens when the inbox shows again")
    func offScreenPillTakesNothing() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "off-screen") { screens in
                let router = AgentToolRouter.shared
                // The inbox's chat asks for a Reply All while the chat is pushed over the inbox, whose
                // pill stays mounted under it and sees the offer move.
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .reply, replyTo: screens.email,
                    to: ["alex@example.com", "david@example.com"], cc: ["sam@example.com"], bcc: [],
                    subject: nil, body: "Friday works",
                    origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox), isReplyAll: true))
                try await Task.sleep(for: .seconds(2))
                let underTheChat = Self.card(in: screens)
                #expect(underTheChat.isEmpty, "nothing opens while the inbox is under the chat: \(underTheChat)")
                #expect(router.composeQueueDepth == 1, "the inbox's pill, off screen, never takes its request")
                #expect(!router.composeAwaitingAppear, "and holds no take for a window that cannot show")

                // The chat closes: the inbox is on screen again and opens the card.
                screens.route.chatShown = false
                try await Self.waitUntil { Self.namesButton(in: screens.view) == nil }
                #expect(Self.namesButton(in: screens.view) == nil, "control: the chat is closed")
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"], "the inbox's Reply All: \(card)")
                #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "\(card)")
                #expect(router.composeQueueDepth == 0)
            }
        }
    }

    // MARK: - 5. The inbox's and the email screen's own pills

    @Test("A reply asked in the inbox's or the email screen's own pill names that screen, and its card opens there",
          arguments: Root.allCases)
    func screensOwnPillOpensItsCard(root: Root) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted pill")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await Self.withOpenablePill {
                try await withScreens(root, backend, tag: "own-\(root.rawValue)", chat: false) { screens in
                    let router = AgentToolRouter.shared
                    // The inbox's chat names no email: the agent replies to this one.
                    let number = await ChatIdTranslator.shared.toNumericId(screens.email.id)
                    backend.reply(to: number)
                    try await Self.openPill(in: screens)
                    if root == .email {
                        #expect(HostedAccessibility.identifiers(in: screens.view).contains("chatEmailCard"),
                                "control: the email screen's pill is about its email: \(HostedAccessibility.identifiers(in: screens.view))")
                    }
                    let request = try await Self.askHeld(in: screens, backend: backend)
                    let asked = root == .inbox
                        ? ComposeOrigin(sessionKey: "inbox", screen: .inbox)
                        : ComposeOrigin(sessionKey: screens.threadKey, screen: .email)
                    #expect(request.origin == asked, "the request names the screen that asked: \(request.origin)")
                    #expect(request.fieldReply == nil, "control: no reply field asked")

                    router.composePresentationDidEnd()
                    let card = try await Self.openedCard(in: screens)
                    #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"], "the \(root.rawValue) screen's Reply All: \(card)")
                    #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "\(card)")
                    #expect(router.composeQueueDepth == 0)
                }
            }
        }
    }

    @Test("A reply asked in the chat's open sheet over the inbox names the chat view, and its card opens there")
    func chatSheetRequestOpensInTheChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await Self.withOpenablePill {
                try await withScreens(.inbox, backend, tag: "sheet") { screens in
                    let router = AgentToolRouter.shared
                    // The chat's sheet opens over its field, as from an agent toast.
                    NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": screens.email.id])
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatClose") }
                    #expect(HostedAccessibility.identifiers(in: screens.view).contains("chatClose"),
                            "control: the chat's sheet is open: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Task.sleep(for: .milliseconds(600))
                    let request = try await Self.askHeld(in: screens, backend: backend)
                    #expect(request.origin == ComposeOrigin(sessionKey: screens.threadKey, screen: .chat),
                            "the sheet's request names the chat view: \(request.origin)")
                    #expect(request.fieldReply == nil, "control: asked in the sheet, not the field")

                    router.composePresentationDidEnd()
                    let card = try await Self.openedCard(in: screens)
                    #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"], "the agent's recipients: \(card)")
                    #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "\(card)")
                    #expect(router.composeQueueDepth == 0, "the chat view took it, not the inbox under it")
                }
            }
        }
    }
}
