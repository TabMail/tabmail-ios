/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// `BodyAssetStore` prepare→publish two-phase write + expiring preparation lease.
///
/// These pin the SYSTEM properties the lease exists to hold at the same time,
/// not the mechanism that holds them:
///
/// 1. no physical deleter may unlink bytes a writer is still materialising, or
///    bytes a manifest row already references;
/// 2. a writer that never came back may not pin its blob forever — its lease
///    ages out on the store's EXISTING `sweepMinAgeSeconds`, after which the
///    ordinary sweep reclaims the blob exactly as it did before leases existed;
/// 3. a writer whose lease expired FAILS CLOSED — it records no manifest row at
///    all, so nothing ever claims content that may no longer be on disk.
///
/// All tests run against an in-memory manifest queue + a per-test temporary
/// container directory injected via `BodyAssetStore._setTestEnvironment(...)`.
/// No App Group entitlement required. Every age fixture is computed from
/// `Date()`, never from a literal date.
@Suite("BodyAssetStore preparation lease", .serialized, .processGlobalState)
struct BodyAssetPreparationLeaseTests {

    // MARK: - Fixtures

    private static func setupTest() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bodyAssetLeaseTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try BodyAssetStore._makeTestQueue()
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: queue)
        return dir
    }

    private static func teardown(_ dir: URL) {
        BodyAssetStore._resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    private static func blobURL(_ blobId: String) -> URL? {
        BodyAssetStore.storeDirectory()?.appendingPathComponent(blobId)
    }

    private static func blobExists(_ blobId: String) -> Bool {
        guard let url = blobURL(blobId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Ages an on-disk item past the sweep threshold. Relative to `Date()` so
    /// the fixture cannot go stale.
    private static func ageOut(path: String) throws {
        let aged = Date().addingTimeInterval(-(BodyAssetStore.sweepMinAgeSeconds + 30))
        try FileManager.default.setAttributes(
            [.modificationDate: aged], ofItemAtPath: path
        )
    }

    /// Backdates every preparation lease so the store treats its writer as dead.
    /// This is how a crashed writer looks to the next sweep.
    private static func ageOutLeases() throws {
        guard let queue = BodyAssetStore.manifestQueue() else {
            Issue.record("manifest queue unavailable")
            return
        }
        let agedMs = Int64(
            (Date().timeIntervalSince1970 - (BodyAssetStore.sweepMinAgeSeconds + 30)) * 1000
        )
        try queue.write { db in
            try db.execute(
                sql: "UPDATE bodyAssetPreparation SET createdAt = ?",
                arguments: [agedMs]
            )
        }
    }

    private static func leaseCount() throws -> Int {
        guard let queue = BodyAssetStore.manifestQueue() else { return -1 }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bodyAssetPreparation") ?? -1
        }
    }

    private static func manifestRowCount(blobId: String) throws -> Int {
        guard let queue = BodyAssetStore.manifestQueue() else { return -1 }
        return try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM bodyAsset WHERE id = ?",
                arguments: [blobId]
            ) ?? -1
        }
    }

    // MARK: - The lease protects an in-flight blob

    @Test("A live preparation lease stops the orphan sweep from deleting a just-prepared blob")
    func liveLeaseSurvivesOrphanSweep() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-1")
        let bytes = Data("prepared-but-not-yet-published".utf8)
        guard let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "1.1",
            contentType: "application/pdf", data: bytes,
            identityStamp: "rfc:lease-1@example.com"
        ) else {
            Issue.record("prepare failed")
            return
        }
        guard let url = Self.blobURL(prepared.blobId) else {
            Issue.record("store directory unavailable")
            return
        }

        // Age the FILE past the sweep threshold: the age gate can no longer save
        // it, so only the LIVE lease stands between the sweep and these bytes.
        try Self.ageOut(path: url.path)

        BodyAssetStore.pruneOrphanFiles()

        #expect(Self.blobExists(prepared.blobId))
        let leasesAfterSweep = try Self.leaseCount()
        #expect(leasesAfterSweep == 1)

        // …and the writer that comes back still publishes the bytes it wrote.
        #expect(BodyAssetStore.publish(prepared) == prepared.blobId)
        #expect(BodyAssetStore.read(assetId: prepared.blobId) == bytes)
        let leasesAfterPublish = try Self.leaseCount()
        #expect(leasesAfterPublish == 0)
    }

    @Test("deleteAllAssets(forContentKey:) cannot unlink a concurrent writer's in-flight blob")
    func contentKeyPurgeSparesInFlightBlob() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-2")
        guard let publishedId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "1.1", contentType: "application/pdf",
            data: Data("already-cached".utf8), identityStamp: "rfc:lease-2@example.com"
        ) else {
            Issue.record("writeAttachment failed")
            return
        }

        // A second writer is mid-flight for the SAME message when the purge runs.
        let inFlight = Data("still-being-written".utf8)
        guard let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "1.2",
            contentType: "application/pdf", data: inFlight,
            identityStamp: "rfc:lease-2@example.com"
        ) else {
            Issue.record("prepare failed")
            return
        }

        _ = BodyAssetStore.deleteAllAssets(forContentKey: key)

        // The purge takes what it owns…
        #expect(!Self.blobExists(publishedId))
        // …and leaves the in-flight blob AND its header directory alone. Taking
        // either would let the writer publish a row over missing bytes.
        #expect(Self.blobExists(prepared.blobId))
        #expect(BodyAssetStore.publish(prepared) == prepared.blobId)
        #expect(BodyAssetStore.read(assetId: prepared.blobId) == inFlight)
    }

    @Test("Discarding an orphaned preparation never unlinks a blob a live manifest row still references")
    func discardSparesPublishedSlot() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-3")
        guard let assetId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "3.1", contentType: "application/pdf",
            data: Data("v1".utf8), identityStamp: "rfc:lease-3@example.com"
        ) else {
            Issue.record("writeAttachment failed")
            return
        }

        // A re-fetch of the SAME logical slot prepares, then never publishes.
        let v2 = Data("v2".utf8)
        guard let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "3.1",
            contentType: "application/pdf", data: v2,
            identityStamp: "rfc:lease-3@example.com"
        ) else {
            Issue.record("prepare failed")
            return
        }
        // The blob id names the logical slot, so the re-fetch targets the very
        // blob the live row references — the case a naive discard would destroy.
        #expect(prepared.blobId == assetId)

        BodyAssetStore.discardPreparedIfOrphaned(prepared)

        #expect(Self.blobExists(assetId))
        #expect(BodyAssetStore.read(assetId: assetId) == v2)
        let rows = try Self.manifestRowCount(blobId: assetId)
        #expect(rows == 1)
        let leases = try Self.leaseCount()
        #expect(leases == 0)
    }

    // MARK: - The lease expires, and expiry never reclaims a live asset

    @Test("An abandoned preparation lease stops protecting its blob after the sweep age threshold")
    func abandonedLeaseExpiresOnTheSweepThreshold() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-4")
        guard let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "1.1",
            contentType: "application/pdf", data: Data(repeating: 0x11, count: 64),
            identityStamp: "rfc:lease-4@example.com"
        ) else {
            Issue.record("prepare failed")
            return
        }
        guard let url = Self.blobURL(prepared.blobId) else {
            Issue.record("store directory unavailable")
            return
        }

        // The writer died between the lease and publication: both its bytes and
        // its lease age past the threshold.
        try Self.ageOut(path: url.path)
        try Self.ageOutLeases()

        BodyAssetStore.pruneOrphanFiles()

        // A pinned blob would be invisible to the user's attachment cap forever,
        // so the reclaim must actually happen.
        #expect(!Self.blobExists(prepared.blobId))
        let leases = try Self.leaseCount()
        #expect(leases == 0)
        let rows = try Self.manifestRowCount(blobId: prepared.blobId)
        #expect(rows == 0)
    }

    @Test("A writer whose lease expired refuses to publish and records no manifest row")
    func expiredLeasePublishFailsClosed() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-5")
        guard let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "2.1",
            contentType: "application/pdf", data: Data(repeating: 0x22, count: 32),
            identityStamp: "rfc:lease-5@example.com"
        ) else {
            Issue.record("prepare failed")
            return
        }

        try Self.ageOutLeases()
        BodyAssetStore.pruneOrphanFiles()   // reaps the abandoned lease

        // FAIL CLOSED. Publishing here would record a row for content the sweep
        // is now free to unlink — a row claiming content we do not have. The
        // caller sees `nil`, treats it as a cache miss, and re-fetches.
        #expect(BodyAssetStore.publish(prepared) == nil)
        let rows = try Self.manifestRowCount(blobId: prepared.blobId)
        #expect(rows == 0)
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: key, section: "2.1",
            identityStamp: "rfc:lease-5@example.com") == nil)
    }

    @Test("A published asset survives an orphan sweep while a true orphan does not")
    func publishedBlobSurvivesSweepButOrphanDoesNot() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-6")
        let bytes = Data("published-bytes".utf8)
        guard let assetId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "1.1", contentType: "application/pdf", data: bytes,
            identityStamp: "rfc:lease-6@example.com"
        ) else {
            Issue.record("writeAttachment failed")
            return
        }
        // Publication consumed the lease, so from here only the manifest ROW
        // protects these bytes — lease expiry is irrelevant to them.
        let leasesAfterWrite = try Self.leaseCount()
        #expect(leasesAfterWrite == 0)

        guard let storeDir = BodyAssetStore.storeDirectory() else {
            Issue.record("store directory unavailable")
            return
        }
        // A genuine orphan in the same header directory: bytes, no row, no lease.
        let orphanId = "\(BodyAssetStore.headerHash(key))/\(String(repeating: "f", count: 16))"
        let orphanURL = storeDir.appendingPathComponent(orphanId)
        try Data("orphan-bytes".utf8).write(to: orphanURL)

        try Self.ageOut(path: storeDir.appendingPathComponent(assetId).path)
        try Self.ageOut(path: orphanURL.path)

        BodyAssetStore.pruneOrphanFiles()

        // Two-sided: the sweep provably still bites (it took the orphan) AND it
        // provably refuses the published blob.
        #expect(!Self.blobExists(orphanId))
        #expect(Self.blobExists(assetId))
        #expect(BodyAssetStore.read(assetId: assetId) == bytes)
        let rows = try Self.manifestRowCount(blobId: assetId)
        #expect(rows == 1)
    }

    // MARK: - Schema convergence

    @Test("migratePreparationSchema is idempotent on a manifest that predates the lease table")
    func preparationSchemaMigrationIsIdempotent() throws {
        // A manifest created before leases existed: `bodyAsset` only.
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE bodyAsset (
                    id                TEXT PRIMARY KEY,
                    headerId          TEXT NOT NULL,
                    kind              INTEGER NOT NULL,
                    contentId         TEXT,
                    attachmentSection TEXT,
                    contentType       TEXT NOT NULL,
                    sizeBytes         INTEGER NOT NULL,
                    createdAt         INTEGER NOT NULL,
                    lastAccessedAt    INTEGER
                )
                """)
        }

        let existsSQL = """
            SELECT EXISTS(
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'bodyAssetPreparation'
            )
            """
        let before = try queue.read { db in try Bool.fetchOne(db, sql: existsSQL) ?? true }
        #expect(before == false)

        // Upgrade path, run twice — `CREATE … IF NOT EXISTS` is also the
        // fresh-install path, so both must converge without throwing.
        try queue.write { db in try BodyAssetStore.migratePreparationSchema(db) }
        try queue.write { db in try BodyAssetStore.migratePreparationSchema(db) }

        let after = try queue.read { db in try Bool.fetchOne(db, sql: existsSQL) ?? false }
        #expect(after)

        // The upgraded shape accepts exactly what `prepare` writes.
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bodyAssetPreparation (preparationId, blobId, createdAt)
                    VALUES (?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    "aaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbb",
                    Int64(Date().timeIntervalSince1970 * 1000),
                ]
            )
        }
        let leases = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bodyAssetPreparation") ?? -1
        }
        #expect(leases == 1)
    }

    /// The UPGRADE half of `migrateAttachmentIdentitySchema`'s convergence claim
    /// (ADR-IOS-066 / T5.1). A manifest that predates `identityStamp` must gain the
    /// column and then behave identically to a freshly created one — otherwise every
    /// existing install's attachment cache is a hard error rather than a miss.
    @Test("A manifest that predates identityStamp upgrades and then serves stamped attachments")
    func attachmentIdentitySchemaUpgradesAnExistingManifest() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bodyAssetLegacyUpgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            BodyAssetStore._resetForTesting()
            try? FileManager.default.removeItem(at: dir)
        }

        // The PRE-column manifest, verbatim as it shipped.
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE bodyAsset (
                    id                TEXT PRIMARY KEY,
                    headerId          TEXT NOT NULL,
                    kind              INTEGER NOT NULL,
                    contentId         TEXT,
                    attachmentSection TEXT,
                    contentType       TEXT NOT NULL,
                    sizeBytes         INTEGER NOT NULL,
                    createdAt         INTEGER NOT NULL,
                    lastAccessedAt    INTEGER
                )
                """)
            try BodyAssetStore.migratePreparationSchema(db)
        }

        // Same introspection form the production migration itself uses, so this
        // cannot pass against a `PRAGMA` spelling the migration would not see.
        func hasIdentityStampColumn() throws -> Bool {
            try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(bodyAsset)")
                    .map { $0["name"] as String }
                    .contains("identityStamp")
            }
        }
        let hadColumnBefore = try hasIdentityStampColumn()
        #expect(hadColumnBefore == false,
                "precondition: the column really is absent before the upgrade")

        // Run twice — the upgrade path is also re-entered on every manifest open.
        try queue.write { db in try BodyAssetStore.migrateAttachmentIdentitySchema(db) }
        try queue.write { db in try BodyAssetStore.migrateAttachmentIdentitySchema(db) }
        let hasColumnAfter = try hasIdentityStampColumn()
        #expect(hasColumnAfter)

        // …and the upgraded manifest behaves exactly like a fresh one.
        BodyAssetStore._setTestEnvironment(containerURL: dir, queue: queue)
        let key = ContentKey(rawValue: "acc1:INBOX:upgraded")
        let stamp = "rfc:upgraded@example.com"
        guard let assetId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf",
            data: Data("upgraded-bytes".utf8), identityStamp: stamp
        ) else {
            Issue.record("writeAttachment failed on the upgraded manifest")
            return
        }
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: key, section: "2", identityStamp: stamp) == assetId)
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: key, section: "2", identityStamp: "rfc:someone-else@example.com") == nil,
            "the upgraded manifest must refuse a different message just as a fresh one does")
    }
}
