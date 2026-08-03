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
/// `messageBody` tables (eviction's `bodyComplete=0` flip, cross-DB orphan
/// sweep) live in `BodyAssetMaintenance` (main-app target only). NSE never
/// runs eviction inside its 30s budget anyway.
///
/// **Storage layout:**
/// - Bytes: `<appGroupContainer>/bodyAssets/<headerHash>/<assetHash>` (no extension).
/// - Manifest: `<appGroupContainer>/bodyAssetIndex.sqlite` — independent of
///   `AppDatabase` so NSE can write rows without reaching into the main-app
///   sandbox.
///
/// **LRU at the message level.** `bodyAsset.lastAccessedAt` is the same
/// timestamp on every row sharing a `headerId`. Bumped only on user tap
/// (open message body, tap attachment) — one `UPDATE … WHERE headerId = ?`
/// touches all of a message's assets. Initial writes leave it NULL so
/// never-tapped messages evict first.
///
/// **Write/delete idempotency** — a manifest-side preparation lease is
/// persisted before file materialization, then publication replaces that lease
/// with the live row. Physical deletion re-checks both live rows and preparation
/// leases while holding the same cross-process manifest write transaction.
/// A lease only protects a blob for `sweepMinAgeSeconds`; past that its writer
/// is presumed dead (see `abandonedPreparationCutoffMs`) and the ordinary
/// age-based sweep reclaims the blob exactly as it did before leases existed.
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
            print("[BodyAssetStore] App Group container unavailable")
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
            try queue.write { db in
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
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_header ON bodyAsset (headerId)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_lru ON bodyAsset (lastAccessedAt)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_attachmentLookup ON bodyAsset (headerId, kind, attachmentSection)")
            }
        } catch {
            print("[BodyAssetStore] manifest DB open/migrate failed: \(error)")
            return nil
        }
        queueCache.withLock { $0 = queue }
        return queue
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
    /// `manifestQueue()` / `_makeTestQueue()`, which already lists `identityStamp`,
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
                print("[BodyAssetStore] App Group UserDefaults suite unavailable — using compile-time default")
                return BodyAssetConfig.defaultAttachmentsBudgetMB
            }
            let raw = defaults.object(forKey: BodyAssetConfig.attachmentsBudgetMBKey) as? Int
            return raw ?? BodyAssetConfig.defaultAttachmentsBudgetMB
        }
        set {
            guard let defaults = UserDefaults(suiteName: BodyAssetConfig.appGroup) else {
                print("[BodyAssetStore] App Group UserDefaults suite unavailable — write dropped")
                return
            }
            defaults.set(newValue, forKey: BodyAssetConfig.attachmentsBudgetMBKey)
        }
    }

    /// Total bytes across both kinds. Cached; invalidated on any write/delete.
    static var usedBytes: Int64 {
        if let cached = usedBytesCache.withLock({ $0 }) { return cached }
        guard let queue = manifestQueue() else { return 0 }
        let value: Int64
        do {
            value = try queue.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset") ?? 0
            }
        } catch {
            print("[BodyAssetStore] usedBytes read failed: \(error)")
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
            print("[BodyAssetStore] usedBytes(kind:) read failed: \(error)")
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

    /// Bytes already materialised on disk, awaiting manifest publication.
    ///
    /// The blob id IS the logical slot id (`"<headerHash>/<assetHash(key)>"`) —
    /// the same address the published row's `id` carries, which is what keeps
    /// the `tabmail-asset://` URLs already baked into cached HTML resolvable and
    /// keeps "write the same (contentKey, key) twice" a single-slot overwrite.
    /// Two consequences the lease has to carry:
    ///   - `prepare` ALWAYS re-materialises the bytes (it cannot assume an
    ///     existing file holds the same content, because the address does not
    ///     name the content);
    ///   - a failed publication cannot unlink the slot's bytes out from under a
    ///     row that still references them — `removeBlobIfUnreferenced` refuses,
    ///     because that live row names this very blob id.
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

    /// Materialises bytes on disk WITHOUT publishing a manifest row, under a
    /// persisted preparation lease that every physical deleter — in EITHER
    /// process — must consult before it may unlink the blob.
    ///
    /// The lease is inserted BEFORE `createDirectory`/`data.write`, so the
    /// protected window strictly contains the whole materialisation window.
    /// A crash anywhere after this point leaves at worst an orphan file plus an
    /// abandoned lease; both age out on `sweepMinAgeSeconds`
    /// (`abandonedPreparationCutoffMs`) and are reclaimed by `pruneOrphanFiles`
    /// exactly as an interrupted single-phase write was before leases existed.
    ///
    /// Not `private` only so the prepare→publish boundary is directly testable;
    /// production reaches it through `write`.
    static func prepare(
        contentKey: ContentKey, kind: BodyAssetKind, key: String,
        contentType: String, data: Data, identityStamp: String?
    ) -> PreparedWrite? {
        guard let dir = storeDirectory(), let queue = manifestQueue() else { return nil }
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

        // 2. File second. Always re-materialised: the blob id names the logical
        // slot, not the bytes, so an existing file may hold DIFFERENT content.
        let folderURL = dir.appendingPathComponent(hHash, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL.appendingPathComponent(aHash)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            discardPreparedIfOrphaned(prepared)
            print("[BodyAssetStore] file write failed for \(blobId): \(error)")
            return nil
        }

        return prepared
    }

    /// Publishes a prepared blob into the manifest. Refuses — recording NOTHING
    /// — when this preparation no longer owns its lease, so a writer whose lease
    /// was reaped can never leave a manifest row pointing at unlinked bytes.
    /// Initial write does NOT bump LRU.
    ///
    /// Not `private` only so the prepare→publish boundary is directly testable;
    /// production reaches it through `write`.
    static func publish(_ prepared: PreparedWrite) -> String? {
        guard let queue = manifestQueue() else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let contentIdValue: String? = (prepared.kind == .inlineImage) ? prepared.key : nil
        let attachmentSectionValue: String? = (prepared.kind == .attachment) ? prepared.key : nil
        let published: Bool

        do {
            published = try queue.write { db -> Bool in
                // This no-op UPDATE proves that this preparation still owns its
                // lease and acquires SQLite's cross-process writer lock before
                // the manifest row is touched.
                try db.execute(
                    sql: """
                        UPDATE bodyAssetPreparation
                        SET createdAt = createdAt
                        WHERE preparationId = ? AND blobId = ?
                        """,
                    arguments: [prepared.preparationId, prepared.blobId]
                )
                guard db.changesCount == 1 else { return false }

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
            // ADR-IOS-046: a database-suspension abort (SQLITE_ABORT/INTERRUPT) is
            // expected + benign — the asset row re-writes on the next wake. Don't
            // log it as a failure. (Shared with the NSE target, so this uses GRDB's
            // built-in `isInterruptionError` rather than the app-only
            // `Error.isDatabaseSuspensionAbort` helper.)
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] row publish failed for \(prepared.blobId): \(error)")
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
            discardPreparedIfOrphaned(prepared)
        }
        return result
    }

    /// Cutoff (epoch ms) at or before which a preparation lease is treated as
    /// ABANDONED — its writer died between the lease INSERT and publish/discard.
    ///
    /// WHY THIS EXISTS. The lease stops a physical delete from unlinking a blob
    /// that another writer just materialised. Without an expiry it also pins the
    /// blob FOREVER when the writer never returns — very plausible for the NSE
    /// inside its 30s budget. Every physical deleter (`pruneOrphanFiles`, both
    /// `deleteAllAssets` overloads, `discardPreparedIfOrphaned`) routes through
    /// `removeBlobIfUnreferenced` and refuses to unlink while any lease names the
    /// blob, and `usedBytes` sums only `bodyAsset.sizeBytes`, so such a blob is
    /// also invisible to the user's attachment cap. Before the lease table
    /// existed the sweep reclaimed exactly this file after `sweepMinAgeSeconds`;
    /// ageing the lease out on the SAME threshold restores that behaviour instead
    /// of replacing it with an ownership test that fails open on crash.
    ///
    /// WHY EXPIRY IS SAFE. Reaping a lease can never publish bad state:
    /// `publish` re-proves ownership of its own lease row (`changesCount == 1`)
    /// before touching `bodyAsset`, so a writer whose lease expired REFUSES to
    /// publish rather than leaving a manifest row pointing at unlinked bytes.
    /// The worst case is a wasted fetch that self-heals on retry, and the caller
    /// sees the same `nil` it sees for any other write failure — never a row that
    /// claims content we do not have. A YOUNG lease still protects its blob
    /// unconditionally, and a PUBLISHED blob is protected by its manifest row
    /// regardless of any lease.
    private static func abandonedPreparationCutoffMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 - sweepMinAgeSeconds) * 1000)
    }

    /// Releases this writer's preparation lease, then removes the blob only if
    /// neither a live manifest row nor another writer's LIVE preparation lease
    /// points at it. The check and unlink deliberately run inside one manifest
    /// write transaction: prepare/publish/discard in the main app and NSE
    /// therefore serialize through SQLite's cross-process writer lock.
    static func discardPreparedIfOrphaned(_ prepared: PreparedWrite) {
        removeBlobIfUnreferenced(
            prepared.blobId,
            releasingPreparationId: prepared.preparationId
        )
    }

    /// Atomically guards a physical unlink with the manifest-side reachability
    /// check. The DELETE is always the first statement — it releases this
    /// writer's own lease AND reaps any abandoned lease on the same blob, and
    /// it acquires the SQLite writer lock before the SELECT and the filesystem
    /// action even when there is no lease of our own to release (the empty
    /// preparation id cannot match a UUID).
    private static func removeBlobIfUnreferenced(
        _ blobId: String,
        releasingPreparationId: String? = nil
    ) {
        guard let queue = manifestQueue(), let dir = storeDirectory() else { return }
        do {
            try queue.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM bodyAssetPreparation
                        WHERE blobId = ?
                          AND (preparationId = ? OR createdAt <= ?)
                        """,
                    arguments: [
                        blobId,
                        releasingPreparationId ?? "",
                        abandonedPreparationCutoffMs(),
                    ]
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
            // Fail closed: an unavailable manifest leaves an orphan file behind,
            // which the next sweep retries. Debug-gated because `Shared/` also
            // compiles into the NSE, where `DebugModeManager` does not exist.
            #if DEBUG
            if (error as? DatabaseError)?.isInterruptionError != true {
                print("[BodyAssetStore] unreferenced-blob check failed for \(blobId): \(error)")
            }
            #endif
        }
    }

    /// Reclaims `<store>/<headerHash>/` once it is provably idle.
    ///
    /// "Idle" is decided under the manifest's cross-process writer lock: no
    /// manifest row and no LIVE preparation lease names a blob under this hash,
    /// and the directory is empty on disk. The lease is the PRECISE guard for
    /// the only harmful race — a writer between `createDirectory` and
    /// `data.write` — because `prepare` inserts its lease before both. That is
    /// why the delete paths need no extra age gate; `pruneOrphanFiles`, which
    /// walks directories it knows nothing about, additionally requires the
    /// directory's own mtime to be older than `sweepMinAgeSeconds`.
    ///
    /// Deliberately narrower than the previous single-phase sweep, which
    /// `removeItem`'d a header directory RECURSIVELY: bytes still on disk belong
    /// to someone, so this only ever removes an EMPTY directory. Files left
    /// under it by an interrupted write are reclaimed by the age-gated file loop
    /// in `pruneOrphanFiles`, not by a recursive delete that cannot tell an
    /// abandoned blob from one a concurrent writer is materialising right now.
    private static func removeHeaderDirectoryIfIdle(hashName: String) {
        guard let queue = manifestQueue(), let dir = storeDirectory() else { return }
        let folderURL = dir.appendingPathComponent(hashName, isDirectory: true)
        do {
            try queue.write { db in
                guard let referenced = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM bodyAsset
                            WHERE substr(id, 1, ?) = ?
                            UNION ALL
                            SELECT 1 FROM bodyAssetPreparation
                            WHERE substr(blobId, 1, ?) = ? AND createdAt > ?
                        )
                        """,
                    arguments: [
                        hashHexLength, hashName,
                        hashHexLength, hashName,
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
    // `GraphAPI.messageFull`) call this. Two callers, identical behavior,
    // impossible to drift.

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
            print("[BodyAssetStore] attachmentAssetId read failed: \(error)")
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
            print("[BodyAssetStore] contentType read failed: \(error)")
            return nil
        }
    }

    // MARK: - Public: LRU bump (the only bump site is user tap)

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
                print("[BodyAssetStore] bumpMessageAccess failed for \(contentKey): \(error)")
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

    /// Returns the oldest-accessed messages with at least one asset, paged.
    /// Used by `BodyAssetMaintenance.evictIfOverCap`. NULL `lastAccessedAt`
    /// sorts first (never-tapped messages evict first).
    static func oldestAccessedMessages(limit: Int) -> [VictimSummary] {
        guard let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT headerId,
                           SUM(sizeBytes) AS totalBytes,
                           SUM(CASE WHEN kind = 0 THEN 1 ELSE 0 END) AS inlineCount
                    FROM bodyAsset
                    GROUP BY headerId
                    HAVING totalBytes > 0
                    ORDER BY MAX(COALESCE(lastAccessedAt, 0)) ASC
                    LIMIT ?
                    """,
                    arguments: [limit]
                )
                return rows.map {
                    VictimSummary(
                        contentKey: $0["headerId"],
                        totalBytes: $0["totalBytes"],
                        inlineCount: $0["inlineCount"]
                    )
                }
            }
        } catch {
            print("[BodyAssetStore] oldestAccessedMessages failed: \(error)")
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
    /// holds anything, the removal misses, and every one of that message's files
    /// leaks until `pruneOrphanFiles()` reclaims it 60s later. Deriving the
    /// directories from `substr(id, 1, hashHexLength)` of the rows actually being
    /// deleted is correct in both worlds, and byte-identical at HEAD where no
    /// re-key has happened (the only distinct prefix IS `headerHash(contentKey)`).
    @discardableResult
    static func deleteAllAssets(forContentKey contentKey: ContentKey) -> Int64 {
        guard let queue = manifestQueue() else { return 0 }
        let deletion: (bytes: Int64, blobIds: [String])
        do {
            deletion = try queue.write { db -> (bytes: Int64, blobIds: [String]) in
                let blobIds = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM bodyAsset WHERE headerId = ?",
                    arguments: [contentKey]
                )
                let total = try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset WHERE headerId = ?",
                    arguments: [contentKey]
                ) ?? 0
                try db.execute(
                    sql: "DELETE FROM bodyAsset WHERE headerId = ?",
                    arguments: [contentKey]
                )
                return (total, blobIds)
            }
        } catch {
            print("[BodyAssetStore] deleteAllAssets manifest failed for \(contentKey): \(error)")
            return 0
        }
        for blobId in deletion.blobIds {
            removeBlobIfUnreferenced(blobId)
        }
        // No rows: fall back to the key's own hash so a manifest-less directory left
        // by an interrupted write is still reclaimed — the pre-existing behaviour,
        // now narrowed to an EMPTY, unleased directory so it cannot take a
        // concurrent writer's in-flight bytes with it.
        let headerHashes: Set<String> = deletion.blobIds.isEmpty
            ? [headerHash(contentKey)]
            : Set(deletion.blobIds.map { String($0.prefix(hashHexLength)) })
        for hash in headerHashes {
            removeHeaderDirectoryIfIdle(hashName: hash)
        }
        invalidateUsedBytesCache()
        return deletion.bytes
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
        guard oldKey != newKey, let queue = manifestQueue() else { return 0 }
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
            print("[BodyAssetStore] rekeyContentKey failed for \(oldKey): \(error)")
            return 0
        }
        if moved < 0 {
            _ = deleteAllAssets(forContentKey: oldKey)
            return 0
        }
        return moved
    }

    /// Delete all manifest rows + files for a kind. Returns the set of content keys
    /// affected (so the maintenance layer can do its main-DB cleanup for kind=0).
    /// Idempotent. Does NOT touch main DB.
    @discardableResult
    static func deleteAllAssets(kind: BodyAssetKind) -> Set<ContentKey> {
        guard let queue = manifestQueue() else { return [] }
        let snapshot: [(id: String, contentKey: ContentKey)]
        do {
            snapshot = try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, headerId FROM bodyAsset WHERE kind = ?",
                    arguments: [kind.rawValue]
                )
                return rows.map { (id: $0["id"], contentKey: $0["headerId"]) }
            }
        } catch {
            print("[BodyAssetStore] deleteAllAssets(kind:) snapshot failed: \(error)")
            return []
        }
        guard !snapshot.isEmpty else { return [] }
        let contentKeys = Set(snapshot.map(\.contentKey))
        do {
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM bodyAsset WHERE kind = ?",
                    arguments: [kind.rawValue]
                )
            }
        } catch {
            print("[BodyAssetStore] deleteAllAssets(kind:) manifest delete failed: \(error)")
        }
        for entry in snapshot {
            removeBlobIfUnreferenced(entry.id)
        }
        // Only rmdir if now empty (other kind's files may remain) and unleased.
        // Directories come from the ROWS, same as `deleteAllAssets(forContentKey:)`
        // — re-hashing the key names the wrong directory after a `rekeyContentKey`.
        for hashName in Set(snapshot.map { String($0.id.prefix(hashHexLength)) }) {
            removeHeaderDirectoryIfIdle(hashName: hashName)
        }
        invalidateUsedBytesCache()
        return contentKeys
    }

    /// Returns the set of distinct content keys present in the manifest.
    /// Used by `BodyAssetMaintenance.pruneOrphans` for the cross-DB sweep.
    static func allManifestContentKeys() -> Set<ContentKey> {
        guard let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                let ids = try ContentKey.fetchAll(db, sql: "SELECT DISTINCT headerId FROM bodyAsset")
                return Set(ids)
            }
        } catch {
            print("[BodyAssetStore] allManifestContentKeys failed: \(error)")
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
            print("[BodyAssetStore] allManifestContentKeysByKind failed: \(error)")
            return []
        }
    }

    /// Filesystem-only orphan sweep: reaps abandoned preparation leases, deletes
    /// files older than `sweepMinAgeSeconds` after an atomic manifest + LIVE
    /// preparation-lease recheck, and reclaims header directories that are empty
    /// and have been idle for at least the same threshold. Does NOT cross to the
    /// main DB. Safe to run from any target.
    static func pruneOrphanFiles() {
        guard let dir = storeDirectory(), let queue = manifestQueue() else { return }

        // Table-wide reap of abandoned leases. `removeBlobIfUnreferenced` reaps
        // per-blob, but a writer that died before its bytes ever hit disk leaves
        // a lease no file-driven sweep would ever visit. This is the only
        // periodic entry point, so it owns the table-wide pass. Deleting a lease
        // NEVER deletes bytes — it only stops an abandoned lease from vetoing
        // the age-gated file sweep below.
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
            print("[BodyAssetStore] pruneOrphanFiles known-hashes read failed: \(error)")
            return
        }

        let topContents: [URL]
        do {
            topContents = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
        } catch {
            print("[BodyAssetStore] pruneOrphanFiles scandir failed: \(error)")
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
                do {
                    knownFileIds = try queue.read { db in
                        let rows = try String.fetchAll(
                            db,
                            sql: "SELECT id FROM bodyAsset WHERE substr(id, 1, ?) = ?",
                            arguments: [hashHexLength, name]
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

    static func _setTestEnvironment(containerURL: URL, queue: DatabaseQueue) {
        testOverride.withLock { $0 = (containerURL, queue) }
        usedBytesCache.withLock { $0 = nil }
    }

    static func _makeTestQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_header ON bodyAsset (headerId)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_lru ON bodyAsset (lastAccessedAt)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bodyAsset_attachmentLookup ON bodyAsset (headerId, kind, attachmentSection)")
        }
        return queue
    }

    static func _resetForTesting() {
        testOverride.withLock { $0 = nil }
        queueCache.withLock { $0 = nil }
        usedBytesCache.withLock { $0 = nil }
    }
}
