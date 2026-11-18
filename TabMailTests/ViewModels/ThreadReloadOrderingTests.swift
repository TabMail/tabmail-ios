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

        // A Recompute and a summary land on the newest email. One scan runs at a time: their
        // change fences the held scan, and its replacement waits for it.
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ?, summaryTextMessage = ? WHERE id = ?",
                arguments: ["Hello Sam,\n\nI can't make Tuesday.", "Sorry, not Tuesday.", "Sam moved the plans.", seededNewest.id])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: seededNewest.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(row()?.replyTextMessage == "Tuesday works.", "nothing publishes while the only scan is held")

        // The held reload settles and publishes nothing; its replacement reads after the change:
        // the email that joined shows, and the newest email's newer rows, never the older copy.
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

    @Test("A burst of changes to a row on screen while a scan is held starts exactly one replacement scan")
    func overtakenScanStartsOneReplacement() async throws {
        let scans = ScanCount()
        let hold = ReloadHold()
        let fixture = try Self.makeFixture { scans.statement($0); hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let opened = Self.header("burst-1", minutesAgo: 30)
        let newest = Self.header("burst-2", minutesAgo: 10, inReplyTo: "burst-1")
        try await fixture.pool.write { db in try opened.insert(db); try newest.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == newest.id } }
        try await Task.sleep(for: .milliseconds(200))
        let perLoad = scans.value
        #expect(perLoad > 0, "control: a thread load runs the References probe")

        hold.arm()
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the scan is held mid-read")
        for version in 1...4 {
            try await fixture.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET replyTextMessage = ? WHERE id = ?", arguments: ["r\(version)", newest.id])
            }
            NotificationCenter.default.post(name: .messageDataDidChange, object: newest.id)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(scans.value < 2 * perLoad + 1, "no second scan runs while one is held: \(scans.value)")
        hold.release.signal()
        try await Self.waitUntil { vm.threadMessages.first { $0.id == newest.id }?.replyTextMessage == "r4" }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!hold.state.withLock { $0.timedOut })
        #expect(vm.threadMessages.first { $0.id == newest.id }?.replyTextMessage == "r4", "the replacement read after the burst")
        #expect(scans.value == 3 * perLoad, "the held scan and exactly one replacement: \(scans.value) vs \(3 * perLoad)")
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

    @Test("A failed load is not pending and does not loop: later changes to rows off screen start no load")
    func failedLoadIsNotPending() async throws {
        let fixture = try Self.makeFixture { _ in }
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory) }
        let opened = Self.header("idle-1", minutesAgo: 30)
        let newest = Self.header("idle-2", minutesAgo: 10, inReplyTo: "idle-1")
        let other = Self.header("idle-other", minutesAgo: 20)
        try await fixture.pool.write { db in try opened.insert(db); try newest.insert(db); try other.insert(db) }

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

        // The database recovers and an email joins; changes to another thread's row start no load.
        let joined = Self.header("idle-3", minutesAgo: 5, inReplyTo: "idle-2")
        try await fixture.pool.write { db in
            try db.execute(sql: "ALTER TABLE folder_hidden RENAME TO folder")
            try joined.insert(db)
        }
        for _ in 0..<3 { NotificationCenter.default.post(name: .messageDataDidChange, object: other.id) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!vm.threadMessages.contains { $0.id == joined.id }, "no load ran after the failure")

        // Control: the next merge loads.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == joined.id } }
        #expect(vm.threadMessages.contains { $0.id == joined.id }, "control: a merge still loads")
    }

    @Test("The opened email is never published as a thread row, even when it changes while a load is out")
    func openedEmailIsNeverAThreadRow() async throws {
        let hold = ReloadHold()
        let fixture = try Self.makeFixture { hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let first = Self.header("disj-1", minutesAgo: 30)
        let second = Self.header("disj-2", minutesAgo: 10, inReplyTo: "disj-1")
        try await fixture.pool.write { db in try first.insert(db); try second.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: first.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(first)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == second.id } }
        #expect(!vm.threadMessages.contains { $0.id == first.id }, "control: the opened email is not a thread row")

        // A load for the first email is held; the second email of the thread is opened meanwhile.
        hold.arm()
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the load is held mid-read")
        vm._testSeedMessage(second)
        hold.release.signal()

        // Never a shared row, while settling and after.
        for _ in 0..<40 {
            #expect(!vm.threadMessages.contains { $0.id == vm.message?.id }, "the opened email showed as a thread row")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!hold.state.withLock { $0.timedOut })
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == first.id } }
        #expect(vm.threadMessages.map(\.id) == [first.id], "the thread rows are the other email: \(vm.threadMessages.map(\.id))")
    }

    /// Delays each traced read by a seeded random amount, so loads and reads finish in a random order.
    final class Jitter: Sendable {
        let rng: Mutex<SplitMix64>
        init(seed: UInt64) { rng = Mutex(SplitMix64(seed: seed)) }
        func statement(_ sql: String) {
            guard sql.contains("messageHeader") || sql.contains("messageReference") else { return }
            let micros = rng.withLock { $0.pick(15_000) }
            usleep(useconds_t(micros))
        }
        func pick(_ bound: Int) -> Int { rng.withLock { $0.pick(bound) } }
    }

    @Test("What is on screen for a row is never older than a newer accepted read of it, in a random completion order",
          arguments: [UInt64(0x5EED_0001), 0x5EED_0002, 0x5EED_0003])
    func screenNeverGoesBack(seed: UInt64) async throws {
        let jitter = Jitter(seed: seed)
        let fixture = try Self.makeFixture { jitter.statement($0) }
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory) }
        let opened = Self.header("rand-1", minutesAgo: 30)
        let member = Self.header("rand-2", minutesAgo: 10, inReplyTo: "rand-1")
        try await fixture.pool.write { db in try opened.insert(db); try member.insert(db) }

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
        try await Self.waitUntil { vm.threadMessages.contains { $0.id == member.id } }

        // Version written as "v<n>": the shown n may only grow, and ends at the last write.
        func version(_ text: String?) -> Int { text.flatMap { Int($0.dropFirst()) } ?? 0 }
        var shownMember = 0
        var shownOpened = 0
        func check() {
            let m = version(vm.threadMessages.first { $0.id == member.id }?.summaryTextMessage)
            let o = version(vm.message?.summaryTextMessage)
            #expect(m >= shownMember, "seed \(seed): the member went back from v\(shownMember) to v\(m)")
            #expect(o >= shownOpened, "seed \(seed): the opened header went back from v\(shownOpened) to v\(o)")
            #expect(!vm.threadMessages.contains { $0.id == vm.message?.id }, "seed \(seed): the opened email is never a thread row")
            shownMember = max(shownMember, m)
            shownOpened = max(shownOpened, o)
        }
        let rounds = 20
        for n in 1...rounds {
            let target = jitter.pick(2) == 0 ? member.id : opened.id
            try await fixture.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET summaryTextMessage = ? WHERE id = ?", arguments: ["v\(n)", target])
            }
            NotificationCenter.default.post(name: .messageDataDidChange, object: target)
            if jitter.pick(3) == 0 {
                NotificationCenter.default.post(name: .nseMergeDidCommit, object: MessageDetailStagedFallbackTests.testPostSentinel)
            }
            for _ in 0..<jitter.pick(4) {
                try await Task.sleep(for: .milliseconds(5))
                check()
            }
        }
        let (lastMember, lastOpened) = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: member.id)?.summaryTextMessage,
             try MessageHeader.fetchOne(db, key: opened.id)?.summaryTextMessage)
        }
        try await Self.waitUntil {
            check()
            return vm.threadMessages.first { $0.id == member.id }?.summaryTextMessage == lastMember
                && vm.message?.summaryTextMessage == lastOpened
        }
        try await Task.sleep(for: .milliseconds(300))
        check()
        #expect(vm.threadMessages.first { $0.id == member.id }?.summaryTextMessage == lastMember, "seed \(seed): the member ends on the last write")
        #expect(vm.message?.summaryTextMessage == lastOpened, "seed \(seed): the opened header ends on the last write")
    }
}
