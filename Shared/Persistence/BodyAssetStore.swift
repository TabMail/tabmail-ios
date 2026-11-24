/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import CryptoKit
import Synchronization

/// Disk-backed asset store for inline CID images (`kind=0`) and file
/// attachments (`kind=1`).
///
/// **Cross-target by construction.** All bytes + manifest live in the App
/// Group container so the *same code path* — `writeInlineImage`,
/// `writeAttachment`, `read`, `contentType`, `bumpMessageAccess` — runs
/// identically in both the main app and the NSE extension. There is no
/// NSE-vs-main-app branch in this file.
///
/// Operations that need to coordinate with the main app's `messageHeader` /
/// `messageBody` tables (eviction's `messageBody` drop, the pending-delete
/// worker) live in `BodyAssetMaintenance` (main-app target only). NSE never
/// runs eviction inside its 30s budget anyway.
///
/// **Storage layout:**
/// - Bytes: `<appGroupContainer>/bodyAssets/<headerHash>/<assetHash>` (no extension).
/// - Manifest: `<appGroupContainer>/bodyAssetIndex.sqlite` — independent of
///   `AppDatabase` so NSE can write rows without reaching into the main-app
///   sandbox.
///
/// **LRU at the message level.** A bump sets `bodyAsset.lastAccessedAt` on
/// every row sharing a `headerId`. Bumped only on user tap
/// (open message body, tap attachment) — one `UPDATE … WHERE headerId = ?`
/// touches all of a message's assets. Initial writes leave it NULL so
/// never-tapped messages evict first; an asset written after its message's
/// last bump is NULL too, so eviction places a message by its rows' latest
/// access (`evictionVictims`).
///
/// **Write/delete idempotency** — a manifest-side preparation lease is
/// persisted before file materialization, and `prepare` writes the bytes into
/// `staging/<preparationId>`, never into the store. `publish` moves them into
/// place inside the manifest write transaction that proves it still holds its
/// lease and records the row, so a file in the store always has a row (#1376).
/// Deletes unlink a row's file BEFORE deleting the row, in one manifest write
/// transaction: a crash in between leaves a row whose file is gone, which a read
/// notices (`BodyAssetSchemeHandler`'s missing-file report), never a file no row
/// names. A lease only protects a write for `sweepMinAgeSeconds`; past that its
/// writer is presumed dead (see `abandonedPreparationCutoffMs`), and
/// `recoverAbandonedPreparations` reaps the lease and its staging file. A
/// message's assets are deleted from the main database's `bodyAssetPendingDelete`
/// list (`deletePendingContentKey`, driven by `BodyAssetMaintenance`); nothing
/// sweeps the whole store.
enum BodyAssetKind: Int, Sendable, Codable {
    case inlineImage = 0
    case attachment  = 1
}

enum BodyAssetStore {
    // MARK: - Internal config (private; not part of cross-module surface)

    /// Hex chars for `headerHash` and `assetHash` (64 bits each).
    /// Birthday paradox at 10^7 items: collision probability ≈ 10^-9.
    static let hashHexLength = 16

    /// Sweep skip threshold — files newer than this age are not orphan candidates
    /// (race guard for in-flight write→insert). Also the lifetime of a
    /// preparation lease and the idle age an empty header directory must reach
    /// before the sweep reclaims it: all three answer the same question ("could
    /// a live writer still be working on this?"), so they share one threshold.
    static let sweepMinAgeSeconds: TimeInterval = 60

    /// Top-level directory name inside the App Group container.
    private static let storeDirectoryName = "bodyAssets"

    /// Directory inside the store where `prepare` writes a preparation's bytes,
    /// named by its preparation id, until `publish` moves them into place
    /// (#1376). Not `hashHexLength` characters long, so `pruneOrphanFiles`
    /// never treats it as a header directory.
    private static let stagingDirectoryName = "staging"

    /// Rows per manifest write transaction in `deleteAllAssets(kind:)`, which
    /// unlinks each row's file inside the transaction: bounds how long one wipe
    /// holds the cross-process writer lock the notification extension also takes.
    private static let wipeBatchSize = 200

    /// Manifest DB filename inside the App Group container.
    private static let manifestDBName = "bodyAssetIndex.sqlite"

    // MARK: - Internal state

    /// Shared `DatabaseQueue` over the App Group manifest DB. Initialized on
    /// first access. `Mutex` for thread-safe lazy init.
    private static let queueCache = Mutex<DatabaseQueue?>(nil)

    /// Cached total `usedBytes`. `nil` = invalidated.
    private static let usedBytesCache = Mutex<Int64?>(nil)

    /// Test-injection: when both are set, `manifestQueue()` returns the
    /// supplied queue and `storeDirectory()` returns the supplied URL,
    /// bypassing the App Group container entirely.
    private static let testOverride = Mutex<(containerURL: URL, queue: DatabaseQueue)?>(nil)

    /// The main app's "does this content key still name a message?" check, which
    /// `publish` asks while its lease is held (#1376). Nil in the notification
    /// extension, which cannot read the main database: the merge queues its
    /// staged keys for deletion instead (`NSEDataBridge.queueStagedAssetKey`).
    private static let publishOwnerCheck = Mutex<(@Sendable (ContentKey) -> Bool)?>(nil)

    private static func invalidateUsedBytesCache() {
        usedBytesCache.withLock { $0 = nil }
    }

    /// Returns the manifest queue, lazily creating + migrating it.
    /// Returns nil if the App Group container is unavailable.
    static func manifestQueue() -> DatabaseQueue? {
        if let test = testOverride.withLock({ $0?.queue }) { return test }
        if let existing = queueCache.withLock({ $0 }) { return existing }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BodyAssetConfig.appGroup
        ) else {
            #if DEBUG
            print("[BodyAssetStore] App Group container unavailable")
            #endif
            return nil
        }
        let dbURL = container.appendingPathComponent(manifestDBName)
        var config = Configuration()
        config.busyMode = .timeout(5)
        // 0xdead10cc defense in the MAIN APP (ADR-IOS-041): DatabaseSuspension
        // posts GRDB's suspend notification before process suspension so the
        // 1.6.x crash class (pruneOrphans/deleteAllAssets mid-write at suspend)
        // aborts cleanly instead. Inert in the NSE process — nothing posts the
        // notification there, and the NSE is terminated, not suspended.
        config.observesSuspensionNotifications = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: dbURL.path, configuration: config)
            try queue.write { db in try migrateManifestSchema(db) }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] manifest DB open/migrate failed: \(error)")
            #endif
            return nil
        }
        queueCache.withLock { $0 = queue }
        return queue
    }

    /// The manifest's whole schema: the fresh-install path and the upgrade path in one, run by
    /// `manifestQueue()` on every open and by `_makeTestQueue()`, so tests plan their queries on
    /// the schema devices have.
    ///
    /// `idx_bodyAsset_lruSize` serves the two reads eviction makes in every maintenance run
    /// (ios#1382). `usedBytes`' `SUM(sizeBytes)` reads only this index's entries, never the table
    /// rows. `evictionVictims` walks it in access order, so it never aggregates and sorts every
    /// message to find the oldest few. It replaces `idx_bodyAsset_lru (lastAccessedAt)`, which is
    /// its prefix: an existing manifest builds the new index once, then drops the old one.
    ///
    /// `idx_bodyAsset_headerAccess (headerId, lastAccessedAt)` gives the walk each message's latest
    /// access in one seek of the index, without reading the message's rows. It replaces
    /// `idx_bodyAsset_header (headerId)`, which is its prefix and serves every other `headerId`
    /// lookup the same way, in the same build-then-drop order.
    ///
    /// QUERY COST (keep this note; QueryCostNoteFenceTests checks it): every query, index, table
    /// or column added here, and every query that reads them, must be as cheap as the data allows.
    /// It must not add a new table or index scan unless no index or plainer query can avoid it;
    /// then state why at the query. Prove a query or index change on a mail-sized database with the
    /// DBProof harness (TabMailTests/Helpers/DBProofHarness.swift).
    static func migrateManifestSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bodyAsset (
                id                TEXT PRIMARY KEY,
                headerId          TEXT NOT NULL,
                kind              INTEGER NOT NULL,
                contentId         TEXT,
                attachmentSection TEXT,
                contentType       TEXT NOT NULL,
                sizeBytes         INTEGER NOT NULL,
                createdAt         INTEGER NOT NULL,
                lastAccessedAt    INTEGER,
                identityStamp     TEXT
            )
            """)
        try migratePreparationSchema(db)
        try migrateAttachmentIdentitySchema(db)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_headerAccess ON bodyAsset (headerId, lastAccessedAt)")
        try db.execute(sql: "DROP INDEX IF EXISTS idx_bodyAsset_header")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_lruSize ON bodyAsset (lastAccessedAt, headerId, sizeBytes)")
        try db.execute(sql: "DROP INDEX IF EXISTS idx_bodyAsset_lru")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_attachmentLookup ON bodyAsset (headerId, kind, attachmentSection)")
    }

    /// Ad-hoc migration for the prepare→publish lease table.
    ///
    /// The `bodyAsset` manifest is a SEPARATE database from `AppDatabase` (it
    /// lives in the App Group so the NSE can write it), so it has no GRDB
    /// `DatabaseMigrator`. Schema evolution is therefore the same
    /// `CREATE … IF NOT EXISTS` idiom the manifest's own table already uses:
    /// it is both the fresh-install path and the upgrade path, so a FRESH
    /// manifest and a manifest that predates leases converge on the identical
    /// schema and the identical expiry semantics.
    ///
    /// `createdAt` is written by `prepare` and READ by
    /// `abandonedPreparationCutoffMs` — a lease older than `sweepMinAgeSeconds`
    /// stops protecting its blob.
    static func migratePreparationSchema(_ db: Database) throws {
        // Cross-process lease table for the prepare -> publish boundary.
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bodyAssetPreparation (
                preparationId TEXT PRIMARY KEY,
                blobId       TEXT NOT NULL,
                createdAt    INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_bodyAssetPreparation_blob
            ON bodyAssetPreparation(blobId)
            """)
    }

    /// Ad-hoc migration for `bodyAsset.identityStamp` — the ATTACHMENT cache's
    /// identity binding (ADR-IOS-066 / T5.1).
    ///
    /// ⚑ WHY THE COLUMN EXISTS — the invariant, not an instance. An attachment is
    /// looked up by `(headerId, kind, attachmentSection)`. BOTH halves of that
    /// address are mutable and reusable:
    ///   - `headerId` is a CONTENT key, `"<accountId>:<folderPath>:<tail>"`, and at
    ///     the current stage the tail is the provider message id — an IMAP UID. A
    ///     `UIDVALIDITY` change reassigns that UID to a DIFFERENT physical message,
    ///     so the same key names a different message before and after;
    ///   - `attachmentSection` is a positional MIME part path (`"2"`, `"1.2"`), which
    ///     essentially every multipart message reuses.
    /// The `UIDVALIDITY` reaction purges this manifest, but that purge is explicitly
    /// best-effort and non-aborting (see `AccountManagerUidValidityReset`'s step 4
    /// comment), and the reaction refuses to start at all for a folder with no
    /// recorded epoch. A surviving row is therefore reachable, and without a positive
    /// identity check the user is served a STRANGER'S ATTACHMENT under their own
    /// message's name. `ContentKey` does not close this: `ContentKey.forHeader` is
    /// inert at Stage B and returns `MessageHeader.id` verbatim, so the newtype
    /// separates two key SPACES, not two MESSAGES at one address.
    ///
    /// ⚑ NULL IS NOT A MISMATCH — IT IS AN UNANSWERED QUESTION. A NULL stamp never
    /// matches the `identityStamp = ?` bind in `attachmentAssetId`, so a legacy row
    /// is a strict cache MISS and the attachment is RE-FETCHED. Nothing here, and
    /// nothing downstream, may delete a row because its stamp is absent or differs —
    /// only `deleteAllAssets` / eviction / the orphan sweeps delete, and all of them
    /// key by content key alone, exactly as before.
    ///
    /// PORT of `v2final`'s `BodyAssetStore.migrateIdentityBoundSchema` (commit
    /// `486bafd4b`), narrowed to ONE column. The manifest is a SEPARATE database from
    /// `AppDatabase` — it lives in the App Group so the NSE can write it — so it has
    /// no GRDB `DatabaseMigrator` and no numbered `vNN`; schema evolution is the same
    /// `PRAGMA table_info` + `ALTER TABLE ADD COLUMN` idiom the reference used.
    ///
    /// CONVERGENCE: a FRESH manifest is created by the `CREATE TABLE` in
    /// `migrateManifestSchema`, which already lists `identityStamp`,
    /// so the `ALTER` here is skipped; an EXISTING manifest gets the column added
    /// here. Both end with the identical schema — the create statements and this
    /// addition list must be kept in lockstep.
    static func migrateAttachmentIdentitySchema(_ db: Database) throws {
        let columns = Set(
            try Row.fetchAll(db, sql: "PRAGMA table_info(bodyAsset)")
                .map { $0["name"] as String }
        )
        let additions: [(String, String)] = [
            ("identityStamp", "TEXT"),
        ]
        for (name, type) in additions where !columns.contains(name) {
            try db.execute(sql: "ALTER TABLE bodyAsset ADD COLUMN \(name) \(type)")
        }
    }

    // MARK: - Public: budget

    /// User-facing attachments cap, in MB. Backed by `UserDefaults(suiteName: appGroup)`
    /// so main app and NSE see the same value. `Int.max` = "Unlimited".
    ///
    /// We deliberately do NOT fall back to `UserDefaults.standard` if the App
    /// Group suite is unavailable. Each target's `.standard` is a different
    /// container — falling back would cause silent cap divergence between
    /// main-app and NSE. Instead we return the compile-time default (read) or
    /// drop the write (verified-broken entitlements is a config bug, not a
    /// runtime error). In practice the suite is always available since both
    /// targets ship with the entitlement.
    static var attachmentsBudgetMB: Int {
        get {
            guard let defaults = UserDefaults(suiteName: BodyAssetConfig.appGroup) else {
                #if DEBUG
                print("[BodyAssetStore] App Group UserDefaults suite unavailable — using compile-time default")
                #endif
                return BodyAssetConfig.defaultAttachmentsBudgetMB
            }
            let raw = defaults.object(forKey: BodyAssetConfig.attachmentsBudgetMBKey) as? Int
            return raw ?? BodyAssetConfig.defaultAttachmentsBudgetMB
        }
        set {
            guard let defaults = UserDefaults(suiteName: BodyAssetConfig.appGroup) else {
                #if DEBUG
                print("[BodyAssetStore] App Group UserDefaults suite unavailable — write dropped")
                #endif
                return
            }
            defaults.set(newValue, forKey: BodyAssetConfig.attachmentsBudgetMBKey)
        }
    }

    /// Total bytes across both kinds. Cached; invalidated on any write/delete.
    /// The sum reads only `idx_bodyAsset_lruSize`'s entries, which carry `sizeBytes`, never the
    /// table rows (ios#1382). It is recomputed from the rows, never kept as a running total.
    static var usedBytes: Int64 {
        if let cached = usedBytesCache.withLock({ $0 }) { return cached }
        guard let queue = manifestQueue() else { return 0 }
        let value: Int64
        do {
            value = try queue.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset") ?? 0
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] usedBytes read failed: \(error)")
            #endif
            return 0
        }
        usedBytesCache.withLock { $0 = value }
        return value
    }

    /// Per-kind bytes (for Settings display + tests).
    static func usedBytes(kind: BodyAssetKind) -> Int64 {
        guard let queue = manifestQueue() else { return 0 }
        do {
            return try queue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset WHERE kind = ?",
                    arguments: [kind.rawValue]
                ) ?? 0
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] usedBytes(kind:) read failed: \(error)")
            #endif
            return 0
        }
    }

    // MARK: - Public: hashing + URL helpers

    /// First `hashHexLength` hex chars of SHA-256(headerId). Used as the per-message
    /// folder name on disk. Identical computation across both targets.
    static func headerHash(_ contentKey: ContentKey) -> String {
        sha256Hex(contentKey.rawValue, take: hashHexLength)
    }

    private static func assetHash(_ input: String) -> String {
        sha256Hex(input, take: hashHexLength)
    }

    private static func sha256Hex(_ input: String, take: Int) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(take).lowercased()
    }

    /// Builds the absolute scheme URL for an assetId.
    static func absoluteURL(forAssetId id: String) -> String {
        "\(BodyAssetConfig.urlScheme)://\(id)"
    }

    /// Parses `tabmail-asset://<headerHash>/<assetHash>` → assetId.
    static func assetId(fromURL url: URL) -> String? {
        guard url.scheme == BodyAssetConfig.urlScheme else { return nil }
        guard let host = url.host(), !host.isEmpty,
              host.count == hashHexLength else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let assetSeg = segments.first,
              assetSeg.count == hashHexLength else { return nil }
        return "\(host)/\(assetSeg)"
    }

    // MARK: - Paths

    /// App Group `bodyAssets/` dir, creating if needed. Nil if container unavailable.
    static func storeDirectory() -> URL? {
        let container: URL
        if let test = testOverride.withLock({ $0?.containerURL }) {
            container = test
        } else {
            guard let real = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: BodyAssetConfig.appGroup
            ) else { return nil }
            container = real
        }
        let dir = container.appendingPathComponent(storeDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// File URL for an existing asset row (for QuickLook + debug).
    static func urlOnDisk(assetId: String) -> URL? {
        guard let dir = storeDirectory() else { return nil }
        let url = dir.appendingPathComponent(assetId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Folder URL for a given content key (debug/reporting only).
    static func folder(for contentKey: ContentKey) -> URL? {
        storeDirectory()?.appendingPathComponent(headerHash(contentKey), isDirectory: true)
    }

    /// `<store>/staging/`, creating it if needed. Nil if the container is unavailable.
    static func stagingDirectory() -> URL? {
        guard let dir = storeDirectory() else { return nil }
        let staging = dir.appendingPathComponent(stagingDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: staging.path) {
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        return staging
    }

    /// Where `prepare` writes this preparation's bytes until `publish`.
    static func stagingURL(for prepared: PreparedWrite) -> URL? {
        stagingDirectory()?.appendingPathComponent(prepared.preparationId)
    }

    /// Installs (or, with nil, removes) the check `publish` asks before it records
    /// a row. The main app installs it once at launch.
    static func setPublishOwnerCheck(_ check: (@Sendable (ContentKey) -> Bool)?) {
        publishOwnerCheck.withLock { $0 = check }
    }

    /// Bytes already materialised in `staging/<preparationId>`, awaiting manifest
    /// publication.
    ///
    /// The blob id IS the logical slot id (`"<headerHash>/<assetHash(key)>"`) —
    /// the same address the published row's `id` carries, which is what keeps
    /// the `tabmail-asset://` URLs already baked into cached HTML resolvable and
    /// keeps "write the same (contentKey, key) twice" a single-slot overwrite.
    /// Two consequences:
    ///   - `prepare` ALWAYS re-materialises the bytes (it cannot assume an
    ///     existing file holds the same content, because the address does not
    ///     name the content);
    ///   - the slot's file changes only inside `publish`'s manifest transaction,
    ///     together with its row (#1376), so a publication refused before the
    ///     `rename` (lease lost, owner check) leaves the slot, and any row that
    ///     names it, exactly as they were. After the `rename` there are two
    ///     exceptions: a transaction that fails removes the moved file, so an older
    ///     row of the same slot names a missing file (a read notices and refetches);
    ///     and a process killed between the `rename` and the COMMIT leaves a store
    ///     file no row names, which only a UIDVALIDITY purge or the local index wipe
    ///     reclaims (IOS-ASSET-004).
    struct PreparedWrite: Sendable {
        let preparationId: String
        let blobId: String
        let contentKey: ContentKey
        let kind: BodyAssetKind
        let key: String
        let contentType: String
        let sizeBytes: Int
        /// The identity of the message these bytes were fetched FOR, as minted by
        /// `AttachmentCacheIdentity.stamp(for:)`. Non-nil for `.attachment`, nil for
        /// `.inlineImage` (whose reader addresses immutable content by asset id out
        /// of the rendered HTML rather than by the mutable `(headerId, cid)` slot).
        let identityStamp: String?
    }

    // MARK: - Public: writes (identical path in NSE and main app)

    /// Writes inline image bytes. Returns the assetId on success, nil on failure.
    ///
    /// Deliberately UNSTAMPED. An inline image is never looked up by its
    /// `(headerId, contentId)` slot: the only reader is `BodyAssetSchemeHandler`,
    /// which resolves the `tabmail-asset://<assetId>` URL that `makeInlineImageWriter`
    /// baked into the cached HTML, and that URL is emitted only after the bytes for
    /// THAT render succeeded. A replacement occupant at the same content key renders
    /// its OWN body, so it references its own asset ids and overwrites the slot it
    /// shares. See `writeAttachment` for why the attachment path cannot make that
    /// argument.
    static func writeInlineImage(
        contentKey: ContentKey, contentId: String, contentType: String, data: Data
    ) -> String? {
        write(contentKey: contentKey, kind: .inlineImage, key: contentId,
              contentType: contentType, data: data, identityStamp: nil)
    }

    /// Writes attachment bytes. Returns the assetId on success, nil on failure.
    ///
    /// `identityStamp` is REQUIRED and deliberately has NO default: it is the only
    /// thing that makes the `(contentKey, section)` slot — two mutable, reusable
    /// halves — safe to read back. A defaulted stamp would let a new writer be added
    /// that silently records nothing while `attachmentAssetId` still reads as though
    /// it were protected. Mint it with `AttachmentCacheIdentity.stamp(for:)`; when
    /// that returns nil the message's identity is UNPROVEN and the caller must not
    /// cache at all.
    static func writeAttachment(
        contentKey: ContentKey, section: String, contentType: String, data: Data,
        identityStamp: String
    ) -> String? {
        write(contentKey: contentKey, kind: .attachment, key: section,
              contentType: contentType, data: data, identityStamp: identityStamp)
    }

    /// Materialises bytes in `staging/<preparationId>` WITHOUT publishing a
    /// manifest row, under a persisted preparation lease.
    ///
    /// The lease is inserted BEFORE the staging file is written, so a staging
    /// file always has a lease until `publish` or a discard releases it. A crash
    /// anywhere after this point leaves at worst a staging file plus an abandoned
    /// lease; the lease ages out on `sweepMinAgeSeconds`
    /// (`abandonedPreparationCutoffMs`) and `recoverAbandonedPreparations` deletes
    /// both. The store itself is never touched until `publish` (#1376).
    ///
    /// The lease also tells the pending-delete worker that a write for this
    /// content key is in progress (`deletePendingContentKey`).
    ///
    /// Not `private` only so the prepare→publish boundary is directly testable;
    /// production reaches it through `write`.
    static func prepare(
        contentKey: ContentKey, kind: BodyAssetKind, key: String,
        contentType: String, data: Data, identityStamp: String?
    ) -> PreparedWrite? {
        guard let staging = stagingDirectory(), let queue = manifestQueue() else { return nil }
        let hHash = headerHash(contentKey)
        let aHash = assetHash(key)
        let blobId = "\(hHash)/\(aHash)"
        let prepared = PreparedWrite(
            preparationId: UUID().uuidString,
            blobId: blobId,
            contentKey: contentKey,
            kind: kind,
            key: key,
            contentType: contentType,
            sizeBytes: data.count,
            identityStamp: identityStamp
        )

        // 1. Lease FIRST, before the filesystem is touched at all. Every
        // physical deleter consults this table under the same SQLite writer
        // lock, including deleters running in the other process.
        do {
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO bodyAssetPreparation
                            (preparationId, blobId, createdAt)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [
                        prepared.preparationId,
                        prepared.blobId,
                        Int64(Date().timeIntervalSince1970 * 1000),
                    ]
                )
            }
        } catch {
            // Fail closed — no lease means no protection, so we do not write
            // bytes we could not defend. The fetch retries later.
            // Debug-gated because `Shared/` also compiles into the NSE, where
            // `DebugModeManager` does not exist.
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] preparation lease failed for \(blobId): \(error)")
            }
            #endif
            return nil
        }

        // 2. File second, into staging, named by the preparation id. Always
        // re-materialised: the blob id names the logical slot, not the bytes, so
        // an existing file may hold DIFFERENT content. Not `.atomic`: nothing
        // reads a staging file before `publish` moves it, and a plain write leaves
        // no temporary file beside it.
        do {
            try data.write(to: staging.appendingPathComponent(prepared.preparationId))
        } catch {
            discardPrepared(prepared)
            #if DEBUG
            print("[BodyAssetStore] file write failed for \(blobId): \(error)")
            #endif
            return nil
        }

        return prepared
    }

    /// Publishes a prepared blob: moves its staging file into the store and
    /// records its row, in one manifest write transaction. Refuses — recording
    /// and moving NOTHING — when this preparation no longer owns its lease, so a
    /// writer whose lease was reaped can never put a file or a row into the store.
    /// Initial write does NOT bump LRU.
    ///
    /// #1376: it also refuses when the content key no longer names a message
    /// (the main app's `publishOwnerCheck`). The check runs while the lease is
    /// held, and the pending-delete worker never deletes a key's assets while a
    /// lease under the key is live, so a write for a message deleted before or
    /// during it either publishes before the worker deletes, or is refused here:
    /// no row is left for a key nothing will delete.
    ///
    /// Not `private` only so the prepare→publish boundary is directly testable;
    /// production reaches it through `write`.
    static func publish(_ prepared: PreparedWrite) -> String? {
        guard let queue = manifestQueue(), let dir = storeDirectory(),
              let stagedURL = stagingURL(for: prepared) else { return nil }
        if let ownerCheck = publishOwnerCheck.withLock({ $0 }), !ownerCheck(prepared.contentKey) {
            #if DEBUG
            print("[BodyAssetStore] publish refused for \(prepared.blobId): its content key names no message")
            #endif
            return nil
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let contentIdValue: String? = (prepared.kind == .inlineImage) ? prepared.key : nil
        let attachmentSectionValue: String? = (prepared.kind == .attachment) ? prepared.key : nil
        let finalURL = dir.appendingPathComponent(prepared.blobId)
        var movedIntoPlace = false
        let published: Bool

        do {
            published = try queue.write { db -> Bool in
                // This no-op UPDATE proves that this preparation still owns its
                // lease and acquires SQLite's cross-process writer lock before
                // the store or the manifest row is touched.
                try db.execute(
                    sql: """
                        UPDATE bodyAssetPreparation
                        SET createdAt = createdAt
                        WHERE preparationId = ? AND blobId = ?
                        """,
                    arguments: [prepared.preparationId, prepared.blobId]
                )
                guard db.changesCount == 1 else { return false }

                // The file goes into place under the writer lock, so every deleter
                // (each holds the same lock) sees the file and its row together.
                // `rename` replaces an existing slot file atomically: a reader sees
                // the old bytes or the new ones, never a missing file. The header
                // directory cannot be removed under us: `removeHeaderDirectoryIfIdle`
                // runs under the same lock and keeps a directory a live lease names.
                try FileManager.default.createDirectory(
                    at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard rename(stagedURL.path, finalURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                movedIntoPlace = true

                // ⚑ THE CONFLICT UPDATE MUST CARRY THE STAMP. `blobId` names the
                // logical SLOT, not the bytes, and `prepare` ALWAYS re-materialises
                // the file — so by the time this runs, the slot already holds THIS
                // writer's bytes. Leaving a previous occupant's `identityStamp` in
                // place would make the row describe one message while its bytes are
                // another's: the manifest would be lying, and the lie would point at
                // the message whose attachment this ISN'T. Overwriting the stamp is
                // the truthful record, and it is not an invalidation of anything —
                // the prior bytes are already gone.
                try db.execute(
                    sql: """
                    INSERT INTO bodyAsset (id, headerId, kind, contentId, attachmentSection,
                                           contentType, sizeBytes, createdAt, lastAccessedAt,
                                           identityStamp)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        contentType = excluded.contentType,
                        sizeBytes = excluded.sizeBytes,
                        identityStamp = excluded.identityStamp
                    """,
                    arguments: [
                        prepared.blobId, prepared.contentKey, prepared.kind.rawValue,
                        contentIdValue, attachmentSectionValue,
                        prepared.contentType, prepared.sizeBytes, nowMs,
                        prepared.identityStamp
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM bodyAssetPreparation WHERE preparationId = ?",
                    arguments: [prepared.preparationId]
                )
                return true
            }
        } catch {
            // The transaction rolled back after the file went into place: take the
            // file out again, so the store never holds a file its row does not
            // describe. A row that named the slot before now has no file, which a
            // read notices and refetches.
            if movedIntoPlace {
                try? FileManager.default.removeItem(at: finalURL)
            }
            // ADR-IOS-046: a database-suspension abort (SQLITE_ABORT/INTERRUPT) is
            // expected + benign — the asset row re-writes on the next wake. Don't
            // log it as a failure. (Shared with the NSE target, so this uses GRDB's
            // built-in `isInterruptionError` rather than the app-only
            // `Error.isDatabaseSuspensionAbort` helper.)
            if (error as? DatabaseError)?.isInterruptionError != true {
                #if DEBUG
                print("[BodyAssetStore] row publish failed for \(prepared.blobId): \(error)")
                #endif
            }
            return nil
        }

        guard published else { return nil }
        invalidateUsedBytesCache()
        return prepared.blobId
    }

    private static func write(
        contentKey: ContentKey, kind: BodyAssetKind, key: String,
        contentType: String, data: Data, identityStamp: String?
    ) -> String? {
        guard let prepared = prepare(
            contentKey: contentKey,
            kind: kind,
            key: key,
            contentType: contentType,
            data: data,
            identityStamp: identityStamp
        ) else { return nil }
        let result = publish(prepared)
        if result == nil {
            discardPrepared(prepared)
        }
        return result
    }

    /// Cutoff (epoch ms) at or before which a preparation lease is treated as
    /// ABANDONED — its writer died between the lease INSERT and publish/discard.
    ///
    /// WHY THIS EXISTS. A live lease tells the pending-delete worker that a write
    /// for its key is in progress (`deletePendingContentKey` keeps the entry), and
    /// keeps its header directory and staging file. Without an expiry it would do
    /// so FOREVER when the writer never returns — very plausible for the NSE inside
    /// its 30s budget: the worker would never finish the key, and the staging file
    /// would never go (`usedBytes` sums only `bodyAsset.sizeBytes`, so it would also
    /// be invisible to the user's attachment cap). Past `sweepMinAgeSeconds` the
    /// lease is abandoned: `recoverAbandonedPreparations` reaps it with its staging
    /// file, and the worker reaps it in the transaction that deletes its key.
    ///
    /// WHY EXPIRY IS SAFE. Reaping a lease can never publish bad state:
    /// `publish` re-proves ownership of its own lease row (`changesCount == 1`)
    /// before touching `bodyAsset`, so a writer whose lease expired REFUSES to
    /// publish rather than leaving a manifest row pointing at unlinked bytes.
    /// The worst case is a wasted fetch that self-heals on retry, and the caller
    /// sees the same `nil` it sees for any other write failure — never a row that
    /// claims content we do not have. A YOUNG lease is never reaped, and a
    /// PUBLISHED blob is protected by its manifest row regardless of any lease.
    private static func abandonedPreparationCutoffMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 - sweepMinAgeSeconds) * 1000)
    }

    /// Gives up a preparation: deletes its staging file, then releases its lease.
    /// The store is never touched: a preparation's bytes enter it only inside
    /// `publish`. The staging file is this preparation's alone (named by its id),
    /// so it needs no check; if the process dies between the two steps, the lease
    /// ages out and `recoverAbandonedPreparations` reaps it.
    static func discardPrepared(_ prepared: PreparedWrite) {
        if let stagedURL = stagingURL(for: prepared) {
            try? FileManager.default.removeItem(at: stagedURL)
        }
        guard let queue = manifestQueue() else { return }
        do {
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM bodyAssetPreparation WHERE preparationId = ?",
                    arguments: [prepared.preparationId]
                )
            }
        } catch {
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] preparation release failed for \(prepared.blobId): \(error)")
            }
            #endif
        }
    }

    /// #1376: crash recovery for writes, run by the main app's maintenance pass
    /// (foreground only, ADR-IOS-046). Reaps every abandoned preparation lease, then
    /// deletes each staging file whose lease is gone. It lists only `staging/`,
    /// which holds only writes in progress, never the store.
    ///
    /// Exact: a lease is inserted before its staging file is written, and both run
    /// in one manifest write transaction here, so a staging file whose lease this
    /// transaction cannot see was published, discarded or abandoned, and its
    /// preparation id is never leased again. A writer whose lease is reaped here
    /// and that writes on later has its `publish` refused, and discards the file.
    static func recoverAbandonedPreparations() {
        guard let queue = manifestQueue(), let staging = stagingDirectory() else { return }
        do {
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM bodyAssetPreparation WHERE createdAt <= ?",
                    arguments: [abandonedPreparationCutoffMs()]
                )
                let leased = Set(try String.fetchAll(
                    db, sql: "SELECT preparationId FROM bodyAssetPreparation"
                ))
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: staging, includingPropertiesForKeys: nil
                )) ?? []
                for file in files where !leased.contains(file.lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] abandoned preparation recovery failed: \(error)")
            }
            #endif
        }
    }

    /// Atomically guards a physical unlink with the manifest-side reachability
    /// check, for `pruneOrphanFiles`, which walks files it knows nothing about.
    /// The DELETE is always the first statement — it reaps any abandoned lease on
    /// the same blob, and it acquires the SQLite writer lock before the SELECT and
    /// the filesystem action.
    private static func removeBlobIfUnreferenced(_ blobId: String) {
        guard let queue = manifestQueue(), let dir = storeDirectory() else { return }
        do {
            try queue.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM bodyAssetPreparation
                        WHERE blobId = ? AND createdAt <= ?
                        """,
                    arguments: [blobId, abandonedPreparationCutoffMs()]
                )
                // The DELETE above already removed every abandoned lease on this
                // blob, so surviving `bodyAssetPreparation` rows are live ones.
                //
                // `SELECT EXISTS(…)` is a FROM-less scalar select: it always
                // yields exactly one row, so this `fetchOne` is non-nil by
                // construction. Binding it keeps the impossible case fail-closed
                // (leave the file) without dressing dead code up as a policy.
                guard let referenced = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM bodyAsset WHERE id = ?
                            UNION ALL
                            SELECT 1 FROM bodyAssetPreparation WHERE blobId = ?
                        )
                        """,
                    arguments: [blobId, blobId]
                ), !referenced else { return }
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent(blobId)
                )
            }
        } catch {
            // Fail closed: an unavailable manifest leaves the file behind. Debug-gated
            // because `Shared/` also compiles into the NSE, where `DebugModeManager`
            // does not exist.
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] unreferenced-blob check failed for \(blobId): \(error)")
            }
            #endif
        }
    }

    /// The EXCLUSIVE upper bound of the half-open range that selects exactly the
    /// strings beginning with `prefix`, under SQLite's default BINARY collation:
    /// `prefix` with its final Unicode scalar incremented by one.
    ///
    /// Used so a prefix test can be an indexable range instead of
    /// `substr(col, 1, n) = ?`, which hides the column inside a function and
    /// forces a table/index SCAN. Blob ids are hex + `'/'`, so the scalar being
    /// incremented is always ASCII and the `+ 1` cannot leave Unicode's range;
    /// `nil` is returned only for an empty prefix, whose callers treat it as
    /// "cannot decide" and keep whatever they were considering removing.
    private static func prefixUpperBound(_ prefix: String) -> String? {
        guard let last = prefix.unicodeScalars.last,
              let bumped = UnicodeScalar(last.value + 1) else { return nil }
        return String(String.UnicodeScalarView(prefix.unicodeScalars.dropLast())) + String(bumped)
    }

    /// Reclaims `<store>/<headerHash>/` once it is provably idle.
    ///
    /// "Idle" is decided under the manifest's cross-process writer lock: no
    /// manifest row and no LIVE preparation lease names a blob under this hash,
    /// and the directory is empty on disk. `publish` creates the directory and
    /// moves its file in under the same lock, so the two never interleave; the
    /// lease check additionally keeps a directory a write in progress will use.
    /// That is why the delete paths need no extra age gate; `pruneOrphanFiles`,
    /// which walks directories it knows nothing about, additionally requires the
    /// directory's own mtime to be older than `sweepMinAgeSeconds`.
    ///
    /// Deliberately narrower than the previous single-phase sweep, which
    /// `removeItem`'d a header directory RECURSIVELY: bytes still on disk belong
    /// to someone, so this only ever removes an EMPTY directory.
    private static func removeHeaderDirectoryIfIdle(hashName: String) {
        guard let queue = manifestQueue(), let dir = storeDirectory(),
              let hashUpperBound = prefixUpperBound(hashName) else { return }
        let folderURL = dir.appendingPathComponent(hashName, isDirectory: true)
        do {
            try queue.write { db in
                // ⚑ HALF-OPEN PREFIX RANGE, NOT `substr(…) = ?`. Both predicates ask
                // the same question — "does any blob id start with this header hash?" —
                // but `substr(id, 1, n) = ?` wraps the indexed column in a function, so
                // neither `sqlite_autoindex_bodyAsset_1` nor
                // `idx_bodyAssetPreparation_blob` can seek it and both arms became
                // `SCAN`. This runs under the manifest's single WRITER lock, once per
                // directory, while the sweep also does filesystem I/O — so an O(D×N)
                // scan serialises every asset read and every NSE/main-app write behind
                // it. As a range it is `SEARCH … USING (COVERING) INDEX` on both arms.
                //
                // The equivalence is exact, not approximate: under SQLite's default
                // BINARY collation `p <= s < p⁺` (where `p⁺` is `p` with its final byte
                // incremented) selects precisely the strings that begin with `p`, which
                // is precisely `substr(s, 1, p.count) = p`. Blob ids are
                // `"<16 hex>/<16 hex>"` and every caller passes exactly
                // `hashHexLength` characters, so `p.count == hashHexLength` holds and
                // the two forms agree on every row.
                //
                // NEGATIVE CASE: the forms diverge only for a `hashName` whose length is
                // NOT `hashHexLength`, which no call site produces (all three derive it
                // from `String(id.prefix(hashHexLength))` or `headerHash(_:)`, and
                // `pruneOrphanFiles` additionally gates on `name.count == hashHexLength`).
                // Were one to appear, the range would match MORE rows than the `substr`
                // form, i.e. read as referenced and KEEP the directory — the fail-closed
                // direction. An empty `hashName` has no successor and is refused above,
                // also by keeping the directory.
                guard let referenced = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM bodyAsset
                            WHERE id >= ? AND id < ?
                            UNION ALL
                            SELECT 1 FROM bodyAssetPreparation
                            WHERE blobId >= ? AND blobId < ? AND createdAt > ?
                        )
                        """,
                    arguments: [
                        hashName, hashUpperBound,
                        hashName, hashUpperBound,
                        abandonedPreparationCutoffMs(),
                    ]
                ), !referenced else { return }
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: folderURL, includingPropertiesForKeys: nil
                ), contents.isEmpty else { return }
                try? FileManager.default.removeItem(at: folderURL)
            }
        } catch {
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] header directory reclaim failed for \(hashName): \(error)")
            }
            #endif
        }
    }

    // MARK: - Public: factory for the BodyRenderer writer closure
    //
    // This is the single source of the writer — both main-app
    // `BodyFetchProcessor.renderBody` and the NSE clients
    // (`IMAPFetchMapping.renderBody`, `GmailAPI.messageFull`,
    // `GraphAPI.messageFull`) call this. FOUR callers, identical behavior,
    // impossible to drift.
    // ⚠️ This read "Two callers" until R16-7 (2026-08-06) — while the SAME
    // SENTENCE named four sites. A count that contradicts the enumeration beside
    // it is the cheapest possible instance of the class: no census was needed to
    // falsify it, only reading to the end of the sentence. Predicate, comments
    // excluded so this paragraph cannot satisfy it:
    //   `rg -n --pcre2 '^(?!\s*(///|//)).*makeInlineImageWriter'
    //    TabMail/ Shared/ TabMailNotificationService/` → **5** lines = the
    //   definition below plus the four call sites named above.

    /// Returns an `InlineImageWriter` closure bound to a given headerId.
    /// Used by both NSE and main-app render paths. By design, no caller
    /// constructs the closure inline.
    static func makeInlineImageWriter(forContentKey contentKey: ContentKey) -> BodyRenderer.InlineImageWriter {
        return { img in
            guard let id = writeInlineImage(
                contentKey: contentKey,
                contentId: img.contentId,
                contentType: img.contentType,
                data: img.data
            ) else { return nil }
            return absoluteURL(forAssetId: id)
        }
    }

    // MARK: - Public: reads (identical path in NSE and main app)

    /// Reads asset bytes by row id. Returns nil if file is missing.
    static func read(assetId: String) -> Data? {
        guard let dir = storeDirectory() else { return nil }
        let url = dir.appendingPathComponent(assetId)
        return try? Data(contentsOf: url)
    }

    /// Looks up the assetId for an attachment by (contentKey, section) — but ONLY
    /// when the row was published for the SAME message that is asking.
    ///
    /// ⚑ THE INVARIANT: a cached attachment is served only for the message it was
    /// fetched for. `(contentKey, section)` alone cannot express that — both halves
    /// are mutable addresses a different physical message reoccupies (an IMAP UID
    /// after a `UIDVALIDITY` change; a positional MIME part path that every
    /// multipart message reuses). Without the stamp this lookup hands the user a
    /// stranger's attachment under their own message's name. See
    /// `migrateAttachmentIdentitySchema` for the full closure.
    ///
    /// PORT of `v2final`'s `BodyAssetStore.attachmentAsset(headerId:section:)` /
    /// `attachmentAssetId(headerId:section:)` (commit `486bafd4b`), which likewise
    /// admits only rows carrying an identity and treats stampless legacy rows as
    /// strict cache misses.
    ///
    /// FAIL-CLOSED, NEVER FAIL-DESTRUCTIVE. Every refusal here — a NULL legacy stamp,
    /// a differing stamp, an unreadable manifest — returns "no cached asset", which
    /// re-fetches. It never deletes a row, never marks content fetched, and never
    /// widens to a partial match.
    ///
    /// `identityStamp` is REQUIRED and has NO default, so a future reader cannot be
    /// added that skips the check and still compiles.
    static func attachmentAssetId(
        contentKey: ContentKey, section: String, identityStamp: String
    ) -> String? {
        guard let queue = manifestQueue() else { return nil }
        do {
            return try queue.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM bodyAsset
                        WHERE headerId = ? AND kind = ? AND attachmentSection = ?
                          AND identityStamp = ?
                        """,
                    arguments: [
                        contentKey, BodyAssetKind.attachment.rawValue, section,
                        identityStamp,
                    ]
                )
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] attachmentAssetId read failed: \(error)")
            #endif
            return nil
        }
    }

    /// The authorization-relevant fields of ONE manifest row, for the render path.
    ///
    /// Deliberately carries `owner` and `kind` alongside `contentType`: the render
    /// scheme handler must decide *whether* to serve before it decides *what* to
    /// call the bytes, and it can only do that from the row itself.
    struct AssetManifestRow: Sendable, Equatable {
        /// The `headerId` COLUMN as stored right now — never a hash recomputed from
        /// the URL. `rekeyContentKey(from:to:)` re-points this column after a move
        /// while preserving the row `id` and the bytes on disk, so the embedded
        /// `tabmail-asset://` URL keeps the OLD `headerHash`. Authorizing against
        /// the column is what makes a moved message's cached images keep working;
        /// authorizing against `headerHash(currentKey)` would reject every one.
        let owner: ContentKey
        let kind: BodyAssetKind
        let contentType: String
    }

    /// Looks up the ownership + type metadata for an asset id, by exact row id.
    ///
    /// ⚑ THE INVARIANT THIS EXISTS FOR: **an asset is served only to the document
    /// that owns it.** Before this, the render scheme handler paired the
    /// unrestricted `read(assetId:)` with the unrestricted `contentType(assetId:)`
    /// and served any asset id the document named — and asset ids are NOT secrets,
    /// so naming another message's id was all it took. This is the single store
    /// operation that returns what the ownership decision needs; the decision
    /// itself is `BodyAssetServePolicy.authorize`.
    ///
    /// Returns nil for "no such row" and for an unreadable manifest alike — both
    /// mean "not authorized", and the handler renders them identically on the wire.
    static func assetManifestRow(assetId: String) -> AssetManifestRow? {
        guard let queue = manifestQueue() else { return nil }
        do {
            return try queue.read { db -> AssetManifestRow? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT headerId, kind, contentType FROM bodyAsset WHERE id = ?",
                    arguments: [assetId]
                ) else { return nil }
                let rawKind: Int = row["kind"]
                guard let kind = BodyAssetKind(rawValue: rawKind) else { return nil }
                let owner: ContentKey = row["headerId"]
                let contentType: String = row["contentType"]
                return AssetManifestRow(owner: owner, kind: kind, contentType: contentType)
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] assetManifestRow read failed: \(error)")
            #endif
            return nil
        }
    }

    /// Returns the Content-Type for an asset. Nil if no row.
    static func contentType(assetId: String) -> String? {
        guard let queue = manifestQueue() else { return nil }
        do {
            return try queue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT contentType FROM bodyAsset WHERE id = ?",
                    arguments: [assetId]
                )
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] contentType read failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Public: LRU bump (every bump site is a user tap)
    //
    // ⚠️ This MARK read "the only bump site is user tap" until R16-7
    // (2026-08-06). There are **three**, not one — what is true is the PROPERTY
    // (every bump is a user gesture, never a sweep or a background pass), and
    // that property is what the LRU depends on; the singular was never load-
    // bearing and was simply wrong. Predicate, comments excluded:
    //   `rg -n --pcre2 '^(?!\s*(///|//)).*BodyAssetStore\.bumpMessageAccess'
    //    TabMail/ Shared/ TabMailNotificationService/` → **3**
    //   (`AttachmentListView` ×2 — attachment taps; `MessageDetailViewModel` — the
    //   opened-message bump). `MessageDetailViewModel`'s own "SOLE bump site"
    //   comment is correctly QUALIFIED ("for opened-message access") and stays.

    /// Bump every asset of a given message to "now". Single UPDATE; touches all
    /// rows for that headerId. Fire-and-forget.
    static func bumpMessageAccess(contentKey: ContentKey) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        Task.detached(priority: .utility) {
            guard let queue = manifestQueue() else { return }
            do {
                try queue.write { db in
                    try db.execute(
                        sql: "UPDATE bodyAsset SET lastAccessedAt = ? WHERE headerId = ?",
                        arguments: [nowMs, contentKey]
                    )
                }
            } catch {
                #if DEBUG
                print("[BodyAssetStore] bumpMessageAccess failed for \(contentKey): \(error)")
                #endif
            }
        }
    }

    // MARK: - Internal primitives (used by BodyAssetMaintenance, main-app only)

    /// Snapshot of one message's asset aggregate, for eviction ordering.
    struct VictimSummary: Sendable {
        let contentKey: ContentKey
        let totalBytes: Int64
        let inlineCount: Int
    }

    /// The least recently accessed messages with assets, oldest first, until their assets add up
    /// to `bytes` or `limit` messages are chosen. Used by `BodyAssetMaintenance.evictIfOverCap`.
    ///
    /// A message's place is its MOST RECENT asset access, `MAX(COALESCE(lastAccessedAt, 0))` over
    /// its rows: NULL (never opened) counts as 0, so never-opened messages go first. Rows of one
    /// message can differ, because an asset published after the message's last bump starts NULL.
    ///
    /// It walks `idx_bodyAsset_lruSize` in access order and stops as soon as it has enough
    /// (ios#1382), instead of aggregating and sorting every message that has assets. At each row
    /// of a message not yet decided, one seek of `idx_bodyAsset_headerAccess` reads the message's
    /// latest access without touching its rows. A row older than that is passed over: the message
    /// is met again at its latest row, which is its place. Only a message taken at its place has its
    /// rows summed, so a message passed over is never aggregated, and the order is exactly the
    /// aggregate's, with no value kept outside the rows.
    ///
    /// `COALESCE(MAX(lastAccessedAt), 0)` equals the aggregate's `MAX(COALESCE(lastAccessedAt, 0))`
    /// because every stamp is a positive wall-clock time (`bumpMessageAccess`) or NULL (publish).
    /// Messages whose assets add up to 0 bytes are skipped, as before: dropping them reclaims
    /// nothing.
    static func evictionVictims(coveringBytes bytes: Int64, limit: Int) -> [VictimSummary] {
        guard bytes > 0, limit > 0, let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                var decided = Set<ContentKey>()
                var victims: [VictimSummary] = []
                var covered: Int64 = 0
                let walk = try Row.fetchCursor(
                    db, sql: "SELECT headerId, lastAccessedAt FROM bodyAsset ORDER BY lastAccessedAt"
                )
                while let row = try walk.next() {
                    let contentKey: ContentKey = row["headerId"]
                    guard !decided.contains(contentKey) else { continue }
                    let rowAccess: Int64 = row["lastAccessedAt"] ?? 0
                    let latestAccess = try Int64.fetchOne(
                        db,
                        sql: "SELECT MAX(lastAccessedAt) FROM bodyAsset WHERE headerId = ?",
                        arguments: [contentKey]
                    ) ?? 0
                    guard rowAccess >= latestAccess else { continue }
                    decided.insert(contentKey)
                    guard let summary = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT COALESCE(SUM(sizeBytes), 0) AS totalBytes,
                               COALESCE(SUM(CASE WHEN kind = 0 THEN 1 ELSE 0 END), 0) AS inlineCount
                        FROM bodyAsset WHERE headerId = ?
                        """,
                        arguments: [contentKey]
                    ) else { continue }
                    let victim = VictimSummary(
                        contentKey: contentKey,
                        totalBytes: summary["totalBytes"],
                        inlineCount: summary["inlineCount"]
                    )
                    guard victim.totalBytes > 0 else { continue }
                    victims.append(victim)
                    covered += victim.totalBytes
                    if covered >= bytes || victims.count >= limit { break }
                }
                return victims
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] evictionVictims failed: \(error)")
            #endif
            return []
        }
    }

    /// Delete all manifest rows + files for a single content key. Returns bytes
    /// reclaimed. Idempotent. Does NOT touch main DB.
    ///
    /// ⚑ THE DIRECTORIES COME FROM THE ROWS, NOT FROM THE KEY. An asset row's `id`
    /// is `"<headerHash>/<assetHash>"`, where `headerHash` was computed from the key
    /// the row was written under. `headerId` is a mutable COLUMN — `rekeyContentKey`
    /// moves a moved message's assets to its new key without rewriting the files —
    /// so after a re-key `headerHash(contentKey)` names a directory that no longer
    /// holds anything, and a removal derived from the key would miss every one of
    /// that message's files. Deriving the files and directories from the rows
    /// actually being deleted is correct in both worlds, and byte-identical where no
    /// re-key has happened (the only distinct prefix IS `headerHash(contentKey)`).
    @discardableResult
    static func deleteAllAssets(forContentKey contentKey: ContentKey) -> Int64 {
        deleteAllAssetsResult(forContentKey: contentKey) ?? 0
    }

    /// `deleteAllAssets(forContentKey:)`, reporting a manifest failure as nil.
    private static func deleteAllAssetsResult(forContentKey contentKey: ContentKey) -> Int64? {
        guard let queue = manifestQueue(), let dir = storeDirectory() else { return nil }
        let deletion: (bytes: Int64, blobIds: [String])
        do {
            deletion = try queue.write { db in
                try deleteRowsAndFiles(forContentKey: contentKey, in: dir, db: db)
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] deleteAllAssets manifest failed for \(contentKey): \(error)")
            #endif
            return nil
        }
        finishDeletion(of: contentKey, blobIds: deletion.blobIds)
        return deletion.bytes
    }

    /// Inside a manifest write transaction: unlinks every file `contentKey`'s rows
    /// name, THEN deletes the rows (#1376: the file first, then its record). A crash
    /// in between leaves rows whose files are gone, which a read notices
    /// (`BodyAssetSchemeHandler`'s missing-file report, the attachment list's cache
    /// miss) and the next delete of the key finishes; never a file no row names,
    /// which nothing would ever find. Each row's id is its own blob (the primary
    /// key), and a write in progress keeps its bytes in staging until `publish`
    /// moves them in under this same lock, so no other writer's file is unlinked.
    private static func deleteRowsAndFiles(
        forContentKey contentKey: ContentKey, in dir: URL, db: Database
    ) throws -> (bytes: Int64, blobIds: [String]) {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, sizeBytes FROM bodyAsset WHERE headerId = ?",
            arguments: [contentKey]
        )
        let blobIds = rows.map { $0["id"] as String }
        let bytes = rows.reduce(Int64(0)) { $0 + ($1["sizeBytes"] as Int64) }
        for blobId in blobIds {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(blobId))
        }
        try db.execute(
            sql: "DELETE FROM bodyAsset WHERE headerId = ?",
            arguments: [contentKey]
        )
        return (bytes, blobIds)
    }

    /// After a key's rows and files are deleted: reclaims the header directories
    /// they lived in, once idle, and invalidates the byte count. With no rows it
    /// tries the key's own hash, so a directory left empty by an interrupted write
    /// is still reclaimed (only an EMPTY, unleased one).
    private static func finishDeletion(of contentKey: ContentKey, blobIds: [String]) {
        let headerHashes: Set<String> = blobIds.isEmpty
            ? [headerHash(contentKey)]
            : Set(blobIds.map { String($0.prefix(hashHexLength)) })
        for hash in headerHashes {
            removeHeaderDirectoryIfIdle(hashName: hash)
        }
        invalidateUsedBytesCache()
    }

    /// What `deletePendingContentKey` did.
    enum PendingDeleteOutcome: Sendable, Equatable {
        /// The key's rows and files are gone (none is fine); `bytes` reclaimed.
        case deleted(bytes: Int64)
        /// A live preparation lease under the key's header hash: a write for the
        /// key is in progress, so nothing was deleted. Retry later.
        case writeInProgress
        /// The manifest could not be read or written. Retry later.
        case failed
    }

    /// #1376: deletes the assets of a key from the main database's
    /// `bodyAssetPendingDelete` list, for the pending-delete worker
    /// (`BodyAssetMaintenance.processPendingDeletes`), in ONE manifest write
    /// transaction:
    /// 1. reaps the abandoned leases under the key's header hash (its writes
    ///    write under that hash);
    /// 2. if a live lease remains there, a write for the key is in progress:
    ///    nothing is deleted (`.writeInProgress`), so the worker keeps the entry
    ///    and the write's rows are deleted on a later pass;
    /// 3. otherwise unlinks the files the key's rows name, then deletes the rows
    ///    (`deleteRowsAndFiles`).
    ///
    /// A writer whose lease step 1 reaps has its `publish` refused, so it never
    /// records a row after this transaction.
    static func deletePendingContentKey(_ contentKey: ContentKey) -> PendingDeleteOutcome {
        guard let queue = manifestQueue(), let dir = storeDirectory() else { return .failed }
        let hash = headerHash(contentKey)
        guard let hashUpperBound = prefixUpperBound(hash) else { return .failed }
        let result: (bytes: Int64, blobIds: [String])?
        do {
            result = try queue.write { db -> (bytes: Int64, blobIds: [String])? in
                try db.execute(
                    sql: """
                        DELETE FROM bodyAssetPreparation
                        WHERE blobId >= ? AND blobId < ? AND createdAt <= ?
                        """,
                    arguments: [hash, hashUpperBound, abandonedPreparationCutoffMs()]
                )
                // A FROM-less scalar select always yields one row; nil fails closed.
                let leased = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM bodyAssetPreparation
                            WHERE blobId >= ? AND blobId < ?
                        )
                        """,
                    arguments: [hash, hashUpperBound]
                ) ?? true
                guard !leased else { return nil }
                return try deleteRowsAndFiles(forContentKey: contentKey, in: dir, db: db)
            }
        } catch {
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] pending delete failed for \(contentKey): \(error)")
            }
            #endif
            return .failed
        }
        guard let result else { return .writeInProgress }
        finishDeletion(of: contentKey, blobIds: result.blobIds)
        return .deleted(bytes: result.bytes)
    }

    /// #1376: which of `contentKeys` have assets for the pending-delete worker to
    /// settle: a manifest row under the key, or a preparation lease under its header
    /// hash (a write in progress). One manifest read; nil if it failed. A key with
    /// neither has nothing to delete, so its entry needs no manifest write.
    ///
    /// The rows are found by an index seek per key (`headerId IN (…)` on an index led
    /// by `headerId`); the lease table holds only writes in progress, so it is read
    /// whole.
    static func contentKeysWithAssets(among contentKeys: [ContentKey]) -> Set<ContentKey>? {
        guard !contentKeys.isEmpty else { return [] }
        guard let queue = manifestQueue() else { return nil }
        do {
            return try queue.read { db in
                let placeholders = Array(repeating: "?", count: contentKeys.count).joined(separator: ",")
                var withAssets = Set(try ContentKey.fetchAll(
                    db,
                    sql: "SELECT DISTINCT headerId FROM bodyAsset WHERE headerId IN (\(placeholders))",
                    arguments: StatementArguments(contentKeys)
                ))
                let leasedHashes = Set(try String.fetchAll(
                    db, sql: "SELECT blobId FROM bodyAssetPreparation"
                ).map { String($0.prefix(hashHexLength)) })
                for key in contentKeys where leasedHashes.contains(headerHash(key)) {
                    withAssets.insert(key)
                }
                return withAssets
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] contentKeysWithAssets failed: \(error)")
            #endif
            return nil
        }
    }

    /// Re-point every manifest row of `oldKey` at `newKey`, preserving the bytes on
    /// disk. Returns the number of rows moved.
    ///
    /// The manifest's counterpart to `SearchIndex.rekeyHeaders`, and it exists for
    /// the same reason: a message that merely MOVED must keep its cached inline
    /// images and attachments rather than have them swept as orphans and re-fetched.
    ///
    /// Files are NOT moved — the row `id` (and therefore the `tabmail-asset://` URL
    /// already embedded in cached HTML) keeps the OLD `headerHash`, which is exactly
    /// why `deleteAllAssets(forContentKey:)` and `pruneOrphanFiles()` both derive
    /// directories from `substr(id, …)` instead of re-hashing the key.
    ///
    /// Collision policy mirrors `rekeyHeaders`: if `newKey` already has rows, those
    /// are authoritative and the old key's rows + files are deleted instead.
    @discardableResult
    static func rekeyContentKey(from oldKey: ContentKey, to newKey: ContentKey) -> Int {
        rekeyContentKeyResult(from: oldKey, to: newKey) ?? 0
    }

    /// `rekeyContentKey(from:to:)`, reporting a manifest failure as nil, so the
    /// pending-delete worker keeps an entry whose re-key did not happen (#1376).
    static func rekeyContentKeyResult(from oldKey: ContentKey, to newKey: ContentKey) -> Int? {
        guard oldKey != newKey else { return 0 }
        guard let queue = manifestQueue() else { return nil }
        let moved: Int
        do {
            moved = try queue.write { db -> Int in
                let newExists = try Bool.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) > 0 FROM bodyAsset WHERE headerId = ?",
                    arguments: [newKey]
                ) ?? false
                guard !newExists else { return -1 }
                try db.execute(
                    sql: "UPDATE bodyAsset SET headerId = ? WHERE headerId = ?",
                    arguments: [newKey, oldKey]
                )
                return db.changesCount
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] rekeyContentKey failed for \(oldKey): \(error)")
            #endif
            return nil
        }
        if moved < 0 {
            return deleteAllAssetsResult(forContentKey: oldKey) == nil ? nil : 0
        }
        return moved
    }

    /// Delete all manifest rows + files for a kind. Returns the set of content keys
    /// affected (so the maintenance layer can do its main-DB cleanup for kind=0).
    /// Idempotent. Does NOT touch main DB.
    ///
    /// In batches of `wipeBatchSize` rows, walking the primary key, each batch one
    /// manifest write transaction that unlinks its rows' files and then deletes the
    /// rows (#1376: the file first, then its record, as in `deleteRowsAndFiles`).
    @discardableResult
    static func deleteAllAssets(kind: BodyAssetKind) -> Set<ContentKey> {
        guard let queue = manifestQueue(), let dir = storeDirectory() else { return [] }
        var contentKeys = Set<ContentKey>()
        var headerHashes = Set<String>()
        var after = ""
        while true {
            let batch: [(id: String, contentKey: ContentKey)]
            do {
                batch = try queue.write { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: "SELECT id, headerId FROM bodyAsset WHERE kind = ? AND id > ? ORDER BY id LIMIT ?",
                        arguments: [kind.rawValue, after, wipeBatchSize]
                    ).map { (id: $0["id"] as String, contentKey: $0["headerId"] as ContentKey) }
                    guard !rows.isEmpty else { return rows }
                    for row in rows {
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(row.id))
                    }
                    let placeholders = Array(repeating: "?", count: rows.count).joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM bodyAsset WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(rows.map(\.id))
                    )
                    return rows
                }
            } catch {
                #if DEBUG
                print("[BodyAssetStore] deleteAllAssets(kind:) batch failed: \(error)")
                #endif
                break
            }
            guard let last = batch.last else { break }
            after = last.id
            contentKeys.formUnion(batch.map(\.contentKey))
            headerHashes.formUnion(batch.map { String($0.id.prefix(hashHexLength)) })
        }
        // Only rmdir if now empty (other kind's files may remain) and unleased.
        // Directories come from the ROWS, same as `deleteAllAssets(forContentKey:)`
        // — re-hashing the key names the wrong directory after a `rekeyContentKey`.
        for hashName in headerHashes {
            removeHeaderDirectoryIfIdle(hashName: hashName)
        }
        invalidateUsedBytesCache()
        return contentKeys
    }

    /// One page of the manifest's distinct content keys after `after`, in key
    /// order, for the one-time orphan sweep (`BodyAssetMaintenance.runOrphanSweepOnce`).
    /// Walks an index led by `headerId`. Nil if the read failed.
    static func manifestContentKeys(after: ContentKey?, limit: Int) -> [ContentKey]? {
        guard let queue = manifestQueue() else { return nil }
        do {
            return try queue.read { db in
                try ContentKey.fetchAll(
                    db,
                    sql: "SELECT DISTINCT headerId FROM bodyAsset WHERE headerId > ? ORDER BY headerId LIMIT ?",
                    arguments: [after?.rawValue ?? "", limit]
                )
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] manifestContentKeys failed: \(error)")
            #endif
            return nil
        }
    }

    /// Returns the set of distinct content keys present in the manifest. Used by
    /// the UIDVALIDITY reset's per-folder purge (`purgeBodyAssetsForFolder`).
    static func allManifestContentKeys() -> Set<ContentKey> {
        guard let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                let ids = try ContentKey.fetchAll(db, sql: "SELECT DISTINCT headerId FROM bodyAsset")
                return Set(ids)
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] allManifestContentKeys failed: \(error)")
            #endif
            return []
        }
    }

    /// Returns the set of distinct content keys in the manifest that have at least
    /// one row of the given kind. Used by `BodyAssetMaintenance.wipeAll` to
    /// scope the main-DB MessageBody/bodyComplete cleanup to affected headers.
    static func allManifestContentKeysByKind(kind: BodyAssetKind) -> Set<ContentKey> {
        guard let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                let ids = try ContentKey.fetchAll(
                    db,
                    sql: "SELECT DISTINCT headerId FROM bodyAsset WHERE kind = ?",
                    arguments: [kind.rawValue]
                )
                return Set(ids)
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] allManifestContentKeysByKind failed: \(error)")
            #endif
            return []
        }
    }

    /// Filesystem-only orphan sweep: reaps abandoned preparation leases, deletes
    /// files older than `sweepMinAgeSeconds` after an atomic manifest + LIVE
    /// preparation-lease recheck, and reclaims header directories that are empty
    /// and have been idle for at least the same threshold. Does NOT cross to the
    /// main DB. Safe to run from any target.
    ///
    /// It walks the whole store, so it is never periodic (#1376): it runs once
    /// after the update that removed the periodic sweep, for files orphaned before
    /// it (`BodyAssetMaintenance.runOrphanSweepOnce`), and after a UIDVALIDITY
    /// reset's folder purge. `staging/` is not a header directory (its name is not
    /// `hashHexLength` long), so it is skipped.
    static func pruneOrphanFiles() {
        guard let dir = storeDirectory(), let queue = manifestQueue() else { return }

        // Table-wide reap of abandoned leases, as `recoverAbandonedPreparations`
        // does. Deleting a lease NEVER deletes bytes — it only stops an abandoned
        // lease from vetoing the age-gated file sweep below.
        do {
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM bodyAssetPreparation WHERE createdAt <= ?",
                    arguments: [abandonedPreparationCutoffMs()]
                )
            }
        } catch {
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] abandoned preparation reap failed: \(error)")
            }
            #endif
        }

        let knownHeaderHashes: Set<String>
        do {
            knownHeaderHashes = try queue.read { db in
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT substr(id, 1, ?) FROM bodyAsset",
                    arguments: [hashHexLength]
                )
                return Set(rows)
            }
        } catch {
            #if DEBUG
            print("[BodyAssetStore] pruneOrphanFiles known-hashes read failed: \(error)")
            #endif
            return
        }

        let topContents: [URL]
        do {
            topContents = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
        } catch {
            #if DEBUG
            print("[BodyAssetStore] pruneOrphanFiles scandir failed: \(error)")
            #endif
            return
        }

        let now = Date()
        for entry in topContents {
            let name = entry.lastPathComponent
            guard name.count == hashHexLength else { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            // Sampled BEFORE the file loop: adding or removing a file updates a
            // directory's mtime, so "older than the threshold" means nothing has
            // entered or left this directory recently — it cannot be mid-write.
            let dirMtime = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? now

            let knownFileIds: Set<String>
            if knownHeaderHashes.contains(name) {
                // ⚑ HALF-OPEN PREFIX RANGE, NOT `substr(…) = ?` — the same rewrite,
                // for the same reason, as `removeHeaderDirectoryIfIdle`'s idle check
                // (see `prefixUpperBound` and the ⚑ comment there for the exactness
                // argument and its negative case). `substr(id, 1, n) = ?` wraps the
                // indexed column in a function, so `sqlite_autoindex_bodyAsset_1`
                // cannot seek it and this is a full SCAN. It runs once per known
                // header directory, i.e. O(D×N) over the manifest; as a range each
                // iteration is
                // `SEARCH … USING COVERING INDEX (id>? AND id<?)`.
                //
                // `name` is exactly `hashHexLength` characters (guarded above), which
                // is the precondition that makes the two forms select the identical
                // rows. A nil bound is unreachable for a 16-character name; if it ever
                // happened, skipping the directory keeps every file in it — the same
                // fail-closed answer the `catch` below gives.
                guard let nameUpperBound = prefixUpperBound(name) else { continue }
                do {
                    knownFileIds = try queue.read { db in
                        let rows = try String.fetchAll(
                            db,
                            sql: "SELECT id FROM bodyAsset WHERE id >= ? AND id < ?",
                            arguments: [name, nameUpperBound]
                        )
                        return Set(rows)
                    }
                } catch {
                    continue
                }
            } else {
                knownFileIds = []
            }

            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: [.contentModificationDateKey]
                )
            } catch {
                continue
            }

            for file in files {
                let fileId = "\(name)/\(file.lastPathComponent)"
                if knownFileIds.contains(fileId) { continue }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(mtime) > sweepMinAgeSeconds {
                    removeBlobIfUnreferenced(fileId)
                }
            }

            // Reclaim the (now possibly empty) header directory. Age-gated here
            // because this loop walks directories it knows nothing about;
            // `removeHeaderDirectoryIfIdle` then re-checks emptiness and live
            // leases under the manifest writer lock before unlinking.
            if now.timeIntervalSince(dirMtime) > sweepMinAgeSeconds {
                removeHeaderDirectoryIfIdle(hashName: name)
            }
        }
    }

    /// Public mirror of the internal `invalidateUsedBytesCache()`. Production
    /// callers (eviction loop, wipe paths) and tests both invalidate the cache
    /// after manipulating the manifest table directly.
    static func invalidateUsedBytesCachePublic() {
        invalidateUsedBytesCache()
    }

    // MARK: - Test helpers

    /// A test environment starts with no publish owner check (the app installs
    /// one at launch); a test that needs one sets it with `setPublishOwnerCheck`.
    static func _setTestEnvironment(containerURL: URL, queue: DatabaseQueue) {
        testOverride.withLock { $0 = (containerURL, queue) }
        usedBytesCache.withLock { $0 = nil }
        publishOwnerCheck.withLock { $0 = nil }
    }

    static func _makeTestQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in try migrateManifestSchema(db) }
        return queue
    }

    static func _resetForTesting() {
        testOverride.withLock { $0 = nil }
        queueCache.withLock { $0 = nil }
        usedBytesCache.withLock { $0 = nil }
        publishOwnerCheck.withLock { $0 = nil }
    }
}
