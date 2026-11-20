/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation
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

    @MainActor
    final class Flag { var on = false }

    /// Every value a screen field took, in order: the view model calls it on
    /// every assignment of the field, with the new value in place, so no
    /// publication is missed between two samples. A backslide is caught at the
    /// publication that makes it, before any later reader can repair it.
    @MainActor
    final class Recorder<Value: Equatable> {
        private(set) var values: [Value]
        private let read: @MainActor () -> Value
        private let vm: MessageDetailViewModel
        private let field: MessageDetailViewModel.DisplayField
        private let startCount: Int
        private var recorded = 0

        init(
            _ vm: MessageDetailViewModel, _ field: MessageDetailViewModel.DisplayField,
            _ read: @escaping @MainActor () -> Value
        ) {
            self.vm = vm
            self.field = field
            self.read = read
            values = [read()]
            startCount = vm.publicationCountForTesting[field] ?? 0
            let previous = vm._publicationHook
            vm._publicationHook = { [weak self] published in
                previous?(published)
                guard let self, published == self.field else { return }
                self.recorded += 1
                self.values.append(self.read())
            }
        }

        /// True when every publication of the field since init was recorded.
        var isComplete: Bool { recorded == (vm.publicationCountForTesting[field] ?? 0) - startCount }

        /// True when `older` was shown again after `newer` had been shown.
        func wentBack(from newer: Value, to older: Value) -> Bool {
            guard let first = values.firstIndex(of: newer) else { return false }
            return values[(first + 1)...].contains(older)
        }

        /// The recorder saw every publication, saw `newer`, and never `older` after it.
        func neverWentBack(from newer: Value, to older: Value) -> Bool {
            isComplete && values.contains(newer) && !wentBack(from: newer, to: older)
        }
    }

    /// Scripted server fetches: each call writes its body, and a call can be
    /// held until the test lets it go.
    @MainActor
    final class FetchScript {
        let pool: DatabasePool
        let bodies: [String]
        let holdCall: Int?
        let gate = Gate()
        private(set) var calls = 0

        init(pool: DatabasePool, bodies: [String], holdCall: Int? = nil) {
            self.pool = pool
            self.bodies = bodies
            self.holdCall = holdCall
        }

        func fetch(_ msg: MessageHeader) async throws {
            calls += 1
            let call = calls
            if call == holdCall { await gate.hold() }
            let html = bodies[min(call, bodies.count) - 1]
            let key = ContentKey(rawValue: msg.id)
            try await pool.write { db in
                try MessageBody(contentKey: key, htmlContent: html).insert(db, onConflict: .replace)
            }
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
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
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

    /// Waits until the newer value is on screen (a reader outside the turns let
    /// it through) or another reader waits for the held one's turn. Ordered by
    /// the turn state, not by time.
    @MainActor
    private func waitShownOrQueued(_ vm: MessageDetailViewModel, _ shown: () -> Bool) async throws {
        try await waitUntil { shown() || vm.displayTurnWaitersForTesting > 0 }
        #expect(shown() || vm.displayTurnWaitersForTesting > 0)
    }

    /// Waits until no reader runs or waits for a display turn.
    @MainActor
    private func waitIdle(_ vm: MessageDetailViewModel) async throws {
        try await waitUntil { vm.displayTurnIsIdleForTesting }
        #expect(vm.displayTurnIsIdleForTesting)
    }

    /// The action tests start the shared manager's unstructured drain work, which
    /// can outlive the test: the installed pool closes only at process exit.
    private func cleanUp(_ pool: DatabasePool, _ dir: URL, _ previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
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
        let shown = Recorder(vm, .threadMessages) { vm.threadMessages.first?.summaryBlurb }
        try await save(summary: "new suggestion", for: newest.id, in: pool)
        try await waitShownOrQueued(vm) { vm.threadMessages.first?.summaryBlurb == "new suggestion" }
        gate.open()
        // The held reader has published once it is past its hold point.
        try await waitUntil { gate.passed }
        try await waitIdle(vm)

        #expect(vm.threadMessages.map(\.id) == [newest.id])
        #expect(vm.threadMessages.map(\.summaryBlurb) == ["new suggestion"])
        #expect(shown.neverWentBack(from: "new suggestion", to: "old suggestion"), "shown: \(shown.values)")
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
        let shown = Recorder(vm, .threadMessages) { vm.threadMessages.first?.cachedReply }
        let newestId = newest.id
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET cachedReply = ?, replyTextMessage = ? WHERE id = ?",
                arguments: ["new reply", "new reply text", newestId])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: newestId)
        try await waitShownOrQueued(vm) { vm.threadMessages.first?.cachedReply == "new reply" }
        gate.open()
        // The held reader has published once it is past its hold point.
        try await waitUntil { gate.passed }
        try await waitIdle(vm)

        #expect(shown.neverWentBack(from: "new reply", to: "old reply"), "shown: \(shown.values)")
        #expect(vm.threadMessages.map(\.id) == [newestId])
        #expect(vm.threadMessages.map(\.cachedReply) == ["new reply"])
        #expect(vm.threadMessages.map(\.replyTextMessage) == ["new reply text"])
        // The chat's AI Suggestion, read from the thread's newest email, is the new one.
        let suggestion = vm.threadMessages.first.flatMap {
            ChatReplyField.suggestionText(newest: $0, usersTurn: false, onlyTo: nil)
        }
        #expect(suggestion == "new reply text")
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
        let shown = Recorder(vm, .threadMessages) { vm.threadMessages.first?.summaryBlurb }
        try await save(summary: "new summary", for: earlier.id, in: pool)
        try await waitShownOrQueued(vm) { vm.threadMessages.first?.summaryBlurb == "new summary" }
        gate.open()
        // The held reader has published once it is past its hold point.
        try await waitUntil { gate.passed }
        try await waitIdle(vm)

        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
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

        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        try await save(summary: "new summary", for: openedId, in: pool)
        try await waitShownOrQueued(vm) { vm.message?.summaryBlurb == "new summary" }
        gate.open()
        try await waitUntil { gate.passed }
        try await waitIdle(vm)

        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>fetched</p>")
        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
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
        // The mark-read's own write posts a later refresh that would put the new
        // summary back, so every shown value is recorded, not just the last.
        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .markReadResolve, !gate.reached { await gate.hold() }
        }
        let markRead = Task { await vm.markReadOnOpenIfNeeded() }
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        try await save(summary: "new summary", for: opened.id, in: pool)
        try await waitShownOrQueued(vm) { vm.message?.summaryBlurb == "new summary" }
        gate.open()
        await markRead.value
        try await waitIdle(vm)

        try await waitUntil { vm.message?.summaryBlurb == "new summary" }
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.message?.isRead == true)
        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
    }

    // MARK: - Opening and pull-to-refresh, one case per display turn

    @MainActor
    @Test("the open's first header read never takes the screen back to older data")
    func openResolveNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "old summary")
        try insert(opened, into: pool)
        let script = FetchScript(pool: pool, bodies: ["<p>fetched</p>"])
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { msg in try await script.fetch(msg) },
            observeNotifications: true)
        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .openResolve, !gate.reached { await gate.hold() }
        }
        let load = Task { await vm.loadBody() }
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        try await save(summary: "new summary", for: opened.id, in: pool)
        try await waitShownOrQueued(vm) { vm.message?.summaryBlurb == "new summary" }
        gate.open()
        await load.value
        try await waitIdle(vm)

        #expect(vm.message?.id == opened.id)
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>fetched</p>")
        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
    }

    @MainActor
    @Test("the open's header read after a folder sync never takes the screen back to older data")
    func openResolveAfterSyncNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        // Not stored when the open starts: the sync is what lands it.
        let opened = header("opened", summary: "old summary")
        let script = FetchScript(pool: pool, bodies: ["<p>fetched</p>"])
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { msg in try await script.fetch(msg) },
            observeNotifications: true)
        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        let gate = Gate()
        let landed = Flag()
        vm._displayReadHook = { point in
            if point == .openResolve, !landed.on {
                landed.on = true
                try? await pool.write { db in try opened.insert(db) }
            }
            if point == .openResolveAfterSync, !gate.reached { await gate.hold() }
        }
        let load = Task { await vm.loadBody() }
        try await waitUntil { gate.reached }
        #expect(landed.on)
        #expect(gate.reached)

        try await save(summary: "new summary", for: opened.id, in: pool)
        try await waitShownOrQueued(vm) { vm.message?.summaryBlurb == "new summary" }
        gate.open()
        await load.value
        try await waitIdle(vm)

        #expect(vm.message?.id == opened.id)
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>fetched</p>")
        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
    }

    @MainActor
    @Test("the open's re-read after its server fetch never takes the screen back to older data")
    func openRereadNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "old summary")
        try insert(opened, into: pool)
        let script = FetchScript(pool: pool, bodies: ["<p>fetched</p>"])
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { msg in try await script.fetch(msg) },
            observeNotifications: true)
        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .openReread, !gate.reached { await gate.hold() }
        }
        let load = Task { await vm.loadBody() }
        try await waitUntil { gate.reached }
        #expect(gate.reached)
        #expect(script.calls == 1)

        try await save(summary: "new summary", for: opened.id, in: pool)
        try await waitShownOrQueued(vm) { vm.message?.summaryBlurb == "new summary" }
        gate.open()
        await load.value
        try await waitIdle(vm)

        #expect(vm.message?.id == opened.id)
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>fetched</p>")
        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
    }

    @MainActor
    @Test("pull-to-refresh's header read never takes the screen back to older data")
    func refetchResolveNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "old summary")
        try insert(opened, into: pool)
        let script = FetchScript(pool: pool, bodies: ["<p>refetched</p>"])
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { msg in try await script.fetch(msg) },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .refetchResolve, !gate.reached { await gate.hold() }
        }
        let refetch = Task { await vm.refetchBody() }
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        try await save(summary: "new summary", for: opened.id, in: pool)
        try await waitShownOrQueued(vm) { vm.message?.summaryBlurb == "new summary" }
        gate.open()
        await refetch.value
        try await waitIdle(vm)

        #expect(vm.message?.id == opened.id)
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>refetched</p>")
        #expect(shown.neverWentBack(from: "new summary", to: "old summary"), "shown: \(shown.values)")
    }

    @MainActor
    @Test("pull-to-refresh's body read never puts older bytes back over a newer body another reader showed")
    func refetchRereadNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "summary")
        try insert(opened, into: pool)
        // The open's fetch (call 1) is held; pull-to-refresh's fetch (call 2)
        // stores the older bytes, then the open's fetch stores the newer ones.
        let script = FetchScript(
            pool: pool, bodies: ["<p>newer</p>", "<p>older</p>"], holdCall: 1)
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { msg in try await script.fetch(msg) },
            observeNotifications: true)
        let shown = Recorder(vm, .messageBody) { vm.messageBody?.htmlContent }
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .refetchReread, !gate.reached { await gate.hold() }
        }
        let load = Task { await vm.loadBody() }
        try await waitUntil { script.gate.reached }
        #expect(script.gate.reached)

        let refetch = Task { await vm.refetchBody() }
        try await waitUntil { gate.reached }
        #expect(gate.reached)
        #expect(script.calls == 2)

        // The open's fetch stores the newer body; its re-read follows.
        script.gate.open()
        try await waitShownOrQueued(vm) { vm.messageBody?.htmlContent == "<p>newer</p>" }
        gate.open()
        await refetch.value
        await load.value
        try await waitIdle(vm)

        #expect(vm.message?.id == opened.id)
        #expect(vm.messageBody?.htmlContent == "<p>newer</p>")
        #expect(shown.neverWentBack(from: "<p>newer</p>", to: "<p>older</p>"), "shown: \(shown.values)")
    }

    // MARK: - Turn hand-off

    @MainActor
    @Test("a cancelled open waiting for a turn falls back to its poll, and the reader after it still runs")
    func cancelledWaitingOpenHandsOn() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let newest = header("newest", summary: "member")
        let opened = header("opened", summary: "old summary", references: [newest.rfc822MessageId!])
        try insert(newest, into: pool)
        try insert(opened, into: pool)
        let openedId = opened.id
        try await pool.write { db in
            try MessageBody(contentKey: ContentKey(rawValue: openedId), htmlContent: "<p>cached</p>").insert(db)
        }
        var fetched = false
        let vm = MessageDetailViewModel(
            messageId: openedId, dbPool: pool, fetchBodyOverride: { _ in fetched = true },
            observeNotifications: true)
        defer { vm.cancelBodyPollForTesting() }
        vm._testSeedMessage(opened)

        // A thread scan holds the turn.
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        // The open waits for the turn, and its caller is cancelled.
        let load = Task { await vm.loadBody() }
        try await waitUntil { vm.displayTurnWaitersForTesting == 1 }
        #expect(vm.displayTurnWaitersForTesting == 1)
        load.cancel()

        // A refresh waits behind it.
        try await save(summary: "new summary", for: openedId, in: pool)
        try await waitUntil { vm.displayTurnWaitersForTesting == 2 }
        #expect(vm.displayTurnWaitersForTesting == 2)

        gate.open()
        await load.value
        try await waitIdle(vm)
        try await waitUntil { vm.messageBody != nil }

        #expect(vm.hasStartedBodyPollForTesting)
        #expect(vm.message?.id == openedId)
        #expect(vm.message?.summaryBlurb == "new summary")
        #expect(vm.messageBody?.htmlContent == "<p>cached</p>")
        #expect(vm.threadMessages.map(\.id) == [newest.id])
        #expect(!fetched)
    }

    @MainActor
    @Test("a turn that publishes nothing hands the turn on to the readers waiting behind it")
    func nonpublishingTurnHandsOn() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let newest = header("newest", summary: "old summary")
        let opened = header("opened", summary: "opened", references: [newest.rfc822MessageId!])
        try insert(newest, into: pool)
        try insert(opened, into: pool)
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)

        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)

        // Two more scans wait: the first is skipped when its turn comes (a newer
        // one is queued), so it publishes nothing. A refresh waits behind both.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.displayTurnWaitersForTesting == 2 }
        #expect(vm.displayTurnWaitersForTesting == 2)
        try await save(summary: "new summary", for: newest.id, in: pool)
        try await waitUntil { vm.displayTurnWaitersForTesting == 3 }
        #expect(vm.displayTurnWaitersForTesting == 3)

        gate.open()
        try await waitIdle(vm)

        #expect(vm.threadMessages.map(\.id) == [newest.id])
        #expect(vm.threadMessages.map(\.summaryBlurb) == ["new summary"])
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

    // MARK: - The oracle

    @MainActor
    @Test("the recorder sees every publication, even newer, older and newer again in one main-actor turn")
    func recorderSeesEveryPublication() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let older = header("opened", summary: "old summary")
        var newer = older
        newer.summaryBlurb = "new summary"
        let vm = MessageDetailViewModel(
            messageId: older.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: false)
        let shown = Recorder(vm, .message) { vm.message?.summaryBlurb }
        // No suspension between the three: a sampler that reads in a later task
        // sees only the last.
        vm._testSeedMessage(newer)
        vm._testSeedMessage(older)
        vm._testSeedMessage(newer)
        #expect(shown.isComplete)
        #expect(shown.values == [nil, "new summary", "old summary", "new summary"])
        #expect(shown.wentBack(from: "new summary", to: "old summary"))
        #expect(!shown.neverWentBack(from: "new summary", to: "old summary"))
    }

    // MARK: - Local actions against a held thread scan

    /// A chat with one other email, loaded; then a thread scan reads it and is
    /// held before it publishes. Returns the view model, the member and the gate.
    @MainActor
    private func holdScan(
        _ pool: DatabasePool, member name: String
    ) async throws -> (vm: MessageDetailViewModel, member: MessageHeader, gate: Gate) {
        let member = header(name, summary: "member")
        let opened = header("opened", summary: "opened", references: [member.rfc822MessageId!])
        try insert(member, into: pool)
        try insert(opened, into: pool)
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.first?.id == member.id }
        #expect(vm.threadMessages.map(\.id) == [member.id])
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)
        return (vm, member, gate)
    }

    /// Waits until the action's local write has landed and its overlay retired.
    @MainActor
    private func waitLocalCompletion(
        _ pool: DatabasePool, _ id: String, _ landed: @escaping (MessageHeader?) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let row = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
            if landed(row), AccountManager.shared.snapshotOverlay()[id] == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let row = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(landed(row))
        #expect(AccountManager.shared.snapshotOverlay()[id] == nil)
    }

    @MainActor
    @Test("an archive that completes while an older thread scan is held never shows the email back in its old folder")
    func archiveCompletingUnderHeldScanNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        UserDefaults.standard.set(false, forKey: AccountManager.markReadOnArchiveDeleteKey)
        defer { UserDefaults.standard.removeObject(forKey: AccountManager.markReadOnArchiveDeleteKey) }
        let (vm, member, gate) = try await holdScan(pool, member: "archived")
        defer { AccountManager.shared.removeOverlayEntries(ids: [member.id]) }
        let memberId = member.id
        let shown = Recorder(vm, .threadMessages) {
            vm.threadMessages.first(where: { $0.id == memberId })?.folderPath
        }

        let current = try #require(vm.threadMessages.first)
        #expect(vm.archiveMessage(current))
        #expect(vm.threadMessages.first?.folderPath == "Archive")
        try await waitLocalCompletion(pool, memberId) { $0?.folderPath == "Archive" }

        gate.open()
        try await waitUntil { gate.passed }
        try await waitIdle(vm)
        #expect(shown.isComplete)
        #expect(!shown.wentBack(from: "Archive", to: "INBOX"), "shown: \(shown.values)")
    }

    @MainActor
    @Test("a read that completes while an older thread scan is held never shows the email unread again")
    func readCompletingUnderHeldScanNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let (vm, member, gate) = try await holdScan(pool, member: "read")
        defer { AccountManager.shared.removeOverlayEntries(ids: [member.id]) }
        let memberId = member.id
        let shown = Recorder(vm, .threadMessages) {
            vm.threadMessages.first(where: { $0.id == memberId })?.isRead
        }

        vm.toggleReadForThread(try #require(vm.threadMessages.first))
        #expect(vm.threadMessages.first?.isRead == true)
        try await waitLocalCompletion(pool, memberId) { $0?.isRead == true }

        gate.open()
        try await waitUntil { gate.passed }
        try await waitIdle(vm)
        #expect(vm.threadMessages.first?.isRead == true)
        #expect(shown.neverWentBack(from: true, to: false), "shown: \(shown.values)")
    }

    @MainActor
    @Test("a tag that completes while an older thread scan is held never shows the old tag again")
    func tagCompletingUnderHeldScanNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let (vm, member, gate) = try await holdScan(pool, member: "tagged")
        defer { AccountManager.shared.removeOverlayEntries(ids: [member.id]) }
        let memberId = member.id
        let shown = Recorder(vm, .threadMessages) {
            vm.threadMessages.first(where: { $0.id == memberId })?.actionTag
        }

        vm.applyManualTag(try #require(vm.threadMessages.first), tag: .reply)
        #expect(vm.threadMessages.first?.actionTag == .reply)
        try await waitLocalCompletion(pool, memberId) { $0?.actionTag == .reply }

        gate.open()
        try await waitUntil { gate.passed }
        try await waitIdle(vm)
        #expect(vm.threadMessages.first?.actionTag == .reply)
        #expect(shown.neverWentBack(from: .reply, to: nil), "shown: \(shown.values)")
    }

    @MainActor
    @Test("an overlay change on another email costs a held scan at most one more read and changes nothing it shows")
    func overlayChangeElsewhereCostsOneRead() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let (vm, member, gate) = try await holdScan(pool, member: "untouched")
        let elsewhere = "elsewhere-\(UUID().uuidString)"
        defer { AccountManager.shared.removeOverlayEntries(ids: [elsewhere]) }
        let before = vm.displayRereadCountForTesting
        let shownBefore = vm.threadMessages
        let shown = Recorder(vm, .threadMessages) { vm.threadMessages }

        AccountManager.shared.registerMutation(id: elsewhere, mutation: .init(isRead: true))
        gate.open()
        try await waitUntil { gate.passed }
        try await waitIdle(vm)

        // At most one extra read; an implementation that ignores another email's
        // overlay change reads none.
        #expect(vm.displayRereadCountForTesting - before <= 1)
        #expect(shown.isComplete)
        #expect(shown.values.allSatisfy { $0 == shownBefore }, "shown: \(shown.values.map { $0.map(\.id) })")
        #expect(vm.threadMessages.map(\.id) == [member.id])
    }

    @MainActor
    @Test("an overlay registered elsewhere that retires while a scan reads the older row never shows the older state")
    func overlayRetiringUnderHeldScanNeverGoesBack() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let member = header("retired", summary: "member")
        let opened = header("opened", summary: "opened", references: [member.rfc822MessageId!])
        try insert(member, into: pool)
        try insert(opened, into: pool)
        let memberId = member.id
        defer { AccountManager.shared.removeOverlayEntries(ids: [memberId]) }
        // Another screen's read is pending: its overlay exists before this view
        // model loads, and this view model changes nothing itself.
        AccountManager.shared.registerMutation(id: memberId, mutation: .init(isRead: true))
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.first?.isRead == true }
        #expect(vm.threadMessages.map(\.isRead) == [true])

        // A scan reads the stored row, still unread, and is held.
        let gate = Gate()
        vm._displayReadHook = { point in
            if point == .threadScan, !gate.reached { await gate.hold() }
        }
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { gate.reached }
        #expect(gate.reached)
        let shown = Recorder(vm, .threadMessages) {
            vm.threadMessages.first(where: { $0.id == memberId })?.isRead
        }

        // The read commits and its overlay retires, as the queue does.
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [memberId])
        }
        AccountManager.shared.removeOverlayEntries(ids: [memberId])
        gate.open()
        try await waitUntil { gate.passed }
        try await waitIdle(vm)

        #expect(vm.threadMessages.first?.isRead == true)
        #expect(shown.isComplete)
        #expect(!shown.values.contains(false), "shown: \(shown.values)")
    }

    // MARK: - Bodies that only fill an empty slot

    @MainActor
    @Test("loadBody's cache-hit body never replaces a body another reader already showed")
    func lateCacheHitNeverReplacesShownBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "summary")
        try insert(opened, into: pool)
        let openedId = opened.id
        let vm = MessageDetailViewModel(
            messageId: openedId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: false)
        let shown = Recorder(vm, .messageBody) { vm.messageBody?.htmlContent }
        // While the open resolves its header, another reader shows the stored
        // body; the stored row then changes before the open's cache read.
        vm._displayReadHook = { point in
            guard point == .openResolve, vm.messageBody == nil else { return }
            try? await pool.write { db in
                try MessageBody(contentKey: ContentKey(rawValue: openedId), htmlContent: "<p>shown</p>")
                    .insert(db, onConflict: .replace)
            }
            _ = await vm.adoptReadyBody(source: "test")
            try? await pool.write { db in
                try MessageBody(contentKey: ContentKey(rawValue: openedId), htmlContent: "<p>late</p>")
                    .insert(db, onConflict: .replace)
            }
        }
        await vm.loadBody()

        #expect(vm.messageBody?.htmlContent == "<p>shown</p>")
        #expect(shown.isComplete)
        #expect(shown.values == [nil, "<p>shown</p>"], "shown: \(shown.values)")
    }

    @MainActor
    @Test("loadBody's staged body never replaces a body another reader already showed")
    func lateStagedBodyNeverReplacesShownBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let opened = header("opened", summary: "summary")
        try insert(opened, into: pool)
        let openedId = opened.id
        defer { NSEDataBridge.latestStagedBodies.withLock { $0[openedId] = nil } }
        let vm = MessageDetailViewModel(
            messageId: openedId, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: false)
        defer { vm.cancelBodyPollForTesting() }
        let shown = Recorder(vm, .messageBody) { vm.messageBody?.htmlContent }
        // While the open resolves its header, another reader shows a staged body;
        // the staged snapshot then changes before the open's staged read.
        vm._displayReadHook = { point in
            guard point == .openResolve, vm.messageBody == nil else { return }
            NSEDataBridge.latestStagedBodies.withLock {
                $0[openedId] = .init(htmlContent: "<p>shown</p>", attachmentsJSON: nil, icsText: nil)
            }
            _ = await vm.adoptReadyBody(source: "test")
            NSEDataBridge.latestStagedBodies.withLock {
                $0[openedId] = .init(htmlContent: "<p>late</p>", attachmentsJSON: nil, icsText: nil)
            }
        }
        await vm.loadBody()

        #expect(vm.messageBody?.htmlContent == "<p>shown</p>")
        #expect(shown.isComplete)
        #expect(!shown.values.contains("<p>late</p>"), "shown: \(shown.values)")
    }
}
