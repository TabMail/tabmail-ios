/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

// MARK: - Undo of a destructive move — real-path pins

/// 🚨 THIS FILE WAS A BLESSING-TEST CLUSTER AND HAS BEEN RE-SCOPED (2026-08-03).
///
/// Every test here except the two `MessageHeader.stableId` characterizations
/// used to build a `TestDatabase.make()` queue — which is **never installed into
/// `AppDatabase.shared`** — and then hand-simulate `undoDestructiveAction`'s
/// algorithm inside the test body, asserting on its own copy. Not one of them
/// called production. The provider tests literally copied production's
/// `provider == .imap || provider == .icloud` branch into the test, so they
/// could only ever agree with themselves.
///
/// The same cluster was found and repaired on the sibling branch `v2final`
/// (`PLAN_UNDO_IDENTITY.md` §5, round 51), where the measurement was recorded:
/// inverting `providerRekeysIds` in production turned **35 real end-to-end pins
/// red and left all three old provider tests GREEN**. `v2final` reduced this
/// file to the two `stableId` tests alone. v3 keeps the file but rebuilds it as
/// a real-path suite, because v3 has invariants worth pinning here that no other
/// suite covers.
///
/// TWO THINGS HAD ROTTED INTO PINNING BEHAVIOUR v3 DELIBERATELY REMOVED, and
/// both are now inverted rather than deleted:
///  - the IMAP/iCloud move-back recorded the **rfc822 Message-ID**. That is the
///    banned mechanism (ADR-IOS-068 / D4, `IOS-IMAP-002`): a `SEARCH` by
///    Message-ID returns every copy sharing it and mutates all of them.
///  - `save()` **re-created a row the drain had deleted**. v3 forbids
///    resurrection outright (ADR-IOS-059): a vanished row is a whole-command
///    refusal with no upsert fallback.
///
/// RE-SCOPED AGAINST THE POST-O2 INVARIANT (`59423bb7d`, `f7c3354c5`), not the
/// pre-O2 one. Undo of a drained IMAP move is no longer a refusal — it is AN
/// ORDINARY REVERSE MOVE. The drain finishes the move locally
/// (`MessageHeaderRekey.finishMove` re-keys the row to the destination address
/// `COPYUID` proved), `UndoService.applyRekeys` points the stacked members at
/// that address, and `undoMove` admits the inverse through
/// `admittedOrdinaryActionTargets` — the same predicate as any forward gesture.
/// Pinning the pre-O2 "IMAP always refuses" behaviour would have manufactured a
/// second generation of blessing tests.
///
/// PRIOR DISPLAY NAMES, all recorded (old suite → old test → disposition):
///  - "UndoDestructiveAction — Cancel Queued Ops"
///    · "Cancels queued archive op — no move-back needed" → DELETED. Its claim
///      (a never-attempted exact queued move is annihilated and the row
///      restored) is pinned on the real path by
///      `UndoProviderIdentitySafetyTests.exactNeverAttemptedAnnihilation`. Its
///      own assertion — `status == .cancelled` — was already wrong for v3, which
///      DELETES the operation rather than leaving a cancelled tombstone. The
///      *unpinned* half of that guard, `!everAttempted`, is now
///      `aRequeuedMoveThatWasAlreadyAttemptedIsNeverAnnihilated`.
///    · "Cancels associated removeTag ops when undoing archive" → RE-SCOPED to
///      `undoLeavesTagOperationsQueuedBesideTheMoveUntouched`. v3 SUBTRACTED
///      removeTag cancellation from undo (`undoDestructiveAction`'s own comment
///      says so), and tags are local-only (ADR-IOS-036).
///  - "UndoDestructiveAction — Move-Back When Already Executed"
///    · "Queues move-back when original op is already in-flight" → DELETED;
///      pinned on the real path by
///      `UndoProviderIdentitySafetyTests.attemptedMoveIsNeverAnnihilated`.
///    · "IMAP move-back uses rfc822MessageId instead of UID" → INVERTED into
///      `theImapInverseNamesTheDestinationUidAndNeverTheRfc822MessageId`.
///    · "Gmail move-back uses stable messageId" → DELETED; pinned on the real
///      path by `UndoProviderIdentitySafetyTests.completedStableProviderUndo`,
///      which additionally asserts the rfc822 id is absent.
///    · "iCloud move-back uses rfc822MessageId like IMAP" → INVERTED into
///      `theIcloudInverseNamesTheDestinationUidAndNeverTheRfc822MessageId`.
///  - "UndoDestructiveAction — Save/Upsert Pattern"
///    · "Upsert restores message when row still exists" → RE-SCOPED to
///      `undoRestoresOnlyTheFieldsItCapturedAndPreservesTheRest`.
///    · "Upsert re-creates message when drain cleanup deleted the row" →
///      INVERTED into
///      `undoOfAVanishedRowRefusesTheWholeCommandAndResurrectsNothing`.
///  - "UndoDestructiveAction — StableId Matching"
///    · "Matches queued ops by stableId (rfc822MessageId) when numeric UID
///      differs" → INVERTED into
///      `undoMatchesItsForwardOperationByProviderAddressNeverByRfc822MessageId`.
///    · "stableId returns rfc822MessageId for numeric UIDs" → KEPT verbatim; it
///      always called production (`MessageHeader.stableId`).
///    · "stableId returns messageId for non-numeric IDs (Gmail)" → KEPT verbatim.
///  - "UndoDestructiveAction — Optimistic Move"
///    · "Optimistic move skips self-move (source == destination)" → DELETED; the
///      guard is `optimisticMoveToFolder`'s, not undo's, and is pinned on the
///      real path by `AccountManagerActionsTests.selfMoveNoOp`,
///      `DrainQueueIntegrationTests.selfMoveNoOp` and `SameFolderNoOpTests`.
///    · "Tag removal queued before move when leaving inbox" → DELETED; v3 does
///      NOT queue a `.removeTag` operation. ADR-IOS-036 made tags local-only, so
///      leaving the inbox clears `actionTag` in the SAME write as the folder
///      move. Pinned on the real path by `CoordinatedToolActionTests` (F6:
///      "actionTag clears locally in the same write that leaves the inbox",
///      "tagSortOrder resets to the sweepStaleActionTags sentinel").
///
/// ONE TEST IS NEW: `aPartlyAdmissibleImapUndoRefusesTheWholeCommand`, pinning
/// `undoMove`'s `admission.messages.count == currentRows.count` guard. A
/// partly-reversed move is worse than an unreversed one, because the user cannot
/// see which half moved.
///
/// FIXTURE NOTE — test-infra hazard #2 (`PLAN_UNDO_IDENTITY.md` §7):
/// `AccountManager.shared`'s connected `providers` map OUTLIVES a suite and
/// `drainPendingQueue` claims any op whose account has a provider, so a sibling
/// suite's provider can drain this suite's queued ops. Every fixture here uses a
/// unique account id and no provider is ever registered for it.
@Suite("Undo of a destructive move — real path", .processGlobalState)
struct UndoDestructiveActionTests {

    // MARK: - Fixture

    private struct Fixture {
        let pool: DatabasePool
        let previous: AppDatabase?
        let accountId: String
    }

    /// INBOX epoch 41, Archive epoch 202. The two differ deliberately: a test
    /// that admitted against the wrong folder's epoch would fail rather than
    /// pass for the wrong reason.
    private static let sourceEpoch = 41
    private static let destinationEpoch = 202

    @MainActor
    private func install(provider: AccountProvider) throws -> Fixture {
        let accountId = "acc-undo-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("undo.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.write { db in
            var account = Account(
                emailAddress: "undo@example.com", displayName: "Undo", provider: provider)
            account.id = accountId
            try account.insert(db)
            var inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId)
            inbox.lastKnownUidValidity = Self.sourceEpoch
            try inbox.insert(db)
            var archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
            archive.lastKnownUidValidity = Self.destinationEpoch
            try archive.insert(db)
        }
        return Fixture(pool: pool, previous: previous, accountId: accountId)
    }

    @MainActor
    private func uninstall(_ fixture: Fixture) {
        AppDatabase.shared.withLock { $0 = fixture.previous }
        // The fixture still owns an open DatabasePool until the test returns.
        // Leave its unique temp directory for the OS sweep rather than unlinking
        // SQLite/WAL files under an open descriptor.
    }

    /// The row exactly as the drain leaves it after `MessageHeaderRekey`
    /// finishes the move: primary key and `messageId` re-keyed to the
    /// destination UID `COPYUID` proved, stamped with the destination folder's
    /// epoch. Returns the STACKED UNDO MEMBER's snapshot — source fields
    /// describing INBOX, address fields following the re-key, which is precisely
    /// what `UndoService.applyRekeys` produces.
    ///
    /// `destinationEpoch: nil` models a member `COPYUID` never named: the drain
    /// could not re-key it, so it still sits at the destination folder with no
    /// proven address and admission must refuse it.
    @discardableResult
    private func seedDrainedMove(
        _ fixture: Fixture,
        destinationUid: String,
        rfc822: String? = nil,
        destinationEpoch: Int? = Self.destinationEpoch,
        sourceActionTag: ActionTag? = .reply,
        isRead: Bool = false,
        isFlagged: Bool = false
    ) throws -> MessageHeader {
        let destinationId = "\(fixture.accountId):Archive:\(destinationUid)"
        try fixture.pool.write { db in
            var row = MessageHeader(
                messageId: destinationUid, subject: "undo \(destinationUid)", from: "Sender",
                fromAddress: "sender@example.com", to: "undo@example.com", date: Date(),
                snippet: "body", folderId: "\(fixture.accountId):Archive",
                accountId: fixture.accountId, folderPath: "Archive", isInInbox: false)
            row.id = destinationId
            row.rfc822MessageId = rfc822
            row.observedUidValidity = destinationEpoch
            row.isRead = isRead
            row.isFlagged = isFlagged
            row.tagSortOrder = 99
            try row.insert(db)
        }
        // The stacked member: `UndoMember.init(header:)` reads the SOURCE fields
        // off this snapshot and the ADDRESS fields off `id`/`messageId`.
        var member = MessageHeader(
            messageId: destinationUid, subject: "undo \(destinationUid)", from: "Sender",
            fromAddress: "sender@example.com", to: "undo@example.com", date: Date(),
            snippet: "body", folderId: "\(fixture.accountId):INBOX",
            accountId: fixture.accountId, folderPath: "INBOX", isInInbox: true)
        member.id = destinationId
        member.rfc822MessageId = rfc822
        member.observedUidValidity = Self.sourceEpoch
        member.actionTag = sourceActionTag
        member.tagSortOrder = sourceActionTag?.sortOrder ?? 99
        return member
    }

    @MainActor
    private func undo(_ fixture: Fixture, _ members: [MessageHeader]) async {
        await AccountManager.shared.undoDestructiveAction(
            members, accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX",
            toFolderId: "\(fixture.accountId):INBOX")
    }

    @MainActor
    private func operations(_ fixture: Fixture) async throws -> [PendingOperation] {
        try await fixture.pool.read { try PendingOperation.fetchAll($0) }
    }

    @MainActor
    private func row(_ fixture: Fixture, id: String) async throws -> MessageHeader? {
        try await fixture.pool.read { try MessageHeader.fetchOne($0, key: id) }
    }

    // MARK: - Annihilation

    /// PRIOR DISPLAY NAME: *"Cancels queued archive op — no move-back needed"*
    /// (suite "UndoDestructiveAction — Cancel Queued Ops"). That test asserted
    /// the forward op ends `.cancelled`; v3 DELETES it, and the deletion is
    /// already pinned on the real path by
    /// `UndoProviderIdentitySafetyTests.exactNeverAttemptedAnnihilation`.
    ///
    /// INVARIANT PINNED HERE INSTEAD — the leg of that guard nothing covered.
    /// Annihilation is exit 3 of the four never-drop exits and it requires the
    /// earlier operation to have been **never attempted**. `everAttempted` is a
    /// durable one-way flag: an op that failed and was requeued still reads
    /// `.queued`, but it may already have reached the server. Annihilating it
    /// would retire a user intention whose forward half may have landed on the
    /// provider, leaving the local row in INBOX and the mail in Archive forever.
    ///
    /// So the forward operation SURVIVES and the move is reversed the ordinary
    /// way — a queued inverse — which is correct whichever way the attempt went.
    /// The payload here is exact in every other respect, so a guard that dropped
    /// the `!everAttempted` clause would delete this operation and queue nothing.
    @Test("A requeued move that was already attempted is never annihilated")
    @MainActor
    func aRequeuedMoveThatWasAlreadyAttemptedIsNeverAnnihilated() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let member = try seedDrainedMove(fixture, destinationUid: "205")
        try await fixture.pool.write { db in
            // Payload-exact and `.queued` — everything the annihilation guard
            // wants EXCEPT `everAttempted`.
            var attemptedOnce = PendingOperation(
                type: .move, messageIds: ["205"], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive",
                observedUidValidity: Self.sourceEpoch)
            attemptedOnce.everAttempted = true
            attemptedOnce.retryCount = 1
            try attemptedOnce.insert(db)
        }

        await undo(fixture, [member])

        let ops = try await operations(fixture)
        #expect(
            ops.contains { $0.everAttempted && $0.destinationPath == "Archive" },
            "the attempted forward op survives — it may already have reached the server")
        #expect(
            ops.contains { $0.messageIds == ["205"] && $0.destinationPath == "INBOX" },
            "and the move is reversed the ordinary way instead")
        #expect(ops.count == 2)
        let restored = try #require(try await row(fixture, id: member.id))
        #expect(restored.folderPath == "INBOX")
    }

    /// PRIOR DISPLAY NAME: *"Cancels associated removeTag ops when undoing
    /// archive"* (suite "UndoDestructiveAction — Cancel Queued Ops").
    ///
    /// RE-SCOPED BECAUSE v3 REMOVED THE BEHAVIOUR IT PINNED. `undoDestructiveAction`
    /// states it outright — *"SUBTRACT — archive/delete compatibility rows and
    /// removeTag cancellation"* — and `undoMove` filters `activeMoves` on
    /// `type == .move` alone. Tags are local-only (ADR-IOS-036), so there is no
    /// server-side keyword an undo would need to un-remove.
    ///
    /// INVARIANT: undo's cancellation reaches EXACTLY the move it reverses. A
    /// tag operation queued for the same message is a separate user intention
    /// and must survive untouched — cancelling it would be a dropped intention.
    @Test("Undo leaves tag operations queued beside the move untouched")
    @MainActor
    func undoLeavesTagOperationsQueuedBesideTheMoveUntouched() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let member = try seedDrainedMove(fixture, destinationUid: "205")
        try await fixture.pool.write { db in
            try PendingOperation(
                type: .setTag, messageIds: ["205"], accountId: fixture.accountId,
                folderPath: "Archive", tagValue: ActionTag.reply.rawValue).insert(db)
            try PendingOperation(
                type: .move, messageIds: ["205"], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive",
                observedUidValidity: Self.sourceEpoch).insert(db)
        }

        await undo(fixture, [member])

        let ops = try await operations(fixture)
        #expect(ops.count == 1, "the move annihilates; nothing else is touched")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .setTag)
        #expect(ops[0].status == PendingStatus.queued.rawValue)
        #expect(ops[0].tagValue == ActionTag.reply.rawValue)
    }

    // MARK: - The queued inverse names the destination address

    /// PRIOR DISPLAY NAME: *"IMAP move-back uses rfc822MessageId instead of
    /// UID"* (suite "UndoDestructiveAction — Move-Back When Already Executed"),
    /// whose assertion carried the message *"IMAP undo still records its
    /// historical RFC identity pending T2.9 native re-keying"*.
    ///
    /// INVERTED. That is the BANNED mechanism: naming a message by its rfc822
    /// Message-ID means resolving it with `SEARCH HEADER Message-ID`, which
    /// returns EVERY copy sharing the id and mutates all of them (ADR-IOS-068 /
    /// D4, registered as `IOS-IMAP-002`).
    ///
    /// INVARIANT: the inverse an undo queues names the message at the address
    /// the move gave it — the destination UID `COPYUID` proved, carried with the
    /// destination folder's epoch — and the rfc822 Message-ID appears nowhere in
    /// the operation. The system property is that the operation addresses the
    /// one message the gesture selected; the rfc822 assertion is the negative
    /// half that makes the pin discriminating, since the row deliberately HAS an
    /// rfc822 id a resolver could have reached for.
    @Test("The IMAP inverse names the destination UID and never the rfc822 Message-ID")
    @MainActor
    func theImapInverseNamesTheDestinationUidAndNeverTheRfc822MessageId() async throws {
        try await assertInverseNamesDestinationAddress(provider: .imap, uid: "205")
    }

    /// PRIOR DISPLAY NAME: *"iCloud move-back uses rfc822MessageId like IMAP"*
    /// (suite "UndoDestructiveAction — Move-Back When Already Executed").
    ///
    /// INVERTED for the same reason as its IMAP sibling. iCloud is IMAP as far
    /// as identity is concerned — `undoMove`'s `isIMAP` is
    /// `provider == .imap || provider == .icloud` — and this is the only pin on
    /// v3 that exercises the `.icloud` arm of that disjunction, so a regression
    /// that narrowed it to `.imap` alone would otherwise pass everything.
    @Test("The iCloud inverse names the destination UID and never the rfc822 Message-ID")
    @MainActor
    func theIcloudInverseNamesTheDestinationUidAndNeverTheRfc822MessageId() async throws {
        try await assertInverseNamesDestinationAddress(provider: .icloud, uid: "307")
    }

    @MainActor
    private func assertInverseNamesDestinationAddress(
        provider: AccountProvider, uid: String
    ) async throws {
        let fixture = try install(provider: provider)
        defer { uninstall(fixture) }
        let rfc = "unique-\(uid)@example.com"
        let member = try seedDrainedMove(fixture, destinationUid: uid, rfc822: rfc)

        await undo(fixture, [member])

        let ops = try await operations(fixture)
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == "Archive")
        #expect(ops[0].destinationPath == "INBOX")
        #expect(ops[0].messageIds == [uid], "the inverse names the destination address")
        #expect(
            ops[0].observedUidValidity == Self.destinationEpoch,
            "and carries the epoch of the folder it will be issued against")
        #expect(
            ops[0].messageIds.contains(rfc) == false,
            "the rfc822 Message-ID is never a mutation target (ADR-IOS-068 / D4)")
        let restored = try #require(try await row(fixture, id: member.id))
        #expect(restored.folderPath == "INBOX", "the row moves back for display immediately")
    }

    /// PRIOR DISPLAY NAME: *"Matches queued ops by stableId (rfc822MessageId)
    /// when numeric UID differs"* (suite "UndoDestructiveAction — StableId
    /// Matching").
    ///
    /// INVERTED. `MessageHeader.stableId` falls back to the rfc822 Message-ID
    /// for numeric UIDs, and matching an operation by it is the same banned
    /// identity as above wearing a different name. `undoMove` intersects on
    /// `providerMessageId` alone.
    ///
    /// INVARIANT: an operation that names a message by an identity v3 does not
    /// use is NOT this gesture's forward operation. It is neither annihilated
    /// nor cancelled — it is left exactly where it is — and the undo proceeds as
    /// though no forward operation existed, queueing an inverse against the
    /// address it can prove. Treating the rfc-named row as a match would delete
    /// a user intention on the strength of an identity that can name several
    /// messages at once.
    @Test("Undo matches its forward operation by provider address, never by rfc822 Message-ID")
    @MainActor
    func undoMatchesItsForwardOperationByProviderAddressNeverByRfc822MessageId() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let rfc = "legacy-shape@example.com"
        let member = try seedDrainedMove(fixture, destinationUid: "205", rfc822: rfc)
        try await fixture.pool.write { db in
            // The pre-ADR-IOS-068 shape: an op naming the message by its rfc822
            // Message-ID. Payload-exact in every other respect, so a match on
            // stableId would annihilate it.
            try PendingOperation(
                type: .move, messageIds: [rfc], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive",
                observedUidValidity: Self.sourceEpoch).insert(db)
        }

        await undo(fixture, [member])

        let ops = try await operations(fixture)
        #expect(ops.count == 2, "the rfc-named op survives and an inverse is added")
        #expect(
            ops.contains { $0.messageIds == [rfc] && $0.status == PendingStatus.queued.rawValue },
            "an rfc822-named operation is never matched, cancelled or annihilated")
        #expect(
            ops.contains { $0.messageIds == ["205"] && $0.destinationPath == "INBOX" },
            "the inverse is queued against the address undo can actually prove")
    }

    // MARK: - What the restore may and may not write

    /// PRIOR DISPLAY NAME: *"Upsert restores message when row still exists"*
    /// (suite "UndoDestructiveAction — Save/Upsert Pattern"). That test wrote
    /// `restored.save(db)` in the test body and asserted the folder changed —
    /// it characterised GRDB's upsert, not undo.
    ///
    /// INVARIANT: undo restores exactly the fields it captured and preserves
    /// every other field's CURRENT value. `undoMove` says so — *"Preserve every
    /// unrelated field (notably current read/flag state); never `save` a stale
    /// snapshot"* — and it matters because read and flag state can change after
    /// the move: the user reads the message in Archive, then undoes the archive.
    /// A `save()` of the captured snapshot would silently roll that back, which
    /// is a lost user action.
    ///
    /// DISCRIMINATING: the row is read and flagged AFTER the move while the
    /// stacked member still says unread and unflagged, so a snapshot-shaped
    /// restore fails here rather than passing for the wrong reason.
    @Test("Undo restores only the fields it captured and preserves the rest")
    @MainActor
    func undoRestoresOnlyTheFieldsItCapturedAndPreservesTheRest() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        // Row: read and flagged in Archive. Member snapshot: unread, unflagged,
        // tagged `.reply`, sourced from INBOX.
        let member = try seedDrainedMove(
            fixture, destinationUid: "205", sourceActionTag: .reply,
            isRead: true, isFlagged: true)

        await undo(fixture, [member])

        let restored = try #require(try await row(fixture, id: member.id))
        #expect(restored.folderPath == "INBOX", "the captured source folder is restored")
        #expect(restored.isInInbox)
        #expect(restored.actionTag == .reply, "the captured tag is restored")
        #expect(restored.tagSortOrder == ActionTag.reply.sortOrder)
        #expect(restored.isRead, "read state changed after the move and is NOT rolled back")
        #expect(restored.isFlagged, "flag state changed after the move and is NOT rolled back")
    }

    /// PRIOR DISPLAY NAME: *"Upsert re-creates message when drain cleanup
    /// deleted the row"* (suite "UndoDestructiveAction — Save/Upsert Pattern"),
    /// asserting *"save() should re-create the deleted row"*.
    ///
    /// INVERTED. v3 forbids resurrection (ADR-IOS-059): `undoMove` authenticates
    /// every exact local member first and states *"A vanished/re-keyed row is a
    /// whole-command refusal; there is no upsert/resurrection fallback"*.
    /// Re-creating a row from a stale snapshot re-seats a message at an address
    /// nothing has proven it still occupies.
    ///
    /// INVARIANT, both halves: the vanished row stays vanished, AND its
    /// still-present sibling in the same command is not restored either. Undo is
    /// whole-command; a partly-reversed move is worse than an unreversed one
    /// because the user cannot see which half moved.
    @Test("Undo of a vanished row refuses the whole command and resurrects nothing")
    @MainActor
    func undoOfAVanishedRowRefusesTheWholeCommandAndResurrectsNothing() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let present = try seedDrainedMove(fixture, destinationUid: "205")
        let vanished = try seedDrainedMove(fixture, destinationUid: "206")
        try await fixture.pool.write { db in
            _ = try MessageHeader.deleteOne(db, key: vanished.id)
        }

        await undo(fixture, [present, vanished])

        let resurrected = try await row(fixture, id: vanished.id)
        #expect(resurrected == nil, "a deleted row is never re-created from a stale snapshot")
        let sibling = try #require(try await row(fixture, id: present.id))
        #expect(
            sibling.folderPath == "Archive",
            "and its sibling is not restored either — the command refuses whole")
        let ops = try await operations(fixture)
        #expect(ops.isEmpty, "with no durable mutation")
    }

    /// NEW PIN (no prior test). `undoMove` requires
    /// `admission.messages.count == currentRows.count` before queueing the
    /// inverse. Nothing pinned that equality, and dropping it is not a compile
    /// error — the operation would simply be queued for the admissible subset.
    ///
    /// INVARIANT: an IMAP undo is admitted whole or not at all. A member
    /// `COPYUID` never named was not re-keyed, so its row still carries no
    /// proven destination address; admission refuses it, and the whole command
    /// therefore refuses rather than half-reversing the move. Its row is
    /// repaired later by sync — nothing is lost, because the destination copy
    /// exists and the source copy is `\Deleted`-but-present.
    @Test("A partly admissible IMAP undo refuses the whole command")
    @MainActor
    func aPartlyAdmissibleImapUndoRefusesTheWholeCommand() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let rekeyed = try seedDrainedMove(fixture, destinationUid: "205")
        // COPYUID never named this member, so the drain left it unproven.
        let unproven = try seedDrainedMove(
            fixture, destinationUid: "206", destinationEpoch: nil)

        await undo(fixture, [rekeyed, unproven])

        let ops = try await operations(fixture)
        #expect(ops.isEmpty, "no partial inverse is queued")
        let a = try #require(try await row(fixture, id: rekeyed.id))
        let b = try #require(try await row(fixture, id: unproven.id))
        #expect(a.folderPath == "Archive", "the admissible member is not moved back alone")
        #expect(b.folderPath == "Archive")
    }

    // MARK: - C3 — the undo stack must name the MESSAGE, not just the address

    /// NEW PIN (no prior test). Every predicate `undoMove` authenticated a member
    /// with described the ADDRESS — primary key, `messageId`, `folderPath`,
    /// `folderId`, and the folder epoch consulted inside
    /// `admittedOrdinaryActionTargets`. On IMAP the address is a per-folder UID
    /// the server reassigns at a UIDVALIDITY turnover, and the reset reaction
    /// purges the folder and resyncs it — so a DIFFERENT physical message can
    /// come to occupy this exact composite id while the in-memory undo stack,
    /// which the reaction does not touch, still names it. The impostor's epoch is
    /// the FRESH one, so the epoch guard passes on it too.
    ///
    /// The fixture is deliberately minimal: the row's `rfc822MessageId` is the
    /// ONLY field that differs from what the gesture captured. Every address
    /// predicate and the epoch check therefore still pass, which is exactly the
    /// state a turnover produces and the reason a sixth, content-based predicate
    /// is needed.
    ///
    /// INVARIANT: undo never moves a message the user never touched. Refusing is
    /// recoverable — the message is simply still in Archive and one ordinary
    /// gesture moves it back — while a misattributed move is not (C3).
    ///
    /// NON-VACUITY, both sides, without duplicating a fixture: the identical
    /// witness-carrying member with an UNCHANGED row IS admitted, and that is
    /// already pinned by
    /// `theImapInverseNamesTheDestinationUidAndNeverTheRfc822MessageId` (same
    /// `seedDrainedMove(rfc822:)` seam, asserts the queued inverse).
    @Test("Undo refuses when the row at the recorded address is a DIFFERENT message than the one the gesture moved")
    @MainActor
    func undoRefusesWhenTheRowAtTheAddressIsADifferentMessage() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let member = try seedDrainedMove(
            fixture, destinationUid: "205", rfc822: "moved-by-the-user@example.com")

        // The turnover: same folder, same UID, same epoch, different email.
        try await fixture.pool.write { db in
            guard var impostor = try MessageHeader.fetchOne(db, key: member.id) else { return }
            impostor.rfc822MessageId = "someone-elses-mail@example.com"
            try impostor.update(db)
        }

        await undo(fixture, [member])

        let ops = try await operations(fixture)
        #expect(ops.isEmpty, "no inverse may be queued against a message the gesture never named")
        let row = try #require(try await self.row(fixture, id: member.id))
        #expect(row.folderPath == "Archive", "the impostor must not be moved to INBOX")
        #expect(
            row.rfc822MessageId == "someone-elses-mail@example.com",
            "non-vacuity: the impostor really is the row at that address")
    }

    /// The companion half of the adjudication recorded on
    /// `ExpectedMessageIdentity`: a member whose captured witness is UNUSABLE
    /// (nil, empty, or a bare `<>`) keeps today's behaviour and is still
    /// reversed. Rows with no usable RFC 822 Message-ID genuinely exist, and
    /// refusing every undo on them would drop user intention wholesale to close a
    /// rare edge — the opposite of the trade the mantra asks for.
    ///
    /// This is a REGISTERED GAP, not a claim of safety: such a member is still
    /// authenticated by address alone and a turnover could still misattribute it
    /// (`KNOWN_ISSUES.md` `IOS-IDENTITY-001`). It is pinned so that closing the
    /// gap later is a deliberate, visible change rather than an accident, and so
    /// that a fix which "closes" it by refusing everything fails here loudly.
    @Test("A member with NO usable content witness keeps today's behaviour and is still reversed (registered gap IOS-IDENTITY-001)")
    @MainActor
    func undoWithoutAWitnessKeepsTodaysBehaviour() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let member = try seedDrainedMove(fixture, destinationUid: "209", rfc822: nil)

        await undo(fixture, [member])

        let ops = try await operations(fixture)
        #expect(ops.count == 1, "a witness-less member must not be refused — that would drop the intention")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].messageIds == ["209"], "and the inverse still names the destination ADDRESS")
        let restored = try #require(try await row(fixture, id: member.id))
        #expect(restored.folderPath == "INBOX")
    }
}

// MARK: - MessageHeader.stableId legacy characterization (non-queue)

/// KEPT VERBATIM from the pre-re-scope file — these two always called
/// production. `stableId` remains in use for non-queue local keys; durable
/// message actions carry the provider's native address and are covered by their
/// admission and provider-resolution suites instead.
@Suite("MessageHeader.stableId — legacy mixed helper outside the durable queue")
struct MessageHeaderStableIdTests {

    @Test("stableId returns rfc822MessageId for numeric UIDs")
    func stableIdReturnsRfc822ForNumericUid() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", rfc822MessageId: "<stable@example.com>"
        )
        #expect(msg.stableId == "<stable@example.com>", "stableId should prefer rfc822MessageId for numeric UIDs")
    }

    @Test("stableId returns messageId for non-numeric IDs (Gmail)")
    func stableIdReturnsMessageIdForGmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "gmail-stable-id", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", rfc822MessageId: "<msg@gmail.com>"
        )
        #expect(msg.stableId == "gmail-stable-id", "stableId should return messageId for non-numeric IDs")
    }
}
