/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 9: the chat's summaries follow the database while a chat is shown.
///
/// THE SYSTEM PROPERTY pinned here: a row whose body lands while the chat is not looking (the chat
/// is on screen and asks nothing at that moment, the app was in the background and the queue was
/// rebuilt, or another screen covered the chat) shows its summary once the chat is shown again.
/// Nothing in the queue waits for the body: the bubble the user reads is the assertion.
///
/// The thread is in Archive, so the background walk (the newest Inbox rows' threads) never reaches
/// it and cannot ask for it in the chat's place.
extension ChatThreadViewLifecycleTests {
    enum Arrival: String, CaseIterable, CustomTestStringConvertible {
        /// The chat is on screen; the body lands by the backfill writer, which asks for no AI.
        case shown
        /// The body lands by the AI-enabled writer while the app is in the background; the
        /// foreground return cancels every queue and rebuilds the AI queue from the database.
        case backFromTheBackground
        /// Another screen covers the chat; the body lands by the backfill writer; the user comes back.
        case coveredThenShown
        /// Regression: the app is killed and relaunched, and the chat is opened again.
        case relaunch

        var testDescription: String { rawValue }
    }

    /// The screen a test pushes over the chat and pops (hosted buttons cannot be tapped).
    @MainActor @Observable
    final class CoverModel {
        var path: [Int] = []
    }

    private struct CoverHost: View {
        @Bindable var model: CoverModel
        let messageId: String

        var body: some View {
            NavigationStack(path: $model.path) {
                ChatThreadView(messageId: messageId)
                    .navigationDestination(for: Int.self) { _ in Text("Covering screen") }
            }
        }
    }

    private static let arrivalAccount = "acc-chat-arrival"
    private static let landedText = "Tuesday works for me."

    /// Three emails in Archive, oldest first. The older two have their bodies and their summaries
    /// with text messages; the newest has no body yet, only its search index header.
    private static func insertArchivedThread(pool: DatabasePool) throws -> [MessageHeader] {
        _ = try FolderEpochTestFixture.makeAccount(id: arrivalAccount, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: arrivalAccount, path: "Archive", role: .archive, pool: pool)
        let now = Date()
        var headers: [MessageHeader] = []
        for index in 0..<3 {
            var header = MessageHeader(
                messageId: "arrival\(index)", subject: "Lunch \(index)", from: "Sender \(index)",
                fromAddress: "sender\(index)@example.com", to: "me@example.com",
                date: now.addingTimeInterval(TimeInterval(index - 3) * 600), snippet: "Note \(index)",
                folderId: MessageIdentity.folderId(accountId: arrivalAccount, folderPath: "Archive"),
                accountId: arrivalAccount, folderPath: "Archive", isInInbox: false)
            header.rfc822MessageId = "<arrival-\(index)@example.com>"
            header.inReplyTo = index == 0 ? nil : "<arrival-\(index - 1)@example.com>"
            header.headerComplete = true
            header.isRead = true
            let hasBody = index < 2
            header.bodyComplete = hasBody
            if hasBody {
                header.summaryBlurb = "A note."
                header.summaryTextMessage = "Older note \(index)."
            }
            let row = header
            try pool.write { db in
                try row.insert(db)
                if hasBody {
                    try MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Note \(index)</p>").insert(db)
                }
            }
            headers.append(header)
        }
        return headers
    }

    @Test("A body that lands while the chat is not looking shows its summary once the chat is shown again",
          arguments: Arrival.allCases)
    func aBodyThatLandsWhileTheChatIsNotLookingShowsItsSummary(arrival: Arrival) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation { try await bodyLandsWhileNotLooking(arrival) }
    }

    private func bodyLandsWhileNotLooking(_ arrival: Arrival) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        saved.setChatView(on: true)
        let headers = try Self.insertArchivedThread(pool: pool)
        let newest = headers[2]
        let key = ContentKey(rawValue: newest.id)
        try await ChatSummaryExecutionTests.index(newest, body: nil)
        let http = ChatSummaryExecutionTests.summaryBackend(textMessage: Self.landedText)
        defer {
            http.close()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        do {
            try await landAndShow(arrival, headers: headers, http: http, queue: queue, pool: pool)
        } catch {
            await Self.cleanUp(queue: queue, key: key)
            throw error
        }
        await Self.cleanUp(queue: queue, key: key)
    }

    private static func cleanUp(queue: ActiveAIQueue, key: ContentKey) async {
        await queue.clearForTesting()
        await ActiveEmbeddingQueue.shared.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
        try? await SearchIndex.shared.removeMessages(contentKeys: [key])
    }

    private func landAndShow(
        _ arrival: Arrival, headers: [MessageHeader], http: FakeHTTP.Scenario, queue: ActiveAIQueue,
        pool: DatabasePool
    ) async throws {
        let newest = headers[2]
        let model = CoverModel()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var window = UIWindow(windowScene: scene)
        func show() -> UIHostingController<CoverHost> {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            let controller = UIHostingController(rootView: CoverHost(model: model, messageId: headers[0].id))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            return controller
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
        defer { close() }
        var controller = show()
        func labels() -> [String] { HostedAccessibility.labels(in: controller.view) }

        // The chat opens and lands; the newest email shows as still summarizing.
        try await Self.waitUntil { labels().contains { $0.hasSuffix("said: Older note 1.") } }
        #expect(labels().contains { $0.hasSuffix("said: Older note 1.") }, "control: the chat shows: \(labels().prefix(12))")
        try await Task.sleep(for: .seconds(2))
        #expect(labels().contains { $0.hasSuffix("said: Lunch 2, summarizing") },
                "control: the newest email has no summary yet: \(labels().prefix(12))")
        #expect(!(await Self.chatJobQueued(newest, queue: queue)), "control: no summary can be asked for without the body")

        let item = BodyFetchProcessor.ProcessedItem(
            contentKey: ContentKey(rawValue: newest.id), headerId: newest.id, accountId: newest.accountId,
            isInInbox: false, body: "Can we meet for lunch on Tuesday?", snippet: "Can we meet for lunch on Tuesday?")
        switch arrival {
        case .shown:
            await BodyFetchProcessor.flushBatch([item], enableAI: false)
        case .backFromTheBackground:
            await BodyFetchProcessor.flushBatch([item], enableAI: true)
            // What the queue held then (whatever asked for the summary) is wiped by the foreground
            // return's cancel, and the queue is rebuilt from the database (`syncStartup` steps 1, 3).
            try await Self.waitUntil { await Self.chatJobQueued(newest, queue: queue) }
            await SyncScheduler.cancelAllInFlightQueues(inboxOnly: false)
            #expect(!(await Self.chatJobQueued(newest, queue: queue)), "control: the cancel emptied the queue")
            await queue.repopulateFromDatabase(chatViewActive: true)
        case .coveredThenShown:
            model.path = [1]
            try await Self.waitUntil { labels().contains("Covering screen") }
            #expect(labels().contains("Covering screen"), "control: another screen covers the chat")
            try await Task.sleep(for: .seconds(1))
            await BodyFetchProcessor.flushBatch([item], enableAI: false)
            try await Task.sleep(for: .seconds(1))
            model.path = []
        case .relaunch:
            close()
            await BodyFetchProcessor.flushBatch([item], enableAI: false)
            await queue.clearForTesting()
            controller = show()
        }
        let landed = try await pool.read { try MessageHeader.fetchOne($0, key: newest.id)?.bodyComplete }
        #expect(landed == true, "control: the body landed")

        // Whatever asks for the summary, the queue runs it as the drain does.
        try await Self.waitUntil { await Self.chatJobQueued(newest, queue: queue) }
        let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
        for job in await queue.takePendingIntoFlightForTesting() {
            await queue.executeWholeJobForTesting(job, aiService: service)
            await queue.finishInFlightForTesting(job)
        }
        try await Self.waitUntil { labels().contains { $0.hasSuffix("said: \(Self.landedText)") } }
        #expect(labels().contains { $0.hasSuffix("said: \(Self.landedText)") },
                "\(arrival): the newest email shows its summary: \(labels().prefix(12))")
        #expect(!labels().contains { $0.hasSuffix("said: Lunch 2, summarizing") },
                "\(arrival): the newest email is not left summarizing")
        #expect(http.recordedCalls().count == 1, "\(arrival): one model call: \(http.recordedCalls().count)")
    }

    private static func chatJobQueued(_ header: MessageHeader, queue: ActiveAIQueue) async -> Bool {
        await queue.queuedJobsForTesting.contains { $0.headerId == header.id && $0.forChat }
    }

    /// Polls `condition` for up to five seconds; the caller asserts on it afterwards.
    private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<50 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
