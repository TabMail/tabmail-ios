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
    private static func groupEmail(_ tag: String) -> MessageHeader {
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
        }
        private let record = Record()

        init(failure: Failure, asksForReply: Bool = true) {
            http.register(path: "/completions/chat", method: "POST") { [record] request in
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
    }

    /// The open chat.
    @MainActor
    struct Chat {
        let controller: UIHostingController<AnyView>
        let email: MessageHeader
        let accounts: [Account]
        var view: UIView { controller.view }
    }

    /// Opens the chat on `groupEmail(tag)` in a window, its requests going to `backend`, and runs `body`.
    private func withChat(_ backend: Backend, tag: String, _ body: @MainActor (Chat) async throws -> Void) async throws {
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
        defer {
            ChatPillState.shared.aiService = .shared
            ChatPillState.shared.removeAllSessions()
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
        let email = Self.groupEmail(tag)
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
        await registry.register(EmailReplyTool(context: ToolContext(db: pool, translator: ChatIdTranslator.shared)))
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
        let chat = Chat(controller: controller, email: email, accounts: [accountRow])
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
                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                router.composePresentationDidBegin()
                #expect(HostedAccessibility.activate("chatRetry", in: chat.view),
                        "control: the field offers Retry: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { router.composeQueueDepth == 1 }
                #expect(router.composeQueueDepth == 1, "control: the recovered turn asked for a reply")
                #expect(backend.bodies.count == 2, "control: one recovery request: \(backend.bodies.dropFirst().map { $0.suffix(600) })")
                let request = try #require(router.firstQueuedRequestForTesting)
                #expect(request.fieldReply == ChatFieldReply(emailKey: ChatThread.copyKey(chat.email), onlyTo: ["david@example.com"]),
                        "the reply carries the choice made when the request was sent: \(String(describing: request.fieldReply))")
                let reply = ChatReplyCompose.make(agent: request, accounts: chat.accounts)
                #expect(reply == ChatReplyCompose(isReplyAll: false, to: ["david@example.com"], cc: [], bcc: []),
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

                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                router.composePresentationDidBegin()
                #expect(HostedAccessibility.activate("chatRetry", in: chat.view),
                        "control: the field offers Retry: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { router.composeQueueDepth == 1 }
                #expect(router.composeQueueDepth == 1, "control: the recovered turn asked for a reply")
                let request = try #require(router.firstQueuedRequestForTesting)
                #expect(request.fieldReply == ChatFieldReply(emailKey: ChatThread.copyKey(chat.email), onlyTo: nil),
                        "the reply carries the choice made when the request was sent, nobody: \(String(describing: request.fieldReply))")
                let reply = ChatReplyCompose.make(agent: request, accounts: chat.accounts)
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
                #expect(Self.type("Tell them Friday works", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 1 && !ActiveAgentTracker.shared.anyWorking }
                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Self.waitUntil { HostedAccessibility.identifiers(in: chat.view).contains("chatRetry") }
                #expect(HostedAccessibility.identifiers(in: chat.view).contains("chatRetry"), "control: the failed request can be recovered")

                // A newer request from the field, which succeeds.
                #expect(Self.type("Thanks", in: chat.view), "control: the field takes words")
                try await Task.sleep(for: .milliseconds(300))
                #expect(HostedAccessibility.activate("chatSend", in: chat.view),
                        "control: the field's Send takes a tap: \(HostedAccessibility.identifiers(in: chat.view))")
                try await Self.waitUntil { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
                #expect(backend.bodies.count == 2 && backend.bodies.last?.contains("Thanks") == true, "control: the newer request went out")

                #expect(Self.type("", in: chat.view), "control: the field is emptied")
                try await Task.sleep(for: .milliseconds(500))
                #expect(!HostedAccessibility.identifiers(in: chat.view).contains("chatRetry"),
                        "the earlier request can no longer be recovered: \(HostedAccessibility.identifiers(in: chat.view))")
            }
        }
    }
}
