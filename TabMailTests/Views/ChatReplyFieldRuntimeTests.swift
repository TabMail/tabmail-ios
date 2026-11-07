/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-103: the chat's reply field, run for real.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The ready AI Reply is in the mounted field; when the newest email changes, the untouched
///     field holds the new email's ready reply. A completion (a sent compose card, an agent answer
///     from the field) empties the field, and the ready reply does not come back; a late AI Reply
///     never replaces words the user typed. One that arrives while the chat sheet is open fills the
///     untouched field when the sheet closes; words typed in the sheet stay. The two completions are private to `ChatThreadView`,
///     so which ones empty the field is read from the source (`clearWiring`).
///  2. A send names the pill's email as the send starts: after the newest email changes, the next
///     request names the new email, never the number found for the earlier one.
///  3. A failed chat request's persistent log keeps the error and never the user's words while
///     debug logging is off, in every failure branch: the words can be the reply field's AI Reply,
///     written from the email, and a resend or rewind replays them. The gate is in
///     `BackgroundSyncLogger.logChatError`, so it covers every caller.
///  4. The pill wires 2 into every send: hosted views cannot be sent from a unit test (activating the
///     Send button through in-process accessibility did not run it, tried 2026-11-07), so that
///     wiring is read from the source.
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
        /// `ChatThreadView.fieldClearCount`: a send or an answer from the field bumps it.
        var clearCount = 0
        /// The chat sheet is open.
        var expanded = false
        /// Signed in: the open sheet shows its input bar, not the sign-in bar.
        var signedIn = false
        init(_ message: MessageHeader) { self.message = message }
    }

    struct HostView: View {
        @Bindable var host: Host
        var body: some View {
            DynamicIslandChat(
                message: host.message, isExpanded: $host.expanded, isWorking: .constant(false),
                replyField: ChatReplyField(
                    readyText: ChatReplyField.readyText(newest: host.message, isOwn: false),
                    isNoReply: false, clearCount: host.clearCount))
            .environment(\.hasTabMailSession, host.signedIn)
        }
    }

    /// The text of every native editable field under `view`.
    private static func fieldTexts(_ view: UIView) -> [String] {
        let own = (view as? UITextView).map { [$0.text ?? ""] } ?? (view as? UITextField).map { [$0.text ?? ""] } ?? []
        return own + view.subviews.flatMap { fieldTexts($0) }
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    // MARK: - 1. The ready reply fills the field

    @Test("The ready AI Reply is in the mounted field, and follows a new newest email while untouched")
    func readyReplyFillsTheField() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        ChatPillState.shared.removeAllSessions()
        let first = Self.header("field-A", ready: "A ready reply to the first email")
        let host = Host(first)
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
        let texts = Self.fieldTexts(controller.view)
        #expect(!texts.isEmpty, "the mounted pill has a native editable field")
        #expect(texts.contains("A ready reply to the first email"), "got \(texts)")

        host.message = Self.header("field-B", ready: "A ready reply to the newer email")
        try await Self.settle()
        let after = Self.fieldTexts(controller.view)
        #expect(after.contains("A ready reply to the newer email"), "got \(after)")
        #expect(!after.contains("A ready reply to the first email"))
    }

    /// Mounts the pill on `message` and hands the host and controller to `body`.
    private func withMountedField(
        _ message: MessageHeader,
        _ body: @MainActor (Host, UIHostingController<HostView>) async throws -> Void
    ) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
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

    @Test("A send or an answer from the field empties it, and the ready AI Reply does not come back")
    func completionEmptiesTheField() async throws {
        try await withMountedField(Self.header("field-C", ready: "A ready reply")) { host, controller in
            #expect(Self.fieldTexts(controller.view).contains("A ready reply"), "control: the field starts filled")
            host.clearCount += 1
            try await Self.settle()
            let texts = Self.fieldTexts(controller.view)
            #expect(!texts.isEmpty)
            #expect(texts.allSatisfy { $0.isEmpty }, "the field is empty after the completion: \(texts)")
        }
    }

    @Test("A late AI Reply never replaces words the user typed in the field")
    func lateReplyKeepsTheUsersWords() async throws {
        try await withMountedField(Self.header("field-D", ready: "A ready reply")) { host, controller in
            let words = "My own words"
            #expect(Self.type(words, in: controller.view), "the mounted pill has a native editable field")
            try await Self.settle()
            #expect(Self.fieldTexts(controller.view).contains(words), "control: the edit reached the field")
            host.message.replyTextMessage = "A late AI Reply"
            try await Self.settle()
            let texts = Self.fieldTexts(controller.view)
            #expect(texts.contains(words), "the user's words stay: \(texts)")
            #expect(!texts.contains("A late AI Reply"))
        }
    }

    /// The field's words after a reply arrives while the sheet is open and the sheet closes;
    /// `typed`: words the user typed in the sheet first.
    private func afterTheSheet(typed: String?, uid: String) async throws -> [String] {
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
            #expect(!Self.fieldTexts(controller.view).contains("Yes, Tuesday works for me."), "never into the open sheet")
            host.expanded = false
            try await Task.sleep(for: .milliseconds(600))
            words = Self.fieldTexts(controller.view)
        }
        return words
    }

    @Test("A reply that arrives while the sheet is open fills the untouched field when it closes; words typed there stay")
    func readyReplyFollowsTheSheet() async throws {
        let untouched = try await afterTheSheet(typed: nil, uid: "field-sheet-A")
        #expect(untouched.contains("Yes, Tuesday works for me."), "filled once the sheet closed: \(untouched)")
        let typed = try await afterTheSheet(typed: "My own question", uid: "field-sheet-B")
        #expect(typed.contains("My own question"), "the user's words stay: \(typed)")
        #expect(!typed.contains("Yes, Tuesday works for me."))
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
        let savedOptOut = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        AIService.writeOptOutFlag(false)
        defer {
            AIService.optOutStore.set(savedOptOut, forKey: AIService.optOutAllAIKey)
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
        let start = try #require(text.range(of: "private func sendAgentChat("))
        let send = String(text[start.upperBound...])
        #expect(send.contains("var contextNumericId = await Self.contextNumber(sendingAbout: message, known: contextEmailNumericId)"))
    }

    /// The text from `start` to the next `private func`.
    private static func function(_ start: String, in text: String) throws -> String {
        let begin = try #require(text.range(of: start))
        let rest = text[begin.upperBound...]
        return String(rest[..<(rest.range(of: "private func ")?.lowerBound ?? rest.endIndex)])
    }

    @Test("A sent compose card and an agent answer from the field each empty the field; a cancelled card does not")
    func clearWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(text.components(separatedBy: "clearCount: fieldClearCount").count == 2, "the field gets the count once")
        #expect(text.components(separatedBy: "fieldClearCount += 1").count == 3, "only the two completions")
        let answered = try Self.function("private func agentAnswered() {", in: text)
        #expect(answered.contains("guard !fieldComposeOpened else { return } fieldClearCount += 1"))
        let ended = try Self.function("private func composeEnded(_ outcome: ComposeOutcome, replyTo: MessageHeader?, words: String?) {", in: text)
        #expect(ended.contains("guard sentReplies.composeEnded(outcome, replyTo: replyTo, words: words) else { return }"))
        #expect(ended.components(separatedBy: "fieldClearCount += 1").count == 2, "the field empties only after a send")
    }
}
