/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114: the chat's reply field, run for real.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The mounted field holds only the user's words: the AI Suggestion never enters it (it waits
///     as a ghost bubble in the chat), not on open, not when it arrives late, not in the open
///     sheet, not after a completion. Under the empty field the "e.g." line shows its change; a
///     tap puts the change in the field and sends nothing. Words the user typed are never
///     replaced. The two completions are private to `ChatThreadView`, so which ones empty the
///     field is read from the source (`clearWiring`).
///  2. A send names the pill's email as the send starts: after the newest email changes, the next
///     request names the new email, never the number found for the earlier one.
///  3. A failed chat request's persistent log keeps the error and never the user's words while
///     debug logging is off, in every failure branch: the words can quote the email, and a resend
///     or rewind replays them. The gate is in
///     `BackgroundSyncLogger.logChatError`, so it covers every caller.
///  4. The pill wires 2 into every send. The field's Send and the "e.g." line are pressed for real,
///     through accessibility (`HostedAccessibility`), where they ask the agent nothing (an empty
///     field, the line). The agent route sends to the live backend client, which has no test seam,
///     so a press there would reach the backend: its wiring is read from the source.
///  5. A completion empties only what was sent: a draft typed in the sheet after the send stays.
@Suite("Chat reply field at run time", .serialized, .processGlobalState)
@MainActor
struct ChatReplyFieldRuntimeTests {

    private static func header(_ uid: String, ready: String? = nil) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Sender", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(), snippet: "", folderId: "field:INBOX",
            accountId: "field", folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<\(uid)@example.com>"
        if let ready {
            header.cachedReply = "Full reply for \(uid)"
            header.replyTextMessage = ready
        }
        return header
    }

    @Observable final class Host {
        var message: MessageHeader
        /// The chat sheet is open.
        var expanded = false
        /// The agent is answering the user's words.
        var working = false
        /// Signed in: the open sheet shows its input bar, not the sign-in bar.
        var signedIn = false
        /// The "e.g." line's change.
        var example: String? = "politely decline"
        /// Words the field sent to the agent (`onFieldSend`).
        var fieldSends: [String] = []
        init(_ message: MessageHeader) { self.message = message }
    }

    struct HostView: View {
        @Bindable var host: Host
        var body: some View {
            DynamicIslandChat(
                message: host.message, isExpanded: $host.expanded, isWorking: $host.working,
                replyField: ChatReplyField(example: host.example, isNoReply: false),
                onFieldSend: { host.fieldSends.append($0) })
            .environment(\.hasTabMailSession, host.signedIn)
        }
    }

    /// The text of every native editable field under `view`.
    private static func fieldTexts(_ view: UIView) -> [String] {
        let own = (view as? UITextView).map { [$0.text ?? ""] } ?? (view as? UITextField).map { [$0.text ?? ""] } ?? []
        return own + view.subviews.flatMap { fieldTexts($0) }
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    // MARK: - 1. The field holds only the user's words

    @Test("The AI Suggestion never enters the mounted field, on open or when it arrives later")
    func suggestionNeverEntersTheField() async throws {
        try await withMountedField(Self.header("field-A", ready: "A ready reply to the first email")) { host, controller in
            var texts = Self.fieldTexts(controller.view)
            #expect(!texts.isEmpty, "the mounted pill has a native editable field")
            #expect(texts.allSatisfy { $0.isEmpty }, "the field is empty: \(texts)")
            host.message = Self.header("field-B", ready: "A ready reply to the newer email")
            try await Self.settle()
            host.message.replyTextMessage = "A late suggestion"
            try await Self.settle()
            texts = Self.fieldTexts(controller.view)
            #expect(texts.allSatisfy { $0.isEmpty }, "still empty for a newer email and a late suggestion: \(texts)")
        }
    }

    /// Mounts the pill on `message` and hands the host and controller to `body`.
    private func withMountedField(
        _ message: MessageHeader,
        _ body: @MainActor (Host, UIHostingController<HostView>) async throws -> Void
    ) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        // The open sheet's input bar needs a plan: set it here, never from an earlier suite.
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        saved.setChatView(on: true)
        defer { saved.restore() }
        ChatPillState.shared.removeAllSessions()
        let host = Host(message)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: HostView(host: host))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            ChatPillState.shared.removeAllSessions()
        }
        try await Self.settle()
        try await body(host, controller)
    }

    /// Types `words` into the mounted field the way UIKit reports an edit.
    private static func type(_ words: String, in view: UIView) -> Bool {
        if let text = view as? UITextView, text.isEditable {
            text.text = words
            text.delegate?.textViewDidChange?(text)
            return true
        }
        if let text = view as? UITextField {
            text.text = words
            text.sendActions(for: .editingChanged)
            return true
        }
        return view.subviews.contains { type(words, in: $0) }
    }

    @Test("The e.g. line shows under the empty field; a tap puts its change in the field and never sends it")
    func exampleLinePutsTheChange() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted line")
        try await HostedAccessibility.withAutomation { try await exampleLinePutsTheChangeBody() }
    }

    private func exampleLinePutsTheChangeBody() async throws {
        try await withMountedField(Self.header("field-eg", ready: "A ready reply")) { host, controller in
            host.signedIn = true
            try await Self.settle()
            #expect(HostedAccessibility.identifiers(in: controller.view).contains(DynamicIslandChat.exampleLineId),
                    "the empty field shows the line: \(HostedAccessibility.identifiers(in: controller.view))")
            #expect(HostedAccessibility.activate(DynamicIslandChat.exampleLineId, in: controller.view), "the line takes a tap")
            try await Self.settle()
            #expect(Self.fieldTexts(controller.view).contains("politely decline"), "the change is in the field: \(Self.fieldTexts(controller.view))")
            #expect(host.fieldSends.isEmpty, "nothing was sent")
            #expect(!host.working && !host.expanded, "the agent was not asked, and no sheet opened")
            #expect(!HostedAccessibility.identifiers(in: controller.view).contains(DynamicIslandChat.exampleLineId),
                    "with words in the field the line goes")
        }
        try await withMountedField(Self.header("field-eg-none")) { host, controller in
            host.signedIn = true
            host.example = nil
            try await Self.settle()
            #expect(!HostedAccessibility.identifiers(in: controller.view).contains(DynamicIslandChat.exampleLineId), "no change, no line")
            _ = HostedAccessibility.activate("chatSend", in: controller.view)
            try await Self.settle()
            #expect(host.fieldSends.isEmpty, "an empty field sends nothing")
        }
    }

    @Test("A send or an answer from the field empties it, and no AI Suggestion fills it")
    func completionEmptiesTheField() async throws {
        try await withMountedField(Self.header("field-C", ready: "A ready reply")) { host, controller in
            let start = Self.fieldTexts(controller.view)
            #expect(!start.isEmpty && start.allSatisfy { $0.isEmpty }, "control: the field starts empty, the suggestion is not in it: \(start)")
            #expect(Self.type("My question", in: controller.view), "the mounted pill has a native editable field")
            try await Self.settle()
            #expect(Self.fieldTexts(controller.view).contains("My question"), "control: the edit reached the field")
            let key = ChatFieldWords.key(for: host.message)
            // Control: with no field send open, a completion leaves the user's words.
            ChatFieldWords.shared.apply(.completed, to: key)
            try await Self.settle()
            #expect(Self.fieldTexts(controller.view).contains("My question"), "no send open: the words stay: \(Self.fieldTexts(controller.view))")
            // The words sent from the field: the send's completion lands on the chat key the send
            // was made under (ADR-IOS-117) and empties them.
            ChatFieldWords.shared.apply(.sentFromField, to: key)
            ChatFieldWords.shared.apply(.completed, to: key)
            try await Self.settle()
            let texts = Self.fieldTexts(controller.view)
            #expect(!texts.contains("My question"), "the completion emptied the field: \(texts)")
            #expect(texts.allSatisfy { $0.isEmpty }, "the field stays empty: \(texts)")
        }
    }

    @Test("A confirmation card that arrives while the field is collapsed opens the sheet; an answer without a card does not")
    func confirmationCardOpensTheSheet() async throws {
        try await withMountedField(Self.header("field-card", ready: "A ready reply")) { host, _ in
            host.signedIn = true
            try await Self.settle()
            #expect(!host.expanded, "control: the field starts collapsed")
            // The pill's own session, as the agent's tool delivers its card to it.
            let session = ChatPillState.shared.session(for: ChatThreadKey.key(for: host.message))
            session.chatMessages.append(ChatMessage(role: .agent, content: "Done.", timestamp: Date()))
            try await Self.settle()
            #expect(!host.expanded, "control: an answer without a card leaves the field collapsed")
            SessionUISink(session: session).deliverConfirmation(AgentToolRouter.ActionConfirmation(
                action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [], onRespond: { _ in }))
            try await Self.settle()
            #expect(host.expanded, "the card opens the sheet, where it can be answered")
        }
    }

    @Test("A late AI Suggestion never replaces words the user typed in the field")
    func lateReplyKeepsTheUsersWords() async throws {
        try await withMountedField(Self.header("field-D", ready: "A ready reply")) { host, controller in
            let words = "My own words"
            #expect(Self.type(words, in: controller.view), "the mounted pill has a native editable field")
            try await Self.settle()
            #expect(Self.fieldTexts(controller.view).contains(words), "control: the edit reached the field")
            host.message.replyTextMessage = "A late suggestion"
            try await Self.settle()
            let texts = Self.fieldTexts(controller.view)
            #expect(texts.contains(words), "the user's words stay: \(texts)")
            #expect(!texts.contains("A late suggestion"))
        }
    }

    /// The field's words once a reply arrives while the sheet is open, then once the sheet closes;
    /// `typed`: words the user typed in the sheet first.
    private func afterTheSheet(typed: String?, uid: String) async throws -> (open: [String], closed: [String]) {
        var open: [String] = []
        var words: [String] = []
        try await withMountedField(Self.header(uid)) { host, controller in
            #expect(Self.fieldTexts(controller.view).contains(""), "control: the field starts empty")
            host.signedIn = true
            host.expanded = true
            try await Task.sleep(for: .milliseconds(600))
            if let typed {
                #expect(Self.type(typed, in: controller.view), "the open sheet has a native editable field")
                try await Self.settle()
                #expect(Self.fieldTexts(controller.view).contains(typed), "control: the edit reached the field")
            }
            host.message.cachedReply = "Full reply"
            host.message.replyTextMessage = "Yes, Tuesday works for me."
            try await Self.settle()
            open = Self.fieldTexts(controller.view)
            host.expanded = false
            try await Task.sleep(for: .milliseconds(600))
            words = Self.fieldTexts(controller.view)
        }
        return (open, words)
    }

    @Test("A suggestion that arrives while the sheet is open never enters the field there; words typed there stay")
    func suggestionStaysOutOfTheSheet() async throws {
        let untouched = try await afterTheSheet(typed: nil, uid: "field-sheet-A")
        #expect(!untouched.open.contains("Yes, Tuesday works for me."), "not in the open sheet: \(untouched.open)")
        #expect(!untouched.closed.contains("Yes, Tuesday works for me."), "nor after it closed: \(untouched.closed)")
        let typed = try await afterTheSheet(typed: "My own question", uid: "field-sheet-B")
        #expect(typed.open.contains("My own question"), "the user's words stay: \(typed.open)")
        #expect(!typed.open.contains("Yes, Tuesday works for me."))
        #expect(typed.closed.contains("My own question"), "after the sheet closed too: \(typed.closed)")
        #expect(!typed.closed.contains("Yes, Tuesday works for me."))
    }

    // MARK: - 2. A send names the email it is about

    @Test("A send names the pill's email as it starts, never the number found for an earlier email")
    func sendNamesTheCurrentEmail() async {
        let first = Self.header("context-A")
        let newer = Self.header("context-B")
        let firstNumber = await DynamicIslandChat.contextNumber(sendingAbout: first, known: nil)
        let newerNumber = await DynamicIslandChat.contextNumber(sendingAbout: newer, known: firstNumber)
        #expect(firstNumber == (await ChatIdTranslator.shared.toNumericId(first.id)))
        #expect(newerNumber == (await ChatIdTranslator.shared.toNumericId(newer.id)))
        #expect(newerNumber != firstNumber, "the newer email's request names the newer email")
        // Without an email (a resumed session from the inbox), the known number stands.
        #expect(await DynamicIslandChat.contextNumber(sendingAbout: nil, known: 7) == 7)
        #expect(await DynamicIslandChat.contextNumber(sendingAbout: nil, known: nil) == nil)
    }

    // MARK: - 3. Failure logs never quote the reply field

    /// A chat request's failure branches: the server's answer and the line it logs.
    enum Failure: CaseIterable {
        case serverError, emptyAnswer, blankAnswer

        var final: [String: Any] {
            switch self {
            case .serverError: ["error": "upstream failed"]
            case .emptyAnswer: ["assistant": ""]
            case .blankAnswer: ["assistant": " \n\t "]
            }
        }

        var logged: String {
            switch self {
            case .serverError: "Server error: upstream failed"
            case .emptyAnswer: "Empty assistant response from server"
            case .blankAnswer: "Response empty after normalizeUnicode+trim"
            }
        }
    }

    @Test("A failed chat request logs the error, and the user's words only while debug logging is on",
          arguments: Failure.allCases, [false, true])
    func chatRequestFailureLog(failure: Failure, debugLogging: Bool) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let oldURL = AppLogStore.fileURLOverride.withLock { $0 }
        let oldGate = DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 }
        AppLogStore.fileURLOverride.withLock { $0 = logDirectory.appendingPathComponent("chat.log") }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = debugLogging }
        let restoreAISetting = AITestSetting.save()
        AITestSetting.set(aiOff: false)
        defer {
            restoreAISetting()
            AppLogStore.fileURLOverride.withLock { $0 = oldURL }
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = oldGate }
            try? FileManager.default.removeItem(at: logDirectory)
        }
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let final = String(decoding: try JSONSerialization.data(withJSONObject: failure.final), as: UTF8.self)
        http.register(path: "/completions/chat", method: "POST") { _ in
            return .bytes(Data("event: final\ndata: \(final)\n\n".utf8), contentType: "text/event-stream")
        }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        let marker = "Words written from the email privacy marker"

        // A server error throws; the other two answer nothing.
        let response = (try? await service.sendChatMessage(userText: marker, history: [])) ?? nil

        #expect(response == nil)
        #expect(http.recordedCalls().count == 1, "the request really went out")
        let logged = AppLogStore.read(channel: .chatError)
        #expect(logged.contains(failure.logged), "the failure was logged: \(logged)")
        #expect(logged.contains(marker) == debugLogging, "\(logged)")
    }

    // MARK: - 4. Wiring

    private static func source(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Every send names the pill's email as it starts")
    func sendWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let start = try #require(text.range(of: "func sendAgentChat("))
        let send = String(text[start.upperBound...])
        // A field send, or its retry, names the email the field's send started on.
        #expect(send.contains("var contextNumericId = await Self.contextNumber(sendingAbout: field?.message ?? message, known: contextEmailNumericId)"))
    }

    /// The text from `start` to the next `private func`.
    private static func function(_ start: String, in text: String) throws -> String {
        let begin = try #require(text.range(of: start))
        let rest = text[begin.upperBound...]
        return String(rest[..<(rest.range(of: "private func ")?.lowerBound ?? rest.endIndex)])
    }

    @Test("The sheet's re-sends own none of the field's words: Rewind sends with no field, Re-send with its turn's field send and no words key")
    func sheetResendsSendWithNoField() throws {
        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        let rewind = try Self.function("private func rewindToMessage(", in: island)
        #expect(rewind.contains("sendAgentChat(text)") && !rewind.contains("field:"), "Rewind sends with no field: \(rewind)")
        // Re-send of the last turn carries the field send its bubble recorded (the menu passes
        // `msg.fieldSend`): its email and who was chosen in Reply to. The turn was answered, so its
        // own send is complete, and words open in the field by then belong to a newer send: the
        // re-send owns none, so its answer, cards and sent compose leave them alone.
        let resend = try Self.function("private func resendLastUserMessage(", in: island)
        #expect(resend.contains("sendAgentChat(text, field: field, ownsFieldWords: false)") && !resend.contains("replyField"),
                "Re-send sends with its turn's own field send and owns no words: \(resend)")
        // A send names the field's words only from the send's own field, and only when it owns them,
        // never from what the field holds: the re-sends are reached only through a bubble's context
        // menu, which takes no activation in a hosted test, so the one place a send's field key is
        // decided is fenced.
        let send = try Self.function("func sendAgentChat(", in: island)
        #expect(send.components(separatedBy: "fieldWordsKey = ").count == 2
                    && send.contains("let fieldWordsKey = ownsFieldWords ? field.map { ChatFieldWords.key(for: $0.message) } : nil"),
                "a send's field key comes from its field alone, and only for the field's own send")
        #expect(!send.contains("holdsSentWords"), "what the field holds never names a send's field key")
        // A failed re-send's Retry keeps the rule: the failure records whether the send owned words.
        #expect(send.contains("lastFailedSend = .init(text: text, field: field, ownsFieldWords: fieldWordsKey != nil)"),
                "a failed send records whether it owned the field's words")
        #expect(island.contains("sendAgentChat(failed.text, field: failed.field, ownsFieldWords: failed.ownsFieldWords)"),
                "Retry sends with the failed send's own ownership")
    }

    @Test("A sent compose card and an agent answer from the field complete on the request's own chat key, never the view's")
    func clearWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(!text.contains("fieldClearCount"), "no view counter carries a completion")
        let island = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(!island.contains("fieldFill.apply(.completed)") && !island.contains("fieldFill.apply(.confirmationCard)"),
                "the pill never applies a request's transition to the chat it shows")
        #expect(island.components(separatedBy: "ChatFieldWords.shared.apply(.answered, to: fieldWordsKey)").count == 3,
                "a send's and a resume's answer complete on the key captured at send")
        let router = try Self.source("TabMail/Services/AI/AgentToolRouter.swift")
        #expect(router.contains("if case .sent = outcome, let fieldWordsKey { ChatFieldWords.shared.apply(.completed, to: fieldWordsKey) }"))
        let sink = try Self.source("TabMail/Services/AI/Tools/ToolInvocation.swift")
        #expect(sink.contains("if let fieldWordsKey { ChatFieldWords.shared.apply(.confirmationCard, to: fieldWordsKey) }"))
    }
}
