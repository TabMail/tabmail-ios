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
/// **Write/delete idempotency** — file first then row on writes; deleting
/// runs in the order chosen by `BodyAssetMaintenance` so partial failures
/// always self-heal on the next sweep.
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
    /// (race guard for in-flight write→insert).
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
                        lastAccessedAt    INTEGER
                    )
                    """)
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
    static func headerHash(_ headerId: String) -> String {
        sha256Hex(headerId, take: hashHexLength)
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

    /// Folder URL for a given headerId (debug/reporting only).
    static func folder(for headerId: String) -> URL? {
        storeDirectory()?.appendingPathComponent(headerHash(headerId), isDirectory: true)
    }

    // MARK: - Public: writes (identical path in NSE and main app)

    /// Writes inline image bytes. Returns the assetId on success, nil on failure.
    static func writeInlineImage(
        headerId: String, contentId: String, contentType: String, data: Data
    ) -> String? {
        write(headerId: headerId, kind: .inlineImage, key: contentId,
              contentType: contentType, data: data)
    }

    /// Writes attachment bytes. Returns the assetId on success, nil on failure.
    static func writeAttachment(
        headerId: String, section: String, contentType: String, data: Data
    ) -> String? {
        write(headerId: headerId, kind: .attachment, key: section,
              contentType: contentType, data: data)
    }

    private static func write(
        headerId: String, kind: BodyAssetKind, key: String,
        contentType: String, data: Data
    ) -> String? {
        guard let dir = storeDirectory(), let queue = manifestQueue() else { return nil }
        let hHash = headerHash(headerId)
        let aHash = assetHash(key)
        let id = "\(hHash)/\(aHash)"

        // 1. File first.
        let folderURL = dir.appendingPathComponent(hHash, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL.appendingPathComponent(aHash)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[BodyAssetStore] file write failed for \(id): \(error)")
            return nil
        }

        // 2. Row second. Initial write does NOT bump LRU.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let contentIdValue: String? = (kind == .inlineImage) ? key : nil
        let attachmentSectionValue: String? = (kind == .attachment) ? key : nil
        do {
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO bodyAsset (id, headerId, kind, contentId, attachmentSection,
                                           contentType, sizeBytes, createdAt, lastAccessedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(id) DO UPDATE SET
                        contentType = excluded.contentType,
                        sizeBytes = excluded.sizeBytes
                    """,
                    arguments: [
                        id, headerId, kind.rawValue,
                        contentIdValue, attachmentSectionValue,
                        contentType, data.count, nowMs
                    ]
                )
            }
        } catch {
            print("[BodyAssetStore] row insert failed for \(id): \(error)")
            return nil
        }

        invalidateUsedBytesCache()
        return id
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
    static func makeInlineImageWriter(forHeaderId headerId: String) -> BodyRenderer.InlineImageWriter {
        return { img in
            guard let id = writeInlineImage(
                headerId: headerId,
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

    /// Looks up the assetId for an attachment by (headerId, section).
    static func attachmentAssetId(headerId: String, section: String) -> String? {
        guard let queue = manifestQueue() else { return nil }
        do {
            return try queue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM bodyAsset WHERE headerId = ? AND kind = ? AND attachmentSection = ?",
                    arguments: [headerId, BodyAssetKind.attachment.rawValue, section]
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
    static func bumpMessageAccess(headerId: String) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        Task.detached(priority: .utility) {
            guard let queue = manifestQueue() else { return }
            do {
                try queue.write { db in
                    try db.execute(
                        sql: "UPDATE bodyAsset SET lastAccessedAt = ? WHERE headerId = ?",
                        arguments: [nowMs, headerId]
                    )
                }
            } catch {
                print("[BodyAssetStore] bumpMessageAccess failed for \(headerId): \(error)")
            }
        }
    }

    // MARK: - Internal primitives (used by BodyAssetMaintenance, main-app only)

    /// Snapshot of one message's asset aggregate, for eviction ordering.
    struct VictimSummary: Sendable {
        let headerId: String
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
                        headerId: $0["headerId"],
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

    /// Delete all manifest rows + files for a single headerId. Returns bytes
    /// reclaimed. Idempotent. Does NOT touch main DB.
    @discardableResult
    static func deleteAllAssets(forHeaderId headerId: String) -> Int64 {
        guard let queue = manifestQueue() else { return 0 }
        let bytesReclaimed: Int64
        do {
            bytesReclaimed = try queue.write { db -> Int64 in
                let total = try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM bodyAsset WHERE headerId = ?",
                    arguments: [headerId]
                ) ?? 0
                try db.execute(
                    sql: "DELETE FROM bodyAsset WHERE headerId = ?",
                    arguments: [headerId]
                )
                return total
            }
        } catch {
            print("[BodyAssetStore] deleteAllAssets manifest failed for \(headerId): \(error)")
            return 0
        }
        if let dir = storeDirectory() {
            let folderURL = dir.appendingPathComponent(headerHash(headerId), isDirectory: true)
            try? FileManager.default.removeItem(at: folderURL)
        }
        invalidateUsedBytesCache()
        return bytesReclaimed
    }

    /// Delete all manifest rows + files for a kind. Returns the set of headerIds
    /// affected (so the maintenance layer can do its main-DB cleanup for kind=0).
    /// Idempotent. Does NOT touch main DB.
    @discardableResult
    static func deleteAllAssets(kind: BodyAssetKind) -> Set<String> {
        guard let queue = manifestQueue() else { return [] }
        let snapshot: [(id: String, headerId: String)]
        do {
            snapshot = try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, headerId FROM bodyAsset WHERE kind = ?",
                    arguments: [kind.rawValue]
                )
                return rows.map { (id: $0["id"], headerId: $0["headerId"]) }
            }
        } catch {
            print("[BodyAssetStore] deleteAllAssets(kind:) snapshot failed: \(error)")
            return []
        }
        guard !snapshot.isEmpty else { return [] }
        let headerIds = Set(snapshot.map(\.headerId))
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
        if let dir = storeDirectory() {
            for entry in snapshot {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.id))
            }
            for headerId in headerIds {
                let folderURL = dir.appendingPathComponent(headerHash(headerId), isDirectory: true)
                // Only rmdir if now empty (other kind's files may remain).
                if let contents = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil),
                   contents.isEmpty {
                    try? FileManager.default.removeItem(at: folderURL)
                }
            }
        }
        invalidateUsedBytesCache()
        return headerIds
    }

    /// Returns the set of distinct headerIds present in the manifest.
    /// Used by `BodyAssetMaintenance.pruneOrphans` for the cross-DB sweep.
    static func allManifestHeaderIds() -> Set<String> {
        guard let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                let ids = try String.fetchAll(db, sql: "SELECT DISTINCT headerId FROM bodyAsset")
                return Set(ids)
            }
        } catch {
            print("[BodyAssetStore] allManifestHeaderIds failed: \(error)")
            return []
        }
    }

    /// Returns the set of distinct headerIds in the manifest that have at least
    /// one row of the given kind. Used by `BodyAssetMaintenance.wipeAll` to
    /// scope the main-DB MessageBody/bodyComplete cleanup to affected headers.
    static func allManifestHeaderIdsByKind(kind: BodyAssetKind) -> Set<String> {
        guard let queue = manifestQueue() else { return [] }
        do {
            return try queue.read { db in
                let ids = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT headerId FROM bodyAsset WHERE kind = ?",
                    arguments: [kind.rawValue]
                )
                return Set(ids)
            }
        } catch {
            print("[BodyAssetStore] allManifestHeaderIdsByKind failed: \(error)")
            return []
        }
    }

    /// Filesystem-only orphan sweep: deletes files older than `sweepMinAgeSeconds`
    /// without a manifest row, and removes empty header directories.
    /// Does NOT cross to the main DB. Safe to run from any target.
    static func pruneOrphanFiles() {
        guard let dir = storeDirectory(), let queue = manifestQueue() else { return }

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

            if !knownHeaderHashes.contains(name) {
                let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(mtime) > sweepMinAgeSeconds {
                    try? FileManager.default.removeItem(at: entry)
                }
                continue
            }

            let knownFileIds: Set<String>
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
                    try? FileManager.default.removeItem(at: file)
                }
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
                    lastAccessedAt    INTEGER
                )
                """)
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
