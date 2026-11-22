/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation
import Synchronization
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
///  4. Two pills on one chat (the chat view's field and the email card's pill over it) show and
///     change ONE draft: what is typed, emptied or sent in one is what the other shows.
///  5. The user's saved words survive a read of them that fails or is left (Back while it runs):
///     they are there on the next open.
///  6. What the user does before a chat's saved words are read is what the chat keeps, and a pill
///     moving to another email of another chat keeps each chat's words on its own.
///  7. The email screen's pill (no reply field) keeps its chat's words too; the inbox's chat keeps
///     none. A demo's words stay in the demo and go with it.
///  8. Words typed in a chat pushed inside a sheet, as Search opens chats, survive the sheet's
///     dismissal, by its own dismiss and by a UIKit programmatic teardown, and are in the field
///     when the chat opens again, in this run and the next.
///  9. A request from the field transitions the words of the chat it was SENT from: an earlier
///     request's card and answer, landing after the pill moved to another chat, leave that chat's
///     unsent words in the field, in storage and in a new run; an answer that lands after the chat
///     was torn down still empties the words sent, so they never return on reopen; newer words
///     typed while the agent works stay.
/// 10. A field request whose agent opens a compose (reply, compose or forward): newer words typed
///     while it runs survive the compose's Send AND the request's closing answer after it, in the
///     field, on reopen and in a new run; with no newer words, the compose's Send empties the words
///     sent. A compose from a request sent elsewhere (no field key) never touches the typed words.
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

    /// A pill whose email and openness the test changes.
    @Observable final class Host {
        var message: MessageHeader?
        var expanded: Bool
        init(_ message: MessageHeader?, expanded: Bool = false) {
            self.message = message
            self.expanded = expanded
        }
    }

    /// The chat view's pill (`replyField`), else the email screen's (or, with no email, the inbox's).
    struct PillView: View {
        @Bindable var host: Host
        let replyField: Bool
        /// The AI Suggestion the reply field shows (`ChatReplyField.suggestion`); nil: none.
        var suggestion: ReplyResult? = nil
        var body: some View {
            DynamicIslandChat(
                message: host.message, isExpanded: $host.expanded,
                replyField: replyField ? ChatReplyField(example: nil, isNoReply: false, suggestion: suggestion) : nil)
            .environment(\.hasTabMailSession, true)
        }
    }

    /// A mounted pill: its view, and `close` for Back.
    @MainActor
    final class Mounted {
        private var window: UIWindow?
        let view: UIView
        init(window: UIWindow, view: UIView) {
            self.window = window
            self.view = view
        }

        func close() {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }
    }

    /// Mounts `root` in its own window; several can be mounted at once, one over the other.
    static func mount<V: View>(_ root: V) async throws -> Mounted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // An open pill takes its spring to show its field.
        try await Task.sleep(for: .milliseconds(600))
        return Mounted(window: window, view: controller.view)
    }

    struct HostView: View {
        let message: MessageHeader
        @State private var expanded = false
        var body: some View {
            DynamicIslandChat(
                message: message, isExpanded: $expanded,
                replyField: ChatReplyField(example: nil, isNoReply: false))
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
    static func withDatabase(_ body: @MainActor (DatabasePool) async throws -> Void) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        // A chat's words are written only while its account row exists (`Storage.admits`): the
        // account every test types in (`header`) is set up once here, as its setup does.
        _ = try FolderEpochTestFixture.makeAccount(id: "words", provider: .imap, pool: pool)
        ChatPillState.shared.removeAllSessions()
        // A new app run's store: nothing in memory from an earlier test.
        ChatFieldWords.shared = ChatFieldWords()
        defer {
            ChatPillState.shared.removeAllSessions()
            ChatFieldWords.shared = ChatFieldWords()
        }
        try await body(pool)
        await ChatFieldWords.shared.written()
    }

    /// The kept words, by chat key.
    static func stored(_ pool: DatabasePool) throws -> [String: String] {
        let rows = try pool.read { try ChatFieldWordsRecord.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0.words) })
    }

    /// A second pool on the test database with a single reader, so a test can hold the store's
    /// reads (`DatabaseReaderGate`) while the pill is open.
    static func singleReaderPool(_ pool: DatabasePool) throws -> DatabasePool {
        var config = Configuration()
        config.maximumReaderCount = 1
        config.busyMode = .timeout(5)
        return try DatabasePool(path: pool.path, configuration: config)
    }

    /// A new app run whose store reads and writes through `database`.
    static func newRun(_ database: @escaping @Sendable () -> PrioritizedDatabase) async {
        await ChatFieldWords.shared.written()
        ChatFieldWords.shared = ChatFieldWords(database: database)
        ChatPillState.shared.removeAllSessions()
    }

    /// Saves `words` in the field of `message`'s chat, as an earlier app run did.
    static func save(_ words: String, on message: MessageHeader) async throws {
        try await open(message) { view in
            #expect(type(words, in: view), "the mounted pill has a native editable field")
            try await settle()
        }
        await ChatFieldWords.shared.written()
    }

    @Test("Words typed in a chat's field are there again after Back, also on the thread's newer email")
    func wordsSurviveBack() async throws {
        try await Self.withDatabase { _ in
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
        try await Self.withDatabase { _ in
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
        try await Self.withDatabase { _ in
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
        try await Self.withDatabase { _ in
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

    // MARK: - 4. Two pills on one chat

    @Test("The chat view's field and the email card's pill over it show and change one draft")
    func twoPillsShareOneDraft() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation {
            try await Self.withDatabase { pool in
                try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
                let email = Self.header("two-1", thread: "two-thread")
                try await pool.write { try email.insert($0) }
                let key = ChatFieldWords.key(for: email)
                let backend = ThreadChatTests.Backend()
                try await ThreadChatTests.withBackend(backend, chatView: true) {
                    let field = try await Self.mount(PillView(host: Host(email), replyField: true))
                    defer { field.close() }
                    let card = try await Self.mount(PillView(host: Host(email, expanded: true), replyField: false))

                    #expect(Self.type("Typed in the field", in: field.view))
                    try await Self.settle()
                    #expect(Self.fieldTexts(card.view).contains("Typed in the field"), "the card shows the field's words: \(Self.fieldTexts(card.view))")

                    #expect(Self.type("Changed on the card", in: card.view))
                    try await Self.settle()
                    #expect(Self.fieldTexts(field.view).contains("Changed on the card"), "the field shows the card's: \(Self.fieldTexts(field.view))")

                    #expect(Self.type("", in: card.view))
                    try await Self.settle()
                    #expect(Self.fieldTexts(field.view).allSatisfy { $0.isEmpty }, "emptied on the card, empty in the field: \(Self.fieldTexts(field.view))")

                    // A send from the card: its words went, from both pills and from storage.
                    #expect(Self.type("Ask about the date", in: card.view))
                    try await Self.settle()
                    #expect(HostedAccessibility.activate("chatSend", in: card.view),
                            "the card's Send takes a tap: \(HostedAccessibility.identifiers(in: card.view))")
                    try await ThreadChatTests.wait { backend.bodies.count == 1 }
                    #expect(backend.bodies.count == 1, "control: the question went to the backend")
                    try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                    try await Self.settle()
                    #expect(Self.fieldTexts(field.view).allSatisfy { !$0.contains("Ask about the date") },
                            "the sent words are not in the field: \(Self.fieldTexts(field.view))")
                    await ChatFieldWords.shared.written()
                    let stored1 = try Self.stored(pool)
                    #expect(stored1[key] == nil, "nor kept")

                    // The card closes with words typed on it: the field shows them.
                    #expect(Self.type("Typed last, on the card", in: card.view))
                    try await Self.settle()
                    card.close()
                    try await Self.settle()
                    #expect(Self.fieldTexts(field.view).contains("Typed last, on the card"), "\(Self.fieldTexts(field.view))")
                    await ChatFieldWords.shared.written()
                    let stored2 = try Self.stored(pool)
                    #expect(stored2 == [key: "Typed last, on the card"])
                }
            }
        }
    }

    // MARK: - 5. A failed or left read keeps the saved words

    @Test("Saved words survive a read of them that fails: they are there on the next open")
    func failedReadKeepsSavedWords() async throws {
        try await Self.withDatabase { pool in
            let email = Self.header("fail-1", thread: "fail-thread")
            try await Self.save("Words worth keeping", on: email)

            // A new run whose first reads fail: the database they read has no such table.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-words-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let broken = try DatabasePool(path: directory.appendingPathComponent("broken.sqlite").path)
            let failing = Failing()
            await Self.newRun { failing.isOn ? PrioritizedDatabase(pool: broken) : PrioritizedDatabase(pool: pool) }
            try await Self.open(email) { _ in }
            failing.turnOff()

            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains("Words worth keeping"), "the next open shows them: \(Self.fieldTexts(view))")
            }
            await Self.newRun { PrioritizedDatabase(pool: pool) }
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains("Words worth keeping"), "and the next run's: \(Self.fieldTexts(view))")
            }
        }
    }

    /// Whether the store's reads still fail.
    final class Failing: Sendable {
        private let on = Mutex(true)
        var isOn: Bool { on.withLock { $0 } }
        func turnOff() { on.withLock { $0 = false } }
    }

    @Test("Saved words survive Back while their read runs: they are there on the next open")
    func leftReadKeepsSavedWords() async throws {
        try await Self.withDatabase { pool in
            let email = Self.header("left-1", thread: "left-thread")
            try await Self.save("Words worth keeping", on: email)

            let single = try Self.singleReaderPool(pool)
            await Self.newRun { PrioritizedDatabase(pool: single) }
            let gate = DatabaseReaderGate(single)
            #expect(await gate.waitUntilHeld(), "control: the reads are held")
            // Back while the chat's read waits.
            try await Self.open(email) { _ in }
            await gate.release()
            try await Self.settle()

            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains("Words worth keeping"), "the next open shows them: \(Self.fieldTexts(view))")
            }
            await ChatFieldWords.shared.written()
            let stored3 = try Self.stored(pool)
            #expect(stored3 == [ChatFieldWords.key(for: email): "Words worth keeping"])
        }
    }

    // MARK: - 6. Newer intention, and a pill moving between chats

    @Test("A field emptied before the chat's saved words were read stays empty")
    func emptiedBeforeTheReadStaysEmpty() async throws {
        try await Self.withDatabase { pool in
            let email = Self.header("hold-1", thread: "hold-thread")
            try await Self.save("Older words", on: email)

            let single = try Self.singleReaderPool(pool)
            await Self.newRun { PrioritizedDatabase(pool: single) }
            let gate = DatabaseReaderGate(single)
            #expect(await gate.waitUntilHeld(), "control: the reads are held")
            try await Self.open(email) { view in
                #expect(Self.type("x", in: view))
                try await Self.settle()
                #expect(Self.type("", in: view))
                try await Self.settle()
                await gate.release()
                try await Self.settle()
                #expect(Self.fieldTexts(view).allSatisfy { $0.isEmpty }, "the user's emptying stays: \(Self.fieldTexts(view))")
            }
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).allSatisfy { $0.isEmpty }, "and is what is kept: \(Self.fieldTexts(view))")
            }
            await ChatFieldWords.shared.written()
            let stored4 = try Self.stored(pool)
            #expect(stored4.isEmpty)
        }
    }

    @Test("A pill moving to another chat's email while a read runs: each chat keeps only its own words",
          arguments: [false, true])
    func switchingChatsKeepsEachChatsWords(bothReadsHeld: Bool) async throws {
        try await Self.withDatabase { pool in
            let first = Self.header("sw-1", thread: "switch-A")
            let second = Self.header("sw-2", thread: "switch-B")
            try await Self.save("Words for A", on: first)

            let single = try Self.singleReaderPool(pool)
            await Self.newRun { PrioritizedDatabase(pool: single) }
            let host = Host(first)
            var gate: DatabaseReaderGate?
            if bothReadsHeld {
                gate = DatabaseReaderGate(single)
            }
            let pill = try await Self.mount(PillView(host: host, replyField: true))
            defer { pill.close() }
            if !bothReadsHeld {
                #expect(Self.fieldTexts(pill.view).contains("Words for A"), "control: A's words read: \(Self.fieldTexts(pill.view))")
                gate = DatabaseReaderGate(single)
            }
            let held = try #require(gate)
            #expect(await held.waitUntilHeld(), "control: the reads are held")

            host.message = second
            try await Self.settle()
            #expect(Self.type("Words for B", in: pill.view))
            try await Self.settle()
            await held.release()
            try await Self.settle()
            #expect(Self.fieldTexts(pill.view).contains("Words for B") && !Self.fieldTexts(pill.view).contains("Words for A"),
                    "B keeps the words typed on it: \(Self.fieldTexts(pill.view))")

            host.message = first
            try await Self.settle()
            #expect(Self.fieldTexts(pill.view).contains("Words for A") && !Self.fieldTexts(pill.view).contains("Words for B"),
                    "A keeps its own: \(Self.fieldTexts(pill.view))")
            await ChatFieldWords.shared.written()
            let stored5 = try Self.stored(pool)
            #expect(stored5 == [ChatFieldWords.key(for: first): "Words for A", ChatFieldWords.key(for: second): "Words for B"])
        }
    }

    // MARK: - 9. A request's card and completion land on the chat it was sent from

    @Test("An earlier request's card and answer, landing after the pill moved to another chat, never touch that chat's unsent words")
    func olderRequestNeverClearsAnotherChatsWords() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted buttons")
        try await HostedAccessibility.withAutomation { try await olderRequestNeverClearsAnotherChatsWordsBody() }
    }

    private func olderRequestNeverClearsAnotherChatsWordsBody() async throws {
        let (pool, directory, previous) = try ThreadChatTests.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        ChatFieldWords.shared = ChatFieldWords()
        defer { ChatFieldWords.shared = ChatFieldWords() }
        let templateName = "Field words card \(UUID().uuidString.prefix(8))"
        defer {
            if let made = PromptStore.shared.templates.first(where: { $0.name == templateName }) {
                PromptStore.shared.deleteTemplate(id: made.id)
            }
        }
        // Two chats: A's email in one account and thread, B's in another (its own chat key).
        let first = ThreadChatTests.header("301", from: "Ann Example", rfc: "words-1@example.com",
                                           thread: "words-thread-a", minutesAgo: 30)
        let newer = ThreadChatTests.header(
            "302", account: ThreadChatTests.accountB, from: "Bea Example", rfc: "words-2@example.com",
            inReplyTo: "words-1@example.com", thread: "words-2@example.com", minutesAgo: 1)
        let keyA = ChatFieldWords.key(for: first)
        let keyB = ChatFieldWords.key(for: newer)
        #expect(keyA != keyB, "control: two chats")
        try ThreadChatTests.insert(first, pool: pool)
        // B has unsent words of its own, kept on the device.
        let wordsB = "Words for B, not sent"
        ChatFieldWords.shared.apply(.put(wordsB), to: keyB)
        await ChatFieldWords.shared.written()
        let backend = ThreadChatTests.Backend(cardWords: "Make it a template", templateName: templateName, hold: true)
        try await ThreadChatTests.withBackend(backend, chatView: true) {
            let host = Host(first)
            let pill = try await Self.mount(PillView(host: host, replyField: true))
            defer { pill.close() }
            // A's request goes out from the collapsed field; its words stay, pulsing.
            try await ThreadChatTests.ask("Make it a template", in: pill.view, backend: backend, answered: false)
            let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
            #expect(asked, "control: A's request reached the backend")
            // The pill moves to B while A's request runs.
            try ThreadChatTests.insert(newer, pool: pool)
            host.message = newer
            try await Self.settle()
            #expect(Self.fieldTexts(pill.view).contains(wordsB), "control: the field shows B's words: \(Self.fieldTexts(pill.view))")

            // A's card arrives, then Create lets A's request answer.
            backend.proceed.signal()
            try await ThreadChatTests.wait { ThreadChatTests.shows("Create", in: pill.view) }
            #expect(host.expanded, "control: the card opens the sheet on the shown chat")
            #expect(ChatFieldWords.shared.fill(for: keyB).words == wordsB, "A's card left B's words")
            let create = HostedAccessibility.elements(under: pill.view).first { $0.accessibilityLabel == "Create" }
            #expect(create?.accessibilityActivate() == true, "Create takes a tap")
            try await ThreadChatTests.wait { backend.bodies.count == 2 && !ActiveAgentTracker.shared.anyWorking }
            #expect(backend.bodies.count == 2, "control: A's request went on and answered")
            host.expanded = false
            try await Task.sleep(for: .milliseconds(600))

            #expect(Self.fieldTexts(pill.view).contains(wordsB), "B's field still holds B's words: \(Self.fieldTexts(pill.view))")
            #expect(ChatFieldWords.shared.fill(for: keyA).words.isEmpty, "A's sent words finished: the card and answer emptied them")
            await ChatFieldWords.shared.written()
            let stored = try Self.stored(pool)
            #expect(stored == [keyB: wordsB], "only B's words are kept: \(stored)")
        }
        // A fresh store, as the next app run: B's words come back, A's sent words do not.
        await Self.newRun { PrioritizedDatabase(pool: pool) }
        await ChatFieldWords.shared.load(keyB)
        await ChatFieldWords.shared.load(keyA)
        #expect(ChatFieldWords.shared.fill(for: keyB).words == wordsB, "the next run shows B's words")
        #expect(ChatFieldWords.shared.fill(for: keyA).words.isEmpty, "and none of A's")
    }

    /// How the field's send ends in `completionLandsOnTheSendsChat`.
    enum SendEnd: String, CaseIterable, CustomTestStringConvertible {
        /// Same chat, same screen: the answer empties the words sent.
        case answered
        /// Same chat: newer words typed while the agent works stay after its answer.
        case newerWordsTyped
        /// Back tears the chat down before the answer; the chat opens again after it.
        case backBeforeTheAnswer
        var testDescription: String { rawValue }
    }

    @Test("A field send's answer empties only the words sent, on its own chat, also when the chat was closed before the answer",
          arguments: SendEnd.allCases)
    func completionLandsOnTheSendsChat(_ end: SendEnd) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await completionLandsOnTheSendsChatBody(end) }
    }

    private func completionLandsOnTheSendsChatBody(_ end: SendEnd) async throws {
        try await Self.withDatabase { pool in
            try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
            let email = Self.header("done-\(end.rawValue)", thread: "done-thread-\(end.rawValue)")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let sent = "When is the meeting"
            let newerWords = "Also ask about lunch"
            let backend = ThreadChatTests.Backend(holdAnswers: true)
            try await ThreadChatTests.withBackend(backend, chatView: true) {
                let host = Host(email)
                let pill = try await Self.mount(PillView(host: host, replyField: true))
                var closed = false
                defer { if !closed { pill.close() } }
                try await ThreadChatTests.ask(sent, in: pill.view, backend: backend, answered: false)
                let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
                #expect(asked, "control: the request reached the backend")
                #expect(ChatFieldWords.shared.fill(for: key).words == sent, "control: the sent words stay while it works")
                switch end {
                case .answered:
                    break
                case .newerWordsTyped:
                    // The user opens the chat and writes more while the agent works.
                    host.expanded = true
                    try await Task.sleep(for: .milliseconds(600))
                    #expect(Self.type(newerWords, in: pill.view), "the open sheet has a native editable field")
                    try await Self.settle()
                    host.expanded = false
                    try await Task.sleep(for: .milliseconds(600))
                case .backBeforeTheAnswer:
                    pill.close()
                    closed = true
                    try await Self.settle()
                }
                backend.proceed.signal()
                try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                try await Self.settle()
                let expected = end == .newerWordsTyped ? newerWords : ""
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "the answer emptied only the words sent: \(ChatFieldWords.shared.fill(for: key).words)")
                if !closed {
                    let texts = Self.fieldTexts(pill.view)
                    #expect(!texts.contains(sent), "the sent words left the field: \(texts)")
                    #expect(end != .newerWordsTyped || texts.contains(newerWords), "newer words stay: \(texts)")
                }
            }
            try await Self.open(email) { view in
                let texts = Self.fieldTexts(view)
                #expect(!texts.contains(sent), "the sent words never come back on reopen: \(texts)")
                #expect(end != .newerWordsTyped || texts.contains(newerWords), "newer words are there: \(texts)")
            }
            await ChatFieldWords.shared.written()
            let stored = try Self.stored(pool)
            #expect(stored == (end == .newerWordsTyped ? [key: newerWords] : [:]), "\(stored)")
            await Self.newRun { PrioritizedDatabase(pool: pool) }
            await ChatFieldWords.shared.load(key)
            #expect(!ChatFieldWords.shared.fill(for: key).words.contains(sent), "nor in the next run")
        }
    }

    /// How the field's request ends in `retypedSentWordsAreNewWords`.
    enum RetypeEnd: String, CaseIterable, CustomTestStringConvertible {
        /// The agent answers the request.
        case answer
        /// The request's compose card goes out, then its closing answer.
        case card
        var testDescription: String { rawValue }
    }

    @Test("Words cleared and retyped to the sent text while the request runs are new: they survive its answer and card, Back/reopen and a fresh store; unchanged sent words go",
          arguments: RetypeEnd.allCases, [true, false])
    func retypedSentWordsAreNewWords(_ end: RetypeEnd, _ retyped: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await retypedSentWordsBody(end, retyped) }
    }

    private func retypedSentWordsBody(_ end: RetypeEnd, _ retyped: Bool) async throws {
        try await Self.withDatabase { pool in
            try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
            let tag = "\(end.rawValue)-\(retyped)"
            let email = Self.header("retype-\(tag)", thread: "retype-thread-\(tag)")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let sent = "Reply that Friday works"
            let expected = retyped ? sent : ""
            let backend = ThreadChatTests.Backend(holdAnswers: true)
            try await ThreadChatTests.withBackend(backend, chatView: true) {
                let host = Host(email)
                let pill = try await Self.mount(PillView(host: host, replyField: true))
                defer { pill.close() }
                try await ThreadChatTests.ask(sent, in: pill.view, backend: backend, answered: false)
                let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
                #expect(asked, "control: the request reached the backend")
                #expect(ChatFieldWords.shared.fill(for: key).unsent == "", "control: sent words are not kept")
                if retyped {
                    // The user opens the chat, clears the field and types the same words again.
                    host.expanded = true
                    try await Task.sleep(for: .milliseconds(600))
                    #expect(Self.type("", in: pill.view), "the open sheet has a native editable field")
                    try await Self.settle()
                    #expect(Self.type(sent, in: pill.view))
                    try await Self.settle()
                    host.expanded = false
                    try await Task.sleep(for: .milliseconds(600))
                    #expect(ChatFieldWords.shared.fill(for: key).unsent == sent, "the retyped words are kept")
                }
                if end == .card {
                    let result = try await Self.sendCompose(.reply, Self.invocation(.fieldUnchanged, email: email),
                                                            email: email, pool: pool)
                    #expect(result.contains("sent successfully"), "control: the compose went out: \(result)")
                    #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                            "after the card: \(ChatFieldWords.shared.fill(for: key).words)")
                }
                backend.proceed.signal()
                try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                try await Self.settle()
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after the answer: \(ChatFieldWords.shared.fill(for: key).words)")
            }
            try await Self.open(email) { view in
                let texts = Self.fieldTexts(view)
                #expect(texts.contains(sent) == retyped, "reopen: \(texts)")
            }
            await ChatFieldWords.shared.written()
            let stored = try Self.stored(pool)
            #expect(stored == (retyped ? [key: sent] : [:]), "\(stored)")
            await Self.newRun { PrioritizedDatabase(pool: pool) }
            await ChatFieldWords.shared.load(key)
            #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                    "a fresh store: \(ChatFieldWords.shared.fill(for: key).words)")
        }
    }

    // MARK: - 10. A field request's compose, sent, then the request's closing answer

    /// The agent tool that opens the compose for the field's request.
    enum ComposeProducer: String, CaseIterable, CustomTestStringConvertible {
        case reply, compose, forward
        var testDescription: String { rawValue }

        /// Runs the producer's real tool on `email` (numeric id 1), with `invocation`.
        @MainActor
        func run(_ invocation: ToolInvocation, context: ToolContext) async throws -> String {
            let to = JSONValue.array([.string("someone@example.com")])
            switch self {
            case .reply:
                return try await EmailReplyTool(context: context).execute(
                    arguments: ["unique_id": .int(1), "body": .string("Friday works")], invocation: invocation)
            case .compose:
                return try await EmailComposeTool(context: context).execute(
                    arguments: ["to": to, "subject": .string("Plans"), "body": .string("Friday works")], invocation: invocation)
            case .forward:
                return try await EmailForwardTool(context: context).execute(
                    arguments: ["unique_id": .int(1), "to": to, "body": .string("FYI")], invocation: invocation)
            }
        }
    }

    /// Who sent the request whose compose goes out.
    enum ComposeOrigin: String, CaseIterable, CustomTestStringConvertible {
        /// Sent from the collapsed field; newer words typed in the open sheet while it runs.
        case fieldWithNewerWords
        /// Sent from the collapsed field; nothing typed since.
        case fieldUnchanged
        /// Control: a request sent from elsewhere (no field key); words typed in the sheet.
        case sheet
        var testDescription: String { rawValue }
    }

    /// The invocation the field's send builds for `email` (`DynamicIslandChat.sendAgentChat`), or, from
    /// elsewhere, none of the field's.
    static func invocation(_ origin: ComposeOrigin, email: MessageHeader, suggestion: ReplyResult? = nil) -> ToolInvocation {
        guard origin != .sheet else { return ToolInvocation() }
        return ToolInvocation(fieldReply: ChatFieldReply(email: email, onlyTo: nil, suggestion: suggestion),
                              fieldWordsKey: ChatFieldWords.key(for: email))
    }

    /// Runs `producer`'s tool with `invocation` on a router of its own (no view presents the compose)
    /// and presses its Send: the compose's `.sent` outcome, or closes it with `outcome`. Returns the
    /// tool's result.
    static func sendCompose(_ producer: ComposeProducer, _ invocation: ToolInvocation, email: MessageHeader,
                            pool: DatabasePool, outcome: ComposeOutcome = .sent) async throws -> String {
        let translator = MockChatIdTranslator()
        await translator.seed(email.id, as: 1)
        let router = AgentToolRouter()
        let context = ToolContext(db: pool, translator: translator, router: router)
        let task = Task { @MainActor in try await producer.run(invocation, context: context) }
        try await ThreadChatTests.wait { router.pendingCompose != nil }
        let request = try #require(router.pendingCompose, "control: \(producer) opened its compose")
        request.onOutcome(outcome)
        return try await task.value
    }

    @Test("A field request's compose, sent, then its closing answer: newer words stay; with none, the sent words go; a request from elsewhere keeps the typed words",
          arguments: ComposeProducer.allCases, ComposeOrigin.allCases)
    func composeSendThenAnswerKeepsNewerWords(_ producer: ComposeProducer, _ origin: ComposeOrigin) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await composeSendThenAnswerBody(producer, origin) }
    }

    private func composeSendThenAnswerBody(_ producer: ComposeProducer, _ origin: ComposeOrigin) async throws {
        try await Self.withDatabase { pool in
            try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
            let tag = "\(producer.rawValue)-\(origin.rawValue)"
            let email = Self.header("compose-\(tag)", thread: "compose-thread-\(tag)")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let sent = "Reply that Friday works"
            let newerWords = "Also ask about lunch"
            let backend = ThreadChatTests.Backend(holdAnswers: true)
            try await ThreadChatTests.withBackend(backend, chatView: true) {
                let host = Host(email)
                let pill = try await Self.mount(PillView(host: host, replyField: true))
                defer { pill.close() }
                if origin != .sheet {
                    try await ThreadChatTests.ask(sent, in: pill.view, backend: backend, answered: false)
                    let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
                    #expect(asked, "control: the request reached the backend")
                    #expect(ChatFieldWords.shared.fill(for: key).words == sent, "control: the sent words stay while it works")
                }
                if origin != .fieldUnchanged {
                    // The user opens the chat and writes more while the agent works.
                    host.expanded = true
                    try await Task.sleep(for: .milliseconds(600))
                    #expect(Self.type(newerWords, in: pill.view), "the open sheet has a native editable field")
                    try await Self.settle()
                    host.expanded = false
                    try await Task.sleep(for: .milliseconds(600))
                }
                let expected = origin == .fieldUnchanged ? "" : newerWords

                // The agent's compose opens and the user presses its Send.
                let result = try await Self.sendCompose(producer, Self.invocation(origin, email: email), email: email, pool: pool)
                #expect(result.contains("sent successfully"), "control: the compose went out: \(result)")
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after the compose's Send: \(ChatFieldWords.shared.fill(for: key).words)")

                // The request's closing answer arrives after the compose went out.
                if origin != .sheet {
                    backend.proceed.signal()
                    try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                    try await Self.settle()
                }
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after the closing answer: \(ChatFieldWords.shared.fill(for: key).words)")
                let texts = Self.fieldTexts(pill.view)
                #expect(!texts.contains(sent), "the sent words left the field: \(texts)")
                #expect(expected.isEmpty || texts.contains(expected), "newer words stay in the field: \(texts)")
            }
            try await Self.open(email) { view in
                let texts = Self.fieldTexts(view)
                #expect(!texts.contains(sent), "the sent words never come back on reopen: \(texts)")
                #expect(origin == .fieldUnchanged || texts.contains(newerWords), "newer words are there on reopen: \(texts)")
            }
            await ChatFieldWords.shared.written()
            let stored = try Self.stored(pool)
            #expect(stored == (origin == .fieldUnchanged ? [:] : [key: newerWords]), "\(stored)")
            await Self.newRun { PrioritizedDatabase(pool: pool) }
            await ChatFieldWords.shared.load(key)
            #expect(ChatFieldWords.shared.fill(for: key).words == (origin == .fieldUnchanged ? "" : newerWords),
                    "a fresh store: \(ChatFieldWords.shared.fill(for: key).words)")
        }
    }

    /// What follows a field request's first compose Send, in the same request (same invocation).
    enum SameRequestFollowUp: String, CaseIterable, CustomTestStringConvertible {
        /// The request's second compose (another email), sent.
        case secondComposeSent
        /// A later confirmation card (an archive, a template) of the same request.
        case confirmationCard
        var testDescription: String { rawValue }
    }

    @Test("A field request's later compose Send or confirmation card, after its first compose went out, keeps newer words; unchanged sent words still go",
          arguments: SameRequestFollowUp.allCases, [ComposeOrigin.fieldWithNewerWords, .fieldUnchanged])
    func sameRequestFollowUpKeepsNewerWords(_ followUp: SameRequestFollowUp, _ origin: ComposeOrigin) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can type into the hosted field")
        try await HostedAccessibility.withAutomation { try await sameRequestFollowUpBody(followUp, origin) }
    }

    private func sameRequestFollowUpBody(_ followUp: SameRequestFollowUp, _ origin: ComposeOrigin) async throws {
        try await Self.withDatabase { pool in
            try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
            let tag = "\(followUp.rawValue)-\(origin.rawValue)"
            let email = Self.header("follow-\(tag)", thread: "follow-thread-\(tag)")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let sent = "Reply that Friday works and archive the rest"
            let newerWords = "Also ask about lunch"
            let expected = origin == .fieldUnchanged ? "" : newerWords
            // One invocation for the whole request: every tool round carries the same field key.
            let invocation = Self.invocation(origin, email: email)
            let backend = ThreadChatTests.Backend(holdAnswers: true)
            try await ThreadChatTests.withBackend(backend, chatView: true) {
                let host = Host(email)
                let pill = try await Self.mount(PillView(host: host, replyField: true))
                defer { pill.close() }
                try await ThreadChatTests.ask(sent, in: pill.view, backend: backend, answered: false)
                let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
                #expect(asked, "control: the request reached the backend")
                if origin == .fieldWithNewerWords {
                    host.expanded = true
                    try await Task.sleep(for: .milliseconds(600))
                    #expect(Self.type(newerWords, in: pill.view), "the open sheet has a native editable field")
                    try await Self.settle()
                    host.expanded = false
                    try await Task.sleep(for: .milliseconds(600))
                }

                // The request's first compose goes out.
                let first = try await Self.sendCompose(.reply, invocation, email: email, pool: pool)
                #expect(first.contains("sent successfully"), "control: the first compose went out: \(first)")
                #expect(ChatFieldWords.shared.fill(for: key).words == expected, "after the first Send")

                // The same request goes on.
                switch followUp {
                case .secondComposeSent:
                    let second = try await Self.sendCompose(.compose, invocation, email: email, pool: pool)
                    #expect(second.contains("sent successfully"), "control: the second compose went out: \(second)")
                case .confirmationCard:
                    let session = ChatPillState.shared.session(for: ChatThreadKey.key(for: email))
                    let card = AgentToolRouter.ActionConfirmation(
                        action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [], onRespond: { _ in })
                    SessionUISink(session: session, fieldWordsKey: invocation.fieldWordsKey).deliverConfirmation(card)
                }
                try await Self.settle()
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after the follow-up: \(ChatFieldWords.shared.fill(for: key).words)")

                backend.proceed.signal()
                try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                try await Self.settle()
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after the closing answer: \(ChatFieldWords.shared.fill(for: key).words)")
                let texts = Self.fieldTexts(pill.view)
                #expect(!texts.contains(sent), "the sent words left the field: \(texts)")
                #expect(expected.isEmpty || texts.contains(expected), "newer words stay in the mounted field: \(texts)")
            }
            try await Self.open(email) { view in
                let texts = Self.fieldTexts(view)
                #expect(!texts.contains(sent), "the sent words never come back on reopen: \(texts)")
                #expect(expected.isEmpty || texts.contains(expected), "newer words are there on reopen: \(texts)")
            }
            await ChatFieldWords.shared.written()
            let stored = try Self.stored(pool)
            #expect(stored == (expected.isEmpty ? [:] : [key: expected]), "\(stored)")
            await Self.newRun { PrioritizedDatabase(pool: pool) }
            await ChatFieldWords.shared.load(key)
            #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                    "a fresh store: \(ChatFieldWords.shared.fill(for: key).words)")
        }
    }

    /// What the field request does before its answer: no compose, or a compose card of the
    /// producer closed unsent.
    enum ClosedCompose: String, CaseIterable, CustomTestStringConvertible {
        case none, reply, compose, forward
        var testDescription: String { rawValue }
        var producer: ComposeProducer? { ComposeProducer(rawValue: rawValue) }
        /// Only the reply tool's card for the email the field showed is the field's own
        /// (`ChatFieldReply.isOwnReply`): it owns the completion, so its answer hands the words
        /// back. Every other answer empties them.
        var keepsTheWords: Bool { self == .reply }
    }

    /// The AI Suggestion a field shows in `closedComposeThenAnswerKeepsTheSend`'s suggestion cases.
    static let shownSuggestion = ReplyResult(body: "Hi,\n\nFriday works for me.\n\nThanks", textMessage: "Friday works for me")

    @Test("A field request's reply compose closed without sending, then its answer: the sent words are the user's again, kept after a relaunch; with no compose, or a compose or forward card, the answer empties them; the same whether or not the field showed an AI Suggestion at Send",
          arguments: ClosedCompose.allCases, [false, true])
    func closedComposeThenAnswerKeepsTheSend(_ closed: ClosedCompose, suggestionShown: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can drive the hosted field")
        try await HostedAccessibility.withAutomation {
            try await Self.withDatabase { pool in
                try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
                let tag = "\(closed.rawValue)-\(suggestionShown)"
                let email = Self.header("closed-\(tag)", thread: "closed-thread-\(tag)")
                try await pool.write { try email.insert($0) }
                let key = ChatFieldWords.key(for: email)
                let sent = "Reply that Friday works"
                let suggestion = suggestionShown ? Self.shownSuggestion : nil
                let backend = ThreadChatTests.Backend(holdAnswers: true)
                try await ThreadChatTests.withBackend(backend, chatView: true) {
                    let host = Host(email)
                    let pill = try await Self.mount(PillView(host: host, replyField: true, suggestion: suggestion))
                    defer { pill.close() }
                    try await ThreadChatTests.ask(sent, in: pill.view, backend: backend, answered: false)
                    let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
                    #expect(asked, "control: the request reached the backend")
                    if let producer = closed.producer {
                        // The agent's call carries the field's request as sent, its suggestion included.
                        let result = try await Self.sendCompose(producer, Self.invocation(.fieldUnchanged, email: email, suggestion: suggestion),
                                                                email: email, pool: pool, outcome: .cancelled)
                        #expect(!result.contains("sent successfully"), "control: the compose closed unsent: \(result)")
                        #expect(ChatFieldWords.shared.fill(for: key).composing == closed.keepsTheWords,
                                "control: only the reply card opens for the field")
                        #expect(ChatFieldWords.shared.fill(for: key).words == sent, "control: the sent words wait for the answer")
                    }
                    backend.proceed.signal()
                    try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                    try await Self.settle()
                    let fill = ChatFieldWords.shared.fill(for: key)
                    let texts = Self.fieldTexts(pill.view)
                    #expect(fill.atSend == nil && !fill.composing, "the answer completed the send: \(fill)")
                    if closed.keepsTheWords {
                        #expect(fill.words == sent && fill.unsent == sent, "the words are the user's again: \(fill.words)")
                        #expect(texts.contains(sent), "the words stay in the field: \(texts)")
                    } else {
                        #expect(fill.words == "", "the answer emptied the sent words: \(fill.words)")
                        #expect(!texts.contains(sent), "the field is empty: \(texts)")
                    }
                }
                await ChatFieldWords.shared.written()
                let expected = closed.keepsTheWords ? sent : ""
                #expect(try Self.stored(pool) == (expected.isEmpty ? [:] : [key: expected]), "kept only when handed back")
                // A relaunch: a fresh store on the same database.
                await Self.newRun { PrioritizedDatabase(pool: pool) }
                await ChatFieldWords.shared.load(key)
                #expect(ChatFieldWords.shared.fill(for: key).words == expected,
                        "after a relaunch: \(ChatFieldWords.shared.fill(for: key).words)")
            }
        }
    }

    @Test("A compose card from the field empties the field on its Send; a compose card from elsewhere keeps the typed words: in the field, on the device and in a fresh store")
    func fieldCardEmptiesElsewhereCardKeeps() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation {
            try await Self.withDatabase { pool in
                try FolderEpochTestFixture.insertFolder(accountId: "words", path: "INBOX", role: .inbox, pool: pool)
                let email = Self.header("two-sided", thread: "two-sided-thread")
                try await pool.write { try email.insert($0) }
                let key = ChatFieldWords.key(for: email)
                let backend = ThreadChatTests.Backend(holdAnswers: true)
                try await ThreadChatTests.withBackend(backend, chatView: true) {
                    let host = Host(email)
                    let pill = try await Self.mount(PillView(host: host, replyField: true))
                    defer { pill.close() }
                    // Side 1: the field's own request; its card's Send empties the field.
                    let sent = "Reply that Friday works"
                    try await ThreadChatTests.ask(sent, in: pill.view, backend: backend, answered: false)
                    let asked = await Task.detached { ThreadChatTests.waited(for: backend.asked) }.value
                    #expect(asked, "control: the request reached the backend")
                    _ = try await Self.sendCompose(.reply, Self.invocation(.fieldUnchanged, email: email), email: email, pool: pool)
                    try await Self.settle()
                    #expect(ChatFieldWords.shared.fill(for: key).words == "", "the field's card emptied the field")
                    #expect(!Self.fieldTexts(pill.view).contains(sent), "\(Self.fieldTexts(pill.view))")
                    backend.proceed.signal()
                    try await ThreadChatTests.wait { !ActiveAgentTracker.shared.anyWorking }
                    try await Self.settle()
                    await ChatFieldWords.shared.written()
                    #expect(try Self.stored(pool) == [:], "the field's sent words are not kept on the device")
                    // A fresh store on the same database, as the next app run reads it (the pill
                    // stays mounted for side 2, so the app's store is not replaced here).
                    let fresh = ChatFieldWords(database: { PrioritizedDatabase(pool: pool) })
                    await fresh.load(key)
                    #expect(fresh.fill(for: key).words == "", "a fresh store shows none of the sent words: \(fresh.fill(for: key).words)")

                    // Side 2: words typed, then a card from a request sent elsewhere goes out.
                    let typed = "Words the user is writing"
                    #expect(Self.type(typed, in: pill.view), "the field is a native editable field")
                    try await Self.settle()
                    _ = try await Self.sendCompose(.reply, Self.invocation(.sheet, email: email), email: email, pool: pool)
                    try await Self.settle()
                    #expect(ChatFieldWords.shared.fill(for: key).words == typed, "a card from elsewhere keeps the typed words")
                    #expect(Self.fieldTexts(pill.view).contains(typed), "\(Self.fieldTexts(pill.view))")
                }
                await ChatFieldWords.shared.written()
                #expect(try Self.stored(pool) == [key: "Words the user is writing"])
                // A fresh store, as the next app run: the typed words come back.
                await Self.newRun { PrioritizedDatabase(pool: pool) }
                await ChatFieldWords.shared.load(key)
                #expect(ChatFieldWords.shared.fill(for: key).words == "Words the user is writing",
                        "a fresh store: \(ChatFieldWords.shared.fill(for: key).words)")
            }
        }
    }

    // MARK: - 7. The email screen's pill, the inbox's chat, a demo

    @Test("The email screen's pill keeps its chat's words over Back; the inbox's chat keeps none")
    func emailScreenPillKeepsWords() async throws {
        try await Self.withDatabase { pool in
            // The pill shows its field with the chat view on, as in `twoPillsShareOneDraft`.
            try await ThreadChatTests.withBackend(ThreadChatTests.Backend(), chatView: true) {
                let email = Self.header("screen-1", thread: "screen-thread")
                let screen = try await Self.mount(PillView(host: Host(email, expanded: true), replyField: false))
                #expect(Self.type("From the email screen", in: screen.view), "the open pill has a native editable field")
                try await Self.settle()
                screen.close()
                try await Self.settle()
                let again = try await Self.mount(PillView(host: Host(email, expanded: true), replyField: false))
                #expect(Self.fieldTexts(again.view).contains("From the email screen"), "\(Self.fieldTexts(again.view))")
                again.close()

                // Control: the inbox's chat has no thread, and keeps nothing.
                let inbox = try await Self.mount(PillView(host: Host(nil, expanded: true), replyField: false))
                #expect(Self.type("An inbox question", in: inbox.view), "control: the inbox's chat has a field")
                try await Self.settle()
                inbox.close()
                try await Self.settle()
                let inboxAgain = try await Self.mount(PillView(host: Host(nil, expanded: true), replyField: false))
                #expect(Self.fieldTexts(inboxAgain.view).allSatisfy { !$0.contains("An inbox question") }, "\(Self.fieldTexts(inboxAgain.view))")
                inboxAgain.close()
                await ChatFieldWords.shared.written()
                let stored6 = try Self.stored(pool)
                #expect(stored6 == [ChatFieldWords.key(for: email): "From the email screen"])
            }
        }
    }

    @Test("A demo's words stay in the demo and go with it; the real chat keeps its own")
    func demoWordsStayInTheDemo() async throws {
        try await Self.withDatabase { pool in
            let savedAutoSync = UserDefaults.standard.object(forKey: "device_sync_auto_enabled")
            defer {
                if let savedAutoSync {
                    UserDefaults.standard.set(savedAutoSync, forKey: "device_sync_auto_enabled")
                } else {
                    UserDefaults.standard.removeObject(forKey: "device_sync_auto_enabled")
                }
            }
            UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
            DeviceSyncService.shared.disconnect()
            DemoModeStore.shared._resetForTests()
            defer { DemoModeStore.shared._resetForTests() }
            let email = Self.header("demo-1", thread: "demo-thread")
            let realKey = ChatFieldWords.key(for: email)
            try await Self.save("Real words", on: email)

            try await DemoModeService.shared.start(mintToken: false)
            #expect(DemoModeStore.isDemoActive, "control: the demo runs")
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).allSatisfy { !$0.contains("Real words") }, "the demo never shows the real chat's words")
                #expect(Self.type("Demo words", in: view))
                try await Self.settle()
            }
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains("Demo words"), "control: kept in the demo: \(Self.fieldTexts(view))")
            }
            await ChatFieldWords.shared.written()
            let inDemo = try Self.stored(pool)
            #expect(inDemo.count == 2 && inDemo[realKey] == "Real words", "the demo's are kept apart: \(inDemo)")

            await DemoModeService.shared.exit()
            #expect(!DemoModeStore.isDemoActive, "control: the demo ended")
            let stored7 = try Self.stored(pool)
            #expect(stored7 == [realKey: "Real words"], "the demo's words went with it")

            try await DemoModeService.shared.start(mintToken: false)
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).allSatisfy { !$0.contains("Demo words") }, "the next demo starts with none: \(Self.fieldTexts(view))")
            }
            await DemoModeService.shared.exit()
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains("Real words"), "the real chat keeps its words: \(Self.fieldTexts(view))")
            }
        }
    }

    // MARK: - A chat opened from the Search sheet

    /// How the Search sheet goes away.
    enum SheetDismissal: String, CaseIterable, CustomTestStringConvertible {
        /// The sheet's own `dismiss` (Search's Done and title buttons call it).
        case programmatic
        /// A UIKit programmatic teardown of the sheet: the presented controller is dismissed under
        /// its presentation controller's delegate, which is how SwiftUI learns the sheet closed. Not
        /// a swipe: the real Search sheet disables interactive dismissal.
        case uikitTeardown
        var testDescription: String { rawValue }
    }

    /// The Search sheet as the inbox presents it (`InboxView`'s `.sheet` over `SearchView`, whose
    /// `NavigationStack` pushes the chat), with the chat already pushed.
    @Observable final class SearchSheetHost {
        var presented = false
        @ObservationIgnored var dismiss: DismissAction?
    }

    struct SearchSheetView: View {
        @Bindable var host: SearchSheetHost
        let message: MessageHeader
        var body: some View {
            Color.clear
                .sheet(isPresented: $host.presented) {
                    NavigationStack {
                        SheetChat(host: host, message: message)
                    }
                }
        }
    }

    struct SheetChat: View {
        let host: SearchSheetHost
        let message: MessageHeader
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            HostView(message: message)
                .onAppear { host.dismiss = dismiss }
        }
    }

    @Test("Words typed in a chat pushed inside a sheet, as Search opens chats, survive the sheet's dismissal and are there when the chat opens again",
          arguments: SheetDismissal.allCases)
    func wordsSurviveTheSearchSheetsDismissal(_ dismissal: SheetDismissal) async throws {
        try await Self.withDatabase { pool in
            let email = Self.header("search-1", thread: "search-thread")
            let words = "Typed in a chat opened from Search"
            let host = SearchSheetHost()
            let mounted = try await Self.mount(SearchSheetView(host: host, message: email))
            defer { mounted.close() }
            let presenter = try #require(mounted.view.window?.rootViewController)
            host.presented = true
            try await Task.sleep(for: .milliseconds(800))
            let sheet = try #require(presenter.presentedViewController, "control: the Search sheet is up")
            #expect(Self.type(words, in: sheet.view), "the chat in the sheet has a native editable field")
            try await Self.settle()
            #expect(Self.fieldTexts(sheet.view).contains(words), "control: the edit reached the field")

            switch dismissal {
            case .programmatic:
                let dismiss = try #require(host.dismiss, "control: the sheet's chat has its dismiss action")
                dismiss()
            case .uikitTeardown:
                let presentation = try #require(sheet.presentationController)
                presentation.delegate?.presentationControllerWillDismiss?(presentation)
                await withCheckedContinuation { continuation in
                    sheet.dismiss(animated: true) { continuation.resume() }
                }
                presentation.delegate?.presentationControllerDidDismiss?(presentation)
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(presenter.presentedViewController == nil, "control: the Search sheet is gone")
            #expect(!host.presented, "control: SwiftUI saw the sheet close")

            await ChatFieldWords.shared.written()
            let stored = try Self.stored(pool)
            #expect(stored == [ChatFieldWords.key(for: email): words], "the words are kept on the device: \(stored)")
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains(words), "the words are in the field when the chat opens again: \(Self.fieldTexts(view))")
            }
            // And in the next app run.
            await Self.newRun { PrioritizedDatabase(pool: pool) }
            try await Self.open(email) { view in
                #expect(Self.fieldTexts(view).contains(words), "and after the app was closed: \(Self.fieldTexts(view))")
            }
        }
    }
}
