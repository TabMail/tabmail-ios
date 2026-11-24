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
/// pending-delete worker, are main-app responsibilities and live here.
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
/// - `processPendingDeletes()` — foreground maintenance pass (#1376): deletes the
///   assets of the keys the main database queued on `bodyAssetPendingDelete`.
/// - `runOrphanSweepOnce()` — foreground maintenance pass, once after the update
///   that removed the periodic orphan sweep.
/// - `wipeAll(kind:)` — Settings "Delete All Email Attachments" (called twice,
///   once per kind).
/// - `wipeAllAfterLocalIndexWipe()` — Settings "Nuke database".
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
            let batch = BodyAssetStore.evictionVictims(
                coveringBytes: current - target, limit: evictionBatchSize
            )
            if batch.isEmpty { break }

            for victim in batch {
                let bytesReclaimed = await dropMessage(
                    contentKey: victim.contentKey, inlineCount: victim.inlineCount
                )
                current -= bytesReclaimed
                victims += 1
                if current <= target { break }
            }
        }
        BodyAssetStore.invalidateUsedBytesCachePublic()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let reclaimedMB = Double(startBytes - current) / 1024 / 1024
        BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] evict(\(reason)): \(victims) messages, \(String(format: "%.1f", reclaimedMB))MB reclaimed in \(ms)ms")
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
    static func dropMessage(contentKey: ContentKey, inlineCount: Int) async -> Int64 {
        if inlineCount > 0 {
            do {
                try await AppDatabase.dbPool.write { db in
                    // Cache-presence is the messageBody row itself — do NOT
                    // touch bodyComplete here (see type-level invariant).
                    // `messageBody.id` is a CONTENT key, same space as
                    // `bodyAsset.headerId` — both move together at E1, so this pair
                    // stays consistent by construction.
                    try db.execute(
                        sql: "DELETE FROM messageBody WHERE id = ?",
                        arguments: [contentKey]
                    )
                }
            } catch {
                BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] dropMessage main-DB write failed for \(contentKey): \(error)")
                return 0
            }
        }
        return BodyAssetStore.deleteAllAssets(forContentKey: contentKey)
    }

    /// #1376: the scheme handler found that a rendered message's own inline image
    /// has a manifest row but no file. Drops the message's cached body and assets
    /// (`dropMessage`; the body goes because it names that image), which marks the
    /// content unfetched, never fetched, so the next open fetches both again. Off
    /// the main thread: the handler calls this from its synchronous answer.
    @discardableResult
    static func dropMessageWithMissingFile(_ contentKey: ContentKey) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] missing asset file for \(contentKey.rawValue.prefix(12))…: dropping the cached body")
            // inlineCount 1: the missing asset is an inline image the body names.
            _ = await dropMessage(contentKey: contentKey, inlineCount: 1)
        }
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
            let affected = BodyAssetStore.allManifestContentKeysByKind(kind: .inlineImage)
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
                BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] wipeAll(.inlineImage) main-DB write failed: \(error)")
                return
            }
            BackgroundSyncLogger.logBackfill("[AssetEvict] wipeAll(.inlineImage): \(affected.count) messages' cached bodies dropped")
        }
        // Manifest rows + files.
        _ = BodyAssetStore.deleteAllAssets(kind: kind)
    }

    /// Settings "Nuke database" (#1376): the local index wipe deleted every header,
    /// so both kinds of cached assets go now, rows and files. `async` (and not
    /// main-actor isolated) so the file work runs off the main actor.
    static func wipeAllAfterLocalIndexWipe() async {
        BodyAssetStore.deleteAllAssets(kind: .inlineImage)
        BodyAssetStore.deleteAllAssets(kind: .attachment)
    }

    // MARK: - #1376: deletes from the pending list, not a sweep

    /// The main app's publish owner check for `BodyAssetStore` (#1376), installed
    /// once at launch. Not in the unit-test host: tests render and cache assets for
    /// keys no header names, and the tests of the check install it themselves.
    static func installPublishOwnerCheck() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        BodyAssetStore.setPublishOwnerCheck { headerExists($0) }
    }

    /// Whether `contentKey` names a `messageHeader` row: a content key is its
    /// header's id today (`ContentKey.forHeader`). One primary-key lookup, a
    /// synchronous read through the raw pool (`publish` is synchronous). A failed
    /// read answers false: the publish is refused, which costs a refetch, never a
    /// row that nothing would delete.
    static func headerExists(_ contentKey: ContentKey) -> Bool {
        (try? AppDatabase.rawPool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE id = ?)",
                arguments: [contentKey.rawValue]
            ) ?? false
        }) ?? false
    }

    /// What one `processPendingDeletes` pass did.
    struct PendingDeletePass: Sendable, Equatable {
        var batches = 0
        var dropped = 0
        var deletedKeys = 0
        var rekeyedKeys = 0
    }

    /// #1376: deletes the assets of the keys queued on the main database's
    /// `bodyAssetPendingDelete` list. The v114 triggers queue a header's id in the
    /// same transaction as its delete (or an update of its id), and the
    /// notification extension's merge queues the staged keys it lets go
    /// (`NSEDataBridge.queueStagedAssetKey`), so the list holds the keys whose
    /// assets may have lost their owner. Nothing walks the whole store.
    ///
    /// Per batch of `batchSize` entries, in rowid order:
    /// 1. one manifest read (`BodyAssetStore.contentKeysWithAssets`): a key with no
    ///    manifest row and no write in progress has nothing to delete, so its
    ///    entries are dropped with no manifest write (most keys of a large delete:
    ///    only opened messages cache assets);
    /// 2. one main-database read for the keys that have assets
    ///    (`pendingDeleteDecision`): the live-key probe, the ownership gate and
    ///    moved-key recovery;
    /// 3. per key, re-checking the foreground before each manifest step
    ///    (ADR-IOS-046): live → drop; protected → keep; moved →
    ///    `BodyAssetStore.rekeyContentKeyResult`, drop once it succeeds; otherwise
    ///    `BodyAssetStore.deletePendingContentKey`, drop once `.deleted`;
    /// 4. one write deleting the dropped entries BY ROWID, so an entry for the same
    ///    key queued meanwhile stays;
    /// 5. `checkpoint()` after the batch, outside any write: SQLite autocheckpoint
    ///    is off, so every constant writer bounds the WAL itself.
    ///
    /// A kept entry stays for a later pass and never blocks the rest. A failed read
    /// ends the pass and decides nothing (FAIL-SAFE: deleting on an unanswered
    /// question is the one outcome with no path back for the user). The pass ends
    /// at the end of the list, after `passBudgetSeconds`, or when the app leaves
    /// the foreground.
    ///
    /// ## 🚨 THE MASS-DELETION HAZARD THE PROTECTIONS GUARD AGAINST
    ///
    /// The whole-store sweep this replaced once decided content was garbage by
    /// asking only whether its key was still a `messageHeader.id`. The instant
    /// those two stop being the same string (Stage E1 moves a UID-addressed
    /// account's content key onto the RFC 822 Message-ID so a body survives a
    /// `UIDVALIDITY` renumber), every asset row of every IMAP/iCloud message would
    /// read as an orphan. So a key is deleted only when it clears all three
    /// checks, carried over unchanged from that sweep: it is not a live
    /// `messageHeader.id`; `MessageContentStore.protectedKeys` does not protect it
    /// ("some header still MINTS this key", "the folder is under a `UIDVALIDITY`
    /// quarantine", "the ownership read threw"); and it is not a MOVED message's
    /// old key, whose assets are re-keyed instead of deleted and re-downloaded.
    @discardableResult
    static func processPendingDeletes(
        batchSize: Int = SyncConfig.bodyAssetPendingDeleteBatchSize,
        passBudgetSeconds: TimeInterval = SyncConfig.bodyAssetPendingDeletePassBudgetSeconds,
        checkpoint: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() },
        foreground: @Sendable () -> Bool = { BodyAssetMaintenance.isForeground() }
    ) async -> PendingDeletePass {
        var pass = PendingDeletePass()
        var after: Int64 = 0
        let deadline = CFAbsoluteTimeGetCurrent() + passBudgetSeconds
        while CFAbsoluteTimeGetCurrent() < deadline, foreground() {
            // Raw pool: an async `dbPool.read` would first run the NSE merge.
            let entries: [(rowid: Int64, contentKey: ContentKey)]
            do {
                entries = try await AppDatabase.rawPool.read { db in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT id, contentKey FROM bodyAssetPendingDelete WHERE id > ? ORDER BY id LIMIT ?",
                        arguments: [after, batchSize]
                    ).map { (rowid: $0["id"], contentKey: ContentKey(rawValue: $0["contentKey"])) }
                }
            } catch {
                logPendingDeleteFailure("batch read", error)
                break
            }
            guard let last = entries.last else { break }
            after = last.rowid
            pass.batches += 1
            var seen = Set<ContentKey>()
            let keys = entries.map(\.contentKey).filter { seen.insert($0).inserted }

            guard foreground(),
                  let withAssets = BodyAssetStore.contentKeysWithAssets(among: keys) else { break }
            var settled = Set(keys.filter { !withAssets.contains($0) })
            var stopped = false
            let candidates = keys.filter { withAssets.contains($0) }
            if !candidates.isEmpty {
                let decision: PendingDeleteDecision
                do {
                    decision = try await AppDatabase.rawPool.read { db in
                        try pendingDeleteDecision(for: candidates, db: db)
                    }
                } catch {
                    logPendingDeleteFailure("decision read", error)
                    break
                }
                for key in candidates {
                    guard foreground() else { stopped = true; break }
                    if decision.live.contains(key) {
                        settled.insert(key)
                    } else if decision.protected.contains(key) {
                        continue
                    } else if let newKey = decision.recoveries[key] {
                        if BodyAssetStore.rekeyContentKeyResult(from: key, to: newKey) != nil {
                            settled.insert(key)
                            pass.rekeyedKeys += 1
                        }
                    } else if case .deleted = BodyAssetStore.deletePendingContentKey(key) {
                        settled.insert(key)
                        pass.deletedKeys += 1
                    }
                }
            }
            let drops = entries.filter { settled.contains($0.contentKey) }.map(\.rowid)
            if !drops.isEmpty {
                do {
                    try await AppDatabase.backgroundPool.write(label: "bodyAssetPendingDelete.drop") { db in
                        let placeholders = Array(repeating: "?", count: drops.count).joined(separator: ",")
                        try db.execute(
                            sql: "DELETE FROM bodyAssetPendingDelete WHERE id IN (\(placeholders))",
                            arguments: StatementArguments(drops)
                        )
                    }
                    pass.dropped += drops.count
                } catch {
                    logPendingDeleteFailure("drop", error)
                    stopped = true
                }
            }
            await checkpoint()
            if stopped { break }
        }
        if pass.deletedKeys + pass.rekeyedKeys > 0, DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] pending deletes: deleted \(pass.deletedKeys) keys' assets, re-keyed \(pass.rekeyedKeys), dropped \(pass.dropped) entries in \(pass.batches) batches")
        }
        return pass
    }

    /// What the main database says about a batch's pending keys that have assets.
    struct PendingDeleteDecision: Sendable {
        var live: Set<ContentKey> = []
        var protected: Set<ContentKey> = []
        var recoveries: [ContentKey: ContentKey] = [:]
    }

    /// One read for `keys`: which are live header ids, which of the rest the
    /// ownership gate protects, and which of the rest are a moved message's old key
    /// (with its new key). Throws when any part cannot be answered; the caller then
    /// decides nothing for the batch.
    static func pendingDeleteDecision(for keys: [ContentKey], db: Database) throws -> PendingDeleteDecision {
        var decision = PendingDeleteDecision()
        guard !keys.isEmpty else { return decision }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        // ⚠ These ARE `messageHeader.id`s. They are typed `ContentKey` only to
        // compare against the manifest's key space, which is sound BECAUSE the
        // result is used to PROTECT, never to authorize a delete: at E1 this probe
        // simply stops matching, and every key it stops matching is then judged by
        // the ownership gate below.
        decision.live = Set(try ContentKey.fetchAll(
            db,
            sql: "SELECT id FROM messageHeader WHERE id IN (\(placeholders))",
            arguments: StatementArguments(keys)
        ))
        // ⚑ THE GATE IS ASKED ONLY ABOUT THE DEAD KEYS: a live key is dropped
        // before protection is consulted, so its protection cannot change the
        // outcome. `protectedKeys` issues one ownership query per key, so this
        // keeps the cost to what is about to be deleted.
        let dead = keys.filter { !decision.live.contains($0) }
        decision.protected = try MessageContentStore.protectedKeys(among: dead, db: db)
        let unprotected = dead.filter { !decision.protected.contains($0) }
        guard !unprotected.isEmpty else { return decision }
        // Drift recovery BEFORE deletion: a moved message keeps its cached assets.
        let scopes = try MessageContentStore.roster(db)
        for key in unprotected {
            guard let scope = MessageContentStore.resolveScope(for: key, in: scopes),
                  let tail = scope.tail(of: key),
                  let newKey = try MessageContentStore.recoverMovedContentKey(
                      orphan: key, accountId: scope.accountId,
                      providerMessageId: tail, db: db)
            else { continue }
            decision.recoveries[key] = newKey
        }
        return decision
    }

    /// UserDefaults key set once `runOrphanSweepOnce` has completed.
    static let orphanSweepDoneKey = "bodyAssetOrphanSweepDone_v1"

    /// #1376: the whole-store sweep, run ONCE, after the update that replaced it
    /// with the pending-delete list, for assets orphaned before the list existed.
    /// Gated by a standard `UserDefaults` flag set only after a completed run (the
    /// pattern of `SyncEngine.runRefreshPlannerStatisticsIfStale`); a run abandoned
    /// in the background leaves it unset and the next pass starts over, which is
    /// harmless (a key queued twice costs the worker nothing). A lost flag reruns
    /// it once.
    ///
    /// 1. Walks the manifest's distinct keys a page at a time and queues each
    ///    page's keys that name no header on `bodyAssetPendingDelete`, one write per
    ///    page and then `checkpoint()`. The worker then applies the protections and
    ///    deletes, exactly as for any queued key.
    /// 2. `BodyAssetStore.pruneOrphanFiles()`: files no manifest row names.
    @discardableResult
    static func runOrphanSweepOnce(
        defaults: UserDefaults = .standard,
        markerKey: String = orphanSweepDoneKey,
        pageSize: Int = SyncConfig.bodyAssetOrphanSweepPageSize,
        checkpoint: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() },
        foreground: @Sendable () -> Bool = { BodyAssetMaintenance.isForeground() }
    ) async -> Bool {
        guard !defaults.bool(forKey: markerKey) else { return false }
        var after: ContentKey?
        while true {
            guard foreground(),
                  let page = BodyAssetStore.manifestContentKeys(after: after, limit: pageSize) else { return false }
            guard let last = page.last else { break }
            after = last
            do {
                try await AppDatabase.backgroundPool.write(label: "bodyAssetOrphanSweep.queue") { db in
                    for key in page {
                        try db.execute(
                            sql: """
                                INSERT INTO bodyAssetPendingDelete (contentKey)
                                SELECT ? WHERE NOT EXISTS (SELECT 1 FROM messageHeader WHERE id = ?)
                                """,
                            arguments: [key.rawValue, key.rawValue]
                        )
                    }
                }
            } catch {
                logPendingDeleteFailure("orphan sweep queue", error)
                return false
            }
            await checkpoint()
            if page.count < pageSize { break }
        }
        guard foreground() else { return false }
        BodyAssetStore.pruneOrphanFiles()
        defaults.set(true, forKey: markerKey)
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] one-time orphan sweep completed")
        }
        return true
    }

    /// The manifest is a non-WAL `DatabaseQueue`: a read or write may only START in
    /// the foreground (ADR-IOS-046). The default of the `foreground` parameter of
    /// `processPendingDeletes` and `runOrphanSweepOnce`; tests pass their own.
    static func isForeground() -> Bool {
        DatabaseSuspension.isAppActive && !DatabaseSuspension.isSuspended
    }

    private static func logPendingDeleteFailure(_ step: String, _ error: Error) {
        guard !error.isDatabaseSuspensionAbort else { return }
        BackgroundSyncLogger.logDebug("[BodyAssetMaintenance] pending delete \(step) failed: \(error)")
    }
}

/// The identity a cached ATTACHMENT is bound to, as a single opaque string the
/// manifest stores verbatim and compares with `=` (ADR-IOS-066 / T5.1).
///
/// ⚑ THE PROBLEM IT SOLVES, stated as the closure rather than the instance. An
/// attachment is cached at `(contentKey, attachmentSection)`. Neither half names a
/// message: `contentKey`'s tail is the provider message id — an IMAP UID, which a
/// `UIDVALIDITY` change reassigns to a different physical message — and
/// `attachmentSection` is a positional MIME part path that essentially every
/// multipart message reuses. So the address alone can, and after a reset does,
/// resolve to a DIFFERENT message's bytes. This value is the missing term: what the
/// bytes were fetched FOR.
///
/// ⚑ IT IS EVIDENCE, NOT MUTATION AUTHORITY. Reading the RFC 822 Message-ID to
/// answer "are these the same message?" is permitted on `v3`; keying a durable
/// mutation by it is not (D4). Nothing derived from this value ever executes a
/// provider action, and nothing derived from it ever deletes: a nil stamp, an absent
/// stamp on a stored row, or a differing stamp all mean exactly one thing —
/// RE-FETCH.
///
/// PORT of the identity LADDER in `v2final`'s
/// `DisplayedAttachmentIdentity.resolve(for:)` (same file there; commit `486bafd4b`),
/// with three deliberate subtractions:
///
///  - **SUBTRACT `DisplayedAttachmentIdentity.settledUidEpoch(_:)`.** The reference
///    had to read the FOLDER's *current* `lastKnownUidValidity`, because `v2final`'s
///    `MessageHeader` carries no epoch of its own (its own comment says so). That
///    forced it to slam the bare-UID door shut for any folder with ANY reset history,
///    since a retained pre-reset snapshot would otherwise be "confirmed" against the
///    post-reset epoch. `v3` has `MessageHeader.observedUidValidity` — the epoch
///    observed by the exact SELECT/FETCH that supplied THIS row's UID, marked
///    `⚑ NO REFERENCE — INVENTED` there precisely because `486bafd4b` deferred it.
///    Reading the row's own proven epoch cannot sample a later one, so the premise of
///    the reference's extra refusal is unreachable here.
///  - **SUBTRACT the `.providerMessageId` leg for `.gmail` / `.outlook`.** The
///    reference resolved the provider by reading `Account` from the database. A
///    stable-provider id is never reassigned, so its `contentKey` already IS a
///    positive identity and the leg adds no safety; keeping it would only buy a cache
///    HIT for a stable-provider message with no usable RFC 822 Message-ID, at the
///    cost of an async DB read on the attachment-tap path. Those messages fall to
///    `nil` and re-fetch. ACCEPTED LIMITATION, recorded rather than hidden: a
///    correctness-neutral cache regression for a rare shape.
///  - **SUBTRACT `matches(currentHeader:provider:currentFolder:)`.** That half of the
///    reference type guards ACTIONS, not the cache. `v3` guards actions through the
///    `observedUidValidity` admission stamps in `AccountManagerActions` /
///    `AccountManagerQueue`; re-deriving a second, parallel action guard here is the
///    compensating-mechanism shape rule A3 forbids.
enum AttachmentCacheIdentity {

    /// The stamp for a message, or `nil` when its identity cannot be PROVEN — in
    /// which case the caller must neither read nor write the attachment cache.
    ///
    /// The ladder, in order, each rung a positive identity:
    ///  1. a usable RFC 822 Message-ID — device-independent and epoch-independent,
    ///     so it survives every renumber the address does not;
    ///  2. the header's own `observedUidValidity`. A bare UID is only an address, but
    ///     a UID paired with the `UIDVALIDITY` it was proven under IS an identity:
    ///     within one epoch an IMAP server never reassigns a UID, and the UID itself
    ///     is already the `contentKey`'s tail. (Stable-provider headers leave this
    ///     column nil by design, so this rung cannot fire for them.)
    ///  3. otherwise nil — refuse.
    ///
    /// `comparableRfc822Identity` is the correct normalizer here, NOT
    /// `usableRfc822Tail`: this value is compared with `=`, never used as a key tail,
    /// so the `':'` folder-scoping rejection that `usableRfc822Tail` adds would only
    /// throw away real identities (see both doc comments in `MessageIdentity`).
    ///
    /// The rung prefixes are load-bearing: they keep an RFC identity and an epoch
    /// from ever comparing equal to one another.
    static func stamp(for header: MessageHeader) -> String? {
        if let rfc = MessageIdentity.comparableRfc822Identity(header.rfc822MessageId) {
            return "rfc:\(rfc)"
        }
        if let epoch = header.observedUidValidity {
            return "uid:\(epoch)"
        }
        return nil
    }
}

