/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Graph and Gmail refusals as the app's own queues see them (#426), end to end
/// through `AccountManager`:
///
/// - a queued action runs under `SyncConfig.pendingOperationTimeoutSeconds`; a
///   refusal the HTTP layer receives in time reaches the queue as a refusal
///   (`retryCount` charged, the intention kept) as long as each retry is no
///   slower than the request before it, and a request still on the wire at the
///   deadline is an uncounted timeout with the intention kept;
/// - a persisted send refused with 429 or 503 stays queued with its content whole,
///   no strike and no acceptance stamp, and goes out once the server accepts it;
///   a 500 is a strike;
/// - the Outlook providers `AccountManager` builds for an account (an ordinary
///   one and a calendar-only one) share the mailbox's four requests with every
///   other requester of that mailbox.
///
/// The wire oracles reuse `GraphThrottlingTests`' fake-server helpers.
@Suite("Graph throttling through the queues", .serialized, .processGlobalState, .timeLimit(.minutes(2)))
struct GraphThrottlingQueueTests {

    private typealias Wire = GraphThrottlingTests

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let account: Account
    }

    /// Graph folder ids are the folder paths on Exchange.
    private static let inbox = "graph-throttle-inbox"

    /// How long the fake server takes to answer each request of a slow queued
    /// action.
    private static let slowAnswer = Duration.seconds(3)

    /// A Sendable on/off switch a route handler reads.
    private final class Switch: Sendable {
        private let state = Mutex(false)
        var isOn: Bool { state.withLock { $0 } }
        func turnOn() { state.withLock { $0 = true } }
    }

    /// A temporary database installed as `AppDatabase.shared`, holding one account
    /// (its id a fresh UUID, distinct from its address, as in production) and its
    /// Inbox. No Sent folder: a send the server accepts is then finalized at once.
    private func fixture(_ provider: AccountProvider, calendarOnly: Bool) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        var account = Account(emailAddress: Wire.uniqueMailbox(), displayName: "Throttled", provider: provider)
        account.calendarOnly = calendarOnly
        let stored = account
        try pool.writeWithoutTransaction { db in
            try stored.insert(db)
            try Folder(name: Self.inbox, path: Self.inbox, role: .inbox, accountId: stored.id).insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, account: stored)
    }

    /// Run `body` against a fresh fixture and fake server, and tear both down
    /// whether it returns or throws.
    private func withFixture(
        _ provider: AccountProvider, calendarOnly: Bool = false,
        _ body: (Fixture, FakeHTTP.Scenario) async throws -> Void
    ) async throws {
        let fixture = try fixture(provider, calendarOnly: calendarOnly)
        let http = FakeHTTP.Scenario()
        do {
            try await body(fixture, http)
        } catch {
            await finish(fixture, http)
            throw error
        }
        await finish(fixture, http)
    }

    private func finish(_ fixture: Fixture, _ http: FakeHTTP.Scenario) async {
        await AccountManager.shared.disconnectAccount(fixture.account)
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.account.id)
        http.close()
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func register(_ provider: any EmailProvider, _ fixture: Fixture) async {
        await AccountManager.shared.registerProviderForTesting(accountId: fixture.account.id, provider: provider)
    }

    private func outlook(_ fixture: Fixture, _ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: fixture.account.emailAddress, accessToken: { _ in "token" }, session: http.session)
    }

    /// A local header as an Exchange sync leaves it: addressed by its Graph id.
    @discardableResult
    private func seedHeader(_ fixture: Fixture, graphId: String) throws -> MessageHeader {
        let header = MessageHeader(
            messageId: graphId,
            subject: "throttled \(graphId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: fixture.account.emailAddress,
            date: Date(),
            snippet: "throttled body",
            folderId: MessageIdentity.folderId(accountId: fixture.account.id, folderPath: Self.inbox),
            accountId: fixture.account.id,
            folderPath: Self.inbox,
            isInInbox: true)
        try fixture.pool.writeWithoutTransaction { db in try header.insert(db) }
        return header
    }

    private func queuedOperations(_ fixture: Fixture) throws -> [PendingOperation] {
        try fixture.pool.read { db in try PendingOperation.fetchAll(db) }
    }

    /// How many times, and how often, `waitForQuietQueue` checks the queue.
    private static let quietQueueAttempts = 200
    private static let quietQueueInterval = Duration.milliseconds(10)

    /// Wait, bounded, until no drain owns the queue. A gesture such as `markRead`
    /// ends by starting a drain of its own; with no provider registered it changes
    /// nothing, but it still owns the queue until it returns.
    private func waitForQuietQueue() async -> Bool {
        for _ in 0..<Self.quietQueueAttempts {
            if await AccountManager.shared.pendingQueueIsQuiescentForTesting() { return true }
            try? await Task.sleep(for: Self.quietQueueInterval)
        }
        return await AccountManager.shared.pendingQueueIsQuiescentForTesting()
    }

    /// Register the provider and run ONE drain from a quiet queue, timed.
    private func drainOnce(_ fixture: Fixture, provider: any EmailProvider) async throws -> Duration {
        try #require(await waitForQuietQueue(), "an earlier drain still owns the queue")
        await register(provider, fixture)
        let clock = ContinuousClock()
        let start = clock.now
        await AccountManager.shared.drainPendingQueue()
        return clock.now - start
    }

    // MARK: - The action queue's deadline

    /// How the server refuses each request of a queued mark-read, and how many
    /// requests that takes.
    struct SlowRefusal: Sendable, CustomTestStringConvertible {
        let retryAfter: Int?
        let requests: Int
        var testDescription: String {
            retryAfter.map { "503 with Retry-After \($0)" } ?? "503 without Retry-After"
        }
    }

    /// Each refusal takes `slowAnswer` (3 s) to arrive, and the queue's deadline is
    /// 15 s. Without a header the back-off waits 1 s, then 2 s: the third refusal
    /// arrives at about 3 + 1 + 3 + 2 + 3 = 12 s, and a fourth request (a 4 s wait
    /// and a 3 s request) would end at 19 s, so it is not made. With `Retry-After`
    /// 10 (inside the wait budget) a retry would end at 3 + 10 + 3 = 16 s, so none
    /// is made. A retry made anyway would still be on the wire at 15 s, and the
    /// queue would cut it off as an uncounted timeout.
    static let slowRefusals = [
        SlowRefusal(retryAfter: nil, requests: 3),
        SlowRefusal(retryAfter: 10, requests: 1),
    ]

    @Test("A queued action whose refusals arrive slowly is charged a refusal before its deadline, not timed out",
          arguments: slowRefusals)
    func slowRefusalReachesTheQueueAsARefusal(_ refusal: SlowRefusal) async throws {
        try await withFixture(.outlook) { f, http in
            let meter = Wire.WireMeter()
            http.register(path: "/messages/", method: "PATCH") { _ in
                Wire.metered(meter, latency: Self.slowAnswer, Wire.throttled(503, retryAfter: refusal.retryAfter))
            }
            let header = try seedHeader(f, graphId: "graph-slow-refusal")
            // No provider yet, so the gesture is queued, and the drain it starts
            // leaves it there. Read the queue once that drain has returned.
            await AccountManager.shared.markRead([header])
            try #require(await waitForQuietQueue(), "the gesture's own drain never returned")
            let queued = try queuedOperations(f)
            #expect(queued.count == 1, "the gesture was not queued")
            guard queued.count == 1 else { return }

            let elapsed = try await drainOnce(f, provider: outlook(f, http))
            await Wire.waitUntil { meter.now == 0 }

            let after = try queuedOperations(f)
            #expect(after.count == 1, "the user's mark-read was dropped")
            guard after.count == 1 else { return }
            #expect(after[0].id == queued[0].id)
            #expect(after[0].type == .markRead)
            #expect(after[0].messageIds == queued[0].messageIds)
            #expect(after[0].status == PendingStatus.queued.rawValue)
            #expect(after[0].retryCount == queued[0].retryCount + 1, """
                the refusal was not charged (\(after[0].retryCount)): it reached the queue as a timeout, \
                which never counts toward the refusal limit
                """)
            #expect(http.recordedCalls().filter { $0.method == "PATCH" }.count == refusal.requests)
            #expect(elapsed < .seconds(SyncConfig.pendingOperationTimeoutSeconds),
                    "the drain ran into the queue's deadline: \(elapsed)")
        }
    }

    /// The control: an action of two requests (a label's category read, then its
    /// write), each answered after 8 s, has its write still on the wire at the 15 s
    /// deadline. Its outcome is unknown, so the queue times it out, charges
    /// nothing and keeps the intention for the next drain.
    @Test("A queued action still on the wire at its deadline times out uncharged, its intention kept")
    func requestOnTheWireAtTheDeadlineTimesOutUncharged() async throws {
        try await withFixture(.outlook) { f, http in
            let meter = Wire.WireMeter()
            let answer = Duration.seconds(8)
            http.register(path: "/messages/", method: "GET") { _ in
                Wire.metered(meter, latency: answer, .json(raw: #"{"id":"graph-label","categories":[]}"#))
            }
            http.register(path: "/messages/", method: "PATCH") { _ in
                Wire.metered(meter, latency: answer, Wire.emptyObject)
            }
            try seedHeader(f, graphId: "graph-label")
            let op = PendingOperation(
                type: .addUserLabel, messageIds: ["graph-label"],
                accountId: f.account.id, folderPath: Self.inbox, userLabelId: "Receipts")
            try await f.pool.write { db in
                var row = op
                try row.insert(db)
            }

            let elapsed = try await drainOnce(f, provider: outlook(f, http))
            await Wire.waitUntil { meter.now == 0 }

            let after = try queuedOperations(f)
            #expect(after.count == 1, "the user's label was dropped")
            guard after.count == 1 else { return }
            #expect(after[0].id == op.id)
            #expect(after[0].messageIds == ["graph-label"])
            #expect(after[0].userLabelId == "Receipts")
            #expect(after[0].status == PendingStatus.queued.rawValue)
            #expect(after[0].retryCount == 0, "a timeout was charged as a refusal")
            #expect(http.servedCallSequence().count == 2, "the write never went out, so no request was cut off")
            #expect(elapsed >= .seconds(SyncConfig.pendingOperationTimeoutSeconds))
        }
    }

    // MARK: - The outbox

    @Test("A persisted send refused with 429 or 503 stays queued whole with no strike and goes out later; a 500 is a strike",
          arguments: [AccountProvider.outlook, .gmail])
    func refusedSendStaysQueued(provider kind: AccountProvider) async throws {
        for (status, transient) in [(429, true), (503, true), (500, false)] {
            try await withFixture(kind) { f, http in
                let accepting = Switch()
                // Above the wait budget, so the HTTP layer hands the refusal straight back.
                let refusal = Wire.throttled(status, retryAfter: Int(HTTPConfig.retryWaitBudgetSeconds) + 1)
                let sendPath = kind == .outlook ? "/sendMail" : "/messages/send"
                let acceptance = kind == .outlook ? Wire.accepted : Wire.emptyObject
                http.register(path: sendPath, method: "POST") { _ in accepting.isOn ? acceptance : refusal }
                let provider: any EmailProvider = kind == .outlook
                    ? outlook(f, http)
                    : GmailProvider(userEmail: f.account.emailAddress, accessToken: { _ in "token" }, session: http.session)
                let draft = DraftMessage(
                    to: ["recipient@example.com"], subject: "Refused with \(status)", body: "Body of the \(status) send")
                var message = OutboxMessage(accountId: f.account.id, draft: draft)
                message.holdUntil = Date().addingTimeInterval(-60)
                let seeded = message
                try await f.pool.write { db in try seeded.insert(db) }
                await register(provider, f)

                await AccountManager.shared.drainOutbox()

                let label = "\(kind) HTTP \(status)"
                let sends = { http.recordedCalls().filter { $0.method == "POST" }.count }
                #expect(sends() == 1, "\(label): the send never reached the server")
                let refused = try await f.pool.read { db in try OutboxMessage.fetchOne(db, key: seeded.id) }
                #expect(refused != nil, "\(label): the send was dropped")
                guard let refused else { return }
                #expect(refused.outboxStatus == .queued, "\(label): \(refused.outboxStatus)")
                #expect(refused.retryCount == (transient ? 0 : 1), "\(label): strikes \(refused.retryCount)")
                #expect(refused.sentAt == nil, "\(label): a refused send carries an acceptance stamp")
                #expect(refused.to == draft.to && refused.subject == draft.subject && refused.body == draft.body,
                        "\(label): the queued send lost its content")
                guard transient else { return }

                accepting.turnOn()
                await AccountManager.shared.drainOutbox()
                #expect(sends() == 2, "\(label): the queued send was not retried")
                let accepted = try await f.pool.read { db in try OutboxMessage.fetchOne(db, key: seeded.id) }
                #expect(accepted == nil, "\(label): the accepted send was not finalized")
            }
        }
    }

    // MARK: - The providers AccountManager builds

    /// `connectAccount` builds the Outlook mail and calendar providers through its
    /// own factories. Whatever they are keyed by, every requester of the mailbox
    /// (here: its mail provider, or for a calendar-only account another mail
    /// provider of the same address) must share its four requests.
    @Test("The Outlook providers AccountManager builds share the mailbox's four requests",
          arguments: [false, true])
    func builtProvidersShareTheMailboxGate(calendarOnly: Bool) async throws {
        try await withFixture(.outlook, calendarOnly: calendarOnly) { f, http in
            let meter = Wire.WireMeter()
            Wire.registerGraph(http, meter: meter, latency: { .milliseconds(20) })
            // `connect()` reads the profile.
            http.register(path: "/v1.0/me", method: "GET", response: Wire.emptyObject)
            try ProviderCredentialStore.shared.install(
                accountId: f.account.id,
                tokens: .init(accessToken: "token", refreshToken: "refresh",
                              expiresAt: Date().addingTimeInterval(3600)))
            do {
                try await AuthedHTTP.$sessionOverride.withValue(http.session) {
                    try await AccountManager.shared.connectAccount(f.account)
                    let built = await AccountManager.shared.calendarProviders[f.account.id] as? ExchangeCalendarProvider
                    let calendar = try #require(built, "no Outlook calendar provider was built")
                    let mail: ExchangeProvider
                    if calendarOnly {
                        #expect(await AccountManager.shared.providers[f.account.id] == nil)
                        mail = outlook(f, http)
                    } else {
                        let builtMail = await AccountManager.shared.providers[f.account.id] as? ExchangeProvider
                        mail = try #require(builtMail, "no Outlook mail provider was built")
                    }

                    let result = await Wire.runMixedLoad(
                        mail: mail, calendar: calendar, bodies: 20, actions: 6, sends: 2, listings: 8)

                    let ended: Int = result.outcomes.count
                    #expect(ended == 20 + 6 + 2 + 8)
                    #expect(result.outcomes.allSatisfy { $0.outcome == .success })
                    #expect(meter.peak == Wire.graphDocumentedConcurrentRequests, "peak \(meter.peak)")
                    #expect(meter.now == 0)
                }
            } catch {
                try ProviderCredentialStore.shared.remove(accountId: f.account.id)
                throw error
            }
            try ProviderCredentialStore.shared.remove(accountId: f.account.id)
        }
    }
}
