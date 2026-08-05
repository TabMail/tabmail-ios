/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Thin I/O shell for `InboxListComposer` — PLAN_INBOX_UNIFIED_READ.md
/// §2.1/§2.1b. NOT wired into any production call site yet (Phase 3 does the
/// switch); this file exists so the shell + its shared gather logic can be
/// integration-tested against a real GRDB pool ahead of the cutover.
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
            print("[InboxListReader] fetch error: \(error)")
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
            print("[InboxListReader] fetchSync error: \(error)")
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
            var q = MessageHeader.filter(Column("folderId") == folder.id)
                .filter(Column("headerComplete") == true)
            if query.filterUnread {
                q = q.filter(Column("isRead") == false)
            }
            // 🚨 THE LABEL FILTER RUNS HERE, IN SQL, BEFORE THIS QUERY'S `LIMIT`
            // — NEVER only in memory after it. `InboxListComposer.compose`
            // step 6 applies the identical `isSubset` predicate to D, P and S
            // uniformly and REMAINS the authority for P and S (a P row is
            // fetched by id, an S row synthesizes with `userLabels == []`).
            // What it must not be is the FIRST place a DURABLE row meets the
            // filter: the `limit(query.targetCount)` below IS the page, so a
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
                q = q.filter(
                    sql: """
                    EXISTS (
                        SELECT 1 FROM messageUserLabel
                        WHERE messageUserLabel.messageId = messageHeader.id
                          AND messageUserLabel.userLabelId = ?
                    )
                    """,
                    arguments: [labelId]
                )
            }
            if let cutoff = query.beforeDate {
                q = q.filter(Column("date") < cutoff)
            }
            if query.mode == .triage {
                q = q.order(Column("tagSortOrder").asc, Column("date").desc)
            } else {
                q = q.order(Column("date").desc)
            }
            allHeaders.append(contentsOf: try q.limit(query.targetCount).fetchAll(db))
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
