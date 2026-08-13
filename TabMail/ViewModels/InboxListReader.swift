/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Thin I/O shell for `InboxListComposer` — PLAN_INBOX_UNIFIED_READ.md
/// §2.1/§2.1b.
///
/// ⚠ **PHASE 3 HAS LANDED — this doc used to say "NOT wired into any production
/// call site yet (Phase 3 does the switch)", and that is stale.** Both entry
/// points are on the production inbox read path:
/// `InboxViewModel.fetchFullRange()` calls `fetch(folders:query:)`, and
/// `InboxViewModel.fetchPage(before:)` calls `fetchSync(folders:query:)`. The
/// original rationale still holds for the *tests* — the shell and its shared
/// `gather` logic are integration-tested against a real GRDB pool — but a
/// change here now alters what the user sees, not just what a test asserts.
///
/// Deliberately BORING: every decision (eligibility, precedence, dedup,
/// filters, sort, trim) lives in `InboxListComposer.compose`. This file only
/// gathers value snapshots — overlay + staged-rows Mutex reads, and ONE read
/// transaction producing D (durable), P (overlay-pinned), and the staged
/// identity resolutions — then hands them to `compose`.
enum InboxListReader {

    /// Async gather (repaint-decoupled): reads `AppDatabase.rawPool`
    /// directly, same rationale as `fetchFullRange`'s deliberate rawPool
    /// read — skips the read-through NSE merge so a slow merge can't block
    /// the inbox repaint. Used for reloads.
    @MainActor
    static func fetch(folders: [Folder], query: InboxListQuery) async -> [MessageSnapshot] {
        let overlay = AccountManager.shared.snapshotOverlay()
        let staged = NSEDataBridge.latestStagedRows.withLock { $0 }
        let gathered: GatherResult
        do {
            gathered = try await AppDatabase.rawPool.read { db in
                try gather(db: db, folders: folders, query: query, overlay: overlay, staged: staged)
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() { print("[InboxListReader] fetch error: \(error)") }
            return []
        }
        return InboxListComposer.compose(ComposeInputs(
            durable: gathered.durable,
            pinned: gathered.pinned,
            staged: staged,
            stagedResolutions: gathered.resolutions,
            overlay: overlay,
            query: query
        ))
    }

    /// Sync gather: same pattern as today's `fetchPage` — `AppDatabase.dbPool`
    /// (status quo, no read-through-merge cost added; the merge is a no-op
    /// here since this pool's sync `read` overload passes straight through,
    /// see `PrioritizedDatabase.read`). Used where today's code is already
    /// sync (init / pagination — §2.1b).
    @MainActor
    static func fetchSync(folders: [Folder], query: InboxListQuery) -> [MessageSnapshot] {
        let overlay = AccountManager.shared.snapshotOverlay()
        let staged = NSEDataBridge.latestStagedRows.withLock { $0 }
        let gathered: GatherResult
        do {
            gathered = try AppDatabase.dbPool.read { db in
                try gather(db: db, folders: folders, query: query, overlay: overlay, staged: staged)
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() { print("[InboxListReader] fetchSync error: \(error)") }
            return []
        }
        return InboxListComposer.compose(ComposeInputs(
            durable: gathered.durable,
            pinned: gathered.pinned,
            staged: staged,
            stagedResolutions: gathered.resolutions,
            overlay: overlay,
            query: query
        ))
    }

    // MARK: - Shared gather (so sync/async can't drift)

    private struct GatherResult: Sendable {
        let durable: [MessageSnapshot]
        let pinned: [MessageSnapshot]
        let resolutions: [String: StagedIdentityResolution]
    }

    // MARK: - The D statement
    //
    /// The per-folder durable statement the D step runs, as SQL plus its
    /// arguments. Named — rather than inlined in `gather` — for the same reason
    /// as `MessageContentStore.ownersSQL`: the PLAN invariant is asserted
    /// against the statement the production path actually executes, never
    /// against a copy in a test that would silently drift away from it.
    ///
    /// 🚨 WHY THIS IS SQL AND NOT THE GRDB QUERY INTERFACE, WHICH IS WHAT IT
    /// USED TO BE. Only for `INDEXED BY`, which GRDB's query interface cannot
    /// express (no `indexedBy`/`notIndexed` in `GRDB/QueryInterface`). The
    /// predicate, its clause ORDER, the `ORDER BY` and the `LIMIT` are
    /// unchanged from the query-interface form, which is what
    /// `InboxListReaderStatementTests` pins by running both and comparing rows.
    ///
    /// 🚨 WHY THE TRIAGE HINT (R13-U6). Adding `id ASC` to the `ORDER BY` made
    /// SQLite abandon `messageHeader_triage_display` ENTIRELY and fall onto
    /// `messageHeader_inbox_display` plus a sort of the WHOLE folder — an index
    /// SWITCH, not an extra sort term. Measured, `folderId=? AND
    /// headerComplete=1`, no cursor, 100k rows in one folder, SQLite 3.51.0
    /// (Mac; a device is 2–4× slower), median of 7:
    ///
    /// ```
    ///                        empty stats   ANALYZEd    plan
    ///   no hint                 18.28 ms   18.67 ms    inbox_display  + TEMP B-TREE FOR ORDER BY
    ///   INDEXED BY triage        1.91 ms    2.04 ms    triage_display + TEMP B-TREE FOR LAST 2 TERMS
    ///   (two-term ORDER BY)      1.91 ms    2.04 ms    triage_display + TEMP B-TREE FOR LAST TERM
    /// ```
    ///
    /// Reproduces in EVERY statistics regime including a schema-only empty DB,
    /// so it is not a stats problem and `ANALYZE` does not fix it. `fetchSync`
    /// is `@MainActor` with a blocking `dbPool.read`, this loop runs ONCE PER
    /// DISPLAYED FOLDER, and it is on first paint and on every scroll page — a
    /// unified inbox multiplies it.
    ///
    /// ⚠️ THE HINT IS DELIBERATELY NOT APPLIED WHEN `filterUnread` IS ON, AND
    /// THAT IS THE MIRROR IMAGE OF THIS FIX, NOT AN OMISSION. With the unread
    /// filter the planner picks `messageHeader_folderId_isRead`, whose
    /// selectivity is the whole point. Measured on the same 100k folder with
    /// THREE unread rows — the state triage exists to drive users toward:
    ///
    /// ```
    ///   no hint                  0.022 ms   folderId_isRead (folderId=? AND isRead=?)
    ///   INDEXED BY triage       18.891 ms   triage_display  (folderId=? AND headerComplete=?)
    /// ```
    ///
    /// 860× the wrong way. Neither choice dominates (at 33k unread the hint
    /// wins 1.44 ms to 14.29 ms), and where we have no dominating answer the
    /// planner keeps the decision. The regression this fixes is the
    /// cursor-less, unread-OFF first paint, which is what the range changed.
    ///
    /// ⚠️ A migration that renames or drops `messageHeader_triage_display`
    /// makes this statement THROW — `fetch`/`fetchSync` catch it and return an
    /// empty list, i.e. an empty inbox until the next reload. Loud, and never a
    /// wrong row. Same fail-safe rationale as `MessageContentStore.ownersSQL`.
    static func durableQuerySQL(folderId: String, query: InboxListQuery) -> (sql: String, arguments: StatementArguments) {
        var sql = "SELECT * FROM messageHeader"
        if query.mode == .triage && !query.filterUnread {
            sql += " INDEXED BY messageHeader_triage_display"
        }
        sql += " WHERE folderId = ? AND headerComplete = 1"
        var args: [any DatabaseValueConvertible] = [folderId]
        if query.filterUnread {
            sql += " AND isRead = 0"
        }
        // 🚨 THE LABEL FILTER RUNS HERE, IN SQL, BEFORE THIS QUERY'S `LIMIT`
        // — NEVER only in memory after it. `InboxListComposer.compose`
        // step 6 applies the identical `isSubset` predicate to D, P and S
        // uniformly and REMAINS the authority for P and S (a P row is
        // fetched by id, an S row synthesizes with `userLabels == []`).
        // What it must not be is the FIRST place a DURABLE row meets the
        // filter: the `LIMIT query.targetCount` below IS the page, so a
        // filter applied after it NARROWS the page instead of SELECTING
        // it. Two decisions downstream then read a post-filter SURVIVOR
        // count as a statement about the source:
        //
        //  * `InboxViewModel`'s `hasMoreMessages = loadedMessages.count >=
        //    targetWindowSize` (`resetMessages`, `reloadMessages`) and
        //    `>= SyncConfig.inboxPageSize` (`loadMoreMessages` phase 1).
        //    Filtering by a label with 2 hits in the newest 50 rows made a
        //    full page look short, flipped exhaustion true, and left every
        //    older match unreachable by scrolling.
        //  * The pagination cursor itself — `loadedMessages.last?.date` —
        //    which named the oldest SURVIVING row rather than the oldest
        //    row EXAMINED, and is `nil` outright when nothing survived.
        //
        // Both become honest for free once the `LIMIT` bounds MATCHING
        // rows, which is why this is filtered here rather than compensated
        // for downstream with a coverage signal (CLAUDE.md A3: the
        // deviation was the sibling's ordering, not a missing mechanism).
        //
        // `filterLabelIds` is an AND (`isSubset`), so one `EXISTS` per id,
        // ANDed; `.sorted()` keeps the statement shape stable for the
        // cache. `userLabelId` is the account-prefixed surrogate
        // (`"<accountId>:<providerLabelId>"`, D10 / `IOS-LABEL-001`), so
        // this join cannot cross an account boundary any more than
        // compose's in-memory set comparison can. Each probe is covered by
        // `messageUserLabel`'s PRIMARY KEY (`messageId`, `userLabelId`).
        //
        // ⚠ Stated negatively: this is a SUPERSET of step 6's predicate by
        // exactly one corner — step 6 compares against `userLabels`, which
        // `UserLabelStore.loadLabels` has already narrowed by `isSystem`
        // and `shouldExcludeLabel`, and neither is expressible here. A
        // `filterLabelIds` naming a system or excluded label would pass
        // SQL and still be dropped by step 6, re-creating the narrowing
        // this removes. `LabelFilterPickerView` offers only
        // `UserLabelStore.allLabels`, which excludes both, so no reachable
        // filter can name one — do not widen `filterLabelIds`' producers
        // without moving that narrowing here too.
        for labelId in query.filterLabelIds.sorted() {
            sql += """
             AND EXISTS (
                    SELECT 1 FROM messageUserLabel
                    WHERE messageUserLabel.messageId = messageHeader.id
                      AND messageUserLabel.userLabelId = ?
                )
            """
            args.append(labelId)
        }
        // 🚨 KEYSET CURSOR — THE PAGE BOUNDARY IS THE WHOLE ORDERING KEY,
        // NEVER JUST THE DATE (R12-T3). See `InboxPageCursor` for the two
        // defects a bare `date < cutoff` caused (tied-second rows skipped
        // permanently in `.normal`; an entire later tag bucket excluded in
        // `.triage`, whose order is not date-monotonic at all).
        //
        // ⚠️ THE PREDICATE IS SPELT AS `range AND (range OR tie)` ON PURPOSE
        // — A6/database-performance. A bare `date < ? OR (date = ? AND id > ?)`
        // is a top-level OR, which SQLite cannot turn into a single index
        // range on `messageHeader_inbox_display (folderId, headerComplete,
        // date)`; it would fall back to scanning the whole folder. Leading
        // with the redundant-but-sargable `date <= ?` keeps the index range
        // and demotes the tie-break to a residual filter over the boundary
        // block only. Same shape for triage against
        // `messageHeader_triage_display (folderId, headerComplete,
        // tagSortOrder, date)`.
        //
        // ⚠️ `id ASC` is in BOTH `ORDER BY`s so the SQL order is total and
        // matches `InboxListComposer.compose` step 7 exactly. Removing it
        // re-breaks the R12-T3 keyset invariant (`loadedMessages.last` stops
        // being maximal, the cursor goes loose, `IOS-SCROLL-002` returns) —
        // the third term is not the defect, the index switch it provoked was.
        //
        // ⚠️ THE COST OF THE LAST TERM, MEASURED — this comment claimed two
        // things that were both false before R13-U6. Normal mode's block sort
        // is NOT "bounded by the `LIMIT`": it is bounded by the `LIMIT` PLUS
        // the tied-second block straddling it (`USE TEMP B-TREE FOR LAST TERM
        // OF ORDER BY`, 0.24 ms at 100k). And triage's block is NOT "keyed by
        // the index-ordered `tagSortOrder`, then `date`" — with the hint the
        // plan is `USE TEMP B-TREE FOR LAST 2 TERMS OF ORDER BY`, so `date` is
        // sorted too and the block is ONE WHOLE TAG BUCKET (1.91 ms at 100k,
        // 95% untagged). Both numbers are Mac medians on the fixture described
        // above; a device is 2–4× slower.
        if let cursor = query.before {
            if query.mode == .triage {
                sql += " AND tagSortOrder >= ? AND (tagSortOrder > ? OR date < ? OR (date = ? AND id > ?))"
                args.append(contentsOf: [cursor.tagSortOrder, cursor.tagSortOrder, cursor.date, cursor.date, cursor.id] as [any DatabaseValueConvertible])
            } else {
                sql += " AND date <= ? AND (date < ? OR id > ?)"
                args.append(contentsOf: [cursor.date, cursor.date, cursor.id] as [any DatabaseValueConvertible])
            }
        }
        sql += query.mode == .triage
            ? " ORDER BY tagSortOrder ASC, date DESC, id ASC"
            : " ORDER BY date DESC, id ASC"
        // 🚨 THE LIMIT IS A LITERAL, NOT A BOUND PARAMETER, AND THAT IS
        // LOAD-BEARING — it is also what GRDB emitted, so the rewrite changes
        // only the hint. SQLite folds a literal `LIMIT` into its cost model and
        // cannot fold a bound one, so the two plan DIFFERENTLY: measured on the
        // v83 schema with an EMPTY `messageHeader`, `LIMIT ?` makes the
        // un-hinted triage query pick `messageHeader_triage_display` while
        // `LIMIT 50` picks `messageHeader_inbox_display` and sorts everything.
        // On a populated 100k folder both pick `inbox_display` (21.11 ms bound,
        // 19.21 ms literal), so a bound limit does not fix anything — it only
        // hides the regression from a test that runs on an empty schema.
        // `targetCount` is an `Int`, so interpolation cannot inject.
        sql += " LIMIT \(query.targetCount)"
        return (sql, StatementArguments(args))
    }

    /// Runs INSIDE one read transaction. Produces the three pieces
    /// `ComposeInputs` needs beyond overlay/staged (which are Mutex
    /// snapshots taken outside the txn, before the read — existing rule,
    /// see `reloadMessages`' overlay-snapshot-before-DB-read comment).
    private static func gather(
        db: Database,
        folders: [Folder],
        query: InboxListQuery,
        overlay: [String: AccountManager.PendingMutation],
        staged: [StagedInboxRow]
    ) throws -> GatherResult {
        // MARK: D — per-folder query, exact shape of fetchFullRange/fetchPage.
        var allHeaders: [MessageHeader] = []
        for folder in folders {
            let (sql, arguments) = durableQuerySQL(folderId: folder.id, query: query)
            allHeaders.append(contentsOf: try MessageHeader.fetchAll(db, sql: sql, arguments: arguments))
        }

        // §4.4-2 instrumentation (PLAN_INBOX_UNIFIED_READ.md): time everything
        // AFTER the D query — the P-step, its label batch load, and the S
        // identity-resolution loop — NOT the D query above (that's the
        // pre-existing, already-profiled cost). `BootProfiler.mark` is
        // already production-gated (`DebugModeManager.isLoggingEnabled()`),
        // so this is a guard-return no-op in production builds.
        let unionStepStart = CFAbsoluteTimeGetCurrent()

        // MARK: P — overlay-pinned rows (Q1: folderId-driven selection, per
        // PLAN_INBOX_UNIFIED_READ.md §6). `isInInbox`-only mutations never
        // *restore* a row into a folder set, so they don't select for
        // pinning here — they're field overrides on rows already in D/S.
        let durableIds = Set(allHeaders.map(\.id))
        var pinnedHeaders: [MessageHeader] = []
        for (id, mutation) in overlay {
            guard let newFolderId = mutation.folderId,
                  query.displayedFolderIds.contains(newFolderId) else { continue }
            guard !durableIds.contains(id) else { continue }
            guard var header = try MessageHeader.fetchOne(db, key: id) else { continue }
            // insertUndoneMessages' exact field-application logic.
            header.folderId = newFolderId
            if let v = mutation.folderPath { header.folderPath = v }
            if let v = mutation.isInInbox { header.isInInbox = v }
            if let v = mutation.isRead { header.isRead = v }
            // Shell-side unread-filter guard, mirrors insertUndoneMessages'
            // `if filterUnread && header.isRead { continue }` — applied here
            // (not in compose) so filterUnread behavior is uniform across
            // D/P/S at the point each is materialized. `compose` only
            // re-filters S (see ComposeInputs.durable's doc comment).
            if query.filterUnread && header.isRead { continue }
            pinnedHeaders.append(header)
        }

        // Labels for D AND P in one batch — P rows need real labels too, or
        // an undone message that genuinely carries the filtered label would
        // be wrongly dropped by compose's uniform label filter (step 6).
        let labelsByMessage = try UserLabelStore.loadLabels(
            for: allHeaders.map(\.id) + pinnedHeaders.map(\.id), in: db
        )
        let durable = allHeaders.map { header in
            MessageSnapshot(from: header, userLabels: labelsByMessage[header.id] ?? [])
        }
        let pinned = pinnedHeaders.map { header in
            MessageSnapshot(from: header, userLabels: labelsByMessage[header.id] ?? [])
        }

        // MARK: S resolutions — one DurableIdentityLookup.find per staged
        // row, the SAME identity lookup the merge uses (phase 1/phase 2,
        // verifyDurable, detectStaleByMoveRows). No decisions here — compose
        // owns the stale-by-move / carry-over / inclusion logic.
        var resolutions: [String: StagedIdentityResolution] = [:]
        resolutions.reserveCapacity(staged.count)
        for row in staged {
            let ref = try DurableIdentityLookup.find(
                db: db, accountId: row.accountId, folderPath: row.folderPath, messageId: row.messageId,
                rfc822MessageId: row.rfc822MessageId
            )
            resolutions[row.headerId] = StagedIdentityResolution(stagedHeaderId: row.headerId, durable: ref)
        }

        let unionStepMs = Int((CFAbsoluteTimeGetCurrent() - unionStepStart) * 1000)
        if unionStepMs > 10 {
            BootProfiler.mark(
                "InboxListReader union step \(unionStepMs)ms (pinned=\(pinned.count) stagedResolutions=\(resolutions.count))"
            )
        }

        return GatherResult(durable: durable, pinned: pinned, resolutions: resolutions)
    }
}
