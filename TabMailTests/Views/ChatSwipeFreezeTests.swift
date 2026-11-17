/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 12 under the user-interaction freeze rule: the chat's swipes.
///
/// THE SYSTEM PROPERTY pinned here: while a swipe on the chat holds the finger, and until it has
/// let go and settled, data that lands does not change what the chat shows; it shows once the
/// swipe has settled. A swipe that is cancelled, fails, or whose screen goes away lets the data
/// through too, so nothing stays held.
///
/// The swipe's pan is UIKit's own recognizer type with the state the test sets, handed to the pan's
/// own handler (`ChatHorizontalPan.handle`), as UIKit hands it each event: SwiftUI keeps a
/// representable's recognizer outside the hosted view tree.
extension ChatThreadViewLifecycleTests {
    /// A pan whose event the test sets.
    final class FreezePan: UIPanGestureRecognizer {
        var event: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { event }
            set { event = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 20, y: 0) }
        override func velocity(in view: UIView?) -> CGPoint { .zero }
    }

    /// Hands the swipe `id` one pan event, as UIKit does.
    static func swipe(_ state: UIGestureRecognizer.State, on id: String, pan: FreezePan = FreezePan()) {
        pan.event = state
        ChatHorizontalPan.handle(pan, holding: id, changed: { _ in }, ended: { _, _ in })
    }

    /// Longer than a let-go swipe keeps holding.
    static var settled: Duration { ChatViewLayout.swipeSettleHold + .milliseconds(400) }

    @Test("A swipe holds the freeze from its first motion until it has let go and settled; a cancelled or failed one lets go too")
    func swipeHoldsTheFreezeUntilSettled() async throws {
        let gate = PreviewFreezeGate.shared
        #expect(!gate.isFrozen, "control: nothing holds the freeze")
        for end in [UIGestureRecognizer.State.ended, .cancelled, .failed] {
            let pan = FreezePan()
            Self.swipe(.began, on: "unit-swipe", pan: pan)
            #expect(gate.isFrozen, "\(end.rawValue): the swipe took the finger")
            Self.swipe(.changed, on: "unit-swipe", pan: pan)
            #expect(gate.isFrozen, "\(end.rawValue): still under the finger")
            Self.swipe(end, on: "unit-swipe", pan: pan)
            #expect(gate.isFrozen, "\(end.rawValue): let go, still settling")
            try await Task.sleep(for: Self.settled)
            #expect(!gate.isFrozen, "\(end.rawValue): settled, the data goes through")
        }

        // Taken again while it settles: held until that drag has settled.
        Self.swipe(.began, on: "unit-swipe")
        Self.swipe(.ended, on: "unit-swipe")
        Self.swipe(.began, on: "unit-swipe")
        try await Task.sleep(for: Self.settled)
        #expect(gate.isFrozen, "the second drag still holds the finger")
        Self.swipe(.ended, on: "unit-swipe")
        try await Task.sleep(for: Self.settled)
        #expect(!gate.isFrozen)

        // Two swipes at once: held until both let go.
        Self.swipe(.began, on: "swipe-a")
        Self.swipe(.began, on: "swipe-b")
        Self.swipe(.ended, on: "swipe-a")
        try await Task.sleep(for: Self.settled)
        #expect(gate.isFrozen, "one swipe still holds the finger")
        Self.swipe(.cancelled, on: "swipe-b")
        try await Task.sleep(for: Self.settled)
        #expect(!gate.isFrozen)

        // A preview that froze first keeps the freeze; a swipe never ends it.
        gate.begin()
        Self.swipe(.began, on: "unit-swipe")
        Self.swipe(.ended, on: "unit-swipe")
        try await Task.sleep(for: Self.settled)
        #expect(gate.isFrozen, "the preview's freeze stays")
        gate.end()
    }

    @Test("The swipe hold keeps state only for swipes that hold or settle, and a reused id keeps its newer hold")
    func swipeHoldKeepsNoStateOnceSettled() async throws {
        let hold = ChatSwipeHold.shared
        let gate = PreviewFreezeGate.shared
        #expect(hold.trackedIdsForTesting.isEmpty, "control: no swipe holds anything")

        // Every bubble that leaves the screen lets go of its id, swiped or not.
        for index in 0..<50 { hold.releaseNow("teardown-\(index)") }
        // Swipes that let go and settle.
        for index in 0..<20 {
            Self.swipe(.began, on: "settled-\(index)")
            Self.swipe(.ended, on: "settled-\(index)")
        }
        #expect(hold.trackedIdsForTesting.count == 20, "control: each let-go swipe is settling")
        try await Task.sleep(for: Self.settled)
        #expect(!gate.isFrozen, "control: settled, the data goes through")
        #expect(hold.trackedIdsForTesting.isEmpty, "nothing is kept for a swipe that settled or a view that went: \(hold.trackedIdsForTesting.count)")

        // An id reused while its earlier swipe's settle is pending: the newer swipe keeps holding.
        Self.swipe(.began, on: "reused")
        Self.swipe(.ended, on: "reused")
        hold.releaseNow("reused")
        #expect(!gate.isFrozen, "control: the view went, the hold let go")
        Self.swipe(.began, on: "reused")
        try await Task.sleep(for: Self.settled)
        #expect(gate.isFrozen, "the earlier swipe's settle never releases the newer swipe")
        Self.swipe(.ended, on: "reused")
        try await Task.sleep(for: Self.settled)
        #expect(!gate.isFrozen)
        #expect(hold.trackedIdsForTesting.isEmpty)

        // Taken again and let go again before the first let-go has settled: when the first
        // settle's time is up, the second swipe is still settling and still holds.
        Self.swipe(.began, on: "overlap")
        Self.swipe(.ended, on: "overlap")
        try await Task.sleep(for: ChatViewLayout.swipeSettleHold * 0.9)
        Self.swipe(.began, on: "overlap")
        Self.swipe(.ended, on: "overlap")
        try await Task.sleep(for: ChatViewLayout.swipeSettleHold * 0.6)
        #expect(gate.isFrozen, "the first let-go's settle never ends the second swipe's")
        try await Task.sleep(for: Self.settled)
        #expect(!gate.isFrozen, "the second swipe has settled")
        #expect(hold.trackedIdsForTesting.isEmpty)
    }

    private static let freezeAccount = "acc-chat-swipe-freeze"
    private static let freezeText = "Thursday suits me."

    /// Two emails in Archive, oldest first: the older with its body and summary, the newest with
    /// no body yet. In Archive, the background walk never asks for its summary.
    private static func insertSwipeThread(pool: DatabasePool) throws -> [MessageHeader] {
        _ = try FolderEpochTestFixture.makeAccount(id: freezeAccount, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: freezeAccount, path: "Archive", role: .archive, pool: pool)
        let now = Date()
        var headers: [MessageHeader] = []
        for index in 0..<2 {
            var header = MessageHeader(
                messageId: "freeze\(index)", subject: "Dinner \(index)", from: "Sender \(index)",
                fromAddress: "sender\(index)@example.com", to: "me@example.com",
                date: now.addingTimeInterval(TimeInterval(index - 2) * 600), snippet: "Note \(index)",
                folderId: MessageIdentity.folderId(accountId: freezeAccount, folderPath: "Archive"),
                accountId: freezeAccount, folderPath: "Archive", isInInbox: false)
            header.rfc822MessageId = "<freeze-\(index)@example.com>"
            header.inReplyTo = index == 0 ? nil : "<freeze-\(index - 1)@example.com>"
            header.headerComplete = true
            header.isRead = true
            header.bodyComplete = index == 0
            if index == 0 {
                header.summaryBlurb = "A note."
                header.summaryTextMessage = "Older dinner note."
            }
            let row = header
            try pool.write { db in
                try row.insert(db)
                if index == 0 {
                    try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Note</p>").insert(db)
                }
            }
            headers.append(header)
        }
        return headers
    }

    /// The chat opened on a two-email thread whose newest email is still summarizing, with its
    /// body landed and its summary asked for. `body` gets the chat's view, the newest email, and
    /// a way to run the summary as the queue's drain does.
    private func withSummarizingChat(
        _ body: @MainActor (UIView, MessageHeader, @MainActor () async -> Void, @MainActor () -> Void) async throws -> Void
    ) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        saved.setChatView(on: true)
        let headers = try Self.insertSwipeThread(pool: pool)
        let newest = headers[1]
        let key = ContentKey(rawValue: newest.id)
        try await ChatSummaryExecutionTests.index(newest, body: nil)
        let http = ChatSummaryExecutionTests.summaryBackend(textMessage: Self.freezeText)
        func cleanUp() async {
            await queue.clearForTesting()
            await ActiveEmbeddingQueue.shared.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
            try? await SearchIndex.shared.removeMessages(contentKeys: [key])
            // Whatever a case left held, the next case starts with nothing frozen.
            for id in headers.map(\.id) + ["chat-swipe"] { ChatSwipeHold.shared.releaseNow(id) }
        }
        defer {
            http.close()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChatThreadView(messageId: headers[0].id) })
        window.makeKeyAndVisible()
        let close: @MainActor () -> Void = {
            window.isHidden = true
            window.rootViewController = nil
        }
        defer { close() }
        let view = try #require(window.rootViewController?.view)
        do {
            func labels() -> [String] { HostedAccessibility.labels(in: view) }
            try await Self.waitFor { labels().contains { $0.hasSuffix("said: Older dinner note.") } }
            #expect(labels().contains { $0.hasSuffix("said: Older dinner note.") }, "control: the chat shows: \(labels().prefix(12))")
            try await Task.sleep(for: .seconds(1))
            #expect(labels().contains { $0.hasSuffix("said: Dinner 1, summarizing") },
                    "control: the newest email has no summary yet: \(labels().prefix(12))")
            let item = BodyFetchProcessor.ProcessedItem(
                contentKey: key, headerId: newest.id, accountId: newest.accountId, isInInbox: false,
                body: "Can we meet for dinner on Thursday?", snippet: "Can we meet for dinner on Thursday?")
            await BodyFetchProcessor.flushBatch([item], enableAI: false)
            try await Self.waitFor { await queue.queuedJobsForTesting.contains { $0.headerId == newest.id && $0.forChat } }
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
            let summarize: @MainActor () async -> Void = {
                for job in await queue.takePendingIntoFlightForTesting() {
                    await queue.executeWholeJobForTesting(job, aiService: service)
                    await queue.finishInFlightForTesting(job)
                }
            }
            try await body(view, newest, summarize, close)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    /// Polls `condition` for up to five seconds; the caller asserts on it afterwards.
    private static func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<50 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test("A summary that lands while a bubble is swiped shows once the swipe has let go and settled; with no swipe it shows at once",
          arguments: [true, false])
    func summaryWaitsForTheSwipe(swiping: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withSummarizingChat { view, newest, summarize, _ in
                @MainActor func labels() -> [String] { HostedAccessibility.labels(in: view) }
                @MainActor func summarizing() -> Bool { labels().contains { $0.hasSuffix("said: Dinner 1, summarizing") } }
                @MainActor func summarized() -> Bool { labels().contains { $0.hasSuffix("said: \(Self.freezeText)") } }
                let pan = FreezePan()
                if swiping {
                    Self.swipe(.began, on: newest.id, pan: pan)
                    Self.swipe(.changed, on: newest.id, pan: pan)
                }
                await summarize()
                let stored = try await AppDatabase.rawPool.read { try MessageHeader.fetchOne($0, key: newest.id)?.summaryTextMessage }
                #expect(stored == Self.freezeText, "control: the summary is in the database")
                guard swiping else {
                    try await Self.waitFor { summarized() }
                    #expect(summarized(), "control, no swipe: the summary shows: \(labels().prefix(12))")
                    return
                }
                try await Task.sleep(for: .seconds(2))
                #expect(summarizing() && !summarized(), "under the finger, the bubble is unchanged: \(labels().prefix(12))")
                Self.swipe(.ended, on: newest.id, pan: pan)
                try await Task.sleep(for: .milliseconds(100))
                #expect(summarizing() && !summarized(), "let go and still settling, the bubble is unchanged")
                try await Self.waitFor { summarized() }
                #expect(summarized(), "settled, the summary shows: \(labels().prefix(12))")
                #expect(!summarizing())
            }
        }
    }

    @Test("A swipe whose chat goes away mid-drag lets go of the freeze")
    func teardownLetsGo() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withSummarizingChat { _, newest, _, close in
                Self.swipe(.began, on: newest.id)
                #expect(PreviewFreezeGate.shared.isFrozen, "control: the swipe holds the freeze")
                close()
                try await Self.waitFor { !PreviewFreezeGate.shared.isFrozen }
                #expect(!PreviewFreezeGate.shared.isFrozen, "the chat went away: nothing stays held")
            }
        }
    }
}
