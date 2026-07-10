/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Everything the composer needs to know about "what list is being asked
/// for" — folder scope, filters, sort mode, and window size.
/// PLAN_INBOX_UNIFIED_READ.md §2.1.
struct InboxListQuery: Equatable, Sendable {
    /// `Set(folders.map(\.id))` — the currently displayed folder set.
    let displayedFolderIds: Set<String>
    let filterUnread: Bool
    let filterLabelIds: Set<String>
    let mode: InboxMode
    /// Window size: `targetWindowSize` (full-range reload) or `pageSize` (a
    /// single page). Rows are trimmed to this count after sort.
    let targetCount: Int
    /// Pagination cutoff (`fetchPage(before:)`). `nil` for a full-range
    /// reload. When non-nil, `S` and `P` rows are cut in `compose` (D
    /// arrives already cut by the shell's SQL `date < beforeDate`).
    let beforeDate: Date?

    init(
        displayedFolderIds: Set<String>,
        filterUnread: Bool,
        filterLabelIds: Set<String>,
        mode: InboxMode,
        targetCount: Int,
        beforeDate: Date?
    ) {
        self.displayedFolderIds = displayedFolderIds
        self.filterUnread = filterUnread
        self.filterLabelIds = filterLabelIds
        self.mode = mode
        self.targetCount = targetCount
        self.beforeDate = beforeDate
    }
}

/// What the shell resolved (via `DurableIdentityLookup`) for one staged
/// row's dedup identity. `durable == nil` means no durable header exists
/// anywhere for this identity (an ordinary new message).
struct StagedIdentityResolution: Equatable, Sendable {
    let stagedHeaderId: String // StagedInboxRow.headerId
    let durable: DurableIdentityLookup.DurableHeaderRef?

    init(stagedHeaderId: String, durable: DurableIdentityLookup.DurableHeaderRef?) {
        self.stagedHeaderId = stagedHeaderId
        self.durable = durable
    }
}

/// Value snapshot of the three list sources + the query, everything
/// `InboxListComposer.compose` needs. No I/O — every field is a plain value.
struct ComposeInputs: Sendable {
    /// D — durable GRDB rows, folder-filtered (`folderId ==`),
    /// `headerComplete == true` only, per-folder-limited to
    /// `query.targetCount`, mode-ordered.
    ///
    /// PARITY NOTE (compose step 4): arrives ALREADY filtered by `isRead` at
    /// the SQL level when `query.filterUnread` is set — exactly like
    /// `fetchFullRange`/`fetchPage` do today. `compose` does NOT re-filter D
    /// by `isRead`. This preserves today's asymmetry (SQL filters D
    /// pre-overlay; the overlay can flip `isRead` afterward without
    /// re-excluding the row) rather than "fixing" it — parity first, per the
    /// migration plan.
    ///
    /// Label filter is NOT applied here — `compose` owns label filtering
    /// uniformly for D/P/S (step 6).
    let durable: [MessageSnapshot]
    /// P — overlay-pinned rows: overlay entries whose `folderId` mutation
    /// points INTO the displayed folder set but whose durable row is
    /// elsewhere, fetched by id. The shell has ALREADY applied the overlay's
    /// folderId/folderPath/isInInbox/isRead fields onto these snapshots
    /// (`insertUndoneMessages`' exact logic) — this is the "undo shape".
    /// Re-applying the overlay in step 3 must be a no-op for these rows
    /// (idempotency), which holds because overlay lookups key off
    /// `snapshot.id` (the durable header's own id, unaffected by the
    /// overlay's target-folder values).
    let pinned: [MessageSnapshot]
    /// S — the in-memory staged snapshot (`NSEDataBridge.latestStagedRows`).
    let staged: [StagedInboxRow]
    /// Keyed by `StagedInboxRow.headerId`.
    let stagedResolutions: [String: StagedIdentityResolution]
    let overlay: [String: AccountManager.PendingMutation]
    let query: InboxListQuery

    init(
        durable: [MessageSnapshot],
        pinned: [MessageSnapshot],
        staged: [StagedInboxRow],
        stagedResolutions: [String: StagedIdentityResolution],
        overlay: [String: AccountManager.PendingMutation],
        query: InboxListQuery
    ) {
        self.durable = durable
        self.pinned = pinned
        self.staged = staged
        self.stagedResolutions = stagedResolutions
        self.overlay = overlay
        self.query = query
    }
}

/// PURE composer for the inbox list — PLAN_INBOX_UNIFIED_READ.md §2.1/§2.1a.
///
/// NO I/O, NO clocks, NO singletons, NO GRDB. Everything here is a
/// deterministic function of value inputs, which is what makes the whole
/// three-source dance (durable GRDB rows / overlay-pinned rows / in-memory
/// staged rows) unit-testable without a database — see
/// `InboxComposeScenarioTests`. The thin I/O shell that gathers these inputs
/// from the real world lives in `InboxListReader.swift`.
///
/// This file REPLICATES (not reinvents) today's `InboxViewModel` semantics:
/// `fetchFullRange`/`fetchPage` (D), `insertUndoneMessages` (P), and
/// `insertStagedRows` (S eligibility, in-memory computedThreadId adoption,
/// identity dedup). Where this file's behavior differs from those functions,
/// it is a DELIBERATE unification called out in a comment (e.g. the label
/// filter now applies to staged rows too — see step 6).
enum InboxListComposer {

    static func compose(_ inputs: ComposeInputs) -> [MessageSnapshot] {
        let query = inputs.query

        // MARK: Step 1 — D ∪ P, dedup by id, D wins (D is the authoritative
        // GRDB read; P only fills in rows D's folder-scoped query missed).
        var byId: [String: MessageSnapshot] = [:]
        byId.reserveCapacity(inputs.durable.count + inputs.pinned.count + inputs.staged.count)
        for p in inputs.pinned where byId[p.id] == nil {
            byId[p.id] = p
        }
        let durableIds = Set(inputs.durable.map(\.id))
        for d in inputs.durable {
            byId[d.id] = d
        }
        // Frozen D∪P snapshot for computedThreadId adoption (§2.1 step 3's
        // "compose has D ∪ P in hand, so the adoption is pure") — captured
        // BEFORE the S loop mutates `byId`, so adoption results don't depend
        // on the order `staged` happens to be enumerated in.
        let frozenDP = Array(byId.values)

        // MARK: Step 2 — S-row eligibility (§2.1a's audit-corrected table).
        var stagedIncludedIds: Set<String> = []
        for row in inputs.staged {
            guard query.displayedFolderIds.contains(row.folderId) else { continue }

            if let durable = inputs.stagedResolutions[row.headerId]?.durable {
                let stagedFolderId = row.folderId
                // detectStaleByMoveRows' EXACT predicate (NSEDataBridge.swift ~729).
                let staleByMove = durable.folderId != stagedFolderId || !durable.isInInbox
                if staleByMove {
                    continue // (b) SUPPRESS — durable truth wins.
                }
                if let existing = byId[durable.id] {
                    // (c) SUPPRESS as a separate row; AI carry-over onto the
                    // D/P row where its own AI fields are nil (relocated
                    // Pass-1 carry-over — ADR-IOS-049).
                    byId[durable.id] = applyAICarryOver(existing, from: row)
                    continue
                }
                // (d) durable same-folder-in-inbox, NOT in D ∪ P → falls
                // through to inclusion below (the headerComplete=0 window).
            }
            // (a) no durable header at all → falls through to inclusion.

            // Belt identity dedup (phantom-row fix, mirrors insertStagedRows):
            // matches the merge's (accountId, messageId)/(rfc822) identity,
            // not just headerId — protects against resolution staleness AND
            // two staged rows in this same batch sharing an identity.
            guard !isDuplicateIdentity(row, in: byId.values) else { continue }

            var header = row.toMessageHeader()
            if let adopted = adoptThreadId(for: row, from: frozenDP) {
                header.computedThreadId = adopted
            }
            let snapshot = MessageSnapshot(from: header)
            byId[snapshot.id] = snapshot
            stagedIncludedIds.insert(snapshot.id)
        }

        // MARK: Step 3 — overlay, applied uniformly to D, P, and S rows.
        var rows = applyOverlay(
            Array(byId.values), overlay: inputs.overlay, displayedFolderIds: query.displayedFolderIds
        )

        // MARK: Step 4 — filterUnread. D arrives pre-filtered (SQL, see the
        // `durable` doc comment above); P was pre-filtered by the shell
        // (mirrors insertUndoneMessages). Only S rows are re-filtered here,
        // POST-overlay, exactly like `insertStagedRows` does. This preserves
        // today's pre/post-overlay asymmetry on purpose — not a bug to fix.
        if query.filterUnread {
            rows.removeAll { stagedIncludedIds.contains($0.id) && $0.isRead }
        }

        // MARK: Step 5 — pagination cutoff. D arrives already cut by SQL
        // (`date < beforeDate`); apply the same cutoff to non-durable rows
        // (P and S) here.
        if let cutoff = query.beforeDate {
            rows.removeAll { !durableIds.contains($0.id) && $0.date >= cutoff }
        }

        // MARK: Step 6 — label filter, uniformly over D, P, and S. S rows
        // synthesize with `userLabels == []`, so an active label filter
        // always drops them — the deliberate unification called out in
        // PLAN_INBOX_UNIFIED_READ.md §2.1 step 3 (today's `insertStagedRows`
        // skips this filter entirely; the reader unifies it).
        if !query.filterLabelIds.isEmpty {
            rows = rows.filter { snapshot in
                query.filterLabelIds.isSubset(of: Set(snapshot.userLabels.map(\.id)))
            }
        }

        // MARK: Step 7 — sort (mode-aware), dedup by id, trim to window.
        switch query.mode {
        case .triage:
            rows.sort { a, b in
                if a.tagSortOrder != b.tagSortOrder { return a.tagSortOrder < b.tagSortOrder }
                return a.date > b.date
            }
        case .normal:
            rows.sort { $0.date > $1.date }
        }

        var seen: Set<String> = []
        seen.reserveCapacity(rows.count)
        rows.removeAll { !seen.insert($0.id).inserted }

        if rows.count > query.targetCount {
            rows = Array(rows.prefix(query.targetCount))
        }

        return rows
    }

    // MARK: - Helpers

    /// AI-field carry-over onto an existing D/P row (ADR-IOS-049), moved
    /// from `reloadMessages`' Pass-1 diff into the reader. Only fills fields
    /// that are currently nil on the target row — never clobbers a fresher
    /// AI result. `tagSortOrder` is mirrored alongside `actionTag` (matches
    /// `MessageSnapshot`'s `var` doc comment).
    private static func applyAICarryOver(_ existing: MessageSnapshot, from row: StagedInboxRow) -> MessageSnapshot {
        var updated = existing
        if updated.actionTag == nil, let rawTag = row.actionTag, let tag = ActionTag(rawValue: rawTag) {
            updated.actionTag = tag
            updated.tagSortOrder = tag.sortOrder
        }
        if updated.summaryBlurb == nil, let blurb = row.summaryBlurb {
            updated.summaryBlurb = blurb
        }
        return updated
    }

    /// `insertStagedRows`' identity-dedup check, ported verbatim: matches the
    /// merge's dedup identity — (accountId, messageId) then rfc822 fallback —
    /// not just headerId equality.
    private static func isDuplicateIdentity(
        _ row: StagedInboxRow, in snapshots: some Sequence<MessageSnapshot>
    ) -> Bool {
        snapshots.contains { snap in
            guard snap.accountId == row.accountId else { return false }
            if !row.messageId.isEmpty, snap.messageId == row.messageId { return true }
            if let rfc = row.rfc822MessageId, !rfc.isEmpty,
               let snapRfc = snap.rfc822MessageId, !snapRfc.isEmpty,
               rfc == snapRfc { return true }
            return false
        }
    }

    /// `insertStagedRows`' in-memory computedThreadId adoption, ported
    /// verbatim: a reply animates straight into its on-screen thread instead
    /// of appearing as a singleton and re-grouping when the durable reload
    /// lands with the real thread id.
    private static func adoptThreadId(for row: StagedInboxRow, from candidates: [MessageSnapshot]) -> String? {
        candidates.first { snap in
            guard snap.accountId == row.accountId, !snap.computedThreadId.isEmpty else { return false }
            if let tid = row.threadId, tid == snap.threadId { return true }
            if let rfc = snap.rfc822MessageId, !rfc.isEmpty,
               row.inReplyTo == rfc || row.references.contains(rfc) { return true }
            return false
        }?.computedThreadId
    }

    /// `applyOverlay`'s exact semantics, ported: field overrides + filter out
    /// rows whose overlay folderId left the displayed set. Applying this to a
    /// P row a second time (the shell already applied the same overlay entry
    /// once) is a harmless no-op re-assignment — overlay lookups key off
    /// `snapshot.id`, which for a P row is the durable header's own id and is
    /// unaffected by the overlay's target-folder values.
    private static func applyOverlay(
        _ snapshots: [MessageSnapshot],
        overlay: [String: AccountManager.PendingMutation],
        displayedFolderIds: Set<String>
    ) -> [MessageSnapshot] {
        guard !overlay.isEmpty else { return snapshots }
        return snapshots.compactMap { snapshot in
            guard let mutation = overlay[snapshot.id] else { return snapshot }
            if let newFolderId = mutation.folderId, !displayedFolderIds.contains(newFolderId) {
                return nil
            }
            var modified = snapshot
            if let v = mutation.isRead { modified.isRead = v }
            if let v = mutation.isFlagged { modified.isFlagged = v }
            if let v = mutation.actionTag { modified.actionTag = v }
            if let v = mutation.isInInbox { modified.isInInbox = v }
            return modified
        }
    }
}
