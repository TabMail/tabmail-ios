/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    /// Clear bulk index task from dictionary (called from Task defer).
    func clearBulkIndexTask(accountId: String) {
        bulkIndexTasks[accountId] = nil
    }

    // MARK: - FTS Indexing Helpers

    /// Convert inserted MessageHeaders into FTS index records.
    /// Awaitable — completes before body fetch can start, preventing the race condition
    /// where updateBody() runs before the FTS header row exists.
    func indexHeadersForFTS(_ headers: [MessageHeader]) async {
        let records = headers.map { header in
            FTSHeaderRecord(
                headerId: header.id,
                messageId: header.messageId,
                subject: header.subject,
                from: "\(header.from) <\(header.fromAddress)>",
                to: header.to,
                cc: header.cc,
                bcc: header.bcc,
                dateMs: Int64(header.date.timeIntervalSince1970 * 1000),
                folderId: header.folderId
            )
        }
        await indexHeadersForFTS(records)
    }

    /// Index pre-built FTS records. Awaitable — ensures headers are in FTS before
    /// any body update, eliminating the Task.detached race condition.
    /// Sets headerComplete=1 in GRDB after FTS indexing succeeds.
    func indexHeadersForFTS(_ records: [FTSHeaderRecord]) async {
        guard !records.isEmpty else { return }
        // Yield to a privileged merge before the FTS index write. This is the
        // common chokepoint for header indexing (backfill walk, self-heal,
        // recover) — SearchIndex's writes are a separate sync `@noasync` pool, so
        // the async caller yields on its behalf.
        await PriorityGate.shared.yield("fts-index")
        do {
            let inserted = try await SearchIndex.shared.indexHeaders(records)
            if inserted > 0 {
                print("[FTS] Indexed \(inserted) new messages")
            }
            // Mark headers as fully indexed — body queue requires headerComplete=1.
            let headerIds = records.map(\.headerId)
            try await AppDatabase.backgroundPool.write { db in
                for headerId in headerIds {
                    try db.execute(
                        sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                        arguments: [headerId]
                    )
                }
            }
        } catch {
            print("[FTS] Indexing failed: \(error)")
        }
    }

    /// Recover headers where GRDB says `bodyComplete=1` but the FTS index has
    /// no row for them. Produced by historical buggy write paths (pre-fix NSE
    /// merge, v31 snapshot migration, attachment-only branch) that set
    /// `bodyComplete=1` without ensuring FTS membership. These rows get stuck
    /// forever: AI queue picks them up (`bodyComplete=1`), FTS probe fails,
    /// message is dropped, repeat on every cycle.
    ///
    /// Fix: re-index the header via `indexHeadersForFTS`, reset `bodyComplete=0`
    /// so the body queue re-fetches and writes the FTS body row. Runs once per
    /// startup. Cheap in the steady state (0 orphans).
    ///
    /// NOT inbox-scoped: pre-rekeyHeaders UID remaps produced this exact state
    /// on MOVED (non-inbox) messages — the header was re-keyed while its FTS
    /// entry stayed under the dead old id. New occurrences are prevented by
    /// `SearchIndex.rekeyHeaders`; this recurring pass covers the most-recent
    /// 2000 rows (the ones users actually search). Rows older than that rank
    /// are NEVER sampled here — the one-time `healAllFTSBodyMembership` sweep
    /// (part of `oneTimeFTSReconciliation`) walks the full history instead.
    ///
    /// The SQL is a shared constant so `FTSSelfHealTests` locks the exact
    /// candidate contract (a reintroduced `isInInbox` filter must fail a test).
    static let ftsBodyMembershipCandidateSQL = """
        SELECT id FROM messageHeader
        WHERE bodyComplete = 1 AND headerComplete = 1
        ORDER BY date DESC
        LIMIT 2000
        """

    func selfHealFTSBodyMembership() async {
        do {
            // Fetch only IDs first. The steady state has 0 missing from FTS, so
            // materializing 2000 full MessageHeader rows (~30 columns each) just
            // to extract `.id` is wasted allocation on every launch. Full rows
            // are loaded lazily below only for the missing subset.
            let candidateIds: [String] = try await dbPool.read { db in
                try String.fetchAll(db, sql: Self.ftsBodyMembershipCandidateSQL)
            }
            guard !candidateIds.isEmpty else { return }

            let missingIds = try await SearchIndex.shared.headerIdsMissingFromFTS(candidateIds)
            guard !missingIds.isEmpty else { return }

            print("[FTS] Self-heal: \(missingIds.count) headers with bodyComplete=1 missing from FTS — re-indexing")
            BackgroundSyncLogger.log("[FTS] Self-heal: re-indexing \(missingIds.count) orphaned headers")

            try await reindexAndRequeueBodies(missingIds: missingIds)
        } catch {
            print("[FTS] Self-heal failed: \(error)")
        }
    }

    /// Shared heal tail: re-index the headers under their ids and reset
    /// `bodyComplete = 0` so the body pipeline re-fetches and re-indexes the
    /// body text. Used by the recurring recent-window heal and the one-time
    /// full-history sweep.
    private func reindexAndRequeueBodies(missingIds: [String]) async throws {
        let toReindex: [MessageHeader] = try await dbPool.read { db in
            let placeholders = missingIds.map { _ in "?" }.joined(separator: ",")
            return try MessageHeader.fetchAll(
                db,
                sql: "SELECT * FROM messageHeader WHERE id IN (" + placeholders + ")",
                arguments: StatementArguments(missingIds)
            )
        }
        await indexHeadersForFTS(toReindex)

        try await AppDatabase.backgroundPool.write { db in
            for chunk in missingIds.chunked(into: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    /// Sister of `selfHealFTSBodyMembership` for the backfill queue's scope:
    /// headers where `headerComplete=1` (so backfill will pick them up) but
    /// the FTS index has no row. Without this, `updateBodies` silently defers,
    /// `bodyComplete` stays 0, and the same rows re-dispatch every cycle —
    /// bandwidth burned, no progress. Caused by v38 migration default
    /// (`headerComplete` defaulted to true for all pre-existing rows, regardless
    /// of FTS state) and historical indexing races.
    ///
    /// Fix: re-index the header. Body queue's next dispatch will succeed.
    /// No `bodyComplete` reset needed (already 0). Runs once per startup.
    func selfHealBackfillFTSMembership() async {
        do {
            // Same pattern as `selfHealFTSBodyMembership`: fetch only IDs first,
            // load full rows lazily for the missing subset. Steady state has 0
            // missing so avoiding 5000-row full-model allocation on every launch
            // is the win here.
            let candidateIds: [String] = try await dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT id FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                    LIMIT 5000
                    """)
            }
            guard !candidateIds.isEmpty else { return }

            let missingIds = try await SearchIndex.shared.headerIdsMissingFromFTS(candidateIds)
            guard !missingIds.isEmpty else { return }

            print("[FTS] Backfill self-heal: \(missingIds.count)/\(candidateIds.count) headers missing from FTS — re-indexing")
            BackgroundSyncLogger.log("[FTS] Backfill self-heal: re-indexing \(missingIds.count) orphans")

            let toReindex: [MessageHeader] = try await dbPool.read { db in
                let placeholders = missingIds.map { _ in "?" }.joined(separator: ",")
                return try MessageHeader.fetchAll(
                    db,
                    sql: "SELECT * FROM messageHeader WHERE id IN (" + placeholders + ")",
                    arguments: StatementArguments(missingIds)
                )
            }
            await indexHeadersForFTS(toReindex)
        } catch {
            print("[FTS] Backfill self-heal failed: \(error)")
        }
    }

    /// UserDefaults gate for the one-time FTS reconciliation. Versioned so a
    /// future re-sweep only needs a key bump. (v1 covered the orphan prune
    /// alone under `ftsOrphanPrune.v1.done`; the reconcile key supersedes it
    /// and adds the full-history GRDB→FTS membership sweep — devices that ran
    /// v1 re-run once, which is idempotent.)
    /// v2: `pruneFTSOrphans` now RE-KEYS recoverable orphans (moved Gmail/Graph
    /// messages) to their current id instead of deleting them — preserving the
    /// indexed body and repairing drift for every consumer (search/AI/embeddings).
    /// Bumped so devices re-run the sweep once with the heal-not-delete behavior.
    static let ftsReconcileDoneKey = "ftsReconcile.v2.done"

    /// One-time full FTS↔GRDB reconciliation, both directions:
    /// 1. `pruneFTSOrphans` — remove FTS entries whose header id no longer
    ///    exists in GRDB (FTS→GRDB). Orphans were produced by the
    ///    pre-`rekeyHeaders` era: UID remaps re-keyed headers without touching
    ///    FTS, and deletions could race their FTS removal. They surface as
    ///    stale search hits that render without subject/sender and cannot open.
    /// 2. `healAllFTSBodyMembership` — full-history walk of `bodyComplete=1`
    ///    headers missing from FTS (GRDB→FTS). The recurring
    ///    `selfHealFTSBodyMembership` only samples the most-recent 2000 rows
    ///    per launch; stuck rows older than that rank would never be reached.
    ///
    /// Neither state can form anymore (rekeyHeaders moves entries in place;
    /// `bodyComplete` is only set after a confirmed FTS write), so one clean
    /// completion suffices — the gate is set only then; an interrupted or
    /// failed sweep resumes on the next launch.
    ///
    /// Non-blocking: runs in the detached startup heal task (utility, +5s),
    /// cursor-paged (both pools are WAL — readers never block writers), FTS
    /// writes only for confirmed work, chunked.
    func oneTimeFTSReconciliation(defaults: UserDefaults = .standard, scopePrefix: String? = nil) async {
        guard !defaults.bool(forKey: Self.ftsReconcileDoneKey) else { return }
        // Overlap guard — see `ftsReconcileInFlight`. Check-and-set is
        // synchronous, so actor reentrancy can't interleave two claims.
        guard !ftsReconcileInFlight else { return }
        ftsReconcileInFlight = true
        defer { ftsReconcileInFlight = false }
        do {
            let pruned = try await pruneFTSOrphans(scopePrefix: scopePrefix)
            let healed = try await healAllFTSBodyMembership(scopePrefix: scopePrefix)
            defaults.set(true, forKey: Self.ftsReconcileDoneKey)
            if pruned > 0 || healed > 0 {
                print("[FTS] Reconciliation complete: pruned \(pruned) dead entries, healed \(healed) missing entries")
                BackgroundSyncLogger.log("[FTS] Reconciliation complete: pruned \(pruned), healed \(healed)")
            }
        } catch {
            // Gate NOT set — the sweep restarts from the beginning next launch.
            print("[FTS] Reconciliation failed: \(error) — resuming next launch")
        }
    }

    /// Full-history GRDB→FTS membership sweep: rowid-cursor walk over ALL
    /// `bodyComplete = 1 AND headerComplete = 1` headers (no date window),
    /// re-indexing + re-queueing any missing from FTS. Returns healed count.
    /// `scopePrefix` restricts to a header-id prefix — test isolation only.
    @discardableResult
    func healAllFTSBodyMembership(scopePrefix: String? = nil) async throws -> Int {
        var cursor: Int64 = 0
        var healed = 0
        while true {
            // Hoist — capturing the mutable cursor in the Sendable read
            // closure is a Swift 6 error.
            let pageCursor = cursor
            let page: [(rowid: Int64, id: String)] = try await dbPool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT rowid, id FROM messageHeader
                        WHERE rowid > ? AND bodyComplete = 1 AND headerComplete = 1
                        ORDER BY rowid LIMIT ?
                        """,
                    arguments: [pageCursor, SyncConfig.ftsOrphanPruneChunk]
                ).map { (rowid: $0["rowid"] as Int64, id: $0["id"] as String) }
            }
            guard let last = page.last else { break }
            cursor = last.rowid

            var ids = page.map(\.id)
            if let scopePrefix {
                ids = ids.filter { $0.hasPrefix(scopePrefix) }
            }
            guard !ids.isEmpty else { continue }

            let missingIds = try await SearchIndex.shared.headerIdsMissingFromFTS(ids)
            guard !missingIds.isEmpty else { continue }

            try await reindexAndRequeueBodies(missingIds: missingIds)
            healed += missingIds.count
            print("[FTS] Full-history heal: re-indexed \(missingIds.count) (cursor \(cursor))")
        }
        return healed
    }

    /// The sweep body — separated from the gate so tests can drive it directly.
    /// Returns the number of pruned entries. `scopePrefix` restricts the sweep
    /// to header ids with that prefix — test isolation only (parallel test
    /// suites share SearchIndex.shared and an unscoped sweep would remove
    /// their fixtures); production passes nil.
    @discardableResult
    func pruneFTSOrphans(scopePrefix: String? = nil) async throws -> Int {
        var cursor: Int64 = 0
        var pruned = 0
        while true {
            let page = try await SearchIndex.shared.headerIdPage(
                afterRowid: cursor, limit: SyncConfig.ftsOrphanPruneChunk)
            guard let last = page.last else { break }
            cursor = last.rowid

            var ids = page.map(\.headerId)
            if let scopePrefix {
                ids = ids.filter { $0.hasPrefix(scopePrefix) }
            }
            guard !ids.isEmpty else { continue }
            let existing = try await fetchExistingHeaderIds(ids)
            var candidates = ids.filter { !existing.contains($0) }
            guard !candidates.isEmpty else { continue }

            // Re-verify after a beat. FTS entries are written only AFTER their
            // GRDB row commits, so a row still missing on the second look is a
            // true orphan, not an insert in flight.
            try await Task.sleep(for: .milliseconds(SyncConfig.ftsOrphanPruneRecheckMs))
            let stillExisting = try await fetchExistingHeaderIds(candidates)
            candidates = candidates.filter { !stillExisting.contains($0) }
            guard !candidates.isEmpty else { continue }

            // Drift recovery: an orphan whose (accountId, messageId) still exists
            // in GRDB under a NEW id is a MOVED message (Gmail archive/trash etc.),
            // not a dead one. Re-key the FTS entry to the current id — preserving
            // its indexed body — instead of deleting it. This repairs drift for
            // EVERY consumer (search, AI, embeddings), not just on-search.
            var rekeys: [(oldId: String, newId: String, newMessageId: String?)] = []
            var deadIds: [String] = []
            for orphan in candidates {
                if let newId = try await recoverMovedHeaderId(forOrphan: orphan) {
                    rekeys.append((oldId: orphan, newId: newId, newMessageId: nil))
                } else {
                    deadIds.append(orphan)
                }
            }
            if !rekeys.isEmpty {
                try await SearchIndex.shared.rekeyHeaders(rekeys)
                print("[FTS] Orphan reconcile: re-keyed \(rekeys.count) moved messages (cursor \(cursor))")
            }
            if !deadIds.isEmpty {
                try await SearchIndex.shared.removeMessages(headerIds: deadIds)
                print("[FTS] Orphan prune: removed \(deadIds.count) dead entries (cursor \(cursor))")
            }
            pruned += deadIds.count
        }
        return pruned
    }

    /// Resolve an orphan FTS headerId to the message's CURRENT GRDB id, if the
    /// message merely moved folders. Returns nil for genuinely-dead messages or
    /// when recovery isn't safe.
    ///
    /// Only Gmail/Graph are recoverable by `(accountId, messageId)`: their
    /// messageId is globally unique AND survives folder moves. The headerId
    /// `accountId:folder:messageId` splits into exactly 3 components for them
    /// (no ':' in account UUID, folder, or the hex/opaque messageId); a different
    /// component count means a folder path with ':' (IMAP) — skip, since IMAP's
    /// per-folder UID changes on move and repeats across folders.
    private func recoverMovedHeaderId(forOrphan headerId: String) async throws -> String? {
        let parts = headerId.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        let accountId = parts[0]
        let messageId = parts[2]
        return try await dbPool.read { db -> String? in
            guard let provider = try Account.fetchOne(db, key: accountId)?.provider,
                  provider == .gmail || provider == .outlook else { return nil }
            let matches = try MessageHeader
                .filter(Column("accountId") == accountId && Column("messageId") == messageId)
                .fetchAll(db)
            guard !matches.isEmpty else { return nil }
            // Same message can live in several folders; any current id works (the
            // body rides along in the re-key). Prefer a non-trash/spam copy.
            let preferred = matches.first { !$0.folderPath.contains("TRASH") && !$0.folderPath.contains("SPAM") }
            return (preferred ?? matches.first)?.id
        }
    }

    /// Which of `ids` exist as messageHeader PKs — single indexed IN query.
    private func fetchExistingHeaderIds(_ ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try await dbPool.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try Set(String.fetchAll(
                db,
                sql: "SELECT id FROM messageHeader WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            ))
        }
    }

    /// Recover headers that are in GRDB but not yet FTS-indexed (headerComplete=0).
    /// Runs on every sync startup — cheap in the normal case (0 incomplete headers).
    /// Handles crash recovery: app killed between GRDB insert and FTS indexing.
    func recoverIncompleteHeaders() async {
        // One-shot EXPLAIN QUERY PLAN probe. Isolates whether the 3-5s
        // cost for a 0-row result is planner picking the wrong index vs something else.
        // Same pattern used for BackfillEmbeddingQueue diagnosis.
        if !recoverIncompleteExplainLogged {
            recoverIncompleteExplainLogged = true
            let probeT0 = CFAbsoluteTimeGetCurrent()
            do {
                let rows: [(id: Int64, parent: Int64, detail: String)] = try await dbPool.read { db in
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM messageHeader WHERE headerComplete = 0 LIMIT 500").map { row in
                        ((row["id"] as? Int64) ?? -1, (row["parent"] as? Int64) ?? -1, (row["detail"] as? String) ?? "?")
                    }
                }
                let probeMs = Int((CFAbsoluteTimeGetCurrent() - probeT0) * 1000)
                print("[recoverIncompleteHeaders:EXPLAIN] probe \(probeMs)ms — plan:")
                for row in rows {
                    print("[recoverIncompleteHeaders:EXPLAIN]   id=\(row.id) parent=\(row.parent) \(row.detail)")
                }
            } catch {
                print("[recoverIncompleteHeaders:EXPLAIN] failed: \(error)")
            }
        }

        do {
            let incomplete: [MessageHeader] = try await dbPool.read { db in
                try MessageHeader
                    .filter(Column("headerComplete") == false)
                    .limit(500)
                    .fetchAll(db)
            }
            guard !incomplete.isEmpty else { return }
            print("[FTS] Recovering \(incomplete.count) incomplete headers")
            BackgroundSyncLogger.log("[FTS] Recovering \(incomplete.count) incomplete headers")
            await indexHeadersForFTS(incomplete)
            // indexHeadersForFTS already sets headerComplete=1
        } catch {
            print("[FTS] Recovery failed: \(error)")
        }
    }

    /// Remove deleted message IDs from FTS index.
    func removeHeadersFromFTS(_ headerIds: [String]) {
        guard !headerIds.isEmpty else { return }
        Task.detached(priority: .utility) {
            do {
                try await SearchIndex.shared.removeMessages(headerIds: headerIds)
                print("[FTS] Removed \(headerIds.count) messages from index")
            } catch {
                print("[FTS] Removal failed: \(error)")
            }
        }
    }

    // MARK: - FTS Bulk Indexing

    /// Index existing messages into FTS if the index is sparse.
    /// Runs once per account, typically on first launch after FTS is added.
    /// Uses paginated queries to avoid materializing all messages at once.
    func bulkIndexIfNeeded(account: Account) {
        // Don't overlap per-account
        guard bulkIndexTasks[account.id] == nil else { return }

        let accountId = account.id
        // QoS: `.medium` — see SyncEngineBackfill.swift for rationale.
        bulkIndexTasks[accountId] = Task(priority: .medium) { [weak self] in
            do {
                let folderIds: [String] = try await self?.dbPool.read { db in
                    try String.fetchAll(db,
                        Folder.select(Column("id")).filter(Column("accountId") == account.id)
                    )
                } ?? []

                var totalCount = 0
                for fi in folderIds {
                    totalCount += (try? await self?.dbPool.read { db in
                        try MessageHeader.filter(Column("folderId") == fi).fetchCount(db)
                    }) ?? 0
                }

                // Compare per-account header count vs per-account FTS count.
                let indexCount = try await SearchIndex.shared.documentCountForAccount(accountId: account.id)

                // Phase 1: Index headers that aren't in FTS yet
                if totalCount > indexCount + 10 {
                    print("[FTS Bulk] Indexing \(totalCount) existing messages (FTS has \(indexCount))")

                    let batchSize = SyncConfig.ftsIndexBatchSize
                    var batchNum = 0
                    for fi in folderIds {
                        var offset = 0
                        while true {
                            guard !Task.isCancelled else { return }
                            let currentOffset = offset
                            let batch: [MessageHeader] = (try? await self?.dbPool.read { db in
                                try MessageHeader
                                    .filter(Column("folderId") == fi)
                                    .order(Column("date").desc)
                                    .limit(batchSize, offset: currentOffset)
                                    .fetchAll(db)
                            }) ?? []
                            guard !batch.isEmpty else { break }

                            let records = batch.map { header in
                                FTSHeaderRecord(
                                    headerId: header.id,
                                    messageId: header.messageId,
                                    subject: header.subject,
                                    from: "\(header.from) <\(header.fromAddress)>",
                                    to: header.to,
                                    cc: header.cc,
                                    bcc: header.bcc,
                                    dateMs: Int64(header.date.timeIntervalSince1970 * 1000),
                                    folderId: header.folderId
                                )
                            }
                            let inserted = try await SearchIndex.shared.indexHeaders(records)
                            if inserted > 0 {
                                print("[FTS Bulk] Batch \(batchNum + 1): indexed \(inserted)")
                            }
                            // Mark headers as fully indexed
                            let headerIds = records.map(\.headerId)
                            try? await AppDatabase.backgroundPool.write { db in
                                for hid in headerIds {
                                    try db.execute(
                                        sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                                        arguments: [hid]
                                    )
                                }
                            }
                            offset += batch.count
                            batchNum += 1
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }

                // Phase 2 (body backfill from MessageBody cache) REMOVED.
                // Body→FTS indexing is now handled by ActiveBodyQueue (inbox)
                // and BackfillBodyQueue (non-inbox). No separate opportunistic path needed.

            } catch {
                print("[FTS Bulk] Failed: \(error)")
            }
            await self?.clearBulkIndexTask(accountId: accountId)
        }
    }

    /// Backfill folderId for existing FTS entries that were indexed before the folderId column existed.
    /// Reads GRDB in chunks, updates SearchIndex. Idempotent — no-ops once all entries have folderId.
    func backfillFolderIdsIfNeeded() {
        // QoS: `.medium` — see SyncEngineBackfill.swift for rationale.
        Task(priority: .medium) { [weak self] in
            guard let self else { return }
            let batchSize = SyncConfig.backfillChunkSize
            var totalUpdated = 0

            while true {
                let emptyIds: [String]
                do {
                    emptyIds = try await SearchIndex.shared.headerIdsWithEmptyFolderId(limit: batchSize)
                } catch {
                    print("[FTS Backfill] Failed to query empty folderIds: \(error)")
                    break
                }
                guard !emptyIds.isEmpty else { break }

                // Look up each headerId in GRDB to get the current folderId
                let folderMap: [String: String] = (try? await self.dbPool.read { db in
                    var map: [String: String] = [:]
                    for headerId in emptyIds {
                        if let header = try MessageHeader.fetchOne(db, key: headerId) {
                            map[headerId] = header.folderId
                        }
                    }
                    return map
                }) ?? [:]

                // Group by folderId for batch updates
                var byFolder: [String: [String]] = [:]
                var orphanedIds: [String] = []
                for headerId in emptyIds {
                    if let folderId = folderMap[headerId] {
                        byFolder[folderId, default: []].append(headerId)
                    } else {
                        orphanedIds.append(headerId)
                    }
                }

                // Update each folder group
                for (folderId, headerIds) in byFolder {
                    do {
                        try await SearchIndex.shared.updateFolderIds(headerIds: headerIds, newFolderId: folderId)
                        totalUpdated += headerIds.count
                    } catch {
                        print("[FTS Backfill] Failed to update folderId for \(headerIds.count) entries: \(error)")
                    }
                }

                // Remove orphaned entries (headerId not in GRDB) per ADR-003 (no fallbacks)
                if !orphanedIds.isEmpty {
                    print("[FTS Backfill] Removing \(orphanedIds.count) orphaned FTS entries")
                    try? await SearchIndex.shared.removeMessages(headerIds: orphanedIds)
                }

                try? await Task.sleep(for: .milliseconds(100))
            }

            if totalUpdated > 0 {
                print("[FTS Backfill] Backfilled folderId for \(totalUpdated) entries")
            }
        }
    }
}
