/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - IMAP External-Deletion Reconcile (ADR-IOS-051)
//
// Raw-IMAP/iCloud accounts have no provider delta feed for deletions, so a
// message deleted externally (webmail, another client) below the windowed
// stale-detection UID floor used to persist in GRDB + FTS indefinitely
// (PROJECT_MEMORY "IMAP external-deletion blind spot", audit 2026-07-02).
// Two evidence-triggered mechanisms close the hole — no periodic jobs, work
// proportional to drift, UID everywhere (never date — ADR-IOS-042):
//
// Phase 1 — IDLE `VANISHED` (RFC 7162): the server NAMES the deleted UIDs.
//   `SyncScheduler` forwards them to `handleVanishedUIDs` for targeted
//   deletes. `.expunge` events carry SEQUENCE numbers (not UIDs) and cannot
//   be mapped safely — they remain generic poll triggers.
//
// Phase 2 — count-mismatch reconcile walk: for IMAP folders, local GRDB is a
//   partial mirror of the server folder (optimistic local deletes remove rows
//   immediately, so pending user deletions only LOWER local count). Therefore
//   `localHeaderCount > server messageCount` proves ghost rows exist.
//   (`local < server` is normal — backfill incomplete.) The evidence is
//   durable and recomputable (COUNT vs latest STATUS) — no persisted walk
//   state is needed; an interrupted walk simply re-triggers, and per-chunk
//   deletion shrinks the mismatch monotonically.
//
// Every deletion flows through `deleteServerConfirmedDeletions`, which applies
// the SAME protections as the windowed stale flow (`runSyncMessages`) and the
// SAME FTS-removal channel (`removeHeadersFromFTS`) — no parallel path.

/// Outcome of one deletion-reconcile walk (Phase 2).
struct DeletionReconcileOutcome: Sendable, Equatable {
    /// Headers deleted across all chunks.
    var deletedCount = 0
    /// Chunks whose UID SEARCH threw — NOTHING was deleted from them.
    var failedChunks = 0
    /// Chunks whose UID SEARCH returned successfully.
    var searchedChunks = 0
    /// True when the walk stopped early (connection error, UIDVALIDITY change,
    /// cancellation, DB failure). The trigger predicate re-fires next sync.
    var aborted = false
    /// Debug-readable abort cause (nil when not aborted).
    var abortReason: String?
}

extension SyncEngine {

    // MARK: - Pure decision functions (selectStaleHeaders style — no DB/IO)

    /// Trigger predicate: ghost rows provably exist iff the local header count
    /// exceeds the server's live message count (plus tolerance). The reverse
    /// (`local < server`) is normal — backfill incomplete — and never triggers.
    nonisolated static func shouldReconcileDeletions(localCount: Int, serverCount: Int, tolerance: Int) -> Bool {
        localCount > serverCount + tolerance
    }

    /// Ghosts in one chunk: local UIDs the server's `UID SEARCH` did NOT list.
    /// Only meaningful for a SUCCESSFUL search response — a failed/thrown
    /// SEARCH must delete nothing (callers never reach this on failure).
    nonisolated static func selectGhostUIDs(localChunk: [UInt32], serverFound: Set<UInt32>) -> [UInt32] {
        localChunk.filter { !serverFound.contains($0) }
    }

    /// Chunk planner: ascending-UID chunks of `chunkSize` covering the local
    /// UID set. Sorted so a partial walk covers a contiguous low-UID prefix.
    nonisolated static func planReconcileChunks(uids: [UInt32], chunkSize: Int) -> [[UInt32]] {
        guard chunkSize > 0, !uids.isEmpty else { return [] }
        let sorted = uids.sorted()
        return stride(from: 0, to: sorted.count, by: chunkSize).map {
            Array(sorted[$0..<min($0 + chunkSize, sorted.count)])
        }
    }

    // MARK: - Walk core (orchestration over injected effects — unit-testable)

    /// Run the reconcile walk over the folder's local UID set. Pure
    /// orchestration: all effects (SEARCH, deletion, UIDVALIDITY persistence)
    /// are injected so the invariants are unit-testable without IMAP:
    ///
    /// - A thrown SEARCH chunk deletes NOTHING from that chunk. Non-connection
    ///   errors skip the chunk and continue; connection/SELECT errors abort.
    /// - UIDVALIDITY guard: `storedUidValidity` (when present) and the first
    ///   successful chunk's SELECT pin the expected value; any later mismatch
    ///   — or an unreported (0) value — ABORTS the walk. When no stored value
    ///   exists, the first observation is persisted via `persistUidValidity`.
    /// - A failed deletion (e.g. DB suspension, ADR-IOS-041/046) aborts —
    ///   abandon and let the trigger predicate re-fire next sync.
    /// - Deletion circuit breaker: `maxDeletions` caps cumulative deletions at
    ///   what the count evidence supports (expected mismatch + slack). The
    ///   walk's per-ghost proof is a single source — the SEARCH response — so
    ///   a response that ever parsed as falsely EMPTY (server quirk, protocol
    ///   regression) would read the whole chunk as ghosts. The cap turns that
    ///   worst case from "folder wiped" into "walk aborted before the
    ///   offending chunk, logged"; the fresh evidence next sync re-derives a
    ///   correct cap if deletions were legitimate.
    nonisolated static func runDeletionReconcileWalk(
        localUIDs: [UInt32],
        chunkSize: Int,
        storedUidValidity: Int?,
        maxDeletions: Int,
        interChunkDelaySeconds: TimeInterval,
        search: @Sendable ([UInt32]) async throws -> UIDExistenceResult,
        deleteGhosts: @Sendable ([UInt32]) async throws -> Int,
        persistUidValidity: @Sendable (UInt32) async throws -> Void
    ) async -> DeletionReconcileOutcome {
        var outcome = DeletionReconcileOutcome()
        var expectedValidity: UInt32? = storedUidValidity.flatMap { UInt32(exactly: $0) }
        let chunks = planReconcileChunks(uids: localUIDs, chunkSize: chunkSize)

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled {
                outcome.aborted = true
                outcome.abortReason = "cancelled"
                break
            }

            let result: UIDExistenceResult
            do {
                result = try await search(chunk)
            } catch {
                // Failed chunk ⟹ delete NOTHING from it (never remove on
                // uncertainty). Connection/SELECT errors abort the walk —
                // every later chunk would fail the same way; the trigger
                // predicate re-fires next sync. Other errors skip just this
                // chunk and continue.
                outcome.failedChunks += 1
                if isConnectionError(error) || isSelectFailedError(error) {
                    outcome.aborted = true
                    outcome.abortReason = "connection error: \(error)"
                    break
                }
                continue
            }
            outcome.searchedChunks += 1

            // UIDVALIDITY guard — 0 means the SELECT did not report a value.
            // A changed (or unknowable) UIDVALIDITY invalidates every local
            // UID, so a "not found" result proves nothing: ABORT. The
            // UID-remap/resync machinery owns that case (ADR-IOS-051).
            guard result.uidValidity != 0 else {
                outcome.aborted = true
                outcome.abortReason = "uidValidity unreported"
                break
            }
            if let expected = expectedValidity {
                guard result.uidValidity == expected else {
                    outcome.aborted = true
                    outcome.abortReason = "uidValidity changed (\(expected) → \(result.uidValidity))"
                    break
                }
            } else {
                expectedValidity = result.uidValidity
                do {
                    try await persistUidValidity(result.uidValidity)
                } catch {
                    outcome.aborted = true
                    outcome.abortReason = "persist uidValidity failed: \(error)"
                    break
                }
            }

            let ghosts = selectGhostUIDs(localChunk: chunk, serverFound: result.found)
            if !ghosts.isEmpty {
                // Circuit breaker: deleting this chunk would exceed what the
                // count evidence supports — abort BEFORE deleting anything
                // from it (never delete on inconsistent evidence). If the
                // excess ghosts are real, next sync's fresh counts raise the
                // cap and the re-triggered walk finishes the job.
                if outcome.deletedCount + ghosts.count > maxDeletions {
                    outcome.aborted = true
                    outcome.abortReason = "deletion cap exceeded (cap=\(maxDeletions), alreadyDeleted=\(outcome.deletedCount), chunkGhosts=\(ghosts.count))"
                    break
                }
                do {
                    outcome.deletedCount += try await deleteGhosts(ghosts)
                } catch {
                    // DB write failure (e.g. suspension) — abandon the walk and
                    // retry on the next trigger (ADR-IOS-046 abandon-on-suspend).
                    outcome.aborted = true
                    outcome.abortReason = "delete failed: \(error)"
                    break
                }
            }

            if index < chunks.count - 1 && interChunkDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(interChunkDelaySeconds))
            }
        }
        return outcome
    }

    // MARK: - Shared server-confirmed deletion path (Phases 1 + 2 both land here)

    /// Delete local headers for UIDs the server has CONFIRMED absent, applying
    /// the SAME protections as the windowed stale flow in `runSyncMessages`
    /// (SyncEngineFullSync.swift): pending ops targeting this folder (source
    /// OR destination — an optimistic move places the row at the destination
    /// with the source UID), recently-completed ops (server-lag bridge), and
    /// in-flight outbox sends (sent folder only). Load pending ops INSIDE the
    /// write transaction (TOCTOU — see PendingOperationSnapshot).
    ///
    /// Protected rows survive this pass; remote-wins is settled by the existing
    /// drain conflict handling (the op no-ops server-side and is dropped), and
    /// the count-mismatch evidence re-fires the reconcile after the queue drains.
    ///
    /// Returns the deleted header ids (for the FTS-removal channel).
    nonisolated static func deleteConfirmedGhostHeaders(
        folderId: String,
        folderPath: String,
        accountId: String,
        folderRole: FolderRole,
        uids: [UInt32],
        recentlyCompleted: [String: Date],
        db: Database
    ) throws -> [String] {
        guard !uids.isEmpty else { return [] }

        // Load candidate rows by EXACT messageId membership (messageId IS the
        // UID for IMAP — pure membership, no UID/date window; ADR-IOS-042-safe).
        let uidStrings = uids.map(String.init)
        var candidates: [MessageHeader] = []
        let sqlChunkSize = SyncConfig.sqlChunkSize
        for start in stride(from: 0, to: uidStrings.count, by: sqlChunkSize) {
            let end = min(start + sqlChunkSize, uidStrings.count)
            let chunk = Array(uidStrings[start..<end])
            candidates += try MessageHeader
                .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                .fetchAll(db)
        }
        guard !candidates.isEmpty else { return [] }

        // SAME protection set as the stale flow (see runSyncMessages).
        let pendingOps = try PendingOperation.fetchAll(db)
        let opsTargetingThisFolder = pendingOps.filter {
            $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
        }
        let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))

        var outboxProtectedRfc822s = Set<String>()
        if folderRole == .sent {
            let outboxRfc822s = try String.fetchAll(db, sql: """
                SELECT sentMessageId FROM outboxMessage
                WHERE accountId = ? AND sentMessageId IS NOT NULL
            """, arguments: [accountId])
            for raw in outboxRfc822s {
                outboxProtectedRfc822s.insert(EmailFilter.normalizeMessageId(raw))
            }
        }

        let isProtected: (MessageHeader) -> Bool = { msg in
            pendingAllIds.containsAnyKey(messageId: msg.messageId, rfc822MessageId: msg.rfc822MessageId) ||
            recentlyCompleted[msg.messageId] != nil ||
            (msg.rfc822MessageId.map { recentlyCompleted[$0] != nil } ?? false) ||
            (msg.rfc822MessageId.map { outboxProtectedRfc822s.contains($0) } ?? false)
        }

        let deletable = candidates.filter { !isProtected($0) }
        for msg in deletable {
            try msg.delete(db) // messageBody CASCADE-deletes; MessageAICache survives by design
        }
        return deletable.map(\.id)
    }

    /// Instance wiring for the shared deletion path: write transaction +
    /// FTS removal via the SAME channel the stale flow uses
    /// (`staleIds → removeHeadersFromFTS`) + unread recount.
    /// Throws on DB failure so callers can abort (never mask failures).
    @discardableResult
    func deleteServerConfirmedDeletions(folder: Folder, uids: [UInt32], reason: String) async throws -> Int {
        guard !uids.isEmpty else { return 0 }
        // Prune before snapshotting — deleteConfirmedGhostHeaders does a presence
        // check (`!= nil`) that doesn't consult per-entry expiry.
        await AccountManager.shared.pruneRecentlyCompleted()
        let recentlyCompleted = await AccountManager.shared.recentlyCompleted
        let folderId = folder.id
        let folderPath = folder.path
        let accountId = folder.accountId
        let folderRole = folder.role
        let deletedIds: [String] = try await dbPool.write { db in
            try Self.deleteConfirmedGhostHeaders(
                folderId: folderId,
                folderPath: folderPath,
                accountId: accountId,
                folderRole: folderRole,
                uids: uids,
                recentlyCompleted: recentlyCompleted,
                db: db
            )
        }
        guard !deletedIds.isEmpty else { return 0 }
        // REUSED wiring: same FTS-removal channel as the stale-deletion flow.
        removeHeadersFromFTS(deletedIds)
        await UnreadCountManager.shared.requestRecount(folderId: folderId)
        if DebugModeManager.isLoggingEnabled() {
            print("[Reconcile] \(folder.name): removed \(deletedIds.count) server-confirmed deleted messages (\(reason))")
        }
        BackgroundSyncLogger.log("reconcile[\(reason)]: \(folder.name) removed \(deletedIds.count)")
        return deletedIds.count
    }

    // MARK: - Phase 1: IDLE VANISHED handler

    /// Targeted deletes from an IDLE `VANISHED` UID set (RFC 7162) — the server
    /// names the deleted UIDs for free. The IDLE connection monitors INBOX
    /// (see `IMAPProvider.launchIdleConnection`), so the UIDs are inbox UIDs.
    /// Unknown UIDs are no-ops; rows protected by pending/recent ops survive
    /// (remote-wins is settled by the existing drain conflict handling).
    func handleVanishedUIDs(accountEmail: String, uids: [UInt32]) async {
        guard !uids.isEmpty else { return }
        do {
            let inbox: Folder? = try await dbPool.read { db in
                guard let account = try Account
                    .filter(Column("emailAddress") == accountEmail)
                    .fetchOne(db) else { return nil }
                return try Folder
                    .filter(Column("accountId") == account.id && Column("role") == FolderRole.inbox.rawValue)
                    .fetchOne(db)
            }
            guard let inbox else {
                if DebugModeManager.isLoggingEnabled() {
                    print("[Reconcile] VANISHED for \(accountEmail): no inbox folder resolved — skipping")
                }
                return
            }
            try await deleteServerConfirmedDeletions(folder: inbox, uids: uids, reason: "IDLE VANISHED")
        } catch {
            // DB failure (e.g. suspension) — abandon; the Phase 2 count-mismatch
            // trigger re-fires on the next sync pass (ADR-IOS-046).
            if DebugModeManager.isLoggingEnabled() {
                print("[Reconcile] VANISHED handling failed for \(accountEmail): \(error)")
            }
        }
    }

    // MARK: - Phase 2: count-mismatch-triggered reconcile walk

    /// Evidence-triggered reconcile walk for one IMAP folder. Callers evaluate
    /// `shouldReconcileDeletions` first (delta sync after its windowed pass;
    /// full sync per folder). Iterates the LOCAL UID set — not the server's
    /// UID space — in chunks of `SyncConfig.deletionReconcileChunkSize`,
    /// `UID SEARCH`es each chunk's explicit UID set, and deletes the UIDs the
    /// server did not list via the shared deletion path. Walk progress is NOT
    /// persisted: the trigger predicate is durable evidence, and per-chunk
    /// deletion shrinks the mismatch monotonically.
    ///
    /// `expectedGhosts` is the trigger's `localCount − serverCount` — the walk
    /// may never delete more than this plus `SyncConfig
    /// .deletionReconcileCapSlack` (circuit breaker; see
    /// `runDeletionReconcileWalk`).
    func reconcileExternallyDeletedMessages(folder: Folder, provider: IMAPProvider, expectedGhosts: Int) async {
        guard let workQueue = workQueues[folder.accountId] else { return }
        // Synchronous check-and-insert (no suspension point) — race-free under
        // actor reentrancy; prevents overlapping walks for the same folder.
        guard !deletionReconcileInFlight.contains(folder.id) else { return }
        deletionReconcileInFlight.insert(folder.id)
        defer { deletionReconcileInFlight.remove(folder.id) }

        // Snapshot the local UID set (single TEXT column for ONE folder —
        // bounded: ~6 bytes/UID; paging by numeric UID would need a
        // CAST(messageId AS INTEGER) full scan PER PAGE, which is worse) and
        // the stored UIDVALIDITY, fresh from GRDB.
        let folderId = folder.id
        let snapshot: (uids: [UInt32], storedValidity: Int?)
        do {
            snapshot = try await dbPool.read { db in
                let ids = try String.fetchAll(db,
                    MessageHeader.select(Column("messageId")).filter(Column("folderId") == folderId)
                )
                let stored = try Folder.fetchOne(db, key: folderId)?.lastKnownUidValidity
                return (ids.compactMap { UInt32($0) }, stored)
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                print("[Reconcile] \(folder.name): snapshot read failed: \(error)")
            }
            return
        }
        guard !snapshot.uids.isEmpty else { return }

        let maxDeletions = max(expectedGhosts, 0) + SyncConfig.deletionReconcileCapSlack
        if DebugModeManager.isLoggingEnabled() {
            print("[Reconcile] \(folder.name): walk START — \(snapshot.uids.count) local UIDs, chunk=\(SyncConfig.deletionReconcileChunkSize), storedUidValidity=\(snapshot.storedValidity.map(String.init) ?? "nil"), deletionCap=\(maxDeletions)")
        }

        let folderPath = folder.path
        let capturedFolder = folder
        let outcome = await Self.runDeletionReconcileWalk(
            localUIDs: snapshot.uids,
            chunkSize: SyncConfig.deletionReconcileChunkSize,
            storedUidValidity: snapshot.storedValidity,
            maxDeletions: maxDeletions,
            interChunkDelaySeconds: SyncConfig.deletionReconcileInterChunkDelaySeconds,
            search: { chunk in
                // Backfill etiquette (ADR-IOS-014 successor): route through the
                // account work queue at headerFetch priority; the pool
                // connection is checked out per chunk, so user actions
                // interleave between chunks.
                try await workQueue.execute(priority: .headerFetch) {
                    try await provider.searchExistingUIDs(folder: folderPath, uids: chunk)
                }
            },
            deleteGhosts: { ghosts in
                try await self.deleteServerConfirmedDeletions(
                    folder: capturedFolder, uids: ghosts, reason: "reconcile walk"
                )
            },
            persistUidValidity: { validity in
                try await self.persistFolderUidValidity(folderId: folderId, uidValidity: validity)
            }
        )

        if DebugModeManager.isLoggingEnabled() {
            print("[Reconcile] \(folder.name): walk DONE — deleted=\(outcome.deletedCount) searchedChunks=\(outcome.searchedChunks) failedChunks=\(outcome.failedChunks) aborted=\(outcome.aborted)\(outcome.abortReason.map { " (\($0))" } ?? "")")
        }
        if outcome.deletedCount > 0 || outcome.aborted {
            BackgroundSyncLogger.log("reconcileWalk: \(folder.name) deleted=\(outcome.deletedCount) failed=\(outcome.failedChunks) aborted=\(outcome.aborted)")
        }
    }

    /// Persist the bootstrap UIDVALIDITY observation (walk guard, ADR-IOS-051).
    private func persistFolderUidValidity(folderId: String, uidValidity: UInt32) async throws {
        try await dbPool.write { db in
            _ = try Folder.filter(Column("id") == folderId)
                .updateAll(db, Column("lastKnownUidValidity").set(to: Int(uidValidity)))
        }
    }
}
