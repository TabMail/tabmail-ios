/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// **A test scope must never tear down transport that work IT started still
/// depends on.** This type is the boundary that makes that a contract instead
/// of a race.
///
/// **The defect it closes (`IOS-TEST-009`).** Every `queue*` method on
/// `AccountManagerActions` ends with an UNSTRUCTURED `Task { await
/// drainPendingQueue() }` — seven of them. That is deliberate product design:
/// a user gesture must not block on its own wire drain, and the never-drop
/// contract's whole premise is that the intention is durable in the database
/// and drains asynchronously (`CLAUDE.md` § *Never Drop User Intention*, and
/// the `KNOWN_ISSUES.md` `IOS-TEST-009` row's explicit "do NOT fix this by
/// making `queueDraftDelete` stop kicking a drain"). So the drain OUTLIVES the
/// test body that triggered it, by design.
///
/// A test that drives such a gesture through a `FakeHTTP.Scenario` and then
/// runs `defer { http.close() }` invalidates the `URLSession` underneath that
/// still-running drain. The next request the drain issues raises the
/// Objective-C `NSGenericException` *'Task created in a session that has been
/// invalidated'* — which Swift cannot catch, so `libc++abi` terminates the
/// WHOLE test process. `xcodebuild` then logs *"Restarting after unexpected
/// exit, crash, or test timeout"* and blames whichever test happened to be
/// running next. Every test that had not run yet in that launch is silently
/// dropped and the summary is stitched from two launches, so a truncated run
/// reports a plausible-looking pass count. That is the evidence-destroying
/// shape, one layer down from `IOS-TEST-006`.
///
/// **Why this barrier is not the four existing ones.** `FinishTheMoveLocally
/// Tests.drainToQuiescence`, `ProviderIdQueueFuzzTests.drainProviderQueue`,
/// `IdResetDispositionMatrixTests.drainProviderQueue` and
/// `DraftDeleteEpochBoundaryTests.drainUntilSettled` all wait on
/// `queue-is-EMPTY && quiescent`, requesting a drain whenever quiescent and
/// non-empty. They are correct for what they do — prove an op EXECUTED. They
/// cannot express this scope's requirement, for two independent reasons:
///
/// 1. **Emptiness is unreachable here.** A scope that tears its transport down
///    is usually one whose route was never registered, so the drain's request
///    is answered `599`, the provider throws, and the op is REQUEUED — never
///    dropped, that is the never-drop contract working. `isEmpty` is then false
///    forever, so those barriers burn their entire bound (300 × 10 ms) issuing
///    a fresh drain every poll, and still return with a drain possibly in
///    flight. They would make the crash slower, not absent.
/// 2. **Asking for a drain re-arms the thing you are waiting for.**
///    `drainPendingQueue`'s first statement is `guard !isDraining else {
///    needsRedrain = true; return }`, and `pendingQueueIsQuiescentForTesting`
///    reads `!isDraining && !needsRedrain`. A poll that calls the drain while
///    an owner is live sets the very flag it then reads. That is the recorded
///    flake fixed in `f214c70`; the sibling barriers avoid it by sampling
///    first. **This barrier never calls `drainPendingQueue()` at all**, so it
///    cannot re-arm anything. Do NOT add a drain request to it.
///
/// **The bound, stated so nobody widens it.** The predicate is
/// `(no pending operation is still unattempted) && (no drain is in flight)`.
/// The first half is a DURABLE witness: `everAttempted` is set inside the claim
/// transaction in `AccountManagerQueue`, BEFORE any provider I/O, and is never
/// cleared. It closes the start race — a bare quiescence poll can observe
/// `!isDraining` simply because the escaped `Task` has not been scheduled yet,
/// exit immediately, and reproduce the crash. The second half is the existing
/// `pendingQueueIsQuiescentForTesting()` seam. v3 has no zombie reaper and no
/// `redriveDurableQueue`, so nothing outside this scope can re-arm the drain
/// between the two samples. If this ever flakes, root-cause it — do NOT raise
/// the attempt count, lengthen the interval, or add retries.
///
/// **What it deliberately does NOT cover.** Only the `AccountManager` pending-
/// operation drain. Outbox drains, unread recounts, AI queues and body queues
/// are separate escaped-work families with their own seams; a scope whose body
/// starts one of those needs its own witness, not a wider bound here. Compare
/// `TestDatabaseTeardown`, which reached the same conclusion for on-disk
/// fixtures and answered it with process-boundary retention because *"production
/// spawns fire-and-forget tasks that outlive the test that triggered them"*.
enum EscapedDrainTransport {

    private enum Config {
        /// Same shape and same values as the sibling barriers'
        /// `FuzzConfig.drainPollAttempts` / `Config.drainAttempts`.
        static let settleAttempts = 300
        static let settleIntervalMs = 10
    }

    /// The three facts the settle predicate is built from, read in one
    /// transaction so they cannot disagree about the same queue.
    private struct QueueSettleReading: Sendable {
        var total: Int
        var unattempted: Int
        var claimed: Int

        /// A drain really ran against this queue: it either emptied it or left
        /// at least one row carrying the claim's durable attempt proof.
        ///
        /// 🚨 THIS IS NOT `unattempted == 0`, AND THE DIFFERENCE IS THE WHOLE
        /// POINT. The global single-operation executor claims ONE row at a time
        /// and stops the drain at a failure, so an operation sitting behind a
        /// failed one is NEVER CLAIMED — legitimately, by design, that is the
        /// guarantee. Waiting for `everAttempted` on every row therefore waits
        /// for something that will not happen and burns the whole bound on a
        /// healthy queue. What the transport actually needs is that no drain is
        /// running and no row is still claimed; what the DIAGNOSTIC needs is
        /// proof the drain was not silently unclaimable from the start (no
        /// provider registered, no network), and one attempted row is exactly
        /// that proof.
        var aDrainReachedTheWire: Bool { total == 0 || unattempted < total }
    }

    private static func read(_ pool: DatabasePool) async throws -> QueueSettleReading {
        try await pool.read { db in
            QueueSettleReading(
                total: try PendingOperation.fetchCount(db),
                unattempted: try PendingOperation
                    .filter(Column("everAttempted") == false)
                    .fetchCount(db),
                claimed: try PendingOperation
                    .filter(Column("status") == PendingStatus.inFlight.rawValue)
                    .fetchCount(db))
        }
    }

    /// Blocks until no drain is in flight, no operation is still CLAIMED, and a
    /// drain has demonstrably reached the wire — i.e. until nothing the caller
    /// started is still using the transport it is about to tear down.
    ///
    /// Records a `Testing` issue rather than returning silently if the bound
    /// expires: a silent return here re-opens the process-killing race, and a
    /// bound expiry means an assumption changed (no provider registered, no
    /// network, a second drain source) that must be diagnosed, not slept off.
    static func awaitPendingQueueSettled(pool: DatabasePool) async throws {
        for _ in 0..<Config.settleAttempts {
            let reading = try await read(pool)
            let isQuiescent = await AccountManager.shared
                .pendingQueueIsQuiescentForTesting()
            if reading.aDrainReachedTheWire && reading.claimed == 0 && isQuiescent { return }
            try await Task.sleep(for: .milliseconds(Config.settleIntervalMs))
        }
        let reading = try await read(pool)
        let isQuiescent = await AccountManager.shared
            .pendingQueueIsQuiescentForTesting()
        Issue.record(
            """
            The pending-queue drain never settled: \(reading.total) operation(s) \
            remain, \(reading.unattempted) of them never attempted, \
            \(reading.claimed) still claimed, quiescent = \(isQuiescent). \
            Closing the scope's transport now would invalidate a URLSession an \
            in-flight drain is using, which kills the whole test process. \
            Diagnose the drain — do not widen this bound. If EVERY row is \
            unattempted the drain never claimed anything at all: check that a \
            provider is registered for the account and that the connectivity \
            gate lets the drain start.
            """)
    }

    /// Registers `provider`, runs `body`, waits for the pending-queue drain that
    /// `body` started to settle, and only THEN closes `transport` — before the
    /// provider is unregistered.
    ///
    /// **That order is the contract, and it is why this composes the two scopes
    /// instead of leaving callers to nest them.** The drain's claim loop begins
    /// `guard providers[op.accountId] != nil else { continue }`, so a scope that
    /// unregisters the provider FIRST leaves the operation permanently
    /// unclaimable: `everAttempted` never flips, the barrier below waits out its
    /// whole bound, and the transport is then closed with the same race intact.
    /// The registration must outlive the barrier, and one helper is the only way
    /// to make that unskippable at every call site.
    ///
    /// The close happens on every exit — normal or thrown — and always after the
    /// barrier. A barrier written as the last statement of a test body is
    /// skipped by an early `return` from a `guard` and by any `try` that throws,
    /// and those are exactly the paths on which the test is already failing and
    /// most needs its failure to survive rather than be replaced by a process
    /// abort.
    static func withProviderAndTransport(
        isolation: isolated (any Actor)? = #isolation,
        accountId: String,
        provider: any EmailProvider,
        transport: FakeHTTP.Scenario,
        pool: DatabasePool,
        _ body: () async throws -> Void
    ) async throws {
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            var thrown: Error?
            do {
                try await body()
            } catch {
                thrown = error
            }
            do {
                try await awaitPendingQueueSettled(pool: pool)
            } catch {
                if thrown == nil { thrown = error }
            }
            transport.close()
            if let thrown { throw thrown }
        }
    }
}

/// Pins the SYSTEM PROPERTY behind `IOS-TEST-009`: **work a scope starts
/// finishes its round trip against that scope's own transport, before the scope
/// is in a position to tear the transport down.**
///
/// It is deliberately NOT a test that "a `defer` was reordered" or that
/// `withQuiescentTransport` was called — either would be a mechanism-pinning
/// test (MIS-015) that stays green the first time the same defect is written a
/// different way. What is asserted is the end state at the teardown boundary:
/// the fake RECEIVED the drain's request (so the barrier is not vacuously
/// true), no operation is still unattempted, and no drain is in flight.
@Suite("Escaped-drain transport lifetime", .serialized, .processGlobalState)
@MainActor
struct EscapedDrainTransportLifetimeTests {

    /// This suite deliberately NEVER invalidates its `URLSession`.
    ///
    /// The property under test is the STATE at the boundary. Invalidating the
    /// session while the barrier is inverted (the red proof) would abort the
    /// whole test process with the `NSGenericException` this row exists to
    /// remove — destroying the very expectation failures that are the evidence.
    /// Retaining the scenario for the process lifetime is the same answer
    /// `TestDatabaseTeardown.registerForProcessExit` gives for on-disk fixtures,
    /// for the same reason, and it is bounded at one session per run.
    private static let retainedScenarios = Mutex<[FakeHTTP.Scenario]>([])

    private func makeTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "owner@example.com", displayName: "Owner", provider: .gmail)
            account.id = "acc-escaped-drain"
            try account.insert(db)
            let drafts = Folder(
                name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc-escaped-drain")
            try drafts.insert(db)
        }
        return (pool, dir, previous)
    }

    @Test("The drain a gesture starts inside a scope completes against that scope's own transport")
    func escapedDrainCompletesBeforeTheScopeCouldTearDownItsTransport() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer {
            InstalledTestDatabaseLifetime.finish(
                previous: previous, pool: pool, directory: dir)
        }

        let http = FakeHTTP.Scenario()
        Self.retainedScenarios.withLock { $0.append(http) }
        let containedMessageId = "18f0c9d2e4b6a1c3"
        http.register(
            path: "/messages/\(containedMessageId)/trash",
            method: "POST",
            response: .json(raw: "{}"))

        let gmail = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "tok" }, session: http.session)

        var servedAtBoundary: [String] = []
        var quiescentAtBoundary = false
        var unattemptedAtBoundary = -1

        try await TestProviderRegistry.withRegisteredProvider(
            accountId: "acc-escaped-drain", provider: gmail
        ) {
            // The real production gesture: it admits a durable op and then fires
            // the unstructured `Task { await drainPendingQueue() }` that outlives
            // this scope. Nothing here is a mock of that behaviour.
            let queued = await AccountManager.shared.queueDraftDelete(
                identity: .gmailContainedMessage(messageId: containedMessageId),
                accountId: "acc-escaped-drain",
                folderPath: "Drafts")
            #expect(queued, "fixture is vacuous — no durable op was admitted, so no drain was started")

            try await EscapedDrainTransport.awaitPendingQueueSettled(pool: pool)

            servedAtBoundary = http.servedCallSequence()
            quiescentAtBoundary = await AccountManager.shared
                .pendingQueueIsQuiescentForTesting()
            unattemptedAtBoundary = try await pool.read { db in
                try PendingOperation
                    .filter(Column("everAttempted") == false)
                    .fetchCount(db)
            }
        }

        // THE HEADLINE. The drain the gesture started reached THIS scope's
        // transport. If the scope had been free to invalidate that session at
        // this point, the request would never have arrived — and in the real
        // failure it does not arrive, it raises an uncatchable ObjC exception
        // that kills the process.
        #expect(
            servedAtBoundary.contains {
                $0.hasPrefix("POST ") && $0.hasSuffix("/messages/\(containedMessageId)/trash")
            },
            "the escaped drain's request never reached this scope's transport: \(servedAtBoundary)")

        // The boundary state itself: nothing the scope started is still running.
        #expect(quiescentAtBoundary, "a drain was still in flight at the teardown boundary")
        #expect(
            unattemptedAtBoundary == 0,
            "\(unattemptedAtBoundary) durable operation(s) had not been attempted at the teardown boundary")
    }
}
