/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// `BodyAssetStore` prepare→publish two-phase write + expiring preparation lease.
///
/// These pin the SYSTEM properties the lease exists to hold at the same time,
/// not the mechanism that holds them:
///
/// 1. no physical deleter may unlink bytes a writer is still materialising, or
///    bytes a manifest row already references; and (#1376) a write in progress
///    never touches the store: its bytes stay in `staging/` until publish moves
///    them in with their row;
/// 2. a writer that never came back may not pin its bytes forever — its lease
///    ages out on the store's EXISTING `sweepMinAgeSeconds`, after which
///    `recoverAbandonedPreparations` reclaims the staged file and the lease;
/// 3. a writer whose lease expired FAILS CLOSED — it records no manifest row and
///    moves no file, so nothing ever claims content the store does not hold.
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

    /// #1376: a preparation's bytes live in `staging/<preparationId>` until publish.
    private static func stagedExists(_ prepared: BodyAssetStore.PreparedWrite) -> Bool {
        guard let url = BodyAssetStore.stagingURL(for: prepared) else { return false }
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

    @Test("A live preparation keeps its staged bytes through the sweep and recovery, and publishes them")
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
        guard let stagedURL = BodyAssetStore.stagingURL(for: prepared) else {
            Issue.record("staging directory unavailable")
            return
        }
        // #1376: nothing enters the store before publish.
        #expect(Self.stagedExists(prepared))
        #expect(!Self.blobExists(prepared.blobId), "prepare must not touch the store")

        // Age the staged FILE past the threshold: only the LIVE lease decides.
        try Self.ageOut(path: stagedURL.path)

        BodyAssetStore.pruneOrphanFiles()
        BodyAssetStore.recoverAbandonedPreparations()

        #expect(Self.stagedExists(prepared))
        let leasesAfterSweep = try Self.leaseCount()
        #expect(leasesAfterSweep == 1)

        // …and the writer that comes back still publishes the bytes it wrote.
        #expect(BodyAssetStore.publish(prepared) == prepared.blobId)
        #expect(BodyAssetStore.read(assetId: prepared.blobId) == bytes)
        #expect(!Self.stagedExists(prepared), "publish moves the staged file into the store")
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
        // …and leaves the in-flight bytes (in staging, #1376) AND the header
        // directory alone. Taking either would fail the writer's publish.
        #expect(Self.stagedExists(prepared))
        #expect(BodyAssetStore.publish(prepared) == prepared.blobId)
        #expect(BodyAssetStore.read(assetId: prepared.blobId) == inFlight)
    }

    /// #1376: a preparation that never publishes leaves the slot EXACTLY as it was.
    /// Before staging, `prepare` overwrote the slot's file in place, so the live row
    /// read the abandoned v2 bytes (a row describing bytes nobody published).
    @Test("A discarded preparation leaves the published slot's bytes and row as they were")
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

        #expect(BodyAssetStore.read(assetId: assetId) == Data("v1".utf8),
                "a preparation must not change the slot before it publishes")

        BodyAssetStore.discardPrepared(prepared)

        #expect(Self.blobExists(assetId))
        #expect(BodyAssetStore.read(assetId: assetId) == Data("v1".utf8))
        #expect(!Self.stagedExists(prepared), "the discard removes its staged bytes")
        let rows = try Self.manifestRowCount(blobId: assetId)
        #expect(rows == 1)
        let leases = try Self.leaseCount()
        #expect(leases == 0)
    }

    // MARK: - The lease expires, and expiry never reclaims a live asset

    @Test("An abandoned preparation is recovered after the age threshold: its lease and staged bytes go")
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

        // The writer died between the lease and publication.
        try Self.ageOutLeases()

        BodyAssetStore.recoverAbandonedPreparations()

        // Staged bytes are invisible to the user's attachment cap (`usedBytes` sums
        // only rows), so the reclaim must actually happen.
        #expect(!Self.stagedExists(prepared))
        #expect(!Self.blobExists(prepared.blobId))
        let leases = try Self.leaseCount()
        #expect(leases == 0)
        let rows = try Self.manifestRowCount(blobId: prepared.blobId)
        #expect(rows == 0)
    }

    /// Recovery is exact in both directions in one run: a live preparation's staged
    /// file stays, an abandoned one's goes, and a staged file with no lease at all
    /// (a writer that died after its lease was reaped) goes too.
    @Test("Recovery keeps a live preparation's staged bytes and deletes abandoned and unleased ones")
    func recoveryKeepsLiveAndDeletesAbandonedStagedFiles() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-recover")
        guard let abandoned = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "1.1",
            contentType: "application/pdf", data: Data(repeating: 0x31, count: 16),
            identityStamp: "rfc:lease-recover@example.com"
        ) else {
            Issue.record("prepare failed")
            return
        }
        try Self.ageOutLeases()
        guard let live = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "1.2",
            contentType: "application/pdf", data: Data(repeating: 0x32, count: 16),
            identityStamp: "rfc:lease-recover@example.com"
        ), let staging = BodyAssetStore.stagingDirectory() else {
            Issue.record("prepare failed")
            return
        }
        let unleased = staging.appendingPathComponent(UUID().uuidString)
        try Data("no lease".utf8).write(to: unleased)

        BodyAssetStore.recoverAbandonedPreparations()

        #expect(Self.stagedExists(live), "a live preparation's staged bytes must stay")
        #expect(!Self.stagedExists(abandoned), "an abandoned preparation's staged bytes must go")
        #expect(!FileManager.default.fileExists(atPath: unleased.path),
                "a staged file no lease names must go")
        let leases = try Self.leaseCount()
        #expect(leases == 1)
        #expect(BodyAssetStore.publish(live) == live.blobId)
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
        BodyAssetStore.pruneOrphanFiles()   // reaps the abandoned lease, skips staging
        // The staged bytes are still there, so the refusal below is the lease's.
        #expect(Self.stagedExists(prepared))

        // FAIL CLOSED. Publishing here would record a row the pending-delete worker
        // may already have settled for this key (#1376). The caller sees `nil`,
        // treats it as a cache miss, and re-fetches.
        #expect(BodyAssetStore.publish(prepared) == nil)
        let rows = try Self.manifestRowCount(blobId: prepared.blobId)
        #expect(rows == 0)
        #expect(!Self.blobExists(prepared.blobId), "a refused publish moves nothing into the store")
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: key, section: "2.1",
            identityStamp: "rfc:lease-5@example.com") == nil)
    }

    /// #1376: a re-fetch whose lease was reaped can change nothing about the slot it
    /// targets. Before staging, `prepare` had already overwritten the slot's file, so
    /// the published row then served bytes its publish was refused for.
    @Test("A refused publish leaves an existing slot's bytes and row as they were")
    func refusedPublishLeavesTheExistingSlotUntouched() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let key = ContentKey(rawValue: "acc1:INBOX:msg-lease-7")
        let stamp = "rfc:lease-7@example.com"
        guard let assetId = BodyAssetStore.writeAttachment(
            contentKey: key, section: "2", contentType: "application/pdf",
            data: Data("v1".utf8), identityStamp: stamp
        ), let prepared = BodyAssetStore.prepare(
            contentKey: key, kind: .attachment, key: "2",
            contentType: "application/pdf", data: Data("v2-longer".utf8),
            identityStamp: stamp
        ) else {
            Issue.record("write or prepare failed")
            return
        }
        #expect(prepared.blobId == assetId, "precondition: the re-fetch targets the same slot")

        try Self.ageOutLeases()
        BodyAssetStore.pruneOrphanFiles()

        #expect(BodyAssetStore.publish(prepared) == nil)
        #expect(BodyAssetStore.read(assetId: assetId) == Data("v1".utf8))
        let rows = try Self.manifestRowCount(blobId: assetId)
        #expect(rows == 1)
        #expect(BodyAssetStore.attachmentAssetId(
            contentKey: key, section: "2", identityStamp: stamp) == assetId)
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

    // MARK: - Header-directory reclaim: which blob ids count as "under this hash"

    /// A manifest row for a blob id that has no file on disk. Reachable in
    /// production whenever bytes are lost out of band (a partially-failed purge,
    /// an OS-level cleanup) and it is the shape that isolates the RELATIONAL half
    /// of the reclaim decision from the "is the directory empty" half.
    private static func insertManifestRow(blobId: String) throws {
        guard let queue = BodyAssetStore.manifestQueue() else {
            Issue.record("manifest queue unavailable")
            return
        }
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bodyAsset
                        (id, headerId, kind, contentId, attachmentSection,
                         contentType, sizeBytes, createdAt, lastAccessedAt, identityStamp)
                    VALUES (?, ?, 1, NULL, '2', 'application/pdf', 16, ?, NULL, NULL)
                    """,
                arguments: [
                    blobId, "acc1:INBOX:\(blobId)",
                    Int64(Date().timeIntervalSince1970 * 1000),
                ]
            )
        }
    }

    /// A preparation lease with an explicit age. `ageSeconds == 0` is a live
    /// writer; anything past `sweepMinAgeSeconds` is a writer presumed dead.
    /// Computed from `Date()`, never a literal.
    private static func insertLease(blobId: String, ageSeconds: TimeInterval) throws {
        guard let queue = BodyAssetStore.manifestQueue() else {
            Issue.record("manifest queue unavailable")
            return
        }
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bodyAssetPreparation (preparationId, blobId, createdAt)
                    VALUES (?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, blobId,
                    Int64((Date().timeIntervalSince1970 - ageSeconds) * 1000),
                ]
            )
        }
    }

    /// An empty header directory, aged past the sweep threshold so only the
    /// manifest-side decision is left standing between it and the reclaim.
    private static func makeAgedEmptyDirectory(_ hashName: String) throws {
        guard let storeDir = BodyAssetStore.storeDirectory() else {
            Issue.record("store directory unavailable")
            return
        }
        let url = storeDir.appendingPathComponent(hashName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try ageOut(path: url.path)
    }

    private static func directoryExists(_ hashName: String) -> Bool {
        guard let storeDir = BodyAssetStore.storeDirectory() else { return false }
        return FileManager.default.fileExists(
            atPath: storeDir.appendingPathComponent(hashName, isDirectory: true).path)
    }

    /// THE SYSTEM PROPERTY: a header directory is reclaimed exactly when no blob id
    /// **under that hash** is claimed by a manifest row or a live lease — and a blob
    /// id under a DIFFERENT hash is never "under this one", however close the two
    /// sort.
    ///
    /// Both directions in one run, which is what makes it a boundary test rather
    /// than a policy test:
    ///  - the claimed directory must SURVIVE — a predicate that stopped matching
    ///    (too narrow) would unlink a directory whose bytes something still
    ///    references;
    ///  - its lexicographic PREDECESSOR, claimed by nothing, must be RECLAIMED — a
    ///    predicate that matched too much (an unbounded `id >= prefix`, a prefix
    ///    test that ignores where the hash ends) would report it referenced and leak
    ///    the directory forever.
    ///
    /// Blob ids are `"<16 hex>/<16 hex>"`, so no header hash can be a proper prefix
    /// of another and the classic prefix-range trap is unreachable by length. The
    /// reachable trap is the ADJACENCY asserted here, plus the all-`f` case below
    /// where the exclusive upper bound leaves the hex alphabet.
    @Test("Header-directory reclaim: a claimed hash survives while its unclaimed neighbour is reclaimed")
    func headerDirectoryReclaimHonoursTheHashBoundary() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let claimed = "bbbbbbbbbbbbbbbb"
        let unclaimedPredecessor = "aaaaaaaaaaaaaaaa"
        try Self.insertManifestRow(blobId: "\(claimed)/1111111111111111")
        try Self.makeAgedEmptyDirectory(claimed)
        try Self.makeAgedEmptyDirectory(unclaimedPredecessor)

        BodyAssetStore.pruneOrphanFiles()

        #expect(Self.directoryExists(claimed),
                "a directory whose hash still has a manifest row must not be unlinked")
        #expect(!Self.directoryExists(unclaimedPredecessor),
                "a directory nothing claims must be reclaimed — a neighbouring hash's row is not a claim on it")
    }

    /// The successor boundary at the top of the hex alphabet: the exclusive upper
    /// bound of `ffffffffffffffff` is not a hex string at all. A directory claimed
    /// by a row must still survive there, and an unclaimed neighbour must still go.
    @Test("Header-directory reclaim: the all-f hash boundary keeps its claimed directory")
    func headerDirectoryReclaimHandlesTheTopOfTheHashAlphabet() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let claimed = "ffffffffffffffff"
        let unclaimed = "eeeeeeeeeeeeeeee"
        try Self.insertManifestRow(blobId: "\(claimed)/2222222222222222")
        try Self.makeAgedEmptyDirectory(claimed)
        try Self.makeAgedEmptyDirectory(unclaimed)

        BodyAssetStore.pruneOrphanFiles()

        #expect(Self.directoryExists(claimed),
                "the highest possible hash must still match its own rows")
        #expect(!Self.directoryExists(unclaimed),
                "the unclaimed neighbour must still be reclaimed")
    }

    /// The lease arm of the same decision, in the exact race the lease exists for:
    /// a writer that has inserted its lease and created the directory but has not
    /// yet written bytes. The directory is EMPTY and aged, so nothing but the live
    /// lease can save it.
    @Test("Header-directory reclaim: a live preparation lease keeps an empty, aged directory")
    func headerDirectoryReclaimRefusesWhileALeaseIsLive() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let leased = "cccccccccccccccc"
        try Self.insertLease(blobId: "\(leased)/3333333333333333", ageSeconds: 0)
        try Self.makeAgedEmptyDirectory(leased)

        BodyAssetStore.pruneOrphanFiles()

        #expect(Self.directoryExists(leased),
                "unlinking here would race a writer whose publish moves its file into this directory")
        let leases = try Self.leaseCount()
        #expect(leases == 1, "a live lease must not be reaped by the sweep")
    }

    /// Non-vacuity for the leg above: the SAME shape with an EXPIRED lease must be
    /// reclaimed. Without this, a reclaim that simply never fired would pass the
    /// live-lease test.
    ///
    /// ⚠ WHAT THIS TEST DOES **NOT** PIN, measured rather than assumed. It does not
    /// pin the reclaim predicate's `createdAt > ?` liveness THRESHOLD. Inverting that
    /// term alone — `createdAt > (? - 999999999999)`, i.e. "every lease is live" —
    /// leaves this test GREEN, verified under the build lock on 2026-08-05. The reason
    /// is ordering inside `pruneOrphanFiles`: the abandoned-lease REAP runs before the
    /// directory reclaim and has already deleted this row, so the reclaim's lease arm
    /// finds nothing to evaluate the threshold against and the outcome is the same
    /// either way. What IS pinned, and was proved RED in that same session by replacing
    /// the arm's predicate with a constant-false one, is that the lease arm is
    /// consulted at all — `headerDirectoryReclaimRefusesWhileALeaseIsLive` fails
    /// immediately without it. The threshold's own reachability lives on the callers
    /// that reclaim WITHOUT a preceding reap (`deleteAllAssets(forContentKey:)`), which
    /// no test here exercises; stated so the gap is visible rather than assumed closed.
    @Test("Header-directory reclaim: an expired preparation lease no longer keeps the directory")
    func headerDirectoryReclaimProceedsOnceTheLeaseExpires() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let abandoned = "dddddddddddddddd"
        try Self.insertLease(
            blobId: "\(abandoned)/4444444444444444",
            ageSeconds: BodyAssetStore.sweepMinAgeSeconds + 30)
        try Self.makeAgedEmptyDirectory(abandoned)

        BodyAssetStore.pruneOrphanFiles()

        #expect(!Self.directoryExists(abandoned),
                "a dead writer's lease may not pin an empty directory forever")
        let leases = try Self.leaseCount()
        #expect(leases == 0, "the abandoned lease itself must be reaped")
    }

    // MARK: - Orphan sweep: which files under a hash the manifest already accounts for

    /// Bytes on disk under `<store>/<hash>/<blob>`, aged past the sweep threshold so
    /// only the manifest-side classification is left standing between them and the
    /// physical deleter. Creates the header directory but deliberately does NOT age
    /// it, so the directory reclaim (a different predicate, already covered above)
    /// stays out of these tests.
    private static func writeAgedBlobFile(_ blobId: String, bytes: Data) throws {
        guard let storeDir = BodyAssetStore.storeDirectory() else {
            Issue.record("store directory unavailable")
            return
        }
        let url = storeDir.appendingPathComponent(blobId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        try ageOut(path: url.path)
    }

    /// How many times `body` put `blobId` through the physical-delete path: the
    /// manifest recheck `removeBlobIfUnreferenced` runs before it unlinks
    /// (`… FROM bodyAsset WHERE id = <blobId>`), counted from a statement trace on
    /// the test manifest's one connection (an in-memory `DatabaseQueue`).
    ///
    /// WHY A TRACE IS NEEDED AT ALL, stated so the next reader does not "simplify"
    /// these tests into vacuity: the classification below cannot be observed through
    /// file survival. `removeBlobIfUnreferenced` re-decides authoritatively under the
    /// manifest writer lock, so a manifest-backed file survives whether or not the
    /// sweep classified it correctly. What the classification decides is whether the
    /// sweep takes a WRITE transaction per already-accounted-for file — which is the
    /// whole point of the query, and which only the trace makes visible. (#1376
    /// replaced the earlier tracer, a lease with an empty preparation id that the
    /// delete path released: that parameter had no other caller left.)
    ///
    /// Recorded from `expandedDescription` (bound values inline), acceptable only
    /// because this manifest is a throwaway in-memory fixture.
    private static func manifestStatements(during body: () -> Void) -> [String] {
        guard let queue = BodyAssetStore.manifestQueue() else {
            Issue.record("manifest queue unavailable")
            return []
        }
        let tape = StatementTape()
        queue.inDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        body()
        queue.inDatabase { db in db.trace(options: .statement, nil) }
        return tape.statements()
    }

    private static func physicalDeleteChecks(of blobId: String, in statements: [String]) -> Int {
        statements.filter { $0.contains("FROM bodyAsset WHERE id = '\(blobId)'") }.count
    }

    /// THE SYSTEM PROPERTY: for a given header directory, `pruneOrphanFiles` counts a
    /// file as already accounted for exactly when the manifest holds a row for that
    /// blob id **under that hash** — so a file the manifest knows about is never
    /// handed to the physical deleter, and a file it does not know about is.
    ///
    /// Both directions in one run, in the SAME directory, which is what makes this a
    /// classification test rather than a "the sweep ran" test.
    ///
    /// ⚠ WHAT THIS TEST DOES **NOT** PIN, measured rather than assumed. It does not
    /// pin the predicate's UPPER bound. Widening it (up to and including selecting the
    /// whole table) leaves every assertion here GREEN, and that is a property of the
    /// system, not a gap in the test: the returned ids are compared for full-string
    /// equality against `"<hash>/<file>"`, so rows belonging to another hash can never
    /// match, and the ids are drawn from `bodyAsset` itself, so a match always implies
    /// a real row. Over-matching is therefore inert here — the reachable failure is
    /// UNDER-matching, which is what the assertions below catch.
    @Test("Orphan sweep: a manifest-backed file is spared the deleter while a true orphan beside it is not")
    func orphanSweepClassifiesFilesUnderTheHashByTheManifest() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let hash = "aaaaaaaaaaaaaaaa"
        let known = "\(hash)/1111111111111111"
        let orphan = "\(hash)/2222222222222222"

        try Self.insertManifestRow(blobId: known)
        try Self.writeAgedBlobFile(known, bytes: Data("known-bytes".utf8))
        try Self.writeAgedBlobFile(orphan, bytes: Data("orphan-bytes".utf8))

        let statements = Self.manifestStatements { BodyAssetStore.pruneOrphanFiles() }
        let knownChecks = Self.physicalDeleteChecks(of: known, in: statements)
        let orphanChecks = Self.physicalDeleteChecks(of: orphan, in: statements)

        // ACCOUNTED FOR: the sweep never reaches the deleter for it.
        #expect(knownChecks == 0,
                "a file the manifest already accounts for must not be run through the physical-delete path")
        #expect(Self.blobExists(known), "and its bytes must still be there")

        // NON-VACUITY, same run, same directory: the sweep provably DID run and DID
        // bite — otherwise the assertions above would pass on a sweep that did nothing.
        #expect(orphanChecks == 1, "the unaccounted-for file goes through the delete path once")
        #expect(!Self.blobExists(orphan),
                "an unaccounted-for file's bytes must be reclaimed")
    }

    /// The same classification at the top of the hash alphabet, where the exclusive
    /// upper bound of `ffffffffffffffff` is not a hex string at all. A hash that
    /// cannot match its own files there would hand every cached attachment of those
    /// messages to the deleter whenever the sweep runs (#1376: once after the update,
    /// and after a UIDVALIDITY reset's folder purge).
    @Test("Orphan sweep: the top of the hash alphabet still matches its own files")
    func orphanSweepMatchesFilesAtTheTopOfTheHashAlphabet() throws {
        let dir = try Self.setupTest()
        defer { Self.teardown(dir) }

        let hash = "ffffffffffffffff"
        let known = "\(hash)/3333333333333333"
        let orphan = "\(hash)/4444444444444444"

        try Self.insertManifestRow(blobId: known)
        try Self.writeAgedBlobFile(known, bytes: Data("known-bytes-at-the-top".utf8))
        try Self.writeAgedBlobFile(orphan, bytes: Data("orphan-bytes-at-the-top".utf8))

        let statements = Self.manifestStatements { BodyAssetStore.pruneOrphanFiles() }

        #expect(Self.physicalDeleteChecks(of: known, in: statements) == 0,
                "the highest possible hash must still match its own files")
        #expect(Self.physicalDeleteChecks(of: orphan, in: statements) == 1)
        #expect(Self.blobExists(known))

        #expect(!Self.blobExists(orphan), "the orphan beside it must still be reclaimed")
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
    /// existing install's attachment cache is a hard error rather than a miss. The
    /// upgrade runs through `migrateManifestSchema`, the entry point every manifest
    /// open calls, so the test fails if that entry point stops running the upgrade.
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
        try queue.write { db in try BodyAssetStore.migrateManifestSchema(db) }
        try queue.write { db in try BodyAssetStore.migrateManifestSchema(db) }
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

/// The statements a trace saw. `trace` fires on the database's own queue, so the
/// buffer is lock-protected.
private final class StatementTape: Sendable {
    private let buffer = Mutex<[String]>([])
    func record(_ sql: String) { buffer.withLock { $0.append(sql) } }
    func statements() -> [String] { buffer.withLock { $0 } }
}
