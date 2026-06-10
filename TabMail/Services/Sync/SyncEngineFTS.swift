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
        do {
            let inserted = try await SearchIndex.shared.indexHeaders(records)
            if inserted > 0 {
                print("[FTS] Indexed \(inserted) new messages")
            }
            // Mark headers as fully indexed — body queue requires headerComplete=1.
            let headerIds = records.map(\.headerId)
            try await dbPool.write { db in
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
    /// `SearchIndex.rekeyHeaders`; this sweep heals the leftovers. The bound
    /// samples most-recent-first so each launch covers the rows users actually
    /// search, converging over a few launches for large mailboxes.
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

            let toReindex: [MessageHeader] = try await dbPool.read { db in
                let placeholders = missingIds.map { _ in "?" }.joined(separator: ",")
                return try MessageHeader.fetchAll(
                    db,
                    sql: "SELECT * FROM messageHeader WHERE id IN (" + placeholders + ")",
                    arguments: StatementArguments(missingIds)
                )
            }
            await indexHeadersForFTS(toReindex)

            try await dbPool.write { db in
                for chunk in missingIds.chunked(into: 500) {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    try db.execute(
                        sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
            }
        } catch {
            print("[FTS] Self-heal failed: \(error)")
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
                let rows = try await dbPool.read { db in
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM messageHeader WHERE headerComplete = 0 LIMIT 500")
                }
                let probeMs = Int((CFAbsoluteTimeGetCurrent() - probeT0) * 1000)
                print("[recoverIncompleteHeaders:EXPLAIN] probe \(probeMs)ms — plan:")
                for row in rows {
                    let id = (row["id"] as? Int64) ?? -1
                    let parent = (row["parent"] as? Int64) ?? -1
                    let detail = (row["detail"] as? String) ?? "?"
                    print("[recoverIncompleteHeaders:EXPLAIN]   id=\(id) parent=\(parent) \(detail)")
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
                            try? await self?.dbPool.write { db in
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
