/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Backfill Body Miss Count

/// Tests for the IMAP-miss-count safety net in `BackfillBodyQueue.handleMissedItems`.
///
/// Context: IMAP batch fetch can omit UIDs that no longer exist on the server.
/// Previously these items were retried forever with no cap. The fix increments a
/// persistent `missFetchCount` column on each miss; after `backfillBodyMissThreshold`
/// consecutive misses (5) the header is treated as confirmed gone and deleted.
/// A successful fetch resets the counter to 0 (so a transient blip doesn't
/// accumulate toward deletion).
///
/// The production `handleMissedItems` reads/writes `AppDatabase.dbPool` directly,
/// which isn't swappable for testing. These tests replicate the SAME SQL against
/// an in-memory `TestDatabase` — if production SQL changes, the helpers here must
/// change with it (same pattern as `BackfillBodyRepopulateOnDrainTests`).
@Suite("BackfillBodyQueue — missFetchCount counter + threshold delete")
struct BackfillBodyMissCountTests {

    /// Replicates production: read-then-write increment of `missFetchCount`. Returns
    /// the new count.
    private func incrementMissCount(_ db: DatabaseQueue, headerId: String) throws -> Int {
        try db.write { conn in
            let newCount = (try Int.fetchOne(
                conn,
                sql: "SELECT missFetchCount FROM messageHeader WHERE id = ?",
                arguments: [headerId]
            ) ?? 0) + 1
            try conn.execute(
                sql: "UPDATE messageHeader SET missFetchCount = ? WHERE id = ?",
                arguments: [newCount, headerId]
            )
            return newCount
        }
    }

    /// Replicates production: reset missFetchCount alongside bodyComplete in the
    /// `BodyFetchProcessor.flushBatch` success path.
    private func markBodyCompleteResetMiss(_ db: DatabaseQueue, headerId: String) throws {
        try db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET snippet = ?, bodyComplete = 1, missFetchCount = 0 WHERE id = ?",
                arguments: ["snip", headerId]
            )
        }
    }

    private func readMissCount(_ db: DatabaseQueue, headerId: String) throws -> Int {
        try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT missFetchCount FROM messageHeader WHERE id = ?", arguments: [headerId]) ?? 0
        }
    }

    // MARK: - Tests

    @Test("Freshly inserted messageHeader has missFetchCount = 0 (v46 default)")
    func defaultIsZero() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")
        #expect(try readMissCount(db, headerId: h.id) == 0)
    }

    @Test("Single miss increments missFetchCount to 1, below threshold — header retained")
    func singleMissIncrementsCounter() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")

        let c1 = try incrementMissCount(db, headerId: h.id)
        #expect(c1 == 1)
        #expect(c1 < SyncConfig.backfillBodyMissThreshold)

        // Header still present
        let exists = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [h.id]) ?? 0
        }
        #expect(exists == 1)
    }

    @Test("Threshold reached after exactly 5 consecutive misses (counter semantics)")
    func thresholdAtFive() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")

        var lastCount = 0
        for _ in 0..<SyncConfig.backfillBodyMissThreshold {
            lastCount = try incrementMissCount(db, headerId: h.id)
        }
        #expect(lastCount == SyncConfig.backfillBodyMissThreshold)
        #expect(lastCount >= SyncConfig.backfillBodyMissThreshold) // production uses `>=`
    }

    @Test("Counter is persistent across 'batches' — misses accumulate across cycles")
    func counterPersistsAcrossCycles() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Simulate 3 separate dispatch cycles, each producing one miss
        _ = try incrementMissCount(db, headerId: h.id)
        _ = try incrementMissCount(db, headerId: h.id)
        let c3 = try incrementMissCount(db, headerId: h.id)
        #expect(c3 == 3)

        // Still below threshold (5), would have retried each cycle — header is retained
        let exists = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [h.id]) ?? 0
        }
        #expect(exists == 1)
    }

    @Test("Successful body fetch resets missFetchCount to 0 — transient blip does NOT accumulate toward deletion")
    func successResetsCounter() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Accumulate misses near threshold but short of it
        _ = try incrementMissCount(db, headerId: h.id)
        _ = try incrementMissCount(db, headerId: h.id)
        _ = try incrementMissCount(db, headerId: h.id)
        #expect(try readMissCount(db, headerId: h.id) == 3)

        // Body fetch succeeds — resets counter
        try markBodyCompleteResetMiss(db, headerId: h.id)
        #expect(try readMissCount(db, headerId: h.id) == 0)

        // Next miss starts from 1 again, not from 4 — so the header can survive
        // many more cycles of transient misses as long as they're interrupted by
        // success.
        let after = try incrementMissCount(db, headerId: h.id)
        #expect(after == 1)
    }

    @Test("SyncConfig.backfillBodyMissThreshold is 5 (user-agreed value)")
    func thresholdConfigured() {
        #expect(SyncConfig.backfillBodyMissThreshold == 5)
    }

    /// The threshold delete funnels into `deleteConfirmedGoneHeader`, which since
    /// Stage D (`v70_dropMessageBodyHeaderFK`) reclaims the body through
    /// `MessageContentStore.releaseUnowned(…, stores: [.searchIndex, .body])` after
    /// its transaction commits, rather than through an FK cascade inside it.
    @Test("Delete at threshold removes header — same routed reclamation as the confirmed-gone path")
    func deleteAtThresholdRemovesHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")
        _ = try TestDatabase.insertMessageBody(db, headerId: h.id)

        // Drive counter up to threshold
        for _ in 0..<SyncConfig.backfillBodyMissThreshold {
            _ = try incrementMissCount(db, headerId: h.id)
        }

        // Simulate the delete branch: lookup + delete (same SQL as deleteConfirmedGoneHeader)
        let ids: [String] = try db.read { conn in
            try String.fetchAll(conn, sql: "SELECT id FROM messageHeader WHERE accountId = ? AND messageId = ?", arguments: [h.accountId, h.messageId])
        }
        #expect(ids == [h.id])
        try db.write { conn in _ = try MessageHeader.deleteOne(conn, key: ids[0]) }

        // Header gone
        let headerCount = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [h.id]) ?? 0
        }
        #expect(headerCount == 0)

        // The body is NOT carried out by the delete — no FK cascade remains. It is
        // reclaimed by the routed release that runs after the transaction commits.
        let bodyCount = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [h.id]) ?? 0
        }
        #expect(bodyCount == 1)
    }
}
