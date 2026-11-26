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

/// The chat's reply field and its AI Suggestion through a real chat, and the recovery of the
/// panel's requests.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The closed field's Send is the reply's compose edit, never a turn for the agent (ADR-IOS-114
///     decision 10, amended 2026-11-25): an edit of the AI Suggestion is written into the ghost
///     (stored in place first when it keeps its envelope), then opens the field's own card, and
///     asks the agent nothing; a card closed unsent hands the words back
///     (ADR-IOS-117); a compose cut off leaves nothing to resume and keeps the words.
///  2. A request the open sheet sends, cut off, is recovered with no field words named, and the
///     inbox pill's words typed after a cut-off offer Send.
///  3. The ghost's card: its Recompute and its own pill's edits go to the chat's AI service.
///
/// Until 2026-11-25 this suite pinned decision 11 after a failure: a field request sent to the
/// agent kept its Reply to choice through its recovery. The closed field no longer sends to the
/// agent, so those cases were deleted with the routing they tested.
///
/// Each case opens the chat for real in a window with its requests going to a fake backend.
@Suite("The reply field and the AI Suggestion through a real chat, and the panel's recovery", .serialized, .processGlobalState)
@MainActor
struct ChatReplyRecoveryTests {
    private static let account = "acc-chat-recovery"
    private static let me = "me@example.com"

    /// The chat's email: from Alex to the user and David, Cc Sam. One per case, so no case meets
    /// another's chat.
    private static func groupEmail(_ tag: String, suggestion: ReplyResult? = nil) -> MessageHeader {
        var header = MessageHeader(
            messageId: "recovery-\(tag)", subject: "Plans", from: "Alex Doe <alex@example.com>",
            fromAddress: "alex@example.com", to: "\(me), david@example.com",
            date: Date().addingTimeInterval(-600), snippet: "Tuesday works.",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.cc = "sam@example.com"
        header.rfc822MessageId = "<recovery-\(tag)@example.com>"
        header.headerComplete = true
        header.isRead = true
        if let suggestion { _ = header.replaceSuggestion(with: suggestion, ifStill: nil) }
        return header
    }

    /// How the first request fails.
    enum Failure: String, CaseIterable, Sendable {
        /// Cut off in transit: the turn is resumed from its saved request.
        case connectionLost
        /// A server error: the request is sent again.
        case serverError
    }

    /// The fake backend: the first request fails as `failure` (nil: it does not fail); a request
    /// with no saved state that does not fail asks for `email_reply` on the email it names (unless
    /// `asksForReply` is false); one carrying the tool's result is answered "Done".
    final class Backend: @unchecked Sendable {
        let http = FakeHTTP.Scenario()
        final class Record: Sendable {
            let bodies = Mutex<[String]>([])
            let cardEdits = Mutex(0)
        }
        private let record = Record()

        /// `recompute`: a reply asked for by a card's Recompute is answered with `recomputed`, held until the gate is released.
        /// `cardEdit`: the compose edit a card's own pill asks for is answered with this JSON.
        /// `holdFirst`: the first request is answered (as `failure`) only once it is signalled, so
        /// the agent keeps working until then.
        init(failure: Failure?, asksForReply: Bool = true, recompute: ReplyGate? = nil,
             cardEdit: String? = nil, holdFirst: DispatchSemaphore? = nil) {
            http.register(path: "/completions/chat", method: "POST") { [record] request in
                if let recompute, AITextMessageCallerTests.Backend.prompt(request.body) == "system_prompt_compose" {
                    return recompute.answer()
                }
                if let cardEdit, AITextMessageCallerTests.Backend.prompt(request.body) == "system_prompt_compose_interactive" {
                    record.cardEdits.withLock { $0 += 1 }
                    let final = (try? JSONSerialization.data(withJSONObject: ["assistant": cardEdit])) ?? Data()
                    return .bytes(Data(("event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n").utf8),
                                  contentType: "text/event-stream")
                }
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                let count = record.bodies.withLock { bodies in
                    bodies.append(body)
                    return bodies.count
                }
                if count == 1, let failure {
                    let failed: FakeHTTP.CannedResponse = switch failure {
                    case .connectionLost: .transportError(.networkConnectionLost)
                    case .serverError: .status(500)
                    }
                    guard let holdFirst else { return failed }
                    return .parked {
                        holdFirst.wait()
                        return failed
                    }
                }
                let final: [String: Any]
                if body.contains("conversation_state") || !asksForReply {
                    final = ["assistant": "Done"]
                } else {
                    let number = Self.emailNumber(in: body) ?? 0
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

        /// The email the request's own question is about: the number in its last "Regarding [Email](N)".
        static func emailNumber(in body: String) -> Int? {
            let pattern = try! NSRegularExpression(pattern: #"Regarding \[Email\]\((\d+)\)"#)
            let matches = pattern.matches(in: body, range: NSRange(body.startIndex..., in: body))
            guard let last = matches.last, let range = Range(last.range(at: 1), in: body) else { return nil }
            return Int(body[range])
        }

        var service: AIService {
            AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        }

        var bodies: [String] { record.bodies.withLock { $0 } }
        var cardEdits: Int { record.cardEdits.withLock { $0 } }
    }

    /// The reply a card's Recompute gets.
    nonisolated static let recomputed = ReplyResult(body: "Hi Alex,\n\nTuesday is perfect.\n\nThanks", textMessage: "Tuesday is perfect")

    /// Holds the reply a card's Recompute asks for until `release()`, and counts the asks.
    final class ReplyGate: Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let state = Mutex<(asked: Int, answered: Bool, released: Bool)>((0, false, false))

        var asked: Int { state.withLock { $0.asked } }
        var answered: Bool { state.withLock { $0.answered } }

        func answer() -> FakeHTTP.CannedResponse {
            state.withLock { $0.asked += 1 }
            return .parked { [self] in
                _ = self.gate.wait(timeout: .now() + 20)
                self.state.withLock { $0.answered = true }
                let reply: [String: Any] = ["subject": "Re: Plans", "body": ChatReplyRecoveryTests.recomputed.body,
                                            "text_message": ChatReplyRecoveryTests.recomputed.textMessage ?? ""]
                let assistant = String(decoding: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(), as: UTF8.self)
                let final = (try? JSONSerialization.data(withJSONObject: ["assistant": assistant])) ?? Data()
                return .bytes(Data(("event: final\ndata: " + String(decoding: final, as: UTF8.self) + "\n\n").utf8),
                              contentType: "text/event-stream")
            }
        }

        func release() {
            let first = state.withLock { value -> Bool in
                defer { value.released = true }
                return !value.released
            }
            if first { gate.signal() }
        }
    }

    /// The open chat.
    @MainActor
    struct Chat {
        let controller: UIHostingController<AnyView>
        let email: MessageHeader
        let accounts: [Account]
        let pool: DatabasePool
        var view: UIView { controller.view }
    }

    /// Opens the chat on `groupEmail(tag)` in a window, its requests going to `backend`, and runs `body`.
    func withChat(_ backend: Backend, tag: String, suggestion: ReplyResult? = nil,
                          composeEdit: EmailReplyTool.ComposeEdit? = nil,
                          _ body: @MainActor (Chat) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        let router = AgentToolRouter.shared
        router.resetComposeQueueForTesting()
        ChatPillState.shared.removeAllSessions()
        ChatPillState.shared.aiService = backend.service
        // A new app run's field-word store: nothing in memory from an earlier test.
        ChatFieldWords.shared = ChatFieldWords()
        defer {
            ChatPillState.shared.aiService = .shared
            ChatPillState.shared.removeAllSessions()
            ChatFieldWords.shared = ChatFieldWords()
            backend.http.close()
            router.resetComposeQueueForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        var account = Account(emailAddress: Self.me, displayName: "Me", provider: .gmail)
        account.id = Self.account
        let accountRow = account
        let email = Self.groupEmail(tag, suggestion: suggestion)
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.account)
        try await pool.write { db in
            try accountRow.insert(db)
            try inbox.insert(db)
            try email.insert(db)
        }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [accountRow]
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack { ChatThreadView(messageId: email.id) }
                .environment(navigationStore)
                .environment(\.hasTabMailSession, true)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // The registry's tools keep the database they were made with, which is an earlier test's
        // once one has run; the agent's email_reply reads this chat's database.
        let registry = ToolRegistry.shared
        await registry.ensureDefaultToolsRegistered()
        let registeredReply = await registry.tool(named: "email_reply")
        await registry.register(EmailReplyTool(context: ToolContext(db: pool, translator: ChatIdTranslator.shared), composeEdit: composeEdit))
        // The reply's card is left open, so its turn never ends: closing cancels it, and its
        // working mark, which a cancelled turn leaves, is cleared with it.
        func close() async throws {
            ChatPillState.shared.removeAllSessions()
            ActiveAgentTracker.shared.clearWorking(ChatThreadKey.key(for: email))
            window.isHidden = true
            window.rootViewController = nil
            try await Self.waitUntil { router.composePresentationCount == 0 }
            try await Task.sleep(for: .milliseconds(300))
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
            if let registeredReply { await registry.register(registeredReply) }
        }
        let chat = Chat(controller: controller, email: email, accounts: [accountRow], pool: pool)
        try await Self.waitUntil { Self.namesButton(in: chat.view) != nil }
        #expect(Self.namesButton(in: chat.view) != nil, "control: the chat shows its header: \(HostedAccessibility.labels(in: chat.view).prefix(12))")
        // The field can come on screen after the header; every case types into it.
        try await Self.waitUntil { Self.type("", in: chat.view) }
        #expect(Self.type("", in: chat.view), "control: the chat shows its reply field")
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

    /// Toggles `addresses` in the Reply to sheet, as the user does, then Done.
    static func toggle(_ addresses: [String], in chat: Chat) async throws {
        let names = try #require(namesButton(in: chat.view))
        #expect(names.accessibilityActivate(), "control: the header's names open Reply to")
        try await waitUntil { chat.controller.presentedViewController != nil }
        let sheet = try #require(chat.controller.presentedViewController?.view, "control: Reply to is open")
        try await waitUntil { row(addresses[0], in: sheet) != nil }
        for address in addresses {
            let person = try #require(row(address, in: sheet), "control: Reply to lists \(address): \(HostedAccessibility.labels(in: sheet))")
            #expect(person.accessibilityActivate(), "control: \(address) is toggled")
            try await Task.sleep(for: .milliseconds(200))
        }
        let done = try #require(HostedAccessibility.elements(under: sheet).first { $0.accessibilityLabel == "Done" },
                                "control: Reply to has Done: \(HostedAccessibility.labels(in: sheet))")
        #expect(done.accessibilityActivate(), "control: Done")
        try await waitUntil { chat.controller.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(300))
    }

    private static func row(_ address: String, in sheet: UIView) -> NSObject? {
        HostedAccessibility.elements(under: sheet).first { ($0.accessibilityLabel ?? "").contains(address) }
    }

    /// The "Replying only to" line above the field, if shown.
    static func replyingOnlyTo(in view: UIView) -> String? {
        HostedAccessibility.labels(in: view).first { $0.hasPrefix("Replying only to") }
    }

    /// Types `words` into the field, as UIKit reports an edit.
    private static func type(_ words: String, in view: UIView) -> Bool {
        ThreadChatTests.type(words, in: view)
    }

    /// The compose's addresses by field ("to", "cc", "bcc"), as its recipient fields name them.
    static func composeRecipients(_ view: UIView?) -> [String: String] {
        guard let view else { return [:] }
        var found: [String: String] = [:]
        for element in HostedAccessibility.elements(under: view) {
            guard let identifier = HostedAccessibility.identifier(of: element),
                  identifier.hasPrefix("recipientInput-") else { continue }
            found[String(identifier.dropFirst("recipientInput-".count))] = element.accessibilityLabel ?? ""
        }
        return found
    }

    static func addresses(_ field: String?) -> Set<String> {
        Set((field ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// Polls `condition` for up to ten seconds; the caller asserts on it afterwards.
    static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("While the field's reply is being written, VoiceOver's \"Show TabMail chat\" on the field's words still opens the panel")
    func showChatWhileTheAgentWorks() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let release = DispatchSemaphore(value: 0)
        let backend = Backend(failure: .serverError, asksForReply: false, holdFirst: release)
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "show-chat-working") { chat in
                defer { release.signal() }
                let name = ChatViewConfig.showChatActionName
                #expect(Self.type("Tell them Friday works", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1 && ActiveAgentTracker.shared.anyWorking,
                        "control: the field's compose edit is out and the send is working")
                @MainActor func carrier() -> NSObject? {
                    HostedAccessibility.elements(under: chat.view).first {
                        $0.isAccessibilityElement && HostedAccessibility.identifier(of: $0) != ChatThreadView.replyPillId
                            && ($0.accessibilityCustomActions?.contains { $0.name == name } ?? false)
                    }
                }
                try await Self.waitUntil { carrier() != nil }
                let element = try #require(carrier(), "an element VoiceOver focuses carries the action while the reply is written: \(HostedAccessibility.labels(in: chat.view).prefix(20))")
                #expect(ActiveAgentTracker.shared.anyWorking, "control: still working")
                let action = try #require(element.accessibilityCustomActions?.first { $0.name == name })
                let handler = try #require(action.actionHandler, "control: a SwiftUI action has a handler")
                #expect(handler(action), "the action runs")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatClose") }
                #expect(HostedAccessibility.identifiers(in: chat.view).contains("chatClose"), "the panel opened")
            }
        }
    }

    // MARK: - An edit of the AI Suggestion, held, through the field and the cards

    /// Holds the compose edit the field's request runs until `release()`.
    final class EditGate: Sendable {
        private let state = Mutex<(entered: Int, released: Bool, waiter: CheckedContinuation<Void, Never>?)>((0, false, nil))

        var entered: Int { state.withLock { $0.entered } }

        func hold() async {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { value -> Bool in
                    value.entered += 1
                    if value.released { return true }
                    value.waiter = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func release() {
            let waiter = state.withLock { value -> CheckedContinuation<Void, Never>? in
                value.released = true
                defer { value.waiter = nil }
                return value.waiter
            }
            waiter?.resume()
        }
    }

    static let shownSuggestion = ReplyResult(
        body: "Hi Alex,\n\nTuesday works for me.\n\nThanks", textMessage: "Tuesday works for me")
    private static let editedSuggestion = ReplyResult(
        body: "Hi Alex,\n\nTuesday works.\n\nThanks", textMessage: "Tuesday works", changeCommand: "make it shorter")

    /// The AI Suggestions on screen, by the text they show.
    static func ghosts(in view: UIView) -> [(text: String, element: NSObject)] {
        HostedAccessibility.elements(under: view).compactMap { element in
            guard HostedAccessibility.identifier(of: element) == ChatSuggestionBubble.bubbleId,
                  let label = element.accessibilityLabel,
                  label.hasPrefix("\(ChatSuggestionConfig.label): ") else { return nil }
            return (String(label.dropFirst(ChatSuggestionConfig.label.count + 2)), element)
        }
    }

    /// Opens the ghost's card as its tap does (`ChatThreadView.openSuggestion`): the suggestion the
    /// ghost shows, through the same value (`ChatReadyReply`) and presenter, full screen over the
    /// chat. The ghost's button itself does not take an accessibility activation in a hosted test,
    /// so the card is opened the way the tap opens it.
    private static func openGhostCard(_ shown: ReplyResult, in chat: Chat) async throws {
        let fetched = try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }
        let message = try #require(fetched)
        let ready = ChatReadyReply(message: message, suggestion: shown, accounts: chat.accounts)
        let store = NavigationStore()
        store.accounts = chat.accounts
        let card = UIHostingController(rootView: AnyView(
            ready.composeView(openedOn: .chat, onOutcome: { _ in })
                .environment(store)
                .environment(\.hasTabMailSession, true)))
        card.modalPresentationStyle = .fullScreen
        chat.controller.present(card, animated: false)
        try await waitUntil { chat.controller.presentedViewController === card }
    }

    @Test("A field edit of the AI Suggestion, held: the suggestion stays, pulsing; released, the edit is stored in place, lands in the ghost, then its card opens, and the agent is asked nothing; the ghost's card is the exact Reply All")
    func heldFieldEditThroughTheGhostAndItsCard() async throws {
        // The card's own debug log says what it was given (ComposeView.prepopulate).
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: nil)
        let gate = EditGate()
        let edited = Self.editedSuggestion
        let composeEdit: EmailReplyTool.ComposeEdit = { _, subject, _, _ in
            await gate.hold()
            return try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(
                response: "Done.", subject: subject, body: edited.body,
                textMessage: edited.textMessage ?? "", changeCommand: edited.changeCommand ?? "")))
        }
        defer { gate.release() }
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "edit-in-place", suggestion: Self.shownSuggestion, composeEdit: composeEdit) { chat in
                let router = AgentToolRouter.shared
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == Self.shownSuggestion.textMessage } }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [Self.shownSuggestion.textMessage],
                        "control: the chat shows the AI Suggestion: \(Self.ghosts(in: chat.view).map(\.text))")

                // The field asks for an edit; the edit its Send runs is held.
                // The field can be replaced while the chat settles; wait for it.
                try await Self.waitUntil { Self.type("Make it shorter", in: chat.view) }
                #expect(Self.type("Make it shorter", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                // The card the edit opens waits in the queue, so the test reads it before it shows.
                router.composePresentationDidBegin()
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { gate.entered == 1 }
                #expect(gate.entered == 1, "control: the field's Send ran the edit: \(backend.bodies.count) requests")
                // While it is written the suggestion stays in its place, pulsing, and never shows the
                // edit before it is stored.
                @MainActor func writing() -> [String] {
                    HostedAccessibility.elements(under: chat.view).compactMap { element in
                        HostedAccessibility.identifier(of: element) == ChatSuggestionWorkingBubble.bubbleId
                            ? element.accessibilityLabel : nil
                    }
                }
                let pulsing = "\(ChatSuggestionConfig.writingLine): \(Self.shownSuggestion.textMessage ?? "")"
                try await Self.waitUntil { writing() == [pulsing] }
                let shownWriting = writing()
                #expect(shownWriting == [pulsing], "while the edit is held the suggestion shown stays, pulsing: \(shownWriting)")
                let heldGhosts = Self.ghosts(in: chat.view).map(\.text)
                let heldShowsEdit = heldGhosts.contains { $0 == edited.textMessage }
                #expect(!heldShowsEdit, "while the edit is held the ghost never shows it: \(heldGhosts)")
                let held = try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }
                #expect(held?.suggestion == Self.shownSuggestion, "nothing is stored while the edit is held")

                // Released: the edit replaces the suggestion in place, lands in the ghost, then its card opens.
                gate.release()
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == edited.textMessage } }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [edited.textMessage],
                        "the ghost shows the edit: \(Self.ghosts(in: chat.view).map(\.text))")
                let stored = try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }
                #expect(stored?.suggestion == edited, "the edit is stored whole, its command included")
                try await Self.waitUntil { router.composeQueueDepth == 1 }
                let request = try #require(router.firstQueuedRequestForTesting, "an edit in place opens its card too")
                #expect(request.isFieldsOwnReply && request.suggestion?.textMessage == edited.textMessage,
                        "the card is the field's own, with the edit: \(String(describing: request.suggestion?.textMessage))")
                #expect(backend.bodies.isEmpty, "the closed field asks the agent nothing: \(backend.bodies.count) requests")
                // The user closes that card; the edit stays the AI Suggestion.
                request.onOutcome(.cancelled)
                router.composePresentationDidEnd()
                try await Self.waitUntil { !ActiveAgentTracker.shared.anyWorking }
                try await Self.waitUntil { Self.ghosts(in: chat.view).map(\.text) == [edited.textMessage] }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [edited.textMessage],
                        "the ghost keeps the edit after its card closed: \(Self.ghosts(in: chat.view).map(\.text))")

                // The ghost's card is the exact Reply All, with the edit.
                try await Self.openGhostCard(try #require(stored?.suggestion), in: chat)
                var card: [String: String] = [:]
                // To and Cc both shown: the check below reads both, and the card's rows join the
                // accessibility tree one by one (#1125).
                try await Self.waitUntil {
                    card = Self.composeRecipients(chat.controller.presentedViewController?.view)
                    return card["to"]?.isEmpty == false && card["cc"]?.isEmpty == false
                }
                #expect(Self.addresses(card["to"]).union(Self.addresses(card["cc"])) == ["alex@example.com", "david@example.com", "sam@example.com"],
                        "the card goes to everyone on the email: \(card)")
                #expect(Self.addresses(card["bcc"]).isEmpty, "nobody in Bcc: \(card)")
            }
        }
    }

    @Test("A field edit of the AI Suggestion that changes its envelope opens the field's own card, with no agent; closed unsent, the words are handed back: in the field, on the device, and in the chat opened again after a relaunch")
    func fieldEditCardClosedUnsentKeepsTheWords() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let sent = "Make it formal"
        let backend = Backend(failure: nil)
        let edited = Self.editedSuggestion
        // The edit changes the envelope (a new subject), so it opens a card instead of landing in place.
        let composeEdit: EmailReplyTool.ComposeEdit = { _, _, _, _ in
            try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(
                response: "Done.", subject: "Re: New plan", body: edited.body,
                textMessage: edited.textMessage ?? "", changeCommand: sent)))
        }
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "edit-card-words", suggestion: Self.shownSuggestion, composeEdit: composeEdit) { chat in
                let router = AgentToolRouter.shared
                let key = ChatFieldWords.key(for: chat.email)
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == Self.shownSuggestion.textMessage } }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [Self.shownSuggestion.textMessage],
                        "control: the chat shows the AI Suggestion: \(Self.ghosts(in: chat.view).map(\.text))")

                // The field asks for the edit; the card its compose opens is held in the queue.
                try await Self.waitUntil { Self.type(sent, in: chat.view) }
                #expect(Self.type(sent, in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                router.composePresentationDidBegin()
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { router.composeQueueDepth == 1 }
                let request = try #require(router.firstQueuedRequestForTesting,
                                           "control: the field's compose opened a card: \(backend.bodies.count) requests")
                let onOwnDraft = request.draftId != nil
                #expect(onOwnDraft, "control: the card is the suggestion edit's own")
                let composing = ChatFieldWords.shared.fill(for: key).composing
                #expect(composing, "the field's own card owns the send")

                // The user closes the card unsent; the field's send ends there.
                request.onOutcome(.cancelled)
                router.composePresentationDidEnd()
                try await Self.waitUntil { !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.isEmpty, "the closed field asks the agent nothing: \(backend.bodies.count) requests")
                try await Task.sleep(for: .milliseconds(300))
                let fill = ChatFieldWords.shared.fill(for: key)
                #expect(fill.words == sent && fill.unsent == sent && !fill.composing, "the words are the user's again: \(fill)")
                let texts = ChatFieldWordsRuntimeTests.fieldTexts(chat.view)
                #expect(texts.contains(sent), "the words stay in the field: \(texts)")
                await ChatFieldWords.shared.written()
                let stored = try await chat.pool.read { try ChatFieldWordsRecord.fetchAll($0) }
                let byKey = Dictionary(uniqueKeysWithValues: stored.map { ($0.sessionId, $0.words) })
                #expect(byKey == [key: sent], "kept on the device: \(byKey)")

                // A relaunch (a fresh store on the same database), then the chat opened again.
                ChatFieldWords.shared = ChatFieldWords()
                try await ChatFieldWordsRuntimeTests.open(chat.email) { view in
                    try await Self.waitUntil { ChatFieldWordsRuntimeTests.fieldTexts(view).contains(sent) }
                    let reopened = ChatFieldWordsRuntimeTests.fieldTexts(view)
                    #expect(reopened.contains(sent), "the field opened again after a relaunch: \(reopened)")
                }
            }
        }
    }

    /// What happens while the card's Recompute waits for its reply.
    enum WhileRecomputing: String, CaseIterable, Sendable {
        /// Nothing: the reply lands in the card, the stored suggestion and the ghost.
        case nothing
        /// The card closes: nothing is stored.
        case close
    }

    @Test("The ghost's card Recompute asks the chat's AI service; held, it lands in the card and the ghost, or nowhere once the card closed",
          .disabled("Harness: in a hosted test the compose card's SwiftUI content under its scroll view (the AI Suggestion box, its Recompute, the pill's Send) takes no accessibility activation; the card is given and shows the suggestion (ComposeView's prepopulate log), and the UIKit recipient fields are reachable"),
          arguments: WhileRecomputing.allCases)
    func ghostCardRecompute(_ during: WhileRecomputing) async throws {
        // The card's own debug log says what it was given (ComposeView.prepopulate).
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let gate = ReplyGate()
        let backend = Backend(failure: .serverError, recompute: gate)
        defer { gate.release() }
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "recompute-\(during.rawValue)", suggestion: Self.shownSuggestion) { chat in
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == Self.shownSuggestion.textMessage } }
                try await Self.openGhostCard(Self.shownSuggestion, in: chat)
                var card: UIView?
                try await Self.waitUntil {
                    card = chat.controller.presentedViewController?.view
                    return card.map { HostedAccessibility.identifiers(in: $0).contains("composeRecompute") } ?? false
                }
                let cardView = try #require(card, "control: the ghost's card opens")
                #expect(HostedAccessibility.activate("composeRecompute", in: cardView),
                        "control: the card offers Recompute: \(HostedAccessibility.identifiers(in: cardView))")
                try await Self.waitUntil { gate.asked == 1 }
                #expect(gate.asked == 1, "the card's Recompute asks the chat's AI service")
                #expect(backend.bodies.isEmpty, "and nothing else")

                if during == .close {
                    chat.controller.dismiss(animated: false)
                    try await Self.waitUntil { chat.controller.presentedViewController == nil }
                    #expect(chat.controller.presentedViewController == nil, "control: the card closed")
                }
                gate.release()
                try await Self.waitUntil { gate.answered }
                #expect(gate.answered, "control: the reply came back")
                let stored: () async throws -> ReplyResult? = { try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }?.suggestion }
                switch during {
                case .nothing:
                    try await Self.waitUntil { try await stored() == Self.recomputed }
                    #expect(try await stored() == Self.recomputed, "the reply is stored as the AI Suggestion")
                    let texts = Self.textViews(chat.controller.presentedViewController?.view).map(\.text)
                        + HostedAccessibility.labels(in: chat.controller.presentedViewController?.view ?? UIView())
                    #expect(texts.contains { $0.contains("Tuesday is perfect.") }, "the card shows it: \(texts.prefix(20))")
                    chat.controller.dismiss(animated: false)
                    try await Self.waitUntil { Self.ghosts(in: chat.view).map(\.text) == [Self.recomputed.textMessage] }
                    #expect(Self.ghosts(in: chat.view).map(\.text) == [Self.recomputed.textMessage], "the ghost shows it")
                case .close:
                    try await Task.sleep(for: .milliseconds(500))
                    #expect(try await stored() == Self.shownSuggestion, "nothing is stored once the card closed")
                    #expect(Self.ghosts(in: chat.view).map(\.text) == [Self.shownSuggestion.textMessage], "the ghost keeps the suggestion")
                }
                #expect(gate.asked == 1, "the reply was asked for once")
            }
        }
    }

    @Test("An edit asked in the ghost card's own pill goes to the chat's AI service and replaces the AI Suggestion in place",
          .disabled("Harness: in a hosted test the compose card's SwiftUI content under its scroll view (the AI Suggestion box, its Recompute, the pill's Send) takes no accessibility activation; the card is given and shows the suggestion (ComposeView's prepopulate log), and the UIKit recipient fields are reachable"))
    func ghostCardPillEdit() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        let edited = Self.editedSuggestion
        let backend = Backend(failure: .serverError, cardEdit: ComposeEditJSON.make(
            response: "Made it shorter.", subject: "Re: Plans", body: edited.body,
            textMessage: edited.textMessage ?? "", changeCommand: edited.changeCommand ?? ""))
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "card-edit", suggestion: Self.shownSuggestion) { chat in
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == Self.shownSuggestion.textMessage } }
                try await Self.openGhostCard(Self.shownSuggestion, in: chat)
                let card = try #require(chat.controller.presentedViewController?.view, "control: the ghost's card opened")
                // The card's own pill: Edit, then the request, then its Send.
                let pill = HostedAccessibility.elements(under: card).first {
                    HostedAccessibility.identifier(of: $0) == "chatPill" && $0.accessibilityLabel == "Edit"
                }
                #expect(pill?.accessibilityActivate() == true, "control: the card's pill opens")
                try await Self.waitUntil { Self.type("Make it shorter", in: card) }
                #expect(Self.type("Make it shorter", in: card), "control: the card's pill takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: card),
                        "control: the card's pill sends: \(HostedAccessibility.identifiers(in: card))")
                let stored: () async throws -> ReplyResult? = { try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }?.suggestion }
                try await Self.waitUntil { try await stored() == edited }
                #expect(backend.cardEdits == 1, "the card's edit asks the chat's AI service once")
                #expect(backend.bodies.isEmpty, "and nothing else")
                #expect(try await stored() == edited, "the edit replaces the AI Suggestion whole, its command included")
                chat.controller.dismiss(animated: false)
                try await Self.waitUntil { Self.ghosts(in: chat.view).map(\.text) == [edited.textMessage] }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [edited.textMessage], "the ghost shows it")
            }
        }
    }

    private static func textViews(_ view: UIView?) -> [UITextView] {
        guard let view else { return [] }
        return ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews($0) }
    }

    /// A request the open sheet sends goes with no field (`sendAgentChat` takes none, fenced in
    /// `ChatReplyFieldRuntimeTests.agentSendsCarryNoField`), and its words went with it: cut off, it
    /// can be resumed. The closed field's Send is a compose edit, not an agent turn (ADR-IOS-114
    /// decision 10, amended 2026-11-25): cut off, it leaves no recovery, and its words stay in the
    /// field.
    @Test("A cut-off request from the sheet can be resumed and its words went with it; a cut-off compose from the field leaves no recovery and keeps the words",
          arguments: [false, true])
    func cutOffRecoveryNamesTheFieldOnlyForItsOwnRequest(fromField: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: .connectionLost, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "recovery-origin-\(fromField)") { chat in
                let sent = "Tell them Friday works"
                let key = ChatFieldWords.key(for: chat.email)
                if !fromField {
                    // The sheet opens, and its own input sends.
                    NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": chat.email.id])
                    try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatClose") }
                    #expect(HostedAccessibility.identifiers(in: chat.view).contains("chatClose"),
                            "control: the sheet is open: \(HostedAccessibility.identifiers(in: chat.view))")
                }
                try await Self.waitUntil { Self.type(sent, in: chat.view) }
                #expect(Self.type(sent, in: chat.view), "control: the input takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1, "control: the request went out once and was cut off")
                let compose = backend.bodies.first?.contains("system_prompt_compose_interactive") == true
                #expect(compose == fromField, "the field's words go to the compose edit, the sheet's to the agent")
                let session = ChatPillState.shared.session(for: ChatThreadKey.key(for: chat.email))
                if fromField {
                    try await Task.sleep(for: .milliseconds(500))
                    #expect(session.pendingResume == nil, "a compose is no agent turn: nothing to resume")
                } else {
                    try await Self.waitUntil { session.pendingResume != nil }
                    #expect(session.pendingResume != nil, "the cut-off request can be resumed")
                }
                // From the field the words stay in it; from the sheet they went with the request.
                let expectedWords = fromField ? sent : ""
                #expect(ChatFieldWords.shared.fill(for: key).words == expectedWords,
                        "the words: \(ChatFieldWords.shared.fill(for: key).words)")
            }
        }
    }

    @Test("The inbox pill's own words typed after a cut-off offer Send, not Retry")
    func inboxPillWordsAfterCutOffOfferSend() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: .connectionLost, asksForReply: false)
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        ChatPillState.shared.removeAllSessions()
        ChatPillState.shared.aiService = backend.service
        ChatFieldWords.shared = ChatFieldWords()
        // The inbox pill shows its field only with AI on (else it offers Subscribe); set as the
        // chat view's tests do.
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        saved.setChatView(on: true)
        defer {
            ChatPillState.shared.aiService = .shared
            ChatPillState.shared.removeAllSessions()
            ChatFieldWords.shared = ChatFieldWords()
            backend.http.close()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        try await HostedAccessibility.withAutomation {
            try await ThreadChatTests.withPill(nil) { host, view in
                host.expanded = true
                try await Task.sleep(for: .milliseconds(600))
                #expect(Self.type("What is due this week", in: view), "control: the pill takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: view),
                        "control: the pill's Send takes a tap: \(HostedAccessibility.identifiers(in: view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1, "control: the request went out once and was cut off")

                // The cut-off left a recovery: the empty field offers Retry.
                // Right after the request ends, Retry can show a moment before the field is mounted again.
                try await Self.waitUntil { Self.type("", in: view) }
                #expect(Self.type("", in: view), "control: the pill's field is empty")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: view).contains("chatRetry") }
                #expect(HostedAccessibility.identifiers(in: view).contains("chatRetry"),
                        "control: the cut-off can be resumed: \(HostedAccessibility.identifiers(in: view))")

                #expect(Self.type("And next week", in: view), "control: the pill takes new words")
                try await Task.sleep(for: .milliseconds(500))
                let ids = HostedAccessibility.identifiers(in: view)
                #expect(ids.contains("chatSend") && !ids.contains("chatRetry"), "the pill's own words offer Send: \(ids)")
            }
        }
    }
}
