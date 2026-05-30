/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Main-app orchestration for `BodyAssetStore`. Lives in the main app target
/// (not Shared) because it coordinates with `AppDatabase` (`messageBody` /
/// `messageHeader` tables) which the NSE target can't access.
///
/// `BodyAssetStore` itself is NSE-safe: writes, reads, and bumps run identically
/// in both targets. The kind=0 path's `bodyComplete = 0` flip + `MessageBody`
/// row drop, plus the cross-DB orphan sweep, are main-app responsibilities and
/// live here.
///
/// Triggers (all main-app):
/// - `evictIfOverCap()` — after-write trigger, foreground sweep, picker change.
/// - `pruneForPressure()` — `.critical` thermalState or memory warning.
/// - `pruneOrphans()` — startup + foreground sweep.
/// - `wipeAll(kind:)` — Settings "Delete All Email Attachments" (called twice,
///   once per kind).
enum BodyAssetMaintenance {
    /// Eviction target = cap * factor (hysteresis to avoid thrashing).
    private static let evictionHysteresisFactor = 0.9

    /// Thermal/memory pressure prune target = cap * ratio.
    private static let thermalPruneRatio = 0.5

    /// Snapshot batch size per LRU pass.
    private static let evictionBatchSize = 100

    /// Hard ceiling on eviction iterations to prevent runaway loops on bugs.
    private static let maxEvictionIterations = 1000

    /// LRU eviction. Drops oldest-accessed messages' assets whole until under cap.
    /// kind=0 victims also get `bodyComplete = 0` + `MessageBody` row drop in
    /// the main DB (so the body queue refetches on next open).
    static func evictIfOverCap() async {
        await evict(target: { capBytes in
            Int64(Double(capBytes) * evictionHysteresisFactor)
        })
    }

    /// Tighter prune for thermal/memory pressure.
    static func pruneForPressure() async {
        await evict(target: { capBytes in
            Int64(Double(capBytes) * thermalPruneRatio)
        })
    }

    private static func evict(target targetFn: (Int64) -> Int64) async {
        let budget = BodyAssetStore.attachmentsBudgetMB
        guard budget != BodyAssetConfig.unlimitedBudgetMB else { return }

        let capBytes = Int64(budget) * 1024 * 1024
        let target = targetFn(capBytes)

        var current = BodyAssetStore.usedBytes
        guard current > capBytes else { return }

        var iterations = 0
        while current > target && iterations < maxEvictionIterations {
            iterations += 1
            let batch = BodyAssetStore.oldestAccessedMessages(limit: evictionBatchSize)
            if batch.isEmpty { break }

            for victim in batch {
                let bytesReclaimed = await dropMessage(
                    headerId: victim.headerId, inlineCount: victim.inlineCount
                )
                current -= bytesReclaimed
                if current <= target { break }
            }
        }
        BodyAssetStore.invalidateUsedBytesCachePublic()
    }

    /// Drops a single message's assets. Returns bytes reclaimed (0 on failure).
    /// Order: main-DB write (kind=0 only) → manifest+files via store.
    /// If main-DB write fails, abort — leaving everything in place for retry.
    /// If manifest delete fails after main-DB write, body queue refetches and
    /// the old rows get overwritten via INSERT … ON CONFLICT.
    private static func dropMessage(headerId: String, inlineCount: Int) async -> Int64 {
        if inlineCount > 0 {
            do {
                try await AppDatabase.dbPool.write { db in
                    try db.execute(
                        sql: "DELETE FROM messageBody WHERE id = ?",
                        arguments: [headerId]
                    )
                    try db.execute(
                        sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE id = ?",
                        arguments: [headerId]
                    )
                }
            } catch {
                print("[BodyAssetMaintenance] dropMessage main-DB write failed for \(headerId): \(error)")
                return 0
            }
        }
        return BodyAssetStore.deleteAllAssets(forHeaderId: headerId)
    }

    /// Wipe all assets for a specific kind.
    /// - `.inlineImage`: deletes manifest rows + files + (in main DB) MessageBody
    ///   rows + flips `bodyComplete = 0` for every affected header.
    /// - `.attachment`: deletes manifest rows + files only.
    static func wipeAll(kind: BodyAssetKind) async {
        if kind == .inlineImage {
            // Main DB write FIRST. If it fails for kind=0, abort the wipe —
            // leaving manifest+files in place is safer than orphaned HTML refs.
            let affected = BodyAssetStore.allManifestHeaderIdsByKind(kind: .inlineImage)
            guard !affected.isEmpty else { return }
            do {
                try await AppDatabase.dbPool.write { db in
                    let placeholders = Array(repeating: "?", count: affected.count).joined(separator: ",")
                    let args = StatementArguments(Array(affected))
                    try db.execute(
                        sql: "DELETE FROM messageBody WHERE id IN (\(placeholders))",
                        arguments: args
                    )
                    try db.execute(
                        sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE id IN (\(placeholders))",
                        arguments: args
                    )
                }
            } catch {
                print("[BodyAssetMaintenance] wipeAll(.inlineImage) main-DB write failed: \(error)")
                return
            }
        }
        // Manifest rows + files.
        _ = BodyAssetStore.deleteAllAssets(kind: kind)
    }

    /// Cross-DB + filesystem orphan sweep. Main-app only.
    /// 1. Finds manifest rows whose headerId no longer exists in `messageHeader`.
    ///    Deletes them via `BodyAssetStore.deleteAllAssets(forHeaderId:)`.
    /// 2. Filesystem-only orphan files via `BodyAssetStore.pruneOrphanFiles()`.
    static func pruneOrphans() async {
        // 1. Cross-DB row sweep.
        let manifestHeaderIds = BodyAssetStore.allManifestHeaderIds()
        if !manifestHeaderIds.isEmpty {
            do {
                let liveHeaderIds: Set<String> = try await AppDatabase.dbPool.read { db in
                    let placeholders = Array(repeating: "?", count: manifestHeaderIds.count).joined(separator: ",")
                    let args = StatementArguments(Array(manifestHeaderIds))
                    let ids = try String.fetchAll(
                        db,
                        sql: "SELECT id FROM messageHeader WHERE id IN (\(placeholders))",
                        arguments: args
                    )
                    return Set(ids)
                }
                let dead = manifestHeaderIds.subtracting(liveHeaderIds)
                for headerId in dead {
                    _ = BodyAssetStore.deleteAllAssets(forHeaderId: headerId)
                }
            } catch {
                print("[BodyAssetMaintenance] cross-DB sweep failed: \(error)")
            }
        }

        // 2. Filesystem orphan sweep.
        BodyAssetStore.pruneOrphanFiles()
    }
}
