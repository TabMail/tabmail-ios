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

/// ADR-IOS-114 decision 9: the chat screen, opened for real in a window.
///
/// THE SYSTEM PROPERTIES pinned here (owner rule 2026-11-09):
///  1. The open lands where it asks: the bottom when every email is read, the Unread line when
///     some are not, the opened email when it came from search or a notification.
///  2. Every email of the thread is marked read in the database once the chat shows it.
///  3. The open asks for the newest `ChatViewConfig.summaryWindow` emails, newest first, wherever
///     it lands. Any other email is asked for only once it has been on screen: scrolling up asks
///     for the rows it shows, and a row never shown asks nothing.
///  4. A context load that a newer member change cancelled never shows: the chat keeps the newer
///     load's accounts and attachment chips when the older read finally returns.
///
/// What was asked is read back from the summary queue; which rows are on screen is read from the
/// bubbles' accessibility frames (each email has its own subject).
@Suite("Chat screen at run time", .serialized, .processGlobalState)
@MainActor
struct ChatThreadViewLifecycleTests {
    private static let account = "acc-chat-life"
    private static let length = 40
    /// The emails the open asks for: the newest `summaryWindow`.
    private static var newest: [Int] { Array((length - ChatViewConfig.summaryWindow..<length).reversed()) }

    private static func rfc(_ index: Int) -> String { "<life-\(index)@example.com>" }
    /// Lines in the tall bubble: about seven screens of text on the test's phone.
    private static let tallLineCount = 160

    /// A 40-email chain, e0 (oldest) to e39 (newest), all in the Inbox with their bodies and no
    /// summaries, ten minutes apart (no time stamps between them). `unreadFrom`: emails from this
    /// index on are unread.
    /// `tall`: this email's bubble holds `tallText`, many times the screen's height, with no summary
    /// stored yet, so it still asks for one.
    private static func insertThread(unreadFrom: Int?, tall: Int? = nil, pool: DatabasePool) throws -> [MessageHeader] {
        _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
        let now = Date()
        var headers: [MessageHeader] = []
        for index in 0..<length {
            var header = MessageHeader(
                messageId: "life\(index)", subject: "Plans \(index)", from: "Sender \(index % 3)",
                fromAddress: "sender\(index % 3)@example.com", to: "me@example.com",
                date: now.addingTimeInterval(TimeInterval(index - length) * 600), snippet: "Note \(index)",
                folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
                accountId: account, folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = rfc(index)
            header.inReplyTo = index == 0 ? nil : rfc(index - 1)
            header.headerComplete = true
            header.bodyComplete = true
            header.isRead = unreadFrom.map { index < $0 } ?? true
            if index == tall { header.summaryTextMessage = tallText(index) }
            let row = header
            try pool.write { db in
                try row.insert(db)
                try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Note \(index)</p>").insert(db)
            }
            headers.append(header)
        }
        return headers
    }

    /// A text message of many lines, starting "Plans N" as the bubble's label reads it.
    private static func tallText(_ index: Int) -> String {
        (["Plans \(index)"] + (1...Self.tallLineCount).map { "Line \($0) of a long note." }).joined(separator: "\n")
    }

    private struct Opened {
        /// The summary queue's chat jobs, front first, as email indices.
        let queued: [Int]
        /// Emails any part of whose bubble is inside the chat's scroll view at the end.
        let partlyShown: Set<Int>
        /// Emails any part of whose bubble is inside the scroll view's visible area (below the
        /// bars and the chat's header) at the end.
        let partlyVisible: Set<Int>
        /// Emails whose whole bubble is inside the scroll view's visible area at the end.
        let fullyShown: Set<Int>
        /// Distance from the bottom of the chat's scroll view to the bottom of the screen.
        let belowScreen: CGFloat
        let readInDatabase: [Bool]

        /// The asks other than the open's request.
        @MainActor var older: [Int] { queued.filter { !ChatThreadViewLifecycleTests.newest.contains($0) } }
    }

    /// The chat jobs in the queue, front first, once they have not changed for a while.
    private static func settledQueue(_ queue: ActiveAIQueue) async throws -> [String] {
        var jobs: [String] = []
        var stableFor = 0
        for _ in 0..<60 where stableFor < 4 {
            try await Task.sleep(for: .milliseconds(150))
            let now = await queue.queuedJobsForTesting.filter(\.forChat).map(\.headerId)
            stableFor = (!now.isEmpty && now == jobs) ? stableFor + 1 : 0
            jobs = now
        }
        return jobs
    }

    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).flatMap { $0 is UITextView ? nil : [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews($0) }
    }

    private static func below(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - (scroll.contentOffset.y + scroll.bounds.height)
    }

    /// Each bubble's index and screen frame, from its accessibility label ("… said: Plans 7, …").
    private static func bubbleFrames(in view: UIView) -> [(index: Int, frame: CGRect)] {
        HostedAccessibility.elements(under: view).compactMap { element in
            guard let label = element.accessibilityLabel,
                  let range = label.range(of: " said: Plans ") else { return nil }
            let digits = label[range.upperBound...].prefix { $0.isNumber }
            guard let index = Int(digits) else { return nil }
            return (index, element.accessibilityFrame)
        }
    }

    /// Opens the chat on `headers[openedIndex]` and waits until the queue and the scroll settle;
    /// `then` runs after that, and the queue is read again once it settles.
    private func open(
        unreadFrom: Int?, openedIndex: Int, highlights: Bool, landsAway: Bool = false, tall: Int? = nil,
        then action: (@MainActor (UIScrollView) async throws -> Void)? = nil
    ) async throws -> Opened {
        try await HostedAccessibility.withAutomation {
            try await openWithAutomation(unreadFrom: unreadFrom, openedIndex: openedIndex,
                                         highlights: highlights, landsAway: landsAway, tall: tall, then: action)
        }
    }

    private func openWithAutomation(
        unreadFrom: Int?, openedIndex: Int, highlights: Bool, landsAway: Bool, tall: Int?,
        then action: (@MainActor (UIScrollView) async throws -> Void)?
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
        let headers = try Self.insertThread(unreadFrom: unreadFrom, tall: tall, pool: pool)

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
        var jobs = try await Self.settledQueue(queue)
        let scroll = try #require(chatScroll(), "the chat's scroll view")
        if let action {
            try await action(scroll)
            try await Task.sleep(for: .milliseconds(600))
            jobs = try await Self.settledQueue(queue)
        }
        await AccountManager.shared.awaitWriteQueueDrain()
        let index = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1.id, $0) })
        let scrollFrame = scroll.convert(scroll.bounds, to: nil)
        let visible = scrollFrame.inset(by: scroll.adjustedContentInset)
        let frames = Self.bubbleFrames(in: controller.view)
        let read = try await pool.read { db in
            try headers.map { try MessageHeader.fetchOne(db, key: $0.id)?.isRead ?? false }
        }
        let opened = Opened(
            queued: jobs.compactMap { index[$0] },
            partlyShown: Set(frames.filter { $0.frame.intersects(scrollFrame) }.map(\.index)),
            partlyVisible: Set(frames.filter { $0.frame.intersects(visible) }.map(\.index)),
            fullyShown: Set(frames.filter { visible.contains($0.frame) }.map(\.index)),
            belowScreen: Self.below(scroll), readInDatabase: read)
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
        return opened
    }

    /// The open's request is in the queue, newest first.
    private static func expectOpenRequest(_ opened: Opened, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(opened.queued.filter { newest.contains($0) } == newest,
                "the newest summaryWindow emails, newest first: \(opened.queued)", sourceLocation: sourceLocation)
    }

    @Test("All read: the chat opens at the bottom and asks for the newest summaryWindow emails, newest first")
    func allReadOpensAtTheBottom() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false)
        #expect(abs(opened.belowScreen) < 2, "at the bottom, got \(opened.belowScreen) below the screen")
        #expect(opened.fullyShown.contains(Self.length - 1), "the newest email is on screen: \(opened.fullyShown.sorted())")
        Self.expectOpenRequest(opened)
        #expect(opened.older.isEmpty,
                "at the bottom every email on screen is among the newest asked for, so no older one asks: \(opened.older) vs \(opened.partlyShown.sorted())")
        #expect(!opened.queued.contains(0), "the oldest email waits for a scroll")
    }

    @Test("Some unread: the chat opens at the Unread line and marks every email read; the open still asks for the newest")
    func unreadOpensAtTheUnreadLine() async throws {
        let firstUnread = 20
        let opened = try await open(unreadFrom: firstUnread, openedIndex: Self.length - 1, highlights: false, landsAway: true)
        #expect(opened.readInDatabase.allSatisfy { $0 }, "every email shown is marked read: \(opened.readInDatabase)")
        #expect(opened.belowScreen > 2, "not at the bottom")
        #expect(opened.fullyShown.contains(firstUnread), "the first unread email is on screen: \(opened.fullyShown.sorted())")
        // The line is at the top of what the user sees: no email above it shows there. Rows under
        // the bars and the header are laid out too (a plain stack), so the visible area decides.
        #expect(opened.partlyVisible.allSatisfy { $0 >= firstUnread }, "the Unread line is at the top: \(opened.partlyVisible.sorted())")
        Self.expectOpenRequest(opened)
        #expect(opened.older.contains(firstUnread), "the email on screen is asked for: \(opened.queued)")
        #expect(opened.older.allSatisfy { $0 >= firstUnread - 1 }, "nothing above the screen: \(opened.queued)")
    }

    @Test("From search: the chat opens at the opened email and asks for it; the open still asks for the newest")
    func searchOpensAtTheEmail() async throws {
        let target = 5
        let opened = try await open(unreadFrom: nil, openedIndex: target, highlights: true, landsAway: true)
        #expect(opened.belowScreen > 2, "not at the bottom")
        #expect(opened.fullyShown.contains(target), "the opened email is on screen: \(opened.fullyShown.sorted())")
        Self.expectOpenRequest(opened)
        #expect(opened.older.contains(target), "the email on screen is asked for: \(opened.queued)")
        let skipped = (target + ChatViewConfig.summaryWindow)..<(Self.length - 2 * ChatViewConfig.summaryWindow)
        #expect(!opened.older.contains { skipped.contains($0) },
                "the emails between the landing and the bottom were never shown and ask nothing: \(opened.queued)")
    }

    @Test("Scrolling to the top asks for the emails it shows, and the ones it jumped past ask nothing")
    func scrollingUpAsksForWhatItShows() async throws {
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { scroll in
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            scroll.layoutIfNeeded()
        }
        #expect(opened.fullyShown.contains(0), "control: the top of the thread is on screen: \(opened.fullyShown.sorted())")
        #expect(opened.older.contains(0), "the oldest email is asked for once shown: \(opened.queued)")
        #expect(opened.fullyShown.isSubset(of: Set(opened.queued)), "every email on screen is asked for: \(opened.queued)")
        let middle = ChatViewConfig.summaryWindow + 5..<(Self.length - ChatViewConfig.summaryWindow - 5)
        #expect(!opened.older.contains { middle.contains($0) }, "the emails jumped past ask nothing: \(opened.queued)")
        Self.expectOpenRequest(opened)
    }

    /// Moves the chat's content by `distance` points (positive scrolls toward the bottom), as a drag
    /// that lets go without momentum.
    private static func scroll(_ scroll: UIScrollView, by distance: CGFloat) {
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + distance), animated: false)
        scroll.layoutIfNeeded()
    }

    /// The screen frame of email `index`'s bubble, read from the whole window `view` is in (the
    /// hosting view holds the elements, not the scroll view).
    private static func bubbleFrame(_ index: Int, in view: UIView) -> CGRect? {
        bubbleFrames(in: view.window ?? view).first { $0.index == index }?.frame
    }

    final class Measured { var bubbleHeight: CGFloat = 0; var screenHeight: CGFloat = 0; var askedAtSliver = false }

    @Test("A row is shown once half of it, or half of the screen, is visible: one rule for every height")
    func visibilityRule() {
        let screen: CGFloat = 800
        let short: CGFloat = 100
        let rowShare = ChatViewLayout.shownShareOfRow
        let screenShare = ChatViewLayout.shownShareOfViewport
        #expect(!ChatRowVisibility.isShown(visibleHeight: short * rowShare - 1, rowHeight: short, viewportHeight: screen))
        #expect(ChatRowVisibility.isShown(visibleHeight: short * rowShare, rowHeight: short, viewportHeight: screen))
        let tall = 3 * screen
        #expect(!ChatRowVisibility.isShown(visibleHeight: screen * screenShare - 1, rowHeight: tall, viewportHeight: screen))
        #expect(ChatRowVisibility.isShown(visibleHeight: screen * screenShare, rowHeight: tall, viewportHeight: screen),
                "a row taller than the screen counts once it fills half of it")
        #expect(ChatRowVisibility.isShown(visibleHeight: screen, rowHeight: tall, viewportHeight: screen))
        #expect(!ChatRowVisibility.isShown(visibleHeight: 0, rowHeight: 0, viewportHeight: screen), "nothing visible is never shown")
    }

    @Test("A row more than twice the screen's height asks for its summary once scrolled into; the rows jumped past ask nothing")
    func tallRowAsksOnceScrolledInto() async throws {
        let tall = 15
        let measured = Measured()
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false, tall: tall) { scroll in
            let frame = try #require(Self.bubbleFrame(tall, in: scroll), "control: the tall row is laid out")
            let screen = scroll.convert(scroll.bounds, to: nil)
            measured.bubbleHeight = frame.height
            measured.screenHeight = screen.height
            // In one move, as a fast drag lands: the row's middle at the screen's middle.
            Self.scroll(scroll, by: frame.midY - screen.midY)
        }
        #expect(measured.bubbleHeight > 2 * measured.screenHeight,
                "control: the bubble is more than twice the screen: \(measured.bubbleHeight) vs \(measured.screenHeight)")
        #expect(opened.partlyShown == [tall], "control: only the tall row is on screen: \(opened.partlyShown.sorted())")
        #expect(opened.older == [tall], "the tall row asks, and nothing it was scrolled past does: \(opened.queued)")
        Self.expectOpenRequest(opened)
    }

    @Test("A short row asks only once half of it is on screen")
    func shortRowAsksAtHalf() async throws {
        let target = 20
        let measured = Measured()
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { scroll in
            let screen = scroll.convert(scroll.bounds, to: nil)
            let frame = try #require(Self.bubbleFrame(target, in: scroll), "control: the row is laid out")
            // A fifth of the bubble inside the top of the scroll view.
            Self.scroll(scroll, by: frame.maxY - frame.height / 5 - screen.minY)
            // The accessibility frames follow the scroll once SwiftUI has laid out again.
            try await Task.sleep(for: .milliseconds(600))
            let sliver = try #require(Self.bubbleFrame(target, in: scroll))
            #expect(abs(sliver.maxY - screen.minY - sliver.height / 5) < 2, "control: a fifth of it shows: \(sliver) in \(screen)")
            let jobs = try await Self.settledQueue(ActiveAIQueue.shared)
            measured.askedAtSliver = jobs.contains(MessageIdentity.headerId(accountId: Self.account, folderPath: "INBOX", messageId: "life\(target)"))
            // The whole bubble inside the area below the bars and the header.
            let visible = screen.inset(by: scroll.adjustedContentInset)
            Self.scroll(scroll, by: sliver.minY - visible.minY - 20)
        }
        #expect(!measured.askedAtSliver, "a fifth of a short row is not enough")
        #expect(opened.fullyShown.contains(target), "control: the row is on screen: \(opened.fullyShown.sorted())")
        #expect(opened.older.contains(target), "the row asks once it is on screen: \(opened.queued)")
        Self.expectOpenRequest(opened)
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
}
