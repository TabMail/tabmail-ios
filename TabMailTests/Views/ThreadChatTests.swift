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

/// ADR-IOS-114: one TabMail chat per email thread; the chat view's requests are about the thread's
/// newest email, the email screen's about the email that is open.
///
/// THE SYSTEM PROPERTIES pinned here, each through the real pill and a fake backend that reads
/// what a request sends:
///  (a) A confirmation card raised by a request sent about one email stays visible and answerable
///      after a newer email of the thread lands: the sheet rises with it, Create answers that
///      request, and its answer stays in the thread's chat.
///  (b) A question sent about a newer email carries the exchange held about an earlier email of
///      the same thread to the model.
///  (c) The email screen, opened on an older email of a thread, shows the whole thread's chat,
///      and names that open email in its card and in every new request; the chat view, opened
///      on the same older email, names the thread's newest email.
///  (d) Two threads joined by a newer email: the chat shows both histories.
///  (e) Upgrading keeps each email's chat as one thread chat: two emails' chats read as one,
///      a chat whose email is gone stays as it was, demo chats stay demo chats.
///  (f) A thread with any email in the Inbox keeps its chat when old chats are cleared.
///  (g) The inbox chat's own sessions are unchanged: listed and cleared as before, never a
///      thread's chat.
///
/// (a), (b) and (d) run for a thread within one account and for one spanning two accounts.
@Suite("Per-thread chat", .serialized, .processGlobalState)
@MainActor
struct ThreadChatTests {

    static let accountA = "thread-a"
    static let accountB = "thread-b"

    // MARK: - Fixture

    /// A header of `account`'s `folder`, `minutesAgo` old.
    static func header(
        _ uid: String, account: String = accountA, folder: String = "INBOX", from: String,
        rfc: String, inReplyTo: String? = nil, references: [String] = [], thread: String, minutesAgo: Int
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Lunch plans", from: from, fromAddress: "sender@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-Double(minutesAgo) * 60), snippet: "",
            folderId: "\(account):\(folder)", accountId: account, folderPath: folder, isInInbox: folder == "INBOX")
        header.rfc822MessageId = rfc
        header.inReplyTo = inReplyTo
        if !references.isEmpty {
            header.referencesJSON = String(decoding: try! JSONSerialization.data(withJSONObject: references), as: UTF8.self)
        }
        header.computedThreadId = thread
        return header
    }

    static func insert(_ headers: MessageHeader..., pool: DatabasePool) throws {
        try pool.write { db in for header in headers { try header.insert(db) } }
    }

    /// An installed app database with two accounts, each with an Inbox and an Archive.
    static func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        for account in [accountA, accountB] {
            _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: account, path: "Archive", role: .archive, pool: pool)
        }
        return (pool, directory, previous)
    }

    /// The fake backend: answers each chat request "Answer N" (N counts the answers), or, for a
    /// request whose words contain `cardWords`, raises a template card first and answers
    /// "Template saved." once it is answered. `hold` keeps the first round until signalled.
    final class Backend: @unchecked Sendable {
        let http = FakeHTTP.Scenario()
        let asked = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        /// Every request body, in order, and how many plain answers were given. Kept here, not
        /// read from the scenario, which forgets its calls when it closes.
        final class Record: Sendable {
            let bodies = Mutex<[String]>([])
            let answers = Mutex(0)
        }
        private let record = Record()

        init(cardWords: String? = nil, templateName: String = "", hold: Bool = false) {
            http.register(path: "/completions/chat", method: "POST") { [record, asked, proceed] request in
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                record.bodies.withLock { $0.append(body) }
                let final: [String: Any]
                if let cardWords, body.contains(cardWords), !body.contains("conversation_state") {
                    asked.signal()
                    if hold { _ = proceed.wait(timeout: .now() + 20) }
                    let arguments: [String: Any] = [
                        "name": templateName, "instructions": ["Say yes."], "example_reply": "Yes, thanks.",
                    ]
                    let argumentsText = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                    final = [
                        "assistant": "",
                        "tool_calls": [["id": "tc1", "function": ["name": "template_create", "arguments": argumentsText]]],
                        "conversation_state": ["harmony_messages": [], "current_round": 1],
                    ]
                } else if cardWords != nil, body.contains("conversation_state") {
                    final = ["assistant": "Template saved."]
                } else {
                    let number = record.answers.withLock { count in
                        count += 1
                        return count
                    }
                    final = ["assistant": "Answer \(number)"]
                }
                let text = String(decoding: try! JSONSerialization.data(withJSONObject: final), as: UTF8.self)
                return .bytes(Data("event: final\ndata: \(text)\n\n".utf8), contentType: "text/event-stream")
            }
        }

        var service: AIService {
            AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        }

        /// The request bodies, in order.
        var bodies: [String] { record.bodies.withLock { $0 } }
    }

    /// The messages a request sent: the model history, then the question last.
    static func messages(_ body: String) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return try #require(object["messages"] as? [[String: Any]])
    }

    static func text(_ message: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: message)) ?? Data(), as: UTF8.self)
    }

    /// Runs `body` with the pills' requests going to `backend`, the chat view's settings as given,
    /// and no in-process chat left behind.
    static func withBackend(_ backend: Backend, chatView: Bool, _ body: () async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        saved.setChatView(on: chatView)
        ChatPillState.shared.removeAllSessions()
        ChatPillState.shared.aiService = backend.service
        defer {
            ChatPillState.shared.aiService = .shared
            ChatPillState.shared.removeAllSessions()
            backend.http.close()
            saved.restore()
        }
        try await body()
    }

    // MARK: - The pill

    @Observable final class Host {
        var message: MessageHeader?
        var expanded = false
        var working = false
        init(_ message: MessageHeader?) { self.message = message }
    }

    struct HostView: View {
        @Bindable var host: Host
        /// The chat view's pill (its reply field), else the email screen's.
        let inChatView: Bool
        var body: some View {
            DynamicIslandChat(
                message: host.message, isExpanded: $host.expanded, isWorking: $host.working,
                replyField: inChatView && host.message != nil
                    ? ChatReplyField(example: nil, isNoReply: false, clearCount: 0) : nil)
            .environment(\.hasTabMailSession, true)
        }
    }

    /// Mounts a pill on `message` and hands the host and its view to `body`.
    static func withPill(
        _ message: MessageHeader?, inChatView: Bool = false,
        _ body: @MainActor (Host, UIView) async throws -> Void
    ) async throws {
        let host = Host(message)
        try await mount(HostView(host: host, inChatView: inChatView)) { try await body(host, $0) }
    }

    static func mount<V: View>(_ view: V, _ body: @MainActor (UIView) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await settle()
        try await body(controller.view)
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    /// Waits up to ten seconds for `done`.
    static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(100)) }
    }

    nonisolated static func waited(for semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 10) == .success
    }

    static func labels(_ view: UIView) -> [String] { HostedAccessibility.labels(in: view) }

    static func shows(_ words: String, in view: UIView) -> Bool {
        labels(view).contains { $0.contains(words) }
    }

    /// Types `words` into the first native editable field under `view`, as UIKit reports an edit.
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

    /// Asks `words` in the mounted pill, through its Send, and waits for the answer.
    static func ask(_ words: String, in view: UIView, backend: Backend, answered: Bool = true) async throws {
        let before = backend.bodies.count
        #expect(type(words, in: view), "the pill has a native editable field")
        try await settle()
        #expect(HostedAccessibility.activate("chatSend", in: view),
                "the pill's Send takes a tap: \(HostedAccessibility.identifiers(in: view))")
        try await wait { backend.bodies.count > before }
        #expect(backend.bodies.count == before + 1, "control: the question went to the backend")
        guard answered else { return }
        try await wait { !ActiveAgentTracker.shared.anyWorking }
        try await settle()
    }

    /// Asks `words` about `message` from the email screen's pill, open.
    static func askAbout(_ message: MessageHeader?, _ words: String, backend: Backend) async throws {
        try await withPill(message) { host, view in
            host.expanded = true
            try await Task.sleep(for: .milliseconds(600))
            try await ask(words, in: view, backend: backend)
        }
    }

    // MARK: - (a) Live cards

    @Test("A card raised for an earlier email shows once a newer email of the thread lands; Create answers that request and its answer stays in the thread's chat",
          arguments: [false, true])
    func cardStaysAnswerable(acrossAccounts: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted buttons")
        try await HostedAccessibility.withAutomation { try await cardStaysAnswerableBody(acrossAccounts: acrossAccounts) }
    }

    private func cardStaysAnswerableBody(acrossAccounts: Bool) async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let templateName = "Thread card \(UUID().uuidString.prefix(8))"
        defer {
            if let made = PromptStore.shared.templates.first(where: { $0.name == templateName }) {
                PromptStore.shared.deleteTemplate(id: made.id)
            }
        }
        // Each case its own emails, so nothing one case leaves running reaches the other.
        let tag = acrossAccounts ? "b" : "a"
        let first = Self.header(acrossAccounts ? "111" : "101", from: "Ann Example", rfc: "card-1\(tag)@example.com",
                                thread: "card-thread-\(tag)", minutesAgo: 30)
        let newer = Self.header(
            acrossAccounts ? "112" : "102", account: acrossAccounts ? Self.accountB : Self.accountA, from: "Bea Example",
            rfc: "card-2\(tag)@example.com", inReplyTo: "card-1\(tag)@example.com",
            thread: acrossAccounts ? "card-2\(tag)@example.com" : "card-thread-\(tag)", minutesAgo: 1)
        try Self.insert(first, pool: pool)
        let backend = Backend(cardWords: "Make it a template", templateName: templateName, hold: true)
        try await Self.withBackend(backend, chatView: true) {
            try await Self.withPill(first, inChatView: true) { host, view in
                // The request goes out about the newest email, email 1.
                try await Self.ask("Make it a template", in: view, backend: backend, answered: false)
                let asked = await Task.detached { Self.waited(for: backend.asked) }.value
                #expect(asked, "control: the request reached the backend")
                // Email 2 lands while the request runs; the chat is now about it.
                try Self.insert(newer, pool: pool)
                host.message = newer
                try await Self.settle()
                backend.proceed.signal()

                try await Self.wait { Self.shows("Create", in: view) }
                #expect(host.expanded, "the card opens the sheet")
                #expect(Self.shows("Create", in: view), "the card is shown: \(Self.labels(view).prefix(30))")
                let create = HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == "Create" }
                #expect(create?.accessibilityActivate() == true, "Create takes a tap")

                try await Self.wait { backend.bodies.count == 2 && Self.shows("Template saved.", in: view) }
                #expect(backend.bodies.count == 2, "Create answered the request, which went on")
                #expect(Self.shows("Template saved.", in: view), "its answer shows: \(Self.labels(view).prefix(30))")

                // Read again from storage, as after a relaunch: the answer is in the thread's chat.
                try await Self.wait { !ActiveAgentTracker.shared.anyWorking }
                host.expanded = false
                try await Self.settle()
                ChatPillState.shared.removeAllSessions()
                host.expanded = true
                try await Self.wait { Self.shows("Template saved.", in: view) }
                #expect(Self.shows("Template saved.", in: view), "stored in the thread's chat: \(Self.labels(view).prefix(30))")
            }
        }
    }

    // MARK: - (b) Thread memory

    @Test("A question about a newer email sends the model the exchange held about an earlier email of the thread",
          arguments: [false, true])
    func newerEmailRemembersTheThread(acrossAccounts: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await newerEmailRemembersTheThreadBody(acrossAccounts: acrossAccounts) }
    }

    private func newerEmailRemembersTheThreadBody(acrossAccounts: Bool) async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let first = Self.header("201", from: "Ann Example", rfc: "memory-1@example.com", thread: "memory-thread", minutesAgo: 30)
        let newer = Self.header(
            "202", account: acrossAccounts ? Self.accountB : Self.accountA, from: "Bea Example",
            rfc: "memory-2@example.com", inReplyTo: "memory-1@example.com",
            thread: acrossAccounts ? "memory-2@example.com" : "memory-thread", minutesAgo: 1)
        try Self.insert(first, pool: pool)
        let backend = Backend()
        try await Self.withBackend(backend, chatView: true) {
            try await Self.withPill(first, inChatView: true) { host, view in
                try await Self.ask("Where do we meet", in: view, backend: backend)
                try Self.insert(newer, pool: pool)
                host.message = newer
                try await Self.settle()
                try await Self.ask("What time", in: view, backend: backend)
            }
        }
        let bodies = backend.bodies
        #expect(bodies.count == 2)
        guard bodies.count == 2 else { return }
        let sent = try Self.messages(bodies[1])
        let history = sent.dropLast().map(Self.text).joined(separator: "\n")
        #expect(history.contains("Where do we meet"), "the earlier question is in the history: \(history)")
        #expect(history.contains("Answer 1"), "and its answer: \(history)")
        #expect(Self.text(sent.last ?? [:]).contains("What time"), "control: the question is last")
    }

    // MARK: - (c) The email screen

    @Test("The email screen opened on an older email shows the whole thread's chat, its card shows that email, and a question names that email")
    func emailScreenUsesTheOpenEmail() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await emailScreenUsesTheOpenEmailBody() }
    }

    private func emailScreenUsesTheOpenEmailBody() async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let older = Self.header("301", from: "Ann Example", rfc: "screen-1@example.com", thread: "screen-thread", minutesAgo: 30)
        let newest = Self.header(
            "302", from: "Bea Example", rfc: "screen-2@example.com", inReplyTo: "screen-1@example.com",
            thread: "screen-thread", minutesAgo: 1)
        try Self.insert(older, pool: pool)
        let backend = Backend()
        try await Self.withBackend(backend, chatView: false) {
            // A question asked while the older email was the only one, then one about the newer.
            try await Self.askAbout(older, "Where do we meet", backend: backend)
            try Self.insert(newest, pool: pool)
            try await Self.askAbout(newest, "What time", backend: backend)
            ChatPillState.shared.removeAllSessions()

            let screen = NavigationStack { MessageDetailView(messageId: older.id) }
                .environment(\.hasTabMailSession, true)
            try await Self.mount(screen) { view in
                try await Self.wait { HostedAccessibility.identifiers(in: view).contains("chatPill") }
                try await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(name: .openMessageWithChat, object: nil, userInfo: ["messageId": older.id])
                try await Self.wait { Self.shows("Answer", in: view) }
                try await Task.sleep(for: .milliseconds(600))
                #expect(Self.shows("Answer 1", in: view), "the earlier exchange: \(Self.labels(view).prefix(40))")
                #expect(Self.shows("Answer 2", in: view), "the exchange about the newer email: \(Self.labels(view).prefix(40))")
                let card = HostedAccessibility.elements(under: view)
                    .first { HostedAccessibility.identifier(of: $0) == "chatEmailCard" }?.accessibilityLabel ?? ""
                #expect(card.contains("Ann Example"), "the card shows the open email: \(card)")
                #expect(!card.contains("Bea Example"), "never the thread's newest: \(card)")

                try await Self.ask("Is it confirmed", in: view, backend: backend)
            }
        }
        let bodies = backend.bodies
        #expect(bodies.count == 3)
        guard bodies.count == 3 else { return }
        let sent = try Self.messages(bodies[2])
        let newestNumber = await ChatIdTranslator.shared.toNumericId(newest.id)
        let olderNumber = await ChatIdTranslator.shared.toNumericId(older.id)
        let question = Self.text(sent.last ?? [:])
        #expect(question.contains("Is it confirmed"), "control: the question is last: \(question)")
        #expect(question.contains("[Email](\(olderNumber))"), "it names the open email: \(question)")
        #expect(!question.contains("[Email](\(newestNumber))"), "never the thread's newest: \(question)")
        let history = sent.dropLast().map(Self.text).joined(separator: "\n")
        #expect(history.contains("Answer 1") && history.contains("Answer 2"), "the whole thread's chat goes with it: \(history)")
    }

    @Test("The chat view opened on an older email of a thread asks about the thread's newest email")
    func chatViewUsesTheNewestEmail() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await chatViewUsesTheNewestEmailBody() }
    }

    private func chatViewUsesTheNewestEmailBody() async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let older = Self.header("311", from: "Ann Example", rfc: "view-1@example.com", thread: "view-thread", minutesAgo: 30)
        let newest = Self.header(
            "312", from: "Bea Example", rfc: "view-2@example.com", inReplyTo: "view-1@example.com",
            thread: "view-thread", minutesAgo: 1)
        try Self.insert(older, newest, pool: pool)
        let accounts = try await pool.read { try Account.fetchAll($0) }
        let backend = Backend()
        try await Self.withBackend(backend, chatView: true) {
            let navigationStore = NavigationStore()
            navigationStore.accounts = accounts
            let chat = NavigationStack { ChatThreadView(messageId: older.id) }
                .environment(navigationStore)
                .environment(\.hasTabMailSession, true)
            try await Self.mount(chat) { view in
                try await Self.wait { Self.shows("Bea Example", in: view) }
                try await Self.settle()
                try await Self.ask("Is it confirmed", in: view, backend: backend)
            }
        }
        let bodies = backend.bodies
        #expect(bodies.count == 1)
        guard bodies.count == 1 else { return }
        let question = Self.text(try Self.messages(bodies[0]).last ?? [:])
        let newestNumber = await ChatIdTranslator.shared.toNumericId(newest.id)
        let olderNumber = await ChatIdTranslator.shared.toNumericId(older.id)
        #expect(question.contains("Is it confirmed"), "control: the question is last: \(question)")
        #expect(question.contains("[Email](\(newestNumber))"), "it names the newest email: \(question)")
        #expect(!question.contains("[Email](\(olderNumber))"), "never the email it was opened on: \(question)")
    }

    // MARK: - (d) Joined threads

    @Test("Two threads joined by a newer email: the chat shows both histories", arguments: [false, true])
    func joinedThreadsShowBothHistories(acrossAccounts: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await joinedThreadsShowBothHistoriesBody(acrossAccounts: acrossAccounts) }
    }

    private func joinedThreadsShowBothHistoriesBody(acrossAccounts: Bool) async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let left = Self.header("401", from: "Ann Example", rfc: "join-a@example.com", thread: "join-a", minutesAgo: 60)
        let right = Self.header(
            "402", account: acrossAccounts ? Self.accountB : Self.accountA, from: "Bea Example",
            rfc: "join-b@example.com", thread: "join-b", minutesAgo: 50)
        // A reply that cites both: it joins the two threads, taking the first one's thread id.
        let joining = Self.header(
            "403", from: "Cy Example", rfc: "join-c@example.com", inReplyTo: "join-b@example.com",
            references: ["join-a@example.com", "join-b@example.com"], thread: "join-a", minutesAgo: 1)
        try Self.insert(left, right, pool: pool)
        let backend = Backend()
        try await Self.withBackend(backend, chatView: true) {
            try await Self.askAbout(left, "About the first", backend: backend)
            try await Self.askAbout(right, "About the second", backend: backend)
            try Self.insert(joining, pool: pool)
            ChatPillState.shared.removeAllSessions()
            try await Self.withPill(joining, inChatView: true) { host, view in
                host.expanded = true
                try await Self.wait { Self.shows("Answer 1", in: view) && Self.shows("Answer 2", in: view) }
                #expect(Self.shows("Answer 1", in: view), "the first thread's chat: \(Self.labels(view).prefix(30))")
                #expect(Self.shows("Answer 2", in: view), "the second thread's chat: \(Self.labels(view).prefix(30))")
            }
        }
    }

    // MARK: - (e) Upgrade

    /// A database file migrated up to `migration`, as an older build left it.
    static func migrated(upTo migration: String) throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("threadchat_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(pool, upTo: migration)
        return (pool, dir)
    }

    static func turn(_ id: String, session: String, minutesAgo: Int, words: String) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: Date().addingTimeInterval(-Double(minutesAgo) * 60).timeIntervalSince1970 * 1000,
            role: "user", content: "chat_converse", userMessage: words, type: "normal", chars: words.count,
            renderedContent: nil, sessionId: session, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
    }

    @Test("Upgrading: the chats of two emails of a thread read as one chat; a chat whose email is gone stays; demo chats stay demo chats")
    func upgradeJoinsEachThreadsChats() throws {
        let (pool, dir) = try Self.migrated(upTo: "v106_repairAICacheMessageIds")
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let first = Self.header("501", from: "Ann Example", rfc: "up-1@example.com", thread: "up-thread", minutesAgo: 60)
        let second = Self.header("502", folder: "Archive", from: "Bea Example", rfc: "up-2@example.com", thread: "up-thread", minutesAgo: 30)
        // A provider whose ids are not IMAP UIDs: its email's chat was keyed by that id.
        let apiEmail = Self.header("api-id-1", from: "Cy Example", rfc: "up-3@example.com", thread: "", minutesAgo: 20)
        let other = Self.header("503", from: "Di Example", rfc: "up-4@example.com", thread: "up-other", minutesAgo: 10)
        try pool.write { db in
            var account = Account(emailAddress: "a@example.com", displayName: "A", provider: .imap)
            account.id = Self.accountA
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountA).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: Self.accountA).insert(db)
            for header in [first, second, apiEmail, other] { try TestDatabase.insertAtOldSchema(header, db) }
            let a = Self.accountA
            let turns = [
                Self.turn("t1", session: "msg:\(a):up-1@example.com", minutesAgo: 50, words: "first email"),
                Self.turn("t2", session: "msg:\(a):up-2@example.com", minutesAgo: 25, words: "second email"),
                Self.turn("t3", session: "msg:\(a):api-id-1", minutesAgo: 15, words: "api email"),
                Self.turn("t4", session: "msg:\(a):up-4@example.com", minutesAgo: 5, words: "other thread"),
                Self.turn("t5", session: "msg:\(a):gone@example.com", minutesAgo: 40, words: "gone email"),
                Self.turn("t6", session: "demo:msg:\(a):up-1@example.com", minutesAgo: 45, words: "demo first"),
                Self.turn("t7", session: "demo:msg:\(a):up-2@example.com", minutesAgo: 35, words: "demo second"),
                Self.turn("t8", session: "inbox-session-id", minutesAgo: 3, words: "inbox chat"),
            ]
            for turn in turns { try turn.insert(db) }
            for turn in turns {
                try db.execute(
                    sql: "INSERT INTO chatHistory (id, timestamp, role, content, userMessage, sessionId, chars) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [turn.id, turn.timestamp, turn.role, turn.content, turn.userMessage, turn.sessionId, turn.chars])
            }
        }

        try AppDatabase.runMigrations(on: pool)

        for table in ["chatTurn", "chatHistory"] {
            let sessions = try pool.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, sessionId FROM \(table)").map {
                    ($0["id"] as String, $0["sessionId"] as String)
                })
            }
            #expect(sessions.count == 8, "every row stays, under its own id: \(table)")
            guard sessions.count == 8 else { return }
            let thread = try #require(sessions["t1"])
            #expect(sessions["t2"] == thread, "\(table): the two emails' chats are one: \(sessions)")
            #expect(!thread.hasPrefix("msg:"), "\(table): \(sessions)")
            #expect(Set([sessions["t3"], sessions["t4"], thread]).count == 3, "\(table): other threads stay apart: \(sessions)")
            #expect(sessions["t3"]?.hasPrefix("msg:") == false, "\(table): a non-UID email's chat moves too: \(sessions)")
            #expect(sessions["t5"] == "msg:\(Self.accountA):gone@example.com", "\(table): a chat whose email is gone stays: \(sessions)")
            let demo = try #require(sessions["t6"])
            #expect(sessions["t7"] == demo, "\(table): the demo chats of the thread are one: \(sessions)")
            #expect(demo.hasPrefix("demo:") && demo != thread && !demo.hasPrefix("demo:msg:"), "\(table): and stay demo: \(sessions)")
            #expect(sessions["t8"] == "inbox-session-id", "\(table): the inbox chat is untouched: \(sessions)")
        }
        // The stored chat of the thread reads as one conversation, in time order.
        let thread = try #require(try pool.read { try String.fetchOne($0, sql: "SELECT sessionId FROM chatTurn WHERE id = 't1'") })
        let words = try pool.read { db in
            try String.fetchAll(db, sql: "SELECT userMessage FROM chatTurn WHERE sessionId = ? ORDER BY timestamp", arguments: [thread])
        }
        #expect(words == ["first email", "second email"])
    }

    // MARK: - (f) Clearing old chats

    @Test("Clearing old chats keeps a thread's chat while any email of the thread is in the Inbox")
    func threadWithAnInboxEmailKeepsItsChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await threadWithAnInboxEmailKeepsItsChatBody() }
    }

    private func threadWithAnInboxEmailKeepsItsChatBody() async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        // The thread's newest email is archived; an earlier one is still in the Inbox.
        let inInbox = Self.header("601", from: "Ann Example", rfc: "keep-1@example.com", thread: "keep-thread", minutesAgo: 30)
        let archived = Self.header(
            "602", folder: "Archive", from: "Bea Example", rfc: "keep-2@example.com",
            inReplyTo: "keep-1@example.com", thread: "keep-thread", minutesAgo: 5)
        // Control: a thread with every email archived.
        let allArchived = Self.header("603", folder: "Archive", from: "Cy Example", rfc: "gone-1@example.com", thread: "gone-thread", minutesAgo: 10)
        try Self.insert(inInbox, archived, allArchived, pool: pool)
        let backend = Backend()
        try await Self.withBackend(backend, chatView: false) {
            try await Self.askAbout(archived, "Keep this question", backend: backend)
            try await Self.askAbout(allArchived, "Clear this question", backend: backend)
        }
        func stored(_ words: String) throws -> Int {
            try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chatTurn WHERE userMessage LIKE ?", arguments: ["%\(words)%"]) ?? 0 }
        }
        #expect(try stored("Keep this question") == 1 && stored("Clear this question") == 1, "control: both chats are stored")

        _ = try await ChatStore.shared.evictMessageDetailSessions(limit: 0)

        #expect(try stored("Clear this question") == 0, "control: a thread with no email in the Inbox is cleared")
        #expect(try stored("Keep this question") == 1, "a thread with an email in the Inbox keeps its chat")
    }

    // MARK: - (g) The inbox chat

    @Test("The inbox chat lists and clears only its own sessions, never a thread's chat")
    func inboxChatSessionsUnchanged() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await inboxChatSessionsUnchangedBody() }
    }

    private func inboxChatSessionsUnchangedBody() async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let email = Self.header("701", folder: "Archive", from: "Ann Example", rfc: "inbox-chat-1@example.com", thread: "inbox-chat-thread", minutesAgo: 5)
        try Self.insert(email, pool: pool)
        let backend = Backend()
        try await Self.withBackend(backend, chatView: false) {
            try await Self.askAbout(nil, "An inbox question", backend: backend)
            try await Self.askAbout(email, "A thread question", backend: backend)
        }
        let listed = try await ChatStore.shared.loadSessions(limit: ChatPillState.defaultMaxSessions, demoActive: false)
        #expect(listed.count == 1, "only the inbox chat's own session: \(listed.map(\.id))")
        guard listed.count == 1 else { return }
        #expect(UUID(uuidString: listed[0].id) != nil, "a session of its own: \(listed[0].id)")
        #expect(listed[0].turns.compactMap(\.userMessage).contains("An inbox question"))

        let cleared = try await ChatStore.shared.evictInboxSessions(limit: 0)
        #expect(cleared == 1, "the inbox chat's limit clears its own session")
        let left = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT userMessage FROM chatTurn WHERE role = 'user' ORDER BY timestamp")
        }
        #expect(left.count == 1 && left.first?.contains("A thread question") == true, "the thread's chat stays: \(left)")
    }
}
