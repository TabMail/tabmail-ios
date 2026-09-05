/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Invariant tests for the drain's core — the lane key, checkpoint A's
/// draft/reset arm, the narrowing pass, and the publication of a committed
/// re-key into the stores that live outside GRDB.
///
/// Every test here asserts a SYSTEM PROPERTY the corresponding defect violated
/// — which intentions still execute, which durable rows survive, which address
/// a row ends up carrying, and whether an index entry can outlive its header —
/// never the mechanism that produces it.
///
/// Rows closed: `IOS-QUEUE-001`, `IOS-QUEUE-002`, `IOS-QUEUE-005`,
/// `IOS-UNDO-002`, `IOS-SEARCH-002`.
@Suite("Queue core invariants (lane key, checkpoint A, narrowing, re-key publication)",
       .serialized, .processGlobalState)
struct QueueCoreInvariantTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    /// Folders are `(path, role, lastKnownUidValidity)`.
    private func fixture(
        accountId: String,
        provider: AccountProvider = .imap,
        folders: [(String, FolderRole, Int?)] = [
            ("INBOX", .inbox, 42), ("Archive", .archive, 42), ("Trash", .trash, 42),
        ]
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
                emailAddress: "queue-core@example.com", displayName: "Queue core",
                provider: provider)
            account.id = accountId
            try account.insert(db)
            for (path, role, epoch) in folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                folder.lastKnownUidValidity = epoch
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    /// Mirrors `AccountManagerQueueDrainTests`' teardown: the drain paths driven
    /// here fire unstructured background Tasks that can outlive the test body,
    /// so no earlier boundary can safely close the pool.
    ///
    /// It no longer unregisters the provider. It used to, through a bare
    /// un-awaited `Task { … }` — an actor job merely ENQUEUED when this
    /// synchronous helper returned, so the registry could still hold this
    /// fixture's provider when the next suite started (`IOS-TEST-008`). Every
    /// test here that registers one now scopes it through
    /// `TestProviderRegistry.withRegisteredProvider`, which awaits the
    /// unregister on both exits before the test body ends.
    private func finish(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    /// Whole-second so the GRDB date round trip compares exactly, and derived
    /// from `Date()` so it can never go stale (repo rule: no hardcoded dates).
    private func baseTimestamp() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() - 3600)
    }

    private func insertOp(_ op: PendingOperation, _ fixture: Fixture) throws {
        try fixture.pool.writeWithoutTransaction { db in try op.insert(db) }
    }

    private func fetchOp(_ id: String, _ fixture: Fixture) throws -> PendingOperation? {
        try fixture.pool.read { db in try PendingOperation.fetchOne(db, key: id) }
    }

    /// A local header seeded at `folderPath` with `messageId`, carrying `epoch`.
    /// `headerFolderPath` overrides the folder the row's PRIMARY KEY is derived
    /// from, which is how an optimistically-moved row looks: shown in the
    /// destination, still keyed by its source address.
    @discardableResult
    private func seedHeader(
        _ fixture: Fixture,
        messageId: String,
        folderPath: String,
        keyedFromFolderPath: String? = nil,
        epoch: Int? = 42
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "queue core \(messageId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "queue-core@example.com",
            date: Date(),
            snippet: "queue core body",
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: folderPath),
            accountId: fixture.accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX")
        header.id = MessageIdentity.headerId(
            accountId: fixture.accountId,
            folderPath: keyedFromFolderPath ?? folderPath,
            messageId: messageId)
        header.observedUidValidity = epoch
        let seeded = header
        try fixture.pool.writeWithoutTransaction { db in try seeded.insert(db) }
        return seeded
    }

    /// A provider refusal that could not obtain the proof its own safety gate
    /// requires. Conforms to the SAME protocol `IMAPProvider`'s three private
    /// refusal enums do, so `executeSingleOp` routes it down the per-op
    /// `evidenceRefused` arm — the arm that halts a lane WITHOUT poisoning the
    /// account, and therefore the arm that makes a permanently-refusing op a
    /// permanent lane halt rather than a whole-account stop.
    private enum TestEvidenceUnavailable: ProviderEvidenceUnavailable {
        case noProofFromServer
    }

    // MARK: - IOS-QUEUE-001 — the folder is part of the address
    //
    // On IMAP a UID is mailbox-local, so UID 77 in INBOX and UID 77 in Archive
    // are DIFFERENT PHYSICAL MESSAGES. The lane key used to be
    // "accountId:messageId", which put them in ONE lane. A permanently
    // evidence-refused op therefore halted its lane forever AND took an
    // unrelated message in another folder down with it — an intention that is
    // never dropped but can never execute either, which the never-drop rule's
    // wedge corollary counts as loss. No UI lists PendingOperation rows, so the
    // bystander's owner could neither see nor clear it.
    //
    // RED PROOF (recorded): with the lane key reverted to
    // `"\(op.accountId):\($0)"` / `find("\(op.accountId):\(firstId)")`,
    // `laneHaltInOneFolderDoesNotStarveTheSameUidInAnother` fails — the
    // bystander's `markRead` never reaches the provider and its durable row is
    // still queued after the drain.

    // A3.1: parameterized over BOTH mailbox-local providers. The lane key is
    // folder-qualified for every account ABSENT from
    // `AccountManager.accountScopedIdAccountIds` (which admits `.gmail`,
    // `.outlook` and the demo account), so `.imap` and `.icloud` must classify
    // identically here — an iCloud UID is just as mailbox-local as an IMAP one.
    // A mutation that
    // admitted `.icloud` into the account-qualified set would be invisible to an
    // `.imap`-only fixture, because `.imap` alone still exercises the "folder is
    // part of the address" branch of `buildLanes` and this test would stay green.
    // The exact-set oracle for the classifier itself lives in
    // `AccountManagerQueueDrainTests.accountScopedIdAccountIdsAdmitsExactlyGmailOutlookAndTheDemoAccount`.
    @Test("a permanently evidence-refused op on (INBOX, 77) does not starve an unrelated message at (Archive, 77)",
          arguments: [AccountProvider.imap, .icloud])
    func laneHaltInOneFolderDoesNotStarveTheSameUidInAnother(accountProvider: AccountProvider) async throws {
        let fixture = try fixture(
            accountId: "acc-queue-001-bystander-\(accountProvider.rawValue)", provider: accountProvider)
        defer { finish(fixture) }

        let provider = MockEmailProvider()
        // Only the move refuses. The bystander's markRead is untouched.
        await provider.setMoveThrows(TestEvidenceUnavailable.noProofFromServer)
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: fixture.accountId, provider: provider
        ) {

            let t0 = baseTimestamp()
            var wedged = PendingOperation(
                type: .move, messageIds: ["77"], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
            wedged.createdAt = t0
            // The BYSTANDER: same UID number, different mailbox, therefore a
            // different physical message that shares nothing with the op above.
            var bystander = PendingOperation(
                type: .markRead, messageIds: ["77"], accountId: fixture.accountId,
                folderPath: "Archive", observedUidValidity: 42)
            bystander.createdAt = t0.addingTimeInterval(1)
            try insertOp(wedged, fixture)
            try insertOp(bystander, fixture)

            await AccountManager.shared.drainPendingQueue()

            // THE PROPERTY: the bystander's intention executed.
            let reads = await provider.markedReadIds
            #expect(
                reads.contains { $0.ids == ["77"] && $0.folder == "Archive" },
                """
                a message in Archive was starved by an unrelated op wedged on the same UID number in \
                INBOX — the two are different physical messages and share no lane: \(reads)
                """)
            #expect(try fetchOp(bystander.id, fixture) == nil, "the bystander's op retired on success")

            // NON-VACUITY, and the never-drop half: the refused op is preserved,
            // not dropped, and not executed.
            let refused = try fetchOp(wedged.id, fixture)
            #expect(refused != nil, "an evidence refusal is an absence of evidence — never an exit")
            #expect(refused?.status == PendingStatus.queued.rawValue)
        }
    }

    @Test("two ops on the SAME (account, folder, UID) still serialize — the lane split is per address, not per op")
    func sameFolderAndUidStillShareOneLane() async throws {
        let fixture = try fixture(accountId: "acc-queue-001-control")
        defer { finish(fixture) }

        let provider = MockEmailProvider()
        await provider.setMoveThrows(TestEvidenceUnavailable.noProofFromServer)
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: fixture.accountId, provider: provider
        ) {

            let t0 = baseTimestamp()
            var wedged = PendingOperation(
                type: .move, messageIds: ["77"], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
            wedged.createdAt = t0
            // Same account, same folder, same UID — the SAME physical message.
            var successor = PendingOperation(
                type: .markRead, messageIds: ["77"], accountId: fixture.accountId,
                folderPath: "INBOX", observedUidValidity: 42)
            successor.createdAt = t0.addingTimeInterval(1)
            try insertOp(wedged, fixture)
            try insertOp(successor, fixture)

            await AccountManager.shared.drainPendingQueue()

            // THE CONTROL for the test above: adding the folder to the key must not
            // de-serialize two gestures on ONE message. A later op sharing an
            // address with an unresolved predecessor must never run ahead of it.
            let reads = await provider.markedReadIds
            #expect(
                reads.isEmpty,
                "a later op on the SAME address ran ahead of its unresolved predecessor: \(reads)")
            let successorAfter = try fetchOp(successor.id, fixture)
            #expect(successorAfter != nil, "held, not dropped")
            #expect(successorAfter?.status == PendingStatus.queued.rawValue)
        }
    }

    // MARK: - IOS-QUEUE-002 — checkpoint A's draft/reset arm
    //
    // The arm compared two epochs on BARE INEQUALITY, so a zero on either side
    // read as a POSITIVE disagreement and took the DELETE direction. Zero is
    // what SwiftMail yields when a server omits the REQUIRED
    // `* OK [UIDVALIDITY n]` (`Mailbox.Selection.uidValidity` defaults to
    // `UIDValidity(0)`), i.e. it means "we were told nothing" — an absence of
    // evidence, which is never one of the four exits.
    //
    // The op is held in its lane by an unresolved predecessor so its DURABLE
    // row is observable after the drain; without that the mock retires every
    // op it can execute and the two outcomes are indistinguishable.
    //
    // RED PROOF (recorded): with the arm reverted to
    // `else if let stamped = fetched.observedUidValidity, let live =
    // sourceFolder?.lastKnownUidValidity, live != stamped`,
    // `checkpointAKeepsAnOpWhoseEpochIsZero` fails at `after != nil` — the row
    // is gone, deleted before any provider I/O.

    @Test("checkpoint A does not retire an op whose recorded epoch is zero — zero is unknown, not a mismatch")
    func checkpointAKeepsAnOpWhoseEpochIsZero() async throws {
        let fixture = try fixture(
            accountId: "acc-queue-002-zero", provider: .gmail,
            folders: [("Drafts", .drafts, 5)])
        defer { finish(fixture) }

        let provider = MockEmailProvider()
        // The predecessor fails transiently, so the lane halts and the op under
        // test is requeued instead of being executed and retired.
        await provider.setMarkReadThrows(ProviderError.notConnected)
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: fixture.accountId, provider: provider
        ) {

            let t0 = baseTimestamp()
            var predecessor = PendingOperation(
                type: .markRead, messageIds: ["draft-1"], accountId: fixture.accountId,
                folderPath: "Drafts")
            predecessor.createdAt = t0
            // `.setTag` is outside checkpoint A's provider-address set, so it is
            // judged by the draft/reset arm under test.
            var subject = PendingOperation(
                type: .setTag, messageIds: ["draft-1"], accountId: fixture.accountId,
                folderPath: "Drafts", tagValue: "archive", observedUidValidity: 0)
            subject.createdAt = t0.addingTimeInterval(1)
            try insertOp(predecessor, fixture)
            try insertOp(subject, fixture)

            await AccountManager.shared.drainPendingQueue()

            let after = try fetchOp(subject.id, fixture)
            #expect(
                after != nil,
                "a zero epoch is an ABSENCE of evidence — retiring on it drops a user intention on an unknown")
            #expect(after?.status == PendingStatus.queued.rawValue)
        }
    }

    @Test("checkpoint A still retires an op whose source folder PROVABLY turned over — exit 4 is unchanged")
    func checkpointAStillRetiresOnAProvenTurnover() async throws {
        let fixture = try fixture(
            accountId: "acc-queue-002-turnover", provider: .gmail,
            folders: [("Drafts", .drafts, 5)])
        defer { finish(fixture) }

        let provider = MockEmailProvider()
        await provider.setMarkReadThrows(ProviderError.notConnected)
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: fixture.accountId, provider: provider
        ) {

            let t0 = baseTimestamp()
            var predecessor = PendingOperation(
                type: .markRead, messageIds: ["draft-1"], accountId: fixture.accountId,
                folderPath: "Drafts")
            predecessor.createdAt = t0
            // Both epochs REAL and disagreeing: a proven reset in this op's own
            // address space. This is the one arm of the checkpoint that may delete.
            var subject = PendingOperation(
                type: .setTag, messageIds: ["draft-1"], accountId: fixture.accountId,
                folderPath: "Drafts", tagValue: "archive", observedUidValidity: 4)
            subject.createdAt = t0.addingTimeInterval(1)
            try insertOp(predecessor, fixture)
            try insertOp(subject, fixture)

            await AccountManager.shared.drainPendingQueue()

            // THE CONTROL: if the non-zero guards had been written as an
            // unconditional refusal to compare, the pair would stop distinguishing
            // anything and a proven turnover would execute under numbering the op
            // never observed (C3).
            #expect(
                try fetchOp(subject.id, fixture) == nil,
                "a proven epoch turnover must still retire the op before any provider I/O")
        }
    }

    // MARK: - IOS-QUEUE-005 — the narrowing pass finishes the move it retires
    //
    // `retirePartiallyCompletedOp` is the drain's STANDING CONTRACT for any
    // provider that dispositions a strict subset of an op's members. It
    // returned before any re-key, so a retired member kept its SOURCE address
    // while its copy sat at the destination — the state that makes
    // `admittedOrdinaryActionTargets` refuse the row, so the user's next
    // gesture on it is a silent dead no-op until a sync repairs it.
    //
    // No production provider returns a strict subset today (`IMAPProvider.move`
    // dispositions every member), so this test is the path's only reachability
    // — which is precisely why the contract must be whole.
    //
    // RED PROOF (recorded): with the `finishMove` call removed from
    // `retirePartiallyCompletedOp`'s narrowing write,
    // `narrowedRetirementCarriesTheDestinationAddressTheServerNamed` fails —
    // the surviving row is still `…:INBOX:77` with `messageId == "77"`.

    @Test("a member retired in a narrowing pass ends the drain carrying the destination address COPYUID proved")
    func narrowedRetirementCarriesTheDestinationAddressTheServerNamed() async throws {
        let fixture = try fixture(accountId: "acc-queue-005-proven")
        defer { finish(fixture) }

        // The optimistic half of a move already ran: the row is shown in
        // Archive but still keyed by, and named by, its INBOX address.
        try seedHeader(
            fixture, messageId: "77", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)

        let op = PendingOperation(
            type: .move, messageIds: ["77", "88"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
        try insertOp(op, fixture)

        await AccountManager.shared.retirePartiallyCompletedOp(
            op, provenMembers: ["77"], remaining: ["88"],
            provenDestinations: [ProvenDestinationAddress(
                sourceProviderId: "77", destinationProviderId: "5", destinationUidValidity: 42)],
            addressChangesOnMove: true,
            context: AccountManager.DrainContext())

        let destinationId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "5")
        let rows = try await fixture.pool.read { db in
            try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(
            rows[0].id == destinationId && rows[0].messageId == "5",
            """
            the retired member was left at its SOURCE address, so the next gesture on it is a \
            silent dead no-op: id=\(rows[0].id) messageId=\(rows[0].messageId)
            """)
        #expect(
            rows[0].observedUidValidity == 42,
            "the destination epoch the server reported agrees with the folder, so it is stamped")

        // The unproven member is preserved, narrowed — never dropped.
        let after = try fetchOp(op.id, fixture)
        #expect(after?.messageIds == ["88"])
        #expect(after?.status == PendingStatus.queued.rawValue)
    }

    @Test("a narrowing pass with NO proven destination re-keys nothing and still keeps the unproven member queued")
    func narrowedRetirementWithoutProvenDestinationsChangesNoAddress() async throws {
        let fixture = try fixture(accountId: "acc-queue-005-unproven")
        defer { finish(fixture) }

        let seeded = try seedHeader(
            fixture, messageId: "77", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)

        let op = PendingOperation(
            type: .move, messageIds: ["77", "88"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
        try insertOp(op, fixture)

        await AccountManager.shared.retirePartiallyCompletedOp(
            op, provenMembers: ["77"], remaining: ["88"],
            provenDestinations: [], addressChangesOnMove: true,
            context: AccountManager.DrainContext())

        // THE CONTROL: the re-key is authorized by the server's own `COPYUID`
        // and by nothing else. With no destination proved, the address must not
        // move — a re-key on unproven evidence would be the wrong-message
        // mutation this whole design exists to refuse.
        let rows = try await fixture.pool.read { db in
            try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == seeded.id && rows[0].messageId == "77")

        let after = try fetchOp(op.id, fixture)
        #expect(after?.messageIds == ["88"], "the unproven member stays queued")
    }

    /// **THE PROPERTY, on an ACCOUNT-SCOPED provider: a member retired in a
    /// narrowing pass ends the drain addressed by the id the wire proved, in the
    /// folder its row currently occupies, and every queued operation still
    /// naming the old id is carried with it — all in the retiring transaction.**
    ///
    /// The two tests above only ever exercise the IMAP arm, and the two things
    /// that make the Outlook handoff work are exactly the two the IMAP arm does
    /// NOT do: follow the row out of `destinationPath`, and re-address the queue
    /// (`readdressQueuedOperations` returns immediately when `accountScopedIds`
    /// is false). So `retirePartiallyCompletedOp` — the drain's standing
    /// contract for any provider that dispositions a strict subset — had no
    /// coverage at all on the arm that Graph actually takes, even though it
    /// reads its own `accountScopedIdAccountIds` classification inside the
    /// narrowing write.
    ///
    /// The row is seeded back in `INBOX` while the move to `Archive` retires —
    /// the archive/undo/re-delete sequence — so a primary-key lookup at
    /// `destinationPath` would miss it, the row would keep the id Graph just
    /// invalidated, and the user's next gesture built FROM THAT ROW would name a
    /// dead id.
    @Test("Outlook: a member retired in a narrowing pass carries the proven address into its row AND into the queue")
    func narrowedRetirementOnAnAccountScopedProviderCarriesTheAddressIntoTheQueue() async throws {
        let fixture = try fixture(
            accountId: "acc-queue-005-graph", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        try seedHeader(
            fixture, messageId: "graph-old", folderPath: "INBOX", epoch: nil)

        // A follower the user queued behind the move, naming the id Graph is
        // about to reallocate, and a bystander naming a different message.
        let follower = PendingOperation(
            type: .markRead, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", observedUidValidity: nil)
        let bystander = PendingOperation(
            type: .markFlagged, messageIds: ["graph-other"], accountId: fixture.accountId,
            folderPath: "INBOX", observedUidValidity: nil)
        try insertOp(follower, fixture)
        try insertOp(bystander, fixture)

        var op = PendingOperation(
            type: .move, messageIds: ["graph-old", "graph-unproven"],
            accountId: fixture.accountId, folderPath: "INBOX",
            destinationPath: "Archive", observedUidValidity: nil)
        op.status = PendingStatus.inFlight.rawValue
        op.everAttempted = true
        try insertOp(op, fixture)
        let frozenOp = op

        await AccountManager.shared.retirePartiallyCompletedOp(
            frozenOp, provenMembers: ["graph-old"], remaining: ["graph-unproven"],
            provenDestinations: [ProvenDestinationAddress(
                sourceProviderId: "graph-old", destinationProviderId: "graph-new",
                destinationUidValidity: nil)],
            addressChangesOnMove: true,
            context: AccountManager.DrainContext())

        // The row answers to the proven address, IN THE FOLDER IT OCCUPIES.
        let landedId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "graph-new")
        let rows = try await fixture.pool.read { db in
            try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == landedId && rows[0].messageId == "graph-new"
                    && rows[0].folderPath == "INBOX", """
            the narrowing pass left the retired member at an address Graph had \
            already invalidated: id=\(rows[0].id) messageId=\(rows[0].messageId) \
            folder=\(rows[0].folderPath). The next gesture built from this row \
            names a dead id, 404s, and is deleted by the conflict arm.
            """)

        // The handoff reached the QUEUE in the same transaction — and only the
        // operation that actually named the moved id.
        let (followerIds, bystanderIds) = try await fixture.pool.read { db in
            (try PendingOperation.fetchOne(db, key: follower.id)?.messageIds,
             try PendingOperation.fetchOne(db, key: bystander.id)?.messageIds)
        }
        #expect(followerIds == ["graph-new"], """
            a follower queued behind a PARTIALLY retired move still names the \
            dead id: observed \(String(describing: followerIds))
            """)
        #expect(bystanderIds == ["graph-other"],
                "an operation naming a different message was re-addressed — that is a wrong-message mutation")

        // The unproven member is preserved, narrowed, and retryable — never
        // dropped and never left `inFlight`.
        let after = try fetchOp(frozenOp.id, fixture)
        #expect(after?.messageIds == ["graph-unproven"])
        #expect(after?.status == PendingStatus.queued.rawValue)
    }

    /// **THE PROPERTY: a re-addressed follower keeps EVERY member it named, in
    /// order, with only the members the wire actually re-addressed rewritten.**
    ///
    /// The sibling above proves the handoff reaches the queue with a
    /// single-member follower, which cannot tell three different rewrites apart:
    /// "replace the whole array with the mapped ids", "rewrite the first member"
    /// and "map each member through the proof, pass the rest through" all agree
    /// on a one-element array whose one element is mapped. They disagree the
    /// moment a follower names a member the move never touched — the ordinary
    /// case, because a user selects a set and then acts on part of it.
    ///
    /// So this follower names `[untouched, moved-1, moved-2]`: the UNMAPPED
    /// member comes FIRST, and TWO members are proven. A rewrite that keeps only
    /// the mapped members silently drops `graph-untouched` — a dropped
    /// intention. A rewrite that only touches the first member leaves both moved
    /// ids at addresses Graph has already invalidated, where the follower 404s
    /// and the single-message conflict arm deletes it.
    ///
    /// The follower's own identity is asserted unchanged as well: a re-address
    /// rewrites an ADDRESS, never the gesture, its folder, or the durable proof
    /// that it was already claimed once.
    @Test("Outlook: a re-addressed follower keeps its untouched members, in order, and its claim state")
    func narrowedRetirementReaddressesOnlyTheMembersTheWireProved() async throws {
        let fixture = try fixture(
            accountId: "acc-queue-005-graph-mixed", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        try seedHeader(fixture, messageId: "graph-moved-1", folderPath: "INBOX", epoch: nil)
        try seedHeader(fixture, messageId: "graph-moved-2", folderPath: "INBOX", epoch: nil)
        try seedHeader(fixture, messageId: "graph-untouched", folderPath: "INBOX", epoch: nil)

        // The follower the user queued behind the move. It names a member the
        // move never touched FIRST, then both members the move is about to
        // reallocate.
        var follower = PendingOperation(
            type: .markRead,
            messageIds: ["graph-untouched", "graph-moved-1", "graph-moved-2"],
            accountId: fixture.accountId, folderPath: "INBOX", observedUidValidity: nil)
        follower.everAttempted = true
        let frozenFollower = follower
        try insertOp(frozenFollower, fixture)

        var op = PendingOperation(
            type: .move,
            messageIds: ["graph-moved-1", "graph-moved-2", "graph-unproven"],
            accountId: fixture.accountId, folderPath: "INBOX",
            destinationPath: "Archive", observedUidValidity: nil)
        op.status = PendingStatus.inFlight.rawValue
        op.everAttempted = true
        try insertOp(op, fixture)
        let frozenOp = op

        await AccountManager.shared.retirePartiallyCompletedOp(
            frozenOp,
            provenMembers: ["graph-moved-1", "graph-moved-2"],
            remaining: ["graph-unproven"],
            provenDestinations: [
                ProvenDestinationAddress(
                    sourceProviderId: "graph-moved-1",
                    destinationProviderId: "graph-new-1",
                    destinationUidValidity: nil),
                ProvenDestinationAddress(
                    sourceProviderId: "graph-moved-2",
                    destinationProviderId: "graph-new-2",
                    destinationUidValidity: nil),
            ],
            addressChangesOnMove: true,
            context: AccountManager.DrainContext())

        let readdressed = try fetchOp(frozenFollower.id, fixture)
        #expect(readdressed?.messageIds == ["graph-untouched", "graph-new-1", "graph-new-2"], """
            the re-address did not map member-for-member: observed \
            \(String(describing: readdressed?.messageIds)). Keeping only the mapped \
            members drops the user's gesture on graph-untouched; rewriting only the \
            first member leaves graph-moved-1 and graph-moved-2 at ids Graph has \
            already invalidated, where the follower 404s and is deleted.
            """)

        // THE ADDRESS CHANGED — NOTHING ELSE DID. `everAttempted` in particular
        // is the durable proof that this row was already claimed once; a
        // re-address that reset it would make the row annihilable again.
        #expect(readdressed?.type == .markRead, "the re-address rewrote the gesture itself")
        #expect(readdressed?.folderPath == "INBOX", "the re-address moved the follower's folder")
        #expect(readdressed?.everAttempted == frozenFollower.everAttempted,
                "the re-address discarded the durable claim proof")
        #expect(readdressed?.retryCount == frozenFollower.retryCount,
                "a retry was charged for a re-address, which is not a failure")

        // The parent keeps EXACTLY its unproven remainder — the two proven
        // members retired, the third never touched the wire.
        let after = try fetchOp(frozenOp.id, fixture)
        #expect(after?.messageIds == ["graph-unproven"])
        #expect(after?.status == PendingStatus.queued.rawValue)

        // POSITIVE CONTROL for the rows themselves: both proven members answer
        // to the ids the wire named, and the untouched one does not move.
        let messageIds = try await fixture.pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == fixture.accountId)
                .fetchAll(db)
                .map(\.messageId)
                .sorted()
        }
        #expect(messageIds == ["graph-new-1", "graph-new-2", "graph-untouched"], """
            the re-key did not follow both proven members: \(messageIds)
            """)
    }

    /// A GRDB `TransactionObserver` that REFUSES the commit of any transaction
    /// which wrote `messageHeader` — the standard GRDB way to force a commit
    /// failure (`databaseWillCommit()` throws → SQLite's commit hook aborts the
    /// COMMIT → GRDB rolls back and rethrows to `pool.write`'s caller). A real
    /// production possibility (an I/O error or a full disk at COMMIT), not a
    /// manufactured writer. Lifted from
    /// `SyncEngineRunSyncTests.HeaderCommitRefuser`, refusal counter included so
    /// a test can prove the refusal landed on the transaction it names.
    private final class HeaderCommitRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let sawHeaderWrite = Mutex(false)
        let refusals = Mutex(0)

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageHeader.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            sawHeaderWrite.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawHeaderWrite.withLock({ $0 }) else { return }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
    }

    /// **THE PROPERTY: the narrowing pass is ALL OR NOTHING, and a proof the
    /// provider has already given us is not thrown away because the local write
    /// would not commit. If the write does not commit the operation keeps every
    /// member it was issued with, no address anywhere has moved, and nothing can
    /// claim the row again — the proof is retained in this process and replayed
    /// by the next drain, which then narrows the row to exactly its unproven
    /// remainder.**
    ///
    /// The two tests above assert what a SUCCESSFUL narrowing leaves behind.
    /// Neither can see the state that matters more: the re-key and the narrowing
    /// are one transaction, so a partial outcome — members removed from the row
    /// while the header keeps its source address, or the reverse — would be a
    /// silently dropped intention or a row nothing can address.
    ///
    /// ⚠️ THIS TEST USED TO PIN THE OLD MECHANISM: it asserted the whole bundle
    /// was returned to `queued`, so a retry would re-copy the members the
    /// provider had already proved. That accepted a duplicate at the destination
    /// to avoid losing a member — but it also DISCARDED the destination
    /// addresses the wire had named for the proven prefix, which on an
    /// account-scoped provider is the follower's address too. The invariant, not
    /// the mechanism, is what is asserted now (`MIS-015`): what the operation
    /// still owes, whether anything can execute it meanwhile, and where the row
    /// ends up once the database accepts writes again
    /// (`TabMail/tabmail-ios#120`).
    ///
    /// The refusal is raised at COMMIT rather than by a poisoned statement, so
    /// the transaction is one a real disk failure — or GRDB's own suspension
    /// when the app is backgrounded mid-drain — could produce, and the refusal
    /// counter proves it landed on the narrowing write itself (`MIS-027`: red
    /// for the right reason).
    @Test("a narrowing pass whose write never commits keeps the WHOLE bundle unclaimable, moves no address, and is replayed by the next drain")
    func narrowedRetirementThatCannotCommitKeepsTheWholeBundleQueued() async throws {
        let fixture = try fixture(accountId: "acc-queue-005-rollback")
        defer { finish(fixture) }

        let seeded = try seedHeader(
            fixture, messageId: "77", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)

        var op = PendingOperation(
            type: .move, messageIds: ["77", "88"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
        op.status = PendingStatus.inFlight.rawValue
        op.everAttempted = true
        try insertOp(op, fixture)
        let frozenOp = op

        // Installed AFTER the fixture seeding, so the only header-writing
        // transaction it can refuse is the narrowing write itself.
        let refuser = HeaderCommitRefuser()
        fixture.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        await AccountManager.shared.retirePartiallyCompletedOp(
            frozenOp, provenMembers: ["77"], remaining: ["88"],
            provenDestinations: [ProvenDestinationAddress(
                sourceProviderId: "77", destinationProviderId: "5",
                destinationUidValidity: 42)],
            addressChangesOnMove: true,
            context: AccountManager.DrainContext())

        // NON-VACUITY: the narrowing write really was attempted and really was
        // refused — once per `retryWrite` attempt, and never more.
        #expect(refuser.refusals.withLock { $0 } == 3, """
            the refusal did not land on the narrowing write for all three \
            attempts, so this test is not measuring a rollback: \
            \(refuser.refusals.withLock { $0 })
            """)

        // NOTHING was narrowed: the proven member is still owed by the row, so
        // no member has been dropped by a write that never committed.
        let after = try fetchOp(frozenOp.id, fixture)
        #expect(after?.messageIds == ["77", "88"], """
            the operation was narrowed by a transaction that never committed — \
            observed \(String(describing: after?.messageIds))
            """)
        // AND NOTHING CAN CLAIM IT MEANWHILE. The provider already moved the
        // proven member; returning the bundle to `queued` here would hand that
        // same member back to the wire on the next pass. `inFlight` is what the
        // claim loop refuses, and it is what makes "exactly one wire move per
        // proven move" hold without any new guard.
        #expect(after?.status == PendingStatus.inFlight.rawValue, """
            the bundle was made claimable again after the provider had already \
            proved part of it, so the proven member will be re-sent: \
            \(after?.status ?? "<deleted>")
            """)
        #expect(after?.retryCount == 0,
                "a failed LOCAL write charges no provider retry")

        // And NO address moved: the header is exactly where the seeding left it.
        let rows = try await fixture.pool.read { db in
            try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == seeded.id && rows[0].messageId == "77", """
            the re-key survived a transaction that was rolled back: \
            id=\(rows[0].id) messageId=\(rows[0].messageId)
            """)

        // THE RECOVERY. The database accepts writes again — the state a live
        // process reaches when the app returns to the foreground and GRDB's
        // suspension lifts. The retained proof is replayed by the ordinary
        // drain, through the SAME transaction the original site ran.
        fixture.pool.remove(transactionObserver: refuser)
        await AccountManager.shared.drainPendingQueue()

        let replayed = try fetchOp(frozenOp.id, fixture)
        #expect(replayed?.messageIds == ["88"], """
            the retained proof was not replayed: the row still owes members the \
            provider already moved — \(String(describing: replayed?.messageIds))
            """)
        #expect(replayed?.status == PendingStatus.queued.rawValue,
                "the narrowed remainder must be retryable — \(replayed?.status ?? "<deleted>")")

        let destinationId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "5")
        let replayedRows = try await fixture.pool.read { db in
            try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
        }
        #expect(replayedRows.count == 1)
        guard replayedRows.count == 1 else { return }
        #expect(replayedRows[0].id == destinationId && replayedRows[0].messageId == "5", """
            the retired member is still at its SOURCE address after the replay, \
            so the next gesture on it is a silent dead no-op: \
            id=\(replayedRows[0].id) messageId=\(replayedRows[0].messageId)
            """)
    }

    /// **THE SAME PROPERTY ON THE ARM GRAPH ACTUALLY TAKES: the retained proof
    /// carries the address into the QUEUE when it is replayed, and the move is
    /// never sent to the wire a second time.**
    ///
    /// The IMAP sibling above cannot see either half. `readdressQueuedOperations`
    /// returns immediately when `accountScopedIds` is false, so on IMAP a
    /// discarded proof costs only the header's address; on Outlook it costs the
    /// FOLLOWER's, and a follower that goes out at the id Graph reallocated is
    /// 404'd and deleted by the single-message conflict arm — the user's newest
    /// gesture, destroyed.
    ///
    /// The provider ledger is the wire oracle and it is two-sided: after the
    /// replay it must contain the move of the UNPROVEN member (proving the
    /// registered provider is live and reachable from the drain, so a `0` below
    /// is not structural) and must NOT contain any move naming the member the
    /// provider already proved.
    @Test("Outlook: a narrowing pass that cannot commit is replayed to the proven address, and the proven member is never moved twice")
    func narrowedRetirementThatCannotCommitIsReplayedOnAnAccountScopedProvider() async throws {
        // No `Archive` folder row: the post-drain sync is a repair strictly
        // downstream of the defect, and against a mock provider it would rewrite
        // the very rows this test reads. Omitting the destination `Folder` makes
        // the post-drain lookup miss and skips it — the same reason
        // `OutlookQueueHandoffTests` omits it.
        let fixture = try fixture(
            accountId: "acc-queue-005-graph-replay", provider: .outlook,
            folders: [("INBOX", .inbox, nil)])
        defer { finish(fixture) }

        let seeded = try seedHeader(
            fixture, messageId: "graph-old", folderPath: "INBOX", epoch: nil)

        // The follower the user queued behind the move, naming the id Graph is
        // about to reallocate.
        let follower = PendingOperation(
            type: .markRead, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", observedUidValidity: nil)
        try insertOp(follower, fixture)

        var op = PendingOperation(
            type: .move, messageIds: ["graph-old", "graph-unproven"],
            accountId: fixture.accountId, folderPath: "INBOX",
            destinationPath: "Archive", observedUidValidity: nil)
        op.status = PendingStatus.inFlight.rawValue
        op.everAttempted = true
        try insertOp(op, fixture)
        let frozenOp = op

        let refuser = HeaderCommitRefuser()
        fixture.pool.add(transactionObserver: refuser, extent: .databaseLifetime)

        let provider = MockEmailProvider()
        try await TestProviderRegistry.withRegisteredProvider(
            accountId: fixture.accountId, provider: provider
        ) {
            await AccountManager.shared.retirePartiallyCompletedOp(
                frozenOp, provenMembers: ["graph-old"], remaining: ["graph-unproven"],
                provenDestinations: [ProvenDestinationAddress(
                    sourceProviderId: "graph-old", destinationProviderId: "graph-new",
                    destinationUidValidity: nil)],
                addressChangesOnMove: true,
                context: AccountManager.DrainContext())

            #expect(refuser.refusals.withLock { $0 } == 3, """
                the refusal did not land on the narrowing write for all three \
                attempts, so this test is not measuring a rollback: \
                \(refuser.refusals.withLock { $0 })
                """)

            // PHASE 1 — nothing durable moved, and nothing can claim the row.
            let held = try fetchOp(frozenOp.id, fixture)
            #expect(held?.messageIds == ["graph-old", "graph-unproven"],
                    "a member was removed by a write that never committed: \(String(describing: held?.messageIds))")
            #expect(held?.status == PendingStatus.inFlight.rawValue, """
                the bundle was made claimable again after Graph had already moved \
                one of its members: \(held?.status ?? "<deleted>")
                """)
            #expect(held?.retryCount == 0, "a failed LOCAL write charges no provider retry")
            let heldFollower = try fetchOp(follower.id, fixture)
            #expect(heldFollower?.messageIds == ["graph-old"], """
                the follower's address moved even though the transaction that \
                proves it never committed: \(String(describing: heldFollower?.messageIds))
                """)
            let beforeRows = try await fixture.pool.read { db in
                try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
            }
            #expect(beforeRows.count == 1)
            guard beforeRows.count == 1 else { return }
            #expect(beforeRows[0].id == seeded.id && beforeRows[0].messageId == "graph-old",
                    "the re-key survived a transaction that was rolled back: id=\(beforeRows[0].id)")

            // PHASE 2 — writes work again, and an ordinary drain replays.
            fixture.pool.remove(transactionObserver: refuser)
            await AccountManager.shared.drainPendingQueue()

            let replayedRows = try await fixture.pool.read { db in
                try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchAll(db)
            }
            #expect(replayedRows.count == 1)
            guard replayedRows.count == 1 else { return }
            #expect(replayedRows[0].messageId == "graph-new" && replayedRows[0].folderPath == "INBOX", """
                the retired member is still at the address Graph invalidated: \
                messageId=\(replayedRows[0].messageId) folder=\(replayedRows[0].folderPath)
                """)

            // THE WIRE LEDGER, both sides. The unproven member's move proves the
            // provider is live and reachable from this drain; the absence of any
            // move naming the proven member is the invariant.
            let log = await provider.callLog
            let moves = log.filter { $0.hasPrefix("move(") }
            #expect(moves.count == 1, "unexpected move traffic: \(moves)")
            guard moves.count == 1 else { return }
            #expect(moves[0].contains("graph-unproven"), """
                the narrowed remainder never reached the provider, so the \
                "no second move" assertion below is structurally vacuous: \(moves)
                """)
            #expect(!moves[0].contains("graph-old"), """
                the member the provider had already proved was moved a SECOND \
                time on the wire: \(moves)
                """)

            // And the follower executed at the address the retirement proved.
            let reads = log.filter { $0.hasPrefix("markRead(") }
            #expect(reads.count == 1, "the follower did not execute exactly once: \(reads)")
            guard reads.count == 1 else { return }
            #expect(reads[0].contains("graph-new") && !reads[0].contains("graph-old"), """
                the follower went to the wire at an address the move had already \
                invalidated, where Graph answers 404 and the conflict arm deletes \
                the user's newest gesture: \(reads)
                """)

            let survivors = try await fixture.pool.read { db in
                try PendingOperation.filter(Column("accountId") == fixture.accountId).fetchAll(db)
            }
            #expect(survivors.isEmpty,
                    "the queue did not drain after the replay: \(survivors.map(\.messageIdsJSON))")
        }
    }

    // MARK: - IOS-UNDO-002 / IOS-SEARCH-002 — publishing a committed re-key
    //
    // Both rows are about the window AFTER the GRDB write commits, when stores
    // that key by `messageHeader.id` — undo, chat-pill identity, FTS and body
    // assets — are brought up to date.

    /// `IOS-UNDO-002`. The FTS index is a SEPARATE SQLite pool, so its re-key is
    /// a real cross-database round trip. Running it BEFORE the undo publication
    /// left the stack naming the stale `originalHeaderId` for the whole of that
    /// suspension, and an `Undo` landing inside it was refused WHOLE
    /// (`undoMove` authenticates each member with
    /// `MessageHeader.fetchOne(db, key: originalHeaderId)`, now nil) with no
    /// way to repair an entry already popped off the stack.
    ///
    /// The ordering is observed WITHOUT a timing race: `UndoService` is
    /// `@MainActor`, so holding the MainActor makes the undo publication
    /// impossible. Anything the publication manages to do during that hold
    /// therefore provably happened BEFORE the undo stack was updated. In the
    /// fixed ordering the answer is "nothing", because the FTS call sits after
    /// a hop that cannot complete.
    ///
    /// RED PROOF (recorded): with `publishMoveFinish`'s two calls swapped back, the
    /// probe observes the FTS entry ALREADY re-keyed while the MainActor is
    /// still held, and `ftsUntouchedWhileUndoPublicationIsBlocked` fails.
    @Test("the undo stack is published BEFORE the cross-database FTS round trip")
    @MainActor
    func undoStackIsPublishedBeforeTheFtsRoundTrip() async throws {
        let fixture = try fixture(accountId: "acc-undo-002")
        defer { finish(fixture) }

        let oldHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "77")
        let newHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "5")
        let oldKey = ContentKey(rawValue: oldHeaderId)
        let record = HeaderRekeyRecord(
            oldHeaderId: oldHeaderId, newHeaderId: newHeaderId, newProviderMessageId: "5")

        // A real FTS entry at the old key, so the cross-database re-key has
        // something observable to do.
        _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
            contentKey: oldKey, headerId: oldHeaderId, messageId: "77",
            subject: "queue core undo", from: "Sender", to: "queue-core@example.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: "INBOX"))])
        defer {
            Task { try? await SearchIndex.shared.removeMessages(
                contentKeys: [oldKey, ContentKey(rawValue: newHeaderId)]) }
        }

        // The undo stack names the member by the address the re-key changes.
        let moved = try seedHeader(fixture, messageId: "77", folderPath: "INBOX")
        let undoAction = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [moved],
            originalFolderId: moved.folderId,
            originalFolderPath: "INBOX",
            accountId: fixture.accountId,
            timestamp: Date())
        let actionID = undoAction.id
        UndoService.shared.push(undoAction)
        defer { UndoService.shared.dismissAll() }

        // Samples the FTS index from OUTSIDE the MainActor, at a point where
        // the MainActor is provably still held below.
        let probe = Task.detached { () -> Bool in
            try? await Task.sleep(for: .milliseconds(Self.probeDelayMilliseconds))
            let missing = (try? await SearchIndex.shared
                .contentKeysMissingFromFTS([oldKey])) ?? []
            return missing.isEmpty
        }
        let publish = Task.detached {
            await AccountManager.shared.publishMoveFinish(MoveFinishResult(applied: [record]))
        }
        // Hold the MainActor SYNCHRONOUSLY — an `await` here would release it
        // and let the undo publication through, which is exactly what must not
        // happen while the probe is sampling.
        let deadline = Date().addingTimeInterval(Double(Self.mainActorHoldMilliseconds) / 1000)
        while Date() < deadline { _ = Date() }

        let ftsStillAtOldKey = await probe.value
        #expect(
            ftsStillAtOldKey,
            """
            the cross-database FTS re-key ran while the undo stack still named the stale header \
            id — an Undo landing in that window is refused whole and cannot be repaired
            """)

        // NON-VACUITY, both sides: once the MainActor is free BOTH stores
        // converge, so the assertion above cannot be passing because the
        // publication did nothing at all.
        await publish.value
        let stackMember = UndoService.shared.undoStack.last?.commands.first?.members.first
        #expect(UndoService.shared.undoStack.last?.id == actionID)
        #expect(stackMember?.originalHeaderId == newHeaderId)
        #expect(stackMember?.providerMessageId == "5")
        let missingAfter = try await SearchIndex.shared.contentKeysMissingFromFTS([oldKey])
        #expect(missingAfter == [oldKey], "the FTS entry moved off the old key")
    }

    @Test("a committed message re-key preserves cached chat-pill identity")
    func committedRekeyPreservesCachedChatPillIdentity() async throws {
        let fixture = try fixture(accountId: "acc-chat-pill-rekey")
        defer { finish(fixture) }
        await ChatIdTranslator.shared.clearAll()

        let oldHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "77")
        let newHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "5")
        let numericId = await ChatIdTranslator.shared.toNumericId(oldHeaderId)

        await AccountManager.shared.publishMoveFinish(MoveFinishResult(applied: [
            HeaderRekeyRecord(
                oldHeaderId: oldHeaderId,
                newHeaderId: newHeaderId,
                newProviderMessageId: "5")
        ]))

        #expect(await ChatIdTranslator.shared.toRealId(numericId) == newHeaderId)
        let persistedRealId = try await fixture.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?",
                arguments: [numericId])
        }
        #expect(persistedRealId == newHeaderId)

        await ChatIdTranslator.shared.clearAll()
    }

    /// `IOS-SEARCH-002`. `MessageHeaderRekey.apply` deletes the old header and
    /// its body BEFORE the collision guard — deliberately, so the leg that
    /// skips the re-insert cannot leave a duplicate — and then returns false.
    /// The drain published only the APPLIED re-keys, so the old id's FTS entry
    /// survived with no header behind it: the *indexed but unfindable* class,
    /// at a composite id a later message can re-occupy.
    ///
    /// RED PROOF (recorded): with the `removeMessages` call deleted from
    /// `publishMoveFinish`, `collidedRekeyLeavesNoFtsEntryWithoutAHeader` fails —
    /// `contentKeysMissingFromFTS` reports the old key present while no
    /// `messageHeader` row carries it.
    @Test("a collided drain-time re-key leaves no FTS entry whose header is gone")
    func collidedRekeyLeavesNoFtsEntryWithoutAHeader() async throws {
        let fixture = try fixture(accountId: "acc-search-002")
        defer { finish(fixture) }

        // The row this move is finishing, still keyed by its source address …
        try seedHeader(
            fixture, messageId: "77", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)
        // … and a row ALREADY occupying the destination address the server
        // named, which is what makes `apply` take its collision return.
        try seedHeader(fixture, messageId: "5", folderPath: "Archive")

        let oldHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "77")
        let oldKey = ContentKey(rawValue: oldHeaderId)
        _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
            contentKey: oldKey, headerId: oldHeaderId, messageId: "77",
            subject: "queue core collision", from: "Sender", to: "queue-core@example.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: "INBOX"))])
        defer { Task { try? await SearchIndex.shared.removeMessages(contentKeys: [oldKey]) } }

        let op = PendingOperation(
            type: .move, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)

        // The drain's own step 3, verbatim — the re-key and the retirement of
        // the operation in ONE write, then the publication outside it.
        let outcome = try await fixture.pool.write { db -> MoveFinishResult in
            try MessageHeaderRekey.finishMove(
                op, destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationProviderId: "5", destinationUidValidity: 42)],
                addressChangesOnMove: true, accountScopedIds: false, db: db)
        }
        await AccountManager.shared.publishMoveFinish(outcome)

        // NON-VACUITY: the collision leg is the one that actually ran.
        #expect(outcome.applied.isEmpty)
        #expect(outcome.removedOldHeaderIds == [oldHeaderId])

        // THE PROPERTY, stated as the invariant rather than the mechanism: no
        // FTS entry names a header id with no `messageHeader` row behind it.
        let headerStillThere = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: oldHeaderId) != nil
        }
        #expect(!headerStillThere, "the collision leg deletes the old row — that is its contract")
        let missing = try await SearchIndex.shared.contentKeysMissingFromFTS([oldKey])
        #expect(
            missing == [oldKey],
            "an FTS entry outlived its header — a search hit with nothing behind it, at an address a later message can re-occupy")
    }

    @Test("an epochless Graph move still adopts the destination id the server returned")
    func epochlessGraphMoveStillRekeys() async throws {
        let fixture = try fixture(
            accountId: "acc-graph-rekey", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        let old = try seedHeader(
            fixture, messageId: "graph-old", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)
        let op = PendingOperation(
            type: .move, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: nil)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "graph-old",
                    destinationProviderId: "graph-new",
                    destinationUidValidity: nil)],
                addressChangesOnMove: true,
                // Outlook fixture — Graph ids are account-scoped.
                accountScopedIds: true,
                db: db)
        }

        let newId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "graph-new")
        let moved = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: newId)
        }
        #expect(result.applied == [HeaderRekeyRecord(
            oldHeaderId: old.id, newHeaderId: newId, newProviderMessageId: "graph-new")])
        #expect(moved?.messageId == "graph-new" && moved?.observedUidValidity == nil)
    }

    // MARK: - T11 — the address space decides where the row is, and who follows it

    /// **THE PROPERTY: on an account-scoped provider the re-key follows the
    /// MESSAGE, not the operation's destination folder.**
    ///
    /// One Graph id names one message per account, so the row that carries the
    /// id IS the row this move re-addresses — wherever it currently sits. It
    /// legitimately sits somewhere other than `destinationPath` in the sequence
    /// this arm exists for (`IOS-QUEUE-008`): archive, undo, then re-delete. The
    /// undo restores the row to the source folder while the forward move is still
    /// on the wire, so when the forward retires the row is NOT at the
    /// destination. A primary-key lookup there would miss it, the row would keep
    /// the id Graph had just invalidated, and the NEXT gesture the user builds
    /// FROM THAT ROW would name a dead id — 404, conflict arm, intention gone.
    ///
    /// Asserted as "the row now answers to the address the wire proved, in the
    /// folder it occupies", not as "the arm was taken" (`MIS-015`).
    @Test("account-scoped re-key: the row is re-addressed in the folder it currently occupies, not in the operation's destination")
    func accountScopedRekeyFollowsTheRowOutOfTheDestinationFolder() async throws {
        let fixture = try fixture(
            accountId: "acc-graph-follows-row", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        // The row is back in INBOX (an undo landed) while the forward move to
        // Archive is retiring. Its primary key is still the INBOX-shaped one the
        // gesture created.
        let row = try seedHeader(
            fixture, messageId: "graph-old", folderPath: "INBOX", epoch: nil)
        let op = PendingOperation(
            type: .move, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: nil)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "graph-old",
                    destinationProviderId: "graph-new",
                    destinationUidValidity: nil)],
                addressChangesOnMove: true,
                accountScopedIds: true,
                db: db)
        }

        // NON-VACUITY: the row really is NOT in the operation's destination, so
        // a destination-keyed lookup could not have found it.
        #expect(row.folderPath == "INBOX" && op.destinationPath == "Archive",
                "the fixture no longer poses the question this test exists for")

        let landedId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "graph-new")
        let moved = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: landedId)
        }
        #expect(moved?.messageId == "graph-new" && moved?.folderPath == "INBOX", """
            the row kept an address the wire had already invalidated: the next \
            gesture built from it would name a dead Graph id, 404, and be deleted \
            by the conflict arm. applied=\(result.applied)
            """)
        #expect(result.applied.map(\.newHeaderId) == [landedId])
        #expect(result.unsafeUndoOldHeaderIds.isEmpty)
    }

    /// **THE NEGATIVE CASE THAT BOUNDS IT: on IMAP the folder is part of the
    /// address, so a row that has left the destination is NOT this move's row.**
    ///
    /// The same fixture shape, one flag apart. A UID is mailbox-local — UID 77 in
    /// `INBOX` and UID 77 in `Archive` are different physical messages — so
    /// "follow the id wherever it went" would re-key a bystander (C3). G3's
    /// folder clause must still decline here, and it must decline by RETAINING
    /// the row and revoking only the stale undo authority.
    @Test("IMAP re-key still declines when the row has left the operation's destination folder")
    func imapRekeyStillDeclinesWhenTheRowLeftTheDestination() async throws {
        let fixture = try fixture(accountId: "acc-imap-declines-row")
        defer { finish(fixture) }

        let row = try seedHeader(fixture, messageId: "77", folderPath: "INBOX")
        let op = PendingOperation(
            type: .move, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationProviderId: "5",
                    destinationUidValidity: 42)],
                addressChangesOnMove: true,
                accountScopedIds: false,
                db: db)
        }

        #expect(result.applied.isEmpty, """
            an IMAP row that is not in this operation's destination folder was \
            re-keyed anyway — on IMAP that is a different physical message (C3)
            """)
        #expect(result.unsafeUndoOldHeaderIds == [row.id])
        let survivor = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: row.id)
        }
        #expect(survivor?.messageId == "77", "the declined row must be retained, not removed")
    }

    /// **THE PROPERTY: the address the wire just proved is carried into every
    /// queued operation of the account that still names the old one — and into
    /// nothing else.**
    ///
    /// This is what makes account-qualified lanes SAFE for Graph
    /// (`IOS-GRAPH-005`). Serializing a follower behind a move guarantees it runs
    /// after the id was reallocated; without this rewrite that guarantee is the
    /// defect, because the follower would go to the wire naming the dead id.
    ///
    /// The "and nothing else" half is not decoration: a re-address that swept in
    /// an operation naming a DIFFERENT message would be a wrong-message mutation,
    /// which nothing recovers.
    @Test("a queued follower naming the moved id is re-addressed in the retiring transaction, and an unrelated operation is not")
    func queuedFollowerIsReaddressedAndBystandersAreNot() async throws {
        let fixture = try fixture(
            accountId: "acc-graph-readdress", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        _ = try seedHeader(
            fixture, messageId: "graph-old", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)
        let retiring = PendingOperation(
            type: .move, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: nil)
        let follower = PendingOperation(
            type: .markRead, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "Archive", observedUidValidity: nil)
        let bystander = PendingOperation(
            type: .markFlagged, messageIds: ["graph-other"], accountId: fixture.accountId,
            folderPath: "INBOX", observedUidValidity: nil)
        try insertOp(follower, fixture)
        try insertOp(bystander, fixture)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                retiring,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "graph-old",
                    destinationProviderId: "graph-new",
                    destinationUidValidity: nil)],
                addressChangesOnMove: true,
                accountScopedIds: true,
                db: db)
        }

        let (followerIds, bystanderIds) = try await fixture.pool.read { db in
            (try PendingOperation.fetchOne(db, key: follower.id)?.messageIds,
             try PendingOperation.fetchOne(db, key: bystander.id)?.messageIds)
        }
        #expect(followerIds == ["graph-new"], """
            the follower still names the id the move invalidated: it will 404 and \
            the single-message conflict arm will delete it — the user's latest \
            intention, lost deterministically. observed: \(String(describing: followerIds))
            """)
        #expect(bystanderIds == ["graph-other"],
                "an operation naming a different message was re-addressed — that is a wrong-message mutation")
        #expect(result.readdressedOperationIds == [follower.id])
    }

    /// **THE FIRST BOUNDARY: "one id names one message" holds PER ACCOUNT, so a
    /// second account's operation carrying the SAME id string is a different
    /// message and must not be touched.**
    ///
    /// The test above bounds the sweep by MESSAGE (a different id in the same
    /// account is left alone). Nothing bounded it by ACCOUNT, and that is the
    /// direction where the id strings actually collide: Graph ids are opaque
    /// base64-ish blobs, two mailboxes of the same organisation are ordinary,
    /// and a restored-from-backup or re-added account can legitimately carry the
    /// same string. The account clause is the ONLY thing separating them —
    /// `readdressQueuedOperations` selects on `accountId`, and if that clause
    /// were dropped the sweep would rewrite another mailbox's queued gesture to
    /// an address the wire proved for a completely different message. That is a
    /// C3 wrong-message mutation, and nothing recovers it.
    @Test("a second account's operation naming the SAME provider id string is not re-addressed")
    func readdressingIsBoundedByAccountNotOnlyByMessageId() async throws {
        let fixture = try fixture(
            accountId: "acc-graph-readdress-a", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        // A SECOND Outlook account in the same database, whose queued gesture
        // names the identical id string.
        let otherAccountId = "acc-graph-readdress-b"
        try await fixture.pool.write { db in
            var other = Account(
                emailAddress: "queue-core-other@example.com", displayName: "Queue core B",
                provider: .outlook)
            other.id = otherAccountId
            try other.insert(db)
            for (path, role) in [("INBOX", FolderRole.inbox), ("Archive", FolderRole.archive)] {
                try Folder(name: path, path: path, role: role, accountId: otherAccountId)
                    .insert(db)
            }
        }

        _ = try seedHeader(
            fixture, messageId: "graph-old", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)
        let retiring = PendingOperation(
            type: .move, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: nil)
        let sameAccountFollower = PendingOperation(
            type: .markRead, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "Archive", observedUidValidity: nil)
        let otherAccountNamesake = PendingOperation(
            type: .markFlagged, messageIds: ["graph-old"], accountId: otherAccountId,
            folderPath: "INBOX", observedUidValidity: nil)
        try insertOp(sameAccountFollower, fixture)
        try insertOp(otherAccountNamesake, fixture)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                retiring,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "graph-old",
                    destinationProviderId: "graph-new",
                    destinationUidValidity: nil)],
                addressChangesOnMove: true,
                accountScopedIds: true,
                db: db)
        }

        let (mine, theirs) = try await fixture.pool.read { db in
            (try PendingOperation.fetchOne(db, key: sameAccountFollower.id)?.messageIds,
             try PendingOperation.fetchOne(db, key: otherAccountNamesake.id)?.messageIds)
        }
        // NON-VACUITY: the sweep really did run and really did rewrite something,
        // so "the other account was untouched" is not the trivially true answer
        // a no-op pass would also give.
        #expect(mine == ["graph-new"],
                "the sweep did not run at all, so the bystander half below proves nothing")
        #expect(theirs == ["graph-old"], """
            another ACCOUNT's queued gesture was re-addressed to an id proved for \
            a different mailbox's message — a wrong-message mutation (C3). \
            observed: \(String(describing: theirs))
            """)
        #expect(result.readdressedOperationIds == [sameAccountFollower.id])
    }

    /// **THE SECOND BOUNDARY, and the reason the whole sweep is gated: on IMAP a
    /// UID is MAILBOX-LOCAL, so an operation naming UID 77 in another folder is
    /// a different physical message and no `COPYUID` may re-address it.**
    ///
    /// `imapRekeyStillDeclinesWhenTheRowLeftTheDestination` covers the HEADER
    /// side of this; the QUEUE side was uncovered. The producer is real and
    /// routine: `NSEDataBridge.queueSetTagPendingOp` inserts rows keyed by a
    /// bare numeric id against a hard-coded `INBOX`, and any pre-move operation
    /// can legitimately name the same number for a different message elsewhere.
    /// A sweep that keyed on the id alone would rewrite `77` to `5` in an
    /// operation that never named this message, and the next drain would flag,
    /// read or move whatever now sits at UID 5 in that other folder.
    @Test("IMAP: a queued operation naming the same UID in ANOTHER folder is never re-addressed by a COPYUID")
    func imapReaddressingNeverCrossesAFolderBoundary() async throws {
        let fixture = try fixture(accountId: "acc-imap-readdress")
        defer { finish(fixture) }

        // The optimistic shape: shown in Archive, still keyed by its INBOX
        // address, so the IMAP arm's G3 folder clause admits the re-key.
        _ = try seedHeader(
            fixture, messageId: "77", folderPath: "Archive",
            keyedFromFolderPath: "INBOX")
        let retiring = PendingOperation(
            type: .move, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
        // A DIFFERENT physical message that happens to carry UID 77 in Trash.
        let elsewhere = PendingOperation(
            type: .markFlagged, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "Trash", observedUidValidity: 42)
        try insertOp(elsewhere, fixture)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                retiring,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationProviderId: "5",
                    destinationUidValidity: 42)],
                addressChangesOnMove: true,
                accountScopedIds: false,
                db: db)
        }

        // NON-VACUITY: the move DID prove a destination and the header DID move
        // to it, so a sweep keyed on the id alone had everything it needed.
        let movedId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "5")
        #expect(result.applied.map(\.newHeaderId) == [movedId],
                "the re-key did not happen, so there was no proven mapping for a sweep to misapply")

        let elsewhereIds = try fetchOp(elsewhere.id, fixture)?.messageIds
        #expect(elsewhereIds == ["77"], """
            a queued operation on (Trash, UID 77) was re-addressed by a COPYUID \
            proved for (INBOX, UID 77) — a UID is mailbox-local, so that is a \
            different physical message and this is a C3 wrong-message mutation. \
            observed: \(String(describing: elsewhereIds))
            """)
        #expect(result.readdressedOperationIds.isEmpty,
                "IMAP has no legitimate follower to re-address; the sweep must not run at all")
    }

    @Test("an address-stable Gmail move does not require destination-address evidence")
    func addressStableGmailMoveDoesNotEnterAddressRepair() async throws {
        let fixture = try fixture(accountId: "acc-gmail-stable", provider: .gmail)
        defer { finish(fixture) }

        let old = try seedHeader(
            fixture, messageId: "gmail-stable", folderPath: "Archive",
            keyedFromFolderPath: "INBOX", epoch: nil)
        let op = PendingOperation(
            type: .move, messageIds: ["gmail-stable"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: nil)

        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                // Gmail ids are account-scoped, but `addressChangesOnMove: false`
                // short-circuits before either arm — that is what this test pins.
                op, destinations: [], addressChangesOnMove: false,
                accountScopedIds: true, db: db)
        }

        #expect(result == .empty)
        let survivor = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: old.id)
        }
        #expect(survivor?.messageId == "gmail-stable" && survivor?.folderPath == "Archive")
    }

    @Test("a retired move whose old row is already gone releases its old external mirrors")
    func missingOldRowIsClassifiedForMirrorRemoval() async throws {
        let fixture = try fixture(accountId: "acc-missing-old-row")
        defer { finish(fixture) }

        let op = PendingOperation(
            type: .move, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                op, destinations: [], addressChangesOnMove: true,
                accountScopedIds: false, db: db)
        }
        let oldId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "77")

        #expect(result.applied.isEmpty)
        #expect(result.unsafeUndoOldHeaderIds.isEmpty)
        #expect(result.removedOldHeaderIds == [oldId])
    }

    /// **THE ACCOUNT-SCOPED HALF OF THE SAME PROPERTY, with a REAL producer: a
    /// move that retires against zero matching rows classifies the member for
    /// mirror removal — it never declines, and it never re-keys a bystander.**
    ///
    /// The test above only reaches the IMAP arm's `fetchOne(key:) == nil` path.
    /// The account-scoped arm answers "already gone" from a DIFFERENT test —
    /// `candidates.isEmpty` on an `(accountId, messageId)` query — and it sits
    /// beside the `candidates.count > 1` arm, which does the OPPOSITE (declines
    /// and revokes undo authority). Nothing distinguished the two, so an
    /// inversion that folded zero into the ambiguous arm would have gone
    /// unnoticed, leaving external mirrors (FTS entries, body assets, undo
    /// commands) pointing at a header id nothing will ever produce again.
    ///
    /// The rows are removed by the REAL producer rather than by a hand-written
    /// `DELETE`: `AccountDetailView.resetMessageDataTxn`, the account-scoped
    /// "reset message data" gesture, which deletes every `messageHeader` of the
    /// account while deliberately leaving `pendingOperation` alone — so a move
    /// can genuinely be in flight across it and retire into an empty header
    /// table.
    @Test("account-scoped: a move retiring after the account's message data was reset releases its old mirrors")
    func accountScopedZeroMatchAfterAMessageDataResetIsClassifiedForMirrorRemoval() async throws {
        let fixture = try fixture(
            accountId: "acc-graph-missing-old-row", provider: .outlook,
            folders: [("INBOX", .inbox, nil), ("Archive", .archive, nil)])
        defer { finish(fixture) }

        let seeded = try seedHeader(
            fixture, messageId: "graph-old", folderPath: "INBOX", epoch: nil)

        // THE REAL PRODUCER. Its own contract is asserted here too, because the
        // arm under test depends on both halves of it: headers gone, operations
        // untouched.
        let survivingOp = PendingOperation(
            type: .markRead, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", observedUidValidity: nil)
        try insertOp(survivingOp, fixture)
        try await fixture.pool.write { db in
            try AccountDetailView.resetMessageDataTxn(db, accountId: fixture.accountId)
        }
        let (headerCount, opSurvived) = try await fixture.pool.read { db in
            (try MessageHeader.filter(Column("accountId") == fixture.accountId).fetchCount(db),
             try PendingOperation.fetchOne(db, key: survivingOp.id) != nil)
        }
        #expect(headerCount == 0, "the reset did not remove the header, so the zero-match arm is not reached")
        #expect(opSurvived, "the reset removed the queued operation, so nothing is left in flight across it")

        let op = PendingOperation(
            type: .move, messageIds: ["graph-old"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: nil)
        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                op,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "graph-old",
                    destinationProviderId: "graph-new",
                    destinationUidValidity: nil)],
                addressChangesOnMove: true,
                accountScopedIds: true,
                db: db)
        }

        #expect(result.applied.isEmpty, "there was no row to re-key")
        #expect(result.unsafeUndoOldHeaderIds.isEmpty, """
            zero matches was treated as the AMBIGUOUS case: the member's external \
            mirrors are then retained against a header id that no longer exists \
            and will never be produced again
            """)
        #expect(result.removedOldHeaderIds == [seeded.id], """
            the vanished member was not classified for mirror removal — observed \
            \(result.removedOldHeaderIds)
            """)
        // The queue handoff still runs: the wire proved an address, so a
        // follower must carry it even though no local row survives to re-key.
        #expect(try fetchOp(survivingOp.id, fixture)?.messageIds == ["graph-new"],
                "the follower kept the id the move invalidated even though the wire proved its replacement")
    }

    /// A successful address-changing move invalidates the source-address undo
    /// member even when the old primary key has since been occupied by a row
    /// outside this operation's exact optimistic shape. The row itself must be
    /// left untouched, and its FTS entry must remain because it still exists;
    /// only the stale undo authority is unsafe.
    ///
    /// RED PROOF (recorded): before the first atomic-MOVE implementation audit
    /// classified G3 mismatches for undo pruning, `finishMove` returned no
    /// disposition for this member. `publishMoveFinish` therefore retained an
    /// undo command whose source address now names the unrelated survivor.
    @Test("a successful move prunes stale undo when its old key now names a non-optimistic row")
    @MainActor
    func nonOptimisticOldRowPrunesOnlyItsStaleUndoMember() async throws {
        let fixture = try fixture(accountId: "acc-mismatched-old-row")
        defer { finish(fixture) }

        let original = try seedHeader(
            fixture, messageId: "77", folderPath: "INBOX", epoch: 42)
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [original],
            originalFolderId: original.folderId,
            originalFolderPath: "INBOX",
            accountId: fixture.accountId,
            timestamp: Date()))
        defer { UndoService.shared.dismissAll() }

        // Simulate a later local owner at the same primary key. Its folder
        // fields deliberately do not match this operation's optimistic
        // Archive row, so G3 must not re-key or delete it.
        try await fixture.pool.write { db in
            let fetched = try MessageHeader.fetchOne(db, key: original.id)
            var survivor = try #require(fetched)
            survivor.folderPath = "Trash"
            survivor.folderId = MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: "Trash")
            survivor.observedUidValidity = 42
            try survivor.update(db)
        }

        let oldKey = ContentKey(rawValue: original.id)
        _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
            contentKey: oldKey, headerId: original.id, messageId: "77",
            subject: "mismatched old-row survivor", from: "Sender",
            to: "queue-core@example.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: MessageIdentity.folderId(
                accountId: fixture.accountId, folderPath: "Trash"))])
        defer { Task { try? await SearchIndex.shared.removeMessages(contentKeys: [oldKey]) } }

        let op = PendingOperation(
            type: .move, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 42)
        let result = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                op, destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationProviderId: "5",
                    destinationUidValidity: 42)],
                addressChangesOnMove: true, accountScopedIds: false, db: db)
        }
        await AccountManager.shared.publishMoveFinish(result)

        #expect(result.applied.isEmpty)
        #expect(result.unsafeUndoOldHeaderIds == [original.id])
        #expect(result.removedOldHeaderIds.isEmpty)
        let survivor = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: original.id)
        }
        #expect(survivor?.folderPath == "Trash")
        #expect(UndoService.shared.undoStack.isEmpty)
        let missing = try await SearchIndex.shared.contentKeysMissingFromFTS([oldKey])
        #expect(missing.isEmpty, "the surviving row's external mirror must not be deleted")
    }

    @Test("discarding one unsafe undo member preserves its safe sibling")
    @MainActor
    func unsafeUndoDiscardIsMemberScoped() throws {
        let fixture = try fixture(accountId: "acc-undo-member-scope")
        defer { finish(fixture) }

        let unsafe = try seedHeader(fixture, messageId: "77", folderPath: "INBOX")
        let safe = try seedHeader(fixture, messageId: "88", folderPath: "INBOX")
        let offered = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [unsafe, safe],
            originalFolderId: unsafe.folderId,
            originalFolderPath: "INBOX",
            accountId: fixture.accountId,
            timestamp: Date())
        UndoService.shared.push(offered)
        defer { UndoService.shared.dismissAll() }

        UndoService.shared.discardMembers(namedByOldHeaderIds: [unsafe.id])

        let action = UndoService.shared.undoStack.last
        #expect(action?.messages.map(\.id) == [safe.id])
        #expect(action?.commands.flatMap(\.members).map(\.originalHeaderId) == [safe.id])
        #expect(action?.id != offered.id, "the altered offer must invalidate a captured Undo button")
        #expect(UndoService.shared.showToast == false)
    }

    @Test("discarding the visible latest action never retargets Undo to its predecessor")
    @MainActor
    func unsafeLatestUndoDoesNotFallThrough() async throws {
        let fixture = try fixture(accountId: "acc-undo-no-fallthrough")
        defer { finish(fixture) }

        let older = try seedHeader(fixture, messageId: "77", folderPath: "INBOX")
        let unsafeLatest = try seedHeader(fixture, messageId: "88", folderPath: "INBOX")
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Trash"),
            messages: [older],
            originalFolderId: older.folderId,
            originalFolderPath: "INBOX",
            accountId: fixture.accountId,
            timestamp: Date()))
        let offeredLatest = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [unsafeLatest],
            originalFolderId: unsafeLatest.folderId,
            originalFolderPath: "INBOX",
            accountId: fixture.accountId,
            timestamp: Date())
        UndoService.shared.push(offeredLatest)
        defer { UndoService.shared.dismissAll() }

        UndoService.shared.discardMembers(namedByOldHeaderIds: [unsafeLatest.id])

        #expect(UndoService.shared.undoStack.count == 1)
        #expect(UndoService.shared.currentAction?.messages.map(\.id) == [older.id])
        #expect(UndoService.shared.showToast == false)

        // This is the exact stale button closure captured before the drain
        // learned that the latest MOVE had no safe destination address.
        await UndoService.shared.undo(expectedActionID: offeredLatest.id)
        #expect(UndoService.shared.undoStack.count == 1)
        #expect(UndoService.shared.currentAction?.messages.map(\.id) == [older.id])
    }

    @Test("Undo consumes the displayed newest action before its queued restore can run")
    @MainActor
    func newestUndoDoesNotRetargetWhileForwardWriteIsQueued() async throws {
        let fixture = try fixture(accountId: "acc-undo-newest-first")
        defer { finish(fixture) }
        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        let older = try seedHeader(fixture, messageId: "77", folderPath: "INBOX")
        let latest = try seedHeader(fixture, messageId: "88", folderPath: "INBOX")
        try await fixture.pool.writeWithoutTransaction { db in
            try MessageHeader.filter(Column("id") == latest.id).updateAll(
                db,
                Column("folderId").set(to: MessageIdentity.folderId(
                    accountId: fixture.accountId, folderPath: "Archive")),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false),
                Column("observedUidValidity").set(to: nil as Int?))
            try PendingOperation(
                type: .move,
                messageIds: [latest.messageId],
                accountId: fixture.accountId,
                folderPath: "INBOX",
                destinationPath: "Archive",
                observedUidValidity: 42).insert(db)
        }

        let olderAction = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Trash"),
            messages: [older], originalFolderId: older.folderId,
            originalFolderPath: "INBOX", accountId: fixture.accountId,
            timestamp: Date())
        let latestAction = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [latest], originalFolderId: latest.folderId,
            originalFolderPath: "INBOX", accountId: fixture.accountId,
            timestamp: Date())
        UndoService.shared.push(olderAction)
        UndoService.shared.push(latestAction)

        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }

        await UndoService.shared.undo(expectedActionID: latestAction.id)

        #expect(UndoService.shared.undoStack.map(\.id) == [olderAction.id])
        #expect(AccountManager.shared.snapshotOverlay()[latest.id]?.folderPath == "INBOX")
        let beforeRelease = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: latest.id), try PendingOperation.fetchAll(db))
        }
        #expect(beforeRelease.0?.folderPath == "Archive")
        #expect(beforeRelease.1.count == 1)

        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        let afterRestore = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: latest.id), try PendingOperation.fetchAll(db))
        }
        #expect(afterRestore.0?.folderPath == "INBOX")
        #expect(afterRestore.1.isEmpty)
        #expect(UndoService.shared.undoStack.map(\.id) == [olderAction.id])
        #expect(AccountManager.shared.snapshotOverlay()[latest.id] == nil)
    }

    @Test("a provider re-key after Undo pops its action updates the queued inverse")
    @MainActor
    func providerRekeyUpdatesPoppedUndoBeforeInverseAdmission() async throws {
        let fixture = try fixture(accountId: "acc-undo-rekey-in-progress")
        defer { finish(fixture) }
        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        let source = try seedHeader(
            fixture, messageId: "77", folderPath: "INBOX", epoch: 42)
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [source], originalFolderId: source.folderId,
            originalFolderPath: "INBOX", accountId: fixture.accountId,
            timestamp: Date()))

        // The forward gesture has committed its optimistic local address, but
        // the provider has not yet published the destination UID.
        _ = try await fixture.pool.writeWithoutTransaction { db in
            try MessageHeader.filter(Column("id") == source.id).updateAll(
                db,
                Column("folderId").set(to: MessageIdentity.folderId(
                    accountId: fixture.accountId, folderPath: "Archive")),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false),
                Column("observedUidValidity").set(to: nil as Int?))
        }

        // Hold the local-write FIFO after Undo pops the action but before its
        // inverse admission reads the command.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        defer { gate.finish() }
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        await UndoService.shared.undo()
        #expect(UndoService.shared.undoStack.isEmpty)

        let forward = PendingOperation(
            type: .move, messageIds: ["77"], accountId: fixture.accountId,
            folderPath: "INBOX", destinationPath: "Archive",
            observedUidValidity: 42)
        let finishResult = try await fixture.pool.write { db in
            try MessageHeaderRekey.finishMove(
                forward,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77",
                    destinationProviderId: "5",
                    destinationUidValidity: 42)],
                addressChangesOnMove: true,
                accountScopedIds: false,
                db: db)
        }
        #expect(finishResult.applied.count == 1)
        UndoService.shared.applyRekeys(finishResult.applied)

        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        let inverse = try await fixture.pool.read { db in
            try PendingOperation.fetchAll(db)
        }
        #expect(inverse.count == 1)
        #expect(inverse.first?.messageIds == ["5"])
        #expect(inverse.first?.folderPath == "Archive")
        #expect(inverse.first?.destinationPath == "INBOX")
    }

    // MARK: - Test-local timings
    //
    // Only the RED direction depends on these being generous enough for a small
    // SQLite write to complete; the GREEN direction is guaranteed by the
    // MainActor hold itself, not by the durations.
    private static let probeDelayMilliseconds = 150
    private static let mainActorHoldMilliseconds = 400
}
