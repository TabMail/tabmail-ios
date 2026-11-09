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
/// - no more than `GraphConfig.maxConcurrentRequestsPerMailbox` requests of one
///   mailbox are ever on the wire at once, whatever mix of backfill, actions,
///   sends and calendar calls is running;
/// - a 429 or 503 is retried after its `Retry-After`, and a `Retry-After` longer
///   than `HTTPConfig.maxHonouredRetryAfterSeconds` ends the retries at once;
/// - a request waiting out a `Retry-After` holds no slot;
/// - a send refused with 429 or 503 is transient (stays queued, no strike).
///
/// The wire is measured at `FakeHTTP`: a `WireMeter` counts a request from the
/// moment the fake receives it until just before its response is delivered.
/// A `Mutex` an escaping closure can capture (a `Mutex` itself is noncopyable).
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

@Suite("Graph throttling: four per mailbox, Retry-After", .timeLimit(.minutes(2)))
struct GraphThrottlingTests {

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

    @Test("One gate per mailbox, whatever the address's case")
    func mailboxGatesAreSharedPerMailbox() {
        let gate = GraphMailboxGates.gate(for: "Owner.426@Example.com")
        #expect(gate === GraphMailboxGates.gate(for: "owner.426@example.com"))
        #expect(gate !== GraphMailboxGates.gate(for: "other.426@example.com"))
        #expect(gate.limit == GraphConfig.maxConcurrentRequestsPerMailbox)
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

    @Test("A Retry-After above the cap ends the retries at once")
    func retryAfterAboveTheCapIsNotWaited() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let retryAfter = Int(HTTPConfig.maxHonouredRetryAfterSeconds) + 1
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
        #expect(elapsed < .seconds(HTTPConfig.maxHonouredRetryAfterSeconds))
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
        let script = FakeHTTP.ResponseScript([429, 200])
        http.register(path: "/me/first", method: "GET") { _ in
            script.next() == 429 ? Self.throttled(429, retryAfter: 1) : Self.emptyObject
        }
        http.register(path: "/me/second", method: "GET", response: Self.emptyObject)
        let gate = HTTPConcurrencyGate(limit: 1)
        let finished = Locked<[String]>([])

        let first = Task {
            _ = try await performHTTPRequestWithRetry(
                url: "https://graph.microsoft.com/v1.0/me/first", method: "GET", body: nil, token: "token",
                retryableStatusCodes: HTTPRetryPolicy.graph.retryableStatusCodes, session: http.session, gate: gate)
            finished.withLock { $0.append("first") }
        }
        await Self.waitUntil { !script.served.isEmpty }
        // The first request is now asleep for its Retry-After. Holding the only
        // slot through that sleep would keep this one waiting until it ends.
        _ = try await performHTTPRequest(
            url: "https://graph.microsoft.com/v1.0/me/second", method: "GET", body: nil, token: "token",
            session: http.session, gate: gate)
        finished.withLock { $0.append("second") }
        try await first.value

        #expect(finished.withLock { $0 } == ["second", "first"])
        #expect(script.served == [429, 200])
    }

    // MARK: - Providers on the wire

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

    /// Backfill at width 25, actions, sends and calendar listings, all at once,
    /// against providers sharing `gate`. Returns how many operations finished.
    static func runMixedLoad(
        mail: ExchangeProvider, calendar: ExchangeCalendarProvider,
        bodies: Int, actions: Int, sends: Int, listings: Int
    ) async -> Int {
        let finished = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let ids = (0..<bodies).map { "m\($0)" }
                for await _ in await mail.fetchTextBodiesStream(ids: ids, concurrency: 25) {
                    finished.withLock { $0 += 1 }
                }
            }
            for index in 0..<actions {
                group.addTask {
                    try? await mail.markRead(ids: ["a\(index)"], folder: "inbox")
                    finished.withLock { $0 += 1 }
                }
            }
            for _ in 0..<sends {
                group.addTask {
                    try? await mail.send(draft: draft())
                    finished.withLock { $0 += 1 }
                }
            }
            for _ in 0..<listings {
                group.addTask {
                    _ = try? await calendar.listCalendars()
                    finished.withLock { $0 += 1 }
                }
            }
        }
        return finished.withLock { $0 }
    }

    @Test("Mail and calendar of one mailbox share four requests on the wire")
    func providersShareFourPerMailbox() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let meter = WireMeter()
        Self.registerGraph(http, meter: meter, latency: { .milliseconds(20) })
        let gate = HTTPConcurrencyGate(limit: GraphConfig.maxConcurrentRequestsPerMailbox)
        let mail = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" },
                                    session: http.session, mailboxGate: gate)
        let calendar = ExchangeCalendarProvider(accessToken: { _ in "token" }, mailboxGate: gate,
                                                session: http.session)

        let finished = await Self.runMixedLoad(
            mail: mail, calendar: calendar, bodies: 40, actions: 10, sends: 3, listings: 3)

        #expect(finished == 40 + 10 + 3 + 3)
        #expect(meter.peak == GraphConfig.maxConcurrentRequestsPerMailbox)
        #expect(meter.now == 0)
    }

    @Test("A send refused with 429 or 503 stays queued without a strike; a 500 is a strike")
    func throttledSendIsTransient() async {
        for (status, transient) in [(429, true), (503, true), (500, false)] {
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            // Above the cap, so the HTTP layer hands the refusal straight back.
            let retryAfter = Int(HTTPConfig.maxHonouredRetryAfterSeconds) + 1
            http.register(path: "/sendMail", method: "POST",
                          response: Self.throttled(status, retryAfter: retryAfter))
            let provider = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" },
                                            session: http.session)
            do {
                try await provider.send(draft: Self.draft())
                Issue.record("HTTP \(status) must fail the send")
            } catch {
                #expect(AccountManager.isTransientSendError(error) == transient, "HTTP \(status)")
            }
        }
    }

    // MARK: - Seeded fuzz

    /// Seeds run on every test pass. `GRAPH_THROTTLE_FUZZ_SEED=0x…` runs only that one.
    static let fuzzSeeds: [UInt64] = {
        if let raw = ProcessInfo.processInfo.environment["GRAPH_THROTTLE_FUZZ_SEED"],
           let seed = UInt64(raw.replacingOccurrences(of: "0x", with: ""), radix: 16) {
            return [seed]
        }
        return [0x426, 0xA11CE, 0xB0B5EED, 0xC0FFEE, 0xD15EA5E]
    }()

    /// Random latency and random 429/503 refusals (with and without a short
    /// `Retry-After`) under a mixed load on one mailbox. Invariants: never more
    /// than four requests on the wire, the limit is actually reached, every
    /// operation finishes, and nothing is left on the wire.
    @Test("Fuzz: random latency and throttling never exceed four on the wire", arguments: fuzzSeeds)
    func fuzzThrottledMixedLoad(seed: UInt64) async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let meter = WireMeter()
        let random = Locked(SplitMix64(seed: seed))
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
        let gate = HTTPConcurrencyGate(limit: GraphConfig.maxConcurrentRequestsPerMailbox)
        let mail = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" },
                                    session: http.session, mailboxGate: gate)
        let calendar = ExchangeCalendarProvider(accessToken: { _ in "token" }, mailboxGate: gate,
                                                session: http.session)
        let (bodies, actions, sends, listings) = (
            30 + random.withLock { $0.pick(20) }, 4 + random.withLock { $0.pick(8) },
            1 + random.withLock { $0.pick(3) }, 1 + random.withLock { $0.pick(3) })

        let finished = await Self.runMixedLoad(
            mail: mail, calendar: calendar, bodies: bodies, actions: actions, sends: sends, listings: listings)

        let label = "seed 0x\(String(seed, radix: 16))"
        #expect(finished == bodies + actions + sends + listings, "\(label): every operation finishes")
        #expect(meter.peak <= GraphConfig.maxConcurrentRequestsPerMailbox, "\(label): peak \(meter.peak)")
        #expect(meter.peak == GraphConfig.maxConcurrentRequestsPerMailbox, "\(label): the load reaches the limit")
        #expect(meter.now == 0, "\(label): nothing left on the wire")
        #expect(meter.total >= finished, "\(label): every operation reached the wire")
    }
}
