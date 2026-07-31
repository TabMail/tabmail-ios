/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Characterizes `NavigationStore.toggleFavorite / setFavorite / setPrimaryAccount`
/// after they were converted from synchronous main-actor writes to the async
/// `await dbPool.write` overload (so the write suspends off the main actor instead
/// of blocking it behind an in-flight writer).
///
/// The conversion changes only WHERE the write waits, not the SQL — so the
/// database outcome must be identical. These tests pin that outcome, and in
/// particular the data-integrity invariant of `setPrimaryAccount`: clearing all
/// primaries and setting one happen in ONE transaction, so there is never a
/// committed state with zero or two primary accounts (the property a naive
/// two-statement non-transactional write could violate).
///
/// Responsiveness (the merge no longer freezes the UI) is established by the
/// identical `await dbPool.write` mechanism already validated in
/// `NSEMergeMainActorBlockTests`; it isn't re-measured here.
@Suite("NavigationStore favorites/primary — async write", .serialized, .processGlobalState)
@MainActor
struct NavigationStoreFavoritesAsyncTests {

    private func makeStore() throws -> (store: NavigationStore, pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        try pool.writeWithoutTransaction { db in
            var a1 = Account(emailAddress: "a1@example.com", displayName: "A1", provider: .gmail); a1.id = "acc1"
            try a1.insert(db)
            var a2 = Account(emailAddress: "a2@example.com", displayName: "A2", provider: .gmail); a2.id = "acc2"
            try a2.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
        }
        // No loadInitialData() — that registers process-wide NotificationCenter
        // observers (the existing NavigationStoreTests avoid constructing the
        // store for the same reason). We only drive the write methods.
        return (NavigationStore(), pool, dir, previous)
    }

    @Test("toggleFavorite flips isFavorite in the DB (off-main async write)")
    func toggleFavoriteFlipsDB() async throws {
        let (store, pool, dir, previous) = try makeStore()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        guard let folder = try await pool.read({ try Folder.fetchOne($0, key: "acc1:INBOX") }) else {
            Issue.record("seed folder missing"); return
        }
        #expect(folder.isFavorite == false)

        await store.toggleFavorite(folder)
        let on = try await pool.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(on?.isFavorite == true)

        await store.toggleFavorite(folder)
        let off = try await pool.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(off?.isFavorite == false)
    }

    @Test("setFavorite writes the explicit value")
    func setFavoriteExplicit() async throws {
        let (store, pool, dir, previous) = try makeStore()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        guard let folder = try await pool.read({ try Folder.fetchOne($0, key: "acc1:INBOX") }) else {
            Issue.record("seed folder missing"); return
        }
        await store.setFavorite(folder, isFavorite: true)
        #expect(try await pool.read { try Folder.fetchOne($0, key: "acc1:INBOX") }?.isFavorite == true)
        await store.setFavorite(folder, isFavorite: false)
        #expect(try await pool.read { try Folder.fetchOne($0, key: "acc1:INBOX") }?.isFavorite == false)
    }

    @Test("setPrimaryAccount leaves EXACTLY ONE primary (atomic clear-then-set)")
    func setPrimaryAtomic() async throws {
        let (store, pool, dir, previous) = try makeStore()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        guard let acc2 = try await pool.read({ try Account.fetchOne($0, key: "acc2") }) else {
            Issue.record("seed account missing"); return
        }
        await store.setPrimaryAccount(acc2)
        let primaries = try await pool.read { try Account.filter(Column("isPrimary") == true).fetchAll($0) }
        #expect(primaries.count == 1)
        #expect(primaries.first?.id == "acc2")

        // Switching primary to the other account must STILL leave exactly one.
        guard let acc1 = try await pool.read({ try Account.fetchOne($0, key: "acc1") }) else {
            Issue.record("seed account missing"); return
        }
        await store.setPrimaryAccount(acc1)
        let primaries2 = try await pool.read { try Account.filter(Column("isPrimary") == true).fetchAll($0) }
        #expect(primaries2.count == 1)
        #expect(primaries2.first?.id == "acc1")
    }
}
