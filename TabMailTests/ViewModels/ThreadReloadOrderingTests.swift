/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// THE SYSTEM PROPERTY pinned here: a thread reload that read its rows before a row's AI fields
/// were rewritten never puts the older row back on screen once that row was refreshed. Both the
/// AI Suggestion (the reply and its text version, as a Recompute writes them) and the summary are
/// covered; the reload's other result (an email that joined the thread) still applies.
@Suite("A thread reload never puts back a row refreshed after it began", .serialized, .processGlobalState)
@MainActor
struct ThreadReloadOrderingTests {
    private static let account = "acc-reload-order"

    /// Holds the first thread-detection References probe once armed, inside its read
    /// transaction, so the reload's snapshot predates the writes made while it is held.
    final class ReloadHold: Sendable {
        struct State { var armed = false; var held = false; var timedOut = false }
        let state = Mutex(State())
        let release = DispatchSemaphore(value: 0)
        func arm() { state.withLock { $0.armed = true } }
        var isHeld: Bool { state.withLock { $0.held } }
        func statement(_ sql: String) {
            guard sql.contains("messageReference") else { return }
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

    private static func header(_ id: String, minutesAgo: Double, inReplyTo: String? = nil) -> MessageHeader {
        var header = MessageHeader(
            messageId: id, subject: "Plans", from: "Sam Lee <sam@example.com>", fromAddress: "sam@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-minutesAgo * 60), snippet: "Plans",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<\(id)@example.com>"
        header.inReplyTo = inReplyTo.map { "<\($0)@example.com>" }
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = true
        return header
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("A Recompute and a summary written while a reload is held stay on screen after the reload lands")
    func reloadKeepsNewerRows() async throws {
        let hold = ReloadHold()
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
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        let opened = Self.header("order-1", minutesAgo: 30)
        var newest = Self.header("order-2", minutesAgo: 10, inReplyTo: "order-1")
        newest.cachedReply = "Hello Sam,\n\nTuesday works."
        newest.replyTextMessage = "Tuesday works."
        newest.summaryTextMessage = "Sam asks about Tuesday."
        let seededNewest = newest
        try await pool.write { db in try opened.insert(db); try seededNewest.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        func row() -> MessageHeader? { vm.threadMessages.first { $0.id == seededNewest.id } }
        try await Self.waitUntil { row() != nil }
        #expect(row()?.replyTextMessage == "Tuesday works.", "control: the first load shows the newest email")

        // An email joins the thread with no event yet: only the held reload's snapshot has it.
        let joined = Self.header("order-3", minutesAgo: 5, inReplyTo: "order-2")
        try await pool.write { db in try joined.insert(db) }

        // A reload starts and is held with its snapshot taken.
        hold.arm()
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the reload is held mid-read")

        // A Recompute and a summary land on the newest email, and their refresh shows them.
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ?, summaryTextMessage = ? WHERE id = ?",
                arguments: ["Hello Sam,\n\nI can't make Tuesday.", "Sorry, not Tuesday.", "Sam moved the plans.", seededNewest.id])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: seededNewest.id)
        try await Self.waitUntil { row()?.replyTextMessage == "Sorry, not Tuesday." }
        #expect(row()?.replyTextMessage == "Sorry, not Tuesday.", "control: the refresh showed the new row")

        // The held reload lands: its email that joined shows, its older copy of the newest does not.
        hold.release.signal()
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == joined.id } }
        #expect(vm.threadMessages.contains { $0.id == joined.id }, "control: the held reload applied")
        #expect(!hold.state.withLock { $0.timedOut })
        try await Task.sleep(for: .milliseconds(200))
        let shown = try #require(row())
        #expect(shown.replyTextMessage == "Sorry, not Tuesday." && shown.cachedReply == "Hello Sam,\n\nI can't make Tuesday.",
                "the AI Suggestion stays the newer one: \(shown.replyTextMessage ?? "nil")")
        #expect(shown.summaryTextMessage == "Sam moved the plans.", "the summary stays the newer one: \(shown.summaryTextMessage ?? "nil")")
    }
}
