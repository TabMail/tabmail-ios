/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The NSE merge's durable-identity lookup, extracted to ONE shared helper so
/// the merge (`NSEDataBridge.verifyDurable` / `detectStaleByMoveRows` /
/// `performMerge` phase 1 / phase 2) and the upcoming unified inbox reader
/// (`InboxListComposer`, PLAN_INBOX_UNIFIED_READ.md §2.1/§2.1a) share the
/// EXACT SAME dedup identity by construction, not by convention.
///
/// This IS the merge's dedup identity AND (per PLAN_INBOX_UNIFIED_READ.md
/// §2.1a) the reader's S-row eligibility identity. §4.4 risk 1 names this
/// divergence explicitly: "Identity parity is load-bearing... Mitigation:
/// extract ONE shared identity-resolution helper used by BOTH the merge
/// lookups and the reader; contract tests on both." Any change to the
/// lookup order or fallback condition here MUST keep ALL of the following in
/// lockstep:
///   - `NSEDataBridge.verifyDurable`
///   - `NSEDataBridge.detectStaleByMoveRows`
///   - `NSEDataBridge.performMerge` phase 1 (header-only upsert)
///   - `NSEDataBridge.performMerge` phase 2 (body/AI upsert)
///   - `InboxListReader.gather` (unified reader S-row resolution)
///   - the IN-MEMORY comparator `isSameLogicalMessage` below —
///     `InboxListComposer.isDuplicateIdentity` and
///     `InboxViewModel.insertStagedRows`' inline dedup check
/// A divergence reintroduces duplicate phantom rows (I5) or the
/// archived-resurrection bug (I1) the merge/reader dance exists to prevent.
///
/// G3 audit fix: IMAP UIDs (`messageId`) are per-FOLDER, not per-account
/// (ADR-IOS-042 — "messageId is the UID"). A folder-blind `(accountId,
/// messageId)` lookup can therefore land on a DIFFERENT message that
/// happens to share a UID in another folder — not the same message moved.
/// The lookup order below is (1) exact-folder match first — unambiguous by
/// construction — then (2) the folder-blind match, REJECTED when both sides
/// carry a non-nil rfc822 identity that disagrees (provable non-match), then
/// (3) the rfc822 fallback.
enum DurableIdentityLookup {

    /// The durable `messageHeader` row (if any) matching a staged/incoming
    /// message's dedup identity. All five columns are carried so a single
    /// lookup serves every call site — some callers only need `id`, others
    /// need the folder/inbox/rfc822 state too (e.g. stale-by-move, AI
    /// carry-over folder scoping).
    struct DurableHeaderRef: Equatable, Sendable {
        let id: String
        let folderId: String
        let folderPath: String
        let isInInbox: Bool
        let rfc822MessageId: String?
    }

    /// Resolves the durable header for a staged/incoming message's identity,
    /// in three steps:
    ///
    /// 1. **Exact-folder match** — `(accountId, folderPath, messageId)`.
    ///    Unambiguous: IMAP UIDs are scoped per folder, so a hit here is
    ///    provably the same message.
    /// 2. **Folder-blind match** — `(accountId, messageId)`, ignoring
    ///    folder. Safe by default for Gmail/Graph, where `messageId` is
    ///    globally unique per account (a hit there IS the same message, and
    ///    its `rfc822MessageId` will agree with the caller's automatically).
    ///    For IMAP, folder-blind UID equality is NOT proof of identity —
    ///    two unrelated messages in two different folders can legitimately
    ///    share a UID. REJECTED (falls through to step 3) when BOTH sides
    ///    carry a non-nil, non-empty `rfc822MessageId` and they DISAGREE —
    ///    that's proof positive of two different messages, not a false
    ///    match this lookup should return. When either side's rfc822 is nil
    ///    (can't prove a difference), the folder-blind match is retained —
    ///    a deliberately conservative default that preserves today's
    ///    behavior when there's no evidence to reject it.
    /// 3. **rfc822 fallback** — `(accountId, rfc822MessageId)`, ONLY when
    ///    non-nil and non-empty. Catches IMAP UID remaps after a
    ///    server-side MOVE (see NSEDataBridge's phase-2 lookup doc comment).
    ///
    /// Returns `nil` when no step finds a row (an ordinary new message, not
    /// yet durable, OR a folder-blind hit that was rejected and had no
    /// rfc822 fallback to catch).
    ///
    /// At most 3 SELECTs, fetching all five columns each time — no second
    /// round-trip to pick up folder/inbox/rfc822 state after a hit.
    ///
    /// COST PER OUTCOME, stated per-step because the steps are SEQUENTIAL and a
    /// later step only runs because the earlier ones MISSED. ⚠️ This paragraph read
    /// *"The common case (step 1 or step 2, no rejection) is 1 SELECT"* until R16-7
    /// (corrected 2026-08-06) — false for step 2, which by construction costs the
    /// step-1 miss plus its own hit:
    ///   • step-1 hit (exact folder) — **1** SELECT. This is the true common case.
    ///   • step-2 hit (folder-blind, not rejected) — **2**.
    ///   • step-2 rejection then a step-3 hit, or step-3 hit outright — **3**.
    ///   • no row at all — **2** with no usable `rfc822MessageId` (step 3 is
    ///     short-circuited by its `let rfc822 …, !rfc822.isEmpty` guard), **3** with
    ///     one.
    /// Predicate for the upper bound, skipping comments so this text cannot satisfy
    /// it: `rg -c --pcre2 '^(?!\s*(///|//)).*Row\.fetchOne\(db, sql:'
    /// TabMail/Services/DurableIdentityLookup.swift` → **3**.
    ///
    /// ⚠️ DO NOT "FIX" THIS BY COLLAPSING THE THREE SELECTS INTO ONE. Preserving
    /// exact-folder PRECEDENCE and step 2's conditional rfc822-disagreement
    /// REJECTION in a single statement risks changing identity semantics, which is
    /// C3 territory. The count is the thing that was wrong, not the query.
    static func find(
        db: Database,
        accountId: String,
        folderPath: String,
        messageId: String,
        rfc822MessageId: String?
    ) throws -> DurableHeaderRef? {
        // Step 1: exact-folder match.
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, folderId, folderPath, isInInbox, rfc822MessageId FROM messageHeader
            WHERE accountId = ? AND folderPath = ? AND messageId = ?
            """, arguments: [accountId, folderPath, messageId]) {
            return DurableHeaderRef(
                id: row["id"], folderId: row["folderId"], folderPath: row["folderPath"],
                isInInbox: row["isInInbox"], rfc822MessageId: row["rfc822MessageId"]
            )
        }

        // Step 2: folder-blind match, with rfc822-mismatch rejection.
        if let row = try Row.fetchOne(db, sql: """
            SELECT id, folderId, folderPath, isInInbox, rfc822MessageId FROM messageHeader
            WHERE accountId = ? AND messageId = ?
            """, arguments: [accountId, messageId]) {
            let candidateRfc822: String? = row["rfc822MessageId"]
            let provablyDifferent: Bool = {
                guard let candidateRfc822, !candidateRfc822.isEmpty,
                      let rfc822MessageId, !rfc822MessageId.isEmpty else { return false }
                return candidateRfc822 != rfc822MessageId
            }()
            if !provablyDifferent {
                return DurableHeaderRef(
                    id: row["id"], folderId: row["folderId"], folderPath: row["folderPath"],
                    isInInbox: row["isInInbox"], rfc822MessageId: candidateRfc822
                )
            }
            // else: fall through to step 3 — do NOT return the false match.
        }

        // Step 3: rfc822 fallback (IMAP UID-remap after MOVE).
        if let rfc822 = rfc822MessageId, !rfc822.isEmpty,
           let row = try Row.fetchOne(db, sql: """
            SELECT id, folderId, folderPath, isInInbox, rfc822MessageId FROM messageHeader
            WHERE accountId = ? AND rfc822MessageId = ?
            """, arguments: [accountId, rfc822]) {
            return DurableHeaderRef(
                id: row["id"], folderId: row["folderId"], folderPath: row["folderPath"],
                isInInbox: row["isInInbox"], rfc822MessageId: row["rfc822MessageId"]
            )
        }

        return nil
    }

    /// The IN-MEMORY counterpart of `find`'s step-2 rejection, for the two
    /// call sites that dedup against rows already held in memory rather than
    /// querying `messageHeader` — `InboxListComposer.isDuplicateIdentity`
    /// (compose step 2's belt dedup) and `InboxViewModel.insertStagedRows`'
    /// inline identity check. Both used to do a bare `(accountId,
    /// messageId)`-then-rfc822-fallback match, which silently UNDID `find`'s
    /// G3 rejection one branch later: `find` can correctly return `nil` for a
    /// staged row (rejecting a cross-folder UID collision), but the OLD
    /// in-memory check would then still treat that staged row as a duplicate
    /// of the unrelated on-screen row sharing the same raw UID — suppressing
    /// a genuinely new message. Nonisolated + pure so it's callable from both
    /// the (`@MainActor`) VM and the composer's pure core.
    ///
    /// Semantics (any change here needs the truth table below re-verified —
    /// see `DurableIdentityLookupTests`'s `isSameLogicalMessage` truth-table
    /// coverage and DECISIONS.md ADR-IOS-055's G3 in-memory-comparator
    /// addendum):
    /// 1. Different `accountId` → `false` — never the same message across
    ///    accounts.
    /// 2. BOTH `rfc822MessageId` values non-nil AND non-empty → return rfc822
    ///    EQUALITY. Agreement proves the same message even across an IMAP
    ///    UID remap (server-side MOVE, differing `messageId`); disagreement
    ///    PROVES two different messages — a `messageId` match at that point
    ///    is meaningless, because IMAP UIDs are scoped per folder
    ///    (ADR-IOS-042), not per account.
    /// 3. Otherwise (either side's rfc822 is unknown — nil or empty, so a
    ///    difference can't be proven) → non-empty `messageId` equality,
    ///    today's conservative default, UNCHANGED by this fix.
    ///
    /// The ONLY behavior change vs. the old bare comparator: equal
    /// `messageId` + both-known-and-DISAGREEING rfc822 now returns `false`
    /// (previously `true`). Every previously-`true` case still returns
    /// `true`: a UID-remap duplicate (differing `messageId`, agreeing
    /// rfc822), a same-folder redelivery / Gmail dual-label (both equal), and
    /// a collision with rfc822 unknown on one side (conservative, equal
    /// `messageId`).
    static func isSameLogicalMessage(
        accountId: String,
        messageId: String,
        rfc822MessageId: String?,
        candidateAccountId: String,
        candidateMessageId: String,
        candidateRfc822MessageId: String?
    ) -> Bool {
        guard accountId == candidateAccountId else { return false }
        if let rfc822MessageId, !rfc822MessageId.isEmpty,
           let candidateRfc822MessageId, !candidateRfc822MessageId.isEmpty {
            return rfc822MessageId == candidateRfc822MessageId
        }
        guard !messageId.isEmpty else { return false }
        return messageId == candidateMessageId
    }
}
