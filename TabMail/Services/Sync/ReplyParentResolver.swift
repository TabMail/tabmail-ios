/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// When sync ingests a Sent-folder message whose `In-Reply-To` points at a
/// locally-stored message, that means the user replied to the parent from
/// some other client (TB, Gmail web, native Mail). The parent's `isReplied`
/// must be flipped locally so the inbox row shows the curl-arrow indicator,
/// the "Reply" action tag clears, and the LLM tool readers see "replied: yes".
///
/// Server-side `\Answered` is intentionally NOT written back — the reply
/// already exists on the server, whichever client sent it had its own chance
/// to set the flag. See the retired
/// `recoverRepliedFlags` (project memory `project_recover_replied_flags_retired.md`)
/// for the rationale.
///
/// The OR-merge at SyncEngineFullSync.swift:554
/// (`existing.isReplied = existing.isReplied || info.isReplied`) is what makes
/// this safe to make local-only — no future sync of the parent's folder can
/// regress us from `true` back to `false`.
enum ReplyParentResolver {

    /// Within an open write transaction, mark local parent messages as replied
    /// when the just-inserted batch represents outgoing replies. Caller passes
    /// raw `In-Reply-To` values from the batch — the helper normalizes, dedups,
    /// and gates on folder role. Cheap when folder is not Sent: early returns
    /// without touching the DB.
    ///
    /// Returns the list of parent header IDs that were updated, for caller-side
    /// `.messageDataDidChange` notification fan-out AFTER the transaction commits.
    static func markParentsReplied(
        inReplyTos: [String?],
        folderRole: FolderRole,
        accountId: String,
        db: Database
    ) throws -> [String] {
        guard folderRole == .sent else { return [] }
        guard !inReplyTos.isEmpty else { return [] }

        // Normalize defensively. IMAPProvider normalizes at the boundary
        // (IMAPProvider.swift:1922) but Gmail/Exchange providers pass raw
        // metadata through — `normalizeMessageId` is idempotent so this costs
        // nothing when the value was already normalized.
        let normalized: Set<String> = Set(
            inReplyTos
                .compactMap { $0.map(EmailFilter.normalizeMessageId) }
                .filter { !$0.isEmpty }
        )
        guard !normalized.isEmpty else { return [] }

        // One SELECT for all candidate parents in this account that aren't
        // already marked. The `isReplied = 0` filter avoids no-op writes and
        // prevents re-firing the tag-clear PendingOperation on already-marked
        // rows. Index-backed via `messageHeader_rfc822MessageId`
        // (AppDatabase.swift:349).
        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ",")
        let sql = """
            SELECT id, actionTag
            FROM messageHeader
            WHERE accountId = ?
              AND rfc822MessageId IN (\(placeholders))
              AND isReplied = 0
            """
        var args: [any DatabaseValueConvertible] = [accountId]
        for value in normalized { args.append(value) }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var updated: [String] = []
        for row in rows {
            let id: String = row["id"]
            let actionTagRaw: String? = row["actionTag"]
            let actionTag = actionTagRaw.flatMap(ActionTag.init(rawValue:))

            try db.execute(
                sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?",
                arguments: [id]
            )

            // The user's actual reply makes any "Reply" suggestion obsolete.
            // Action tags are local-only (ADR-IOS-036), so this is solely a
            // MessageHeader update and never admits a durable provider job.
            let clearedReplyTag = (actionTag == .reply)
            if clearedReplyTag {
                try db.execute(
                    sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, actionTagSetAt = ? WHERE id = ?",
                    arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, Date(), id]
                )
            }

            updated.append(id)
            print("[ReplyDetect] SentDiscover: marked parent \(id) as replied\(clearedReplyTag ? " (cleared .reply tag)" : "")")
        }

        return updated
    }

    /// One-shot historic backfill: flip `isReplied` (and clear stale `.reply`
    /// action tag) on every local parent whose `rfc822MessageId` is the
    /// `inReplyTo` of some local Sent-folder reply. Called exactly once via
    /// the v53 GRDB migration in `AppDatabase`.
    ///
    /// Local-only — no `PendingOperation(.setTag)` queued. Per ADR-IOS-036
    /// action tags are local-only; mirroring the going-forward `markParents-
    /// Replied` queue behavior here would flood the queue with potentially
    /// thousands of historic ops.
    ///
    /// Returns the number of parent rows updated, for logging.
    @discardableResult
    static func runHistoricBackfill(db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE messageHeader
            SET isReplied = 1,
                actionTag = CASE WHEN actionTag = 'reply' THEN 'none' ELSE actionTag END,
                tagSortOrder = CASE WHEN actionTag = 'reply' THEN 1 ELSE tagSortOrder END
            WHERE isReplied = 0
              AND rfc822MessageId IS NOT NULL
              AND rfc822MessageId != ''
              AND id IN (
                SELECT m.id
                FROM messageHeader m
                JOIN messageHeader r ON r.inReplyTo = m.rfc822MessageId
                                    AND r.accountId = m.accountId
                JOIN folder f ON f.id = r.folderId
                WHERE f.role = 'sent'
                  AND r.inReplyTo IS NOT NULL
                  AND r.inReplyTo != ''
              )
            """)
        return db.changesCount
    }

    /// Post `.messageDataDidChange` per parent ID (threshold-gated via
    /// `SyncConfig.sentDiscoverNotifyPerIdLimit` to avoid notification storms
    /// on first-ever Sent-folder syncs) plus one `.inboxDataDidChange`. Call
    /// AFTER the GRDB write transaction commits.
    static func postParentNotifications(_ parentIds: [String]) {
        guard !parentIds.isEmpty else { return }
        if parentIds.count <= SyncConfig.sentDiscoverNotifyPerIdLimit {
            for id in parentIds {
                NotificationCenter.default.post(name: .messageDataDidChange, object: id)
            }
        } else {
            print("[ReplyDetect] Skipping per-ID fan-out (\(parentIds.count) > \(SyncConfig.sentDiscoverNotifyPerIdLimit)) — relying on inboxDataDidChange")
        }
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
    }
}
