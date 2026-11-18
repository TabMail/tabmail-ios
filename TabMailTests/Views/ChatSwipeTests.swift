/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 12: the chat's swipes.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A right swipe on a read bubble offers "Unread from here": it and every newer email become
///     unread, never the user's own; on an unread bubble "Read up to here": it and every older
///     email become read.
///  2. Afterwards the Unread line marks the emails unread then.
///  3. Archive, Delete and Move act on every email in the opened email's folder, once each.
///  4. In the inbox, Read on a collapsed chat reads the whole chat when the chat view is on; every
///     other case is today's single-email toggle.
///  5. A let-go swipe opens, closes, or (where allowed) runs the edge button, and a drag never
///     goes past closed or fully open. A drag the system cancels or fails closes and runs
///     nothing, however far it went.
///  6. With nothing open a reveal takes a drag toward its buttons, but a bubble leaves the screen's
///     left edge to the back swipe; while one is open only it takes drags, and the closer takes a
///     touch only outside it. Both back swipes wait for the pans. Real drags: ChatSwipeUITests.
///  7. The views wire each of these: hosted SwiftUI views cannot be driven from a unit test, so the
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
        #expect(text.contains("startsAtScreenEdge: atEdge) }, changed: changed, ended: ended))"),
                "the reveal hands the pan its drag, held under its id")
        #expect(text.contains("func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) { Self.handle(recognizer, holding: holdId, changed: changed, ended: ended) }"),
                "every recognizer event goes through `handle` (the freeze, ChatSwipeFreezeTests) and `deliver`")
        #expect(text.contains(".onDisappear { ChatSwipeHold.shared.releaseNow(id) }"))
    }

    @Test("The chat slides left for Trash then Archive, with a full swipe, acting on the whole chat; with no Inbox copy, Trash only and no full swipe")
    func chatSwipeWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(text.contains("let offersArchive = viewModel.chatHasInboxCopy"))
        #expect(text.contains("id: Self.chatSwipeId, edge: .trailing, buttons: chatSwipeButtons(offersArchive: offersArchive), allowsFullSwipe: offersArchive, openId: $openSwipeId"),
                "the full swipe runs only while Archive is at the edge")
        #expect(text.contains("actions: bubbleSwipeButtons(item, thread: thread) + chatSwipeButtons(offersArchive: offersArchive).map { button in ChatSwipeButton(title: \"\\(button.title) chat\", systemImage: button.systemImage, tint: button.tint, action: button.action) },"),
                "VoiceOver's actions are the swipe's buttons, on the bubble")
        // On the bubble itself, never on the whole row: actions on a view of several elements
        // reorder what VoiceOver reads in it (the bubble came between its own chips).
        let bubble = try Self.source("TabMail/Views/Chat/ChatBubbleView.swift")
        #expect(bubble.contains(".accessibilityAddTraits(.isButton) .accessibilityActions { ForEach(actions) { action in Button(action.title, action: action.action) } }"))
        #expect(!text.contains("allowsFullSwipe: false, openId: $openSwipeId)) .accessibilityActions"), "no actions on the whole row")
        let swipe = try Self.source("TabMail/Views/Chat/ChatSwipe.swift")
        #expect(!swipe.contains(".accessibilityActions"), "the reveal names no actions on what it slides")
        let buttons = try Self.body(of: "private func chatSwipeButtons(offersArchive: Bool) -> [ChatSwipeButton] {", in: text)
        // The inbox row's word for a move to Trash.
        let delete = try #require(buttons.range(of: "title: \"Trash\""))
        let archive = try #require(buttons.range(of: "title: \"Archive\""))
        #expect(delete.lowerBound < archive.lowerBound, "Archive sits at the edge, so a full swipe archives")
        #expect(buttons.contains("{ deleteChat() }"))
        #expect(buttons.contains("if offersArchive { buttons.append(ChatSwipeButton(title: \"Archive\", systemImage: \"archivebox\", tint: Theme.archive) { archiveChat() }) }"))
        let archiveBody = try Self.body(of: "private func archiveChat() {", in: text)
        #expect(archiveBody.contains("let moved = viewModel.archiveChat(viewModel.chatRows) if !moved.isEmpty { dismissChat(moved: moved, destinationFolderId: nil) }"))
        let deleteBody = try Self.body(of: "private func deleteChat() {", in: text)
        #expect(deleteBody.contains("let moved = viewModel.deleteChat(viewModel.chatRows) if !moved.isEmpty { dismissChat(moved: moved, destinationFolderId: nil) }"))
        let move = try Self.body(of: "private func moveChat(toFolderPath path: String) {", in: text)
        #expect(move.contains("let moved = viewModel.moveChat(viewModel.chatRows, toFolderPath: path) if !moved.isEmpty {"))
        #expect(move.contains("dismissChat(moved: moved, destinationFolderId: MessageIdentity.folderId(accountId: opened.accountId, folderPath: path))"))
        let dismissal = try Self.body(of: "private func dismissChat(moved: Set<String>, destinationFolderId: String?) {", in: text)
        #expect(dismissal.contains("if moved.contains(viewModel.messageId) { NotificationCenter.default.post( name: .messageDismissedFromDetail, object: viewModel.messageId"),
                "the list behind hides the opened row only if it moved")
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
        #expect(buttons.contains("{ guard TutorialCoordinator.shared.admits(.other) else { return } showsMove = true }"))
        // The tutorial's mail actions are off (owner 2026-10-21): every chat action asks it first.
        for signature in [
            "private func setRead(_ action: ChatSwipe.ReadAction, at item: ChatThread.Item, thread: ChatThread) {",
            "private func archiveChat() {",
            "private func deleteChat() {",
        ] {
            let body = try Self.body(of: signature, in: text)
            #expect(body.hasPrefix(" guard TutorialCoordinator.shared.admits(.other) else { return }"), "\(signature) asks the tutorial first")
        }
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

    @Test("A reveal's drag follows the one rule, from what is open and where it starts")
    func revealWiring() throws {
        let text = try Self.source("TabMail/Views/Chat/ChatSwipe.swift")
        #expect(text.contains("shouldBegin: { velocityX, atEdge in ChatSwipe.takesDrag(id: id, openId: open.id, sign: sign, velocityX: velocityX, startsAtScreenEdge: atEdge) },"))
        #expect(text.contains("return abs(velocity.x) > abs(velocity.y) && shouldBegin(velocity.x, startsAtScreenEdge)"),
                "a vertical drag stays the scroll view's")
        #expect(text.contains(".onDisappear { ChatSwipeHold.shared.releaseNow(id) open.left(id) }"),
                "a reveal whose view leaves the chat is no longer open")
        #expect(text.contains("Coordinator(shouldBegin: shouldBegin)") && text.contains("context.coordinator.shouldBegin = shouldBegin"),
                "the pan hands the rule to its coordinator when made and on every update")
        #expect(text.contains("if now != id, drag.offset != 0 { withAnimation(Self.spring) { drag.offset = 0 } }"))
    }

    // SwiftUI keeps a representable's recognizer outside the hosted view tree, so the pan is checked
    // where it is built, and the source shows the representable builds it that way.
    @Test("The swipe's pan asks its coordinator before it starts, so a vertical drag stays the scroll view's")
    func panAsksItsCoordinator() throws {
        var asked: [CGFloat] = []
        let coordinator = ChatHorizontalPan.Coordinator(shouldBegin: { velocity, _ in asked.append(velocity); return true })
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

    @Test("A sideways drag starts the swipe unless the rule declines it; an upright drag never asks")
    func panAdmitsSidewaysMotion() {
        var asked: [CGFloat] = []
        var answer = true
        let coordinator = ChatHorizontalPan.Coordinator(shouldBegin: { velocity, _ in asked.append(velocity); return answer })
        let pan = MovingPan()
        pan.delegate = coordinator

        for given in [true, false] {
            answer = given
            asked.removeAll()
            pan.speed = CGPoint(x: -120, y: 4)
            #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == given, "\(given)")
            #expect(asked == [-120], "the rule is asked with the drag's sideways speed")
        }

        answer = true
        asked.removeAll()
        for speed in [CGPoint(x: -4, y: 120), CGPoint(x: -40, y: 40)] {
            pan.speed = speed
            #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false, "not sideways enough: \(speed)")
        }
        #expect(asked.isEmpty, "an upright drag never reaches the rule")
    }

    @Test("A drag starts in the back swipe's zone only within the configured width of the screen's left edge")
    func screenEdgeZone() {
        let width = ChatViewLayout.backSwipeEdgeWidth
        #expect(width > 0)
        #expect(ChatHorizontalPan.Coordinator.startsAtScreenEdge(0))
        #expect(ChatHorizontalPan.Coordinator.startsAtScreenEdge(width))
        #expect(!ChatHorizontalPan.Coordinator.startsAtScreenEdge(width + 1))
    }

    // MARK: - Which pan takes a drag

    @Test("With nothing open, a reveal takes a drag toward its buttons; a bubble leaves the screen's left edge to the back swipe")
    func nothingOpen() {
        // A bubble opens rightward, the whole chat leftward.
        #expect(ChatSwipe.takesDrag(id: "b", openId: nil, sign: 1, velocityX: 300, startsAtScreenEdge: false))
        #expect(!ChatSwipe.takesDrag(id: "b", openId: nil, sign: 1, velocityX: 300, startsAtScreenEdge: true))
        #expect(!ChatSwipe.takesDrag(id: "b", openId: nil, sign: 1, velocityX: -300, startsAtScreenEdge: false))
        #expect(ChatSwipe.takesDrag(id: "chat", openId: nil, sign: -1, velocityX: -300, startsAtScreenEdge: false))
        #expect(!ChatSwipe.takesDrag(id: "chat", openId: nil, sign: -1, velocityX: 300, startsAtScreenEdge: false))
    }

    @Test("While a reveal is open only it takes drags, either way; every other reveal lets them go to the closer")
    func onlyTheOpenRevealTakesDrags() {
        for velocity in [CGFloat(300), -300] {
            for edge in [false, true] {
                #expect(ChatSwipe.takesDrag(id: "b", openId: "b", sign: 1, velocityX: velocity, startsAtScreenEdge: edge))
                #expect(!ChatSwipe.takesDrag(id: "other", openId: "b", sign: 1, velocityX: velocity, startsAtScreenEdge: edge))
                #expect(!ChatSwipe.takesDrag(id: "chat", openId: "b", sign: -1, velocityX: velocity, startsAtScreenEdge: edge))
            }
        }
    }

    @Test("What is open: one reveal, its frame and buttons; it closes, moves with its reveal, and clears when its view leaves")
    func openState() {
        let open = ChatSwipeOpen()
        let row = CGRect(x: 0, y: 100, width: 300, height: 50)
        let strip = CGRect(x: 0, y: 100, width: 80, height: 50)
        #expect(open.id == nil && !open.ownsDrag(.zero) && !open.ownsTap(.zero))
        open.open("b", frame: row, buttons: strip)
        #expect(open.id == "b" && open.ownsDrag(CGPoint(x: 200, y: 120)) && !open.ownsDrag(CGPoint(x: 10, y: 200)))
        #expect(open.ownsTap(CGPoint(x: 10, y: 120)), "its buttons stay tappable")
        #expect(!open.ownsTap(CGPoint(x: 200, y: 120)), "a tap on its own content only closes it")
        open.moved("other", frame: .zero, buttons: .zero)
        #expect(open.ownsDrag(CGPoint(x: 200, y: 120)), "another reveal's move changes nothing")
        open.moved("b", frame: row.offsetBy(dx: 0, dy: 80), buttons: strip.offsetBy(dx: 0, dy: 80))
        #expect(open.ownsDrag(CGPoint(x: 200, y: 200)) && !open.ownsDrag(CGPoint(x: 200, y: 120)), "the open one's frame follows it")
        #expect(open.ownsTap(CGPoint(x: 10, y: 200)))
        open.left("other")
        #expect(open.id == "b", "another view leaving changes nothing")
        open.left("b")
        #expect(open.id == nil && !open.ownsDrag(CGPoint(x: 200, y: 200)), "its view left: nothing is open")
        open.open("b", frame: .zero, buttons: .zero)
        open.close()
        #expect(open.id == nil)
    }

    @Test("Under the header or the reply field nothing is the open reveal's, though its frame runs under them")
    func openRevealOnlyWhereATouchReachesIt() {
        let open = ChatSwipeOpen()
        // The whole chat open: its frame is the scroll view, under the header and the reply field.
        open.open("chat", frame: CGRect(x: 0, y: 0, width: 400, height: 800),
                  buttons: CGRect(x: 240, y: 0, width: 160, height: 800))
        open.reach(top: 120, bottom: 700)
        for y: CGFloat in [10, 119, 700, 790] {
            #expect(!open.ownsDrag(CGPoint(x: 100, y: y)), "the header and the reply field are never the chat's")
            #expect(!open.ownsTap(CGPoint(x: 300, y: y)))
        }
        #expect(open.ownsDrag(CGPoint(x: 100, y: 400)))
        #expect(open.ownsTap(CGPoint(x: 300, y: 400)))
        #expect(!open.ownsTap(CGPoint(x: 100, y: 400)), "a tap on a bubble while the chat is open only closes")
    }

    /// A touch at a set point, as UIKit hands it to `shouldReceive`.
    private final class PlacedTouch: UITouch {
        var point = CGPoint.zero
        var readIn: UIView?
        override func location(in view: UIView?) -> CGPoint { readIn = view; return point }
    }

    @Test("The closer takes a touch only while something is open and only where it is not the open reveal's, read in its anchor")
    func closerTakesOnlyTouchesOutsideTheOpenReveal() throws {
        let (nav, window) = try Self.pushedChat()
        defer { window.isHidden = true }
        let open = ChatSwipeOpen()
        let closer = ChatSwipeCloser.Coordinator(open: open)
        let anchor = ChatSwipeCloser.Anchor()
        anchor.coordinator = closer
        try #require(nav.topViewController).view.addSubview(anchor)
        let touch = PlacedTouch()
        touch.point = CGPoint(x: 200, y: 400)
        for recognizer in [closer.pan, closer.tap] as [UIGestureRecognizer] {
            #expect(!closer.gestureRecognizer(recognizer, shouldReceive: touch), "nothing open: the chat works as before")
            #expect(!closer.gestureRecognizerShouldBegin(recognizer))
        }
        open.open("b", frame: CGRect(x: 0, y: 100, width: 300, height: 50), buttons: CGRect(x: 0, y: 100, width: 80, height: 50))
        #expect(closer.gestureRecognizer(closer.tap, shouldReceive: touch), "a touch elsewhere is the closer's")
        #expect(touch.readIn === anchor, "read in the space the frames are measured in")
        #expect(closer.gestureRecognizerShouldBegin(closer.tap))
        touch.point = CGPoint(x: 200, y: 120)
        #expect(!closer.gestureRecognizer(closer.pan, shouldReceive: touch), "a drag on the open reveal continues it")
        #expect(closer.gestureRecognizer(closer.tap, shouldReceive: touch), "a tap on its content only closes")
        touch.point = CGPoint(x: 10, y: 120)
        #expect(!closer.gestureRecognizer(closer.tap, shouldReceive: touch), "its buttons stay tappable")
        let other = UIPanGestureRecognizer()
        #expect(closer.gestureRecognizer(closer.pan, shouldBeRequiredToFailBy: other), "another recognizer waits for the closer")
        #expect(!closer.gestureRecognizer(closer.pan, shouldBeRequiredToFailBy: closer.tap))
        #expect(!closer.gestureRecognizer(closer.pan, shouldRecognizeSimultaneouslyWith: other))
    }

    @Test("The closer installs on the navigation controller's own view, the bar included; the edge back swipe is off only while something is open")
    func closerCoversTheWholeScreen() throws {
        let (nav, window) = try Self.pushedChat()
        defer { window.isHidden = true }
        let open = ChatSwipeOpen()
        let closer = ChatSwipeCloser.Coordinator(open: open)
        let anchor = ChatSwipeCloser.Anchor()
        anchor.coordinator = closer
        let edgePop = try #require(nav.interactivePopGestureRecognizer)
        try #require(nav.topViewController).view.addSubview(anchor)
        #expect(closer.pan.view === nav.view && closer.tap.view === nav.view, "on the view that holds the bar and the chat")
        #expect(edgePop.isEnabled, "nothing open: the edge back swipe works")
        open.open("b", frame: .zero, buttons: .zero)
        #expect(!edgePop.isEnabled, "something open: an edge drag only closes it")
        open.close()
        #expect(edgePop.isEnabled, "closed: the next edge drag goes back")
        open.open("b", frame: .zero, buttons: .zero)
        anchor.removeFromSuperview()
        #expect(closer.pan.view == nil && closer.tap.view == nil, "gone with the chat")
        #expect(edgePop.isEnabled, "and the edge back swipe is back on")
    }

    // MARK: - The back swipes wait for the rule

    /// A real navigation controller with a pushed screen, on screen, so its back swipes are live.
    /// `presented`: the pushed chat lives in a second navigation controller presented as a sheet
    /// over the first (search opens chats that way).
    private static func pushedChat(presented: Bool = false) throws -> (nav: UINavigationController, window: UIWindow) {
        let root = UINavigationController(rootViewController: UIViewController())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        var nav = root
        if presented {
            nav = UINavigationController(rootViewController: UIViewController())
            root.present(nav, animated: false)
        }
        nav.pushViewController(UIViewController(), animated: false)
        nav.view.layoutIfNeeded()
        return (nav, window)
    }

    /// The swipe's pan as `ChatSwipeReveal` builds it, kept alive by the returned coordinator (a
    /// recognizer holds its delegate weakly). It is attached to no UIKit view, as SwiftUI may host it.
    private static func pan() -> (UIPanGestureRecognizer, ChatHorizontalPan.Coordinator) {
        let coordinator = ChatHorizontalPan.Coordinator(shouldBegin: { _, _ in true })
        return (ChatHorizontalPan.makePan(delegate: coordinator), coordinator)
    }

    // UIKit arbitrates two recognizers on a touch by asking their delegates these questions; a unit
    // test cannot make a real touch, so it asks them about the real navigation controller's own
    // back-swipe recognizers. A device check covers the gesture itself.
    @Test("Both back swipes wait for a chat drag's decision and never run with it; nothing else changes",
          arguments: [false, true])
    func backSwipesWaitForTheRule(presented: Bool) throws {
        let (nav, window) = try Self.pushedChat(presented: presented)
        defer { nav.presentingViewController?.dismiss(animated: false); window.isHidden = true }
        let (pan, coordinator) = Self.pan()
        let contentPop = try #require(nav.interactiveContentPopGestureRecognizer)
        let edgePop = try #require(nav.interactivePopGestureRecognizer)
        if presented {
            #expect(nav.presentingViewController != nil && nav.view.window != nil, "control: the second stack is presented, on screen")
        }
        let popDelegates = (contentPop.delegate, edgePop.delegate)
        for pop in [contentPop, edgePop] {
            #expect(coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: pop) == false, "\(pop)")
            #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: pop) == true, "\(pop)")
        }
        // The chat's scroll, inside the pushed screen as in the app; a recognizer outside any
        // navigation controller; and one on no view: none waits for the swipe.
        let scroll = UIScrollView()
        try #require(nav.topViewController).view.addSubview(scroll)
        let loose = UIView()
        let looseWindow = UIWindow(windowScene: try #require(window.windowScene))
        looseWindow.addSubview(loose)
        let looseTap = UITapGestureRecognizer()
        loose.addGestureRecognizer(looseTap)
        for other in [scroll.panGestureRecognizer, looseTap, UIPanGestureRecognizer()] {
            #expect(coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: other) == false,
                    "a swipe runs alone, so a tap never also opens the bubble's card: \(other)")
            #expect(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: other) == false, "never waits for the swipe: \(other)")
        }
        #expect(contentPop.isEnabled && edgePop.isEnabled, "both back swipes stay on")
        #expect(contentPop.delegate === popDelegates.0 && edgePop.delegate === popDelegates.1, "they keep their own delegates")
    }

}
