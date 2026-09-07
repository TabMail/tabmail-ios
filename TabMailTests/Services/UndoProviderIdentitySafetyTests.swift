/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

private actor UndoWriteGate {
    private var didEnter = false
    private var didOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !didOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        didOpen = true
        openWaiter?.resume()
        openWaiter = nil
    }
}

// A3.4: `queuedInverseDiagnosticCorrelatesWithTheInsertedRow` below redirects
// `AppLogStore.fileURLOverride` and forces
// `DebugModeManager.loggingEnabledOverrideForTesting` — process-global seams
// (mirrors `AccountManagerQueueDrainTests`/`AppLogStoreTests`) — so the suite
// now also carries `.serialized` alongside the pre-existing `.processGlobalState`.
@Suite("Undo provider identity safety", .serialized, .processGlobalState)
struct UndoProviderIdentitySafetyTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func install(provider: AccountProvider, accountId: String = "undo-provider") throws -> Fixture {
        MessageHeaderRekey.clearAddressHandoffsForTesting()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("undo.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.write { db in
            var account = Account(
                emailAddress: "undo@example.com",
                displayName: "Undo",
                provider: provider
            )
            account.id = accountId
            try account.insert(db)
            var inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId)
            inbox.lastKnownUidValidity = 41
            try inbox.insert(db)
            var archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
            archive.lastKnownUidValidity = 52
            try archive.insert(db)
            var other = Folder(name: "Other", path: "Other", role: .custom, accountId: accountId)
            other.lastKnownUidValidity = 63
            try other.insert(db)
            var trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: accountId)
            trash.lastKnownUidValidity = 74
            try trash.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func uninstall(_ fixture: Fixture) {
        MessageHeaderRekey.clearAddressHandoffsForTesting()
        // See `UndoDestructiveActionTests.uninstall` for the full reasoning.
        // Short version: the old comment named a real hazard (unlinking
        // SQLite/WAL under an open descriptor) and discharged it by leaking —
        // six fresh UUID directories per run of this suite, collected by
        // nothing. The registry closes before it unlinks, which is the ordering
        // the comment was reaching for.
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous,
            pool: fixture.pool,
            directory: fixture.directory)
    }

    private func sourceHeader(
        _ fixture: Fixture,
        providerId: String,
        rfc: String? = nil,
        sourcePath: String = "INBOX",
        sourceEpoch: Int? = 41,
        actionTag: ActionTag? = .reply
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: providerId,
            subject: "Undo \(providerId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "undo@example.com",
            date: Date(),
            snippet: "body",
            folderId: "\(fixture.accountId):\(sourcePath)",
            accountId: fixture.accountId,
            folderPath: sourcePath,
            isInInbox: sourcePath == "INBOX"
        )
        header.rfc822MessageId = rfc
        header.observedUidValidity = sourceEpoch
        header.actionTag = actionTag
        return header
    }

    private func installOptimisticallyMoved(
        _ original: MessageHeader,
        destinationPath: String = "Archive",
        destinationEpoch: Int? = nil,
        pool: DatabasePool
    ) throws {
        try pool.write { db in
            try original.insert(db)
            try MessageHeader.filter(Column("id") == original.id).updateAll(
                db,
                Column("folderId").set(to: "\(original.accountId):\(destinationPath)"),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: false),
                Column("observedUidValidity").set(to: destinationEpoch),
                Column("actionTag").set(to: nil as String?),
                Column("tagSortOrder").set(to: 99)
            )
        }
    }

    @MainActor
    private func insertInFlightMove(
        _ fixture: Fixture,
        messageIds: [String],
        from sourcePath: String,
        to destinationPath: String,
        epoch: Int
    ) async throws -> PendingOperation {
        var operation = PendingOperation(
            type: .move,
            messageIds: messageIds,
            accountId: fixture.accountId,
            folderPath: sourcePath,
            destinationPath: destinationPath,
            observedUidValidity: epoch)
        operation.status = PendingStatus.inFlight.rawValue
        operation.everAttempted = true
        let toInsert = operation
        // `inserted` returns the copy the write allocated a `queuePosition` for,
        // so the value handed back matches the durable row.
        return try await fixture.pool.write { db in try toInsert.inserted(db) }
    }

    @MainActor
    private func finishMove(
        _ fixture: Fixture,
        operation: PendingOperation,
        sourceId: String,
        destinationId: String,
        destinationEpoch: UInt32
    ) async throws -> MoveFinishResult {
        try await fixture.pool.write { db in
            let result = try MessageHeaderRekey.finishMove(
                operation,
                destinations: [ProvenDestinationAddress(
                    sourceProviderId: sourceId,
                    destinationProviderId: destinationId,
                    destinationUidValidity: destinationEpoch)],
                addressChangesOnMove: true,
                // Every fixture in this suite is IMAP (numeric UIDs, a positive
                // `destinationEpoch`), which is the folder-qualified address space.
                accountScopedIds: false,
                db: db)
            _ = try PendingOperation.deleteOne(db, key: operation.id)
            MessageHeaderRekey.publishAddressHandoffsAfterCommit(
                result.applied, in: db)
            return result
        }
    }

    @Test("Undo is immediate while an IMAP move is in flight and waits only for its destination UID")
    @MainActor
    func inFlightImapUndoIsImmediateAndUidSafe() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        let original = sourceHeader(fixture, providerId: "101", rfc: "move@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)
        _ = try await insertInFlightMove(
            fixture, messageIds: ["101"], from: "INBOX", to: "Archive", epoch: 41)

        let manager = AccountManager.shared
        manager.retainOverlayEntry(id: original.id)
        manager.registerMutation(
            id: original.id,
            mutation: .init(
                folderId: original.folderId,
                folderPath: original.folderPath,
                isInInbox: true,
                actionTag: .some(original.actionTag)))
        let restored = await manager.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Archive",
            members: [UndoMember(header: original)])
        manager.releaseOverlayEntry(id: original.id)

        #expect(restored == [original.id])
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1)
        #expect(manager.snapshotOverlay()[original.id]?.folderPath == "INBOX")
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "Archive", "the durable row remains eligible for the forward COPYUID re-key")
        #expect(state.0?.observedUidValidity == nil)
        #expect(state.1.count == 1)
        #expect(state.1.first?.status == PendingStatus.inFlight.rawValue)

        await manager.clearDeferredMoveSuccessorsForTesting()
    }

    @Test("COPYUID turns a deferred Undo into one ordinary inverse with the proven destination address")
    @MainActor
    func copyUidMaterializesDeferredInverse() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        let original = sourceHeader(fixture, providerId: "101", rfc: "move@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["101"], from: "INBOX", to: "Archive", epoch: 41)
        let restored = await AccountManager.shared.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Archive",
            members: [UndoMember(header: original)])
        #expect(restored == [original.id])

        let result = try await finishMove(
            fixture, operation: forward, sourceId: "101",
            destinationId: "901", destinationEpoch: 52)
        await AccountManager.shared.materializeDeferredMoveSuccessors(
            after: forward, result: result)
        await AccountManager.shared.awaitWriteQueueDrain()

        let newHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "901")
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: newHeaderId), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "INBOX", "Undo stays optimistic after the forward re-key")
        #expect(state.0?.observedUidValidity == nil, "destination UID must not be paired with the INBOX epoch")
        #expect(state.1.count == 1)
        guard state.1.count == 1 else { return }
        #expect(state.1[0].messageIds == ["901"])
        #expect(state.1[0].folderPath == "Archive")
        #expect(state.1[0].destinationPath == "INBOX")
        #expect(state.1[0].observedUidValidity == 52)
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[original.id] == nil)
    }

    /// **THE INVARIANT: a deferred move successor registered against a
    /// predecessor that is retired by a NARROWING pass is materialized, so the
    /// user's follow-up gesture is not stranded.**
    ///
    /// Undo behind an in-flight IMAP move is recorded as a process-local
    /// `DeferredMoveSuccessor` instead of a queued operation, because the
    /// inverse's source address does not exist until the forward's `COPYUID`
    /// names it. The only thing that ever turns that record back into a durable
    /// user intention is `materializeDeferredMoveSuccessors`, and the drain has
    /// FOUR sites that retire an operation: whole-op success, the narrowing
    /// pass, and the retained replay of each. A site that commits its retirement
    /// without materializing leaves the successor in `deferredMoveSuccessors`
    /// forever with its overlay entry still retained, and `coalesceDeferredMoves`
    /// then folds every LATER gesture on that message into a successor that will
    /// never run — the user's move silently never happens, which is the
    /// `MIS-IOS-008` / `IOS-QUEUE-008` shape and is not recoverable by a sync.
    ///
    /// This pins the NARROWING site specifically, which is the one that lost the
    /// call in `a270c312a` when the confirmed-gone header cleanup was written
    /// over it. The assertion is on the OUTCOME the user can observe — a durable
    /// inverse operation addressed by the id the wire proved — never on the call
    /// itself, so any future shape that keeps the intention alive still passes.
    ///
    /// RED PROOF (recorded 2026-09-06): with the
    /// `materializeDeferredMoveSuccessors` call removed from
    /// `retirePartiallyCompletedOp`'s success arm, this test fails — the
    /// deferred count is still 1 and the operation table holds only the narrowed
    /// forward move, so no inverse is ever queued.
    ///
    /// REACHABILITY, stated rather than implied: no production provider makes an
    /// IMAP move return a strict subset today (`IMAPProvider.move` dispositions
    /// every member at all of its return sites), and a `DeferredMoveSuccessor`
    /// is only ever registered against an IMAP predecessor — so the narrowing
    /// pass is driven directly here, the same way `QueueCoreInvariantTests`
    /// drives it and the reason `retirePartiallyCompletedOp` is `internal`.
    /// Nothing else in the scenario is a seam: two archives, one whole-command
    /// Undo, and one change of mind are all ordinary production API.
    @Test("A narrowing retirement materializes the deferred inverse its predecessor owes")
    @MainActor
    func narrowedRetirementMaterializesTheDeferredInverseItsPredecessorOwes() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        let proven = sourceHeader(fixture, providerId: "101", rfc: "proven@example.com")
        let owed = sourceHeader(fixture, providerId: "202", rfc: "owed@example.com")
        try installOptimisticallyMoved(proven, pool: fixture.pool)
        try installOptimisticallyMoved(owed, pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["101", "202"], from: "INBOX", to: "Archive", epoch: 41)

        // The user undoes the whole two-message archive while it is still on the
        // wire. Undo is whole-command, so both members become deferred
        // successors behind the same predecessor.
        let restored = await AccountManager.shared.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Archive",
            members: [UndoMember(header: proven), UndoMember(header: owed)])
        #expect(Set(restored) == Set([proven.id, owed.id]))
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 2)

        // ...then changes their mind about the second message and archives it
        // again. Moving back to the predecessor's own destination cancels that
        // successor outright, which leaves exactly ONE inverse still owed — and
        // it belongs to the member the narrowing pass is about to prove, while
        // the member left queued owes nothing.
        _ = await AccountManager.shared.move([owed], to: "Archive")
        #expect(
            await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1,
            "precondition: one deferred inverse is owed, for the member the pass proves")

        // The provider proved ONE of the two members and said nothing about the
        // other, so the drain narrows the row instead of retiring it whole.
        await AccountManager.shared.retirePartiallyCompletedOp(
            forward,
            provenMembers: ["101"],
            remaining: ["202"],
            provenDestinations: [ProvenDestinationAddress(
                sourceProviderId: "101",
                destinationProviderId: "901",
                destinationUidValidity: 52)],
            addressChangesOnMove: true,
            context: AccountOperationExecutor.DrainContext())
        await AccountManager.shared.awaitWriteQueueDrain()

        let ops = try await fixture.pool.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }

        // The unproven member is never dropped — same row, narrowed.
        let narrowed = ops.first { $0.id == forward.id }
        #expect(narrowed?.messageIds == ["202"])
        #expect(narrowed?.status == PendingStatus.queued.rawValue)

        // 🚨 THE PROPERTY. The user's Undo is a durable operation again,
        // addressed by the destination UID the forward's COPYUID proved —
        // not a process-local record waiting on a predecessor that is gone.
        let deferredAfter = await AccountManager.shared.deferredMoveSuccessorCountForTesting()
        let inverse = ops.filter { $0.id != forward.id }
        let opSummary = ops.map { "\($0.type.rawValue)\($0.messageIds)" }.joined(separator: ",")
        #expect(inverse.count == 1, """
            the deferred inverse was stranded by the narrowing retirement: \
            deferredStillWaiting=\(deferredAfter) ops=[\(opSummary)]
            """)
        guard inverse.count == 1 else { return }
        #expect(inverse[0].type == .move)
        #expect(inverse[0].messageIds == ["901"])
        #expect(inverse[0].folderPath == "Archive")
        #expect(inverse[0].destinationPath == "INBOX")
        #expect(inverse[0].observedUidValidity == 52)
        #expect(deferredAfter == 0, "the successor must be settled, not left waiting forever")
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[proven.id] == nil)
    }

    @Test("Delete after an in-flight Delete Undo cancels the deferred move back")
    @MainActor
    func deleteUndoDeleteCancelsDeferredMoveBack() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        let original = sourceHeader(fixture, providerId: "101", rfc: "move@example.com")
        try installOptimisticallyMoved(original, destinationPath: "Trash", pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["101"], from: "INBOX", to: "Trash", epoch: 41)
        _ = await AccountManager.shared.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Trash",
            members: [UndoMember(header: original)])

        let outcome = await AccountManager.shared.move([original], to: "Trash")

        #expect(outcome.admittedIds == [original.id])
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "Trash")
        #expect(state.1.count == 1)
        guard state.1.count == 1 else { return }
        #expect(state.1[0].id == forward.id)
        #expect(state.1[0].status == PendingStatus.inFlight.rawValue)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[original.id] == nil)
    }

    @Test("Delete still cancels an in-flight Undo after COPYUID rekeys first")
    @MainActor
    func deleteUndoDeleteCancelsDeferredMoveBackAfterRekey() async throws {
        let fixture = try install(provider: .imap)
        defer {
            UndoService.shared.dismissAll()
            uninstall(fixture)
        }
        let manager = AccountManager.shared
        await manager.clearDeferredMoveSuccessorsForTesting()
        UndoService.shared.dismissAll()

        let original = sourceHeader(
            fixture, providerId: "111", rfc: "move-after-rekey@example.com")
        try installOptimisticallyMoved(
            original, destinationPath: "Trash", pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["111"], from: "INBOX", to: "Trash", epoch: 41)
        // UndoService publishes the visible source location before asking the
        // manager to cancel/defer provider work. Reproduce that same UI order;
        // the deferred successor takes its own retain below.
        manager.retainOverlayEntry(id: original.id)
        manager.registerMutation(
            id: original.id,
            mutation: .init(
                folderId: original.folderId,
                folderPath: original.folderPath,
                isInInbox: original.isInInbox,
                actionTag: .some(original.actionTag)))
        _ = await manager.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Trash",
            members: [UndoMember(header: original)])
        manager.releaseOverlayEntry(id: original.id)
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1)

        let result = try await finishMove(
            fixture, operation: forward, sourceId: "111",
            destinationId: "911", destinationEpoch: 74)
        let folders = try await fixture.pool.read { db in try Folder.fetchAll(db) }
        let viewModel = InboxViewModel(folders: folders)

        #expect(!viewModel.deleteIsNoOp(original.id),
                "the still-visible Undo overlay must win over the newly re-keyed Trash row")
        #expect(await viewModel.delete(original.id),
                "the second Delete must be recorded rather than ignored")
        await manager.awaitWriteQueueDrain()

        #expect(await manager.deferredMoveSuccessorCountForTesting() == 0,
                "the second Delete must cancel the deferred move-back under its old key")
        await manager.materializeDeferredMoveSuccessors(after: forward, result: result)
        await manager.awaitWriteQueueDrain()

        let trashHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Trash", messageId: "911")
        let settled = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: trashHeaderId),
             try PendingOperation.fetchAll(db))
        }
        #expect(settled.0?.folderPath == "Trash")
        #expect(settled.1.filter { $0.type == .move }.isEmpty,
                "the obsolete move-back must never be materialized after the second Delete")
    }

    @Test("Delete retargets an in-flight Undo and skips the obsolete move back")
    @MainActor
    func deleteRetargetsDeferredUndoBeforeCopyUid() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        let original = sourceHeader(fixture, providerId: "101", rfc: "move@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["101"], from: "INBOX", to: "Archive", epoch: 41)
        _ = await AccountManager.shared.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Archive",
            members: [UndoMember(header: original)])

        let delete = await AccountManager.shared.move([original], to: "Trash")
        #expect(delete.pendingIds == [original.id])
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1)

        let result = try await finishMove(
            fixture, operation: forward, sourceId: "101",
            destinationId: "901", destinationEpoch: 52)
        await AccountManager.shared.materializeDeferredMoveSuccessors(
            after: forward, result: result)
        await AccountManager.shared.awaitWriteQueueDrain()

        let archiveHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Archive", messageId: "901")
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: archiveHeaderId), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "Trash")
        #expect(state.1.count == 1)
        guard state.1.count == 1 else { return }
        #expect(state.1[0].messageIds == ["901"])
        #expect(state.1[0].folderPath == "Archive")
        #expect(state.1[0].destinationPath == "Trash")
        #expect(state.1[0].observedUidValidity == 52)
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
    }

    @Test("A terminal predecessor drops its deferred Undo overlay and leaves reconciliation to sync")
    @MainActor
    func terminalPredecessorDropsDeferredSuccessor() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        let original = sourceHeader(fixture, providerId: "101", rfc: "move@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["101"], from: "INBOX", to: "Archive", epoch: 41)
        _ = await AccountManager.shared.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Archive",
            members: [UndoMember(header: original)])

        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[original.id] == 1)

        await AccountManager.shared.dropDeferredMoveSuccessors(for: forward.id)

        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
        #expect(AccountManager.shared.overlayOpRefCountForTesting()[original.id] == nil)
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "Archive")
        #expect(state.1.first?.id == forward.id)
    }

    @Test("A queued inverse and an immediate opposite gesture annihilate to the provider address")
    @MainActor
    func queuedInverseAndOppositeGestureAnnihilate() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        var row = sourceHeader(
            fixture, providerId: "901", rfc: "move@example.com",
            sourcePath: "Trash", sourceEpoch: nil)
        row.folderId = MessageIdentity.folderId(accountId: fixture.accountId, folderPath: "INBOX")
        row.folderPath = "INBOX"
        row.isInInbox = true
        let insertedRow = row
        try await fixture.pool.write { db in
            try insertedRow.insert(db)
            var moveOp = PendingOperation(
                type: .move,
                messageIds: ["901"],
                accountId: fixture.accountId,
                folderPath: "Trash",
                destinationPath: "INBOX",
                observedUidValidity: 74)
            try moveOp.insert(db)
        }

        let outcome = await AccountManager.shared.move([insertedRow], to: "Trash")

        #expect(outcome.admittedIds == [insertedRow.id])
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: insertedRow.id), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "Trash")
        #expect(state.0?.observedUidValidity == 74)
        #expect(state.1.isEmpty, "the two opposite never-sent moves reduce to no provider work")
    }

    @Test("Delete after a completed Delete Undo waits for the in-flight move-back UID")
    @MainActor
    func deleteAfterCompletedDeleteUndoChainsSafely() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()

        var row = sourceHeader(
            fixture, providerId: "901", rfc: "move@example.com",
            sourcePath: "Trash", sourceEpoch: nil)
        row.folderId = MessageIdentity.folderId(accountId: fixture.accountId, folderPath: "INBOX")
        row.folderPath = "INBOX"
        row.isInInbox = true
        let insertedRow = row
        try await fixture.pool.write { db in try insertedRow.insert(db) }
        let inverse = try await insertInFlightMove(
            fixture, messageIds: ["901"], from: "Trash", to: "INBOX", epoch: 74)

        let admission = await AccountManager.shared.move([insertedRow], to: "Trash")
        #expect(admission.pendingIds == [insertedRow.id])
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1)

        let result = try await finishMove(
            fixture, operation: inverse, sourceId: "901",
            destinationId: "102", destinationEpoch: 41)
        await AccountManager.shared.materializeDeferredMoveSuccessors(
            after: inverse, result: result)
        await AccountManager.shared.awaitWriteQueueDrain()

        let inboxHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "102")
        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: inboxHeaderId), try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.folderPath == "Trash")
        #expect(state.0?.observedUidValidity == nil)
        #expect(state.1.count == 1)
        guard state.1.count == 1 else { return }
        #expect(state.1[0].messageIds == ["102"])
        #expect(state.1[0].folderPath == "INBOX")
        #expect(state.1[0].destinationPath == "Trash")
        #expect(state.1[0].observedUidValidity == 41)
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
    }

    @Test("Undo of a Delete waiting behind move-back cancels that deferred Delete")
    @MainActor
    func undoCancelsDeleteDeferredBehindMoveBack() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let manager = AccountManager.shared
        await manager.clearDeferredMoveSuccessorsForTesting()

        // Exact slow-iCloud shape from logmain.log: the first Undo has already
        // restored the row optimistically to Inbox, while its Trash → Inbox
        // provider move is still in flight and the row still carries Trash's
        // UID/address. A new Delete therefore becomes a deferred successor.
        var row = sourceHeader(
            fixture, providerId: "901", rfc: "move@example.com",
            sourcePath: "Trash", sourceEpoch: nil)
        row.folderId = MessageIdentity.folderId(
            accountId: fixture.accountId, folderPath: "INBOX")
        row.folderPath = "INBOX"
        row.isInInbox = true
        let insertedRow = row
        try await fixture.pool.write { db in try insertedRow.insert(db) }
        let moveBack = try await insertInFlightMove(
            fixture, messageIds: ["901"], from: "Trash", to: "INBOX", epoch: 74)

        let deletion = await manager.move([insertedRow], to: "Trash")
        #expect(deletion.pendingIds == [insertedRow.id])
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1)

        let restored = await manager.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Trash",
            members: [UndoMember(header: insertedRow)])

        #expect(restored == [insertedRow.id])
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 0)
        let beforeProviderFinishes = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: insertedRow.id),
             try PendingOperation.fetchAll(db))
        }
        #expect(beforeProviderFinishes.0?.folderPath == "INBOX")
        #expect(beforeProviderFinishes.1.map(\.id) == [moveBack.id],
                "Undo cancels the waiting Delete; it must not queue a third move")

        // When the already-sent move-back later completes, there is no deferred
        // Delete left to materialize, so the restored message stays restored.
        let result = try await finishMove(
            fixture, operation: moveBack, sourceId: "901",
            destinationId: "102", destinationEpoch: 41)
        await manager.materializeDeferredMoveSuccessors(
            after: moveBack, result: result)
        await manager.awaitWriteQueueDrain()

        let inboxHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "102")
        let settled = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: inboxHeaderId),
             try PendingOperation.fetchAll(db))
        }
        #expect(settled.0?.folderPath == "INBOX")
        #expect(settled.1.isEmpty)
    }

    @Test("Undo after Delete cancels then reinstates an in-flight move-back")
    @MainActor
    func undoAfterDeleteCancelsThenReinstatesMoveBack() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let manager = AccountManager.shared
        await manager.clearDeferredMoveSuccessorsForTesting()

        let original = sourceHeader(
            fixture, providerId: "101", rfc: "move@example.com")
        try installOptimisticallyMoved(
            original, destinationPath: "Trash", pool: fixture.pool)
        let forward = try await insertInFlightMove(
            fixture, messageIds: ["101"], from: "INBOX", to: "Trash", epoch: 41)

        let firstUndo = await manager.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Trash",
            members: [UndoMember(header: original)])
        #expect(firstUndo == [original.id])
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1)

        // Exact slow-iCloud shape: the durable optimistic row is already in
        // Trash and therefore has no Inbox UIDVALIDITY, while the still-live
        // Undo overlay makes the next gesture look like Inbox -> Trash.
        var secondDeleteSnapshot = try #require(await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: original.id)
        })
        secondDeleteSnapshot.folderId = original.folderId
        secondDeleteSnapshot.folderPath = original.folderPath
        secondDeleteSnapshot.isInInbox = original.isInInbox
        secondDeleteSnapshot.actionTag = original.actionTag
        secondDeleteSnapshot.tagSortOrder = original.tagSortOrder
        #expect(secondDeleteSnapshot.observedUidValidity == nil)

        let secondDelete = await manager.move([secondDeleteSnapshot], to: "Trash")
        #expect(secondDelete.admittedIds == [original.id])
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 0)

        let secondUndo = await manager.undoMove(
            accountId: fixture.accountId,
            forwardDestinationPath: "Trash",
            members: [UndoMember(header: secondDeleteSnapshot)])

        #expect(secondUndo == [original.id],
                "Undoing the coalesced Delete must reinstate the deferred move-back")
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1)

        let result = try await finishMove(
            fixture, operation: forward, sourceId: "101",
            destinationId: "901", destinationEpoch: 74)
        await manager.materializeDeferredMoveSuccessors(after: forward, result: result)
        await manager.awaitWriteQueueDrain()

        let trashHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "Trash", messageId: "901")
        let settled = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: trashHeaderId),
             try PendingOperation.fetchAll(db))
        }
        #expect(settled.0?.folderPath == "INBOX")
        #expect(settled.1.count == 1)
        #expect(settled.1.first?.folderPath == "Trash")
        #expect(settled.1.first?.destinationPath == "INBOX")
    }

    @Test("Queued Undo cancels its deferred Delete even when COPYUID rekeys first")
    @MainActor
    func queuedUndoCancellationSurvivesPredecessorRekey() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let manager = AccountManager.shared
        await manager.clearDeferredMoveSuccessorsForTesting()
        UndoService.shared.dismissAll()
        defer { UndoService.shared.dismissAll() }

        var row = sourceHeader(
            fixture, providerId: "901", rfc: "move@example.com",
            sourcePath: "Trash", sourceEpoch: nil)
        row.folderId = MessageIdentity.folderId(
            accountId: fixture.accountId, folderPath: "INBOX")
        row.folderPath = "INBOX"
        row.isInInbox = true
        let insertedRow = row
        try await fixture.pool.write { db in try insertedRow.insert(db) }
        let moveBack = try await insertInFlightMove(
            fixture, messageIds: ["901"], from: "Trash", to: "INBOX", epoch: 74)

        let action = UndoableAction(
            type: .move(fromPath: "INBOX", toPath: "Trash"),
            messages: [insertedRow],
            originalFolderId: insertedRow.folderId,
            originalFolderPath: insertedRow.folderPath,
            accountId: fixture.accountId,
            timestamp: Date())
        UndoService.shared.push(action)
        let deletion = await manager.move([insertedRow], to: "Trash")
        #expect(deletion.pendingIds == [insertedRow.id])
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1)

        // Hold the local FIFO after Undo has popped the action but before its
        // cancellation closure runs. The provider then finishes and rekeys the
        // row, reproducing the ordering captured in logmain.log.
        let gate = UndoWriteGate()
        await manager.enqueueWriteAfterPriorAdmissions { await gate.hold() }
        await gate.waitUntilEntered()
        await UndoService.shared.undo(
            expectedActionID: action.id, source: .programmatic)

        let result = try await finishMove(
            fixture, operation: moveBack, sourceId: "901",
            destinationId: "102", destinationEpoch: 41)
        await manager.publishMoveFinish(result)
        await manager.materializeDeferredMoveSuccessors(
            after: moveBack, result: result)
        await gate.open()
        await manager.awaitWriteQueueDrain()

        let inboxHeaderId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: "INBOX", messageId: "102")
        let settled = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: inboxHeaderId),
             try PendingOperation.fetchAll(db))
        }
        #expect(settled.0?.folderPath == "INBOX")
        #expect(settled.1.isEmpty,
                "the undone deferred Delete must not materialize after the rekey")
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 0)
    }

    @Test("Undo annihilates only an exact never-attempted provider-ID move and restores the exact local member")
    @MainActor
    func exactNeverAttemptedAnnihilation() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "101", rfc: "same@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)
        try await fixture.pool.write { db in
            var moveOp2 = PendingOperation(
                type: .move,
                messageIds: ["101"],
                accountId: fixture.accountId,
                folderPath: "INBOX",
                destinationPath: "Archive",
                observedUidValidity: 41
            )
            try moveOp2.insert(db)
        }

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(result.0?.folderPath == "INBOX")
        #expect(result.0?.observedUidValidity == 41)
        #expect(result.0?.actionTag == .reply)
        #expect(result.1.isEmpty, "an exact unattempted move is physically annihilated")
    }

    @Test("Undo never annihilates an attempted move whose provider outcome may be unknown")
    @MainActor
    func attemptedMoveIsNeverAnnihilated() async throws {
        let fixture = try install(provider: .gmail)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "gmail-201", sourceEpoch: nil)
        try installOptimisticallyMoved(original, pool: fixture.pool)
        try await fixture.pool.write { db in
            var attempted = PendingOperation(
                type: .move, messageIds: [original.messageId], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive"
            )
            attempted.status = PendingStatus.inFlight.rawValue
            try attempted.insert(db)
        }

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let ops = try await fixture.pool.read { try PendingOperation.fetchAll($0) }
        #expect(ops.contains { $0.status == PendingStatus.inFlight.rawValue })
        #expect(ops.contains { $0.status == PendingStatus.queued.rawValue && $0.folderPath == "Archive" })
    }

    @Test("Undo refuses partial-batch, cross-mailbox, and cross-epoch cancellation")
    @MainActor
    func cancellationMustMatchWholeBundle() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let partial = sourceHeader(fixture, providerId: "301", rfc: "partial@example.com")
        let mailbox = sourceHeader(fixture, providerId: "401", rfc: "mailbox@example.com")
        let epoch = sourceHeader(fixture, providerId: "501", rfc: "epoch@example.com", sourceEpoch: 41)
        try installOptimisticallyMoved(partial, pool: fixture.pool)
        try installOptimisticallyMoved(mailbox, pool: fixture.pool)
        try installOptimisticallyMoved(epoch, pool: fixture.pool)
        try await fixture.pool.write { db in
            var moveOp3 = PendingOperation(type: .move, messageIds: ["301", "302"], accountId: fixture.accountId,
                                 folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 41)
            try moveOp3.insert(db)
            var moveOp4 = PendingOperation(type: .move, messageIds: ["401"], accountId: fixture.accountId,
                                 folderPath: "Other", destinationPath: "Archive", observedUidValidity: 63)
            try moveOp4.insert(db)
            var moveOp5 = PendingOperation(type: .move, messageIds: ["501"], accountId: fixture.accountId,
                                 folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 40)
            try moveOp5.insert(db)
        }

        for original in [partial, mailbox, epoch] {
            await AccountManager.shared.undoDestructiveAction(
                [original], accountId: fixture.accountId, originalOpType: .move,
                fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
            )
        }

        let result = try await fixture.pool.read { db -> ([PendingOperation], [MessageHeader]) in
            let headers = try [partial.id, mailbox.id, epoch.id].compactMap { id in
                try MessageHeader.fetchOne(db, key: id)
            }
            return (try PendingOperation.fetchAll(db), headers)
        }
        #expect(result.0.count == 3)
        #expect(result.0.allSatisfy { $0.status == PendingStatus.queued.rawValue })
        #expect(result.1.allSatisfy { $0.folderPath == "Archive" }, "a refused cancellation performs no local restore")
    }

    @Test("Completed stable-provider Undo queues one native-ID inverse without RFC authority")
    @MainActor
    func completedStableProviderUndo() async throws {
        let fixture = try install(provider: .gmail)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "gmail-601", rfc: "shared@example.com", sourceEpoch: nil)
        try installOptimisticallyMoved(original, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(result.0?.folderPath == "INBOX")
        #expect(result.1.count == 1)
        #expect(result.1.first?.messageIds == ["gmail-601"])
        #expect(result.1.first?.messageIds.contains("shared@example.com") == false)
    }

    @Test("Completed IMAP Undo without a proven destination UID and epoch fails closed with zero local or provider mutation")
    @MainActor
    func completedImapWithoutDestinationProofFailsClosed() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "701", rfc: "imap@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(result.0?.folderPath == "Archive")
        #expect(result.0?.observedUidValidity == nil)
        #expect(result.1.isEmpty)
    }

    @Test("Undo after a completed move mutates exactly the moved provider address or nothing")
    @MainActor
    func completedUndoExactAddressOrNothing() async throws {
        let fixture = try install(provider: .outlook)
        defer { uninstall(fixture) }
        let intended = sourceHeader(fixture, providerId: "graph-801", rfc: "duplicate@example.com", sourceEpoch: nil)
        let decoy = sourceHeader(fixture, providerId: "graph-802", rfc: "duplicate@example.com", sourceEpoch: nil, actionTag: .archive)
        try installOptimisticallyMoved(intended, pool: fixture.pool)
        try installOptimisticallyMoved(decoy, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [intended], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (
                try MessageHeader.fetchOne(db, key: intended.id),
                try MessageHeader.fetchOne(db, key: decoy.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(result.0?.folderPath == "INBOX")
        #expect(result.1?.folderPath == "Archive")
        #expect(result.1?.actionTag == nil, "the unrelated destination row stays byte-for-byte locally moved")
        #expect(result.2.count == 1)
        #expect(result.2.first?.messageIds == ["graph-801"])
    }

    // MARK: - A3.4: the `phase=queuedInverse` diagnostic correlates with the durable row

    /// The `.inbox`-channel entry MESSAGES — the `] [INBOX] ` head stripped —
    /// the same shape `AccountManagerQueueDrainTests.queueEntryMessages` uses
    /// for `.queue`. A physical line with no entry head is dropped: nothing
    /// this scenario writes emits a continuation line, and treating one as an
    /// entry would make a field-split depend on text that is not one.
    private static func inboxEntryMessages(in log: String) -> [String] {
        let head = "] [\(AppLogChannel.inbox.tag)] "
        return log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.hasPrefix("["), let range = line.range(of: head) else { return nil }
            return String(line[range.upperBound...])
        }
    }

    /// Every `phase=queuedInverse` line's fields, split on spaces and keyed by
    /// the text before each token's `=` — never string-containment on the
    /// whole rendered sentence, so a wrong `from`/`to`, a mismatched `opId`,
    /// or a re-stamped `createdAt` cannot hide behind a `contains` that a
    /// wrong render would still satisfy.
    private static func queuedInverseFieldSets(in log: String) -> [[String: String]] {
        inboxEntryMessages(in: log).compactMap { line -> [String: String]? in
            let tokens = line.split(separator: " ")
            guard tokens.count > 2,
                  tokens[0] == "[RoleActionTrace]",
                  tokens[1] == "manager.undoMove",
                  tokens[2] == "phase=queuedInverse"
            else { return nil }
            var fields: [String: String] = [:]
            for token in tokens[3...] {
                guard let eq = token.firstIndex(of: "=") else { continue }
                fields[String(token[token.startIndex..<eq])] = String(token[token.index(after: eq)...])
            }
            return fields
        }
    }

    /// GRDB's `.datetime` column stores `Date` as TEXT
    /// `"yyyy-MM-dd HH:mm:ss.SSS"` — millisecond precision
    /// (`GRDB/Core/Support/Foundation/Date.swift`) — so a `PendingOperation`
    /// row fetched AFTER its insert commits has necessarily dropped whatever
    /// sub-millisecond digits `Date()` produced when `inverseOp` was
    /// constructed. Comparing at millisecond granularity is EXACT at the
    /// precision the row can actually persist; a bit-for-bit `Double`
    /// comparison against the pre-round-trip value would fail on entirely
    /// correct code every time "now" does not land on an exact millisecond
    /// boundary — which is effectively always.
    private static let createdAtMillisecondTolerance = 0.001

    @Test("Undo of a completed stable-provider move logs phase=queuedInverse with opId/createdAt correlated to the inserted row, and stays silent when debug logging is locked")
    @MainActor
    func queuedInverseDiagnosticCorrelatesWithTheInsertedRow() async throws {
        let fixture = try install(provider: .gmail)
        defer { uninstall(fixture) }

        // Redirect the shared app log to a private temp file for the duration
        // of this test — a process-global seam (mirrors
        // `AccountManagerQueueDrainTests.drainLaneInstrumentationIsReadableFromTheExportedLog`
        // and `AppLogStoreTests.withTempLog`/`withDebugLogging`). Both
        // overrides are restored unconditionally.
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("undoqueuedinverselog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // ---- Gate OPEN ----------------------------------------------------
        // Same shape as `completedStableProviderUndo`: a Gmail (stable-id,
        // non-IMAP) account with no active queued/in-flight move for this
        // message, so `undoMove` takes the "completed forward, ordinary
        // inverse" branch and reaches `phase=queuedInverse` — never the
        // `annihilate`/`deferBehindInFlight` branches, which log a different
        // phase and insert no row.
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let unlockedProviderId = "gmail-queuedinverse-unlocked"
        let unlockedOriginal = sourceHeader(
            fixture, providerId: unlockedProviderId,
            rfc: "queuedinverse-unlocked@example.com", sourceEpoch: nil)
        try installOptimisticallyMoved(unlockedOriginal, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [unlockedOriginal], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        // Non-vacuity: the fixture really produced a durable inverse row and
        // the optimistic local restoration, so the log assertions below
        // describe a scenario that actually queued something rather than a
        // silently-refused undo.
        let unlockedState = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: unlockedOriginal.id), try PendingOperation.fetchAll(db))
        }
        #expect(unlockedState.0?.folderPath == "INBOX",
                "the optimistic local restoration must be durable, or the log line describes nothing real")
        let unlockedOps = unlockedState.1.filter { $0.messageIds == [unlockedProviderId] }
        #expect(unlockedOps.count == 1,
                "exactly one inverse PendingOperation must have been queued for this scenario")
        guard unlockedOps.count == 1, let inverseRow = unlockedOps.first else { return }
        #expect(inverseRow.folderPath == "Archive")
        #expect(inverseRow.destinationPath == "INBOX")

        let unlockedLog = AppLogStore.read(channel: .inbox)
        let matches = Self.queuedInverseFieldSets(in: unlockedLog).filter {
            $0["providerIds"] == "[\(unlockedProviderId)]"
        }
        #expect(matches.count == 1,
                "exactly one phase=queuedInverse line for this scenario, got \(matches.count):\n\(unlockedLog)")
        guard matches.count == 1, let fields = matches.first else { return }
        #expect(fields["from"] == "Archive")
        #expect(fields["to"] == "INBOX")
        #expect(fields["opId"] == inverseRow.id,
                "opId= must equal the inserted row's id exactly")
        let loggedCreatedAt: Double? = fields["createdAt"].flatMap { Double($0) }
        #expect(loggedCreatedAt != nil,
                "createdAt= did not parse as a Double: \(fields["createdAt"] ?? "<missing>")")
        if let loggedCreatedAt {
            #expect(abs(loggedCreatedAt - inverseRow.createdAt.timeIntervalSince1970) < Self.createdAtMillisecondTolerance,
                    "createdAt=\(loggedCreatedAt) does not correlate with the inserted row's createdAt=\(inverseRow.createdAt.timeIntervalSince1970)")
        }

        // ---- Gate CLOSED (two-sided non-vacuity) ---------------------------
        AppLogStore.clear()
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = false }
        let lockedProviderId = "gmail-queuedinverse-locked"
        let lockedOriginal = sourceHeader(
            fixture, providerId: lockedProviderId,
            rfc: "queuedinverse-locked@example.com", sourceEpoch: nil)
        try installOptimisticallyMoved(lockedOriginal, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [lockedOriginal], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        // Non-vacuity for THIS half: the locked-gate scenario also really
        // queued its own inverse row and restored the header, so the silence
        // below is the gate rather than an undo that never ran.
        let lockedState = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: lockedOriginal.id), try PendingOperation.fetchAll(db))
        }
        #expect(lockedState.0?.folderPath == "INBOX",
                "the locked-gate undo never restored the row — its silence proves nothing")
        let lockedOps = lockedState.1.filter { $0.messageIds == [lockedProviderId] }
        #expect(lockedOps.count == 1,
                "the locked-gate undo never queued its inverse — its silence proves nothing")

        let lockedLog = AppLogStore.read(channel: .inbox)
        #expect(!lockedLog.contains(lockedProviderId),
                "the .inbox channel persisted content for the locked-gate undo: \(lockedLog)")
        #expect(Self.queuedInverseFieldSets(in: lockedLog).isEmpty,
                "a phase=queuedInverse line survived the closed debug gate: \(lockedLog)")
    }

    /// A GRDB `TransactionObserver` that REFUSES the commit of any transaction
    /// which INSERTED a `pendingOperation` row — the standard GRDB way to force
    /// a commit failure: `databaseWillCommit()` throws → SQLite's commit hook
    /// aborts the COMMIT → GRDB rolls the transaction back and rethrows this
    /// very error to `dbPool.write`'s caller. A real production possibility (an
    /// I/O error or a full disk at COMMIT), not a manufactured writer. Keyed on
    /// the inverse's own insert and counting its refusals, so a test can prove
    /// the refusal landed on the undo's write rather than somewhere else
    /// (`MIS-027`: red for the right reason). Modelled on
    /// `SyncEngineFullSyncUpsertDiagnosticTests.HeaderCommitRefuser`.
    private final class InverseCommitRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let sawInverseInsert = Mutex(false)
        let refusals = Mutex(0)

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            guard case .insert(let tableName) = eventKind else { return false }
            return tableName == PendingOperation.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            sawInverseInsert.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawInverseInsert.withLock({ $0 }) else { return }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawInverseInsert.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawInverseInsert.withLock { $0 = false }
        }
    }

    @Test("Undo whose write is refused at COMMIT queues no inverse, restores nothing, and persists NO phase=queuedInverse line")
    @MainActor
    func queuedInverseDiagnosticIsAbsentWhenTheUndoWriteRollsBack() async throws {
        let fixture = try install(provider: .gmail)
        defer { uninstall(fixture) }

        // Same isolated-log seam as the sibling above: the shared app log is
        // redirected at a private temp file and both process-global overrides
        // are restored unconditionally.
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("undoqueuedinverserollbacklog_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }

        // Gate UNLOCKED — the same fixture the sibling uses for its positive
        // case, so the ONLY difference between the two is whether the write
        // committed. With the gate closed this test could not tell a rolled-back
        // emission from a gated one.
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        let providerId = "gmail-queuedinverse-rollback"
        let original = sourceHeader(
            fixture, providerId: providerId,
            rfc: "queuedinverse-rollback@example.com", sourceEpoch: nil)
        try installOptimisticallyMoved(original, pool: fixture.pool)

        // Installed AFTER the fixture seeding, so the only
        // `pendingOperation`-inserting transaction it can refuse is the undo's
        // own write, and removed immediately after so the assertions below read
        // an unobstructed database.
        let refuser = InverseCommitRefuser()
        fixture.pool.add(transactionObserver: refuser, extent: .databaseLifetime)
        let restored = await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )
        fixture.pool.remove(transactionObserver: refuser)

        // Non-vacuity: the undo really reached its inverse insert and the COMMIT
        // of that very transaction was refused, exactly once. Without this the
        // silence below could be an undo that was refused before it ever wrote.
        #expect(refuser.refusals.withLock { $0 } == 1,
                "the refusal must land on the undo's own write, exactly once")

        // THE PROPERTY, on the results the API actually exposes. `undoMove` does
        // not throw: it catches the write failure and reports it by restoring
        // nothing, so an empty return IS the surfaced failure.
        #expect(restored.isEmpty,
                "a refused undo write must restore nothing, got \(restored)")

        let state = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(state.1.isEmpty,
                "a refused commit must leave no durable inverse operation, got \(state.1.map(\.id))")
        // The header still sits at its pre-undo address — the rollback took the
        // optimistic restoration with it.
        #expect(state.0?.folderPath == "Archive")
        #expect(state.0?.folderId == "\(fixture.accountId):Archive")
        #expect(state.0?.isInInbox == false)

        // … and the diagnostic named none of it. `AppLogStore.append` enqueues
        // file I/O on an independent queue that no SQLite ROLLBACK retracts, so
        // a line emitted from inside the write would still be here — naming an
        // operation that never became durable.
        let log = AppLogStore.read(channel: .inbox)
        #expect(Self.queuedInverseFieldSets(in: log).isEmpty,
                "a phase=queuedInverse line survived a rolled-back undo write: \(log)")
    }
}
