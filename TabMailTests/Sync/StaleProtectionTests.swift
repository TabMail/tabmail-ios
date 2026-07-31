/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration test for the stale-detection drop-race fix (commit 609fc05): a message
/// registered in `recentlyCompleted` (as the NSE merge does for push-arrived mail) must
/// NOT be stale-deleted by a sync whose server fetch transiently misses it. Drives the
/// REAL `SyncEngine.runSyncMessages` against an AppDatabase-backed pool + a MockEmailProvider
/// whose fetch returns nothing (the propagation-lag race). `.serialized` because it swaps
/// the `AppDatabase.shared` singleton.
@Suite("Stale-detection drop-race protection", .serialized, .processGlobalState)
struct StaleProtectionTests {

    /// Real DatabasePool-backed AppDatabase (runs all migrations) swapped into the shared
    /// slot so `SyncEngine.runSyncMessages` / `AppDatabase.dbPool` hit the test DB.
    private func makeAppDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        return (pool, dir, previous)
    }

    /// Account + IMAP inbox + one durable "just-arrived" message. Returns (folder, headerId).
    private func seed(_ pool: DatabasePool) throws -> (folder: Folder, headerId: String) {
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "u@ex.com", displayName: "U", provider: .imap)
            acc.id = "acc1"
            try acc.insert(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
            try folder.insert(db)
            var h = MessageHeader(
                messageId: "500", subject: "New", from: "Alice", fromAddress: "a@ex.com",
                to: "u@ex.com", date: Date(), snippet: "hi", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            h.rfc822MessageId = "<new-500@ex.com>"
            h.headerComplete = true
            try h.insert(db)
        }
        let folder = try pool.read { try Folder.fetchOne($0, key: "acc1:INBOX")! }
        let headerId = try pool.read {
            try MessageHeader.filter(Column("messageId") == "500").fetchOne($0)!.id
        }
        return (folder, headerId)
    }

    /// A fetch that returns NOTHING — the server transiently not including the just-arrived
    /// message (STATUS/fetch propagation lag), which is what makes stale detection want to
    /// delete it. `fetchMessagesResult` defaults to `[]`.
    private func missingFetchMock() -> MockEmailProvider { MockEmailProvider(staleWindowMode: .uid) }

    @Test("A recentlyCompleted-protected message the fetch missed is NOT marked stale")
    func protectedSurvives() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (folder, headerId) = try seed(pool)

        // Exactly what the merge registers: provider messageId + normalized rfc822.
        let recent: [String: Date] = [
            "500": Date(),
            EmailFilter.normalizeMessageId("<new-500@ex.com>"): Date()
        ]
        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: missingFetchMock(), limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool, recentlyCompleted: recent)

        #expect(!result.staleIds.contains(headerId),
                "a protected just-arrived message must not be stale-deleted by a racing sync")
    }

    @Test("WITHOUT protection the same message IS marked stale (protection is load-bearing)")
    func unprotectedIsDeleted() async throws {
        let (pool, dir, previous) = try makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let (folder, headerId) = try seed(pool)

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: missingFetchMock(), limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool, recentlyCompleted: [:])  // no protection

        #expect(result.staleIds.contains(headerId),
                "an unprotected message the fetch missed IS stale-deleted — the pre-fix drop race")
    }
}
