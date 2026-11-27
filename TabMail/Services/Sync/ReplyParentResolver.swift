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
/// A copy whose subject starts with a forward prefix is a forward, not a reply
/// (some apps set In-Reply-To on a forward): its parent gets `isForwarded`
/// instead, and keeps its "Reply" tag (`markParentsReplied`).
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

    /// A message synced into a Sent folder, as the resolver reads it: the message
    /// its `In-Reply-To` names, and its subject.
    struct SentCopy: Sendable {
        let inReplyTo: String?
        let subject: String

        /// Whether this copy is a forward, not a reply: its subject starts with a
        /// forward prefix (`ThreadUtils.hasForwardPrefix`), whatever its
        /// `In-Reply-To` says. The one rule every reader of a stored Sent copy
        /// applies: `markParentsReplied` marks such a copy's parent forwarded
        /// instead of replied, and `hasStoredReply` does not count it as a reply.
        var isForward: Bool { ThreadUtils.hasForwardPrefix(subject) }
    }

    /// Within an open write transaction, mark the local parent messages the
    /// just-inserted Sent copies answer: replied for a reply, forwarded for a
    /// forward. Caller passes the batch's raw `In-Reply-To` values with their
    /// subjects — the helper normalizes, dedups, and gates on folder role. Cheap
    /// when folder is not Sent: early returns without touching the DB.
    ///
    /// A copy whose subject starts with a forward prefix
    /// (`SentCopy.isForward`) is a forward even though it names its
    /// original in `In-Reply-To`: Thunderbird sets `In-Reply-To` on every forward
    /// (it derives it from References whatever the compose kind). Its original is
    /// marked forwarded, never replied, and keeps its "Reply" tag: the user has not
    /// answered it. TabMail's own forwards carry no `In-Reply-To`
    /// (`ThreadUtils.outgoingThreadHeaders`), so this reads other apps' copies.
    ///
    /// Returns the list of parent header IDs that were updated, for caller-side
    /// `.messageDataDidChange` notification fan-out AFTER the transaction commits.
    static func markParentsReplied(
        sentCopies: [SentCopy],
        folderRole: FolderRole,
        accountId: String,
        db: Database
    ) throws -> [String] {
        guard folderRole == .sent else { return [] }
        guard !sentCopies.isEmpty else { return [] }

        // Normalize defensively. Every provider already hands In-Reply-To over
        // bare (IMAP's `IMAPProvider.mapMessageInfo` through `normalizeMessageId`,
        // Gmail and RFC 822 parsing through `extractFirstMessageId`; Graph gives
        // none), and `normalizeMessageId` is idempotent, so this costs nothing
        // when the value was already normalized.
        var replied = Set<String>()
        var forwarded = Set<String>()
        for copy in sentCopies {
            guard let raw = copy.inReplyTo else { continue }
            let parent = EmailFilter.normalizeMessageId(raw)
            guard !parent.isEmpty else { continue }
            if copy.isForward {
                forwarded.insert(parent)
            } else {
                replied.insert(parent)
            }
        }
        let normalized = replied.union(forwarded)
        guard !normalized.isEmpty else { return [] }

        // One SELECT for all candidate parents in this account that aren't
        // already marked both ways. The `isReplied = 0 OR isForwarded = 0` filter
        // and the per-row checks below avoid no-op writes and prevent re-firing
        // the tag-clear PendingOperation on already-marked rows. Index-backed:
        // the production statement's explicit `INDEXED BY`
        // forces `messageHeader_rfc822MessageId` (`rfc822MessageId=?`) regardless
        // of statistics; the planner cannot substitute the date, account, or
        // folder indexes.
        //
        // ⚠️ CORRECTED 2026-08-05: this previously read "Index-backed via
        // `messageHeader_rfc822MessageId` (AppDatabase.swift:349)". That line number
        // is a COLUMN LIST (`"inReplyTo TEXT",`) — at the release base and at HEAD
        // alike — not an index declaration. Cite indexes by NAME; a `file:line`
        // anchor into a file as edited as `AppDatabase.swift` rots on the next
        // migration (MIS-009).
        let sql = parentLookupSQL(count: normalized.count)
        var args: [any DatabaseValueConvertible] = [accountId]
        for value in normalized { args.append(value) }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

        var updated: [String] = []
        for row in rows {
            let id: String = row["id"]
            let messageId: String = row["messageId"]
            let rowRfc822: String? = row["rfc822MessageId"]
            let folderPath: String = row["folderPath"]
            let parentAccountId: String = row["accountId"]
            let actionTagRaw: String? = row["actionTag"]
            let actionTag = actionTagRaw.flatMap(ActionTag.init(rawValue:))
            let wasReplied: Bool = row["isReplied"]
            let wasForwarded: Bool = row["isForwarded"]

            // The row matched one of `normalized` by rfc822MessageId.
            let marksReplied = !wasReplied && rowRfc822.map(replied.contains) == true
            let marksForwarded = !wasForwarded && rowRfc822.map(forwarded.contains) == true
            guard marksReplied || marksForwarded else { continue }

            if marksForwarded {
                // A forward leaves the original's replied mark and "Reply" tag alone.
                try db.execute(
                    sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?",
                    arguments: [id]
                )
                if DebugModeManager.isLoggingEnabled() {
                    print("[ReplyDetect] SentDiscover: marked parent \(id) as forwarded")
                }
            }
            guard marksReplied else {
                updated.append(id)
                continue
            }

            // Mirror MessageHeader.stableId: prefer rfc822 for numeric UIDs (IMAP),
            // else messageId (Gmail/Exchange already have stable IDs).
            let stableId: String = {
                if UInt32(messageId) != nil, let rfc822 = rowRfc822, !rfc822.isEmpty {
                    return rfc822
                }
                return messageId
            }()

            try db.execute(
                sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?",
                arguments: [id]
            )

            // Mirror the existing ReplyDetect tag-clear at
            // SyncEngineFullSync.swift:617-630: the user's actual reply makes
            // any "Reply" suggestion tag obsolete, and the local clear must
            // be mirrored to the server via setTag.
            let clearedReplyTag = (actionTag == .reply)
            if clearedReplyTag {
                // Raw SQL (not `MessageHeader.setActionTag`) because this loop
                // works off a projected `Row`, never a materialised header — so
                // it stamps `actionTagSetAt` explicitly to keep the invariant
                // `actionTag != nil ⇒ actionTagSetAt != nil`. `ActionTag.none`
                // is the real tag VALUE "none", not Optional.none, so this is a
                // tag ASSIGNMENT and must carry a fresh stamp.
                try db.execute(
                    sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ?, actionTagSetAt = ? WHERE id = ?",
                    arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, Date(), id]
                )
                var setTagOp = PendingOperation(
                    type: .setTag,
                    messageIds: [stableId],
                    accountId: parentAccountId,
                    folderPath: folderPath,
                    tagValue: ActionTag.none.rawValue
                )
                try setTagOp.insert(db)
            }

            updated.append(id)
            if DebugModeManager.isLoggingEnabled() {
                print("[ReplyDetect] SentDiscover: marked parent \(id) as replied\(clearedReplyTag ? " (cleared .reply tag)" : "")")
            }
        }

        return updated
    }

    /// Within an open write transaction, after a batch of rows was inserted in
    /// any folder: mark the inserted rows that a reply or forward already stored in
    /// a Sent folder of the same account answers. This is the parent-side direction
    /// of `markParentsReplied` (which runs when the copy is inserted): a parent
    /// that loads after its reply shows as replied too, as on Gmail. The marking
    /// itself (`isReplied`, the `.reply` tag clear, the queued `setTag`, or
    /// `isForwarded` for a forward) is `markParentsReplied`'s, fed the stored
    /// copies' `inReplyTo` values and subjects. No query runs when nothing was
    /// inserted. Index-backed by `messageHeader_inReplyTo`.
    ///
    /// Returns the parent header IDs updated, for `postParentNotifications`.
    static func markInsertedParentsOfStoredReplies(
        insertedRfc822Ids: [String],
        accountId: String,
        db: Database
    ) throws -> [String] {
        let normalized = Set(insertedRfc822Ids.map(EmailFilter.normalizeMessageId).filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return [] }
        let chunkSize = SyncConfig.backfillInsertChunkSize
        let ids = Array(normalized)
        var copies: [SentCopy] = []
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let slice = Array(ids[start..<min(start + chunkSize, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            var args: [any DatabaseValueConvertible] = [accountId, FolderRole.sent.rawValue]
            for value in slice { args.append(value) }
            // Named index: where the stored mail has no In-Reply-To (Outlook stores
            // none), ANALYZE counts all its rows under one value and the planner read
            // every row of each Sent folder instead (#1563). The index is
            // migration-built (v13), never deferred or dropped.
            copies += try Row.fetchAll(db, sql: """
                SELECT DISTINCT r.inReplyTo, r.subject
                FROM messageHeader r INDEXED BY messageHeader_inReplyTo JOIN folder f ON f.id = r.folderId
                WHERE r.accountId = ? AND f.role = ? AND r.inReplyTo IN (\(placeholders))
                """, arguments: StatementArguments(args)).map { SentCopy(inReplyTo: $0["inReplyTo"], subject: $0["subject"]) }
        }
        return try markParentsReplied(sentCopies: copies, folderRole: .sent, accountId: accountId, db: db)
    }

    /// Whether a reply to the message whose Message-ID is `rfc822MessageId` is
    /// stored in a Sent folder of `accountId`: a copy there that names it in
    /// `In-Reply-To` and is not a forward (`SentCopy.isForward`), the evidence
    /// the two functions above mark a parent replied by. Another app's forward
    /// that names the message in `In-Reply-To` marks it forwarded there, so it
    /// is no reply here either. The unsent-removal revert asks it
    /// (`AccountManager.revertQueuedOriginalChanges`, #1490) so a reply the user
    /// sent from another client while TabMail's reply waited keeps the original
    /// replied. It only ever stops a change, so a Message-ID shared by several
    /// messages never chooses one to change (ADR-IOS-068 D4).
    ///
    /// Forced onto `messageHeader_inReplyTo`, it visits only the stored rows
    /// naming this one Message-ID in `In-Reply-To` (that message's replies and
    /// the forwards that name it, in any account or folder: a number that does
    /// not grow with the mailbox) and reads the subjects of those in this
    /// account's Sent, since the forward rule is Swift's. Every writer stores In-Reply-To
    /// normalized (Gmail and RFC 822 parsing through
    /// `EmailFilter.extractFirstMessageId`; IMAP's envelope mapping and the
    /// extension's `IMAPFetchMapping` through `EmailFilter.normalizeMessageId`;
    /// the optimistic Sent copy; Graph stores none), so the bare form is the only
    /// one matched, as `markInsertedParentsOfStoredReplies` matches it.
    static func hasStoredReply(
        toRfc822MessageId rfc822MessageId: String?,
        accountId: String,
        db: Database
    ) throws -> Bool {
        let normalized = rfc822MessageId.map(EmailFilter.normalizeMessageId) ?? ""
        guard !normalized.isEmpty else { return false }
        let subjects = try String.fetchAll(db, sql: """
            SELECT r.subject
            FROM messageHeader r INDEXED BY messageHeader_inReplyTo
            JOIN folder f ON f.id = r.folderId
            WHERE r.inReplyTo = ? AND r.accountId = ? AND f.role = ?
            """, arguments: [normalized, accountId, FolderRole.sent.rawValue])
        return subjects.contains { !SentCopy(inReplyTo: normalized, subject: $0).isForward }
    }

    /// The set lookup executed by `markParentsReplied`, named so plan coverage
    /// cannot drift from production's predicates or projection.
    static func parentLookupSQL(count: Int) -> String {
        let placeholders = Array(repeating: "?", count: count).joined(separator: ",")
        // stableId is a Swift-side computed property on MessageHeader (rfc822 if
        // messageId is a numeric UID, else messageId) — fetch the inputs and
        // recompute in Swift rather than rely on a SQL column.
        return """
            SELECT id, messageId, rfc822MessageId, folderPath, accountId, actionTag, isReplied, isForwarded
            FROM messageHeader INDEXED BY messageHeader_rfc822MessageId
            WHERE accountId = ?
              AND rfc822MessageId IN (\(placeholders))
              AND (isReplied = 0 OR isForwarded = 0)
            """
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
    /// Deliberately does NOT stamp `actionTagSetAt` (unlike the going-forward
    /// `markParentsReplied` path above): this runs inside migration v53, and on a
    /// fresh install the `actionTagSetAt` column does not exist yet — v81 adds it
    /// afterwards, and it cannot be stamped before it exists.
    ///
    /// ⚠️ Updated 2026-08-05: v81 used to backfill a stamp onto every already-tagged
    /// row (which covered the rows this writes, because the `'none'` it assigns is
    /// NOT NULL in SQL). That backfill is GONE — v81 is schema-only now. So these
    /// rows carry `actionTag != nil` with a NULL `actionTagSetAt`, which is the
    /// documented LEGACY-ROW state: `SyncEngine.sweepStaleActionTags`
    /// treats a NULL stamp as already expired, so such a tag is reclaimed on the
    /// next maintenance pass once the message has left the inbox, rather than after
    /// a further TTL. That is the intended fail-safe direction, and it is the same
    /// direction TB's `purgeExpiredActionEntries` takes (ADR-IOS-008). The
    /// going-forward invariant `actionTag != nil ⇒ actionTagSetAt != nil` is
    /// enforced by `MessageHeader.setActionTag` and still holds for every writer
    /// after v81; this v53-era path is not one of them.
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
            BackgroundSyncLogger.logDebug("[ReplyDetect] Skipping per-ID fan-out (\(parentIds.count) > \(SyncConfig.sentDiscoverNotifyPerIdLimit)) — relying on inboxDataDidChange")
        }
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
    }
}
