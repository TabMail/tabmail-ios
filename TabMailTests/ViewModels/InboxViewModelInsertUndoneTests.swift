/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Regression test for commit 00cbdb8: `insertUndoneMessages` must apply the
/// optimistic overlay before the folder-membership guard.
///
/// Undo archive/move calls `AccountManager.registerMutation(folderId: originalFolderId)`
/// synchronously, then posts `.messagesUndone`. The DB restore write is
/// deferred via enqueueWrite. Without the overlay, `insertUndoneMessages`
/// reads the header directly — header.folderId is still the destination
/// (e.g. Archive), fails the `folderIds.contains(header.folderId)` check,
/// and the undone row never reappears until the next full reload.
/// ⚠️ `.processGlobalState` is REQUIRED, not decorative. `makeTestDB` replaces
/// `AppDatabase.shared` (and the tests clear `AccountManager.shared`'s optimistic
/// overlay), and `.serialized` orders cases only WITHIN this suite — it does not
/// join the cross-suite `ProcessGlobalTestState` lock. Without the trait, a
/// concurrently running suite's `AccountManager.dbPool` (which re-resolves
/// `AppDatabase.shared` at every access) can execute its `UPDATE … SET isRead=1`
/// against THIS suite's fixture: zero rows touched, nothing thrown, and the
/// victim then reads its own pool and sees `isRead == false`. That was task #91,
/// the `SearchLocalResultIdentityTests.identityPreservingMidFlightWriteStillMarksRead`
/// flake — a harness defect, not a product race. Of the suites that write the
/// global, this was the single genuine outlier.
@Suite("InboxViewModel insertUndoneMessages overlay", .serialized, .processGlobalState)
struct InboxViewModelInsertUndoneTests {

    @MainActor
    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)

        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }

        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)

            let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            let archive = Folder(name: "Archive", path: "[Gmail]/All Mail", role: .archive, accountId: "acc1")
            try inbox.insert(db)
            try archive.insert(db)
        }

        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "[Gmail]/All Mail", role: .archive, accountId: "acc1")
        return (pool, inbox, archive, dir, previous)
    }

    @MainActor
    private func insertHeader(
        _ pool: DatabasePool,
        messageId: String,
        folderId: String,
        folderPath: String,
        isInInbox: Bool
    ) throws -> String {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "me@example.com",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            snippet: "body",
            folderId: folderId,
            accountId: "acc1",
            folderPath: folderPath,
            isInInbox: isInInbox
        )
        header.headerComplete = true
        try pool.writeWithoutTransaction { db in
            try header.insert(db)
        }
        let stored = try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("accountId") == "acc1")
                .fetchOne(db)
        }
        return stored!.id
    }

    private func clearOverlay() {
        // snapshotOverlay / removeOverlayEntries are both nonisolated on the
        // AccountManager actor. Snapshot the current keys and remove them —
        // avoids direct access to the (actor-isolated) Mutex property.
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    @Test("Overlay redirects header back to visible inbox → message reappears")
    @MainActor func overlayRerouteInsertsMessage() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        // DB state after archive: header.folderId = archive, isInInbox = false.
        // This is exactly the state insertUndoneMessages sees between the undo
        // trigger and the deferred DB restore write.
        let id = try insertHeader(
            pool,
            messageId: "m-undone-1",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )

        // VM created BEFORE the overlay mutation exists (PLAN_INBOX_UNIFIED_READ.md
        // Phase 3: `InboxViewModel(folders:)` -> resetMessages() -> fetchPage(before: nil)
        // now routes through InboxListReader, whose P-step fetches ANY
        // overlay-pinned row by id on every read — see §2.1/§4.1's "improvement".
        // Ordering the overlay registration BEFORE VM creation (as this test
        // originally did) would have the reader's P-step surface the row during
        // `init` itself, making line "loadedMessages is empty" below false before
        // `insertUndoneMessages` is ever called — that's real Phase-3 behavior,
        // not a bug, but it defeats what THIS test is isolating (insertUndoneMessages'
        // own overlay-reroute logic). Mirroring the real call order (UndoService
        // registers the overlay, THEN posts .messagesUndone -> insertUndoneMessages)
        // keeps the test meaningful: no reader-backed fetch runs between VM
        // creation and the mutation, so the pre-condition still holds.
        let vm = InboxViewModel(folders: [inbox])
        // Archive message never loaded into inbox VM — loadedMessages is empty.
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        // The undo path registers this mutation synchronously before posting
        // .messagesUndone — overlay now says "this message belongs in Inbox".
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                isRead: nil,
                folderId: inbox.id,
                folderPath: inbox.path,
                isInInbox: true,
                isFlagged: nil,
                actionTag: nil
            )
        )
        // Registering the mutation alone doesn't trigger a VM refetch — still empty.
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        vm.insertUndoneMessages([id])

        #expect(vm.loadedMessages.contains(where: { $0.id == id }))
    }

    @Test("No overlay → header still in archive, insert is a silent no-op")
    @MainActor func noOverlayDropsInsert() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        // Same archive-state header, but this time no overlay is registered —
        // mimics the pre-fix behavior. The message stays dropped.
        let id = try insertHeader(
            pool,
            messageId: "m-undone-2",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )

        let vm = InboxViewModel(folders: [inbox])
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))

        vm.insertUndoneMessages([id])

        // Without the overlay, folder-membership check fails and the row is
        // silently dropped. (This is the bug the commit fixes — the fix kicks
        // in when an overlay IS present, but this test locks in the "no
        // overlay → conservative drop" semantics so future refactors don't
        // accidentally start inserting messages from arbitrary folders.)
        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))
    }

    @Test("Overlay without folderId change → still gated by real folderId")
    @MainActor func overlayWithoutFolderIdChange() async throws {
        let (pool, inbox, archive, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            clearOverlay()
        }
        clearOverlay()

        let id = try insertHeader(
            pool,
            messageId: "m-undone-3",
            folderId: archive.id,
            folderPath: archive.path,
            isInInbox: false
        )

        // Overlay only changes isRead — folder guard still sees archive.
        AccountManager.shared.registerMutation(
            id: id,
            mutation: .init(
                isRead: true,
                folderId: nil,
                folderPath: nil,
                isInInbox: nil,
                isFlagged: nil,
                actionTag: nil
            )
        )

        let vm = InboxViewModel(folders: [inbox])
        vm.insertUndoneMessages([id])

        #expect(!vm.loadedMessages.contains(where: { $0.id == id }))
    }
}
