/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// iOS #979: words typed in a chat's field and not sent are kept like Messages keeps them.
///
/// THE SYSTEM PROPERTIES pinned here, on the mounted pill:
///  1. Words typed in a thread's field, then left with Back (the screen is torn down), are in the
///     field again when the thread is reopened, also on the thread's newer email.
///  2. A thread's words never show in another thread's field.
///  3. The words are there again in a new app run (a new store on the same database), and an
///     emptied field leaves nothing to bring back.
@Suite("Chat field words kept on Back", .serialized, .processGlobalState)
@MainActor
struct ChatFieldWordsRuntimeTests {

    static func header(_ uid: String, thread: String, account: String = "words") -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Sender", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(), snippet: "", folderId: "\(account):INBOX",
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<\(uid)@example.com>"
        header.computedThreadId = thread
        return header
    }

    struct HostView: View {
        let message: MessageHeader
        @State private var expanded = false
        var body: some View {
            DynamicIslandChat(
                message: message, isExpanded: $expanded,
                replyField: ChatReplyField(example: nil, isNoReply: false, clearCount: 0))
        }
    }

    /// The text of every native editable field under `view`.
    static func fieldTexts(_ view: UIView) -> [String] {
        let own = (view as? UITextView).map { [$0.text ?? ""] } ?? (view as? UITextField).map { [$0.text ?? ""] } ?? []
        return own + view.subviews.flatMap { fieldTexts($0) }
    }

    /// Types `words` into the mounted field the way UIKit reports an edit.
    static func type(_ words: String, in view: UIView) -> Bool {
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

    static func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    /// Opens the pill on `message`, hands its view to `body`, then leaves the screen: the window
    /// and the hosting controller go, so every view state goes with them, as on Back.
    static func open(_ message: MessageHeader, _ body: @MainActor (UIView) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var window: UIWindow? = UIWindow(windowScene: scene)
        window?.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        var controller: UIHostingController<HostView>? = UIHostingController(rootView: HostView(message: message))
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        try await settle()
        if let view = controller?.view { try await body(view) }
        window?.isHidden = true
        window?.rootViewController = nil
        controller = nil
        window = nil
        try await settle()
    }

    /// One installed database for the whole test, as one app run has.
    static func withDatabase(_ body: @MainActor () async throws -> Void) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        ChatPillState.shared.removeAllSessions()
        // A new app run's store: nothing in memory from an earlier test.
        ChatFieldWords.shared = ChatFieldWords()
        defer { ChatPillState.shared.removeAllSessions() }
        try await body()
        await ChatFieldWords.shared.written()
    }

    @Test("Words typed in a chat's field are there again after Back, also on the thread's newer email")
    func wordsSurviveBack() async throws {
        try await Self.withDatabase {
            let words = "Sounds good, see you Tuesday"
            try await Self.open(Self.header("back-1", thread: "back-thread")) { view in
                #expect(Self.fieldTexts(view).allSatisfy { $0.isEmpty }, "control: the field starts empty")
                #expect(Self.type(words, in: view), "the mounted pill has a native editable field")
                try await Self.settle()
                #expect(Self.fieldTexts(view).contains(words), "control: the edit reached the field")
            }
            try await Self.open(Self.header("back-1", thread: "back-thread")) { view in
                #expect(Self.fieldTexts(view).contains(words), "the words are back after Back: \(Self.fieldTexts(view))")
            }
            // A newer email arrived in the thread: the chat is on it now, and the words stay.
            try await Self.open(Self.header("back-2", thread: "back-thread")) { view in
                #expect(Self.fieldTexts(view).contains(words), "the thread's newer email keeps them: \(Self.fieldTexts(view))")
            }
        }
    }

    @Test("A thread's words never show in another thread's field")
    func wordsStayInTheirThread() async throws {
        try await Self.withDatabase {
            let words = "Only for the first thread"
            try await Self.open(Self.header("key-1", thread: "key-thread-A")) { view in
                #expect(Self.type(words, in: view), "the mounted pill has a native editable field")
                try await Self.settle()
                #expect(Self.fieldTexts(view).contains(words), "control: the edit reached the field")
            }
            try await Self.open(Self.header("key-2", thread: "key-thread-B")) { view in
                let texts = Self.fieldTexts(view)
                #expect(!texts.isEmpty, "control: the other thread's pill has a field")
                #expect(texts.allSatisfy { !$0.contains(words) }, "another thread's field: \(texts)")
            }
            // The same thread in another account is another thread.
            try await Self.open(Self.header("key-1", thread: "key-thread-A", account: "words-other")) { view in
                let texts = Self.fieldTexts(view)
                #expect(texts.allSatisfy { !$0.contains(words) }, "another account's thread: \(texts)")
            }
        }
    }

    @Test("Words typed in a chat's field are there again after the app was closed and opened")
    func wordsSurviveARestart() async throws {
        try await Self.withDatabase {
            let words = "Kept across a restart"
            try await Self.open(Self.header("restart-1", thread: "restart-thread")) { view in
                #expect(Self.type(words, in: view), "the mounted pill has a native editable field")
                try await Self.settle()
            }
            // The app ends: its writes are done, and the next run starts with nothing in memory.
            await ChatFieldWords.shared.written()
            ChatFieldWords.shared = ChatFieldWords()
            ChatPillState.shared.removeAllSessions()
            try await Self.open(Self.header("restart-1", thread: "restart-thread")) { view in
                #expect(Self.fieldTexts(view).contains(words), "the next run's field has them: \(Self.fieldTexts(view))")
            }
        }
    }

    @Test("A field the user emptied is empty when the chat is reopened, in this run and the next")
    func emptiedFieldStaysEmpty() async throws {
        try await Self.withDatabase {
            let header = Self.header("empty-1", thread: "empty-thread")
            try await Self.open(header) { view in
                #expect(Self.type("Words to take back", in: view))
                try await Self.settle()
                #expect(Self.type("", in: view))
                try await Self.settle()
            }
            try await Self.open(header) { view in
                #expect(Self.fieldTexts(view).allSatisfy { $0.isEmpty }, "\(Self.fieldTexts(view))")
            }
            await ChatFieldWords.shared.written()
            ChatFieldWords.shared = ChatFieldWords()
            try await Self.open(header) { view in
                #expect(Self.fieldTexts(view).allSatisfy { $0.isEmpty }, "the next run: \(Self.fieldTexts(view))")
            }
        }
    }
}
