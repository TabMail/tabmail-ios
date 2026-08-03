/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// T4.V12 — a recount belongs to the database it was requested FOR.
///
/// `performRecount` is debounced, so resolving `AppDatabase.dbPool` at execution
/// time lets a recount requested against one database land on whichever database
/// happens to be installed when the timer fires. `requestRecount` therefore
/// captures the pool, and ids accumulated for a superseded pool are dropped
/// rather than recomputed against the wrong database's truth.
///
/// The dropped half is deliberate and does NOT violate "never drop user
/// intention": those ids name folders in a database we can no longer safely
/// touch, and writing them into the new one would corrupt counts that were never
/// requested. The request for the CURRENT pool must still land — that is the
/// two-sided assertion below.
///
/// `.serialized` + `.processGlobalState`: rebinds the process-global
/// `AppDatabase.shared`, restored on exit. The manager under test is a FRESH
/// instance rather than `UnreadCountManager.shared`, so no other suite's pending
/// ids can interfere with this one's debounce state.
@Suite(
    "UnreadCountManager binds a recount to the pool it was requested for (T4.V12)",
    .serialized,
    .processGlobalState
)
struct UnreadCountManagerPendingPoolTests {

    /// Parked sentinel: any folder a recount touches moves off this value, so
    /// "still parked" is positive evidence that no recount was applied.
    private static let parkedCount = 99

    private func makeTestPool() throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        try AppDatabase.runMigrations(on: pool)
        return (pool, dir)
    }

    /// Seeds one account plus the named folders, each parked at `parkedCount`
    /// and carrying `unread` unread headers.
    private func seed(
        pool: DatabasePool,
        folders: [(path: String, role: FolderRole, unread: Int)]
    ) throws {
        var account = Account(
            emailAddress: "recount@example.com",
            displayName: "Recount",
            provider: .imap
        )
        account.id = "acc1"
        try pool.write { db in
            try account.insert(db)
            for spec in folders {
                var folder = Folder(
                    name: spec.path,
                    path: spec.path,
                    role: spec.role,
                    accountId: "acc1"
                )
                folder.unreadCount = Self.parkedCount
                try folder.insert(db)
                for index in 0..<spec.unread {
                    var header = MessageHeader(
                        messageId: "\(spec.path)-\(index)",
                        subject: "Subject \(index)",
                        from: "Sender",
                        fromAddress: "sender@example.com",
                        to: "recipient@example.com",
                        date: Date(),
                        snippet: "",
                        folderId: "acc1:\(spec.path)",
                        accountId: "acc1",
                        folderPath: spec.path,
                        isInInbox: spec.role == .inbox
                    )
                    header.headerComplete = true
                    try header.insert(db)
                }
            }
        }
    }

    private func unreadCount(in pool: DatabasePool, folderId: String) throws -> Int? {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT unreadCount FROM folder WHERE id = ?",
                arguments: [folderId]
            )
        }
    }

    @Test("A recount bound to a superseded pool is discarded while a request for the current pool still lands")
    func supersededPoolIsDiscardedAndCurrentPoolStillLands() async throws {
        // A fresh instance, not the shared singleton — this suite must not
        // inherit or donate debounce state.
        let manager = UnreadCountManager()

        let (poolA, dirA) = try makeTestPool()
        let (poolB, dirB) = try makeTestPool()

        // Both databases carry the SAME folder id. That collision is what makes a
        // cross-pool write silently recompute one database's counts from the
        // other's truth — B's Archive holds 0 unread, A's holds 2.
        try seed(pool: poolA, folders: [
            (path: "INBOX", role: .inbox, unread: 3),
            (path: "Archive", role: .archive, unread: 2)
        ])
        try seed(pool: poolB, folders: [
            (path: "Archive", role: .archive, unread: 0),
            (path: "Sent", role: .sent, unread: 1)
        ])

        let appDbA = try AppDatabase(dbPool: poolA)
        let appDbB = try AppDatabase(dbPool: poolB)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDbA
            return prev
        }
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: poolA, directory: dirA)
            TestDatabaseTeardown.retire(pool: poolB, directory: dirB)
        }

        // Leading edge — fires against A and opens the cooldown window.
        await manager.requestRecount(folderIds: ["acc1:INBOX"])
        // Collected during that window, so these ids are PENDING and bound to A.
        await manager.requestRecount(folderIds: ["acc1:Archive"])

        // The database is swapped underneath the pending request.
        AppDatabase.shared.withLock { $0 = appDbB }

        // A request for the CURRENT database. The ids still pending belong to a
        // database we can no longer safely touch, so they are dropped; this one
        // must still be recounted.
        await manager.requestRecount(folderIds: ["acc1:Sent"])

        await manager.awaitIdleForTesting()

        let archiveInB = try unreadCount(in: poolB, folderId: "acc1:Archive")
        let sentInB = try unreadCount(in: poolB, folderId: "acc1:Sent")

        // (i) The superseded request never recomputed B's Archive. Pre-fix, the
        //     drain resolved the pool at execution time and wrote B's Archive to
        //     0 from B's truth for a request that was never made against B.
        #expect(
            archiveInB == Self.parkedCount,
            "a recount bound to a superseded pool must not apply its result to the new database"
        )
        // (ii) Two-sided non-vacuity: binding the pool must not make a legitimate
        //      recount disappear. The request issued against the CURRENT pool
        //      still lands.
        #expect(
            sentInB == 1,
            "a request for the current pool must still recount — dropping it would drop real user-visible truth"
        )
    }
}
