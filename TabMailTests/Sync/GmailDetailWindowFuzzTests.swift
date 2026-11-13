/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Seeded adversarial schedules for the Gmail detail fetch
/// (`GmailProvider.fetchMessageDetails`), which keeps the account request
/// gate's width of gets in flight and refills the window as answers arrive.
/// Driven on `FakeHTTP` with a real provider, so the window, the gate and the
/// HTTP layer's rate-limit backoff all run as they do in the app.
///
/// Each iteration draws, from its seed: a batch of 0 to several windows of ids
/// (duplicates included), an answer per id (readable, gone 404/410, a server
/// or client error, an unreadable or undated record, a dropped connection, a
/// 429 answered on the retry), a latency per answer, and one of three
/// schedules:
/// - **plain**: the answers as drawn;
/// - **other request**: the first window's answers are held, another request
///   on the account joins the gate's queue, and one answer is released;
/// - **cancel**: the fetch is cancelled at a seeded get, either while that
///   get waits for its answer or while it waits out a 429 backoff.
///
/// Invariants checked on every iteration, never expected values for a
/// particular schedule:
/// 1. **Background progress**: the first window's gets (up to the gate's
///    width) are all on the wire before any of them is answered. A fetch that
///    waits for each get fails this, and so misses the background deadline.
/// 2. **First freed slot**: a request that joined the gate while the window was
///    full reaches the server before any further get of the fetch.
/// 3. **Results**: a fetch with no dropped connection returns exactly the
///    readable ones (as a multiset) and names exactly the ones whose own answer
///    was unusable (a server or client error, an unreadable or undated record),
///    having asked for each id once (plus each 429's retry), never more than
///    the gate's width at once.
/// 4. **Throw semantics**: a fetch with a dropped connection throws that
///    failure, never a cancellation; a cancelled fetch never returns success,
///    and with no dropped connection it throws its cancellation.
/// 5. **Termination**: the fetch returns within a bound, nothing it started
///    is still in flight afterwards, and nothing more reaches the server
///    (after a failure or a cancellation, at most the gate's width of gets
///    already on their way when they were cancelled; see `run`).
/// 6. **Gate reuse**: afterwards a full width of gets is in flight together.
///
/// Knobs (`TEST_RUNNER_` prefix on the CLI, so they reach the simulator-hosted
/// test process): `GMAIL_DETAIL_FUZZ_ITERATIONS` (default
/// `FuzzConfig.defaultIterations`) and `GMAIL_DETAIL_FUZZ_SEED` (`0x…` hex or
/// decimal). A failure names its base seed and iteration; replay it with that
/// seed and `ITERATIONS` set to the iteration plus one. The run stops at the
/// first failing iteration so a broken producer costs one bounded timeout.
@Suite("Gmail detail fetch window fuzzer", .serialized)
struct GmailDetailWindowFuzzTests {

    enum FuzzConfig {
        static let defaultIterations = 18
        static let defaultSeed: UInt64 = 0x6D41_DE7A_0000_0001

        static var iterations: Int {
            if let raw = ProcessInfo.processInfo.environment["GMAIL_DETAIL_FUZZ_ITERATIONS"], let v = Int(raw), v > 0 { return v }
            return defaultIterations
        }

        static var seed: UInt64 {
            guard let raw = ProcessInfo.processInfo.environment["GMAIL_DETAIL_FUZZ_SEED"] else { return defaultSeed }
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") { return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed }
            return UInt64(raw) ?? defaultSeed
        }

        /// Most windows of ids in one batch, plus a few beyond the last full one.
        static let maxWindows = 4
        static let extraIds = 3
        /// Seeded per-answer latency bound. Small: it stretches the await
        /// windows without making the default pass slow.
        static let latencyMaxMilliseconds = 8
        /// Percent chance that an id fails (only on iterations that allow failures).
        static let failurePercent = 15
        /// Percent chance that an id is gone.
        static let gonePercent = 15
        /// Percent chance that a plain iteration has one id answered 429 first
        /// (each one costs the HTTP layer's first backoff).
        static let rateLimitPercent = 33
        /// Percent chance that a batch carries a duplicate id.
        static let duplicatePercent = 25
        /// How long the first window may take to be on the wire in full.
        static let windowArrivalTimeoutSeconds: Double = 2
        /// Bound on how long any held answer waits for the test.
        static let holdTimeoutSeconds: Double = 10
        /// Bound on one fetch, including a 429 retry.
        static let fetchDeadlineSeconds: Double = 15
        /// See `DeltaDetailFetchFailureTests.admissionSettleMilliseconds`.
        static let admissionSettleMilliseconds = 30
        /// Seeded jitter before a cancel; well inside the first backoff.
        static let cancelJitterMaxMilliseconds = 20
        /// How long the wire must stay quiet after the fetch returned.
        static let quietAfterReturnMilliseconds = 50
    }

    enum Schedule: CaseIterable { case plain, otherRequest, cancel }
    enum CancelPoint { case awaitingAnswer, inRateLimitBackoff }
    enum Failure: CaseIterable { case serverError, clientError, unreadableBody, undatedRecord, transportError }
    enum Answer: Equatable {
        case readable, gone(Int), failed(Failure), rateLimitedOnce

        var isReadable: Bool { self == .readable || self == .rateLimitedOnce }
        /// A failure about the request, not the message: it fails the fetch.
        var isFailure: Bool { self == .failed(.transportError) }
        /// The server's answer for the one message is unusable: it is named.
        var isUnreadable: Bool { if case .failed = self { return !isFailure }; return false }
    }

    struct Plan: Sendable {
        let iteration: Int
        let schedule: Schedule
        let ids: [String]
        let answers: [String: Answer]
        let latencies: [Int]
        let cancelAt: Int?
        let cancelPoint: CancelPoint
        let cancelJitterMilliseconds: Int

        var width: Int { GmailAPI.maxConcurrentRequests }
        var firstWindow: Int { min(width, ids.count) }
        var expectsFailure: Bool { ids.contains { answers[$0]!.isFailure } }
        var readable: [String] { ids.filter { answers[$0]!.isReadable }.sorted() }
        var unreadable: [String] { ids.filter { answers[$0]!.isUnreadable }.sorted() }
        var retries: Int { Set(ids).filter { answers[$0] == .rateLimitedOnce }.count }

        func latency(arrival: Int) -> Int { latencies[arrival % latencies.count] }

        func response(id: String, attempt: Int) -> FakeHTTP.CannedResponse {
            switch answers[id]! {
            case .readable: return .json(raw: DeltaDetailFetchFailureTests.gmailMessageJSON(id: id))
            case .rateLimitedOnce:
                return attempt == 1 ? .status(429) : .json(raw: DeltaDetailFetchFailureTests.gmailMessageJSON(id: id))
            case .gone(let status): return .status(status)
            case .failed(.serverError): return .status(503)
            case .failed(.clientError): return .status(400)
            case .failed(.unreadableBody): return .json(raw: "not a message")
            case .failed(.undatedRecord): return .json(raw: DeltaDetailFetchFailureTests.gmailMessageJSON(id: id, dated: false))
            case .failed(.transportError): return .transportError(.networkConnectionLost)
            }
        }

        var summary: String {
            let failing = ids.filter { answers[$0]!.isFailure || answers[$0]!.isUnreadable }.count
            let gone = ids.filter { if case .gone = answers[$0]! { return true }; return false }.count
            let cancel = cancelAt.map { ", cancel at get \($0) \(cancelPoint)" } ?? ""
            return "\(schedule), \(ids.count) ids (\(Set(ids).count) distinct), \(failing) failing, \(gone) gone, \(retries) rate-limited\(cancel)"
        }
    }

    static func makePlan(iteration: Int, rng: inout SplitMix64) -> Plan {
        let width = GmailAPI.maxConcurrentRequests
        let schedule = Schedule.allCases[iteration % Schedule.allCases.count]
        // Odd iterations may fail; even ones never do, so every schedule is
        // also run with every id readable or gone.
        let failuresAllowed = !iteration.isMultiple(of: 2)
        let count: Int
        switch schedule {
        case .plain: count = rng.pick(width * FuzzConfig.maxWindows + FuzzConfig.extraIds)
        case .otherRequest: count = width + 1 + rng.pick(width * (FuzzConfig.maxWindows - 1))
        case .cancel: count = 1 + rng.pick(width * FuzzConfig.maxWindows)
        }
        var ids = (0..<count).map { "fz-\(iteration)-\($0)" }
        if ids.count >= 2, rng.pick(100) < FuzzConfig.duplicatePercent {
            ids[rng.pick(ids.count)] = ids[rng.pick(ids.count)]
        }
        var answers: [String: Answer] = [:]
        for id in ids where answers[id] == nil {
            let roll = rng.pick(100)
            if failuresAllowed, roll < FuzzConfig.failurePercent {
                answers[id] = .failed(Failure.allCases[rng.pick(Failure.allCases.count)])
            } else if roll >= 100 - FuzzConfig.gonePercent {
                answers[id] = .gone(rng.pick(2) == 0 ? 404 : 410)
            } else {
                answers[id] = .readable
            }
        }
        // Only a failure about the account (a dropped connection) throws; a
        // message's own bad answer is named unreadable. One kind in five is too
        // rare for the default run to be sure of a throw, so a failing plain
        // iteration starts with one.
        if failuresAllowed, schedule == .plain, let first = ids.first {
            answers[first] = .failed(.transportError)
        }
        if schedule == .plain, rng.pick(100) < FuzzConfig.rateLimitPercent,
           let id = Array(Set(ids)).sorted().filter({ answers[$0] == .readable }).first {
            answers[id] = .rateLimitedOnce
        }
        let latencies = (0..<(count * 2 + 8)).map { _ in rng.pick(FuzzConfig.latencyMaxMilliseconds + 1) }
        return Plan(
            iteration: iteration, schedule: schedule, ids: ids, answers: answers, latencies: latencies,
            cancelAt: schedule == .cancel ? rng.pick(count) : nil,
            cancelPoint: (iteration / Schedule.allCases.count).isMultiple(of: 2) ? .awaitingAnswer : .inRateLimitBackoff,
            cancelJitterMilliseconds: rng.pick(FuzzConfig.cancelJitterMaxMilliseconds + 1))
    }

    /// Opens once `expected` gets have arrived. A get that arrives first waits
    /// for the rest until a shared deadline; past it, the barrier records that
    /// the window never filled and lets every get through.
    final class ArrivalBarrier: Sendable {
        private struct State { var arrived = 0; var open = false; var timedOut = false; var deadline: DispatchTime? }
        private let expected: Int
        private let state = Mutex(State())
        private let opened = DispatchSemaphore(value: 0)

        init(expected: Int) { self.expected = expected }

        var isOpen: Bool { state.withLock { $0.open } }
        var timedOut: Bool { state.withLock { $0.timedOut } }
        var arrived: Int { state.withLock { $0.arrived } }

        func arriveAndWait() {
            let decision: (openNow: Bool, deadline: DispatchTime?) = state.withLock { s in
                s.arrived += 1
                if s.open || s.timedOut { return (false, nil) }
                if s.arrived >= expected { s.open = true; return (true, nil) }
                if s.deadline == nil { s.deadline = .now() + FuzzConfig.windowArrivalTimeoutSeconds }
                return (false, s.deadline)
            }
            if decision.openNow { for _ in 0..<expected { opened.signal() } }
            guard let deadline = decision.deadline else { return }
            if opened.wait(timeout: deadline) == .timedOut {
                state.withLock { if !$0.open { $0.timedOut = true } }
            }
        }

        func releaseAll() { for _ in 0..<expected { opened.signal() } }
    }

    /// What the fake server saw of the fetch's gets.
    final class Wire: Sendable {
        struct State { var arrivals = 0; var active = 0; var peak = 0; var attempts: [String: Int] = [:]; var cancelPointReached = false }
        let state = Mutex(State())
        let window: ArrivalBarrier
        /// Holds the first window's answers in the other-request schedule.
        let hold = DispatchSemaphore(value: 0)
        /// Holds the cancel point's answer until the test has cancelled.
        let cancelled = DispatchSemaphore(value: 0)
        private let holdCount: Int

        init(plan: Plan) {
            window = ArrivalBarrier(expected: plan.firstWindow)
            holdCount = plan.ids.count + 1
        }

        var arrivals: Int { state.withLock { $0.arrivals } }
        var active: Int { state.withLock { $0.active } }
        var peak: Int { state.withLock { $0.peak } }
        var cancelPointReached: Bool { state.withLock { $0.cancelPointReached } }

        func releaseAll() {
            window.releaseAll()
            for _ in 0..<holdCount { hold.signal(); cancelled.signal() }
        }
    }

    struct Report {
        var violations: [String] = []
        var cancelApplied = false
        var otherRequestChecked = false
        var threwFailure = false
        var succeeded = false
        var namedUnreadable = false
    }

    static let profileCall = "GET /gmail/v1/users/me/profile"
    static let profileHistoryId = "77"

    static func run(_ plan: Plan) async -> Report {
        var report = Report()
        let width = plan.width
        let scenario = FakeHTTP.Scenario()
        defer { scenario.close() }
        let wire = Wire(plan: plan)
        defer { wire.releaseAll() }

        scenario.register(path: "/messages/fz-", method: "GET") { request in
            let id = request.url.lastPathComponent
            let counted: (arrival: Int, attempt: Int) = wire.state.withLock { s in
                let arrival = s.arrivals
                s.arrivals += 1
                s.active += 1
                s.peak = max(s.peak, s.active)
                s.attempts[id, default: 0] += 1
                return (arrival, s.attempts[id]!)
            }
            let arrival = counted.arrival
            let attempt = counted.attempt
            return .parked {
                defer { wire.state.withLock { $0.active -= 1 } }
                let inFirstWindow = arrival < plan.firstWindow
                if inFirstWindow { wire.window.arriveAndWait() }
                if inFirstWindow, plan.schedule == .otherRequest {
                    _ = wire.hold.wait(timeout: .now() + FuzzConfig.holdTimeoutSeconds)
                }
                Thread.sleep(forTimeInterval: Double(plan.latency(arrival: arrival)) / 1000)
                if arrival == plan.cancelAt {
                    wire.state.withLock { $0.cancelPointReached = true }
                    // Answered 429 either way: if the cancelled get is still
                    // delivered, it goes into backoff and the cancellation
                    // ends it there.
                    if plan.cancelPoint == .awaitingAnswer {
                        _ = wire.cancelled.wait(timeout: .now() + FuzzConfig.holdTimeoutSeconds)
                    }
                    return .status(429)
                }
                return plan.response(id: id, attempt: attempt)
            }
        }
        scenario.register(path: "/profile", method: "GET", response: .json(
            raw: #"{"emailAddress": "gmail-detail-fuzz@example.com", "historyId": "\#(profileHistoryId)"}"#))
        let reuseIds = (0..<width).map { "rz-\($0)" }
        let reuseWindow = ArrivalBarrier(expected: width)
        defer { reuseWindow.releaseAll() }
        scenario.register(path: "/messages/rz-", method: "GET") { request in
            let id = request.url.lastPathComponent
            return .parked {
                reuseWindow.arriveAndWait()
                return .json(raw: DeltaDetailFetchFailureTests.gmailMessageJSON(id: id))
            }
        }
        let provider = GmailProvider(
            userEmail: "gmail-detail-fuzz@example.com", accessToken: { _ in "fake-access-token" }, session: scenario.session)

        let fetch = Task { try await provider.fetchMessageDetails(ids: plan.ids) }
        let done = Mutex(false)
        let watcher = Task { _ = await fetch.result; done.withLock { $0 = true } }

        // 1. Background progress.
        if plan.firstWindow > 0 {
            _ = await DeltaDetailFetchFailureTests.waitUntil(seconds: FuzzConfig.windowArrivalTimeoutSeconds * 2) {
                wire.window.isOpen || wire.window.timedOut
            }
            if !wire.window.isOpen {
                report.violations.append("only \(wire.window.arrived) of the first \(plan.firstWindow) gets were on the wire before the first answer")
            }
        }

        // 2. First freed slot.
        if plan.schedule == .otherRequest, wire.window.isOpen {
            try? await Task.sleep(for: .milliseconds(FuzzConfig.admissionSettleMilliseconds))
            let entered = Mutex(false)
            let other = Task {
                try await DeltaDetailFetchFailureTests.currentHistoryIdOnceEntered(on: provider) { entered.withLock { $0 = true } }
            }
            let queued = await DeltaDetailFetchFailureTests.waitUntil { entered.withLock { $0 } }
            wire.hold.signal()
            let nextArrived = await DeltaDetailFetchFailureTests.waitUntil { scenario.recordedCalls().count > width }
            let sequence = scenario.servedCallSequence()
            for _ in 0..<width { wire.hold.signal() }
            let next = sequence.count > width ? sequence[width] : "nothing"
            if !queued || !nextArrived || next != profileCall {
                report.violations.append("the first slot the fetch freed went to \(next), ahead of a request waiting at the gate")
            }
            if (try? await other.value) != profileHistoryId {
                report.violations.append("the other request did not complete")
            }
            report.otherRequestChecked = true
        }

        // Cancel at the seeded get, unless the fetch already ended.
        if plan.cancelAt != nil {
            _ = await DeltaDetailFetchFailureTests.waitUntil(seconds: FuzzConfig.fetchDeadlineSeconds) {
                wire.cancelPointReached || done.withLock { $0 }
            }
            if wire.cancelPointReached, !done.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(plan.cancelJitterMilliseconds))
                fetch.cancel()
                report.cancelApplied = true
            }
            for _ in 0..<2 { wire.cancelled.signal() }
        }

        // 5. Termination.
        let finished = await DeltaDetailFetchFailureTests.waitUntil(seconds: FuzzConfig.fetchDeadlineSeconds) {
            done.withLock { $0 }
        }
        guard finished else {
            report.violations.append("the fetch did not return within \(FuzzConfig.fetchDeadlineSeconds) s")
            fetch.cancel()
            return report
        }
        _ = await watcher.value
        let result = await fetch.result
        let arrivalsAtReturn = wire.arrivals
        let drained = await DeltaDetailFetchFailureTests.waitUntil(seconds: FuzzConfig.windowArrivalTimeoutSeconds) {
            wire.active == 0
        }
        if !drained { report.violations.append("\(wire.active) gets were still in flight after the fetch returned") }
        try? await Task.sleep(for: .milliseconds(FuzzConfig.quietAfterReturnMilliseconds))
        // The wire counts a get when the URL loader calls `startLoading`, on its
        // own thread. A get the fetch had already handed to URLSession when a
        // failure or a cancellation cancelled it can therefore be counted after
        // the fetch returned, although its call ended before the return. So the
        // count must stay put exactly when no get was cancelled (a fetch that
        // succeeded), and otherwise may grow by at most the gate's width, the
        // most gets that can be on their way when the fetch is cancelled.
        let lateArrivals = wire.arrivals - arrivalsAtReturn
        let cancelledGets = report.cancelApplied || (try? result.get()) == nil
        if cancelledGets ? lateArrivals > width : lateArrivals != 0 {
            report.violations.append("\(lateArrivals) gets reached the server after the fetch returned")
        }

        // 3 and 4. Results and throw semantics.
        switch result {
        case .success(let batch):
            report.succeeded = true
            if !batch.unreadable.isEmpty { report.namedUnreadable = true }
            let received = batch.details.map(\.header.messageId).sorted()
            if report.cancelApplied {
                report.violations.append("a cancelled fetch returned \(received.count) messages as if complete")
            } else if plan.expectsFailure {
                report.violations.append("a fetch with a failing message returned \(received.count) messages as if complete")
            } else {
                if received != plan.readable {
                    report.violations.append("returned \(received.count) messages, expected the \(plan.readable.count) readable ones; missing \(Set(plan.readable).subtracting(received).sorted())")
                }
                if batch.unreadable.sorted() != plan.unreadable {
                    report.violations.append("named \(batch.unreadable.sorted()) unreadable, expected \(plan.unreadable)")
                }
                if arrivalsAtReturn != plan.ids.count + plan.retries {
                    report.violations.append("asked \(arrivalsAtReturn) times for \(plan.ids.count) ids and \(plan.retries) retries")
                }
                if wire.peak > width {
                    report.violations.append("\(wire.peak) gets in flight at once, past the gate's \(width)")
                }
            }
        case .failure(let error):
            let cancellation = DeltaDetailFetchFailureTests.isCancellation(error)
            if report.cancelApplied {
                if !plan.expectsFailure, !cancellation {
                    report.violations.append("a cancelled fetch threw \(error) instead of its cancellation")
                }
            } else if !plan.expectsFailure {
                report.violations.append("a fetch with every message readable or gone threw \(error)")
            } else if cancellation {
                report.violations.append("a fetch with a failing message threw a cancellation instead of the failure")
            } else {
                report.threwFailure = true
            }
        }

        // 6. Gate reuse.
        let wave = Task { try await provider.fetchMessageDetails(ids: reuseIds) }
        _ = await DeltaDetailFetchFailureTests.waitUntil(seconds: FuzzConfig.windowArrivalTimeoutSeconds * 2) {
            reuseWindow.isOpen || reuseWindow.timedOut
        }
        if !reuseWindow.isOpen {
            report.violations.append("after the fetch only \(reuseWindow.arrived) of \(width) gets could be in flight together")
        }
        reuseWindow.releaseAll()
        let reused = try? await wave.value
        if Set(reused?.details.map(\.header.messageId) ?? []) != Set(reuseIds) {
            report.violations.append("the full-width fetch after it did not return every message")
        }
        return report
    }

    @Test("Seeded Gmail detail fetch schedules keep the window full, every readable message, fail closed, end, and give back the gate")
    func gmailDetailWindowFuzz() async {
        let seed = FuzzConfig.seed
        let iterations = FuzzConfig.iterations
        var cleanCancels = 0
        var otherRequests = 0
        var failures = 0
        var successes = 0
        var namedUnreadable = 0
        for iteration in 0..<iterations {
            var rng = SplitMix64(seed: seed &+ UInt64(iteration) &* 0x9E37_79B9_7F4A_7C15)
            let plan = Self.makePlan(iteration: iteration, rng: &rng)
            let report = await Self.run(plan)
            if !report.violations.isEmpty {
                Issue.record("seed 0x\(String(seed, radix: 16)) iteration \(iteration) (\(plan.summary)): \(report.violations.joined(separator: "; "))")
                return
            }
            if report.cancelApplied, !plan.expectsFailure { cleanCancels += 1 }
            if report.otherRequestChecked { otherRequests += 1 }
            if report.threwFailure { failures += 1 }
            if report.succeeded { successes += 1 }
            if report.namedUnreadable { namedUnreadable += 1 }
        }
        // The default run must reach every checker, or it proves nothing.
        if iterations >= FuzzConfig.defaultIterations {
            #expect(cleanCancels > 0, "no iteration cancelled a fetch with every message readable or gone")
            #expect(otherRequests > 0, "no iteration checked the first freed slot")
            #expect(failures > 0, "no iteration threw a message's failure")
            #expect(successes > 0, "no iteration completed")
            #expect(namedUnreadable > 0, "no iteration named an unreadable message")
        }
    }
}
