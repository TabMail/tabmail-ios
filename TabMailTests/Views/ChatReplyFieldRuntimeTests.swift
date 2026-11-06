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
///     field holds the new email's ready reply.
///  2. A send names the pill's email as the send starts: after the newest email changes, the next
///     request names the new email, never the number found for the earlier one.
///  3. A failed chat request's persistent log keeps the error and never the user's words while
///     debug logging is off, in every failure branch: the words can be the reply field's AI Reply,
///     written from the email, and a resend or rewind replays them. The gate is in
///     `BackgroundSyncLogger.logChatError`, so it covers every caller.
///  4. The pill wires 2 into every send: hosted views cannot be sent from a unit test, so that
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
        init(_ message: MessageHeader) { self.message = message }
    }

    struct HostView: View {
        @Bindable var host: Host
        var body: some View {
            DynamicIslandChat(
                message: host.message, isExpanded: .constant(false), isWorking: .constant(false),
                replyField: ChatReplyField(
                    readyText: ChatReplyField.readyText(newest: host.message, isOwn: false),
                    isNoReply: false, clearCount: 0))
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
}
