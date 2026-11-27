/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

extension SyncEngine {

    // MARK: - Background Maintenance (nonisolated)

    /// Each account's sync-ordering dimension (`EmailProvider.staleWindowMode`),
    /// which the prune deletes oldest-first in: `.uid` (IMAP) lowest UID first,
    /// `.date` (Gmail, Exchange) oldest date first. Resolved here, at the provider
    /// boundary, and passed to the prune (ADR-IOS-006, ADR-IOS-042).
    func pruneOrderByAccount() -> [String: StaleWindowMode] {
        providers.mapValues { $0.staleWindowMode }
    }

    /// The prune's oldest-first order for one folder, in its account's sync
    /// order: an IMAP folder keeps its highest UIDs, and the prune records the
    /// highest UID it deleted (`CatchUpPruneCutoff`), below which the catch-up
    /// loads nothing under a limit (ADR-IOS-006 current note, #1062).
    /// *Superseded (#1062):* "its lowest held UID is a clean floor below which
    /// nothing is kept, and the catch-up loads nothing below it": a scroll page
    /// caches rows below it, so it is no record of the prune. The same `CAST(messageId AS
    /// INTEGER)` form `SyncEngine.selectStaleHeaders`' UID window uses. A
    /// non-numeric `messageId` in an IMAP folder would read as 0 and so sort
    /// first, pruned before every UID; no IMAP path writes one.
    nonisolated static func pruneOrderSQL(_ mode: StaleWindowMode) -> String {
        "\(pruneKeySQL(mode)) ASC"
    }

    /// The prune order's key, as its index stores it: `messageHeader_folderId_uidInt`
    /// for `.uid`, `messageHeader_folderId_date` for `.date`. Rows that share a key
    /// come out of either index in `rowid` order.
    nonisolated static func pruneKeySQL(_ mode: StaleWindowMode) -> String {
        switch mode {
        case .uid: return "CAST(messageId AS INTEGER)"
        case .date: return "date"
        }
    }

    /// The last row a body-pass page returned: its prune key as stored (compared
    /// in the column's own representation, never re-encoded) and its `rowid`.
    struct PruneCursor: Sendable {
        let key: DatabaseValue
        let rowId: Int64
    }

    /// The rows after the cursor in (prune key, `rowid`) order. On `date` it is the
    /// row value `(date, rowid) > (?, ?)`, which the index seeks in full, so rows
    /// that share a date are never read twice. SQLite does not match a row value
    /// against an indexed expression: `(CAST(messageId AS INTEGER), rowid) > (?, ?)`
    /// seeks only `folderId` and walks the folder from its start. So on `.uid` it is
    /// a range on the key, which the index seeks, plus a test of the `rowid` among
    /// the rows that share the cursor's key: one row in an IMAP folder, whose UIDs
    /// are unique.
    private nonisolated static func pruneCursorPredicate(_ mode: StaleWindowMode, afterCursor: Bool) -> String {
        guard afterCursor else { return "" }
        switch mode {
        case .uid:
            let key = pruneKeySQL(mode)
            return " AND \(key) >= ? AND (\(key) > ? OR rowid > ?)"
        case .date:
            return " AND (date, rowid) > (?, ?)"
        }
    }

    /// One body-pass page: the next `limit` rows of a folder after the cursor, in
    /// the prune order with ties in `rowid` order, as a seek on the order's index
    /// (#1402). Arguments: `pruneArguments`.
    nonisolated static func prunePageSQL(_ mode: StaleWindowMode, afterCursor: Bool) -> String {
        let key = pruneKeySQL(mode)
        return """
            SELECT rowid AS pruneRowId, id, \(key) AS pruneKey FROM messageHeader
            WHERE folderId = ?\(pruneCursorPredicate(mode, afterCursor: afterCursor))
            ORDER BY \(key), rowid LIMIT ?
            """
    }

    /// How many of a folder's rows lie after the cursor (all of them without one),
    /// counted up to `limit` only: it reads at most `limit` index entries, whatever
    /// the folder's size (#1402). Arguments: `pruneArguments`.
    nonisolated static func pruneRemainderSQL(_ mode: StaleWindowMode, afterCursor: Bool) -> String {
        let key = pruneKeySQL(mode)
        return """
            SELECT count(*) FROM (SELECT 1 FROM messageHeader
            WHERE folderId = ?\(pruneCursorPredicate(mode, afterCursor: afterCursor))
            ORDER BY \(key), rowid LIMIT ?)
            """
    }

    /// `[folderId, limit]` without a cursor; after one, `[folderId, key, key, rowid,
    /// limit]` on `.uid` and `[folderId, key, rowid, limit]` on `.date`.
    nonisolated static func pruneArguments(
        _ mode: StaleWindowMode, folderId: String, cursor: PruneCursor?, limit: Int
    ) -> StatementArguments {
        guard let cursor else { return [folderId, limit] }
        switch mode {
        case .uid: return [folderId, cursor.key, cursor.key, cursor.rowId, limit]
        case .date: return [folderId, cursor.key, cursor.rowId, limit]
        }
    }

    /// Whether more than `floor` of the folder's rows lie after the cursor (all of
    /// them without one). It reads at most `floor + 1` index entries. Until #1402
    /// the prune counted the whole folder for this: once per folder in the body
    /// pass, and before every chunk of the header pass.
    nonisolated static func pruneRowsBeyondFloor(
        _ db: Database, folderId: String, mode: StaleWindowMode, after cursor: PruneCursor?, floor: Int
    ) throws -> Bool {
        let counted = try Int.fetchOne(
            db, sql: pruneRemainderSQL(mode, afterCursor: cursor != nil),
            arguments: pruneArguments(mode, folderId: folderId, cursor: cursor, limit: floor + 1)) ?? 0
        return counted > floor
    }

    /// One folder's body pass: deletes the cached bodies of its rows oldest first
    /// in the prune order, a page of `chunkSize` rows at a time, while more than
    /// `floor` rows lie after the last page (`pruneRowsBeyondFloor`) and, asked
    /// after that, `aboveTarget()` holds. Returns how many bodies it deleted.
    /// After each page's write, outside it, it calls `afterEachBatch` (the run's
    /// checkpoint, `runPruneIfOverBudget`'s).
    /// `aboveTarget` is the pass's storage check (`runPruneIfOverBudget`); a test
    /// passes its own to stop after a given number of pages. Until #1437 it was
    /// `StorageEstimator.isOverBudget`, the size of the files in Application
    /// Support, which a delete never shrinks.
    ///
    /// A page is the next `chunkSize` rows after a cursor (`prunePageSQL`), a seek
    /// on the order's index, so it costs the same wherever it lies in the folder,
    /// and a pass reads each row once (#1402). Until #1402 the page was
    /// `LIMIT chunkSize OFFSET n` after a full count of the folder: each page
    /// stepped over every row before it, so a folder of n rows read about
    /// n² / (2 · chunkSize) index entries. In a folder no other writer changes during
    /// the pass, the pages, their order and the stops are the same: the rows after
    /// the cursor are the folder's count less the offset, so "more than `floor` of
    /// them" is exactly the former `offset < count - floor`, and rows that share a
    /// key come in `rowid` order, as the index returned them. When sync writes the
    /// folder meanwhile, the check counts the rows after the cursor as they are then,
    /// where the former walk kept its start-of-pass count and offset: a row deleted
    /// before the cursor no longer makes the walk skip rows or run into the floor, a
    /// row deleted after it stops the pass earlier, a row inserted before it is no
    /// longer re-read, and a row inserted after it can let the pass prune up to that
    /// many more older bodies, rounded to pages, each outside the floor when checked.
    /// A row deleted between a check and its page can still put that page inside the
    /// floor, as the last page may be; the former walk had the whole pass for that.
    /// As before, the last page is a whole page even when fewer rows are left above
    /// the floor, so it can delete the bodies of rows inside the floor.
    ///
    /// A read that fails ends the folder's pass, as a failed count or page did.
    nonisolated static func pruneFolderBodies(
        dbPool: PrioritizedDatabase, folderId: String, mode: StaleWindowMode,
        floor: Int, chunkSize: Int, aboveTarget: () async -> Bool,
        afterEachBatch: () async -> Void
    ) async -> Int {
        var removed = 0
        var cursor: PruneCursor?
        while (try? passThroughRead(dbPool, { db in
            try pruneRowsBeyondFloor(db, folderId: folderId, mode: mode, after: cursor, floor: floor)
        })) ?? false, await aboveTarget() {
            let page: [(id: String, cursor: PruneCursor)] = (try? passThroughRead(dbPool) { db in
                try Row.fetchAll(
                    db, sql: prunePageSQL(mode, afterCursor: cursor != nil),
                    arguments: pruneArguments(mode, folderId: folderId, cursor: cursor, limit: chunkSize)
                ).map { row -> (id: String, cursor: PruneCursor) in
                    let key: DatabaseValue = row["pruneKey"]
                    let rowId: Int64 = row["pruneRowId"]
                    return (id: row["id"], cursor: PruneCursor(key: key, rowId: rowId))
                }
            }) ?? []
            guard let last = page.last else { break }
            let headerIds = page.map(\.id)
            let deleted = (try? passThroughWrite(dbPool) { db in
                try MessageBody.filter(headerIds.contains(Column("id"))).deleteAll(db)
            }) ?? 0
            removed += deleted
            cursor = last.cursor
            await afterEachBatch()
        }
        return removed
    }

    /// Nonisolated prune — runs entirely off the main thread. `pruneOrder` is each
    /// account's sync order (`pruneOrderByAccount`); bodies and headers are both
    /// pruned in it. An account with no resolved order (no registered provider)
    /// is pruned oldest date first, as before #1062.
    /// *Superseded (#1062):* every folder was pruned oldest DATE first, which on
    /// IMAP left pruned holes throughout the UID range (UID and date are
    /// decorrelated, ADR-IOS-042) that every catch-up listing downloaded again.
    ///
    /// It runs only under an Email Index Limit, and only once the space the limit
    /// counts (`StorageEstimator.SpaceMeter`: the space Settings reports, with the
    /// email and search databases counted by the data they hold) reaches the gate's
    /// start percentage of the limit; it then deletes until that space is at or below
    /// `SyncConfig.storagePruneTargetPercent` of it, or every folder is at its floor.
    /// The limit is read once, as its first step: a limit changed while it runs
    /// applies to the next prune. The storage folder is walked once, at the start,
    /// outside any write; each later check re-reads only the databases' page totals.
    /// Each header batch waits for its search entries and bodies to be released
    /// before the next check, so that check sees what the batch freed. After each
    /// batch's write (a page of bodies or a batch of headers), outside it, the run
    /// calls `afterEachBatch`: the throttled `PASSIVE` checkpoint, so the WAL does not
    /// grow through the whole run (autocheckpoint is off). `space` replaces the app's
    /// measure (`SpaceSource.app`) and `afterEachBatch` the checkpoint in tests.
    ///
    /// *Superseded (#1437):* it ran while `StorageEstimator.isOverBudget`, the
    /// allocated size of the files in Application Support, reached the limit, walked
    /// again before every folder, every page and every deleted row (that check ran
    /// inside the batch's write). A delete never shrinks a SQLite file (the pages it
    /// frees go to the freelist, and auto_vacuum was off), so that size never fell and
    /// every run trimmed every folder to its floor. The release after each batch was
    /// not awaited.
    nonisolated static func runPruneIfOverBudget(
        dbPool: PrioritizedDatabase, pruneOrder: [String: StaleWindowMode],
        gate: StorageEstimator.PruneGate, space: StorageEstimator.SpaceSource? = nil,
        afterEachBatch: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() }
    ) async {
        let budgetMB = StorageEstimator.budgetMB
        guard let startBytes = StorageEstimator.limitBytes(percent: gate.startPercent, ofBudgetMB: budgetMB),
              let targetBytes = StorageEstimator.limitBytes(
                percent: SyncConfig.storagePruneTargetPercent, ofBudgetMB: budgetMB) else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let meter = await StorageEstimator.SpaceMeter.start(space ?? .app(pool: dbPool)) else { return }
        let measureMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let startUsed = meter.startBytes
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[Prune] Used \(Self.megabytes(startUsed))MB of \(budgetMB)MB (reported \(Self.megabytes(meter.reportedBytes))MB, database files \(Self.megabytes(meter.databaseFileBytes))MB, measured in \(measureMs)ms), gate \(gate)")
        }
        guard Double(startUsed) >= startBytes else { return }
        // Whether the prune goes on: the run is still wanted (`runWALMaintenance`'s
        // `shouldRun`) and the space used is still above the target. A measure that
        // fails stops it, as a failed read stops a folder.
        let aboveTarget: () async -> Bool = {
            guard !Task.isCancelled, !DatabaseSuspension.isSuspended,
                  let used = await meter.usedBytes() else { return false }
            return Double(used) > targetBytes
        }

        let floor = StorageEstimator.floorPerFolder

        let accounts = (try? passThroughRead(dbPool) { db in try Account.fetchAll(db) }) ?? []
        let pruneChunkSize = SyncConfig.pruneChunkSize

        // Fetch all folders once — reused for both body and header pruning
        var foldersByAccount: [String: [Folder]] = [:]
        for account in accounts {
            foldersByAccount[account.id] = (try? passThroughRead(dbPool) { db in
                try Folder.filter(Column("accountId") == account.id).fetchAll(db)
            }) ?? []
        }

        var bodiesRemoved = 0
        for account in accounts {
            // An account with no registered provider (it failed to register,
            // e.g. missing credentials) is still pruned, oldest date first as
            // before #1062: no catch-up of it runs to reload what is pruned.
            let mode = pruneOrder[account.id] ?? .date
            let folders = foldersByAccount[account.id] ?? []
            for folder in folders {
                guard await aboveTarget() else { break }
                bodiesRemoved += await pruneFolderBodies(
                    dbPool: dbPool, folderId: folder.id, mode: mode,
                    floor: floor, chunkSize: pruneChunkSize, aboveTarget: aboveTarget,
                    afterEachBatch: afterEachBatch)
            }
        }
        if bodiesRemoved > 0 {
            BackgroundSyncLogger.logDebug("[Prune] Removed \(bodiesRemoved) message bodies")
        }

        var headersRemoved = 0
        for account in accounts {
            // An account with no registered provider (it failed to register,
            // e.g. missing credentials) is still pruned, oldest date first as
            // before #1062: no catch-up of it runs to reload what is pruned.
            let mode = pruneOrder[account.id] ?? .date
            let orderSQL = pruneOrderSQL(mode)
            let folders = foldersByAccount[account.id] ?? []
            for folder in folders {
                guard await aboveTarget() else { break }
                while await aboveTarget() {
                    // At most `floor + 1` index entries, not a count of the whole
                    // folder before every chunk (#1402). A failed read stops the
                    // folder, as the count's `?? 0` did.
                    let beyondFloor = (try? passThroughRead(dbPool) { db in
                        try pruneRowsBeyondFloor(db, folderId: folder.id, mode: mode, after: nil, floor: floor)
                    }) ?? false
                    guard beyondFloor else { break }
                    let batch: [MessageHeader] = (try? passThroughRead(dbPool) { db in
                        try MessageHeader
                            .filter(Column("folderId") == folder.id)
                            .order(sql: orderSQL)
                            .limit(pruneChunkSize)
                            .fetchAll(db)
                    }) ?? []
                    guard !batch.isEmpty else { break }

                    // The batch's ids, once its transaction commits. A failed write
                    // rolls the whole batch back and stops the folder: the same batch
                    // would be selected again, and a write that keeps failing would
                    // repeat it for as long as the space used stays above the target. Until
                    // #1437 a failed write kept the ids collected before it failed and
                    // released them, and the write checked
                    // `StorageEstimator.isOverBudget` (a walk of the files) before
                    // every row; nothing is measured inside the write now.
                    let chunkIds: [String]
                    do {
                        chunkIds = try passThroughWrite(dbPool) { db -> [String] in
                            // A folder pruned lowest UID first records where the
                            // prune reached, with the folder's epoch, in this same
                            // transaction (`CatchUpPruneCutoff`, #1062): under a
                            // storage limit the catch-up loads nothing at or below
                            // it, even after another path caches a lower row. Only
                            // rows THIS transaction deleted count, re-read here
                            // (the batch was selected before it): still in this
                            // folder under the same UID, and stamped with the
                            // folder's epoch both when selected and now, so a row
                            // a reset or a turnover removed meanwhile, a row an
                            // optimistic move brought in under its source UID
                            // (stamp cleared), or a row of another numbering never
                            // moves it. An unknown epoch records nothing, so no
                            // cutoff outlives an epoch change (ADR-IOS-061).
                            var cutoffEpoch: Int?
                            if pruneOrder[account.id] == .uid {
                                cutoffEpoch = Self.knownUidValidity(try Int.fetchOne(
                                    db, sql: "SELECT lastKnownUidValidity FROM folder WHERE id = ?",
                                    arguments: [folder.id]))
                            }
                            var highestPrunedUid: Int?
                            var ids: [String] = []
                            for msg in batch {
                                ids.append(msg.id)
                                var current: MessageHeader?
                                if cutoffEpoch != nil { current = try MessageHeader.fetchOne(db, key: msg.id) }
                                let deleted = try msg.delete(db)
                                if deleted, let cutoffEpoch, let current,
                                   current.folderId == folder.id, current.messageId == msg.messageId,
                                   current.observedUidValidity == cutoffEpoch, msg.observedUidValidity == cutoffEpoch,
                                   let uid = Int(current.messageId) {
                                    highestPrunedUid = max(highestPrunedUid ?? uid, uid)
                                }
                            }
                            if let cutoffEpoch, let highestPrunedUid {
                                try Self.recordCatchUpPruneCutoff(
                                    folderId: folder.id, highest: highestPrunedUid, epoch: cutoffEpoch, db: db)
                            }
                            return ids
                        }
                    } catch {
                        BackgroundSyncLogger.logDebug("[Prune] Delete failed: \(error)")
                        break
                    }
                    headersRemoved += chunkIds.count
                    if !chunkIds.isEmpty {
                        // Routed through `MessageContentStore`. The headers were
                        // deleted in the write transaction just above, so this
                        // release counts owners in the post-delete world. Awaited
                        // (#1437): the next storage check has to see the search
                        // entries and bodies this batch freed, or the prune would
                        // delete more headers for space already on its way back.
                        //
                        // `.body` joins `.searchIndex` from Stage D and MATTERS MOST
                        // here: this whole function exists to reclaim disk when the
                        // user is over their storage budget, and without it the
                        // bodies — the bulk of the bytes — would stay: since #1433
                        // `runEvictStaleBodies` reads only bodies whose header exists.
                        //
                        // ⚠️ `.medium`, NOT `.utility` — ADR-IOS-031's floor for any
                        // background task that touches GRDB. `releaseUnowned` runs on
                        // the MAIN pool (`dbPool`/`syncPool`/`backgroundPool` all wrap
                        // the same `rawPool`; `PrioritizedDatabase.priority` is the DB
                        // write-queue TIER, not a `TaskPriority`), so at QoS 17 it
                        // contended both with MainActor reads at `.userInitiated` (25)
                        // and with this function's own delete loop. Scheduling priority
                        // is the only change; the work, its ordering and its failure
                        // handling are untouched.
                        let keys = chunkIds.map(ContentKey.init(rawValue:))
                        await Task.detached(priority: .medium) { () -> Void in
                            await MessageContentStore.releaseUnowned(
                                keys, stores: [.searchIndex, .body], pool: dbPool)
                        }.value
                    }
                    // After the batch's write and its release, outside both.
                    await afterEachBatch()
                }
            }
        }
        if headersRemoved > 0 {
            BackgroundSyncLogger.logDebug("[Prune] Removed \(headersRemoved) message headers")
        }
        if DebugModeManager.isLoggingEnabled() {
            let used = await meter.usedBytes().map(Self.megabytes) ?? "unknown"
            BackgroundSyncLogger.logDebug("[Prune] Done — used now \(used)MB")
        }
    }

    /// Bytes as megabytes with one decimal, for the prune's debug lines.
    private nonisolated static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }

    /// The evict step as the maintenance pass runs it: only once its index
    /// (`HTMLCachePair.indexName`) exists. Returns whether it ran.
    ///
    /// Without the index every page would scan the whole header table inside its
    /// write, the #1354 hold made worse, and the bodies cached before v116 would not
    /// be candidates yet (the fill that records them commits with the index). The
    /// index is deferred, built later in the same pass
    /// (`runRefreshPlannerStatisticsIfStale`), so the first pass after an upgrade
    /// skips the step and the next one evicts; stale bodies stay cached one pass
    /// longer, which changes nothing but disk use. A schema that cannot be read counts
    /// as missing (retried next pass).
    @discardableResult
    nonisolated static func runEvictStaleBodiesIfIndexed(
        dbPool: PrioritizedDatabase, undoProtectedBodyIds: Set<String>
    ) async -> Bool {
        guard let missing = missingDeferredIndexes(dbPool), !missing.contains(HTMLCachePair.indexName) else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[BodyCache] evict waits for \(HTMLCachePair.indexName)")
            }
            return false
        }
        await runEvictStaleBodies(dbPool: dbPool, undoProtectedBodyIds: undoProtectedBodyIds)
        return true
    }

    /// `PrioritizedDatabase.write`'s synchronous pass-through overload, for an
    /// async caller. Not `async` on purpose: from an async context Swift binds the
    /// awaited overload, which enters `DatabaseWriteQueue`; the evict's page write
    /// stays the pass-through write `IOS-PERF-002` accepts for it.
    private nonisolated static func passThroughWrite<T>(
        _ dbPool: PrioritizedDatabase, _ updates: (Database) throws -> T
    ) throws -> T {
        try dbPool.write(updates)
    }

    /// `PrioritizedDatabase.read`'s synchronous overload, for an async caller, for
    /// the same reason as `passThroughWrite`: the storage prune's reads stay the
    /// synchronous reads they were before it became async (#1437), with no
    /// `Sendable` result required.
    private nonisolated static func passThroughRead<T>(
        _ dbPool: PrioritizedDatabase, _ value: (Database) throws -> T
    ) throws -> T {
        try dbPool.read(value)
    }

    /// The body-cache evict: deletes the cached HTML of messages outside every inbox
    /// that was cached more than `SyncConfig.bodyCacheTTLHours` ago, except the undo
    /// set's and each folder's newest `SyncConfig.bodyCacheRecentPerFolder`. Runs on
    /// every maintenance pass once its index exists (`runEvictStaleBodiesIfIndexed`),
    /// entirely off the main thread.
    ///
    /// ## What it reads (#1433)
    ///
    /// Its candidates come from the HTML-cache pair (`HTMLCachePair`): a seek on
    /// `messageHeader_htmlCachedAt` for headers with `isInInbox = 0` and
    /// `htmlCachedAt` before the cutoff. A kept inbox body is never visited, and the
    /// rules run on the candidates only. Until #1433 the step walked every cached body
    /// older than the TTL and read each one's header to keep the inbox ones: about
    /// 19,000 kept bodies, 377 writes and 7.5 s per pass at 105k headers.
    ///
    /// A body with no header is not a candidate: the release after a header's removal
    /// deletes its body (`MessageContentStore.releaseUnowned`), and a body left behind
    /// when that release is skipped stays as a harmless leftover (#1446). A folder's
    /// UIDVALIDITY reset deletes every body in its id range, so no such body is ever
    /// shown as a new message's HTML.
    ///
    /// ## Termination
    ///
    /// The page is the next `chunkSize` candidates after a cursor in
    /// `(htmlCachedAt, rowid)` order, and the cursor moves to the page's last row
    /// whatever the rules did with each row. Every candidate visited is strictly
    /// greater than the one before and below `(cutoff, ·)`. A body re-fetched during
    /// the run gets a fresh `htmlCachedAt` above the cutoff and leaves the set; a
    /// message that leaves the inbox with an old one below the cursor waits for the
    /// next run. So the run ends at its first empty page, and no row is read twice.
    ///
    /// ## What one write holds
    ///
    /// Each page runs in one pass-through write: at most `chunkSize` index entries,
    /// those headers' rows, the rules' per-folder newest-N read (once per folder per
    /// run), and the pages freed by the bodies it deletes. What a write holds does not
    /// grow with the number of cached bodies, and a run reads only candidates.
    ///
    /// ## The WAL between pages
    ///
    /// SQLite's autocheckpoint is off (`AppDatabase.makePool`), so nothing else
    /// moves a page's frames out of the WAL while the run goes on. After each
    /// page's write, outside it, the run calls `afterEachPage`: the throttled
    /// checkpoint (`checkpointWALThrottled`), so a long run never grows the WAL by
    /// all of its pages. The checkpoint shares its throttle with every other
    /// caller, the foreground maintenance pass's closing checkpoint included (a
    /// `TRUNCATE` on a prune pass): one that comes within the throttle's interval
    /// after a page's checkpoint is skipped, so the WAL file is shrunk only by a
    /// later `TRUNCATE`. The maintenance pass passes nothing, so production always
    /// runs this default. Tests pass their own, to see where it runs or to keep a
    /// fixture's run off the app's database.
    nonisolated static func runEvictStaleBodies(
        dbPool: PrioritizedDatabase, undoProtectedBodyIds: Set<String>,
        afterEachPage: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() }
    ) async {
        let ttlCutoff = Calendar.current.date(byAdding: .hour, value: -SyncConfig.bodyCacheTTLHours, to: Date()) ?? Date.distantPast
        let recentPerFolder = SyncConfig.bodyCacheRecentPerFolder
        let chunkSize = SyncConfig.pruneChunkSize

        var recentCache: [String: Set<String>] = [:]
        var evicted = 0
        var cursor: HTMLCachePair.EvictCursor?
        while !Task.isCancelled {
            let after = cursor
            do {
                let pageResult = try passThroughWrite(dbPool) { db -> (evicted: Int, last: HTMLCachePair.EvictCursor?) in
                    let page = try HTMLCachePair.evictCandidatesPage(
                        db, cachedBefore: ttlCutoff, after: after, limit: chunkSize)
                    guard let last = page.last else { return (0, nil) }
                    var batchEvicted = 0
                    for candidate in page.candidates {
                        // `undoProtectedBodyIds` holds `messageHeader.id`s
                        // (`UndoService.undoStack … messages.map(\.id)`), the same
                        // space as the candidate's id.
                        if undoProtectedBodyIds.contains(candidate.headerId) {
                            continue
                        }
                        if recentCache[candidate.folderId] == nil {
                            let recentIds = try Set(String.fetchAll(db,
                                MessageHeader
                                    .select(Column("id"))
                                    .filter(Column("folderId") == candidate.folderId)
                                    .order(Column("date").desc)
                                    .limit(recentPerFolder)
                            ))
                            recentCache[candidate.folderId] = recentIds
                        }
                        if recentCache[candidate.folderId]?.contains(candidate.headerId) == true {
                            continue
                        }
                        // ⚠ STAGE E1: the body is keyed by CONTENT; it equals the
                        // header id until content keys diverge.
                        try MessageBody.deleteOne(db, key: candidate.headerId)
                        batchEvicted += 1
                    }
                    return (batchEvicted, last)
                }
                guard let last = pageResult.last else { break }
                evicted += pageResult.evicted
                cursor = last
            } catch {
                BackgroundSyncLogger.logDebug("[BodyCache] Eviction failed: \(error)")
                break
            }
            await afterEachPage()
        }
        if evicted > 0 {
            BackgroundSyncLogger.logDebug("[BodyCache] Evicted \(evicted) stale bodies (TTL=\(SyncConfig.bodyCacheTTLHours)h)")
        }
    }

    /// Expire the AI cache (ADR-IOS-078): an entry no one has written for
    /// `SyncConfig.aiCacheTTLDays` is deleted, unless its message is in an inbox
    /// now, in which case it is kept and its clock restarts. Membership is read
    /// from the message's own headers, never from the entry's key: the key names
    /// the folder the AI ran in, which stays the inbox after the message is
    /// archived. Runs after an AI queue drain and in maintenance, off the main
    /// thread.
    ///
    /// Every read seeks an index (ADR-IOS-029), named with `INDEXED BY` so that
    /// statistics taken while a table was small cannot turn it into a scan: the
    /// expired set through `messageAICache_expiry`, a message's copies through
    /// `messageHeader_rfc822MessageId`. Each batch reads the expired set again
    /// from its start, with no OFFSET: every entry a batch handles is deleted or
    /// gets `updatedAt = now`, which is after the cutoff, so the expired set
    /// shrinks with every batch and the loop ends. A batch reads each entry's key
    /// and Message-ID only, so an entry whose stored results no longer decode is
    /// expired like any other instead of failing the batch on every run.
    ///
    /// SQLite's own checkpoint is off (`AppDatabase.makePool`), so the WAL grows
    /// until something checkpoints it: between two batches, once the earlier one's
    /// write has committed, the run calls `checkpointWAL` (the throttled
    /// `checkpointWALThrottled`, as the other batch writers do). It never checkpoints
    /// after its last batch. The maintenance pass asks for a TRUNCATE checkpoint right
    /// after the run, and the throttle would skip that TRUNCATE inside the window a
    /// checkpoint moments before had opened; so a run of one batch, the common case,
    /// adds no checkpoint at all. To know inside its own transaction whether another
    /// batch follows, a batch reads one expired entry more than it handles.
    nonisolated static func runPurgeExpiredAICache(
        dbPool: PrioritizedDatabase,
        checkpointWAL: @Sendable () async -> Void = { await SyncEngine.checkpointWALThrottled() }
    ) async {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheTTLDays, to: now) ?? Date.distantPast
        let chunkSize = SyncConfig.pruneChunkSize

        let count = expiredAICacheCount(dbPool: dbPool, cutoff: cutoff)
        guard count > 0 else { return }

        var purged = 0
        var rescued = 0
        while true {
            do {
                let batchResult = try expireAICacheBatch(dbPool: dbPool, now: now, cutoff: cutoff, chunkSize: chunkSize)
                purged += batchResult.purged
                rescued += batchResult.rescued
                if !batchResult.more { break }
            } catch {
                BackgroundSyncLogger.logDebug("[AICache] Purge failed: \(error)")
                break
            }
            await checkpointWAL()
        }
        if purged > 0 || rescued > 0 {
            BackgroundSyncLogger.logDebug("[AICache] Purged \(purged) expired entries, rescued \(rescued) still-in-inbox (TTL=\(SyncConfig.aiCacheTTLDays)d)")
        }
    }

    // The purge's database steps are synchronous functions on purpose. Called straight
    // from the async run, `dbPool.read` and `dbPool.write` would bind
    // `PrioritizedDatabase`'s async overloads, which merge the extension's staged rows
    // before a read and queue a write behind the priority tiers. From here they are the
    // pass-through calls the purge has always made.

    /// How many AI cache entries are older than `cutoff`; 0 when the read fails.
    private nonisolated static func expiredAICacheCount(dbPool: PrioritizedDatabase, cutoff: Date) -> Int {
        (try? dbPool.read { db in
            try Int.fetchOne(db, sql: aiCacheExpiredCountSQL, arguments: [cutoff]) ?? 0
        }) ?? 0
    }

    /// One batch of the purge, read and handled in one write transaction: up to
    /// `chunkSize` expired entries, each deleted or, when its message is in an inbox,
    /// kept with `updatedAt = now`. It reads one entry more than it handles: `more`
    /// when that entry exists, so another batch follows.
    private nonisolated static func expireAICacheBatch(
        dbPool: PrioritizedDatabase, now: Date, cutoff: Date, chunkSize: Int
    ) throws -> (purged: Int, rescued: Int, more: Bool) {
        return try dbPool.write { db -> (purged: Int, rescued: Int, more: Bool) in
            let rows = try Row.fetchAll(db, sql: aiCacheExpiredBatchSQL, arguments: [cutoff, chunkSize + 1])

            var batchPurged = 0
            var batchRescued = 0
            for row in rows.prefix(chunkSize) {
                let key: String = row["key"]
                let rfc822MessageId: String? = row["rfc822MessageId"]
                if let msgId = rfc822MessageId.map({ EmailFilter.normalizeMessageId($0) }), !msgId.isEmpty,
                   try Bool.fetchOne(db, sql: aiCacheInInboxSQL, arguments: [msgId]) == true {
                    try db.execute(sql: "UPDATE messageAICache SET updatedAt = ? WHERE key = ?", arguments: [now, key])
                    batchRescued += 1
                    continue
                }
                try db.execute(sql: "DELETE FROM messageAICache WHERE key = ?", arguments: [key])
                batchPurged += 1
            }
            return (batchPurged, batchRescued, rows.count > chunkSize)
        }
    }

    /// How many AI cache entries are older than the cutoff: the purge's gate.
    nonisolated static let aiCacheExpiredCountSQL = """
        SELECT COUNT(*) FROM messageAICache INDEXED BY messageAICache_expiry
        WHERE updatedAt < ?
        """

    /// One batch of expired AI cache entries: their keys and Message-IDs only.
    nonisolated static let aiCacheExpiredBatchSQL = """
        SELECT key, rfc822MessageId FROM messageAICache INDEXED BY messageAICache_expiry
        WHERE updatedAt < ?
        LIMIT ?
        """

    /// Whether any copy of a message, in any account, is in an inbox. It reads
    /// that message's copies only and stops at the first one in an inbox.
    nonisolated static let aiCacheInInboxSQL = """
        SELECT EXISTS (
            SELECT 1 FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
            WHERE rfc822MessageId = ? AND isInInbox = 1
        )
        """

    // MARK: - Retired calendar operation reclaim

    /// Reclaim TERMINALLY-RETIRED calendar operations once they are older than
    /// `SyncConfig.retiredCalendarOpRetentionDays`. Nonisolated, chunked at
    /// `SyncConfig.pruneChunkSize`, runs entirely off the main thread — the same
    /// shape as `runPurgeExpiredAICache` beside it.
    ///
    /// 🚨 **WHY THIS EXISTS (R17-3): R16-1 GAVE THE ROW A TERMINAL STATE AND NO
    /// EXIT.** The six terminal arms used to `PendingCalendarOperation.deleteOne`;
    /// they now retain the row as `PendingStatus.failed` with a `failureReason` so
    /// the outcome outlives the in-memory awaiter. That is right — but nothing
    /// swept the retained rows, so `pendingCalendarOperation` became
    /// monotonically growing, and `drainCalendarQueue` reads it with
    /// `filter(Column("status") == queued).order(createdAt).fetchAll` against a
    /// table whose only DDL is `v8`'s create, `v28` and `v84` — **no index on
    /// `status`**. Every drain therefore pays a full scan plus a temp B-tree sort
    /// over a table that never shrinks.
    ///
    /// 🚨 **NOT AN INDEX AND NOT A MIGRATION, DELIBERATELY.** The owner's standing
    /// directive is that startup migrations carry only what is blocking and
    /// everything else belongs in the heal/sync/background queues. Bounding the
    /// table's CARDINALITY here fixes the scan at its cause; an index would make
    /// the scan cheaper while the table still grew forever, at the price of a
    /// migration on the launch-blocking chain.
    ///
    /// **Aged by `createdAt`, which is the only timestamp the row has** — there is
    /// no `failedAt` and adding one would be the migration this deliberately
    /// avoids. `createdAt <= (the moment it was retired)`, so this reclaims no
    /// LATER than a true failure-age window would, never earlier than the op
    /// existed. That asymmetry is acceptable precisely because a `failed` row is
    /// inert: it is outside `drainCalendarQueue`'s `status == queued` filter and
    /// outside `AppDatabase.init`'s `inFlight` reset, so it can never be
    /// re-executed and can never starve a later op. Reclaiming one drops the
    /// record of a failure and its inbox banner (`LateCalendarFailureStore`), never
    /// a user intention.
    nonisolated static func runReclaimRetiredCalendarOps(dbPool: PrioritizedDatabase) {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -SyncConfig.retiredCalendarOpRetentionDays, to: Date()
        ) ?? Date.distantPast
        let chunkSize = SyncConfig.pruneChunkSize
        let terminal = PendingStatus.failed.rawValue
        // A failed row that still holds saved put-back files (#718, `CalendarPutBackFiles.held`) is
        // never reclaimed: the files are the only copy of what the user had attached, and only the
        // user's warned dismissal or account removal deletes them. A row whose directory holds
        // bytes it does not hold is reclaimed, and the drain-start sweep removes them.
        let candidates = Array(CalendarPutBackFiles.heldOperationIds())
        let held: [String]
        do {
            held = candidates.isEmpty ? [] : try dbPool.read { db in
                try PendingCalendarOperation.filter(keys: candidates).fetchAll(db)
                    .filter { !CalendarPutBackFiles.held($0).isEmpty }.map(\.id)
            }
        } catch {
            // Nothing is reclaimed when the rows that hold files can't be told.
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[CalendarQueue] Retired-op reclaim skipped: the rows holding saved files can't be read: \(error)")
            }
            return
        }
        let spared = held.isEmpty ? "" : "AND id NOT IN (\(held.map { _ in "?" }.joined(separator: ",")))"

        var reclaimed = 0
        while true {
            do {
                let batch = try dbPool.write { db -> Int in
                    let ids = try String.fetchAll(
                        db,
                        sql: """
                            SELECT id FROM pendingCalendarOperation
                            WHERE status = ? AND createdAt < ? \(spared)
                            LIMIT ?
                            """,
                        arguments: [terminal, cutoff] + StatementArguments(held) + [chunkSize])
                    guard !ids.isEmpty else { return 0 }
                    // Each batch deletes exactly the rows it just selected, so the
                    // loop is monotone and needs no offset cursor — unlike the AI
                    // cache purge, which RESCUES some rows and must skip past them.
                    let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM pendingCalendarOperation WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(ids))
                    return ids.count
                }
                if batch == 0 { break }
                reclaimed += batch
            } catch {
                // Debug-gated per global rule 12. This is a diagnostic, not a
                // structured alert production observability consumes: the reclaim
                // is a best-effort background sweep, the rows it failed to remove
                // are inert (`status == failed` is outside `drainCalendarQueue`'s
                // filter), and the next pass retries. Its two siblings in this
                // file — `runRefreshPlannerStatisticsIfStale`'s success and
                // abandoned arms — are gated the same way, including the error arm.
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[CalendarQueue] Retired-op reclaim failed: \(error)")
                }
                break
            }
        }
        if reclaimed > 0, DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[CalendarQueue] Reclaimed \(reclaimed) retired calendar ops older than \(SyncConfig.retiredCalendarOpRetentionDays)d")
        }
    }

    // MARK: - Stale Action Tag Sweep

    /// Clear local `actionTag` on non-inbox messages. Action tags are
    /// inbox-scoped — the chip should not follow a message into Archive /
    /// Trash / custom folders. Server-side keyword/label writes were
    /// removed in ADR-IOS-036 (action tags are local-only now), so this
    /// pass only touches GRDB.
    ///
    /// Gmail duplicate-label safety: if the same rfc822MessageId still
    /// exists in inbox, the tag is legitimate (Gmail shows the same
    /// message in both Inbox and All Mail) and we skip it. Each candidate
    /// (a tagged non-inbox row past the TTL with a Message-ID) is checked on
    /// its own with `inboxCopySQL`, a seek on the Message-ID index; a sweep
    /// with no candidate reads no inbox row at all (#1404). A check that
    /// fails keeps that tag; the next full sync's sweep checks it again.
    ///
    /// `inboxCopyExists` replaces that check (tests); nil reads `inboxCopySQL`.
    func sweepStaleActionTags(
        account: Account,
        provider _: any EmailProvider,
        inboxCopyExists: (@Sendable (_ rfc822MessageId: String, _ accountId: String) async throws -> Bool)? = nil
    ) async {
        let maxPerSweep = SyncConfig.pruneChunkSize
        let pool = dbPool
        let inboxCopyExists = inboxCopyExists ?? { rfc822MessageId, accountId in
            try await pool.read { db in
                try Self.inboxCopyExists(db, rfc822MessageId: rfc822MessageId, accountId: accountId)
            }
        }

        let folders = (try? await dbPool.read { db in
            try Folder.filter(Column("accountId") == account.id && Column("role") != FolderRole.inbox.rawValue).fetchAll(db)
        }) ?? []

        // TTL cutoff (Round D-0b): a tag is eligible for reclaim once
        // `actionTagSetAt` is older than this. Computed once — `Date()` inside
        // the per-message loop would let the sweep's own running time nudge
        // the cutoff message-to-message.
        let cutoff = Date().addingTimeInterval(-SyncConfig.actionTagTTLSeconds)

        var cleared = 0
        for folder in folders {
            guard cleared < maxPerSweep else { break }
            let remaining = maxPerSweep - cleared
            let msgs: [MessageHeader] = (try? await dbPool.read { db in
                try MessageHeader
                    .filter(Column("folderId") == folder.id)
                    .limit(remaining)
                    .fetchAll(db)
            }) ?? []
            for msg in msgs where msg.actionTag != nil {
                guard cleared < maxPerSweep else { break }

                // TTL guard: only reclaim once the tag is older than
                // SyncConfig.actionTagTTLSeconds. A NULL `actionTagSetAt`
                // (legacy pre-migration row, or a writer that failed to stamp
                // it) is deliberately fail-safe — treated as already expired,
                // degrading to the pre-TTL "clear on next touch" behavior
                // instead of leaking the tag forever. This matches TB's
                // `purgeExpiredActionEntries`, where a missing/non-numeric
                // timestamp is likewise treated as expired (ADR-IOS-008).
                if let setAt = msg.actionTagSetAt, setAt > cutoff {
                    continue
                }

                // Gmail safety: if this rfc822MessageId is still in inbox, skip.
                // Checked after the TTL so a young tag costs no read; a failed
                // check keeps the tag (fail closed).
                if let rfc = msg.rfc822MessageId, !rfc.isEmpty {
                    guard let inInbox = try? await inboxCopyExists(rfc, account.id), !inInbox else {
                        continue
                    }
                }

                // Clear local state — action tags are local-only (ADR-IOS-036),
                // no server-side sync needed.
                let tag = msg.actionTag
                let messageId = msg.messageId
                try? await dbPool.write { db in
                    _ = try MessageHeader.filter(Column("id") == msg.id)
                        .updateAll(db,
                            Column("actionTag").set(to: nil as String?),
                            Column("tagSortOrder").set(to: 99),
                            Column("actionTagSetAt").set(to: nil as Date?)
                        )
                }

                cleared += 1
                BackgroundSyncLogger.logDebug("[StaleTagSweep] Cleared \(tag?.rawValue ?? "?") from \(messageId) in \(folder.name)")
            }
        }

        if cleared > 0 {
            BackgroundSyncLogger.logDebug("[StaleTagSweep] Swept \(cleared) stale tags for \(account.emailAddress)")
        }
    }

    /// Whether `accountId` has an inbox row with this Message-ID: the stale-tag
    /// sweep's Gmail duplicate guard, read once per candidate.
    ///
    /// It names its index, as `aiCacheInInboxSQL` does, so it always seeks the
    /// Message-ID (the few copies of one message) whatever the planner statistics
    /// hold. Left to the planner, the read walks `messageHeader_isInInbox_date`
    /// (every inbox row of every account) with no statistics, and scans the whole
    /// table with statistics recorded while `messageHeader` held a row or two (a
    /// fresh install's first maintenance pass); nothing re-analyzes the table
    /// while its schema is unchanged. `messageHeader_rfc822MessageId` is built by
    /// the migrations, never deferred.
    nonisolated static let inboxCopySQL = """
        SELECT 1 FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
        WHERE rfc822MessageId = ? AND accountId = ? AND isInInbox = 1
        LIMIT 1
        """

    nonisolated static func inboxCopyExists(_ db: Database, rfc822MessageId: String, accountId: String) throws -> Bool {
        try Int.fetchOne(db, sql: inboxCopySQL, arguments: [rfc822MessageId, accountId]) != nil
    }

    // MARK: - Chat Session Eviction

    /// Evict old chat sessions and enforce global memory cap.
    ///
    /// **Session vs History distinction:**
    /// - *Resumable sessions* have raw `[Email](N)` references + ChatIdTranslator mappings.
    ///   The agent can interact with email references on resume.
    /// - *History* (memory) has dereferenced content — subjects baked in, no translator needed.
    ///   Searchable by MemorySearchTool but NOT resumable.
    ///
    /// **Phases:**
    /// 1. Message-detail: dereference sessions whose message left inbox (session→history transition)
    /// 2. Compose: delete turns older than TTL (compose sessions are never resumable; each opens fresh)
    /// 3. Compose drafts: DraftStore model eviction (count-based)
    /// 4. Global turn cap: delete oldest turns across all types (enforces Memory setting)
    nonisolated static func runEvictChatSessions(dbPool: PrioritizedDatabase) {
        let msgLimit = SyncConfig.maxMessageChatSessions
        let composeLimit = SyncConfig.maxComposeDraftSessions
        let composeTTL = SyncConfig.composeChatSessionTTLDays
        let maxTurns = UserDefaults.standard.integer(forKey: ChatPillState.maxMemoryTurnsKey)
        let effectiveMaxTurns = maxTurns > 0 ? maxTurns : ChatPillState.defaultMaxMemoryTurns

        // Phase 0: Inbox sessions — delete oldest beyond the Sessions limit.
        let inboxLimit = UserDefaults.standard.integer(forKey: ChatPillState.maxSessionsKey)
        let effectiveInboxLimit = inboxLimit > 0 ? inboxLimit : ChatPillState.defaultMaxSessions
        do {
            let evicted = try ChatStore.shared.evictInboxSessionsSync(dbPool: dbPool, limit: effectiveInboxLimit)
            if evicted > 0 {
                BackgroundSyncLogger.logDebug("[ChatEviction] Evicted \(evicted) inbox sessions (limit=\(effectiveInboxLimit))")
            }
        } catch {
            BackgroundSyncLogger.logDebug("[ChatEviction] Inbox session eviction failed: \(error)")
        }

        // Phase 1: Message-detail sessions — delete sessions whose message left inbox.
        do {
            let evicted = try ChatStore.shared.evictMessageDetailSessionsSync(dbPool: dbPool, limit: msgLimit)
            if evicted > 0 {
                BackgroundSyncLogger.logDebug("[ChatEviction] Dereferenced \(evicted) message-detail sessions (limit=\(msgLimit))")
            }
        } catch {
            BackgroundSyncLogger.logDebug("[ChatEviction] Message-detail eviction failed: \(error)")
        }

        // Phase 2: Compose chat turns — TTL-based deletion. Compose sessions are never
        // resumable (each new compose creates a fresh session). Old turns kept for memory
        // search until TTL expires.
        do {
            let evicted = try ChatStore.shared.evictComposeSessionsSync(dbPool: dbPool, ttlDays: composeTTL)
            if evicted > 0 {
                BackgroundSyncLogger.logDebug("[ChatEviction] Evicted \(evicted) compose sessions (ttl=\(composeTTL) days)")
            }
        } catch {
            BackgroundSyncLogger.logDebug("[ChatEviction] Compose chat session eviction failed: \(error)")
        }

        // Phase 3: Compose drafts (DraftStore model eviction)
        do {
            let evicted = try DraftStore.shared.evictSync(dbPool: dbPool, limit: composeLimit)
            if evicted > 0 {
                BackgroundSyncLogger.logDebug("[ChatEviction] Evicted \(evicted) compose drafts (limit=\(composeLimit))")
            }
        } catch {
            BackgroundSyncLogger.logDebug("[ChatEviction] Compose draft eviction failed: \(error)")
        }

        // Phase 4: Global turn cap — delete oldest turns first (across all session types).
        // This is the hard limit on total GRDB memory. User-configurable "Memory" setting.
        // Cascade evicted IDs to memory.db so `memory_search` doesn't surface content
        // that was evicted by the cap (ADR-IOS-034).
        do {
            let evictedIds = try ChatStore.shared.evictHistoryBeyondCapSync(dbPool: dbPool, maxTurns: effectiveMaxTurns)
            if !evictedIds.isEmpty {
                BackgroundSyncLogger.logDebug("[ChatEviction] Evicted \(evictedIds.count) turns beyond cap (max=\(effectiveMaxTurns))")
                Task { @Sendable [evictedIds] in
                    await MemoryIndex.shared.deleteTurns(chatHistoryIds: evictedIds)
                }
            }
        } catch {
            BackgroundSyncLogger.logDebug("[ChatEviction] Turn cap eviction failed: \(error)")
        }
    }

    // MARK: - Deferred index builds (ADR-IOS-029 rule 5, deferred timing)

    /// One index whose BUILD is deferred off the blocking launch path.
    ///
    /// The DDL and the name live in ONE value on purpose. Two parallel lists — a
    /// `[String]` of statements and a `[String]` of names to probe — is a census
    /// that drifts the first time somebody adds an index to one and not the other
    /// (`MIS-006`), and the drift is silent: the pass would report "already
    /// present" for an index it never built.
    ///
    /// `fill`, when set, is the data the index needs before it may exist, run just
    /// before `sql` and only while the index is missing, in the same write. The index
    /// existing is then the proof the fill ran: no marker records it, and a write that
    /// is rolled back leaves neither.
    struct DeferredIndex: Sendable {
        let name: String
        let sql: String
        var fill: String? = nil
    }

    /// Indexes moved OFF the blocking migration path (ADR-IOS-029, 2026-08-05
    /// amendment; owner directive *"startup migrations should really have only
    /// things that are absolutely necessary and blocking. Other things should happen
    /// durably in the heal/sync/background queues."*).
    ///
    /// `messageHeader_unreadSweep` is `v83`'s index. On the owner's device upgrading
    /// v67 → v83 (5 accounts / 78 folders) `MigrationTimingLedger` attributed
    /// **5,050 ms** to `v83` — a single `CREATE INDEX` over the whole
    /// `messageHeader` table, paid before any UI appears. Its `ANALYZE` had already
    /// been moved here by the same amendment; this moves the build itself.
    ///
    /// ⚠️ WHY THIS ONE IS ELIGIBLE AND MOST ARE NOT — the test is stated as a rule
    /// because the next reader will want to "finish the job". An index may move here
    /// only if its absence degrades PERFORMANCE AND NOTHING ELSE. A column, a data
    /// repair, a UNIQUE index a write depends on, or an index a query names with
    /// `INDEXED BY` (which makes SQLite *error* when it is missing) all stay
    /// blocking. `messageHeader_unreadSweep` qualifies exactly: every one of
    /// `InboxViewModel.markAllAsRead`'s three statements returns the SAME ROWS
    /// without it, just via a temp B-tree sort — the O(U²/50) shape `v83` exists to
    /// remove. No result changes, no write depends on it, and nothing names it in an
    /// `INDEXED BY` clause.
    ///
    /// ⚠️ **THE CHECK IS STATED AS AN INSTRUMENT THIS SENTENCE CANNOT ENTER, and
    /// that is the entire point.** It used to read *"`rg 'INDEXED BY
    /// messageHeader_unreadSweep'` … → zero"*, which was FALSE THE MOMENT IT WAS
    /// WRITTEN: the grep returned exactly one hit — this comment. A check whose
    /// quoted command matches the prose quoting it can never be re-run to a clean
    /// result, and it fails silently, because the reader who re-runs it sees a hit
    /// and cannot tell a real `INDEXED BY` from the sentence claiming there is none
    /// (`MIS-033`). Re-run these two instead; both skip `//` and `///` lines with a
    /// negative lookahead, so no comment — including this one — can satisfy them:
    ///   1. **Absence, the claim itself.** `rg --pcre2 '^(?!\s*(///|//)).*INDEXED
    ///      BY\s+messageHeader_unreadSweep' TabMail/ Shared/
    ///      TabMailNotificationService/` → **no output, exit 1**.
    ///   2. **Non-vacuity, so a broken regex cannot pass as a clean result.**
    ///      The same command without the index name returns exactly **12 hint
    ///      occurrences** — `messageHeader_folderId_messageId`
    ///      (`MessageContentStore.ownersSQL`), `messageHeader_rfc822MessageId`
    ///      (`MessageContentStore.ownersSQL`, `ChatStore.findByStableIdSQL`,
    ///      `AccountManager.queuedMemberIdentitySQL`,
    ///      `DurableIdentityLookup.rfc822FallbackSQL`,
    ///      `AccountManager.inboxEntryAITargetSQL`,
    ///      `SyncEngine.optimisticDedupSQL`,
    ///      `ReplyParentResolver.parentLookupSQL`, `Draft.replyTargetLookupSQL`,
    ///      `InboxView.stableIdRfcLookupSQL`, and
    ///      `AccountManager.optimisticSentDedupSQL`), and
    ///      `messageHeader_triage_display` (`InboxListReader`). Every named index is
    ///      built by a SHIPPED migration (`v64`, `v1`, `v38`), none deferred. Check
    ///      1 is meaningful only when check 2 is non-empty. Re-count occurrences
    ///      rather than carrying this integer forward when another hint lands.
    ///
    /// CONVERGENCE (Data Integrity rule 5). `v83`'s body is now empty, so the two
    /// populations diverge for exactly as long as it takes this pass to run: a
    /// database that ran `v83` BEFORE the body was emptied already has the index; a
    /// fresh install or a device that upgrades after it does not. Both converge here,
    /// because `CREATE INDEX IF NOT EXISTS` is a no-op on the first and a build on
    /// the second, and this pass runs from both the foreground poll and the
    /// BGProcessing drain. Registered as `IOS-PERF-005`.
    ///
    /// QUERY COST (keep this note; QueryCostNoteFenceTests checks it): every query,
    /// index, table or column added here, and every query that reads them, must be as
    /// cheap as the data allows. It must not add a new table or index scan unless no
    /// index or plainer query can avoid it; then state why at the query. Prove a query
    /// or index change on a mail-sized database with the DBProof harness
    /// (TabMailTests/Helpers/DBProofHarness.swift).
    nonisolated static let deferredIndexes: [DeferredIndex] = [
        DeferredIndex(
            name: "messageHeader_unreadSweep",
            sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_unreadSweep
                ON messageHeader(folderId, id)
                WHERE isRead = 0
                """),
        // Extends v40's `messageHeader_bodyRepopulate` by the one equality column the
        // body-queue admission queries gained with `bodyMetadataOversized`, keeping
        // `date` last so one index serves both the seek and the ORDER BY. Deferred
        // rather than built in `v88_addBodyMetadataOversized` because its absence
        // degrades performance and nothing else: without it those queries still seek on
        // four of five equality columns, in date order, with no temp B-tree — the fifth
        // conjunct is simply filtered per row. That is the transient window this
        // mechanism exists to accept.
        DeferredIndex(
            name: "messageHeader_bodyRepopulateV2",
            sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_bodyRepopulateV2
                ON messageHeader(isInInbox, headerComplete, bodyComplete,
                                 bodyEmptyConfirmed, bodyMetadataOversized, date)
                """),
        // #1433: the stale-body evict's index, replacing `messageBody_staleEvict`
        // (messageBody(fetchedAt), #1354), which nothing reads any more (a database
        // that already built it keeps it; it changes no result). Its fill records the
        // bodies cached before v116 in `messageHeader.htmlCachedAt` first (v116 adds
        // the column and its triggers only), so the index is built once from the
        // filled column and commits with it. Deferred like the others, and for one
        // more reason: built in a migration, it would have no statistics row until
        // this write's `ANALYZE` (#1401). The evict waits for it
        // (`runEvictStaleBodiesIfIndexed`). Its fill is a data repair readers rely on,
        // deferred as a named exception to ADR-IOS-029 NEGATIVE CASE 3: until it
        // commits, a body cached before v116 reads as not cached, so it may be fetched
        // or merged again; nothing is deleted and no message is shown another's content
        // (`HTMLCachePair`, "Before the deferred index step"). The fill reads every
        // cached body once, as `messageBody_staleEvict`'s build did, and also rewrites
        // one header row per cached body, and the index build reads every header (the
        // index holds only the cached ones outside the inbox: partial, see
        // `HTMLCachePair.indexSQL`), all in the one write, so this build costs more than
        // that one did (`StaleBodyEvictPairProofTests` reports it).
        DeferredIndex(
            name: HTMLCachePair.indexName,
            sql: HTMLCachePair.indexSQL,
            fill: HTMLCachePair.fillSQL),
        // #1401: the backfill progress counts (`backfillProgressCounts`) count
        // `MessageHeader.bodySettledRequest` and `.pendingBodyRequest` for one account
        // on every progress update. This index holds every column either predicate
        // tests, so both counts read its entries and never a header row: the pending
        // count seeks all five columns, the settled count reads the account's entries
        // and tests its OR in each. No other index has `accountId` with
        // `bodyEmptyConfirmed` and `bodyMetadataOversized`. It extends v40's
        // `messageHeader_accountId_bodyComplete` and keeps its prefix, so it serves
        // every plan that one does; v40's stays (ADR-IOS-029 rules 3 and 4). Deferred:
        // the build reads every header once, and its absence changes no result, only
        // how much the counts read.
        DeferredIndex(
            name: "messageHeader_backfillProgress",
            sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_backfillProgress
                ON messageHeader(accountId, bodyComplete, bodyEmptyConfirmed,
                                 bodyMetadataOversized, headerComplete)
                """),
        // Serves `SyncEngine.ftsBodyMembershipCandidateSQL`, the start-up search
        // self-check's newest 2,000 complete headers (#1397). With it that read walks
        // this index newest first, takes `id` from it (covering: no table page is read)
        // and stops at the 2,000th entry; without it the read seeks
        // `idx_messageHeader_bodyStatus` and sorts every complete header of every
        // account before returning the first. Deferred because its absence degrades
        // performance and nothing else: the statement names no index and picks the same
        // headers either way, so until the first maintenance pass builds it the read
        // costs what it cost before.
        //
        // PARTIAL, on purpose. It holds only complete headers, so SQLite can use it only
        // for a statement whose WHERE implies `headerComplete = 1 AND bodyComplete = 1`.
        // A full index led by `headerComplete` was also taken by the start-up recovery
        // read (`headerComplete = 0`), which then read more pages than through
        // `idx_messageHeader_bodyStatus`. Only a header whose two flags are both 1 is
        // written to it: inserting a header with no body, or marking a header complete
        // before its body, leaves it alone.
        DeferredIndex(
            name: "messageHeader_completeByDate",
            sql: """
                CREATE INDEX IF NOT EXISTS messageHeader_completeByDate
                ON messageHeader(date, id)
                WHERE headerComplete = 1 AND bodyComplete = 1
                """)
    ]

    /// Creates every index in `indexes` (the deferred set unless a test names another)
    /// that does not already exist, inside the caller's transaction, each after its
    /// `fill` when it has one. Which indexes are missing is read inside that
    /// transaction, so a fill runs exactly when its index is built.
    ///
    /// Separate from the `async` pass below so a test can reach the PRODUCTION DDL
    /// through a plain `Database` instead of re-typing the `CREATE INDEX` — a
    /// re-typed copy is a test that passes against a statement the app does not run.
    nonisolated static func createDeferredIndexes(
        _ db: Database, _ indexes: [DeferredIndex] = SyncEngine.deferredIndexes
    ) throws {
        let missing = Set(try missingDeferredIndexNames(db, among: indexes))
        for index in indexes {
            if let fill = index.fill, missing.contains(index.name) {
                try db.execute(sql: fill)
            }
            try db.execute(sql: index.sql)
        }
    }

    /// The indexes of `indexes` that `sqlite_master` does not have, or `nil` if the
    /// schema could not be read at all (which is *unknown*, not *present*).
    ///
    /// ⚠️ NOT `async`, for the same reason as `plannerStatisticsSchemaVersion` below:
    /// Swift binds the ASYNC overload from an async context, and
    /// `PrioritizedDatabase.read`'s awaited overload runs the NSE read-through
    /// staging merge before it reads. Inlining this into the async caller silently
    /// drags a multi-second durable merge into a probe that exists to decide whether
    /// to do any work at all.
    private static func missingDeferredIndexes(
        _ dbPool: PrioritizedDatabase, among indexes: [DeferredIndex] = SyncEngine.deferredIndexes
    ) -> [String]? {
        try? dbPool.read { db in try missingDeferredIndexNames(db, among: indexes) }
    }

    /// The names of the indexes of `indexes` that `sqlite_master` does not have: one
    /// lookup per index on the schema table, no data read. Also the build's own check
    /// (`createDeferredIndexes`), inside its write.
    nonisolated static func missingDeferredIndexNames(
        _ db: Database, among indexes: [DeferredIndex] = SyncEngine.deferredIndexes
    ) throws -> [String] {
        try indexes.filter { index in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: [index.name]) == nil
        }.map(\.name)
    }

    // MARK: Building a deferred index (inside the statistics write below)
    //
    // A missing deferred index is built by `runRefreshPlannerStatisticsIfStale`, in
    // the SAME write transaction as the whole-database `ANALYZE` and before it, and
    // the marker is then settled on the schema version read after that `ANALYZE`
    // (2026-11-24). Until then the build was its own write, run just
    // before the statistics step, and that left a window: a connection that read
    // between the two writes loaded the new index with no statistics row beside
    // current ones for every other index, and SQLite keeps what a connection loads
    // until the next schema change, because `ANALYZE` alone does not bump
    // `schema_version`. With the new index looking far more selective than it is,
    // such a connection planned the unread inbox page and the pending-body count
    // through it (measured on a 100k-header test database: 71 to 367 pages read for the
    // unread page), and kept doing so until GRDB closed it at the next background
    // entry. One write means no connection can load a schema that has a new index
    // but not its statistics, whatever statistics the database had before. Two
    // narrower fixes do not hold: an `ANALYZE` of only the new index in the build's write, which is exact
    // only when every other index's statistics are current (with older or missing
    // ones the new index looks UNselective, so its own read keeps the old plan and
    // another read can flip), and an `ANALYZE` of its table there, which is exact but
    // pays a second statistics run when the whole-database one follows.
    //
    // The rest of this note is the build's own history, kept from when it was a
    // separate step.
    //
    // ORDER. `CREATE INDEX` is DDL, so it bumps SQLite's `schema_version`, which is
    // exactly the marker the statistics step latches on. Building FIRST means the
    // `ANALYZE` reads the POST-index version and records it, so **one pass
    // converges**: index built, statistics computed over it, marker settled.
    // Building after would have the analysis record version N, the index bump it to
    // N+1, and the NEXT pass pay a second whole-database `ANALYZE` for nothing. Inside
    // one write the order is the statement order, and the marker is read last.
    //
    // FAILS SAFE. If the write is skipped, cancelled or aborted it rolls back whole
    // (index and statistics), `markAllAsRead` sorts through a temp B-tree — slow, and
    // correct in the sense that matters (identical rows, identical order), and the
    // stale-body evict step waits for its index (`runEvictStaleBodiesIfIndexed`); a
    // rolled-back write takes the HTML-cache pair's fill with it. Nothing is recorded on failure,
    // so the next pass retries. Recovery is automatic and needs no user gesture (THE
    // MANTRA: recoverable ⇒ fail closed).
    //
    // 🚨 IT IS **NOT** "THE ALREADY-SHIPPED BEHAVIOUR UP TO `v83`", WHICH IS WHAT
    // THIS SENTENCE SAID UNTIL R16-4 (corrected 2026-08-06) — and the wording
    // mattered, because that clause was the entire licence for deferring the build.
    // Shipped `markAllAsRead` (`07a4bb703:TabMail/ViewModels/InboxViewModel.swift`,
    // an immutable tag) fetched `.filter(folderId == fid && isRead == false)
    // .limit(batchSize)` with **no `ORDER BY`**, so it never sorted at all. The
    // ordered keyset sweep arrived IN-RANGE with `a790dd61d` (2026-08-03), which
    // `git merge-base --is-ancestor a790dd61d 07a4bb703` reports is NOT an ancestor
    // of the shipped tag (exit 1). Measured at 357,400 rows / 100,000 unread /
    // fresh-install `sqlite_stat1`: shipped **7,889 ms**, current with the index
    // **4,610 ms**, current WITHOUT it **43,296 ms** — **5.5× worse than shipped**.
    // The deferral is accepted because the window is TRANSIENT and SELF-HEALING,
    // never because it equals a shipped baseline. Full argument: `IOS-PERF-005`.
    //
    // ⚠️ Contrast `runRefreshPlannerStatisticsIfStale`'s own doc below: its
    // "ALREADY-SHIPPED regime" claim about stale statistics is TRUE and stays —
    // `ANALYZE` really has only ever run inside migration bodies. Two adjacent
    // functions, the same argument shape, opposite truth values; that is why each
    // one has to be checked against the tag rather than against its neighbour.
    //
    // COST OF A BUILD: inside the statistics write; for `messageHeader_unreadSweep`
    // 119 ms measured at 360k rows, 5,050 ms on a real 5-account device — which
    // is the whole point of it being here rather than on the launch path.
    // `messageBody_staleEvict` (#1354, out of the list since #1433) read every cached
    // body once, since `fetchedAt` is stored after the HTML, so its build cost more
    // than those figures on a large body cache. `messageHeader_htmlCachedAt`'s fill
    // (#1433) reads every cached body once the same way, then the build reads
    // `messageHeader` once.

    // MARK: - Query-planner statistics (ADR-IOS-029 rule 5, deferred timing)

    /// What one call to `runRefreshPlannerStatisticsIfStale` did. Returned so the
    /// invariant — *statistics are refreshed after a schema change and not
    /// otherwise, and an aborted pass does not consume the obligation* — is
    /// observable without reaching into the marker or into SQLite internals.
    enum PlannerStatisticsRefresh: Equatable, Sendable {
        /// Every deferred index exists and the schema has not changed since the last
        /// completed `ANALYZE`.
        case alreadyFresh
        /// `ANALYZE` completed, after building every missing deferred index in the
        /// same write, and the marker advanced to the settled schema version.
        case refreshed
        /// The pass could not read the schema or its version, or the write failed /
        /// was aborted, which rolls back any index it built with its statistics. The
        /// marker is UNCHANGED, so the next pass retries.
        case abandoned
        /// Another caller already holds the single-flight latch. This pass did
        /// nothing and consumed no obligation — the in-flight one will advance the
        /// marker, or leave it for the next pass. Distinct from `.alreadyFresh`
        /// (which is a statement about the SCHEMA) and from `.abandoned` (which is
        /// a statement about a FAILURE), so a test can tell the three apart.
        case alreadyRunning
    }

    /// Single-flight latch for the whole-database `ANALYZE`.
    ///
    /// 🚨 THE MARKER IS NOT A LATCH. It is read, and then written only after
    /// `ANALYZE` returns, so two callers can both read it stale and both run a
    /// whole-database analysis — the second one paying the full cost for nothing,
    /// serialized behind the first on SQLite's single writer. The two callers are
    /// real and can overlap: `SyncEngine.scheduleMaintenanceInBackground` (the
    /// foreground poll) and `SyncScheduler`'s BGProcessing drain both call
    /// `runWALMaintenance`, from independent detached tasks.
    ///
    /// `Mutex` (SE-0433) per the Resilience rule — not `NSLock`, not
    /// `nonisolated(unsafe)`.
    ///
    /// The email database's switch to `auto_vacuum = INCREMENTAL` holds it too
    /// (`switchEmailDatabaseToIncremental`), so no `ANALYZE` stores its marker
    /// between that switch's `VACUUM` and its carry of the marker.
    static let plannerStatisticsRefreshInFlight = Mutex<Bool>(false)

    /// The SQLite `schema_version` right now, or `nil` if it could not be read.
    ///
    /// ⚠️ NOT `async`, AND THAT IS THE WHOLE POINT OF THIS FUNCTION EXISTING. Swift
    /// binds the ASYNC overload of an overloaded call from an async context, and
    /// `PrioritizedDatabase.read`'s awaited overload is explicitly NOT a passthrough:
    /// it runs the NSE read-through staging merge — durable header/body writes and an
    /// FTS flush, measured at 7.6 s on a cold-I/O boot — BEFORE it reads. Dragging
    /// that into a `PRAGMA` probe that exists to decide whether to do maintenance
    /// would be a new cost, not a fix. Keeping the probe in a non-async function is
    /// the only way to bind the synchronous passthrough overload, so inlining this
    /// back into the (async) caller silently reintroduces the merge.
    private static func plannerStatisticsSchemaVersion(_ dbPool: PrioritizedDatabase) -> Int? {
        try? dbPool.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") ?? 0 }
    }

    /// `UserDefaults` key holding the SQLite `schema_version` in force when the last
    /// whole-database `ANALYZE` COMPLETED. `StartupMigrations` is the precedent for
    /// using `UserDefaults` as a durable one-shot latch here.
    nonisolated static let plannerStatisticsSchemaVersionKey = "didAnalyzeAtSchemaVersion_v1"

    /// Whole-database `ANALYZE`, moved OFF the blocking migration path and run here
    /// at most once per schema change (ADR-IOS-029, 2026-08-05 amendment; owner
    /// directive *"startup migrations should really have only things that are
    /// absolutely necessary and blocking"*). `v83_markAllAsReadUnreadSweepIndex` used
    /// to carry it inline and measured ~850 ms at 360k rows and 8,522 ms at 500k,
    /// before any UI appeared.
    ///
    /// ⚠️ WHY IT IS ON THIS SIDE OF THE MAINTENANCE SPLIT. `ANALYZE` rewrites
    /// `sqlite_stat1` — an ordinary WAL write on the MAIN database, which at the
    /// suspension instant throws a benign `SQLITE_ABORT`. The other half,
    /// `runBodyAssetMaintenance`, reads a NON-WAL App-Group `DatabaseQueue` whose
    /// read lock cannot be aborted and is the `0xdead10cc` shape (ADR-IOS-046).
    /// Putting a main-DB write there would be a new bug, not a fix.
    ///
    /// THE LATCH, AND EXACTLY WHAT RE-ARMS IT. The marker is the SQLite
    /// `schema_version` in force when the last `ANALYZE` completed. SQLite bumps
    /// `schema_version` on every DDL statement, so ANY migration that creates, drops
    /// or alters a table or an index re-arms this **automatically** — there is no
    /// hand-maintained constant to forget, which is the failure mode a
    /// "bump me when you add an index" counter would have. ⚠️ WHAT DOES **NOT**
    /// re-arm it, stated because it is the mirror-image mistake: ordinary
    /// `INSERT`/`UPDATE`/`DELETE` traffic, however far the row counts move. That is
    /// deliberate. A per-poll `ANALYZE` would cost the 8.5 s above on every
    /// foreground poll and would be a far worse defect than the one this fixes.
    ///
    /// DURABLE. `UserDefaults` survives app kill, crash and reboot, so a device that
    /// dies between the migration and this pass still refreshes on a later launch;
    /// and a device that dies *during* the `ANALYZE` finds the old marker and
    /// retries. The marker is written only after `ANALYZE` returns, so a partial run
    /// never records a success it did not achieve.
    ///
    /// FAILS SAFE. If this is skipped, cancelled or aborted, the only consequence is
    /// that statistics stay stale — which is the ALREADY-SHIPPED regime: `ANALYZE`
    /// has only ever run inside migration bodies, and on a fresh install those
    /// bodies record statistics for an EMPTY `messageHeader`. So the exposure window
    /// between an upgrade launch and the first maintenance pass is no worse than
    /// every shipped release, and strictly better once the pass runs.
    ///
    /// IT ALSO BUILDS EVERY MISSING DEFERRED INDEX, IN THE SAME WRITE. When an index
    /// of `indexes` (`deferredIndexes` in the app) is missing, the write creates it
    /// and then runs the `ANALYZE`, whatever the marker says, so the index and its
    /// statistics commit together and the marker settles on the post-index schema
    /// version: no connection can load a schema that has the new index but not its
    /// statistics (see "Building a deferred index" above). With every deferred index
    /// present this is the stale-marker `ANALYZE` alone, as before. `indexes` is a
    /// parameter only so a test can add an index the app does not build yet; the app
    /// always passes the default.
    ///
    /// COST WHILE IT RUNS: one write transaction, up to ~8.5 s at 500k headers, plus,
    /// on the pass that builds a deferred index, that build (see "COST OF A BUILD"
    /// above).
    ///
    /// THE WAL AFTER A BUILD. A write that built an index (and ran a fill for one)
    /// wrote many pages in one transaction, the largest WAL of the pass, and
    /// autocheckpoint is off, so after it commits this calls `checkpointWAL` with the
    /// pool it wrote to (`checkpointWALThrottled(truncate: true, pool:)` in the app),
    /// outside the write. It is the one checkpoint helper, throttle included. It asks
    /// for a TRUNCATE, which leaves the WAL file empty, because the throttle lets only
    /// one checkpoint through per `walCheckpointMinIntervalSeconds`: a PASSIVE one here
    /// would make the pass's closing TRUNCATE (`scheduleMaintenanceInBackground`), which
    /// follows this last step within that window, skip, and the file would stay at its
    /// largest until a later pass. The background-processing pass, which has no closing
    /// checkpoint, gets its TRUNCATE here too. A checkpoint run less than the interval
    /// earlier skips this one, and the next batch writer's checkpoint takes those
    /// frames. It runs once per build, so its wait on readers is a one-time cost. A
    /// refresh that built nothing writes only `sqlite_stat1` and adds no checkpoint.
    ///
    /// ⚠️ THIS FUNCTION IS `async` FOR ONE REASON, AND THE PREVIOUS VERSION OF THIS
    /// PARAGRAPH WAS WRONG. It used to claim the cost lands *"on the caller's pool
    /// tier (`.background` from the foreground poll) … never on a `.priority`
    /// write"*. It did not, and could not: the function was NOT async, so
    /// `dbPool.write { }` bound `PrioritizedDatabase`'s SYNCHRONOUS overload, whose
    /// own doc says *"Sync write — can't `await`, so it can't enter the queue;
    /// passes through."* **A pass-through write has no tier at all.** It went
    /// straight to GRDB's writer, holding SQLite's single writer for the whole
    /// analysis, ahead of every `.priority` write already queued behind
    /// `DatabaseWriteQueue` — the exact contention the tiering exists to prevent.
    /// Being `async` is what makes the sentence true: the awaited overload enters
    /// `DatabaseWriteQueue` at the caller's tier (`.background` from both
    /// maintenance callers), so a user action's `.priority` write jumps ahead of
    /// this instead of waiting behind it.
    ///
    /// The schema-version READ stays synchronous deliberately — see
    /// `plannerStatisticsSchemaVersion`, which exists only to keep that binding.
    ///
    /// It runs at most once per schema change and never on the launch path.
    @discardableResult
    nonisolated static func runRefreshPlannerStatisticsIfStale(
        dbPool: PrioritizedDatabase,
        defaults: UserDefaults = .standard,
        markerKey: String = plannerStatisticsSchemaVersionKey,
        indexes: [DeferredIndex] = SyncEngine.deferredIndexes,
        checkpointWAL: @Sendable (PrioritizedDatabase) async -> Void = { await SyncEngine.checkpointWALThrottled(truncate: true, pool: $0) }
    ) async -> PlannerStatisticsRefresh {
        // SINGLE-FLIGHT. Taken BEFORE the marker read, because the race is two
        // callers both reading the marker stale — taking it after the read would
        // leave exactly that window open.
        let acquired = plannerStatisticsRefreshInFlight.withLock { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard acquired else { return .alreadyRunning }
        defer { plannerStatisticsRefreshInFlight.withLock { $0 = false } }

        // Under the latch, so two overlapping callers cannot both build and analyze.
        guard let missing = missingDeferredIndexes(dbPool, among: indexes) else {
            // Could not read the schema ⇒ nothing is determined. Retry next pass.
            return .abandoned
        }
        guard let currentVersion = plannerStatisticsSchemaVersion(dbPool) else {
            // Could not read the schema version ⇒ nothing is determined. Leave the
            // marker alone and retry next pass.
            return .abandoned
        }
        // `object(forKey:)` rather than `integer(forKey:)`: a never-analyzed database
        // has NO stored value, and `integer(forKey:)` cannot tell that apart from a
        // stored 0 — which is a legal `schema_version`.
        if missing.isEmpty,
           let analyzed = defaults.object(forKey: markerKey) as? Int,
           analyzed == currentVersion {
            return .alreadyFresh
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        // 🚨 CANCELLATION IS RE-CHECKED AFTER THE WRITER IS ACQUIRED, not only
        // before entering. `runWALMaintenance`'s `shouldRun()` gate is evaluated
        // before the call, and the awaited write then waits for the priority queue
        // AND for SQLite's single writer — an unbounded delay during which the
        // maintenance task can be cancelled (`SyncEngine.cancelMaintenance` on
        // background entry) or the process suspended. Spending 8.5 s on an ANALYZE
        // for a task that no longer exists is the cost this closes.
        //
        // It is a `Mutex`-backed flag rather than `Task.isCancelled` INSIDE the
        // closure, and that is not a stylistic choice: GRDB dispatches the write
        // closure onto its own writer queue, so it does not run inside the Swift
        // concurrency task and `Task.isCancelled` there always reads `false`.
        // `withTaskCancellationHandler` fires `onCancel` on the cancelling thread —
        // and immediately, if the task is already cancelled — so the flag is
        // readable from wherever the closure ends up running.
        //
        // ⚠️ THIS DELIBERATELY DEVIATES from `DatabaseWriteQueue`'s stated contract
        // (*"a write already queued here runs to completion even if its Task is
        // cancelled … never-drop-user-intention: a half-decided DB write must not be
        // abandoned mid-flight"*). That contract protects writes that CARRY a user
        // intention. `ANALYZE` carries none — it rewrites planner statistics only —
        // and neither does a deferred index build, so abandoning the write drops
        // nothing: it rolls back whole, the marker is left where it was, so the
        // obligation stays outstanding and the next pass redoes it. The deviation is
        // confined to this one write for exactly that reason.
        let cancelledWhileQueued = Mutex<Bool>(false)
        do {
            let settled: Int = try await withTaskCancellationHandler {
                try await dbPool.write(label: "AnalyzePlannerStatistics") { db in
                    guard !cancelledWhileQueued.withLock({ $0 }),
                          !DatabaseSuspension.isSuspended else {
                        throw CancellationError()
                    }
                    // The missing deferred indexes first, then the statistics over
                    // them, in this one transaction (see "Building a deferred index").
                    if !missing.isEmpty {
                        try createDeferredIndexes(db, indexes)
                    }
                    try db.execute(sql: "ANALYZE")
                    // Read AFTER, inside the same transaction. The FIRST `ANALYZE` on a
                    // database CREATES `sqlite_stat1`, which is itself DDL and bumps
                    // `schema_version`; storing the version read BEFORE would record a
                    // value the analysis had already invalidated and this pass would
                    // re-fire forever.
                    return try Int.fetchOne(db, sql: "PRAGMA schema_version") ?? currentVersion
                }
            } onCancel: {
                cancelledWhileQueued.withLock { $0 = true }
            }
            defaults.set(settled, forKey: markerKey)
            if DebugModeManager.isLoggingEnabled() {
                let built = missing.isEmpty ? "" : "built deferred index(es) \(missing.joined(separator: ", ")) and "
                BackgroundSyncLogger.logDebug("[Maintenance] \(built)ANALYZE refreshed query-planner statistics in one write in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (schema_version \(settled))")
            }
            // See "THE WAL AFTER A BUILD" above.
            if !missing.isEmpty { await checkpointWAL(dbPool) }
            return .refreshed
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                let built = missing.isEmpty ? "" : " (with the build of \(missing.joined(separator: ", ")), rolled back)"
                BackgroundSyncLogger.logDebug("[Maintenance] ANALYZE abandoned after \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms\(built) — statistics stay stale, retrying next pass: \(error)")
            }
            return .abandoned
        }
    }
}
