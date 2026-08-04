/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - IOS-OUTBOX-001 / IOS-OUTBOX-002 — recovery and wake scheduling

/// **The system properties pinned here, not the mechanisms that implement them.**
///
/// 1. *A send stranded `.sending` with no `sentAt` becomes sendable again WITHOUT
///    a process relaunch.* (`IOS-OUTBOX-001`)
/// 2. *A row carrying `sentAt` is NEVER re-queued or re-claimed by that recovery.*
///    (`sentAt` before delete — Outbox Reliability Rule 3, the double-send
///    firewall.)
/// 3. *When any queued row's hold is still in the future, the wake target IS that
///    row — whatever other queued rows exist.* (`IOS-OUTBOX-002`)
///
/// **Why "sendable again" is measured by the REAL `atomicClaim`.** `drainOutbox`
/// selects `.queued` only, and `atomicClaim` is the single gate every send passes
/// through: admitted ⇒ this message will be transmitted, refused ⇒ it will not.
/// Asserting the claim's admit/refuse outcome therefore asserts whether the user's
/// email actually goes out, rather than asserting that some particular function was
/// called or that some field holds a particular value. A differently-implemented
/// recovery that upholds the property stays green here; a broken one reds.
///
/// **Every case is two-sided.** The stranded-row cases carry a `sentAt`-bearing
/// companion that must stay unsendable, and the firewall cases carry a stranded
/// companion that must become sendable — so neither direction can pass vacuously
/// (a recovery that requeues nothing, and a firewall that refuses everything, both
/// fail).
///
/// `.serialized` + `.processGlobalState`: each case rebinds the process-global
/// `AppDatabase.shared` that `reconcileOutbox` / `atomicClaim` write through.
/// example.com addresses only; every instant is derived from `Date()`.
@Suite("Outbox in-session recovery and wake scheduling", .serialized, .processGlobalState)
struct OutboxForegroundRecoveryTests {

    // MARK: - Fixture

    /// Installs a temp file-backed `DatabasePool` as `AppDatabase.shared` and seeds
    /// the account the outbox rows' foreign key needs — `atomicClaim` also reads it
    /// for Message-ID generation.
    private func makeTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
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
            var acc = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            acc.id = "acc-outbox-fg"
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    private func restore(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    /// Seed one outbox row in an explicit durable state. `holdUntil` defaults to a
    /// PAST instant derived from `Date()` so the undo-hold gate can never be the
    /// reason a claim is refused — a refusal in these cases must be attributable to
    /// status or `sentAt` alone.
    @discardableResult
    private func seedOutbox(
        _ pool: DatabasePool,
        id: String,
        status: OutboxStatus,
        sentAt: Date?,
        appendedToSent: Bool = false,
        holdUntil: Date? = Date().addingTimeInterval(-3600)
    ) throws -> OutboxMessage {
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "Subject", body: "Body")
        var msg = OutboxMessage(accountId: "acc-outbox-fg", draft: draft)
        msg.id = id
        msg.status = status.rawValue
        msg.sentAt = sentAt
        msg.appendedToSent = appendedToSent
        msg.holdUntil = holdUntil
        let insertable = msg
        try pool.write { try insertable.insert($0) }
        return msg
    }

    private func fetch(_ pool: DatabasePool, _ id: String) throws -> OutboxMessage? {
        try pool.read { try OutboxMessage.fetchOne($0, key: id) }
    }

    /// The production wake query, read synchronously. Kept as a helper so an
    /// `async` case cannot accidentally bind GRDB's async `read` overload.
    private func wakeTarget(_ pool: DatabasePool, at instant: Date) throws -> OutboxMessage? {
        try pool.read { try AccountManager.earliestFutureHoldWakeTarget(now: instant, db: $0) }
    }

    // MARK: - IOS-OUTBOX-001

    /// **The property: the user's send is live again without relaunching the app.**
    ///
    /// The stranded state (`.sending`, `sentAt == nil`) is invisible to
    /// `drainOutbox` — it selects `.queued` — and `OutboxView` offers no gesture
    /// for it, so before the foreground trigger existed the ONLY escape was a full
    /// process launch. The assertion is not "reconcile ran": it is that the real
    /// `atomicClaim` REFUSES the row before the trigger and ADMITS it after, i.e.
    /// the message that could not be sent can now be sent.
    ///
    /// The `sentAt`-bearing companion is the non-vacuity control in the opposite
    /// direction: a recovery that simply requeued every `.sending` row would pass
    /// the first half and fail here.
    @Test("A stranded `.sending`/no-`sentAt` row becomes claimable on foreground — no relaunch — while a `sentAt` row stays refused")
    func strandedRowRecoversInSessionAndSentRowDoesNot() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let stranded = try seedOutbox(pool, id: "stranded", status: .sending, sentAt: nil)
        let alreadySent = try seedOutbox(
            pool, id: "already-sent", status: .sending,
            sentAt: Date().addingTimeInterval(-60), appendedToSent: false)

        // Pre-state: neither row can be sent. The stranded one is refused because
        // it is not `.queued`; that refusal IS the defect.
        #expect(await AccountManager.shared.atomicClaimForTesting(stranded) == false)
        #expect(await AccountManager.shared.atomicClaimForTesting(alreadySent) == false)

        await AccountManager.shared.reconcileOutboxOnForeground()

        // The stranded intention is live again — durable state first, then the
        // gate that decides whether the provider is actually called.
        let recovered = try #require(try fetch(pool, "stranded"))
        #expect(recovered.outboxStatus == .queued)
        #expect(recovered.sentAt == nil)
        #expect(await AccountManager.shared.atomicClaimForTesting(recovered) == true)

        // 🚨 The double-send firewall: the already-sent row was NOT requeued and is
        // still refused by the send gate.
        let sentRow = try #require(try fetch(pool, "already-sent"))
        #expect(sentRow.outboxStatus != .queued)
        #expect(sentRow.sentAt != nil)
        #expect(await AccountManager.shared.atomicClaimForTesting(sentRow) == false)
    }

    /// **The property: a completed send is finished, never re-sent.**
    ///
    /// A `.sending` row with `sentAt` AND `appendedToSent` is a send that fully
    /// succeeded and only failed to delete itself. Reconciliation finalizes it. The
    /// one outcome that must be impossible is `.queued`: that would hand a message
    /// the server already accepted back to the send phase.
    ///
    /// The stranded companion in the same pass is the non-vacuity control — a
    /// trigger that did nothing at all would satisfy "never `.queued`" trivially.
    @Test("A fully-completed `sentAt` row is finalized, never re-queued, while a stranded row in the same pass recovers")
    func completedSendIsFinalizedNotRequeued() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        try seedOutbox(
            pool, id: "completed", status: .sending,
            sentAt: Date().addingTimeInterval(-120), appendedToSent: true)
        try seedOutbox(pool, id: "stranded", status: .sending, sentAt: nil)

        await AccountManager.shared.reconcileOutboxOnForeground()

        // Finalized: the row is gone. It is emphatically NOT sitting at `.queued`.
        let completed = try fetch(pool, "completed")
        if let completed {
            #expect(completed.outboxStatus != .queued)
            Issue.record("completed send row survived finalization with status \(completed.status)")
        }

        let stranded = try #require(try fetch(pool, "stranded"))
        #expect(stranded.outboxStatus == .queued)
    }

    // MARK: - IOS-OUTBOX-002

    /// **The property: whenever a queued row's hold is still in the future, a wake
    /// target exists and it is the earliest such row.**
    ///
    /// A legacy-NULL or already-elapsed `holdUntil` sorts FIRST under SQLite `ASC`,
    /// so an order-only query handed the caller a row whose `hold > now` re-check
    /// fails and no timer was armed for the future row hiding behind it.
    @Test("A future-held row is the wake target even when past-held and legacy-NULL rows sort ahead of it")
    func futureHeldRowIsNotShadowed() throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let now = Date()
        try seedOutbox(pool, id: "legacy-null", status: .queued, sentAt: nil, holdUntil: nil)
        try seedOutbox(pool, id: "past", status: .queued, sentAt: nil,
                       holdUntil: now.addingTimeInterval(-5))
        try seedOutbox(pool, id: "future-late", status: .queued, sentAt: nil,
                       holdUntil: now.addingTimeInterval(600))
        try seedOutbox(pool, id: "future-soon", status: .queued, sentAt: nil,
                       holdUntil: now.addingTimeInterval(300))

        let target = try pool.read {
            try AccountManager.earliestFutureHoldWakeTarget(now: now, db: $0)
        }
        #expect(target?.id == "future-soon")
        // …and the caller's own re-check now passes, which is what arms the timer.
        #expect((target?.holdUntil ?? .distantPast) > now)
    }

    /// Non-vacuity for the row above: narrowing the WAKE query must not stop the
    /// shadowing rows being sent. Both are still admitted by the real send gate,
    /// so they are drained by the ordinary loop that runs before the timer — which
    /// is exactly why excluding them from the timer removes no intention.
    @Test("Non-vacuity: the past-held and legacy-NULL rows the wake query now skips are still admitted by the real send gate")
    func shadowingRowsAreStillDrainable() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let now = Date()
        let legacy = try seedOutbox(pool, id: "legacy-null", status: .queued, sentAt: nil, holdUntil: nil)
        let past = try seedOutbox(pool, id: "past", status: .queued, sentAt: nil,
                                  holdUntil: now.addingTimeInterval(-5))
        let future = try seedOutbox(pool, id: "future", status: .queued, sentAt: nil,
                                    holdUntil: now.addingTimeInterval(600))

        #expect(await AccountManager.shared.atomicClaimForTesting(legacy) == true)
        #expect(await AccountManager.shared.atomicClaimForTesting(past) == true)
        // The future-held row is correctly NOT sendable yet — that is why it needs
        // a wake timer at all.
        #expect(await AccountManager.shared.atomicClaimForTesting(future) == false)
    }

    /// Rule 8 is not widened by this change: a `.failed` row awaiting an explicit
    /// user Retry must never become a wake target, however far in the future its
    /// hold sits.
    @Test("Only `.queued` rows are wake targets — a future-held `.failed` row is not scheduled")
    func failedRowIsNeverAWakeTarget() throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let now = Date()
        try seedOutbox(pool, id: "failed-future", status: .failed, sentAt: nil,
                       holdUntil: now.addingTimeInterval(120))
        try seedOutbox(pool, id: "sending-future", status: .sending, sentAt: nil,
                       holdUntil: now.addingTimeInterval(60))

        let target = try pool.read {
            try AccountManager.earliestFutureHoldWakeTarget(now: now, db: $0)
        }
        #expect(target == nil)
    }

    /// No future-held queued row ⇒ no wake target, so no timer is armed for a
    /// deadline that has already passed.
    @Test("Only past-held and legacy-NULL queued rows → no wake target")
    func noFutureHoldMeansNoWakeTarget() throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let now = Date()
        try seedOutbox(pool, id: "legacy-null", status: .queued, sentAt: nil, holdUntil: nil)
        try seedOutbox(pool, id: "past", status: .queued, sentAt: nil,
                       holdUntil: now.addingTimeInterval(-1))

        let target = try pool.read {
            try AccountManager.earliestFutureHoldWakeTarget(now: now, db: $0)
        }
        #expect(target == nil)
    }

    // MARK: - The wake HANDOFF: selection and re-check read the clock twice

    /// **THE INVARIANT: every queued, unsent row is, when its hold expires, either
    /// claimed by the current drain or covered by an autonomous future drain —
    /// never left depending solely on an unrelated external trigger.**
    ///
    /// The two rows above pin the SELECTION. This pins the HANDOFF from that
    /// selection to the timer, which is a second decision at a SECOND instant:
    /// `drainOutbox` captures `wakeNow`, awaits a `dbPool.read` whose predicate is
    /// `holdUntil > wakeNow`, and then re-checks the answer against a FRESH
    /// `Date()`. If the deadline elapses during that read the row was future when
    /// selected and past when re-checked — and the drain loop has already
    /// finished. The old `hold > Date()` re-check simply fell through there, so NO
    /// timer was armed for a row nothing else was going to look at.
    ///
    /// Asserted as coverage — *a drain is scheduled, and not after the deadline* —
    /// never as "the interval is zero". A zero-interval assertion pins the fix's
    /// mechanism and would stay green on a system re-broken a different way.
    ///
    /// The blessing gap this closes, stated plainly: `futureHeldRowIsNotShadowed`
    /// above and `ComposeThrottleTests.PostLoopWakeUpQueryTests.guardAgainstPastHold`
    /// both check the selected row is STILL future at a later instant, using
    /// comfortable 300 s / 5 s deadlines. Neither exercises the boundary, so both
    /// bless the two-instant shape as sufficient. They remain correct and untouched.
    @Test("A deadline that elapses while the wake query is in flight still gets an autonomous drain")
    func anElapsedWakeDeadlineStillSchedulesAnAutonomousDrain() throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let wakeNow = Date()
        let hold = wakeNow.addingTimeInterval(5)
        try seedOutbox(pool, id: "elapsing", status: .queued, sentAt: nil, holdUntil: hold)

        // Instant 1 — the production selection, exactly as `drainOutbox` runs it.
        let target = try pool.read {
            try AccountManager.earliestFutureHoldWakeTarget(now: wakeNow, db: $0)
        }
        #expect(target?.id == "elapsing", "precondition: the wake query selected the row")

        // Instant 2 — the re-check, after a read that outlived the deadline. The
        // row is unchanged; only the clock moved.
        let reCheck = hold.addingTimeInterval(1)
        let delay = AccountManager.wakeUpDelay(for: target, at: reCheck)

        #expect(delay != nil, """
            no autonomous drain was scheduled for a queued, unsent row whose hold had already \
            expired. The drain loop finished before this point, so the row now sits `.queued` \
            until some unrelated external trigger — a foreground return, a sync, another \
            `queueSend` — happens along. The user's send waits on an event that may never come
            """)
        guard let delay else { return }
        #expect(reCheck.addingTimeInterval(delay) <= max(hold, reCheck),
                "the drain was scheduled AFTER the deadline it exists to honour")
        #expect(delay >= 0, """
            a negative interval TRAPS at `UInt64(interval * 1_000_000_000)` — converting a \
            negative Double to UInt64 is a runtime crash, not a saturating conversion
            """)
    }

    /// The other half of the invariant, and the proof that the re-drive the clause
    /// above schedules is neither a no-op nor a loop.
    ///
    /// Once a deadline has passed the row leaves the WAKE query's predicate
    /// (`holdUntil > now`), so no second timer can be armed for it — the re-drive
    /// terminates. And the real send gate ADMITS it, so the pass that re-drive
    /// starts claims the row instead of falling through again. Coverage is
    /// therefore handed from the timer to the drain loop, with no gap.
    @Test("The re-drive an elapsed deadline schedules terminates and claims the row")
    func theReDriveTerminatesAndClaimsTheElapsedRow() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let elapsed = try seedOutbox(pool, id: "elapsed", status: .queued, sentAt: nil,
                                     holdUntil: Date().addingTimeInterval(-1))

        // Termination: an elapsed row is not a wake target, so the re-drive cannot
        // arm another timer for it. (Read through a synchronous helper: inside an
        // `async` case, `pool.read { }` would resolve to GRDB's async overload.)
        let target = try wakeTarget(pool, at: Date())
        #expect(target == nil, "an elapsed deadline re-armed a timer instead of being drained")

        // Non-vacuity: it is not "covered" by being invisible. The gate every send
        // passes through admits it, so the re-drive's pass transmits the message.
        #expect(await AccountManager.shared.atomicClaimForTesting(elapsed) == true,
                "the row the timer handed to the drain loop is refused by the send gate — it is stranded")
    }

    /// Control: the ordinary path is unchanged. A deadline still in the future
    /// schedules the drain at exactly that deadline — not earlier (which would
    /// spin) and not later (which would delay the user's send).
    @Test("Control: a still-future deadline schedules the drain exactly at that deadline")
    func aFutureDeadlineSchedulesTheDrainAtTheDeadline() throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let now = Date()
        let hold = now.addingTimeInterval(300)
        try seedOutbox(pool, id: "future", status: .queued, sentAt: nil, holdUntil: hold)

        let target = try pool.read {
            try AccountManager.earliestFutureHoldWakeTarget(now: now, db: $0)
        }
        let delay = try #require(AccountManager.wakeUpDelay(for: target, at: now))
        #expect(abs(now.addingTimeInterval(delay).timeIntervalSince(hold)) < 0.001,
                "the clamp changed the ordinary path — a future deadline must be honoured exactly")
    }
}
