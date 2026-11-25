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
    /// An email the field's compose edit wrote, with its text version and change command.
    private static let written = ReplyResult(body: "The email.", textMessage: "Short.", changeCommand: "make it shorter")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam")
    private static let lee = ChatThread.Person(address: "lee@example.com", name: "Lee")

    // MARK: - Where it opens

    @Test("A new email opens the chat with the chat view on and signed in; off, or signed out, today's compose")
    func newEmailRoute() {
        let on = ChatNewThreadRoute.newEmail(opensInChat: true, signedIn: true)
        let off = ChatNewThreadRoute.newEmail(opensInChat: false, signedIn: true)
        let signedOut = ChatNewThreadRoute.newEmail(opensInChat: true, signedIn: false)
        let neither = ChatNewThreadRoute.newEmail(opensInChat: false, signedIn: false)
        #expect(on == .newThread)
        #expect(off == .compose)
        #expect(signedOut == .compose, "signed out, the chat's field cannot send")
        #expect(neither == .compose)
    }

    @Test("Only a new email started in the chat reopens as its chat, and only with the chat view on")
    func savedDraftRoute() {
        let newEmail = Draft.newEmailKey()
        let compose = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        let reply = Draft.draftKey(replyTo: "acc1:parent@example.com", isForward: false, newId: nil)
        let forward = Draft.draftKey(replyTo: "acc1:parent@example.com", isForward: true, newId: nil)
        let separate = Draft.separateReplyKey(replyTo: reply)
        let onNew = ChatNewThreadRoute.savedDraft(id: newEmail, opensInChat: true, signedIn: true)
        let offNew = ChatNewThreadRoute.savedDraft(id: newEmail, opensInChat: false, signedIn: true)
        let signedOutNew = ChatNewThreadRoute.savedDraft(id: newEmail, opensInChat: true, signedIn: false)
        #expect(onNew == .newThread)
        #expect(offNew == .compose, "with the chat view off every draft opens in compose")
        #expect(signedOutNew == .compose, "signed out, the chat's field cannot send")
        for other in [compose, reply, forward, separate] {
            let route = ChatNewThreadRoute.savedDraft(id: other, opensInChat: true, signedIn: true)
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

    @Test("Writing a new email's chat's email reads Writing your email, as a reply does")
    func composeStatusLine() throws {
        let composing = try #require(ToolRegistry.activityLabels["email_compose"])
        #expect(ChatReplyField.statusLine(composing) == "Writing your email")
    }

    @Test("The card opens with the chat's people, Cc, Bcc and attachments, and the email written with its text version; a carried subject wins over the written one")
    func cardFields() throws {
        let request = MailtoRequest(to: ["Maria <maria@example.com>"], cc: ["lee@example.com"], bcc: ["sam@example.com"],
                                    subject: "Lunch", body: "words")
        let model = ChatNewThreadModel(account: nil, request: request)
        let file = DraftAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        model.addAttachment(file)
        let req = AgentToolRouter.ComposeRequest(
            mode: .compose, replyTo: nil, to: ["someone@example.com"], cc: [], bcc: [], subject: "Agent's subject",
            body: "The email.", origin: ComposeOrigin(sessionKey: model.sessionKey, screen: .chat), suggestion: Self.written)
        let draftId = ChatNewThreadModel.newCardDraftId()
        let card = model.card(for: req, account: nil, draftId: draftId) { _ in }
        #expect(card.prefillDraftId == draftId, "the card writes under the draft id the chat gave it, which finds its send")
        #expect(card.prefillTo == ["\"Maria\" <maria@example.com>"], "To is the chat's people, as a save writes them")
        #expect(card.prefillCc == ["lee@example.com"])
        #expect(card.prefillBcc == ["sam@example.com"])
        #expect(card.prefillSubject == "Lunch", "the link's subject, not the agent's")
        #expect(card.suggestedBody == "The email.")
        #expect(card.suggestion == Self.written, "the email written, with its text version and change command")
        #expect(card.prefillAttachments == [file])
        let plain = ChatNewThreadModel(account: nil)
        plain.setPeople([Self.maria])
        #expect(plain.card(for: req, account: nil, draftId: ChatNewThreadModel.newCardDraftId()) { _ in }.prefillSubject == "Agent's subject",
                "with no subject of its own, the agent's")
    }

    @Test("A new email's agent chat stores no turn; every other chat stores its turns")
    func newEmailTurnsNotStored() async throws {
        let key = ChatNewEmailField.newSessionKey()
        #expect(ChatNewEmailField.isSessionKey(key))
        #expect(!ChatNewEmailField.isSessionKey("inbox"))
        #expect(!ChatNewEmailField.isSessionKey("thread:account:1"))
        let session = ChatPillState.shared.session(for: key)
        defer { ChatPillState.shared.removeSession(for: key) }
        #expect(!session.storesTurns)
        #expect(ChatPillState.Session().storesTurns, "a chat stores its turns unless it is a new email's")
        let turn = ChatTurn(
            id: ChatTurn.generateId(), timestamp: Date().timeIntervalSince1970 * 1000, role: "user",
            content: "chat_converse", userMessage: "words", type: "normal", chars: 5, renderedContent: nil,
            sessionId: key, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
        let evicted = await session.appendTurn(turn, admission: nil)
        #expect(evicted?.isEmpty == true, "kept in memory: nothing written, nothing evicted")
        let pill = try Self.source("TabMail/Views/Inbox/ChatPillState.swift")
        #expect(Self.count("func appendTurn(_ turn: ChatTurn, admission: DemoModeStore.Admission?) async -> [ChatTurn]? { // Kept in memory only: nothing is written and nothing is evicted. guard storesTurns else { return [] }", in: pill) == 1,
                "the guard comes before any write")
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
        // Triage shows the same subject line.
        let triage = try Self.source("TabMail/Views/Inbox/TriageCardView.swift")
        #expect(Self.count("Text(MessageRowView.subjectLine(message.subject, isDraftsFolder: isDraftsFolder))", in: triage) == 1)
        #expect(Self.count("Text(message.subject)", in: triage) == 0, "the triage row's subject goes through the fallback")
        #expect(Self.count("TriageRowView(message: snapshot, isSelected: selectedMessageId == snapshot.id, isDraftsFolder: isDraftsContext,", in: inbox) == 1)
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

    @Test("A reopened draft's person picked again under another name is written under that name; under the same name, as the draft wrote them")
    func toEntriesRepickedUnderAnotherName() {
        let reopened = ChatNewDraft.people(fromTo: ["Maria Lee <Maria@Example.com>", "sam@example.com"])
        let renamed = ChatThread.Person(address: "maria@example.com", name: "Maria Chen")
        let samNamed = ChatThread.Person(address: "sam@example.com", name: "Sam Park")
        let written = ChatNewDraft.toEntries(
            people: [renamed, samNamed], authored: reopened.authored, leftovers: reopened.leftovers)
        #expect(written == ["\"Maria Chen\" <maria@example.com>", "\"Sam Park\" <sam@example.com>"],
                "the name picked, never the one the draft gave")
        let sameAgain = ChatNewDraft.toEntries(
            people: reopened.people, authored: reopened.authored, leftovers: reopened.leftovers)
        #expect(sameAgain == ["\"Maria Lee\" <Maria@Example.com>", "sam@example.com"], "unchanged, as the draft wrote them")
    }

    @Test("The person a saved mailbox names: its address in lower case, under its own name or the address's")
    func personFromMailbox() {
        let mailboxes = [
            RecipientEntry.Recipient(address: "Maria@Example.com", name: "Maria Lee"),
            RecipientEntry.Recipient(address: "sam@example.com", name: nil),
            RecipientEntry.Recipient(address: "Kim@Example.com", name: ""),
        ]
        let people = mailboxes.map(ChatNewDraft.person)
        let addresses = people.map(\.address)
        let names = people.map(\.name)
        #expect(addresses == ["maria@example.com", "sam@example.com", "kim@example.com"])
        #expect(names == ["Maria Lee", ChatThread.fallbackName("sam@example.com"), ChatThread.fallbackName("kim@example.com")])
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

    @Test("The new email's field has its own placeholder; a thread's field keeps its own")
    func fieldPlaceholder() {
        let field = Self.newEmailField()
        let newEmail = ChatReplyField(example: nil, newEmail: field)
        let reply = ChatReplyField(example: nil)
        #expect(newEmail.placeholder == "Message or ask anything")
        #expect(newEmail.placeholder == ChatNewEmailField.placeholder)
        #expect(reply.placeholder == "Write your reply")
        #expect(reply.newEmail == nil)
    }

    @Test("Each new email's chat has its own in-memory session, never the inbox's, kept by its chat for as long as it is open")
    func sessionKeys() {
        let first = ChatNewEmailField.newSessionKey()
        let second = ChatNewEmailField.newSessionKey()
        #expect(first != second)
        #expect(first != "inbox")
        #expect(!first.hasPrefix(Draft.newEmailPrefix), "the session is not the draft")
        let chat = ChatNewThreadModel(account: nil)
        let other = ChatNewThreadModel(account: nil)
        #expect(chat.sessionKey == chat.sessionKey, "one chat, one session")
        #expect(chat.sessionKey != other.sessionKey)
        #expect(chat.sessionKey != chat.draftId)
    }

    @Test("Ending a session cancels its running turn, stops counting it as working, and drops it; other sessions stay")
    func endSession() async {
        let state = ChatPillState.shared
        let key = ChatNewEmailField.newSessionKey()
        let other = ChatNewEmailField.newSessionKey()
        defer { state.endSession(for: other) }
        let session = state.session(for: key)
        session.chatMessages.append(ChatMessage(role: .user, content: "Hi", timestamp: Date()))
        state.session(for: other).chatMessages.append(ChatMessage(role: .user, content: "Stay", timestamp: Date()))
        let turn = Task<Void, Never> {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        }
        session.activeChatTask = turn
        ActiveAgentTracker.shared.setWorking(key)
        state.endSession(for: key)
        #expect(turn.isCancelled, "the running turn is cancelled")
        // Read before joining: a turn left running fails above, then this cancel lets the join end.
        turn.cancel()
        await turn.value
        #expect(session.activeChatTask == nil)
        #expect(!ActiveAgentTracker.shared.workingSessions.contains(key))
        let fresh = state.session(for: key)
        #expect(fresh.chatMessages.isEmpty, "the session is gone; asking again starts a new one")
        #expect(fresh !== session)
        state.endSession(for: key)
        #expect(state.session(for: other).chatMessages.first?.content == "Stay")
        state.endSession(for: "never-made-\(UUID().uuidString)")
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
        #expect(examples == [
            "ask for the Q2 numbers",
            "invite them to lunch on Friday",
            "thank them for yesterday's meeting",
            "ask when they are free next week",
            "send them the slides from today",
            "ask how the launch went",
            "remind them about Thursday's review",
            "introduce yourself and ask for a call",
        ], "the decided set: each is an email to write, none a reply")
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

    @Test("A picked item is named by the attachments already there when it lands")
    func pickedItemCountsWhatIsThere() async {
        let model = ChatNewThreadModel(account: nil)
        model.addAttachment(DraftAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data([1])))
        let loading = model.addPicked(["photo"]) { _ in (data: Data([2]) as Data?, type: UTType.jpeg as UTType?) }
        await loading?.value
        let names = model.attachments.map(\.filename)
        let types = model.attachments.map(\.mimeType)
        #expect(names == ["report.pdf", "photo_2.jpeg"])
        #expect(types == ["application/pdf", "image/jpeg"])
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

    @Test("The inbox compose button reads the setting and the session at the tap and pushes the chat; otherwise compose as before")
    func inboxWiring() throws {
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        #expect(Self.count("ComposeToolbarButton(onNewCompose: { collapseChat() startNewEmail() })", in: inbox) == 1)
        // The whole toolbar item, so no modifier (a `.disabled` in some folder) is added to the
        // button: the compose button starts a new email in every folder, Drafts included.
        #expect(Self.count("ToolbarItem(placement: .topBarTrailing) { ComposeToolbarButton(onNewCompose: { collapseChat() startNewEmail() }) .tutorialLockedNavigation() .transaction { $0.disablesAnimations = true } }", in: inbox) == 1)
        #expect(Self.count("ComposeToolbarButton(", in: inbox) == 1, "one compose button in the mailbox")
        #expect(Self.count("switch ChatNewThreadRoute.newEmail(opensInChat: ChatViewConfig.opensInChat, signedIn: hasTabMailSession) { case .newThread: newEmail = ChatNewThreadModel(account: viewModel.primaryAccount) case .compose: viewModel.showCompose = true }", in: inbox) == 1)
        #expect(Self.count(".navigationDestination(item: $newEmail) { model in ChatNewThreadView(model: model) }", in: inbox) == 1)
        #expect(Self.count(".fullScreenCover(isPresented: $vm.showCompose) { ComposeView(account: viewModel.primaryAccount) }", in: inbox) == 1,
                "the chat view off keeps today's compose")
        #expect(Self.count("viewModel.showCompose = true", in: inbox) == 1, "only through the route")
    }

    @Test("A saved draft is routed once its preparation checked the row; the chat is made there, once")
    func draftOpenWiring() throws {
        let presenter = try Self.source("TabMail/Views/Compose/DraftComposePresenter.swift")
        #expect(Self.count("@State private var opensInChat = ChatViewConfig.opensInChat", in: presenter) == 1)
        #expect(Self.count("if case .ready(let ready) = prepared, ChatNewThreadRoute.savedDraft(id: ready.draft.id, opensInChat: opensInChat, signedIn: signedIn) == .newThread { newEmail = ChatNewThreadModel(reopening: ready.draft, account: ready.account) } else { newEmail = nil } outcome = prepared", in: presenter) == 1)
        #expect(Self.count("private func prepare() async { let signedIn = hasTabMailSession #if DEBUG", in: presenter) == 1,
                "the session is read as the open starts, before the preparation suspends")
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
        // The old gate in any spelling: spaces and parentheses do not matter to it.
        let bare = pill.filter { !$0.isWhitespace && $0 != "(" && $0 != ")" }
        #expect(Self.count("!isComposeMode&&message==nil", in: bare) == 0, "nor in another spelling")
        #expect(Self.count("message==nil&&!isComposeMode", in: bare) == 0, "nor turned around")
        // Nor a new gate on the compose context and message alone, which a new email also passes:
        // the one such test is isInboxChat's own.
        #expect(Self.count("composeContext==nil&&message==nil", in: bare) == 1, "only isInboxChat tests these two")
        #expect(Self.count("message==nil&&composeContext==nil", in: bare) == 0, "nor turned around")
        let sessionAt = try #require(pill.range(of: "if let newEmail = replyField?.newEmail { return newEmail.sessionKey }"))
        let inboxAt = try #require(pill.range(of: "return \"inbox\""))
        #expect(sessionAt.lowerBound < inboxAt.lowerBound, "its own session, before the inbox's")
        let send = try #require(pill.range(of: "private func sendFromReplyField(_ text: String, _ field: ChatReplyField) {"))
        let intercept = try #require(pill.range(of: "if let newEmail = field.newEmail { guard let people = newEmail.send(text) else { return } newEmailTo = people }", range: send.upperBound..<pill.endIndex))
        let sent = try #require(pill.range(of: "fieldFill.apply(.sentFromField)", range: send.upperBound..<pill.endIndex))
        #expect(intercept.lowerBound < sent.lowerBound, "its Send is the chat's, before any agent send")
        // With people picked, the words are the request of the new email's compose edit, and never
        // reach the agent (ADR-IOS-114 decision 10, amended 2026-11-25); the nudge that once sent
        // them to the agent is gone. A new email's chat has no email to reply to, so its send
        // carries no reply field and keeps its words itself.
        #expect(Self.count("if let newEmailTo { composeNewEmailFromField(text, to: newEmailTo) } else if let message {", in: pill) == 1)
        #expect(Self.count("private func composeNewEmailFromField(_ text: String, to people: [ChatThread.Person]) { // As mailboxes with their names, so the email written can greet them by name. let to = ChatNewDraft.toEntries(people: people, authored: [], leftovers: []) runFieldCompose(fieldReply: nil, fieldWordsKey: nil) { invocation in await EmailComposeTool.composeWithRegisteredTool(text, to: to, invocation: invocation) }", in: pill) == 1)
        #expect(Self.count("EmailComposeTool.composeWithRegisteredTool(", in: pill) == 1)
        #expect(Self.count("newEmailTo", in: pill) == 4, "only the field's own Send names the people")
        #expect(Self.count("agentMessage", in: pill) == 0)
        #expect(Self.count(".task(id: replyField?.newEmail?.sessionKey) { startNewEmail() }", in: pill) == 1)
        #expect(Self.count(".onChange(of: inputText) { _, words in replyField?.newEmail?.wordsChanged(words) }", in: pill) == 1)
        let bar = try Self.source("TabMail/Views/Inbox/DynamicIslandChat+ReplyField.swift")
        // The paperclip at the text's end: a new email's, or a thread's (`ChatReplyField.paperclip`).
        #expect(Self.count("if let attach = field.paperclip {", in: bar) == 1)
        #expect(Self.count("ChatPaperclipButton(attach: attach)", in: bar) == 1)
    }

    @Test("Back saves before it leaves, the background saves, and the open draft is kept from eviction")
    func screenWiring() throws {
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count(".navigationBarBackButtonHidden(true)", in: view) == 1)
        #expect(Self.count("Button { leave() } label:", in: view) == 1)
        #expect(Self.count("let outcome = await model.saveIfNeeded() isLeaving = false switch outcome { case .saved: dismiss() case .refused(let message): saveRefusal = message }", in: view) == 1)
        #expect(Self.count("if phase == .background { Task { await saveInBackground() } }", in: view) == 1)
        #expect(Self.count("Button(\"Leave without saving\", role: .destructive) { leaveWithoutSaving() }", in: view) == 1)
        #expect(Self.count(".onAppear { opened() }", in: view) == 1)
        // The new email and the sent email's thread share one host, so the swap from one to the
        // other neither closes the screen nor takes down what it presents (a Group would give each
        // its own open, close and covers).
        #expect(Self.count("var body: some View { // One container for both, never a Group: a Group gives its modifiers to each child, so the // swap would run this screen's close and open, and take down a cover presented over it // (a reopened compose included). The ZStack keeps one host for the whole presentation. ZStack { if let threadId { // The sent email's thread, with its own header, Forward and reply field. ChatThreadView(messageId: threadId) } else { newEmail } } // Back saves first", in: view) == 1,
                "one host for the new email and its thread")
        #expect(Self.count(".onDisappear { if !showsCamera { closed() } }", in: view) == 1,
                "the camera's cover hides the screen without closing it")
        #expect(Self.count("DraftSessionRegistry.shared.register(model.draftId)", in: view) == 1)
        #expect(Self.count("DraftSessionRegistry.shared.unregister(model.draftId)", in: view) == 1)
        #expect(Self.count("model.setPeople(ChatNewDraft.people(after: done, current: model.people))", in: view) == 1)
        // The paperclip's three choices each open their own picker (the simulator has no camera,
        // and a system picker cannot be driven from a hosted test).
        #expect(Self.count("switch source { case .photos: showsPhotoPicker = true case .camera: showsCamera = true case .files: showsFilePicker = true }", in: view) == 1,
                "photos, camera and files each open their own picker")
        // The keyboard rule, on this screen itself, as the chat's own thread installs it.
        #expect(Self.count(".defaultScrollAnchor(.bottom) .scrollDismissesKeyboard(.interactively) .frame(maxWidth: .infinity, maxHeight: .infinity) .background(Palette.previewPaneBg) .dismissKeyboardOnTap()", in: view) == 1,
                "a tap on the stream, or a drag, dismisses the keyboard")
        let registry = try Self.source("TabMail/Services/AI/DraftSessionRegistry.swift")
        #expect(registry.contains("(5 production files:"), "the registry's census names the chat as a producer")
    }

    /// The new email's field takes a thread's drag up (`ChatReplyFieldTests.fieldDragWiring` pins the
    /// thread's). A hosted test cannot move the pan (memory 128), so its wiring is pinned here; the
    /// open, the VoiceOver action and the swap's wait are pinned on screen in
    /// `ChatNewThreadScreenTests`.
    @Test("A new email's field drags up to open the TabMail panel as a thread's does: the swell, the open at let-go, the freeze held once per drag, and the swap to the thread waiting for the panel")
    func fieldDragWiring() throws {
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(Self.count("@State private var fieldDrag = ChatFieldDrag.Model()", in: view) == 1)
        #expect(Self.count("@State private var fieldPanCut = ChatFieldPan.Cut()", in: view) == 1)
        // The drag's progress is written by the pan's two calls and read only inside modifiers, so a
        // moving finger never rebuilds the screen's body or the field.
        #expect(Self.count("fieldDrag.progress", in: view) == 2, "only the two writes below")
        #expect(Self.count("drag: fieldDrag,", in: view) == 1, "the field gets the model, so its glass swells")
        #expect(Self.count(".modifier(ChatFieldDrag.Swell(model: fieldDrag, sign: -1))", in: view) == 1,
                "the swell taken back out of the layout, so nothing above moves under the drag")
        // Never over the open panel, by drag or by VoiceOver.
        #expect(Self.count("let opensPanel = !chatExpanded return VStack(", in: view) == 1)
        #expect(Self.count(".gesture(ChatFieldPan(isEnabled: opensPanel, cut: fieldPanCut, moved: fieldDragMoved, ended: fieldDragEnded))", in: view) == 1)
        #expect(Self.count("showChat: opensPanel ? { withAnimation(.spring(ChatThreadView.pillSpringModel)) { chatExpanded = true } } : nil,", in: view) == 1)
        let moved = try Self.body(of: "private func fieldDragMoved(_ drag: ChatHorizontalPan.Sample) {", in: view)
        #expect(Self.count("fieldDrag.progress = ChatFieldDrag.progress(translation: drag.travel) }", in: moved) == 1)
        #expect(Self.count("chatExpanded", in: moved) == 0, "a move only swells the field")
        // A cancelled drag resets too, so the field never stays swollen; a finished drag that reaches
        // the open distance opens the panel, in the same spring.
        let ended = try Self.body(of: "private func fieldDragEnded(_ drag: ChatHorizontalPan.Sample, finished: Bool) {", in: view)
        #expect(Self.count("let opens = finished && ChatFieldDrag.opens(letGo: drag)", in: ended) == 1)
        #expect(Self.count("withAnimation(.spring(ChatThreadView.pillSpringModel)) { fieldDrag.progress = ChatFieldDrag.Progress() if opens { chatExpanded = true } }", in: ended) == 1,
                "the let-go opens the panel")
        // The freeze, from the gesture state, so a cancelled drag releases: held from the drag's start,
        // released after the settle and the freeze rule's cooldown, and at once if the field goes.
        #expect(Self.count(".modifier(ChatFieldDrag.Watch(model: fieldDrag) { fieldDragChanged($0) })", in: view) == 1)
        let changed = try Self.body(of: "private func fieldDragChanged(_ dragging: Bool) {", in: view)
        #expect(Self.count("ChatSwipeHold.shared.begin(ChatThreadView.fieldDragHoldId)", in: changed) == 1)
        #expect(Self.count("if dragging { ChatSwipeHold.shared.begin(ChatThreadView.fieldDragHoldId) ChatFieldDragTip.close() return }", in: changed) == 1,
                "held once per drag, from its start; the drag ends the tip")
        #expect(Self.count("ChatSwipeHold.shared.release( ChatThreadView.fieldDragHoldId, after: ChatThreadView.fieldDragSettle + ChatViewLayout.freezeCooldown)", in: changed) == 1)
        #expect(Self.count(".onDisappear { ChatSwipeHold.shared.releaseNow(ChatThreadView.fieldDragHoldId) }", in: view) == 1,
                "the field gone mid-drag ends its freeze")
        #expect(Self.count("ChatThreadView.fieldDragHoldId", in: view) == 3, "begin, release and releaseNow: nothing else holds it")
        // The panel opening under a held drag (the agent answering) cuts that drag off.
        #expect(Self.count(".onChange(of: chatExpanded) { _, expanded in if expanded { fieldPanCut() } }", in: view) == 1)
        // The swap to the sent email's thread waits while the panel is open and runs as it closes;
        // the panel stays out of `newEmailCovered`, which also decides whether a compose card presents.
        #expect(Self.count("guard threadId == nil, let copy = cardSend?.sentCopyId, !newEmailCovered, !chatExpanded else { return }", in: view) == 1)
        #expect(Self.count(".onChange(of: chatExpanded) { _, open in if !open { swapToThread() } }", in: view) == 1)
        #expect(Self.count("showsAddRecipient || showsCamera || showsPhotoPicker || showsFilePicker || agentCompose != nil }", in: view) == 1)
    }

    // MARK: - Helpers

    private static func newEmailField() -> ChatNewEmailField {
        ChatNewEmailField(
            startWords: "", sessionKey: ChatNewEmailField.newSessionKey(),
            wordsChanged: { _ in }, send: { _ in nil }, attach: { _ in })
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

    /// The text from `signature` to the next `private` declaration in `text` (from `source`).
    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature))
        let end = try #require(text[start.upperBound...].range(of: " private "))
        return String(text[start.upperBound..<end.lowerBound])
    }
}

/// The new email's header and attachment tray on screen, as VoiceOver reaches them.
@Suite("New email as a chat, on screen", .serialized, .processGlobalState)
@MainActor
struct ChatNewThreadHostedTests {
    private static let maria = ChatThread.Person(address: "maria@example.com", name: "Maria")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam")

    @Test("With nobody picked the header's one button is Add recipient, with the new email's hint, and a press runs the header's action")
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
        // The same render holds a header with someone in it: once its button is on screen, the
        // empty header beside it has been drawn too.
        let window = try Self.host(VStack {
            ChatHeaderView(people: [Self.maria]) {}
            ChatHeaderView(people: []) {}
        })
        defer { window.isHidden = true }
        func buttons() -> [NSObject] {
            HostedAccessibility.elements(under: window).filter { HostedAccessibility.identifier(of: $0) == ChatHeaderView.namesId }
        }
        _ = await Self.waitUntil { !buttons().isEmpty }
        let shown = buttons().map { $0.accessibilityLabel ?? "" }
        #expect(shown.count == 1, "only the header with someone has a button: \(shown)")
        #expect(shown.first?.contains("Maria") == true, "control: the header with someone is drawn")
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
/// reopened draft keeps, every refusal before the save leaving the saved row as it was, and what
/// the real queue and push make of it.
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

    /// A save started, returned once it has run up to its first wait. Both run on the main actor:
    /// the save's task says it started, then runs straight into `saveIfNeeded` until that first
    /// suspends, before this resumes, so a save that does not wait has already finished here.
    private static func startedSave(_ model: ChatNewThreadModel) async -> Task<ChatNewDraftSave.Outcome, Never> {
        let (started, startedNow) = AsyncStream<Void>.makeStream()
        let save = Task { @MainActor () -> ChatNewDraftSave.Outcome in
            startedNow.yield(())
            return await model.saveIfNeeded()
        }
        for await _ in started { break }
        return save
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

    @Test("Through the real queue a saved new email is in Drafts, as a placeholder and a queued save named from its key made colon-safe; its push carries a fresh Message-ID, never the key")
    func realQueueAndWireIdentity() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        try FolderEpochTestFixture.insertFolder(accountId: Self.accountId, path: "Drafts", role: .drafts, pool: fixture.pool)
        let model = ChatNewThreadModel(account: fixture.account)
        model.setPeople([ChatThread.Person(address: "maria@example.com", name: "Maria")])
        model.words = "Lunch on Friday?"
        let outcome = await model.saveIfNeeded()
        #expect(outcome == .saved)
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow)
        let epoch = try #require(saved.instanceEpoch)
        let headerId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: Self.accountId, draftsFolderPath: "Drafts", draftId: model.draftId, instanceEpoch: epoch)
        let headerRow = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        let placeholder = try #require(headerRow, "the Drafts list has the draft")
        let draftId = model.draftId
        let ops = try await fixture.pool.read { db in
            try PendingOperation.filter(Column("draftId") == draftId).fetchAll(db)
        }
        #expect(placeholder.folderPath == "Drafts")
        #expect(placeholder.snippet.contains("Lunch on Friday?"))
        #expect(placeholder.to.contains("maria@example.com"))
        #expect(placeholder.messageId == PendingOperation.draftPlaceholderMessageId(draftId: model.draftId, instanceEpoch: epoch))
        #expect(!placeholder.messageId.contains(Draft.newEmailPrefix), "the key's colon is not in the header's id")
        #expect(ops.count == 1, "one queued save")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .saveDraft)
        #expect(ops[0].instanceEpoch == epoch)

        // The push: what reaches the provider names the email by a fresh Message-ID.
        let provider = MockEmailProvider(saveDraftResult: .created(.imap(folder: "Drafts", uidValidity: 1, uid: 7)))
        _ = try? await DraftStore.shared.pushDraftToServer(
            draftId: model.draftId, expectedInstanceEpoch: epoch, provider: provider,
            runtimeKind: .imap, draftsFolderPath: "Drafts")
        let sent = await provider.savedDraftPayloads.map(\.draft)
        #expect(sent.count == 1, "control: the push reached the provider")
        guard sent.count == 1 else { return }
        let wireId = try #require(sent[0].messageId)
        let localPart = String(model.draftId.dropFirst(Draft.newEmailPrefix.count)).lowercased()
        #expect(model.draftId.hasPrefix(Draft.newEmailPrefix) && !localPart.isEmpty, "control: the key is the prefix and its own id")
        #expect(!wireId.contains(model.draftId))
        #expect(!wireId.contains(Draft.newEmailPrefix), "the local key never goes on the wire")
        #expect(!wireId.lowercased().contains(localPart), "nor its own id, in any spelling of the key: \(wireId)")
        #expect(wireId.contains("@"), "a usable Message-ID of its own: \(wireId)")
        // A new email replies to nothing, and its own id is in no header, with or without hyphens.
        let pushed = sent[0]
        #expect(pushed.inReplyTo == nil, "a new email replies to nothing")
        #expect(pushed.references.isEmpty, "and is in no thread")
        let compact: (String) -> String = { $0.lowercased().replacingOccurrences(of: "-", with: "") }
        let key = compact(localPart)
        let headers = [wireId] + [pushed.inReplyTo].compactMap { $0 } + pushed.references
        let leaked = headers.filter { compact($0).contains(key) }
        #expect(!key.isEmpty, "control: the key's own id")
        #expect(leaked.isEmpty, "the key's own id is in no header, in any spelling: \(leaked)")
        #expect(sent[0].body == "Lunch on Friday?")
        #expect(sent[0].to == ["\"Maria\" <maria@example.com>"])
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
        let again = ChatNewThreadModel(reopening: draft, account: fixture.account)
        #expect(again.draftId == model.draftId, "control: the same draft opened again")
        #expect(again.sessionKey != model.sessionKey, "each opening has its own in-memory session")
    }

    @Test("After the card's Send the chat goes on as a new email to the same people, with the subject, Cc and Bcc it carries, an empty field and no attachments, in a draft and session of its own; left as it is it saves nothing, and typed words save to its own draft")
    func nextEmailAfterSend() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, subject: "Lunch", cc: ["lee@example.com"], bcc: ["sam@example.com"])
        let recorder = QueueRecorder()
        let sent = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        #expect(!sent.attachments.isEmpty && !sent.words.isEmpty, "control: the sent chat had words and a file")
        let next = ChatNewThreadModel(after: sent)
        #expect(next.draftId != sent.draftId, "a draft of its own: the sent chat's was discarded at the send")
        #expect(Draft.isNewEmailKey(next.draftId), "a new email's chat draft, which reopens as a chat")
        #expect(next.sessionKey != sent.sessionKey, "an agent session of its own")
        #expect(next.cursor.newEpoch != sent.cursor.newEpoch, "a generation of its own")
        #expect(next.account?.id == fixture.account.id)
        #expect(next.people == sent.people, "the same people")
        #expect(next.carried == sent.carried, "the same subject, Cc and Bcc")
        #expect(next.startWords.isEmpty && next.words.isEmpty, "an empty field")
        #expect(next.attachments.isEmpty, "no attachments")
        #expect(next.savedAt == nil, "never saved")

        let untouched = await next.saveIfNeeded()
        #expect(untouched == .saved && recorder.calls.isEmpty, "left as it is, nothing is saved")
        let rowsBefore = try await rowCount(fixture)

        next.words = "And dessert?"
        let typed = await next.saveIfNeeded()
        #expect(typed == .saved)
        #expect(recorder.calls == ["\(next.draftId)|\(fixture.account.id)"], "typed words save to its own draft")
        let written = try await row(fixture, next.draftId)
        #expect(written?.body == "And dessert?")
        #expect(written?.subject == "Lunch", "with the carried subject")
        let rowsAfter = try await rowCount(fixture)
        #expect(rowsAfter == rowsBefore + 1, "a row of its own: the sent chat's draft is left to its own discard")
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

    @Test("A draft another session saved after the chat opened is never overwritten from the chat, and going back to what was opened then saves nothing")
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

        // A refused save wrote nothing, so the chat still compares with what it opened: going
        // back to the draft's own words saves nothing and leaves the other session's row as it is.
        model.words = "Lunch on Friday?"
        let again = await model.saveIfNeeded()
        let finalRow = try await row(fixture, draft.id)
        let final = try #require(finalRow)
        #expect(again == .saved, "back to what was opened: nothing to save")
        #expect(final.body == "Written in compose")
        #expect(recorder.calls.isEmpty)
    }

    @Test("A save that a newer save of the draft already beat on disk is refused, writes nothing, and leaves the chat comparing with what it opened")
    func supersededSaveKeepsWhatWasOpened() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, attachments: [])
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        let id = draft.id
        // A newer save of the same draft, in this session: the row on disk is later than any
        // snapshot the chat takes now, so the store keeps it and does not apply the chat's.
        let later = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await fixture.pool.write { db in
            try db.execute(sql: "UPDATE draft SET updatedAt = ?, body = ? WHERE id = ?",
                           arguments: [later, "Saved later", id])
        }
        model.words = "Written in the chat"
        let outcome = await model.saveIfNeeded()
        let afterRow = try await row(fixture, draft.id)
        let after = try #require(afterRow)
        let refused: Bool
        if case .refused = outcome { refused = true } else { refused = false }
        #expect(refused, "the chat's save was not applied: \(outcome)")
        #expect(after.body == "Saved later")
        #expect(recorder.calls.isEmpty)

        // Nothing of the chat's was written, so going back to the draft's own words saves nothing.
        model.words = "Lunch on Friday?"
        let again = await model.saveIfNeeded()
        let finalRow = try await row(fixture, draft.id)
        let final = try #require(finalRow)
        #expect(again == .saved, "back to what was opened: nothing to save")
        #expect(final.body == "Saved later")
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
        let save = await Self.startedSave(model)
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

    @Test("A picked item that fails to load does not hold the save: it waits for the rest and saves what loaded")
    func failedPickLetsTheSaveFinish() async throws {
        struct LoadFailed: Error {}
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        let (release, releaseNow) = AsyncStream<Void>.makeStream()
        let loading = model.addPicked(["broken", "empty", "photo"]) { item in
            if item == "broken" { throw LoadFailed() }
            if item == "empty" { return (data: nil, type: UTType.png as UTType?) }
            for await _ in release { break }
            return (data: Data([7]) as Data?, type: UTType.png as UTType?)
        }
        let save = await Self.startedSave(model)
        let rowsWhileLoading = try await rowCount(fixture)
        #expect(rowsWhileLoading == 0, "the failed items settle, the loading one still holds the save")
        releaseNow.yield(())
        await loading?.value
        let outcome = await save.value
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow)
        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: saved.attachmentsDirName)
        let loadedNames = loaded.map(\.filename)
        let failures = [0, 1].map { DraftAttachmentImport.pickedFailureLabel(index: $0) }
        #expect(outcome == .saved)
        #expect(loadedNames == ["photo_1.png"])
        #expect(model.failedImports == failures)
    }

    @Test("Back and the background saving at once write the draft once")
    func oneSaveAtATime() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = makeModel(fixture, recorder)
        model.words = "Saved once"
        // The database's writer is held, so the first save is still running when the second starts.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let (holding, holdingNow) = AsyncStream<Void>.makeStream()
        let pool = fixture.pool
        let hold = Task.detached {
            try await pool.writeWithoutTransaction { _ in
                holdingNow.yield(())
                release.wait()
            }
        }
        for await _ in holding { break }
        let first = await Self.startedSave(model)
        let firstRunning = model.isSaving
        #expect(firstRunning, "control: the first save is running, held at the database")
        let second = await Self.startedSave(model)
        let queuedWhileHeld = recorder.calls.count
        #expect(queuedWhileHeld == 0, "control: no save is done while the writer is held")
        release.signal()
        try await hold.value
        let outcomes = [await first.value, await second.value]
        let rows = try await rowCount(fixture)
        #expect(outcomes == [.saved, .saved])
        #expect(recorder.calls.count == 1, "the second save waited for the first and found nothing left to save")
        #expect(rows == 1)
        #expect(model.isSaving == false)
    }
}
