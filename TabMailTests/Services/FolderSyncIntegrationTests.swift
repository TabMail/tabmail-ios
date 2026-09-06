/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite 1: Folder Upsert from Remote

@Suite("Folder Sync Integration - Upsert from Remote")
struct FolderSyncUpsertTests {

    let db: DatabaseQueue

    init() throws {
        db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
    }

    /// Simulate the fullSync folder upsert/delete pattern.
    private func simulateFolderSync(remoteFolders: [FolderInfo], accountId: String = "acc1") throws {
        try db.write { dbConn in
            let localFolders = try Folder.filter(Column("accountId") == accountId).fetchAll(dbConn)

            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
                    existing.name = info.name
                    existing.totalCount = info.totalCount
                    if let uidNext = info.uidNext { existing.lastKnownUidNext = uidNext }
                    try existing.update(dbConn)
                } else {
                    var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: accountId)
                    folder.totalCount = info.totalCount
                    folder.lastKnownUidNext = info.uidNext
                    try folder.insert(dbConn)
                }
            }

            // Remove local folders no longer on remote
            let remotePaths = Set(remoteFolders.map(\.path))
            for folder in localFolders where !remotePaths.contains(folder.path) {
                // v2 migration removed FK on messageHeader.folderId — manual cleanup
                let folderId = folder.id
                try MessageHeader.filter(Column("folderId") == folderId).deleteAll(dbConn)
                try folder.delete(dbConn)
            }
        }
    }

    @Test("Fresh sync inserts all remote folders into DB")
    func freshSyncInsertsAll() throws {
        let remote = [
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 5, totalCount: 100, uidNext: 501),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 50),
            FolderInfo(name: "Trash", path: "Trash", role: .trash, unreadCount: 0, totalCount: 10),
        ]

        try simulateFolderSync(remoteFolders: remote)

        let folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 3)

        let inbox = folders.first(where: { $0.path == "INBOX" })
        #expect(inbox?.name == "Inbox")
        #expect(inbox?.role == .inbox)
        #expect(inbox?.totalCount == 100)
        #expect(inbox?.lastKnownUidNext == 501)
        #expect(inbox?.id == "acc1:INBOX")

        let sent = folders.first(where: { $0.path == "Sent" })
        #expect(sent?.totalCount == 50)
        #expect(sent?.lastKnownUidNext == nil)
    }

    @Test("Existing folder updated with new name, totalCount, and uidNext")
    func existingFolderUpdated() throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remote = [
            FolderInfo(name: "Primary Inbox", path: "INBOX", role: .inbox, unreadCount: 10, totalCount: 200, uidNext: 800),
        ]
        try simulateFolderSync(remoteFolders: remote)

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.name == "Primary Inbox")
        #expect(folder?.totalCount == 200)
        #expect(folder?.lastKnownUidNext == 800)
    }

    @Test("New folder added to existing set incrementally")
    func newFolderAddedIncrementally() throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remote = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 100),
            FolderInfo(name: "Projects", path: "Projects", role: .custom, unreadCount: 0, totalCount: 25),
        ]
        try simulateFolderSync(remoteFolders: remote)

        let folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 2)

        let projects = folders.first(where: { $0.path == "Projects" })
        #expect(projects != nil)
        #expect(projects?.role == .custom)
        #expect(projects?.totalCount == 25)
        #expect(projects?.id == "acc1:Projects")
    }

    @Test("Remote folder gone causes local folder deletion")
    func remoteFolderGoneCausesLocalDeletion() throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "OldFolder", path: "OldFolder", role: .custom)

        // Remote only has INBOX
        let remote = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 100),
        ]
        try simulateFolderSync(remoteFolders: remote)

        let folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 1)
        #expect(folders[0].path == "INBOX")
    }

    @Test("Folder role preserved during updates")
    func folderRolePreservedDuringUpdates() throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Remote updates name/count but role stays .inbox
        let remote = [
            FolderInfo(name: "My Inbox", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 999),
        ]
        try simulateFolderSync(remoteFolders: remote)

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.role == .inbox)
        #expect(folder?.name == "My Inbox")
    }

    @Test("Multiple accounts — folders isolated by accountId")
    func multipleAccountsFoldersIsolated() throws {
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")

        let remote1 = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 50),
        ]
        let remote2 = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 80),
            FolderInfo(name: "Work", path: "Work", role: .custom, unreadCount: 0, totalCount: 30),
        ]

        try simulateFolderSync(remoteFolders: remote1, accountId: "acc1")
        try simulateFolderSync(remoteFolders: remote2, accountId: "acc2")

        let acc1Folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        let acc2Folders = try db.read { try Folder.filter(Column("accountId") == "acc2").fetchAll($0) }

        #expect(acc1Folders.count == 1)
        #expect(acc2Folders.count == 2)
        #expect(acc1Folders[0].totalCount == 50)
    }

    @Test("UidNext only updates when remote provides non-nil value")
    func uidNextOnlyUpdatesWhenNonNil() throws {
        var folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        folder.lastKnownUidNext = 500
        try db.write { try folder.update($0) }

        // Remote provides a new uidNext
        let remote = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 100, uidNext: 600),
        ]
        try simulateFolderSync(remoteFolders: remote)

        let updated = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(updated?.lastKnownUidNext == 600)
    }

    @Test("FolderInfo with uidNext=nil does not overwrite existing lastKnownUidNext")
    func nilUidNextPreservesExisting() throws {
        var folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        folder.lastKnownUidNext = 500
        try db.write { try folder.update($0) }

        // Remote returns nil uidNext (e.g. Gmail has no uidNext concept)
        let remote = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 100),
        ]
        try simulateFolderSync(remoteFolders: remote)

        let updated = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(updated?.lastKnownUidNext == 500)
    }
}

// MARK: - Suite 2: Folder Deletion Edge Cases

@Suite("Folder Sync Integration - Deletion Edge Cases")
struct FolderSyncDeletionEdgeCaseTests {

    let db: DatabaseQueue

    init() throws {
        db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
    }

    @Test("Deleting folder with messages — messages become orphaned without manual cleanup")
    func deletingFolderOrphansMessagesWithoutCleanup() throws {
        try TestDatabase.insertFolder(db, name: "OldFolder", path: "OldFolder", role: .custom)
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg1", folderId: "acc1:OldFolder", folderPath: "OldFolder", isInInbox: false
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg2", folderId: "acc1:OldFolder", folderPath: "OldFolder", isInInbox: false
        )

        // Delete the folder WITHOUT cleaning up messages (simulates what happens if cleanup is missed)
        try db.write { dbConn in
            let folder = try Folder.fetchOne(dbConn, key: "acc1:OldFolder")!
            try folder.delete(dbConn)
        }

        // Folder is gone
        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:OldFolder") }
        #expect(folder == nil)

        // Messages are orphaned — they still exist because v2 removed FK on folderId
        let orphaned = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:OldFolder").fetchAll($0) }
        #expect(orphaned.count == 2)
    }

    @Test("Deleting folder with pending operations — ops reference by folderPath, survive deletion")
    func deletingFolderPendingOpsSurvive() throws {
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )

        // Create a pending operation referencing the folder path
        var op = PendingOperation(
            type: .move,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "Archive",
            destinationPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Delete the folder
        try db.write { dbConn in
            let folder = try Folder.fetchOne(dbConn, key: "acc1:Archive")!
            try folder.delete(dbConn)
        }

        // PendingOperation still exists — it references folderPath as a string, not FK
        let ops = try db.read { try PendingOperation.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].folderPath == "Archive")
    }

    @Test("Deleting all folders for one account does not affect other accounts")
    func deleteAllFoldersOneAccountIsolated() throws {
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        // Delete all acc1 folders
        _ = try db.write { dbConn in
            try Folder.filter(Column("accountId") == "acc1").deleteAll(dbConn)
        }

        let acc1Folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        let acc2Folders = try db.read { try Folder.filter(Column("accountId") == "acc2").fetchAll($0) }

        #expect(acc1Folders.isEmpty)
        #expect(acc2Folders.count == 1)
        #expect(acc2Folders[0].path == "INBOX")
    }

    @Test("Re-adding a previously deleted folder — fresh row, no stale data")
    func reAddingDeletedFolderFreshRow() throws {
        // Insert folder with backfill state
        var folder = try TestDatabase.insertFolder(db, name: "Projects", path: "Projects", role: .custom)
        folder.backfillComplete = true
        folder.lastKnownUidNext = 999
        folder.totalCount = 42
        folder.isFavorite = true
        try db.write { try folder.update($0) }

        // Delete the folder
        _ = try db.write { dbConn in
            try Folder.filter(Column("id") == "acc1:Projects").deleteAll(dbConn)
        }

        // Verify deleted
        let deleted = try db.read { try Folder.fetchOne($0, key: "acc1:Projects") }
        #expect(deleted == nil)

        // Re-add via sync — should get fresh defaults
        let remote = [
            FolderInfo(name: "Projects", path: "Projects", role: .custom, unreadCount: 0, totalCount: 10),
        ]
        try db.write { dbConn in
            for info in remote {
                var newFolder = Folder(name: info.name, path: info.path, role: info.role, accountId: "acc1")
                newFolder.totalCount = info.totalCount
                newFolder.lastKnownUidNext = info.uidNext
                try newFolder.insert(dbConn)
            }
        }

        let reAdded = try db.read { try Folder.fetchOne($0, key: "acc1:Projects") }
        #expect(reAdded != nil)
        #expect(reAdded?.totalCount == 10)
        #expect(reAdded?.backfillComplete == false) // Fresh default
        #expect(reAdded?.lastKnownUidNext == nil)   // Fresh default
        #expect(reAdded?.isFavorite == false)        // Fresh default
    }
}

// MARK: - Suite 3: Folder Priority and Selection

@Suite("Folder Sync Integration - Priority and Selection")
struct FolderSyncPriorityTests {

    let db: DatabaseQueue

    init() throws {
        db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
    }

    /// Returns folders sorted by sync priority: inbox first, then favorites, then secondary roles, then custom.
    private func sortedBySyncPriority(_ folders: [Folder]) -> [Folder] {
        folders.sorted { a, b in
            let aPriority = syncPriority(for: a)
            let bPriority = syncPriority(for: b)
            return aPriority < bPriority
        }
    }

    private func syncPriority(for folder: Folder) -> Int {
        switch folder.role {
        case .inbox: return 0
        case .sent, .drafts, .trash, .archive, .spam: return folder.isFavorite ? 1 : 2
        case .custom: return folder.isFavorite ? 1 : 3
        }
    }

    @Test("Sync priority: inbox first, then favorites, then secondary roles, then custom")
    func syncPriorityOrdering() throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        let favCustom = try TestDatabase.insertFolder(db, name: "Important", path: "Important", role: .custom)
        try db.write { dbConn in
            var mutable = favCustom
            mutable.isFavorite = true
            try mutable.update(dbConn)
        }
        try TestDatabase.insertFolder(db, name: "Random", path: "Random", role: .custom)

        let allFolders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        let sorted = sortedBySyncPriority(allFolders)

        // Inbox always first
        #expect(sorted[0].role == .inbox)
        // Favorited custom folder next (priority 1)
        #expect(sorted[1].name == "Important")
        #expect(sorted[1].isFavorite == true)
        // Secondary roles (priority 2)
        let secondaryPaths = Set(sorted[2...3].map(\.path))
        #expect(secondaryPaths.contains("Sent"))
        #expect(secondaryPaths.contains("Trash"))
        // Non-favorited custom last (priority 3)
        #expect(sorted[4].name == "Random")
    }

    @Test("Primary role is inbox")
    func primaryRoleIsInbox() throws {
        let inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        #expect(syncPriority(for: inbox) == 0)
    }

    @Test("Secondary roles: sent, drafts, trash, archive, spam")
    func secondaryRoles() throws {
        let secondaryRoles: [(String, FolderRole)] = [
            ("Sent", .sent), ("Drafts", .drafts), ("Trash", .trash),
            ("Archive", .archive), ("Spam", .spam),
        ]
        for (name, role) in secondaryRoles {
            let folder = try TestDatabase.insertFolder(db, name: name, path: name, role: role)
            #expect(syncPriority(for: folder) == 2, "Expected priority 2 for \(name)")
        }
    }

    @Test("Non-favorited custom folders have lowest sync priority")
    func nonFavoritedCustomLowestPriority() throws {
        let custom = try TestDatabase.insertFolder(db, name: "Random", path: "Random", role: .custom)
        #expect(syncPriority(for: custom) == 3)
    }

    @Test("Favorited custom folders included at elevated priority")
    func favoritedCustomElevatedPriority() throws {
        var custom = try TestDatabase.insertFolder(db, name: "Important", path: "Important", role: .custom)
        custom.isFavorite = true
        try db.write { try custom.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: "acc1:Important") }!
        #expect(syncPriority(for: fetched) == 1)
    }
}

// MARK: - Suite 4: Provider → DB Flow with MockEmailProvider

@Suite("Folder Sync Integration - Provider to DB Flow")
struct FolderSyncProviderFlowTests {

    let db: DatabaseQueue
    let provider: MockEmailProvider

    init() throws {
        db = try TestDatabase.make()
        provider = MockEmailProvider()
        try TestDatabase.insertAccount(db, id: "acc1")
    }

    /// Simulate fullSync folder upsert logic using the provider.
    private func simulateFolderSync(accountId: String = "acc1") async throws {
        let remoteFolders = await provider.fetchFoldersResult

        try await db.write { dbConn in
            let localFolders = try Folder.filter(Column("accountId") == accountId).fetchAll(dbConn)

            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
                    existing.name = info.name
                    existing.totalCount = info.totalCount
                    if let uidNext = info.uidNext { existing.lastKnownUidNext = uidNext }
                    try existing.update(dbConn)
                } else {
                    var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: accountId)
                    folder.totalCount = info.totalCount
                    folder.lastKnownUidNext = info.uidNext
                    try folder.insert(dbConn)
                }
            }

            // Remove local folders no longer on remote
            let remotePaths = Set(remoteFolders.map(\.path))
            for folder in localFolders where !remotePaths.contains(folder.path) {
                let folderId = folder.id
                try MessageHeader.filter(Column("folderId") == folderId).deleteAll(dbConn)
                try folder.delete(dbConn)
            }
        }
    }

    /// Simulate fullSync folder fetch via provider.fetchFolders() with error handling.
    private func simulateFolderSyncViaProvider(accountId: String = "acc1") async throws {
        let remoteFolders = try await provider.fetchFolders()

        try await db.write { dbConn in
            let localFolders = try Folder.filter(Column("accountId") == accountId).fetchAll(dbConn)

            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
                    existing.name = info.name
                    existing.totalCount = info.totalCount
                    if let uidNext = info.uidNext { existing.lastKnownUidNext = uidNext }
                    try existing.update(dbConn)
                } else {
                    var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: accountId)
                    folder.totalCount = info.totalCount
                    folder.lastKnownUidNext = info.uidNext
                    try folder.insert(dbConn)
                }
            }

            let remotePaths = Set(remoteFolders.map(\.path))
            for folder in localFolders where !remotePaths.contains(folder.path) {
                let folderId = folder.id
                try MessageHeader.filter(Column("folderId") == folderId).deleteAll(dbConn)
                try folder.delete(dbConn)
            }
        }
    }

    @Test("MockEmailProvider returns folder list — verify DB state matches")
    func providerReturnsListDBMatches() async throws {
        await provider.setFetchFoldersResult([
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 3, totalCount: 120, uidNext: 501),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 45),
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0, totalCount: 200),
        ])

        try await simulateFolderSync()

        let folders = try await db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 3)

        let inbox = folders.first(where: { $0.path == "INBOX" })
        #expect(inbox?.name == "Inbox")
        #expect(inbox?.totalCount == 120)
        #expect(inbox?.lastKnownUidNext == 501)

        let sent = folders.first(where: { $0.path == "Sent" })
        #expect(sent?.totalCount == 45)
    }

    @Test("Provider returns empty list — all local folders removed")
    func providerReturnsEmptyRemovesAll() async throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        await provider.setFetchFoldersResult([])

        try await simulateFolderSync()

        let folders = try await db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.isEmpty)
    }

    @Test("Provider throws — no local changes")
    func providerThrowsNoLocalChanges() async throws {
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        await provider.setFetchFoldersThrows(ProviderError.notConnected)

        // Attempt sync via provider — should throw, no DB changes
        do {
            try await simulateFolderSyncViaProvider()
            Issue.record("Expected provider to throw")
        } catch {
            // Expected
        }

        let folders = try await db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 2)
    }

    @Test("Second sync with changed folders — adds new, removes gone, updates existing")
    func secondSyncDelta() async throws {
        // First sync
        await provider.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 100, uidNext: 500),
            FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0, totalCount: 50),
        ])
        try await simulateFolderSync()

        // Second sync: Archive gone, INBOX updated, new Drafts
        await provider.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 2, totalCount: 150, uidNext: 600),
            FolderInfo(name: "Drafts", path: "Drafts", role: .drafts, unreadCount: 0, totalCount: 5),
        ])
        try await simulateFolderSync()

        let folders = try await db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 2)

        let paths = Set(folders.map(\.path))
        #expect(paths.contains("INBOX"))
        #expect(paths.contains("Drafts"))
        #expect(!paths.contains("Archive"))

        let inbox = folders.first(where: { $0.path == "INBOX" })
        #expect(inbox?.totalCount == 150)
        #expect(inbox?.lastKnownUidNext == 600)

        let drafts = folders.first(where: { $0.path == "Drafts" })
        #expect(drafts?.totalCount == 5)
    }

    @Test("Full sync cycle: folders then messages — verify folder-message relationship")
    func fullSyncCycleFoldersAndMessages() async throws {
        await provider.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 1, totalCount: 2),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 1),
        ])
        try await simulateFolderSync()

        // Insert messages referencing the synced folders
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg1", subject: "Hello",
            folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg2", subject: "World",
            folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "msg3", subject: "Sent email",
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )

        // Verify folder-message relationship
        let inboxMsgs = try await db.read { try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0) }
        let sentMsgs = try await db.read { try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll($0) }
        #expect(inboxMsgs.count == 2)
        #expect(sentMsgs.count == 1)

        // Verify folders exist
        let inboxFolder = try await db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        let sentFolder = try await db.read { try Folder.fetchOne($0, key: "acc1:Sent") }
        #expect(inboxFolder != nil)
        #expect(sentFolder != nil)
    }
}

