/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Undo send, end to end: the real Send of a hosted compose decides who offers the send's Undo, and
/// the bubble's fill is checked as drawn.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Who offers a send's Undo is decided from the chat view setting at the Send tap and the screen
///     the compose was opened on. A reply sent with the chat view on from a compose the chat opened
///     (the ready AI Suggestion, built as the chat builds it) has it on its bubble and no toast; a
///     reply sent with it off, and any new email, has the toast. Changing the setting right after
///     the tap changes nothing for that send. A later bubble send leaves an earlier send's toast
///     showing.
///  1b. A reply from a compose another screen opened keeps the toast with the chat view on: sent
///     again from the compose an Undo reopened (after an Undo in the chat or in Search), or opened
///     from Drafts and sent. No screen there shows its bubble.
///  1c. The chat records itself only for a compose of one of its own emails, seen as the user sees it:
///     in the real chat with RootView's toast presenter over it, an agent's reply or Forward card of
///     the chat's email shows its one Undo on the bubble; one for an email of another thread shows its
///     one Undo on the toast (the chat that opened it shows no bubble for it). A reply sent with the
///     chat view off at the tap shows only the toast's Undo, and once the user closes the toast only
///     the bubble's. The Empty Body alert's Send Anyway reads the setting at its own tap, not at the
///     Send that raised the alert. The setting read at Send is the chat view as it applies
///     (`ChatViewConfig.isActive`): the toggle on with no plan is off. Each Undo is checked on the
///     hold Send gave the email before the test moves that hold.
///  1d. The chat's own gestures, from the real chat: a tap on the AI Suggestion and the toolbar's
///     Forward (words typed, so Send sends as typed) show one Undo, the bubble's with the chat view
///     on at Send and the toast's with it off.
///  1e. A compose keeps the origin it opened with: built again with another while open (a chat
///     whose emails changed), its send's Undo goes where the first origin puts it.
///  2. Drawn: the solid blue rises from the bottom edge, inside the bubble's shape; in light mode the
///     text is the pending text colour over the tint and white over the solid; under Reduce Motion
///     there is no rising fill; a mounted bubble drops its Undo when its deadline passes.
@Suite("Undo send routing and drawing", .serialized, .processGlobalState)
@MainActor
struct ChatUndoSendRoutingTests {
    nonisolated private static let account = "acc-undo-routing"

    /// Every test starts with no Undo owner left by another (the suite's shared teardown point:
    /// Swift Testing makes a new suite value per test), so test order does not matter.
    init() {
        PendingSendService.shared.resetUndoOwnersForTesting()
    }

    // MARK: - 1. The real Send

    private struct Fixture {
        let pool: DatabasePool
        let account: Account
        /// The chat's email.
        let parent: MessageHeader
        /// An email of another thread, which an agent's card can name from the chat.
        let otherThread: MessageHeader

        /// The normalized Message-IDs of the chat's emails, as `ChatThreadView` reads them.
        var chatMessageIds: Set<String> {
            Set([parent.rfc822MessageId].compactMap { $0.map(EmailFilter.normalizeMessageId) })
        }
    }

    private static func makeFixture(_ pool: DatabasePool) async throws -> Fixture {
        let account = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "Sent", role: .sent, pool: pool)
        // Where an undone send returns (`AccountManager.admitDraftToDrafts`).
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "Drafts", role: .drafts, pool: pool)
        var parent = MessageHeader(
            messageId: "routing-parent", subject: "Lunch plans", from: "sender@example.com", fromAddress: "sender@example.com",
            to: account.emailAddress, date: Date().addingTimeInterval(-600), snippet: "Note",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        parent.rfc822MessageId = "routing-parent@example.com"
        parent.summaryTextMessage = Self.parentText
        parent.headerComplete = true
        parent.bodyComplete = true
        parent.isRead = true
        var otherThread = MessageHeader(
            messageId: "routing-other-thread", subject: "Budget", from: "finance@example.com", fromAddress: "finance@example.com",
            to: account.emailAddress, date: Date().addingTimeInterval(-900), snippet: "Numbers",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        otherThread.rfc822MessageId = "routing-other-thread@example.com"
        otherThread.headerComplete = true
        otherThread.bodyComplete = true
        otherThread.isRead = true
        let stored = [parent, otherThread]
        try await pool.write { db in for header in stored { try header.insert(db) } }
        return Fixture(pool: pool, account: account, parent: parent, otherThread: otherThread)
    }

    /// The chat's email as its bubble reads.
    nonisolated private static let parentText = "Lunch on Tuesday?"

    /// Polls (of 100 ms) between taps on a Send the compose ignored.
    private static let retapEvery = 20

    @MainActor private struct Hosted {
        let window: UIWindow
        let controller: UIViewController
        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Hosts `root` in a window as the app does, with the accounts in the navigation store.
    private static func host(_ root: some View, fixture: Fixture) throws -> Hosted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [fixture.account]
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: root.environment(navigationStore))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return Hosted(window: window, controller: controller)
    }

    /// Hosts the compose `root`, taps its Send (`tapSend`), and returns the outbox row the send queued.
    private static func send(
        _ root: some View, fixture: Fixture, beforeTap: () -> Void = {}, afterTap: () -> Void = {}
    ) async throws -> OutboxMessage {
        let hosted = try host(root, fixture: fixture)
        defer { hosted.close() }
        return try await tapSend(in: hosted.controller, fixture: fixture, beforeTap: beforeTap, afterTap: afterTap)
    }

    /// Taps Send in the compose `host` shows (its own view, or with `presented` the compose it
    /// presents) once Send is enabled, and returns the outbox row the send queued. `beforeTap` and
    /// `afterTap` run right around every tap that sends, so a test can change a setting at that
    /// moment: Send itself, or with `confirmsEmptyBody` the Empty Body alert's Send Anyway; then
    /// `beforeAlertTap` runs right before each Send tap that raises the alert. A compose
    /// still binding the draft it opened with ignores the tap and keeps its Send button, so Send is
    /// tapped again (inside the same `beforeTap` and `afterTap`) while no row has come and Send still
    /// shows enabled; an admitted send swaps Send for a spinner for good, so nothing is sent twice.
    private static func tapSend(
        in host: UIViewController, presented: Bool = false, fixture: Fixture, confirmsEmptyBody: Bool = false,
        beforeAlertTap: () -> Void = {}, beforeTap: () -> Void = {}, afterTap: () -> Void = {}
    ) async throws -> OutboxMessage {
        let before = try await fixture.pool.read { try OutboxMessage.fetchAll($0).map(\.id) }
        func composeView() -> UIView? { presented ? host.presentedViewController?.view : host.view }
        func sendEnabled() -> Bool {
            guard let view = composeView() else { return false }
            return HostedAccessibility.elements(under: view).contains {
                HostedAccessibility.identifier(of: $0) == ComposeView.sendButtonId
                    && !$0.accessibilityTraits.contains(.notEnabled)
            }
        }
        for _ in 0..<80 where !sendEnabled() { try await Task.sleep(for: .milliseconds(100)) }
        let compose = try #require(composeView(), "control: the compose is open")
        if confirmsEmptyBody {
            beforeAlertTap()
            #expect(HostedAccessibility.activate(ComposeView.sendButtonId, in: compose), "control: Send was tapped")
        } else {
            beforeTap()
            #expect(HostedAccessibility.activate(ComposeView.sendButtonId, in: compose), "control: Send was tapped")
            afterTap()
        }
        var queued: OutboxMessage?
        for poll in 1...100 where queued == nil {
            try await Task.sleep(for: .milliseconds(100))
            if confirmsEmptyBody, let alert = topPresented(host) as? UIAlertController, alert.title == "Empty Body" {
                try await press("Send Anyway", on: alert, beforeTap: beforeTap, afterTap: afterTap)
                continue
            }
            queued = try await fixture.pool.read { db in
                try OutboxMessage.order(Column("createdAt")).fetchAll(db).last { !before.contains($0.id) }
            }
            if queued == nil, poll.isMultiple(of: Self.retapEvery), sendEnabled(), let view = composeView() {
                if confirmsEmptyBody {
                    beforeAlertTap()
                    _ = HostedAccessibility.activate(ComposeView.sendButtonId, in: view)
                } else {
                    beforeTap()
                    _ = HostedAccessibility.activate(ComposeView.sendButtonId, in: view)
                    afterTap()
                }
            }
        }
        let row = try #require(queued, "the send queued its email")
        // The owner is recorded when the compose presents, right after the queue write.
        for _ in 0..<50 where PendingSendService.shared.undoOwner(for: row.id) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        return row
    }

    /// The controller on top of what `controller` presents, if it presents anything.
    private static func topPresented(_ controller: UIViewController) -> UIViewController? {
        var top = controller.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    /// Presses `title` on the alert as the user does: UIKit dismisses the alert, then runs that
    /// button's own handler, with `beforeTap` and `afterTap` right around it. An alert's action views
    /// do not answer `accessibilityActivate` in a hosted test, so this follows
    /// `ChatAISummariesNoticeHostedTests.pressOK`.
    private static func press(
        _ title: String, on alert: UIAlertController, beforeTap: () -> Void, afterTap: () -> Void
    ) async throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let action = try #require(alert.actions.first { $0.title == title }, "the alert has \(title)")
        try #require(action.responds(to: NSSelectorFromString("handler")), "UIAlertAction exposes its handler")
        let block = try #require(action.value(forKey: "handler") as AnyObject?, "\(title) has a handler")
        let handler = unsafeBitCast(block, to: Handler.self)
        alert.dismiss(animated: false)
        for _ in 0..<50 where alert.presentingViewController != nil { try await Task.sleep(for: .milliseconds(50)) }
        beforeTap()
        handler(action)
        afterTap()
    }

    /// The ready AI Suggestion's compose card, built as the chat builds it (`ChatThreadView`): a
    /// Reply All to the email's people, saving to the suggestion's own draft (`ChatReadyReply.draftId`).
    private static func readyAIReply(_ fixture: Fixture) -> some View {
        let ready = ChatReadyReply(
            message: fixture.parent,
            compose: ChatReplyCompose.make(replyAllTo: fixture.parent, accounts: [fixture.account]))
        return ready.compose.composeView(
            replyTo: ready.message, suggestedBody: "Tuesday works for me.", draftId: ready.draftId,
            openedOn: ChatThreadView.composeScreen(answering: ready.message, chatMessageIds: fixture.chatMessageIds),
            onAgentOutcome: { _ in })
    }

    private static func newEmail(_ fixture: Fixture) -> some View {
        ComposeView(
            suggestedBody: "Here is the plan.", account: fixture.account,
            prefillTo: ["someone@example.com"], prefillCc: nil, prefillBcc: nil, prefillSubject: "Plan",
            onAgentOutcome: { _ in })
    }

    private func withSendEnvironment(_ body: (Fixture, ChatSummaryQueueTests.SavedChatViewState) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        // A real Send summarizes its email through the shared AI service when the host has a session
        // and the consent (`SentEmailSummary.mayRun`). The consent is held off here, so no test send
        // can reach a real backend; the Undo owner never reads it (`ChatViewConfig.isActive`).
        let standard = UserDefaults.standard
        let consentBefore = standard.object(forKey: AgeAndTermsConsent.completedKey)
        standard.set(false, forKey: AgeAndTermsConsent.completedKey)
        // Restored however the fixture ends, a failed setup below included.
        defer {
            if let consentBefore { standard.set(consentBefore, forKey: AgeAndTermsConsent.completedKey) } else {
                standard.removeObject(forKey: AgeAndTermsConsent.completedKey)
            }
        }
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        while service.reopenSnapshot != nil { service.finishReopen() }
        try await HostedAccessibility.withAutomation { @MainActor in
            try await body(try await Self.makeFixture(pool), saved)
        }
    }

    @Test("The ready AI Reply sent with the chat view on has its Undo on the bubble, even if the chat view goes off right after the tap")
    func readyReplyWithChatViewOnUsesTheBubble() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            let row = try await Self.send(
                Self.readyAIReply(fixture), fixture: fixture,
                beforeTap: { saved.setChatView(on: true) }, afterTap: { saved.setChatView(on: false) })
            #expect(row.inReplyTo != nil, "control: a reply")
            let ownDraft = row.draftId?.hasPrefix(Draft.separateReplyPrefix) == true
            #expect(ownDraft, "control: sent from the AI Suggestion's own draft, as the chat opens it")
            #expect(PendingSendService.shared.undoOwner(for: row.id) == .bubble, "the setting at the tap decided")
            #expect(PendingSendService.shared.visibleToast?.id != row.id, "no toast for it")
        }
    }

    @Test("A reply sent with the chat view off has the toast, even if the chat view comes on right after the tap")
    func replyWithChatViewOffUsesTheToast() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)   // the card opens as the chat opens it; the setting is off at the tap
            let row = try await Self.send(
                Self.readyAIReply(fixture), fixture: fixture,
                beforeTap: { saved.setChatView(on: false) }, afterTap: { saved.setChatView(on: true) })
            #expect(PendingSendService.shared.undoOwner(for: row.id) == .toast, "the setting at the tap decided")
            #expect(PendingSendService.shared.visibleToast?.id == row.id, "RootView shows its toast")
        }
    }

    @Test("A new email has the toast with the chat view on, and a reply sent next on its bubble leaves that toast showing")
    func newEmailKeepsItsToastAcrossAReply() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let email = try await Self.send(Self.newEmail(fixture), fixture: fixture)
            #expect(email.inReplyTo == nil, "control: a new email")
            #expect(PendingSendService.shared.undoOwner(for: email.id) == .toast)
            #expect(PendingSendService.shared.visibleToast?.id == email.id, "RootView shows its toast")
            let reply = try await Self.send(Self.readyAIReply(fixture), fixture: fixture)
            #expect(PendingSendService.shared.undoOwner(for: reply.id) == .bubble)
            #expect(PendingSendService.shared.visibleToast?.id == email.id, "the email keeps its toast, its only Undo")
        }
    }

    @Test("A reply sent with the chat view toggle on but no plan has the toast: the setting at Send is the chat view as it applies")
    func replyWithToggleOnButNoPlanUsesTheToast() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let row = try await Self.send(Self.readyAIReply(fixture), fixture: fixture, beforeTap: {
                // The card opened with the chat view on; the plan ends before Send.
                AISubscriptionGate.shared.closeGate()
                #expect(ChatViewConfig.isEnabledByUser && !ChatViewConfig.isActive, "control: the toggle on, the chat view off")
            })
            #expect(row.inReplyTo != nil, "control: a reply")
            #expect(PendingSendService.shared.undoOwner(for: row.id) == .toast, "the chat view as it applies at Send decided")
            #expect(PendingSendService.shared.visibleToast?.id == row.id, "RootView shows its toast, its one Undo")
        }
    }

    // MARK: - 1c. The chat records itself only for its own emails, as the user sees it

    /// The Undos drawn on screen: the chat bubble's and the toast's.
    private struct Undos: Equatable, CustomStringConvertible {
        let bubble: Int
        let toast: Int
        var description: String { "bubble \(bubble), toast \(toast)" }
    }

    /// The chat of `fixture.parent` as the app shows it, with RootView's toast presenter
    /// (`PendingSendToastPresenter`, its mounting fenced in `ChatUndoSendTests.rootViewWiring`) over it.
    @MainActor private struct MountedChat {
        let hosted: Hosted
        var controller: UIViewController { hosted.controller }

        func undos() -> Undos {
            let view: UIView = controller.view
            return Undos(
                bubble: HostedAccessibility.identifiers(in: view).filter { $0 == ChatUndoSendStatus.undoId }.count,
                toast: HostedAccessibility.labels(in: view).filter { $0 == "Undo" }.count)
        }

        /// Once the compose has gone and an Undo shows, the Undos drawn are `expected`, and stay so
        /// for a second, well inside the send's window.
        func expectUndos(_ expected: Undos, _ note: String) async throws {
            for _ in 0..<50 where controller.presentedViewController != nil || undos() == Undos(bubble: 0, toast: 0) {
                try await Task.sleep(for: .milliseconds(100))
            }
            for _ in 0..<5 {
                let seen = undos()
                #expect(seen == expected, "\(note): \(seen)")
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        /// On the hold Send gave `row`, before the test moves it: the row is held for its Undo
        /// window plus the claim buffer from when it was queued, and the Undos drawn are `expected`
        /// before that hold's Undo deadline.
        func expectUndosOnItsOwnHold(_ row: OutboxMessage, _ expected: Undos, _ note: String) async throws {
            try ChatUndoSendRoutingTests.expectQueuedHold(row, note)
            let deadline = OutboxCancellationPolicy.undoDeadline(for: row.holdUntil)
            while Date() < deadline, undos() != expected { try await Task.sleep(for: .milliseconds(50)) }
            let seen = undos()
            let inTime = Date() < deadline
            #expect(seen == expected && inTime, "\(note), on the send's own hold: \(seen)")
        }
    }

    /// `row` has the hold Send gives a send for its Undo: `SyncConfig.outboxUndoHoldSeconds` plus the
    /// claim buffer from when it was queued.
    private static func expectQueuedHold(_ row: OutboxMessage, _ note: String) throws {
        let hold = try #require(row.holdUntil, "\(note): Send held the email for its Undo")
        let held = hold.timeIntervalSince(row.createdAt)
        let queuedHold = SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        #expect(abs(held - queuedHold) < 1, "\(note): the hold Send gave it (\(held) s)")
    }

    /// Mounts the chat, waits until it shows its email, and runs `body`; then closes it and waits for
    /// the compose it opened to report itself gone. The shared AI queue and compose queue are given
    /// back on every exit: a failed mount and a cancelled wait included.
    private static func withMountedChat(_ fixture: Fixture, _ body: @MainActor (MountedChat) async throws -> Void) async throws {
        let queue = ActiveAIQueue.shared
        let router = AgentToolRouter.shared
        await queue.setDispatchSuppressedForTesting(true)
        /// Never throws, so nothing skips the queue's restore: a cancelled wait for the compose ends
        /// the wait, not the restore.
        func restore(_ hosted: Hosted?) async {
            hosted?.close()
            for _ in 0..<50 where router.composePresentationCount > 0 {
                guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { break }
            }
            router.resetComposeQueueForTesting()
            router.pendingCompose = nil
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
        }
        var hosted: Hosted?
        do {
            await queue.clearForTesting()
            router.resetComposeQueueForTesting()
            router.pendingCompose = nil
            let mounted = try Self.host(
                NavigationStack { ChatThreadView(messageId: fixture.parent.id) }.modifier(PendingSendToastPresenter()),
                fixture: fixture)
            hosted = mounted
            let chat = MountedChat(hosted: mounted)
            func showsItsEmail() -> Bool { HostedAccessibility.labels(in: chat.controller.view).contains { $0.contains(Self.parentText) } }
            for _ in 0..<80 where !showsItsEmail() { try await Task.sleep(for: .milliseconds(100)) }
            #expect(showsItsEmail(), "control: the chat shows its email")
            try await body(chat)
        } catch {
            await restore(hosted)
            throw error
        }
        await restore(hosted)
    }

    /// The agent opens a card from the chat, as its reply and forward tools do.
    private static func openAgentCard(_ mode: AgentToolRouter.ComposeRequest.Mode, for email: MessageHeader, body: String?) {
        AgentToolRouter.shared.enqueueCompose(AgentToolRouter.ComposeRequest(
            mode: mode, replyTo: email, to: ["someone@example.com"], cc: [], bcc: [], subject: nil, body: body))
    }

    /// The test, not the clock, ends the bubble's window (its row's durable deadline).
    private static func holdOpen(_ row: OutboxMessage, _ fixture: Fixture) async throws {
        let hold = Date().addingTimeInterval(3600)
        let id = row.id
        try await fixture.pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET holdUntil = ? WHERE id = ?", arguments: [hold, id])
        }
    }

    enum AgentCard: CaseIterable, CustomTestStringConvertible {
        case replyToTheChatsEmail, forwardOfTheChatsEmail, replyToAnotherThreadsEmail, forwardOfAnotherThreadsEmail

        var isForward: Bool { self == .forwardOfTheChatsEmail || self == .forwardOfAnotherThreadsEmail }
        var answersTheChat: Bool { self == .replyToTheChatsEmail || self == .forwardOfTheChatsEmail }
        var testDescription: String { "\(self)" }
    }

    @Test("A card the agent opens from the chat, sent with the chat view on: for the chat's email its one Undo on screen is the bubble's, for another thread's email the toast's", arguments: AgentCard.allCases)
    func agentCardShowsOneUndo(_ card: AgentCard) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the chat's compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            try await Self.withMountedChat(fixture) { chat in
                let target = card.answersTheChat ? fixture.parent : fixture.otherThread
                Self.openAgentCard(card.isForward ? .forward : .reply, for: target, body: "Passing this on.")
                let row = try await Self.tapSend(in: chat.controller, presented: true, fixture: fixture)
                #expect(row.isForward == card.isForward, "control: the card the agent asked for")
                let answered = row.inReplyTo.map(EmailFilter.normalizeMessageId)
                #expect(answered == target.rfc822MessageId.map(EmailFilter.normalizeMessageId), "control: it answers the email the agent named")
                if card.answersTheChat {
                    try await chat.expectUndosOnItsOwnHold(row, Undos(bubble: 1, toast: 0), "its bubble's Undo")
                    try await Self.holdOpen(row, fixture)
                    try await chat.expectUndos(Undos(bubble: 1, toast: 0), "its one Undo is on its bubble in the chat")
                } else {
                    try await chat.expectUndosOnItsOwnHold(row, Undos(bubble: 0, toast: 1), "the toast's Undo")
                    try await chat.expectUndos(Undos(bubble: 0, toast: 1), "its one Undo is the toast's: the chat shows no bubble for it")
                }
            }
        }
    }

    @Test("A reply to the chat's email sent with the chat view off at the tap shows only the toast's Undo; once the user closes the toast, only its bubble's")
    func toastThenBubbleShowOneUndo() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the chat's compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            try await Self.withMountedChat(fixture) { chat in
                Self.openAgentCard(.reply, for: fixture.parent, body: "Tuesday works for me.")
                let row = try await Self.tapSend(
                    in: chat.controller, presented: true, fixture: fixture,
                    beforeTap: { saved.setChatView(on: false) }, afterTap: { saved.setChatView(on: true) })
                #expect(PendingSendService.shared.undoOwner(for: row.id) == .toast, "control: the setting at the tap gave the toast")
                try await chat.expectUndosOnItsOwnHold(row, Undos(bubble: 0, toast: 1), "sent: the toast's Undo")
                try await Self.holdOpen(row, fixture)
                try await chat.expectUndos(Undos(bubble: 0, toast: 1), "sent: only the toast's Undo")
                // The user taps the toast's close (×) on screen, through RootView's presenter.
                #expect(HostedAccessibility.activate(PendingSendToast.closeId, in: chat.controller.view),
                        "the user closes the toast")
                #expect(PendingSendService.shared.undoOwner(for: row.id) == .bubble, "the close handed its Undo to the bubble")
                try await chat.expectUndos(Undos(bubble: 1, toast: 0), "the toast closed: only the bubble's Undo")
            }
        }
    }

    @Test("A reply to the chat's email sent with the Empty Body alert's Send Anyway has its Undo where the chat view setting at Send Anyway puts it, whatever it was at the Send that raised the alert or right after",
          arguments: [true, false])
    func sendAnywayReadsTheSettingAtItsTap(onAtSendAnyway: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the chat's compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            try await Self.withMountedChat(fixture) { chat in
                Self.openAgentCard(.reply, for: fixture.parent, body: nil)
                let row = try await Self.tapSend(
                    in: chat.controller, presented: true, fixture: fixture, confirmsEmptyBody: true,
                    beforeAlertTap: { saved.setChatView(on: !onAtSendAnyway) },
                    beforeTap: { saved.setChatView(on: onAtSendAnyway) }, afterTap: { saved.setChatView(on: !onAtSendAnyway) })
                #expect(row.inReplyTo != nil, "control: a reply")
                let owner = PendingSendService.shared.undoOwner(for: row.id)
                #expect(owner == (onAtSendAnyway ? .bubble : .toast), "the setting at Send Anyway decided")
                saved.setChatView(on: true)
                let expected = onAtSendAnyway ? Undos(bubble: 1, toast: 0) : Undos(bubble: 0, toast: 1)
                try await chat.expectUndosOnItsOwnHold(row, expected, "its one Undo")
                try await Self.holdOpen(row, fixture)
                try await chat.expectUndos(expected, "its one Undo, through its window")
            }
        }
    }

    // MARK: - 1d. The chat's own gestures, from the real chat

    enum ChatGesture: CaseIterable, CustomTestStringConvertible {
        /// A tap on the AI Suggestion: its Reply All card, sent with the suggestion (Send adopts it).
        case aiSuggestion
        /// The toolbar's Forward of the chat's email, a recipient and the user's words typed (Send
        /// sends what was typed).
        case toolbarForward

        var testDescription: String { "\(self)" }
    }

    /// The first `type` view under `view` that `matches`, depth first.
    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView, where matches: (T) -> Bool = { _ in true }) -> T? {
        if let found = view as? T, matches(found) { return found }
        for subview in view.subviews {
            if let found = firstView(type, in: subview, where: matches) { return found }
        }
        return nil
    }

    @Test("From the real chat, the AI Suggestion's card and the toolbar Forward of its email have one Undo: the bubble's with the chat view on at Send, the toast's with it off, whatever it is right after",
          arguments: ChatGesture.allCases, [true, false])
    func chatGestureShowsOneUndo(_ gesture: ChatGesture, onAtSend: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the chat and its compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            if gesture == .aiSuggestion {
                // The email's AI reply is ready, so the chat shows the AI Suggestion under it.
                let id = fixture.parent.id
                try await fixture.pool.write { db in
                    try db.execute(sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                                   arguments: ["Tuesday works for me.", "Tuesday works for me.", id])
                }
            }
            try await Self.withMountedChat(fixture) { chat in
                let view: UIView = chat.controller.view
                switch gesture {
                case .aiSuggestion:
                    func showsSuggestion() -> Bool { HostedAccessibility.identifiers(in: view).contains(ChatSuggestionBubble.bubbleId) }
                    for _ in 0..<50 where !showsSuggestion() { try await Task.sleep(for: .milliseconds(100)) }
                    #expect(HostedAccessibility.activate(ChatSuggestionBubble.bubbleId, in: view), "the user taps the AI Suggestion")
                case .toolbarForward:
                    #expect(HostedAccessibility.activate(ChatThreadView.forwardId, in: view), "the user taps Forward")
                }
                for _ in 0..<50 where chat.controller.presentedViewController == nil { try await Task.sleep(for: .milliseconds(100)) }
                let compose = try #require(chat.controller.presentedViewController?.view, "the chat opened its compose")
                if gesture == .toolbarForward {
                    // A recipient, committed by its separator, and the user's own words.
                    func toField() -> UITextField? {
                        Self.firstView(UITextField.self, in: compose) { HostedAccessibility.identifier(of: $0) == "recipientInput-to" }
                            ?? Self.firstView(UITextField.self, in: compose)
                    }
                    for _ in 0..<50 where toField() == nil { try await Task.sleep(for: .milliseconds(100)) }
                    let field = toField()
                    let to = try #require(field, "the forward has its To field")
                    to.insertText("someone@example.com, ")
                    let editor = Self.firstView(UITextView.self, in: compose) { $0.isEditable }
                    let body = try #require(editor, "the forward has its body")
                    body.insertText("Passing this on.")
                }
                let row = try await Self.tapSend(
                    in: chat.controller, presented: true, fixture: fixture,
                    beforeTap: { saved.setChatView(on: onAtSend) }, afterTap: { saved.setChatView(on: !onAtSend) })
                #expect(row.isForward == (gesture == .toolbarForward), "control: the compose the gesture opened")
                let answered = row.inReplyTo.map(EmailFilter.normalizeMessageId)
                #expect(answered == fixture.parent.rfc822MessageId.map(EmailFilter.normalizeMessageId), "control: about the chat's email")
                let owner = PendingSendService.shared.undoOwner(for: row.id)
                #expect(owner == (onAtSend ? .bubble : .toast), "the setting at Send and the chat's own compose decided")
                saved.setChatView(on: true)
                let expected = onAtSend ? Undos(bubble: 1, toast: 0) : Undos(bubble: 0, toast: 1)
                try await chat.expectUndosOnItsOwnHold(row, expected, "its one Undo")
                try await Self.holdOpen(row, fixture)
                try await chat.expectUndos(expected, "its one Undo, through its window")
            }
        }
    }

    // MARK: - 1e. The origin is the one the compose opened with

    /// A screen's origin for the compose it shows, which can change while the compose is open (a
    /// chat whose emails changed: a merge brings in, or takes out, the email the compose answers).
    @MainActor @Observable private final class LiveOrigin {
        var screen: ComposeScreen?
        /// Each origin the compose was built with, in order. Not observed: recording one never
        /// builds the compose again.
        @ObservationIgnored var built: [ComposeScreen?] = []

        init(_ screen: ComposeScreen?) { self.screen = screen }
    }

    /// The AI Suggestion's compose under a screen that builds it again, with `origin` as it is now,
    /// whenever the origin changes (as `ChatThreadView` builds its cover's compose again on a change).
    private struct RebuiltReadyReply: View {
        let ready: ChatReadyReply
        let origin: LiveOrigin

        var body: some View {
            let screen = origin.screen
            let _ = origin.built.append(screen)
            ready.compose.composeView(
                replyTo: ready.message, suggestedBody: "Tuesday works for me.", draftId: ready.draftId,
                openedOn: screen, onAgentOutcome: { _ in })
        }
    }

    @Test("A compose keeps the origin it opened with: built again with another while open, its send's Undo goes where the first one puts it",
          arguments: [true, false])
    func composeKeepsItsOpeningOrigin(openedOnTheChat: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let first: ComposeScreen? = openedOnTheChat ? .chat : nil
            let later: ComposeScreen? = openedOnTheChat ? nil : .chat
            let origin = LiveOrigin(first)
            let ready = ChatReadyReply(
                message: fixture.parent,
                compose: ChatReplyCompose.make(replyAllTo: fixture.parent, accounts: [fixture.account]))
            let hosted = try Self.host(RebuiltReadyReply(ready: ready, origin: origin), fixture: fixture)
            defer { hosted.close() }
            for _ in 0..<50 where origin.built.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            origin.screen = later
            func rebuilt() -> Bool { origin.built.count > 1 && origin.built.last == .some(later) }
            for _ in 0..<50 where !rebuilt() { try await Task.sleep(for: .milliseconds(100)) }
            #expect(rebuilt(), "control: the open compose was built again with the other origin")
            let row = try await Self.tapSend(in: hosted.controller, fixture: fixture)
            #expect(row.inReplyTo != nil, "control: a reply to the chat's email")
            let owner = PendingSendService.shared.undoOwner(for: row.id)
            #expect(owner == (openedOnTheChat ? .bubble : .toast), "the origin it opened with decided")
        }
    }

    // MARK: - 1b. A compose another screen opened

    /// Sends the AI Suggestion from the chat, then taps Undo on its Sending bubble as the chat does
    /// (`ChatUnsentReply.undo()` on the row the chat reads). Returns the compose the Undo queued to
    /// reopen, which RootView presents at the top level after an Undo in the chat or in Search alike.
    private static func sendFromTheChatAndUndoOnTheBubble(_ fixture: Fixture) async throws -> PendingSendService.ReopenSnapshot {
        let service = PendingSendService.shared
        let first = try await Self.send(Self.readyAIReply(fixture), fixture: fixture)
        #expect(service.undoOwner(for: first.id) == .bubble, "control: sent from the chat, Undo on its bubble")
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        // On the hold Send gave it, before the test moves it: its bubble offers the Undo.
        try Self.expectQueuedHold(first, "the reply")
        let queued = try await fixture.pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let onItsHold = queued.first { $0.id == first.id }?.bubbleUndoSecondsLeft(at: Date(), owner: service.undoOwner(for: first.id))
        #expect(onItsHold != nil, "its bubble offers Undo on the send's own hold")
        // The test, not the clock, ends the window.
        try await Self.holdOpen(first, fixture)
        let bubbles = try await fixture.pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let shown = bubbles.first { $0.id == first.id }
        let bubble = try #require(shown, "control: the chat shows the reply's bubble")
        bubble.undo()
        let reopen = try #require(service.reopenSnapshot, "the bubble's Undo reopens the compose")
        let cancelled = try await fixture.pool.read { try OutboxMessage.fetchOne($0, key: first.id) } == nil
        #expect(cancelled, "control: the first send is cancelled")
        return reopen
    }

    @Test("A reply undone on its bubble and sent again from the compose the Undo reopened has the toast: that compose is not the chat's")
    func reopenedComposeSendsWithTheToast() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let reopen = try await Self.sendFromTheChatAndUndoOnTheBubble(fixture)
            let again = try await Self.send(UndoReopenCompose(snapshot: reopen), fixture: fixture)
            #expect(again.inReplyTo != nil, "control: still a reply to the chat's email")
            #expect(PendingSendService.shared.undoOwner(for: again.id) == .toast, "its Undo is on the toast")
            #expect(PendingSendService.shared.visibleToast?.id == again.id, "RootView shows its toast, its one Undo")
        }
    }

    @Test("A reply undone on its bubble, then opened from Drafts and sent, has the toast")
    func draftsSendKeepsTheToast() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let reopen = try await Self.sendFromTheChatAndUndoOnTheBubble(fixture)
            #expect(reopen.returnedToDrafts, "control: the Undo put the reply back in Drafts")
            // The reopened compose is closed without typing; the reply waits in Drafts.
            PendingSendService.shared.finishReopen()
            let again = try await Self.send(
                DraftComposePresenter(source: .draftId(reopen.authority.draftId)), fixture: fixture)
            #expect(again.inReplyTo != nil, "control: still a reply to the chat's email")
            #expect(PendingSendService.shared.undoOwner(for: again.id) == .toast, "its Undo is on the toast")
            #expect(PendingSendService.shared.visibleToast?.id == again.id, "RootView shows its toast, its one Undo")
        }
    }

    // MARK: - 2. Drawn

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func rgba(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255, Double(bytes[i + 3]) / 255)
        }

        /// Whether the pixel is `color`, resolved for the mode.
        func shows(_ color: Color, at x: Int, _ y: Int, dark: Bool) -> Bool {
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            let p = rgba(x, y)
            let tolerance = 0.06
            return abs(p.r - r) < tolerance && abs(p.g - g) < tolerance && abs(p.b - b) < tolerance && p.a > 0.9
        }
    }

    private static let side = 100
    private static let textColumn = 50
    private static let backgroundColumn = 10

    /// Renders `view` at `side` x `side` points, one pixel per point.
    private static func render(_ view: some View, dark: Bool) throws -> Bitmap {
        let renderer = ImageRenderer(content: view
            .frame(width: CGFloat(side), height: CGFloat(side))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "rendered")
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let context = try #require(CGContext(
            data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Bitmap(width: side, height: side, bytes: bytes)
    }

    /// A bubble whose "text" is a solid column in the text colour, background either side of it.
    private static func content(_ textColor: Color) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 40)
            textColor.frame(width: 20)
            Color.clear.frame(width: 40)
        }
        .frame(width: CGFloat(side), height: CGFloat(side))
    }

    @Test("The solid blue rises from the bottom edge inside the bubble's shape, and light-mode text switches colour at the fill edge", arguments: [false, true])
    func fillIsDrawnFromTheBottom(dark: Bool) throws {
        let bitmap = try Self.render(ChatUndoSendFill(look: .pending(fill: 0.25)) { Self.content($0) }, dark: dark)
        let low = 90, high = 40   // inside the risen quarter, and above it
        #expect(bitmap.shows(Theme.accent, at: Self.backgroundColumn, low, dark: dark), "the bottom quarter is solid blue")
        #expect(bitmap.shows(Palette.chatUndoSendPendingTint, at: Self.backgroundColumn, high, dark: dark), "above it, the pending tint")
        #expect(bitmap.shows(Color.white, at: Self.textColumn, low, dark: dark), "text over the solid is white")
        #expect(bitmap.shows(Palette.chatUndoSendPendingText, at: Self.textColumn, high, dark: dark),
                "text over the tint is the pending text colour (navy in light mode, white in dark)")
        #expect(bitmap.rgba(0, 0).a < 0.1 && bitmap.rgba(0, Self.side - 1).a < 0.1,
                "the corners are outside the bubble's shape, the fill's included")
    }

    @Test("Under Reduce Motion the bubble does not fill; with motion it has risen by the part of the window passed")
    func reduceMotionDrawsNoFill() throws {
        // 4 of the 5 s of the window have passed: a moving fill is 80% up.
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 1)
        let reply = ChatUnsentReply(outboxId: "o-drawn", status: .queued, sentAt: nil, holdUntil: hold,
                                    draftId: "d", instanceEpoch: "E1", filed: false, textMessage: nil)
        func drawn(reduceMotion: Bool) throws -> Bitmap {
            try Self.render(ChatUndoSendTimelineBody(reply: reply, reduceMotion: reduceMotion) { look, _ in
                ChatUndoSendFill(look: look) { Self.content($0) }
            }, dark: false)
        }
        let middle = 50
        #expect(try drawn(reduceMotion: false).shows(Theme.accent, at: Self.backgroundColumn, middle, dark: false),
                "control: with motion the middle is already solid")
        #expect(try drawn(reduceMotion: true).shows(Palette.chatUndoSendPendingTint, at: Self.backgroundColumn, middle, dark: false),
                "Reduce Motion: still the pending tint")
    }

    @Test("A mounted bubble offers Undo until its deadline passes, then shows Sending with no Undo")
    func mountedBubbleCrossesItsDeadline() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted bubble")
        try await HostedAccessibility.withAutomation { @MainActor in
            let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 1.5)
            let reply = ChatUnsentReply(outboxId: "o-mounted", status: .queued, sentAt: nil, holdUntil: hold,
                                        draftId: "d", instanceEpoch: "E1", filed: false, textMessage: "I said Tuesday works.")
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 300)
            let controller = UIHostingController(rootView: ChatUnsentReplyBubble(reply: reply, retry: {}, delete: {}, undo: {}))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let hasUndo: @MainActor () -> Bool = { HostedAccessibility.identifiers(in: controller.view).contains(ChatUndoSendStatus.undoId) }
            for _ in 0..<20 where !hasUndo() { try await Task.sleep(for: .milliseconds(50)) }
            #expect(hasUndo(), "Undo while the window lasts")
            for _ in 0..<60 where hasUndo() { try await Task.sleep(for: .milliseconds(100)) }
            #expect(!hasUndo(), "no Undo once the deadline passed")
            #expect(HostedAccessibility.labels(in: controller.view).contains { $0.contains("Sending") }, "the bubble still reads Sending")
        }
    }
}
