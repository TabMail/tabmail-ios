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
/// THE SYSTEM PROPERTIES pinned here:
///  1. The open lands where it asks: the bottom when every email is read, the Unread line when
///     some are not, the opened email when it came from search or a notification.
///  2. Every email of the thread is marked read in the database once the chat shows it.
///  3. The open asks for the newest `ChatViewConfig.summaryWindow` emails, newest first, wherever
///     it lands. Any other email is asked for only once it has been on screen: scrolling up asks
///     for the rows it shows, an older row already on screen as the chat lands asks too, and a row
///     never shown asks nothing.
///  4. A context load that a newer member change cancelled never shows: the chat keeps the newer
///     load's accounts and attachment chips when the older read finally returns.
///  5. An email that joins the open chat is its newest and asks for its summary, first. A draft
///     that joins is not the chat's and never asks, from any account, whatever folders the
///     chat had read.
///  6. At the bottom, the AI Suggestion sits where the reply lands once sent: under the newest
///     bubble and above the reply field, short or long, and the field never holds it.
///  7. No AI Suggestion is offered on the user's turn: while a reply of theirs is
///     in the outbox (offline it may stay there for long) and once it is sent, until an email from
///     someone else arrives; that email's own AI Suggestion then shows. (The Sending bubble itself:
///     `ChatSendingBubbleTests`.)
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
    /// index on are unread. `newestReady`: the newest email's ready AI Suggestion.
    /// `tall`: this email's bubble holds `tallText`, many times the screen's height, with no summary
    /// stored yet, so it still asks for one.
    private static func insertThread(unreadFrom: Int?, newestReady: String? = nil, tall: Int? = nil, pool: DatabasePool) throws -> [MessageHeader] {
        _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "Drafts", role: .drafts, pool: pool)
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

    /// A text message of many lines, starting "Plans N" as the bubble's label reads it.
    private static func tallText(_ index: Int) -> String {
        (["Plans \(index)"] + (1...Self.tallLineCount).map { "Line \($0) of a long note." }).joined(separator: "\n")
    }

    private struct Opened {
        /// The summary queue's chat jobs, front first, as email indices.
        let queued: [Int]
        /// The same jobs as header ids, including emails that joined after the open.
        let queuedIds: [String]
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
        height: CGFloat = 852,
        then action: (@MainActor (UIScrollView) async throws -> Void)? = nil
    ) async throws -> Opened {
        try await HostedAccessibility.withAutomation {
            try await openWithAutomation(unreadFrom: unreadFrom, openedIndex: openedIndex,
                                         highlights: highlights, landsAway: landsAway, tall: tall,
                                         height: height, then: action)
        }
    }

    private func openWithAutomation(
        unreadFrom: Int?, openedIndex: Int, highlights: Bool, landsAway: Bool, tall: Int?, height: CGFloat,
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
        window.frame = CGRect(x: 0, y: 0, width: 393, height: height)
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
            queued: jobs.compactMap { index[$0] }, queuedIds: jobs,
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

    /// SwiftUI reports a bubble's visibility only when it changes, so an older email already on
    /// screen as the chat lands asks then, or never while it stays there.
    @Test("A tall screen: every email on screen as the chat lands asks for its summary, older ones too")
    func tallScreenAsksForEveryEmailShownAtTheOpen() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false, height: 2400)
        #expect(abs(opened.belowScreen) < 2, "at the bottom, got \(opened.belowScreen) below the screen")
        Self.expectOpenRequest(opened)
        let olderShown = opened.fullyShown.subtracting(Self.newest)
        #expect(!olderShown.isEmpty,
                "precondition: the screen shows emails older than the newest asked for: \(opened.fullyShown.sorted())")
        #expect(olderShown.isSubset(of: Set(opened.queued)),
                "every older email on screen is asked for: \(olderShown.sorted()) vs \(opened.queued)")
    }

    /// Holds every read of the chat's context (its attachment lists and calendar files) on its
    /// reader thread until opened (bounded), so the chat cannot land while it is held.
    final class ContextReadGate: Sendable {
        struct State { var armed = false; var open = false; var held = 0; var timedOut = false }
        let state = Mutex(State())
        /// Holds nothing until armed, so the migrations and the fixture's writes run free.
        func arm() { state.withLock { $0.armed = true } }
        func openGate() { state.withLock { $0.open = true } }
        func statement(_ sql: String) {
            guard sql.contains("attachmentsJSON"), sql.contains("icsText") else { return }
            let holds = state.withLock { value -> Bool in
                guard value.armed, !value.open else { return false }
                value.held += 1
                return true
            }
            guard holds else { return }
            let deadline = Date().addingTimeInterval(30)
            while !state.withLock({ $0.open }) {
                if Date() > deadline {
                    state.withLock { $0.timedOut = true }
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    /// The bug the landing fix closed, made certain: the bubbles are on screen before the chat
    /// lands (its context read is held), so each reports its visibility then and never again, as
    /// the landing scroll leaves the screen where it was. Those emails must still be asked for.
    @Test("An email on screen before the chat lands, whose only visibility report comes then, is asked for its summary")
    func anEmailShownBeforeTheLandingAsks() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await shownBeforeTheLanding() }
    }

    private func shownBeforeTheLanding() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let gate = ContextReadGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Held context reads each keep a reader; the chat's other reads must still run.
        config.maximumReaderCount = 16
        config.prepareDatabase { db in db.trace { gate.statement("\($0)") } }
        let pool = try DatabasePool(path: directory.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        defer {
            gate.openGate()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let headers = try Self.insertThread(unreadFrom: nil, pool: pool)
        let index = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1.id, $0) })

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 2400)
        gate.arm()
        let controller = UIHostingController(rootView: NavigationStack {
            ChatThreadView(messageId: headers[Self.length - 1].id)
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// The emails whose whole bubble is in the chat's visible area, and the scroll offset.
        func screen() -> (shown: Set<Int>, offset: CGFloat)? {
            guard let scroll = Self.scrollViews(controller.view).max(by: { $0.contentSize.height < $1.contentSize.height }) else { return nil }
            let visible = scroll.convert(scroll.bounds, to: nil).inset(by: scroll.adjustedContentInset)
            let shown = Set(Self.bubbleFrames(in: controller.view).filter { visible.contains($0.frame) }.map(\.index))
            return (shown, scroll.contentOffset.y)
        }
        func chatJobs() async -> [Int] {
            await queue.queuedJobsForTesting.filter(\.forChat).compactMap { index[$0.headerId] }
        }

        // Before the landing: every email of the thread is in, the bubbles are laid out and still.
        var before: (shown: Set<Int>, offset: CGFloat)?
        var stableFor = 0
        for _ in 0..<80 where stableFor < 6 {
            try await Task.sleep(for: .milliseconds(150))
            let now = screen()
            let complete = now.map { $0.shown.contains(Self.length - 1) && $0.shown.count > ChatViewConfig.summaryWindow } ?? false
            stableFor = complete && now?.shown == before?.shown && now?.offset == before?.offset ? stableFor + 1 : 0
            before = now
        }
        let held = try #require(before, "the chat's scroll view")
        #expect(stableFor >= 6, "control: the chat is laid out and still before it lands: \(held.shown.sorted())")
        #expect(gate.state.withLock { $0.held > 0 }, "control: the chat's context read is held, so it has not landed")
        let askedBefore = await chatJobs()
        #expect(!askedBefore.contains(Self.length - 1), "control: the open's request is not made yet: \(askedBefore)")

        // The chat lands.
        gate.openGate()
        let jobs = try await Self.settledQueue(queue)
        try await Task.sleep(for: .milliseconds(600))
        let after = try #require(screen(), "the chat's scroll view")
        #expect(!gate.state.withLock { $0.timedOut }, "control: the held reads were released, not timed out")
        #expect(abs(after.offset - held.offset) < 2,
                "control: the landing left the screen where it was, so no bubble reports again: \(held.offset) to \(after.offset)")
        let queued = jobs.compactMap { index[$0] }
        #expect(queued.filter { Self.newest.contains($0) } == Self.newest, "control: the open asks for the newest, newest first: \(queued)")
        let olderShown = after.shown.intersection(held.shown).subtracting(Self.newest)
        #expect(!olderShown.isEmpty, "precondition: emails older than the newest asked for were on screen before the landing: \(held.shown.sorted())")
        #expect(olderShown.isSubset(of: Set(queued)),
                "every older email on screen before and after the landing is asked for: \(olderShown.sorted()) vs \(queued)")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
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
        // The rule's numbers, written out: half of the row, or half of the screen.
        let screen: CGFloat = 800
        let short: CGFloat = 100
        #expect(!ChatRowVisibility.isShown(visibleHeight: 49, rowHeight: short, viewportHeight: screen))
        #expect(ChatRowVisibility.isShown(visibleHeight: 50, rowHeight: short, viewportHeight: screen),
                "a short row counts once half of it shows")
        let tall = 3 * screen
        #expect(!ChatRowVisibility.isShown(visibleHeight: 399, rowHeight: tall, viewportHeight: screen))
        #expect(ChatRowVisibility.isShown(visibleHeight: 400, rowHeight: tall, viewportHeight: screen),
                "a row more than twice the screen's height counts once it fills half of the screen")
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

    // MARK: - 5. An email that joins

    @Test("An email that joins the open chat asks for its summary, first")
    func aJoiningEmailAsks() async throws {
        let joinedIndex = Self.length
        var joined = MessageHeader(
            messageId: "life\(joinedIndex)", subject: "Plans \(joinedIndex)", from: "Sender 1",
            fromAddress: "sender1@example.com", to: "me@example.com", date: Date(), snippet: "Note \(joinedIndex)",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        joined.rfc822MessageId = Self.rfc(joinedIndex)
        joined.inReplyTo = Self.rfc(joinedIndex - 1)
        joined.headerComplete = true
        joined.bodyComplete = true
        joined.isRead = true
        let row = joined
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { _ in
            let askedBefore = await ActiveAIQueue.shared.queuedJobsForTesting.contains { $0.headerId == row.id }
            #expect(!askedBefore, "control: not asked before it joins")
            try await AppDatabase.dbPool.write { db in
                try row.insert(db)
                try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Note</p>").insert(db)
            }
            // Announced as a mail merge announces new mail.
            NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        }
        #expect(opened.queuedIds.first == row.id, "the joining email is asked for, at the front: \(opened.queuedIds.prefix(3))")
        Self.expectOpenRequest(opened)
    }

    /// An email answering the thread's newest, joining the open chat.
    private static func joining(_ uid: String, folderPath: String, accountId: String = account) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans \(uid)", from: "Me",
            fromAddress: "me@example.com", to: "sender1@example.com", date: Date(), snippet: "Reply \(uid)",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId, folderPath: folderPath, isInInbox: folderPath == "INBOX")
        header.rfc822MessageId = "<life-\(uid)@example.com>"
        header.inReplyTo = rfc(length - 1)
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        return header
    }

    @Test("A draft that joins the open chat never asks for a summary; an email joining with it does")
    func aJoiningDraftDoesNotAsk() async throws {
        // The user's reply draft, saved while the chat is open, with its body on the device.
        let draft = Self.joining("draft", folderPath: "Drafts")
        // Control: an email that joins at the same time.
        let email = Self.joining("joined", folderPath: "INBOX")
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { _ in
            try await AppDatabase.dbPool.write { db in
                for row in [draft, email] {
                    try row.insert(db)
                    try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Reply</p>").insert(db)
                }
            }
            NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        }
        #expect(opened.queuedIds.contains(email.id), "control: the joining email is asked for: \(opened.queuedIds.prefix(3))")
        #expect(!opened.queuedIds.contains(draft.id),
                "no chat summary is asked for a draft: its text would leave the device for nothing shown")
        Self.expectOpenRequest(opened)
    }

    @Test("A draft from an account that holds no other email of the thread never asks for a summary when it joins")
    func aJoiningDraftFromAnotherAccountDoesNotAsk() async throws {
        // The reply draft sits in another account, which has no other email of the thread, so the
        // chat had no reason to read that account's folders before it joined.
        let other = "acc-chat-life-other"
        let draft = Self.joining("other-draft", folderPath: "Drafts", accountId: other)
        // Control: an email that joins at the same time.
        let email = Self.joining("other-joined", folderPath: "INBOX")
        let opened = try await open(unreadFrom: nil, openedIndex: Self.length - 1, highlights: false) { _ in
            try await AppDatabase.dbPool.write { db in
                var account = Account(emailAddress: "\(other)@example.com", displayName: "Other", provider: .gmail)
                account.id = other
                try account.insert(db)
                try Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: other).insert(db)
                for row in [draft, email] {
                    try row.insert(db)
                    try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Reply</p>").insert(db)
                }
            }
            NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        }
        #expect(opened.queuedIds.contains(email.id), "control: the joining email is asked for: \(opened.queuedIds.prefix(3))")
        #expect(!opened.queuedIds.contains(draft.id),
                "unsent draft text never leaves the device, whatever folders the chat had read")
        Self.expectOpenRequest(opened)
    }

    // MARK: - 6. The AI Suggestion sits at the sent position, above the field

    private struct Bottom: Equatable {
        /// The chat's scrollable height: the bubbles, then the room kept under the last one.
        let contentHeight: CGFloat
        /// The top of the reply field's text, on screen.
        let fieldTop: CGFloat
        /// The bottom of the newest email's bubble, on screen.
        let newestBottom: CGFloat
        /// The AI Suggestion's frame, on screen.
        let ghost: CGRect
        let belowScreen: CGFloat
        /// The texts of the native editable fields.
        let fieldTexts: [String]
    }

    /// The AI Suggestions on screen: their frames and texts, read from their accessibility.
    private static func ghosts(in view: UIView) -> [(text: String, frame: CGRect)] {
        HostedAccessibility.elements(under: view).compactMap { element in
            guard HostedAccessibility.identifier(of: element) == ChatSuggestionBubble.bubbleId,
                  let label = element.accessibilityLabel,
                  label.hasPrefix("\(ChatSuggestionConfig.label): ") else { return nil }
            return (String(label.dropFirst(ChatSuggestionConfig.label.count + 2)), element.accessibilityFrame)
        }
    }

    private static func textViews(_ view: UIView) -> [UITextView] {
        ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews($0) }
    }

    /// Opens the all-read thread, signed in, with `ready` as the newest email's AI Suggestion, and reads
    /// the bottom once the scroll and the field have not moved for a while.
    /// `typed`: words the user types in the field once it shows, to make it grow.
    private func bottom(ready: String, typed: String? = nil) async throws -> Bottom {
        try await HostedAccessibility.withAutomation { try await bottomWithAutomation(ready: ready, typed: typed) }
    }

    private func bottomWithAutomation(ready: String, typed: String?) async throws -> Bottom {
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
        var typedIn = typed == nil
        for _ in 0..<120 where stableFor < 6 {
            try await Task.sleep(for: .milliseconds(100))
            if !typedIn, let typed, let field = Self.textViews(controller.view).first(where: \.isEditable) {
                field.text = typed
                field.delegate?.textViewDidChange?(field)
                typedIn = true
                continue
            }
            guard let scroll = Self.scrollViews(controller.view).max(by: { $0.contentSize.height < $1.contentSize.height }),
                  let field = Self.textViews(controller.view).first,
                  let ghost = Self.ghosts(in: controller.view).first(where: { $0.text == ready }),
                  let newestBubble = Self.bubbleFrames(in: controller.view).first(where: { $0.index == Self.length - 1 }) else {
                stableFor = 0
                continue
            }
            let now = Bottom(contentHeight: scroll.contentSize.height,
                             fieldTop: field.convert(field.bounds, to: nil).minY,
                             newestBottom: newestBubble.frame.maxY,
                             ghost: ghost.frame,
                             belowScreen: Self.below(scroll),
                             fieldTexts: Self.textViews(controller.view).map(\.text))
            stableFor = now == last ? stableFor + 1 : 0
            last = now
        }
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
        try #require(stableFor >= 6, "the chat, its AI Suggestion and its field settle, got \(String(describing: last))")
        return try #require(last)
    }

    @Test("At the bottom, the AI Suggestion sits under the newest bubble and above the field, short or long")
    func suggestionSitsAtTheSentPosition() async throws {
        let short = try await bottom(ready: "Sounds good.")
        let long = try await bottom(ready: "Thanks for sending the detailed schedule, I can attend the planning session on Tuesday afternoon and will bring the updated budget numbers, the contractor estimates and the notes from our last discussion. I will also check the two open questions with the team beforehand and send the revised agenda by Monday so everyone has time to review it.")
        #expect(abs(short.belowScreen) < 2 && abs(long.belowScreen) < 2,
                "both open at the bottom: \(short.belowScreen), \(long.belowScreen)")
        #expect(long.ghost.height > short.ghost.height + 40, "control: the long suggestion is taller, \(short.ghost) vs \(long.ghost)")
        for bottom in [short, long] {
            #expect(bottom.newestBottom <= bottom.ghost.minY, "the suggestion is under the newest email: \(bottom)")
            #expect(bottom.ghost.maxY <= bottom.fieldTop, "and above the field, never under it: \(bottom)")
            #expect(bottom.fieldTexts.allSatisfy { $0.isEmpty }, "the field never holds it: \(bottom.fieldTexts)")
        }
        // On the user's side, where their reply lands once sent.
        #expect(short.ghost.midX > 393 / 2, "on the right: \(short.ghost)")
    }

    @Test("At the bottom, the newest bubble and the AI Suggestion stay above the field however tall a typed draft grows it")
    func newestBubbleClearsATallField() async throws {
        let ready = "Sounds good."
        let short = try await bottom(ready: ready)
        let draft = (1...6).map { "Line \($0) of what I want to say." }.joined(separator: "\n")
        let tall = try await bottom(ready: ready, typed: draft)
        #expect(tall.fieldTexts.contains(draft), "control: the typed draft is in the field: \(tall.fieldTexts)")
        let fieldRise = short.fieldTop - tall.fieldTop
        #expect(fieldRise > 40, "control: the draft grows the field, by \(fieldRise)")
        #expect(abs(tall.belowScreen) < 2, "still at the bottom: \(tall.belowScreen)")
        #expect(tall.newestBottom <= tall.ghost.minY && tall.ghost.maxY <= tall.fieldTop,
                "the newest bubble, then the suggestion, both above the grown field: \(tall)")
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

    // MARK: - 7. The user's turn

    @Test("While a reply is in the outbox and once it is sent, no AI Suggestion shows, until someone else's email arrives")
    func sentReplyTakesTheTurn() async throws {
        try await HostedAccessibility.withAutomation { try await sentReplyTakesTheTurnBody() }
    }

    private func sentReplyTakesTheTurnBody() async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        ChatPillState.shared.removeAllSessions()
        defer {
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
        func ghostTexts() -> [String] { Self.ghosts(in: controller.view).map(\.text) }
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<60 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        }
        try await waitFor { ghostTexts().contains(ready) }
        #expect(ghostTexts().contains(ready), "control: the chat offers the AI Suggestion on the sender's turn: \(ghostTexts())")

        // A reply to it is queued, as the compose card queues it.
        let queued = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["sender@example.com"], subject: "Re: Lunch plans", body: ready,
                                inReplyTo: parent.rfc822MessageId),
            accountId: Self.account, replyToHeaderId: parent.id, isForward: false, serverDraftId: nil,
            draftId: "turn-draft", instanceEpoch: "E1")
        let sentId = try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId)?.sentMessageId })
        try await waitFor { !ghostTexts().contains(ready) }
        // Offline, the email stays in the outbox: the field stays without a suggestion.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!Self.textViews(controller.view).isEmpty, "control: the field is on screen")
        #expect(!ghostTexts().contains(ready), "no suggestion while the reply is in the outbox: \(ghostTexts())")

        // Online, the provider takes it: the send stamps `sentAt`, then writes the Sent copy, in two
        // writes, and nothing tells the chat (no merge signal is posted here).
        // The user's own bubble: "You said: …", or "You replied only to …" for a reply to fewer people.
        func said() -> Int { HostedAccessibility.labels(in: controller.view).filter { $0.hasPrefix("You said") || $0.hasPrefix("You replied") }.count }
        func sending() -> Int { HostedAccessibility.labels(in: controller.view).filter { $0.contains("Sending") }.count }
        try await pool.write { db in
            try db.execute(sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?", arguments: [Date(), queued.outboxId])
        }
        try await Task.sleep(for: .milliseconds(1000))
        #expect(said() == 1, "sent, its copy not written yet: the reply's bubble stays until the copy is in the chat")
        var own = header("turn-own", from: account.emailAddress, secondsAgo: 0, inReplyTo: "<turn-parent@example.com>", ready: nil)
        own.rfc822MessageId = EmailFilter.normalizeMessageId(sentId)
        let ownCopy = own
        try await pool.write { db in try ownCopy.insert(db) }
        var neither = 0
        for _ in 0..<60 where !(said() == 1 && sending() == 0) {
            if said() == 0 { neither += 1 }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(said() == 1 && sending() == 0, "the sent email is in the chat and its outbox bubble is gone")
        #expect(neither == 0, "never neither the bubble nor the email on screen")
        try await Task.sleep(for: .milliseconds(500))
        #expect(!ghostTexts().contains(ready), "no suggestion once the sent email is in the chat: \(ghostTexts())")

        // Someone else answers: their email's own AI Suggestion shows.
        let later = "Friday is better for me."
        let other = header("turn-other", from: "friend@example.com", secondsAgo: -5, inReplyTo: own.rfc822MessageId, ready: later)
        try await pool.write { db in try other.insert(db) }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
        try await waitFor { ghostTexts().contains(later) }
        #expect(ghostTexts().contains(later), "a new email from someone else is their turn: \(ghostTexts())")
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }
}
