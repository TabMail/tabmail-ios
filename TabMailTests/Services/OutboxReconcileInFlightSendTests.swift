/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

// MARK: - Crash-residue reconciliation versus a live, in-flight send

/// **THE SYSTEM PROPERTY, and the only thing this suite asserts: a message whose
/// SMTP transaction is on the wire is never observable as `.queued`, and can
/// never be discarded — whichever reconciliation entry runs.**
///
/// Nothing here inspects a flag, counts guard evaluations, or asserts that some
/// particular function was called. Every assertion is on state a USER can reach:
/// the durable row's status, whether the Discard gesture is accepted, whether
/// the message reached the Sent folder, and how many times the provider was
/// asked to transmit it. A differently-implemented mutual exclusion that upholds
/// the property stays green here; a broken one reds.
///
/// **Why the property is load-bearing.** `reconcileOutbox` resets
/// `.sending`/`sentAt == nil` rows to `.queued`, because that is the state a
/// process killed mid-send leaves behind. Durable state cannot distinguish that
/// residue from a row a LIVE drain has just claimed and handed to the provider:
/// `sentAt` is stamped only after `provider.send()` RETURNS, so an in-flight
/// send looks exactly like residue. If the reset lands on the live row,
/// `discardOutboxMessageConfirmed` — whose refusal conditions are
/// `outboxStatus == .sending` and `sentAt != nil`, both now false — accepts a
/// Discard and deletes the row and its attachments. `stampSentAt` then matches
/// zero rows, `sendSingleOutboxMessage` returns at its guard, and there is no
/// optimistic Sent header, no Sent APPEND and no finalize. **The recipient
/// receives a message the user was told was discarded, and it never appears in
/// Sent.** Outbox Reliability Rule 3 (`sentAt` before delete — the double-send
/// firewall) and Rule 10 (cannot discard a `sending` message) both forbid that.
///
/// **Both production reconciliation entries are covered, because there are
/// exactly two and they differ in what protected them:**
/// 1. `reconcileOutbox()` — reached from `AccountManager.reconcilePendingOperations`,
///    which `RootView`'s launch task awaits. It had NO ownership check at all.
///    `launchReconciliationCannotUnclaimAnInFlightSend` drives that entry with a
///    send genuinely on the wire, and is the RED-FIRST proof for the suite.
/// 2. `reconcileOutboxOnForeground()` — `RootView`'s `scenePhase → .active`
///    branch. It read the drain latch and then `await`ed, which released the
///    actor for as long as `PrioritizedDatabase.read`'s staging merge takes
///    (measured at 7.6 s on a cold-I/O boot, and staging is pending precisely on
///    foreground return). `foregroundReconciliationCannotUnclaimAnInFlightSend`
///    pins the same property through that entry, and
///    `interleavedForegroundReconciliationCannotUnclaimAnInFlightSend` attacks
///    the scheduling window itself.
///
/// **Every case is non-vacuous in the liveness direction too.** A "fix" that
/// simply stopped reconciling, or stopped draining, would satisfy "never
/// `.queued` while in flight" trivially — so every case also requires the
/// message to be transmitted exactly once, to reach the Sent folder, and to
/// finalize its durable row. Refusing to send is a dropped intention, which is
/// worse than the bug being fixed.
///
/// `.serialized` + `.processGlobalState`: each case rebinds the process-global
/// `AppDatabase.shared` that the drain, the claim and reconciliation all write
/// through. example.com addresses only; every instant derives from `Date()`.
@Suite("Outbox reconciliation versus an in-flight send", .serialized, .processGlobalState)
struct OutboxReconcileInFlightSendTests {

    // MARK: - Fixture

    private static let accountId = "acc-outbox-inflight"

    /// Installs a temp file-backed `DatabasePool` as `AppDatabase.shared`, seeds
    /// the account the outbox row's foreign key needs, and — unlike the sibling
    /// outbox suites — seeds a **Sent folder**. That is deliberate: without one,
    /// `attemptSentAppend` short-circuits to `markAppendedToSent` and never calls
    /// the provider, so "the message never reached Sent" would be
    /// unobservable — and that consequence is half of what this suite exists to
    /// pin.
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
            acc.id = Self.accountId
            try acc.insert(db)
            let sent = Folder(name: "Sent", path: "Sent", role: .sent, accountId: Self.accountId)
            try sent.insert(db)
        }
        return (pool, dir, previous)
    }

    private func restore(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    /// One ready-to-send queued row. `holdUntil` is a PAST instant derived from
    /// `Date()`, so the undo-hold gate can never be the reason a claim is
    /// refused.
    @discardableResult
    private func seedQueued(_ pool: DatabasePool, id: String) throws -> OutboxMessage {
        let draft = DraftMessage(
            to: ["recipient@example.com"], subject: "In-flight \(id)", body: "Body")
        var msg = OutboxMessage(accountId: Self.accountId, draft: draft)
        msg.id = id
        msg.status = OutboxStatus.queued.rawValue
        msg.sentAt = nil
        msg.holdUntil = Date().addingTimeInterval(-3600)
        let insertable = msg
        try pool.write { try insertable.insert($0) }
        return msg
    }

    // MARK: - Cases

    /// **RED-FIRST PROOF for the whole suite.** The launch entry had no
    /// ownership check whatsoever, so the interleaving is fully deterministic:
    /// the send is held open inside the provider by a gate this test controls,
    /// and reconciliation is then invoked exactly as
    /// `reconcilePendingOperations` invokes it.
    ///
    /// Pre-fix this fails on the status observation (`.queued` while the
    /// provider call had not returned), on the Discard being ACCEPTED, on the
    /// row having been deleted, and on the message never reaching Sent.
    @Test("Launch reconciliation cannot unclaim a send that is on the wire, and cannot make it discardable")
    func launchReconciliationCannotUnclaimAnInFlightSend() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let outboxId = "outbox-inflight-launch"
        try seedQueued(pool, id: outboxId)

        let provider = MockEmailProvider()
        let onTheWire = OneShotGate()
        let letSendReturn = OneShotGate()
        await provider.setSendHook {
            onTheWire.open()
            await letSendReturn.wait()
        }

        try await TestProviderRegistry.withRegisteredProvider(
            accountId: Self.accountId, provider: provider
        ) {
            let drainTask = Task { await AccountManager.shared.drainOutbox() }
            await onTheWire.wait()

            // The launch entry, verbatim: `reconcilePendingOperations` awaits
            // this exact function and supplies no check of its own.
            await AccountManager.shared.reconcileOutbox()

            // ---- Observations taken while `provider.send` has NOT returned ----
            let during = try outboxRow(pool, outboxId)
            #expect(during?.outboxStatus != .queued, """
                reconciliation returned a row to `.queued` while its SMTP transaction was still on \
                the wire. `.queued` is the state that says "no send has been attempted": it makes \
                the row re-claimable by the next drain and, worse, strips the two conditions that \
                make Discard refuse
                """)
            let discardAccepted = AccountManager.shared.discardOutboxMessageConfirmed(outboxId)
            #expect(discardAccepted == false, """
                the user was allowed to discard a message whose SMTP transaction was already on \
                the wire — Outbox Reliability Rule 10. The recipient still receives it, the row \
                and its attachments are gone, and `stampSentAt` will match no row, so nothing ever \
                appends it to Sent
                """)
            let survives = try outboxRow(pool, outboxId) != nil
            #expect(survives, "the durable row backing an in-flight send was deleted")

            letSendReturn.open()
            await settle(pool: pool, outboxId: outboxId, tasks: [drainTask])

            // ---- Liveness: the intention completed, exactly once ----
            #expect(await provider.sentDrafts.count == 1,
                    "the user's message must be transmitted exactly once")
            #expect(await provider.appendedToSent.count == 1, """
                the message was transmitted but never appended to Sent. That is the user-visible \
                half of this defect: the recipient has the mail and the sender has no record of it
                """)
            let finalized = try outboxRow(pool, outboxId) == nil
            #expect(finalized, "a fully completed send must finalize its durable row")
        }
    }

    /// The same property through the SECOND production entry.
    ///
    /// Stated honestly: with the send already on the wire when this entry is
    /// called, the pre-fix code also passed — its wrapper-local latch check
    /// caught exactly this ordering. It is here because the fix DELETES that
    /// wrapper check and makes `reconcileOutboxOnForeground` a pure delegate to
    /// the one guarded `reconcileOutbox`, and a delegate that silently regained
    /// reconciliation logic of its own is the regression this case would catch.
    /// The window the wrapper genuinely lost — being past its check and then
    /// suspended — is attacked by the case below.
    @Test("Foreground reconciliation cannot unclaim a send that is on the wire, and cannot make it discardable")
    func foregroundReconciliationCannotUnclaimAnInFlightSend() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let outboxId = "outbox-inflight-foreground"
        try seedQueued(pool, id: outboxId)

        let provider = MockEmailProvider()
        let onTheWire = OneShotGate()
        let letSendReturn = OneShotGate()
        await provider.setSendHook {
            onTheWire.open()
            await letSendReturn.wait()
        }

        try await TestProviderRegistry.withRegisteredProvider(
            accountId: Self.accountId, provider: provider
        ) {
            let drainTask = Task { await AccountManager.shared.drainOutbox() }
            await onTheWire.wait()

            await AccountManager.shared.reconcileOutboxOnForeground()

            let during = try outboxRow(pool, outboxId)
            #expect(during?.outboxStatus != .queued,
                    "the foreground entry returned an in-flight send to `.queued`")
            let discardAccepted = AccountManager.shared.discardOutboxMessageConfirmed(outboxId)
            #expect(discardAccepted == false,
                    "the foreground entry made a message whose SMTP was on the wire discardable")
            let survives = try outboxRow(pool, outboxId) != nil
            #expect(survives, "the durable row backing an in-flight send was deleted")

            letSendReturn.open()
            await settle(pool: pool, outboxId: outboxId, tasks: [drainTask])

            #expect(await provider.sentDrafts.count == 1)
            #expect(await provider.appendedToSent.count == 1)
            let finalized = try outboxRow(pool, outboxId) == nil
            #expect(finalized)
        }
    }

    /// **The foreground entry's own window: past the check, then suspended.**
    ///
    /// The pre-fix wrapper read the latch and then `await`ed `reconcileOutbox`,
    /// whose first statement is an `await dbPool.read` — an actor release long
    /// enough for a whole drain to claim a row and reach the provider. A latch
    /// observed before a suspension says nothing about the state at the write on
    /// the far side of it, which is precisely why the fix ACQUIRES it instead of
    /// merely reading it.
    ///
    /// That window is a scheduling window, so this case attacks it the way the
    /// project's concurrency-fuzzing rule prescribes rather than pretending it
    /// is deterministic: reconciliation and a drain are started concurrently
    /// across a sweep of yield offsets, and the observation is taken from INSIDE
    /// `provider.send` — the only place where "the transaction is on the wire"
    /// is a fact rather than an inference. Whichever side wins a given
    /// iteration, the invariant is identical, and the liveness assertions keep a
    /// "nobody sent anything" outcome from passing.
    ///
    /// ⚠️ **RECORDED HONESTLY: this case did NOT go red on the pre-fix code,
    /// and the reason is worth keeping.** In the red run it passed all six
    /// offsets while `launchReconciliationCannotUnclaimAnInFlightSend` failed
    /// four assertions. Reconciliation takes its `.sending` snapshot at its
    /// FIRST await, and in a test that read completes in microseconds — the
    /// drain needs several awaits (the stuck-row report, the Sent-append phase,
    /// the queued fetch, the claim's own read and write) before it can claim, so
    /// the snapshot essentially always wins and the victim row is not in it. The
    /// production window exists because that same read runs a full NSE staging
    /// merge first — seconds, on foreground return specifically — and this
    /// harness has no honest way to make it take seconds. So this case is a
    /// regression guard over concurrent reconcile/drain interleavings, NOT the
    /// red proof for the foreground entry. The red proof is the launch case
    /// above; what carries it to this entry is that
    /// `reconcileOutboxOnForeground` now holds no logic of its own.
    @Test("Interleaved foreground reconciliation and drain never expose an in-flight send as queued or discardable")
    func interleavedForegroundReconciliationCannotUnclaimAnInFlightSend() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }

        let provider = MockEmailProvider()
        let iterations = 6

        try await TestProviderRegistry.withRegisteredProvider(
            accountId: Self.accountId, provider: provider
        ) {
            for offset in 0..<iterations {
                let outboxId = "outbox-inflight-race-\(offset)"
                try seedQueued(pool, id: outboxId)

                // Observed from inside the provider call, i.e. after the claim
                // and before `sentAt` exists. `queuedWhileOnTheWire` is set only
                // if the durable row is ACTUALLY seen at `.queued` there.
                let queuedWhileOnTheWire = Mutex<Bool>(false)
                let discardAccepted = Mutex<Bool>(false)
                await provider.setSendHook {
                    for _ in 0..<200 {
                        if let row = try? outboxRow(pool, outboxId),
                           row.outboxStatus == .queued {
                            queuedWhileOnTheWire.withLock { $0 = true }
                            break
                        }
                        try? await Task.sleep(nanoseconds: 500_000)
                    }
                    let accepted = AccountManager.shared.discardOutboxMessageConfirmed(outboxId)
                    discardAccepted.withLock { $0 = accepted }
                }

                let reconcileTask = Task { await AccountManager.shared.reconcileOutboxOnForeground() }
                for _ in 0..<offset { await Task.yield() }
                let drainTask = Task { await AccountManager.shared.drainOutbox() }
                await settle(pool: pool, outboxId: outboxId, tasks: [reconcileTask, drainTask])

                #expect(queuedWhileOnTheWire.withLock { $0 } == false, """
                    offset \(offset): the durable row was observed at `.queued` from inside the \
                    provider call — the send was on the wire and the message was simultaneously \
                    advertised as never attempted
                    """)
                #expect(discardAccepted.withLock { $0 } == false, """
                    offset \(offset): Discard was accepted for a message whose SMTP transaction \
                    was on the wire
                    """)
                // Liveness, per iteration: refusing to send would satisfy the
                // two assertions above vacuously.
                #expect(await provider.sentDrafts.count == offset + 1,
                        "offset \(offset): the message must be transmitted exactly once")
                #expect(await provider.appendedToSent.count == offset + 1,
                        "offset \(offset): the transmitted message never reached Sent")
                let finalized = try outboxRow(pool, outboxId) == nil
                #expect(finalized,
                        "offset \(offset): a fully completed send must finalize its durable row")
            }
        }
        await provider.setSendHook(nil)
    }

    /// Wait until the row under test has left the table — which happens only
    /// after finalize (send + Sent append + atomic delete) or after a discard —
    /// then stop the drain loops.
    ///
    /// The cancel is what keeps this suite fast: `drainOutbox` sleeps
    /// `SyncConfig.outboxMinSendGapSeconds` between sends, and that global rate
    /// limit is not what any case here is about. Cancelling only AFTER the row
    /// has vanished means every observed outcome — the send, the Sent append,
    /// the finalize — has already committed, so cancellation can never be the
    /// reason an assertion passes or fails.
    private func settle(
        pool: DatabasePool, outboxId: String, tasks: [Task<Void, Never>]
    ) async {
        for _ in 0..<2000 {
            // do/catch rather than `try?`: `try?` flattens (SE-0230), so a
            // FAILED read and a row that is genuinely absent would both read as
            // `nil` and a transient read error would end the wait early.
            var vanished = false
            do { vanished = try outboxRow(pool, outboxId) == nil } catch { vanished = false }
            if vanished { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}

/// Read one outbox row SYNCHRONOUSLY. A file-scope function, not a method,
/// because it is called from `@Sendable` provider hooks; and synchronous
/// because inside an `async` context `pool.read { }` binds GRDB's async
/// overload, which would suspend rather than sample the row at that instant.
private func outboxRow(_ pool: DatabasePool, _ id: String) throws -> OutboxMessage? {
    try pool.read { try OutboxMessage.fetchOne($0, key: id) }
}
