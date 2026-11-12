/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The generic apply: one folder, one write transaction (ADR-IOS-111)
//
// Everything the apply decides on is read INSIDE the folder's write transaction:
// the folder row, the pending-operation snapshot and the recent completions
// (#106, Memory 127; source fence F3). No logging but debug-gated `print` inside.
//
// Per folder:
// - removals go through the ONE removal core (`deleteConfirmedGhostHeaders…`),
//   with the account-wide identity term when the ids are stable (no address epoch);
// - a record for a message the folder does not hold inserts it, unless the user's
//   own destructive action on it is pending or just completed;
// - a record for a message the folder holds merges its PRESENT fields; flags and
//   the server tag are kept back while the user's flag action is pending or just
//   completed;
// - every change kept back is put on the folder's re-read list
//   (`FolderChangeState.recheck`), read again on the next pass until it applies.
//   Over `SyncConfig.changeRecheckLimit` ids, the folder's catch-up is armed.

/// What one folder transaction wrote.
struct FolderChangeApplyResult {
    var newHeaders: [MessageHeader] = []
    var removedIds: [String] = []
    var discoveredParents: [String] = []
    var wroteRows = false
    var armedCatchUp = false
}

extension SyncEngine {

    nonisolated static func applyFolderChanges(_ changes: FolderChanges, db: Database) throws -> FolderChangeApplyResult {
        var result = FolderChangeApplyResult()
        guard let folder = try Folder.fetchOne(db, key: changes.folderId),
              folder.uidValidityResetPendingAt == nil else { return result }
        let accountId = folder.accountId

        // Shields, read INSIDE this transaction.
        let snapshot = try PendingOperationSnapshot.load(accountId: accountId, db: db)
        let recentlyCompleted = AccountManager.shared.liveRecentlyCompleted()

        var declined = Set<String>()
        var settled = Set<String>()

        // Removals: the one removal core, the union of every shield.
        let removal = try deleteConfirmedGhostHeadersReportingProtected(
            folderId: folder.id, folderPath: folder.path, accountId: accountId, folderRole: folder.role,
            ids: changes.removals, idsAreUniqueInAccount: changes.addressEpoch == nil,
            recentlyCompleted: recentlyCompleted, db: db)
        result.removedIds += removal.deleted
        result.wroteRows = !removal.deleted.isEmpty
        declined.formUnion(removal.protectedMessageIds)
        settled.formUnion(Set(changes.removals).subtracting(removal.protectedMessageIds))
        if DebugModeManager.isLoggingEnabled(), folder.role == .drafts, !removal.deleted.isEmpty {
            // Draft rekey visibility: Gmail mints a new message id on every draft
            // push, so the old one is reported removed (the matching insert below).
            print("[DraftRekey] change apply: removed drafts-folder rows \(removal.deleted) from \(folder.name)")
        }

        for record in changes.records {
            let applied = try applyChangeRecord(
                record, folder: folder, addressEpoch: changes.addressEpoch,
                snapshot: snapshot, recentlyCompleted: recentlyCompleted, result: &result, db: db)
            if applied { settled.insert(record.messageId) } else { declined.insert(record.messageId) }
        }

        // The re-read list: drop what applied, add what was kept back.
        var state = FolderChangeState(raw: folder.changeState)
        let before = state
        var recheck = state.recheck.filter { declined.contains($0) || !settled.contains($0) }
        for id in declined.sorted() where !recheck.contains(id) { recheck.append(id) }
        if recheck.count > SyncConfig.changeRecheckLimit {
            recheck = Array(recheck.prefix(SyncConfig.changeRecheckLimit))
            try markCatchUpLapse(folderId: folder.id, db: db)
            result.armedCatchUp = true
        }
        state.recheck = recheck
        if state != before {
            try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folder.id])
        }
        return result
    }

    /// Arm one folder's catch-up: the same lapse mark `lapseDeltaCursor` sets on
    /// every folder, for this folder only (ADR-IOS-107).
    nonisolated static func markCatchUpLapse(folderId: String, db: Database) throws {
        try db.execute(sql: """
            UPDATE folder SET catchUpState = CASE
                WHEN json_valid(catchUpState) THEN CASE
                    WHEN json_type(catchUpState) = 'object' THEN json_set(
                        catchUpState, '$.' || ?, COALESCE(json_extract(catchUpState, '$.' || ?), 0) + 1)
                    ELSE NULL END
                ELSE NULL END
            WHERE id = ? AND catchUpState IS NOT NULL
            """, arguments: [CatchUpLapse.countKey, CatchUpLapse.countKey, folderId])
    }

    /// One record in one folder. Returns false when a shield kept the change back.
    private nonisolated static func applyChangeRecord(
        _ record: ChangeRecord, folder: Folder, addressEpoch: Int?,
        snapshot: PendingOperationSnapshot, recentlyCompleted: [String: Date],
        result: inout FolderChangeApplyResult, db: Database
    ) throws -> Bool {
        let rfc822 = record.rfc822MessageId ?? record.header?.rfc822MessageId
        if var existing = try MessageHeader
            .filter(Column("messageId") == record.messageId && Column("folderId") == folder.id)
            .fetchOne(db) {
            return try mergeChangeRecord(
                record, into: &existing, folder: folder, addressEpoch: addressEpoch,
                snapshot: snapshot, recentlyCompleted: recentlyCompleted, result: &result, db: db)
        }
        // A partial record for a message this folder does not hold: nothing to update.
        guard let info = record.header else { return true }
        if snapshot.destructive.containsAnyKey(messageId: info.messageId, rfc822MessageId: rfc822) {
            // A pending destructive op owns this identity.
            return false
        }
        if recentlyCompleted[info.messageId] != nil {
            // The queue completed an op on this message within the TTL, so the
            // server state just read may be stale. 🚨 NOT removable: it is what
            // stops a just-completed message from reappearing in its source.
            return false
        }
        return try insertChangeRecord(info, record: record, folder: folder, snapshot: snapshot, result: &result, db: db)
    }

    /// The existing-row merge: PRESENT fields only; flags and the server tag
    /// under the flag shield; rfc822 and references always.
    private nonisolated static func mergeChangeRecord(
        _ record: ChangeRecord, into existing: inout MessageHeader, folder: Folder, addressEpoch: Int?,
        snapshot: PendingOperationSnapshot, recentlyCompleted: [String: Date],
        result: inout FolderChangeApplyResult, db: Database
    ) throws -> Bool {
        let rfc822 = record.rfc822MessageId ?? existing.rfc822MessageId
        existing.observedUidValidity = addressEpoch
        let shielded = snapshot.flag.containsAnyKey(messageId: record.messageId, rfc822MessageId: rfc822)
            || recentlyCompleted[record.messageId] != nil
        var keptBack = false
        if shielded {
            keptBack = (record.isRead.map { $0 != existing.isRead } ?? false)
                || (record.isFlagged.map { $0 != existing.isFlagged } ?? false)
                || (record.serverTag.map { $0 != existing.actionTag } ?? false)
        } else {
            if let isRead = record.isRead { existing.isRead = isRead }
            if let isFlagged = record.isFlagged { existing.isFlagged = isFlagged }
            if let serverTag = record.serverTag {
                if existing.actionTag != serverTag {
                    if DebugModeManager.isLoggingEnabled() {
                        print("[Sync] change apply: remote tag change for \(record.messageId): \(existing.actionTag?.rawValue ?? "nil") -> \(serverTag.rawValue)")
                    }
                    try MessageAICache.writeThrough(
                        accountId: folder.accountId, folderPath: folder.path,
                        rfc822MessageId: existing.rfc822MessageId, actionTag: serverTag, db: db)
                }
                existing.actionTag = serverTag
                existing.tagSortOrder = serverTag.sortOrder
            }
        }
        if let rfc822 = record.rfc822MessageId { existing.rfc822MessageId = rfc822 }
        if let references = record.references { existing.referencesJSON = MessageHeader.encodeReferences(references) }
        try existing.update(db)
        result.wroteRows = true
        return !keptBack
    }

    /// The insert arm: the header builder, AI-cache restore, reply-detect, orphan
    /// reclaim, Drafts/Sent placeholder dedup (with label and body carry), the
    /// references and user-label rows, and the Sent reply-parent mark.
    private nonisolated static func insertChangeRecord(
        _ info: MessageHeaderInfo, record: ChangeRecord, folder: Folder, snapshot: PendingOperationSnapshot,
        result: inout FolderChangeApplyResult, db: Database
    ) throws -> Bool {
        let accountId = folder.accountId
        if folder.role == .drafts, DebugModeManager.isLoggingEnabled() {
            print("[DraftRekey] change apply: inserting drafts-folder header messageId=\(info.messageId) into \(folder.name)")
        }
        var header = MessageHeader(
            messageId: info.messageId,
            subject: info.subject,
            from: info.from,
            fromAddress: info.fromAddress,
            to: info.to,
            date: info.date,
            snippet: EmailFilter.cleanSnippet(info.snippet),
            folderId: folder.id,
            accountId: accountId,
            folderPath: folder.path,
            isInInbox: folder.role == .inbox,
            providerDate: info.providerOrderDate
        )
        header.rfc822MessageId = info.rfc822MessageId
        header.inReplyTo = info.inReplyTo
        header.referencesJSON = MessageHeader.encodeReferences(info.references)
        header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: accountId, subject: header.subject)
        try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: info.threadId, db: db)
        header.replyTo = info.replyTo
        header.cc = info.cc
        header.bcc = info.bcc
        header.isRead = info.isRead
        header.isFlagged = info.isFlagged
        header.hasAttachments = info.hasAttachments
        header.isReplied = info.isReplied
        header.isForwarded = info.isForwarded
        header.actionTag = info.actionTag
        header.tagSortOrder = info.actionTag?.sortOrder ?? 99
        try MessageAICache.restoreIfCached(into: &header, accountId: accountId, folderPath: folder.path, db: db)
        // ReplyDetect: an already-replied message tagged "reply" becomes "none".
        // The AI cache keeps the model's value; only the row and the server tag change.
        if header.isReplied && header.actionTag == .reply {
            header.actionTag = ActionTag.none
            header.tagSortOrder = ActionTag.none.sortOrder
            var tagOp = PendingOperation(
                type: .setTag, messageIds: [header.stableId], accountId: accountId,
                folderPath: folder.path, tagValue: ActionTag.none.rawValue)
            try tagOp.insert(db)
            if DebugModeManager.isLoggingEnabled() {
                print("[ReplyDetect] change insert: reply→none for \(header.messageId) (already replied)")
            }
        }

        // An orphaned row with the same id but another folderId (left by a no-op
        // optimistic move, e.g. archive from All Mail on Gmail) is taken over.
        // `header.id` encodes the folder path, so two folders never collide.
        if var orphaned = try MessageHeader.fetchOne(db, key: header.id) {
            // A destructive op queued on it makes the user's optimistic folder
            // authoritative until it drains.
            if snapshot.destructive.containsAnyKey(messageId: orphaned.messageId, rfc822MessageId: orphaned.rfc822MessageId) {
                return false
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[Sync] change apply reclaiming orphaned row \(header.id): folderId \(orphaned.folderId) → \(folder.id)")
            }
            orphaned.folderId = folder.id
            orphaned.folderPath = folder.path
            orphaned.observedUidValidity = nil
            orphaned.isInInbox = folder.role == .inbox
            orphaned.messageId = header.messageId
            orphaned.isRead = header.isRead
            orphaned.isFlagged = header.isFlagged
            orphaned.date = header.date
            orphaned.providerDate = header.providerDate
            orphaned.from = header.from
            orphaned.fromAddress = header.fromAddress
            orphaned.to = header.to
            orphaned.cc = header.cc
            orphaned.bcc = header.bcc
            orphaned.replyTo = header.replyTo
            orphaned.rfc822MessageId = header.rfc822MessageId
            orphaned.isReplied = orphaned.isReplied || header.isReplied
            orphaned.isForwarded = orphaned.isForwarded || header.isForwarded
            orphaned.subject = header.subject
            orphaned.snippet = header.snippet
            orphaned.hasAttachments = header.hasAttachments
            orphaned.actionTag = header.actionTag
            orphaned.tagSortOrder = header.tagSortOrder
            try orphaned.update(db)
            result.newHeaders.append(orphaned)
            result.wroteRows = true
            return true
        }

        // Drafts and Sent: the optimistic placeholder with the same rfc822 is
        // replaced. Its body and its user-label membership are carried: the
        // `messageUserLabel` rows cascade with the deleted header, and the
        // incoming label set can be empty before the label catalog loads or miss
        // a label whose op has not drained. The body carry rests on the same
        // `(folderId, rfc822MessageId, messageId <> …)` match.
        var deferredBody: MessageBody?
        var carriedUserLabelIds: [String] = []
        if folder.role == .drafts || folder.role == .sent,
           let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
           let optimistic = try MessageHeader.fetchOne(
            db, sql: optimisticDedupSQL, arguments: [folder.id, rfc822, header.messageId]) {
            let oldId = optimistic.id
            carriedUserLabelIds = try MessageUserLabel
                .filter(Column("messageId") == oldId)
                .fetchAll(db)
                .map(\.userLabelId)
            if let body = try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) {
                var newBody = body
                newBody.id = ContentKey(rawValue: header.id)
                try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldId))
                deferredBody = newBody
            }
            result.removedIds.append(oldId)
            try optimistic.delete(db)
            if DebugModeManager.isLoggingEnabled() {
                print("[Sync] change apply dedup: replaced optimistic \(folder.role.rawValue) header \(oldId) with \(header.id)")
            }
        }
        // The orphan check above established inside THIS transaction that no row
        // occupies `header.id`; snapshot isolation and the single writer keep it
        // so until the insert. A colliding insert would throw UNIQUE and roll back
        // this folder's transaction; the bookmark is written later, so the next
        // pass reads the same changes again.
        try header.insert(db)
        if let deferredBody { try deferredBody.insert(db) }
        try ThreadUtils.insertMessageReferences(for: header, db: db)

        for labelId in record.userLabelIds ?? info.userLabelIds {
            let labelRow = UserLabel(accountId: accountId, providerLabelId: labelId, name: labelId, isSystem: false)
            try labelRow.insert(db, onConflict: .ignore)
            // The join FK is `userLabel.id`, the account-prefixed surrogate (IOS-LABEL-001).
            try MessageUserLabel(messageId: header.id, userLabelId: labelRow.id)
                .insert(db, onConflict: .ignore)
        }
        for carriedUserLabelId in carriedUserLabelIds {
            try MessageUserLabel(messageId: header.id, userLabelId: carriedUserLabelId)
                .insert(db, onConflict: .ignore)
        }
        result.newHeaders.append(header)
        result.wroteRows = true

        // Sent-folder reply discovery; a no-op for any other folder.
        result.discoveredParents += try ReplyParentResolver.markParentsReplied(
            inReplyTos: [info.inReplyTo], folderRole: folder.role, accountId: accountId, db: db)
        return true
    }
}
