/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import TabMail

/// A new email as an empty chat in the chat view: where the compose button and a saved draft go,
/// what the chat decides on its own (who it is to, Send, what leaving keeps), its attachments, and
/// how the screen is wired into the inbox, the draft opener and the shared field.
@Suite("New email as a chat")
@MainActor
struct ChatNewThreadTests {
    private static let maria = ChatThread.Person(address: "maria@example.com", name: "Maria")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam")
    private static let lee = ChatThread.Person(address: "lee@example.com", name: "Lee")

    // MARK: - Where it opens

    @Test("The compose button opens the chat with the chat view on, today's compose with it off")
    func composeButtonRoute() {
        let on = ChatNewThreadRoute.composeButton(opensInChat: true)
        let off = ChatNewThreadRoute.composeButton(opensInChat: false)
        #expect(on == .newThread)
        #expect(off == .compose)
    }

    @Test("Only a new email started in the chat reopens as its chat, and only with the chat view on")
    func savedDraftRoute() {
        let newEmail = Draft.newEmailKey()
        let compose = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        let reply = Draft.draftKey(replyTo: "acc1:parent@example.com", isForward: false, newId: nil)
        let forward = Draft.draftKey(replyTo: "acc1:parent@example.com", isForward: true, newId: nil)
        let separate = Draft.separateReplyKey(replyTo: reply)
        let onNew = ChatNewThreadRoute.savedDraft(id: newEmail, opensInChat: true)
        let offNew = ChatNewThreadRoute.savedDraft(id: newEmail, opensInChat: false)
        #expect(onNew == .newThread)
        #expect(offNew == .compose, "with the chat view off every draft opens in compose")
        for other in [compose, reply, forward, separate] {
            let route = ChatNewThreadRoute.savedDraft(id: other, opensInChat: true)
            #expect(route == .compose, "\(other) opens in compose")
        }
    }

    @Test("A new email's draft key is its own, fresh each time, and names no email it replies to")
    func newEmailKey() {
        let first = Draft.newEmailKey()
        let second = Draft.newEmailKey()
        #expect(first != second)
        #expect(first.hasPrefix(Draft.newEmailPrefix))
        #expect(Draft.isNewEmailKey(first))
        let composeKey = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        #expect(!Draft.isNewEmailKey(composeKey))
        #expect(!Draft.isNewEmailKey("reply:\(first)"), "only a key that starts with the prefix")
        let replyTail = Draft.replyKeyTail(draftKey: first, isForward: false)
        let forwardTail = Draft.replyKeyTail(draftKey: first, isForward: true)
        #expect(replyTail == nil)
        #expect(forwardTail == nil)
    }

    // MARK: - What the chat decides

    @Test("Something is waiting only with words that are not just spaces, or an attachment")
    func isWaiting() {
        let empty = ChatNewDraft.Content(words: "", recipients: [], attachments: [])
        let spaces = ChatNewDraft.Content(words: "  \n\t ", recipients: [], attachments: [])
        let peopleOnly = ChatNewDraft.Content(words: "", recipients: ["maria@example.com"], attachments: [])
        let words = ChatNewDraft.Content(words: "Lunch?", recipients: [], attachments: [])
        let file = DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        let attachment = ChatNewDraft.Content(words: "", recipients: [], attachments: [file])
        #expect(!empty.isWaiting)
        #expect(!spaces.isWaiting)
        #expect(!peopleOnly.isWaiting, "people alone are not kept")
        #expect(words.isWaiting)
        #expect(attachment.isWaiting)
    }

    @Test("Leaving saves a new chat only when something waits, and a saved draft whenever it changed, emptied included")
    func needsSave() {
        let empty = ChatNewDraft.Content(words: "", recipients: [], attachments: [])
        let peopleOnly = ChatNewDraft.Content(words: "", recipients: ["maria@example.com"], attachments: [])
        let words = ChatNewDraft.Content(words: "Lunch?", recipients: ["maria@example.com"], attachments: [])
        let moreWords = ChatNewDraft.Content(words: "Lunch on Friday?", recipients: ["maria@example.com"], attachments: [])
        let otherPeople = ChatNewDraft.Content(words: "Lunch?", recipients: ["sam@example.com"], attachments: [])
        #expect(!ChatNewDraft.needsSave(current: empty, saved: nil), "an empty chat leaves nothing in Drafts")
        #expect(!ChatNewDraft.needsSave(current: peopleOnly, saved: nil))
        #expect(ChatNewDraft.needsSave(current: words, saved: nil))
        #expect(!ChatNewDraft.needsSave(current: words, saved: words), "nothing changed, nothing written")
        #expect(ChatNewDraft.needsSave(current: moreWords, saved: words))
        #expect(ChatNewDraft.needsSave(current: otherPeople, saved: words), "who it is to changed")
        #expect(ChatNewDraft.needsSave(current: empty, saved: words), "an emptied draft is saved empty, never deleted here")
    }

    @Test("A file replaced by another with the same name, size and type is a change; the same file again is not")
    func attachmentChangeIsTheBytes() {
        let base = DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        let sameBytes = DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        let otherBytes = DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1, 2, 4]))
        let renamed = DraftAttachment(filename: "b.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))
        let retyped = DraftAttachment(filename: "a.pdf", mimeType: "text/plain", data: Data([1, 2, 3]))
        let alternative = DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]), isAlternative: true)
        let saved = ChatNewDraft.Content(words: "Lunch?", recipients: [], attachments: [base])
        func content(_ file: DraftAttachment) -> ChatNewDraft.Content {
            ChatNewDraft.Content(words: "Lunch?", recipients: [], attachments: [file])
        }
        let unchanged = content(sameBytes)
        let replaced = content(otherBytes)
        let others = [renamed, retyped, alternative].map(content)
        #expect(!ChatNewDraft.needsSave(current: unchanged, saved: saved), "the same file again writes nothing")
        #expect(ChatNewDraft.needsSave(current: replaced, saved: saved), "same name, size and type, other bytes")
        for other in others {
            #expect(ChatNewDraft.needsSave(current: other, saved: saved))
        }
    }

    @Test("The thumbnail is redrawn when the file's bytes change, as the save is")
    func thumbnailKeyedByBytes() throws {
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count(".task(id: attachment)", in: view) == 1)
        let model = try Self.source("TabMail/Models/DraftMessage.swift")
        #expect(Self.count("struct DraftAttachment: Sendable, Equatable {", in: model) == 1)
    }

    @Test("Send with nobody picked asks who it is to; with people, it is for them")
    func sendAction() {
        let nobody = ChatNewDraft.send(people: [])
        let picked = ChatNewDraft.send(people: [Self.maria, Self.sam])
        #expect(nobody == .askForRecipient)
        #expect(picked == .write(to: ["maria@example.com", "sam@example.com"]))
    }

    @Test("The chat's line names who the email is to, and is the hint before anyone is picked")
    func recipientsLine() {
        let none = ChatNewDraft.recipientsLine([])
        let one = ChatNewDraft.recipientsLine([Self.maria])
        let two = ChatNewDraft.recipientsLine([Self.maria, Self.sam])
        let three = ChatNewDraft.recipientsLine([Self.maria, Self.sam, Self.lee])
        #expect(none == nil)
        #expect(one == "New email to Maria.")
        #expect(two == "New email to Maria and Sam.")
        #expect(three == "New email to Maria, Sam and Lee.")
        #expect(ChatNewDraft.emptyHint == "New email. Type what you want to say, or ask TabMail to write it.")
    }

    @Test("A saved draft's line has the time, and the date too when it was saved before today")
    func savedLine() {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let earlierToday = now.addingTimeInterval(-60 * 60)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let today = ChatNewDraft.savedLine(earlierToday, now: now, calendar: calendar)
        let before = ChatNewDraft.savedLine(twoDaysAgo, now: now, calendar: calendar)
        let todayTime = earlierToday.formatted(date: .omitted, time: .shortened)
        let beforeDate = twoDaysAgo.formatted(date: .abbreviated, time: .omitted)
        #expect(today == "Draft, saved \(todayTime)")
        #expect(before.hasPrefix("Draft, saved "))
        #expect(before.contains(beforeDate))
        #expect(!today.contains(earlierToday.formatted(date: .abbreviated, time: .omitted)))
    }

    @Test("In Drafts a draft with no subject reads 'Draft (no subject yet)'; a subject, or any other folder, shows as stored")
    func draftRowSubject() throws {
        let blank = MessageRowView.subjectLine("", isDraftsFolder: true)
        let spaces = MessageRowView.subjectLine(" \n\t", isDraftsFolder: true)
        let titled = MessageRowView.subjectLine("Plans", isDraftsFolder: true)
        let elsewhere = MessageRowView.subjectLine("", isDraftsFolder: false)
        #expect(blank == "Draft (no subject yet)")
        #expect(spaces == "Draft (no subject yet)")
        #expect(titled == "Plans")
        #expect(elsewhere == "", "only Drafts gets the fallback")
        let row = try Self.source("TabMail/Views/Inbox/MessageRowView.swift")
        #expect(Self.count("Text(Self.subjectLine(message.subject, isDraftsFolder: isDraftsFolder))", in: row) == 1)
        #expect(Self.count("Text(message.subject)", in: row) == 0, "the row's subject goes through the fallback")
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        #expect(Self.count("showsRecipientInsteadOfSender: isUserAuthoredFolder, isDraftsFolder: isDraftsContext )", in: inbox) == 1)
    }

    @Test("A saved To becomes the people, by name or the address's own; text that is no address is kept apart")
    func peopleFromTo() {
        let result = ChatNewDraft.people(fromTo: ["Maria Lee <Maria@Example.com>", "sam@example.com", "not an address"])
        let addresses = result.people.map(\.address)
        let names = result.people.map(\.name)
        #expect(addresses == ["maria@example.com", "sam@example.com"])
        #expect(names == ["Maria Lee", "sam"])
        #expect(result.leftovers == ["not an address"])
    }

    @Test("A save writes each person with their name: a reopened draft's as it wrote them, a new pick by the name picked")
    func toEntries() {
        let reopened = ChatNewDraft.people(fromTo: ["Maria Lee <Maria@Example.com>", "sam@example.com", "not an address"])
        #expect(reopened.people.count == 2)
        guard reopened.people.count == 2 else { return }
        let picked = ChatThread.Person(address: "lee@example.com", name: "Lee Park")
        let plain = ChatThread.Person(address: "kim@example.com", name: ChatThread.fallbackName("kim@example.com"))
        let written = ChatNewDraft.toEntries(
            people: reopened.people + [picked, plain], authored: reopened.authored, leftovers: reopened.leftovers)
        #expect(written == [
            "\"Maria Lee\" <Maria@Example.com>", "sam@example.com", "\"Lee Park\" <lee@example.com>",
            "kim@example.com", "not an address",
        ])
        let readBack = ChatNewDraft.people(fromTo: written)
        let names = readBack.people.map(\.name)
        #expect(names == ["Maria Lee", "sam", "Lee Park", "kim"], "every entry reads back as itself")
        #expect(readBack.leftovers == ["not an address"])
        let removed = ChatNewDraft.toEntries(people: [reopened.people[1]], authored: reopened.authored, leftovers: [])
        #expect(removed == ["sam@example.com"], "a person taken off is not written")
    }

    @Test("Add recipient starts from nobody, needs someone, and its Done replaces the people picked")
    func addRecipientChoice() {
        var choice = ChatReplyToChoice(replyPeople: [], target: .replyAll)
        #expect(choice.people.isEmpty)
        #expect(!choice.canFinish, "Done needs someone")
        let ownAdded = choice.add("me@example.com", ownAddresses: ["me@example.com"])
        #expect(!ownAdded, "the user's own address is not added")
        let added = choice.add("Maria <maria@example.com>", ownAddresses: ["me@example.com"])
        #expect(added)
        #expect(choice.canFinish)
        let done = choice.target(replyPeople: [])
        let picked = ChatNewDraft.people(after: done, current: []).map(\.address)
        #expect(picked == ["maria@example.com"])

        // Opened again with Maria picked: Done with nothing changed keeps her; adding Sam adds him.
        let current = [Self.maria]
        let unchanged = ChatReplyToChoice(replyPeople: current, target: .replyAll).target(replyPeople: current)
        let kept = ChatNewDraft.people(after: unchanged, current: current)
        #expect(kept == current)
        var more = ChatReplyToChoice(replyPeople: current, target: .replyAll)
        more.add("sam@example.com", ownAddresses: [])
        let both = ChatNewDraft.people(after: more.target(replyPeople: current), current: current).map(\.address)
        #expect(both == ["maria@example.com", "sam@example.com"])
        // Maria unticked, Sam added: only Sam.
        var swapped = ChatReplyToChoice(replyPeople: current, target: .replyAll)
        swapped.toggle(Self.maria)
        swapped.add("sam@example.com", ownAddresses: [])
        let onlySam = ChatNewDraft.people(after: swapped.target(replyPeople: current), current: current).map(\.address)
        #expect(onlySam == ["sam@example.com"])
    }

    // MARK: - The field and the header

    @Test("The new email's field has its own placeholder; every other field keeps its own")
    func fieldPlaceholder() {
        let field = Self.newEmailField()
        let newEmail = ChatReplyField(example: nil, isNoReply: false, clearCount: 0, newEmail: field)
        let noReplyNewEmail = ChatReplyField(example: nil, isNoReply: true, clearCount: 0, newEmail: field)
        let reply = ChatReplyField(example: nil, isNoReply: false, clearCount: 0)
        let noReply = ChatReplyField(example: nil, isNoReply: true, clearCount: 0)
        #expect(newEmail.placeholder == "Message or ask anything")
        #expect(noReplyNewEmail.placeholder == ChatNewEmailField.placeholder)
        #expect(reply.placeholder == "Reply or ask anything")
        #expect(noReply.placeholder == "Ask anything")
        #expect(reply.newEmail == nil)
    }

    @Test("Each new email's chat has its own in-memory session, never the inbox's")
    func sessionKeys() {
        let first = ChatNewEmailField.newSessionKey()
        let second = ChatNewEmailField.newSessionKey()
        #expect(first != second)
        #expect(first != "inbox")
        #expect(!first.hasPrefix(Draft.newEmailPrefix), "the session is not the draft")
    }

    @Test("The paperclip offers Photos, Camera and Files, in that order")
    func attachSources() {
        let titles = ChatNewEmailField.AttachSource.allCases.map(\.title)
        let images = ChatNewEmailField.AttachSource.allCases.map(\.systemImage)
        #expect(titles == ["Photos", "Camera", "Files"])
        #expect(Set(images).count == images.count)
    }

    @Test("The new email's e.g. line comes from its own config set")
    func examples() {
        let examples = ChatSuggestionConfig.newEmailExamples
        #expect(!examples.isEmpty)
        #expect(Set(examples).isDisjoint(with: ChatSuggestionConfig.replyExamples))
        let picked = ChatSuggestionConfig.randomExample(from: examples)
        let isMember = picked.map(examples.contains) ?? false
        #expect(isMember)
    }

    @Test("The sheet is titled Add recipient for a new email, Reply to otherwise; the header's hint says which")
    func titlesAndHints() {
        #expect(ChatReplyToSheet.addRecipientTitle == "Add recipient")
        #expect(ChatReplyToSheet.replyToTitle == "Reply to")
        #expect(ChatHeaderView.replyHint == "Changes who gets your reply")
        #expect(ChatHeaderView.newEmailHint != ChatHeaderView.replyHint)
        #expect(ChatNewEmailSubjectLine.text == "New email")
        #expect(ChatNewThreadView.askTitle == "Who is this to?")
        #expect(ChatNewThreadView.askMessage == "Add at least one recipient to send this email.")
    }

    // MARK: - The model's attachments

    @Test("A new chat starts with nobody, no words and its own draft key")
    func newModel() {
        let model = ChatNewThreadModel(account: nil)
        #expect(Draft.isNewEmailKey(model.draftId))
        #expect(model.people.isEmpty)
        #expect(model.words.isEmpty)
        #expect(model.startWords.isEmpty)
        #expect(model.attachments.isEmpty)
        #expect(model.savedAt == nil)
        #expect(model.sendAction == .askForRecipient)
        model.setPeople([Self.maria])
        #expect(model.sendAction == .write(to: ["maria@example.com"]))
        let other = ChatNewThreadModel(account: nil)
        #expect(other.draftId != model.draftId)
    }

    @Test("Picked items land in order, named as compose names them; one that fails is listed")
    func pickedItems() async {
        struct LoadFailed: Error {}
        let model = ChatNewThreadModel(account: nil)
        let loading = model.addPicked(["first", "broken", "third"]) { item in
            if item == "broken" { throw LoadFailed() }
            return (data: Data(item.utf8) as Data?, type: UTType.png as UTType?)
        }
        await loading?.value
        let names = model.attachments.map(\.filename)
        let contents = model.attachments.map(\.data)
        #expect(names == ["photo_1.png", "photo_2.png"])
        #expect(contents == [Data("first".utf8), Data("third".utf8)])
        #expect(model.failedImports == [DraftAttachmentImport.pickedFailureLabel(index: 1)])
        let none = model.addPicked([String]()) { _ in (data: nil, type: nil) }
        #expect(none == nil, "no items, no loading")
    }

    @Test("A picked item with no data is listed, not added")
    func pickedItemWithoutData() async {
        let model = ChatNewThreadModel(account: nil)
        let loading = model.addPicked(["empty"]) { _ in (data: nil, type: UTType.png as UTType?) }
        await loading?.value
        #expect(model.attachments.isEmpty)
        #expect(model.failedImports == [DraftAttachmentImport.pickedFailureLabel(index: 0)])
    }

    @Test("Files are added whole, named by their file; one that cannot be read is listed")
    func files() {
        struct ReadFailed: Error {}
        let model = ChatNewThreadModel(account: nil)
        let good = URL(fileURLWithPath: "/tmp/report.pdf")
        let bad = URL(fileURLWithPath: "/tmp/locked.txt")
        model.addFiles([good, bad]) { url in
            guard url == good else { throw ReadFailed() }
            return Data([9, 8, 7])
        }
        let names = model.attachments.map(\.filename)
        let types = model.attachments.map(\.mimeType)
        #expect(names == ["report.pdf"])
        #expect(types == ["application/pdf"])
        #expect(model.failedImports == [DraftAttachmentImport.fileFailureLabel(bad)])
    }

    @Test("A camera photo that cannot be made into a JPEG is listed, not added")
    func cameraFailure() {
        let model = ChatNewThreadModel(account: nil)
        model.addCameraPhoto(UIImage())
        #expect(model.attachments.isEmpty)
        #expect(model.failedImports == [DraftAttachmentImport.cameraFailureLabel])
    }

    @Test("The tray's x takes away that attachment only; an index that is gone does nothing")
    func removeAttachment() {
        let model = ChatNewThreadModel(account: nil)
        model.addAttachments([
            DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1])),
            DraftAttachment(filename: "b.pdf", mimeType: "application/pdf", data: Data([2])),
        ])
        model.removeAttachment(at: 5)
        #expect(model.attachments.count == 2)
        model.removeAttachment(at: 0)
        let names = model.attachments.map(\.filename)
        #expect(names == ["b.pdf"])
    }

    // MARK: - Wiring

    @Test("The inbox compose button reads the setting at the tap and pushes the chat; off, compose as before")
    func inboxWiring() throws {
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        #expect(Self.count("ComposeToolbarButton(onNewCompose: { collapseChat() startNewEmail() })", in: inbox) == 1)
        #expect(Self.count("switch ChatNewThreadRoute.composeButton(opensInChat: ChatViewConfig.opensInChat) { case .newThread: newEmail = ChatNewThreadModel(account: viewModel.primaryAccount) case .compose: viewModel.showCompose = true }", in: inbox) == 1)
        #expect(Self.count(".navigationDestination(item: $newEmail) { model in ChatNewThreadView(model: model) }", in: inbox) == 1)
        #expect(Self.count(".fullScreenCover(isPresented: $vm.showCompose) { ComposeView(account: viewModel.primaryAccount) }", in: inbox) == 1,
                "the chat view off keeps today's compose")
        #expect(Self.count("viewModel.showCompose = true", in: inbox) == 1, "only through the route")
    }

    @Test("A saved draft is routed once its preparation checked the row; the chat is made there, once")
    func draftOpenWiring() throws {
        let presenter = try Self.source("TabMail/Views/Compose/DraftComposePresenter.swift")
        #expect(Self.count("@State private var opensInChat = ChatViewConfig.opensInChat", in: presenter) == 1)
        #expect(Self.count("if case .ready(let ready) = prepared, ChatNewThreadRoute.savedDraft(id: ready.draft.id, opensInChat: opensInChat) == .newThread { newEmail = ChatNewThreadModel(reopening: ready.draft, account: ready.account) } else { newEmail = nil } outcome = prepared", in: presenter) == 1)
        #expect(Self.count("if let newEmail { newEmailChat(newEmail) } else { ComposeView(", in: presenter) == 1)
        #expect(Self.count("if presentedAsCover { NavigationStack { ChatNewThreadView(model: model) } } else { ChatNewThreadView(model: model) }", in: presenter) == 1)
        let open = try Self.source("TabMail/Views/Chat/MessageOpenView.swift")
        #expect(Self.count("DraftComposePresenter(source: .header(header), presentedAsCover: false)", in: open) == 1,
                "pushed inside a navigation, the chat uses its bar")
    }

    @Test("The shared field treats a new email's chat as neither the inbox chat nor an email's")
    func fieldWiring() throws {
        let pill = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(Self.count("private var isInboxChat: Bool { composeContext == nil && message == nil && replyField?.newEmail == nil }", in: pill) == 1)
        #expect(Self.count("!isComposeMode && message == nil", in: pill) == 0, "every inbox-only rule asks isInboxChat")
        let sessionAt = try #require(pill.range(of: "if let newEmail = replyField?.newEmail { return newEmail.sessionKey }"))
        let inboxAt = try #require(pill.range(of: "return \"inbox\""))
        #expect(sessionAt.lowerBound < inboxAt.lowerBound, "its own session, before the inbox's")
        let send = try #require(pill.range(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {"))
        let intercept = try #require(pill.range(of: "if let newEmail = field.newEmail { newEmail.send(text) return }", range: send.upperBound..<pill.endIndex))
        let sent = try #require(pill.range(of: "fieldFill.apply(.sentFromField)", range: send.upperBound..<pill.endIndex))
        #expect(intercept.lowerBound < sent.lowerBound, "its Send is the chat's, before any agent send")
        #expect(Self.count(".task(id: replyField?.newEmail?.sessionKey) { startNewEmail() }", in: pill) == 1)
        #expect(Self.count(".onChange(of: inputText) { _, words in replyField?.newEmail?.wordsChanged(words) }", in: pill) == 1)
        let bar = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        #expect(Self.count("if let newEmail = field.newEmail {", in: bar) == 1)
        #expect(Self.count("ChatPaperclipButton(attach: newEmail.attach)", in: bar) == 1)
    }

    @Test("Back saves before it leaves, the background saves, and the open draft is kept from eviction")
    func screenWiring() throws {
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count(".navigationBarBackButtonHidden(true)", in: view) == 1)
        #expect(Self.count("Button { leave() } label:", in: view) == 1)
        #expect(Self.count("let outcome = await model.saveIfNeeded() isLeaving = false switch outcome { case .saved: dismiss() case .refused(let message): saveRefusal = message }", in: view) == 1)
        #expect(Self.count("if phase == .background { Task { await saveInBackground() } }", in: view) == 1)
        #expect(Self.count("Button(\"Leave without saving\", role: .destructive) { dismiss() }", in: view) == 1)
        #expect(Self.count(".onAppear { DraftSessionRegistry.shared.register(model.draftId) }", in: view) == 1)
        #expect(Self.count(".onDisappear { DraftSessionRegistry.shared.unregister(model.draftId) }", in: view) == 1)
        #expect(Self.count("model.setPeople(ChatNewDraft.people(after: done, current: model.people))", in: view) == 1)
        // The keyboard rule, on this screen itself, as the chat's own thread installs it.
        #expect(Self.count(".defaultScrollAnchor(.bottom) .scrollDismissesKeyboard(.interactively) .frame(maxWidth: .infinity, maxHeight: .infinity) .background(Palette.previewPaneBg) .dismissKeyboardOnTap()", in: view) == 1,
                "a tap on the stream, or a drag, dismisses the keyboard")
        let registry = try Self.source("TabMail/Services/AI/DraftSessionRegistry.swift")
        #expect(registry.contains("(5 production files:"), "the registry's census names the chat as a producer")
    }

    // MARK: - Helpers

    private static func newEmailField() -> ChatNewEmailField {
        ChatNewEmailField(
            startWords: "", sessionKey: ChatNewEmailField.newSessionKey(),
            wordsChanged: { _ in }, send: { _ in }, attach: { _ in })
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

/// The new email's header and attachment tray on screen, as VoiceOver reaches them.
@Suite("New email as a chat, on screen", .serialized, .processGlobalState)
@MainActor
struct ChatNewThreadHostedTests {
    private static let maria = ChatThread.Person(address: "maria@example.com", name: "Maria")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam")

    @Test("With nobody picked the header's one button is Add recipient, and it opens the sheet")
    func hostedEmptyHeader() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hostedEmptyHeaderBody() }
    }

    private func hostedEmptyHeaderBody() async throws {
        let taps = TapCounter()
        let window = try Self.host(ChatHeaderView(
            people: [], emptyTitle: ChatReplyToSheet.addRecipientTitle, hint: ChatHeaderView.newEmailHint
        ) { taps.count += 1 })
        defer { window.isHidden = true }
        _ = await Self.waitUntil { Self.element(ChatHeaderView.namesId, in: window) != nil }
        let names = try #require(Self.element(ChatHeaderView.namesId, in: window),
                                 "the header's button: \(HostedAccessibility.identifiers(in: window))")
        let label = names.accessibilityLabel ?? ""
        let hint = names.accessibilityHint
        #expect(label.contains("Add recipient"))
        #expect(hint == ChatHeaderView.newEmailHint)
        let activated = names.accessibilityActivate()
        #expect(activated)
        #expect(taps.count == 1)
    }

    @Test("With people picked the header shows their names, with no Add recipient")
    func hostedPeopleHeader() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hostedPeopleHeaderBody() }
    }

    private func hostedPeopleHeaderBody() async throws {
        let window = try Self.host(ChatHeaderView(
            people: [Self.maria, Self.sam], emptyTitle: ChatReplyToSheet.addRecipientTitle,
            hint: ChatHeaderView.newEmailHint) {})
        defer { window.isHidden = true }
        _ = await Self.waitUntil { Self.element(ChatHeaderView.namesId, in: window) != nil }
        let names = try #require(Self.element(ChatHeaderView.namesId, in: window))
        let label = names.accessibilityLabel ?? ""
        #expect(label.contains("Maria, Sam"))
        let labels = HostedAccessibility.labels(in: window)
        let showsAdd = labels.contains { $0.contains("Add recipient") }
        #expect(!showsAdd)
    }

    @Test("A thread's header with nobody to reply to still shows no button")
    func hostedThreadHeaderWithNobody() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hostedThreadHeaderWithNobodyBody() }
    }

    private func hostedThreadHeaderWithNobodyBody() async throws {
        let window = try Self.host(ChatHeaderView(people: []) {})
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        let names = Self.element(ChatHeaderView.namesId, in: window)
        #expect(names == nil)
    }

    @Test("The tray's x on an item removes that item")
    func hostedTrayRemove() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hostedTrayRemoveBody() }
    }

    private func hostedTrayRemoveBody() async throws {
        let removed = TapCounter()
        let tray = ChatAttachmentTray(attachments: [
            DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1])),
            DraftAttachment(filename: "b.pdf", mimeType: "application/pdf", data: Data([2])),
        ]) { removed.indices.append($0) }
        let window = try Self.host(tray)
        defer { window.isHidden = true }
        func removeB() -> NSObject? {
            HostedAccessibility.elements(under: window).first {
                HostedAccessibility.identifier(of: $0) == ChatAttachmentTray.removeId && $0.accessibilityLabel == "Remove b.pdf"
            }
        }
        _ = await Self.waitUntil { removeB() != nil }
        let button = try #require(removeB(), "the x: \(HostedAccessibility.labels(in: window))")
        let activated = button.accessibilityActivate()
        #expect(activated)
        #expect(removed.indices == [1])
    }

    // MARK: - Helpers

    @MainActor
    private final class TapCounter {
        var count = 0
        var indices: [Int] = []
    }

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func host<V: View>(_ view: V) throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HostingFailure(description: "no UIWindowScene is available to host the view")
        }
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private static func element(_ identifier: String, in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { HostedAccessibility.identifier(of: $0) == identifier }
    }

    /// Bounded: a view that never shows the element fails the test rather than hanging it.
    private static func waitUntil(seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// A new email's draft against a real database: what Back and the background write, what a
/// reopened draft keeps, and every refusal leaving the saved row as it was.
@Suite("New email draft saves", .serialized, .processGlobalState)
@MainActor
struct ChatNewDraftSaveTests {
    nonisolated private static let accountId = "chat-new-email"
    nonisolated private static let generation = "generation"

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let account: Account
    }

    @MainActor
    private final class QueueRecorder {
        var calls: [String] = []
        var answer = true

        func queue(_ draftId: String, _ accountId: String) -> Bool {
            calls.append("\(draftId)|\(accountId)")
            return answer
        }
    }

    private func fixture() throws -> Fixture {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let account = try FolderEpochTestFixture.makeAccount(id: Self.accountId, provider: .imap, pool: pool)
        return Fixture(pool: pool, directory: directory, previous: previous, account: account)
    }

    private func finish(_ fixture: Fixture) {
        let dirs = (try? fixture.pool.read { db in try Draft.fetchAll(db).compactMap(\.attachmentsDirName) }) ?? []
        for dir in dirs { DraftAttachmentStorage.deleteAttachments(dirName: dir) }
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory)
    }

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft? {
        try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) }
    }

    private func rowCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.pool.read { db in try Draft.fetchCount(db) }
    }

    private func makeModel(_ fixture: Fixture, _ recorder: QueueRecorder) -> ChatNewThreadModel {
        ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
    }

    /// A saved new email's draft, as the chat wrote it earlier, with one attachment unless told
    /// otherwise; `attachmentsDirName` names a directory that was never written when `readable` is false.
    private func savedDraft(
        _ fixture: Fixture,
        to: [String] = ["Maria Lee <maria@example.com>", "sam@example.com"],
        subject: String = "",
        cc: [String] = [],
        bcc: [String] = [],
        body: String = "Lunch on Friday?",
        attachments: [DraftAttachment] = [DraftAttachment(filename: "menu.pdf", mimeType: "application/pdf", data: Data([4, 5, 6]))],
        readable: Bool = true
    ) async throws -> Draft {
        let dirName = attachments.isEmpty ? nil : DraftAttachmentStorage.newStagingDirName()
        if let dirName, readable {
            try DraftAttachmentStorage.saveAttachments(attachments, dirName: dirName)
        }
        let updatedAt = Date().addingTimeInterval(-60).timeIntervalSince1970
        var draft = Draft(
            id: Draft.newEmailKey(), accountId: Self.accountId,
            toJSON: Draft.encodeStringArray(to), ccJSON: Draft.encodeStringArray(cc),
            bccJSON: Draft.encodeStringArray(bcc), subject: subject, body: body, replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: updatedAt, updatedAt: updatedAt,
            serverDraftId: nil, serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: dirName)
        draft.instanceEpoch = Self.generation
        let toInsert = draft
        try await fixture.pool.write { db in try toInsert.insert(db) }
        return draft
    }

    @Test("An empty chat, spaces only, or people only leaves nothing in Drafts")
    func nothingWaitingSavesNothing() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        let empty = await model.saveIfNeeded()
        model.words = "   \n"
        let spaces = await model.saveIfNeeded()
        model.words = ""
        model.setPeople([ChatThread.Person(address: "maria@example.com", name: "Maria")])
        let peopleOnly = await model.saveIfNeeded()
        let rows = try await rowCount(fixture)
        #expect(empty == .saved)
        #expect(spaces == .saved)
        #expect(peopleOnly == .saved)
        #expect(rows == 0)
        #expect(recorder.calls.isEmpty)
        #expect(model.savedAt == nil)
    }

    @Test("Words are saved as the chat's own draft, to the people picked, and its push is queued")
    func wordsAreSaved() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        model.setPeople([ChatThread.Person(address: "maria@example.com", name: "Maria")])
        model.words = "Lunch on Friday?"
        let savedAt = Date()
        let outcome = await model.saveIfNeeded(now: { savedAt })
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow)
        #expect(outcome == .saved)
        #expect(Draft.isNewEmailKey(saved.id))
        #expect(saved.accountId == Self.accountId)
        #expect(saved.body == "Lunch on Friday?")
        #expect(saved.toArray == ["\"Maria\" <maria@example.com>"], "written with the name picked")
        #expect(saved.ccArray.isEmpty)
        #expect(saved.subject.isEmpty)
        #expect(saved.replyToId == nil)
        #expect(saved.isForward == false)
        #expect(saved.attachmentsDirName == nil)
        #expect(saved.instanceEpoch == model.cursor.newEpoch)
        #expect(recorder.calls == ["\(model.draftId)|\(Self.accountId)"])
        #expect(model.savedAt == savedAt)
    }

    @Test("Saving again with nothing changed writes nothing; a change writes and queues again")
    func onlyChangesAreSaved() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        model.words = "First words"
        _ = await model.saveIfNeeded()
        let firstRow = try await row(fixture, model.draftId)
        let first = try #require(firstRow)
        let unchanged = await model.saveIfNeeded()
        let afterUnchangedRow = try await row(fixture, model.draftId)
        let afterUnchanged = try #require(afterUnchangedRow)
        #expect(unchanged == .saved)
        #expect(afterUnchanged.updatedAt == first.updatedAt)
        #expect(recorder.calls.count == 1)
        model.words = "Second words"
        let changed = await model.saveIfNeeded(now: { Date().addingTimeInterval(1) })
        let afterChangeRow = try await row(fixture, model.draftId)
        let afterChange = try #require(afterChangeRow)
        #expect(changed == .saved)
        #expect(afterChange.body == "Second words")
        #expect(recorder.calls.count == 2)
        let rows = try await rowCount(fixture)
        #expect(rows == 1, "one draft for one chat")
    }

    @Test("Attachments alone are kept, whole")
    func attachmentsAreSaved() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        let bytes = Data(repeating: 7, count: 300_000)
        model.addAttachment(DraftAttachment(filename: "slides.pdf", mimeType: "application/pdf", data: bytes))
        let outcome = await model.saveIfNeeded()
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow)
        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: saved.attachmentsDirName)
        let loadedNames = loaded.map(\.filename)
        let loadedData = loaded.map(\.data)
        #expect(outcome == .saved)
        #expect(saved.body.isEmpty)
        #expect(loadedNames == ["slides.pdf"])
        #expect(loadedData == [bytes])
    }

    @Test("A push that is not queued is refused and tried again on the next save")
    func notQueuedIsRefused() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        recorder.answer = false
        let model = makeModel(fixture, recorder)
        model.words = "Keep these words"
        let refused = await model.saveIfNeeded()
        #expect(refused == .refused(ChatNewDraftSave.notQueuedMessage))
        #expect(model.savedAt == nil, "not shown as saved")
        recorder.answer = true
        let retried = await model.saveIfNeeded(now: { Date().addingTimeInterval(1) })
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow)
        #expect(retried == .saved)
        #expect(saved.body == "Keep these words")
        #expect(recorder.calls.count == 2)
    }

    @Test("With no account the save is refused and nothing is written")
    func noAccountIsRefused() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: nil, queueDraftSave: { recorder.queue($0, $1) })
        model.words = "Words with nowhere to go"
        let outcome = await model.saveIfNeeded()
        let rows = try await rowCount(fixture)
        #expect(outcome == .refused(ChatNewThreadModel.noAccountMessage))
        #expect(rows == 0)
        #expect(recorder.calls.isEmpty)
    }

    @Test("A reopened draft brings back its words, people, attachments and save time")
    func reopenRestores() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture)
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account)
        let names = model.people.map(\.name)
        let addresses = model.people.map(\.address)
        let files = model.attachments.map(\.filename)
        #expect(model.draftId == draft.id)
        #expect(model.startWords == "Lunch on Friday?")
        #expect(model.words == "Lunch on Friday?")
        #expect(names == ["Maria Lee", "sam"])
        #expect(addresses == ["maria@example.com", "sam@example.com"])
        #expect(files == ["menu.pdf"])
        let expectedSavedAt = Date(timeIntervalSince1970: draft.updatedAt)
        #expect(model.attachmentLoadFailed == false)
        #expect(model.savedAt == expectedSavedAt)
    }

    @Test("A reopened draft left unchanged is not written")
    func reopenUnchangedWritesNothing() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture)
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow)
        #expect(outcome == .saved)
        #expect(after.updatedAt == draft.updatedAt)
        #expect(recorder.calls.isEmpty)
    }

    @Test("A reopened draft the user emptied is saved empty, never deleted")
    func reopenEmptiedIsKept() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture)
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        model.words = ""
        model.removeAttachment(at: 0)
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow, "the draft is still there")
        #expect(outcome == .saved)
        #expect(after.body.isEmpty)
        #expect(after.attachmentsDirName == nil)
        #expect(recorder.calls.count == 1)
    }

    @Test("A reopened draft keeps the subject, Cc and Bcc compose gave it")
    func reopenKeepsComposeFields() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(
            fixture, subject: "Plans", cc: ["cc@example.com"], bcc: ["bcc@example.com"], attachments: [])
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        model.words = "Lunch on Saturday instead?"
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow)
        #expect(outcome == .saved)
        #expect(after.body == "Lunch on Saturday instead?")
        #expect(after.subject == "Plans")
        #expect(after.ccArray == ["cc@example.com"])
        #expect(after.bccArray == ["bcc@example.com"])
        #expect(after.toArray == ["\"Maria Lee\" <maria@example.com>", "sam@example.com"], "a body change keeps the names compose wrote")
    }

    @Test("Named people and a long message survive a save and a reopen, and the reopened draft is not written again")
    func namesAndWordsRoundTrip() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        let words = (1...400).map { "Line \($0) of what I want to say, with a comma, and \"quotes\"." }.joined(separator: "\n")
        model.setPeople([
            ChatThread.Person(address: "maria@example.com", name: "Lee, Maria"),
            ChatThread.Person(address: "sam@example.com", name: "sam"),
        ])
        model.words = words
        _ = await model.saveIfNeeded()
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow)
        #expect(saved.toArray == ["\"Lee, Maria\" <maria@example.com>", "sam@example.com"])
        #expect(saved.body == words, "the whole message, never cut")
        let reopened = ChatNewThreadModel(reopening: saved, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        let names = reopened.people.map(\.name)
        let addresses = reopened.people.map(\.address)
        #expect(names == ["Lee, Maria", "sam"])
        #expect(addresses == ["maria@example.com", "sam@example.com"])
        #expect(reopened.words == words)
        let again = await reopened.saveIfNeeded()
        #expect(again == .saved)
        #expect(recorder.calls.count == 1, "the reopened draft, unchanged, is not written again")
    }

    @Test("A reopened draft keeps an address as compose wrote it, and text that is no address")
    func reopenKeepsAddressTextAndLeftovers() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, to: ["Maria Lee <Maria@Example.com>", "not an address"], attachments: [])
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        let addresses = model.people.map(\.address)
        #expect(addresses == ["maria@example.com"], "matched by the address in lower case")
        model.words = "Changed words"
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow)
        #expect(outcome == .saved)
        #expect(after.toArray == ["\"Maria Lee\" <Maria@Example.com>", "not an address"])
    }

    @Test("A reopened draft whose attachments cannot be read is never saved from the chat")
    func unreadableAttachmentsBlockSaving() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, readable: false)
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        #expect(model.attachmentLoadFailed)
        model.words = "Changed words"
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow)
        #expect(outcome == .refused(ChatNewThreadModel.attachmentLoadMessage))
        #expect(after.body == "Lunch on Friday?")
        #expect(after.attachmentsDirName == draft.attachmentsDirName, "the saved files are not replaced by none")
        #expect(recorder.calls.isEmpty)
    }

    @Test("A draft another session saved after the chat opened is never overwritten from the chat")
    func newerSessionWins() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, attachments: [])
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        let id = draft.id
        try await fixture.pool.write { db in
            try db.execute(sql: "UPDATE draft SET instanceEpoch = ?, body = ? WHERE id = ?",
                           arguments: ["another-session", "Written in compose", id])
        }
        model.words = "Written in the chat"
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow)
        let refused: Bool
        if case .refused = outcome { refused = true } else { refused = false }
        #expect(refused)
        #expect(after.body == "Written in compose")
        #expect(recorder.calls.isEmpty)
    }

    @Test("A draft deleted after the chat opened is not brought back from the chat")
    func deletedDraftStaysDeleted() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, attachments: [])
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        let id = draft.id
        try await fixture.pool.write { db in _ = try Draft.deleteOne(db, key: id) }
        model.words = "Still typing"
        let outcome = await model.saveIfNeeded()
        let rows = try await rowCount(fixture)
        let refused: Bool
        if case .refused = outcome { refused = true } else { refused = false }
        #expect(refused)
        #expect(rows == 0)
        #expect(recorder.calls.isEmpty)
    }

    @Test("A save waits for a picked photo that is still loading, and keeps it")
    func saveWaitsForLoadingPhotos() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        let (release, releaseNow) = AsyncStream<Void>.makeStream()
        let loading = model.addPicked(["photo"]) { _ in
            for await _ in release { break }
            return (data: Data([7, 8, 9]) as Data?, type: UTType.png as UTType?)
        }
        let save = Task { await model.saveIfNeeded() }
        for _ in 0..<10 { await Task.yield() }
        let rowsWhileLoading = try await rowCount(fixture)
        #expect(rowsWhileLoading == 0, "nothing is written while the photo loads")
        releaseNow.yield(())
        await loading?.value
        let outcome = await save.value
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow, "the save waited and kept the photo")
        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: saved.attachmentsDirName)
        let loadedNames = loaded.map(\.filename)
        let loadedData = loaded.map(\.data)
        #expect(outcome == .saved)
        #expect(loadedNames == ["photo_1.png"])
        #expect(loadedData == [Data([7, 8, 9])])
    }

    @Test("Back and the background saving at once write the draft once")
    func oneSaveAtATime() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        model.words = "Saved once"
        let savedAt = Date()
        let first = Task { await model.saveIfNeeded(now: { savedAt }) }
        let second = Task { await model.saveIfNeeded(now: { savedAt }) }
        let outcomes = [await first.value, await second.value]
        let rows = try await rowCount(fixture)
        #expect(outcomes == [.saved, .saved])
        #expect(recorder.calls.count == 1)
        #expect(rows == 1)
        #expect(model.isSaving == false)
    }
}
