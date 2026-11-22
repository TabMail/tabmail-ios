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
/// against a real database: what the field shows of a reopened draft, Send's ask and the way from
/// it to "Add recipient", the header's sheet, the alert a reopened draft with unreadable
/// attachments shows, and what the app going to the background, Back, "Leave without saving" and
/// the screen going away any other way save, end and give back. Also which screen a saved new
/// email's draft opens in from Drafts (`DraftComposePresenter`).
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
    private final class Stage {
        var phase: ScenePhase = .active
        var pushed: ChatNewThreadModel?
        var shown = true
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
                        .navigationDestination(item: $stage.pushed) { ChatNewThreadView(model: $0) }
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
        let draft = try await savedDraft(fixture, body: "Lunch on Friday?", attachment: Self.menu)
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

    private enum Opened: Equatable { case chat, compose, neither }

    /// Opens `draft` as the Drafts list does (`DraftComposePresenter`, a cover of its own) and tells
    /// which screen came up: the chat by its header, compose by its recipient fields. Then closes
    /// it and waits for its draft to be given back.
    private func opened(_ draft: Draft, _ fixture: Fixture, signedIn: Bool) async throws -> Opened {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [fixture.account]
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let root = DraftComposePresenter(source: .draftId(draft.id))
            .environment(\.hasTabMailSession, signedIn)
            .environment(navigationStore)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        var result = Opened.neither
        try await Self.waitUntil {
            if Self.names(in: window) != nil {
                result = .chat
            } else if HostedAccessibility.identifiers(in: window).contains(where: { $0.hasPrefix("recipientInput-") }) {
                result = .compose
            }
            return result != .neither
        }
        if result == .neither {
            Issue.record("no screen came up for \(draft.id): \(HostedAccessibility.identifiers(in: window).prefix(20))")
        }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        try await Self.waitUntil { !DraftSessionRegistry.shared.isActive(draft.id) }
        return result
    }

    /// Runs `body` with the Chat View setting as given and AI on (not opted out, the plan's gate
    /// open), then puts all three back.
    private static func withChatView(_ on: Bool, _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let savedChat = defaults.object(forKey: ChatViewConfig.enabledKey)
        let savedOptOut = AIService.optOutStore.object(forKey: AIService.optOutAllAIKey)
        let gate = AISubscriptionGate.shared
        let gateWasActive = gate.isActive
        defer {
            defaults.set(savedChat, forKey: ChatViewConfig.enabledKey)
            AIService.optOutStore.set(savedOptOut, forKey: AIService.optOutAllAIKey)
            if gateWasActive { gate.openGate() } else { gate.closeGate() }
        }
        defaults.set(on, forKey: ChatViewConfig.enabledKey)
        AIService.optOutStore.set(false, forKey: AIService.optOutAllAIKey)
        gate.openGate()
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

    private func row(_ fixture: Fixture, _ id: String) async throws -> Draft? {
        try await fixture.pool.read { db in try Draft.fetchOne(db, key: id) }
    }

    private func rowCount(_ fixture: Fixture) async throws -> Int {
        try await fixture.pool.read { db in try Draft.fetchCount(db) }
    }

    private static let menu = DraftAttachment(filename: "menu.pdf", mimeType: "application/pdf", data: Data([4, 5, 6]))

    /// A saved new email's draft to nobody yet, as the chat wrote it earlier, with `attachment`
    /// stored in its own directory; with `unreadableAttachment`, its row names an attachments
    /// directory that was never written. `id` gives another key (a draft compose wrote).
    private func savedDraft(
        _ fixture: Fixture, body: String, id: String = Draft.newEmailKey(),
        attachment: DraftAttachment? = nil, unreadableAttachment: Bool = false
    ) async throws -> Draft {
        let updatedAt = Date().addingTimeInterval(-60).timeIntervalSince1970
        var dirName: String?
        if let attachment {
            let name = DraftAttachmentStorage.newStagingDirName()
            try DraftAttachmentStorage.saveAttachments([attachment], dirName: name)
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
