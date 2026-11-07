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
///  1. A context load that a newer member change cancelled never shows: the chat keeps the newer
///     load's accounts and attachment chips when the older read finally returns.
@Suite("Chat screen at run time", .serialized, .processGlobalState)
@MainActor
struct ChatThreadViewLifecycleTests {
    private static let account = "acc-chat-life"
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
