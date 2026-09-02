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
@Suite("Opening an oversized-quarantined message reports failure without a fetch")
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
            try header.insert(db)
        }

        let headerId = try pool.read { db in
            try MessageHeader.fetchOne(db, sql: "SELECT * FROM messageHeader WHERE messageId = '100'")!.id
        }

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
    @Test("Pull-to-refresh still performs a real fetch on a flagged message")
    @MainActor
    func pullToRefreshStillRetries() async throws {
        let probe = FetchProbe()
        let (vm, pool, dir) = try makeVM(oversized: true, probe: probe)
        defer { cleanup(pool, dir) }

        await vm.loadBody()
        #expect(probe.attempts == 0)

        await vm.refetchBody()

        #expect(probe.attempts == 1,
                "an explicit user retry must reach the wire — the parser bound is fragmentation-dependent, so the same message can succeed on a different connection")
    }
}
