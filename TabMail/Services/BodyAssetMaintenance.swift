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
                print("[BodyAssetMaintenance] dropMessage main-DB write failed for \(contentKey): \(error)")
                return 0
            }
        }
        return BodyAssetStore.deleteAllAssets(forContentKey: contentKey)
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
                print("[BodyAssetMaintenance] wipeAll(.inlineImage) main-DB write failed: \(error)")
                return
            }
            BackgroundSyncLogger.logBackfill("[AssetEvict] wipeAll(.inlineImage): \(affected.count) messages' cached bodies dropped")
        }
        // Manifest rows + files.
        _ = BodyAssetStore.deleteAllAssets(kind: kind)
    }

    /// Cross-DB + filesystem orphan sweep. Main-app only.
    /// 1. Finds manifest rows nothing owns any more and deletes them via
    ///    `BodyAssetStore.deleteAllAssets(forContentKey:)`.
    /// 2. Filesystem-only orphan files via `BodyAssetStore.pruneOrphanFiles()`.
    ///
    /// ## 🚨 THE MASS-DELETION HAZARD THIS SWEEP USED TO CARRY
    ///
    /// Step 1 used to be exactly `manifestKeys.subtracting(liveKeys)` where
    /// `liveKeys` came straight out of `SELECT id FROM messageHeader` — i.e. it
    /// decided that content was garbage by asking whether its key was still a
    /// `messageHeader.id`. The instant those two stop being the same string
    /// (Stage E1 moves a UID-addressed account's content key onto the RFC 822
    /// Message-ID so a body survives a `UIDVALIDITY` renumber), **every** asset row
    /// of **every** IMAP/iCloud message reads as an orphan and the user's cached
    /// bodies and attachments are deleted wholesale.
    ///
    /// Three things now stand between a key-space divergence and a delete, and a key
    /// must clear ALL of them:
    ///
    /// 1. it must not be a live `messageHeader.id` (the original probe, kept — it
    ///    protects every live header even when its `Folder` row is missing);
    /// 2. `MessageContentStore.protectedKeys` must not protect it — that covers
    ///    "some header still MINTS this key" (the E1-proof question), "the folder is
    ///    under a `UIDVALIDITY` quarantine", and "the ownership read threw";
    /// 3. drift recovery must decline it. A key whose message merely MOVED is
    ///    re-keyed in the manifest, preserving its cached inline images and
    ///    attachments, instead of being deleted and re-downloaded — the same
    ///    heal-don't-delete leg `SyncEngine.pruneFTSOrphans` has had for the FTS
    ///    index, which this sweep never had.
    ///
    /// Deletion is therefore a strict NARROWING of the previous behaviour: nothing
    /// that survived before can be deleted now.
    static func pruneOrphans() async {
        // 1. Cross-DB row sweep.
        let manifestKeys = BodyAssetStore.allManifestContentKeys()
        if !manifestKeys.isEmpty {
            do {
                let keys = Array(manifestKeys)
                // ONE read for both probes: the original "is it a header id" existence
                // check, and the ownership/quarantine gate.
                let (liveKeys, protected) = try await AppDatabase.dbPool.read {
                    db -> (Set<ContentKey>, Set<ContentKey>) in
                    let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
                    let args = StatementArguments(keys)
                    // ⚠ These ARE `messageHeader.id`s. They are typed `ContentKey` only
                    // to compare against the manifest's key space, which is sound
                    // BECAUSE the result is used to PROTECT, never to authorize a
                    // delete: at E1 this probe simply stops matching, and every key it
                    // stops matching is then judged by the ownership gate below.
                    let ids = try ContentKey.fetchAll(
                        db,
                        sql: "SELECT id FROM messageHeader WHERE id IN (\(placeholders))",
                        arguments: args
                    )
                    let live = Set(ids)
                    // ⚑ THE GATE IS ASKED ONLY ABOUT THE DEAD CANDIDATES, and that is
                    // identical BY CONSTRUCTION rather than by care. `protected` has
                    // exactly one consumer, the next statement, and it is
                    // `manifestKeys.subtracting(liveKeys).subtracting(protected)` — so a
                    // key that is already in `liveKeys` has been excluded before
                    // `protected` is consulted and its protection status cannot change
                    // the result. Subtracting a set element that is not in the minuend
                    // is a no-op, so narrowing the INPUT to `manifestKeys - liveKeys`
                    // yields the same `dead` set for every possible database state.
                    //
                    // Why it matters: `protectedKeys` issues one ownership query PER KEY
                    // (`MessageContentStore.owners`), and this runs on the 60-second
                    // foreground maintenance poll. Asked about the whole manifest that
                    // is O(manifest); asked about the dead candidates it is O(what we
                    // were about to delete), normally zero — in which case `protectedKeys`
                    // returns on its own empty guard.
                    //
                    // NEGATIVE CASE, because this is an equivalence claim and an
                    // unqualified one would be an absolute without its scope: the ONE
                    // observable difference is that an empty dead set no longer reads the
                    // folder/account roster, so a roster read that would have THROWN now
                    // does not. That cannot change any deletion — with no dead candidates
                    // there is nothing to delete either way — and whenever a candidate
                    // does exist the roster is read and a throw propagates to the
                    // fail-safe `catch` exactly as before.
                    let deadCandidates = keys.filter { !live.contains($0) }
                    return (live, try MessageContentStore.protectedKeys(among: deadCandidates, db: db))
                }
                let dead = manifestKeys.subtracting(liveKeys).subtracting(protected)
                guard !dead.isEmpty else {
                    BodyAssetStore.pruneOrphanFiles()
                    return
                }
                // Drift recovery BEFORE deletion — resolved in one read for the whole
                // dead set rather than one read per key.
                let recoveries = try await AppDatabase.dbPool.read {
                    db -> [ContentKey: ContentKey] in
                    let scopes = try MessageContentStore.roster(db)
                    var map: [ContentKey: ContentKey] = [:]
                    for key in dead {
                        guard let scope = MessageContentStore.resolveScope(for: key, in: scopes),
                              let tail = scope.tail(of: key),
                              let newKey = try MessageContentStore.recoverMovedContentKey(
                                  orphan: key, accountId: scope.accountId,
                                  providerMessageId: tail, db: db)
                        else { continue }
                        map[key] = newKey
                    }
                    return map
                }
                var recovered = 0
                var deleted = 0
                for contentKey in dead {
                    // Abandon if backgrounded mid-sweep (ADR-IOS-046) — non-WAL deletes
                    // held into suspension are the same 0xdead10cc risk as the reads.
                    guard DatabaseSuspension.isAppActive && !DatabaseSuspension.isSuspended else { break }
                    if let newKey = recoveries[contentKey] {
                        recovered += BodyAssetStore.rekeyContentKey(from: contentKey, to: newKey) > 0 ? 1 : 0
                        continue
                    }
                    _ = BodyAssetStore.deleteAllAssets(forContentKey: contentKey)
                    deleted += 1
                }
                if recovered > 0, DebugModeManager.isLoggingEnabled() {
                    print("[BodyAssetMaintenance] cross-DB sweep: re-keyed \(recovered) moved messages' assets, deleted \(deleted) orphans")
                }
            } catch {
                // FAIL-SAFE: a failed read decides nothing. Deleting on an unanswered
                // question is the one outcome with no path back for the user.
                print("[BodyAssetMaintenance] cross-DB sweep failed: \(error)")
            }
        }

        // 2. Filesystem orphan sweep.
        BodyAssetStore.pruneOrphanFiles()
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

