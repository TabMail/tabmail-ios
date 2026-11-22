/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Every new email opens the chat (ADR-IOS-114 decision 24, *Every new email*): what a contact
/// pill or a `mailto:` link brings into the new email's chat, what its draft keeps, the account it
/// starts from, and which screen takes each request.
@Suite("A new email from a contact or a link", .serialized, .processGlobalState)
@MainActor
struct ChatNewEmailRequestTests {
    nonisolated private static let accountId = "chat-new-email-request"

    /// A link with everything a `mailto:` can carry: a quoted name with a comma, a plain address,
    /// an entry that names no address, Cc, Bcc, a subject and a body.
    private static let link = MailtoRequest(
        to: ["\"Doe, John\" <John@Example.com>", "maria@example.com", "undisclosed-recipients:;"],
        cc: ["Sam Park <sam@example.com>"],
        bcc: ["alex@example.com"],
        subject: "Lunch on Friday",
        body: "Are you free at noon?")

    @MainActor
    private final class QueueRecorder {
        var calls: [String] = []

        func queue(_ draftId: String, _ accountId: String) -> Bool {
            calls.append("\(draftId)|\(accountId)")
            return true
        }
    }

    // MARK: - Where it opens

    @Test("The cover opens the chat with what the request brought from the chat's account; otherwise compose with the request itself")
    func coverContent() throws {
        var chosen = Account(emailAddress: "me@example.com", displayName: "Me", provider: .imap)
        chosen.id = "chosen"
        var other = Account(emailAddress: "other@example.com", displayName: "Other", provider: .imap)
        other.id = "other"
        let chat = ChatNewEmailCover.make(
            request: Self.link, opensInChat: true, signedIn: true, chatAccount: chosen, composeAccount: other)
        guard case .chat(let model) = chat.content else {
            Issue.record("the chat view on and signed in opens the chat: \(chat.content)")
            return
        }
        #expect(model.account?.id == "chosen", "the chat starts from the account it was given")
        #expect(model.people.map(\.address) == ["john@example.com", "maria@example.com"])
        for (opensInChat, signedIn) in [(false, true), (true, false), (false, false)] {
            let cover = ChatNewEmailCover.make(
                request: Self.link, opensInChat: opensInChat, signedIn: signedIn, chatAccount: chosen, composeAccount: other)
            guard case .compose(let request, let account) = cover.content else {
                Issue.record("on \(opensInChat), signed in \(signedIn): compose opens")
                continue
            }
            #expect(request == Self.link, "compose gets the whole request")
            #expect(account?.id == "other", "from the account compose was given")
        }
        let button = ChatNewEmailCover.make(
            request: nil, opensInChat: true, signedIn: true, chatAccount: chosen, composeAccount: nil)
        guard case .chat(let empty) = button.content else {
            Issue.record("the email screen's compose button opens the chat too: \(button.content)")
            return
        }
        #expect(empty.people.isEmpty)
        #expect(empty.words.isEmpty)
        #expect(empty.carried == ChatNewDraft.Carried.empty)
        let again = ChatNewEmailCover.make(
            request: nil, opensInChat: true, signedIn: true, chatAccount: chosen, composeAccount: nil)
        #expect(again.id != button.id, "each request is a cover of its own")
    }

    // MARK: - What the chat holds

    @Test("A link's To becomes the people picked, a quoted name with a comma one person; its body the field's words; its subject, Cc and Bcc are held, and Bcc is never a person")
    func modelFromLink() {
        let model = ChatNewThreadModel(account: nil, request: Self.link)
        #expect(model.people.map(\.address) == ["john@example.com", "maria@example.com"])
        #expect(model.people.map(\.name) == ["Doe, John", ChatThread.fallbackName("maria@example.com")])
        #expect(model.words == "Are you free at noon?")
        #expect(model.startWords == "Are you free at noon?", "the field starts with the body, editable")
        #expect(model.carried.subject == "Lunch on Friday")
        #expect(model.carried.cc == [RecipientEntry.text(name: "Sam Park", address: "sam@example.com")])
        #expect(model.carried.bcc == ["alex@example.com"])
        #expect(!model.people.contains { $0.address == "alex@example.com" }, "Bcc is never a person picked")
        #expect(!model.content.recipients.contains { $0.contains("alex@example.com") }, "nor written as To")
        let readBack = ChatNewDraft.people(fromTo: model.content.recipients)
        #expect(readBack.people.map(\.address) == ["john@example.com", "maria@example.com"], "To reads back as the people")
        #expect(readBack.leftovers == ["undisclosed-recipients:;"], "an entry that names no address is written back as written")
        #expect(model.sendAction == .write(to: ["john@example.com", "maria@example.com"]))
        let pill = ChatNewThreadModel(account: nil, request: MailtoRequest(to: ["Maria Lee <maria@example.com>"]))
        #expect(pill.people.map(\.name) == ["Maria Lee"], "a contact pill: that person picked")
        #expect(pill.words.isEmpty)
        #expect(pill.carried == ChatNewDraft.Carried.empty)
    }

    @Test("Cc and Bcc lines name everyone in them, and show nothing for no one; a blank subject shows New email")
    func linesAndSubject() {
        #expect(ChatNewDraft.copyLine("Cc", []) == nil)
        #expect(ChatNewDraft.copyLine("Cc", ["undisclosed-recipients:;"]) == nil, "an entry that names no one is no line")
        #expect(ChatNewDraft.copyLine("Cc", ["Sam Park <sam@example.com>"]) == "Cc: Sam Park.")
        #expect(ChatNewDraft.copyLine("Bcc", ["Bo <b@example.com>", "Cy <c@example.com>"]) == "Bcc: Bo and Cy.")
        #expect(ChatNewDraft.copyLine("Cc", ["a@example.com", "Bo <b@example.com>", "Cy <c@example.com>"])
                == "Cc: \(ChatThread.fallbackName("a@example.com")), Bo and Cy.")
        #expect(ChatNewDraft.copyLine("Cc", ["\"Doe, John\" <john@example.com>"]) == "Cc: Doe, John.", "one person")
        #expect(ChatNewDraft.Carried.empty.shownSubject == nil)
        #expect(ChatNewDraft.Carried(subject: " \n", cc: [], bcc: []).shownSubject == nil)
        #expect(ChatNewDraft.Carried(subject: "Lunch", cc: [], bcc: []).shownSubject == "Lunch")
        // The shared join still reads as before for the recipients line.
        let people = [ChatThread.Person(address: "a@example.com", name: "Ann"), ChatThread.Person(address: "b@example.com", name: "Bo")]
        #expect(ChatNewDraft.recipientsLine(people) == "New email to Ann and Bo.")
    }

    @Test("Held Cc and Bcc are stored one mailbox per entry, each reading back as itself, entries naming no address as written")
    func heldEntries() {
        let stored = ChatNewDraft.entries(["\"Doe, John\" <John@Example.com>; sam@example.com", "undisclosed-recipients:;"])
        #expect(stored.count == 3, "one entry per mailbox: \(stored)")
        let readBack = RecipientEntry(stored)
        #expect(readBack.recipients.map(\.address) == ["John@Example.com", "sam@example.com"])
        #expect(readBack.recipients.first?.name == "Doe, John")
        #expect(readBack.leftovers == ["undisclosed-recipients:;"])
    }

    @Test("A chat opened from a link saves nothing while it holds just what the link brought; any change beyond it is saved")
    func openedIsTheStartingPoint() {
        let opened = ChatNewDraft.Content(words: "Are you free?", recipients: ["maria@example.com"], attachments: [])
        let typed = ChatNewDraft.Content(words: "Are you free at noon?", recipients: ["maria@example.com"], attachments: [])
        let repicked = ChatNewDraft.Content(words: "Are you free?", recipients: ["sam@example.com"], attachments: [])
        let emptied = ChatNewDraft.Content(words: "", recipients: ["maria@example.com"], attachments: [])
        #expect(!ChatNewDraft.needsSave(current: opened, saved: nil, opened: opened), "a link opened by mistake leaves nothing")
        #expect(ChatNewDraft.needsSave(current: typed, saved: nil, opened: opened))
        #expect(ChatNewDraft.needsSave(current: repicked, saved: nil, opened: opened))
        #expect(!ChatNewDraft.needsSave(current: emptied, saved: nil, opened: opened), "nothing waits")
        #expect(ChatNewDraft.needsSave(current: opened, saved: typed, opened: opened), "once saved, the row is what counts")
        #expect(ChatNewDraft.needsSave(current: opened, saved: nil), "with no starting point, words wait")
    }

    // MARK: - The draft

    @Test("A link's chat saves nothing until the user changes something; then the link's subject, Cc and Bcc are written with the words, Bcc as Bcc, and a later save keeps them")
    func linkDraftSaves() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let account = try FolderEpochTestFixture.makeAccount(id: Self.accountId, provider: .imap, pool: pool)
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: account, request: Self.link, queueDraftSave: { recorder.queue($0, $1) })
        let untouched = await model.saveIfNeeded()
        let before = try await pool.read { db in try Draft.fetchCount(db) }
        #expect(untouched == .saved)
        #expect(before == 0, "Back with nothing changed leaves nothing in Drafts")
        #expect(recorder.calls.isEmpty)
        model.words = "Are you free at noon? Or one?"
        let first = await model.saveIfNeeded()
        let firstRow = try await pool.read { db in try Draft.fetchOne(db, key: model.draftId) }
        let saved = try #require(firstRow, "the change is saved")
        #expect(first == .saved)
        #expect(saved.body == "Are you free at noon? Or one?")
        #expect(saved.subject == "Lunch on Friday")
        #expect(saved.ccArray == [RecipientEntry.text(name: "Sam Park", address: "sam@example.com")])
        #expect(saved.bccArray == ["alex@example.com"], "Bcc stays Bcc")
        #expect(!saved.toArray.contains { $0.contains("alex@example.com") })
        #expect(saved.toArray.last == "undisclosed-recipients:;")
        model.words = "Lunch at one, then."
        let second = await model.saveIfNeeded()
        let secondRow = try await pool.read { db in try Draft.fetchOne(db, key: model.draftId) }
        let resaved = try #require(secondRow)
        #expect(second == .saved)
        #expect(resaved.body == "Lunch at one, then.")
        #expect(resaved.subject == "Lunch on Friday")
        #expect(resaved.ccArray == saved.ccArray)
        #expect(resaved.bccArray == ["alex@example.com"])
        #expect(recorder.calls == Array(repeating: "\(model.draftId)|\(Self.accountId)", count: 2))
    }

    @Test("A reopened draft shows its own subject, Cc and Bcc as a link's are shown")
    func reopenedCarriesItsOwn() {
        let draft = Draft(
            id: Draft.newEmailKey(), accountId: Self.accountId,
            toJSON: Draft.encodeStringArray(["maria@example.com"]),
            ccJSON: Draft.encodeStringArray(["Sam Park <sam@example.com>"]),
            bccJSON: Draft.encodeStringArray(["alex@example.com"]), subject: "Plans", body: "Lunch?", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
        var account = Account(emailAddress: "me@example.com", displayName: "Me", provider: .imap)
        account.id = Self.accountId
        let model = ChatNewThreadModel(reopening: draft, account: account)
        #expect(model.carried.shownSubject == "Plans")
        #expect(ChatNewDraft.copyLine("Cc", model.carried.cc) == "Cc: Sam Park.")
        #expect(model.carried.bcc == ["alex@example.com"])
    }

    // MARK: - The account

    @Test("A new email starts from the active primary account, else the oldest active one; an inactive account never")
    func primaryAccount() throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        func account(_ id: String, primary: Bool, active: Bool, minutesAgo: Double) -> Account {
            var account = Account(emailAddress: "\(id)@example.com", displayName: id, provider: .imap)
            account.id = id
            account.isPrimary = primary
            account.isActive = active
            account.createdAt = Date().addingTimeInterval(-minutesAgo * 60)
            return account
        }
        let none = try pool.read { db in try Account.primary(in: db) }
        #expect(none == nil, "no account, no start")
        let inactivePrimary = account("inactive-primary", primary: true, active: false, minutesAgo: 30)
        let older = account("older", primary: false, active: true, minutesAgo: 20)
        let newer = account("newer", primary: false, active: true, minutesAgo: 10)
        try pool.write { db in
            try inactivePrimary.insert(db)
            try older.insert(db)
            try newer.insert(db)
        }
        let oldest = try pool.read { db in try Account.primary(in: db) }
        #expect(oldest?.id == "older", "no active primary: the oldest active, never the inactive primary")
        let chosen = account("chosen", primary: true, active: true, minutesAgo: 5)
        try pool.write { db in try chosen.insert(db) }
        let primary = try pool.read { db in try Account.primary(in: db) }
        #expect(primary?.id == "chosen")
        #expect(Account.primary()?.id == "chosen", "the app's database, as the screens read it")
        let list = try Self.source("TabMail/ViewModels/InboxViewModel.swift")
        #expect(Self.count("var primaryAccount: Account? { Account.primary(pool: dbPool) }", in: list) == 1,
                "the list's compose button reads the same rule")
    }

    // MARK: - Which screen takes it

    @Test("One screen takes each request, the one on top: the list with no email open over it, an open chat with nothing over it, the email screen; each asks the one route and shows the one cover")
    func handlerWiring() throws {
        let inboxPath = "TabMail/Views/Inbox/InboxView.swift"
        let chatPath = "TabMail/Views/Chat/ChatThreadView.swift"
        let detailPath = "TabMail/Views/Message/MessageDetailView.swift"
        let cover = ".fullScreenCover(item: $newEmailCover) { ChatNewEmailCoverView(cover: $0) }"
        let inbox = try Self.source(inboxPath)
        #expect(Self.count("guard selectedMessageId == nil, pushedMessageId == nil, !showSearch else { return }", in: inbox) == 1,
                "an email opened over the list, by a row, a pill or in Search, takes it itself")
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: viewModel.primaryAccount, composeAccount: viewModel.primaryAccount)", in: inbox) == 1)
        #expect(Self.count(cover, in: inbox) == 1)
        #expect(Self.count("prefillTo:", in: inbox) == 0, "compose is filled from a request only through the cover")
        let chat = try Self.source(chatPath)
        #expect(Self.count("guard isOnScreen, !isAnyPresentation else { return }", in: chat) == 1,
                "a pushed screen, or its email card's screen, takes it instead")
        #expect(Self.count("|| forwardMessage != nil || showsReplyTo || showsMove || newEmailCover != nil", in: chat) == 1,
                "its own cover counts as presented")
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: Account.primary(), composeAccount: Account.primary())", in: chat) == 1)
        #expect(Self.count(cover, in: chat) == 1)
        let detail = try Self.source(detailPath)
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: Account.primary(), composeAccount: nil)", in: detail) == 1)
        #expect(Self.count("askForNewEmail(request)", in: detail) == 1, "a contact pill or a link")
        #expect(Self.count("askForNewEmail(nil)", in: detail) == 1, "its compose button")
        #expect(Self.count("newEmailCover != nil || replyMessage != nil", in: detail) == 1, "counted among its presentations")
        #expect(Self.count(cover, in: detail) == 1)
        #expect(Self.count("ComposeView()", in: detail) == 0, "its compose button goes through the route")
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count(".safeAreaBar(edge: .top, spacing: 0) { ChatNewEmailSubjectLine(subject: model.carried.shownSubject) }", in: view) == 1)
        // Exactly these three screens take a request, so no two present for one.
        let takers = try Self.swiftFiles(under: "TabMail").filter {
            try Self.source($0).contains("publisher(for: .contactPillComposeTapped)")
        }
        #expect(takers.sorted() == [chatPath, detailPath, inboxPath].sorted())
    }

    // MARK: - Helpers

    static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The Swift files under `folder`, as paths from the repository's root.
    private static func swiftFiles(under folder: String) throws -> [String] {
        let base = root.standardizedFileURL.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { String($0.standardizedFileURL.path.dropFirst(base.count)) }
    }
}

/// A contact pill or a link while an email's chat is open: before, nothing took it; now the chat
/// takes it and the new email's chat comes up over it, with what the link brought.
@Suite("A new email from a link, over an open chat", .serialized, .processGlobalState)
@MainActor
struct ChatNewEmailRequestHostedTests {
    private static let link = MailtoRequest(
        to: ["\"Doe, John\" <john@example.com>"],
        cc: ["Sam Park <sam@example.com>"],
        bcc: ["alex@example.com"],
        subject: "Lunch on Friday",
        body: "Are you free at noon?")

    @Test("A link posted while a chat is open brings the new email's chat up over it with the person, the words, the subject, Cc and Bcc; Back with nothing changed closes it and saves nothing")
    func linkOverAnOpenChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkOverAnOpenChatBody() }
    }

    private func linkOverAnOpenChatBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try ThreadChatTests.install()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        saved.setChatView(on: true)
        defer {
            ChatPillState.shared.removeAllSessions()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let email = ThreadChatTests.header("601", from: "Ann Example", rfc: "request-1@example.com", thread: "request-thread", minutesAgo: 5)
        try ThreadChatTests.insert(email, pool: pool)
        let accounts = try await pool.read { db in try Account.fetchAll(db) }
        let navigationStore = NavigationStore()
        navigationStore.accounts = accounts
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack { ChatThreadView(messageId: email.id) }
                .environment(navigationStore)
                .environment(\.hasTabMailSession, true)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        func topPresented() -> UIViewController? {
            var top = controller.presentedViewController
            while let next = top?.presentedViewController { top = next }
            return top
        }
        func cleanUp() async {
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
        }
        do {
            try await ThreadChatTests.wait { ThreadChatTests.shows("Ann Example", in: controller.view) }
            #expect(ThreadChatTests.shows("Ann Example", in: controller.view), "control: the chat is open: \(ThreadChatTests.labels(controller.view).prefix(12))")
            try await ThreadChatTests.settle()
            #expect(topPresented() == nil, "control: nothing is presented over the chat")

            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            let expectedLine = ChatNewDraft.recipientsLine([ChatThread.Person(address: "john@example.com", name: "Doe, John")])
            let expectedHint = [expectedLine].compactMap { $0 }
            let expectedBcc = [ChatNewDraft.copyLine("Bcc", ["alex@example.com"])].compactMap { $0 }
            func newEmailView() -> UIView? {
                guard let view = topPresented()?.view,
                      Self.labels(of: ChatNewThreadView.hintId, in: view) == expectedHint else { return nil }
                return view
            }
            try await ThreadChatTests.wait { newEmailView() != nil }
            let presentedLabels = topPresented().map { Array(HostedAccessibility.labels(in: $0.view).prefix(16)) } ?? []
            let shown = try #require(newEmailView(), "the new email's chat came up over the chat: \(presentedLabels)")
            try await ThreadChatTests.wait { Self.fieldText(in: shown) == "Are you free at noon?" }
            #expect(Self.fieldText(in: shown) == "Are you free at noon?", "the body is the field's starting words")
            let labels = HostedAccessibility.labels(in: shown)
            #expect(labels.contains("Lunch on Friday"), "the subject slot reads the link's subject: \(labels.prefix(16))")
            #expect(!labels.contains(ChatNewEmailSubjectLine.text), "not New email")
            #expect(Self.labels(of: ChatNewThreadView.ccLineId, in: shown) == ["Cc: Sam Park."])
            let bccLine = Self.labels(of: ChatNewThreadView.bccLineId, in: shown)
            #expect(bccLine == expectedBcc)

            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: shown), "Back takes a tap")
            try await ThreadChatTests.wait { topPresented() == nil }
            #expect(topPresented() == nil, "Back closes the cover")
            try await ThreadChatTests.settle()
            let drafts = try await pool.read { db in try Draft.fetchCount(db) }
            #expect(drafts == 0, "nothing changed since the link: nothing in Drafts")
            #expect(ThreadChatTests.shows("Ann Example", in: controller.view), "the chat is still there")
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    // MARK: - Reading the screen

    private static func labels(of id: String, in view: UIView) -> [String] {
        HostedAccessibility.elements(under: view)
            .filter { HostedAccessibility.identifier(of: $0) == id }
            .compactMap(\.accessibilityLabel)
    }

    /// The field's words, nil while there is no editable field.
    private static func fieldText(in view: UIView) -> String? {
        if let text = view as? UITextView, text.isEditable { return text.text }
        if let text = view as? UITextField { return text.text }
        for subview in view.subviews {
            if let found = fieldText(in: subview) { return found }
        }
        return nil
    }
}
