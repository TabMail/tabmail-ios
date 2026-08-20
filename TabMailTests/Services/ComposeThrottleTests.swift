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

@Suite("PendingSendService generation-safe confirmed cancellation",
       .serialized, .processGlobalState)
@MainActor
struct PendingSendServiceLifecycleTests {
    private enum Refusal: Sendable, Equatable { case sending, sent }

    private func makeFreshService() -> PendingSendService {
        PendingSendService.shared.dismiss()
        return PendingSendService.shared
    }

    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "owner@example.com", displayName: "Owner", provider: .gmail)
            account.id = "acc1"
            try account.insert(db)
        }
        return (pool, directory, previous)
    }

    private func finish(_ fixture: (DatabasePool, URL, AppDatabase?)) {
        PendingSendService.shared.dismiss()
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.2, pool: fixture.0, directory: fixture.1)
    }

    private func draft(id: String, epoch: String) -> Draft {
        var value = Draft(
            id: id, accountId: "acc1", toJSON: "[\"to@example.com\"]",
            ccJSON: "[\"cc@example.com\"]", bccJSON: "[]",
            subject: "subject", body: "body", replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 1)
        value.instanceEpoch = epoch
        return value
    }

    private func outbox(
        id: String = UUID().uuidString,
        draftId: String,
        epoch: String,
        status: OutboxStatus = .queued,
        sentAt: Date? = nil
    ) -> OutboxMessage {
        var value = OutboxMessage(
            accountId: "acc1",
            draft: DraftMessage(to: ["to@example.com"], subject: "subject", body: "body"))
        value.id = id
        value.draftId = draftId
        value.instanceEpoch = epoch
        value.status = status.rawValue
        value.sentAt = sentAt
        // Stamped exactly as `persistQueuedSend` stamps it, so the toast these
        // rows are presented with is inside its hold window rather than backed by
        // no hold at all — the state every `undo()` test below means to model.
        value.holdUntil = Date().addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds)
        return value
    }

    @Test("Pending Send presents and replaces the exact Draft generation")
    func presentCarriesExactGeneration() {
        let svc = makeFreshService()
        let hold = Date().addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds)
        svc.present(
            outboxId: "first", draftId: "draft-1", instanceEpoch: "E1",
            toSummary: "first", holdUntil: hold)
        svc.present(
            outboxId: "second", draftId: "draft-2", instanceEpoch: "E2",
            toSummary: "second", holdUntil: hold)
        #expect(svc.current?.id == "second")
        #expect(svc.current?.draftId == "draft-2")
        #expect(svc.current?.instanceEpoch == "E2")
        svc.dismiss()
    }

    @Test("Undo always attempts confirmed cancellation but never reopens a replaced generation")
    func generationMismatchStillCancels() throws {
        let fixture = try install()
        defer { finish(fixture) }
        let replacement = draft(id: "draft-1", epoch: "E2")
        let pending = outbox(draftId: replacement.id, epoch: "E1")
        try fixture.0.writeWithoutTransaction { db in
            try replacement.insert(db)
            try pending.insert(db)
        }
        let svc = makeFreshService()
        svc.present(
            outboxId: pending.id, draftId: replacement.id, instanceEpoch: "E1",
            toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

        #expect(svc.undo() == nil)
        #expect(try fixture.0.read {
            try OutboxMessage.fetchOne($0, key: pending.id)
        } == nil)
        #expect(try fixture.0.read {
            try Draft.fetchOne($0, key: replacement.id)
        }?.instanceEpoch == "E2")
        #expect(svc.current == nil)
        // The OTHER side of `thrownAuthorityReadLeavesTheSendCancellable` below: a
        // PROVEN mismatch still cancels, so refusing to cancel on an unknown cannot
        // be satisfied by never cancelling at all.
        #expect(svc.undoFailureMessage == nil)
    }

    @Test("Confirmed Undo retains and reopens only the exact Draft generation")
    func confirmedUndoRetainsExactDraft() throws {
        let fixture = try install()
        defer { finish(fixture) }
        let retained = draft(id: "draft-retained", epoch: "E1")
        let pending = outbox(draftId: retained.id, epoch: "E1")
        try fixture.0.writeWithoutTransaction { db in
            try retained.insert(db)
            try pending.insert(db)
        }
        let svc = makeFreshService()
        svc.present(
            outboxId: pending.id, draftId: retained.id, instanceEpoch: "E1",
            toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

        let snapshot = try #require(svc.undo())
        #expect(snapshot.authority == .init(
            draftId: retained.id, accountId: "acc1", instanceEpoch: "E1"))
        #expect(try fixture.0.read {
            try OutboxMessage.fetchOne($0, key: pending.id)
        } == nil)
        #expect(try fixture.0.read {
            try Draft.fetchOne($0, key: retained.id)
        }?.instanceEpoch == "E1")
        let compose = UndoReopenCompose.composeView(for: snapshot)
        #expect(compose.prefillDraftId == retained.id)
        #expect(compose.retainedDraftAuthority == snapshot.authority)
        #expect(svc.current == nil)
    }

    @Test("Undo refuses sending or sent rows and leaves the toast intact", arguments: [
        Refusal.sending, .sent,
    ])
    private func cancellationRefusals(refusal: Refusal) throws {
        let fixture = try install()
        defer { finish(fixture) }
        let retained = draft(id: "draft-refused", epoch: "E1")
        let status: OutboxStatus = refusal == .sending ? .sending : .queued
        let pending = outbox(
            draftId: retained.id, epoch: "E1", status: status,
            sentAt: refusal == .sent ? Date() : nil)
        try fixture.0.writeWithoutTransaction { db in
            try retained.insert(db)
            try pending.insert(db)
        }
        let svc = makeFreshService()
        svc.present(
            outboxId: pending.id, draftId: retained.id, instanceEpoch: "E1",
            toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

        #expect(svc.undo() == nil)
        #expect(try fixture.0.read {
            try OutboxMessage.fetchOne($0, key: pending.id)
        } != nil)
        #expect(try fixture.0.read {
            try Draft.fetchOne($0, key: retained.id)
        } != nil)
        #expect(svc.current?.id == pending.id)
    }

    /// THE INVARIANT: an Undo tap whose retained-authority read THREW must not
    /// destroy the durable send. "We could not determine the answer" is never a
    /// provider-authoritative verdict (never-drop clause 2), and here the cost of
    /// getting it wrong is unrecoverable: cancelling deletes the `OutboxMessage`
    /// *and* returns no reopen snapshot, so the user's authored text survives only
    /// as a `Draft` row nothing can enumerate — `draft` is reachable BY KEY only,
    /// and the send path mints no Drafts-folder header to supply one.
    ///
    /// Asserted AT THE STORE, as end state, not as a classifier's return value: the
    /// `OutboxMessage` row is still there and the toast is still up, so Undo remains
    /// available inside the hold window. Any reimplementation that keeps those two
    /// facts passes; any that cancels on an unknown fails.
    ///
    /// TWO-SIDED, so this cannot pass by simply never cancelling: the proven-mismatch
    /// direction is pinned by `generationMismatchStillCancels` above (row IS deleted,
    /// toast IS cleared, and `undoFailureMessage` stays nil), on the same code path.
    ///
    /// The fault is real, not a seam: dropping `draft` makes the resolver's first
    /// statement throw exactly as a suspended or otherwise unreadable database does
    /// — the same mechanism `ReplyTargetThrownReadTests` uses. `outboxMessage` is
    /// left intact precisely so its survival is the thing under test.
    @Test("A thrown retained-authority read must not cancel the send or clear the toast")
    func thrownAuthorityReadLeavesTheSendCancellable() throws {
        let fixture = try install()
        defer { finish(fixture) }
        let retained = draft(id: "draft-unknown", epoch: "E1")
        let pending = outbox(draftId: retained.id, epoch: "E1")
        try fixture.0.writeWithoutTransaction { db in
            try retained.insert(db)
            try pending.insert(db)
        }
        let svc = makeFreshService()
        svc.present(
            outboxId: pending.id, draftId: retained.id, instanceEpoch: "E1",
            toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

        // NON-VACUITY: while the database is readable this exact pair resolves, so
        // the refusal below is the failure firing and not an empty-fixture miss.
        #expect(try fixture.0.read { try Draft.fetchOne($0, key: retained.id) } != nil)
        #expect(try fixture.0.read { try OutboxMessage.fetchOne($0, key: pending.id) } != nil)

        try fixture.0.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TABLE draft")
        }

        #expect(svc.undo() == nil)
        // (a) the durable send survives — it is still queued and still cancellable.
        #expect(try fixture.0.read {
            try OutboxMessage.fetchOne($0, key: pending.id)
        } != nil)
        // (b) the toast survives, so the user can tap Undo again in the hold window.
        #expect(svc.current?.id == pending.id)
        // (c) and the tap is not a dead one: the user is told it did not take.
        #expect(svc.undoFailureMessage != nil)
    }

    // MARK: - R16-9 — every exit of undo() speaks

    /// Whether this `undo()` return left the user with ANYTHING to observe.
    /// The three channels are the only ones the surface has: a reopen snapshot
    /// (compose comes back), a cleared toast (the send is visibly gone), or an
    /// `undoFailureMessage` (the user is told it did not take). A `nil` return
    /// with the toast still up and no message is a dead tap.
    private func leftAnObservableEndState(
        _ service: PendingSendService, snapshot: PendingSendService.ReopenSnapshot?
    ) -> Bool {
        snapshot != nil || service.current == nil || service.undoFailureMessage != nil
    }

    /// 🚨 THE INVARIANT, asserted as the SYSTEM PROPERTY rather than the fix's
    /// mechanism (`MIS-015`): **every exit of `PendingSendService.undo()` leaves an
    /// observable end state** — a reopen snapshot, a cleared toast, or a non-nil
    /// `undoFailureMessage`. Never a `nil` return with the toast still up and
    /// nothing said.
    ///
    /// The defect this pins: `undo()`'s doc claimed exactly this property, and it
    /// was FALSE for two of its six exits. `RetainedAuthorityOutcome`'s three cases
    /// are a roster of ANSWERS, not of exits — two of those cases each contain a
    /// `guard AccountManager.shared.discardOutboxMessageConfirmed(…) else { return nil }`,
    /// and both inner returns left no snapshot, no cleared toast and no message. The
    /// sibling `.readFailed` arm eight lines above set one for the SAME user
    /// experience: under a suspended GRDB one root cause routed two ways, one spoke,
    /// one was silent, and the message went out while the user believed they had
    /// stopped it. That the invariant was WRITTEN DOWN is exactly how it went
    /// unaudited (`MIS-018`'s tell — a thorough doc comment reads as evidence the
    /// work was done), so it is now machine-checked instead.
    ///
    /// ⚠️ THE REFUSAL ITSELF IS DELIBERATELY HELD AND IS **NOT** UNDER TEST HERE
    /// (`MIS-026`, Outbox Rules 3/10). `discardOutboxMessageConfirmed` returning
    /// `false` means the row was not provably cancelled — a `sending` row may
    /// already have left the server — and making the cancellation unconditional
    /// would be a double-send or a lost message. What R16-9 changed is the SILENCE,
    /// not the refusal, so every refusal case below still asserts that the Outbox
    /// row and the toast SURVIVE.
    ///
    /// Enumerated by counting `return` statements inside `undo()` — six — rather
    /// than by the enum, so a seventh exit cannot join the silent set unnoticed.
    @Test("Every exit of undo() leaves an observable end state")
    func everyUndoExitLeavesAnObservableEndState() throws {
        // EXIT 1 — `guard let p = current`. Nothing to observe because there was no
        // toast to begin with; the cleared-toast channel is satisfied trivially.
        do {
            let service = makeFreshService()
            service.dismiss()
            let snapshot = service.undo()
            #expect(leftAnObservableEndState(service, snapshot: snapshot),
                    "no toast: an undo with nothing pending must still be an observable no-op")
            #expect(service.current == nil)
        }

        // EXIT 2 — `.readFailed`. The read threw, so nothing is decided and the user
        // is told. (Also covered by `thrownAuthorityReadLeavesTheSendCancellable`;
        // repeated here so the roster below is exhaustive rather than partial.)
        do {
            let fixture = try install()
            defer { finish(fixture) }
            let retained = draft(id: "draft-exit-read-failed", epoch: "E1")
            let pending = outbox(draftId: retained.id, epoch: "E1")
            try fixture.0.writeWithoutTransaction { db in
                try retained.insert(db)
                try pending.insert(db)
            }
            let service = makeFreshService()
            service.present(
                outboxId: pending.id, draftId: retained.id, instanceEpoch: "E1",
                toSummary: "To: to@example.com", holdUntil: pending.holdUntil)
            try fixture.0.writeWithoutTransaction { db in
                try db.execute(sql: "DROP TABLE draft")
            }

            let snapshot = service.undo()
            #expect(leftAnObservableEndState(service, snapshot: snapshot),
                    "readFailed: an undecidable read must still tell the user")
            #expect(service.undoFailureMessage != nil)
            #expect(service.current?.id == pending.id,
                    "and the send stays cancellable — the refusal direction is held")
        }

        // EXIT 3 — `.mismatchOrAbsent`, cancellation CONFIRMED. The toast clears,
        // which is the observable end state; no message is needed and none is set.
        do {
            let fixture = try install()
            defer { finish(fixture) }
            let replacement = draft(id: "draft-exit-mismatch-ok", epoch: "E2")
            let pending = outbox(draftId: replacement.id, epoch: "E1")
            try fixture.0.writeWithoutTransaction { db in
                try replacement.insert(db)
                try pending.insert(db)
            }
            let service = makeFreshService()
            service.present(
                outboxId: pending.id, draftId: replacement.id, instanceEpoch: "E1",
                toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

            let snapshot = service.undo()
            #expect(leftAnObservableEndState(service, snapshot: snapshot))
            #expect(service.current == nil)
            #expect(service.undoFailureMessage == nil,
                    "a confirmed cancellation is not a failure — warning here would be the mirror image")
        }

        // EXIT 4 — `.mismatchOrAbsent`, cancellation REFUSED (R16-9 leg A).
        // A `sending` row cannot be provably cancelled, so the refusal stands; what
        // must not stand is the silence.
        do {
            let fixture = try install()
            defer { finish(fixture) }
            let replacement = draft(id: "draft-exit-mismatch-refused", epoch: "E2")
            let pending = outbox(draftId: replacement.id, epoch: "E1", status: .sending)
            try fixture.0.writeWithoutTransaction { db in
                try replacement.insert(db)
                try pending.insert(db)
            }
            let service = makeFreshService()
            service.present(
                outboxId: pending.id, draftId: replacement.id, instanceEpoch: "E1",
                toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

            let snapshot = service.undo()
            #expect(leftAnObservableEndState(service, snapshot: snapshot),
                    "mismatch + refused discard: the user tapped Undo, nothing was cancelled, nothing reopened, and the toast stayed up — so this exit MUST say so or the tap is dead")
            #expect(service.undoFailureMessage != nil,
                    "the sibling `.readFailed` arm sets one for the same user experience; this arm returned nil in silence")
            // The held direction: the refusal itself is preserved.
            #expect(try fixture.0.read { try OutboxMessage.fetchOne($0, key: pending.id) } != nil,
                    "a `sending` row may already have left the server — it must NOT be cancelled")
            #expect(service.current?.id == pending.id)
        }

        // EXIT 5 — `.verified`, cancellation REFUSED (R16-9 leg B). The arm where
        // the user had a reopenable draft in hand, so a silent nil reads as
        // "Undo did nothing at all".
        do {
            let fixture = try install()
            defer { finish(fixture) }
            let retained = draft(id: "draft-exit-verified-refused", epoch: "E1")
            let pending = outbox(draftId: retained.id, epoch: "E1", status: .sending)
            try fixture.0.writeWithoutTransaction { db in
                try retained.insert(db)
                try pending.insert(db)
            }
            let service = makeFreshService()
            service.present(
                outboxId: pending.id, draftId: retained.id, instanceEpoch: "E1",
                toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

            let snapshot = service.undo()
            #expect(leftAnObservableEndState(service, snapshot: snapshot),
                    "verified + refused discard: nothing cancelled, nothing reopened, toast still up — this exit MUST say so")
            #expect(service.undoFailureMessage != nil)
            #expect(try fixture.0.read { try OutboxMessage.fetchOne($0, key: pending.id) } != nil,
                    "the refusal is deliberately held (Outbox Rules 3/10)")
            #expect(service.current?.id == pending.id)
        }

        // EXIT 6 — `.verified`, cancellation CONFIRMED. The snapshot IS the
        // observable end state. This is the NON-VACUITY anchor for the whole test
        // (`MIS-030`): it proves the harness can reach a successful undo at all, so
        // the five absences above are meaningful.
        do {
            let fixture = try install()
            defer { finish(fixture) }
            let retained = draft(id: "draft-exit-verified-ok", epoch: "E1")
            let pending = outbox(draftId: retained.id, epoch: "E1")
            try fixture.0.writeWithoutTransaction { db in
                try retained.insert(db)
                try pending.insert(db)
            }
            let service = makeFreshService()
            service.present(
                outboxId: pending.id, draftId: retained.id, instanceEpoch: "E1",
                toSummary: "To: to@example.com", holdUntil: pending.holdUntil)

            let snapshot = service.undo()
            #expect(leftAnObservableEndState(service, snapshot: snapshot))
            #expect(snapshot != nil, "non-vacuity: a confirmed undo must still reopen")
            #expect(service.current == nil)
            #expect(service.undoFailureMessage == nil)
        }
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

// MARK: - THE INVARIANT — the Undo affordance never outlives the durable hold

/// 🚨 **The invariant, as a SYSTEM PROPERTY rather than a timer wiring
/// (`MIS-015`): the Undo affordance is never offered at an instant at or after
/// the durable hold that backs it.** Precisely, for every instant `t` at which
/// the toast renders an Undo button for an outbox row:
///
///     t + SyncConfig.outboxClaimBufferSeconds <= row.holdUntil
///
/// i.e. the affordance is withdrawn with the whole claim buffer still unspent,
/// which is the margin `atomicClaim` was given to make the tap race-free.
///
/// **The defect this pins (issue #76).** `OutboxMessage.holdUntil` is stamped
/// `queuedAt + undoHold + claimBuffer` where `queuedAt` is captured at persist
/// START, inside `AccountManager.persistQueuedSend`, before its attachment write
/// and before its awaited `dbPool.write`. The toast's window used to be counted
/// as a flat `outboxUndoHoldSeconds` from `PendingSendService.present()`, which
/// `ComposeView` reaches only AFTER that awaited persist returns. The two anchors
/// therefore differ by the persist latency Δ, and for Δ > `claimBuffer` the button
/// stayed tappable after the drain was already free to claim the row — the tap
/// then failed with "Couldn't undo / Try again." on a message that went out.
///
/// **Why these tests are not a replica** (`Companion/Memory/Current/100-…`: a
/// replica cannot go red on a defect in the original): the decision under test is
/// the production one — `PendingSendToastPhase.resolve`, reached through a
/// `Pending` built by the production `PendingSendService.present`. The suite never
/// re-implements the phase rule; it only chooses the instants, which is exactly
/// why `resolve` takes them as parameters instead of reading the clock.
/// `PendingSendToast.body` has a single exhaustive `switch` over that enum and no
/// other branch, so the rendered affordance and `.undoable` are the same fact.
///
/// **Two-sided** (`feedback_non_vacuity_must_be_two_sided`): every sweep also
/// counts the instants at which the affordance IS offered, and asserts that count
/// is non-zero whenever a window should exist. A fix that simply never offers Undo
/// would satisfy the safety half and fail here.
@Suite("Undo affordance never outlives the durable hold (issue #76)",
       .serialized, .processGlobalState)
@MainActor
struct UndoAffordanceHoldInvariantTests {

    private func freshService() -> PendingSendService {
        PendingSendService.shared.dismiss()
        return PendingSendService.shared
    }

    /// Present a toast for a send whose durable hold was stamped `persistLatency`
    /// seconds ago — i.e. a send whose persist took that long — and return the
    /// production `Pending` together with the durable deadline it must respect.
    private func presentAfterPersist(
        latency persistLatency: TimeInterval
    ) throws -> (pending: PendingSendService.Pending, holdUntil: Date, presentedAt: Date) {
        let service = freshService()
        let presentedAt = Date()
        // `persistQueuedSend` stamped this at `presentedAt - persistLatency`.
        let holdUntil = presentedAt.addingTimeInterval(
            SyncConfig.outboxUndoHoldSeconds + SyncConfig.outboxClaimBufferSeconds
                - persistLatency)
        service.present(
            outboxId: "outbox-hold-invariant",
            draftId: "draft-hold-invariant",
            instanceEpoch: "E1",
            toSummary: "To: recipient@example.com",
            holdUntil: holdUntil)
        let pending = try #require(service.current)
        return (pending, holdUntil, presentedAt)
    }

    /// Sweep every 50 ms from presentation to well past the hold and count the
    /// instants at which Undo is offered. Returns that count so the caller can
    /// assert non-vacuity; asserts the safety half inline.
    private func sweepAssertingSafety(
        pending: PendingSendService.Pending,
        holdUntil: Date,
        presentedAt: Date
    ) -> Int {
        var offered = 0
        var step: TimeInterval = 0
        let horizon = SyncConfig.outboxUndoHoldSeconds
            + SyncConfig.outboxClaimBufferSeconds + 2
        while step <= horizon {
            let instant = presentedAt.addingTimeInterval(step)
            if case .undoable = PendingSendToastPhase.resolve(
                at: instant, presentedAt: pending.presentedAt,
                undoDeadline: pending.undoDeadline
            ) {
                offered += 1
                #expect(instant < holdUntil, """
                    the Undo affordance was offered \(instant.timeIntervalSince(holdUntil)) s \
                    RELATIVE TO the durable hold — a tap here reaches a row the drain is already \
                    free to claim, which is the "Couldn't undo" end state
                    """)
                #expect(
                    instant.addingTimeInterval(SyncConfig.outboxClaimBufferSeconds) <= holdUntil,
                    """
                    the affordance was offered with less than the full claim buffer left \
                    (\(holdUntil.timeIntervalSince(instant)) s to the hold); the buffer is the \
                    margin atomicClaim was given, not slack to spend
                    """)
            }
            step += 0.05
        }
        return offered
    }

    @Test("Undo is never offered at or after the durable hold, at any persist latency",
          arguments: [0.0, 0.25, 1.0, 2.0, 4.0, 4.9, 5.0, 6.0, 9.0] as [TimeInterval])
    func undoIsNeverOfferedAtOrAfterTheDurableHold(persistLatency: TimeInterval) throws {
        let scenario = try presentAfterPersist(latency: persistLatency)
        defer { PendingSendService.shared.dismiss() }

        let offered = sweepAssertingSafety(
            pending: scenario.pending,
            holdUntil: scenario.holdUntil,
            presentedAt: scenario.presentedAt)

        // NON-VACUITY, the other side of the invariant. A window exists exactly
        // while the persist finished with time left before `holdUntil - buffer`.
        if persistLatency < SyncConfig.outboxUndoHoldSeconds {
            #expect(offered > 0, """
                persistLatency=\(persistLatency): an undo window should still exist here, so a \
                sweep that never once saw `.undoable` means the safety half above passed \
                vacuously
                """)
        } else {
            #expect(offered == 0, """
                persistLatency=\(persistLatency): the persist consumed the entire undo window, so \
                no Undo may be offered at all
                """)
        }
    }

    /// The sharp, single-instant statement of the defect. Δ = 2 s ⇒ the durable
    /// hold ends 4 s after the toast appears. The pre-fix rule rendered the button
    /// for a flat 5 s from presentation, so t = present + 4.5 s was inside the
    /// button's window and a full 0.5 s past the drain's claim deadline.
    @Test("A 2 s persist shortens the VISIBLE undo window instead of outliving the hold")
    func slowPersistShortensTheVisibleWindowNotTheHold() throws {
        let scenario = try presentAfterPersist(latency: 2.0)
        defer { PendingSendService.shared.dismiss() }
        let pending = scenario.pending

        let lateTap = scenario.presentedAt.addingTimeInterval(4.5)
        // Non-vacuity for THIS instant: it really is past the durable hold, and it
        // really is inside the flat five seconds the old rule would have allowed.
        #expect(scenario.holdUntil < lateTap,
                "fixture check: at present+4.5 s the durable hold must already be gone")
        #expect(lateTap.timeIntervalSince(scenario.presentedAt) < SyncConfig.outboxUndoHoldSeconds,
                "fixture check: present+4.5 s must be inside the pre-fix flat window")
        #expect(PendingSendToastPhase.resolve(
            at: lateTap, presentedAt: pending.presentedAt, undoDeadline: pending.undoDeadline
        ) == .confirming, """
            the affordance survived its durable hold: a tap at present+4.5 s would reach a row \
            the drain may already have claimed
            """)

        // And the other side — the shortened window is a real window, not zero.
        let earlyTap = scenario.presentedAt.addingTimeInterval(1.0)
        guard case .undoable = PendingSendToastPhase.resolve(
            at: earlyTap, presentedAt: pending.presentedAt, undoDeadline: pending.undoDeadline
        ) else {
            Issue.record("a 2 s persist must still leave a usable undo window at present+1 s")
            return
        }
    }

    /// Fail closed when the hold is ALREADY gone by the time the toast is built —
    /// a very slow persist, or a dedup onto an older in-flight row whose hold was
    /// stamped long before. Offering an Undo we cannot honour is the defect;
    /// offering none is the correct, recoverable outcome (the message lands in
    /// Sent, where the user can reach it).
    ///
    /// This test also stands as the live proof that `present` does not trap on a
    /// past deadline: it computes the auto-dismiss interval from `holdUntil`, and
    /// `UInt64(a negative Double)` is a runtime TRAP in Swift, so an unclamped
    /// implementation kills the test host here rather than failing an assertion
    /// (`Companion/Memory/Current/100-…`).
    @Test("A hold that has already elapsed offers no Undo at all")
    func elapsedHoldOffersNoUndo() throws {
        let service = freshService()
        defer { service.dismiss() }
        let presentedAt = Date()
        let holdUntil = presentedAt.addingTimeInterval(-30)
        service.present(
            outboxId: "outbox-elapsed-hold",
            draftId: "draft-elapsed-hold",
            instanceEpoch: "E1",
            toSummary: "To: recipient@example.com",
            holdUntil: holdUntil)
        let pending = try #require(service.current)

        #expect(pending.id == "outbox-elapsed-hold",
                "the toast itself still appears — only its Undo affordance is withheld")
        for offset in [0.0, 0.1, 1.0, 4.9] as [TimeInterval] {
            #expect(PendingSendToastPhase.resolve(
                at: presentedAt.addingTimeInterval(offset),
                presentedAt: pending.presentedAt,
                undoDeadline: pending.undoDeadline
            ) == .confirming, "no Undo may be offered \(offset) s after an already-elapsed hold")
        }
    }

    /// A legacy pre-v49 row carries no hold at all, and the drain's admission
    /// filter reads that as "claimable immediately"
    /// (`(holdUntil ?? .distantPast) <= Date()`). The affordance must agree with
    /// the drain rather than invent a window.
    @Test("A row with no durable hold offers no Undo")
    func absentHoldOffersNoUndo() throws {
        let service = freshService()
        defer { service.dismiss() }
        let presentedAt = Date()
        service.present(
            outboxId: "outbox-legacy-row",
            draftId: "draft-legacy-row",
            instanceEpoch: "E1",
            toSummary: "To: recipient@example.com",
            holdUntil: nil)
        let pending = try #require(service.current)

        #expect(pending.undoDeadline == .distantPast)
        #expect(PendingSendToastPhase.resolve(
            at: presentedAt, presentedAt: pending.presentedAt,
            undoDeadline: pending.undoDeadline
        ) == .confirming)
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

}

// MARK: - Post-loop wake-up query

@Suite("Post-loop earliest-pending query (wake-up scheduling)")
struct PostLoopWakeUpQueryTests {

    /// Calls the PRODUCTION wake-up query that `drainOutbox` uses, rather than a
    /// copy of it.
    ///
    /// ⚠️ It used to be a copy — `.filter(status == queued).order(holdUntil.asc)
    /// .fetchOne(db)` written out here — and that is precisely why this suite
    /// stayed green while production shipped `IOS-OUTBOX-002`: a replica cannot
    /// red on a defect in the original. Reaching through to
    /// `AccountManager.earliestFutureHoldWakeTarget(now:db:)` makes every case
    /// below an assertion about the app.
    private func runEarliestPendingQuery(_ db: DatabaseQueue) throws -> OutboxMessage? {
        try db.read { dbConn in
            try AccountManager.earliestFutureHoldWakeTarget(now: Date(), db: dbConn)
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

    /// ⚠️ RE-SCOPED (`IOS-OUTBOX-002`). **Previous display name: "Wake-up guard:
    /// schedule ONLY if holdUntil > now (don't schedule for past-hold)".** It
    /// asserted `earliest?.id == "past"` and `shouldSchedule == false` with a
    /// future-held row sitting in the same table — i.e. it ENCODED the defect as
    /// the expected behaviour: the past-held row shadows the future one, no timer
    /// is armed, and the future row is reached only by some later drain trigger.
    /// It could only assert that because it ran against a replica of the query;
    /// once `runEarliestPendingQuery` calls production, the old expectation reds.
    /// The test was not deleted and none of its fixture changed — only the
    /// expectation it encodes, from the shadowing behaviour to the invariant the
    /// shadowing violated. Its second half (deleting the shadowing row and
    /// re-querying) is kept as the ordering control it always was.
    @Test("Wake-up target: a future-held row is selected even when a past-held row sorts ahead of it")
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

        // The past-held row sorts first under `holdUntil ASC` but is NOT a wake
        // target — its deadline has already passed, so the ordinary drain loop
        // owns it. The future-held row behind it is what needs a timer.
        let earliest = try runEarliestPendingQuery(db)
        #expect(earliest?.id == "future")

        // …and the production re-check (`let hold = earliest.holdUntil, hold >
        // Date()`) now passes, which is what actually arms the wake-up Task.
        let shouldSchedule = (earliest?.holdUntil ?? .distantPast) > Date()
        #expect(shouldSchedule == true)

        // Ordering control: with the shadowing row gone the answer is unchanged.
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
