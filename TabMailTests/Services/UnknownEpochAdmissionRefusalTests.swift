/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T1.3 — a durable IMAP action admission FAILS CLOSED on an unknown folder epoch.
///
/// The SYSTEM PROPERTY under test (never the guard's mechanism): when a NEW user
/// gesture targets an IMAP folder whose `Folder.lastKnownUidValidity` is nil,
/// **no `PendingOperation` row exists afterwards AND no optimistic local mutation
/// landed** — the two must fail together, atomically. A local move/flag the queue
/// will never execute is worse than doing nothing.
///
/// 🚨 The anti-brick cases are the reason this suite exists in this shape.
/// `Folder.lastKnownUidValidity` is nil FOREVER on Gmail and Exchange — UIDVALIDITY
/// is an IMAP concept and neither the Gmail nor the Graph provider ever populates
/// `FolderInfo.uidValidity`. A refusal that keyed off "the column is nil" rather
/// than off the account's provider would therefore silently no-op every action on
/// every Gmail and Exchange account, permanently. `gmailNilEpoch…` and
/// `exchangeNilEpoch…` below fail loudly if the guard ever loses its provider
/// scoping, and must never be weakened to accommodate a guard that has.
///
/// 🚨 Those two providers are NOT the whole anti-brick class, and treating them as
/// such is what shipped a live brick. The demo account is STORED as `.imap` — it
/// satisfies the provider clause — but is served by `DemoProvider`, which never
/// performs a SELECT, so its epoch is nil FOREVER too. `demoAccount…` below covers
/// the third and last member of that class (the full `Account`-construction census
/// is on `newGestureRefusedForUnknownEpoch`). The lesson the family teaches: the
/// question the guard is asking is "is this account IMAP-BACKED", and the provider
/// column is only a proxy for it.
@Suite("T1.3 — durable IMAP admission fails closed on an unknown folder epoch", .serialized, .processGlobalState)
struct UnknownEpochAdmissionRefusalTests {

    // MARK: - Harness

    /// Installs a temp `AppDatabase` holding one account of `provider`, an INBOX
    /// whose stored epoch is `inboxEpoch`, and an Archive whose epoch is ALWAYS
    /// nil. Archive staying nil is deliberate: the move tests then prove the
    /// refusal reads the **source** folder's epoch (where UIDs are resolved),
    /// not the destination's.
    @MainActor
    private func makeTestDB(
        provider: AccountProvider,
        inboxEpoch: Int?
    ) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: provider)
            acc.id = "acc1"
            try acc.insert(db)

            var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            inbox.lastKnownUidValidity = inboxEpoch
            try inbox.insert(db)

            // Destination epoch is intentionally left nil — see doc above.
            let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
            try archive.insert(db)
        }
        return (pool, dir, previous)
    }

    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    /// Inserts a durable header and returns the stored row.
    /// `messageId` is numeric (an IMAP UID) and `rfc822MessageId` is supplied, so
    /// `stableId` resolves to the RFC id — the ordinary shape for a synced message.
    @MainActor
    private func insertMessage(
        _ pool: DatabasePool,
        messageId: String,
        folderPath: String = "INBOX",
        rfc822MessageId: String? = "rfc-\(UUID().uuidString)@example.com"
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Subject \(messageId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "snippet",
            folderId: "acc1:\(folderPath)",
            accountId: "acc1",
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        header.headerComplete = true
        header.rfc822MessageId = rfc822MessageId
        try pool.writeWithoutTransaction { db in try header.insert(db) }
        let stored = try pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        return try #require(stored)
    }

    private func ops(_ pool: DatabasePool) async throws -> [PendingOperation] {
        try await pool.read { db in try PendingOperation.fetchAll(db) }
    }

    private func header(_ pool: DatabasePool, _ id: String) async throws -> MessageHeader? {
        try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    // MARK: - 1. IMAP + nil epoch + new user gesture → refused, atomically

    @Test("IMAP, nil epoch: markRead admits no op AND leaves isRead untouched")
    @MainActor
    func imapNilEpochRefusesMarkRead() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "101")
        #expect(msg.isRead == false)

        await AccountManager.shared.markRead([msg])

        #expect(try await ops(pool).isEmpty, "a nil-epoch IMAP folder must admit no durable op")
        #expect(try await header(pool, msg.id)?.isRead == false,
                "the optimistic local mutation must NOT land when the op is refused")
    }

    @Test("IMAP, nil epoch: markFlagged admits no op AND leaves isFlagged untouched")
    @MainActor
    func imapNilEpochRefusesMarkFlagged() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "102")

        await AccountManager.shared.markFlagged([msg], flagged: true)

        #expect(try await ops(pool).isEmpty)
        #expect(try await header(pool, msg.id)?.isFlagged == false,
                "the optimistic local mutation must NOT land when the op is refused")
    }

    @Test("IMAP, nil epoch: move admits no op AND leaves the message in its source folder")
    @MainActor
    func imapNilEpochRefusesMove() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "103")

        await AccountManager.shared.move([msg], to: "Archive")

        #expect(try await ops(pool).isEmpty)
        let stored = try await header(pool, msg.id)
        #expect(stored?.folderId == "acc1:INBOX",
                "a refused move must not relocate the row locally")
        #expect(stored?.folderPath == "INBOX")
    }

    @Test("iCloud is an IMAP account — nil epoch refuses just like .imap")
    @MainActor
    func icloudNilEpochRefusesMarkRead() async throws {
        // Guards the known `.imap`-only predicate trap: several sync sites test
        // `provider == .imap` alone and silently exclude iCloud, which IS IMAP.
        let (pool, dir, previous) = try makeTestDB(provider: .icloud, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "104")

        await AccountManager.shared.markRead([msg])

        #expect(try await ops(pool).isEmpty)
        #expect(try await header(pool, msg.id)?.isRead == false)
    }

    // MARK: - 2. IMAP + known epoch → admitted exactly as before (regression guard)

    @Test("IMAP, known epoch: markRead is admitted exactly as today")
    @MainActor
    func imapKnownEpochAdmitsMarkRead() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "201")

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(rows[0].messageIds == [msg.stableId])
        #expect(rows[0].folderPath == "INBOX")
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("IMAP, known SOURCE epoch and nil DESTINATION epoch: move is admitted")
    @MainActor
    func imapKnownEpochAdmitsMoveDespiteNilDestinationEpoch() async throws {
        // The Archive folder's epoch is nil in this fixture. UID resolution for a
        // move happens in the SOURCE mailbox, so the destination's unknown epoch
        // must not refuse the gesture. If this test ever fails, the guard has been
        // wired to the wrong folder.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let archiveEpoch = try await pool.read { db in
            try Folder.fetchOne(db, key: "acc1:Archive")?.lastKnownUidValidity
        }
        #expect(archiveEpoch == nil, "fixture precondition: destination epoch is unknown")

        let msg = try insertMessage(pool, messageId: "202")

        await AccountManager.shared.move([msg], to: "Archive")

        let rows = try await ops(pool)
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(rows[0].folderPath == "INBOX")
        #expect(rows[0].destinationPath == "Archive")
        #expect(try await header(pool, msg.id)?.folderId == "acc1:Archive")
    }

    // MARK: - 3 & 4. ANTI-BRICK — Gmail and Exchange are nil FOREVER, must admit

    @Test("ANTI-BRICK: Gmail account with a nil epoch is ADMITTED, not refused")
    @MainActor
    func gmailNilEpochAdmitsMarkRead() async throws {
        // Gmail never populates FolderInfo.uidValidity, so this column is nil for
        // the life of the account. A refusal here is a permanently bricked account.
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "gmail-301", rfc822MessageId: nil)

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Gmail's permanently-nil epoch must never refuse an action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("ANTI-BRICK: Gmail account with a nil epoch admits a move")
    @MainActor
    func gmailNilEpochAdmitsMove() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "gmail-302", rfc822MessageId: nil)

        await AccountManager.shared.move([msg], to: "Archive")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Gmail's permanently-nil epoch must never refuse a move")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(try await header(pool, msg.id)?.folderId == "acc1:Archive")
    }

    @Test("ANTI-BRICK: Exchange account with a nil epoch is ADMITTED, not refused")
    @MainActor
    func exchangeNilEpochAdmitsMarkRead() async throws {
        // Same reasoning as Gmail: the Graph provider never reports UIDVALIDITY.
        let (pool, dir, previous) = try makeTestDB(provider: .outlook, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "graph-401", rfc822MessageId: nil)

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Exchange's permanently-nil epoch must never refuse an action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("ANTI-BRICK: Exchange account with a nil epoch admits a move")
    @MainActor
    func exchangeNilEpochAdmitsMove() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .outlook, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "graph-402", rfc822MessageId: nil)

        await AccountManager.shared.move([msg], to: "Archive")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "Exchange's permanently-nil epoch must never refuse a move")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(try await header(pool, msg.id)?.folderId == "acc1:Archive")
    }

    // MARK: - 5. System-generated ops are NOT governed by T1.3 — still admitted

    @Test("System op: undo's compensating move-back is admitted under a nil epoch")
    @MainActor
    func imapNilEpochStillAdmitsUndoMoveBack() async throws {
        // Owner decision §9 D6: T1.3 governs only NEW gestures. The move-back is a
        // compensating op for work the server has already done, and on IMAP it is
        // addressed by rfc822MessageId — a Message-ID SEARCH, which is immune to a
        // UIDVALIDITY change. Refusing it would strand the message, not protect it.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "501", folderPath: "Archive",
                                    rfc822MessageId: "rfc-501@example.com")

        await AccountManager.shared.undoDestructiveAction(
            [msg],
            accountId: "acc1",
            originalOpType: .move,
            fromFolderPath: "Archive",
            toFolderPath: "INBOX",
            toFolderId: "acc1:INBOX"
        )

        let rows = try await ops(pool)
        #expect(rows.count == 1, "a system-generated compensating move must still be admitted")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(rows[0].messageIds == ["rfc-501@example.com"])
    }

    // MARK: - 6. ANTI-BRICK — the demo account is `.imap` but is not IMAP-BACKED

    /// Installs a fixture shaped exactly like `DemoSeed`: the real demo account id,
    /// `provider: .imap`, and folders with NO epoch (nothing can ever stamp one —
    /// `DemoProvider` answers from GRDB and performs no SELECT).
    @MainActor
    private func makeDemoTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "demo@example.com", displayName: "Demo", provider: .imap)
            acc.id = DemoSeed.demoAccountId
            try acc.insert(db)
            // Mirrors DemoSeed.seedFolders — `Folder.init` leaves the epoch nil and
            // DemoSeed never assigns one.
            let inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: DemoSeed.demoAccountId)
            try inbox.insert(db)
            let archive = Folder(name: "Archive", path: "ARCHIVE", role: .archive, accountId: DemoSeed.demoAccountId)
            try archive.insert(db)
        }
        return (pool, dir, previous)
    }

    @MainActor
    private func insertDemoMessage(_ pool: DatabasePool, messageId: String) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Subject \(messageId)", from: "Sender",
            fromAddress: "sender@example.com", to: "demo@example.com", date: Date(),
            snippet: "snippet", folderId: "\(DemoSeed.demoAccountId):INBOX",
            accountId: DemoSeed.demoAccountId, folderPath: "INBOX", isInInbox: true
        )
        header.headerComplete = true
        header.rfc822MessageId = "rfc-\(messageId)@example.com"
        try pool.writeWithoutTransaction { db in try header.insert(db) }
        return try #require(try pool.read { db in try MessageHeader.fetchOne(db, key: header.id) })
    }

    @Test("ANTI-BRICK: the demo account is stored as .imap but has no server — a nil epoch must ADMIT")
    @MainActor
    func demoAccountNilEpochAdmitsMarkRead() async throws {
        // `DemoSeed.seedAccount` writes `provider: .imap` and `seedFolders` never
        // assigns `lastKnownUidValidity`; `DemoProvider` performs no SELECT, so
        // nothing can ever stamp one. A refusal here is not a bounded first-sync
        // window — it is Demo Mode permanently unable to archive, delete, move,
        // mark read, flag or label anything.
        let (pool, dir, previous) = try makeDemoTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertDemoMessage(pool, messageId: "601")

        await AccountManager.shared.markRead([msg])

        let rows = try await ops(pool)
        #expect(rows.count == 1, "the demo account's permanently-nil epoch must never refuse an action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .markRead)
        #expect(try await header(pool, msg.id)?.isRead == true)
    }

    @Test("ANTI-BRICK: the demo account admits a move under a nil epoch")
    @MainActor
    func demoAccountNilEpochAdmitsMove() async throws {
        let (pool, dir, previous) = try makeDemoTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertDemoMessage(pool, messageId: "602")

        await AccountManager.shared.move([msg], to: "ARCHIVE")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "demo archive/delete/move must not be a silent no-op")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .move)
        #expect(try await header(pool, msg.id)?.folderId == "\(DemoSeed.demoAccountId):ARCHIVE")
    }

    // MARK: - 7. A missing `Folder` row is an ORPHANED header, not a benign unknown

    @Test("An orphaned header whose folder row no longer exists is REFUSED")
    @MainActor
    func orphanedHeaderWithNoFolderRowIsRefused() async throws {
        // `SyncEngine.fullSync` deletes a vanished folder's row but RETAINS its
        // headers (no foreign key; the code is in the FILE `SyncEngineFullSync.swift`,
        // an `extension SyncEngine` — there is no `SyncEngineFullSync` type to cite).
        // The survivor keeps a folderId/folderPath with no
        // metadata behind it, and its `messageId` is a bare UID from the OLD epoch.
        // Admitting a gesture on it writes that UID into a durable op which can then
        // STORE over whatever occupies the UID in the NEW epoch — a C3 violation.
        // The system property: no op row AND no local mutation.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // A header in a folder that has no `Folder` row at all.
        let orphan = try insertMessage(pool, messageId: "701", folderPath: "VanishedFolder",
                                       rfc822MessageId: nil)
        let folderRow = try await pool.read { db in
            try Folder.fetchOne(db, key: "acc1:VanishedFolder")
        }
        #expect(folderRow == nil, "fixture precondition: the folder row is gone but the header survives")

        await AccountManager.shared.markRead([orphan])

        #expect(try await ops(pool).isEmpty,
                "a gesture on an orphaned header must admit no durable op — its UID belongs to an unknown epoch")
        #expect(try await header(pool, orphan.id)?.isRead == false,
                "the optimistic local mutation must not land either")
    }

    // MARK: - 8. Draft ops — guarded by what the PROVIDER does, not by the op's name

    @MainActor
    private func makeDraftRow(
        _ pool: DatabasePool,
        id: String,
        serverDraftId: String?
    ) throws {
        let draft = Draft(
            id: id, accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Draft \(id)", body: "Body",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            serverDraftId: serverDraftId, serverPushStatus: nil,
            rfc822MessageId: "rfc-draft-\(id)@example.com", attachmentsDirName: nil
        )
        try pool.writeWithoutTransaction { db in try draft.insert(db) }
    }

    /// Adds a drafts-role folder with the given epoch to the standard fixture.
    @MainActor
    private func addDraftsFolder(_ pool: DatabasePool, epoch: Int?) throws {
        try pool.writeWithoutTransaction { db in
            var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
            drafts.lastKnownUidValidity = epoch
            try drafts.insert(db)
        }
    }

    @Test("A draft save carrying a NUMERIC serverDraftId is refused under a nil epoch")
    @MainActor
    func imapNilEpochRefusesDraftSaveWithNumericServerDraftId() async throws {
        // `IMAPProvider.saveDraft`'s `existingDraftId` branch runs BEFORE the APPEND
        // and does `store(flags: [.deleted])` + `expunge()` on a LITERAL UID, both
        // `try?`-swallowed. `saveDraft` mints `DraftSaveResult(serverId: String(uid))`,
        // so a numeric `serverDraftId` IS an IMAP UID and this is the normal path for
        // every save after the first. Under an unknown epoch that expunge can destroy
        // a different message, silently.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        try addDraftsFolder(pool, epoch: nil)
        try makeDraftRow(pool, id: "d-numeric", serverDraftId: "4271")

        await AccountManager.shared.queueDraftSave(draftId: "d-numeric", accountId: "acc1")

        #expect(try await ops(pool).isEmpty,
                "a UID-addressed draft save must not be admitted against an unknown epoch")
        let headers = try await pool.read { db in
            try MessageHeader.filter(Column("folderPath") == "Drafts").fetchAll(db)
        }
        #expect(headers.isEmpty, "the optimistic draft header must not land when the op is refused")
    }

    @Test("ANTI-BRICK: a FIRST draft save (no serverDraftId) is admitted under a nil epoch")
    @MainActor
    func imapNilEpochAdmitsFirstDraftSave() async throws {
        // No serverDraftId means `IMAPProvider.saveDraft` skips the delete branch
        // entirely and performs a pure APPEND — it resolves no existing UID, so there
        // is nothing for an unknown epoch to misresolve. Refusing here would make a
        // brand-new account unable to save a draft at all.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        try addDraftsFolder(pool, epoch: nil)
        try makeDraftRow(pool, id: "d-fresh", serverDraftId: nil)

        await AccountManager.shared.queueDraftSave(draftId: "d-fresh", accountId: "acc1")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "an APPEND-only draft save resolves no UID and must be admitted")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .saveDraft)
    }

    @Test("ANTI-BRICK: a draft save on an account with NO drafts-role folder row is admitted")
    @MainActor
    func draftSaveWithNoDraftsFolderRowIsAdmitted() async throws {
        // `draftsFolderPath` falls back to a guessed "Drafts" when no drafts-role row
        // exists, and that guess matches no `Folder` row — the case the missing-row
        // refusal would otherwise brick permanently. It cannot: an account that has
        // never had a drafts folder row cannot have produced a numeric serverDraftId,
        // so the guessed path never reaches the guard.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        let draftsRow = try await pool.read { db in try Folder.fetchOne(db, key: "acc1:Drafts") }
        #expect(draftsRow == nil, "fixture precondition: no drafts-role folder row exists")
        try makeDraftRow(pool, id: "d-nofolder", serverDraftId: nil)

        await AccountManager.shared.queueDraftSave(draftId: "d-nofolder", accountId: "acc1")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "draft saving must not brick on an account with no drafts folder row")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .saveDraft)
    }

    @Test("A draft delete addressed by NUMERIC id is refused under a nil epoch")
    @MainActor
    func imapNilEpochRefusesDraftDeleteWithNumericId() async throws {
        // `IMAPProvider.deleteDraft` calls `resolveUID(draftId)`, which short-circuits
        // a numeric id straight to `UIDSet(UID(uidValue))` with no SEARCH — so the
        // following `store(.deleted)` + `expunge()` is literal-UID addressed.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        try addDraftsFolder(pool, epoch: nil)

        await AccountManager.shared.queueDraftDelete(serverDraftId: "5150", accountId: "acc1")

        #expect(try await ops(pool).isEmpty,
                "a UID-addressed draft delete must not be admitted against an unknown epoch")
    }

    @Test("A draft delete addressed by a NON-numeric id is admitted — Message-ID SEARCH is epoch-immune")
    @MainActor
    func imapNilEpochAdmitsDraftDeleteWithNonNumericId() async throws {
        // A non-numeric id routes through `searchByMessageId`, which resolves by
        // RFC 822 Message-ID and is unaffected by a UIDVALIDITY change. Refusing it
        // would drop user intention for zero safety gain.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        try addDraftsFolder(pool, epoch: nil)

        await AccountManager.shared.queueDraftDelete(
            serverDraftId: "rfc-draft-abc@example.com", accountId: "acc1")

        let rows = try await ops(pool)
        #expect(rows.count == 1, "an RFC-addressed draft delete is epoch-immune and must be admitted")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .deleteDraft)
    }

    // MARK: - 9. A refusal must not leave a PHANTOM SUCCESS in the UI

    @Test("A refused label removal leaves the label VISIBLE on screen, not just in the DB")
    @MainActor
    func refusedLabelRemovalRestoresTheOnScreenLabel() async throws {
        // The DB half of this was already correct: the join row and the op row are
        // written in one transaction, so a refusal leaves both untouched. The
        // PRESENTATION half was not. `removeUserLabel` mutated `loadedMessages`
        // BEFORE the guard and had no revert, so on refusal the chip vanished from
        // the row while the label was still applied — the user is shown a removal
        // that never happened and never will. This asserts the UI-facing state; a
        // test that only checked `messageUserLabel` would stay green on the bug.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "801")
        let label = UserLabel(id: "lbl-work", accountId: "acc1", name: "Work", isSystem: false)
        try await pool.writeWithoutTransaction { db in
            try label.insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: label.id).insert(db)
        }

        let inbox = try #require(try await pool.read { db in
            try Folder.fetchOne(db, key: "acc1:INBOX")
        })
        let vm = InboxViewModel(folders: [inbox])
        let before = vm.loadedMessages.first(where: { $0.id == msg.id })
        #expect(before?.userLabels.contains(where: { $0.id == label.id }) == true,
                "fixture precondition: the label is on screen before the gesture")
        let snapshot = try #require(before)

        await vm.removeUserLabel(label, from: snapshot)

        // The op was refused (nil epoch), so nothing was queued...
        #expect(try await ops(pool).isEmpty, "precondition: this gesture was refused")
        // ...and the durable join row still exists...
        let stillJoined = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == msg.id && Column("userLabelId") == label.id)
                .fetchCount(db)
        }
        #expect(stillJoined == 1, "a refused removal must not delete the join row")
        // ...so the on-screen row MUST still show the label. This is the assertion
        // that fails on the pre-fix code.
        let after = vm.loadedMessages.first(where: { $0.id == msg.id })
        #expect(after?.userLabels.contains(where: { $0.id == label.id }) == true,
                "the label disappeared from the visualized row although nothing was removed — phantom success")
    }

    @Test("System op: a local-only tag write is admitted under a nil epoch")
    @MainActor
    func imapNilEpochStillAdmitsTagWrite() async throws {
        // Action tags are local-only (ADR-IOS-036) and `.setTag` drains to a
        // provider no-op, so a tag op can never mutate a message on the server —
        // there is nothing for an unknown epoch to endanger. Guarding it would
        // drop user intent for zero safety gain.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "502", rfc822MessageId: "rfc-502@example.com")

        AccountManager.queueTagWrite(
            accountId: "acc1",
            messageId: msg.messageId,
            rfc822MessageId: msg.rfc822MessageId,
            tag: ActionTag.reply,
            folder: "INBOX"
        )

        let rows = try await ops(pool)
        #expect(rows.count == 1, "a local-only tag write is not an epoch-sensitive action")
        guard rows.count == 1 else { return }
        #expect(rows[0].type == .setTag)
    }
}
