/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Microsoft Graph allows four concurrent requests per app and mailbox, and asks a
/// throttled client to wait for `Retry-After` (#426). These tests pin the system
/// properties that follow:
///
/// - no more than four requests of one mailbox (Graph's documented limit) are
///   ever on the wire at once, whatever mix of backfill, actions, sends and
///   calendar calls is running;
/// - a 429 or 503 is retried after its `Retry-After`, and the waits of one call
///   add up to at most `HTTPConfig.retryWaitBudgetSeconds`; under an
///   `HTTPDeadline` a retry is made only if it would end before the deadline
///   (`GraphThrottlingQueueTests` drives that through the real queue);
/// - a request waiting out a `Retry-After` holds no slot, and a caller cancelled
///   while queued leaks none;
/// - every Graph request leg (token-refresh retries, draft deletes, upload
///   chunks) holds a slot of the mailbox's gate;
/// - Outlook body fetches run at most `GraphConfig.bodyFetchConcurrency` wide,
///   whatever width the caller asks for;
/// - a send refused with 429 or 503 is transient (stays queued, no strike), for
///   Outlook and Gmail alike; a 500 is a strike.
///
/// The wire is measured at `FakeHTTP`: a `WireMeter` counts a request from the
/// moment the fake receives it until just before its response is delivered. A
/// request its caller cancelled is returned to the caller before the transport
/// tears it down, so the gate can admit the next request while the fake still
/// counts the cancelled one; the wire bound is therefore checked on loads
/// without cancellation, and loads with cancellation check outcomes and slots.
/// A `Mutex` an escaping closure can capture (a `Mutex` itself is noncopyable).
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

@Suite("Graph throttling: four per mailbox, Retry-After", .timeLimit(.minutes(2)))
struct GraphThrottlingTests {

    /// Graph's documented limit, written out rather than read from
    /// `GraphConfig.maxConcurrentRequestsPerMailbox`: "Four concurrent requests"
    /// per app and mailbox (learn.microsoft.com/graph/throttling-limits, Outlook
    /// service limits). A wrong production constant then fails these tests
    /// instead of moving their oracle with it.
    static let graphDocumentedConcurrentRequests = 4

    // MARK: - Wire meter

    /// Requests in flight at the fake, and the most there ever were at once.
    final class WireMeter: Sendable {
        private struct State { var now = 0; var peak = 0; var total = 0 }
        private let state = Mutex(State())

        func enter() {
            state.withLock {
                $0.now += 1
                $0.total += 1
                $0.peak = max($0.peak, $0.now)
            }
        }

        func leave() { state.withLock { $0.now -= 1 } }

        var now: Int { state.withLock { $0.now } }
        var peak: Int { state.withLock { $0.peak } }
        var total: Int { state.withLock { $0.total } }
    }

    /// A response produced after `latency`, counted on the wire meanwhile. The
    /// latency is spent off the transport's loader thread (`FakeHTTP.parked`), so
    /// a slow response never holds back another request.
    static func metered(
        _ meter: WireMeter, latency: Duration, _ response: FakeHTTP.CannedResponse
    ) -> FakeHTTP.CannedResponse {
        meter.enter()
        return .parked {
            Thread.sleep(forTimeInterval: Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18)
            meter.leave()
            return response
        }
    }

    static let messageBody = FakeHTTP.CannedResponse.json(
        raw: #"{"id":"m","body":{"contentType":"text","content":"body"}}"#)
    static let emptyObject = FakeHTTP.CannedResponse.json(raw: "{}")
    static let calendarList = FakeHTTP.CannedResponse.json(raw: #"{"value":[]}"#)
    static let accepted = FakeHTTP.CannedResponse.raw(statusCode: 202)

    static func throttled(_ status: Int, retryAfter: Int?) -> FakeHTTP.CannedResponse {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = String(retryAfter) }
        return .raw(
            statusCode: status, headers: headers,
            body: Data(#"{"error":{"code":"ApplicationThrottled","message":"Too many requests"}}"#.utf8))
    }

    static func draft() -> DraftMessage {
        DraftMessage(to: ["recipient@example.com"], subject: "Subject", body: "Body",
                     inReplyTo: "parent@example.com", references: ["parent@example.com"])
    }

    /// Poll until `condition` holds. Every wait in this suite is bounded by the
    /// suite's time limit.
    static func waitUntil(_ condition: () -> Bool) async {
        while !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - HTTPConcurrencyGate

    @Test("The gate never admits more than its limit, and reaches it")
    func gateHoldsItsLimit() async {
        let gate = HTTPConcurrencyGate(limit: 3)
        let meter = WireMeter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.withSlot {
                        meter.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        meter.leave()
                    }
                }
            }
        }
        #expect(meter.peak == gate.limit)
        #expect(meter.total == 20)
    }

    @Test("Waiters are admitted in the order they arrived")
    func gateIsFirstInFirstOut() async {
        let gate = HTTPConcurrencyGate(limit: 1)
        let holding = WireMeter()
        let arrived = Locked<[Int]>([])
        let admitted = Locked<[Int]>([])

        let holder = Task {
            await gate.withSlot {
                holding.enter()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        await Self.waitUntil { holding.now == 1 }

        var waiters: [Task<Void, Never>] = []
        for index in 0..<6 {
            waiters.append(Task {
                arrived.withLock { $0.append(index) }
                await gate.withSlot { admitted.withLock { $0.append(index) } }
            })
            try? await Task.sleep(for: .milliseconds(20))
        }
        await holder.value
        for waiter in waiters { await waiter.value }

        let arrivalOrder = arrived.withLock { $0 }
        #expect(arrivalOrder.count == 6)
        #expect(admitted.withLock { $0 } == arrivalOrder)
    }

    struct BodyFailed: Error {}

    @Test("A body that throws still gives its slot back")
    func gateReleasesOnThrow() async {
        let gate = HTTPConcurrencyGate(limit: 1)
        await #expect(throws: BodyFailed.self) {
            try await gate.withSlot { throw BodyFailed() }
        }
        // With the slot leaked this would wait forever (bounded by the time limit).
        let ran = await gate.withSlot { true }
        #expect(ran)
    }

    @Test("A caller cancelled while queued leaks no slot, and the next one is still admitted")
    func gateSurvivesACancelledWaiter() async {
        let gate = HTTPConcurrencyGate(limit: 1)
        let holding = WireMeter()
        let release = Locked(false)
        let holder = Task {
            await gate.withSlot {
                holding.enter()
                await Self.waitUntil { release.withLock { $0 } }
            }
        }
        await Self.waitUntil { holding.now == 1 }
        let sawCancellation = Locked(false)
        let cancelled = Task {
            await gate.withSlot { sawCancellation.withLock { $0 = Task.isCancelled } }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let next = Task { await gate.withSlot { true } }
        try? await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        release.withLock { $0 = true }

        await holder.value
        await cancelled.value
        #expect(await next.value)
        #expect(sawCancellation.withLock { $0 }, "the cancelled caller is admitted in turn and sees its cancellation")
        #expect(await Self.allSlotsFree(gate))
    }

    /// True when every slot of `gate` can be held at once within `within`, i.e.
    /// no slot leaked. A task that cannot get a slot stays queued; that only
    /// happens when this returns false.
    static func allSlotsFree(_ gate: HTTPConcurrencyGate, within: Duration = .seconds(5)) async -> Bool {
        let entered = Locked(0)
        let done = Locked(false)
        for _ in 0..<gate.limit {
            Task {
                await gate.withSlot {
                    entered.withLock { $0 += 1 }
                    await Self.waitUntil { done.withLock { $0 } }
                }
            }
        }
        let deadline = ContinuousClock.now + within
        while entered.withLock({ $0 }) < gate.limit, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let allIn = entered.withLock { $0 } == gate.limit
        done.withLock { $0 = true }
        return allIn
    }

    @Test("One gate per mailbox, whatever the address's case")
    func mailboxGatesAreSharedPerMailbox() {
        let gate = GraphMailboxGates.gate(for: "Owner.426@Example.com")
        #expect(gate === GraphMailboxGates.gate(for: "owner.426@example.com"))
        #expect(gate !== GraphMailboxGates.gate(for: "other.426@example.com"))
        #expect(gate.limit == Self.graphDocumentedConcurrentRequests)
    }

    // MARK: - Retry-After

    @Test("A 429's Retry-After is waited for, not the exponential back-off")
    func retryAfterIsHonoured() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let script = FakeHTTP.ResponseScript([429, 200])
        let retryAfter = 2
        http.register(path: "/me/throttled", method: "GET") { _ in
            script.next() == 429 ? Self.throttled(429, retryAfter: retryAfter) : Self.emptyObject
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await performHTTPRequestWithRetry(
            url: "https://graph.microsoft.com/v1.0/me/throttled", method: "GET", body: nil, token: "token",
            retryableStatusCodes: HTTPRetryPolicy.graph.retryableStatusCodes, maxAttempts: 3,
            // Far below Retry-After: an elapsed time of at least Retry-After can only
            // come from honouring the header.
            initialDelay: 0.01, session: http.session)
        let elapsed = clock.now - start
        #expect(result.statusCode == 200)
        #expect(script.served == [429, 200])
        #expect(elapsed >= .seconds(retryAfter))
    }

    @Test("Each refusal's own Retry-After is waited for, not only the first one's")
    func everyRetryAfterIsHonoured() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Two refusals, the second asking for longer than the first; together
        // they stay inside the budget, so both waits are made.
        let retryAfters = [1, 3]
        #expect(TimeInterval(retryAfters.reduce(0, +)) <= HTTPConfig.retryWaitBudgetSeconds)
        let script = FakeHTTP.ResponseScript([429, 429, 200])
        let refusals = Locked(0)
        http.register(path: "/me/throttled", method: "GET") { _ in
            guard script.next() == 429 else { return Self.emptyObject }
            let index = refusals.withLock { count -> Int in
                defer { count += 1 }
                return count
            }
            return Self.throttled(429, retryAfter: retryAfters[index])
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await performHTTPRequestWithRetry(
            url: "https://graph.microsoft.com/v1.0/me/throttled", method: "GET", body: nil, token: "token",
            retryableStatusCodes: HTTPRetryPolicy.graph.retryableStatusCodes, maxAttempts: 3,
            // Far below either Retry-After, so only honouring both reaches their sum.
            initialDelay: 0.01, session: http.session)
        let elapsed = clock.now - start
        #expect(result.statusCode == 200)
        #expect(script.served == [429, 429, 200])
        #expect(elapsed >= .seconds(retryAfters.reduce(0, +)))
    }

    @Test("A Retry-After above the budget ends the retries at once")
    func retryAfterAboveTheBudgetIsNotWaited() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let retryAfter = Int(HTTPConfig.retryWaitBudgetSeconds) + 1
        http.register(path: "/me/throttled", method: "GET",
                      response: Self.throttled(429, retryAfter: retryAfter))
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await performHTTPRequestWithRetry(
            url: "https://graph.microsoft.com/v1.0/me/throttled", method: "GET", body: nil, token: "token",
            retryableStatusCodes: HTTPRetryPolicy.graph.retryableStatusCodes, maxAttempts: 3,
            initialDelay: 0.01, session: http.session)
        let elapsed = clock.now - start
        #expect(result.statusCode == 429)
        #expect(result.retryAfter == TimeInterval(retryAfter))
        #expect(http.recordedCalls().count == 1)
        #expect(elapsed < .seconds(HTTPConfig.retryWaitBudgetSeconds))
    }

    @Test("The waits of one call stop at the budget: a single-request queued action's last refusal is a refusal, not a timeout")
    func retryWaitsAddUpToTheBudget() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Exactly the budget: the first wait is honoured (the bound is inclusive),
        // a second would pass it, so the call returns the refusal after two requests.
        let retryAfter = Int(HTTPConfig.retryWaitBudgetSeconds)
        http.register(path: "/messages/", method: "PATCH", response: Self.throttled(429, retryAfter: retryAfter))
        let mail = ExchangeProvider(userEmail: Self.uniqueMailbox(), accessToken: { _ in "token" },
                                    session: http.session)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            // How `AccountOperationExecutor` runs a queued action.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                try await mail.markRead(ids: ["m1"], folder: "inbox")
            }
            Issue.record("a refused action must fail")
        } catch {
            #expect(Self.classify(error) == .refused, "\(error)")
            #expect(!SyncEngine.isConnectionError(error), "the queue charges a refusal, not a timeout")
        }
        let elapsed = clock.now - start
        #expect(http.recordedCalls().count == 2)
        #expect(elapsed >= .seconds(retryAfter))
        #expect(elapsed < .seconds(SyncConfig.pendingOperationTimeoutSeconds))
    }

    @Test("Retry-After parses delta-seconds only")
    func retryAfterParsing() {
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://graph.microsoft.com/v1.0/me")!, statusCode: 429,
                            httpVersion: "HTTP/1.1", headerFields: value.map { ["Retry-After": $0] } ?? [:])!
        }
        #expect(retryAfterSeconds(response("7")) == 7)
        #expect(retryAfterSeconds(response(" 0 ")) == 0)
        #expect(retryAfterSeconds(response(nil)) == nil)
        #expect(retryAfterSeconds(response("-1")) == nil)
        #expect(retryAfterSeconds(response("Wed, 21 Oct 2099 07:28:00 GMT")) == nil)
    }

    @Test("Graph's 503 is retried; a 500 is not")
    func graphPolicyRetries503Not500() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let unavailable = FakeHTTP.ResponseScript([503, 200])
        http.register(path: "/me/unavailable", method: "GET") { _ in
            unavailable.next() == 503 ? Self.throttled(503, retryAfter: 0) : Self.emptyObject
        }
        http.register(path: "/me/broken", method: "GET", response: .status(500))
        let authed = AuthedHTTP(
            auth: AccountAuthSource(accountId: "owner@example.com", accessToken: { _ in "token" }),
            retry: .graph, session: http.session)

        _ = try await authed.get("https://graph.microsoft.com/v1.0/me/unavailable")
        #expect(unavailable.served == [503, 200])

        await #expect(throws: HTTPError.self) {
            _ = try await authed.get("https://graph.microsoft.com/v1.0/me/broken")
        }
        #expect(http.recordedCalls().filter { $0.url.contains("/me/broken") }.count == 1)
    }

    @Test("A request waiting out Retry-After holds no slot")
    func retrySleepReleasesTheSlot() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // Long enough that "during the wait" and "after it" are seconds apart.
        let retryAfter = 4
        let script = FakeHTTP.ResponseScript([429, 200])
        http.register(path: "/me/first", method: "GET") { _ in
            script.next() == 429 ? Self.throttled(429, retryAfter: retryAfter) : Self.emptyObject
        }
        http.register(path: "/me/second", method: "GET", response: Self.emptyObject)
        let gate = HTTPConcurrencyGate(limit: 1)

        let first = Task {
            _ = try await performHTTPRequestWithRetry(
                url: "https://graph.microsoft.com/v1.0/me/first", method: "GET", body: nil, token: "token",
                retryableStatusCodes: HTTPRetryPolicy.graph.retryableStatusCodes, session: http.session, gate: gate)
        }
        await Self.waitUntil { !script.served.isEmpty }
        // The first request is now asleep for its Retry-After. Holding the only
        // slot through that sleep would keep this one off the wire until the
        // first one's retry had been answered.
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await performHTTPRequest(
            url: "https://graph.microsoft.com/v1.0/me/second", method: "GET", body: nil, token: "token",
            session: http.session, gate: gate)
        let elapsed = clock.now - start
        let servedFirstWhenSecondReturned = script.served
        try await first.value

        #expect(servedFirstWhenSecondReturned == [429],
                "the second request went out after the first one's retry, not during its wait")
        #expect(elapsed < .seconds(retryAfter) / 2, "the second request waited \(elapsed) for the slot")
        #expect(http.servedCallSequence() == ["GET /v1.0/me/first", "GET /v1.0/me/second", "GET /v1.0/me/first"])
        #expect(script.served == [429, 200])
    }

    // MARK: - Providers on the wire

    /// A mailbox address no other test uses: providers look their gate up by
    /// address, and gates live for the whole test process.
    static func uniqueMailbox() -> String { "mailbox-\(UUID().uuidString)@example.com" }

    /// How an operation ended: what the fuzz and the budget test check.
    enum Outcome: Equatable {
        case success, refused, cancelled
        case unexpected(String)
    }

    /// Success, a 429/503 refusal (the only fault the tests inject), a
    /// cancellation, or anything else.
    static func classify(_ error: Error?) -> Outcome {
        guard let error else { return .success }
        var underlying: Error = error
        if case ProviderError.networkError(let inner) = error { underlying = inner }
        if let http = underlying as? HTTPError, http.asksToRetryLater { return .refused }
        if case ExchangeCalendarError.httpError(let status, _) = underlying,
           HTTPConfig.retryLaterStatusCodes.contains(status) { return .refused }
        if underlying is CancellationError || (underlying as? URLError)?.code == .cancelled { return .cancelled }
        return .unexpected(String(describing: error))
    }

    /// Register every Graph route the provider tests use, each answering after
    /// `latency` with `outcome(request)` and counted by `meter`.
    static func registerGraph(
        _ http: FakeHTTP.Scenario, meter: WireMeter,
        latency: @escaping @Sendable () -> Duration,
        outcome: @escaping @Sendable (FakeHTTP.CannedResponse) -> FakeHTTP.CannedResponse = { $0 }
    ) {
        http.register(path: "/messages/", method: "GET") { _ in
            metered(meter, latency: latency(), outcome(messageBody))
        }
        http.register(path: "/messages/", method: "PATCH") { _ in
            metered(meter, latency: latency(), outcome(emptyObject))
        }
        http.register(path: "/sendMail", method: "POST") { _ in
            metered(meter, latency: latency(), outcome(accepted))
        }
        http.register(path: "/calendars", method: "GET") { _ in
            metered(meter, latency: latency(), outcome(calendarList))
        }
    }

    /// A seeded chaos point: most calls pass straight through; the rest yield a
    /// few times or park briefly, so tasks resume in orders latency alone does
    /// not produce.
    final class Chaos: Sendable {
        private let random: Locked<SplitMix64>
        init(seed: UInt64) { random = Locked(SplitMix64(seed: seed)) }
        func pick(_ bound: Int) -> Int { random.withLock { $0.pick(bound) } }
        func point() async {
            switch pick(4) {
            case 0: for _ in 0...pick(8) { await Task.yield() }
            case 1: try? await Task.sleep(for: .milliseconds(pick(6)))
            default: break
            }
        }
    }

    struct LoadResult {
        /// One entry per operation that ended (one per body for the body stream,
        /// operation 0), and whether that operation was cancelled.
        var outcomes: [(operation: Int, cancelled: Bool, outcome: Outcome)] = []
        var operations = 0
        var cancelledOperations = Set<Int>()
        var cancelled: Int { cancelledOperations.count }
    }

    /// Backfill at width 25, actions, sends and calendar listings, all at once,
    /// against the providers of one mailbox. With `chaos`, each operation starts
    /// after a chaos point; `cancel` picks about one operation in `cancelOneIn` to
    /// cancel at a random moment (its own generator, so a seed replays the same
    /// choices).
    static func runMixedLoad(
        mail: ExchangeProvider, calendar: ExchangeCalendarProvider,
        bodies: Int, actions: Int, sends: Int, listings: Int,
        chaos: Chaos? = nil, cancel: Chaos? = nil, cancelOneIn: Int = 0
    ) async -> LoadResult {
        let ended = Locked<[(Int, Outcome)]>([])
        var operations: [@Sendable () async -> Void] = []
        operations.append {
            let ids = (0..<bodies).map { "m\($0)" }
            for await result in await mail.fetchTextBodiesStream(ids: ids, concurrency: 25) {
                ended.withLock { $0.append((0, classify(result.error))) }
            }
        }
        for index in 0..<actions {
            operations.append {
                do { try await mail.markRead(ids: ["a\(index)"], folder: "inbox"); ended.withLock { $0.append((1 + index, .success)) } }
                catch { ended.withLock { $0.append((1 + index, classify(error))) } }
            }
        }
        for index in 0..<sends {
            operations.append {
                do { try await mail.send(draft: draft()); ended.withLock { $0.append((1 + actions + index, .success)) } }
                catch { ended.withLock { $0.append((1 + actions + index, classify(error))) } }
            }
        }
        for index in 0..<listings {
            operations.append {
                do { _ = try await calendar.listCalendars(); ended.withLock { $0.append((1 + actions + sends + index, .success)) } }
                catch { ended.withLock { $0.append((1 + actions + sends + index, classify(error))) } }
            }
        }
        var tasks: [Task<Void, Never>] = []
        var cancelledIndexes = Set<Int>()
        for (index, operation) in operations.enumerated() {
            tasks.append(Task {
                await chaos?.point()
                await operation()
            })
            if let cancel, cancelOneIn > 0, cancel.pick(cancelOneIn) == 0 {
                cancelledIndexes.insert(index)
                let task = tasks[index]
                let delay = cancel.pick(40)
                Task {
                    try? await Task.sleep(for: .milliseconds(delay))
                    task.cancel()
                }
            }
        }
        for task in tasks { await task.value }
        var result = LoadResult()
        result.outcomes = ended.withLock { $0 }.map { ($0.0, cancelledIndexes.contains($0.0), $0.1) }
        result.operations = operations.count
        result.cancelledOperations = cancelledIndexes
        return result
    }

    @Test("Mail and calendar of one mailbox share four requests on the wire")
    func providersShareFourPerMailbox() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let meter = WireMeter()
        Self.registerGraph(http, meter: meter, latency: { .milliseconds(20) })
        // Built as `AccountManager` builds them, from the account's address alone;
        // the address's case does not matter.
        let mailbox = Self.uniqueMailbox()
        let mail = ExchangeProvider(userEmail: mailbox.uppercased(), accessToken: { _ in "token" },
                                    session: http.session)
        let calendar = ExchangeCalendarProvider(mailbox: mailbox, accessToken: { _ in "token" },
                                                session: http.session)

        let result = await Self.runMixedLoad(
            mail: mail, calendar: calendar, bodies: 40, actions: 10, sends: 3, listings: 3)

        let ended: Int = result.outcomes.count
        let expected: Int = 40 + 10 + 3 + 3
        #expect(ended == expected)
        #expect(result.outcomes.allSatisfy { $0.outcome == .success })
        #expect(meter.peak == Self.graphDocumentedConcurrentRequests)
        #expect(meter.now == 0)
    }

    /// Every way a Graph request leaves the providers, each run eight at a time on
    /// one mailbox: the token-refresh retry of an ordinary request and of the
    /// 404-tolerant probe, a draft delete (its first try and its refresh retry),
    /// the upload-session chunk `PUT`, and the calendar's token-refresh retry.
    @Test("Every Graph request leg holds a slot of the mailbox's gate",
          arguments: ["refreshedRequest", "refreshedProbe", "deleteDraft", "uploadChunk", "calendarRefresh"])
    func everyLegIsGated(leg: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let meter = WireMeter()
        let latency = Duration.milliseconds(30)
        // A stale token is refused with 401, so every request also takes its
        // refresh retry; the upload leg needs no refusal.
        let stale = leg != "uploadChunk"
        let refreshed = Locked(0)
        @Sendable func answer(_ request: FakeHTTP.Request, _ fresh: FakeHTTP.CannedResponse) -> FakeHTTP.CannedResponse {
            let isStale = request.header("Authorization") == "Bearer stale"
            if !isStale { refreshed.withLock { $0 += 1 } }
            return Self.metered(meter, latency: latency, isStale ? .status(401) : fresh)
        }
        http.register(path: "/messages/", method: "PATCH") { answer($0, Self.emptyObject) }
        http.register(path: "/messages/", method: "GET") { answer($0, .status(404)) }
        http.register(path: "/attachments", method: "GET") { answer($0, .json(raw: #"{"value":[]}"#)) }
        http.register(path: "/messages/", method: "DELETE") { answer($0, .status(204)) }
        http.register(path: "/calendars", method: "GET") { answer($0, Self.calendarList) }
        let drafts = Locked(0)
        http.register(path: "/mailFolders/drafts/messages", method: "POST") { request in
            let id = drafts.withLock { $0 += 1; return $0 }
            return answer(request, .json(raw: "{\"id\":\"g\(id)\"}", statusCode: 201))
        }
        http.register(path: "/messages/", method: "POST") { request in
            answer(request, .json(raw: #"{"uploadUrl":"https://outlook.office.com/AttachmentSessions/s?authtoken=synthetic-token"}"#))
        }
        http.register(path: "AttachmentSessions", method: "PUT") { request in
            let range = request.header("Content-Range") ?? ""
            let bounds = range.split(whereSeparator: { " -/".contains($0) }).compactMap { Int($0) }
            let last = bounds.count == 3 && bounds[1] + 1 == bounds[2]
            return Self.metered(meter, latency: latency, .json(raw: "{}", statusCode: last ? 201 : 200))
        }
        let mailbox = Self.uniqueMailbox()
        let mail = ExchangeProvider(
            userEmail: mailbox, accessToken: { force in stale && !force ? "stale" : "fresh" },
            session: http.session)
        let calendar = ExchangeCalendarProvider(
            mailbox: mailbox, accessToken: { force in stale && !force ? "stale" : "fresh" },
            session: http.session)
        let large = DraftAttachment(filename: "large.bin", mimeType: "application/octet-stream",
                                    data: Data(repeating: 7, count: ExchangeDraftConfig.singlePostAttachmentLimitBytes))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    switch leg {
                    case "refreshedRequest": try await mail.markRead(ids: ["m\(index)"], folder: "inbox")
                    case "refreshedProbe": _ = try await mail.fetchDraftCopy(identity: .outlook(graphId: "d\(index)"))
                    case "deleteDraft": try await mail.deleteDraft(identity: .outlook(graphId: "d\(index)"))
                    case "calendarRefresh": _ = try await calendar.listCalendars()
                    default:
                        _ = try await mail.saveDraft(
                            DraftMessage(to: ["recipient@example.com"], subject: "Plan", body: "Text", attachments: [large]),
                            existingIdentity: nil, draftsFolderPath: "Drafts")
                    }
                }
            }
            try await group.waitForAll()
        }
        let puts = http.recordedCalls().filter { $0.method == "PUT" }.count
        #expect(leg != "uploadChunk" || puts == 8, "every upload sends its chunk")
        #expect(!stale || refreshed.withLock { $0 } >= 8, "\(leg): every operation took its token-refresh retry")
        #expect(meter.peak <= Self.graphDocumentedConcurrentRequests, "\(leg): peak \(meter.peak)")
        #expect(meter.now == 0)
    }

    @Test("A calendar request refused with 429 is retried after its Retry-After and succeeds")
    func calendarRetriesAfterRetryAfter() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let script = FakeHTTP.ResponseScript([429, 200])
        http.register(path: "/calendars", method: "GET") { _ in
            script.next() == 429 ? Self.throttled(429, retryAfter: 1) : Self.calendarList
        }
        let calendar = ExchangeCalendarProvider(mailbox: Self.uniqueMailbox(), accessToken: { _ in "token" },
                                                session: http.session)
        let calendars = try await calendar.listCalendars()
        #expect(calendars.isEmpty)
        #expect(script.served == [429, 200])
    }

    @Test("Outlook serves a wide body-fetch request at its own width, inside the provider")
    func bodyFetchWidthIsTheProvidersOwn() async {
        // The caller (the sync engine) asks for its profile's width and knows
        // nothing of Graph; the provider caps it, below the mailbox gate's limit.
        for stream in ["backfill", "bodies"] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let meter = WireMeter()
            Self.registerGraph(http, meter: meter, latency: { .milliseconds(20) })
            let mail = ExchangeProvider(userEmail: Self.uniqueMailbox(), accessToken: { _ in "token" },
                                        session: http.session)
            let ids = (0..<20).map { "m\($0)" }
            var yielded = 0
            if stream == "backfill" {
                for await _ in await mail.fetchBackfillBatch(ids: ids, concurrency: 25) { yielded += 1 }
            } else {
                for await _ in await mail.fetchTextBodiesStream(ids: ids, concurrency: 25) { yielded += 1 }
            }
            #expect(yielded == ids.count, "\(stream)")
            #expect(meter.peak == GraphConfig.bodyFetchConcurrency, "\(stream)")
            #expect(meter.peak < Self.graphDocumentedConcurrentRequests, "\(stream) leaves room under the mailbox limit")
            #expect(meter.total == ids.count, "\(stream)")
        }
    }

    @Test("Only a 429 or 503 refusal asks to be retried later")
    func onlyThrottledOrUnavailableAsksToRetryLater() {
        #expect(HTTPError.networkError(statusCode: 429).asksToRetryLater)
        #expect(HTTPError.networkError(statusCode: 503).asksToRetryLater)
        #expect(!HTTPError.networkError(statusCode: 500).asksToRetryLater)
        #expect(!HTTPError.invalidURL("https://graph.microsoft.com").asksToRetryLater)
    }

    @Test("A send refused with 429 or 503 stays queued without a strike; a 500 is a strike",
          arguments: ["outlook", "gmail"])
    func throttledSendIsTransient(provider kind: String) async {
        for (status, transient) in [(429, true), (503, true), (500, false)] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            // Above the budget, so the HTTP layer hands the refusal straight back.
            let refusal = Self.throttled(status, retryAfter: Int(HTTPConfig.retryWaitBudgetSeconds) + 1)
            http.register(path: "/sendMail", method: "POST", response: refusal)
            http.register(path: "/messages/send", method: "POST", response: refusal)
            do {
                if kind == "outlook" {
                    try await ExchangeProvider(userEmail: Self.uniqueMailbox(), accessToken: { _ in "token" },
                                               session: http.session).send(draft: Self.draft())
                } else {
                    try await GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" },
                                            session: http.session).send(draft: Self.draft())
                }
                Issue.record("\(kind): HTTP \(status) must fail the send")
            } catch {
                #expect(AccountManager.isTransientSendError(error) == transient, "\(kind): HTTP \(status)")
            }
        }
    }

    // MARK: - Seeded fuzz

    /// Seeds run on every test pass. `GRAPH_THROTTLE_FUZZ_SEED=0x…` runs only that
    /// one; `GRAPH_THROTTLE_FUZZ_ROUNDS=N` runs N rounds per seed (default 1).
    static let fuzzSeeds: [UInt64] = {
        if let raw = ProcessInfo.processInfo.environment["GRAPH_THROTTLE_FUZZ_SEED"],
           let seed = UInt64(raw.replacingOccurrences(of: "0x", with: ""), radix: 16) {
            return [seed]
        }
        return [0x426, 0xA11CE, 0xB0B5EED, 0xC0FFEE, 0xD15EA5E]
    }()

    static let fuzzRounds: Int = {
        ProcessInfo.processInfo.environment["GRAPH_THROTTLE_FUZZ_ROUNDS"].flatMap { Int($0) }.map { max(1, $0) } ?? 1
    }()

    /// Random latency, random 429/503 refusals (with and without a short
    /// `Retry-After`) and chaos points before every operation, under a mixed load
    /// on one mailbox; each round runs the load once as it is and once with
    /// random cancellation. Invariants:
    /// - without cancellation, the load reaches exactly four requests on the
    ///   wire and never more (with it, a cancelled request's teardown on the
    ///   transport can overlap the next admitted one: see the type's note);
    /// - every operation that was not cancelled ends in success or in an injected
    ///   refusal, and none ends in anything else;
    /// - afterwards nothing is on the wire and every slot of the gate is free.
    @Test("Fuzz: latency, throttling and chaos never exceed four on the wire; cancellation never leaks a slot",
          arguments: fuzzSeeds)
    func fuzzThrottledMixedLoad(seed: UInt64) async {
        for round in 0..<Self.fuzzRounds {
            for cancelling in [false, true] {
                let roundSeed = (seed &+ UInt64(round) &* 0x9E37_79B9_7F4A_7C15) ^ (cancelling ? 0x00C0_FFEE_00C0_FFEE : 0)
                let label = "seed 0x\(String(seed, radix: 16)) round \(round)\(cancelling ? " cancelling" : "")"
                let http = FakeHTTP.Scenario()
                defer { http.close() }
                let meter = WireMeter()
                let random = Locked(SplitMix64(seed: roundSeed))
                Self.registerGraph(
                    http, meter: meter,
                    latency: { .milliseconds(random.withLock { $0.pick(15) }) },
                    outcome: { success in
                        switch random.withLock({ $0.pick(20) }) {
                        case 0..<3: Self.throttled(429, retryAfter: 0)
                        case 3: Self.throttled(429, retryAfter: 1)
                        case 4..<6: Self.throttled(503, retryAfter: 0)
                        default: success
                        }
                    })
                let mailbox = Self.uniqueMailbox()
                let mail = ExchangeProvider(userEmail: mailbox, accessToken: { _ in "token" }, session: http.session)
                let calendar = ExchangeCalendarProvider(mailbox: mailbox, accessToken: { _ in "token" },
                                                        session: http.session)
                let (bodies, actions, sends, listings) = (
                    30 + random.withLock { $0.pick(20) }, 4 + random.withLock { $0.pick(8) },
                    1 + random.withLock { $0.pick(3) }, 1 + random.withLock { $0.pick(3) })

                let result = await Self.runMixedLoad(
                    mail: mail, calendar: calendar, bodies: bodies, actions: actions, sends: sends, listings: listings,
                    chaos: Chaos(seed: roundSeed ^ 0x5EED_5EED_5EED_5EED),
                    cancel: cancelling ? Chaos(seed: roundSeed ^ 0xCA9C_E1CA_9CE1_CA9C) : nil,
                    cancelOneIn: cancelling ? 6 : 0)

                let limit = Self.graphDocumentedConcurrentRequests
                let unexpected = result.outcomes.filter { !$0.cancelled && ![.success, .refused].contains($0.outcome) }
                #expect(unexpected.isEmpty, "\(label): \(unexpected.map(\.outcome))")
                for operation in 0..<result.operations where !result.cancelledOperations.contains(operation) {
                    let ends = result.outcomes.filter { $0.operation == operation }.count
                    #expect(ends == (operation == 0 ? bodies : 1), "\(label): operation \(operation) ends \(ends) times")
                }
                if !cancelling {
                    #expect(meter.peak <= limit, "\(label): peak \(meter.peak)")
                    #expect(meter.peak >= limit, "\(label): the load reaches the limit")
                }
                await Self.waitUntil { meter.now == 0 }
                #expect(await Self.allSlotsFree(GraphMailboxGates.gate(for: mailbox)), "\(label): no slot leaked")
            }
        }
    }
}
