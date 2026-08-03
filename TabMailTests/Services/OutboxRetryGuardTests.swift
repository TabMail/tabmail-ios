/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

// MARK: - D1: manual Retry must never re-admit a live or already-sent send

/// Drives the REAL `AccountManager.retryOutboxMessage` against a rebound
/// `AppDatabase.shared`, because the defect lives in that function's durable
/// write — not in any logic a test could replicate.
///
/// **The invariant pinned here (the system property, not the fix's mechanism):**
/// *A retry must never move a message that is `.sending`, or that has already
/// been sent (`sentAt != nil`), back into a drainable state.*
///
/// Every assertion is on the OBSERVABLE END STATE — the row's status /
/// `sentAt` / `retryCount` / `errorMessage` after the retry attempt, and the
/// returned `Bool`. Nothing here inspects the SQL text or `changesCount`, so a
/// differently-implemented guard that upholds the property stays green and a
/// broken one reds.
///
/// **Why this is reachable in production:** the only gate on Retry is the
/// SwiftUI row snapshot in `OutboxView` (`message.outboxStatus == .failed`), and
/// `NavigationStore`'s refresh debounce keeps a failed row's Retry affordance
/// visible after a first Retry has already queued it and the drain has claimed
/// it `.sending`. A second activation off that stale snapshot is what resets the
/// live send.
///
/// **The owner's binding directive is respected:** having a failed draft retried
/// IS user intention. `retryFailedUnsentRowIsAdmitted` is the protected flow and
/// asserts it still works end to end — it is the two-sided control every refusal
/// below is measured against, so this suite cannot pass vacuously against a
/// system that admits nothing.
///
/// **Side-effect observability — the honest maximum.** The commit-gated side
/// effects are the `.backgroundDataDidChange` post and a fire-and-forget
/// `Task { drainOutbox() }`. The post is directly observable and asserted in
/// both directions (exactly 1 on an admitted retry, 0 on every refusal); it is
/// posted synchronously on the calling thread, so the observer window is the
/// call itself. The drain kick has no production seam to spy on and is a no-op
/// in a test process (`workQueues` is empty), so it cannot be observed
/// directly; the tests instead assert the end state a drain could only reach
/// through the row being drainable, and the notification count witnesses
/// whether the refused path signalled success at all.
///
/// `.serialized` + `.processGlobalState`: each test rebinds the process-global
/// `AppDatabase.shared`, so no other global-state suite may run concurrently.
/// Uses example.com addresses only; every date is derived from `Date()`.
@Suite("Outbox retry guard (D1)", .serialized, .processGlobalState)
@MainActor
struct OutboxRetryGuardTests {

    // MARK: - Fixture

    /// Installs a temp file-backed `DatabasePool` as `AppDatabase.shared` (the
    /// pool `retryOutboxMessage` writes through) and seeds the account the
    /// outbox row's foreign key needs. Caller tears down via `restore`.
    private func makeTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
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

    /// Restores the prior process DB, then hands this fixture over for
    /// close-before-unlink. An admitted retry deliberately fires an escaped
    /// `Task { drainOutbox() }`, so the fixture is retained rather than closed
    /// on the spot.
    private func restore(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    /// Seed one outbox row in an explicit durable state. `retryCount` and
    /// `errorMessage` are seeded non-default so a refused retry's "row
    /// unchanged" claim covers every field the UPDATE would have touched.
    @discardableResult
    private func seedOutbox(
        _ pool: DatabasePool,
        id: String,
        status: OutboxStatus,
        sentAt: Date? = nil,
        retryCount: Int = 3,
        errorMessage: String? = "previous failure"
    ) throws -> OutboxMessage {
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "Subject", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.id = id
        msg.status = status.rawValue
        msg.sentAt = sentAt
        msg.retryCount = retryCount
        msg.errorMessage = errorMessage
        let insertable = msg
        try pool.write { try insertable.insert($0) }
        return msg
    }

    /// Runs `retryOutboxMessage` while counting `.backgroundDataDidChange`
    /// posts. The observer is registered immediately before and torn down
    /// immediately after the synchronous call, so the counted window is the
    /// call itself.
    private func retryCountingPosts(_ messageId: String) -> (accepted: Bool, posts: Int) {
        let counter = Mutex(0)
        let token = NotificationCenter.default.addObserver(
            forName: .backgroundDataDidChange,
            object: nil,
            queue: nil
        ) { _ in
            counter.withLock { $0 += 1 }
        }
        let accepted = AccountManager.shared.retryOutboxMessage(messageId)
        NotificationCenter.default.removeObserver(token)
        return (accepted, counter.withLock { $0 })
    }

    /// Lets any fire-and-forget `Task { drainOutbox() }` reach its first
    /// suspension before the test returns.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func row(_ pool: DatabasePool, _ id: String) throws -> OutboxMessage? {
        try pool.read { try OutboxMessage.fetchOne($0, key: id) }
    }

    // MARK: - The protected flow (owner directive) — must keep working

    @Test("PROTECTED: a .failed row with sentAt == nil is admitted — status becomes .queued, retryCount/errorMessage reset, returns true, side effects fire")
    func retryFailedUnsentRowIsAdmitted() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        try seedOutbox(pool, id: "ob-failed", status: .failed, sentAt: nil)

        let outcome = retryCountingPosts("ob-failed")

        #expect(outcome.accepted == true)
        #expect(outcome.posts == 1)  // admitted retry signals success

        let after = try row(pool, "ob-failed")
        #expect(after?.outboxStatus == .queued)  // drainable again — the user's intention
        #expect(after?.sentAt == nil)
        #expect(after?.retryCount == 0)          // fresh set of automatic retries
        #expect(after?.errorMessage == nil)
        await settle()
    }

    // MARK: - Refusals

    @Test("A .sending row is refused — it stays .sending, returns false, no success signal")
    func retryRefusesSendingRow() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        try seedOutbox(pool, id: "ob-sending", status: .sending, sentAt: nil)

        let outcome = retryCountingPosts("ob-sending")

        #expect(outcome.accepted == false)
        #expect(outcome.posts == 0)  // a refused retry must not signal success

        let after = try row(pool, "ob-sending")
        // The live send is untouched: it must NOT be re-admitted as drainable.
        #expect(after?.outboxStatus == .sending)
        #expect(after?.retryCount == 3)
        #expect(after?.errorMessage == "previous failure")
        await settle()
    }

    @Test("A .queued row is refused — it stays queued with its counters intact, returns false")
    func retryRefusesQueuedRow() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        try seedOutbox(pool, id: "ob-queued", status: .queued, sentAt: nil)

        let outcome = retryCountingPosts("ob-queued")

        #expect(outcome.accepted == false)
        #expect(outcome.posts == 0)

        let after = try row(pool, "ob-queued")
        #expect(after?.outboxStatus == .queued)
        // Already carrying the requested retry intention — its automatic-retry
        // budget must not be silently rewound by a second activation.
        #expect(after?.retryCount == 3)
        #expect(after?.errorMessage == "previous failure")
        await settle()
    }

    @Test("ALREADY SENT: any status with sentAt != nil is refused and left untouched", arguments: [OutboxStatus.failed, .queued, .sending])
    func retryRefusesAlreadySentRow(status: OutboxStatus) async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        // sentAt set = the provider send already succeeded. The row belongs to
        // Sent-append/finalization recovery and must never re-enter the send
        // phase — re-admitting it is a DOUBLE SEND.
        let sentAt = Date()
        let id = "ob-sent-\(status.rawValue)"
        try seedOutbox(pool, id: id, status: status, sentAt: sentAt)

        let outcome = retryCountingPosts(id)

        #expect(outcome.accepted == false, "status \(status.rawValue) with sentAt set must be refused")
        #expect(outcome.posts == 0, "status \(status.rawValue): refused retry must not signal success")

        let after = try row(pool, id)
        #expect(after?.outboxStatus == status, "status \(status.rawValue) must be unchanged")
        #expect(after?.sentAt != nil, "status \(status.rawValue): the double-send firewall marker must survive")
        #expect(after?.retryCount == 3)
        #expect(after?.errorMessage == "previous failure")
        await settle()
    }

    @Test("An absent row returns false and posts nothing")
    func retryAbsentRowReturnsFalse() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restore(pool: pool, dir: dir, previous: previous) }
        // Fixture only; no row is seeded.

        let outcome = retryCountingPosts("ob-does-not-exist")

        #expect(outcome.accepted == false)
        #expect(outcome.posts == 0)
        await settle()
    }
}
