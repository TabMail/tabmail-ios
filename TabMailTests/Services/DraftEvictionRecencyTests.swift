/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T4.D5 — `Draft.lastTouchedSeq` is the monotonic eviction-recency key, so a
/// just-saved draft can never be the eviction victim even when the wall clock
/// ties or runs backwards. Covers the v79 seed for pre-existing rows too.
///
/// PORT reference: `v2final:TabMail/Models/Draft.swift` → `lastTouchedSeq`;
/// `v2final:…/DraftStore.swift` → `nextLastTouchedSeq` + the eviction ordering;
/// `v2final:…/AppDatabase.swift` → `seedDraftLastTouchedSeq`.
@Suite("Draft eviction recency key")
struct DraftEvictionRecencyTests {

    private func makePool() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-eviction-recency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            var account = Account(
                emailAddress: "acc1@example.com", displayName: "Test", provider: .outlook)
            account.id = "acc1"
            try account.insert(db)
        }
        return (pool, directory)
    }

    private func draft(id: String, updatedAt: Double) -> Draft {
        Draft(
            id: id, accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: "authored body for \(id)", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: updatedAt,
            updatedAt: updatedAt, serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
    }

    @Test("A save assigns a strictly increasing eviction key regardless of updatedAt")
    func saveAssignsMonotonicKey() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let now = Date().timeIntervalSince1970

        try db.write { connection in
            _ = try DraftStore.applySave(draft(id: "new:a", updatedAt: now), db: connection)
            // Wall clock rolls BACKWARD between the two saves.
            _ = try DraftStore.applySave(draft(id: "new:b", updatedAt: now - 600), db: connection)
        }

        let rows = try db.read { connection in
            (a: try Draft.fetchOne(connection, key: "new:a"),
             b: try Draft.fetchOne(connection, key: "new:b"))
        }
        #expect(rows.a != nil)
        #expect(rows.b != nil)
        guard let a = rows.a, let b = rows.b else { return }
        // `b` was touched last, so it must rank ahead of `a` even though its
        // wall-clock `updatedAt` is older.
        #expect(b.lastTouchedSeq > a.lastTouchedSeq)
        #expect(a.lastTouchedSeq > 0)
    }

    @Test("A just-saved draft is never the eviction victim of a backward clock")
    func justSavedDraftSurvivesEviction() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let now = Date().timeIntervalSince1970
        let staleClockId = "new:just-saved-under-a-backward-clock"
        let olderId = "new:older-but-newer-timestamp"

        try fixture.pool.write { db in
            _ = try DraftStore.applySave(draft(id: olderId, updatedAt: now), db: db)
            // The user's most recent edit, stamped with an EARLIER wall clock.
            _ = try DraftStore.applySave(
                draft(id: staleClockId, updatedAt: now - 600), db: db)
        }

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool), limit: 1)

        let state = try fixture.pool.read { db in
            (justSaved: try Draft.fetchOne(db, key: staleClockId),
             older: try Draft.fetchOne(db, key: olderId))
        }
        // Ordering by `updatedAt` would have kept `older` and DELETED the draft the
        // user just typed into. The monotonic key keeps the right one.
        #expect(state.justSaved != nil)
        #expect(state.older == nil)
    }

    @Test("The v79 seed ranks pre-existing drafts distinctly by updatedAt then id")
    func seedRanksLegacyRowsDistinctly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let now = Date().timeIntervalSince1970

        // Written straight to the table, so every row still carries the column
        // default of 0 — exactly the pre-upgrade state the v79 seed repairs.
        try db.write { connection in
            try draft(id: "new:c", updatedAt: now).insert(connection)
            try draft(id: "new:a", updatedAt: now - 600).insert(connection)
            // Same wall clock as "new:a" — the tie the seed must break by id.
            try draft(id: "new:b", updatedAt: now - 600).insert(connection)
        }
        let beforeSeed = try db.read { connection in
            try Draft.fetchAll(connection).map(\.lastTouchedSeq)
        }
        #expect(beforeSeed.allSatisfy { $0 == 0 })

        try db.write { try AppDatabase.seedDraftLastTouchedSeq($0) }

        let ranks = try db.read { connection in
            try Draft.fetchAll(connection).reduce(into: [String: Int]()) {
                $0[$1.id] = $1.lastTouchedSeq
            }
        }
        #expect(ranks.count == 3)
        #expect(Set(ranks.values).count == 3)          // distinct, no ties
        #expect(ranks["new:a"] == 1)                   // oldest updatedAt, lowest id
        #expect(ranks["new:b"] == 2)                   // same updatedAt, higher id
        #expect(ranks["new:c"] == 3)                   // newest updatedAt

        // The next save continues from MAX, so a seeded row is never re-tied.
        try db.write { connection in
            _ = try DraftStore.applySave(draft(id: "new:d", updatedAt: now), db: connection)
        }
        let seeded = try db.read { try Draft.fetchOne($0, key: "new:d") }
        #expect(seeded?.lastTouchedSeq == 4)
    }
}
