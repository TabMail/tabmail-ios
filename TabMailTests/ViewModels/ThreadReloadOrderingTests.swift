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

    /// Counts thread-detection References probes: every thread load runs them, a single-row
    /// refresh never does.
    final class ScanCount: Sendable {
        let count = Mutex(0)
        func statement(_ sql: String) {
            if sql.contains("messageReference") { count.withLock { $0 += 1 } }
        }
        var value: Int { count.withLock { $0 } }
    }

    /// Holds the first single-row read once armed, after its row was read and before its
    /// transaction ends, so the read returns the row as it was before writes made while held.
    final class RowReadHold: Sendable {
        struct State { var armed = false; var readRow = false; var held = false; var timedOut = false }
        let state = Mutex(State())
        let release = DispatchSemaphore(value: 0)
        func arm() { state.withLock { $0.armed = true } }
        var isHeld: Bool { state.withLock { $0.held } }
        func statement(_ sql: String) {
            let first = state.withLock { value -> Bool in
                guard value.armed, !value.held else { return false }
                if sql.contains("FROM \"messageHeader\" WHERE \"id\" = ") { value.readRow = true; return false }
                guard value.readRow, sql.contains("COMMIT") else { return false }
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

        // An email joins the thread with no event yet: only the held reload's snapshot has it (and any later load).
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

        // The held reload lands: the email that joined shows, the older copy of the newest does not.
        hold.release.signal()
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == joined.id } }
        #expect(vm.threadMessages.contains { $0.id == joined.id }, "control: the thread's members still apply")
        #expect(!hold.state.withLock { $0.timedOut })
        try await Task.sleep(for: .milliseconds(200))
        let shown = try #require(row())
        #expect(shown.replyTextMessage == "Sorry, not Tuesday." && shown.cachedReply == "Hello Sam,\n\nI can't make Tuesday.",
                "the AI Suggestion stays the newer one: \(shown.replyTextMessage ?? "nil")")
        #expect(shown.summaryTextMessage == "Sam moved the plans.", "the summary stays the newer one: \(shown.summaryTextMessage ?? "nil")")
    }

    @Test("When the newest reload fails, an older one that succeeds never applies; the screen keeps its state until the next reload")
    func failedNewestKeepsTheScreen() async throws {
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
        let opened = Self.header("fail-1", minutesAgo: 30)
        let newest = Self.header("fail-2", minutesAgo: 10, inReplyTo: "fail-1")
        try await pool.write { db in try opened.insert(db); try newest.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == newest.id } }
        let before = vm.threadMessages.map(\.id)
        #expect(before == [newest.id], "control: the first load shows the thread: \(before)")

        // An email joins; an older reload reads it and is held.
        let joined = Self.header("fail-3", minutesAgo: 5, inReplyTo: "fail-2")
        try await pool.write { db in try joined.insert(db) }
        hold.arm()
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the older reload is held mid-read")

        // The newest reload fails: thread detection's first read finds no folder table.
        try await pool.write { db in try db.execute(sql: "ALTER TABLE folder RENAME TO folder_hidden") }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Task.sleep(for: .milliseconds(300))

        // The older reload succeeds, after the newer one started: it never applies.
        hold.release.signal()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!hold.state.withLock { $0.timedOut })
        #expect(vm.threadMessages.map(\.id) == before, "the screen keeps its state: \(vm.threadMessages.map(\.id))")

        // The next reload applies.
        try await pool.write { db in try db.execute(sql: "ALTER TABLE folder_hidden RENAME TO folder") }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == joined.id } }
        #expect(vm.threadMessages.contains { $0.id == joined.id }, "the next reload shows the email that joined")
    }

    private struct Fixture {
        let pool: DatabasePool
        let previous: AppDatabase?
        let directory: URL
    }

    private static func makeFixture(trace: @escaping @Sendable (String) -> Void) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in db.trace { trace("\($0)") } }
        let pool = try DatabasePool(path: directory.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        return Fixture(pool: pool, previous: previous, directory: directory)
    }

    @Test("A row change for another thread never starts a thread scan, with no load out or with one out")
    func otherThreadChangeStartsNoScan() async throws {
        let scans = ScanCount()
        let hold = ReloadHold()
        let fixture = try Self.makeFixture { scans.statement($0); hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let opened = Self.header("scan-1", minutesAgo: 30)
        let newest = Self.header("scan-2", minutesAgo: 10, inReplyTo: "scan-1")
        let other = Self.header("scan-other", minutesAgo: 20)
        try await fixture.pool.write { db in try opened.insert(db); try newest.insert(db); try other.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == newest.id } }
        try await Task.sleep(for: .milliseconds(200))
        let perLoad = scans.value
        #expect(perLoad > 0, "control: a thread load runs the References probe")

        // No load out: summaries written for another thread start nothing.
        for _ in 0..<3 { NotificationCenter.default.post(name: .messageDataDidChange, object: other.id) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(scans.value == perLoad, "no scan for another thread's row: \(scans.value) vs \(perLoad)")

        // A load out: the same changes still start no further load once it returns.
        hold.arm()
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the load is held mid-read")
        for _ in 0..<3 { NotificationCenter.default.post(name: .messageDataDidChange, object: other.id) }
        try await Task.sleep(for: .milliseconds(200))
        hold.release.signal()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!hold.state.withLock { $0.timedOut })
        #expect(scans.value == 2 * perLoad, "only the held load scanned: \(scans.value) vs \(2 * perLoad)")
    }

    @Test("A failed load is not pending: a later change to a row on screen starts no load")
    func failedLoadIsNotPending() async throws {
        let fixture = try Self.makeFixture { _ in }
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory) }
        let opened = Self.header("idle-1", minutesAgo: 30)
        let newest = Self.header("idle-2", minutesAgo: 10, inReplyTo: "idle-1")
        try await fixture.pool.write { db in try opened.insert(db); try newest.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == newest.id } }

        // A load fails.
        try await fixture.pool.write { db in try db.execute(sql: "ALTER TABLE folder RENAME TO folder_hidden") }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Task.sleep(for: .milliseconds(300))

        // The database recovers and an email joins; row changes on screen start no load.
        let joined = Self.header("idle-3", minutesAgo: 5, inReplyTo: "idle-2")
        try await fixture.pool.write { db in
            try db.execute(sql: "ALTER TABLE folder_hidden RENAME TO folder")
            try joined.insert(db)
        }
        for _ in 0..<3 { NotificationCenter.default.post(name: .messageDataDidChange, object: newest.id) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!vm.threadMessages.contains { $0.id == joined.id }, "no load ran after the failure")

        // Control: the next merge loads.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == joined.id } }
        #expect(vm.threadMessages.contains { $0.id == joined.id }, "control: a merge still loads")
    }

    @Test("A single-row read that finishes after a newer read of that row started never lands")
    func lateRowReadNeverLands() async throws {
        let hold = RowReadHold()
        let fixture = try Self.makeFixture { hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let opened = Self.header("late-1", minutesAgo: 30)
        var newest = Self.header("late-2", minutesAgo: 10, inReplyTo: "late-1")
        newest.replyTextMessage = "Tuesday works."
        let seeded = newest
        try await fixture.pool.write { db in try opened.insert(db); try seeded.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        func row() -> MessageHeader? { vm.threadMessages.first { $0.id == seeded.id } }
        try await Self.waitUntil { row() != nil }
        try await Task.sleep(for: .milliseconds(200))

        // A first change; its read takes the row and is held.
        try await fixture.pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyTextMessage = ? WHERE id = ?", arguments: ["Wednesday then.", seeded.id])
        }
        hold.arm()
        NotificationCenter.default.post(name: .messageDataDidChange, object: seeded.id)
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the first read is held after taking the row")

        // A newer change; its read lands.
        try await fixture.pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET replyTextMessage = ? WHERE id = ?", arguments: ["Sorry, not this week.", seeded.id])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: seeded.id)
        try await Self.waitUntil { row()?.replyTextMessage == "Sorry, not this week." }
        #expect(row()?.replyTextMessage == "Sorry, not this week.", "control: the newer read showed the row")

        // The held read finishes last: its older copy never lands.
        hold.release.signal()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!hold.state.withLock { $0.timedOut })
        #expect(row()?.replyTextMessage == "Sorry, not this week.", "the newer row stays: \(row()?.replyTextMessage ?? "nil")")
    }
}
