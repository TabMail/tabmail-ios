/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Undo send on the chat's "Sending" bubble (replaces the toast for a reply in the chat view).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Undo shows iff the instant is before the row's `OutboxCancellationPolicy.undoDeadline` and the
///     shared policy answers Cancel Send; never after, never for a sending, failed or sent row, and
///     its seconds count down to that deadline and stop there (no time is added).
///  2. Each bubble counts down from its own row's deadline.
///  3. Leaving the chat and opening it again shows Undo again while time is left, and not after.
///  4. Tapping the bubble's Undo runs the toast's own undo-and-reopen path: the outbox row is gone,
///     the reopen names the send's own draft generation, and another send's toast stays.
///  5. A reply sent with the chat view on has no toast; any other send keeps it.
@Suite("Undo send on the chat bubble", .serialized, .processGlobalState)
@MainActor
struct ChatUndoSendTests {
    nonisolated private static let account = "acc-undo-bubble"

    private static func reply(
        status: OutboxStatus = .queued, sentAt: Date? = nil, holdUntil: Date?,
        draftId: String? = "d", id: String = "o"
    ) -> ChatUnsentReply {
        ChatUnsentReply(outboxId: id, status: status, sentAt: sentAt, holdUntil: holdUntil,
                        draftId: draftId, instanceEpoch: "E1", filed: false, textMessage: nil)
    }

    // MARK: - 1. Visible iff now < undoDeadline

    @Test("Undo shows only before the row's own undo deadline, counting whole seconds down to it")
    func visibleIffBeforeDeadline() {
        let now = Date()
        let hold = now.addingTimeInterval(4.5)
        let deadline = OutboxCancellationPolicy.undoDeadline(for: hold)
        let row = Self.reply(holdUntil: hold)
        #expect(row.undoDeadline == deadline, "the deadline is the shared policy's, from the row")
        #expect(row.undoSecondsLeft(at: deadline.addingTimeInterval(-3.5)) == 4)
        #expect(row.undoSecondsLeft(at: deadline.addingTimeInterval(-1)) == 1)
        #expect(row.undoSecondsLeft(at: deadline.addingTimeInterval(-0.01)) == 1)
        #expect(row.undoSecondsLeft(at: deadline) == nil, "not at the deadline")
        #expect(row.undoSecondsLeft(at: deadline.addingTimeInterval(1)) == nil, "not after it")
        // Every instant agrees with the policy the Outbox's Cancel Send uses.
        for offset in stride(from: -6.0, through: 2.0, by: 0.25) {
            let instant = deadline.addingTimeInterval(offset)
            let policy = OutboxCancellationPolicy.action(status: .queued, sentAt: nil, holdUntil: hold, at: instant)
            #expect((row.undoSecondsLeft(at: instant) != nil) == (policy == .cancelSend), "at \(offset)")
        }
    }

    @Test("No Undo for a row that is sending, failed, sent, has no hold, or names no draft")
    func noUndoOutsideTheWindow() {
        let hold = Date().addingTimeInterval(3600)
        let now = Date()
        #expect(Self.reply(holdUntil: hold).undoSecondsLeft(at: now) != nil, "control: queued, in the window")
        #expect(Self.reply(status: .sending, holdUntil: hold).undoSecondsLeft(at: now) == nil)
        #expect(Self.reply(status: .failed, holdUntil: hold).undoSecondsLeft(at: now) == nil)
        #expect(Self.reply(sentAt: now, holdUntil: hold).undoSecondsLeft(at: now) == nil)
        #expect(Self.reply(holdUntil: nil).undoSecondsLeft(at: now) == nil)
        #expect(Self.reply(holdUntil: hold, draftId: nil).undoSecondsLeft(at: now) == nil)
    }

    @Test("The countdown's ticks fall on each whole second before the deadline and end at it")
    func ticksEndAtTheDeadline() {
        let start = Date()
        let deadline = start.addingTimeInterval(2.5)
        let ticks = ChatUndoSendSchedule.ticks(from: start, deadline: deadline)
        #expect(ticks == [start, deadline.addingTimeInterval(-2), deadline.addingTimeInterval(-1), deadline])
        #expect(ChatUndoSendSchedule.ticks(from: deadline.addingTimeInterval(1), deadline: deadline).count == 1,
                "nothing scheduled after the deadline")
    }

    // MARK: - 2. Per message

    @Test("Each bubble counts down from its own row's deadline, read from the database")
    func perMessageDeadline() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let a = try await Self.queueReply(fixture, draftId: "draft-a")
        let b = try await Self.queueReply(fixture, draftId: "draft-b")
        let now = Date()
        try await Self.setHold(pool, a.id, now.addingTimeInterval(10))
        try await Self.setHold(pool, b.id, now.addingTimeInterval(30))
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        let rows = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let ra = try #require(byId[a.id]), rb = try #require(byId[b.id])
        #expect(ra.undoSecondsLeft(at: now) == 9 && rb.undoSecondsLeft(at: now) == 29,
                "each from its own hold less the claim buffer")
        let afterA = now.addingTimeInterval(15)
        #expect(ra.undoSecondsLeft(at: afterA) == nil && rb.undoSecondsLeft(at: afterA) == 14,
                "one bubble's window ending does not end the other's")
    }

    // MARK: - 3, 4. Hosted chat: leave and return; tap Undo

    @Test("Leaving the chat and opening it again shows Undo while time is left, and not after the deadline")
    func reappearsAfterReturning() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await reappearsBody() }
    }

    private func reappearsBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-return")
        try await Self.setHold(pool, row.id, Date().addingTimeInterval(3600))

        var chat = try Self.host(fixture)
        try await Self.waitFor { chat.hasUndo() }
        #expect(chat.hasUndo(), "the bubble offers Undo in its window")
        chat.close()

        chat = try Self.host(fixture)
        try await Self.waitFor { chat.hasUndo() }
        #expect(chat.hasUndo(), "opened again, Undo is back with the time left")
        chat.close()

        // The window has passed while the chat was closed.
        try await Self.setHold(pool, row.id, Date().addingTimeInterval(-1))
        chat = try Self.host(fixture)
        try await Self.waitFor { chat.count("Sending") == 1 }
        #expect(chat.count("Sending") == 1 && !chat.hasUndo(), "past the deadline: Sending, no Undo")
        chat.close()
    }

    @Test("Tapping the bubble's Undo cancels that send through the toast's undo-and-reopen path")
    func tapUsesTheSharedPath() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await tapBody() }
    }

    private func tapBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.reopenSnapshot = nil
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)
        let other = try await Self.queueReply(fixture, draftId: "draft-toast", inReplyTo: "another-chat@example.com")
        let row = try await Self.queueReply(fixture, draftId: "draft-tap")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, row.id, hold)
        try await Self.setHold(pool, other.id, hold)
        // Another send's toast is up.
        service.present(outboxId: other.id, draftId: "draft-toast", instanceEpoch: "E1",
                        toSummary: "To: someone@example.com", holdUntil: hold, showsToast: true)
        service.reopenSnapshot = nil

        let chat = try Self.host(fixture)
        defer { chat.close() }
        try await Self.waitFor { chat.hasUndo() }
        #expect(HostedAccessibility.activate(ChatUndoSendStatus.undoId, in: chat.controller.view), "the bubble offers Undo")

        let left = try await pool.read { try OutboxMessage.fetchAll($0).map(\.id) }
        #expect(!left.contains(row.id), "the send is cancelled: its outbox row is gone")
        #expect(left.contains(other.id), "control: the other send is untouched")
        let reopen = try #require(service.reopenSnapshot, "the compose reopens, as from the toast")
        #expect(reopen.id == row.id && reopen.authority.draftId == "draft-tap" && reopen.authority.instanceEpoch == "E1",
                "the reopen names this send's own draft generation")
        #expect(service.current?.id == other.id, "the other send's toast stays")
        try await Self.waitFor { chat.count("Sending") == 0 }
        #expect(chat.count("Sending") == 0 && !chat.hasUndo(), "the bubble is gone")
    }

    // MARK: - 5. Toast or bubble

    @Test("A reply sent with the chat view on has its Undo on the bubble; any other send keeps the toast")
    func toastOrBubble() {
        #expect(PendingSendService.sendHasBubbleUndo(chatViewActive: true, inReplyTo: "<p@example.com>"))
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: false, inReplyTo: "<p@example.com>"))
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: true, inReplyTo: nil))
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: false, inReplyTo: nil))
    }

    @Test("Every send has exactly one visible Undo, a reply and a new email, with the chat view on or off")
    func exactlyOneUndoPerSend() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let reply = try await Self.queueReply(fixture, draftId: "draft-one-reply")
        let newEmail = try await Self.queueReply(fixture, draftId: "draft-one-new", newEmail: true)
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, reply.id, hold)
        try await Self.setHold(pool, newEmail.id, hold)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let now = Date()
        for chatViewActive in [true, false] {
            for row in [reply, newEmail] {
                let toast = !PendingSendService.sendHasBubbleUndo(chatViewActive: chatViewActive, inReplyTo: row.inReplyTo)
                let bubble = chatViewActive
                    && bubbles.contains { $0.id == row.id && $0.undoSecondsLeft(at: now) != nil }
                #expect((toast ? 1 : 0) + (bubble ? 1 : 0) == 1,
                        "chat view \(chatViewActive), \(row.id == reply.id ? "reply" : "new email"): toast \(toast), bubble \(bubble)")
            }
        }
    }

    @Test("RootView shows the toast only for a send whose Undo is not on a bubble, and both Undos share one reopen")
    func rootViewWiring() throws {
        let text = try Self.source("TabMail/Views/RootView.swift")
        #expect(text.contains("if let pending = pendingSendService.current, pending.showsToast {"))
        #expect(text.contains("onUndo: { pendingSendService.undoAndReopen() }"))
        #expect(text.contains("Binding(get: { pendingSendService.reopenSnapshot },") && text.contains(".fullScreenCover(item: reopenSnapshot) {"))
        let compose = try Self.source("TabMail/Views/Compose/ComposeView.swift")
        #expect(compose.contains("showsToast: !snapshot.sendHasBubbleUndo"))
    }

    // MARK: - Fixture

    private struct Fixture {
        let pool: DatabasePool
        let parent: MessageHeader
    }

    @MainActor private struct HostedChat {
        let window: UIWindow
        let controller: UIViewController
        func labels() -> [String] { HostedAccessibility.labels(in: controller.view) }
        func count(_ words: String) -> Int { labels().filter { $0.contains(words) }.count }
        func hasUndo() -> Bool { HostedAccessibility.identifiers(in: controller.view).contains(ChatUndoSendStatus.undoId) }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private static func host(_ fixture: Fixture) throws -> HostedChat {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return HostedChat(window: window, controller: controller)
    }

    private static func waitFor(_ done: () -> Bool) async throws {
        for _ in 0..<80 where !done() { try await Task.sleep(for: .milliseconds(100)) }
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func makeFixture(_ pool: DatabasePool) async throws -> Fixture {
        _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "Sent", role: .sent, pool: pool)
        var parent = MessageHeader(
            messageId: "undo-parent", subject: "Lunch plans", from: "sender@example.com", fromAddress: "sender@example.com",
            to: "someone@example.com", date: Date().addingTimeInterval(-600), snippet: "Note",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        parent.rfc822MessageId = "undo-parent@example.com"
        parent.headerComplete = true
        parent.bodyComplete = true
        parent.isRead = true
        let stored = parent
        try await pool.write { db in try stored.insert(db) }
        return Fixture(pool: pool, parent: parent)
    }

    /// Queues a reply as the compose card does, with an undo hold, and returns its outbox row.
    private static func queueReply(_ fixture: Fixture, draftId: String, inReplyTo: String? = nil, newEmail: Bool = false) async throws -> OutboxMessage {
        try await fixture.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: "Tuesday works", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let queued = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: "Tuesday works for me.",
                                inReplyTo: newEmail ? nil : (inReplyTo ?? fixture.parent.rfc822MessageId)),
            accountId: Self.account, replyToHeaderId: newEmail ? nil : fixture.parent.id, isForward: false, serverDraftId: nil,
            draftId: draftId, instanceEpoch: "E1", holdsForUndo: true)
        return try #require(try await fixture.pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) })
    }

    /// Sets the row's durable hold, so the test chooses where its window ends.
    private static func setHold(_ pool: DatabasePool, _ id: String, _ hold: Date) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET holdUntil = ? WHERE id = ?", arguments: [hold, id])
        }
    }
}
