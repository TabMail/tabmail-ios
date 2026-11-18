/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The message screen never goes back to older stored data (tabmail-ios #992).
///
/// Each test holds one display reader between its database read and its publish
/// (`_displayReadHook`), lets a save land and its `.messageDataDidChange` notice
/// arrive, then lets the held reader go. Whatever the readers do, the screen
/// must end up showing the newest stored row.
///
/// `.serialized`, `.processGlobalState`: the view models observe process-wide
/// notifications, and the mark-read case registers an intent on the shared
/// `AccountManager`.
@Suite("MessageDetail display order (#992)", .serialized, .processGlobalState)
struct MessageDetailDisplayOrderTests {

    /// Sentinel `object` for test posts of `.nseMergeDidCommit`, so count
    /// contracts in other suites can exclude them (production posts `nil`).
    static let testPostSentinel = "MessageDetailDisplayOrderTests"

    /// Holds a reader at its read point until `open()`. Only the first arrival
    /// holds; `passed` turns true once the held reader has been let go.
    @MainActor
    final class Gate {
        private(set) var reached = false
        private(set) var passed = false
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?

        func hold() async {
            reached = true
            if !isOpen { await withCheckedContinuation { waiter = $0 } }
            passed = true
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func makePool() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    private func insert(_ header: MessageHeader, into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try header.insert(db) }
    }

    /// A unique header per test: the shared `AccountManager` overlay is keyed by id.
    private func header(
        _ name: String, summary: String, references: [String] = [], isRead: Bool = false
    ) -> MessageHeader {
        let messageId = "\(name)-\(UUID().uuidString)"
        var h = StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@example.com>", threadId: nil, inReplyTo: nil,
            references: references, subject: "Subject \(name)", senderName: "Sender",
            senderAddress: "sender@example.com", to: "me@example.com", snippet: "snip",
            date: Date(), isRead: isRead, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: summary
        ).toMessageHeader()
        h.isRead = isRead
        return h
    }

    /// The save: a newer summary lands in the stored row, then its notice is posted
    /// (the order `ComposeView` and the AI writers use).
    private func save(summary: String, for id: String, in pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ? WHERE id = ?",
                arguments: [summary, id])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: id)
    }

    @MainActor
    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Lets the held reader go and waits until it has published.
    @MainActor
    private func release(_ gate: Gate) async throws {
        // Time for a refresh that is not held to read and publish first.
        try await Task.sleep(for: .milliseconds(300))
        gate.open()
        try await waitUntil { gate.passed }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func cleanUp(_ pool: DatabasePool, _ dir: URL, _ previous: AppDatabase?) {
        AppDatabase.shared.withLock { $0 = previous }
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    // MARK: - Thread scan against a point refresh

    @MainActor
    @Test("a thread scan that read before a save never puts the older row back over the refresh that read after it")
    func scanThatReadBeforeSaveNeverOverwritesNewerRefresh() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let newest = header("newest", summary: "old suggestion")
        let opened = header("opened", summary: "opened", references: [newest.rfc822MessageId!])
        try insert(newest, into: pool)
        try insert(opened, into: pool)

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.first?.summaryBlurb == "old suggestion" }
        #expect(vm.threadMessages.map(\.summaryBlurb) == ["old suggestion"])

        // A thread scan reads the newest row, and is held before it publishes.
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        // Recompute saves a new suggestion; its refresh reads after the save.
        try await save(summary: "new suggestion", for: newest.id, in: pool)
        try await release(gate)

        try await waitUntil { vm.threadMessages.first?.summaryBlurb == "new suggestion" }
        #expect(vm.threadMessages.map(\.id) == [newest.id])
        #expect(vm.threadMessages.map(\.summaryBlurb) == ["new suggestion"])
    }

    @MainActor
    @Test("a thread scan that read an older AI reply never puts it back over the rewrite stored after it")
    func scanThatReadOldReplyNeverOverwritesStoredRewrite() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        var newest = header("newest", summary: "summary")
        newest.cachedReply = "old reply"
        newest.replyTextMessage = "old reply text"
        let opened = header("opened", summary: "opened", references: [newest.rfc822MessageId!])
        try insert(newest, into: pool)
        try insert(opened, into: pool)

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.first?.cachedReply == "old reply" }
        #expect(vm.threadMessages.map(\.replyTextMessage) == ["old reply text"])

        // A thread scan reads the member's old reply, and is held before it publishes.
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        // The rewritten reply is stored and its notice posted, as the AI writers do.
        let newestId = newest.id
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                arguments: ["new reply", "new reply text", newestId])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: newestId)
        try await release(gate)

        try await waitUntil { vm.threadMessages.first?.cachedReply == "new reply" }
        #expect(vm.threadMessages.map(\.id) == [newestId])
        #expect(vm.threadMessages.map(\.cachedReply) == ["new reply"])
        #expect(vm.threadMessages.map(\.replyTextMessage) == ["new reply text"])
        // The chat's AI Suggestion, read from the thread's newest email, is the new one.
        let shown = vm.threadMessages.first.flatMap {
            ChatReplyField.suggestionText(newest: $0, usersTurn: false, onlyTo: nil)
        }
        #expect(shown == "new reply text")
    }

    @MainActor
    @Test("a refresh for a row a pending thread scan is about to show still lands")
    func refreshForRowAPendingScanAddsStillLands() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        // The opened message replies to one that is not stored yet.
        let earlier = header("earlier", summary: "old summary")
        let opened = header("opened", summary: "opened", references: [earlier.rfc822MessageId!])
        try insert(opened, into: pool)

        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        #expect(vm.threadMessages.isEmpty)

        // The earlier message is stored; the scan that finds it reads it and is held.
        try insert(earlier, into: pool)
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        // Its summary is saved before the scan shows it.
        try await save(summary: "new summary", for: earlier.id, in: pool)
        try await release(gate)

        try await waitUntil { vm.threadMessages.first?.summaryBlurb == "new summary" }
        #expect(vm.threadMessages.map(\.id) == [earlier.id])
        #expect(vm.threadMessages.map(\.summaryBlurb) == ["new summary"])
    }

    // MARK: - Opened message

    @MainActor
    @Test("a body poll's read never takes the opened message back to older data")
    func pollReadNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "old summary")
        try insert(opened, into: pool)
        let openedId = opened.id

        // The server fetch writes the body; the poll then reads body and header.
        let vm = MessageDetailViewModel(
            messageId: openedId, dbPool: pool,
            fetchBodyOverride: { _ in
                try await pool.write { db in
                    try MessageBody(
                        contentKey: ContentKey(rawValue: openedId),
                        htmlContent: "<p>fetched</p>").insert(db)
                }
            },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .pollReread, !gate.reached { await gate.hold() }
        }
        vm.startBodyPoll()
        defer { vm.cancelBodyPollForTesting() }
        // The poll's first server attempt comes after its 2s tick.
        try await waitUntil(seconds: 6) { gate.reached }
        #expect(gate.reached)

        try await save(summary: "new summary", for: openedId, in: pool)
        try await release(gate)

        try await waitUntil { vm.message?.summaryBlurb == "new summary" }
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>fetched</p>")
    }

    @MainActor
    @Test("the mark-read on open never takes the opened message back to older data, and it stays read")
    func markReadNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "old summary")
        try insert(opened, into: pool)

        // Not staged, so the mark-read resolves the header itself.
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        #expect(vm.message == nil)
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .markReadResolve, !gate.reached { await gate.hold() }
        }
        let markRead = Task { await vm.markReadOnOpenIfNeeded() }
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        try await save(summary: "new summary", for: opened.id, in: pool)
        try await release(gate)
        await markRead.value

        try await waitUntil { vm.message?.summaryBlurb == "new summary" }
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.message?.isRead == true)
    }

    @MainActor
    @Test("an already-read email with a cached body shows its content, never the placeholder")
    func alreadyReadCachedEmailShowsContent() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "summary", isRead: true)
        try insert(opened, into: pool)
        let openedId = opened.id
        try await pool.write { db in
            try MessageBody(
                contentKey: ContentKey(rawValue: openedId), htmlContent: "<p>cached</p>").insert(db)
        }

        var fetched = false
        let vm = MessageDetailViewModel(
            messageId: openedId, dbPool: pool, fetchBodyOverride: { _ in fetched = true },
            observeNotifications: true)
        #expect(vm.message == nil)
        // The view starts both on open.
        async let load: Void = vm.loadBody()
        async let markRead: Void = vm.markReadOnOpenIfNeeded()
        _ = await (load, markRead)

        #expect(vm.message?.id == openedId)
        #expect(vm.message?.isRead == true)
        #expect(vm.messageBody?.htmlContent == "<p>cached</p>")
        #expect(vm.isLoading == false)
        #expect(!fetched)
    }
}
