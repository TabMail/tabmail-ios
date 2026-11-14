/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// Microsoft Graph refuses a write to a mailbox over its storage quota with HTTP 403 and the error
// code `ErrorQuotaExceeded`, the status it also gives for a missing permission (#865). A calendar
// change refused for a full mailbox must never be dropped and must never ask the user to sign in
// again: it stays queued, and it is made once the user frees space. Every case below runs the real
// queue (`AccountManager.drainCalendarQueue`) against the real `ExchangeCalendarProvider` and the
// fake Graph calendar, refusing one kind of write: a create's POST, an edit's PATCH, the single
// POST that copies a small file onto a split's new part, and the upload session's range PUT that
// copies a large one.

@Suite("A calendar change refused for a full mailbox stays queued until space is freed (#865)", .serialized, .processGlobalState)
@MainActor
struct CalendarMailboxFullTests {

    /// A file sent in one POST, and one an upload session takes in more than one range: at Graph's
    /// own edges (`GraphAttachmentLimits`).
    private static let small = Data("Agenda for the series\n".utf8)
    private static let large = Data((0..<(max(GraphAttachmentLimits.singlePostMaxExclusive, ExchangeDraftConfig.uploadChunkBytes) + 1))
        .map { UInt8(truncatingIfNeeded: $0 &* 31) })

    enum Write: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// A new event: `POST /me/events`.
        case create
        /// An edit of a single event: `PATCH /me/events/{id}`.
        case patch
        /// A split whose new part gets the series' small file by one attachment POST.
        case attachmentPost
        /// A split whose new part gets the series' large file by an upload session's range PUTs.
        case uploadSession

        var testDescription: String { rawValue }

        /// The fake's name for the request a full mailbox refuses in this case.
        var refused: Set<String> {
            switch self {
            case .create: ["POST"]
            case .patch: ["PATCH"]
            case .attachmentPost: ["ATTACH"]
            case .uploadSession: ["PUT"]
            }
        }
    }

    /// The calendar a case starts from, and the change the user queued.
    private static func scenario(_ write: Write) -> (graph: FakeGraphCalendar, op: PendingCalendarOperation, accountId: String) {
        let accountId = "mailbox-full-\(write.rawValue)"
        switch write {
        case .create:
            let start = GraphFixture.onDevice(days: 2, hour: 10)
            let op = PendingCalendarOperation(
                operationType: .create, accountId: accountId, eventId: "precreated865", calendarId: "primary",
                arguments: [
                    "title": .string("Planning"),
                    "start_iso": .string(GraphFixture.wall(start, in: TimeZone.current.identifier)),
                    "end_iso": .string(GraphFixture.wall(start.addingTimeInterval(3_600), in: TimeZone.current.identifier)),
                ], eventTitle: "Planning")
            return (FakeGraphCalendar([]), op, accountId)
        case .patch:
            let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-1", online: false)])
            let op = PendingCalendarOperation(
                operationType: .edit, accountId: accountId, eventId: "ev-1", calendarId: "primary",
                arguments: ["title": .string("Planning (moved rooms)")], eventTitle: "Planning")
            return (graph, op, accountId)
        case .attachmentPost, .uploadSession:
            let graph = GraphSplitFixture.calendar(GraphSplitFixture.series(range: GraphSplitFixture.numbered))
            graph.attachFile(write == .attachmentPost ? "agenda.txt" : "deck.bin", contentType: "application/octet-stream",
                             bytes: write == .attachmentPost ? small : large, to: "ser-1")
            let op = PendingCalendarOperation(
                operationType: .edit, accountId: accountId, eventId: "ser-1", calendarId: "primary",
                arguments: [
                    "edit_scope": .string("this_and_following"),
                    "recurrence_id": .string(GraphSplitFixture.recurrenceId),
                    "title": .string("Planning (phase 2)"),
                ], eventTitle: "Planning")
            return (graph, op, accountId)
        }
    }

    /// Whether the change the user asked for is on the server.
    private static func landed(_ write: Write, _ graph: FakeGraphCalendar) -> Bool {
        switch write {
        case .create:
            return graph.created.contains { $0["subject"] as? String == "Planning" }
        case .patch:
            return graph.event("ev-1")?["subject"] as? String == "Planning (moved rooms)"
        case .attachmentPost, .uploadSession:
            let name = write == .attachmentPost ? "agenda.txt" : "deck.bin"
            let bytes = write == .attachmentPost ? small : large
            guard let part = graph.created.first, let partId = part["id"] as? String else { return false }
            return part["subject"] as? String == "Planning (phase 2)"
                && graph.files(of: partId).contains { $0.name == name && $0.bytes == bytes }
                && !graph.patches("ser-1").isEmpty
        }
    }

    @Test("a change refused for a full mailbox is never dropped and never asks for sign-in; it goes through once space is freed",
          arguments: Write.allCases)
    func fullMailboxKeepsTheChangeQueued(_ write: Write) async throws {
        let (graph, op, accountId) = Self.scenario(write)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        let db = try CalendarQueueTestDatabase(accountId: accountId)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: provider)
        defer {
            Task {
                await AccountManager.shared.clearAuthFailed(accountId)
                await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId)
            }
            db.finish()
        }
        try await db.pool.write { db in try op.insert(db) }

        graph.refuseWrites(write.refused, code: FakeGraphCalendar.mailboxFullCode)
        // Two drains while the mailbox is full: the change is retried, never given up.
        for attempt in 1...2 {
            await AccountManager.shared.drainCalendarQueue()
            let row = try await db.pool.read { db in try PendingCalendarOperation.fetchOne(db, key: op.id) }
            #expect(row?.status == PendingStatus.queued.rawValue,
                    "drain \(attempt): the change refused for a full mailbox left the queue (\(String(describing: row?.status)), \(row?.failureReason ?? "no reason")); writes: \(graph.writes)")
            #expect(row?.failureKind == nil, "drain \(attempt): it was recorded as a failure of kind \(String(describing: row?.failureKind))")
            #expect(row?.waitReason == .mailboxFull, "drain \(attempt): the queued change does not say why it waits: \(String(describing: row?.waitReason))")
        }
        #expect(!Self.landed(write, graph), "fixture check: the full mailbox did not refuse the change: \(http.servedCallSequence())")
        #expect(await !AccountManager.shared.authFailedAccounts.contains(accountId),
                "a full mailbox asked the user to sign in again, which can't help")
        let store = LateCalendarFailureStore()
        await store.reload()
        #expect(store.failures.isEmpty, "a full mailbox showed a failure banner: \(store.failures.map(\.bannerText))")
        #expect(store.waiting.map(\.bannerText)
                == ["A calendar change is waiting: Planning. The mailbox is full. It will be made once space is freed."],
                "the inbox does not say the change waits for space: \(store.waiting.map(\.bannerText))")

        // The user frees space; the next drain makes the change and the row leaves the queue.
        graph.acceptWrites()
        await AccountManager.shared.drainCalendarQueue()
        let rows = try await db.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
        #expect(rows.isEmpty, "the change did not leave the queue once space was freed: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
        #expect(Self.landed(write, graph), "the change was not made once space was freed: \(http.servedCallSequence())")
        await store.reload()
        #expect(store.waiting.isEmpty && store.failures.isEmpty,
                "a banner stayed after the change was made: \(store.waiting.map(\.bannerText)) \(store.failures.map(\.bannerText))")
    }

    @Test("a later attempt refused for another passing reason clears the mailbox-full reason; the change still goes through")
    func anotherTransientReasonClearsTheWaitReason() async throws {
        let (graph, op, accountId) = Self.scenario(.patch)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        let db = try CalendarQueueTestDatabase(accountId: accountId + "-cleared")
        let queued = PendingCalendarOperation(
            operationType: .edit, accountId: accountId + "-cleared", eventId: "ev-1", calendarId: "primary",
            arguments: op.arguments, eventTitle: "Planning")
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: queued.accountId, provider: provider)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: queued.accountId) }
            db.finish()
        }
        try await db.pool.write { db in try queued.insert(db) }
        let store = LateCalendarFailureStore()

        graph.refuseWrites(["PATCH"], code: FakeGraphCalendar.mailboxFullCode)
        await AccountManager.shared.drainCalendarQueue()
        await store.reload()
        #expect(store.waiting.map(\.id) == [queued.id], "fixture check: the full mailbox was not shown: \(store.waiting.map(\.bannerText))")

        // Graph asks to come back later (409): still queued, and no longer said to be a full mailbox.
        graph.refuseWrites(["PATCH"], status: 409, code: "ErrorIrresolvableConflict")
        await AccountManager.shared.drainCalendarQueue()
        let row = try await db.pool.read { db in try PendingCalendarOperation.fetchOne(db, key: queued.id) }
        #expect(row?.status == PendingStatus.queued.rawValue && row?.waitReason == nil,
                "got \(String(describing: row?.status)) waiting for \(String(describing: row?.waitReason))")
        await store.reload()
        #expect(store.waiting.isEmpty, "the inbox still says the mailbox is full: \(store.waiting.map(\.bannerText))")

        graph.acceptWrites()
        await AccountManager.shared.drainCalendarQueue()
        #expect(try await db.pool.read { db in try PendingCalendarOperation.fetchCount(db) } == 0)
        #expect(Self.landed(.patch, graph), "the change was not made: \(http.servedCallSequence())")
    }

    @Test("a full mailbox seen on the retry after a forced token refresh also keeps the change queued")
    func fullMailboxAfterTokenRefresh() async throws {
        let (graph, op, accountId) = Self.scenario(.patch)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com",
                                                accessToken: { forceRefresh in forceRefresh ? "fresh-token" : "stale-token" },
                                                session: http.session)
        let db = try CalendarQueueTestDatabase(accountId: accountId + "-refresh")
        let queued = PendingCalendarOperation(
            operationType: .edit, accountId: accountId + "-refresh", eventId: "ev-1", calendarId: "primary",
            arguments: op.arguments, eventTitle: "Planning")
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: queued.accountId, provider: provider)
        defer {
            Task {
                await AccountManager.shared.clearAuthFailed(queued.accountId)
                await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: queued.accountId)
            }
            db.finish()
        }
        try await db.pool.write { db in try queued.insert(db) }

        // The first PATCH is refused for an expired sign-in; the retry with a fresh token finds the
        // mailbox full.
        graph.failNext("PATCH", with: 401)
        graph.refuseWrites(["PATCH"], code: FakeGraphCalendar.mailboxFullCode)
        await AccountManager.shared.drainCalendarQueue()
        let row = try await db.pool.read { db in try PendingCalendarOperation.fetchOne(db, key: queued.id) }
        #expect(graph.patchAuthorizations.count == 2, "fixture check: no refresh retry: \(graph.patchAuthorizations)")
        #expect(row?.status == PendingStatus.queued.rawValue && row?.waitReason == .mailboxFull,
                "got \(String(describing: row?.status)) \(row?.failureReason ?? "") waiting for \(String(describing: row?.waitReason))")
        #expect(await !AccountManager.shared.authFailedAccounts.contains(queued.accountId),
                "a full mailbox asked the user to sign in again")
    }

    @Test("a 403 for any other reason is still a missing permission: retired and told, as before")
    func otherForbiddenIsStillMissingPermission() async throws {
        let (graph, op, accountId) = Self.scenario(.patch)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" },
                                                session: http.session)
        let db = try CalendarQueueTestDatabase(accountId: accountId + "-other")
        let other = PendingCalendarOperation(
            operationType: .edit, accountId: accountId + "-other", eventId: "ev-1", calendarId: "primary",
            arguments: op.arguments, eventTitle: "Planning")
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: other.accountId, provider: provider)
        defer {
            Task {
                await AccountManager.shared.clearAuthFailed(other.accountId)
                await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: other.accountId)
            }
            db.finish()
        }
        try await db.pool.write { db in try other.insert(db) }

        graph.refuseWrites(["PATCH"], code: "ErrorAccessDenied")
        await AccountManager.shared.drainCalendarQueue()
        let row = try await db.pool.read { db in try PendingCalendarOperation.fetchOne(db, key: other.id) }
        #expect(row?.status == PendingStatus.failed.rawValue && row?.failureKind == .missingPermission,
                "a 403 that is not a full mailbox must stay the missing-permission arm; got \(String(describing: row?.status)) \(String(describing: row?.failureKind))")
        #expect(await AccountManager.shared.authFailedAccounts.contains(other.accountId),
                "the missing-permission arm must still ask the user to sign in again")
    }
}

/// A fresh database installed as `AppDatabase.shared` with one account, for tests that drive the
/// calendar queue and check its rows between drains.
struct CalendarQueueTestDatabase {
    let pool: DatabasePool
    private let dir: URL
    private let previous: AppDatabase?

    init(accountId: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .outlook)
            acc.id = accountId
            try acc.insert(db)
        }
    }

    func finish() {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }
}
