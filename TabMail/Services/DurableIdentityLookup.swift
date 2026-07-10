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
///   - `InboxListComposer` Phase 2b (unified reader, not yet landed)
/// A divergence reintroduces duplicate phantom rows (I5) or the
/// archived-resurrection bug (I1) the merge/reader dance exists to prevent.
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

    /// Resolves the durable header for `(accountId, messageId)`, falling
    /// back to `(accountId, rfc822MessageId)` ONLY when the primary lookup
    /// misses AND `rfc822MessageId` is non-nil and non-empty (catches IMAP
    /// UID remaps after a server-side MOVE — see NSEDataBridge's phase-2
    /// lookup doc comment). Returns `nil` when neither lookup finds a row
    /// (an ordinary new message, not yet durable).
    ///
    /// ONE SELECT per step, fetching all five columns — no second
    /// round-trip to pick up folder/inbox/rfc822 state after the id hit.
    static func find(
        db: Database,
        accountId: String,
        messageId: String,
        rfc822MessageId: String?
    ) throws -> DurableHeaderRef? {
        var row = try Row.fetchOne(db, sql: """
            SELECT id, folderId, folderPath, isInInbox, rfc822MessageId FROM messageHeader
            WHERE accountId = ? AND messageId = ?
            """, arguments: [accountId, messageId])
        if row == nil, let rfc822 = rfc822MessageId, !rfc822.isEmpty {
            row = try Row.fetchOne(db, sql: """
                SELECT id, folderId, folderPath, isInInbox, rfc822MessageId FROM messageHeader
                WHERE accountId = ? AND rfc822MessageId = ?
                """, arguments: [accountId, rfc822])
        }
        guard let row else { return nil }
        return DurableHeaderRef(
            id: row["id"],
            folderId: row["folderId"],
            folderPath: row["folderPath"],
            isInInbox: row["isInInbox"],
            rfc822MessageId: row["rfc822MessageId"]
        )
    }
}
