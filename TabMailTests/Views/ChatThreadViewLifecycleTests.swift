/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-103 decision 9: the chat screen, opened for real in a window.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The first scroll lands where the open asks: the bottom when every email is read, the Unread
///     line when some are not, the opened email when it came from search or a notification.
///  2. Every email of the thread is marked read in the database once the chat shows it (Q21).
///  3. The chat asks summaries only for the emails on screen and the `ChatViewConfig.summaryLead`
///     older than the oldest of them, on screen first: the rest of a long thread waits. When a
///     scroll stops, the emails then on screen go to the front. Only a hand scroll widens the
///     window to `summarySpread` both ways (`ChatSummaryWindow.userMoved`, unit-tested: a test
///     cannot drag a finger), so the chat's own scrolls keep the open window. A layout change
///     with no scroll at all (the screen shrinks) asks again for the emails then on screen.
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
    private static func insertThread(unreadFrom: Int?, pool: DatabasePool) throws -> [MessageHeader] {
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

    @Test("All read: the chat opens at the bottom and asks for the screen and summaryLead older emails, newest first")
    func allReadOpensAtTheBottom() async throws {
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false)
        #expect(abs(opened.belowScreen) < 2, "at the bottom, got \(opened.belowScreen) below the screen")
        #expect(opened.queued.first == Self.length - 1, "the newest email is on screen and asked for first: \(opened.queued)")
        let asked = opened.queued.count
        #expect(asked > ChatViewConfig.summaryLead && asked < Self.length,
                "the screen and summaryLead more, never the whole thread: \(opened.queued)")
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

    @Test("Some unread: the chat opens at the Unread line, marks every email read, and asks for the screen and exactly summaryLead above it")
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
        #expect((firstUnread - 1 - ChatViewConfig.summaryLead)...(firstUnread - ChatViewConfig.summaryLead) ~= oldestAsked,
                "the screen, then exactly summaryLead emails above it: \(opened.queued)")
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
        #expect(newestOnScreen < Self.length - 1 - ChatViewConfig.summaryLead,
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
        #expect(opened.queued.count > ChatViewConfig.summaryLead, "the screen and summaryLead more")
        #expect(!opened.queued.contains(0), "the rest of the long thread waits")
    }

    @Test("From search: the chat opens at the opened email")
    func searchOpensAtTheEmail() async throws {
        let target = 5
        let opened = try await open(unreadFrom: nil, openedIndex: target, highlights: true, landsAway: true)
        #expect(opened.belowScreen > 2, "not at the bottom")
        let newestOnScreen = try #require(opened.queued.first)
        #expect(newestOnScreen >= target && newestOnScreen < Self.length - 1, "\(opened.queued)")
        #expect(opened.queued.contains(target))
        #expect(opened.queued.contains(0), "the emails above it, within summaryLead")
    }
}
