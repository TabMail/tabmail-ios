/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Dispatch
import Foundation
import GRDB
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-103 decision 9: the chat screen, opened for real in a window.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The first scroll lands where the open asks: the bottom when every email is read, the Unread
///     line when some are not, the opened email when it came from search or a notification.
///  2. Every email of the thread is marked read in the database once the chat shows it (Q21).
///  3. The chat asks summaries only for the emails on screen and the `ChatViewConfig.summaryWindow`
///     older than the oldest of them, on screen first: the rest of a long thread waits. When a
///     scroll stops, the emails then on screen go to the front. Only a hand scroll widens the
///     window to `summaryWindow` both ways (`ChatSummaryWindow.userMoved`, unit-tested: a test
///     cannot drag a finger), so the chat's own scrolls keep the open window. A layout change
///     with no scroll at all (the screen shrinks) asks again for the emails then on screen.
///  4. At the bottom, the newest bubble stays above the reply field however tall the field grows:
///     a six-line ready AI Reply raises the thread's bottom by as much as it raises the field.
///  5. A context load that a newer member change cancelled never shows: the chat keeps the newer
///     load's accounts and attachment chips when the older read finally returns.
///  6. (The Sending bubble of a reply sent from the chat: `ChatSendingBubbleTests`.)
///  7. No AI Reply is offered on the user's turn (owner 2026-11-07): from the moment a reply is
///     sent from the chat, the field holds no suggestion, whether or not the sent email has
///     arrived (offline it may not for long), until an email from someone else arrives; that
///     email's own AI Reply then shows.
///
/// What is on screen is read back from the summary queue, whose front is the latest request:
/// the newest email on screen, then the rest of the screen, then the older ones.
@Suite("Chat screen at run time", .serialized, .processGlobalState)
@MainActor
struct ChatThreadViewLifecycleTests {
    private static let account = "acc-chat-life"
    private static let length = 40

    private static func rfc(_ index: Int) -> String { "<life-\(index)@example.com>" }

    /// A 40-email chain, e0 (oldest) to e39 (newest), all in the Inbox with their bodies and no
    /// summaries. `unreadFrom`: emails from this index on are unread.
    private static func insertThread(unreadFrom: Int?, newestReady: String? = nil, pool: DatabasePool) throws -> [MessageHeader] {
        _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
        let now = Date()
        var headers: [MessageHeader] = []
        for index in 0..<length {
            var header = MessageHeader(
                messageId: "life\(index)", subject: "Plans", from: "Sender \(index % 3)",
                fromAddress: "sender\(index % 3)@example.com", to: "me@example.com",
                date: now.addingTimeInterval(TimeInterval(index - length) * 600), snippet: "Note \(index)",
                folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
                accountId: account, folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = rfc(index)
            header.inReplyTo = index == 0 ? nil : rfc(index - 1)
            header.headerComplete = true
            header.bodyComplete = true
            header.isRead = unreadFrom.map { index < $0 } ?? true
            if index == length - 1, let newestReady {
                header.cachedReply = "Hello,\n\n\(newestReady)\n\nThanks."
                header.replyTextMessage = newestReady
            }
            let row = header
            try pool.write { db in
                try row.insert(db)
                try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Note \(index)</p>").insert(db)
            }
            headers.append(header)
        }
        return headers
    }

    private struct Opened {
        let headers: [MessageHeader]
        /// The summary queue's chat jobs, front first, as indices into `headers`.
        let queued: [Int]
        /// Distance from the bottom of the chat's scroll view to the bottom of the screen.
        let belowScreen: CGFloat
        let readInDatabase: [Bool]
    }

    /// The chat jobs in the queue, front first, once the front has not changed for a while.
    private static func settledFront(_ queue: ActiveAIQueue) async throws -> [String] {
        var front: [String] = []
        var stableFor = 0
        for _ in 0..<60 where stableFor < 4 {
            try await Task.sleep(for: .milliseconds(150))
            let now = await queue.queuedJobsForTesting.filter(\.forChat).map(\.headerId)
            stableFor = (!now.isEmpty && now == front) ? stableFor + 1 : 0
            front = now
        }
        return front
    }

    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).flatMap { $0 is UITextView ? nil : [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews($0) }
    }

    private static func below(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - (scroll.contentOffset.y + scroll.bounds.height)
    }

    /// Opens the chat on `headers[openedIndex]` and waits until the queue and the scroll settle.
    /// `landsAway`: the open scrolls away from the bottom (the Unread line, a searched email), so
    /// the wait first lets that scroll happen; the chat starts at the bottom until its thread loads.
    private func open(
        unreadFrom: Int?, openedIndex: Int, highlights: Bool, landsAway: Bool = false,
        then action: (@MainActor (UIScrollView) async throws -> Void)? = nil
    ) async throws -> Opened {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let headers = try Self.insertThread(unreadFrom: unreadFrom, pool: pool)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack {
            ChatThreadView(messageId: headers[openedIndex].id, highlightsOpenedMessage: highlights)
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        func chatScroll() -> UIScrollView? {
            Self.scrollViews(controller.view).max { $0.contentSize.height < $1.contentSize.height }
        }
        if landsAway {
            for _ in 0..<80 {
                if let scroll = chatScroll(), Self.below(scroll) > 2 { break }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        var front = try await Self.settledFront(queue)
        let scroll = chatScroll()
        if let action {
            let view = try #require(scroll)
            try await action(view)
            try await Task.sleep(for: .milliseconds(600))
            front = try await Self.settledFront(queue)
        }
        await AccountManager.shared.awaitWriteQueueDrain()
        let index = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1.id, $0) })
        let belowScreen = scroll.map(Self.below) ?? -1
        let read = try await pool.read { db in
            try headers.map { try MessageHeader.fetchOne(db, key: $0.id)?.isRead ?? false }
        }
        let opened = Opened(headers: headers, queued: front.compactMap { index[$0] }, belowScreen: belowScreen,
                            readInDatabase: read)
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
        return opened
    }

    @Test("All read: the chat opens at the bottom and asks for the screen and summaryWindow older emails, newest first")
    func allReadOpensAtTheBottom() async throws {
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false)
        #expect(abs(opened.belowScreen) < 2, "at the bottom, got \(opened.belowScreen) below the screen")
        #expect(opened.queued.first == Self.length - 1, "the newest email is on screen and asked for first: \(opened.queued)")
        let asked = opened.queued.count
        #expect(asked > ChatViewConfig.summaryWindow && asked < Self.length,
                "the screen and summaryWindow more, never the whole thread: \(opened.queued)")
        #expect(opened.queued == Array((Self.length - asked..<Self.length).reversed()),
                "one run of the newest emails, newest first: \(opened.queued)")
        #expect(!opened.queued.contains(0), "the oldest email waits for a scroll")
    }

    /// The latest request: the run of consecutive emails, newest first, at the queue's front.
    private static func latestRun(_ queued: [Int]) -> [Int] {
        guard let first = queued.first else { return [] }
        var run = [first]
        for index in queued.dropFirst() {
            guard index == first - run.count else { break }
            run.append(index)
        }
        return run
    }

    @Test("Some unread: the chat opens at the Unread line, marks every email read, and asks for the screen and exactly summaryWindow above it")
    func unreadOpensAtTheUnreadLine() async throws {
        let firstUnread = 20
        let opened = try await open(unreadFrom: firstUnread, openedIndex: Self.length - 1, highlights: false, landsAway: true)
        #expect(opened.readInDatabase.allSatisfy { $0 }, "every email shown is marked read: \(opened.readInDatabase)")
        #expect(opened.belowScreen > 2, "not at the bottom")
        let run = Self.latestRun(opened.queued)
        let newestOnScreen = try #require(run.first)
        let oldestAsked = try #require(run.last)
        #expect(newestOnScreen >= firstUnread && newestOnScreen < Self.length - 1,
                "the first unread email is at the top of the screen, the newest is below it: \(opened.queued)")
        // The Unread line sits at the top of the screen, so the email above it may show a little.
        #expect((firstUnread - 1 - ChatViewConfig.summaryWindow)...(firstUnread - ChatViewConfig.summaryWindow) ~= oldestAsked,
                "the screen, then exactly summaryWindow emails above it: \(opened.queued)")
        #expect(opened.queued.allSatisfy { $0 >= oldestAsked },
                "the chat's own scroll to the Unread line is not a hand scroll: nothing further is asked: \(opened.queued)")
    }

    @Test("When a scroll stops, the emails then on screen go to the front, and a scroll the chat made keeps the open window")
    func stoppedScrollPutsTheScreenFirst() async throws {
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { scroll in
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true)
        }
        #expect(opened.belowScreen > 2, "scrolled away from the bottom")
        let run = Self.latestRun(opened.queued)
        let newestOnScreen = try #require(run.first)
        #expect(newestOnScreen < Self.length - 1 - ChatViewConfig.summaryWindow,
                "the front of the queue is the new screen, not the bottom: \(opened.queued)")
        #expect(run.last == 0, "then the emails above it, to the top of the thread: \(opened.queued)")
        // A programmatic scroll is not a hand scroll, so nothing below the screen comes next: the
        // queue goes on with the open's request, the newest email first.
        #expect(opened.queued.dropFirst(run.count).first == Self.length - 1, "\(opened.queued)")
    }

    @Test("A layout change with no scroll asks for the emails then on screen")
    func idleLayoutChangeAsks() async throws {
        var heights: (before: CGFloat, after: CGFloat) = (0, 0)
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { scroll in
            #expect(!(await ActiveAIQueue.shared.queuedJobsForTesting).isEmpty, "control: the open asked")
            await ActiveAIQueue.shared.clearForTesting()
            let window = try #require(scroll.window)
            heights.before = scroll.bounds.height
            window.frame.size.height = 480
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            heights.after = scroll.bounds.height
            #expect(!scroll.isDragging && !scroll.isDecelerating, "no scroll happened")
        }
        #expect(heights.after < heights.before - 100, "control: the screen itself shrank")
        // The scroll view keeps its offset as the screen shrinks, so which emails stay on screen
        // depends on the layout; what is pinned is that the chat asks again, for one screen.
        #expect(!opened.queued.isEmpty, "the chat asks again after the layout change")
        #expect(Self.latestRun(opened.queued) == opened.queued,
                "one run of the emails then on screen and above them, newest first: \(opened.queued)")
        #expect(opened.queued.count > ChatViewConfig.summaryWindow, "the screen and summaryWindow more")
        #expect(!opened.queued.contains(0), "the rest of the long thread waits")
    }

    @Test("Screens that change faster than the settle wait ask once, for the last screen")
    func quickChangesAskOnce() async throws {
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { scroll in
            await ActiveAIQueue.shared.clearForTesting()
            // Halfway, then the top, well inside `ChatViewConfig.summaryAskSettle`; no hand scroll.
            scroll.setContentOffset(CGPoint(x: 0, y: (scroll.contentSize.height - scroll.bounds.height) / 2), animated: false)
            scroll.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            scroll.layoutIfNeeded()
        }
        #expect(!opened.queued.isEmpty, "the last screen is asked for")
        #expect(Self.latestRun(opened.queued) == opened.queued && opened.queued.last == 0,
                "one run: the top screen, newest first, down to the oldest email: \(opened.queued)")
        #expect(opened.queued.allSatisfy { $0 < Self.length / 2 }, "nothing from the screen passed on the way: \(opened.queued)")
    }

    @Test("From search: the chat opens at the opened email")
    func searchOpensAtTheEmail() async throws {
        let target = 5
        let opened = try await open(unreadFrom: nil, openedIndex: target, highlights: true, landsAway: true)
        #expect(opened.belowScreen > 2, "not at the bottom")
        let newestOnScreen = try #require(opened.queued.first)
        #expect(newestOnScreen >= target && newestOnScreen < Self.length - 1, "\(opened.queued)")
        #expect(opened.queued.contains(target))
        #expect(opened.queued.contains(0), "the emails above it, within summaryWindow")
    }

    // MARK: - 4. The field never covers the newest bubble

    private struct Bottom: Equatable {
        /// The chat's scrollable height: the bubbles, then the room kept under the last one.
        let contentHeight: CGFloat
        /// The top of the reply field's text, on screen.
        let fieldTop: CGFloat
        let belowScreen: CGFloat
    }

    private static func textViews(_ view: UIView) -> [UITextView] {
        ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews($0) }
    }

    /// Opens the all-read thread, signed in, with `ready` as the newest email's AI Reply, and reads
    /// the bottom once the scroll and the field have not moved for a while.
    private func bottom(ready: String) async throws -> Bottom {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        ChatPillState.shared.removeAllSessions()
        let headers = try Self.insertThread(unreadFrom: nil, newestReady: ready, pool: pool)
        let newest = try #require(headers.last)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack {
            ChatThreadView(messageId: newest.id)
        }.environment(\.hasTabMailSession, true))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            ChatPillState.shared.removeAllSessions()
        }

        var last: Bottom?
        var stableFor = 0
        for _ in 0..<120 where stableFor < 6 {
            try await Task.sleep(for: .milliseconds(100))
            guard let scroll = Self.scrollViews(controller.view).max(by: { $0.contentSize.height < $1.contentSize.height }),
                  let field = Self.textViews(controller.view).first(where: { $0.text == ready }) else {
                stableFor = 0
                continue
            }
            let now = Bottom(contentHeight: scroll.contentSize.height,
                             fieldTop: field.convert(field.bounds, to: nil).minY,
                             belowScreen: Self.below(scroll))
            stableFor = now == last ? stableFor + 1 : 0
            last = now
        }
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
        try #require(stableFor >= 6, "the chat and its field settle, got \(String(describing: last))")
        return try #require(last)
    }

    @Test("At the bottom, a six-line ready AI Reply raises the thread's bottom as much as it raises the field")
    func newestBubbleClearsATallField() async throws {
        let short = try await bottom(ready: "Sounds good.")
        let long = try await bottom(ready: "Thanks for sending the detailed schedule, I can attend the planning session on Tuesday afternoon and will bring the updated budget numbers, the contractor estimates and the notes from our last discussion. I will also check the two open questions with the team beforehand and send the revised agenda by Monday so everyone has time to review it.")
        #expect(abs(short.belowScreen) < 2 && abs(long.belowScreen) < 2,
                "both open at the bottom: \(short.belowScreen), \(long.belowScreen)")
        // The bubbles are the same in both chats, so the extra scrollable height is the extra room
        // under the last bubble; at the bottom it lifts the last bubble by that much.
        let fieldRise = short.fieldTop - long.fieldTop
        let threadRise = long.contentHeight - short.contentHeight
        #expect(fieldRise > 40, "control: the long reply grows the field, by \(fieldRise)")
        #expect(threadRise >= fieldRise - 1,
                "the newest bubble rises with the field: the field rose \(fieldRise), the thread \(threadRise)")
    }

    /// Holds the first context read that reaches the body table, on its reader thread, until
    /// released (bounded): the read of the chat's attachment lists and calendar files.
    final class ContextReadHold: Sendable {
        struct State { var armed = false; var held = false; var timedOut = false }
        let state = Mutex(State())
        let release = DispatchSemaphore(value: 0)
        /// Holds nothing until armed, so the migrations and the fixture's writes run free.
        func arm() { state.withLock { $0.armed = true } }
        func statement(_ sql: String) {
            guard sql.contains("attachmentsJSON") else { return }
            let first = state.withLock { value in
                if !value.armed || value.held { return false }
                value.held = true
                return true
            }
            if first, release.wait(timeout: .now() + 30) == .timedOut {
                state.withLock { $0.timedOut = true }
            }
        }
    }

    @Test("A cancelled older context load never replaces the newer one: the chat keeps its attachment chip")
    func cancelledContextLoadNeverShows() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await cancelledContextLoad() }
    }

    private func cancelledContextLoad() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let backend = AITextMessageCallerTests.Backend()
        defer { backend.close() }
        let hold = ContextReadHold()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in db.trace { hold.statement("\($0)") } }
        let pool = try DatabasePool(path: directory.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        defer {
            hold.release.signal()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let account = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        var header = MessageHeader(
            messageId: "context-race", subject: "Documents", from: "Sender", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date(), snippet: "The agenda",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<context-race@example.com>"
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        let seeded = header
        var body = MessageBody(contentKey: ContentKey(rawValue: seeded.id), htmlContent: "<p>The agenda.</p>")
        body.attachmentsJSON = String(decoding: try JSONEncoder().encode([
            AttachmentInfo(filename: "agenda.txt", contentType: "text/plain", section: "2", size: 1, encoding: nil),
        ]), as: UTF8.self)
        let seededBody = body
        try await pool.write { db in try seeded.insert(db); try seededBody.insert(db) }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        hold.arm()
        let controller = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: seeded.id) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func showsChip() -> Bool { HostedAccessibility.labels(in: controller.view).contains("Attachment agenda.txt") }

        for _ in 0..<100 where !hold.state.withLock({ $0.held }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(hold.state.withLock { $0.held }, "control: the chat's first context read is held")
        // The summary arrives while that read is held: the real writer stores its text message
        // and tells the screen, whose new members cancel the held load and start a new one.
        let target = try #require(try await pool.read { try AIWriteTarget.capture(message: seeded, db: $0) })
        let writer = ActiveAIQueue()
        await writer.setDispatchSuppressedForTesting(true)
        let retry = await writer.executeJobForTesting(
            .init(headerId: seeded.id, accountId: account.id, jobType: .summary, windowExempt: true, forChat: true),
            message: seeded, plainText: "The agenda.", account: account, target: target, aiService: backend.service)
        #expect(!retry, "control: the summary was written")
        for _ in 0..<100 where !showsChip() {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(showsChip(), "control: the newer load shows the attachment chip: \(HostedAccessibility.labels(in: controller.view).prefix(20))")

        hold.release.signal()
        try await Task.sleep(for: .seconds(1))
        #expect(!hold.state.withLock { $0.timedOut }, "control: the held read was released, not timed out")
        #expect(showsChip(), "the cancelled older load did not replace the newer one")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    @Test("After a reply is sent from the chat, no AI Reply shows until someone else's email arrives, whether or not the sent email has")
    func sentReplyTakesTheTurn() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        let replies = ChatSentReplies.shared
        replies.removeAllForTesting()
        ChatPillState.shared.removeAllSessions()
        defer {
            replies.removeAllForTesting()
            ChatPillState.shared.removeAllSessions()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let account = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        let now = Date()
        func header(_ id: String, from: String, secondsAgo: Double, inReplyTo: String?, ready: String?) -> MessageHeader {
            var header = MessageHeader(
                messageId: id, subject: "Lunch plans", from: from, fromAddress: from, to: "someone@example.com",
                date: now.addingTimeInterval(-secondsAgo), snippet: "Note \(id)",
                folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
                accountId: Self.account, folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = "<\(id)@example.com>"
            header.inReplyTo = inReplyTo
            header.headerComplete = true
            header.bodyComplete = true
            header.isRead = true
            if let ready {
                header.cachedReply = "Hello,\n\n\(ready)\n\nThanks."
                header.replyTextMessage = ready
            }
            return header
        }
        let ready = "Yes, Tuesday works for me."
        let parent = header("turn-parent", from: "sender@example.com", secondsAgo: 600, inReplyTo: nil, ready: ready)
        let accountId = Self.account
        try await pool.write { db in
            try parent.insert(db)
            var draft = Draft(
                id: "turn-draft", accountId: accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Lunch plans", body: ready, replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack {
            ChatThreadView(messageId: parent.id)
        }.environment(\.hasTabMailSession, true))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func fieldTexts() -> [String] { Self.textViews(controller.view).map(\.text) }
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<60 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }
        try await waitFor { fieldTexts().contains(ready) }
        #expect(fieldTexts().contains(ready), "control: the field offers the AI Reply on the sender's turn: \(fieldTexts())")

        // The reply is sent from the chat: queued as the compose card queues it, and reported sent.
        let queued = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: ready,
                                inReplyTo: parent.rfc822MessageId),
            accountId: Self.account, replyToHeaderId: parent.id, isForward: false, serverDraftId: nil,
            draftId: "turn-draft", instanceEpoch: "E1")
        let sentId = try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId)?.sentMessageId })
        #expect(replies.composeEnded(.sent(outboxId: queued.outboxId), replyTo: parent), "control: the send counts")
        try await waitFor { !fieldTexts().contains(ready) }
        // Offline, the sent email does not arrive: the field stays without a suggestion.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!fieldTexts().isEmpty, "control: the field is on screen")
        #expect(!fieldTexts().contains(ready), "no suggestion while the sent email has not arrived: \(fieldTexts())")

        // Online, the sent email arrives, announced as a mail merge announces new mail: still the
        // user's turn.
        var own = header("turn-own", from: account.emailAddress, secondsAgo: 0, inReplyTo: "<turn-parent@example.com>", ready: nil)
        own.rfc822MessageId = EmailFilter.normalizeMessageId(sentId)
        let ownCopy = own
        try await pool.write { db in try ownCopy.insert(db) }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        try await waitFor { replies.entries.isEmpty }
        #expect(replies.entries.isEmpty, "control: the sent email reached the chat and ended its Sent bubble")
        try await Task.sleep(for: .milliseconds(500))
        #expect(!fieldTexts().contains(ready), "no suggestion once the sent email is in the chat: \(fieldTexts())")

        // Someone else answers: their email's own AI Reply shows.
        let later = "Friday is better for me."
        let other = header("turn-other", from: "friend@example.com", secondsAgo: -5, inReplyTo: own.rfc822MessageId, ready: later)
        try await pool.write { db in try other.insert(db) }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        try await waitFor { fieldTexts().contains(later) }
        #expect(fieldTexts().contains(later), "a new email from someone else is their turn: \(fieldTexts())")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }
}
