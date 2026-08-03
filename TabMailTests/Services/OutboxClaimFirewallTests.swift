/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - D12: `sentAt` is the double-send firewall — the send phase must honour it

/// Drives the REAL `AccountManager.atomicClaim` (via its `atomicClaimForTesting`
/// seam) against a rebound `AppDatabase.shared`, because the defect lives in
/// that function's durable claim write — not in any logic a test could
/// replicate.
///
/// **The invariants pinned here (system properties, not the fix's mechanism):**
/// 1. *A row with `sentAt` set can never be claimed for sending, under any
///    status.*
/// 2. *A row whose undo-hold window has not elapsed can never be claimed.*
/// 3. *Concurrent claims of one row admit at most one winner.*
///
/// `sentAt` is stamped only after `provider.send()` has RETURNED SUCCESS
/// (`sendSingleOutboxMessage`), so by Outbox Reliability Rule 3 it is the proof
/// that the message already left the server. Claiming such a row means
/// transmitting the user's email a second time. Rows carrying `sentAt` belong
/// exclusively to the Sent-append / finalization recovery path.
///
/// Every assertion is on the OBSERVABLE END STATE — the claim's admit/refuse
/// outcome plus the row's resulting `status` / `sentMessageId` / `sentAt` /
/// `appendedToSent`. Nothing here inspects SQL text or `changesCount`, so a
/// differently-implemented guard that upholds the property stays green and a
/// broken one reds.
///
/// **No stuck row is created by the refusal.** The Sent-append recovery phase —
/// phase 1 of every `drainOutbox()`, running BEFORE the send phase — selects on
/// `sentAt != nil AND appendedToSent == false` and is deliberately
/// STATUS-AGNOSTIC (`drainPendingSentAppends`). So a `.queued`/`.failed` row
/// carrying `sentAt` that the send phase now refuses is still picked up there,
/// its append retried, and `finalizeOutboxMessage` deletes it once complete.
/// `refusedRowRemainsReachableBySentAppendRecovery` pins exactly that, so a
/// future narrowing of the recovery predicate cannot silently strand a sent
/// message. The held-row refusal likewise strands nothing: the hold is a
/// deadline, the row stays `.queued`, and the drain's own wake-up Task plus
/// every ordinary drain trigger re-select it once the deadline passes —
/// `heldRowRemainsQueuedAndBecomesClaimableOnceTheHoldElapses` pins that the
/// SAME row is admitted after its hold expires.
///
/// **The protected positive case is asserted** in every pair: a `.queued` row
/// with `sentAt == nil` and an elapsed hold is the normal send path and MUST
/// still be claimed. Refusing it would DROP a user's message, which is far
/// worse than the double-send being fixed here (Core Philosophy: Never Drop
/// User Intention).
///
/// `.serialized` + `.processGlobalState`: each test rebinds the process-global
/// `AppDatabase.shared`, so no other global-state suite may run concurrently.
/// Uses example.com addresses only; every date is derived from `Date()`.
@Suite("Outbox claim firewall (D12)", .serialized, .processGlobalState)
struct OutboxClaimFirewallTests {

    // MARK: - Fixture

    /// Installs a temp file-backed `DatabasePool` as `AppDatabase.shared` (the
    /// pool `atomicClaim` writes through) and seeds the account the outbox row's
    /// foreign key needs — `atomicClaim` also reads it for Message-ID
    /// generation. Caller tears down via `restore`.
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
            acc.id = "acc1"
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    /// Restores the prior process DB, then closes and removes this fixture. If
    /// the host had no prior shared DB, the fixture is retained as the valid
    /// process DB so trailing unstructured work cannot dereference a closed
    /// pool.
    private func restore(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    /// Seed one outbox row in an explicit durable state. `holdUntil` defaults to
    /// a PAST instant derived from `Date()` so the hold-window guard can never
    /// be the reason a claim is refused — every `sentAt` refusal in this suite
    /// must be attributable to `sentAt` alone. The hold tests pass an explicit
    /// future deadline.
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
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.id = id
        msg.status = status.rawValue
        msg.sentAt = sentAt
        msg.appendedToSent = appendedToSent
        msg.holdUntil = holdUntil
        let insertable = msg
        try pool.write { try insertable.insert($0) }
        return msg
    }

    private func row(_ pool: DatabasePool, _ id: String) throws -> OutboxMessage? {
        try pool.read { try OutboxMessage.fetchOne($0, key: id) }
    }

    /// The set of rows the Sent-append / finalization recovery phase will pick
    /// up — the same durable condition `drainPendingSentAppends` selects on,
    /// status-agnostic by design. Used to prove a refused claim leaves the row
    /// REACHABLE rather than stuck.
    private func sentAppendRecoverySelection(_ pool: DatabasePool) throws -> [OutboxMessage] {
        try pool.read { db in
            try OutboxMessage
                .filter(Column("sentAt") != nil)
                .filter(Column("appendedToSent") == false)
                .fetchAll(db)
        }
    }

    /// Lets any escaped unstructured work reach its first suspension before the
    /// fixture's database file is removed.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - The protected flow — must keep working (a refusal here DROPS mail)

    @Test("PROTECTED: a .queued row with sentAt == nil is still claimed — status becomes .sending and a sentMessageId is persisted. This is the normal send path; refusing it would drop the user's message.")
    func protectedQueuedUnsentRowIsClaimed() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(pool, id: "ob-unsent", status: .queued, sentAt: nil)

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == true, "an unsent .queued row is the normal send path and MUST be claimable")

        let after = try row(pool, "ob-unsent")
        #expect(after?.outboxStatus == .sending, "the claimed row transitioned to .sending")
        #expect(after?.sentMessageId != nil, "the claim persisted the Message-ID it will send with")
        #expect(after?.sentAt == nil, "the claim does not stamp sentAt — only a completed provider.send() does")
        await settle()
    }

    // MARK: - The firewall: sentAt set ⇒ never claimable, under ANY status

    @Test("D12: a .queued row that already carries sentAt is REFUSED — sentAt is proof provider.send() succeeded, so claiming it would transmit the user's email a second time")
    func queuedRowWithSentAtIsNeverClaimed() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let stamped = Date().addingTimeInterval(-120)
        let seeded = try seedOutbox(pool, id: "ob-sent-queued", status: .queued, sentAt: stamped)

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == false, "D12: a row with sentAt set must never be admitted to the send phase")

        let after = try row(pool, "ob-sent-queued")
        #expect(after?.outboxStatus == .queued, "the refused row is NOT transitioned to .sending")
        #expect(after?.sentMessageId == nil, "the refused row is not written at all — no Message-ID was persisted")
        #expect(after?.sentAt != nil, "the firewall marker survives the refusal")
        await settle()
    }

    @Test("D12: a .failed row that already carries sentAt is REFUSED — the invariant is status-independent, so no future status transition can reopen the firewall")
    func failedRowWithSentAtIsNeverClaimed() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(pool, id: "ob-sent-failed", status: .failed, sentAt: Date().addingTimeInterval(-120))

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == false, "D12: sentAt set ⇒ refused, regardless of status")

        let after = try row(pool, "ob-sent-failed")
        #expect(after?.outboxStatus == .failed, "the refused row keeps its status")
        #expect(after?.sentMessageId == nil, "the refused row is not written at all")
        await settle()
    }

    @Test("D12: a .queued row that is fully complete (sentAt set AND appendedToSent) is REFUSED — a completed send needs finalization, never a re-send")
    func completedRowWithSentAtIsNeverClaimed() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(
            pool, id: "ob-complete", status: .queued,
            sentAt: Date().addingTimeInterval(-120), appendedToSent: true
        )

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == false, "D12: a provably-completed send must never re-enter the send phase")

        let after = try row(pool, "ob-complete")
        #expect(after?.outboxStatus == .queued, "the refused row is NOT transitioned to .sending")
        #expect(after?.sentMessageId == nil, "the refused row is not written at all")
        #expect(after?.appendedToSent == true, "the completion markers survive the refusal")
        await settle()
    }

    // MARK: - No stuck row: what the send phase refuses, recovery still owns

    @Test("D12 no-stuck-row: a .queued row refused for carrying sentAt is STILL selected by the Sent-append/finalization recovery phase — the refusal narrows the send path without stranding a sent message")
    func refusedRowRemainsReachableBySentAppendRecovery() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(pool, id: "ob-pending-append", status: .queued,
                                    sentAt: Date().addingTimeInterval(-120), appendedToSent: false)

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == false, "the send phase refuses it (sentAt set)")

        // ...and the recovery phase, which runs FIRST on every drain and does
        // not filter on status, still owns it. Neither phase may lose it.
        let recoverable = try sentAppendRecoverySelection(pool)
        #expect(recoverable.count == 1, "the refused row is still reachable by Sent-append recovery")
        guard recoverable.count == 1 else { return }
        #expect(recoverable[0].id == "ob-pending-append", "and it is that exact row")
        await settle()
    }

    @Test("D12 no-stuck-row: a .failed row refused for carrying sentAt is likewise still selected by the Sent-append/finalization recovery phase")
    func refusedFailedRowRemainsReachableBySentAppendRecovery() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(pool, id: "ob-failed-append", status: .failed,
                                    sentAt: Date().addingTimeInterval(-120), appendedToSent: false)

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == false, "the send phase refuses it (sentAt set)")

        let recoverable = try sentAppendRecoverySelection(pool)
        #expect(recoverable.count == 1, "the refused row is still reachable by Sent-append recovery")
        guard recoverable.count == 1 else { return }
        #expect(recoverable[0].id == "ob-failed-append", "and it is that exact row")
        await settle()
    }

    // MARK: - F0a: the undo-hold deadline is re-evaluated by the claim itself

    /// The drain's pre-claim scan filters on `holdUntil` in Swift, OUTSIDE the
    /// claim transaction. That filter is a scan-time optimisation, not the
    /// guarantee: a bypassed or racing caller (the NSE drains the same SQLite
    /// file from a second process) must never start an irreversible send before
    /// the user's Undo window has elapsed. This drives the claim seam DIRECTLY,
    /// bypassing the scan filter entirely, so only an in-transaction re-check
    /// can make it pass.
    @Test("F0a: a .queued row whose undo-hold has NOT elapsed is refused by the claim itself, not merely by the drain's pre-scan filter")
    func heldRowIsRefusedByTheClaimTransaction() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(
            pool, id: "ob-held", status: .queued, sentAt: nil,
            holdUntil: Date().addingTimeInterval(SyncConfig.outboxUndoHoldSeconds)
        )

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == false, "F0a: the claim is the irreversible start of send; it must honour the hold")

        let after = try row(pool, "ob-held")
        #expect(after?.outboxStatus == .queued, "the held row stays drainable for after its deadline")
        #expect(after?.sentMessageId == nil, "the refused row is not written at all")
        #expect(after?.sentAt == nil, "nothing was sent")
        await settle()
    }

    /// Two-sided control for the hold refusal AND the no-stuck-row proof: the
    /// SAME row, seeded with an already-elapsed deadline, IS claimed. A hold is
    /// a deadline, never a discard.
    @Test("F0a control: the same row with an already-elapsed hold IS claimed — the hold defers a send, it never drops one")
    func heldRowRemainsQueuedAndBecomesClaimableOnceTheHoldElapses() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(
            pool, id: "ob-hold-elapsed", status: .queued, sentAt: nil,
            holdUntil: Date().addingTimeInterval(-SyncConfig.outboxUndoHoldSeconds)
        )

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == true, "an elapsed hold must not block the user's send")

        let after = try row(pool, "ob-hold-elapsed")
        #expect(after?.outboxStatus == .sending, "the row was admitted to the send phase")
        #expect(after?.sentMessageId != nil, "the claim persisted the Message-ID it will send with")
        await settle()
    }

    /// A legacy row predating the undo-hold column has `holdUntil == nil`. It
    /// must be treated as "no hold", not as "held forever" — the latter would
    /// silently strand every pre-migration send.
    @Test("F0a: a legacy row with holdUntil == nil is treated as unheld and IS claimed")
    func legacyRowWithNoHoldIsClaimed() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(
            pool, id: "ob-legacy-hold", status: .queued, sentAt: nil, holdUntil: nil
        )

        let claimed = await AccountManager.shared.atomicClaimForTesting(seeded)
        #expect(claimed == true, "a nil hold is no hold; refusing it would strand pre-migration sends")

        let after = try row(pool, "ob-legacy-hold")
        #expect(after?.outboxStatus == .sending, "the row was admitted to the send phase")
        await settle()
    }

    // MARK: - At most one winner

    /// **Honest scope.** In a single process GRDB serializes writers, and the
    /// claim's re-read lives inside its own write transaction, so exactly-one
    /// already holds here without the compare-and-swap; this test therefore does
    /// NOT go red on the pre-CAS code and is not offered as a red proof. Its job
    /// is to pin the SYSTEM PROPERTY — *concurrent claims of one row admit at
    /// most one winner, and the loser leaves no trace* — so that a later
    /// refactor which moves the re-read out of the transaction (the shape the
    /// CAS exists to survive) has something to fail against. The genuinely
    /// broken case the CAS closes is cross-PROCESS (the NSE drains the same
    /// SQLite file), which a single-process unit test cannot reproduce.
    @Test("Concurrent claims of one row admit exactly one winner, and the row ends .sending with a single persisted Message-ID")
    func concurrentClaimsAdmitExactlyOneWinner() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        let seeded = try seedOutbox(pool, id: "ob-race", status: .queued, sentAt: nil)

        let outcomes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<4 {
                group.addTask { await AccountManager.shared.atomicClaimForTesting(seeded) }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }

        #expect(outcomes.count == 4)
        guard outcomes.count == 4 else { return }
        #expect(outcomes.filter { $0 }.count == 1, "exactly one concurrent claim may be admitted")

        let after = try row(pool, "ob-race")
        #expect(after?.outboxStatus == .sending, "the winner's transition is the durable end state")
        #expect(after?.sentMessageId != nil, "the winner persisted the Message-ID it will send with")
        #expect(after?.sentAt == nil, "no claim stamps sentAt — only a completed provider.send() does")
        await settle()
    }
}
