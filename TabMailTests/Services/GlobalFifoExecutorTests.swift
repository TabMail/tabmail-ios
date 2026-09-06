/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// THE GLOBAL SINGLE-OPERATION FIFO EXECUTOR, end to end.
///
/// The v2→v3 port replaced v2final's one-owner FIFO drain with claim-all +
/// concurrent lane dispatch, and the order authority went with it: `createdAt`
/// is a wall clock, ties are unordered, and a deferral could not move a row
/// without deleting and reinserting it. This suite pins what replaced it — a
/// durable `queuePosition`, one owner that claims the live front row, and
/// related-chain tail movement — against REAL drains and REAL provider calls.
///
/// 🚨 NOTHING HERE SORTS BY `createdAt` OR SIMULATES A LANE. The spec says in as
/// many words that a helper which does either is not evidence of production FIFO
/// behaviour. Every ordering assertion below reads one of two things: the order
/// the PROVIDER was called in (`StatefulExchangeActionServer.mutationLog()` for
/// Graph, `MockEmailProvider.movedIds`/`markedReadIds` for the mock), or the
/// durable `queuePosition` column the executor itself claims by.
@Suite("Global FIFO executor — durable queuePosition, one-at-a-time drain, chain deferral",
       .serialized, .processGlobalState)
struct GlobalFifoExecutorTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    private static let source = "INBOX"
    private static let archive = "Archive"

    @MainActor
    private func fixture(
        accountId: String, provider: AccountProvider = .outlook, folders: [String] = []
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: accountId,
                provider: provider)
            account.id = accountId
            try account.insert(db)
            try Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: accountId
            ).insert(db)
            for path in folders {
                try Folder(name: path, path: path, role: .custom, accountId: accountId).insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    /// Restore the previously-installed database. **Deliberately SYNCHRONOUS.**
    ///
    /// 🚨 THIS MUST NOT BE `async` AND MUST NOT BE CALLED FROM A `Task {}` IN A
    /// `defer`. `AppDatabase.shared` is process-global: an `async` teardown
    /// parked in a detached task restores it whenever the scheduler gets round to
    /// it, which in a serialized suite is routinely AFTER the NEXT test installed
    /// its own database. That test then drains a pool holding none of its rows,
    /// nothing is claimed, and it fails with an empty wire — a failure that reads
    /// exactly like a scheduling regression and is not one. Observed here, in
    /// this file, on the first full-suite run.
    @MainActor
    private func finish(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    /// Admit an operation through the SAME typed route production uses, so the
    /// position it gets is the one `PendingOperation.willInsert(_:)` allocates.
    @discardableResult
    private func admit(
        _ fixture: Fixture, _ operation: PendingOperation
    ) throws -> PendingOperation {
        let toInsert = operation
        return try fixture.pool.writeWithoutTransaction { db in try toInsert.inserted(db) }
    }

    private func rowsByPosition(_ fixture: Fixture) throws -> [PendingOperation] {
        try fixture.pool.read { db in
            try PendingOperation.order(Column("queuePosition").asc).fetchAll(db)
        }
    }

    private func seedHeader(
        _ fixture: Fixture, messageId: String, folderPath: String = GlobalFifoExecutorTests.source
    ) throws {
        var header = MessageHeader(
            messageId: messageId,
            subject: "fifo \(messageId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "\(fixture.accountId)@example.com",
            date: Date(),
            snippet: "fifo body",
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: folderPath),
            accountId: fixture.accountId,
            folderPath: folderPath,
            isInInbox: folderPath == Self.source)
        header.rfc822MessageId = "\(messageId)@example.com"
        let seeded = header
        try fixture.pool.writeWithoutTransaction { db in try seeded.insert(db) }
    }

    /// A refusal that says NOTHING about the connection, so the account is not
    /// suppressed and the failure stays operation-local — which is what the
    /// spec's worked examples require (`A1` fails; `B1` and `C1` still proceed).
    private struct EvidenceRefused: ProviderEvidenceUnavailable {}

    // MARK: - 1. Admission order is the order authority, and a clock cannot move it

    /// **THE PROPERTY: admission order decides execution order, and neither equal
    /// timestamps nor a clock that steps BACKWARD can reorder it.**
    ///
    /// `createdAt` was the ordering key before this change, so two gestures in
    /// the same second were unordered and an NTP correction (or a user changing
    /// the device clock) could put a newer intention ahead of an older one. The
    /// durable position is allocated after the current maximum inside the
    /// admission transaction, so it cannot be affected by either.
    ///
    /// The oracle is the WIRE: `markedReadIds` in call order, not a re-sort of
    /// the rows.
    @Test("Admission order decides wire order — equal timestamps and a backward clock step do not reorder it")
    @MainActor
    func admissionOrderIsTheOrderAuthorityRegardlessOfTheClock() async throws {
        let f = try fixture(accountId: "fifo-clock", provider: .gmail)
        defer { finish(f) }

        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        // Deliberately adversarial: op 2 is a full hour OLDER than op 1, op 3
        // shares op 1's exact timestamp, op 4 is older still.
        let stamps = [now, now.addingTimeInterval(-3600), now, now.addingTimeInterval(-7200)]
        for (index, stamp) in stamps.enumerated() {
            try seedHeader(f, messageId: "c\(index)")
            var op = PendingOperation(
                type: .markRead, messageIds: ["c\(index)"], accountId: f.accountId,
                folderPath: Self.source)
            op.createdAt = stamp
            try admit(f, op)
        }

        let admitted = try rowsByPosition(f)
        #expect(admitted.map(\.queuePosition) == [1, 2, 3, 4], """
            positions must be allocated after the current maximum in admission \
            order, got \(admitted.map(\.queuePosition))
            """)
        // NON-VACUITY: the fixture really does contain the adversarial clock,
        // so a `createdAt` ordering would genuinely disagree with this one.
        let byClock = admitted.sorted { $0.createdAt < $1.createdAt }.map(\.messageIds)
        #expect(byClock != admitted.map(\.messageIds), """
            the fixture's timestamps are not adversarial — a createdAt sort \
            agrees with the position sort, so this test cannot tell them apart
            """)

        let provider = MockEmailProvider()
        await TestProviderRegistry.withRegisteredProvider(
            accountId: f.accountId, provider: provider
        ) {
            await AccountManager.shared.drainPendingQueue()
        }

        let wire = await provider.markedReadIds.map(\.ids)
        #expect(wire == [["c0"], ["c1"], ["c2"], ["c3"]], """
            the provider was called out of admission order: \(wire)
            """)
        #expect(try rowsByPosition(f).isEmpty, "every operation must have retired")
    }

    // MARK: - 2. §3(b) — an N-member operation settles in ONE continuous run

    /// **THE PROPERTY: an operation with N members well above 3 settles EVERY
    /// member inside ONE drain, one member per provider attempt, yielding to
    /// unrelated work between members.**
    ///
    /// 🚨 THIS IS THE THROUGHPUT REQUIREMENT, and it is the one the review train
    /// deferred into this change. Graph settles exactly ONE member per request
    /// (`ExchangeProvider.patchEachMessage`; re-batching to recover the rate is
    /// what `MIS-IOS-022` forbids, twice), and the previous drain answered a
    /// narrowing with a lane halt bounded by a three-pass cap — so an eight
    /// message gesture needed THREE separate drains, each waiting on a gesture, a
    /// reconnect or the five-minute poll. This test drives eight members through
    /// ONE `drainPendingQueue()` call with no other trigger and requires all
    /// eight to be settled when it returns.
    ///
    /// The bystander is the other half of the requirement, and it is what makes
    /// the assertion two-sided: the narrowed remainder is moved to the TAIL, so
    /// unrelated mail admitted behind an eight-member gesture must go out AFTER
    /// the first member and BEFORE the second, not after all eight. A design that
    /// kept the remainder at the head would settle all eight in one run and fail
    /// here; a design that marked the narrowing deferred would settle exactly ONE
    /// and fail the count.
    ///
    /// The oracle is the server's own arrival log — the real Graph wire, in the
    /// order the requests were served.
    @Test("An eight-member Graph operation settles every member in ONE drain, one per attempt, yielding to unrelated work after the first")
    @MainActor
    func eightMemberGraphOperationSettlesInOneContinuousRunAndYieldsToUnrelatedWork() async throws {
        let f = try fixture(accountId: "fifo-graph-throughput")
        let members = (1...8).map { "graph-member-\($0)" }
        let bystanderId = "graph-bystander"
        let server = StatefulExchangeActionServer(
            messages: (members + [bystanderId]).map {
                .init(rfc822MessageId: "\($0)@example.com", providerMessageId: $0,
                      folderId: Self.source)
            })
        defer {
            server.close()
            finish(f)
            // Safe as a detached task where the database restore was NOT:
            // `providers` is keyed by account id and every id in this file is
            // unique to its own test, so a late removal cannot reach another
            // test's registration.
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId) }
        }
        for id in members + [bystanderId] { try seedHeader(f, messageId: id) }

        // Position 1: the eight-member gesture. Position 2: an unrelated
        // single-message action admitted behind it.
        try admit(f, PendingOperation(
            type: .markRead, messageIds: members, accountId: f.accountId,
            folderPath: Self.source))
        try admit(f, PendingOperation(
            type: .markFlagged, messageIds: [bystanderId], accountId: f.accountId,
            folderPath: Self.source))

        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: server.provider())

        // EXACTLY ONE DRAIN. No redrive, no second trigger, no polling loop.
        await AccountManager.shared.drainPendingQueue()

        let leftover = try rowsByPosition(f)
        #expect(leftover.isEmpty, """
            the queue is not empty after ONE drain: \
            \(leftover.map { "\($0.queuePosition):\($0.messageIds)" }). \
            An N-member operation must settle every member in one continuous run.
            """)
        for id in members {
            #expect(server.snapshot(providerMessageId: id)?.isRead == true,
                    "member \(id) was never marked read on the server")
        }
        #expect(server.snapshot(providerMessageId: bystanderId)?.isFlagged == true,
                "the unrelated bystander never reached the provider")

        // THE WIRE ORDER, exactly: member 1, then the unrelated action it
        // yielded to, then the remaining seven members in order.
        let expected = ["PATCH \(members[0])", "PATCH \(bystanderId)"]
            + members.dropFirst().map { "PATCH \($0)" }
        #expect(server.mutationLog() == expected, """
            the executor did not settle one member per attempt while yielding to \
            unrelated work.
            expected: \(expected)
            observed: \(server.mutationLog())
            """)
    }

    // MARK: - 3. Related-chain tail movement — the spec's worked examples

    /// **THE PROPERTY (spec §3, first worked example): `A1, B1, A2, C1` with `A1`
    /// failing becomes `B1, C1, A1, A2` — `A2` cannot pass `A1`, and `B1`/`C1`
    /// keep their relative order and execute.**
    ///
    /// The failure is deliberately a `ProviderEvidenceUnavailable`, not a
    /// connection error: an account-wide connection failure legitimately
    /// suppresses `B1` and `C1` too, so it could not tell a working chain
    /// deferral from an account suppression.
    @Test("A1 fails: its chain moves to the tail in order, and the unrelated B1/C1 execute in this same drain")
    @MainActor
    func failedChainMovesToTheTailWhileUnrelatedWorkProceeds() async throws {
        let f = try fixture(accountId: "fifo-chain-abc", provider: .gmail,
                            folders: [Self.archive])
        defer { finish(f) }
        for id in ["A", "B", "C"] { try seedHeader(f, messageId: id) }

        let a1 = try admit(f, PendingOperation(
            type: .move, messageIds: ["A"], accountId: f.accountId,
            folderPath: Self.source, destinationPath: Self.archive))
        let b1 = try admit(f, PendingOperation(
            type: .move, messageIds: ["B"], accountId: f.accountId,
            folderPath: Self.source, destinationPath: Self.archive))
        let a2 = try admit(f, PendingOperation(
            type: .move, messageIds: ["A"], accountId: f.accountId,
            folderPath: Self.archive, destinationPath: Self.source))
        let c1 = try admit(f, PendingOperation(
            type: .move, messageIds: ["C"], accountId: f.accountId,
            folderPath: Self.source, destinationPath: Self.archive))
        #expect([a1, b1, a2, c1].map(\.queuePosition) == [1, 2, 3, 4])

        // The DURABLE ages, read back through the same encoder the drain will
        // read them with. Comparing the post-drain rows against the in-memory
        // structs instead would compare a `Date` that never round-tripped
        // through SQLite's sub-second-truncating representation, and would fail
        // for a reason that has nothing to do with tail movement.
        let admittedAges: [String: Date] = try rowsByPosition(f)
            .reduce(into: [:]) { $0[$1.id] = $1.createdAt }

        let provider = MockEmailProvider()
        await provider.setMoveThrowsOnId("A", error: EvidenceRefused())
        await TestProviderRegistry.withRegisteredProvider(
            accountId: f.accountId, provider: provider
        ) {
            await AccountManager.shared.drainPendingQueue()
        }

        // THE WIRE: B and C went out, in their own relative order, and A was
        // attempted exactly ONCE.
        let wire = await provider.callLog.filter { $0.hasPrefix("move(ids:") }
        #expect(wire == [
            "move(ids:[\"A\"],from:INBOX,to:Archive)",
            "move(ids:[\"B\"],from:INBOX,to:Archive)",
            "move(ids:[\"C\"],from:INBOX,to:Archive)",
        ], "unrelated mail did not proceed past the failed chain, or A was retried: \(wire)")

        // THE DURABLE QUEUE: only the A chain survives, A1 still ahead of A2.
        let survivors = try rowsByPosition(f)
        #expect(survivors.map(\.id) == [a1.id, a2.id], """
            expected the A chain alone, A1 before A2. Got \
            \(survivors.map { "\($0.queuePosition):\($0.folderPath)→\($0.destinationPath ?? "-")" })
            """)
        guard survivors.count == 2 else { return }
        #expect(survivors[0].queuePosition > c1.queuePosition, """
            the failed chain was not moved BEHIND the unrelated work it yielded \
            to: A1 sits at \(survivors[0].queuePosition), C1 was at \(c1.queuePosition)
            """)
        #expect(survivors[0].status == PendingStatus.queued.rawValue)
        #expect(survivors[1].status == PendingStatus.queued.rawValue)
        #expect(survivors[0].retryCount == 1, "the attempted row is charged exactly one retry")
        #expect(survivors[1].retryCount == 0,
                "a follower deferred WITHOUT a provider attempt consumes no retry")
        #expect(survivors[0].everAttempted, "A1 was claimed and attempted")
        #expect(!survivors[1].everAttempted,
                "A2 was never claimed, so it must not carry the attempted-row proof")
        // Identity, payload and age are untouched by tail movement — `createdAt`
        // is age-only now, and nothing in the deferral may rewrite it.
        #expect(survivors[0].createdAt == admittedAges[a1.id], """
            tail movement rewrote A1's age: \(survivors[0].createdAt) was \
            \(admittedAges[a1.id].map(String.init(describing:)) ?? "<absent>")
            """)
        #expect(survivors[1].createdAt == admittedAges[a2.id], """
            tail movement rewrote A2's age: \(survivors[1].createdAt) was \
            \(admittedAges[a2.id].map(String.init(describing:)) ?? "<absent>")
            """)
        #expect(survivors.map(\.messageIds) == [["A"], ["A"]],
                "tail movement rewrote the chain's payload: \(survivors.map(\.messageIds))")
    }

    /// **THE PROPERTY (spec §3, second worked example): a BATCH connects the
    /// pending work of every member it names. `A1, X1, action(A+B), B2, Y1` with
    /// `A1` failing becomes `X1, Y1, A1, action(A+B), B2`.**
    ///
    /// The batch is what makes `B2` — which never mentions `A` — part of `A`'s
    /// chain. A per-message deferral would leave `B2` ahead of the batch that
    /// owns it and race them on the wire.
    @Test("A batch connects its members' chains: A1's failure defers action(A+B) and B2 too, while X1 and Y1 proceed")
    @MainActor
    func batchMembershipConnectsTwoChainsForDeferral() async throws {
        let f = try fixture(accountId: "fifo-chain-batch", provider: .gmail,
                            folders: [Self.archive])
        defer { finish(f) }
        for id in ["A", "B", "X", "Y"] { try seedHeader(f, messageId: id) }

        func move(_ ids: [String]) -> PendingOperation {
            PendingOperation(
                type: .move, messageIds: ids, accountId: f.accountId,
                folderPath: Self.source, destinationPath: Self.archive)
        }
        let a1 = try admit(f, move(["A"]))
        let x1 = try admit(f, move(["X"]))
        let batch = try admit(f, move(["A", "B"]))
        let b2 = try admit(f, move(["B"]))
        let y1 = try admit(f, move(["Y"]))
        #expect([a1, x1, batch, b2, y1].map(\.queuePosition) == [1, 2, 3, 4, 5])

        let provider = MockEmailProvider()
        await provider.setMoveThrowsOnId("A", error: EvidenceRefused())
        await TestProviderRegistry.withRegisteredProvider(
            accountId: f.accountId, provider: provider
        ) {
            await AccountManager.shared.drainPendingQueue()
        }

        let landed = await provider.movedIds.map(\.ids)
        #expect(landed == [["X"], ["Y"]], """
            only the unrelated singletons may land; B2 shares the batch's chain \
            and the batch shares A's. Got \(landed)
            """)
        let survivors = try rowsByPosition(f)
        #expect(survivors.map(\.messageIds) == [["A"], ["A", "B"], ["B"]], """
            the deferred chain must keep its relative order at the tail, got \
            \(survivors.map { "\($0.queuePosition):\($0.messageIds)" })
            """)
    }

    // MARK: - 4. One attempt per drain, and convergence when the fault clears

    /// **THE PROPERTY: a persistently failing operation is attempted EXACTLY ONCE
    /// per drain — never a hot loop — and when the fault clears the deferred
    /// chain completes in its original order.**
    ///
    /// The executor has no passes-per-drain cap, so without the deferred set it
    /// would walk the queue, meet the failed row again at the tail, and retry it
    /// at wire speed for as long as the app is running. Three drains, three
    /// attempts, is the assertion that says the spin guard is live.
    @Test("A persistent failure gets exactly one attempt per drain, and the chain converges in order once it clears")
    @MainActor
    func persistentFailureGetsOneAttemptPerDrainThenConvergesInOrder() async throws {
        let f = try fixture(accountId: "fifo-one-attempt", provider: .gmail,
                            folders: [Self.archive])
        defer { finish(f) }
        for id in ["P", "Q"] { try seedHeader(f, messageId: id) }

        let first = try admit(f, PendingOperation(
            type: .move, messageIds: ["P"], accountId: f.accountId,
            folderPath: Self.source, destinationPath: Self.archive))
        let second = try admit(f, PendingOperation(
            type: .move, messageIds: ["P"], accountId: f.accountId,
            folderPath: Self.archive, destinationPath: Self.source))
        let unrelated = try admit(f, PendingOperation(
            type: .move, messageIds: ["Q"], accountId: f.accountId,
            folderPath: Self.source, destinationPath: Self.archive))
        _ = unrelated

        let provider = MockEmailProvider()
        await provider.setMoveThrowsOnId("P", error: EvidenceRefused())
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: f.accountId, provider: provider
        ) {
            for _ in 0..<3 { await AccountManager.shared.drainPendingQueue() }

            let attempts = await provider.callLog.filter { $0.contains("[\"P\"]") }
            #expect(attempts.count == 3, """
                three drains must produce exactly three attempts on the failing \
                operation — more is a hot loop, fewer is a wedge. Got \
                \(attempts.count): \(attempts)
                """)
            let held = try rowsByPosition(f)
            #expect(held.map(\.id) == [first.id, second.id],
                    "the unrelated Q move must have retired; the P chain must be held in order")
            #expect(held.first?.retryCount == 3,
                    "one retry charged per attempt: \(held.first?.retryCount ?? -1)")
            #expect(held.last?.retryCount == 0,
                    "the never-attempted follower is charged nothing")

            // THE FAULT CLEARS.
            await provider.clearMoveThrowsOnId()
            await AccountManager.shared.drainPendingQueue()
        }

        #expect(try rowsByPosition(f).isEmpty, "the chain must converge once the fault clears")
        let landedP = await provider.movedIds.filter { $0.ids == ["P"] }.map { "\($0.from)→\($0.to)" }
        #expect(landedP == ["INBOX→Archive", "Archive→INBOX"], """
            the deferred chain must execute in its ORIGINAL order once it clears, \
            got \(landedP)
            """)
    }

    // MARK: - 5. Unclaimable frontiers never block unrelated work

    /// **THE PROPERTY: a frontier that cannot be claimed — no registered
    /// provider, a source folder mid-UIDVALIDITY reset, or checkpoint A without
    /// address/epoch evidence — defers its own chain WITHOUT an attempt and lets
    /// unrelated work through, and the skipped rows keep `queued`, their
    /// `everAttempted` and their `retryCount`.**
    ///
    /// This is v2final's global-stop branch replaced by a per-chain deferral: the
    /// old shape let one not-yet-connected account hold every other account's
    /// mail.
    @Test("An unclaimable frontier defers its own chain without an attempt and never blocks unrelated work")
    @MainActor
    func unclaimableFrontiersDeferWithoutAnAttemptAndDoNotBlockOthers() async throws {
        let f = try fixture(accountId: "fifo-unclaimable", provider: .imap,
                            folders: [Self.archive, "Resetting"])
        defer { finish(f) }

        // A second account with NO registered provider — the "no provider entry"
        // frontier, and it is admitted FIRST so it sits at the head.
        let orphanAccount = "fifo-unclaimable-orphan"
        try await f.pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(orphanAccount)@example.com", displayName: orphanAccount,
                provider: .gmail)
            account.id = orphanAccount
            try account.insert(db)
            try Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: orphanAccount
            ).insert(db)
            // The folder that is mid-reset.
            var resetting = try Folder.fetchOne(
                db, key: MessageIdentity.folderId(
                    accountId: "fifo-unclaimable", folderPath: "Resetting"))!
            resetting.uidValidityResetPendingAt = Date()
            resetting.lastKnownUidValidity = 7
            try resetting.update(db)
            // The source folder has a KNOWN epoch, so checkpoint A can be
            // satisfied by the healthy op and refused by the unstamped one.
            var inbox = try Folder.fetchOne(
                db, key: MessageIdentity.folderId(
                    accountId: "fifo-unclaimable", folderPath: Self.source))!
            inbox.lastKnownUidValidity = 42
            try inbox.update(db)
        }
        for id in ["11", "12", "13"] { try seedHeader(f, messageId: id) }

        // 1) no provider/work queue for its account
        let orphan = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["orphan-1"], accountId: orphanAccount,
            folderPath: Self.source))
        // 2) source folder mid UIDVALIDITY reset
        let midReset = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["12"], accountId: f.accountId,
            folderPath: "Resetting", observedUidValidity: 7))
        // 3) checkpoint A with no epoch evidence (IMAP op, no observedUidValidity)
        let noEvidence = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["13"], accountId: f.accountId,
            folderPath: Self.source))
        // 3b) 🚨 A FOLLOWER OF (3) THAT IS CLAIMABLE ON ITS OWN. It names the same
        // message and carries the epoch the folder actually has, so nothing about
        // THIS row is unclaimable — it may run only because its predecessor is
        // deferred, and it must not. This is what makes the deferral's SCOPE
        // observable: a skip that parks one row instead of its whole connected
        // chain lets the user's LATER gesture on message 13 overtake the earlier
        // one it must follow, which is the ordering violation the executor
        // exists to prevent. Without this row every frontier here is a
        // single-message chain and "chain" and "row" cannot be told apart.
        let unresolvedFollower = try admit(f, PendingOperation(
            type: .markUnread, messageIds: ["13"], accountId: f.accountId,
            folderPath: Self.source, observedUidValidity: 42))
        // 4) the healthy one, LAST, so it can only run if the four above yielded
        let healthy = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["11"], accountId: f.accountId,
            folderPath: Self.source, observedUidValidity: 42))

        let provider = MockEmailProvider()
        await TestProviderRegistry.withRegisteredProvider(
            accountId: f.accountId, provider: provider
        ) {
            await AccountManager.shared.drainPendingQueue()
        }

        let wire = await provider.markedReadIds.map(\.ids)
        #expect(wire == [["11"]], """
            the healthy operation behind four unclaimable frontiers did not \
            execute, or an unclaimable one did: \(wire)
            """)
        _ = healthy
        let unreadWire = await provider.markedUnreadIds.map(\.ids)
        #expect(unreadWire.isEmpty, """
            the follower of an unclaimable frontier executed — the skip parked \
            one ROW instead of its whole related chain, so the user's LATER \
            gesture on message 13 overtook the earlier one: \(unreadWire)
            """)

        let survivors = try rowsByPosition(f)
        #expect(Set(survivors.map(\.id))
                    == [orphan.id, midReset.id, noEvidence.id, unresolvedFollower.id], """
            an unclaimable frontier and everything deferred with it must be \
            PARKED, never dropped: \(survivors.map(\.id))
            """)
        for row in survivors {
            #expect(row.status == PendingStatus.queued.rawValue,
                    "\(row.id.prefix(8)) must stay queued, got \(row.status)")
            #expect(!row.everAttempted,
                    "\(row.id.prefix(8)) was never attempted, so the attempted-row proof must be absent")
            #expect(row.retryCount == 0,
                    "\(row.id.prefix(8)) was deferred without an attempt and must be charged nothing")
        }
        // Positions are UNCHANGED: an in-memory skip is not a tail movement.
        #expect(survivors.map(\.queuePosition) == [1, 2, 3, 4], """
            a no-attempt skip must not rewrite positions — the user's gestures \
            stay where they were put: \(survivors.map(\.queuePosition))
            """)
    }

    // MARK: - 6. Cross-account isolation and folder-qualified IMAP UIDs

    /// **THE PROPERTY: equal numeric UIDs in different folders, and equal ids in
    /// different accounts, are DIFFERENT targets — a failure on one never defers
    /// the other.**
    ///
    /// This is `IOS-QUEUE-001`'s wedge-with-a-bystander in the deferral world: on
    /// IMAP a UID is mailbox-local, so `(INBOX, 77)` and `(Archive, 77)` are
    /// unrelated messages and must be in different chains.
    @Test("Identical IMAP UIDs in different folders, and identical ids in different accounts, are separate chains")
    @MainActor
    func identicalUidsInDifferentFoldersAndAccountsAreSeparateChains() async throws {
        let f = try fixture(accountId: "fifo-uid-split", provider: .imap,
                            folders: [Self.archive])
        defer { finish(f) }
        let otherAccount = "fifo-uid-split-other"
        try await f.pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(otherAccount)@example.com", displayName: otherAccount,
                provider: .imap)
            account.id = otherAccount
            try account.insert(db)
            try Folder(
                name: Self.source, path: Self.source, role: .inbox, accountId: otherAccount
            ).insert(db)
            for id in [
                MessageIdentity.folderId(accountId: "fifo-uid-split", folderPath: Self.source),
                MessageIdentity.folderId(accountId: "fifo-uid-split", folderPath: Self.archive),
                MessageIdentity.folderId(accountId: otherAccount, folderPath: Self.source),
            ] {
                var folder = try Folder.fetchOne(db, key: id)!
                folder.lastKnownUidValidity = 42
                try folder.update(db)
            }
        }

        // Same numeric id 77 in three different address spaces.
        let inboxSeventySeven = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["77"], accountId: f.accountId,
            folderPath: Self.source, observedUidValidity: 42))
        let archiveSeventySeven = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["77"], accountId: f.accountId,
            folderPath: Self.archive, observedUidValidity: 42))
        let otherAccountSeventySeven = try admit(f, PendingOperation(
            type: .markRead, messageIds: ["77"], accountId: otherAccount,
            folderPath: Self.source, observedUidValidity: 42))

        let providerA = MockEmailProvider()
        let providerB = MockEmailProvider()
        await providerA.setMarkReadHook { }
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: providerA)
        await AccountManager.shared.registerProviderForTesting(
            accountId: otherAccount, provider: providerB)
        // Same reasoning as the eight-member test's defer: unique account ids
        // make a late provider removal harmless, unlike the database restore.
        defer {
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: otherAccount) }
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId) }
        }

        // Fail every markRead on account A's provider with an operation-local
        // refusal, so ONLY the first row's own chain may be deferred.
        await providerA.setMarkReadThrows(EvidenceRefused())
        await AccountManager.shared.drainPendingQueue()

        let survivors = try rowsByPosition(f)
        // The INBOX/77 row failed; the Archive/77 row is a DIFFERENT target so it
        // must also have been attempted (and failed on the same provider); the
        // other account's row must have executed.
        #expect(survivors.map(\.id).contains(inboxSeventySeven.id))
        #expect(survivors.map(\.id).contains(archiveSeventySeven.id))
        #expect(!survivors.map(\.id).contains(otherAccountSeventySeven.id), """
            an unrelated ACCOUNT's operation was held by a failure on another \
            account: \(survivors.map(\.accountId))
            """)
        let attemptedFolders = survivors.filter { $0.everAttempted }.map(\.folderPath).sorted()
        #expect(attemptedFolders == [Self.archive, Self.source], """
            both folder-qualified 77s must be attempted independently — a merged \
            chain would leave one of them unattempted. Got \(attemptedFolders)
            """)
        let otherWire = await providerB.markedReadIds.map(\.ids)
        #expect(otherWire == [["77"]], "the other account's identical UID never executed")
    }

    // MARK: - 7. The durable column itself

    /// **THE PROPERTY: the EFFECTIVE schema — the one a migrated database
    /// actually has — requires a populated, positive position on every row, and
    /// there is no ranking migration to fall back on.**
    ///
    /// `MIS-IOS-007`: read the schema a real database ends up with, never the
    /// first `CREATE TABLE` in the file. So this inspects `PRAGMA table_info`
    /// and then proves the constraint by trying to violate it.
    @Test("The effective pendingOperation schema requires a populated, positive queuePosition and indexes it")
    @MainActor
    func effectiveSchemaEnforcesAPopulatedPosition() async throws {
        let f = try fixture(accountId: "fifo-schema", provider: .gmail)
        defer { finish(f) }

        let column = try f.pool.read { db -> Row? in
            try Row.fetchOne(
                db, sql: "SELECT * FROM pragma_table_info('pendingOperation') WHERE name = 'queuePosition'")
        }
        #expect(column != nil, "the effective schema has no queuePosition column")
        guard let column else { return }
        #expect(column["notnull"] as Int? == 1, "queuePosition must be NOT NULL")
        #expect(column["dflt_value"] as String? == nil,
                "queuePosition must have NO default — a zero default is exactly the silent admission the spec forbids")

        let indexed = try await f.pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'pendingOperation'")
        }
        #expect(indexed.contains("pendingOperation_queuePosition"),
                "the frontier walk orders by queuePosition and must be index-backed: \(indexed)")

        // A writer that omits the column FAILS rather than admitting at zero.
        var omitted = false
        do {
            try await f.pool.writeWithoutTransaction { db in
                try db.execute(sql: """
                    INSERT INTO pendingOperation
                        (id, type, messageIdsJSON, accountId, folderPath, createdAt, status, retryCount)
                    VALUES ('omitted', 'markRead', '["m"]', ?, 'INBOX', ?, 'queued', 0)
                    """, arguments: [f.accountId, Date()])
            }
        } catch {
            omitted = true
        }
        #expect(omitted, "a writer that omits queuePosition must fail verification, not admit silently")

        // And a zero is refused by the CHECK, so the unallocated sentinel can
        // never reach the table.
        var zeroed = false
        do {
            try await f.pool.writeWithoutTransaction { db in
                try db.execute(sql: """
                    INSERT INTO pendingOperation
                        (id, type, messageIdsJSON, accountId, folderPath, createdAt, status,
                         retryCount, queuePosition)
                    VALUES ('zeroed', 'markRead', '["m"]', ?, 'INBOX', ?, 'queued', 0, ?)
                    """, arguments: [
                        f.accountId, Date(), PendingOperation.unallocatedQueuePosition])
            }
        } catch {
            zeroed = true
        }
        #expect(zeroed, "the unallocated sentinel must be refused by the schema")
    }

    /// **THE PROPERTY: status-only recovery keeps the row's position.**
    ///
    /// A crash leaves rows `inFlight`; launch recovery returns them to `queued`.
    /// That is a status change, not a re-admission, and a recovery that
    /// reallocated the position would silently reorder every intention a crash
    /// touched.
    @Test("Crash recovery returns an inFlight row to queued WITHOUT moving its position")
    @MainActor
    func statusOnlyRecoveryRetainsPosition() async throws {
        let f = try fixture(accountId: "fifo-recovery", provider: .gmail)
        defer { finish(f) }

        try admit(f, PendingOperation(
            type: .markRead, messageIds: ["r1"], accountId: f.accountId, folderPath: Self.source))
        var stranded = PendingOperation(
            type: .markRead, messageIds: ["r2"], accountId: f.accountId, folderPath: Self.source)
        stranded.status = PendingStatus.inFlight.rawValue
        let strandedRow = try admit(f, stranded)
        try admit(f, PendingOperation(
            type: .markRead, messageIds: ["r3"], accountId: f.accountId, folderPath: Self.source))
        #expect(strandedRow.queuePosition == 2)

        // THE NEXT LAUNCH — real `AppDatabase.init`, real recovery.
        _ = try AppDatabase(dbPool: f.pool)

        let after = try rowsByPosition(f)
        #expect(after.map(\.messageIds) == [["r1"], ["r2"], ["r3"]],
                "recovery reordered the queue: \(after.map { "\($0.queuePosition):\($0.messageIds)" })")
        #expect(after[1].status == PendingStatus.queued.rawValue,
                "the stranded row must be returned to queued")
        #expect(after[1].queuePosition == 2,
                "recovery must retain the position, got \(after[1].queuePosition)")
    }

    // MARK: - 8. Cost on a realistic queue

    /// **THE PROPERTY: the frontier walk and the deferral transaction stay cheap
    /// on a realistic backlog — a long offline queue must not turn the drain into
    /// a quadratic stall.**
    ///
    /// The shape that would: recomputing the connected components once per
    /// deferral instead of once per claim transaction. With 400 rows all naming
    /// distinct messages and every one of them refused, that is 400 union-find
    /// passes over 400 rows. The bound is deliberately generous — this is a
    /// blow-up detector, not a benchmark.
    @Test("A 400-row backlog in which every operation is refused drains once through without a quadratic stall")
    @MainActor
    func deferralCostStaysLinearOnARealisticBacklog() async throws {
        let f = try fixture(accountId: "fifo-cost", provider: .gmail, folders: [Self.archive])
        defer { finish(f) }

        try await f.pool.writeWithoutTransaction { db in
            for index in 0..<400 {
                var op = PendingOperation(
                    type: .move, messageIds: ["cost-\(index)"], accountId: f.accountId,
                    folderPath: Self.source, destinationPath: Self.archive)
                try op.insert(db)
            }
        }
        let admitted = try rowsByPosition(f)
        #expect(admitted.count == 400)
        #expect(admitted.map(\.queuePosition) == Array(1...400),
                "a bulk admission must produce a contiguous increasing range")

        let provider = MockEmailProvider()
        await provider.setMoveThrows(EvidenceRefused())
        let started = Date()
        await TestProviderRegistry.withRegisteredProvider(
            accountId: f.accountId, provider: provider
        ) {
            await AccountManager.shared.drainPendingQueue()
        }
        let elapsed = Date().timeIntervalSince(started)

        let attempts = await provider.callLog.filter { $0.hasPrefix("move(ids:") }.count
        #expect(attempts == 400, """
            every unrelated operation must get its one attempt in this drain — \
            got \(attempts). Fewer means the deferral is over-grouping unrelated \
            work; more means the spin guard is not holding.
            """)
        #expect(elapsed < 60, """
            400 refused operations took \(String(format: "%.1f", elapsed))s to \
            drain once. That is the shape of a per-deferral component \
            recomputation over the whole queue.
            """)
        #expect(try rowsByPosition(f).count == 400, "nothing may be dropped")
    }
}
