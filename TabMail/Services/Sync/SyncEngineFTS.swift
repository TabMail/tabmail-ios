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
                // ⚠ STAGE E1: mint through `ContentKey.forHeader` once the provider
                // space is plumbed here. Byte-identical today.
                contentKey: ContentKey(rawValue: header.id),
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
            // ⚠ `[String]` is load-bearing: this binds `messageHeader.id`, so
            // `records.map(\.contentKey)` must not compile here (F2).
            let headerIds: [String] = records.map(\.headerId)
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

            // ⚠ STAGE E1: `candidateIds` are `messageHeader.id`s and are being asked
            // "are you in FTS?" — a CONTENT-key question. Same string today; when the
            // content key moves this probe answers "missing" for every UID-addressed
            // row and the heal re-indexes the whole account on every launch.
            let missingKeys = try await SearchIndex.shared.contentKeysMissingFromFTS(
                candidateIds.map(ContentKey.init(rawValue:)))
            guard !missingKeys.isEmpty else { return }
            let missingIds: [String] = missingKeys.map(\.rawValue)

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
    ///
    /// ⚠️ This scope DELIBERATELY omits `bodyMetadataOversized`, unlike the four body
    /// -queue admission queries. It re-indexes HEADERS, and an oversized row's header is
    /// perfectly healthy — dropping it here would make a quarantined message
    /// unsearchable by subject and sender, which is a strictly larger loss than the
    /// missing body. The two predicates diverged when that flag shipped; do not
    /// re-merge them. Pinned by `OversizedDurableFlagConfinementTests
    /// .ftsSelfHealStillSeesFlaggedRows`.
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

            // ⚠ STAGE E1 — same header-id-asked-as-a-content-key probe as
            // `selfHealFTSBodyMembership`; see the note there.
            let missingKeys = try await SearchIndex.shared.contentKeysMissingFromFTS(
                candidateIds.map(ContentKey.init(rawValue:)))
            guard !missingKeys.isEmpty else { return }
            let missingIds: [String] = missingKeys.map(\.rawValue)

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

    /// UserDefaults gate for the one-time bodyComplete restore. Repairs the
    /// damage from the pre-2026-07-02 `BodyAssetMaintenance` conflation, where
    /// asset-cache eviction flipped `bodyComplete = 0` on thousands of rows
    /// whose body text was still fully indexed in FTS — re-enqueueing them all
    /// into the backfill body queue for pointless refetches (the "indexing goes
    /// backwards" loop). Versioned so a future re-run only needs a key bump.
    static let bodyCompleteRestoreDoneKey = "bodyCompleteRestore.v1.done"

    /// One-time reverse heal: rows flagged `bodyComplete = 0` whose FTS entry
    /// HAS real body text get flipped back to `bodyComplete = 1` — zero network,
    /// restores a truthful `pendingBodyCount` instantly.
    ///
    /// Predicate (each condition load-bearing):
    /// - `headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0` —
    ///   the body queues' pending population.
    /// - FTS body text present (`contentKeysWithFTSBody`, length > 1 — excludes
    ///   the " " sentinel and header-only FTS entries). NSE unresolved-CID mail
    ///   never writes an FTS body, so it is naturally excluded.
    /// - NO `messageBody` row. A row that still has cached HTML while flagged
    ///   incomplete is some "cache present but flagged for re-render" state
    ///   (e.g. a suspension-aborted `flushBatch` flag write) — skipping it costs
    ///   one refetch and risks nothing; healing it could freeze a stale render.
    ///   Asset-eviction victims always had their `messageBody` row deleted, so
    ///   they all qualify.
    ///
    /// The gate is set only after a clean full pass; an interrupted run resumes
    /// next launch (idempotent). `scopePrefix` restricts to a header-id prefix —
    /// test isolation only.
    func oneTimeBodyCompleteRestore(defaults: UserDefaults = .standard, scopePrefix: String? = nil) async {
        guard !defaults.bool(forKey: Self.bodyCompleteRestoreDoneKey) else { return }
        do {
            // Id-only load of the whole candidate population (same trade-off as
            // BackfillBodyQueue.repopulateFromDatabase: tens of thousands of
            // short strings, one-time).
            let candidates: [String] = try await dbPool.read { db in
                if let prefix = scopePrefix {
                    return try String.fetchAll(db, sql: """
                        SELECT id FROM messageHeader
                        WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                          AND id LIKE ?
                        """, arguments: ["\(prefix)%"])
                }
                return try String.fetchAll(db, sql: """
                    SELECT id FROM messageHeader
                    WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0
                    """)
            }
            var healed = 0
            for chunk in candidates.chunked(into: SyncConfig.sqlChunkSize) {
                // Abandon on suspension (ADR-IOS-046) — gate stays unset, the
                // pass restarts next launch.
                guard !DatabaseSuspension.isSuspended else {
                    print("[FTS] bodyComplete restore paused by suspension — resuming next launch")
                    return
                }
                // ⚠ STAGE E1 — `chunk` holds `messageHeader.id`s; the FTS probe and the
                // `messageBody` probe below both key by CONTENT, and the heal's UPDATE
                // keys by HEADER. All three are the same string only until E1.
                let withBody = try await SearchIndex.shared.contentKeysWithFTSBody(
                    chunk.map(ContentKey.init(rawValue:)))
                guard !withBody.isEmpty else { continue }
                let withBodyArr: [String] = withBody.map(\.rawValue)
                let cachedIds: Set<String> = try await dbPool.read { db in
                    let placeholders = withBodyArr.map { _ in "?" }.joined(separator: ",")
                    return try Set(String.fetchAll(
                        db,
                        sql: "SELECT id FROM messageBody WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(withBodyArr)
                    ))
                }
                let toHeal = withBodyArr.filter { !cachedIds.contains($0) }
                guard !toHeal.isEmpty else { continue }
                try await AppDatabase.backgroundPool.write { db in
                    let placeholders = toHeal.map { _ in "?" }.joined(separator: ",")
                    try db.execute(
                        sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(toHeal)
                    )
                }
                healed += toHeal.count
            }
            defaults.set(true, forKey: Self.bodyCompleteRestoreDoneKey)
            if healed > 0 {
                print("[FTS] bodyComplete restore: healed \(healed)/\(candidates.count) rows (FTS body present, no cached HTML)")
                BackgroundSyncLogger.log("[FTS] bodyComplete restore: healed \(healed)/\(candidates.count) rows")
                BackgroundSyncLogger.logBackfill("[FTS] bodyComplete restore: healed \(healed)/\(candidates.count) pending rows without refetch")
            }
        } catch {
            // Gate NOT set — the pass restarts from the beginning next launch.
            print("[FTS] bodyComplete restore failed: \(error) — resuming next launch")
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

            // ⚠ STAGE E1 — see `selfHealFTSBodyMembership`.
            let missingKeys = try await SearchIndex.shared.contentKeysMissingFromFTS(
                ids.map(ContentKey.init(rawValue:)))
            guard !missingKeys.isEmpty else { continue }
            let missingIds: [String] = missingKeys.map(\.rawValue)

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
            let page = try await SearchIndex.shared.contentKeyPage(
                afterRowid: cursor, limit: SyncConfig.ftsOrphanPruneChunk)
            guard let last = page.last else { break }
            cursor = last.rowid

            // ⚠ `page` holds CONTENT keys and `fetchExistingHeaderIds` asks
            // `SELECT id FROM messageHeader WHERE id IN (…)`. That probe answers a
            // HEADER-space question, so at Stage E1 it will stop matching for every
            // UID-addressed row. It is kept — but only as a PROTECTION term: a key it
            // matches is live, and a key it does not match is handed to the ownership
            // gate and then to drift recovery before anything is deleted. It can no
            // longer authorize a delete on its own, which is what made it a
            // mass-deletion hazard.
            var entries = page
            if let scopePrefix {
                entries = entries.filter { $0.contentKey.rawValue.hasPrefix(scopePrefix) }
            }
            guard !entries.isEmpty else { continue }
            let ids: [String] = entries.map(\.contentKey.rawValue)
            let existing = try await fetchExistingHeaderIds(ids)
            var candidates = ids.filter { !existing.contains($0) }
            guard !candidates.isEmpty else { continue }

            // Re-verify after a beat. FTS entries are written only AFTER their
            // GRDB row commits, so a row still missing on the second look is a
            // true orphan, not an insert in flight.
            //
            // ⚠ This sleep is a TIMING HEURISTIC and is deliberately NOT the thing
            // standing between a key-space divergence and a mass delete — the
            // ownership + quarantine gate below is, because it tests facts.
            try await Task.sleep(for: .milliseconds(SyncConfig.ftsOrphanPruneRecheckMs))
            let stillExisting = try await fetchExistingHeaderIds(candidates)
            candidates = candidates.filter { !stillExisting.contains($0) }
            guard !candidates.isEmpty else { continue }

            // Ownership + quarantine gate. Protects a key that some header still
            // MINTS (the question that survives E1), a key whose folder is mid
            // `UIDVALIDITY` reset, and a key whose ownership read threw.
            let candidateKeys = candidates.map(ContentKey.init(rawValue:))
            let protected = try await dbPool.read { db in
                try MessageContentStore.protectedKeys(among: candidateKeys, db: db)
            }
            let survivors = candidateKeys.filter { !protected.contains($0) }
            guard !survivors.isEmpty else { continue }

            // Drift recovery: an orphan whose (accountId, messageId) still exists
            // in GRDB under a NEW id is a MOVED message (Gmail archive/trash etc.),
            // not a dead one. Re-key the FTS entry to the current id — preserving
            // its indexed body — instead of deleting it. This repairs drift for
            // EVERY consumer (search, AI, embeddings), not just on-search.
            let entryByKey = Dictionary(entries.map { ($0.contentKey, $0) },
                                        uniquingKeysWith: { first, _ in first })
            let roster = try await dbPool.read { db in try MessageContentStore.roster(db) }
            var rekeys: [(oldKey: ContentKey, newKey: ContentKey, newMessageId: String?)] = []
            var newFolderIds: [ContentKey: String] = [:]
            var deadIds: [ContentKey] = []
            for orphan in survivors {
                if let newKey = try await recoverMovedContentKey(
                    orphan: orphan, entry: entryByKey[orphan], roster: roster
                ) {
                    rekeys.append((oldKey: orphan, newKey: newKey, newMessageId: nil))
                    // `rekeyHeaders` moves `message_ids.headerId`, `message_meta.headerId`
                    // and the shard's `msgId` — but NOT `message_meta.folderId`. A moved
                    // message re-keyed without this would keep its OLD folderId and every
                    // folder-scoped search would place it in the folder it left.
                    if let scope = MessageContentStore.resolveScope(for: newKey, in: roster) {
                        newFolderIds[newKey] = scope.folderId
                    }
                } else {
                    deadIds.append(orphan)
                }
            }
            if !rekeys.isEmpty {
                try await SearchIndex.shared.rekeyHeaders(rekeys)
                for (newKey, folderId) in newFolderIds {
                    try? await SearchIndex.shared.updateFolderIds(
                        contentKeys: [newKey], newFolderId: folderId)
                }
                print("[FTS] Orphan reconcile: re-keyed \(rekeys.count) moved messages (cursor \(cursor))")
            }
            if !deadIds.isEmpty {
                try await SearchIndex.shared.removeMessages(contentKeys: deadIds)
                print("[FTS] Orphan prune: removed \(deadIds.count) dead entries (cursor \(cursor))")
            }
            pruned += deadIds.count
        }
        return pruned
    }

    /// Resolve an orphan FTS content key to the key its message is stored under
    /// NOW, if the message merely moved folders. `nil` for genuinely-dead messages
    /// or when recovery isn't safe.
    ///
    /// 🚨 **The composite is NEVER split on `':'`.** The previous implementation did
    /// `headerId.components(separatedBy: ":")` + `guard parts.count == 3`, which is
    /// wrong because `folderPath` may legitimately contain a `':'` — RFC 3501 permits
    /// any hierarchy delimiter, and a Gmail/Outlook label name can contain one too.
    /// A four-component key failed the guard, recovery silently declined, and the FTS
    /// row was **deleted instead of re-keyed**, losing its indexed body and its
    /// `messages_vec` embedding — precisely for the users with unusual folder names.
    /// Raising the part count or using `maxSplits:` would not fix it (the tail is the
    /// LAST component, so a split parse would have to count from the end and would
    /// still be a parse). Instead the `accountId` and the folder id are carried
    /// ALONGSIDE the key, out of `message_meta`, exactly as Stage B's both-ids split
    /// established; the folder roster is the second source for rows indexed before
    /// `message_meta.folderId` existed.
    ///
    /// The Gmail/Graph gate is KEPT. IMAP UIDs change on move and repeat across
    /// folders, so an `(accountId, messageId)` lookup there would bind the indexed
    /// body of one message to a completely different one — recovery must decline.
    /// Under a content key an IMAP row's key moves for a different reason (a
    /// `UIDVALIDITY` renumber), and that case is handled where the fact lives: the
    /// quarantine term of `MessageContentStore.protectedKeys`, which keeps the row
    /// rather than guessing at its new identity.
    private func recoverMovedContentKey(
        orphan: ContentKey,
        entry: SearchIndex.ContentKeyPageEntry?,
        roster: [MessageContentStore.ContentKeyScope]
    ) async throws -> ContentKey? {
        let scope = MessageContentStore.resolveScope(for: orphan, in: roster)
        // The provider message id, from the folder id the row was INDEXED under,
        // falling back to the live folder roster for pre-folderId rows.
        guard let providerMessageId =
                MessageContentStore.tail(of: orphan, folderId: entry?.folderId ?? "")
                ?? scope?.tail(of: orphan)
        else { return nil }
        let accountId = (entry?.accountId).flatMap { $0.isEmpty ? nil : $0 } ?? scope?.accountId
        guard let accountId else { return nil }
        return try await dbPool.read { db in
            try MessageContentStore.recoverMovedContentKey(
                orphan: orphan, accountId: accountId,
                providerMessageId: providerMessageId, db: db)
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
    ///
    /// The single FTS-removal channel for "a header went away" — deletion reconcile,
    /// full sync's `staleIds`, and all four delta-sync removal paths funnel here, so
    /// routing this one function through `MessageContentStore` routes all six.
    ///
    /// 🚨 ORDERING CONTRACT: every caller has ALREADY committed its header delete
    /// before calling. That is load-bearing — count the owners while the header still
    /// exists and the count is always ≥ 1, so nothing is ever released and the gate
    /// becomes a permanent silent no-op that every outcome-only test still passes.
    ///
    /// ⚠ STAGE E1: callers hand `messageHeader.id`s here (deletion is a header-space
    /// event); the FTS delete keys by content. Convert at the mint when they diverge.
    ///
    /// `.body` joins `.searchIndex` from Stage D: `v70_dropMessageBodyHeaderFK`
    /// removed the FK cascade that used to reclaim `messageBody` as a side effect of
    /// each caller's header delete. Routing it here covers all six callers at once.
    /// ⚠️ `.medium`, NOT `.utility` — ADR-IOS-031's floor for anything that touches
    /// GRDB off the main actor. At `07a4bb703` this body called
    /// `SearchIndex.shared.removeMessages`, which touches only `SearchIndex`'s own
    /// private FTS pool, so `.utility` (QoS 17) cost the main pool nothing. It now
    /// calls `MessageContentStore.releaseUnowned(…, pool:)`, which reads and runs
    /// `DELETE FROM messageBody` on the MAIN pool — `dbPool`, `syncPool` and
    /// `backgroundPool` all wrap the same `rawPool`, and `PrioritizedDatabase.priority`
    /// is the DB write-queue TIER, not a `TaskPriority`, so it does nothing to QoS.
    /// At `.utility` this became a QoS-17 reader/writer contending with MainActor
    /// reads at `.userInitiated` (25): the 8-level inversion ADR-IOS-031 forbids, on
    /// an ordinary primary path (six callers — every delta sync, full sync, and
    /// deletion-reconcile pass). Predicate for the count, comments excluded so this
    /// sentence cannot satisfy it (R16-7):
    ///   `rg -n --pcre2 '^(?!\s*(///|//)).*removeHeadersFromFTS\('
    ///    TabMail/ Shared/ TabMailNotificationService/` → **7** lines = this
    ///   definition plus **6** call sites (`SyncEngineDeltaSync` ×4,
    ///   `SyncEngineDeletionReconcile`, `SyncEngineFullSync`).
    /// Scheduling priority is the only thing that changes;
    /// the work performed, its ordering, and its failure handling are untouched.
    func removeHeadersFromFTS(_ headerIds: [String]) {
        guard !headerIds.isEmpty else { return }
        let pool = dbPool
        Task.detached(priority: .medium) {
            let released = await MessageContentStore.releaseUnowned(
                headerIds.map(ContentKey.init(rawValue:)), stores: [.searchIndex, .body], pool: pool)
            print("[FTS] Removed \(released)/\(headerIds.count) messages from index")
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
                                    // ⚠ STAGE E1: mint through `ContentKey.forHeader`.
                                    contentKey: ContentKey(rawValue: header.id),
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
                            // Mark headers as fully indexed. `[String]` is load-bearing:
                            // this binds `messageHeader.id` (F2).
                            let headerIds: [String] = records.map(\.headerId)
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
    ///
    /// Returns the sweep task. Production callers discard it; it exists so the
    /// loop's TERMINATION is observable — that is the property this sweep lost.
    @discardableResult
    func backfillFolderIdsIfNeeded() -> Task<Void, Never> {
        // QoS: `.medium` — see SyncEngineBackfill.swift for rationale.
        return Task(priority: .medium) { [weak self] in
            guard let self else { return }
            let batchSize = SyncConfig.backfillChunkSize
            var totalUpdated = 0
            /// The loop variant. See the termination guard below.
            var lastRemaining = Int.max

            while true {
                guard !Task.isCancelled else { return }
                // 🚨 THE THIRD SWEEP. These are CONTENT keys, and every use below
                // treats them as `messageHeader.id`s — the `fetchOne(db, key:)` lookup
                // and the "not in GRDB ⇒ orphan ⇒ delete from FTS" conclusion. It has
                // the identical mass-delete shape to `pruneFTSOrphans`, and a
                // type-shaped census MISSED it because `.map(\.rawValue)` converts
                // straight back to `String` (GRDB's `fetchOne(_:key:)` is generic over
                // `DatabaseValueConvertible`, so a bare `String` primary key compiles
                // with no diagnostic at all). It is gated below by the same ownership +
                // quarantine term as the other two.
                let emptyIds: [String]
                do {
                    emptyIds = try await SearchIndex.shared.contentKeysWithEmptyFolderId(
                        limit: batchSize).map(\.rawValue)
                } catch {
                    print("[FTS Backfill] Failed to query empty folderIds: \(error)")
                    break
                }
                guard !emptyIds.isEmpty else { break }

                // 🚨 TERMINATION. `contentKeysWithEmptyFolderId` is an UNCURSORED
                // `SELECT … WHERE folderId = '' LIMIT ?` — no ORDER BY, no OFFSET — so
                // this loop only advances by SHRINKING that set: a row leaves it by
                // being given a non-empty folderId, or by being removed. The
                // protection gate added a THIRD outcome — a protected orphan is
                // neither updated nor removed — and once the survivors are all
                // protected the query has nothing new to hand back, forever. That is a
                // durable steady state, not a blip: `uidValidityResetPendingAt` is a
                // PERSISTED column that survives relaunch, and the fail-safe below
                // protects the WHOLE page on a single failed read.
                //
                // So the loop variant is the SIZE OF THE SET, measured — not the size
                // of the work we believe we did. Counting what we handed to
                // `updateFolderIds` / `removeMessages` would be unsound: both skip a
                // key whose rowid does not resolve, an `updateFolderIds` failure is
                // caught and logged, and a header whose own folderId is empty updates
                // to no effect — every one of those looks productive and changes
                // nothing. Comparing the returned PAGE would be unsound for a
                // different reason: the query has no ORDER BY, so a protected set
                // LARGER than `batchSize` is not guaranteed to hand back the same
                // subset twice. `COUNT(*)` is answerable regardless of ordering and is
                // served by `idx_meta_folderId`, so it costs an index range scan over
                // exactly the rows still awaiting backfill. `lastRemaining` strictly
                // decreases and is bounded below by 0 ⇒ the loop terminates.
                //
                // Stopping is correct, not a give-up. A protected row is legitimately
                // undecidable *right now*; the next account sync re-drives the sweep,
                // and by then the quarantine may have cleared. Deleting it instead
                // would invert the gate — that is the data-loss bug, not the fix.
                let remaining: Int
                do {
                    remaining = try await SearchIndex.shared.emptyFolderIdCount()
                } catch {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[FTS Backfill] Failed to measure remaining entries: \(error)")
                    }
                    break
                }
                guard remaining < lastRemaining else {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[FTS Backfill] No progress on \(remaining) entries — stopping until the next sync")
                    }
                    break
                }
                lastRemaining = remaining

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
                        try await SearchIndex.shared.updateFolderIds(
                            contentKeys: headerIds.map(ContentKey.init(rawValue:)), newFolderId: folderId)
                        totalUpdated += headerIds.count
                    } catch {
                        print("[FTS Backfill] Failed to update folderId for \(headerIds.count) entries: \(error)")
                    }
                }

                // Remove orphaned entries (headerId not in GRDB) per ADR-003 (no
                // fallbacks) — but only those that clear the SAME ownership +
                // quarantine gate as the other two sweeps. Without it, this loop
                // deletes the whole search index of every UID-addressed account the
                // moment the content key moves off the provider id.
                if !orphanedIds.isEmpty {
                    let orphanKeys = orphanedIds.map(ContentKey.init(rawValue:))
                    let protected = (try? await self.dbPool.read { db in
                        try MessageContentStore.protectedKeys(among: orphanKeys, db: db)
                        // FAIL-SAFE: a failed read protects the whole batch.
                    }) ?? Set(orphanKeys)
                    let removable = orphanKeys.filter { !protected.contains($0) }
                    if !removable.isEmpty {
                        print("[FTS Backfill] Removing \(removable.count)/\(orphanedIds.count) orphaned FTS entries")
                        try? await SearchIndex.shared.removeMessages(contentKeys: removable)
                    }
                }

                try? await Task.sleep(for: .milliseconds(100))
            }

            if totalUpdated > 0 {
                print("[FTS Backfill] Backfilled folderId for \(totalUpdated) entries")
            }
        }
    }
}
