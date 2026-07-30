/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// REFACTOR NOTE (PLAN_INTENTION_QUEUE.md): the 3 splitGate_* tests drive
// AccountManager.registerMutation directly to seed the overlay before refreshFolders();
// invariant = badge move-delta source/dest truth table (plan section 4 item 11, must survive).
// Retarget the SEED call to record(intention:); the store.folders assertions are unaffected.

import Testing
import Foundation
import GRDB
@testable import TabMail

/// NavigationStore is tightly coupled to AppDatabase.dbPool (singleton) and
/// @MainActor + @Observable. All methods use AppDatabase.dbPool directly with
/// no db: parameter injection point. RenderGate.shared is also used inline.
///
/// What we CAN test: the DB query patterns NavigationStore uses, and the
/// folder favorite toggle logic, using TestDatabase directly.
@Suite("NavigationStore - DB Query Patterns")
struct NavigationStoreTests {

    // MARK: - Account query pattern

    @Test("Active non-calendar accounts query filters correctly")
    func activeAccountQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")

        // Insert an inactive account via raw SQL (isActive=false)
        try db.write { dbConn in
            var inactive = Account(emailAddress: "inactive@b.com", displayName: "Inactive", provider: .gmail)
            inactive.id = "acc3"
            try inactive.insert(dbConn)
            try dbConn.execute(sql: "UPDATE account SET isActive = 0 WHERE id = ?", arguments: ["acc3"])
        }

        let accounts = try db.read { dbConn in
            try Account.filter(Column("isActive") == true && Column("calendarOnly") == false)
                .order(Column("createdAt"))
                .fetchAll(dbConn)
        }

        #expect(accounts.count == 2)
        #expect(accounts.allSatisfy { $0.isActive })
    }

    // MARK: - Folder query pattern

    @Test("Folders ordered by name")
    func folderOrdering() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let folders = try db.read { dbConn in
            try Folder.order(Column("name")).fetchAll(dbConn)
        }

        #expect(folders.count == 3)
        #expect(folders[0].name == "Archive")
        #expect(folders[1].name == "INBOX")
        #expect(folders[2].name == "Trash")
    }

    // MARK: - Toggle favorite pattern

    @Test("Toggle favorite flips isFavorite from false to true")
    func toggleFavoriteFalseToTrue() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Verify initial state
        let initial = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(initial?.isFavorite == false)

        // Toggle
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [folder.id])
        }

        let toggled = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(toggled?.isFavorite == true)
    }

    @Test("Toggle favorite flips isFavorite from true to false")
    func toggleFavoriteTrueToFalse() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Set to favorite first
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET isFavorite = 1 WHERE id = ?", arguments: [folder.id])
        }

        // Toggle
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET isFavorite = NOT isFavorite WHERE id = ?", arguments: [folder.id])
        }

        let toggled = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(toggled?.isFavorite == false)
    }

    @Test("Set favorite sets isFavorite to specific value")
    func setFavoriteExplicit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET isFavorite = ? WHERE id = ?", arguments: [true, folder.id])
        }

        let result = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(result?.isFavorite == true)
    }

    // MARK: - Set primary account pattern

    @Test("Set primary account clears other primary flags")
    func setPrimaryAccountClearsOthers() throws {
        let db = try TestDatabase.make()
        let acc1 = try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        let acc2 = try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")

        // Set acc1 as primary
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE account SET isPrimary = 0 WHERE isPrimary = 1")
            try dbConn.execute(sql: "UPDATE account SET isPrimary = 1 WHERE id = ?", arguments: [acc1.id])
        }

        // Set acc2 as primary — should clear acc1
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE account SET isPrimary = 0 WHERE isPrimary = 1")
            try dbConn.execute(sql: "UPDATE account SET isPrimary = 1 WHERE id = ?", arguments: [acc2.id])
        }

        let accounts = try db.read { try Account.fetchAll($0) }
        let primaryAccounts = accounts.filter(\.isPrimary)
        #expect(primaryAccounts.count == 1)
        #expect(primaryAccounts[0].id == "acc2")
    }

}

/// Characterizes the actual `NavigationStore.refresh()` / `refreshFolders()`
/// methods (not just their query patterns) against a real `AppDatabase` so the
/// sync→async conversion (Half A / PLAN_HANG_FIX) can be verified before/after.
/// `.serialized` because it swaps the `AppDatabase.shared` singleton.
@Suite("NavigationStore refresh behavior", .serialized)
struct NavigationStoreRefreshTests {

    @MainActor
    private func withTestDB(_ body: @MainActor (DatabasePool) async throws -> Void) async throws {
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
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await body(pool)
    }

    private static func insertFolders(_ db: Database, _ specs: [(String, String, FolderRole)], accountId: String) throws {
        for (name, path, role) in specs {
            var f = Folder(name: name, path: path, role: role, accountId: accountId)
            try f.insert(db)
        }
    }

    @Test("refresh() populates accounts + folders + hasAnyAccount from GRDB")
    @MainActor func refreshPopulatesState() async throws {
        try await withTestDB { pool in
            try await pool.write { db in
                var a1 = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail); a1.id = "acc1"; try a1.insert(db)
                var a2 = Account(emailAddress: "c@d.com", displayName: "C", provider: .gmail); a2.id = "acc2"; try a2.insert(db)
                try Self.insertFolders(db, [("INBOX", "INBOX", .inbox), ("Archive", "Archive", .archive), ("Trash", "Trash", .trash)], accountId: "acc1")
            }
            let store = NavigationStore()
            #expect(store.accounts.isEmpty)            // not loaded until refresh
            await store.refresh()
            #expect(store.hasAnyAccount == true)
            #expect(store.accounts.count == 2)
            #expect(store.folders.count == 3)
        }
    }

    @Test("refreshFolders() loads folders ordered by name from GRDB")
    @MainActor func refreshFoldersOrdered() async throws {
        try await withTestDB { pool in
            try await pool.write { db in
                var a = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail); a.id = "acc1"; try a.insert(db)
                try Self.insertFolders(db, [("Trash", "Trash", .trash), ("Archive", "Archive", .archive), ("INBOX", "INBOX", .inbox)], accountId: "acc1")
            }
            let store = NavigationStore()
            await store.refreshFolders()
            #expect(store.folders.map(\.name) == ["Archive", "INBOX", "Trash"])
        }
    }

    // MARK: - F5: badge-delta split (source truth vs dest-projected truth)
    //
    // `optimisticOverlay` entries are process-wide (`AccountManager.shared`),
    // not scoped to the swapped `AppDatabase.shared` — clear them before AND
    // after every test in this section so no cross-test/cross-suite leakage
    // (other suites assert an empty overlay).

    private func makeInboxArchiveHeader(
        folderId: String, accountId: String, folderPath: String, messageId: String, isRead: Bool
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folderId, accountId: accountId, folderPath: folderPath, isInInbox: folderPath == "INBOX"
        )
        h.headerComplete = true
        h.isRead = isRead
        return h
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    /// Characterizes the pre-fix bug AND pins the fix: a message that is
    /// ALREADY READ in the source folder (never contributed to its
    /// unreadCount) is moved AND marked unread on arrival. The OLD code
    /// gated BOTH the source decrement and the dest increment on the same
    /// `isUnread` boolean (derived from the mutation's overlay-projected
    /// state), so it wrongly decremented the source too — a read row that
    /// was never part of the count. The fix splits the two questions:
    /// source uses raw DB truth (`!dbIsRead`), dest uses the
    /// overlay-projected truth.
    @Test("refreshFolders(): read row moved + marked-unread-on-arrival — source unread count UNCHANGED (F5 split fix; pre-fix code wrongly decremented it), dest +1")
    @MainActor func splitGate_readRowMovedMarkedUnread_sourceUnchangedDestIncrements() async throws {
        try await withTestDB { pool in
            clearOverlay()
            defer { clearOverlay() }
            try await pool.write { db in
                var a = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail); a.id = "acc1"; try a.insert(db)
                try Self.insertFolders(db, [("INBOX", "INBOX", .inbox), ("Archive", "Archive", .archive)], accountId: "acc1")
            }
            // Baseline: 3 UNRELATED unread messages already counted in Inbox.
            // The row under test is READ, so it never contributed to this 3.
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET unreadCount = 3 WHERE id = ?", arguments: ["acc1:INBOX"])
            }
            let header = makeInboxArchiveHeader(folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", messageId: "m1", isRead: true)
            try await pool.write { db in try header.insert(db) }

            AccountManager.shared.registerMutation(id: header.id, mutation: .init(isRead: false, folderId: "acc1:Archive"))

            let store = NavigationStore()
            await store.refreshFolders()

            guard let inbox = store.folders.first(where: { $0.id == "acc1:INBOX" }),
                  let archive = store.folders.first(where: { $0.id == "acc1:Archive" }) else {
                Issue.record("expected folders not found in store.folders")
                return
            }
            #expect(inbox.unreadCount == 3, "source must stay at baseline — this row was READ (never counted as unread in Inbox); the pre-fix code wrongly decremented it to 2")
            #expect(archive.unreadCount == 1, "dest increments — the overlay-projected state (marked unread on arrival) counts it in the destination")
        }
    }

    @Test("refreshFolders(): unread row moved + marked-read-on-arrival — source -1, dest count UNCHANGED (F5 split fix)")
    @MainActor func splitGate_unreadRowMovedMarkedRead_sourceDecrementsDestUnchanged() async throws {
        try await withTestDB { pool in
            clearOverlay()
            defer { clearOverlay() }
            try await pool.write { db in
                var a = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail); a.id = "acc1"; try a.insert(db)
                try Self.insertFolders(db, [("INBOX", "INBOX", .inbox), ("Archive", "Archive", .archive)], accountId: "acc1")
            }
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = ?", arguments: ["acc1:INBOX"])
                try db.execute(sql: "UPDATE folder SET unreadCount = 5 WHERE id = ?", arguments: ["acc1:Archive"])
            }
            let header = makeInboxArchiveHeader(folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", messageId: "m2", isRead: false)
            try await pool.write { db in try header.insert(db) }

            AccountManager.shared.registerMutation(id: header.id, mutation: .init(isRead: true, folderId: "acc1:Archive"))

            let store = NavigationStore()
            await store.refreshFolders()

            guard let inbox = store.folders.first(where: { $0.id == "acc1:INBOX" }),
                  let archive = store.folders.first(where: { $0.id == "acc1:Archive" }) else {
                Issue.record("expected folders not found in store.folders")
                return
            }
            #expect(inbox.unreadCount == 1, "source decrements — this row WAS counted unread in Inbox before the move")
            #expect(archive.unreadCount == 5, "dest must NOT increment — the overlay-projected state (marked read on arrival) is not unread in the destination")
        }
    }

    @Test("refreshFolders(): plain move of an unread row (no isRead in the mutation) — source -1, dest +1 (pre-existing behavior preserved by the F5 split)")
    @MainActor func splitGate_plainMoveOfUnreadRow_sourceDecrementsDestIncrements() async throws {
        try await withTestDB { pool in
            clearOverlay()
            defer { clearOverlay() }
            try await pool.write { db in
                var a = Account(emailAddress: "a@b.com", displayName: "A", provider: .gmail); a.id = "acc1"; try a.insert(db)
                try Self.insertFolders(db, [("INBOX", "INBOX", .inbox), ("Archive", "Archive", .archive)], accountId: "acc1")
            }
            try await pool.write { db in
                try db.execute(sql: "UPDATE folder SET unreadCount = 4 WHERE id = ?", arguments: ["acc1:INBOX"])
            }
            let header = makeInboxArchiveHeader(folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", messageId: "m3", isRead: false)
            try await pool.write { db in try header.insert(db) }

            AccountManager.shared.registerMutation(id: header.id, mutation: .init(folderId: "acc1:Archive"))

            let store = NavigationStore()
            await store.refreshFolders()

            guard let inbox = store.folders.first(where: { $0.id == "acc1:INBOX" }),
                  let archive = store.folders.first(where: { $0.id == "acc1:Archive" }) else {
                Issue.record("expected folders not found in store.folders")
                return
            }
            #expect(inbox.unreadCount == 3, "source decrements by 1")
            #expect(archive.unreadCount == 1, "dest increments by 1 — no isRead override, falls through to raw DB truth (unread) on both sides")
        }
    }
}
