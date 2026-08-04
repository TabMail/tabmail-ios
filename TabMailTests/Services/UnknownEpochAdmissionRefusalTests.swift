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
        header.observedUidValidity = try pool.read { db in
            try Folder.fetchOne(db, key: "acc1:\(folderPath)")?.lastKnownUidValidity
        }
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
        #expect(rows[0].messageIds == [msg.messageId])
        #expect(rows[0].observedUidValidity == 12345)
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

    // MARK: - 5. Completed IMAP Undo has no destination address proof

    @Test("Completed IMAP Undo without a destination UID and epoch fails closed")
    @MainActor
    func imapNilEpochRefusesUnprovenUndoMoveBack() async throws {
        // SUBTRACT — v2final's RFC-addressed compensating move is intentionally
        // omitted. The provider-ID port has no COPYUID/destination receipt, so
        // the numeric destination UID and its epoch are both unproven. C3 wins:
        // fail closed and let sync reconcile instead of manufacturing authority.
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
        #expect(rows.isEmpty, "an unproven completed IMAP move must not manufacture an RFC inverse")
        let unchanged = try await header(pool, msg.id)
        #expect(unchanged?.folderPath == "Archive")
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
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-work", name: "Work", isSystem: false)
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

    @Test("System op: a local-only tag write needs no pending operation under a nil epoch")
    @MainActor
    func imapNilEpochStillAdmitsTagWrite() async throws {
        // Action tags are local-only (ADR-IOS-036) and `.setTag` drains to a
        // provider no-op, so a tag op can never mutate a message on the server —
        // there is nothing for an unknown epoch to endanger. Guarding it would
        // drop user intent for zero safety gain.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "502", rfc822MessageId: "rfc-502@example.com")

        await AccountManager.shared.applyManualTag(msg, tag: .reply)

        let rows = try await ops(pool)
        #expect(rows.isEmpty, "a local-only tag must never create a durable server operation")
        #expect(try await header(pool, msg.id)?.actionTag == .reply)
    }

    // MARK: - 11. A refusal reconciles the presentation state FROM THE DATABASE

    /// 🚨 THE INVARIANT: after any sequence of toggles, admitted or refused, the
    /// displayed checkmarks equal the durable join rows.
    ///
    /// Two taps inside one write window is ordinary use — the menu is a persistent
    /// `List` of `Button`s, not a dismissing `Menu`, and its `appliedIds` is only
    /// recomputed by `loadLabels()` on `.onAppear`. The rollback this replaces
    /// captured `wasApplied` at dispatch and restored it at completion, which
    /// composes wrongly: tap 1 captures `true` and displays L absent, tap 2 captures
    /// `false` (from tap 1's UNPERSISTED optimistic state) and displays L applied,
    /// both writes are refused, rollback 1 re-inserts L and rollback 2 removes it —
    /// leaving the DB holding L with no checkmark. A phantom success, i.e. the exact
    /// defect the rollback was added to eliminate, re-created under concurrency.
    ///
    /// This asserts `appliedIds == the join rows`, never "the revert ran" — a
    /// mechanism assertion would stay green on a rollback that composes wrongly.
    @Test("Two REFUSED label toggles leave the checkmarks equal to the database")
    @MainActor
    func twoRefusedTogglesReconcileFromTheDatabase() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "901")
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-work", name: "Work", isSystem: false)
        try await pool.writeWithoutTransaction { db in
            try label.insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: label.id).insert(db)
        }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()
        #expect(model.appliedIds.contains(label.id),
                "fixture precondition: the label is checked before the gesture")

        // Both taps capture their baseline before either write completes.
        let first = model.toggleLabel(label)
        let second = model.toggleLabel(label)
        await first.value
        await second.value

        #expect(try await ops(pool).isEmpty, "precondition: both toggles were refused")
        let durable = try await pool.read { db in
            Set(try MessageUserLabel
                .filter(Column("messageId") == msg.id)
                .fetchAll(db)
                .map(\.userLabelId))
        }
        #expect(durable == [label.id], "precondition: a refused toggle changes no join row")
        #expect(model.appliedIds == durable,
                """
                the checkmarks disagree with the database after two refused toggles \
                (shown \(model.appliedIds.sorted()) vs stored \(durable.sorted())) — \
                a phantom success
                """)
    }

    @Test("Two ADMITTED label toggles also leave the checkmarks equal to the database")
    @MainActor
    func twoAdmittedTogglesAgreeWithTheDatabase() async throws {
        // Non-vacuity, two ways. (1) The property above must not be satisfiable by a
        // menu whose toggles never change anything: here both writes ARE admitted, so
        // the join rows really move (remove, then re-add) and the assertion has
        // something to disagree with. (2) The reconcile runs on the admitted path too
        // — this pins that it AGREES with the writes rather than clobbering them, the
        // failure a reconcile-everywhere design could plausibly introduce.
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "902")
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-later", name: "Later", isSystem: false)
        try await pool.writeWithoutTransaction { db in
            try label.insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: label.id).insert(db)
        }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()

        let first = model.toggleLabel(label)
        await first.value
        let second = model.toggleLabel(label)
        await second.value

        let durable = try await pool.read { db in
            Set(try MessageUserLabel
                .filter(Column("messageId") == msg.id)
                .fetchAll(db)
                .map(\.userLabelId))
        }
        #expect(durable == [label.id], "precondition: remove-then-add leaves the label applied")
        #expect(model.appliedIds == durable,
                "shown \(model.appliedIds.sorted()) vs stored \(durable.sorted())")
    }

    // MARK: - 11b. The DISTINGUISHING case: the last completion is ADMITTED

    /// 🚨 THE TEST THAT SEPARATES "reconcile on EVERY completion" FROM
    /// "reconcile only on refusal". Neither of the two tests above does:
    /// `twoAdmittedTogglesAgreeWithTheDatabase` SERIALIZES its toggles (it
    /// awaits the first before creating the second), so the optimistic
    /// composition and the durable composition apply the same flips in the same
    /// order and agree by construction; `twoRefusedTogglesReconcileFromTheDatabase`
    /// is all-refused, so a refusal-only reconcile runs on every completion
    /// anyway. Both stay GREEN on a design the commit records as REJECTED, which
    /// means the strengthening was pinned by nothing.
    ///
    /// THE INVARIANT (unchanged, and the only thing asserted): after any
    /// sequence of toggles the displayed checkmarks equal the durable join rows.
    ///
    /// What makes this case distinguishing is a durable change the toggles did
    /// not make. `appliedIds` is computed once by `loadLabels()`; a label
    /// applied to the same message afterwards — by a sync pass, by a drain, by
    /// another device — is in the database and NOT in the display. Two
    /// overlapping toggles then run and BOTH are admitted, so under a
    /// refusal-only design nothing ever re-reads and that label stays invisible
    /// until the sheet is reopened. Reconciling on every completion makes the
    /// LAST completion authoritative, so it appears. No interleaving is relied
    /// on: the divergence exists before either toggle starts and neither toggle
    /// can remove it.
    @Test("Two OVERLAPPING toggles whose LAST completion is ADMITTED still match the database")
    @MainActor
    func overlappingTogglesEndingAdmittedMatchTheDatabase() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "903")
        let toggled = UserLabel(accountId: "acc1", providerLabelId: "lbl-toggled", name: "Toggled", isSystem: false)
        let arrivedLater = UserLabel(accountId: "acc1", providerLabelId: "lbl-arrived", name: "Arrived", isSystem: false)
        try await pool.writeWithoutTransaction { db in
            try toggled.insert(db)
            try arrivedLater.insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: toggled.id).insert(db)
        }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()
        #expect(model.appliedIds == [toggled.id],
                "fixture precondition: the menu was loaded before the second label arrived")

        // A durable change the menu has not seen — a sync pass, a drain, or
        // another device applying a label to the same message.
        try await pool.writeWithoutTransaction { db in
            try MessageUserLabel(messageId: msg.id, userLabelId: arrivedLater.id).insert(db)
        }

        // Two taps inside one write window. Both are ADMITTED (the epoch is
        // known), so the LAST completion is an admitted one.
        let first = model.toggleLabel(toggled)
        let second = model.toggleLabel(toggled)
        await first.value
        await second.value

        let durable = try await pool.read { db in
            Set(try MessageUserLabel
                .filter(Column("messageId") == msg.id)
                .fetchAll(db)
                .map(\.userLabelId))
        }
        #expect(durable.contains(arrivedLater.id),
                "precondition: the externally-applied label is still in the database")
        #expect(model.appliedIds == durable,
                """
                the checkmarks disagree with the database after two overlapping toggles whose \
                last completion was ADMITTED (shown \(model.appliedIds.sorted()) vs stored \
                \(durable.sorted())) — reconciling only on refusal never re-reads here, so the \
                display keeps whatever the optimistic flips left behind
                """)
    }

    /// The same invariant for the OTHER consumer of the same reconcile.
    /// `InboxViewModel.reconcileUserLabels` received the identical
    /// "on every completion, not only on refusal" change and had no test at all.
    ///
    /// The row's `userLabels` is a snapshot taken when the list was built; a
    /// label applied afterwards is durable and undisplayed. An ADMITTED
    /// `removeUserLabel` must leave the row equal to the join rows — which under
    /// a refusal-only reconcile it does not, because the admitted path never
    /// re-reads.
    @Test("An ADMITTED removeUserLabel leaves the row's labels equal to the database")
    @MainActor
    func admittedRemoveUserLabelReconcilesTheRow() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .imap, inboxEpoch: 12345)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "904")
        let removed = UserLabel(accountId: "acc1", providerLabelId: "lbl-removed", name: "Removed", isSystem: false)
        let arrivedLater = UserLabel(accountId: "acc1", providerLabelId: "lbl-row-arrived", name: "RowArrived", isSystem: false)
        try await pool.writeWithoutTransaction { db in
            try removed.insert(db)
            try arrivedLater.insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: removed.id).insert(db)
        }

        let inbox = try #require(try await pool.read { db in
            try Folder.fetchOne(db, key: "acc1:INBOX")
        })
        // The VM loads its rows (and their labels) in `init` — this is the
        // snapshot the user is looking at.
        let viewModel = InboxViewModel(folders: [inbox])
        let snapshot = try #require(viewModel.loadedMessages.first { $0.id == msg.id })
        #expect(snapshot.userLabels.map(\.id) == [removed.id],
                "fixture precondition: the row was built before the second label arrived")

        // Durable, and not in the row's snapshot.
        try await pool.writeWithoutTransaction { db in
            try MessageUserLabel(messageId: msg.id, userLabelId: arrivedLater.id).insert(db)
        }

        await viewModel.removeUserLabel(removed, from: snapshot)

        let durable = try await pool.read { db in
            Set(try MessageUserLabel
                .filter(Column("messageId") == msg.id)
                .fetchAll(db)
                .map(\.userLabelId))
        }
        #expect(durable == [arrivedLater.id], "precondition: only the removed label left the database")
        let shown = Set(viewModel.loadedMessages.first { $0.id == msg.id }?.userLabels.map(\.id) ?? [])
        #expect(shown == durable,
                """
                the row's labels disagree with the database after an ADMITTED removal \
                (shown \(shown.sorted()) vs stored \(durable.sorted())) — the admitted path \
                must reconcile too, or a label applied since the row was built stays invisible
                """)
    }

    // MARK: - 12. A label op never targets a folder the user was not acting on
    //
    // These four share this suite's harness because they exercise the same
    // admission transaction, but they are NOT epoch tests: every one of them runs
    // on a provider the T1.3 epoch guard admits unconditionally (`.gmail`,
    // `.outlook`), so the guard cannot supply the refusal and the property under
    // test is isolated.
    //
    // 🚨 THE SYSTEM PROPERTY, stated once for the pair 12a/12b: **a queued label
    // operation names the folder the acted-on row is actually in — never a
    // default, and above all never `"INBOX"`.** The site that violated it read the
    // message's folder in its own earlier `dbPool.read` and fell back to
    // `?? "INBOX"` when the row was missing; an op carrying a guessed path
    // resolves its id inside a mailbox the user never acted on, which on IMAP
    // mutates whichever message that numbering put there (C3).
    //
    // Neither test asserts the fix's MECHANISM (no "the header was fetched inside
    // the transaction", no "the helper is gone"). 12a asserts the op's folder
    // equals the row's; 12b asserts that with no row there is no op at all. A
    // mechanism assertion would stay green on any other way of guessing.
    //
    // 12c/12d are the provider gate, in the same two-sided shape.

    /// 12a — the ADMITTED side. Also the non-vacuity partner for 12b: a fix that
    /// merely refused every label gesture would pass 12b and fail here.
    @Test("A queued label op names the folder the message is actually in, not INBOX")
    @MainActor
    func labelOpNamesTheMessagesOwnFolder() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        // The message lives in Archive, NOT the inbox — so "the folder the row is
        // in" and "INBOX" are distinguishable, which is the whole point.
        let msg = try insertMessage(pool, messageId: "910", folderPath: "Archive")
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-receipts", name: "Receipts", isSystem: false)
        try await pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()
        let admitted = await model.applyLabel(label)
        #expect(admitted, "precondition: this gesture must be ADMITTED, or the assertion below is vacuous")

        let queued = try await ops(pool)
        #expect(queued.count == 1, "precondition: exactly one label op")
        guard queued.count == 1 else { return }
        #expect(queued[0].folderPath == "Archive",
                """
                the label op names folder '\(queued[0].folderPath)' while the message it acts \
                on is in 'Archive' — the op would resolve its id inside a mailbox the user was \
                never acting on
                """)
        #expect(queued[0].accountId == "acc1")
        // The id half of this test, corrected after audit A-6. It asserted
        // `[msg.stableId]` — the rfc822 CONTENT id — which is precisely the shape
        // the producer was fixed to stop enqueueing: no provider arm can execute an
        // rfc822 string as an address, so such an op is queued, checkmarked, and
        // never performed. The op must carry the PROVIDER's native address for the
        // row it mutated.
        #expect(msg.stableId != msg.messageId,
                """
                precondition: this row's content id and provider address must DIFFER \
                (messageId '\(msg.messageId)' parses as a UID and the row carries an RFC id), \
                or the assertion below cannot tell the two shapes apart
                """)
        #expect(queued[0].messageIds == [msg.messageId],
                """
                the op names \(queued[0].messageIds) — it must name the provider address of \
                the row it mutated locally, not that row's rfc822 content id and not some \
                other identity
                """)
        #expect(queued[0].type == .addUserLabel)
    }

    /// 12b — the REFUSED side. With no row there is no folder, and an absence of
    /// evidence must not become a default. The refusal latches nothing, so it stays
    /// RETRYABLE: the user's next tap re-runs the same transaction.
    @Test("A label gesture whose message row has vanished queues no op at all")
    @MainActor
    func vanishedMessageRowQueuesNoLabelOp() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "911", folderPath: "Archive")
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-vendor", name: "Vendor", isSystem: false)
        try await pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()
        // The sheet is open on this message when a purge/move retires its row
        // underneath — the exact situation the `?? "INBOX"` guess fired in.
        try await pool.writeWithoutTransaction { db in
            _ = try MessageHeader.deleteOne(db, key: msg.id)
        }

        let admitted = await model.applyLabel(label)
        #expect(admitted == false, "a gesture whose target row is gone must fail CLOSED")
        #expect(try await ops(pool).isEmpty,
                """
                an op was queued for a message whose row no longer exists — with no row there \
                is no folder to name, so every folder it could name (INBOX above all) is one \
                the user was not acting on
                """)
        let joined = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == msg.id && Column("userLabelId") == label.id)
                .fetchCount(db)
        }
        #expect(joined == 0, "the local half must not land either — the two must fail together")
    }

    /// 12c — the provider gate, REFUSED side. Exchange's adapter implements no
    /// remote user-label mutation, so an admitted op could never execute; the drain
    /// would carry it forever while the menu showed a checkmark for a label the
    /// server will never hold.
    @Test("A provider with no remote user labels queues no label op and offers no menu")
    @MainActor
    func providerWithoutRemoteUserLabelsQueuesNoLabelOp() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .outlook, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "912")
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-ledger", name: "Ledger", isSystem: false)
        try await pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()
        #expect(model.supportsRemoteUserLabels == false)
        #expect(model.sortedLabels.isEmpty,
                "the menu must not offer labels this account's adapter cannot carry to the server")

        // Entered directly, the way a non-menu caller would: the transaction must
        // carry its own gate rather than trusting the presentation flag above.
        let admitted = await model.applyLabel(label)
        #expect(admitted == false)
        #expect(try await ops(pool).isEmpty,
                """
                a label op was queued for a provider whose adapter cannot mutate labels \
                remotely — nothing can ever execute it
                """)
        let joined = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == msg.id && Column("userLabelId") == label.id)
                .fetchCount(db)
        }
        #expect(joined == 0, "the local half must not land either — the two must fail together")
    }

    /// 12d — the provider gate, ADMITTED side. Same fixture as 12c with only the
    /// provider changed, so a gate that simply refuses everything cannot pass both.
    @Test("The same label gesture on a provider WITH remote user labels is admitted")
    @MainActor
    func providerWithRemoteUserLabelsAdmitsTheLabelOp() async throws {
        let (pool, dir, previous) = try makeTestDB(provider: .gmail, inboxEpoch: nil)
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let msg = try insertMessage(pool, messageId: "912")
        let label = UserLabel(accountId: "acc1", providerLabelId: "lbl-ledger", name: "Ledger", isSystem: false)
        try await pool.writeWithoutTransaction { db in try label.insert(db) }

        let model = UserLabelMenuModel(messageSnapshot: MessageSnapshot(from: msg))
        model.loadLabels()
        #expect(model.supportsRemoteUserLabels)
        #expect(model.sortedLabels.contains(where: { $0.id == label.id }),
                "the menu must offer the label on an account whose adapter can carry it")

        let admitted = await model.applyLabel(label)
        #expect(admitted, "the gate must not refuse a provider that DOES support remote user labels")
        #expect(try await ops(pool).count == 1)
        let joined = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == msg.id && Column("userLabelId") == label.id)
                .fetchCount(db)
        }
        #expect(joined == 1, "the local half must land on the admitted path")
    }
}
