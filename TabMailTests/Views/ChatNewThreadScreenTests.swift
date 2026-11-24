/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// A new email's chat on screen, signed in, pushed in a navigation as the mailbox list pushes it,
/// against a real database: what the field shows of a reopened draft and of an empty one (focus,
/// mic, paperclip, the "e.g." line, the row's order and places), the typed words kept when another
/// screen hides the chat and it shows again, the attachments waiting above it and the files that could
/// not be added, Send's ask, its Cancel and
/// the way from it to "Add recipient", Send with someone picked, the header's sheet, the alert a
/// reopened draft with unreadable attachments shows, and what the app going to the background,
/// Back, "Leave without saving" and the screen going away any other way save, end, give back and
/// say. Also the Drafts row of a saved new email and which screen its draft opens in from Drafts
/// (`DraftComposePresenter`), in the list's cover or pushed, and with the setting changed meanwhile.
@Suite("New email as a chat, the whole screen", .serialized, .processGlobalState)
@MainActor
struct ChatNewThreadScreenTests {
    nonisolated private static let accountId = "chat-new-email-screen"
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
        /// Whether the draft was still kept from eviction as each save was admitted.
        var keptAtAdmission: [Bool] = []
        var answer = true

        func queue(_ draftId: String, _ accountId: String) -> Bool {
            calls.append("\(draftId)|\(accountId)")
            keptAtAdmission.append(DraftSessionRegistry.shared.isActive(draftId))
            return answer
        }
    }

    /// The screen's scene phase and whether it is pushed, both moved by the test.
    @MainActor @Observable
    fileprivate final class Stage {
        var phase: ScenePhase = .active
        var pushed: ChatNewThreadModel?
        var shown = true
        /// Another screen pushed over the chat, which hides it until it is popped.
        var covered = false
        /// Pushed once: the root appearing again after Back does not push the chat again.
        var didPush = false
    }

    /// The mailbox list's navigation, reduced to the push: the chat is pushed once the root
    /// appears, as the compose button's tap pushes it, and Back pops it.
    private struct Navigation: View {
        @Bindable var stage: Stage
        let model: ChatNewThreadModel

        var body: some View {
            if stage.shown {
                NavigationStack {
                    Color.clear
                        .navigationDestination(item: $stage.pushed) {
                            ChatNewThreadView(model: $0)
                                .navigationDestination(isPresented: $stage.covered) { Color.black }
                        }
                        .onAppear {
                            guard !stage.didPush else { return }
                            stage.didPush = true
                            stage.pushed = model
                        }
                }
                .environment(\.scenePhase, stage.phase)
                .environment(\.hasTabMailSession, true)
            } else {
                // The list the chat sat on, replaced (on iPad, another mailbox picked).
                Color.clear
            }
        }
    }

    @MainActor
    private struct Screen {
        let controller: UIHostingController<AnyView>
        let stage: Stage
        var view: UIView { controller.view }
    }

    // MARK: - The screen's behaviour

    @Test("Reopened, the draft's words are in the field; Send with nobody picked asks who it is to, and the ask's Add recipient opens the sheet")
    func reopenedWordsAndSendAsks() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await reopenedWordsAndSendAsksBody() }
    }

    private func reopenedWordsAndSendAsksBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, body: "Lunch on Friday?", attachments: [Self.menu])
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { _, _ in true })
        #expect(model.attachments.map(\.data) == [Self.menu.data], "control: the reopened draft has its file")
        try await withScreen(model) { screen in
            try await Self.waitUntil { Self.fieldText(in: screen.view) == "Lunch on Friday?" }
            #expect(Self.fieldText(in: screen.view) == "Lunch on Friday?", "the reopened words are put in the field")
            try await Self.settle()
            #expect(HostedAccessibility.activate("chatSend", in: screen.view),
                    "Send takes a tap: \(HostedAccessibility.identifiers(in: screen.view))")
            try await Self.waitUntil { Self.alert(screen)?.title == ChatNewThreadView.askTitle }
            let ask = try #require(Self.alert(screen), "Send asks: \(String(describing: Self.topPresented(screen)))")
            #expect(ask.title == ChatNewThreadView.askTitle)
            #expect(ask.message == ChatNewThreadView.askMessage)
            try Self.press(ChatReplyToSheet.addRecipientTitle, on: ask)
            try await Self.waitUntil { Self.sheetIsUp(screen) }
            #expect(Self.sheetIsUp(screen), "the ask's Add recipient opens the sheet: \(Self.presentedLabels(screen))")
            #expect(model.words == "Lunch on Friday?", "the words stay")
            #expect(model.attachments.map(\.filename) == [Self.menu.filename], "the attachment stays")
            #expect(model.attachments.map(\.data) == [Self.menu.data], "with its bytes")
        }
    }

    @Test("The header shows New email as its subject, and its Add recipient opens the sheet titled Add recipient")
    func headerOpensTheSheet() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await headerOpensTheSheetBody() }
    }

    private func headerOpensTheSheetBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { _, _ in true })
        try await withScreen(model) { screen in
            let names = try #require(Self.names(in: screen.view))
            #expect(HostedAccessibility.labels(in: screen.view).contains(ChatNewEmailSubjectLine.text),
                    "the subject line reads New email: \(HostedAccessibility.labels(in: screen.view).prefix(12))")
            #expect(Self.topPresented(screen) == nil, "control: nothing is open yet")
            #expect(names.accessibilityActivate())
            try await Self.waitUntil { Self.sheetIsUp(screen) }
            #expect(Self.sheetIsUp(screen), "the sheet opened: \(Self.presentedLabels(screen))")
        }
    }

    @Test("The words typed go to the draft, and the app going to the background saves them; the chat stays")
    func backgroundSaves() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await backgroundSavesBody() }
    }

    private func backgroundSavesBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        try await withScreen(model) { screen in
            #expect(ThreadChatTests.type("See you at noon", in: screen.view), "control: the field takes words")
            try await Self.waitUntil { model.words == "See you at noon" }
            #expect(model.words == "See you at noon", "the field's words go to the draft")
            let before = try await rowCount(fixture)
            #expect(before == 0, "control: nothing is saved before the app leaves")
            screen.stage.phase = .background
            try await Self.waitUntil { recorder.calls.count == 1 }
            let savedRow = try await row(fixture, model.draftId)
            let saved = try #require(savedRow, "the background saved the draft")
            #expect(saved.body == "See you at noon")
            #expect(recorder.calls == ["\(model.draftId)|\(Self.accountId)"])
            #expect(screen.stage.pushed === model, "the chat stays open")
            #expect(DraftSessionRegistry.shared.isActive(model.draftId), "still open, still kept from eviction")
            try await Self.settle()
            #expect(Self.topPresented(screen) == nil, "a save that worked says nothing")
        }
    }

    @Test("A link's chat going to the background saves nothing while it holds just what the link brought; once its words change, the background saves them with the link's To, Cc, Bcc and subject")
    func linkBackgroundSaves() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await linkBackgroundSavesBody() }
    }

    private func linkBackgroundSavesBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let link = MailtoRequest(
            to: ["Maria Lee <maria@example.com>"], cc: ["Sam Park <sam@example.com>"], bcc: ["alex@example.com"],
            subject: "Lunch on Friday", body: "Are you free at noon?\nOr later this week?")
        let model = ChatNewThreadModel(account: fixture.account, request: link, queueDraftSave: { recorder.queue($0, $1) })
        let draftId = model.draftId
        try await withScreen(model) { screen in
            #expect(Self.fieldText(in: screen.view) == "Are you free at noon?\nOr later this week?", "the field starts with the link's whole body")
            screen.stage.phase = .background
            try await Self.settle()
            let untouched = try await rowCount(fixture)
            #expect(untouched == 0, "unchanged since the link, the background saves nothing")
            #expect(recorder.calls.isEmpty, "and queues nothing")
            screen.stage.phase = .active
            #expect(ThreadChatTests.type("Are you free at one?\nOr later this week?", in: screen.view), "control: the field takes words")
            try await Self.waitUntil { model.words == "Are you free at one?\nOr later this week?" }
            screen.stage.phase = .background
            try await Self.waitUntil { recorder.calls.count == 1 }
            let savedRow = try await row(fixture, draftId)
            let saved = try #require(savedRow, "the background saved the change")
            #expect(saved.body == "Are you free at one?\nOr later this week?", "the whole body")
            #expect(saved.toArray.count == 1 && saved.toArray.first?.contains("maria@example.com") == true, "To is the link's person: \(saved.toArray)")
            #expect(saved.ccArray == [RecipientEntry.text(name: "Sam Park", address: "sam@example.com")])
            #expect(saved.bccArray == ["alex@example.com"], "Bcc stays Bcc")
            #expect(saved.subject == "Lunch on Friday")
            #expect(recorder.calls == ["\(draftId)|\(Self.accountId)"])
        }
    }

    @Test("The app going to the background with the save refused says why; the chat and its words stay, and Stay keeps them")
    func backgroundRefusalShown() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await backgroundRefusalShownBody() }
    }

    private func backgroundRefusalShownBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        recorder.answer = false
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        try await withScreen(model) { screen in
            #expect(ThreadChatTests.type("Kept on screen", in: screen.view))
            try await Self.waitUntil { model.words == "Kept on screen" }
            screen.stage.phase = .background
            try await Self.waitUntil { Self.alert(screen)?.title == "This draft couldn't be saved" }
            let refusal = try #require(Self.alert(screen), "the refusal is shown: \(String(describing: Self.topPresented(screen)))")
            #expect(refusal.message == ChatNewDraftSave.notQueuedMessage)
            #expect(recorder.calls.count == 1, "control: the background tried once")
            #expect(screen.stage.pushed === model, "the chat stays open")
            #expect(Self.fieldText(in: screen.view) == "Kept on screen", "the words stay in the field")
            try Self.press("Stay", on: refusal)
            try await Self.waitUntil { Self.alert(screen) == nil }
            #expect(Self.alert(screen) == nil, "Stay closes the alert")
            #expect(screen.stage.pushed === model, "and keeps the chat")
            #expect(model.words == "Kept on screen")
        }
    }

    @Test("An empty new email's field takes focus and has its mic, the paperclip and an e.g. line from the new-email set")
    func emptyFieldReady() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await emptyFieldReadyBody() }
    }

    private func emptyFieldReadyBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { _, _ in true })
        try await withScreen(model) { screen in
            try await Self.waitUntil { Self.editableField(in: screen.view)?.isFirstResponder == true }
            let focused = Self.editableField(in: screen.view)?.isFirstResponder == true
            #expect(focused, "the field takes focus as the chat opens")
            let lines = Self.labels(of: DynamicIslandChat.exampleLineId, in: screen.view)
            let offered = ChatSuggestionConfig.newEmailExamples.map(ChatSuggestionConfig.exampleLine)
            let replies = ChatSuggestionConfig.replyExamples.map(ChatSuggestionConfig.exampleLine)
            let fromNewEmail = !lines.isEmpty && lines.allSatisfy { offered.contains($0) }
            let fromReplies = lines.contains { replies.contains($0) }
            #expect(fromNewEmail, "the e.g. line is a new-email example: \(lines)")
            #expect(!fromReplies, "never a reply's: \(lines)")
            let labels = HostedAccessibility.labels(in: screen.view)
            let hasMic = labels.contains("Dictate") || labels.contains("Stop dictation")
            #expect(hasMic, "the field has its mic: \(labels.prefix(24))")
            let ids = HostedAccessibility.identifiers(in: screen.view)
            #expect(ids.contains(ChatPaperclipButton.id), "and the paperclip: \(ids.prefix(24))")
            // The row keeps its places: the mic at its start, then the words, the paperclip at
            // their end, and Send at the row's end; the mic and Send keep their widths.
            let rowFrame = Self.elements(ChatNewThreadView.fieldId, in: screen.view).first?.accessibilityFrame
            let micFrame = HostedAccessibility.elements(under: screen.view)
                .first { $0.accessibilityLabel == "Dictate" }?.accessibilityFrame
            let clipFrame = Self.elements(ChatPaperclipButton.id, in: screen.view).first?.accessibilityFrame
            let sendFrame = Self.elements("chatSend", in: screen.view).first?.accessibilityFrame
            let textFrame = Self.editableField(in: screen.view).map { UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0) }
            let row = try #require(rowFrame, "the field's row is on screen")
            let mic = try #require(micFrame, "the mic is on screen")
            let clip = try #require(clipFrame, "the paperclip is on screen")
            let send = try #require(sendFrame, "Send is on screen")
            let text = try #require(textFrame, "the words are on screen")
            let inOrder = mic.midX < text.minX && text.maxX < clip.midX && clip.midX < send.midX
            #expect(inOrder, "mic, words, paperclip, Send, in that order: \(mic) \(text) \(clip) \(send)")
            let sendAtEnd = row.maxX - ChatViewLayout.fieldSendInset - ChatViewLayout.fieldSendSize / 2
            let micAtStart = row.minX + ChatViewLayout.fieldMicInset + ChatViewLayout.fieldMicGlyphWidth / 2
            #expect(abs(send.midX - sendAtEnd) < 1, "Send keeps its place at the row's end: \(send), row \(row)")
            #expect(abs(mic.midX - micAtStart) < 1, "the mic keeps its place at the row's start: \(mic), row \(row)")
            #expect(abs(send.width - ChatViewLayout.fieldTapSize) < 1, "Send keeps its width: \(send.width)")
            #expect(abs(mic.width - ChatViewLayout.fieldMicTapWidth) < 1, "the mic keeps its width: \(mic.width)")
            // With the e.g. line under the words, the paperclip stays on Send's line, level with
            // Send and the mic, not up on the words' first line.
            #expect(fromNewEmail, "control: the e.g. line shows")
            #expect(abs(clip.midY - send.midY) < 1, "the paperclip is level with Send: \(clip) \(send)")
            #expect(abs(clip.midY - mic.midY) < 1, "and with the mic: \(clip) \(mic)")
        }
    }

    @Test("A reopened draft's chat hidden by another screen and shown again keeps the words typed since it opened, and Back saves them")
    func hiddenAndShownKeepsTyping() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hiddenAndShownKeepsTypingBody() }
    }

    /// A screen pushed over the chat hides it and shows it again (the simulator has no camera, and
    /// a full-screen cover over this test's navigation does not make the chat go away): the field
    /// puts the draft's saved words in once, as the chat first opens, never again as it shows.
    private func hiddenAndShownKeepsTypingBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, body: "Lunch on Friday?")
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { _, _ in true })
        let typed = "Lunch on Friday? Bring the menu"
        try await withScreen(model) { screen in
            try await Self.waitUntil { Self.fieldText(in: screen.view) == "Lunch on Friday?" }
            #expect(Self.fieldText(in: screen.view) == "Lunch on Friday?", "control: the reopened words are in the field")
            #expect(ThreadChatTests.type(typed, in: screen.view))
            try await Self.waitUntil { model.words == typed }
            screen.stage.covered = true
            try await Self.waitUntil { !DraftSessionRegistry.shared.isActive(model.draftId) }
            let hidden = !DraftSessionRegistry.shared.isActive(model.draftId)
            #expect(hidden, "control: the screen pushed over it hid the chat (it went away and gave its draft back)")
            screen.stage.covered = false
            try await Self.waitUntil { DraftSessionRegistry.shared.isActive(model.draftId) && Self.fieldText(in: screen.view) != nil }
            let shown = DraftSessionRegistry.shared.isActive(model.draftId)
            #expect(shown, "control: the chat is shown again")
            try await Self.settle()
            #expect(Self.fieldText(in: screen.view) == typed, "the field keeps what was typed")
            #expect(model.words == typed, "and so do the draft's words")
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: screen.view), "Back takes a tap")
            try await Self.waitUntil { screen.stage.pushed == nil && !DraftSessionRegistry.shared.isActive(model.draftId) }
            let savedRow = try await row(fixture, model.draftId)
            let saved = try #require(savedRow, "the draft is saved")
            #expect(saved.body == typed, "Back saved the words typed")
        }
    }

    @Test("A reopened draft's photo and file wait above the field, a thumbnail and a chip; one x takes only its own away, and the other stays through Send's ask and its Cancel")
    func trayOnScreen() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await trayOnScreenBody() }
    }

    private func trayOnScreenBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let photo = try Self.photo()
        let draft = try await savedDraft(fixture, body: "Pictures from Friday", attachments: [photo, Self.menu])
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        #expect(model.attachments.map(\.filename) == [photo.filename, Self.menu.filename], "control: both reopened, in order")
        let photoLabel = AttachmentFilename.displayLabel(photo.filename)
        let menuLabel = AttachmentFilename.displayLabel(Self.menu.filename)
        try await withScreen(model) { screen in
            try await Self.waitUntil { Self.removeLabels(in: screen.view).count == 2 }
            let both = Self.removeLabels(in: screen.view)
            #expect(both == ["Remove \(photoLabel)", "Remove \(menuLabel)"], "an x on each, in order")
            let tray = try #require(Self.elements(ChatAttachmentTray.id, in: screen.view).first, "the tray is on screen")
            let field = try #require(Self.elements(ChatNewThreadView.fieldId, in: screen.view).first, "the field is on screen")
            let trayBottom = tray.accessibilityFrame.maxY
            let fieldTop = field.accessibilityFrame.minY
            #expect(trayBottom <= fieldTop + 1, "the tray waits above the field: \(trayBottom) vs \(fieldTop)")
            let texts = Self.textLabels(in: screen.view)
            #expect(texts.contains(menuLabel), "the file is a chip with its name: \(texts.prefix(20))")
            #expect(!texts.contains(photoLabel), "the photo is a thumbnail, not a chip")
            let removePhoto = try #require(Self.elements(ChatAttachmentTray.removeId, in: screen.view).first)
            #expect(removePhoto.accessibilityActivate(), "the photo's x takes a tap")
            try await Self.waitUntil { model.attachments.count == 1 }
            #expect(model.attachments.map(\.filename) == [Self.menu.filename], "only the photo went")
            try await Self.waitUntil { Self.removeLabels(in: screen.view) == ["Remove \(menuLabel)"] }
            let left = Self.removeLabels(in: screen.view)
            #expect(left == ["Remove \(menuLabel)"], "the file stays on screen")
            try await Self.settle()
            #expect(HostedAccessibility.activate("chatSend", in: screen.view), "Send takes a tap")
            try await Self.waitUntil { Self.alert(screen)?.title == ChatNewThreadView.askTitle }
            let ask = try #require(Self.alert(screen), "Send asks who it is to")
            try Self.press("Cancel", on: ask)
            try await Self.waitUntil { Self.alert(screen) == nil }
            try await Self.settle()
            #expect(Self.topPresented(screen) == nil, "Cancel closes the ask and opens nothing")
            #expect(screen.stage.pushed === model, "the chat stays")
            #expect(model.words == "Pictures from Friday", "the words stay")
            #expect(model.attachments.map(\.data) == [Self.menu.data], "the file stays, with its bytes")
            let stillWaiting = Self.removeLabels(in: screen.view)
            #expect(stillWaiting == ["Remove \(menuLabel)"], "still waiting above the field")
            #expect(recorder.calls.isEmpty, "Send's ask saves nothing")
        }
    }

    @Test("With someone picked, Send asks nothing and keeps the words, saving nothing; the header's sheet lists who is picked, and the user's own addresses (every account's) typed there are not added")
    func pickedPeople() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await pickedPeopleBody() }
    }

    private func pickedPeopleBody() async throws {
        // The app's debug log, on for this test: the screen's own-address read logs there when it
        // fails, and the last check below reports those lines.
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        let fixture = try fixture()
        defer { finish(fixture) }
        // The user's second account, whose address is the user's own too. It is stored with
        // capitals, as an address can be set up: the sheet compares addresses in lower case.
        let otherAccount = try FolderEpochTestFixture.makeAccount(id: "\(Self.accountId)-Other", provider: .imap, pool: fixture.pool)
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        model.setPeople([ChatThread.Person(address: "maria@example.com", name: "Maria")])
        try await withScreen(model) { screen in
            #expect(ThreadChatTests.type("Lunch on Friday?", in: screen.view))
            try await Self.waitUntil { model.words == "Lunch on Friday?" }
            try await Self.settle()
            #expect(HostedAccessibility.activate("chatSend", in: screen.view), "Send takes a tap")
            try await Self.settle()
            #expect(Self.topPresented(screen) == nil, "with someone picked, Send asks nothing")
            #expect(model.words == "Lunch on Friday?", "the words stay")
            #expect(Self.fieldText(in: screen.view) == "Lunch on Friday?", "in the field too")
            #expect(recorder.calls.isEmpty, "Send saves nothing")
            let rows = try await rowCount(fixture)
            #expect(rows == 0, "and writes no draft")

            // The user's addresses are every account's: this email's account and the other one.
            // The screen reads them as it opens (`loadOwnAddresses`); the window before that read
            // ends is tabmail-ios#1236. This read is the test's own: it confirms both accounts are
            // in the database the screen reads, not that the screen has read them.
            let ownAddresses = [fixture.account.emailAddress, otherAccount.emailAddress]
            try await Self.waitUntil { try await Set(Self.accountAddresses()).isSuperset(of: ownAddresses) }
            let known = try await Self.accountAddresses()
            #expect(Set(known).isSuperset(of: ownAddresses), "control: the database the screen reads has both accounts: \(known)")
            // Each address typed in turn; the last, someone else's, is added, which shows typed
            // text reaches the sheet's choice in this test.
            let typed: [(address: String, people: [String])] = ownAddresses.map { (address: $0, people: ["maria@example.com"]) }
                + [(address: "sam@example.com", people: ["maria@example.com", "sam@example.com"])]
            for entry in typed {
                let names = try #require(Self.names(in: screen.view))
                #expect(names.accessibilityActivate())
                try await Self.waitUntil { Self.sheetIsUp(screen) }
                let listed = Self.presentedLabels(screen)
                // A person's row reads as one element: the name, then the address.
                let listsMaria = listed.contains { $0.contains("Maria") && $0.contains("maria@example.com") }
                #expect(listsMaria, "the sheet lists who is picked: \(listed.prefix(20))")
                let sheet = try #require(Self.topPresented(screen)?.view)
                try await Self.settle()
                #expect(ThreadChatTests.type(entry.address, in: sheet), "the sheet takes an address")
                try await Self.settle()
                let doneButton = HostedAccessibility.elements(under: sheet).first { $0.accessibilityLabel == "Done" }
                let done = try #require(doneButton, "the sheet has Done")
                #expect(done.accessibilityActivate(), "Done takes a tap")
                try await Self.waitUntil { Self.topPresented(screen) == nil }
                #expect(Self.topPresented(screen) == nil, "Done closes the sheet")
                let screenLog = AppLogStore.read(channel: .debug).split(separator: "\n").filter { $0.contains("[ChatNewEmail]") }
                #expect(model.people.map(\.address) == entry.people, "\(entry.address): only someone else's address is added; the screen's log: \(screenLog.suffix(10))")
            }
        }
    }

    @Test("Back saves, then leaves; the chat's session ends and its draft is given back to eviction")
    func backSavesAndCloses() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await backSavesAndClosesBody() }
    }

    private func backSavesAndClosesBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        try await withScreen(model) { screen in
            #expect(DraftSessionRegistry.shared.isActive(model.draftId), "open: kept from eviction")
            let session = Self.markSession(model)
            #expect(ThreadChatTests.type("Back saves this", in: screen.view))
            try await Self.waitUntil { model.words == "Back saves this" }
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: screen.view), "Back takes a tap")
            try await Self.waitUntil { screen.stage.pushed == nil && !DraftSessionRegistry.shared.isActive(model.draftId) }
            #expect(screen.stage.pushed == nil, "Back left the chat")
            let savedRow = try await row(fixture, model.draftId)
            let saved = try #require(savedRow, "Back saved the draft")
            #expect(saved.body == "Back saves this")
            #expect(recorder.calls.count == 1, "saved once: the close has nothing left to keep")
            #expect(!DraftSessionRegistry.shared.isActive(model.draftId), "closed: given back to eviction")
            #expect(ChatPillState.shared.session(for: model.sessionKey) !== session, "the chat's session ended")
            ChatPillState.shared.endSession(for: model.sessionKey)
        }
    }

    @Test("The list the chat sits on replaced (another mailbox picked on iPad): the words are saved, the session ends, the draft is given back")
    func replacedListSaves() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await replacedListSavesBody() }
    }

    private func replacedListSavesBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        try await withScreen(model) { screen in
            let session = Self.markSession(model)
            #expect(ThreadChatTests.type("Not lost", in: screen.view))
            try await Self.waitUntil { model.words == "Not lost" }
            screen.stage.shown = false
            try await Self.waitUntil { recorder.calls.count == 1 && !DraftSessionRegistry.shared.isActive(model.draftId) }
            let savedRow = try await row(fixture, model.draftId)
            let saved = try #require(savedRow, "the screen going away saved the draft")
            #expect(saved.body == "Not lost")
            #expect(recorder.calls == ["\(model.draftId)|\(Self.accountId)"])
            #expect(recorder.keptAtAdmission == [true], "still kept from eviction while the closing save is admitted")
            #expect(!DraftSessionRegistry.shared.isActive(model.draftId), "given back once the save was done")
            #expect(ChatPillState.shared.session(for: model.sessionKey) !== session, "the chat's session ended")
            ChatPillState.shared.endSession(for: model.sessionKey)
        }
    }

    @Test("Leave without saving, after a refused save, leaves the chat and the close saves nothing more")
    func leaveWithoutSavingSavesNothing() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await leaveWithoutSavingSavesNothingBody() }
    }

    private func leaveWithoutSavingSavesNothingBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let recorder = QueueRecorder()
        recorder.answer = false
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { recorder.queue($0, $1) })
        try await withScreen(model) { screen in
            #expect(ThreadChatTests.type("Refused words", in: screen.view))
            try await Self.waitUntil { model.words == "Refused words" }
            #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: screen.view), "Back takes a tap")
            try await Self.waitUntil { Self.alert(screen)?.title == "This draft couldn't be saved" }
            let refusal = try #require(Self.alert(screen), "the refusal is shown")
            #expect(refusal.message == ChatNewDraftSave.notQueuedMessage)
            #expect(recorder.calls.count == 1, "control: Back tried once")
            #expect(screen.stage.pushed === model, "a refused save keeps the chat open")
            try Self.press("Leave without saving", on: refusal)
            try await Self.waitUntil { screen.stage.pushed == nil && !DraftSessionRegistry.shared.isActive(model.draftId) }
            #expect(screen.stage.pushed == nil, "the chat left")
            try await Self.settle()
            #expect(recorder.calls.count == 1, "the close tried no save of its own")
            #expect(!DraftSessionRegistry.shared.isActive(model.draftId))
        }
    }

    @Test("A reopened draft whose attachments cannot be read says so as the chat opens")
    func unreadableAttachmentsShownAtOpen() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await unreadableAttachmentsShownAtOpenBody() }
    }

    private func unreadableAttachmentsShownAtOpenBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let draft = try await savedDraft(fixture, body: "Lunch on Friday?", unreadableAttachment: true)
        let model = ChatNewThreadModel(reopening: draft, account: fixture.account, queueDraftSave: { _, _ in true })
        #expect(model.attachmentLoadFailed, "control: the attachments could not be read")
        try await withScreen(model) { screen in
            try await Self.waitUntil { Self.alert(screen)?.title == ChatNewThreadView.attachmentLoadTitle }
            let alert = try #require(Self.alert(screen), "shown at open: \(String(describing: Self.topPresented(screen)))")
            #expect(alert.message == ChatNewThreadModel.attachmentLoadMessage)
            try Self.press("OK", on: alert)
        }
    }

    @Test("Files that cannot be read are named in Couldn't add, the readable one waits above the field, and OK clears the list so the next failure is shown alone")
    func importFailuresShown() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await importFailuresShownBody() }
    }

    private func importFailuresShownBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let model = ChatNewThreadModel(account: fixture.account, queueDraftSave: { _, _ in true })
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        let readable = folder.appendingPathComponent("agenda.txt")
        let first = folder.appendingPathComponent("plan.pdf")
        let second = folder.appendingPathComponent("budget.xlsx")
        let third = folder.appendingPathComponent("photo.heic")
        struct Unreadable: Error {}
        let read: (URL) throws -> Data = { url in
            guard url == readable else { throw Unreadable() }
            return Data([1, 2, 3])
        }
        try await withScreen(model) { screen in
            model.addFiles([first, readable, second], read: read)
            try await Self.waitUntil { Self.alert(screen)?.title == "Couldn't add" }
            let alert = try #require(Self.alert(screen), "the failures are shown: \(String(describing: Self.topPresented(screen)))")
            let named = [DraftAttachmentImport.fileFailureLabel(first), DraftAttachmentImport.fileFailureLabel(second)]
            #expect(alert.message == named.joined(separator: ", "), "both unreadable files are named, in order")
            #expect(model.attachments.map(\.data) == [Data([1, 2, 3])], "the readable file is added")
            try Self.press("OK", on: alert)
            try await Self.waitUntil { Self.alert(screen) == nil }
            #expect(model.failedImports.isEmpty, "OK clears the failures")
            let readableLabel = AttachmentFilename.displayLabel(model.attachments.first?.filename ?? "")
            try await Self.waitUntil { Self.removeLabels(in: screen.view) == ["Remove \(readableLabel)"] }
            let waiting = Self.removeLabels(in: screen.view)
            #expect(waiting == ["Remove \(readableLabel)"], "the readable file waits above the field")
            try await Self.settle()
            model.addFiles([third], read: read)
            try await Self.waitUntil { Self.alert(screen)?.title == "Couldn't add" }
            let again = try #require(Self.alert(screen), "the next failure is shown")
            #expect(again.message == DraftAttachmentImport.fileFailureLabel(third), "only the new failure, not the cleared ones")
            try Self.press("OK", on: again)
            try await Self.waitUntil { Self.alert(screen) == nil }
            #expect(screen.stage.pushed === model, "the chat stays")
        }
    }

    @Test("Opened from Drafts, a new email's draft reopens as its chat only with the chat view on and signed in; signed out, with the chat view off, and for a draft compose wrote, compose opens")
    func draftOpenRoutes() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await draftOpenRoutesBody() }
    }

    private func draftOpenRoutesBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let newEmail = try await savedDraft(fixture, body: "Lunch on Friday?")
        let composed = try await savedDraft(fixture, body: "Written in compose", id: "compose-draft-\(UUID().uuidString)")
        try await Self.withChatView(true) {
            let on = ChatViewConfig.opensInChat
            #expect(on, "control: the chat view is on")
            let signedIn = try await opened(newEmail, fixture, signedIn: true)
            let signedOut = try await opened(newEmail, fixture, signedIn: false)
            let other = try await opened(composed, fixture, signedIn: true)
            #expect(signedIn == .chat, "on and signed in: the draft's chat")
            #expect(signedOut == .compose, "signed out: compose, where Send works")
            #expect(other == .compose, "a draft compose wrote: compose")
        }
        try await Self.withChatView(false) {
            let on = ChatViewConfig.opensInChat
            #expect(!on, "control: the chat view is off")
            let off = try await opened(newEmail, fixture, signedIn: true)
            #expect(off == .compose, "the chat view off: compose")
        }
    }

    @Test("In Drafts, a saved new email's row reads Draft (no subject yet); tapped, its row opens the chat in the list's cover, and pushed from a message screen in that navigation; Back closes either")
    func draftsListOpensTheChat() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await draftsListOpensTheChatBody() }
    }

    private func draftsListOpensTheChatBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let saved = try await savedThroughTheQueue(fixture, words: "Lunch on Friday?")
        #expect(saved.header.subject.isEmpty, "control: a new email has no subject")
        let row = MessageRowView(message: MessageSnapshot(from: saved.header), showsRecipientInsteadOfSender: true, isDraftsFolder: true)
        try await withWindow(row) { window in
            try await Self.waitUntil { Self.reads(MessageRowView.draftWithoutSubject, in: window) }
            let reads = Self.reads(MessageRowView.draftWithoutSubject, in: window)
            #expect(reads, "the row reads \(MessageRowView.draftWithoutSubject): \(HostedAccessibility.labels(in: window).prefix(12))")
        }
        let navigationStore = NavigationStore()
        navigationStore.accounts = [fixture.account]
        let shown = Shown()
        try await withRegisteredIMAP {
            try await Self.withChatView(true) {
                // Tapped in the Drafts list: a cover of its own, resolved from the row.
                try await withWindow(CoverOpen(shown: shown, header: saved.header, store: navigationStore)) { window in
                    shown.open = true
                    try await Self.backCloses(saved.draftId, words: "Lunch on Friday?", in: window, shown: shown)
                }
                // Opened from a message screen (search and the like): pushed in its navigation.
                try await withWindow(PushedOpen(shown: shown, header: saved.header, store: navigationStore)) { window in
                    shown.open = true
                    try await Self.backCloses(saved.draftId, words: "Lunch on Friday?", in: window, shown: shown)
                }
            }
        }
    }

    /// The draft's chat came up in `window` with `words` in its field; Back closes it and gives the
    /// draft back.
    private static func backCloses(_ draftId: String, words: String, in window: UIWindow, shown: Shown) async throws {
        try await waitUntil { fieldText(in: window) == words }
        let screen = screenShown(in: window)
        #expect(screen == .chat, "the chat opens: \(HostedAccessibility.identifiers(in: window).prefix(20))")
        #expect(fieldText(in: window) == words, "with the draft's words in the field")
        #expect(DraftSessionRegistry.shared.isActive(draftId), "open: kept from eviction")
        try await settle()
        #expect(HostedAccessibility.activate(ChatNewThreadView.backId, in: window), "Back takes a tap")
        try await waitUntil { !shown.open && !DraftSessionRegistry.shared.isActive(draftId) }
        #expect(!shown.open, "Back closes it")
        #expect(!DraftSessionRegistry.shared.isActive(draftId), "and gives the draft back")
    }

    @Test("A Drafts open still being prepared when the chat view setting changes opens as the setting was at the tap")
    func draftsOpenKeepsItsSetting() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await draftsOpenKeepsItsSettingBody() }
    }

    private func draftsOpenKeepsItsSettingBody() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        let saved = try await savedThroughTheQueue(fixture, words: "Lunch on Friday?")
        let header = saved.header
        let navigationStore = NavigationStore()
        navigationStore.accounts = [fixture.account]
        let started = Shown()
        let (held, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        try await withRegisteredIMAP {
            try await Self.withChatView(true) {
                let presenter = DraftComposePresenter(source: .header(header))
                    .environment(\.hasTabMailSession, true)
                    .environment(navigationStore)
                    .environment(\.draftOpenResolverForTesting, {
                        started.open = true
                        for await _ in held { break }
                        return try await ServerDraftComposeLoader.resolveOpenAuthority(header: header)
                    })
                try await withWindow(presenter) { window in
                    try await Self.waitUntil { started.open }
                    #expect(started.open, "control: the open is being prepared")
                    let before = Self.screenShown(in: window)
                    #expect(before == .neither, "control: nothing is open yet")
                    UserDefaults.standard.set(false, forKey: ChatViewConfig.enabledKey)
                    let off = ChatViewConfig.opensInChat
                    #expect(!off, "control: the chat view is now off")
                    release.finish()
                    var after = Opened.neither
                    try await Self.waitUntil {
                        after = Self.screenShown(in: window)
                        return after != .neither
                    }
                    #expect(after == .chat, "the open keeps the setting it started with")
                }
                try await Self.waitUntil { !DraftSessionRegistry.shared.isActive(saved.draftId) }
            }
        }
    }

    private enum Opened: Equatable { case chat, compose, neither }

    /// Whether a cover or push the test opens is up; also, as a flag, whether a held open started.
    @MainActor @Observable
    fileprivate final class Shown {
        var open = false
    }

    /// The Drafts list's tap: the row's header opens in a cover of its own.
    private struct CoverOpen: View {
        @Bindable var shown: Shown
        let header: MessageHeader
        let store: NavigationStore

        var body: some View {
            Color.clear.fullScreenCover(isPresented: $shown.open) {
                DraftComposePresenter(source: .header(header))
                    .environment(\.hasTabMailSession, true)
                    .environment(store)
            }
        }
    }

    /// A message screen's open (`MessageOpenView`): the header pushed in the screen's navigation.
    private struct PushedOpen: View {
        @Bindable var shown: Shown
        let header: MessageHeader
        let store: NavigationStore

        var body: some View {
            NavigationStack {
                Color.clear.navigationDestination(isPresented: $shown.open) {
                    DraftComposePresenter(source: .header(header), presentedAsCover: false)
                        .environment(\.hasTabMailSession, true)
                        .environment(store)
                }
            }
        }
    }

    /// Opens `draft` as the Drafts list does (`DraftComposePresenter`, a cover of its own) and tells
    /// which screen came up: the chat by its header, compose by its recipient fields. Then closes
    /// it and checks its draft is given back.
    private func opened(_ draft: Draft, _ fixture: Fixture, signedIn: Bool) async throws -> Opened {
        let navigationStore = NavigationStore()
        navigationStore.accounts = [fixture.account]
        let root = DraftComposePresenter(source: .draftId(draft.id))
            .environment(\.hasTabMailSession, signedIn)
            .environment(navigationStore)
        var result = Opened.neither
        try await withWindow(root) { window in
            try await Self.waitUntil {
                result = Self.screenShown(in: window)
                return result != .neither
            }
            if result == .neither {
                Issue.record("no screen came up for \(draft.id): \(HostedAccessibility.identifiers(in: window).prefix(20))")
            }
        }
        try await Self.waitUntil { !DraftSessionRegistry.shared.isActive(draft.id) }
        let released = !DraftSessionRegistry.shared.isActive(draft.id)
        #expect(released, "closed: \(draft.id) is given back to eviction")
        return result
    }

    /// Which screen is up in `view`: the chat by its header, compose by its recipient fields.
    private static func screenShown(in view: UIView) -> Opened {
        if names(in: view) != nil { return .chat }
        if HostedAccessibility.identifiers(in: view).contains(where: { $0.hasPrefix("recipientInput-") }) { return .compose }
        return .neither
    }

    /// Shows `root` in a window of its own, runs `body`, then takes the window down, also when
    /// `body` throws.
    private func withWindow(_ root: some View, _ body: @MainActor (UIWindow) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: AnyView(root))
        window.makeKeyAndVisible()
        func takeDown() {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        do {
            try await body(window)
        } catch {
            takeDown()
            throw error
        }
        takeDown()
    }

    /// Runs `body` with an IMAP provider for the fixture's account, never connected: the draft open
    /// checks the account's kind, and nothing here reaches a server.
    private func withRegisteredIMAP(_ body: () async throws -> Void) async throws {
        let provider = IMAPProvider(
            host: "127.0.0.1", port: 1, username: "nobody", password: "unused",
            smtpHost: "127.0.0.1", smtpPort: 1, useTLS: false)
        await AccountManager.shared.registerProviderForTesting(accountId: Self.accountId, provider: provider)
        do {
            try await body()
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)
    }

    /// A new email saved by its chat through the real queue, and the row the Drafts list shows for
    /// it (its placeholder in Drafts).
    private func savedThroughTheQueue(_ fixture: Fixture, words: String) async throws -> (draftId: String, header: MessageHeader) {
        try FolderEpochTestFixture.insertFolder(accountId: Self.accountId, path: "Drafts", role: .drafts, pool: fixture.pool)
        let model = ChatNewThreadModel(account: fixture.account)
        model.words = words
        let outcome = await model.saveIfNeeded()
        #expect(outcome == .saved, "control: saved through the real queue")
        let savedRow = try await row(fixture, model.draftId)
        let saved = try #require(savedRow, "control: the draft is saved")
        let epoch = try #require(saved.instanceEpoch)
        let headerId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: Self.accountId, draftsFolderPath: "Drafts", draftId: model.draftId, instanceEpoch: epoch)
        let headerRow = try await fixture.pool.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        let header = try #require(headerRow, "control: the Drafts list has the draft")
        ChatPillState.shared.endSession(for: model.sessionKey)
        return (model.draftId, header)
    }

    /// Runs `body` with the Chat View setting as given and AI on (the AI choice made, not opted
    /// out, the plan's gate open), then puts all of it back as it was.
    private static func withChatView(_ on: Bool, _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let savedChat = defaults.object(forKey: ChatViewConfig.enabledKey)
        let restoreAI = AITestSetting.save()
        let gate = AIGateTestState()
        defer {
            defaults.set(savedChat, forKey: ChatViewConfig.enabledKey)
            restoreAI()
            gate.restore()
        }
        defaults.set(on, forKey: ChatViewConfig.enabledKey)
        AITestSetting.set(aiOff: false)
        AISubscriptionGate.shared.openGate()
        try await body()
    }

    // MARK: - Fixture

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

    /// The accounts' addresses, read the way the screen reads them.
    private static func accountAddresses() async throws -> [String] {
        try await AppDatabase.dbPool.read { db in try Account.fetchAll(db) }.map(\.emailAddress)
    }

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft? {
        try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) }
    }

    private func rowCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.pool.read { db in try Draft.fetchCount(db) }
    }

    private static let menu = DraftAttachment(filename: "menu.pdf", mimeType: "application/pdf", data: Data([4, 5, 6]))

    /// A photo the tray can draw as a thumbnail.
    private static func photo() throws -> DraftAttachment {
        let side = CGFloat(8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        let data = try #require(image.pngData(), "control: the photo encodes")
        return DraftAttachment(filename: "beach.png", mimeType: "image/png", data: data)
    }

    /// A saved new email's draft to nobody yet, as the chat wrote it earlier, with `attachments`
    /// stored in their own directory; with `unreadableAttachment`, its row names an attachments
    /// directory that was never written. `id` gives another key (a draft compose wrote).
    private func savedDraft(
        _ fixture: Fixture, body: String, id: String = Draft.newEmailKey(),
        attachments: [DraftAttachment] = [], unreadableAttachment: Bool = false
    ) async throws -> Draft {
        let updatedAt = Date().addingTimeInterval(-60).timeIntervalSince1970
        var dirName: String?
        if !attachments.isEmpty {
            let name = DraftAttachmentStorage.newStagingDirName()
            try DraftAttachmentStorage.saveAttachments(attachments, dirName: name)
            dirName = name
        } else if unreadableAttachment {
            dirName = DraftAttachmentStorage.newStagingDirName()
        }
        var draft = Draft(
            id: id, accountId: Self.accountId,
            toJSON: Draft.encodeStringArray([]), ccJSON: Draft.encodeStringArray([]),
            bccJSON: Draft.encodeStringArray([]), subject: "", body: body, replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: updatedAt, updatedAt: updatedAt,
            serverDraftId: nil, serverPushStatus: nil, rfc822MessageId: nil,
            attachmentsDirName: dirName)
        draft.instanceEpoch = Self.generation
        let toInsert = draft
        try await fixture.pool.write { db in try toInsert.insert(db) }
        return draft
    }

    /// Shows the chat pushed as the mailbox list pushes it, waits for its header and field, runs
    /// `body`, then takes it down and waits for its close to finish, so nothing it saves reaches
    /// the database after the test's own.
    private func withScreen(_ model: ChatNewThreadModel, _ body: @MainActor (Screen) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let stage = Stage()
        let controller = UIHostingController(rootView: AnyView(Navigation(stage: stage, model: model)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let screen = Screen(controller: controller, stage: stage)
        func takeDown() async {
            controller.dismiss(animated: false)
            stage.shown = false
            try? await Self.waitUntil { !DraftSessionRegistry.shared.isActive(model.draftId) }
            window.isHidden = true
            window.rootViewController = nil
            ChatPillState.shared.endSession(for: model.sessionKey)
        }
        do {
            try await Self.waitUntil { Self.names(in: screen.view) != nil && Self.fieldText(in: screen.view) != nil }
            #expect(Self.names(in: screen.view) != nil, "control: the chat shows its header: \(HostedAccessibility.labels(in: screen.view).prefix(12))")
            #expect(Self.fieldText(in: screen.view) != nil, "control: the chat shows its field")
            try await body(screen)
        } catch {
            await takeDown()
            throw error
        }
        await takeDown()
    }

    // MARK: - Reading the screen

    /// The header's button: "Add recipient" or the names.
    private static func names(in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { HostedAccessibility.identifier(of: $0) == ChatHeaderView.namesId }
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

    /// The editable field itself, nil while there is none.
    private static func editableField(in view: UIView) -> UIView? {
        if let text = view as? UITextView, text.isEditable { return text }
        if let text = view as? UITextField { return text }
        for subview in view.subviews {
            if let found = editableField(in: subview) { return found }
        }
        return nil
    }

    /// The elements under `view` with the identifier `id`.
    private static func elements(_ id: String, in view: UIView) -> [NSObject] {
        HostedAccessibility.elements(under: view).filter { HostedAccessibility.identifier(of: $0) == id }
    }

    /// The labels of the elements under `view` with the identifier `id`.
    private static func labels(of id: String, in view: UIView) -> [String] {
        elements(id, in: view).compactMap(\.accessibilityLabel)
    }

    /// The tray's x buttons, by their labels, in order.
    private static func removeLabels(in view: UIView) -> [String] {
        labels(of: ChatAttachmentTray.removeId, in: view)
    }

    /// The labels of the text on screen (a file's chip has its name as text; a photo's thumbnail
    /// has none).
    private static func textLabels(in view: UIView) -> [String] {
        HostedAccessibility.elements(under: view)
            .filter { $0.accessibilityTraits.contains(.staticText) }
            .compactMap(\.accessibilityLabel)
    }

    /// Whether some label under `view` reads `text`.
    private static func reads(_ text: String, in view: UIView) -> Bool {
        HostedAccessibility.labels(in: view).contains { $0.contains(text) }
    }

    /// Puts a marker in the chat's session, so its end shows as a new session after it.
    private static func markSession(_ model: ChatNewThreadModel) -> ChatPillState.Session {
        let session = ChatPillState.shared.session(for: model.sessionKey)
        session.chatMessages.append(ChatMessage(role: .user, content: "marker", timestamp: Date()))
        return session
    }

    private static func topPresented(_ screen: Screen) -> UIViewController? {
        var top = screen.controller.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private static func alert(_ screen: Screen) -> UIAlertController? {
        topPresented(screen) as? UIAlertController
    }

    private static func presentedLabels(_ screen: Screen) -> [String] {
        guard let view = topPresented(screen)?.view else { return [] }
        return HostedAccessibility.labels(in: view)
    }

    /// "Add recipient" is up as a sheet, not as the ask's button.
    private static func sheetIsUp(_ screen: Screen) -> Bool {
        alert(screen) == nil && presentedLabels(screen).contains(ChatReplyToSheet.addRecipientTitle)
    }

    /// Presses an alert's button as the user does: UIKit dismisses the alert, then runs that
    /// button's own handler. An alert's action views do not answer `accessibilityActivate` in a
    /// hosted test (`ChatAISummariesNoticeHostedTests.pressOK`).
    private static func press(_ title: String, on alert: UIAlertController) throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let action = try #require(alert.actions.first { $0.title == title }, "the alert has \(title): \(alert.actions.map(\.title))")
        try #require(action.responds(to: NSSelectorFromString("handler")), "UIAlertAction exposes its handler")
        let block = try #require(action.value(forKey: "handler") as AnyObject?, "\(title) has a handler")
        let handler = unsafeBitCast(block, to: Handler.self)
        alert.dismiss(animated: false) { handler(action) }
    }

    /// Polls `condition` for up to ten seconds; the caller asserts on it afterwards.
    private static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Lets the screen apply what just changed.
    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}
