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
    /// Ids to drop AFTER S-eligibility/carry-over decisions but BEFORE
    /// sort/trim (F2 audit fix). `fetchPage` passes the VM's `loadedIds` so
    /// an already-on-screen row can't eat a `targetCount` trim slot from a
    /// not-yet-loaded one — restores the pre-refactor dedup-BEFORE-prefix
    /// ordering, which matters because the triage-mode sort is not
    /// date-monotonic. `fetchFullRange` passes `[]`: a full-range reload's
    /// diff MUST include already-loaded rows (that's the point of the diff).
    let excludeIds: Set<String>

    init(
        displayedFolderIds: Set<String>,
        filterUnread: Bool,
        filterLabelIds: Set<String>,
        mode: InboxMode,
        targetCount: Int,
        beforeDate: Date?,
        excludeIds: Set<String> = []
    ) {
        self.displayedFolderIds = displayedFolderIds
        self.filterUnread = filterUnread
        self.filterLabelIds = filterLabelIds
        self.mode = mode
        self.targetCount = targetCount
        self.beforeDate = beforeDate
        self.excludeIds = excludeIds
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
        // BEFORE the S loop mutates `byId`, so the D∪P PART of adoption
        // doesn't depend on the order `staged` happens to be enumerated in.
        let frozenDP = Array(byId.values)
        // F4 audit fix: the adoption pool starts as `frozenDP` (kept frozen,
        // above, for that part's determinism) but GROWS as each S row is
        // synthesized below, so a same-batch staged reply-to-a-staged-sibling
        // can chain-adopt — old `insertStagedRows` adopted from the growing
        // `loadedMessages` array, so a reply landing in the same batch as its
        // parent could already adopt the parent's thread. Only a row that
        // itself carries a non-empty adopted `computedThreadId` is appended
        // (see the `!snapshot.computedThreadId.isEmpty` check below) — matches
        // `adoptThreadId`'s own source-eligibility guard, so a staged row with
        // no thread relation of its own can't be adopted from. NOTE this
        // makes later-in-`staged` rows depend on earlier ones' input order —
        // that input-order dependence matches OLD behavior (insertion order
        // = batch order), not a new one introduced here.
        var adoptionPool = frozenDP

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
            if let adopted = adoptThreadId(for: row, from: adoptionPool) {
                header.computedThreadId = adopted
            }
            let snapshot = MessageSnapshot(from: header)
            byId[snapshot.id] = snapshot
            stagedIncludedIds.insert(snapshot.id)
            // Grow the pool (F4) — only if THIS row itself adopted (or
            // otherwise carries) a non-empty computedThreadId, so it's a
            // valid source for a later same-batch S row to chain-adopt from.
            if !snapshot.computedThreadId.isEmpty {
                adoptionPool.append(snapshot)
            }
        }

        // MARK: Step 2.5 — drop already-loaded ids (F2 audit fix). Runs AFTER
        // the S-eligibility loop above, so an excluded durable row still
        // correctly suppresses its staged duplicate via the (c) `byId`
        // membership check (identity is on screen either way — suppression
        // is about not double-rendering the identity, which holds regardless
        // of whether the winning row is about to be excluded here) — but
        // BEFORE sort/trim (step 7), so an old already-loaded row can't eat a
        // `targetCount` trim slot that a not-yet-loaded row needs. This is
        // the exact old dedup-BEFORE-prefix ordering `fetchPage` used to have.
        if !query.excludeIds.isEmpty {
            for id in query.excludeIds { byId.removeValue(forKey: id) }
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
        // G2 audit fix (PLAN_INBOX_UNIFIED_READ.md): every comparator ends in
        // a total-order `id` tie-break. `byId.values` (step 1) iterates a
        // Swift `Dictionary` — its order is NOT a function of insertion
        // order alone and is not guaranteed stable across otherwise-identical
        // composes. Without a final tie-break, rows that compare EQUAL on
        // date (and tagSortOrder, in triage) can land on either side of the
        // `targetCount` trim depending on that incidental iteration order —
        // a tied row appears on one reload and disappears on the next, with
        // nothing in the underlying data having changed (trim-boundary
        // churn). `id` is unique per row and stable, so it's a safe total
        // order to fall back to.
        switch query.mode {
        case .triage:
            rows.sort { a, b in
                if a.tagSortOrder != b.tagSortOrder { return a.tagSortOrder < b.tagSortOrder }
                if a.date != b.date { return a.date > b.date }
                return a.id < b.id
            }
        case .normal:
            rows.sort { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.id < b.id
            }
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

    /// `insertStagedRows`' identity-dedup check, ported: matches the merge's
    /// dedup identity, not just headerId equality. Thin wrapper over
    /// `DurableIdentityLookup.isSameLogicalMessage` — the G3-hardened
    /// in-memory comparator shared with `InboxViewModel.insertStagedRows`'
    /// inline check, so a bare (accountId, messageId) collision with an
    /// on-screen row (e.g. a P row pinned in from another folder — IMAP UIDs
    /// are per-folder, ADR-IOS-042) can no longer suppress a genuinely
    /// different staged message when both sides' rfc822 identities are known
    /// and disagree. See `DurableIdentityLookup.isSameLogicalMessage`'s doc
    /// comment for the full truth table and DECISIONS.md ADR-IOS-055's G3
    /// in-memory-comparator addendum.
    private static func isDuplicateIdentity(
        _ row: StagedInboxRow, in snapshots: some Sequence<MessageSnapshot>
    ) -> Bool {
        snapshots.contains { snap in
            DurableIdentityLookup.isSameLogicalMessage(
                accountId: row.accountId, messageId: row.messageId, rfc822MessageId: row.rfc822MessageId,
                candidateAccountId: snap.accountId, candidateMessageId: snap.messageId,
                candidateRfc822MessageId: snap.rfc822MessageId
            )
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
