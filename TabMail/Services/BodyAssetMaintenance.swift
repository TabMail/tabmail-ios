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
/// in both targets. The kind=0 path's `MessageBody` row drop, plus the cross-DB
/// orphan sweep, are main-app responsibilities and live here.
///
/// INVARIANT (2026-07-02): eviction NEVER touches `bodyComplete`. That flag is
/// the FTS-indexed truth (backfill completion / pendingBodyCount / AI + embedding
/// gating) and eviction doesn't remove FTS text. Flipping it here re-enqueued
/// every victim into the backfill body queue, which re-fetched the bodies, which
/// re-filled this cache past its cap, which evicted again — an infinite
/// refetch loop ("indexing goes backwards"). "HTML cache present" needs no flag:
/// the `messageBody` row's existence IS that state, and the detail view already
/// fetches on cache-miss (same contract as `runEvictStaleBodies` /
/// `runPruneIfOverBudget`, which have always deleted rows without flag flips).
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
    /// kind=0 victims also get their `MessageBody` row dropped in the main DB
    /// (their cached HTML references the deleted `tabmail-asset://` files; the
    /// detail view fetches on cache-miss). `bodyComplete` is NOT touched — see
    /// the type-level invariant.
    static func evictIfOverCap() async {
        await evict(reason: "overCap", target: { capBytes in
            Int64(Double(capBytes) * evictionHysteresisFactor)
        })
    }

    /// Tighter prune for thermal/memory pressure.
    static func pruneForPressure() async {
        await evict(reason: "pressure", target: { capBytes in
            Int64(Double(capBytes) * thermalPruneRatio)
        })
    }

    private static func evict(reason: String, target targetFn: (Int64) -> Int64) async {
        let budget = BodyAssetStore.attachmentsBudgetMB
        guard budget != BodyAssetConfig.unlimitedBudgetMB else { return }

        let capBytes = Int64(budget) * 1024 * 1024
        let target = targetFn(capBytes)

        var current = BodyAssetStore.usedBytes
        guard current > capBytes else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        let startBytes = current
        var victims = 0
        var iterations = 0
        while current > target && iterations < maxEvictionIterations {
            iterations += 1
            // Abandon if the app backgrounded mid-eviction (ADR-IOS-046): the manifest
            // is a NON-WAL `DatabaseQueue`, so a read/delete held into process
            // suspension is a `0xdead10cc` kill that `Database.suspendNotification`
            // can't abort mid-`pread`. Foreground-only; re-runs next foreground poll.
            guard DatabaseSuspension.isAppActive && !DatabaseSuspension.isSuspended else { break }
            let batch = BodyAssetStore.oldestAccessedMessages(limit: evictionBatchSize)
            if batch.isEmpty { break }

            for victim in batch {
                let bytesReclaimed = await dropMessage(
                    headerId: victim.headerId, inlineCount: victim.inlineCount
                )
                current -= bytesReclaimed
                victims += 1
                if current <= target { break }
            }
        }
        BodyAssetStore.invalidateUsedBytesCachePublic()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let reclaimedMB = Double(startBytes - current) / 1024 / 1024
        print("[BodyAssetMaintenance] evict(\(reason)): \(victims) messages, \(String(format: "%.1f", reclaimedMB))MB reclaimed in \(ms)ms")
        BackgroundSyncLogger.logBackfill("[AssetEvict] \(reason): \(victims) messages, \(String(format: "%.1f", reclaimedMB))MB reclaimed in \(ms)ms (budget=\(budget)MB)")
    }

    /// Drops a single message's assets. Returns bytes reclaimed (0 on failure).
    /// Order: main-DB write (kind=0 only) → manifest+files via store.
    /// If main-DB write fails, abort — leaving everything in place for retry.
    /// If manifest delete fails after main-DB write, the detail view's
    /// cache-miss fetch re-renders and the old rows get overwritten via
    /// INSERT … ON CONFLICT.
    /// `internal` (not private) so tests can pin the "never touches
    /// bodyComplete" invariant directly.
    static func dropMessage(headerId: String, inlineCount: Int) async -> Int64 {
        if inlineCount > 0 {
            do {
                try await AppDatabase.dbPool.write { db in
                    // Cache-presence is the messageBody row itself — do NOT
                    // touch bodyComplete here (see type-level invariant).
                    try db.execute(
                        sql: "DELETE FROM messageBody WHERE id = ?",
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
    ///   rows for every affected header. `bodyComplete` is NOT touched (see the
    ///   type-level invariant) — the user asked for disk space back, not a
    ///   full-history re-download through the backfill queue; bodies come back
    ///   lazily on open.
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
                }
            } catch {
                print("[BodyAssetMaintenance] wipeAll(.inlineImage) main-DB write failed: \(error)")
                return
            }
            BackgroundSyncLogger.logBackfill("[AssetEvict] wipeAll(.inlineImage): \(affected.count) messages' cached bodies dropped")
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
                    // Abandon if backgrounded mid-sweep (ADR-IOS-046) — non-WAL deletes
                    // held into suspension are the same 0xdead10cc risk as the reads.
                    guard DatabaseSuspension.isAppActive && !DatabaseSuspension.isSuspended else { break }
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
