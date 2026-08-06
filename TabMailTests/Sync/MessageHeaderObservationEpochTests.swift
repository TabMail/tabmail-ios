/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("Message-header source observation epoch", .serialized, .processGlobalState)
struct MessageHeaderObservationEpochTests {
    private static func info(uid: String, rfc822: String? = nil) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: uid, rfc822MessageId: rfc822, inReplyTo: nil, references: [],
            threadId: nil, subject: "epoch \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "epoch",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    private static func fixture(
        accountId: String = "source-epoch", provider: AccountProvider = .imap,
        path: String = "INBOX", role: FolderRole = .inbox,
        folderEpoch: Int? = nil
    ) throws -> (DatabasePool, URL, AppDatabase?, Folder) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: provider, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: path, role: role, pool: pool,
            lastKnownUidValidity: folderEpoch)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: path, pool: pool))
        return (pool, dir, previous, folder)
    }

    private static func run(
        folder: Folder, pool: DatabasePool, epoch: UInt32?, infos: [MessageHeaderInfo]
    ) async throws {
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setMockedBoundFetchEpoch(epoch, folderPath: folder.path)
        await mock.setFetchMessagesResult(infos)
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))
    }

    private static func stored(
        _ pool: DatabasePool, id: String
    ) async throws -> MessageHeader? {
        try await pool.read { try MessageHeader.fetchOne($0, key: id) }
    }

    @Test("A bound IMAP full-sync insert stores the epoch from the SELECT that served it")
    func boundFullSyncInsert() async throws {
        let (pool, dir, previous, folder) = try Self.fixture()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.run(folder: folder, pool: pool, epoch: 101, infos: [Self.info(uid: "1")])
        let row = try await Self.stored(pool, id: "source-epoch:INBOX:1")
        #expect(row?.observedUidValidity == 101)
    }

    @Test("A missing or zero fetch epoch stores nil and never adopts the Folder epoch")
    func missingOrZeroDoesNotAdoptFolderEpoch() async throws {
        for (suffix, epoch) in [("missing", UInt32?.none), ("zero", UInt32?.some(0))] {
            let accountId = "source-epoch-\(suffix)"
            let (pool, dir, previous, folder) = try Self.fixture(accountId: accountId, folderEpoch: 909)
            defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
            try await Self.run(folder: folder, pool: pool, epoch: epoch, infos: [Self.info(uid: "1")])
            let row = try await Self.stored(pool, id: "\(accountId):INBOX:1")
            #expect(row?.observedUidValidity == nil)
        }
    }

    @Test("A stable-provider header remains epochless")
    func stableProviderInsertIsEpochless() async throws {
        let (pool, dir, previous, folder) = try Self.fixture(accountId: "stable-source", provider: .gmail)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await Self.run(folder: folder, pool: pool, epoch: nil, infos: [Self.info(uid: "gid")])
        let row = try await Self.stored(pool, id: "stable-source:INBOX:gid")
        #expect(row?.observedUidValidity == nil)
    }

    @Test("An accepted canonical update replaces the old header epoch with the bound batch epoch")
    func canonicalUpdateReplacesEpoch() async throws {
        let (pool, dir, previous, folder) = try Self.fixture()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await pool.write { db in
            var row = MessageHeader(messageId: "1", subject: "old", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "old", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
            row.rfc822MessageId = "same@example.com"; row.observedUidValidity = 100; try row.insert(db)
        }
        try await Self.run(folder: folder, pool: pool, epoch: 101, infos: [Self.info(uid: "1", rfc822: "same@example.com")])
        let row = try await Self.stored(pool, id: "source-epoch:INBOX:1")
        #expect(row?.observedUidValidity == 101)
    }

    @Test("Provider-address proof outranks a positive RFC disagreement")
    func providerAddressProofOutranksRfcDisagreement() async throws {
        let (pool, dir, previous, folder) = try Self.fixture()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await pool.write { db in
            var row = MessageHeader(messageId: "1", subject: "old", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "old", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
            row.rfc822MessageId = "old@example.com"; row.observedUidValidity = 100; try row.insert(db)
        }
        try await Self.run(folder: folder, pool: pool, epoch: 101, infos: [Self.info(uid: "1", rfc822: "new@example.com")])
        let row = try await Self.stored(pool, id: "source-epoch:INBOX:1")
        #expect(row?.observedUidValidity == 101)
        #expect(row?.rfc822MessageId == "new@example.com")
    }

    @Test("An RFC-only UID remap remains epochless until an exact folder-native observation")
    func rfcOnlyRemapIsEpochless() async throws {
        let (pool, dir, previous, folder) = try Self.fixture()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await pool.write { db in
            var row = MessageHeader(messageId: "1", subject: "old", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "old", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
            row.rfc822MessageId = "same@example.com"; row.observedUidValidity = 100; try row.insert(db)
        }
        try await Self.run(folder: folder, pool: pool, epoch: 101, infos: [Self.info(uid: "2", rfc822: "same@example.com")])
        let row = try await Self.stored(pool, id: "source-epoch:INBOX:2")
        #expect(row?.observedUidValidity == nil)
    }

    @Test("A stable-provider accepted update clears a seeded IMAP observation epoch")
    func stableProviderUpdateClearsEpoch() async throws {
        let (pool, dir, previous, folder) = try Self.fixture(accountId: "stable-update", provider: .gmail)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try await pool.write { db in
            var row = MessageHeader(messageId: "gid", subject: "old", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "old", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
            row.observedUidValidity = 100; try row.insert(db)
        }
        try await Self.run(folder: folder, pool: pool, epoch: nil, infos: [Self.info(uid: "gid")])
        let row = try await Self.stored(pool, id: "stable-update:INBOX:gid")
        #expect(row?.observedUidValidity == nil)
    }

    @Test("A canonicalization merge or rekey remains epochless until provider ownership is proven")
    func canonicalizationRekeyClearsEpoch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try db.write { connection in
            var remnant = MessageHeader(messageId: "7", subject: "moved", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "moved", folderId: "acc1:Archive", accountId: "acc1", folderPath: "INBOX", isInInbox: false)
            remnant.observedUidValidity = 100
            try remnant.insert(connection)
            let result = try SyncEngine.canonicalizeLocalRows(
                accountId: "acc1", folderPath: "Archive", folderId: "acc1:Archive",
                messageId: "7", isInInbox: false, windowMode: .uid,
                sourceBoundEpoch: 100,
                incomingRfc822Identity: nil, db: connection)
            #expect(result.sourceAddressProven == false)
            #expect(result.row?.observedUidValidity == nil)
            #expect(result.ftsRekey == nil,
                    "an unproven moved row must not be re-keyed into a provider address it may not own")
            #expect(result.row?.id == "acc1:INBOX:7")
            #expect(try MessageHeader.fetchOne(connection, key: "acc1:INBOX:7") != nil)
            #expect(try MessageHeader.fetchOne(connection, key: "acc1:Archive:7") == nil)
        }
    }

    @Test("An optimistic cross-mailbox move clears the source epoch")
    func optimisticMoveClearsEpoch() async throws {
        let (pool, dir, previous, folder) = try Self.fixture(folderEpoch: 101)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try FolderEpochTestFixture.insertFolder(accountId: folder.accountId, path: "Archive", role: .archive, pool: pool)
        let row: MessageHeader = try await pool.write { db in
            var row = MessageHeader(messageId: "9", subject: "move", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "move", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
            row.observedUidValidity = 101; try row.insert(db); return row
        }
        await AccountManager.shared.move([row], to: "Archive")
        let moved = try await Self.stored(pool, id: row.id)
        #expect(moved?.folderPath == "Archive")
        #expect(moved?.observedUidValidity == nil)
    }

    /// 🚨 RE-SCOPED (2026-08-03). Prior display name, recorded because the
    /// assertion is unchanged and only the setup is: *"Undo leaves the restored
    /// row epochless until sync proves its address"* — same name, kept.
    ///
    /// **This test was VACUOUS and passed on `nil == nil`.** Its `snapshot` was
    /// never inserted, so `undoMove`'s member authentication
    /// (`MessageHeader.fetchOne(db, key: member.originalHeaderId)`) found no row
    /// and refused the whole command before writing anything. The read then
    /// returned `nil`, and `restored?.observedUidValidity` on a `nil` row is
    /// `nil`, so the expectation held no matter what production did — inverting
    /// the epoch rule could not turn it red.
    ///
    /// It also predated `59423bb7d`/`f7c3354c5`. Post-O2, undo of a DRAINED
    /// IMAP move is an ordinary reverse move, and "epochless" is specifically
    /// the QUEUED IMAP INVERSE arm: `restoreSourceEpoch = annihilate || !isIMAP`
    /// in `AccountManager.undoMove`. An annihilated (never-attempted) move and a
    /// stable-id provider both RESTORE the captured source epoch, so a fixture
    /// whose forward op is still queued-and-unattempted would pin the opposite
    /// rule. The forward op is therefore already gone from the queue here (the
    /// drain completed it), which is exactly the state the drain leaves behind.
    ///
    /// THE SETUP MODELS THE DRAIN, not a shortcut around it. The row carries the
    /// DESTINATION address `COPYUID` proved — `MessageHeaderRekey.finishMove`
    /// re-keys the primary key and `messageId` to the destination UID and stamps
    /// the destination epoch — and the stacked `UndoMember` follows it via
    /// `UndoService.applyRekeys`, which moves ONLY the two address fields and
    /// leaves every source field describing where the message came from. That is
    /// why the snapshot's `id`/`messageId` name the Archive address while its
    /// `folderPath`/`observedUidValidity` still name INBOX and epoch 101.
    ///
    /// NON-VACUITY IS ASSERTED, not assumed: the row must EXIST and must have
    /// moved back to INBOX. Both are properties of production having actually
    /// run; a refusal leaves the row in Archive and fails the test.
    @Test("Undo leaves the restored row epochless until sync proves its address")
    func undoClearsEpoch() async throws {
        let (pool, dir, previous, folder) = try Self.fixture(folderEpoch: 101)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try FolderEpochTestFixture.insertFolder(
            accountId: folder.accountId, path: "Archive", role: .archive, pool: pool,
            lastKnownUidValidity: 202)
        let destinationId = "\(folder.accountId):Archive:205"
        // The row as the drain leaves it: seated at the destination address
        // COPYUID proved, stamped with the destination folder's epoch.
        try await pool.write { db in
            var row = MessageHeader(messageId: "205", subject: "undo", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "undo", folderId: "\(folder.accountId):Archive", accountId: folder.accountId, folderPath: "Archive", isInInbox: false)
            row.id = destinationId
            row.observedUidValidity = 202
            try row.insert(db)
        }
        // The stacked member as `UndoService.applyRekeys` leaves it: the two
        // ADDRESS fields follow the re-key, every source field does not.
        var snapshot = MessageHeader(messageId: "10", subject: "undo", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "undo", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
        snapshot.observedUidValidity = 101
        snapshot.id = destinationId
        snapshot.messageId = "205"
        await AccountManager.shared.undoDestructiveAction([snapshot], accountId: folder.accountId, originalOpType: .move, fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: folder.id)
        let restored = try #require(try await Self.stored(pool, id: destinationId))
        #expect(restored.folderPath == "INBOX", "the undo must have actually run — a refusal leaves the row in Archive")
        #expect(restored.observedUidValidity == nil)
    }

    @Test("An unbound body-queue UID rekey clears the epoch")
    func bodyQueueRekeyClearsEpoch() async throws {
        let (pool, dir, previous, folder) = try Self.fixture(path: "Archive", role: .archive)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let oldId = "source-epoch:Archive:11"
        try await pool.write { db in
            var row = MessageHeader(messageId: "11", subject: "body", from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "body", folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: false)
            row.observedUidValidity = 101; try row.insert(db)
        }
        let item = BackfillBodyQueue.Item(headerId: oldId, accountId: folder.accountId, folderPath: folder.path, messageId: "11", isInInbox: false)
        _ = await BackfillBodyQueue().rekeyRemappedHeader(item: item, newUID: "12")
        let row = try await Self.stored(pool, id: "source-epoch:Archive:12")
        #expect(row?.observedUidValidity == nil)
    }

    private static func backfillInsert(
        displayId: String, premise: Int? = nil, observed: UInt32?
    ) async throws -> Int? {
        let (pool, dir, previous, folder) = try Self.fixture(accountId: displayId, path: "Archive", role: .archive, folderEpoch: premise)
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let engine = SyncEngine()
        if let premise {
            _ = await engine.insertBackfillBatch([Self.info(uid: "1")], folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, folderRole: folder.role, isInInbox: false, epochPremise: .init(UInt32(premise)), observedEpoch: observed)
        } else {
            _ = await engine.insertBackfillBatch([Self.info(uid: "1")], folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, folderRole: folder.role, isInInbox: false, observedEpoch: observed)
        }
        return try await Self.stored(pool, id: "\(displayId):Archive:1")?.observedUidValidity
    }

    @Test("A backfill premise cannot become a header observation epoch")
    func backfillPremiseIsNotObservation() async throws {
        #expect(try await Self.backfillInsert(displayId: "premise-only", premise: 101, observed: nil) == nil)
    }

    @Test("Self-heal inserts the epoch returned beside its FETCH")
    func selfHealInsertCarriesFetchEpoch() async throws {
        #expect(try await Self.backfillInsert(displayId: "self-heal", premise: 101, observed: 101) == 101)
    }

    @Test("An IMAP infinite-scroll insert carries the epoch of its serving SELECT")
    func infiniteScrollInsertCarriesServingEpoch() async throws {
        #expect(try await Self.backfillInsert(displayId: "infinite-scroll", observed: 102) == 102)
    }

    @Test("Optimistic Draft and Sent placeholders remain epochless")
    func optimisticPlaceholdersAreEpochless() {
        for (path, role) in [("Drafts", FolderRole.drafts), ("Sent", FolderRole.sent)] {
            let row = MessageHeader(messageId: "placeholder", subject: role.rawValue, from: "Sender", fromAddress: "sender@example.com", to: "r@example.com", date: .distantPast, snippet: "", folderId: "a:\(path)", accountId: "a", folderPath: path, isInInbox: false)
            #expect(row.observedUidValidity == nil)
        }
    }

    /// RE-SCOPED (`IOS-NSE-001`). Previous display name: *"NSE staged-only
    /// headers remain epochless until staged-row epoch validation lands"* —
    /// that name blessed the defect, because the projection dropped a
    /// POSITIVELY-PROVEN epoch too, not just an absent one. The carry has now
    /// landed (`NSEStagedEpochCarryTests` covers the proven half), so what
    /// remains true — and is the two-sided control that an absence of evidence
    /// is never upgraded to proof — is only the UNSTAMPED half asserted here.
    @Test("An unstamped NSE staged row still projects an epochless header")
    func unstampedStagedHeaderIsEpochless() {
        let staged = StagedInboxRow(accountId: "a", folderPath: "INBOX", messageId: "16", rfc822MessageId: nil, threadId: nil, inReplyTo: nil, references: [], subject: "staged", senderName: "Sender", senderAddress: "sender@example.com", to: "r@example.com", snippet: "staged", date: .distantPast, isRead: false, isFlagged: false, hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: nil)
        #expect(staged.toMessageHeader().observedUidValidity == nil)
    }

    @Test("Ordinary backfill stores the UIDVALIDITY returned beside its serving FETCH")
    func ordinaryBackfillCarriesEpoch() async throws {
        #expect(try await Self.backfillInsert(displayId: "ordinary", observed: 117) == 117)
    }

    @Test("Deep backfill stores each row with the UIDVALIDITY from its serving FETCH")
    func deepBackfillCarriesEpoch() async throws {
        #expect(try await Self.backfillInsert(displayId: "deep", observed: 118) == 118)
    }

    @Test("A deep-backfill retry spanning E1 and E2 stores no observation epoch")
    func mixedDeepBackfillEpochIsNil() {
        #expect(SyncEngine.commonObservedUidValidity([119, 120]) == nil)
        #expect(SyncEngine.commonObservedUidValidity([119, nil]) == nil)
        #expect(SyncEngine.commonObservedUidValidity([119, 119]) == 119)
    }
}
