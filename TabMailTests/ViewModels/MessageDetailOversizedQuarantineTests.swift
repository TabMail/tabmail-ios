/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The user-open half of the oversized-metadata quarantine (owner decision 2026-09-01).
///
/// A message whose metadata FETCH overflowed the IMAP response parser cannot be
/// fetched by this build. Opening it used to spend a full connection — the overflow
/// marks the folder connection unhealthy, so the retry pays TCP + TLS + LOGIN + SELECT —
/// and then land in the "Unable to load message" state anyway, with a 2s poll behind it
/// repeating the whole thing forever.
///
/// The INVARIANT pinned here: **when the flag is set, opening the message reaches the
/// same observable state a failed fetch would leave behind, without performing a
/// fetch and without starting a poll.** Not "we call this specific early return" —
/// every assertion below is about what the user and the network see.
///
/// Two-sided by construction: the identical fixture with the flag cleared MUST fetch,
/// so a short-circuit that fired unconditionally (or a fixture that never reached the
/// fetch at all) cannot pass this suite.
/// `.serialized, .processGlobalState` is REQUIRED, not decorative. The poll tests below
/// run a REAL body poll, and a poll touches `AccountManager.shared` — `recoverHeaderIfMissing`,
/// the address-corroboration check, and (absent an injected override) `fetchBody` itself,
/// which will `connectAccount` a provider into the shared registry. Without the trait this
/// suite runs in parallel with `ProviderIdQueueFuzzTests`, which swaps `AppDatabase.shared`
/// and asserts on that same registry — and it did: three consecutive full-suite runs failed
/// that suite's `liveSessionCount() == 0` teardown assertion while an isolated re-run of it
/// passed. `.serialized` alone would not have helped; it orders tests only INSIDE one suite.
@Suite("Opening an oversized-quarantined message reports failure without a fetch", .serialized, .processGlobalState)
struct MessageDetailOversizedQuarantineTests {

    /// Counts real fetch attempts. `loadBody` routes through `fetchBodyOverride` when
    /// one is injected, so this is the wire oracle for the open path. Lock-guarded
    /// rather than `@MainActor`-isolated because the override's type is non-isolated.
    private final class FetchProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _attempts = 0
        func record() { lock.lock(); _attempts += 1; lock.unlock() }
        var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }
    }

    /// Same shape as `MessageDetailViewModelErrorTests.makeVM`: a temp file-backed pool
    /// with migrations applied and one body-less header, which is what forces the fetch
    /// path. `oversized` decides whether that header carries the durable flag.
    @MainActor
    private func makeVM(
        oversized: Bool,
        bodyComplete: Bool = false,
        probe: FetchProbe
    ) throws -> (MessageDetailViewModel, DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.runMigrations(on: pool)

        try pool.write { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)

            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            try folder.insert(db)

            var header = MessageHeader(
                messageId: "100",
                subject: "Oversized",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "to@example.com",
                date: Date(),
                snippet: "snippet",
                folderId: "acc1:INBOX",
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            header.isRead = true  // avoid the markRead path touching AccountManager
            header.headerComplete = true
            header.bodyMetadataOversized = oversized
            header.bodyComplete = bodyComplete
            try header.insert(db)
        }

        // `#require`, not `!`: a trap here kills the test HOST, and Swift Testing cannot
        // catch a `fatalError` — one nil would bury the results of thousands of unrelated
        // tests behind a crash that names nothing. Nil is unreachable (the insert above is
        // in the same function), which is exactly when the cheap safe form costs nothing.
        let headerId = try #require(try pool.read { db in
            try MessageHeader.fetchOne(db, sql: "SELECT * FROM messageHeader WHERE messageId = '100'")
        }).id

        let vm = MessageDetailViewModel(
            messageId: headerId,
            dbPool: pool,
            fetchBodyOverride: { _ in probe.record() }
        )
        return (vm, pool, dir)
    }

    private func cleanup(_ pool: DatabasePool, _ dir: URL) {
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    // MARK: - The quarantined open

    @Test("A flagged message reports load failure with ZERO fetch attempts and no poll")
    @MainActor
    func flaggedMessageReportsFailureWithoutFetching() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: true, probe: probe)
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(probe.attempts == 0,
                "the open path must not spend a connection on a fetch this build cannot complete")
        #expect(vm.hasStartedBodyPollForTesting == false,
                "no background path can produce this body — the flag is what removed it from both queues — so a 2s poll would spin forever")
        #expect(vm.error != nil,
                "the user must see the load-failed state; MessageCardView renders it only when `error` is non-nil")
        #expect(vm.isLoading == false, "a spinner would promise progress that will never come")
        #expect(vm.messageBody == nil, "nothing was fetched, so nothing may be displayed as content")
        #expect(vm.messageNotFound == false,
                "the MESSAGE is present and its header renders — only the body is missing; Not Found would be a different and wrong claim")
        #expect(vm.message != nil, "subject, sender and date still come from the healthy header")
    }

    /// Non-vacuity, from the other side. Without this, a `loadBody` that returned early
    /// for any reason — or a fixture whose body was already cached — would satisfy the
    /// test above while proving nothing about the flag.
    @Test("CONTROL: the identical unflagged message DOES attempt a fetch")
    @MainActor
    func unflaggedMessageStillFetches() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: false, probe: probe)
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(probe.attempts == 1,
                "the ONLY difference from the case above is the flag, so the fetch must happen here")
    }

    /// The flag records one failed wire attempt, not a verdict that content is
    /// unobtainable. If bytes exist by any route, they win — the short-circuit sits
    /// AFTER the durable-body lookup on purpose.
    @Test("A durable body outranks the flag — a quarantined row that somehow has content still shows it")
    @MainActor
    func durableBodyOutranksTheFlag() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: true, probe: probe)
        defer { cleanup(pool, dir) }

        let body = MessageBody(
            contentKey: ContentKey(rawValue: vm.messageId),
            htmlContent: "<p>arrived by another route</p>")
        try await pool.write { db in try body.insert(db) }

        await vm.loadBody()

        #expect(vm.messageBody?.htmlContent == "<p>arrived by another route</p>")
        #expect(vm.error == nil, "there is nothing to report a failure about — the content is on screen")
        #expect(probe.attempts == 0)
    }

    /// Pull-to-refresh is the user's explicit "try again", and it is the escape hatch
    /// that keeps the quarantine an observation rather than a verdict. It must stay a
    /// GENUINE retry: the flag is deliberately not consulted here.
    @Test("Pull-to-refresh still performs a real fetch on a flagged message, and leaves a poll behind")
    @MainActor
    func pullToRefreshStillRetries() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: true, probe: probe)
        // Stop the poll `refetchBody` leaves behind before the fixture DB is retired, or
        // it outlives this test. (This comment used to say the poll bypasses the injected
        // override and reaches the live `AccountManager`; it no longer does — the poll
        // routes its fetch through `_fetchBodyOverride` too, which is what makes an
        // escaped poll harmless rather than a session opened inside an unrelated suite.
        // Cancelling is still required: an escaped poll would read a retired pool.)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }

        await vm.loadBody()
        #expect(probe.attempts == 0)

        await vm.refetchBody()

        #expect(probe.attempts == 1,
                "an explicit user retry must reach the wire — the parser bound is fragmentation-dependent, so the same message can succeed on a different connection")
        // Stated, not incidental: the retry produced no body (the override is a no-op),
        // so `refetchBody`'s tail restarts the poll. That poll is what the next two
        // tests are about — it is the ONE path by which a flagged row can still end up
        // with a background retry loop behind it.
        #expect(vm.hasStartedBodyPollForTesting,
                "a refresh that produced no body restarts the poll — the quarantine's poll-side gate is what keeps that bounded")
    }

    // MARK: - The poll-side gate

    /// 🚨 THE OTHER HALF OF THE QUARANTINE. `loadBody`'s branch is unreachable on three
    /// paths — a cancelled header read, a cancelled resolve and a cancelled body
    /// cache-check each `startBodyPoll(); return` BEFORE it — and `refetchBody` restarts
    /// the poll unconditionally when no body arrived. On a flagged row that poll used to
    /// retry every 2 seconds forever, each attempt paying a full TCP + TLS + LOGIN +
    /// SELECT because the parser overflow marks the folder connection unhealthy. Gating
    /// only the four background queries and the open path left this initiator live.
    ///
    /// The property asserted is the user-visible end state the poll must reach on its
    /// own: the load-failed presentation, without the caller ever calling `loadBody`
    /// again. Not "we added a guard at line N".
    @Test("The poll stops itself on a flagged row and reports the load failure")
    @MainActor
    func bodyPollStopsItselfOnAFlaggedRow() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: true, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }

        // Drive the poll DIRECTLY — that is the state the three cancelled-read exits in
        // `loadBody` leave behind, and `loadBody`'s own branch is not involved.
        // Hoisted: `messageId` is main-actor isolated and the read closure is Sendable.
        let key = vm.messageId
        vm._testSeedMessage(try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: key)
        }))
        vm.startBodyPoll()

        // One tick is 2s; give it a second tick's worth of slack rather than racing it.
        try await Task.sleep(for: .seconds(5))

        #expect(vm.error != nil,
                "the poll must reach the same load-failed state the open path reports, on its own")
        #expect(vm.isLoading == false, "a spinner would promise progress that cannot come")
        #expect(vm.messageBody == nil, "nothing was fetched, so nothing may be shown as content")
        #expect(probe.attempts == 0,
                "and it must reach that state WITHOUT a wire attempt — the point of the gate is the connection it does not spend")
    }

    /// CONTROL. Without it the assertion above passes on a build whose poll sets `error`
    /// for any reason at all — including one that never reaches the quarantine check.
    /// An unflagged row's poll takes the ordinary fetch path, whose failures are logged
    /// and retried, never surfaced as `error`.
    @Test("CONTROL: the identical unflagged row's poll does NOT report a load failure")
    @MainActor
    func unflaggedRowPollDoesNotReportFailure() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: false, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }

        // Hoisted: `messageId` is main-actor isolated and the read closure is Sendable.
        let key = vm.messageId
        vm._testSeedMessage(try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: key)
        }))
        vm.startBodyPoll()

        try await Task.sleep(for: .seconds(5))

        #expect(probe.attempts >= 1,
                "the ONLY difference from the case above is the flag, so this poll must reach the wire")
        #expect(vm.error == nil,
                "…and an ordinary poll failure is logged and retried, never surfaced as a load failure")
    }

    /// 🚨 THE STATE THE FLAG STRUCTURALLY CANNOT COVER, and the reason
    /// `BodyFetchRefusal.endsPolling` exists.
    ///
    /// Both `bodyComplete` terms in this design are deliberate:
    /// `BodyFetchProcessor.markBodyMetadataOversized` guards `AND bodyComplete = 0` so a
    /// completed row cannot be handed a stale flag, and `MessageHeader.isBodyQuarantined`
    /// carries `&& !bodyComplete` so an evicted-but-fetched row keeps its only recovery.
    /// Together they make ONE row invisible at every site: fetched once, `messageBody`
    /// later deleted by `BodyAssetMaintenance` (which leaves `bodyComplete = 1` by design),
    /// and whose re-fetch now overflows — the parser's bound is fragmentation-dependent, so
    /// a body that parsed once can overflow later. No writer records it and no reader gates
    /// on it, so before this the poll retried it every 2 seconds for the life of the view
    /// model, each attempt a full TCP + TLS + LOGIN + SELECT.
    ///
    /// The property is about the REFUSAL CLASS, not the flag: `loadBody` must not leave a
    /// poll behind a failure nothing in the background will retract.
    @Test("An overflow with no durable flag still stops the poll from starting")
    @MainActor
    func overflowRefusalPreventsThePollEvenWithoutTheFlag() async throws {
        let probe = FetchProbe()
        // UNFLAGGED and bodyComplete — the post-eviction shape. Neither gate can see it.
        let (vm, pool, dir) = try makeVM(oversized: false, bodyComplete: true, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }
        vm._fetchBodyOverride = { _ in
            probe.record()
            throw BodyFetchRefusal.error(
                BodyFetchRefusal.payloadTooLarge, BodyFetchRefusal.payloadTooLargeMessage)
        }

        await vm.loadBody()

        #expect(probe.attempts == 1, "fixture check: nothing gated this row, so the fetch must have been attempted")
        #expect(vm.hasStartedBodyPollForTesting == false,
                "a poll behind an overflow repeats a full connection every 2s and can never succeed — pull-to-refresh is the retry, not the poll")
        #expect(vm.error != nil, "the user must still see the failure")
    }

    /// CONTROL. Without it the assertion above is satisfied by a `loadBody` that stopped
    /// starting polls at all, which would delete the safety net for every transient failure
    /// the poll exists to cover.
    @Test("CONTROL: an ordinary failure on the identical row DOES leave the poll running")
    @MainActor
    func ordinaryFailureStillLeavesThePollRunning() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: false, bodyComplete: true, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }
        vm._fetchBodyOverride = { _ in
            probe.record()
            throw ProviderError.messageNotFound
        }

        await vm.loadBody()

        #expect(probe.attempts == 1)
        #expect(vm.hasStartedBodyPollForTesting,
                "the ONLY difference from the case above is the refusal class — a reconnect or a background write can still resolve this one")
    }

    /// The poll reads the flag FRESH from the database each tick rather than trusting the
    /// header it was started with — and this is the fixture that can tell the difference.
    /// Both existing poll tests seed a header that is ALREADY in its final state, so a
    /// build that read `msg.isBodyQuarantined` once at start-up would pass them both.
    ///
    /// The production scenario is the one the source comment names: a body queue can flag
    /// this row WHILE the detail view is open and polling. `self.message` is only re-read
    /// when it is nil, so a poll that trusted its seeded header would keep paying a full
    /// TCP + TLS + LOGIN + SELECT every 2 seconds against a row the rest of the build has
    /// already given up on. (Found by audit.)
    @Test("A row flagged mid-poll stops the poll — the gate reads the database, not the seeded header")
    @MainActor
    func bodyPollHonoursAFlagSetWhileItIsRunning() async throws {
        let probe = FetchProbe()
        // Seeded UNFLAGGED. A build that trusts the seed can never stop this poll.
        let (vm, pool, dir) = try makeVM(oversized: false, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }

        let key = vm.messageId
        vm._testSeedMessage(try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: key)
        }))
        vm.startBodyPoll()

        // Let at least one ordinary tick run, so the fixture provably reached the wire
        // before the flag existed. Without this the test could pass on a poll that never
        // started at all.
        //
        // 5s, not 3s, for a 2s tick: the first tick is preceded by `recoverHeaderIfMissing()`
        // and `adoptReadyBody`, so 3s was ~1.5x slack and could go FALSE-RED on a loaded
        // machine — the same 2.5x budget the sibling poll tests use. (Found by audit.)
        try await Task.sleep(for: .seconds(5))
        #expect(probe.attempts >= 1, "fixture check: the unflagged poll must be running and fetching")

        // Now flag it, exactly as a background queue would — through the production writer,
        // so the fixture cannot drift from what that writer actually records.
        try await pool.write { db in
            try BodyFetchProcessor.markBodyMetadataOversized(db, headerId: key)
        }

        try await Task.sleep(for: .seconds(5))

        #expect(vm.error != nil,
                "the poll must observe the NEW flag and reach the load-failed state — the seeded header says otherwise")
        #expect(vm.isLoading == false, "a spinner would promise progress that cannot come")
        let after = probe.attempts
        try await Task.sleep(for: .seconds(5))
        #expect(probe.attempts == after,
                "…and it must actually STOP: a poll that reported the failure but kept fetching still pays the connection every 2s")
    }

    /// 🚨 THE POLL'S OWN `endsPolling` ARM — the second consumer of
    /// `BodyFetchRefusal.endsPolling`, and the one no other test can reach.
    ///
    /// `bodyPollStopsItselfOnAFlaggedRow` short-circuits at the poll's fresh-read
    /// quarantine gate, so its `catch` never runs;
    /// `overflowRefusalPreventsThePollEvenWithoutTheFlag` exercises `loadBody`'s tail, which
    /// decides whether to START a poll. Neither covers an ALREADY-RUNNING poll whose fetch
    /// throws an overflow — the post-eviction row (`bodyComplete = 1`, `messageBody` gone,
    /// re-fetch overflows) that both `bodyComplete` terms in this design deliberately hide
    /// from the flag's writer and from `isBodyQuarantined`. That row reaches the fresh-read
    /// gate, passes it, fetches, and overflows, every 2 seconds, forever.
    ///
    /// The invariant: a running poll ends on a refusal nothing in the background will
    /// retract, and says so.
    @Test("A running poll ends on an overflow the durable flag cannot see")
    @MainActor
    func runningPollEndsOnAnOverflowRefusal() async throws {
        let probe = FetchProbe()
        // The post-eviction shape: unflagged AND complete, so the poll's fresh-read gate
        // cannot fire and the classification in the catch is the only thing left.
        let (vm, pool, dir) = try makeVM(oversized: false, bodyComplete: true, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }
        vm._fetchBodyOverride = { _ in
            probe.record()
            throw BodyFetchRefusal.error(
                BodyFetchRefusal.payloadTooLarge, BodyFetchRefusal.payloadTooLargeMessage)
        }

        let key = vm.messageId
        vm._testSeedMessage(try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: key)
        }))
        vm.startBodyPoll()

        // 2s tick; 5s is the same 2.5x budget the sibling poll tests use.
        try await Task.sleep(for: .seconds(5))
        #expect(probe.attempts >= 1, "fixture check: the poll must have reached the fetch at least once")
        #expect(vm.error != nil,
                "a poll that gives up silently leaves the user on a spinner that can never resolve")
        #expect(vm.isLoading == false, "a spinner would promise progress that cannot come")

        let after = probe.attempts
        try await Task.sleep(for: .seconds(5))
        #expect(probe.attempts == after,
                "…and it must STOP: every further tick is a full TCP + TLS + LOGIN + SELECT for a body this attempt already proved will not parse")
    }

    /// CONTROL for the test above, and it is what stops `endsPolling` from being widened.
    /// The poll IS the safety net for transient failure — a reconnect or a background write
    /// can still land the body — so an ordinary error must leave it ticking. Without this,
    /// a build that ended the poll on ANY throw would pass the test above while deleting
    /// the recovery path for every connection blip.
    @Test("CONTROL: a running poll survives an ordinary failure on the identical row")
    @MainActor
    func runningPollSurvivesAnOrdinaryFailure() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: false, bodyComplete: true, probe: probe)
        defer { vm.cancelBodyPollForTesting(); cleanup(pool, dir) }
        vm._fetchBodyOverride = { _ in
            probe.record()
            throw ProviderError.messageNotFound
        }

        let key = vm.messageId
        vm._testSeedMessage(try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: key)
        }))
        vm.startBodyPoll()

        try await Task.sleep(for: .seconds(5))
        let after = probe.attempts
        #expect(after >= 1, "fixture check: the poll must have reached the fetch")
        try await Task.sleep(for: .seconds(5))
        #expect(probe.attempts > after,
                "the ONLY difference from the case above is the refusal class — this one is exactly what the poll exists to retry")
    }

    /// 🚨 THE EVICTION-RECOVERY INVARIANT — the regression the round-1 audit caught.
    ///
    /// `BodyAssetMaintenance` (`dropMessage`, `wipeAll(.inlineImage)`, `runEvictStaleBodies`,
    /// `runPruneIfOverBudget`) deletes the `messageBody` row while deliberately LEAVING
    /// `bodyComplete = 1`, because the detail view's cache-miss fetch is the designed —
    /// and only — recovery. A short-circuit keyed on the flag alone deletes that
    /// recovery, and a message this build has ALREADY fetched successfully becomes
    /// permanently unopenable: strictly worse than the bug being fixed.
    ///
    /// The property asserted is the recovery itself, not the guard's shape: a row the
    /// build has proven it CAN fetch must still reach the wire when its cache is gone,
    /// whatever stale flag it happens to carry.
    @Test("A proven-fetchable row whose body cache was evicted still fetches, even carrying a stale flag")
    @MainActor
    func evictedBodyStillFetchesDespiteStaleFlag() async throws {
        let probe = FetchProbe()
        // bodyComplete = 1 with NO `messageBody` row is exactly the post-eviction shape.
        let (vm, pool, dir) = try makeVM(oversized: true, bodyComplete: true, probe: probe)
        defer { cleanup(pool, dir) }

        let key = vm.messageId
        let cached = try await pool.read { db in
            try MessageBody.fetchOne(db, key: key)
        }
        #expect(cached == nil, "precondition — the fixture is the evicted shape, so only a fetch can produce content")

        await vm.loadBody()

        #expect(probe.attempts == 1,
                "eviction's designed recovery must survive the quarantine — otherwise a message we already fetched once is bricked forever")
    }

    /// The same shape from the other side, so the test above cannot pass because
    /// `bodyComplete` alone disabled the short-circuit for everyone.
    @Test("CONTROL: a flagged row that was never fetched is still quarantined")
    @MainActor
    func neverFetchedFlaggedRowStaysQuarantined() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: true, bodyComplete: false, probe: probe)
        defer { cleanup(pool, dir) }

        await vm.loadBody()

        #expect(probe.attempts == 0,
                "the quarantine still applies to the population it was built for")
        #expect(vm.error != nil)
    }
}
