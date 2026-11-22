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
///  6. A chat whose own sheet is up takes no card until the sheet closes, then opens it once; a chat
///     shown again takes a request asked under its thread's other account's key.
///  7. A field reply recovered from the email screen's own pill opens in the chat view, to the
///     people chosen when it was sent, and nothing opens on the email screen.
///  8. A field reply narrowed in Reply to opens to the people chosen even when a Reply All draft is
///     saved for that email, and leaves that draft as it was; the open card holds a draft of its own.
///  9. The inbox takes its cards as its navigation says it shows (no email pushed over it), not as
///     its pill's appearance says, takes none while one of its own sheets is up, and takes a card
///     already waiting when it is entered again.
/// 10. A new email asked in the chat view or on the email screen opens from the account bound when
///     its turn started (in the chat, the account of the email it was opened on); one whose bound
///     account is gone ends plainly and holds no card.
/// 11. A turn cut off on one screen and resumed from another keeps the screen that asked, and its
///     bound account, also when the resume is cut off again.
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
/// Cases 4 to 11 read the request's `ComposeOrigin` and the router's queue, which that code did not
/// have. Over the inbox, the inbox's pushed-email binding follows the pushed chat, as the app's
/// navigation does. A case that must show nothing opened for a request asks the screen in question for a card
/// of its own and waits for that card: once it opens, that screen has looked at the queue with the
/// request in it and passed it over.
@Suite("Where the agent's compose card opens", .serialized, .processGlobalState)
@MainActor
struct ChatComposeRoutingTests {
    private static let account = "acc-compose-routing"
    private static let otherAccount = "acc-compose-routing-other"
    private static let me = "me@example.com"
    private static let other = "other@example.com"
    /// Who a screen's own card goes to (`openOwnCard`).
    private static let ownCardAddress = "pat@example.com"

    /// The chat's email: from Alex to the user and David, Cc Sam. One per case, so no case meets
    /// another's chat.
    private static func groupEmail(_ tag: String, inReplyTo: String? = nil) -> MessageHeader {
        var header = MessageHeader(
            messageId: "routing-\(tag)", subject: "Plans", from: "Alex Doe <alex@example.com>",
            fromAddress: "alex@example.com", to: "\(me), david@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Tuesday works.",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.cc = "sam@example.com"
        header.rfc822MessageId = "<routing-\(tag)@example.com>"
        header.inReplyTo = inReplyTo
        header.headerComplete = true
        header.isRead = true
        return header
    }

    /// An earlier email of the same thread in the user's other account, which the chat's email
    /// answers: the thread's chat then reads two keys (ADR-IOS-114).
    private static func earlierEmail(_ tag: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: "routing-earlier-\(tag)", subject: "Plans", from: "Alex Doe <alex@example.com>",
            fromAddress: "alex@example.com", to: other,
            date: Date().addingTimeInterval(-7200), snippet: "Shall we meet?",
            folderId: MessageIdentity.folderId(accountId: otherAccount, folderPath: "INBOX"),
            accountId: otherAccount, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = earlierMessageId(tag)
        header.computedThreadId = "routing-earlier-thread-\(tag)"
        header.headerComplete = true
        header.isRead = true
        return header
    }

    private static func earlierMessageId(_ tag: String) -> String { "routing-earlier-\(tag)@example.com" }

    /// The screen the chat is pushed over.
    enum Root: String, CaseIterable, Sendable {
        case inbox
        case email
    }

    /// The fake backend: a request with no saved state asks for `email_reply` on the email it names
    /// (unless `asksForReply` is false), or on the email set with `reply(to:)` for a request that
    /// names none (the inbox's chat), or for `email_compose` of a new email with `asksForNewEmail`;
    /// one carrying the tool's result is answered "Done". With `failsFirst`, the first `failures`
    /// requests fail that way.
    final class Backend: @unchecked Sendable {
        let http = FakeHTTP.Scenario()
        final class Record: Sendable {
            let bodies = Mutex<[String]>([])
            let emailNumber = Mutex<Int?>(nil)
        }
        private let record = Record()

        static let newEmailTo = "sam@example.com"

        init(asksForReply: Bool = true, asksForNewEmail: Bool = false,
             failsFirst: ChatReplyRecoveryTests.Failure? = nil, failures: Int = 1) {
            http.register(path: "/completions/chat", method: "POST") { [record] request in
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                let count = record.bodies.withLock { bodies in
                    bodies.append(body)
                    return bodies.count
                }
                if count <= failures, let failsFirst {
                    switch failsFirst {
                    case .connectionLost: return .transportError(.networkConnectionLost)
                    case .serverError: return .status(500)
                    }
                }
                let final: [String: Any]
                if body.contains("conversation_state") || !asksForReply {
                    final = ["assistant": "Done"]
                } else if asksForNewEmail {
                    let arguments: [String: Any] = ["to": [Backend.newEmailTo], "subject": "Lunch", "body": "Lunch on Friday?"]
                    let argumentsText = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    final = [
                        "assistant": "",
                        "tool_calls": [["id": "tc-compose", "function": ["name": "email_compose", "arguments": argumentsText]]],
                        "conversation_state": ["harmony_messages": [], "current_round": 1],
                    ]
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

    /// Whether the chat is pushed over the root screen, and what the inbox's navigation says.
    @MainActor @Observable
    final class Route {
        var chatShown = false
        /// What the inbox's navigation (its pushed-email binding) says: an email pushed over it
        /// or not. Nil: whatever `chatShown` shows, as in the app. A case sets it to make the
        /// inbox's navigation and its pill's appearance disagree, as the collapsed split view's
        /// appearance callbacks do (ADR-IOS-054).
        var inboxNavigationSaysPushed: Bool?
        var inboxSaysPushed: Bool { inboxNavigationSaysPushed ?? chatShown }
        /// The email selected in the inbox's list (`selectedMessageId`): in the collapsed split view
        /// it shows over the inbox, in the expanded one beside it.
        var inboxSelected: String?
        /// The split view is expanded, so an opened email shows beside the inbox
        /// (`InboxView.emailsOpenBeside`); the phone turning flips it.
        var inboxEmailsOpenBeside = false
        /// The email the pushed chat is opened on; nil: the root's email. The chat shows its
        /// thread's newest email either way, and binds a new email's From to the email it opened on.
        var chatOpenedOn: String?
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
                    ChatThreadView(messageId: route.chatOpenedOn ?? chatId)
                }
            }
        }
    }

    /// The inbox as `MailNavigationView` builds it: its layout read from `route` on every update.
    private struct InboxRoot: View {
        @Bindable var route: Route
        let folder: Folder
        let selected: Binding<String?>
        let pushed: Binding<String?>

        var body: some View {
            InboxView(title: "Inbox", folders: [folder], selection: .unified(.inbox),
                      selectedMessageId: selected, pushedMessageId: pushed, emailsOpenBeside: route.inboxEmailsOpenBeside)
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
        /// The thread's earlier email in the other account (`withScreens(earlier: true)`).
        let earlier: MessageHeader?
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
    /// requests going to `backend`, and runs `body`. With `earlier`, the thread also has
    /// `earlierEmail(tag)` in the user's other account. `waiting` is queued before the screens
    /// mount, as a request whose screen is entered again; the root's pill is then not awaited,
    /// since the card can cover it at once. `emailsOpenBeside` mounts the inbox as the expanded
    /// split view does, where an opened email shows beside it.
    private func withScreens(
        _ root: Root, _ backend: Backend, tag: String, chat: Bool = true, earlier: Bool = false,
        waiting: AgentToolRouter.ComposeRequest? = nil, emailsOpenBeside: Bool = false,
        _ body: @MainActor (Screens) async throws -> Void
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
        let earlierEmail: MessageHeader? = earlier ? Self.earlierEmail(tag) : nil
        let otherRow: Account? = earlier ? {
            var other = Account(emailAddress: Self.other, displayName: "Other", provider: .gmail)
            other.id = Self.otherAccount
            return other
        }() : nil
        let otherInbox: Folder? = earlier ? Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.otherAccount) : nil
        let email = Self.groupEmail(tag, inReplyTo: earlier ? Self.earlierMessageId(tag) : nil)
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.account)
        try await pool.write { db in
            try accountRow.insert(db)
            try inbox.insert(db)
            if let otherRow, let otherInbox {
                try otherRow.insert(db)
                try otherInbox.insert(db)
            }
            if let earlierEmail { try earlierEmail.insert(db) }
            try email.insert(db)
        }
        let accountId = Self.account
        let storedFolder = try await pool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.inbox.rawValue).fetchOne(db)
        }
        let folder = try #require(storedFolder, "control: the inbox folder is stored")
        let storedEmail = try await pool.read { db in try MessageHeader.fetchOne(db, key: email.id) }
        let stored = try #require(storedEmail, "control: the email is stored")
        let threadKey = ChatThreadKey.key(for: stored)

        if let waiting { router.enqueueCompose(waiting) }
        let route = Route()
        let chatId = email.id
        let rootView: AnyView
        switch root {
        case .inbox:
            // The inbox's pushed-email binding says the chat is pushed over it, as the app's
            // navigation does when it pushes an email's chat (`pushedMessageId`).
            let pushed = Binding<String?>(
                get: { route.inboxSaysPushed ? chatId : nil },
                set: { route.chatShown = $0 != nil })
            let selected = Binding<String?>(get: { route.inboxSelected }, set: { route.inboxSelected = $0 })
            route.inboxEmailsOpenBeside = emailsOpenBeside
            rootView = AnyView(Stack(route: route, chatId: chatId, root: InboxRoot(
                route: route, folder: folder, selected: selected, pushed: pushed)))
        case .email:
            rootView = AnyView(Stack(route: route, chatId: chatId, root: MessageDetailView(messageId: chatId)))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [accountRow] + (otherRow.map { [$0] } ?? [])
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
        let screens = Screens(controller: controller, route: route, email: email, threadKey: threadKey, earlier: earlierEmail)
        do {
            // The root screen shows first, with its pill, then the chat is pushed over it.
            if waiting == nil {
                try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatPill") }
            }
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

    /// The origin of a turn sent from the root screen's own pill.
    private static func rootOrigin(_ root: Root, _ screens: Screens) -> ComposeOrigin {
        switch root {
        case .inbox: ComposeOrigin(sessionKey: "inbox", screen: .inbox)
        case .email: ComposeOrigin(sessionKey: screens.threadKey, screen: .email, fromAccountId: account)
        }
    }

    /// Asks `origin`'s screen for a new email to `ownCardAddress` and returns the recipients of the
    /// first card that opens. When it is that email, the screen's pill has looked at the queue with
    /// every earlier request in it and taken none of them.
    private static func openOwnCard(_ origin: ComposeOrigin, in screens: Screens) async throws -> [String: String] {
        AgentToolRouter.shared.enqueueCompose(AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [ownCardAddress], cc: [], bcc: [],
            subject: "Lunch", body: "Lunch on Friday?", origin: origin))
        return try await openedCard(in: screens)
    }

    /// Closes the card on screen, as the user does, and waits until no compose is presented.
    private static func closeCard(in screens: Screens) async throws {
        screens.controller.dismiss(animated: false)
        try await waitUntil { screens.presented.isEmpty && AgentToolRouter.shared.composePresentationCount == 0 }
        let closed = screens.presented.isEmpty && AgentToolRouter.shared.composePresentationCount == 0
        #expect(closed, "control: the card closed")
    }

    /// Polls `condition` for up to ten seconds, and records an issue where it was awaited when it
    /// never holds, so a wait that times out fails there instead of letting the case go on.
    private static func waitUntil(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () async throws -> Bool
    ) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("the awaited condition never held within ten seconds", sourceLocation: sourceLocation)
    }

    /// The outcome a request's tool received.
    @MainActor
    final class OutcomeBox {
        var outcome: ComposeOutcome?
    }

    /// Every accessibility label of the compose card open over the screens.
    private static func cardLabels(in screens: Screens) -> [String] {
        screens.presented.flatMap { HostedAccessibility.labels(in: $0.view) }
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
                let asked = ComposeOrigin(sessionKey: screens.threadKey, screen: .chat, fromAccountId: Self.account)
                #expect(request.origin == asked,
                        "the field's request names the chat view that asked, and the account its new emails are sent from: \(request.origin)")
                // The bubble of the words sent keeps the field's send, which Re-send sends again.
                let sentBubble = ChatPillState.shared.session(for: screens.threadKey).chatMessages.last { $0.role == .user }
                let kept = sentBubble?.fieldSend?.fieldReply
                #expect(kept == request.fieldReply, "the sent words keep who they were sent to: \(String(describing: kept))")

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
                // The screen under the closed chat opens a card of its own: the chat's request was
                // in the queue before it, and that screen passed it over.
                let own = try await Self.openOwnCard(Self.rootOrigin(root, screens), in: screens)
                #expect(Self.addresses(own["to"]) == [Self.ownCardAddress],
                        "the \(root.rawValue) screen under the closed chat opens only its own card: \(own)")
                let waiting = router.composeQueueDepth
                #expect(waiting == 1, "the chat's request waits for its chat")
                try await Self.closeCard(in: screens)

                // The chat shows again and opens the card it asked for, over the chat, as it
                // appears: the card is read, not the chat it covers.
                screens.route.chatShown = true
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David, as the chat built it: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
                #expect(router.composeQueueDepth == 0, "the request left the queue as its card opened")
                #expect(router.composePresentationCount == 1, "one card for the one request")

                // The card closes; the tool returns and the agent closes with "Done".
                try await Self.closeCard(in: screens)
                try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 2, "control: the tool returned and the agent answered: \(backend.bodies.count)")

                // The chat closes and shows again, then opens a card of its own: the first card it
                // opens is that one, so the reply it already opened was not waiting to open again.
                screens.route.chatShown = false
                try await Self.waitUntil { Self.namesButton(in: screens.view) == nil }
                try await Task.sleep(for: .milliseconds(500))
                screens.route.chatShown = true
                try await Self.waitForChat(in: screens)
                let next = try await Self.openOwnCard(
                    ComposeOrigin(sessionKey: screens.threadKey, screen: .chat, fromAccountId: Self.account), in: screens)
                #expect(Self.addresses(next["to"]) == [Self.ownCardAddress],
                        "the reply's card opens once, never again when its chat shows again: \(next)")
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
                // A window for a take that must not happen: it can only miss a late take (and
                // pass), never fail a correct inbox.
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
                    let asked = Self.rootOrigin(root, screens)
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
                    let asked = ComposeOrigin(sessionKey: screens.threadKey, screen: .chat, fromAccountId: Self.account)
                    #expect(request.origin == asked, "the sheet's request names the chat view: \(request.origin)")
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

    // MARK: - 6. A covered chat, and the merged chat's other key

    @Test("A field reply whose chat has its own sheet up waits under it, and opens once, when the sheet closes")
    func coveredChatWaitsForItsSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "covered") { screens in
                let router = AgentToolRouter.shared
                try await Self.toggle(["alex@example.com", "sam@example.com"], in: screens)
                _ = try await Self.askHeld(in: screens, backend: backend)

                // Reply to opens over the chat and stays up; then the compose on screen goes.
                let names = try #require(Self.namesButton(in: screens.view))
                #expect(names.accessibilityActivate(), "control: the header's names open Reply to")
                try await Self.waitUntil { !screens.presented.isEmpty }
                let sheet = try #require(screens.presented.last?.view, "control: Reply to is open")
                try await Task.sleep(for: .milliseconds(300))
                router.composePresentationDidEnd()
                // A window for a take that must not happen: it can only miss a late take (and
                // pass), never fail a correct chat.
                try await Task.sleep(for: .seconds(2))
                let depth = router.composeQueueDepth
                let holding = router.composeAwaitingAppear
                let underSheet = Self.card(in: screens)
                #expect(depth == 1, "the chat takes nothing while its own sheet is up")
                #expect(!holding, "and holds no take for a card that cannot show")
                #expect(underSheet.isEmpty, "no card opens with the sheet up: \(underSheet)")

                // Done closes Reply to: the chat is uncovered and opens the card, once.
                let done = try #require(HostedAccessibility.elements(under: sheet).first { $0.accessibilityLabel == "Done" },
                                        "control: Reply to has Done: \(HostedAccessibility.labels(in: sheet))")
                #expect(done.accessibilityActivate(), "control: Done")
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
                #expect(router.composeQueueDepth == 0)
                #expect(router.composePresentationCount == 1, "one card for the one request")
            }
        }
    }

    @Test("A request asked under the merged chat's other account's key opens in the chat when the chat shows again")
    func mergedChatTakesItsOtherKeysRequest() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "merged", chat: false, earlier: true) { screens in
                let router = AgentToolRouter.shared
                let earlier = try #require(screens.earlier, "control: the thread has an email in the other account")
                let otherKey = ChatThreadKey.key(for: earlier)
                let keys = await ThreadChatReader.keys(about: screens.email)
                #expect(keys.first == screens.threadKey && keys.contains(otherKey), "control: the chat reads both accounts' keys: \(keys)")

                // The chat asked for a reply to the earlier email under the other account's key,
                // then was closed; the chat is opened again.
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .reply, replyTo: earlier, to: ["alex@example.com"], cc: [], bcc: [],
                    subject: nil, body: "Friday works",
                    origin: ComposeOrigin(sessionKey: otherKey, screen: .chat, fromAccountId: Self.otherAccount)))
                // The card opens as the chat appears: the card is read, not the chat it covers.
                screens.route.chatShown = true
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["alex@example.com"], "the chat opens its other key's request: \(card)")
                #expect(router.composeQueueDepth == 0)
                #expect(router.composePresentationCount == 1, "one card for the one request")
            }
        }
    }

    // MARK: - 7. A field reply recovered on the email screen

    @Test("A failed field reply recovered from the email screen's own pill opens in the chat, to the people chosen",
          arguments: ChatReplyRecoveryTests.Failure.allCases)
    func fieldReplyRecoveredOnTheEmailScreenOpensInTheChat(failure: ChatReplyRecoveryTests.Failure) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted pill")
        let backend = Backend(failsFirst: failure)
        try await HostedAccessibility.withAutomation {
            try await Self.withOpenablePill {
                try await withScreens(.email, backend, tag: "recover-\(failure.rawValue)") { screens in
                    let router = AgentToolRouter.shared
                    // Only David, asked in the chat's field; the request fails.
                    try await Self.toggle(["alex@example.com", "sam@example.com"], in: screens)
                    #expect(Self.type("Tell them Friday works", in: screens.view), "control: the field takes words")
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(HostedAccessibility.activate("chatSend", in: screens.view),
                            "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                    #expect(backend.bodies.count == 1, "control: the request went out once and failed")

                    // The chat closes; the email screen's pill shows the same chat and recovers it.
                    screens.route.chatShown = false
                    try await Self.waitUntil { Self.namesButton(in: screens.view) == nil }
                    #expect(Self.namesButton(in: screens.view) == nil, "control: the chat is closed")
                    try await Self.openPill(in: screens)
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatRetry") }
                    #expect(HostedAccessibility.activate("chatRetry", in: screens.view),
                            "control: the email screen's pill offers Retry: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { router.composeQueueDepth == 1 }
                    let request = try #require(router.firstQueuedRequestForTesting, "control: the recovered turn asked for a reply")
                    let chosen = ChatFieldReply(emailKey: ChatThread.copyKey(screens.email), onlyTo: ["david@example.com"])
                    #expect(request.fieldReply == chosen, "the reply keeps the choice made when it was sent: \(String(describing: request.fieldReply))")
                    let asked = ComposeOrigin(sessionKey: screens.threadKey, screen: .chat, fromAccountId: Self.account)
                    #expect(request.origin == asked, "the recovered field reply belongs to the chat view: \(request.origin)")

                    // The email screen opens a card of its own: it passed the chat's reply over.
                    let own = try await Self.openOwnCard(Self.rootOrigin(.email, screens), in: screens)
                    #expect(Self.addresses(own["to"]) == [Self.ownCardAddress],
                            "the email screen opens only its own card: \(own)")
                    let waiting = router.composeQueueDepth
                    #expect(waiting == 1, "the field reply waits for the chat")
                    try await Self.closeCard(in: screens)

                    // The chat shows again and opens the reply, to David alone.
                    // The card opens as the chat appears: the card is read, not the chat it covers.
                    screens.route.chatShown = true
                    let card = try await Self.openedCard(in: screens)
                    #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David: \(card)")
                    #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
                    #expect(router.composeQueueDepth == 0)
                }
            }
        }
    }

    // MARK: - 8. A narrowed field reply and a saved Reply All draft

    @Test("A field reply for only David opens to David alone with a Reply All draft saved for the email, and leaves that draft as it was")
    func narrowedReplyOverASavedDraft() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend()
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "saved-draft") { screens in
                let router = AgentToolRouter.shared
                // A Reply All draft to everyone, saved for the email an hour ago.
                let parent = "\(screens.email.accountId):\(screens.email.stableId)"
                let savedKey = Draft.draftKey(replyTo: parent, isForward: false, newId: nil)
                let savedAt = Date().addingTimeInterval(-3600).timeIntervalSince1970
                let saved = ComposeDraftGuards.draftToSave(
                    existing: nil, id: savedKey, accountId: Self.account,
                    recipients: (["alex@example.com", "david@example.com"], ["sam@example.com"], []),
                    subject: "Re: Plans", body: "Saved words", replyTo: screens.email, isForward: false,
                    isReplyAll: true, attachmentsDirName: nil, now: savedAt)
                try await AppDatabase.rawPool.write { try saved.insert($0) }

                try await Self.toggle(["alex@example.com", "sam@example.com"], in: screens)
                _ = try await Self.askHeld(in: screens, backend: backend)
                router.composePresentationDidEnd()
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David, never the saved draft's people: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
                // The open card's draft, which its Save writes (a compose keeps the draft it opened
                // with): one of its own for this email, never the saved Reply All draft.
                let open = DraftSessionRegistry.shared.snapshot()
                let ownDrafts = open.filter {
                    $0.hasPrefix(Draft.separateReplyPrefix)
                        && Draft.replyKeyTail(draftKey: $0, isForward: false).map(String.init) == parent
                }
                #expect(ownDrafts.count == 1, "the card holds one draft of its own for this email: \(open)")
                #expect(!open.contains(savedKey), "never the saved Reply All draft: \(open)")
                try await Self.closeCard(in: screens)

                let drafts = try await AppDatabase.rawPool.read { try Draft.fetchAll($0) }
                let kept = try #require(drafts.first { $0.id == savedKey }, "the saved Reply All draft is still there: \(drafts.map(\.id))")
                #expect(kept.body == "Saved words", "never saved over")
                #expect(kept.updatedAt == savedAt, "never touched")
                #expect(kept.toArray == ["alex@example.com", "david@example.com"] && kept.ccArray == ["sam@example.com"],
                        "its people are its own")
                let others = drafts.filter { $0.id != savedKey }.map(\.id)
                #expect(others.allSatisfy { $0.hasPrefix(Draft.separateReplyPrefix) }, "nothing else saved under the email's usual draft: \(others)")
            }
        }
    }

    @Test("A narrowed field reply's card is a plain reply with a draft of its own, naming its email; every other reply keeps the usual draft")
    func narrowedReplyHasADraftOfItsOwn() {
        let email = Self.groupEmail("draft-key")
        var me = Account(emailAddress: Self.me, displayName: "Me", provider: .gmail)
        me.id = Self.account
        let accounts = [me]
        func card(_ field: ChatFieldReply?) -> ChatAgentCard {
            let request = AgentToolRouter.ComposeRequest(
                mode: .reply, replyTo: email, to: ["alex@example.com", "david@example.com"], cc: ["sam@example.com"], bcc: [],
                subject: nil, body: "Friday works",
                origin: ComposeOrigin(sessionKey: ChatThreadKey.key(for: email), screen: .chat, fromAccountId: Self.account),
                isReplyAll: true, fieldReply: field)
            return ChatAgentCard(request: request, reply: ChatReplyCompose.make(agent: request, accounts: accounts))
        }
        let key = ChatThread.copyKey(email)
        let narrowed = card(ChatFieldReply(emailKey: key, onlyTo: ["david@example.com"]))
        let narrowedReply = narrowed.reply
        #expect(narrowedReply == ChatReplyCompose(isReplyAll: false, to: ["david@example.com"], cc: [], bcc: []),
                "a plain reply to David alone: \(narrowedReply)")
        let draftId = narrowed.draftId ?? ""
        #expect(draftId.hasPrefix(Draft.separateReplyPrefix), "a draft of its own: \(draftId)")
        let named = Draft.replyKeyTail(draftKey: draftId, isForward: false).map(String.init)
        #expect(named == "\(email.accountId):\(email.stableId)", "naming the email it answers")
        let again = card(ChatFieldReply(emailKey: key, onlyTo: ["david@example.com"])).draftId
        #expect(again != narrowed.draftId, "each card its own draft")

        let everyone = card(ChatFieldReply(emailKey: key, onlyTo: nil)).draftId
        #expect(everyone == nil, "a field reply to everyone keeps the reply's usual draft")
        let asked = card(nil).draftId
        #expect(asked == nil, "a reply asked in the chat's sheet keeps the reply's usual draft")
    }

    // MARK: - 9. The inbox says from its navigation whether it shows

    @Test("The inbox takes its card when its navigation says it shows, though its pill's appearance says it left")
    func inboxShowsAsItsNavigationSays() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "nav-shows") { screens in
                let router = AgentToolRouter.shared
                // The chat is pushed, so the inbox's pill has had its disappear; the inbox's
                // navigation says nothing is pushed over it. That is the inbox after the collapsed
                // split view's disappear right after it appears, while it stays visible.
                screens.route.inboxNavigationSaysPushed = false
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
                    subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox)))
                try await Self.waitUntil { router.composeQueueDepth == 0 }
                let depth = router.composeQueueDepth
                #expect(depth == 0, "the inbox takes its card: its navigation, not its pill's appearance, says it shows")
            }
        }
    }

    @Test("The inbox takes nothing while its navigation says an email is pushed over it, though its pill appeared, and opens the card when it shows again")
    func inboxUnderAPushedEmailTakesNothing() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "nav-pushed", chat: false) { screens in
                let router = AgentToolRouter.shared
                // The inbox's pill appeared and had no disappear; its navigation says an email is
                // pushed over it, as when the collapsed split view sends no disappear for that push.
                screens.route.inboxNavigationSaysPushed = true
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
                    subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox)))
                // A window for a take that must not happen: it can only miss a late take (and
                // pass), never fail a correct inbox.
                try await Task.sleep(for: .seconds(2))
                let depth = router.composeQueueDepth
                let holding = router.composeAwaitingAppear
                let underTheEmail = Self.card(in: screens)
                #expect(depth == 1, "the inbox under a pushed email takes nothing")
                #expect(!holding, "and holds no take for a card that cannot show")
                #expect(underTheEmail.isEmpty, "nothing opens: \(underTheEmail)")

                // The email is popped: the inbox shows again and opens its card.
                screens.route.inboxNavigationSaysPushed = false
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "the inbox's card: \(card)")
                #expect(router.composeQueueDepth == 0)
            }
        }
    }

    @Test("The inbox takes nothing while a selected email shows over it, and opens the card when it shows again")
    func inboxUnderASelectedEmailTakesNothing() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "nav-selected", chat: false) { screens in
                let router = AgentToolRouter.shared
                // A row is selected: in the collapsed split view its email shows over the inbox.
                screens.route.inboxSelected = screens.email.id
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
                    subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox)))
                // A window for a take that must not happen: it can only miss a late take (and
                // pass), never fail a correct inbox.
                try await Task.sleep(for: .seconds(2))
                let depth = router.composeQueueDepth
                let holding = router.composeAwaitingAppear
                let underTheEmail = Self.card(in: screens)
                #expect(depth == 1, "the inbox under a selected email takes nothing")
                #expect(!holding, "and holds no take for a card that cannot show")
                #expect(underTheEmail.isEmpty, "nothing opens: \(underTheEmail)")

                // Back to the list: the inbox shows again and opens its card.
                screens.route.inboxSelected = nil
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "the inbox's card: \(card)")
                #expect(router.composeQueueDepth == 0)
            }
        }
    }

    @Test("In the expanded split view the inbox takes its card while an email is open beside it")
    func inboxBesideAnOpenEmailTakesItsCard() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "nav-beside", chat: false, emailsOpenBeside: true) { screens in
                let router = AgentToolRouter.shared
                // A row is selected and an email pushed: in the expanded split view both show in the
                // detail column beside the inbox, which stays on screen.
                screens.route.inboxSelected = screens.email.id
                screens.route.inboxNavigationSaysPushed = true
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
                    subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox)))
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "the inbox's card, with the email beside it: \(card)")
                #expect(router.composeQueueDepth == 0)
            }
        }
    }

    @Test("A card held under an email opens once the phone turns and the email shows beside the inbox")
    func heldInboxCardOpensWhenTheEmailMovesBeside() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "nav-turns", chat: false) { screens in
                let router = AgentToolRouter.shared
                // Collapsed: a selected and a pushed email show over the inbox, so its card waits.
                screens.route.inboxSelected = screens.email.id
                screens.route.inboxNavigationSaysPushed = true
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
                    subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox)))
                // A window for a take that must not happen: it can only miss a late take (and
                // pass), never fail a correct inbox.
                try await Task.sleep(for: .seconds(2))
                let depth = router.composeQueueDepth
                let underTheEmail = Self.card(in: screens)
                #expect(depth == 1, "control: the collapsed inbox under an email takes nothing")
                #expect(underTheEmail.isEmpty, "control: nothing opens: \(underTheEmail)")

                // The phone turns: the split view expands and the email shows beside the inbox.
                screens.route.inboxEmailsOpenBeside = true
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "the inbox's card opens beside the email: \(card)")
                #expect(router.composeQueueDepth == 0)
            }
        }
    }

    @Test("The inbox takes no card while its own Search sheet is up, and opens it once the sheet closes")
    func inboxSheetHoldsTheCard() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted inbox")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "inbox-sheet", chat: false) { screens in
                let router = AgentToolRouter.shared
                let search = try #require(HostedAccessibility.elements(under: screens.view).first { $0.accessibilityLabel == "Search" },
                                          "control: the inbox shows Search: \(HostedAccessibility.labels(in: screens.view).prefix(20))")
                #expect(search.accessibilityActivate(), "control: Search opens its sheet")
                try await Self.waitUntil { !screens.presented.isEmpty }
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
                    subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox)))
                // A window for a take that must not happen: it can only miss a late take (and
                // pass), never fail a correct inbox.
                try await Task.sleep(for: .seconds(2))
                let depth = router.composeQueueDepth
                let holding = router.composeAwaitingAppear
                let underTheSheet = Self.card(in: screens)
                #expect(depth == 1, "the inbox takes nothing while its own sheet is up")
                #expect(!holding, "and holds no take for a card that cannot show")
                #expect(underTheSheet.isEmpty, "no card opens with the sheet up: \(underTheSheet)")

                // The sheet closes: the inbox is uncovered and opens the card, once.
                screens.controller.dismiss(animated: false)
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "the inbox's card: \(card)")
                #expect(router.composeQueueDepth == 0)
                #expect(router.composePresentationCount == 1, "one card for the one request")
            }
        }
    }

    @Test("A card waiting when the inbox is entered again opens once, though nothing changes after the inbox shows")
    func enteredInboxTakesItsWaitingCard() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        // The inbox's request was queued while another sidebar page replaced the inbox, so its
        // offer has moved already; the inbox is entered again and says from its first frame that it
        // shows.
        let waiting = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: [Self.ownCardAddress], cc: [], bcc: [],
            subject: "Lunch", body: "Lunch on Friday?", origin: ComposeOrigin(sessionKey: "inbox", screen: .inbox))
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "inbox-entered", chat: false, waiting: waiting) { screens in
                let router = AgentToolRouter.shared
                let card = try await Self.openedCard(in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "the inbox opens its waiting card: \(card)")
                #expect(router.composeQueueDepth == 0)
                #expect(router.composePresentationCount == 1, "one card for the one request")
            }
        }
    }

    // MARK: - 10. A new email opens from the account bound when its turn started

    @Test("A new email bound to the user's other account opens from that account, in the chat view and on the email screen",
          arguments: Root.allCases)
    func boundAccountIsTheCardsFrom(root: Root) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            // Over the inbox, the pushed chat takes the request; at the email screen's root, that
            // screen does. The other account is the app's second, so it is never a default.
            try await withScreens(root, backend, tag: "from-\(root.rawValue)", chat: root == .inbox, earlier: true) { screens in
                let screen: ComposeOrigin.Screen = root == .inbox ? .chat : .email
                let card = try await Self.openOwnCard(
                    ComposeOrigin(sessionKey: screens.threadKey, screen: screen, fromAccountId: Self.otherAccount), in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "control: the new email's card: \(card)")
                let labels = Self.cardLabels(in: screens)
                let fromBound = labels.contains { $0.contains(Self.other) }
                let fromFirst = labels.contains { $0.contains(Self.me) }
                #expect(fromBound, "the card sends from the account bound when the turn started: \(labels)")
                #expect(!fromFirst, "never from the app's first account: \(labels)")
            }
        }
    }

    @Test("A new email asked in a chat opened on the other account's email opens from that account, not from the newest email's")
    func chatNewEmailBindsItsOpenersAccount() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(asksForNewEmail: true)
        try await HostedAccessibility.withAutomation {
            try await Self.withOpenablePill {
                try await withScreens(.inbox, backend, tag: "from-opener", chat: false, earlier: true) { screens in
                    let router = AgentToolRouter.shared
                    let earlier = try #require(screens.earlier, "control: the thread has an email in the other account")
                    // The chat is opened on the thread's email in the other account; its newest email,
                    // whose key the chat's turns use, is in the user's first account.
                    screens.route.chatOpenedOn = earlier.id
                    screens.route.chatShown = true
                    try await Self.waitForChat(in: screens)
                    NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": earlier.id])
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatClose") }
                    #expect(HostedAccessibility.identifiers(in: screens.view).contains("chatClose"),
                            "control: the chat's sheet is open: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Task.sleep(for: .milliseconds(600))
                    let request = try await Self.askHeld(in: screens, backend: backend)
                    let asked = ComposeOrigin(sessionKey: screens.threadKey, screen: .chat, fromAccountId: Self.otherAccount)
                    #expect(request.origin == asked, "the new email binds the account of the email the chat was opened on: \(request.origin)")

                    router.composePresentationDidEnd()
                    let card = try await Self.openedCard(in: screens)
                    #expect(Self.addresses(card["to"]) == [Backend.newEmailTo], "the chat's new email: \(card)")
                    let labels = Self.cardLabels(in: screens)
                    let fromOpener = labels.contains { $0.contains(Self.other) }
                    let fromNewest = labels.contains { $0.contains(Self.me) }
                    #expect(fromOpener, "the card sends from the opener's account: \(labels)")
                    #expect(!fromNewest, "never from the newest email's account: \(labels)")
                }
            }
        }
    }

    @Test("Control: a new email asked in the inbox binds no account and opens from the app's first account")
    func inboxNewEmailPicksItsAccount() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(.inbox, backend, tag: "from-inbox", chat: false, earlier: true) { screens in
                let card = try await Self.openOwnCard(Self.rootOrigin(.inbox, screens), in: screens)
                #expect(Self.addresses(card["to"]) == [Self.ownCardAddress], "control: the new email's card: \(card)")
                let labels = Self.cardLabels(in: screens)
                let fromFirst = labels.contains { $0.contains(Self.me) }
                #expect(fromFirst, "the inbox's new email picks the app's first account: \(labels)")
            }
        }
    }

    @Test("A new email whose bound account is not among the app's accounts ends as its screen takes it, opens nothing, and the next card opens",
          arguments: Root.allCases)
    func missingBoundAccountOpensNothing(root: Root) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted screens")
        let backend = Backend(asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withScreens(root, backend, tag: "missing-\(root.rawValue)", chat: root == .inbox) { screens in
                let router = AgentToolRouter.shared
                let screen: ComposeOrigin.Screen = root == .inbox ? .chat : .email
                let ended = OutcomeBox()
                router.enqueueCompose(AgentToolRouter.ComposeRequest(
                    mode: .compose, replyTo: nil, to: ["sam@example.com"], cc: [], bcc: [],
                    subject: "From nowhere", body: "Hello",
                    origin: ComposeOrigin(sessionKey: screens.threadKey, screen: screen, fromAccountId: "acc-compose-routing-missing"),
                    onOutcome: { ended.outcome = $0 }))
                try await Self.waitUntil { ended.outcome != nil }
                var reason: String?
                if case .failed(let text)? = ended.outcome { reason = text }
                #expect(reason == AgentToolRouter.fromAccountMissingReason,
                        "the tool hears the account to send from is gone: \(String(describing: ended.outcome))")
                #expect(router.composeQueueDepth == 0)

                // The screen's next card opens, and is the only one: the ended request held nothing.
                let next = try await Self.openOwnCard(
                    ComposeOrigin(sessionKey: screens.threadKey, screen: screen, fromAccountId: Self.account), in: screens)
                #expect(Self.addresses(next["to"]) == [Self.ownCardAddress], "the next card opens: \(next)")
                #expect(router.composePresentationCount == 1, "only that card opened")
            }
        }
    }

    // MARK: - 11. A resumed turn keeps the screen that asked

    @Test("A turn cut off on the email screen and resumed from the chat view keeps the email screen's origin, and its card opens there")
    func resumeKeepsTheOriginItStartedWith() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted pill")
        let backend = Backend(failsFirst: .connectionLost)
        try await HostedAccessibility.withAutomation {
            try await Self.withOpenablePill {
                try await withScreens(.email, backend, tag: "resume", chat: false) { screens in
                    let router = AgentToolRouter.shared
                    let number = await ChatIdTranslator.shared.toNumericId(screens.email.id)
                    backend.reply(to: number)
                    // The email screen's own pill asks; the request is cut off in transit.
                    try await Self.openPill(in: screens)
                    #expect(Self.type("Tell them Friday works", in: screens.view), "control: the pill takes words")
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(HostedAccessibility.activate("chatSend", in: screens.view),
                            "control: the pill's Send takes a tap: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                    #expect(backend.bodies.count == 1, "control: the request went out once and was cut off")

                    // The chat view of the same email shows the same chat, and resumes the turn.
                    screens.route.chatShown = true
                    try await Self.waitForChat(in: screens)
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatRetry") }
                    #expect(HostedAccessibility.activate("chatRetry", in: screens.view),
                            "control: the chat offers the cut-off turn: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { router.composeQueueDepth == 1 }
                    let request = try #require(router.firstQueuedRequestForTesting, "control: the resumed turn asked for a reply")
                    let asked = Self.rootOrigin(.email, screens)
                    #expect(request.origin == asked,
                            "the resumed turn keeps the email screen that asked, and its account: \(request.origin)")

                    // The chat opens a card of its own: it passed the email screen's reply over.
                    let own = try await Self.openOwnCard(
                        ComposeOrigin(sessionKey: screens.threadKey, screen: .chat, fromAccountId: Self.account), in: screens)
                    #expect(Self.addresses(own["to"]) == [Self.ownCardAddress], "the chat opens only its own card: \(own)")
                    let waiting = router.composeQueueDepth
                    #expect(waiting == 1, "the reply waits for the email screen")
                    try await Self.closeCard(in: screens)

                    // The email screen shows again and opens the reply.
                    screens.route.chatShown = false
                    let card = try await Self.openedCard(in: screens)
                    #expect(Self.addresses(card["to"]) == ["alex@example.com", "david@example.com"], "the email screen's Reply All: \(card)")
                    #expect(Self.addresses(card["cc"]) == ["sam@example.com"], "\(card)")
                    #expect(router.composeQueueDepth == 0)
                }
            }
        }
    }

    @Test("A new email cut off twice, resumed from a chat bound to the other account, keeps the email screen's origin and opens there from its account")
    func secondInterruptionKeepsTheOrigin() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted pill")
        let backend = Backend(asksForNewEmail: true, failsFirst: .connectionLost, failures: 2)
        try await HostedAccessibility.withAutomation {
            try await Self.withOpenablePill {
                try await withScreens(.email, backend, tag: "resume-twice", chat: false, earlier: true) { screens in
                    let router = AgentToolRouter.shared
                    let earlier = try #require(screens.earlier, "control: the thread has an email in the other account")
                    // The email screen's own pill asks, bound to the email's account; the request
                    // is cut off in transit.
                    try await Self.openPill(in: screens)
                    #expect(Self.type("Ask Sam to lunch", in: screens.view), "control: the pill takes words")
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(HostedAccessibility.activate("chatSend", in: screens.view),
                            "control: the pill's Send takes a tap: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                    #expect(backend.bodies.count == 1, "control: the request went out once and was cut off")

                    // The chat opened on the thread's email in the other account shows the same chat,
                    // and binds a new email to that account. It resumes, and is cut off again.
                    screens.route.chatOpenedOn = earlier.id
                    screens.route.chatShown = true
                    try await Self.waitForChat(in: screens)
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatRetry") }
                    #expect(HostedAccessibility.activate("chatRetry", in: screens.view),
                            "control: the chat offers the cut-off turn: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                    #expect(backend.bodies.count == 2, "control: the resume went out and was cut off")

                    // The second resume asks for the new email: it keeps the screen and account the
                    // turn started with, so it waits for the email screen under the chat.
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: screens.view).contains("chatRetry") }
                    #expect(HostedAccessibility.activate("chatRetry", in: screens.view),
                            "control: the chat offers the turn again: \(HostedAccessibility.identifiers(in: screens.view))")
                    try await Self.waitUntil { router.composeQueueDepth == 1 }
                    let request = try #require(router.firstQueuedRequestForTesting, "control: the resumed turn asked for a new email")
                    #expect(request.origin == Self.rootOrigin(.email, screens),
                            "the twice-resumed turn keeps the email screen that asked, and its account: \(request.origin)")
                    #expect(Self.card(in: screens).isEmpty, "the chat opens no card for the email screen")

                    // The email screen shows again and opens the new email, from the email's account.
                    screens.route.chatShown = false
                    let card = try await Self.openedCard(in: screens)
                    #expect(Self.addresses(card["to"]) == [Backend.newEmailTo], "the email screen's new email: \(card)")
                    let labels = Self.cardLabels(in: screens)
                    let fromBound = labels.contains { $0.contains(Self.me) }
                    let fromChat = labels.contains { $0.contains(Self.other) }
                    #expect(fromBound, "the card sends from the account bound when the turn started: \(labels)")
                    #expect(!fromChat, "never from the account of the chat that resumed it: \(labels)")
                    #expect(router.composeQueueDepth == 0)
                }
            }
        }
    }
}
