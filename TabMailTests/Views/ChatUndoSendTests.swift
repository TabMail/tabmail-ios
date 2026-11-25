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
///  5. A reply sent with the chat view on from a compose the chat opened has no toast; any other
///     send keeps it, a reply from a compose opened on another screen included. Only the chat's own
///     composes record that the chat opened them.
@Suite("Undo send on the chat bubble", .serialized, .processGlobalState)
@MainActor
struct ChatUndoSendTests {
    nonisolated private static let account = "acc-undo-bubble"

    /// Every test starts with no Undo owner left by another (the suite's shared teardown point:
    /// Swift Testing makes a new suite value per test), so test order does not matter.
    init() {
        PendingSendService.shared.resetUndoOwnersForTesting()
    }

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

    /// More entries than any schedule in these tests has (the far hold's is about 86,550): reading
    /// stops there, so a sequence that never ends fails instead of hanging.
    nonisolated private static let entryBound = 200_000
    /// A century: a date this far past every redraw the bubble needs is one no mounted bubble waits for.
    nonisolated private static let unreachableWait: TimeInterval = 100 * 365 * 86_400

    /// The bubble's redraw instants from `start`, as its timeline asks for them: the whole sequence,
    /// its closing entry included, read up to `entryBound`.
    private static func schedule(from start: Date, deadline: Date, animatesFill: Bool) -> [Date] {
        var entries = ChatUndoSendSchedule(deadline: deadline, animatesFill: animatesFill)
            .entries(from: start, mode: .normal).makeIterator()
        var all: [Date] = []
        while all.count <= Self.entryBound, let next = entries.next() { all.append(next) }
        let ended = all.count <= Self.entryBound
        #expect(ended, "the sequence ends")
        return all
    }

    /// The instants the timeline actually redraws at: the sequence less its closing entry. A
    /// TimelineView does not redraw at its schedule's last date, so the sequence must not end on one
    /// it needs: after the last date it needs (the deadline, or `start` when that is not before it)
    /// it gives exactly one more, beyond any wait, and then ends.
    private static func redraws(from start: Date, deadline: Date, animatesFill: Bool) -> [Date] {
        let all = schedule(from: start, deadline: deadline, animatesFill: animatesFill)
        let inOrder = zip(all, all.dropFirst()).allSatisfy { $0 < $1 }
        #expect(inOrder, "in order, each instant once")
        let lastNeeded = max(start, deadline)
        let closing = all.filter { $0 > lastNeeded }
        #expect(closing.count == 1 && closing.first == all.last, "one entry after the last needed date, and it ends the sequence")
        let beyondAnyWait = closing.first.map { $0.timeIntervalSince(lastNeeded) > Self.unreachableWait } ?? false
        #expect(beyondAnyWait, "the closing entry is one no mounted bubble reaches: \(String(describing: closing.first))")
        return Array(all.dropLast())
    }

    @Test("The countdown's ticks fall on each whole second before the deadline and end at it")
    func ticksEndAtTheDeadline() {
        let start = Date()
        let deadline = start.addingTimeInterval(2.5)
        let ticks = Self.redraws(from: start, deadline: deadline, animatesFill: false)
        #expect(ticks == [start, deadline.addingTimeInterval(-2), deadline.addingTimeInterval(-1), deadline])
        for animatesFill in [false, true] {
            // Opened at the deadline, or after it: the start alone, nothing more to redraw.
            for late in [deadline, deadline.addingTimeInterval(1)] {
                let lateRedraws = Self.redraws(from: late, deadline: deadline, animatesFill: animatesFill)
                #expect(lateRedraws == [late], "a start at or after the deadline redraws once: fill \(animatesFill)")
            }
            let all = Self.schedule(from: start, deadline: deadline, animatesFill: animatesFill)
            #expect(all.dropLast().last == deadline,
                    "the deadline is not the schedule's last date, so the timeline redraws at it: \(animatesFill)")
        }
    }

    @Test("A hold far ahead of the clock redraws once a second until the fill's window, then frame by frame to the deadline")
    func farHoldRedrawsBySecondsUntilTheFill() {
        // A reply queued while the device's date ran a day ahead, its chat opened after the date was set right.
        let start = Date()
        let deadline = start.addingTimeInterval(86_400.5)
        let window = SyncConfig.outboxUndoHoldSeconds
        let frame = 1 / Double(ChatUndoSendConfig.fillFramesPerSecond)
        let redraws = Self.redraws(from: start, deadline: deadline, animatesFill: true)
        #expect(redraws.first == start && redraws.last == deadline, "from the start to the deadline")
        let gaps = zip(redraws, redraws.dropFirst()).map { (at: $0, gap: $1.timeIntervalSince($0)) }
        #expect(gaps.allSatisfy { $0.gap > 0 }, "in order, each instant once")
        let fillStarts = deadline.addingTimeInterval(-window)
        let beforeFill = gaps.filter { $0.at < fillStarts.addingTimeInterval(-1) }
        #expect(!beforeFill.isEmpty && beforeFill.allSatisfy { abs($0.gap - 1) < 0.001 || $0.at == start },
                "before the fill moves, one redraw a second: the countdown's")
        let inFill = gaps.filter { $0.at >= fillStarts }
        #expect(inFill.count == Int((window / frame).rounded()) && inFill.allSatisfy { abs($0.gap - frame) < 0.001 },
                "inside the fill's window, every frame")
        #expect(redraws.count < 86_400 + 2 * Int((window / frame).rounded()),
                "control: about one redraw a second, not a frame's worth: \(redraws.count)")
        let still = Self.redraws(from: start, deadline: deadline, animatesFill: false)
        #expect(still.count == 86_402 && still.last == deadline, "Reduce Motion: the whole seconds alone, then the deadline")
    }

    // MARK: - 1b. The fill-up look follows the deadline

    private static func fill(_ look: ChatUndoSendLook) -> Double? {
        if case .pending(let fill) = look { return fill }
        return nil
    }

    @Test("The bubble is pending while Undo is offered, filled by the part of the window that has passed, then solid at the deadline")
    func lookFollowsTheDeadline() {
        let hold = Date().addingTimeInterval(4.5)
        let row = Self.reply(holdUntil: hold)
        let deadline = row.undoDeadline
        let window = SyncConfig.outboxUndoHoldSeconds
        let start = deadline.addingTimeInterval(-window)
        for fraction in [0.0, 0.25, 0.5, 0.9] {
            let at = start.addingTimeInterval(window * fraction)
            let fill = Self.fill(row.undoLook(at: at, reduceMotion: false))
            #expect(fill.map { abs($0 - fraction) < 0.001 } == true, "pending, filled by the part of the window passed: \(fraction)")
        }
        #expect(Self.fill(row.undoLook(at: start.addingTimeInterval(-1), reduceMotion: false)) == 0,
                "a bubble shown before its window starts is empty, never negative")
        #expect(row.undoLook(at: deadline, reduceMotion: false) == .solid, "solid at the deadline")
        #expect(row.undoLook(at: deadline.addingTimeInterval(1), reduceMotion: false) == .solid, "and after it")
        // Every instant agrees with the Undo on the status line: pending iff Undo is offered.
        for offset in stride(from: -6.0, through: 2.0, by: 0.25) {
            let at = deadline.addingTimeInterval(offset)
            #expect((Self.fill(row.undoLook(at: at, reduceMotion: false)) != nil) == (row.undoSecondsLeft(at: at) != nil),
                    "at \(offset)")
        }
        let now = Date()
        #expect(Self.reply(status: .failed, holdUntil: hold).undoLook(at: now, reduceMotion: false) == .solid)
        #expect(Self.reply(status: .sending, holdUntil: hold).undoLook(at: now, reduceMotion: false) == .solid)
        #expect(Self.reply(sentAt: now, holdUntil: hold).undoLook(at: now, reduceMotion: false) == .solid)
    }

    @Test("Under Reduce Motion the fill does not rise, and the bubble turns solid when the email is sent, not when Undo ends")
    func reduceMotionHasNoRisingFill() {
        let hold = Date().addingTimeInterval(4.5)
        let row = Self.reply(holdUntil: hold)
        let deadline = row.undoDeadline
        // Queued, before and after the Undo window ends (a claim buffer, or offline for long).
        for offset in [-4.0, -2.0, -0.25, 0.0, 0.5, 1.0, 30.0, 600.0] {
            #expect(row.undoLook(at: deadline.addingTimeInterval(offset), reduceMotion: true) == .pending(fill: 0),
                    "queued at \(offset): pending, never solid before it is sent")
        }
        #expect(Self.reply(status: .sending, holdUntil: hold).undoLook(at: deadline.addingTimeInterval(1), reduceMotion: true)
                == .pending(fill: 0), "sending is not sent")
        #expect(Self.reply(sentAt: Date(), holdUntil: hold).undoLook(at: deadline.addingTimeInterval(1), reduceMotion: true)
                == .solid, "solid once the email is sent")
        #expect(Self.reply(status: .failed, holdUntil: hold).undoLook(at: deadline, reduceMotion: true) == .solid,
                "a failed send has its own Not sent look on the ordinary bubble")
        #expect(row.undoSecondsLeft(at: deadline) == nil, "control: Undo itself still ends at the deadline")
        let start = deadline.addingTimeInterval(-4)
        let still = Self.redraws(from: start, deadline: deadline, animatesFill: false)
        let wholeSeconds = [start] + [3.0, 2.0, 1.0].map { deadline.addingTimeInterval(-$0) } + [deadline]
        #expect(still == wholeSeconds, "no frame-by-frame redraw: only the whole seconds")
        let frames = Self.redraws(from: start, deadline: deadline, animatesFill: true)
        #expect(frames.count > still.count && frames.last == deadline
                && frames.allSatisfy { $0 <= deadline }, "control: the moving fill redraws often and stops at the deadline")
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
        // Instants half a second off row a's own stored deadline, so the database's millisecond
        // dates cannot move a whole-second count.
        let beforeA = ra.undoDeadline.addingTimeInterval(-0.5)
        #expect(ra.undoSecondsLeft(at: beforeA) == 1 && rb.undoSecondsLeft(at: beforeA) == 21,
                "each from its own hold less the claim buffer")
        let afterA = ra.undoDeadline.addingTimeInterval(0.5)
        #expect(ra.undoSecondsLeft(at: afterA) == nil && rb.undoSecondsLeft(at: afterA) == 20,
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
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
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
                        toSummary: "To: someone@example.com", holdUntil: hold, owner: .toast)
        while service.reopenSnapshot != nil { service.finishReopen() }

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

    @Test("A reply sent with the chat view on from a compose the chat opened has its Undo on the bubble; any other send keeps the toast")
    func toastOrBubble() {
        let reply = "<p@example.com>"
        #expect(PendingSendService.sendHasBubbleUndo(chatViewActive: true, openedOn: .chat, inReplyTo: reply))
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: true, openedOn: nil, inReplyTo: reply),
                "a reply from a compose another screen opened (the Drafts list, the compose the toast's Undo reopens)")
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: false, openedOn: .chat, inReplyTo: reply))
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: true, openedOn: .chat, inReplyTo: nil))
        // Of all eight combinations, only the first has the bubble.
        var bubbles = 0
        for chatView in [true, false] {
            for openedOn in [ComposeScreen.chat, nil] {
                for inReplyTo in [reply, nil] {
                    let bubble = PendingSendService.sendHasBubbleUndo(
                        chatViewActive: chatView, openedOn: openedOn, inReplyTo: inReplyTo)
                    if bubble { bubbles += 1 }
                }
            }
        }
        #expect(bubbles == 1, "the bubble needs the chat view, a compose the chat opened, and a reply")
    }

    @Test("A new email sent from the compose card its own chat opened has its Undo on that chat's bubble with the chat view on, though it has no In-Reply-To")
    func newEmailChatHasTheBubble() {
        #expect(PendingSendService.sendHasBubbleUndo(chatViewActive: true, openedOn: .newEmailChat, inReplyTo: nil),
                "the new email's chat shows the send, found by the card's draft")
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: false, openedOn: .newEmailChat, inReplyTo: nil),
                "with the chat view off, the toast")
        #expect(!PendingSendService.sendHasBubbleUndo(chatViewActive: true, openedOn: .chat, inReplyTo: nil),
                "control: a new email from an email's chat keeps the toast")
    }

    /// The presenters that offer a send's Undo right now, read as the app reads them: the toast
    /// RootView shows (`visibleToast`), and the bubble of a chat showing the row.
    private static func presenters(of row: OutboxMessage, chat: Set<String>, pool: DatabasePool) async throws -> Int {
        let service = PendingSendService.shared
        let toast = service.visibleToast?.id == row.id
        let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let bubble = bubbles.contains {
            $0.id == row.id && $0.bubbleUndoSecondsLeft(at: Date(), owner: service.undoOwner(for: row.id)) != nil
        }
        return (toast ? 1 : 0) + (bubble ? 1 : 0)
    }

    @Test("Every send has exactly one Undo presenter through its window, a reply and a new email, from the chat or another screen, whatever the chat view does after Send")
    func exactlyOnePresenterAcrossChatViewFlips() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let fixture = try await Self.makeFixture(pool)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        var n = 0
        for atSend in [true, false] {
            for isReply in [true, false] {
                for openedOn in [ComposeScreen.chat, nil] {
                    n += 1
                    let row = try await Self.queueReply(fixture, draftId: "draft-flip-\(n)", newEmail: !isReply)
                    let hold = Date().addingTimeInterval(3600)
                    try await Self.setHold(pool, row.id, hold)
                    // Send as ComposeView does: the owner from the setting read at the Send tap and
                    // the screen the compose was opened on.
                    saved.setChatView(on: atSend)
                    let owner: PendingSendService.UndoOwner = PendingSendService.sendHasBubbleUndo(
                        chatViewActive: ChatViewConfig.isActive, openedOn: openedOn, inReplyTo: row.inReplyTo) ? .bubble : .toast
                    service.present(outboxId: row.id, draftId: "draft-flip-\(n)", instanceEpoch: "E1",
                                    toSummary: "To: sender@example.com", holdUntil: hold, owner: owner)
                    let screen = openedOn == .chat ? "the chat" : "another screen"
                    let what = "chat view \(atSend) at Send, \(isReply ? "reply" : "new email") opened on \(screen)"
                    #expect(try await Self.presenters(of: row, chat: chat, pool: pool) == 1, "\(what), no flip")
                    // The chat view flips during the window, then flips back.
                    saved.setChatView(on: !atSend)
                    #expect(try await Self.presenters(of: row, chat: chat, pool: pool) == 1, "\(what), flipped")
                    saved.setChatView(on: atSend)
                    #expect(try await Self.presenters(of: row, chat: chat, pool: pool) == 1, "\(what), flipped back")
                    service.dismiss()
                }
            }
        }
    }

    @Test("A chat reply still in its window after a relaunch (no owner known) has its Undo on the bubble only")
    func relaunchedReplyHasBubbleOnly() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-relaunch")
        try await Self.setHold(pool, row.id, Date().addingTimeInterval(3600))
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        #expect(PendingSendService.shared.undoOwner(for: row.id) == nil, "control: this run never presented it")
        #expect(PendingSendService.shared.visibleToast?.id != row.id, "no toast")
        #expect(try await Self.presenters(of: row, chat: chat, pool: pool) == 1, "the bubble is its one presenter")
    }

    @Test("A send whose Undo is on its bubble leaves another send's toast showing")
    func bubbleSendKeepsAnotherToast() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let fixture = try await Self.makeFixture(pool)
        let email = try await Self.queueReply(fixture, draftId: "draft-keep-email", newEmail: true)
        let reply = try await Self.queueReply(fixture, draftId: "draft-keep-reply")
        let hold = Date().addingTimeInterval(3600)
        service.present(outboxId: email.id, draftId: "draft-keep-email", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        service.present(outboxId: reply.id, draftId: "draft-keep-reply", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        #expect(service.visibleToast?.id == email.id, "the new email keeps its toast, its only Undo")
        #expect(service.undoOwner(for: reply.id) == .bubble && service.undoOwner(for: email.id) == .toast)
    }

    @Test("Two Undos before either compose opens reopen both, in order; a repeated Undo does nothing and says nothing")
    func overlappingUndosKeepEveryReopen() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        while service.reopenSnapshot != nil { service.finishReopen() }
        let fixture = try await Self.makeFixture(pool)
        let email = try await Self.queueReply(fixture, draftId: "draft-two-email", newEmail: true)
        let reply = try await Self.queueReply(fixture, draftId: "draft-two-reply")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, email.id, hold)
        try await Self.setHold(pool, reply.id, hold)
        service.present(outboxId: email.id, draftId: "draft-two-email", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        service.present(outboxId: reply.id, draftId: "draft-two-reply", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        let replyPending = PendingSendService.Pending(
            id: reply.id, draftId: "draft-two-reply", instanceEpoch: "E1", toSummary: "",
            presentedAt: Date(), holdUntil: hold)

        service.undoAndReopen()               // the toast's Undo
        service.undoAndReopen(replyPending)   // the bubble's Undo, before the first compose opens
        #expect(service.reopenQueue.map(\.id) == [email.id, reply.id], "both composes wait to reopen, the first first")
        let left = try await pool.read { try OutboxMessage.fetchAll($0).map(\.id) }
        #expect(!left.contains(email.id) && !left.contains(reply.id), "both sends are cancelled")

        service.undoAndReopen(replyPending)   // a second tap on the same bubble
        #expect(service.reopenQueue.count == 2, "a repeated Undo adds nothing")
        #expect(service.undoFailureMessage == nil, "and raises no failure notice")

        service.finishReopen()
        #expect(service.reopenSnapshot?.id == reply.id, "the second compose opens when the first closes")
    }

    @Test("A new email's chat finds its send by the card's draft: the row while it is queued, then its copy in the account's Sent folder by Message-ID, after the row has gone too")
    func newEmailSendFoundByItsDraft() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let fixture = try await Self.makeFixture(pool)
        var key = ChatNewEmailSend.Key(draftId: "draft-found")
        let nothing = try await pool.read { [key] in try ChatNewEmailSend.fetch(key, db: $0) }
        #expect(nothing == ChatNewEmailSend(reply: nil, email: nil, sentCopyId: nil), "nothing sent yet")

        _ = try await Self.queueReply(fixture, draftId: "draft-other", newEmail: true)
        let row = try await Self.queueReply(fixture, draftId: "draft-found", newEmail: true)
        let queued = try await pool.read { [key] in try ChatNewEmailSend.fetch(key, db: $0) }
        #expect(queued.reply?.id == row.id, "the row of the card's own draft, not another send's")
        let rowMessageId = try #require(row.sentMessageId, "control: the row names its Message-ID")
        let messageId = EmailFilter.normalizeMessageId(rowMessageId)
        let email = ChatNewEmailSend.Email(accountId: row.accountId, messageId: messageId)
        #expect(queued.email == email, "the email the row names")
        #expect(queued.sentCopyId == nil && queued.reply?.filed == false, "no Sent copy yet")

        // A copy outside the Sent folder (the email received back, say) is not the sent copy.
        func header(_ id: String, folder: String) -> MessageHeader {
            var header = MessageHeader(
                messageId: id, subject: "Re: Lunch plans", from: "me@example.com", fromAddress: "me@example.com",
                to: "sender@example.com", date: Date(), snippet: "Tuesday",
                folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: folder),
                accountId: Self.account, folderPath: folder, isInInbox: folder == "INBOX")
            header.rfc822MessageId = messageId
            return header
        }
        let received = header("found-received", folder: "INBOX")
        try await pool.write { try received.insert($0) }
        let elsewhere = try await pool.read { [key] in try ChatNewEmailSend.fetch(key, db: $0) }
        #expect(elsewhere.sentCopyId == nil, "a copy in another folder is not the sent copy")

        let copy = header("found-sent", folder: "Sent")
        try await pool.write { try copy.insert($0) }
        let filed = try await pool.read { [key] in try ChatNewEmailSend.fetch(key, db: $0) }
        #expect(filed.sentCopyId == copy.id, "the copy in the account's Sent folder")
        #expect(filed.reply?.filed == true, "the bubble reads as filed")

        // The row gone before the chat saw the copy: the email the chat kept from the row finds it.
        let rowId = row.id
        _ = try await pool.write { try OutboxMessage.deleteOne($0, key: rowId) }
        let forgotten = try await pool.read { [key] in try ChatNewEmailSend.fetch(key, db: $0) }
        #expect(forgotten == ChatNewEmailSend(reply: nil, email: nil, sentCopyId: nil), "control: with no email kept, nothing names it")
        key.email = email
        let kept = try await pool.read { [key] in try ChatNewEmailSend.fetch(key, db: $0) }
        #expect(kept.reply == nil && kept.sentCopyId == copy.id, "the kept email finds the Sent copy")
    }

    @Test("Undo on a new email's chat's bubble reopens a compose that records that chat; the chat modal on top presents the outcome, and RootView only once none is open")
    func newEmailChatPresentsItsUndoOutcome() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        let search = UUID(), chat = UUID()
        defer {
            service.chatModalClosed(chat)
            service.chatModalClosed(search)
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        while service.reopenSnapshot != nil { service.finishReopen() }
        #expect(service.chatModals.isEmpty, "control: no chat modal is open")
        let fixture = try await Self.makeFixture(pool)
        let email = try await Self.queueReply(fixture, draftId: "draft-new-email-chat", newEmail: true)
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, email.id, hold)
        service.present(outboxId: email.id, draftId: "draft-new-email-chat", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        // Search open, and a new email's chat over it.
        service.chatModalOpened(search)
        service.chatModalOpened(chat)
        #expect(service.chatModals == [search, chat])
        #expect(service.reopen(presentedBy: chat) == nil && !service.closesForOutcome(search), "control: nothing waits yet")

        service.undoAndReopen(PendingSendService.Pending(
            id: email.id, draftId: "draft-new-email-chat", instanceEpoch: "E1", toSummary: "",
            presentedAt: Date(), holdUntil: hold), bubbleScreen: .newEmailChat)
        let reopen = try #require(service.reopenSnapshot, "the bubble's Undo reopens the compose")
        #expect(reopen.openedOn == .newEmailChat, "the reopened compose records the new email's chat, so a send again keeps its bubble")
        #expect(service.reopen(presentedBy: chat)?.id == email.id, "the chat on top presents it over itself")
        #expect(service.reopen(presentedBy: search) == nil, "not Search under it")
        #expect(!service.closesForOutcome(search), "and Search under it stays open")
        #expect(service.topLevelReopen == nil, "RootView waits while a chat modal is open")

        // The chat closed (Back) before its compose opened: Search is on top, and closes for it.
        service.chatModalClosed(chat)
        #expect(service.reopen(presentedBy: chat) == nil)
        #expect(service.closesForOutcome(search), "Search, now on top, closes so RootView can present it")
        #expect(service.topLevelReopen == nil)
        service.chatModalClosed(search)
        #expect(service.topLevelReopen?.id == email.id, "with none open, RootView presents it")

        // A screen that opens again goes to the top.
        service.chatModalOpened(chat)
        service.chatModalOpened(search)
        service.chatModalOpened(chat)
        #expect(service.chatModals == [search, chat])
    }

    @Test("RootView shows the toast only for a send whose Undo is not on a bubble, and both Undos share one reopen")
    func rootViewWiring() throws {
        let text = try Self.source("TabMail/Views/RootView.swift")
        #expect(text.contains(".modifier(PendingSendToastPresenter())"), "RootView mounts the toast's presenter")
        #expect(text.contains(".modifier(UndoReopenPresenter())"), "RootView is the one presenter of the reopen")
        let toast = try Self.source("TabMail/Views/Shared/PendingSendToast.swift")
        #expect(toast.contains("if let pending = service.visibleToast {"))
        #expect(toast.contains("onUndo: { service.undoAndReopen() }"), "the toast's Undo is the one undo-and-reopen")
        let compose = try Self.source("TabMail/Views/Compose/ComposeView.swift")
        #expect(compose.contains("owner: snapshot.sendHasBubbleUndo ? .bubble : .toast"))
        let inbox = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        #expect(inbox.contains(".chatModalSheet(isPresented: $showSearch) {"),
                "the Search sheet, which can hold a chat, closes for an Undo's outcome")
    }

    @Test("A chat records itself for a compose only when its target is one of the chat's own emails")
    func chatRecordsItselfOnlyForItsOwnEmail() {
        func email(_ rfc822MessageId: String?) -> MessageHeader {
            var header = MessageHeader(
                messageId: "screen-target", subject: "Lunch plans", from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "Note",
                folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
                accountId: Self.account, folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = rfc822MessageId
            return header
        }
        // The chat's Message-IDs as `ChatThreadView` builds them from its emails: one written with spaces
        // inside its brackets, and one blank.
        let chat = Set(["<own@example.com>", "< padded@example.com >", ""].map(EmailFilter.normalizeMessageId))
        #expect(ChatThreadView.composeScreen(answering: email("<own@example.com>"), chatMessageIds: chat) == .chat)
        #expect(ChatThreadView.composeScreen(answering: email("own@example.com"), chatMessageIds: chat) == .chat,
                "the same Message-ID written without brackets")
        #expect(ChatThreadView.composeScreen(answering: email("<other-thread@example.com>"), chatMessageIds: chat) == nil,
                "an agent's card for an email of another thread: that chat, not this one, shows its send")
        #expect(ChatThreadView.composeScreen(answering: email(nil), chatMessageIds: chat) == nil,
                "an email with no Message-ID: no chat finds its send")
        #expect(ChatThreadView.composeScreen(answering: nil, chatMessageIds: chat) == nil, "a new email")
        #expect(ChatThreadView.composeScreen(answering: email("< padded@example.com >"), chatMessageIds: chat) == nil,
                "the chat's own email, but its send's In-Reply-To is not found by the chat: no bubble, so the toast")
        #expect(ChatThreadView.composeScreen(answering: email(""), chatMessageIds: chat) == nil,
                "a blank Message-ID: the send carries no In-Reply-To")
        // One rule: the chat records itself exactly for the sends it shows as its bubbles, judged on the
        // In-Reply-To the send queues (`ThreadUtils.outgoingThreadHeaders`, as Send builds it).
        let stored: [String?] = ["<own@example.com>", "own@example.com", "<other-thread@example.com>", "< padded@example.com >", "", nil]
        for id in stored {
            let target = email(id)
            let queued = ThreadUtils.outgoingThreadHeaders(
                replyTo: target, sendAccountId: Self.account, sendSubject: "Re: Lunch plans", providerKind: .gmail).inReplyTo
            let shown = ChatUnsentReply.answers(queued, in: chat)
            let recorded = ChatThreadView.composeScreen(answering: target, chatMessageIds: chat) == .chat
            #expect(recorded == shown, "\(String(describing: id)): the chat records itself only for a send it shows as a bubble")
        }
    }

    /// Where the sends are pinned, as the user sees them (`ChatUndoSendRoutingTests`): the chat's
    /// AI Suggestion and toolbar Forward (1d), the agent's cards the chat opens (1c), and the agent's
    /// cards the inbox and the email's screen open, which keep the toast (1f). This guards a compose
    /// builder the chat may gain later, which those sends would not reach.
    @Test("Every compose the chat view opens for a reply or forward decides from its target whether it records the chat, and no compose records the chat whatever its target")
    func onlyTheChatsComposesRecordTheChat() throws {
        let chat = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        // Its builders: the toolbar Forward (`ComposeView(`); the AI Suggestion and the agent's cards,
        // the agent's through its one presenter (`.composeView(`).
        let built = chat.components(separatedBy: "ComposeView(").count - 1 + chat.components(separatedBy: ".composeView(").count - 1
        let decided = chat.components(separatedBy: "openedOn: composeScreen(answering: ").count - 1
        #expect(built == 3, "control: the chat's compose builders: \(built)")
        #expect(decided == 3, "every compose it opens records the chat only for its own email: \(decided) of 3")
        let unconditional = try Self.appSourceFiles(containing: "openedOn: .chat")
        #expect(unconditional.isEmpty, "no compose records the chat whatever its target: \(unconditional)")
    }

    // MARK: - 6. Owner kept, retry, hand-back

    @Test("Presenting the same send again keeps its first owner; the next send uses the setting at its own Send")
    func representKeepsTheOwner() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-again")
        let next = try await Self.queueReply(fixture, draftId: "draft-next")
        let hold = Date().addingTimeInterval(3600)
        service.present(outboxId: row.id, draftId: "draft-again", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        // The dedup path presents the in-flight row again, after the chat view came on.
        service.present(outboxId: row.id, draftId: "draft-again", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        #expect(service.undoOwner(for: row.id) == .toast, "the send keeps the owner decided at its Send")
        #expect(service.visibleToast?.id == row.id, "and its toast")
        service.present(outboxId: next.id, draftId: "draft-next", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        #expect(service.undoOwner(for: next.id) == .bubble, "a new send uses the changed setting")
    }

    @Test("An Undo refused by the database can be tapped again once the fault is gone, and then cancels and reopens")
    func refusedUndoCanBeRetried() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        while service.reopenSnapshot != nil { service.finishReopen() }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-retry")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, row.id, hold)
        service.present(outboxId: row.id, draftId: "draft-retry", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)

        let refuser = UndoProviderIdentitySafetyTests.OutboxDeleteCommitRefuser()
        pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        service.undoAndReopen()
        pool.remove(transactionObserver: refuser)
        #expect(refuser.refusals.withLock { $0 } == 1, "control: the cancellation commit was refused")
        #expect(service.undoFailureMessage != nil, "the user is told the Undo did not take")
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } != nil, "nothing was cancelled")
        #expect(service.reopenQueue.isEmpty && service.visibleToast?.id == row.id, "no reopen; the toast stays")

        service.dismissUndoFailure()          // the user acknowledges the notice
        service.undoAndReopen()               // and taps Undo again
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } == nil, "the retry cancels the send")
        #expect(service.reopenQueue.map(\.id) == [row.id], "and reopens its compose")
        #expect(service.undoFailureMessage == nil)
    }

    @Test("A bubble-owned send counts as sending through its window, and stops counting the moment its Undo is confirmed")
    func confirmedBubbleUndoEndsSending() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        while service.reopenSnapshot != nil { service.finishReopen() }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-sending")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, row.id, hold)
        #expect(!service.isSending, "control: nothing is sending")
        service.present(outboxId: row.id, draftId: "draft-sending", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        #expect(service.visibleToast == nil && service.isSending,
                "a send whose Undo is on its bubble is sending (the coach card shows progress) with no toast")

        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let bubble = try #require(bubbles.first { $0.id == row.id })
        bubble.undo()
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } == nil, "control: the Undo was confirmed")
        #expect(!service.isSending, "a cancelled send is no longer sending, at once")
        #expect(service.undoOwner(for: row.id) == nil, "and has no Undo owner left")
    }

    @Test("A bubble-owned send stops counting as sending once its window and acknowledgement end")
    func bubbleOwnerExpires() async throws {
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
        }
        service.dismiss()
        #expect(!service.isSending, "control: nothing is sending")
        let id = "o-expiry-\(UUID().uuidString)"
        let hold = Date().addingTimeInterval(0.5)
        service.present(outboxId: id, draftId: "d", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        #expect(service.isSending, "control: sending during its window")
        // The owner lives for the rest of the hold plus the queued acknowledgement.
        let ends = hold.addingTimeInterval(SyncConfig.outboxQueuedAcknowledgementSeconds)
        let limit = ends.addingTimeInterval(3)
        while Date() < limit && service.isSending { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!service.isSending, "the tutorial coach card (it reads isSending) no longer shows a send in progress")
        #expect(service.undoOwner(for: id) == nil, "and the send has no Undo owner left")
        #expect(Date() >= ends.addingTimeInterval(-0.2), "control: it ended with its lifetime, not early")
    }

    @Test("A toast closed after its send's Undo deadline hands nothing to the bubble: no Undo anywhere, and nothing counts as sending")
    func lateCloseHandsNothingOver() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        let fixture = try await Self.makeFixture(pool)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        let row = try await Self.queueReply(fixture, draftId: "draft-late-close")
        // Past its Undo deadline, still in its queued acknowledgement.
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds - 0.5)
        try await Self.setHold(pool, row.id, hold)
        service.present(outboxId: row.id, draftId: "draft-late-close", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        service.dismiss()
        #expect(try await Self.presenters(of: row, chat: chat, pool: pool) == 0, "no Undo on the toast or the bubble")
        #expect(!service.isSending, "and nothing counts as sending once the toast is closed")
    }

    @Test("The bubble's Undo does nothing for a send whose Undo is on the toast")
    func bubbleUndoRefusesAToastOwnedSend() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        while service.reopenSnapshot != nil { service.finishReopen() }
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-toast-owned")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, row.id, hold)
        service.present(outboxId: row.id, draftId: "draft-toast-owned", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        let bubbles = try await pool.read { try ChatUnsentReply.fetch(answering: chat, db: $0) }
        let bubble = try #require(bubbles.first { $0.id == row.id })
        #expect(bubble.undoSecondsLeft(at: Date()) != nil, "control: the send is still in its window")

        bubble.undo()
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } != nil, "nothing is cancelled")
        #expect(service.reopenQueue.isEmpty, "nothing reopens")
        #expect(service.visibleToast?.id == row.id, "the toast keeps the send's one Undo")
    }

    @Test("A toast-owned reply whose toast another send replaces, or the user closes, keeps exactly one Undo: its bubble's")
    func replacedToastHandsUndoToTheBubble() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        let fixture = try await Self.makeFixture(pool)
        let chat: Set<String> = [EmailFilter.normalizeMessageId(try #require(fixture.parent.rfc822MessageId))]
        // Two replies sent 3 s apart with the chat view off: both toast-owned, both in their window.
        saved.setChatView(on: false)
        let first = try await Self.queueReply(fixture, draftId: "draft-hand-1")
        let second = try await Self.queueReply(fixture, draftId: "draft-hand-2")
        let firstHold = Date().addingTimeInterval(3600)
        let secondHold = firstHold.addingTimeInterval(3)
        try await Self.setHold(pool, first.id, firstHold)
        try await Self.setHold(pool, second.id, secondHold)
        service.present(outboxId: first.id, draftId: "draft-hand-1", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: firstHold, owner: .toast)
        #expect(try await Self.presenters(of: first, chat: chat, pool: pool) == 1, "the first: its toast")
        service.present(outboxId: second.id, draftId: "draft-hand-2", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: secondHold, owner: .toast)
        saved.setChatView(on: true)           // the chat that shows both bubbles is open now
        #expect(try await Self.presenters(of: first, chat: chat, pool: pool) == 1, "the first: now its bubble")
        #expect(service.undoOwner(for: first.id) == .bubble, "control: the bubble took it")
        #expect(try await Self.presenters(of: second, chat: chat, pool: pool) == 1, "the second: its toast")
        // The user closes the second toast: its bubble takes the Undo.
        service.dismiss()
        #expect(try await Self.presenters(of: second, chat: chat, pool: pool) == 1, "the second: now its bubble")

        // A send whose window has ended hands nothing over.
        let late = try await Self.queueReply(fixture, draftId: "draft-hand-late")
        let past = Date().addingTimeInterval(-60)
        try await Self.setHold(pool, late.id, past)
        service.present(outboxId: late.id, draftId: "draft-hand-late", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: past, owner: .toast)
        service.dismiss()
        #expect(service.undoOwner(for: late.id) == .toast, "past its deadline the toast keeps it (no Undo left anywhere)")
    }

    // MARK: - 7. Hosted: reopen through the app's reopen presenter, the bubble under Reduce Motion

    private static func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }

    @Test("Two Undos before either compose opens: the app's one reopen presenter opens both composes, one after the other, each with its own draft")
    func reopenPresenterReopensBothComposes() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted window")
        try await HostedAccessibility.withAutomation { @MainActor in try await reopenBody() }
    }

    private func reopenBody() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            while service.reopenSnapshot != nil { service.finishReopen() }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        while service.reopenSnapshot != nil { service.finishReopen() }
        let fixture = try await Self.makeFixture(pool)
        let email = try await Self.queueReply(fixture, draftId: "draft-root-1", newEmail: true, body: "First reopened words")
        let reply = try await Self.queueReply(fixture, draftId: "draft-root-2", body: "Second reopened words")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, email.id, hold)
        try await Self.setHold(pool, reply.id, hold)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        // RootView's reopen presenter (`UndoReopenPresenter`, its mounting fenced in `rootViewWiring`) on an
        // inert view: no RootView, so none of its startup work runs.
        window.rootViewController = UIHostingController(
            rootView: Color.clear.modifier(UndoReopenPresenter()).environment(Self.navigationStore(fixture)))
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        func texts() -> [String] { Self.textViews(window).map(\.text) }
        func shows(_ words: String) -> Bool { texts().contains { $0.contains(words) } }

        service.present(outboxId: email.id, draftId: "draft-root-1", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        service.present(outboxId: reply.id, draftId: "draft-root-2", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)
        service.undoAndReopen()
        service.undoAndReopen(PendingSendService.Pending(
            id: reply.id, draftId: "draft-root-2", instanceEpoch: "E1", toSummary: "", presentedAt: Date(), holdUntil: hold))

        try await Self.waitFor { shows("First reopened words") }
        #expect(shows("First reopened words"), "the first compose opens with its own draft")
        #expect(!shows("Second reopened words"), "one compose at a time")
        // Reach the next compose without the compose's Close (its close decision belongs to
        // ADR-IOS-065, not to this test): the cover goes away as the system dismisses it, which
        // clears the presenter's binding.
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        try await Self.waitFor { shows("Second reopened words") }
        #expect(shows("Second reopened words") && !shows("First reopened words"),
                "after the first compose goes, the second opens, with its own draft")
        #expect(service.reopenSnapshot?.id == reply.id, "the second reopen is the one showing")
    }

    @Test("Under Reduce Motion the real bubble has one Undo button whose value counts down, and its fill does not rise")
    func bubbleUnderReduceMotion() async throws {
        #expect(HostedAccessibility.isAvailable && HostedAccessibility.canSetReduceMotion,
                "control: the test can read the bubble and set Reduce Motion")
        try await HostedAccessibility.withAutomation { @MainActor in
            try await HostedAccessibility.withReduceMotion(true) { @MainActor in try await reduceMotionBody() }
        }
    }

    private func reduceMotionBody() async throws {
        #expect(UIAccessibility.isReduceMotionEnabled, "control: Reduce Motion is on")
        // 4 s of Undo left, 1 s of the window passed.
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 4)
        let reply = ChatUnsentReply(outboxId: "o-reduce", status: .queued, sentAt: nil, holdUntil: hold,
                                    draftId: "d", instanceEpoch: "E1", filed: false, textMessage: "ok, Tuesday works.")
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
        let undo: @MainActor () -> [(label: String?, value: String?)] = {
            HostedAccessibility.labelsAndValues(of: ChatUndoSendStatus.undoId, in: controller.view)
        }
        try await Self.waitFor { !undo().isEmpty }
        let first = undo()
        #expect(first.count == 1, "one Undo button")
        #expect(first.first?.label == "Undo send", "its label names the action, not the time")
        let firstValue = try #require(first.first?.value)
        #expect(firstValue.hasSuffix("seconds left"), "its value carries the time")
        // A tick later: the same one button, the label unchanged, only the value counts down.
        try await Self.waitFor { undo().first?.value != firstValue }
        let later = undo()
        #expect(later.count == 1 && later.first?.label == "Undo send", "still one button, same label")
        let seconds = { (value: String?) in value.flatMap { Int($0.split(separator: " ").first ?? "") } }
        #expect(seconds(later.first?.value).map { $0 < (seconds(firstValue) ?? 0) } == true, "the value counted down")

        // The real bubble read Reduce Motion: drawn 3 s into the window, the middle is still the tint.
        try await Task.sleep(for: .seconds(1.5))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let bubbleFrame = try #require(Self.bubbleFrame(in: controller.view), "the bubble's text is on screen")
        // The text's bottom-left corner, below the round "o": background, low in the bubble, where
        // a rising fill (60% up by now) would be solid blue.
        let probe = CGPoint(x: bubbleFrame.minX + 1, y: bubbleFrame.maxY - 1)
        #expect(Self.color(of: image, at: probe).isClose(to: Palette.chatUndoSendPendingTint, in: controller.traitCollection),
                "the bubble still shows the pending tint: no rising fill under Reduce Motion")
    }

    @Test("Under Reduce Motion the mounted bubble stays pending past the Undo deadline until it is sent, whoever owns the Undo, and again after a failed send is retried")
    func reduceMotionLookFollowsDelivery() async throws {
        #expect(HostedAccessibility.isAvailable && HostedAccessibility.canSetReduceMotion,
                "control: the test can read the bubble and set Reduce Motion")
        try await HostedAccessibility.withAutomation { @MainActor in
            try await HostedAccessibility.withReduceMotion(true) { @MainActor in try await deliveryBody() }
        }
    }

    private func deliveryBody() async throws {
        #expect(UIAccessibility.isReduceMotionEnabled, "control: Reduce Motion is on")
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
        }
        // Undo ends 1.5 s from now.
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 1.5)
        func reply(_ id: String, _ status: OutboxStatus, sentAt: Date? = nil) -> ChatUnsentReply {
            ChatUnsentReply(outboxId: id, status: status, sentAt: sentAt, holdUntil: hold,
                            draftId: "d", instanceEpoch: "E1", filed: false, textMessage: "ok, Tuesday works.")
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 300)
        let controller = UIHostingController(rootView: ChatUnsentReplyBubble(reply: reply("o-life", .queued), retry: {}, delete: {}, undo: {}))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func show(_ row: ChatUnsentReply) async throws {
            controller.rootView = ChatUnsentReplyBubble(reply: row, retry: {}, delete: {}, undo: {})
            try await Task.sleep(for: .milliseconds(300))
        }
        func drawn() throws -> String {
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let frame = try #require(Self.bubbleFrame(in: controller.view), "the bubble's text is on screen")
            let pixel = Self.color(of: image, at: CGPoint(x: frame.minX + 1, y: frame.maxY - 1))
            if pixel.isClose(to: Palette.chatUndoSendPendingTint, in: controller.traitCollection) { return "pending" }
            if pixel.isClose(to: Theme.accent, in: controller.traitCollection) { return "solid" }
            return "other"
        }

        try await show(reply("o-life", .queued))
        #expect(try drawn() == "pending", "queued, in the Undo window")
        // The toast-owned reply in the same chat, queued in its window.
        service.present(outboxId: "o-toast", draftId: "d", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)
        try await show(reply("o-toast", .queued))
        #expect(try drawn() == "pending", "a toast-owned reply still queued looks pending: the look is delivery, not ownership")
        #expect(!HostedAccessibility.identifiers(in: controller.view).contains(ChatUndoSendStatus.undoId),
                "control: its bubble offers no Undo")

        try await Task.sleep(for: .seconds(2))   // past the Undo deadline
        try await show(reply("o-toast", .queued))
        #expect(try drawn() == "pending", "the toast-owned reply past the deadline, still queued: pending")
        try await show(reply("o-life", .queued))
        #expect(try drawn() == "pending", "past the deadline, still queued (a claim buffer, or offline): pending, not solid")
        #expect(!HostedAccessibility.identifiers(in: controller.view).contains(ChatUndoSendStatus.undoId),
                "control: the Undo itself has ended")
        try await show(reply("o-life", .sending))
        #expect(try drawn() == "pending", "sending: pending")
        try await show(reply("o-life", .queued, sentAt: Date()))
        #expect(try drawn() == "solid", "sent: solid")

        try await show(reply("o-retry", .failed))
        #expect(try drawn() == "solid", "a failed send: the ordinary bubble with its Not sent mark")
        try await show(reply("o-retry", .queued))
        #expect(try drawn() == "pending", "retried, queued again: pending")
        try await show(reply("o-retry", .queued, sentAt: Date()))
        #expect(try drawn() == "solid", "and solid once sent")
    }

    /// How long after the deadline a mounted bubble may still show its Undo: the display's own
    /// scheduling, well under half a second.
    nonisolated private static let displayAllowance: TimeInterval = 0.25
    /// How long the mounted bubble is read after its deadline.
    nonisolated private static let watchPastDeadline: TimeInterval = 1
    /// How often the mounted bubble is read.
    nonisolated private static let readInterval: Duration = .milliseconds(50)
    /// How many reads (`readInterval` apart) a hosted view gets to pick up a changed Reduce Motion.
    nonisolated private static let settleReads = 60

    @Test("A mounted bubble offers Undo until its deadline and not after it, with motion and under Reduce Motion; past the deadline a queued reply is solid to the top with motion and still pending under Reduce Motion",
          arguments: [false, true])
    func mountedBubbleCrossesItsDeadline(reduceMotion: Bool) async throws {
        #expect(HostedAccessibility.isAvailable && HostedAccessibility.canSetReduceMotion,
                "control: the test can read the bubble and set Reduce Motion")
        try await HostedAccessibility.withAutomation { @MainActor in
            try await HostedAccessibility.withReduceMotion(reduceMotion) { @MainActor in
                try await mountedDeadlineBody(reduceMotion: reduceMotion)
            }
        }
    }

    private func mountedDeadlineBody(reduceMotion: Bool) async throws {
        let setting = UIAccessibility.isReduceMotionEnabled
        #expect(setting == reduceMotion, "control: Reduce Motion is set as the case asks")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 300)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        // A view hosted right after the switch changes can still read the previous setting for a
        // moment: wait until a view hosted in this window reads the one this case set.
        let probe = UIHostingController(rootView: ReduceMotionProbe())
        window.rootViewController = probe
        window.makeKeyAndVisible()
        let wanted = ReduceMotionProbe.label(reduceMotion)
        func probeReads() -> Bool { HostedAccessibility.labels(in: probe.view).contains(wanted) }
        for _ in 0..<Self.settleReads where !probeReads() { try await Task.sleep(for: Self.readInterval) }
        let settled = probeReads()
        #expect(settled, "control: a hosted view reads the Reduce Motion setting this case set")

        // Undo ends 2.5 s from now; the reply stays queued past it (a claim buffer, or offline).
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 2.5)
        let reply = ChatUnsentReply(outboxId: "o-mounted", status: .queued, sentAt: nil, holdUntil: hold,
                                    draftId: "d", instanceEpoch: "E1", filed: false, textMessage: "ok, Tuesday works.")
        let deadline = reply.undoDeadline
        let controller = UIHostingController(rootView: ChatUnsentReplyBubble(reply: reply, retry: {}, delete: {}, undo: {}))
        window.rootViewController = controller
        func hasUndo() -> Bool {
            HostedAccessibility.identifiers(in: controller.view).contains(ChatUndoSendStatus.undoId)
        }
        // The bubble's colour low in it (the text's bottom-left corner, beside the round "o") and
        // at its top (inside the top padding, above the text): where a rising fill arrives first
        // and where it arrives last.
        func drawn() throws -> (low: String, top: String) {
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let frame = try #require(Self.bubbleFrame(in: controller.view), "the bubble's text is on screen")
            func name(at point: CGPoint) -> String {
                let pixel = Self.color(of: image, at: point)
                if pixel.isClose(to: Palette.chatUndoSendPendingTint, in: controller.traitCollection) { return "pending" }
                if pixel.isClose(to: Theme.accent, in: controller.traitCollection) { return "solid" }
                return "other"
            }
            return (name(at: CGPoint(x: frame.minX + 1, y: frame.maxY - 1)), name(at: CGPoint(x: frame.midX, y: frame.minY - 5)))
        }

        // Read the bubble over the whole window and a second past its deadline, each reading
        // stamped before it is taken.
        var readings: [(at: Date, undo: Bool)] = []
        var lookWithUndo: (low: String, top: String)?
        while Date() < deadline.addingTimeInterval(Self.watchPastDeadline) {
            let at = Date()
            let undo = hasUndo()
            readings.append((at: at, undo: undo))
            // Drawn once while at least a second of Undo is left: the fill is under 80% up.
            if undo, lookWithUndo == nil, at < deadline.addingTimeInterval(-1) { lookWithUndo = try drawn() }
            try await Task.sleep(for: Self.readInterval)
        }

        let undoBefore = readings.contains { $0.undo && $0.at < deadline }
        #expect(undoBefore, "control: Undo while the window lasts")
        let pastAllowance = readings.filter { $0.at >= deadline.addingTimeInterval(Self.displayAllowance) }
        #expect(!pastAllowance.isEmpty, "control: the bubble was read after the deadline")
        let lateUndo = pastAllowance.filter { $0.undo }.map { $0.at.timeIntervalSince(deadline) }
        #expect(lateUndo.isEmpty, "no Undo once the deadline has passed; seen this many seconds after it: \(lateUndo)")
        let sending = HostedAccessibility.labels(in: controller.view).contains { $0.contains("Sending") }
        #expect(sending, "the bubble still reads Sending")

        let before = try #require(lookWithUndo, "control: the bubble was drawn while Undo was offered")
        let lowBefore = reduceMotion ? "pending" : "solid"
        #expect(before.low == lowBefore, "control: with motion the fill has risen past the bottom; under Reduce Motion there is none")
        #expect(before.top == "pending", "control: the fill has not reached the top yet, so the top probe sees a partial fill")
        let after = try drawn()
        let expected = reduceMotion ? "pending" : "solid"
        #expect(after.low == expected && after.top == expected,
                "past the deadline, still queued: solid to the top with motion, pending under Reduce Motion")
    }

    @Test("In a mounted chat under Reduce Motion, the bubble turns solid when the outbox row records the send (observed from the database)")
    func mountedChatTurnsSolidWhenSent() async throws {
        #expect(HostedAccessibility.isAvailable && HostedAccessibility.canSetReduceMotion,
                "control: the test can read the chat and set Reduce Motion")
        try await HostedAccessibility.withAutomation { @MainActor in
            try await HostedAccessibility.withReduceMotion(true) { @MainActor in try await mountedSentBody() }
        }
    }

    private func mountedSentBody() async throws {
        #expect(UIAccessibility.isReduceMotionEnabled, "control: Reduce Motion is on")
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)
        let row = try await Self.queueReply(fixture, draftId: "draft-db-sent")
        try await Self.setHold(pool, row.id, Date().addingTimeInterval(3600))
        // The summary made at Send, which the bubble shows (`SentEmailSummary.textMessage`): the real
        // Send writes it to the AI cache under the row's Sent folder and Message-ID; this queue write,
        // with no text version, does not. The cache keeps a summary's text only with its blurb, as `SentEmailSummary` writes both.
        let sentMessageId = EmailFilter.normalizeMessageId(try #require(row.sentMessageId, "control: the queued row has its Message-ID"))
        try await pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.account, folderPath: "Sent", rfc822MessageId: sentMessageId,
                summaryBlurb: "Tuesday works.", summaryTextMessage: "I said Tuesday works.", db: db)
        }
        let key = try #require(
            MessageAICache.cacheKey(accountId: Self.account, folderPath: "Sent", rfc822MessageId: sentMessageId),
            "control: the summary's cache key")
        let cached = try await pool.read { db in try MessageAICache.fetchOne(db, key: key)?.summaryTextMessage }
        #expect(cached == "I said Tuesday works.", "control: the summary the bubble shows is cached before the chat mounts")
        let chat = try Self.host(fixture)
        defer { chat.close() }
        func drawn() throws -> String? {
            let view = chat.controller.view!
            guard let frame = Self.bubbleFrame(in: view) else { return nil }
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let pixel = Self.color(of: image, at: CGPoint(x: frame.minX + 1, y: frame.maxY - 1))
            if pixel.isClose(to: Palette.chatUndoSendPendingTint, in: view.traitCollection) { return "pending" }
            if pixel.isClose(to: Theme.accent, in: view.traitCollection) { return "solid" }
            return "other"
        }
        try await Self.waitFor { (try? drawn()) == "pending" }
        let bubble = Self.bubbleFrame(in: chat.controller.view)
        #expect(bubble != nil, "control: the chat shows the reply's bubble with its summary")
        #expect(try drawn() == "pending", "control: queued, the bubble is pending")

        // The provider took the email: the outbox row records it under the Message-ID it was queued
        // with, and stays (its Sent copy is not in the chat yet).
        let id = row.id
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?", arguments: [Date(), id])
        }
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) } != nil, "control: the row stays")
        try await Self.waitFor { (try? drawn()) == "solid" }
        #expect(try drawn() == "solid", "the chat observed the send: solid")
        #expect(chat.count("Sending") >= 1, "control: still the unsent reply's bubble, not yet the Sent copy")
    }

    @Test("A mounted toast-owned bubble gains its Undo, with its own deadline, when its toast is replaced, and keeps it across a third send")
    func mountedBubbleGainsUndoOnHandover() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { @MainActor in try await handoverBody() }
    }

    private func handoverBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            service.resetUndoOwnersForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)
        let reply = try await Self.queueReply(fixture, draftId: "draft-hand-reply")
        let second = try await Self.queueReply(fixture, draftId: "draft-hand-second", newEmail: true)
        let third = try await Self.queueReply(fixture, draftId: "draft-hand-third", newEmail: true)
        let undoLeft: TimeInterval = 30
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + undoLeft)
        try await Self.setHold(pool, reply.id, hold)
        // The reply was sent with the chat view off: its Undo is on the toast.
        service.present(outboxId: reply.id, draftId: "draft-hand-reply", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .toast)

        let chat = try Self.host(fixture)
        defer { chat.close() }
        try await Self.waitFor { chat.count("Sending") >= 1 }
        #expect(chat.count("Sending") >= 1, "control: the reply's bubble is mounted")
        #expect(!chat.hasUndo(), "the toast owns its Undo: none on the bubble")

        func undo() -> [(label: String?, value: String?)] {
            HostedAccessibility.labelsAndValues(of: ChatUndoSendStatus.undoId, in: chat.controller.view)
        }
        func secondsLeft() -> Int? {
            undo().first?.value.flatMap { Int($0.split(separator: " ").first ?? "") }
        }
        func fromOriginalDeadline() -> Bool {
            let expected = OutboxCancellationPolicy.undoDeadline(for: hold).timeIntervalSinceNow
            return secondsLeft().map { abs(Double($0) - expected) <= 1.5 } == true
        }

        // A second send's toast replaces the reply's: the mounted bubble takes the Undo.
        service.present(outboxId: second.id, draftId: "draft-hand-second", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold.addingTimeInterval(3), owner: .toast)
        try await Self.waitFor { chat.hasUndo() }
        #expect(undo().count == 1, "the mounted bubble now offers the one Undo")
        #expect(fromOriginalDeadline(), "counting down to the reply's own deadline")

        // A third send replaces the second's toast: the reply keeps its one Undo, same deadline.
        service.present(outboxId: third.id, draftId: "draft-hand-third", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold.addingTimeInterval(6), owner: .toast)
        try await Task.sleep(for: .milliseconds(300))
        #expect(undo().count == 1 && fromOriginalDeadline(), "still one Undo on the bubble, the reply's own deadline")
        #expect(service.undoOwner(for: reply.id) == .bubble && service.visibleToast?.id == third.id)
    }

    /// The app's wiring in small: a chat in a sheet that closes for an Undo's outcome (Search's
    /// `chatModalSheet`), under the one presenter of the reopen (RootView's `UndoReopenPresenter`).
    /// Hosted with the app's navigation store (`navigationStore(_:)`), which the reopened compose reads.
    private struct ChatInSheetHost: View {
        let messageId: String
        @State private var showsSheet = true

        var body: some View {
            Color.clear
                .chatModalSheet(isPresented: $showsSheet) {
                    NavigationStack { ChatThreadView(messageId: messageId) }
                }
                .modifier(UndoReopenPresenter())
                // RootView's own "Couldn't undo" host for a send.
                .background(UndoFailureAlertHost(source: .send))
        }
    }

    @Test("A refused Undo inside a sheet keeps the send, closes the sheet, and shows the Couldn't undo notice at the top level")
    func refusedUndoInsideASheetShowsTheNotice() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the bubble in the sheet")
        try await HostedAccessibility.withAutomation { @MainActor in try await refusedInSheetBody() }
    }

    private func refusedInSheetBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismissUndoFailure()
            service.dismiss()
            service.resetUndoOwnersForTesting()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        service.dismissUndoFailure()
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)
        let reply = try await Self.queueReply(fixture, draftId: "draft-refused-sheet")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, reply.id, hold)
        service.present(outboxId: reply.id, draftId: "draft-refused-sheet", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(
            rootView: ChatInSheetHost(messageId: fixture.parent.id).environment(Self.navigationStore(fixture)))
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        func hasUndo() -> Bool { HostedAccessibility.identifiers(in: window).contains(ChatUndoSendStatus.undoId) }
        func notice() -> UIAlertController? { window.rootViewController?.presentedViewController as? UIAlertController }

        try await Self.waitFor { hasUndo() }
        #expect(service.openChatModals == 1, "control: the chat is inside the open sheet")
        let refuser = UndoProviderIdentitySafetyTests.OutboxDeleteCommitRefuser()
        pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        #expect(HostedAccessibility.activate(ChatUndoSendStatus.undoId, in: window), "the bubble's Undo, inside the sheet")
        pool.remove(transactionObserver: refuser)
        #expect(refuser.refusals.withLock { $0 } == 1, "control: the cancellation commit was refused")
        #expect(try await pool.read { try OutboxMessage.fetchOne($0, key: reply.id) } != nil, "the send stays durable")

        try await Self.waitFor { notice() != nil }
        #expect(service.openChatModals == 0, "the sheet closed after the refusal")
        #expect(notice()?.title == "Couldn't undo", "RootView shows the notice at the top level")
        #expect(service.reopenQueue.isEmpty, "control: nothing reopens")
    }

    @Test("Undo from a chat inside a sheet closes the sheet and opens the email's compose at the top level, and a later reopen still opens")
    func undoInsideASheetReopensAtTheTop() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the bubble in the sheet")
        try await HostedAccessibility.withAutomation { @MainActor in try await undoInSheetBody() }
    }

    private func undoInSheetBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
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
        saved.setChatView(on: true)
        let fixture = try await Self.makeFixture(pool)
        let reply = try await Self.queueReply(fixture, draftId: "draft-in-sheet", body: "Words of the reply undone in Search")
        let later = try await Self.queueReply(fixture, draftId: "draft-later", newEmail: true, body: "Words of a later email")
        let hold = Date().addingTimeInterval(3600)
        try await Self.setHold(pool, reply.id, hold)
        try await Self.setHold(pool, later.id, hold)
        service.present(outboxId: reply.id, draftId: "draft-in-sheet", instanceEpoch: "E1",
                        toSummary: "To: sender@example.com", holdUntil: hold, owner: .bubble)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(
            rootView: ChatInSheetHost(messageId: fixture.parent.id).environment(Self.navigationStore(fixture)))
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        func hasUndo() -> Bool { HostedAccessibility.identifiers(in: window).contains(ChatUndoSendStatus.undoId) }
        func shows(_ words: String) -> Bool { Self.textViews(window).contains { $0.text.contains(words) } }

        try await Self.waitFor { hasUndo() }
        #expect(service.openChatModals == 1, "control: the chat is inside the open sheet")
        #expect(HostedAccessibility.activate(ChatUndoSendStatus.undoId, in: window), "the bubble's Undo, inside the sheet")
        try await Self.waitFor { shows("Words of the reply undone in Search") }
        #expect(shows("Words of the reply undone in Search"), "the compose opens with the email's words")
        #expect(service.openChatModals == 0, "the sheet closed first; the compose is at the top level")

        // Close that compose; a later Undo's reopen opens too: nothing waits behind a stuck head.
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        try await Self.waitFor { service.reopenSnapshot == nil }
        service.present(outboxId: later.id, draftId: "draft-later", instanceEpoch: "E1",
                        toSummary: "To: someone@example.com", holdUntil: hold, owner: .toast)
        service.undoAndReopen()
        try await Self.waitFor { shows("Words of a later email") }
        #expect(shows("Words of a later email"), "the later reopen opens")
    }

    /// The frame of the bubble's text element, in `view`'s coordinates.
    private static func bubbleFrame(in view: UIView) -> CGRect? {
        HostedAccessibility.elements(under: view)
            .first { ($0.accessibilityLabel ?? "").contains("Tuesday works") }
            .map { view.convert($0.accessibilityFrame, from: nil) }
    }

    private static func color(of image: UIImage, at point: CGPoint) -> UIColor {
        let scale = image.scale
        guard let cg = image.cgImage,
              let crop = cg.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)) else { return .clear }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
    }

    // MARK: - Fixture

    private struct Fixture {
        let pool: DatabasePool
        let parent: MessageHeader
        let account: Account
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
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: fixture.parent.id) }
            .environment(Self.navigationStore(fixture)))
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

    /// The names of the app's Swift files whose text contains `text`, sorted.
    private static func appSourceFiles(containing text: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("TabMail"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(text) }
            .map(\.lastPathComponent).sorted()
    }

    /// The navigation store the app puts at its root, holding the test account: a compose that
    /// opens reads it (its From field).
    private static func navigationStore(_ fixture: Fixture) -> NavigationStore {
        let store = NavigationStore()
        store.accounts = [fixture.account]
        return store
    }

    private static func makeFixture(_ pool: DatabasePool) async throws -> Fixture {
        let account = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
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
        return Fixture(pool: pool, parent: parent, account: account)
    }

    /// Queues a reply as the compose card does, with an undo hold, and returns its outbox row.
    private static func queueReply(
        _ fixture: Fixture, draftId: String, inReplyTo: String? = nil, newEmail: Bool = false, body: String = "Tuesday works"
    ) async throws -> OutboxMessage {
        try await fixture.pool.write { db in
            var draft = Draft(
                id: draftId, accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: body, replyToId: nil, isForward: false,
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

/// Shows, as its accessibility label, the Reduce Motion setting SwiftUI gives the views it hosts.
private struct ReduceMotionProbe: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("Reduce Motion probe").accessibilityLabel(Self.label(reduceMotion))
    }

    static func label(_ on: Bool) -> String {
        on ? "Reduce Motion probe: on" : "Reduce Motion probe: off"
    }
}

private extension UIColor {
    /// Whether this colour is `color` as resolved for `traits`, within rendering tolerance.
    func isClose(to color: Color, in traits: UITraitCollection) -> Bool {
        let expected = UIColor(color).resolvedColor(with: traits)
        var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), al: CGFloat(0))
        var b = a
        getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.al)
        expected.getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.al)
        let tolerance: CGFloat = 0.06
        return abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
    }
}
