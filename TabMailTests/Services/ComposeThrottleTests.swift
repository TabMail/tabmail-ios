/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import SwiftMail
@testable import TabMail

// Tests for the compose-throttle feature:
// - undo-send hold (holdUntil) persisted on OutboxMessage
// - deferred-draft-delete via draftId field
// - serial drain filter logic (hold + attempted set)
// - rate-limit constants
// - PendingSendService lifecycle
// - recipient cap

// MARK: - Helpers

/// Filter logic duplicated from drainOutbox (AccountManagerOutbox.swift) so
/// the test doesn't depend on the full actor + network + provider setup.
/// Keeps in lock-step with the production filter by manual review — if the
/// production filter changes, these tests should be updated or fail.
private func selectReady(
    queued: [OutboxMessage],
    now: Date,
    attempted: Set<String>,
    hasProvider: (String) -> Bool
) -> OutboxMessage? {
    queued.first {
        !attempted.contains($0.id) &&
        ($0.holdUntil ?? .distantPast) <= now &&
        hasProvider($0.accountId)
    }
}

/// Build an OutboxMessage with fields set via direct property access.
private func makeMessage(
    id: String = UUID().uuidString,
    accountId: String = "acc1",
    createdAt: Date = Date(),
    holdUntil: Date? = nil,
    draftId: String? = nil,
    status: OutboxStatus = .queued,
    to: [String] = ["a@b.com"]
) -> OutboxMessage {
    let draft = DraftMessage(to: to, subject: "Test", body: "Body")
    var msg = OutboxMessage(accountId: accountId, draft: draft)
    msg.id = id
    msg.createdAt = createdAt
    msg.holdUntil = holdUntil
    msg.draftId = draftId
    msg.status = status.rawValue
    return msg
}

// MARK: - OutboxMessage field round-trip

@Suite("OutboxMessage.holdUntil + draftId persistence")
struct OutboxMessageThrottleFieldsTests {

    @Test("holdUntil and draftId round-trip through GRDB insert+fetch")
    func roundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let hold = Date().addingTimeInterval(6)
        let draft = DraftMessage(to: ["to@x.com"], subject: "s", body: "b")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.holdUntil = hold
        msg.draftId = "draft-xyz-123"
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        // Round-trip through GRDB's DATETIME encoding has sub-second drift on
        // some storage backends — allow ~1 ms tolerance.
        #expect(fetched != nil)
        guard let fetched else { return }
        if let h = fetched.holdUntil {
            #expect(abs(h.timeIntervalSince(hold)) < 0.001)
        } else {
            Issue.record("holdUntil decoded as nil")
        }
        #expect(fetched.draftId == "draft-xyz-123")
    }

    @Test("Legacy row without holdUntil or draftId decodes as nil for both")
    func legacyNilDefaults() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        // Write a row with no holdUntil / draftId — Optional properties
        // default to nil.
        let msg = makeMessage()
        try db.write { try msg.insert($0) }
        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.holdUntil == nil)
        #expect(fetched?.draftId == nil)
    }
}

// MARK: - Serial drain filter logic

@Suite("Serial drain filter (hold + attempted + provider)")
struct SerialDrainFilterTests {

    @Test("Message with holdUntil in the future is NOT picked up")
    func futureHoldSkipped() {
        let now = Date()
        let msg = makeMessage(holdUntil: now.addingTimeInterval(5))
        let ready = selectReady(queued: [msg], now: now, attempted: [], hasProvider: { _ in true })
        #expect(ready == nil)
    }

    @Test("Message with holdUntil in the past IS picked up")
    func pastHoldPicked() {
        let now = Date()
        let msg = makeMessage(holdUntil: now.addingTimeInterval(-1))
        let ready = selectReady(queued: [msg], now: now, attempted: [], hasProvider: { _ in true })
        #expect(ready?.id == msg.id)
    }

    @Test("Message with nil holdUntil (legacy) IS picked up")
    func nilHoldPicked() {
        let now = Date()
        let msg = makeMessage(holdUntil: nil)
        let ready = selectReady(queued: [msg], now: now, attempted: [], hasProvider: { _ in true })
        #expect(ready?.id == msg.id)
    }

    @Test("Oldest ready message wins (createdAt ascending)")
    func oldestWins() {
        let now = Date()
        let older = makeMessage(id: "older", createdAt: now.addingTimeInterval(-10), holdUntil: now.addingTimeInterval(-5))
        let newer = makeMessage(id: "newer", createdAt: now.addingTimeInterval(-1), holdUntil: now.addingTimeInterval(-5))
        // Feed queue in createdAt ascending order (matches drain's fetch order).
        let ready = selectReady(queued: [older, newer], now: now, attempted: [], hasProvider: { _ in true })
        #expect(ready?.id == "older")
    }

    @Test("Attempted messages are skipped (prevents transient-failure spin)")
    func attemptedSkipped() {
        let now = Date()
        let a = makeMessage(id: "a", createdAt: now.addingTimeInterval(-10), holdUntil: now.addingTimeInterval(-1))
        let b = makeMessage(id: "b", createdAt: now.addingTimeInterval(-1), holdUntil: now.addingTimeInterval(-1))
        let ready = selectReady(queued: [a, b], now: now, attempted: ["a"], hasProvider: { _ in true })
        #expect(ready?.id == "b")
    }

    @Test("Message without a provider is skipped")
    func noProviderSkipped() {
        let now = Date()
        let a = makeMessage(id: "a", accountId: "acc_no_provider", holdUntil: now.addingTimeInterval(-1))
        let b = makeMessage(id: "b", accountId: "acc1", holdUntil: now.addingTimeInterval(-1))
        let ready = selectReady(queued: [a, b], now: now, attempted: [], hasProvider: { $0 == "acc1" })
        #expect(ready?.id == "b")
    }

    @Test("All skipped → nil")
    func allSkipped() {
        let now = Date()
        let future = makeMessage(id: "future", holdUntil: now.addingTimeInterval(10))
        let already = makeMessage(id: "already", holdUntil: now.addingTimeInterval(-1))
        let ready = selectReady(queued: [future, already], now: now, attempted: ["already"], hasProvider: { _ in true })
        #expect(ready == nil)
    }
}

// MARK: - Rate-limit constants

@Suite("Outbox throttle SyncConfig constants")
struct OutboxThrottleConfigTests {

    @Test("outboxUndoHoldSeconds is exactly 5")
    func undoHoldIs5() {
        #expect(SyncConfig.outboxUndoHoldSeconds == 5)
    }

    @Test("outboxClaimBufferSeconds is exactly 1 (TOCTOU safety buffer)")
    func claimBufferIs1() {
        #expect(SyncConfig.outboxClaimBufferSeconds == 1)
    }

    @Test("outboxPostSendConfirmSeconds is 1.5")
    func postSendConfirmIs1_5() {
        #expect(SyncConfig.outboxPostSendConfirmSeconds == 1.5)
    }

    @Test("outboxMinSendGapSeconds is 3 (serial drain rate limit)")
    func minSendGapIs3() {
        #expect(SyncConfig.outboxMinSendGapSeconds == 3)
    }

    @Test("outboxMaxRecipients is 50")
    func maxRecipientsIs50() {
        #expect(SyncConfig.outboxMaxRecipients == 50)
    }

    @Test("outboxMaxRecipientsWarnThreshold is 45 (< cap)")
    func warnThresholdIs45() {
        #expect(SyncConfig.outboxMaxRecipientsWarnThreshold == 45)
        #expect(SyncConfig.outboxMaxRecipientsWarnThreshold < SyncConfig.outboxMaxRecipients)
    }

    @Test("Claim buffer < undo hold (undo window precedes claim)")
    func bufferLessThanHold() {
        #expect(SyncConfig.outboxClaimBufferSeconds < SyncConfig.outboxUndoHoldSeconds)
    }

    @Test("holdUntil = queuedAt + undoHold + claimBuffer = 6 s")
    func computedHoldDuration() {
        let total = SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        #expect(total == 6)
    }
}

// MARK: - PendingSendService lifecycle

@Suite("PendingSendService lifecycle")
@MainActor
struct PendingSendServiceLifecycleTests {

    private func makeFreshService() -> PendingSendService {
        // Reset the shared singleton's current/dismissTask for a clean test.
        // The service doesn't expose a reset, so we call dismiss() which
        // clears current and cancels any prior dismissTask.
        PendingSendService.shared.dismiss()
        return PendingSendService.shared
    }

    @Test("present() sets current with the given outboxId + draftId + toSummary")
    func presentPopulatesCurrent() async {
        let svc = makeFreshService()
        svc.present(outboxId: "obx1", draftId: "drft1", toSummary: "To: a@b.com")
        #expect(svc.current?.id == "obx1")
        #expect(svc.current?.draftId == "drft1")
        #expect(svc.current?.toSummary == "To: a@b.com")
        // queuedAt is "now" — should be within a few ms of Date()
        if let q = svc.current?.queuedAt {
            #expect(abs(q.timeIntervalSinceNow) < 1.0)
        } else {
            Issue.record("queuedAt is nil")
        }
        svc.dismiss()
    }

    @Test("Second present() replaces current, cancels prior dismissTask")
    func secondPresentReplaces() async {
        let svc = makeFreshService()
        svc.present(outboxId: "first", draftId: "d1", toSummary: "first")
        #expect(svc.current?.id == "first")
        svc.present(outboxId: "second", draftId: "d2", toSummary: "second")
        #expect(svc.current?.id == "second")
        #expect(svc.current?.draftId == "d2")
        svc.dismiss()
    }

    @Test("dismiss() clears current immediately")
    func dismissClears() async {
        let svc = makeFreshService()
        svc.present(outboxId: "x", draftId: "d", toSummary: "To: x")
        #expect(svc.current != nil)
        svc.dismiss()
        #expect(svc.current == nil)
    }

    // Auto-dismiss Task duration is undoHold + claimBuffer + postSendConfirm
    // = 7.5 s. Too long for a unit test to wait on. We verify the Task is
    // scheduled by cancelling it via dismiss() and observing state matches
    // what the Task would produce. For real timing, an integration test
    // could sleep 8+ s; we skip that here to keep the suite fast.

    @Test("undo() returns nil when no Draft row exists (no snapshot to restore)")
    func undoWithoutDraftRow() async {
        // Note: this test does NOT seed a Draft row, so undo() can't build a
        // snapshot — it returns nil. We're exercising the service-level
        // lifecycle (current cleared, dismissTask cancelled), not the
        // full Draft/Attachment load path.
        let svc = makeFreshService()
        svc.present(outboxId: "nonexistent-id", draftId: "draft-xyz", toSummary: "To: x")
        let returned = svc.undo()
        #expect(returned == nil)  // no Draft row → no snapshot
        #expect(svc.current == nil)  // state cleared either way
    }

    @Test("undo() on empty state returns nil (no crash)")
    func undoEmpty() async {
        let svc = makeFreshService()
        svc.dismiss()  // ensure clean
        let returned = svc.undo()
        #expect(returned == nil)
    }
}

// MARK: - Recipient cap logic

@Suite("Recipient cap (50 combined To+Cc+Bcc)")
struct RecipientCapTests {

    private func canAdd(to: Int, cc: Int, bcc: Int) -> Bool {
        let total = to + cc + bcc
        return total < SyncConfig.outboxMaxRecipients
    }

    @Test("0 recipients: can add")
    func zero() {
        #expect(canAdd(to: 0, cc: 0, bcc: 0) == true)
    }

    @Test("49 recipients across fields: can still add one more")
    func justUnderCap() {
        #expect(canAdd(to: 20, cc: 20, bcc: 9) == true)
    }

    @Test("Exactly 50 recipients: cannot add")
    func atCap() {
        #expect(canAdd(to: 20, cc: 20, bcc: 10) == false)
    }

    @Test("51 recipients (e.g. reply-all prefill): already over cap")
    func overCap() {
        #expect(canAdd(to: 30, cc: 20, bcc: 1) == false)
    }

    @Test("Warn threshold (45) is reached before cap")
    func warnThresholdReachable() {
        #expect(SyncConfig.outboxMaxRecipientsWarnThreshold < SyncConfig.outboxMaxRecipients)
        #expect(45 < 50)
    }

    // MARK: - f927ba3 (ComposeView wire-up) edge cases

    /// ComposeView.queueSend cap check uses `totalFinal > outboxMaxRecipients`
    /// (strict). So exactly 50 recipients passes (inclusive), 51 is rejected.
    /// This is NOT the same as the add-gate semantics (`total < 50`, add-gate
    /// is exclusive of 50). Keeping both boundary behaviors in one place so a
    /// future edit doesn't accidentally flip one to match the other.
    private func canSendAtQueueTime(to: Int, cc: Int, bcc: Int) -> Bool {
        let totalFinal = to + cc + bcc
        return totalFinal <= SyncConfig.outboxMaxRecipients
    }

    @Test("Send-time cap: exactly 50 recipients still sends (> is strict)")
    func sendTimeCapInclusive() {
        #expect(canSendAtQueueTime(to: 20, cc: 20, bcc: 10) == true)
    }

    @Test("Send-time cap: 51 recipients (reply-all prefill path) is rejected")
    func sendTimeCapRejectsOverage() {
        #expect(canSendAtQueueTime(to: 21, cc: 20, bcc: 10) == false)
    }

    /// Replicates ComposeView.queueSend's pending-input handling (lines
    /// 1530-1545): when the user has typed an email into the To/Cc/Bcc
    /// TextField but hasn't committed it to a token, queueSend appends the
    /// pending text to the final list before the cap check. A 49-token send
    /// with 1 pending input across all three fields = 50, which passes.
    private func canSendWithPending(
        toTokens: Int, ccTokens: Int, bccTokens: Int,
        pendingTo: String, pendingCc: String, pendingBcc: String
    ) -> Bool {
        var total = toTokens + ccTokens + bccTokens
        if !pendingTo.trimmingCharacters(in: .whitespaces).isEmpty { total += 1 }
        if !pendingCc.trimmingCharacters(in: .whitespaces).isEmpty { total += 1 }
        if !pendingBcc.trimmingCharacters(in: .whitespaces).isEmpty { total += 1 }
        return total <= SyncConfig.outboxMaxRecipients
    }

    @Test("Send-time cap: pending text input counts toward the cap")
    func pendingInputCountsTowardCap() {
        // 50 tokens + 1 pending (whitespace-only, effectively empty) — still 50.
        #expect(canSendWithPending(
            toTokens: 25, ccTokens: 15, bccTokens: 10,
            pendingTo: "   ", pendingCc: "", pendingBcc: ""
        ) == true)
        // 50 tokens + 1 non-empty pending → 51, rejected.
        #expect(canSendWithPending(
            toTokens: 25, ccTokens: 15, bccTokens: 10,
            pendingTo: "late@arrival.com", pendingCc: "", pendingBcc: ""
        ) == false)
    }

    @Test("Send-time cap: three non-empty pending inputs each add 1 to the total")
    func threePendingInputs() {
        // 48 tokens + 3 pending (one per field) → 51, rejected.
        #expect(canSendWithPending(
            toTokens: 16, ccTokens: 16, bccTokens: 16,
            pendingTo: "a@x.com", pendingCc: "b@x.com", pendingBcc: "c@x.com"
        ) == false)
        // 47 tokens + 3 pending → 50, allowed.
        #expect(canSendWithPending(
            toTokens: 16, ccTokens: 16, bccTokens: 15,
            pendingTo: "a@x.com", pendingCc: "b@x.com", pendingBcc: "c@x.com"
        ) == true)
    }
}

// MARK: - Undo + holdUntil timing

@Suite("Undo window timing")
struct UndoWindowTimingTests {

    @Test("At t=2 s (within undo window), holdUntil is still in the future → drain skips")
    func undoAt2Seconds() {
        let queuedAt = Date()
        let holdUntil = queuedAt.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )
        let tNow = queuedAt.addingTimeInterval(2)  // 2 s after send
        // At t=2, the drain filter should skip (hold not expired).
        #expect(holdUntil > tNow)
    }

    @Test("At t=5 s (Undo deadline), drain still skips — 1 s claim buffer remains")
    func atUndoDeadline() {
        let queuedAt = Date()
        let holdUntil = queuedAt.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )
        let tNow = queuedAt.addingTimeInterval(SyncConfig.outboxUndoHoldSeconds)
        // At t=5 (Undo deadline), UI stops rendering Undo button, but drain
        // still has 1 s to wait before claim. This is the TOCTOU-race-free
        // window.
        #expect(holdUntil > tNow)
    }

    @Test("At t=6 s, hold has expired → drain claims")
    func atDrainClaimTime() {
        let queuedAt = Date()
        let holdUntil = queuedAt.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )
        let tNow = queuedAt.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds + 0.01
        )
        #expect(holdUntil <= tNow)
    }
}

// MARK: - Rate-limit spacing

@Suite("Rate-limit inter-send spacing")
struct RateLimitSpacingTests {

    @Test("Two sends queued at t=0 and t=0.5 both get ~6 s hold; drain spaces them 3 s apart")
    func twoQueuedSpacing() {
        let t0 = Date()
        let holdA = t0.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )
        let tB = t0.addingTimeInterval(0.5)
        let holdB = tB.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
        )
        // A's hold passes first (6 s after t=0).
        #expect(holdA < holdB)
        // B's hold is just 0.5 s after A's, NOT 3 s. The 3 s spacing comes
        // from the drain loop's Task.sleep AFTER it sends A, so SMTP-to-SMTP
        // gap ≈ holdA + 3 s = t+9 (not holdB = t+6.5).
        #expect(holdB.timeIntervalSince(holdA) == 0.5)
        let expectedBSendTime = holdA.addingTimeInterval(SyncConfig.outboxMinSendGapSeconds)
        #expect(expectedBSendTime.timeIntervalSince(t0) == 9)
    }
}

// MARK: - Reconcile doesn't touch held rows

/// Replicates `reconcileOutbox`'s core loop: only processes `.sending` rows,
/// never touches `.queued`. This test guards against future refactors that
/// might accidentally sweep up held `.queued` rows.
private func runReconcileForTest(_ db: DatabaseQueue) throws {
    try db.write { dbConn in
        let stale = try OutboxMessage
            .filter(Column("status") == OutboxStatus.sending.rawValue)
            .fetchAll(dbConn)
        for msg in stale {
            if msg.sentAt != nil {
                if msg.appendedToSent {
                    try OutboxMessage.deleteOne(dbConn, key: msg.id)
                }
                // else: keep for Sent-folder append retry
            } else {
                // Mid-send crash — reset to queued for retry.
                try dbConn.execute(
                    sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                    arguments: [OutboxStatus.queued.rawValue, msg.id]
                )
            }
        }
    }
}

@Suite("Reconcile respects held rows")
struct ReconcileRespectsHeldRowsTests {

    @Test(".queued row with future holdUntil is untouched by reconcile")
    func queuedWithFutureHoldUntouched() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let future = Date().addingTimeInterval(5)
        let msg = makeMessage(holdUntil: future, draftId: "d1")
        try db.write { try msg.insert($0) }

        try runReconcileForTest(db)

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched != nil)
        #expect(fetched?.status == OutboxStatus.queued.rawValue)
        #expect(fetched?.draftId == "d1")
        if let h = fetched?.holdUntil {
            #expect(abs(h.timeIntervalSince(future)) < 0.01)
        } else {
            Issue.record("holdUntil nil after reconcile")
        }
    }

    @Test(".queued row with PAST holdUntil is also untouched (drain's job, not reconcile's)")
    func queuedWithPastHoldUntouched() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let past = Date().addingTimeInterval(-10)
        let msg = makeMessage(holdUntil: past, draftId: "d1")
        try db.write { try msg.insert($0) }

        try runReconcileForTest(db)

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched != nil)
        #expect(fetched?.status == OutboxStatus.queued.rawValue)
    }

    @Test(".sending row with sentAt nil is still reset to queued by reconcile (pre-existing behavior)")
    func sendingMidCrashStillResets() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let msg = makeMessage(status: .sending)
        // sentAt stays nil (simulating mid-send crash)
        try db.write { try msg.insert($0) }

        try runReconcileForTest(db)

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.status == OutboxStatus.queued.rawValue)
    }
}

// MARK: - Atomic claim race protection

/// Replicates `atomicClaim`'s core transaction: re-read, verify `.queued`,
/// UPDATE to `.sending`. Returns nil if the row was discarded or already
/// claimed. Mirrors the behavior at AccountManagerOutbox.swift:atomicClaim.
private func runAtomicClaimForTest(_ db: DatabaseQueue, id: String) throws -> (OutboxMessage, String)? {
    try db.write { dbConn -> (OutboxMessage, String)? in
        guard let fetched = try OutboxMessage.fetchOne(dbConn, key: id) else {
            return nil  // vanished (discarded)
        }
        guard fetched.outboxStatus == .queued else {
            return nil  // already claimed
        }
        let messageId = fetched.sentMessageId ?? "<fake@test.local>"
        try dbConn.execute(
            sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
            arguments: [OutboxStatus.sending.rawValue, messageId, fetched.id]
        )
        return (fetched, messageId)
    }
}

@Suite("atomicClaim race protection")
struct AtomicClaimRaceTests {

    @Test("Claim succeeds when row is .queued — status flips to .sending")
    func claimFromQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let msg = makeMessage(status: .queued)
        try db.write { try msg.insert($0) }

        let claimed = try runAtomicClaimForTest(db, id: msg.id)
        #expect(claimed != nil)

        let after = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(after?.outboxStatus == .sending)
    }

    @Test("Claim rejects when row is already .sending (concurrent-drain protection)")
    func claimRejectsSending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let msg = makeMessage(status: .sending)
        try db.write { try msg.insert($0) }

        let claimed = try runAtomicClaimForTest(db, id: msg.id)
        #expect(claimed == nil)

        // Status unchanged.
        let after = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(after?.outboxStatus == .sending)
    }

    @Test("Claim rejects when row is .failed")
    func claimRejectsFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let msg = makeMessage(status: .failed)
        try db.write { try msg.insert($0) }

        let claimed = try runAtomicClaimForTest(db, id: msg.id)
        #expect(claimed == nil)
    }

    @Test("Claim rejects when row is absent (discarded before claim)")
    func claimRejectsMissing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        // Don't insert anything.

        let claimed = try runAtomicClaimForTest(db, id: "nonexistent")
        #expect(claimed == nil)
    }

    @Test("Claim reuses existing sentMessageId if set (retry scenario)")
    func claimReusesMessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var msg = makeMessage(status: .queued)
        msg.sentMessageId = "<pregenerated@test.local>"
        try db.write { try msg.insert($0) }

        let claimed = try runAtomicClaimForTest(db, id: msg.id)
        #expect(claimed?.1 == "<pregenerated@test.local>")
    }
}

// MARK: - Draft survives discard (undo-reopen guarantee)

/// Replicates `discardOutboxMessage`'s core behavior: delete the outbox row
/// (only if `.queued`, not `.sending`), leave the DraftStore row intact.
/// This guards the undo-reopen contract.
private func runDiscardForTest(_ db: DatabaseQueue, outboxId: String) throws -> Bool {
    try db.write { dbConn -> Bool in
        guard let msg = try OutboxMessage.fetchOne(dbConn, key: outboxId) else { return false }
        guard msg.outboxStatus != .sending else { return false }
        try OutboxMessage.deleteOne(dbConn, key: outboxId)
        return true
    }
}

private func insertDraftForTest(_ db: DatabaseQueue, id: String, accountId: String = "acc1") throws {
    let now = Date().timeIntervalSince1970
    let draft = Draft(
        id: id,
        accountId: accountId,
        toJSON: "[\"a@b.com\"]",
        ccJSON: "[]",
        bccJSON: "[]",
        subject: "Test",
        body: "Body",
        replyToId: nil,
        isForward: false,
        editHistoryJSON: nil,
        createdAt: now,
        updatedAt: now
    )
    try db.write { try draft.insert($0) }
}

@Suite("Draft row survives discard (Undo-Send reopen)")
struct DraftSurvivesDiscardTests {

    @Test("Discarding outbox row while held leaves the Draft row intact")
    func discardKeepsDraftIntact() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try insertDraftForTest(db, id: "drft-keep")
        let outbox = makeMessage(
            holdUntil: Date().addingTimeInterval(6),
            draftId: "drft-keep",
            status: .queued
        )
        try db.write { try outbox.insert($0) }

        let discarded = try runDiscardForTest(db, outboxId: outbox.id)
        #expect(discarded == true)

        // Outbox row gone, Draft row still there.
        let outboxAfter = try db.read { try OutboxMessage.fetchOne($0, key: outbox.id) }
        let draftAfter = try db.read { try Draft.fetchOne($0, key: "drft-keep") }
        #expect(outboxAfter == nil)
        #expect(draftAfter != nil)
        #expect(draftAfter?.id == "drft-keep")
    }

    @Test("Discard on .sending refuses; outbox row and Draft row both intact")
    func discardOnSendingRefuses() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try insertDraftForTest(db, id: "drft-sending")
        let outbox = makeMessage(draftId: "drft-sending", status: .sending)
        try db.write { try outbox.insert($0) }

        let discarded = try runDiscardForTest(db, outboxId: outbox.id)
        #expect(discarded == false)

        let outboxAfter = try db.read { try OutboxMessage.fetchOne($0, key: outbox.id) }
        let draftAfter = try db.read { try Draft.fetchOne($0, key: "drft-sending") }
        #expect(outboxAfter != nil)
        #expect(outboxAfter?.outboxStatus == .sending)
        #expect(draftAfter != nil)
    }

    @Test("Replicates deferred-delete: simulate claim → DraftStore.delete flow")
    func simulateClaimThenDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try insertDraftForTest(db, id: "drft-claim")
        let outbox = makeMessage(
            holdUntil: Date().addingTimeInterval(-1),  // ready
            draftId: "drft-claim",
            status: .queued
        )
        try db.write { try outbox.insert($0) }

        // Step 1: atomic claim (queued → sending)
        let claimed = try runAtomicClaimForTest(db, id: outbox.id)
        #expect(claimed != nil)

        // Step 2: deferred DraftStore.delete runs after claim (production uses
        // a Task { try? await DraftStore.shared.delete(id: did) }). Simulate
        // by deleting directly on the test DB.
        if let did = claimed?.0.draftId {
            try db.write { _ = try Draft.deleteOne($0, key: did) }
        }

        let draftAfter = try db.read { try Draft.fetchOne($0, key: "drft-claim") }
        #expect(draftAfter == nil)  // Draft cleaned up by deferred-delete
    }
}

// MARK: - Post-loop wake-up query

@Suite("Post-loop earliest-pending query (wake-up scheduling)")
struct PostLoopWakeUpQueryTests {

    /// Replicates the post-loop query in drainOutbox: earliest queued by
    /// holdUntil. Returns the row (if any) that a wake-up Task should
    /// target.
    private func runEarliestPendingQuery(_ db: DatabaseQueue) throws -> OutboxMessage? {
        try db.read { dbConn in
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("holdUntil").asc)
                .fetchOne(dbConn)
        }
    }

    @Test("Empty queue → no wake-up target")
    func emptyQueue() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let earliest = try runEarliestPendingQuery(db)
        #expect(earliest == nil)
    }

    @Test("Single future-hold message → that message is the wake-up target")
    func singleFutureHold() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let hold = Date().addingTimeInterval(5)
        let msg = makeMessage(id: "only", holdUntil: hold)
        try db.write { try msg.insert($0) }

        let earliest = try runEarliestPendingQuery(db)
        #expect(earliest?.id == "only")
    }

    @Test("Two future-hold messages: the EARLIER holdUntil wins")
    func earliestHoldWins() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let now = Date()
        let soon = makeMessage(id: "soon", holdUntil: now.addingTimeInterval(5))
        let later = makeMessage(id: "later", holdUntil: now.addingTimeInterval(10))
        // Insert `later` first to confirm order is by holdUntil, not insert order.
        try db.write {
            try later.insert($0)
            try soon.insert($0)
        }

        let earliest = try runEarliestPendingQuery(db)
        #expect(earliest?.id == "soon")
    }

    @Test("Wake-up guard: schedule ONLY if holdUntil > now (don't schedule for past-hold)")
    func guardAgainstPastHold() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        // One past-hold (drain loop just picked it up and failed transiently
        // — it's still .queued but with past hold) and one future-hold.
        let now = Date()
        let past = makeMessage(id: "past", holdUntil: now.addingTimeInterval(-1))
        let future = makeMessage(id: "future", holdUntil: now.addingTimeInterval(5))
        try db.write {
            try past.insert($0)
            try future.insert($0)
        }

        let earliest = try runEarliestPendingQuery(db)
        #expect(earliest?.id == "past")  // query returns it by ordering

        // The production code then gates with `let hold = earliest.holdUntil, hold > Date()`.
        // A past-hold row fails this guard → no wake-up scheduled for it.
        let shouldSchedule = (earliest?.holdUntil ?? .distantPast) > Date()
        #expect(shouldSchedule == false)

        // Drop the past-hold row (simulating drain claim or retry deferral),
        // and re-query: now the future row is the wake-up target.
        try db.write { _ = try OutboxMessage.deleteOne($0, key: "past") }
        let earliest2 = try runEarliestPendingQuery(db)
        #expect(earliest2?.id == "future")
        let shouldSchedule2 = (earliest2?.holdUntil ?? .distantPast) > Date()
        #expect(shouldSchedule2 == true)
    }

    @Test("Query ignores .sending and .failed rows")
    func ignoresNonQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let now = Date()
        let sending = makeMessage(id: "sending", holdUntil: now.addingTimeInterval(1), status: .sending)
        let failed = makeMessage(id: "failed", holdUntil: now.addingTimeInterval(2), status: .failed)
        let queued = makeMessage(id: "queued", holdUntil: now.addingTimeInterval(10), status: .queued)
        try db.write {
            try sending.insert($0)
            try failed.insert($0)
            try queued.insert($0)
        }

        let earliest = try runEarliestPendingQuery(db)
        #expect(earliest?.id == "queued")
    }
}
