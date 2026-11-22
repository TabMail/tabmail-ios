/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Synchronization
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
        let draftId = model.draftId
        let untouched = await model.saveIfNeeded()
        let before = try await pool.read { db in try Draft.fetchCount(db) }
        #expect(untouched == .saved)
        #expect(before == 0, "Back with nothing changed leaves nothing in Drafts")
        #expect(recorder.calls.isEmpty)
        model.words = "Are you free at noon? Or one?"
        let first = await model.saveIfNeeded()
        let firstRow = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
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
        let secondRow = try await pool.read { db in try Draft.fetchOne(db, key: draftId) }
        let resaved = try #require(secondRow)
        #expect(second == .saved)
        #expect(resaved.body == "Lunch at one, then.")
        #expect(resaved.subject == "Lunch on Friday")
        #expect(resaved.ccArray == saved.ccArray)
        #expect(resaved.bccArray == ["alex@example.com"])
        #expect(recorder.calls == Array(repeating: "\(draftId)|\(Self.accountId)", count: 2))
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
        #expect(Self.count("guard selectedMessageId == nil, pushedMessageId == nil, newEmail == nil, !isAnyListPresentation, !ChatNewEmailCover.composeOrPreviewIsUp else { return }", in: inbox) == 1,
                "an email opened over the list, by a row, a pill or in Search, takes it itself; the list's own new email takes none; none under a compose, a draft or a preview anywhere")
        #expect(Self.count("newEmailCover != nil || showSearch || viewModel.showCompose || replyMessage != nil || draftOpen != nil || agentCompose != nil || moveMessageId != nil || moveThreadGroup != nil || labelMenuMessage != nil || showLabelFilterPicker", in: inbox) == 1,
                "every sheet and cover the list presents counts, its own new email's included")
        #expect(Self.count(".onChange(of: isAnyListPresentation, initial: true) { _, up in listPresentationWriter?.isUp = up }", in: inbox) == 1,
                "the list reports what it has up for the detail column")
        #expect(Self.count("listPresentationWriter?.isUp =", in: inbox) == 1,
                "and only as that changes: a screen pushed over the list hides the list, not its Search")
        let navigation = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count("pushedMessageId: $pushedMessageId) .environment(\\.listPresentationWriter, listPresentation)", in: navigation) == 1,
                "the list column writes the state")
        // Every screen that opens in the detail column reads it: the selected email and an email
        // pill's email. Nothing in the list column does, so an email opened in Search still takes one.
        #expect(Self.count("MessageDetailContainer(selectedMessageId: selectedMessageId, notificationOpenedId: notificationOpenedId) .environment(\\.listPresentationBesideDetail, listPresentation)", in: navigation) == 1,
                "the selected email in the detail column reads it")
        #expect(Self.count("PushedMessageDestination(messageId: id) .environment(\\.listPresentationBesideDetail, listPresentation)", in: navigation) == 1,
                "an email pill's email, which opens in the detail column on iPad, reads it")
        #expect(Self.count("\\.listPresentationBesideDetail", in: navigation) == 2, "and nothing else in the navigation")
        #expect(Self.count("\\.listPresentationWriter", in: navigation) == 1)
        // A plain property would be a new, empty state each time the navigation is rebuilt, while
        // the list, which reports only changes, still has its Search up: the detail column beside
        // it would then take a request behind Search. Held as the navigation's own state, the list
        // and the detail column share one state for the navigation's life.
        #expect(Self.count("@State private var listPresentation = ListPresentationState()", in: navigation) == 1,
                "the navigation holds the one state for its life")
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: viewModel.primaryAccount, composeAccount: viewModel.primaryAccount)", in: inbox) == 1)
        #expect(Self.count(cover, in: inbox) == 1)
        #expect(Self.count("prefillTo:", in: inbox) == 0, "compose is filled from a request only through the cover")
        let chat = try Self.source(chatPath)
        #expect(Self.count("guard isOnScreen, !isAnyPresentation, listPresentationBesideDetail?.isUp != true, !ChatNewEmailCover.composeOrPreviewIsUp else { return }", in: chat) == 1,
                "a pushed screen, or its email card's screen, takes it instead; none while the list beside it has something up, nor under a compose, a draft or a preview anywhere")
        #expect(Self.count("|| forwardMessage != nil || showsReplyTo || showsMove || newEmailCover != nil", in: chat) == 1,
                "its own cover counts as presented")
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: Account.primary(), composeAccount: Account.primary())", in: chat) == 1)
        #expect(Self.count(cover, in: chat) == 1)
        let detail = try Self.source(detailPath)
        #expect(Self.count("newEmailCover = .make( request: request, opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession, chatAccount: Account.primary(), composeAccount: nil)", in: detail) == 1)
        #expect(Self.count("askForNewEmail(request)", in: detail) == 1, "a contact pill or a link")
        #expect(Self.count("guard viewModel.isViewVisible, !isAnyCoverPresented, listPresentationBesideDetail?.isUp != true, !ChatNewEmailCover.composeOrPreviewIsUp else { return }", in: detail) == 1,
                "none under a screen pushed over it, while something is up over it, while the list beside it has something up, or under a compose, a draft or a preview anywhere")
        #expect(Self.count("askForNewEmail(nil)", in: detail) == 1, "its compose button")
        #expect(Self.count("newEmailCover != nil || replyMessage != nil", in: detail) == 1, "counted among its presentations")
        #expect(Self.count(cover, in: detail) == 1)
        #expect(Self.count("ComposeView()", in: detail) == 0, "its compose button goes through the route")
        // Search and the screens opened in it are in the list column: given the detail column's
        // state there, an email opened in Search would take nothing while Search is up. So the
        // state is given out only by the navigation, in the three places above, anywhere in the app.
        #expect(Self.count("listPresentationBesideDetail", in: inbox) == 0, "the list column never reads the detail column's state")
        for path in try Self.swiftFiles(under: "TabMail") where path != "TabMail/Views/MailNavigationView.swift" {
            let text = try Self.source(path)
            #expect(Self.count(".environment(\\.listPresentationBesideDetail", in: text) == 0, "\(path) gives out no detail-column state")
            #expect(Self.count(".environment(\\.listPresentationWriter", in: text) == 0, "\(path) gives out no list state")
        }
        // A request is logged without its recipients: the debug log is kept on the device.
        for (path, text) in [(inboxPath, inbox), (chatPath, chat), (detailPath, detail)] {
            #expect(Self.count("request.to", in: text) == 0, "\(path) logs no recipient")
        }
        let coverFile = try Self.source("TabMail/Views/Chat/ChatNewEmailCover.swift")
        #expect(Self.count("AgentToolRouter.shared.isComposeUp || PreviewFreezeGate.shared.isFrozen", in: coverFile) == 1,
                "a compose or a draft anywhere, or a preview, holds every request")
        #expect(Self.count("NavigationStack { ChatNewThreadView(model: model) } // ADR-IOS-030", in: coverFile) == 1)
        #expect(Self.count(".onAppear { AgentToolRouter.shared.composePresentationDidBegin() } .onDisappear { AgentToolRouter.shared.composePresentationDidEnd() }", in: coverFile) == 1,
                "the new email's chat cover holds the agent's compose as compose does")
        let router = try Self.source("TabMail/Services/AI/AgentToolRouter.swift")
        #expect(Self.count("var isComposeUp: Bool { presentationCount > 0 }", in: router) == 1)
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count(".safeAreaBar(edge: .top, spacing: 0) { ChatNewEmailSubjectLine(subject: model.carried.shownSubject) }", in: view) == 1)
        // Exactly these three screens take a request: a structural check only. The hosted tests
        // below show each one taking it, or not, as mounted.
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

    @Test("A link posted while a chat is open brings the new email's chat up over it with the person, the words, the subject, Cc and Bcc; a second link leaves it up; Back with nothing changed closes it and saves nothing; in the detail column, none while the list beside it has something up; with its email card up, the card's email screen takes it")
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
            // One mailbox with no name: its line names it by the address's name part.
            #expect(Self.labels(of: ChatNewThreadView.bccLineId, in: shown) == ["Bcc: alex."])

            try await Self.secondLeavesItUp(screen)
            try await Self.backClosesAndSavesNothing(screen)
            #expect(ThreadChatTests.shows("Ann Example", in: screen.view), "the chat is still there")

            // The email card: its email screen, on top, takes the request, over the card.
            let bubble = try #require(Self.bubble(in: screen.view), "control: the email's bubble: \(ThreadChatTests.labels(screen.view).prefix(12))")
            #expect(bubble.accessibilityActivate(), "control: the bubble opens the email card")
            try await ThreadChatTests.wait { screen.topPresented() != nil }
            let card = screen.topPresented()
            #expect(card != nil, "control: the email card is up")
            try await ThreadChatTests.settle()
            try await ThreadChatTests.settle()
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            try await ThreadChatTests.wait { Self.newEmailView(screen) != nil }
            let overCardLabels = screen.topPresented().map { Array(HostedAccessibility.labels(in: $0.view).prefix(16)) } ?? []
            let overCard = try #require(Self.newEmailView(screen), "the card's email screen takes it: \(overCardLabels)")
            #expect(card?.presentedViewController != nil, "the new email comes up over the card")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: overCard), "Back takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() === card }
            #expect(screen.topPresented() === card, "Back returns to the card")

            // The chat under the card took none: once the card is closed nothing else comes up,
            // and the chat takes the next.
            let closedCard = try #require(card)
            await Self.swipeDown(closedCard)
            try await ThreadChatTests.wait { screen.topPresented() == nil }
            #expect(screen.topPresented() == nil, "control: the card is closed")
            let nothing = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothing, "nothing comes up once the card is closed")
            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.backClosesAndSavesNothing(screen)
        }
    }

    // MARK: - A screen pushed over another

    @Test("With a screen pushed over another of its kind, only the one on top takes a link; once its new email is closed and it is popped, nothing else comes up and the one below takes the next", arguments: [false, true])
    func linkOverAPushedScreen(chat: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkOverAPushedScreenBody(chat: chat) }
    }

    /// An email screen with an email pill's email screen pushed over it, or a chat with another
    /// chat pushed over it.
    private func linkOverAPushedScreenBody(chat: Bool) async throws {
        let push = Push()
        try await withScreen { seed in
            Stacked(push: push) {
                if chat { ChatThreadView(messageId: seed.email.id) } else { MessageDetailView(messageId: seed.email.id) }
            } top: { id in
                if chat { ChatThreadView(messageId: id) } else { MessageDetailView(messageId: id) }
            }
        } body: { screen in
            // The chat shows its person; the email screen its compose button.
            let shows: (UIView) -> Bool = chat
                ? { ThreadChatTests.shows("Ann Example", in: $0) }
                : { Self.composeButton(in: $0) != nil }
            try await ThreadChatTests.wait { Self.depth(screen) == 1 && shows(screen.view) }
            let shown = shows(screen.view)
            #expect(shown, "control: the screen is up: \(ThreadChatTests.labels(screen.view).prefix(12))")
            try await ThreadChatTests.settle()
            push.id = screen.email.id
            try await ThreadChatTests.wait { Self.depth(screen) == 2 }
            #expect(Self.depth(screen) == 2, "control: a second screen is pushed over the first")
            try await ThreadChatTests.settle()

            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.backClosesAndSavesNothing(screen)
            let nothingOnTop = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothingOnTop, "the screen below took none: nothing comes up once the new email is closed")

            push.id = nil
            try await ThreadChatTests.wait { Self.depth(screen) == 1 }
            #expect(Self.depth(screen) == 1, "control: popped back to the first screen")
            let nothingBelow = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothingBelow, "nothing comes up once the screen below shows again")
            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.backClosesAndSavesNothing(screen)
        }
    }

    @Test("An email opened inside the list's Search, which carries the list's surroundings with Search up, takes a link")
    func linkOverAnEmailInSearch() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkOverAnEmailInSearchBody() }
    }

    private func linkOverAnEmailInSearchBody() async throws {
        try await withScreen { seed in
            NavigationStack { ChatThreadView(messageId: seed.email.id) }
                .environment(\.listPresentationWriter, seed.state)
        } body: { screen in
            screen.state.isUp = true
            try await ThreadChatTests.wait { ThreadChatTests.shows("Ann Example", in: screen.view) }
            #expect(ThreadChatTests.shows("Ann Example", in: screen.view), "control: the chat is open: \(ThreadChatTests.labels(screen.view).prefix(12))")
            try await ThreadChatTests.settle()
            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.backClosesAndSavesNothing(screen)
        }
    }

    // MARK: - The list

    @Test("The list with nothing over it takes a link and reports its new email up; a second link leaves it up; while the new email its compose button pushed is open it takes none; with Search up it takes none and reports Search up")
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

            // The new email the list's compose button pushes: while it is open, the list takes none.
            let compose = try #require(Self.composeButton(in: screen.view), "control: the list's compose button: \(ThreadChatTests.labels(screen.view).prefix(20))")
            #expect(compose.accessibilityActivate(), "control: the compose button takes a tap")
            try await ThreadChatTests.wait { HostedAccessibility.identifiers(in: screen.view).contains(ChatNewThreadView.backId) }
            #expect(HostedAccessibility.identifiers(in: screen.view).contains(ChatNewThreadView.backId), "control: the button pushed the new email's chat")
            #expect(screen.topPresented() == nil, "control: pushed, not presented")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            let notCovered = try await Self.keeps { screen.topPresented() == nil }
            #expect(notCovered, "a new email being written is not covered by another")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: screen.view), "Back takes a tap")
            try await ThreadChatTests.wait { Self.searchButton(in: screen.view) != nil }
            #expect(Self.searchButton(in: screen.view) != nil, "control: back on the list")

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

    @Test("With Search up over the list and an email pill's email pushed over the list beneath it, the list still reports Search up and the pushed email takes no link; once Search is closed nothing comes up and the pushed email takes the next; back on the list, nothing comes up")
    func linkWithAnEmailPushedBeneathSearch() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkWithAnEmailPushedBeneathSearchBody() }
    }

    /// The list column as the navigation mounts it on iPhone: the list writes its state, and an
    /// email pill's email is pushed over it through `pushedMessageId` and reads the state.
    private func linkWithAnEmailPushedBeneathSearchBody() async throws {
        let push = Push()
        try await withScreen { seed in
            Stacked(push: push) {
                InboxView(title: "Inbox", folders: seed.inbox, selection: .unified(.inbox),
                          selectedMessageId: .constant(nil), pushedMessageId: Bindable(push).id)
                    .environment(\.listPresentationWriter, seed.state)
            } top: { id in
                PushedMessageDestination(messageId: id)
                    .environment(\.listPresentationBesideDetail, seed.state)
            }
        } body: { screen in
            try await ThreadChatTests.wait { Self.searchButton(in: screen.view) != nil }
            let search = try #require(Self.searchButton(in: screen.view), "control: the list is up: \(ThreadChatTests.labels(screen.view).prefix(20))")
            #expect(search.accessibilityActivate(), "control: Search takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() != nil }
            let searchSheet = try #require(screen.topPresented(), "control: Search is up")
            #expect(screen.state.isUp, "control: the list reports Search up")

            push.id = screen.email.id
            try await ThreadChatTests.wait { Self.depth(screen) == 2 }
            #expect(Self.depth(screen) == 2, "control: the email is pushed over the list, beneath Search")
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() === searchSheet, "control: Search is still up")
            #expect(screen.state.isUp, "the list, hidden by the push, still has Search up and still reports it")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            let stayed = try await Self.keeps { screen.topPresented() === searchSheet && Self.newEmailView(screen) == nil }
            #expect(stayed, "beneath Search, the pushed email takes none")

            let done = try #require(Self.button("Done", in: searchSheet.view), "control: Search's Done: \(ThreadChatTests.labels(searchSheet.view).prefix(16))")
            #expect(done.accessibilityActivate(), "control: Done takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() == nil }
            #expect(screen.topPresented() == nil, "control: Search is closed")
            let nothing = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothing, "nothing comes up once Search is closed")
            try await ThreadChatTests.wait { !screen.state.isUp }
            #expect(!screen.state.isUp, "the list under the pushed email reports Search closed")
            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.backClosesAndSavesNothing(screen)

            push.id = nil
            try await ThreadChatTests.wait { Self.depth(screen) == 1 }
            #expect(Self.depth(screen) == 1, "control: back on the list")
            let nothingOnTheList = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothingOnTheList, "the list under the pushed email took none: nothing comes up back on it")
        }
    }

    @Test("The list with an email open over it, selected or pushed from an email pill, takes no link", arguments: [true, false])
    func listWithAnEmailOpenTakesNone(selected: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await listWithAnEmailOpenTakesNoneBody(selected: selected) }
    }

    private func listWithAnEmailOpenTakesNoneBody(selected: Bool) async throws {
        try await withScreen { seed in
            NavigationStack {
                InboxView(title: "Inbox", folders: seed.inbox, selection: .unified(.inbox),
                          selectedMessageId: .constant(selected ? seed.email.id : nil),
                          pushedMessageId: .constant(selected ? nil : seed.email.id))
            }
            .environment(\.listPresentationWriter, seed.state)
        } body: { screen in
            try await ThreadChatTests.wait { Self.searchButton(in: screen.view) != nil }
            #expect(Self.searchButton(in: screen.view) != nil, "control: the list is up: \(ThreadChatTests.labels(screen.view).prefix(20))")
            #expect(screen.topPresented() == nil, "control: nothing is presented over the list")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            let nothing = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothing, "the email open over the list takes it, not the list")
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

    // MARK: - Compose through the email screen

    @Test("Signed out with the chat view on, or with the chat view off, a link on the email screen opens compose filled with its To, Cc, Bcc, subject and body", arguments: [(true, false), (false, true)])
    func fallbackThroughTheEmailScreen(chatView: Bool, signedIn: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await fallbackThroughTheEmailScreenBody(chatView: chatView, signedIn: signedIn) }
    }

    private func fallbackThroughTheEmailScreenBody(chatView: Bool, signedIn: Bool) async throws {
        try await withScreen(chatView: chatView, signedIn: signedIn) { seed in
            NavigationStack { MessageDetailView(messageId: seed.email.id) }
        } body: { screen in
            try await ThreadChatTests.wait { Self.composeButton(in: screen.view) != nil }
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() == nil, "control: nothing is presented over the email")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            var fields: [String: String] = [:]
            try await ThreadChatTests.wait {
                fields = screen.topPresented().map { Self.composeRecipients($0.view) } ?? [:]
                return fields["to"]?.isEmpty == false
            }
            let presented = try #require(screen.topPresented(), "compose came up: \(fields)")
            #expect(Self.addresses(fields["to"]) == ["john@example.com"], "compose, filled: \(fields)")
            #expect(Self.addresses(fields["cc"]) == ["sam@example.com"])
            #expect(Self.addresses(fields["bcc"]) == ["alex@example.com"], "Bcc stays Bcc")
            let texts = Self.fieldTexts(in: presented.view)
            let hasBody = texts.contains { $0.contains("Are you free at noon?") }
            #expect(texts.contains("Lunch on Friday"), "the subject: \(texts)")
            #expect(hasBody, "the body: \(texts)")
            #expect(!HostedAccessibility.identifiers(in: presented.view).contains(ChatNewThreadView.backId), "not the chat")
        }
    }

    // MARK: - Something up out of the screen's sight

    @Test("While a new email opened out of the screen's sight is up, or an attachment preview, an open chat or the email screen takes no link; once it closes nothing comes up, and the screen takes the next", arguments: [false, true])
    func linkUnderSomethingOutOfSight(chat: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkUnderSomethingOutOfSightBody(chat: chat) }
    }

    /// A draft a compose button opens, or one an email pill opens from the navigation's root, is
    /// presented by something other than the screen. Here a new email's chat, which is counted the
    /// same way, is presented above the screen's navigation, out of its sight. A screen that took
    /// the link anyway would ask for a cover UIKit cannot show while the other is up: it would come
    /// up once the other closes, or never, and the screen would then take no other link. Both fail.
    private func linkUnderSomethingOutOfSightBody(chat: Bool) async throws {
        let elsewhere = Elsewhere()
        try await withScreen { seed in
            Beside(elsewhere: elsewhere) {
                if chat {
                    NavigationStack { ChatThreadView(messageId: seed.email.id) }
                } else {
                    NavigationStack { MessageDetailView(messageId: seed.email.id) }
                }
            }
        } body: { screen in
            if chat {
                try await ThreadChatTests.wait { ThreadChatTests.shows("Ann Example", in: screen.view) }
            } else {
                try await ThreadChatTests.wait { Self.composeButton(in: screen.view) != nil }
            }
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() == nil, "control: nothing is presented over the screen: \(ThreadChatTests.labels(screen.view).prefix(12))")

            elsewhere.cover = .make(request: Self.other, opensInChat: true, signedIn: true, chatAccount: nil, composeAccount: nil)
            try await ThreadChatTests.wait { Self.presentedNewEmail(screen) != nil }
            let up = screen.topPresented()
            #expect(Self.presentedNewEmail(screen) != nil, "control: a new email is up, opened out of the screen's sight")
            #expect(AgentToolRouter.shared.isComposeUp, "control: it is counted as a compose up")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
            let held = try await Self.keeps { screen.topPresented() === up && Self.newEmailView(screen) == nil }
            #expect(held, "the screen takes no link while it is up")
            let shown = try #require(Self.presentedNewEmail(screen), "control: it is still up")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: shown), "Back takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() == nil }
            #expect(screen.topPresented() == nil, "control: Back closed it")
            try await ThreadChatTests.wait { !AgentToolRouter.shared.isComposeUp }
            let nothing = try await Self.keeps { screen.topPresented() == nil }
            #expect(nothing, "nothing comes up once it is closed")

            // An attachment preview is presented by UIKit, outside every screen's sight.
            PreviewFreezeGate.shared.begin()
            let none: Bool
            do {
                NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
                none = try await Self.keeps { screen.topPresented() == nil }
            } catch {
                PreviewFreezeGate.shared.end()
                throw error
            }
            PreviewFreezeGate.shared.end()
            #expect(none, "the screen takes no link while a preview is up")

            _ = try await Self.postedLinkShowsNewEmail(screen)
            try await Self.backClosesAndSavesNothing(screen)
        }
    }

    // MARK: - The agent's compose

    @Test("An agent's compose finished while a new email's chat is up waits for it, and comes up once the new email closes")
    func agentComposeWaitsForTheNewEmail() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await agentComposeWaitsForTheNewEmailBody() }
    }

    private func agentComposeWaitsForTheNewEmailBody() async throws {
        let router = AgentToolRouter.shared
        try await withScreen { seed in
            NavigationStack { MessageDetailView(messageId: seed.email.id) }
        } body: { screen in
            try await ThreadChatTests.wait { Self.composeButton(in: screen.view) != nil }
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() == nil, "control: nothing is presented over the email")
            let shown = try await Self.postedLinkShowsNewEmail(screen)
            let newEmail = screen.topPresented()
            #expect(router.isComposeUp, "the new email's chat counts as a compose up")
            let request = AgentToolRouter.ComposeRequest(
                mode: .compose, replyTo: nil, to: ["next@example.com"], cc: [], bcc: [],
                subject: "From the agent", body: nil)
            router.enqueueCompose(request)
            let waited = try await Self.keeps {
                router.composeQueueDepth == 1 && !router.composeAwaitingAppear && screen.topPresented() === newEmail
            }
            #expect(waited, "the agent's compose waits while the new email is up: queued \(router.composeQueueDepth)")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: shown), "Back takes a tap")
            var fields: [String: String] = [:]
            try await ThreadChatTests.wait {
                fields = screen.topPresented().map { Self.composeRecipients($0.view) } ?? [:]
                return fields["to"]?.isEmpty == false
            }
            #expect(Self.addresses(fields["to"]) == ["next@example.com"], "the agent's compose comes up once the new email closes: \(fields)")
            #expect(router.composeQueueDepth == 0, "and leaves the queue")
        }
    }

    // MARK: - What the producers post

    @Test("What the producers post is taken: a contact pill's lone address, and a link naming only Cc")
    func producersPayloads() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await producersPayloadsBody() }
    }

    private func producersPayloadsBody() async throws {
        try await withScreen { seed in
            NavigationStack { ChatThreadView(messageId: seed.email.id) }
        } body: { screen in
            try await ThreadChatTests.wait { ThreadChatTests.shows("Ann Example", in: screen.view) }
            try await ThreadChatTests.settle()
            #expect(screen.topPresented() == nil, "control: nothing is presented over the chat")

            // A contact pill in a chat's answer posts the address alone, under `email`.
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: ["email": "maria@example.com", "name": "Maria Lee"])
            try await ThreadChatTests.wait { Self.presentedNewEmail(screen) != nil }
            let pill = try #require(Self.presentedNewEmail(screen), "a contact pill's address opens the new email")
            #expect(Self.labels(of: ChatNewThreadView.hintId, in: pill) == ["New email to maria."], "to that address")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: pill), "Back takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() == nil }
            #expect(screen.topPresented() == nil, "Back closes it")
            try await ThreadChatTests.settle()

            // A `mailto:` link in an email, or from outside the app, as it is parsed and posted.
            let url = try #require(URL(string: "mailto:?cc=Sam%20Park%20%3Csam@example.com%3E&subject=Hello%20there"))
            let parsed = try #require(MailtoRequest.parse(url), "control: a link naming only Cc parses")
            NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: parsed.toUserInfo())
            try await ThreadChatTests.wait { Self.presentedNewEmail(screen) != nil }
            let ccOnly = try #require(Self.presentedNewEmail(screen), "a link naming only Cc opens the new email")
            #expect(Self.labels(of: ChatNewThreadView.ccLineId, in: ccOnly) == ["Cc: Sam Park."], "Sam is Cc")
            #expect(Self.labels(of: ChatNewThreadView.bccLineId, in: ccOnly).isEmpty, "no Bcc")
            #expect(HostedAccessibility.labels(in: ccOnly).contains("Hello there"), "the subject")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: ccOnly), "Back takes a tap")
            try await ThreadChatTests.wait { screen.topPresented() == nil }
            #expect(screen.topPresented() == nil, "Back closes it")
            try await ThreadChatTests.settle()
            let drafts = try await screen.pool.read { db in try Draft.fetchCount(db) }
            #expect(drafts == 0, "nothing changed in either: nothing in Drafts")
        }
    }

    // MARK: - A reopened draft

    @Test("A reopened draft's chat shows the draft's own subject, Cc and Bcc")
    func reopenedShowsItsOwn() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await reopenedShowsItsOwnBody() }
    }

    private func reopenedShowsItsOwnBody() async throws {
        let now = Date().timeIntervalSince1970
        let draft = Draft(
            id: Draft.newEmailKey(), accountId: ThreadChatTests.accountA,
            toJSON: Draft.encodeStringArray(["maria@example.com"]),
            ccJSON: Draft.encodeStringArray(["Sam Park <sam@example.com>"]),
            bccJSON: Draft.encodeStringArray(["alex@example.com"]), subject: "Dinner plans", body: "See you there?",
            replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: now - 60, updatedAt: now - 60,
            serverDraftId: nil, serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: nil)
        try await withScreen { seed in
            NavigationStack { ChatNewThreadView(model: ChatNewThreadModel(reopening: draft, account: seed.account)) }
        } body: { screen in
            try await ThreadChatTests.wait { !Self.labels(of: ChatNewThreadView.ccLineId, in: screen.view).isEmpty }
            #expect(Self.labels(of: ChatNewThreadView.ccLineId, in: screen.view) == ["Cc: Sam Park."], "the draft's Cc: \(ThreadChatTests.labels(screen.view).prefix(16))")
            #expect(Self.labels(of: ChatNewThreadView.bccLineId, in: screen.view) == ["Bcc: alex."], "the draft's Bcc")
            #expect(HostedAccessibility.labels(in: screen.view).contains("Dinner plans"), "the draft's subject")
            #expect(!HostedAccessibility.labels(in: screen.view).contains(ChatNewEmailSubjectLine.text), "not New email")
            #expect(Self.fieldText(in: screen.view) == "See you there?", "the draft's words")
        }
    }

    // MARK: - An email from a notification that never arrives

    @Test("An email opened from a notification that never arrives: with a new email up over its chat or email screen, the screen does not ask to be left and the new email stays; with nothing over it, it asks", arguments: [true, false])
    func unresolvedNotificationUnderTheNewEmail(chat: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await unresolvedNotificationBody(chat: chat) }
    }

    /// A notification's email is opened before it is in the database. When the wait for it runs
    /// out, the screen shows Message Not Found and asks to be left (the navigation goes back to the
    /// list), unless something is presented over it, which leaving would close. The new email is
    /// one of those: the screen tells its model while it is up.
    ///
    /// Any timing slip fails rather than passes: a new email that came up only after the wait ran
    /// out, or a wait that ran out only after Back, would both ask to be left.
    private func unresolvedNotificationBody(chat: Bool) async throws {
        let waitSeconds = SyncConfig.notifTapStagedResolveWaitSeconds
        for covered in [false, true] {
            let opened = MessageDetailViewModel.notificationTapIdPrefix + ThreadChatTests.accountA + "::never-arrives-\(covered)"
            let asked = Mutex<[String]>([])
            let observer = NotificationCenter.default.addObserver(forName: .notificationTapUnresolved, object: nil, queue: .main) { note in
                guard let id = note.userInfo?["messageId"] as? String, id == opened else { return }
                asked.withLock { $0.append(id) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try await withScreen { _ in
                if chat {
                    NavigationStack { ChatThreadView(messageId: opened) }
                } else {
                    NavigationStack { MessageDetailView(messageId: opened) }
                }
            } body: { screen in
                guard covered else {
                    try await ThreadChatTests.wait { ThreadChatTests.shows("Message Not Found", in: screen.view) }
                    #expect(ThreadChatTests.shows("Message Not Found", in: screen.view), "control: the wait ran out: \(ThreadChatTests.labels(screen.view).prefix(12))")
                    try await ThreadChatTests.wait { !asked.withLock { $0 }.isEmpty }
                    let asks = asked.withLock { $0 }
                    #expect(asks == [opened], "control: with nothing over it, the screen asks to be left")
                    return
                }
                // The link comes while the wait is on: posted until the screen, once shown, takes it.
                let start = ContinuousClock.now
                for _ in 0..<20 where screen.topPresented() == nil {
                    NotificationCenter.default.post(name: .contactPillComposeTapped, object: nil, userInfo: Self.link.toUserInfo())
                    try await Task.sleep(for: .milliseconds(50))
                }
                let tookAfter = ContinuousClock.now - start
                try await ThreadChatTests.wait { Self.newEmailView(screen) != nil }
                #expect(Self.newEmailView(screen) != nil, "control: the screen took the link, \(tookAfter) after it showed")
                let stayed = try await Self.keeps(seconds: 2 * waitSeconds) {
                    asked.withLock { $0 }.isEmpty && Self.newEmailView(screen) != nil
                }
                let asks = asked.withLock { $0 }
                #expect(stayed, "the wait runs out under the new email: the screen does not ask to be left, and the new email stays: \(asks)")

                try await Self.backClosesAndSavesNothing(screen)
                try await ThreadChatTests.wait { ThreadChatTests.shows("Message Not Found", in: screen.view) }
                #expect(ThreadChatTests.shows("Message Not Found", in: screen.view), "control: the wait ran out while the new email was up")
                try await ThreadChatTests.settle()
                let asksAfter = asked.withLock { $0 }
                #expect(asksAfter.isEmpty, "nor once the new email is closed: \(asksAfter)")
            }
        }
    }

    // MARK: - Compose, with the chat view off

    @Test("A cover decided for compose shows compose filled with the link's To, Cc, Bcc, subject and body, from the account it was given, whatever the setting is when it shows", arguments: [false, true])
    func composeFallback(otherAccount: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await composeFallbackBody(otherAccount: otherAccount) }
    }

    /// Run with each of the two accounts, so whichever compose would pick by itself, one run gives
    /// it the other.
    private func composeFallbackBody(otherAccount: Bool) async throws {
        let full = MailtoRequest(
            to: ["\"Doe, John\" <john@example.com>", "maria@example.com"], cc: ["Sam Park <sam@example.com>"],
            bcc: ["alex@example.com"], subject: "Lunch on Friday", body: "Are you free at noon?")
        let fromId = otherAccount ? ThreadChatTests.accountB : ThreadChatTests.accountA
        let notFromId = otherAccount ? ThreadChatTests.accountA : ThreadChatTests.accountB
        // Decided for compose (the chat view off when the request came); shown with it on.
        try await withScreen { seed in
            ChatNewEmailCoverView(cover: .make(
                request: full, opensInChat: false, signedIn: true, chatAccount: nil,
                composeAccount: otherAccount ? seed.other : seed.account))
        } body: { screen in
            let accounts = try await screen.pool.read { db in try Account.fetchAll(db) }
            let from = try #require(accounts.first { $0.id == fromId }?.emailAddress)
            let notFrom = try #require(accounts.first { $0.id == notFromId }?.emailAddress)
            #expect(from != notFrom, "control: the two accounts have their own addresses")
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
            let labels = HostedAccessibility.labels(in: screen.view)
            #expect(labels.contains(from), "from the account it was given: \(labels.prefix(16))")
            #expect(!labels.contains(notFrom), "not the other one")
            #expect(!HostedAccessibility.identifiers(in: screen.view).contains(ChatNewThreadView.backId), "not the chat")
        }
        let router = AgentToolRouter.shared
        try await ThreadChatTests.wait { router.composePresentationCount == 0 }
        #expect(router.composePresentationCount == 0, "control: compose reported itself gone")
    }

    @Test("A cover decided for the chat shows the chat with what the link brought, also when the chat view was turned off or the user signed out before it shows", arguments: [(false, true), (true, false)])
    func capturedChatCover(chatView: Bool, signedIn: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await capturedChatCoverBody(chatView: chatView, signedIn: signedIn) }
    }

    private func capturedChatCoverBody(chatView: Bool, signedIn: Bool) async throws {
        // Decided for the chat (on and signed in when the request came); shown after the change.
        try await withScreen(chatView: chatView, signedIn: signedIn) { seed in
            ChatNewEmailCoverView(cover: .make(
                request: Self.link, opensInChat: true, signedIn: true, chatAccount: seed.account, composeAccount: nil))
        } body: { screen in
            #expect(ChatViewConfig.opensInChat == chatView, "control: the chat view is \(chatView ? "on" : "off") as it shows")
            try await ThreadChatTests.wait { Self.labels(of: ChatNewThreadView.hintId, in: screen.view) == Self.johnHint }
            let hint = Self.labels(of: ChatNewThreadView.hintId, in: screen.view)
            #expect(hint == Self.johnHint, "the chat, to the link's person: \(ThreadChatTests.labels(screen.view).prefix(16))")
            #expect(Self.fieldText(in: screen.view) == "Are you free at noon?", "with the link's words")
            #expect(Self.labels(of: ChatNewThreadView.ccLineId, in: screen.view) == ["Cc: Sam Park."])
            let fields = Self.composeRecipients(screen.view)
            #expect(fields.isEmpty, "not compose: \(fields)")
        }
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
        /// The second account, never the one given above.
        let other: Account?
        let state: ListPresentationState
    }

    /// A mounted screen: its controller, the app database, the list's presentation state, and the email.
    @MainActor
    struct Screen {
        let controller: UIViewController
        let pool: DatabasePool
        let state: ListPresentationState
        let email: MessageHeader
        var view: UIView { controller.view }

        /// What is presented over the screen, topmost; nil for nothing.
        func topPresented() -> UIViewController? {
            var top = controller.presentedViewController
            while let next = top?.presentedViewController { top = next }
            return top
        }
    }

    /// The email pushed over a stack's first screen; nil for none.
    @MainActor @Observable
    final class Push {
        var id: String?
    }

    /// One navigation stack: `bottom`, and `top` for the email `push` names pushed over it, as
    /// `MailNavigationView` pushes an email pill's email.
    struct Stacked<Bottom: View, Top: View>: View {
        @Bindable var push: Push
        @ViewBuilder let bottom: () -> Bottom
        @ViewBuilder let top: (String) -> Top

        var body: some View {
            NavigationStack {
                bottom().navigationDestination(item: $push.id) { top($0) }
            }
        }
    }

    /// A new email presented above a screen's navigation, as the navigation's root presents a
    /// draft opened from an email pill; nil for none.
    @MainActor @Observable
    final class Elsewhere {
        var cover: ChatNewEmailCover?
    }

    /// `screen`, with `elsewhere`'s new email presented from above it, out of the screen's sight.
    struct Beside<Screen: View>: View {
        @Bindable var elsewhere: Elsewhere
        @ViewBuilder let screen: () -> Screen

        var body: some View {
            screen().fullScreenCover(item: $elsewhere.cover) { ChatNewEmailCoverView(cover: $0) }
        }
    }

    /// Mounts `root` on an installed app database holding one email, with the chat view on and
    /// signed in unless told otherwise, the AI queue held and no compose counted as up, runs
    /// `body`, then takes it all down, also when the setup or `body` throws; what the screen saves
    /// as it closes is done before the database goes.
    private func withScreen<Root: View>(
        chatView: Bool = true,
        signedIn: Bool = true,
        @ViewBuilder _ root: (Seed) -> Root,
        body: (Screen) async throws -> Void
    ) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try ThreadChatTests.install()
        defer {
            ChatPillState.shared.removeAllSessions()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let queue = ActiveAIQueue.shared
        let router = AgentToolRouter.shared
        await queue.setDispatchSuppressedForTesting(true)
        var window: UIWindow?
        // Runs before the database goes (the `defer` above runs after it).
        func cleanUp() async {
            window?.rootViewController?.dismiss(animated: false)
            window?.isHidden = true
            window?.rootViewController = nil
            try? await ThreadChatTests.settle()
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
        }
        do {
            await queue.clearForTesting()
            saved.setChatView(on: chatView)
            // Another suite's compose may still be counted: a count left up would hold every request.
            router.pendingCompose = nil
            router.resetComposeQueueForTesting()
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
            let seed = Seed(
                email: email, inbox: inbox, account: accounts.first { $0.id == accountId },
                other: accounts.first { $0.id != accountId }, state: state)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let shown = UIWindow(windowScene: scene)
            window = shown
            shown.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            let controller = UIHostingController(rootView: AnyView(
                root(seed)
                    .environment(navigationStore)
                    .environment(\.hasTabMailSession, signedIn)))
            shown.rootViewController = controller
            shown.makeKeyAndVisible()
            try await body(Screen(controller: controller, pool: pool, state: state, email: email))
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

    /// Whether `condition` holds throughout the next `seconds` (1.5 unless told), checked every 100 ms.
    private static func keeps(seconds: TimeInterval = 1.5, _ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<Int((seconds * 10).rounded(.up)) {
            guard condition() else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// The email's bubble in the chat: its label names the sender and the subject (no summary yet).
    private static func bubble(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first {
            let label = $0.accessibilityLabel ?? ""
            return label.hasPrefix("Ann Example") && label.contains(" said: Lunch plans")
        }
    }

    private static func searchButton(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == "Search" }
    }

    private static func composeButton(in view: UIView) -> NSObject? {
        button("Compose", in: view)
    }

    private static func button(_ label: String, in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == label }
    }

    /// How many screens the navigation stack under the mounted screen holds; 0 for no stack.
    private static func depth(_ screen: Screen) -> Int {
        var pending: [UIViewController] = [screen.controller]
        while !pending.isEmpty {
            let controller = pending.removeFirst()
            if let navigation = controller as? UINavigationController { return navigation.viewControllers.count }
            pending += controller.children
        }
        return 0
    }

    /// Closes a sheet as a swipe down does: UIKit takes it down and tells the sheet's delegate,
    /// which is how SwiftUI learns that it is gone.
    private static func swipeDown(_ sheet: UIViewController) async {
        guard let presentation = sheet.presentationController else { return }
        presentation.delegate?.presentationControllerWillDismiss?(presentation)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sheet.dismiss(animated: false) { done.resume() }
        }
        presentation.delegate?.presentationControllerDidDismiss?(presentation)
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
