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
        /// Whether the queue takes the push.
        var answer = true

        func queue(_ draftId: String, _ accountId: String) -> Bool {
            calls.append("\(draftId)|\(accountId)")
            return answer
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
        let raw = ["\"Doe, John\" <John@Example.com>; sam@example.com", "undisclosed-recipients:;"]
        let model = ChatNewThreadModel(account: nil, request: MailtoRequest(cc: raw, bcc: raw))
        for stored in [model.carried.cc, model.carried.bcc] {
            #expect(stored.count == 3, "one entry per mailbox: \(stored)")
            let readBack = RecipientEntry(stored)
            #expect(readBack.recipients.map(\.address) == ["John@Example.com", "sam@example.com"])
            #expect(readBack.recipients.first?.name == "Doe, John")
            #expect(readBack.leftovers == ["undisclosed-recipients:;"])
        }
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

    @Test("A saved row's own subject, Cc and Bcc win over what the link brought, an emptied Cc included")
    func rowFieldsWin() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let account = try FolderEpochTestFixture.makeAccount(id: Self.accountId, provider: .imap, pool: pool)
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: account, request: Self.link, queueDraftSave: { recorder.queue($0, $1) })
        model.words = "First words"
        let first = await model.saveIfNeeded()
        #expect(first == .saved, "control: the first save writes the link's subject, Cc and Bcc")
        let draftId = model.draftId
        let firstRow = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
        var changed = try #require(firstRow)
        #expect(changed.subject == "Lunch on Friday", "control: the link's subject was written")
        #expect(!changed.ccArray.isEmpty, "control: the link's Cc was written")
        // Changed on the compose card since: another subject, no Cc, another Bcc.
        changed.subject = "Changed on the card"
        changed.ccJSON = Draft.encodeStringArray([])
        changed.bccJSON = Draft.encodeStringArray(["bo@example.com"])
        let edited = changed
        try await pool.write { db in try edited.update(db) }
        model.words = "Second words"
        let second = await model.saveIfNeeded(now: { Date().addingTimeInterval(1) })
        let afterRow = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
        let after = try #require(afterRow)
        #expect(second == .saved)
        #expect(after.body == "Second words")
        #expect(after.subject == "Changed on the card")
        #expect(after.ccArray.isEmpty, "an emptied Cc is not filled again from the link")
        #expect(after.bccArray == ["bo@example.com"])
    }

    @Test("After a save the queue refused to push, the link's own words or an emptied field are saved and pushed", arguments: [false, true])
    func refusedPushThenBackToTheLink(emptied: Bool) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let account = try FolderEpochTestFixture.makeAccount(id: Self.accountId, provider: .imap, pool: pool)
        let recorder = QueueRecorder()
        recorder.answer = false
        let model = ChatNewThreadModel(account: account, request: Self.link, queueDraftSave: { recorder.queue($0, $1) })
        model.words = "Edited words"
        let refused = await model.saveIfNeeded()
        let draftId = model.draftId
        let committedRow = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
        #expect(refused == .refused(ChatNewDraftSave.notQueuedMessage))
        #expect(committedRow?.body == "Edited words", "control: the edit is saved on the device, its push refused")
        recorder.answer = true
        let linkBody = try #require(Self.link.body)
        let back = emptied ? "" : linkBody
        model.words = back
        let retried = await model.saveIfNeeded(now: { Date().addingTimeInterval(1) })
        let afterRow = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
        let after = try #require(afterRow)
        #expect(retried == .saved)
        #expect(after.body == back, "the draft holds what the field holds")
        #expect(recorder.calls.count == 2, "the push is tried again")
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
        #expect(Self.count("guard selectedMessageId == nil, pushedMessageId == nil, !isAnyListPresentation else { return }", in: inbox) == 1,
                "an email opened over the list, by a row, a pill or in Search, takes it itself")
        #expect(Self.count("newEmailCover != nil || showSearch || viewModel.showCompose || replyMessage != nil || draftOpen != nil || agentCompose != nil || moveMessageId != nil || moveThreadGroup != nil || labelMenuMessage != nil || showLabelFilterPicker", in: inbox) == 1,
                "every sheet and cover the list presents counts, its own new email's included")
        #expect(Self.count(".onChange(of: isAnyListPresentation, initial: true) { _, up in listPresentationWriter?.isUp = up } .onDisappear { listPresentationWriter?.isUp = false }", in: inbox) == 1,
                "the list reports what it has up for the detail column")
        let navigation = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count("pushedMessageId: $pushedMessageId) .environment(\\.listPresentationWriter, listPresentation)", in: navigation) == 1,
                "the list column writes the state")
        #expect(Self.count("MessageDetailContainer(selectedMessageId: selectedMessageId, notificationOpenedId: notificationOpenedId) .environment(\\.listPresentationBesideDetail, listPresentation)", in: navigation) == 1,
                "only the detail column reads it, so an email opened in Search still takes a request")
        #expect(Self.count("\\.listPresentationBesideDetail", in: navigation) == 1)
        #expect(Self.count("\\.listPresentationWriter", in: navigation) == 1)
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: viewModel.primaryAccount, composeAccount: viewModel.primaryAccount)", in: inbox) == 1)
        #expect(Self.count(cover, in: inbox) == 1)
        #expect(Self.count("prefillTo:", in: inbox) == 0, "compose is filled from a request only through the cover")
        let chat = try Self.source(chatPath)
        #expect(Self.count("guard isOnScreen, !isAnyPresentation, listPresentationBesideDetail?.isUp != true else { return }", in: chat) == 1,
                "a pushed screen, or its email card's screen, takes it instead; none while the list beside it has something up")
        #expect(Self.count("|| forwardMessage != nil || showsReplyTo || showsMove || newEmailCover != nil", in: chat) == 1,
                "its own cover counts as presented")
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: Account.primary(), composeAccount: Account.primary())", in: chat) == 1)
        #expect(Self.count(cover, in: chat) == 1)
        let detail = try Self.source(detailPath)
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: Account.primary(), composeAccount: nil)", in: detail) == 1)
        #expect(Self.count("askForNewEmail(request)", in: detail) == 1, "a contact pill or a link")
        #expect(Self.count("guard !isAnyCoverPresented, listPresentationBesideDetail?.isUp != true else { return }", in: detail) == 1,
                "none while something is up over it or the list beside it has something up")
        #expect(Self.count("askForNewEmail(nil)", in: detail) == 1, "its compose button")
        #expect(Self.count("newEmailCover != nil || replyMessage != nil", in: detail) == 1, "counted among its presentations")
        #expect(Self.count(cover, in: detail) == 1)
        #expect(Self.count("ComposeView()", in: detail) == 0, "its compose button goes through the route")
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count(".safeAreaBar(edge: .top, spacing: 0) { ChatNewEmailSubjectLine(subject: model.carried.shownSubject) }", in: view) == 1)
        // Exactly these three screens take a request: a structural check only; which instance
        // takes it is shown by the hosted tests below.
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

/// Which screen takes a contact pill's or a link's request, each mounted as the app shows it: an
/// open chat, the list, the email screen. Each takes it while it is on top with nothing of its own
/// up; in the detail column, none while the list beside it has a sheet or cover up; a second
/// request never replaces a new email already up. Before, an open chat took none.
@Suite("A new email from a link, on each screen", .serialized, .processGlobalState)
@MainActor
struct ChatNewEmailRequestHostedTests {
    private static let link = MailtoRequest(
        to: ["\"Doe, John\" <john@example.com>"],
        cc: ["Sam Park <sam@example.com>"],
        bcc: ["alex@example.com"],
        subject: "Lunch on Friday",
        body: "Are you free at noon?")
    /// A second request, to someone else.
    private static let other = MailtoRequest(to: ["Maria Lee <maria@example.com>"])

    /// The new email's hint line for the link's person.
    private static var johnHint: [String] {
        [ChatNewDraft.recipientsLine([ChatThread.Person(address: "john@example.com", name: "Doe, John")])].compactMap { $0 }
    }

    // MARK: - An open chat

    @Test("A link posted while a chat is open brings the new email's chat up over it with the person, the words, the subject, Cc and Bcc; a second link leaves it up; Back with nothing changed closes it and saves nothing; in the detail column, none while the list beside it has something up")
    func linkOverAnOpenChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkOverAnOpenChatBody() }
    }

    private func linkOverAnOpenChatBody() async throws {
        try await withScreen { seed in
            NavigationStack { ChatThreadView(messageId: seed.email.id) }
                .environment(\.listPresentationBesideDetail, seed.state)
        } body: { screen in
            try await ThreadChatTests.wait { ThreadChatTests.shows("Ann Example", in: screen.view) }
            #expect(ThreadChatTests.shows("Ann Example", in: screen.view), "control: the chat is open: \(ThreadChatTests.labels(screen.view).prefix(12))")
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() == nil, "control: nothing is presented over the chat")
            try await Self.notTakenBesideTheList(screen)

            let shown = try await Self.postedLinkShowsNewEmail(screen)
            try await ThreadChatTests.wait { Self.fieldText(in: shown) == "Are you free at noon?" }
            #expect(Self.fieldText(in: shown) == "Are you free at noon?", "the body is the field's starting words")
            let labels = HostedAccessibility.labels(in: shown)
            #expect(labels.contains("Lunch on Friday"), "the subject slot reads the link's subject: \(labels.prefix(16))")
            #expect(!labels.contains(ChatNewEmailSubjectLine.text), "not New email")
            #expect(Self.labels(of: ChatNewThreadView.ccLineId, in: shown) == ["Cc: Sam Park."])
            let expectedBcc = [ChatNewDraft.copyLine("Bcc", ["alex@example.com"])].compactMap { $0 }
            let bccLine = Self.labels(of: ChatNewThreadView.bccLineId, in: shown)
            #expect(bccLine == expectedBcc)

            try await Self.secondLeavesItUp(screen)
            try await Self.backClosesAndSavesNothing(screen)
            #expect(ThreadChatTests.shows("Ann Example", in: screen.view), "the chat is still there")
        }
    }

    // MARK: - The list

    @Test("The list with nothing over it takes a link and reports its new email up; a second link leaves it up; with Search up the list takes none and reports Search up")
    func linkOverTheList() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkOverTheListBody() }
    }

    private func linkOverTheListBody() async throws {
        try await withScreen { seed in
            NavigationStack {
                InboxView(title: "Inbox", folders: seed.inbox, selection: .unified(.inbox),
                          selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))
            }
            .environment(\.listPresentationWriter, seed.state)
        } body: { screen in
            try await ThreadChatTests.wait { Self.searchButton(in: screen.view) != nil }
            #expect(Self.searchButton(in: screen.view) != nil, "control: the list is up: \(ThreadChatTests.labels(screen.view).prefix(20))")
            #expect(!screen.state.isUp, "control: nothing is up over the list")

            _ = try await Self.postedLinkShowsNewEmail(screen)
            #expect(screen.state.isUp, "the list reports its new email up, for the detail column beside it")
            try await Self.secondLeavesItUp(screen)
            try await Self.backClosesAndSavesNothing(screen)
            try await ThreadChatTests.wait { !screen.state.isUp }
            #expect(!screen.state.isUp, "closed: the list reports nothing up")

            let search = try #require(Self.searchButton(in: screen.view))
            #expect(search.accessibilityActivate(), "control: Search takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() != nil }
            let searchSheet = screen.topPresented()
            #expect(searchSheet != nil, "control: Search is up")
            #expect(screen.state.isUp, "the list reports Search up, so the detail column beside it takes none")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            let stayed = try await Self.keeps { screen.topPresented() === searchSheet && Self.newEmailView(screen) == nil }
            #expect(stayed, "with Search up, the list takes none")
        }
    }

    // MARK: - The email screen

    @Test("The email screen with nothing over it takes a link and a second link leaves its new email up; in the detail column, none while the list beside it has something up; its compose button opens an empty new email's chat")
    func linkOverTheEmailScreen() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkOverTheEmailScreenBody() }
    }

    private func linkOverTheEmailScreenBody() async throws {
        try await withScreen { seed in
            NavigationStack { MessageDetailView(messageId: seed.email.id) }
                .environment(\.listPresentationBesideDetail, seed.state)
        } body: { screen in
            try await ThreadChatTests.wait { Self.composeButton(in: screen.view) != nil }
            #expect(Self.composeButton(in: screen.view) != nil, "control: the email screen is up: \(ThreadChatTests.labels(screen.view).prefix(20))")
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() == nil, "control: nothing is presented over the email")
            try await Self.notTakenBesideTheList(screen)

            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.secondLeavesItUp(screen)
            try await Self.backClosesAndSavesNothing(screen)

            let compose = try #require(Self.composeButton(in: screen.view))
            #expect(compose.accessibilityActivate(), "control: the compose button takes a tap")
            try await ThreadChatTests.wait { Self.presentedNewEmail(screen) != nil }
            let presentedLabels = screen.topPresented().map { Array(HostedAccessibility.labels(in: $0.view).prefix(16)) } ?? []
            let empty = try #require(Self.presentedNewEmail(screen), "the compose button opens the new email's chat: \(presentedLabels)")
            #expect(Self.fieldText(in: empty)?.isEmpty == true, "with no words")
            #expect(Self.labels(of: ChatNewThreadView.ccLineId, in: empty).isEmpty, "and no Cc")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: empty), "Back takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() == nil }
            #expect(screen.topPresented() == nil, "Back closes it")
        }
    }

    // MARK: - Compose, with the chat view off

    @Test("A cover decided for compose shows compose filled with the link's To, Cc, Bcc, subject and body, whatever the setting is when it shows")
    func composeFallback() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await composeFallbackBody() }
    }

    private func composeFallbackBody() async throws {
        let full = MailtoRequest(
            to: ["\"Doe, John\" <john@example.com>", "maria@example.com"], cc: ["Sam Park <sam@example.com>"],
            bcc: ["alex@example.com"], subject: "Lunch on Friday", body: "Are you free at noon?")
        // Decided for compose (the chat view off when the request came); shown with it on.
        try await withScreen { seed in
            ChatNewEmailCoverView(cover: .make(
                request: full, opensInChat: false, signedIn: true, chatAccount: nil, composeAccount: seed.account))
        } body: { screen in
            var fields: [String: String] = [:]
            try await ThreadChatTests.wait {
                fields = Self.composeRecipients(screen.view)
                return fields["to"]?.isEmpty == false
            }
            #expect(Self.addresses(fields["to"]) == ["john@example.com", "maria@example.com"], "compose, filled: \(fields)")
            #expect(Self.addresses(fields["cc"]) == ["sam@example.com"])
            #expect(Self.addresses(fields["bcc"]) == ["alex@example.com"], "Bcc stays Bcc")
            let texts = Self.fieldTexts(in: screen.view)
            let hasBody = texts.contains { $0.contains("Are you free at noon?") }
            #expect(texts.contains("Lunch on Friday"), "the subject: \(texts)")
            #expect(hasBody, "the body: \(texts)")
            #expect(!HostedAccessibility.identifiers(in: screen.view).contains(ChatNewThreadView.backId), "not the chat")
        }
        let router = AgentToolRouter.shared
        try await ThreadChatTests.wait { router.composePresentationCount == 0 }
        #expect(router.composePresentationCount == 0, "control: compose reported itself gone")
    }

    // MARK: - Steps

    /// In the detail column with the list beside it showing a sheet or cover, a request is not
    /// taken; then the list has nothing up again.
    private static func notTakenBesideTheList(_ screen: Screen) async throws {
        screen.state.isUp = true
        NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: link.toUserInfo())
        let stayed = try await keeps { screen.topPresented() == nil }
        #expect(stayed, "behind the list's sheet or cover, the detail column takes none")
        screen.state.isUp = false
    }

    /// Posts the link and waits for the new email's chat to come up over the screen.
    @discardableResult
    private static func postedLinkShowsNewEmail(_ screen: Screen) async throws -> UIView {
        NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: link.toUserInfo())
        try await ThreadChatTests.wait { newEmailView(screen) != nil }
        let presentedLabels = screen.topPresented().map { Array(HostedAccessibility.labels(in: $0.view).prefix(16)) } ?? []
        return try #require(newEmailView(screen), "the new email's chat came up: \(presentedLabels)")
    }

    /// A second request while the new email is up: not taken, the first stays as it is.
    private static func secondLeavesItUp(_ screen: Screen) async throws {
        let first = screen.topPresented()
        #expect(first != nil, "control: the new email is up")
        NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: other.toUserInfo())
        let stayed = try await keeps { screen.topPresented() === first && newEmailView(screen) != nil }
        let hint = screen.topPresented().map { labels(of: ChatNewThreadView.hintId, in: $0.view) } ?? []
        #expect(stayed, "the new email up is not replaced: \(hint)")
    }

    /// Back on the new email, unchanged since the link: it closes, and Drafts stays empty.
    private static func backClosesAndSavesNothing(_ screen: Screen) async throws {
        let shown = try #require(newEmailView(screen), "control: the new email is up")
        #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: shown), "Back takes a tap")
        try await ThreadChatTests.wait { screen.topPresented() == nil }
        #expect(screen.topPresented() == nil, "Back closes the cover")
        try await ThreadChatTests.settle()
        let drafts = try await screen.pool.read { db in try Draft.fetchCount(db) }
        #expect(drafts == 0, "nothing changed since the link: nothing in Drafts")
    }

    // MARK: - Mounting

    /// What a screen is mounted with: the email, the Inbox folders, the account, and the list's
    /// presentation state, given as the list's or the detail column's.
    struct Seed {
        let email: MessageHeader
        let inbox: [Folder]
        let account: Account?
        let state: ListPresentationState
    }

    /// A mounted screen: its controller, the app database, and the list's presentation state.
    @MainActor
    struct Screen {
        let controller: UIViewController
        let pool: DatabasePool
        let state: ListPresentationState
        var view: UIView { controller.view }

        /// What is presented over the screen, topmost; nil for nothing.
        func topPresented() -> UIViewController? {
            var top = controller.presentedViewController
            while let next = top?.presentedViewController { top = next }
            return top
        }
    }

    /// Mounts `root` on an installed app database holding one email, with the chat view on and
    /// signed in and the AI queue held, runs `body`, then takes it all down, also when it throws.
    private func withScreen<Root: View>(
        @ViewBuilder _ root: (Seed) -> Root,
        body: (Screen) async throws -> Void
    ) async throws {
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
        let accountId = ThreadChatTests.accountA
        let accounts = try await pool.read { db in try Account.fetchAll(db) }
        let inbox = try await pool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.inbox.rawValue).fetchAll(db)
        }
        let navigationStore = NavigationStore()
        navigationStore.accounts = accounts
        let state = ListPresentationState()
        let seed = Seed(email: email, inbox: inbox, account: accounts.first { $0.id == accountId }, state: state)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: AnyView(
            root(seed)
                .environment(navigationStore)
                .environment(\.hasTabMailSession, true)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        func cleanUp() async {
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
        }
        do {
            try await body(Screen(controller: controller, pool: pool, state: state))
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    // MARK: - Reading the screen

    /// The new email's chat up over the screen with the link's person, else nil.
    private static func newEmailView(_ screen: Screen) -> UIView? {
        guard let view = screen.topPresented()?.view,
              labels(of: ChatNewThreadView.hintId, in: view) == johnHint else { return nil }
        return view
    }

    /// A new email's chat up over the screen, whoever it is to, else nil.
    private static func presentedNewEmail(_ screen: Screen) -> UIView? {
        guard let view = screen.topPresented()?.view,
              HostedAccessibility.identifiers(in: view).contains(ChatNewThreadView.backId) else { return nil }
        return view
    }

    /// Whether `condition` holds throughout the next 1.5 seconds, checked every 100 ms.
    private static func keeps(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<15 {
            guard condition() else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func searchButton(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == "Search" }
    }

    private static func composeButton(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == "Compose" }
    }

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

    /// The text of every text field and text view under `view`.
    private static func fieldTexts(in view: UIView) -> [String] {
        var found: [String] = []
        if let text = view as? UITextView { found.append(text.text ?? "") }
        if let text = view as? UITextField { found.append(text.text ?? "") }
        return found + view.subviews.flatMap { fieldTexts(in: $0) }
    }

    /// Compose's addresses by field ("to", "cc", "bcc"), as its recipient fields name them.
    private static func composeRecipients(_ view: UIView) -> [String: String] {
        var found: [String: String] = [:]
        for element in HostedAccessibility.elements(under: view) {
            guard let identifier = HostedAccessibility.identifier(of: element),
                  identifier.hasPrefix("recipientInput-") else { continue }
            found[String(identifier.dropFirst("recipientInput-".count))] = element.accessibilityLabel ?? ""
        }
        return found
    }

    private static func addresses(_ field: String?) -> [String] {
        (field ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
