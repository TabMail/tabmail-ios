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

/// ADR-IOS-114 decision 11, after a failure: who gets a reply asked for in the chat's reply field
/// when the request is recovered.
///
/// THE SYSTEM PROPERTY pinned here: a request sent from the reply field with people chosen in
/// Reply to keeps that choice through its recovery. Whether the connection was lost and the turn is
/// resumed, or the request failed and is sent again with Retry, the agent's reply goes to the people
/// chosen when the request was first sent, as a plain reply with no Cc, whatever Reply to shows
/// when the user recovers it; with nobody chosen, it stays a Reply All. A newer send from the field
/// ends the earlier request's recovery.
///
/// Each case opens the chat for real in a window with its requests going to a fake backend, picks
/// "only David" in Reply to as the user does, sends from the field, fails the first request, changes
/// Reply to, recovers with the field's Retry, and reads the reply the agent's `email_reply` opens.
@Suite("Who gets the agent's reply after a recovered field request", .serialized, .processGlobalState)
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

    /// The fake backend: the first request fails as `failure`; a later request with no saved state
    /// asks for `email_reply` on the email it names (unless `asksForReply` is false); one carrying
    /// the tool's result is answered "Done".
    final class Backend: @unchecked Sendable {
        let http = FakeHTTP.Scenario()
        final class Record: Sendable {
            let bodies = Mutex<[String]>([])
            let cardEdits = Mutex(0)
        }
        private let record = Record()

        /// `editRequest`: the later request asks `email_reply` to edit the AI Suggestion shown with
        /// these words, instead of writing a reply. `recompute`: a reply asked for by a card's
        /// Recompute is answered with `recomputed`, held until the gate is released.
        /// `cardEdit`: the compose edit a card's own pill asks for is answered with this JSON.
        init(failure: Failure, asksForReply: Bool = true, editRequest: String? = nil, recompute: ReplyGate? = nil,
             cardEdit: String? = nil) {
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
                if count == 1 {
                    switch failure {
                    case .connectionLost: return .transportError(.networkConnectionLost)
                    case .serverError: return .status(500)
                    }
                }
                let final: [String: Any]
                if body.contains("conversation_state") || !asksForReply {
                    final = ["assistant": "Done"]
                } else {
                    let number = Self.emailNumber(in: body) ?? 0
                    let arguments: [String: Any] = editRequest.map { ["unique_id": number, "request": $0] }
                        ?? ["unique_id": number, "body": "Friday works"]
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
    private func withChat(_ backend: Backend, tag: String, suggestion: ReplyResult? = nil,
                          composeEdit: EmailReplyTool.ComposeEdit? = nil,
                          _ body: @MainActor (Chat) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        let router = AgentToolRouter.shared
        router.resetComposeQueueForTesting()
        router.pendingCompose = nil
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
            router.pendingCompose = nil
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
    private static func toggle(_ addresses: [String], in chat: Chat) async throws {
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
    private static func replyingOnlyTo(in view: UIView) -> String? {
        HostedAccessibility.labels(in: view).first { $0.hasPrefix("Replying only to") }
    }

    /// Types `words` into the field, as UIKit reports an edit.
    private static func type(_ words: String, in view: UIView) -> Bool {
        ThreadChatTests.type(words, in: view)
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

    @Test("A field request for only David, recovered after a failure, replies only to David whatever Reply to shows when recovered",
          arguments: Failure.allCases)
    func recoveredFieldRequestKeepsItsChoice(failure: Failure) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: failure)
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: failure.rawValue) { chat in
                let router = AgentToolRouter.shared
                // Reply only to David, then ask in the field.
                try await Self.toggle(["alex@example.com", "sam@example.com"], in: chat)
                #expect(Self.replyingOnlyTo(in: chat.view) != nil, "control: the chat replies only to David: \(HostedAccessibility.labels(in: chat.view).prefix(16))")
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("Tell them Friday works", in: chat.view) }
                #expect(Self.type("Tell them Friday works", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1, "control: the request went out once and failed")
                #expect(backend.bodies.first?.contains("a reply goes only to") == true,
                        "control: the field's request named the people chosen")

                // Reply to changes before the recovery: Alex is back.
                try await Self.toggle(["alex@example.com"], in: chat)
                #expect(Self.replyingOnlyTo(in: chat.view) != nil, "control: the chat now replies to Alex and David")

                // The field's Retry recovers the request, its reply held behind a compose on screen.
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("", in: chat.view) }
                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                router.composePresentationDidBegin()
                #expect(HostedAccessibility.activate("chatRetry", in: chat.view),
                        "control: the field offers Retry: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { router.composeQueueDepth == 1 }
                #expect(router.composeQueueDepth == 1, "control: the recovered turn asked for a reply")
                #expect(backend.bodies.count == 2, "control: one recovery request: \(backend.bodies.dropFirst().map { $0.suffix(600) })")
                let request = try #require(router.firstQueuedRequestForTesting)
                #expect(request.fieldReply?.email.id == chat.email.id && request.fieldReply?.onlyTo == ["david@example.com"],
                        "the reply carries the choice made when the request was sent: \(String(describing: request.fieldReply))")
                let reply = (isReplyAll: request.isReplyAll, to: request.to, cc: request.cc, bcc: request.bcc)
                #expect(!reply.isReplyAll && reply.to == ["david@example.com"] && reply.cc.isEmpty && reply.bcc.isEmpty,
                        "a plain reply to only David: \(reply)")

                // The card the chat opens goes only to David.
                router.composePresentationDidEnd()
                var card: [String: String] = [:]
                try await Self.waitUntil {
                    card = Self.composeRecipients(chat.controller.presentedViewController?.view)
                    return card["to"]?.isEmpty == false
                }
                #expect(Self.addresses(card["to"]) == ["david@example.com"], "only David: \(card)")
                #expect(Self.addresses(card["cc"]).isEmpty && Self.addresses(card["bcc"]).isEmpty, "nobody else: \(card)")
            }
        }
    }

    @Test("A field request with nobody chosen, recovered after a failure, replies to everyone whatever Reply to shows when recovered",
          arguments: Failure.allCases)
    func recoveredFieldRequestKeepsReplyAll(failure: Failure) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: failure)
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "all-\(failure.rawValue)") { chat in
                let router = AgentToolRouter.shared
                // Nobody chosen: the field's reply goes to everyone.
                #expect(Self.replyingOnlyTo(in: chat.view) == nil, "control: nobody is chosen: \(HostedAccessibility.labels(in: chat.view).prefix(16))")
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("Tell them Friday works", in: chat.view) }
                #expect(Self.type("Tell them Friday works", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1, "control: the request went out once and failed")
                #expect(backend.bodies.first?.contains("a reply goes only to") == false, "control: the request named nobody")

                // Reply to changes before the recovery: only David.
                try await Self.toggle(["alex@example.com", "sam@example.com"], in: chat)
                #expect(Self.replyingOnlyTo(in: chat.view) != nil, "control: the chat now replies only to David")

                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("", in: chat.view) }
                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                router.composePresentationDidBegin()
                #expect(HostedAccessibility.activate("chatRetry", in: chat.view),
                        "control: the field offers Retry: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { router.composeQueueDepth == 1 }
                #expect(router.composeQueueDepth == 1, "control: the recovered turn asked for a reply")
                let request = try #require(router.firstQueuedRequestForTesting)
                #expect(request.fieldReply?.email.id == chat.email.id && request.fieldReply?.onlyTo == nil,
                        "the reply carries the choice made when the request was sent, nobody: \(String(describing: request.fieldReply))")
                let reply = (isReplyAll: request.isReplyAll, to: request.to, cc: request.cc, bcc: request.bcc)
                #expect(reply.isReplyAll, "a Reply All: \(reply)")

                // The card the chat opens goes to everyone on the email.
                router.composePresentationDidEnd()
                var card: [String: String] = [:]
                try await Self.waitUntil {
                    card = Self.composeRecipients(chat.controller.presentedViewController?.view)
                    return card["to"]?.isEmpty == false
                }
                #expect(Self.addresses(card["to"]).union(Self.addresses(card["cc"])) == ["alex@example.com", "david@example.com", "sam@example.com"],
                        "everyone: \(card)")
            }
        }
    }

    @Test("A newer send from the field ends an earlier failed request's recovery", arguments: Failure.allCases)
    func newerSendEndsTheRecovery(failure: Failure) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: failure, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "newer-\(failure.rawValue)") { chat in
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("Tell them Friday works", in: chat.view) }
                #expect(Self.type("Tell them Friday works", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("", in: chat.view) }
                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                #expect(HostedAccessibility.identifiers(in: chat.view).contains("chatRetry"), "control: the failed request can be recovered")

                // A newer request from the field, which succeeds.
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("Thanks", in: chat.view) }
                #expect(Self.type("Thanks", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 2 && backend.bodies.last?.contains("Thanks") == true, "control: the newer request went out")

                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("", in: chat.view) }
                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Task.sleep(for: .milliseconds(500))
                #expect(!HostedAccessibility.identifiers(in: chat.view).contains("chatRetry"),
                        "the earlier request can no longer be recovered: \(HostedAccessibility.identifiers(in: chat.view))")
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

    private static let shownSuggestion = ReplyResult(
        body: "Hi Alex,\n\nTuesday works for me.\n\nThanks", textMessage: "Tuesday works for me")
    private static let editedSuggestion = ReplyResult(
        body: "Hi Alex,\n\nTuesday works.\n\nThanks", textMessage: "Tuesday works", changeCommand: "make it shorter")

    /// The AI Suggestions on screen, by the text they show.
    private static func ghosts(in view: UIView) -> [(text: String, element: NSObject)] {
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
        let message = try #require(try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) })
        let ready = ChatReadyReply(message: message, suggestion: shown, accounts: chat.accounts)
        let store = NavigationStore()
        store.accounts = chat.accounts
        let card = UIHostingController(rootView: AnyView(
            ready.compose.composeView(replyTo: ready.message, suggestion: ready.suggestion, draftId: ready.draftId,
                                      onAgentOutcome: { _ in })
                .environment(store)
                .environment(\.hasTabMailSession, true)))
        card.modalPresentationStyle = .fullScreen
        chat.controller.present(card, animated: false)
        try await waitUntil { chat.controller.presentedViewController === card }
    }

    @Test("A field edit of the AI Suggestion, recovered after a failure and held, lands in place; the ghost's card is the exact Reply All",
          arguments: Failure.allCases)
    func heldFieldEditThroughTheGhostAndItsCard(failure: Failure) async throws {
        // The card's own debug log says what it was given (ComposeView.prepopulate).
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: failure, editRequest: "make it shorter")
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
            try await withChat(backend, tag: "edit-\(failure.rawValue)", suggestion: Self.shownSuggestion, composeEdit: composeEdit) { chat in
                let router = AgentToolRouter.shared
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == Self.shownSuggestion.textMessage } }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [Self.shownSuggestion.textMessage],
                        "control: the chat shows the AI Suggestion: \(Self.ghosts(in: chat.view).map(\.text))")

                // The field asks for an edit; the first request fails.
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("Make it shorter", in: chat.view) }
                #expect(Self.type("Make it shorter", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1, "control: the request went out once and failed")

                // Retry recovers it; the edit it asks for is held.
                // The field can be replaced while the chat settles after a send; wait for it.
                try await Self.waitUntil { Self.type("", in: chat.view) }
                #expect(Self.type("", in: chat.view),
                        "control: the field is emptied: working \(ActiveAgentTracker.shared.anyWorking), \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                #expect(HostedAccessibility.activate("chatRetry", in: chat.view),
                        "control: the field offers Retry: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { gate.entered == 1 }
                #expect(gate.entered == 1, "control: the recovered turn asked for the edit: \(backend.bodies.count) requests")
                // The ghost steps aside while the chat works and never shows the edit before it is stored.
                #expect(!Self.ghosts(in: chat.view).contains { $0.text == edited.textMessage },
                        "while the edit is held the ghost never shows it: \(Self.ghosts(in: chat.view).map(\.text))")
                let held = try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }
                #expect(held?.suggestion == Self.shownSuggestion, "nothing is stored while the edit is held")

                // Released: the edit replaces the suggestion in place; no card opens.
                gate.release()
                try await Self.waitUntil { Self.ghosts(in: chat.view).contains { $0.text == edited.textMessage } }
                #expect(Self.ghosts(in: chat.view).map(\.text) == [edited.textMessage],
                        "the ghost shows the edit: \(Self.ghosts(in: chat.view).map(\.text))")
                let stored = try await AppDatabase.dbPool.read { try MessageHeader.fetchOne($0, key: chat.email.id) }
                #expect(stored?.suggestion == edited, "the edit is stored whole, its command included")
                #expect(router.composeQueueDepth == 0 && router.pendingCompose == nil && chat.controller.presentedViewController == nil,
                        "an edit in place opens no card")

                // The ghost's card is the exact Reply All, with the edit.
                try await Self.openGhostCard(try #require(stored?.suggestion), in: chat)
                var card: [String: String] = [:]
                try await Self.waitUntil {
                    card = Self.composeRecipients(chat.controller.presentedViewController?.view)
                    return card["to"]?.isEmpty == false
                }
                #expect(Self.addresses(card["to"]).union(Self.addresses(card["cc"])) == ["alex@example.com", "david@example.com", "sam@example.com"],
                        "the card goes to everyone on the email: \(card)")
                #expect(Self.addresses(card["bcc"]).isEmpty, "nobody in Bcc: \(card)")
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

    @Test("A resumed field request's answer empties the unchanged sent words, keeps words written since (even the same text), and leaves another chat's words",
          arguments: [false, true])
    func resumedFieldRequestCompletesTheFieldWords(retyped: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        let backend = Backend(failure: .connectionLost, asksForReply: false)
        try await HostedAccessibility.withAutomation {
            try await withChat(backend, tag: "resume-words-\(retyped)") { chat in
                let key = ChatFieldWords.key(for: chat.email)
                let sent = "Tell them Friday works"
                // Another chat's words, which the resumed request must not touch.
                let other = Self.groupEmail("resume-other-\(retyped)")
                let otherKey = ChatFieldWords.key(for: other)
                #expect(otherKey != key, "control: two chats")
                let otherWords = "Words on another chat"
                ChatFieldWords.shared.apply(.put(otherWords), to: otherKey)

                #expect(Self.type(sent, in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 1, "control: the request went out once and was cut off")
                #expect(ChatFieldWords.shared.fill(for: key).words == sent, "control: the sent words wait in the field")
                #expect(ChatFieldWords.shared.fill(for: key).unsent == "", "control: sent words are not kept")
                if retyped {
                    // Cleared and written again, the same text: new words.
                    #expect(Self.type("", in: chat.view))
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(Self.type(sent, in: chat.view))
                    try await Task.sleep(for: .milliseconds(300))
                }

                // The chat's "Connection lost" affordance resumes the cut-off request.
                var resume: NSObject?
                try await Self.waitUntil {
                    resume = HostedAccessibility.elements(under: chat.view).first {
                        ($0.accessibilityLabel ?? "").contains("Connection lost")
                    }
                    return resume != nil
                }
                let button = try #require(resume, "control: the chat offers the resume: \(HostedAccessibility.labels(in: chat.view).suffix(12))")
                #expect(button.accessibilityActivate(), "control: the resume takes a tap")
                try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 2 && backend.bodies.last?.contains("conversation_state") == true,
                        "control: the request was resumed from its saved state")
                try await Task.sleep(for: .milliseconds(300))

                let expected = retyped ? sent : ""
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after the resumed answer: \(ChatFieldWords.shared.fill(for: key).words)")
                #expect(ChatFieldWords.shared.fill(for: otherKey).words == otherWords, "another chat's words stay")
                await ChatFieldWords.shared.written()
                let stored = try await chat.pool.read { try ChatFieldWordsRecord.fetchAll($0) }
                let byKey = Dictionary(uniqueKeysWithValues: stored.map { ($0.sessionId, $0.words) })
                var want = [otherKey: otherWords]
                if retyped { want[key] = sent }
                #expect(byKey == want, "kept words: \(byKey)")
            }
        }
    }
}
