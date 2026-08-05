/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
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

    @Test("a permanently evidence-refused op on (INBOX, 77) does not starve an unrelated message at (Archive, 77)")
    func laneHaltInOneFolderDoesNotStarveTheSameUidInAnother() async throws {
        let fixture = try fixture(accountId: "acc-queue-001-bystander")
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
            provenDestinations: [], context: AccountManager.DrainContext())

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

    // MARK: - IOS-UNDO-002 / IOS-SEARCH-002 — publishing a committed re-key
    //
    // Both rows are about the window AFTER the GRDB write commits, when the two
    // stores that key by `messageHeader.id` but do not live in that database —
    // the in-memory undo stack and the FTS index — are brought up to date.

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
    /// RED PROOF (recorded): with `publishRekeys`' two calls swapped back, the
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
        UndoService.shared.push(UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Archive"),
            messages: [moved],
            originalFolderId: moved.folderId,
            originalFolderPath: "INBOX",
            accountId: fixture.accountId,
            timestamp: Date()))
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
            await AccountManager.shared.publishRekeys([record], collidedOldHeaderIds: [])
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
        #expect(stackMember?.originalHeaderId == newHeaderId)
        #expect(stackMember?.providerMessageId == "5")
        let missingAfter = try await SearchIndex.shared.contentKeysMissingFromFTS([oldKey])
        #expect(missingAfter == [oldKey], "the FTS entry moved off the old key")
    }

    /// `IOS-SEARCH-002`. `MessageHeaderRekey.apply` deletes the old header and
    /// its body BEFORE the collision guard — deliberately, so the leg that
    /// skips the re-insert cannot leave a duplicate — and then returns false.
    /// The drain published only the APPLIED re-keys, so the old id's FTS entry
    /// survived with no header behind it: the *indexed but unfindable* class,
    /// at a composite id a later message can re-occupy.
    ///
    /// RED PROOF (recorded): with the `removeMessages` call deleted from
    /// `publishRekeys`, `collidedRekeyLeavesNoFtsEntryWithoutAHeader` fails —
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
        let outcome = try await fixture.pool.write { db -> (applied: [HeaderRekeyRecord], collided: [String]) in
            var collided: [String] = []
            let applied = try MessageHeaderRekey.finishMove(
                op, destinations: [ProvenDestinationAddress(
                    sourceProviderId: "77", destinationProviderId: "5", destinationUidValidity: 42)],
                db: db, onCollidedRekey: { collided.append($0) })
            return (applied, collided)
        }
        await AccountManager.shared.publishRekeys(
            outcome.applied, collidedOldHeaderIds: outcome.collided)

        // NON-VACUITY: the collision leg is the one that actually ran.
        #expect(outcome.applied.isEmpty)
        #expect(outcome.collided == [oldHeaderId])

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

    // MARK: - Test-local timings
    //
    // Only the RED direction depends on these being generous enough for a small
    // SQLite write to complete; the GREEN direction is guaranteed by the
    // MainActor hold itself, not by the durations.
    private static let probeDelayMilliseconds = 150
    private static let mainActorHoldMilliseconds = 400
}
