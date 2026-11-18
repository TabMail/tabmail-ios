/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// THE SYSTEM PROPERTY pinned here: the opened email's header on screen never goes back to an
/// older read of it. A read that started before a newer refresh read of the same header and
/// finishes after it never replaces the newer header (a nil included), on every path that
/// publishes the header: the body poll, mark-read on open, and the poll's header recovery. When
/// the older read is still the newest, it publishes.
@Suite("The opened header never goes back to an older read", .serialized, .processGlobalState)
@MainActor
struct OpenedHeaderOrderingTests {
    private static let account = "acc-opened-order"

    /// Holds the first single-header read by key once armed, so its snapshot predates the
    /// writes made while it is held.
    final class HeaderReadHold: Sendable {
        struct State { var armed = false; var held = false; var timedOut = false }
        let state = Mutex(State())
        let release = DispatchSemaphore(value: 0)
        func arm() { state.withLock { $0.armed = true } }
        var isHeld: Bool { state.withLock { $0.held } }
        var timedOut: Bool { state.withLock { $0.timedOut } }
        func statement(_ sql: String) {
            guard sql.contains("FROM \"messageHeader\" WHERE \"id\" = ") else { return }
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

    private struct Fixture {
        let pool: DatabasePool
        let previous: AppDatabase?
        let directory: URL
    }

    private static func makeFixture(foreignKeys: Bool = true, trace: @escaping @Sendable (String) -> Void) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = foreignKeys
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

    private static func header(_ id: String, version: String, isRead: Bool = true) -> MessageHeader {
        var header = MessageHeader(
            messageId: id, subject: "Plans", from: "Sam Lee <sam@example.com>", fromAddress: "sam@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-600), snippet: "Plans",
            folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
            accountId: account, folderPath: "INBOX", isInInbox: true)
        header.rfc822MessageId = "<\(id)@example.com>"
        header.headerComplete = true
        header.bodyComplete = true
        header.isRead = isRead
        header.replyTextMessage = version
        return header
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// While `hold` holds an older read, a newer version is written and announced; the newer
    /// refresh read puts it on screen. Returns once it is shown.
    private static func refreshNewer(_ newer: MessageHeader, pool: DatabasePool, vm: MessageDetailViewModel) async throws {
        try await pool.write { db in try newer.save(db) }
        NotificationCenter.default.post(name: .messageDataDidChange, object: newer.id)
        try await waitUntil { vm.message?.replyTextMessage == newer.replyTextMessage }
        #expect(vm.message?.replyTextMessage == newer.replyTextMessage, "control: the newer refresh is shown")
    }

    @Test("A body poll's header read that a newer refresh overtook never replaces the newer header")
    func pollReadNeverGoesBack() async throws {
        let hold = HeaderReadHold()
        let fixture = try Self.makeFixture { hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let v1 = Self.header("poll-1", version: "v1")
        try await fixture.pool.write { db in try v1.insert(db) }
        let pool = fixture.pool
        let vm = MessageDetailViewModel(messageId: v1.id, dbPool: pool, fetchBodyOverride: { msg in
            try await pool.write { db in try MessageBody(contentKey: ContentKey(rawValue: msg.id), htmlContent: "<p>Hi</p>").insert(db) }
            hold.arm()
        }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(v1)
        vm.startBodyPoll()
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the poll's header read is held")

        try await Self.refreshNewer(Self.header("poll-1", version: "v2"), pool: pool, vm: vm)
        hold.release.signal()
        try await Self.waitUntil { vm.messageBody != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(vm.messageBody != nil, "control: the poll landed its body")
        #expect(!hold.timedOut)
        #expect(vm.message?.replyTextMessage == "v2", "the older poll read went back: \(String(describing: vm.message?.replyTextMessage))")
    }

    @Test("A body poll's nil header read never blanks a header a newer refresh set")
    func pollNilNeverBlanks() async throws {
        let hold = HeaderReadHold()
        // No header row while the poll reads: the body goes in without its header.
        let fixture = try Self.makeFixture(foreignKeys: false) { hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let v1 = Self.header("poll-nil-1", version: "v1")
        let pool = fixture.pool
        let vm = MessageDetailViewModel(messageId: v1.id, dbPool: pool, fetchBodyOverride: { msg in
            try await pool.write { db in try MessageBody(contentKey: ContentKey(rawValue: msg.id), htmlContent: "<p>Hi</p>").insert(db) }
            hold.arm()
        }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(v1)
        vm.startBodyPoll()
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the poll's header read is held")

        try await Self.refreshNewer(Self.header("poll-nil-1", version: "v2"), pool: pool, vm: vm)
        hold.release.signal()
        try await Self.waitUntil { vm.messageBody != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(vm.messageBody != nil, "control: the poll landed its body")
        #expect(!hold.timedOut)
        #expect(vm.message?.replyTextMessage == "v2", "the poll's nil blanked a newer header")
    }

    @Test("Control: a body poll's header read that is still the newest publishes")
    func newestPollReadPublishes() async throws {
        let fixture = try Self.makeFixture { _ in }
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory) }
        let v1 = Self.header("poll-ctl-1", version: "v1")
        try await fixture.pool.write { db in try v1.insert(db) }
        let pool = fixture.pool
        let v2 = Self.header("poll-ctl-1", version: "v2")
        let vm = MessageDetailViewModel(messageId: v1.id, dbPool: pool, fetchBodyOverride: { msg in
            // The fetch also rewrites the header, with no announcement: only the poll reads it.
            try await pool.write { db in
                try v2.save(db)
                try MessageBody(contentKey: ContentKey(rawValue: msg.id), htmlContent: "<p>Hi</p>").insert(db)
            }
        }, observeNotifications: false)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(v1)
        vm.startBodyPoll()
        try await Self.waitUntil { vm.messageBody != nil }
        #expect(vm.messageBody != nil, "control: the poll landed its body")
        #expect(vm.message?.replyTextMessage == "v2", "the newest read did not publish")
    }

    @Test("Mark-read on open: its older read never replaces a newer header, and the newer header shows read")
    func markReadNeverGoesBack() async throws {
        let hold = HeaderReadHold()
        let fixture = try Self.makeFixture { hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let v1 = Self.header("read-1", version: "v1", isRead: false)
        try await fixture.pool.write { db in try v1.insert(db) }
        let vm = MessageDetailViewModel(
            messageId: v1.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.message == nil, "control: nothing is shown before the reads")
        hold.arm()
        let markRead = Task { await vm.markReadOnOpenIfNeeded() }
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: mark-read's header read is held")

        try await Self.refreshNewer(Self.header("read-1", version: "v2", isRead: false), pool: fixture.pool, vm: vm)
        hold.release.signal()
        await markRead.value
        #expect(!hold.timedOut)
        #expect(vm.message?.replyTextMessage == "v2", "mark-read's older read went back: \(String(describing: vm.message?.replyTextMessage))")
        #expect(vm.message?.isRead == true, "the newer header still shows read")
    }

    @Test("Control: mark-read's read that is still the newest publishes the header, read")
    func newestMarkReadPublishes() async throws {
        let fixture = try Self.makeFixture { _ in }
        defer { InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory) }
        let v1 = Self.header("read-ctl-1", version: "v1", isRead: false)
        try await fixture.pool.write { db in try v1.insert(db) }
        let vm = MessageDetailViewModel(
            messageId: v1.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: false)
        defer { vm.cancelBodyPollForTesting() }
        await vm.markReadOnOpenIfNeeded()
        #expect(vm.message?.replyTextMessage == "v1", "the newest read did not publish")
        #expect(vm.message?.isRead == true)
    }

    @Test("The poll's header recovery: its older read never replaces a header a newer refresh set")
    func recoveryNeverGoesBack() async throws {
        let hold = HeaderReadHold()
        let fixture = try Self.makeFixture { hold.statement($0) }
        defer {
            hold.release.signal()
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
        }
        let v1 = Self.header("recover-1", version: "v1")
        try await fixture.pool.write { db in try v1.insert(db) }
        let vm = MessageDetailViewModel(
            messageId: v1.id, dbPool: fixture.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.message == nil, "control: nothing is shown before the reads")
        hold.arm()
        vm.startBodyPoll()
        try await Self.waitUntil { hold.isHeld }
        #expect(hold.isHeld, "control: the recovery's header read is held")

        try await Self.refreshNewer(Self.header("recover-1", version: "v2"), pool: fixture.pool, vm: vm)
        hold.release.signal()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!hold.timedOut)
        #expect(vm.message?.replyTextMessage == "v2", "the recovery's older read went back: \(String(describing: vm.message?.replyTextMessage))")
    }

    @Test("Only the one publisher writes the opened header")
    func onePublisherWritesTheHeader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("TabMail/ViewModels/MessageDetailViewModel.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
        // Any write to `message`: an assignment, a compound assignment, or a member write through it.
        let write = try Regex(#"(?<![\w.])(self\.)?message(\?|!)?(\.\w+)*\s*(=|\+=|-=)(?!=)"#)
        let writers = code.enumerated().filter { $0.element.contains(write) }
        #expect(writers.count == 2, "writes to message outside the publisher: \(writers.map(\.element))")
        guard let start = code.firstIndex(where: { $0.contains("private func publishOpened(") }) else {
            Issue.record("the publisher is missing")
            return
        }
        let end = code[start...].firstIndex(where: { $0 == "    }" }) ?? start
        for writer in writers {
            #expect((start...end).contains(writer.offset), "a write to message outside publishOpened: \(writer.element)")
        }
        // Every other type sees `message` read-only.
        #expect(source.contains("    private(set) var message: MessageHeader?"))
    }
}
