/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-103: the chat's swipes (S1.2 to S4).
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A right swipe on a read bubble offers "Unread from here": it and every newer email become
///     unread, never the user's own; on an unread bubble "Read up to here": it and every older
///     email become read (S3.1).
///  2. Afterwards the Unread line marks the emails unread then (S4.1).
///  3. Archive, Delete and Move act on every email in the opened email's folder, once each (S2.1).
///  4. In the inbox, Read on a collapsed chat reads the whole chat when the chat view is on; every
///     other case is today's single-email toggle (S1.2).
///  5. A let-go swipe opens, closes, or (where allowed) runs the edge button, and a drag never
///     goes past closed or fully open. A drag the system cancels or fails closes and runs
///     nothing, however far it went.
///  6. The views wire each of these: hosted SwiftUI views cannot be driven from a unit test, so the
///     wiring is read from the source.
@Suite("Chat swipes")
@MainActor
struct ChatSwipeTests {
    private static let me = "me@example.com"
    private static let now = Date()

    private static func header(
        _ uid: String, fromAddress: String = "alex@example.com", minutesAgo: Double,
        isRead: Bool, folder: String = "INBOX"
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Alex Doe", fromAddress: fromAddress,
            to: me, date: now.addingTimeInterval(-minutesAgo * 60), snippet: "snippet \(uid)",
            folderId: "acc1:\(folder)", accountId: "acc1", folderPath: folder, isInInbox: folder == "INBOX")
        header.rfc822MessageId = "<\(uid)@example.com>"
        header.isRead = isRead
        return header
    }

    private static func items(_ members: [MessageHeader]) -> [ChatThread.Item] {
        ChatThread(
            members: members, replyAddresses: { [$0.fromAddress] }, ownAddresses: [me],
            draftFolderIds: [], sentFolderIds: ["acc1:Sent"], unreadAtOpen: [], preferredId: nil
        ).items
    }

    /// Oldest first: read, own (read), read, unread, read.
    private static let thread: [ChatThread.Item] = items([
        header("1", minutesAgo: 50, isRead: true),
        header("2", fromAddress: me, minutesAgo: 40, isRead: true, folder: "Sent"),
        header("3", minutesAgo: 30, isRead: true),
        header("4", minutesAgo: 20, isRead: false),
        header("5", minutesAgo: 10, isRead: true),
    ])

    private static func uids(_ headers: [MessageHeader]) -> [String] { headers.map(\.messageId) }

    // MARK: - 1. Unread from here, Read up to here

    @Test("A read bubble offers Unread from here, an unread one Read up to here")
    func readAction() {
        #expect(ChatSwipe.ReadAction(for: Self.thread[0].header) == .unreadFromHere)
        #expect(ChatSwipe.ReadAction(for: Self.thread[3].header) == .readUpToHere)
        #expect(ChatSwipe.ReadAction.unreadFromHere.title == "Unread from here")
        #expect(ChatSwipe.ReadAction.readUpToHere.title == "Read up to here")
        #expect(ChatSwipe.ReadAction.unreadFromHere.isRead == false)
        #expect(ChatSwipe.ReadAction.readUpToHere.isRead == true)
    }

    @Test("Unread from here takes this email and every newer one still read, never the user's own")
    func unreadFromHere() {
        let ids = Self.thread.map(\.id)
        #expect(Self.uids(ChatSwipe.readTargets(.unreadFromHere, at: ids[0], in: Self.thread)) == ["1", "3", "5"],
                "own email 2 and already-unread 4 are left alone")
        #expect(Self.uids(ChatSwipe.readTargets(.unreadFromHere, at: ids[2], in: Self.thread)) == ["3", "5"],
                "older emails stay read")
        #expect(ChatSwipe.readTargets(.unreadFromHere, at: "missing", in: Self.thread).isEmpty)
    }

    @Test("Read up to here takes this email and every older one still unread")
    func readUpToHere() {
        let older = Self.items([
            Self.header("1", minutesAgo: 30, isRead: false),
            Self.header("2", minutesAgo: 20, isRead: true),
            Self.header("3", minutesAgo: 10, isRead: false),
            Self.header("4", minutesAgo: 5, isRead: false),
        ])
        #expect(Self.uids(ChatSwipe.readTargets(.readUpToHere, at: older[2].id, in: older)) == ["1", "3"],
                "newer email 4 stays unread")
    }

    // MARK: - 2. The Unread line

    @Test("After Unread from here the line marks the emails it made unread and any still unread")
    func unreadLineAfterUnread() {
        let ids = Self.thread.map(\.id)
        let targets = ChatSwipe.readTargets(.unreadFromHere, at: ids[2], in: Self.thread)
        #expect(ChatSwipe.unreadIds(after: .unreadFromHere, targets: targets, items: Self.thread)
                == [ids[2], ids[3], ids[4]])
    }

    @Test("After Read up to here the line leaves the emails it read")
    func unreadLineAfterRead() {
        let ids = Self.thread.map(\.id)
        let targets = ChatSwipe.readTargets(.readUpToHere, at: ids[3], in: Self.thread)
        #expect(ChatSwipe.unreadIds(after: .readUpToHere, targets: targets, items: Self.thread).isEmpty)
    }

    // MARK: - 3. Whole-chat actions

    // The emails a whole-chat action takes are pinned by their effect in
    // `MessageDetailThreadActionTests` (several folders, one Undo).

    // MARK: - 4. The inbox row

    @Test("Read on a collapsed chat reads every email only with the chat view on")
    func inboxRead() {
        let ids = ["a", "b"]
        #expect(ChatSwipe.inboxReadIds(rowIsRead: false, memberIds: ids, collapsedThread: true, chatActive: true) == ids)
        #expect(ChatSwipe.inboxReadIds(rowIsRead: true, memberIds: ids, collapsedThread: true, chatActive: true) == nil,
                "Unread stays on the newest email")
        #expect(ChatSwipe.inboxReadIds(rowIsRead: false, memberIds: ids, collapsedThread: false, chatActive: true) == nil)
        #expect(ChatSwipe.inboxReadIds(rowIsRead: false, memberIds: ids, collapsedThread: true, chatActive: false) == nil)
    }

    // MARK: - 5. Letting go

    private static let reveal: CGFloat = 2 * ChatViewLayout.swipeButtonWidth
    private static let width: CGFloat = 400

    private static func settle(_ offset: CGFloat, velocity: CGFloat = 0, sign: CGFloat = -1,
                               allowsFull: Bool = true, finished: Bool = true) -> ChatSwipe.Settle {
        ChatSwipe.settle(offset: offset, velocity: velocity, sign: sign, revealWidth: reveal,
                         width: width, allowsFull: allowsFull, finished: finished)
    }

    @Test("A let-go swipe opens past half its buttons, closes short of that, and runs the edge button past the full-swipe line")
    func settleByDistance() {
        let half = Self.reveal / 2
        let full = Self.width * ChatViewLayout.swipeFullFraction
        #expect(Self.settle(-(half - 1)) == .closed)
        #expect(Self.settle(-(half + 1)) == .open)
        #expect(Self.settle(-(full - 1)) == .open)
        #expect(Self.settle(-(full + 1)) == .full)
        #expect(Self.settle(-(full + 1), allowsFull: false) == .open, "a bubble has no full swipe")
        #expect(Self.settle(full + 1, sign: 1) == .full, "a right swipe opens the other way")
        #expect(Self.settle(full + 1) == .closed, "the wrong way never opens")
    }

    @Test("A flick opens or closes whatever the distance")
    func settleByFlick() {
        let flick = ChatViewLayout.swipeFlickVelocity + 1
        #expect(Self.settle(-1, velocity: -flick) == .open)
        #expect(Self.settle(-Self.reveal, velocity: flick) == .closed)
        #expect(Self.settle(-1, velocity: -(flick - 2)) == .closed)
        #expect(Self.settle(0, velocity: -flick) == .closed, "no distance, nothing to open")
    }

    @Test("A drag the system cancels or fails closes and runs nothing, however far it went")
    func interruptedDragRunsNothing() {
        let full = Self.width * ChatViewLayout.swipeFullFraction
        let flick = ChatViewLayout.swipeFlickVelocity + 1
        #expect(Self.settle(-(full + 1)) == .full, "control: the same drag, finished, runs the edge button")
        #expect(Self.settle(-(full + 1), finished: false) == .closed)
        #expect(Self.settle(-Self.reveal, finished: false) == .closed, "nor does it stay open")
        #expect(Self.settle(-1, velocity: -flick, finished: false) == .closed)

        #expect(ChatHorizontalPan.finished(.ended) == true)
        #expect(ChatHorizontalPan.finished(.cancelled) == false)
        #expect(ChatHorizontalPan.finished(.failed) == false)
        for moving in [UIGestureRecognizer.State.possible, .began, .changed] {
            #expect(ChatHorizontalPan.finished(moving) == nil, "still moving")
        }
    }

    @Test("A drag stays between closed and fully open")
    func clamp() {
        #expect(ChatSwipe.clamp(-1000, sign: -1, revealWidth: Self.reveal, width: Self.width, allowsFull: true) == -Self.width)
        #expect(ChatSwipe.clamp(-1000, sign: -1, revealWidth: Self.reveal, width: Self.width, allowsFull: false) == -Self.reveal)
        #expect(ChatSwipe.clamp(50, sign: -1, revealWidth: Self.reveal, width: Self.width, allowsFull: true) == 0)
        #expect(ChatSwipe.clamp(-40, sign: -1, revealWidth: Self.reveal, width: Self.width, allowsFull: true) == -40)
        #expect(ChatSwipe.clamp(40, sign: 1, revealWidth: Self.reveal, width: Self.width, allowsFull: false) == 40)
    }

    /// A pan whose event the test sets: UIKit's own recognizer type, as the swipe receives it.
    private final class DeliveredPan: UIPanGestureRecognizer {
        var event: UIGestureRecognizer.State = .possible
        var travel: CGFloat = 0
        var speed: CGFloat = 0
        override var state: UIGestureRecognizer.State {
            get { event }
            set { event = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: travel, y: 7) }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: speed, y: 9) }
    }

    @Test("A pan's events move the reveal by the drag's travel since it began, and its let-go settles it")
    func deliveredPanMovesTheReveal() {
        let pan = DeliveredPan()
        var drag = ChatSwipeDrag()
        var settled: [ChatSwipe.Settle] = []
        func send(_ state: UIGestureRecognizer.State, travel: CGFloat = 0, speed: CGFloat = 0) {
            pan.event = state
            pan.travel = travel
            pan.speed = speed
            ChatHorizontalPan.deliver(pan, changed: {
                drag.moved($0, sign: -1, revealWidth: Self.reveal, width: Self.width, allowsFull: true)
            }, ended: {
                settled.append(drag.letGo(velocity: $0, finished: $1, sign: -1, revealWidth: Self.reveal,
                                          width: Self.width, allowsFull: true))
            })
        }

        send(.possible, travel: -50)
        #expect(drag.offset == 0 && settled.isEmpty, "not a drag yet")
        send(.began, travel: -10)
        #expect(drag.offset == -10)
        send(.changed, travel: -Self.reveal * 0.75)
        #expect(drag.offset == -Self.reveal * 0.75, "the travel since the drag began, not added up")
        send(.ended, speed: 0)
        #expect(settled == [.open], "past half the buttons, let go: open")

        drag.offset = -Self.reveal  // the reveal springs open
        send(.began, travel: 5)
        #expect(drag.offset == -Self.reveal + 5, "the next drag starts where the reveal sits")
        send(.changed, travel: Self.reveal * 2)
        #expect(drag.offset == 0, "dragged shut, never past closed")
        send(.changed, travel: -Self.width)
        #expect(drag.offset == -Self.width, "back past the full-swipe line")
        send(.cancelled, speed: -(ChatViewLayout.swipeFlickVelocity + 1))
        #expect(settled.last == .closed, "the system cancelled it: closed, however far it went")

        drag.offset = 0
        send(.began, travel: -1)
        send(.changed, travel: -Self.width)
        #expect(drag.offset == -Self.width)
        send(.ended, speed: -10)
        #expect(settled.last == .full, "past the full-swipe line: the edge button runs")
        #expect(settled.count == 3, "one settle per let-go")
    }

    // MARK: - 6. Wiring

    private static func source(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature))
        let end = try #require(text[start.upperBound...].range(of: " private "))
        return String(text[start.upperBound..<end.lowerBound])
    }

    @Test("The reveal settles with whether the recognizer finished the drag")
    func interruptedDragWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatSwipe.swift")
        let ended = try Self.body(of: "private func ended(_ velocity: CGFloat, finished: Bool) {", in: text)
        #expect(ended.contains("switch drag.letGo(velocity: velocity, finished: finished, sign: sign, revealWidth: revealWidth, width: width, allowsFull: allowsFullSwipe) {"))
        let changed = try Self.body(of: "private func changed(_ translation: CGFloat) {", in: text)
        #expect(changed.contains("drag.moved(translation, sign: sign, revealWidth: revealWidth, width: width, allowsFull: allowsFullSwipe)"))
        #expect(text.contains("changed: changed, ended: ended))"), "the reveal hands the pan its drag")
        #expect(text.contains("func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) { Self.deliver(recognizer, changed: changed, ended: ended) }"),
                "every recognizer event goes through `deliver`")
    }

    @Test("The chat slides left for Delete then Archive, with a full swipe, acting on the whole chat")
    func chatSwipeWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(text.contains("id: Self.chatSwipeId, edge: .trailing, buttons: chatSwipeButtons, allowsFullSwipe: true, openId: $openSwipeId"))
        let buttons = try Self.body(of: "private var chatSwipeButtons: [ChatSwipeButton] {", in: text)
        let delete = try #require(buttons.range(of: "title: \"Delete\""))
        let archive = try #require(buttons.range(of: "title: \"Archive\""))
        #expect(delete.lowerBound < archive.lowerBound, "Archive sits at the edge, so a full swipe archives")
        #expect(buttons.contains("{ deleteChat() }"))
        #expect(buttons.contains("{ archiveChat() }"))
        #expect(try Self.body(of: "private func archiveChat() {", in: text)
            .contains("if viewModel.archiveChat(members) { dismissChat(destinationFolderId: nil) }"))
        #expect(try Self.body(of: "private func deleteChat() {", in: text)
            .contains("if viewModel.deleteChat(members) { dismissChat(destinationFolderId: nil) }"))
        let move = try Self.body(of: "private func moveChat(toFolderPath path: String) {", in: text)
        #expect(move.contains("if viewModel.moveChat(members, toFolderPath: path) {"))
        #expect(move.contains("dismissChat(destinationFolderId: MessageIdentity.folderId(accountId: opened.accountId, folderPath: path))"))
        let dismissal = try Self.body(of: "private func dismissChat(destinationFolderId: String?) {", in: text)
        #expect(dismissal.contains("name: .messageDismissedFromDetail, object: viewModel.messageId"))
        #expect(dismissal.contains("dismiss()"))
    }

    @Test("A bubble slides right for its read action and Move, and the read action moves the Unread line")
    func bubbleSwipeWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(text.contains("id: item.id, edge: .leading, buttons: bubbleSwipeButtons(item, thread: thread), allowsFullSwipe: false, openId: $openSwipeId"))
        let buttons = try Self.body(of: "private func bubbleSwipeButtons(_ item: ChatThread.Item, thread: ChatThread) -> [ChatSwipeButton] {", in: text)
        #expect(buttons.contains("let action = ChatSwipe.ReadAction(for: item.header)"))
        #expect(buttons.contains("setRead(action, at: item, thread: thread)"))
        #expect(buttons.contains("title: \"Move\""))
        #expect(buttons.contains("{ showsMove = true }"))
        let read = try Self.body(of: "private func setRead(_ action: ChatSwipe.ReadAction, at item: ChatThread.Item, thread: ChatThread) {", in: text)
        #expect(read.contains("let targets = ChatSwipe.readTargets(action, at: item.id, in: thread.items)"))
        #expect(read.contains("viewModel.setRead(targets, isRead: action.isRead)"))
        #expect(read.contains("unreadAtOpen = ChatSwipe.unreadIds(after: action, targets: targets, items: thread.items)"))
        #expect(text.contains("MoveFolderPicker(accountId: opened.accountId, currentFolderPath: opened.folderPath) { path in moveChat(toFolderPath: path) }"))
        #expect(text.contains("|| showsMove"), "the move sheet pauses the detail like every presentation")
    }

    @Test("The inbox's Read on a collapsed chat goes through the chat rule")
    func inboxReadWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        #expect(text.contains("if let ids = ChatSwipe.inboxReadIds( rowIsRead: snapshot.isRead, memberIds: group.members.map(\\.id), collapsedThread: group.isThread && !isExpanded, chatActive: ChatViewConfig.isActive) { viewModel.markRead(ids) } else { viewModel.toggleRead(snapshot.id) }"))
    }

    @Test("A reveal opens only toward its buttons, and only while no other reveal is open")
    func revealWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatSwipe.swift")
        #expect(text.contains("shouldBegin: { velocityX in openId == id || (openId == nil && velocityX * sign > 0) }"))
        #expect(text.contains("return abs(velocity.x) > abs(velocity.y) && shouldBegin(velocity.x)"),
                "a vertical drag stays the scroll view's")
        #expect(text.contains("if now != id, drag.offset != 0 { withAnimation(Self.spring) { drag.offset = 0 } }"))
    }

    // SwiftUI keeps a representable's recognizer outside the hosted view tree, so the pan is checked
    // where it is built, and the source shows the representable builds it that way.
    @Test("The swipe's pan asks its coordinator before it starts, so a vertical drag stays the scroll view's")
    func panAsksItsCoordinator() throws {
        var asked: [CGFloat] = []
        let coordinator = ChatHorizontalPan.Coordinator(shouldBegin: { asked.append($0); return true })
        let pan = ChatHorizontalPan.makePan(delegate: coordinator)
        #expect(pan.delegate === coordinator)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false,
                "a drag with no sideways speed does not start the swipe")
        #expect(asked.isEmpty, "a drag that is not sideways never reaches the chat's own check")

        let text = try Self.source("TabMail/Views/Chat/ChatSwipe.swift")
        #expect(text.contains("func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer { Self.makePan(delegate: context.coordinator) }"))
    }

    /// A pan whose speed the test sets, as UIKit reports it to the delegate before the pan starts.
    private final class MovingPan: UIPanGestureRecognizer {
        var speed = CGPoint.zero
        override func velocity(in view: UIView?) -> CGPoint { speed }
    }

    @Test("A sideways drag starts the swipe when the chat's check allows its direction; an upright drag never asks")
    func panAdmitsSidewaysMotion() {
        var asked: [CGFloat] = []
        // The chat's own check: here, only a drag toward the leading edge opens buttons.
        let coordinator = ChatHorizontalPan.Coordinator(shouldBegin: { asked.append($0); return $0 < 0 })
        let pan = MovingPan()
        pan.delegate = coordinator

        pan.speed = CGPoint(x: -120, y: 4)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true, "a sideways drag in an allowed direction starts")
        #expect(asked == [-120], "the chat's check is asked with the drag's sideways speed")

        asked.removeAll()
        pan.speed = CGPoint(x: 120, y: 4)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false, "the chat's check refuses this direction")
        #expect(asked == [120])

        asked.removeAll()
        pan.speed = CGPoint(x: -4, y: 120)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false, "an upright drag stays the scroll view's")
        #expect(asked.isEmpty, "an upright drag never reaches the chat's check")

        pan.speed = CGPoint(x: -40, y: 40)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false, "a drag no more sideways than upright does not start")
        #expect(asked.isEmpty)
    }
}
