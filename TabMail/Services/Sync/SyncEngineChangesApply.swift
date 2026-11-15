/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The generic apply: one folder, one write transaction (ADR-IOS-111)
//
// Everything the apply decides on is read INSIDE the folder's write transaction:
// the folder row, the pending-operation snapshot and the recent completions
// (#106, Memory 127; source fence in `ChangeSeamFenceTests`). No logging but debug-gated `print` inside.
//
// Per folder:
// - removals go through the ONE removal core (`deleteConfirmedGhostHeaders…`),
//   with the account-wide identity term when the ids are stable (no address epoch);
// - a record for a message the folder does not hold inserts it, unless the user's
//   own destructive action on it is pending or just completed, or the record
//   leaves out the read state or the flag (then the message is listed and read
//   again in full, never stored with a default);
// - a record for a message the folder holds merges its PRESENT fields; flags and
//   the server tag are kept back while the user's flag action is pending or just
//   completed; a user-label set (the message's whole set on the server) replaces
//   the stored one, kept back while the user's label action is pending or just
//   completed; a record whose label set is not known (nil) keeps the stored
//   labels (the reader lists a message whose set it could not complete,
//   `rereadLater`). A replied/forwarded mark the record carries is set, never
//   cleared (a reader that does not know it says false; the phone's own reply
//   marks its parent before the server shows it; Outlook's last verb, #890);
// - a folder read under a generation of its ids (`FolderChanges.addressEpoch`)
//   other than the one it stores applies nothing (the binding epoch check); a
//   renumbered folder (`ChangeRefusal.addressEpochChanged`) loses its bookmark,
//   coverage and re-read list and has its turnover reaction armed;
// - a record from a baseline (`FolderChangeStatus.isBaseline`: the folder's
//   messages as they are, not changes) inserts only a message dated within the
//   folder's held range (`Folder.oldestSyncedDate`); with no held range yet it
//   inserts nothing, and mail older than the range is the backfill's. A record
//   that answers an id on the folder's own re-read list is not a listing but the
//   server's answer about that one message, and applies whatever the range
//   (ADR-IOS-111, amendment 2026-11-14 "an explicit re-read answer");
// - every change kept back is put on the folder's re-read list
//   (`FolderChangeState.recheck`), read again on later passes (in turn, within
//   `SyncConfig.changeRereadBudgetPerPass`) until a record carrying its read
//   state, flag and user labels applies (`ChangeRecord.carriesKeptBackFields`; a partial record
//   applies what it carries and settles nothing, and the reader reads a listed
//   message in full), and so is every message the provider could not read
//   (`rereadLater`).
//   Over `SyncConfig.changeRecheckLimit` ids, a folder the catch-up checks
//   (`SyncEngine.isSyncable`) keeps every id already stored and only as many of
//   this pass's additions as fit, and its catch-up is armed for the cut ones; a
//   folder the catch-up never checks keeps every id, since nothing else would
//   repair a dropped one (each pass still reads at most the per-pass budget);
// - the folder's own bookmark (`Folder.changeCursor`) is written in the same
//   transaction. A refused one is cleared with the folder's coverage, a lapse
//   mark for its catch-up and the account's full sync made due; a folder whose
//   baseline is in progress or just completed is not covered yet.

/// What one folder transaction wrote.
struct FolderChangeApplyResult {
    var newHeaders: [MessageHeader] = []
    var removedIds: [String] = []
    var discoveredParents: [String] = []
    var wroteRows = false
    var armedCatchUp = false
    /// The folder's path when this transaction armed its turnover reaction
    /// (`ChangeRefusal.addressEpochChanged`); the engine runs the reaction after
    /// the transaction commits.
    var armedTurnoverPath: String?
    /// Nothing was written, not even the bookmark: the folder is gone, its
    /// turnover reaction is pending, or the read was under another epoch than
    /// the folder stores (the binding check). Such a folder is not trackable
    /// this pass.
    var rejected = false
    /// The folder bookmark stored when the transaction ends (nil = none).
    var storedCursor: String?
}

extension SyncEngine {

    nonisolated static func applyFolderChanges(_ changes: FolderChanges, db: Database) throws -> FolderChangeApplyResult {
        var result = FolderChangeApplyResult()
        guard let folder = try Folder.fetchOne(db, key: changes.folderId),
              folder.uidValidityResetPendingAt == nil else {
            result.rejected = true
            return result
        }
        let accountId = folder.accountId

        // The binding epoch check (compare-and-set, ADR-IOS-104): what was read
        // under one generation of the folder's ids applies only while the folder
        // still stores that generation. The turnover reaction runs outside the
        // per-account semaphore and can stamp a new one between the read and
        // this transaction; then nothing is written, not even the bookmark.
        if let epoch = changes.addressEpoch, folder.lastKnownUidValidity != epoch {
            if DebugModeManager.isLoggingEnabled() {
                print("[Sync] change apply: folder \(folder.name) read under generation \(epoch), stores \(folder.lastKnownUidValidity.map(String.init) ?? "none") — nothing applied")
            }
            result.rejected = true
            return result
        }

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
        if folder.role == .drafts, !removal.deleted.isEmpty {
            // Draft rekey visibility: Gmail mints a new message id on every draft
            // push, so the old one is reported removed (the matching insert below).
            // Inside the write transaction, so a console-only print behind the
            // canonical gate, not `BackgroundSyncLogger.logDebug` (rule 12 addendum).
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftRekey] change apply: removed drafts-folder rows \(removal.deleted) from \(folder.name)")
            }
        }

        // The folder's re-read list as stored, read inside this transaction: a
        // record for one of its ids answers it.
        let listed = Set(FolderChangeState(raw: folder.changeState).recheck)
        for record in changes.records {
            let applied = try applyChangeRecord(
                record, folder: folder, addressEpoch: changes.addressEpoch,
                heldRangeApplies: changes.status.isBaseline && !listed.contains(record.messageId),
                snapshot: snapshot, recentlyCompleted: recentlyCompleted, result: &result, db: db)
            if !applied {
                declined.insert(record.messageId)
            } else if record.carriesKeptBackFields {
                // A record without the read state, the flag or the user labels
                // applied what it carries but settles nothing: a listed message
                // stays listed until it is read again in full.
                settled.insert(record.messageId)
            }
        }

        // A message the provider could not read this pass is read again too.
        declined.formUnion(changes.rereadLater)

        // The re-read list: drop what applied; what was kept back goes to the
        // back, behind the ids this pass did not read, so with more ids than one
        // pass reads (`SyncConfig.changeRereadBudgetPerPass`) every id gets its turn.
        var state = FolderChangeState(raw: folder.changeState)
        let before = state
        var recheck = state.recheck.filter { !declined.contains($0) && !settled.contains($0) }
        recheck += state.recheck.filter { declined.contains($0) }
        for id in declined.sorted() where !recheck.contains(id) { recheck.append(id) }
        // Over the limit, only this pass's own additions are cut, never an id
        // already stored (a long list of retired ids drains over passes, #903).
        // Ids are dropped only where the catch-up will find them: arming it does
        // nothing for a folder it never checks, so that folder keeps them all.
        if recheck.count > SyncConfig.changeRecheckLimit,
           Self.isSyncable(role: folder.role, isFavorite: folder.isFavorite) {
            let stored = Set(before.recheck)
            let room = max(0, SyncConfig.changeRecheckLimit - recheck.filter(stored.contains).count)
            var added = 0
            recheck = recheck.filter { id in
                guard !stored.contains(id) else { return true }
                added += 1
                return added <= room
            }
            if added > room {
                try markCatchUpLapse(folderId: folder.id, db: db)
                result.armedCatchUp = true
            }
        }
        state.recheck = recheck

        // The folder's own bookmark and coverage.
        // A bookmark dropped since the read was issued stays dropped: the read's
        // new one is not written (its records still apply). Only a drop is
        // checked (issued with one, none stored now): a reader's own later page
        // of the same folder moves the bookmark forward, never to none.
        let bookmarkMoved = changes.readFrom.map { $0.cursor != nil && folder.changeCursor == nil } ?? false
        var cursor = bookmarkMoved ? folder.changeCursor : (changes.cursor ?? folder.changeCursor)
        switch changes.status {
        case .refused(let reason):
            // This folder only: its bookmark is gone, so it is not covered, its
            // catch-up gets one whole-folder check, and the account's full sync
            // lists it. Its next read starts a new baseline.
            try dropChangeBookmark(folderId: folder.id, onlyIfHeld: false, db: db)
            cursor = nil
            state.tracking = false
            if case .addressEpochChanged(let served) = reason {
                // The re-read ids name messages of the dead generation.
                state.recheck = []
                // Arm the turnover reaction durably, as the STATUS trigger's
                // reaction does at its step 1; the engine runs it after this
                // transaction (and the next pass re-drives it after a crash). Only
                // against a KNOWN stored generation that differs: a folder already
                // on the served one has nothing to reset.
                if let stored = folder.lastKnownUidValidity, stored != served {
                    try db.execute(
                        sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ? AND uidValidityResetPendingAt IS NULL",
                        arguments: [Date(), folder.id])
                    result.armedTurnoverPath = folder.path
                }
            }
        case .untracked:
            // No bookmark can cover the folder: the engine lists it when it changed.
            cursor = nil
            state.tracking = false
        case .baselining:
            state.tracking = false
        case .baselineReady:
            // Covered only after a window listing in a pass whose read covered it
            // (`commitChangeBaseline`); make that listing due.
            state.tracking = false
            try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?", arguments: [accountId])
        case .tracked, .failed, .notRun:
            break
        }
        if cursor != folder.changeCursor {
            try db.execute(sql: "UPDATE folder SET changeCursor = ? WHERE id = ?", arguments: [cursor, folder.id])
        }
        if state != before {
            try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folder.id])
        }
        result.storedCursor = cursor
        return result
    }

    /// Drop one folder's change bookmark outside a read, as a refused read
    /// does (`.refused` above): the bookmark is cleared, the folder is no longer
    /// covered, its catch-up gets one whole-folder check, and the account's full
    /// sync lists it; its next read starts a new baseline. The re-read list is
    /// kept. A folder with no bookmark is left as it is.
    /// `onlyIfHeld: false` (a refused read) ends the folder's tracking even when
    /// it holds no bookmark (a refused baseline).
    nonisolated static func dropChangeBookmark(folderId: String, onlyIfHeld: Bool = true, db: Database) throws {
        guard let folder = try Folder.fetchOne(db, key: folderId),
              !onlyIfHeld || folder.changeCursor != nil else { return }
        var state = FolderChangeState(raw: folder.changeState)
        state.tracking = false
        try db.execute(sql: "UPDATE folder SET changeCursor = NULL, changeState = ? WHERE id = ?",
                       arguments: [state.encoded, folderId])
        try markCatchUpLapse(folderId: folderId, db: db)
        try db.execute(sql: "UPDATE account SET lastFullSyncAt = NULL WHERE id = ?", arguments: [folder.accountId])
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
        _ record: ChangeRecord, folder: Folder, addressEpoch: Int?, heldRangeApplies: Bool,
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
        // A baseline lists the folder as it is: a message older than the held
        // range, or any message before the folder has one, is not inserted (the
        // window listing sets the range, the backfill takes older mail). Not for
        // a record answering a listed id: that message's place is put back
        // wherever its date falls (`heldRangeApplies` is false for it).
        if heldRangeApplies {
            guard let heldSince = folder.oldestSyncedDate, info.providerOrderDate >= heldSince else { return true }
        }
        // A record without the read state or the flag would store a default for
        // the one it leaves out: the message is listed instead and read again in
        // full, and the full record inserts it.
        guard record.carriesReadAndFlag else { return false }
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
    /// under the flag shield; the user-label set under the label shield; rfc822
    /// and references always.
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
        // User labels: the record's set replaces the stored one, under the
        // user's own pending or just-completed label change. A nil set is not
        // known this read and changes nothing; a reader whose set may have
        // changed but could not be completed lists the message itself
        // (`rereadLater`, Gmail's unknown label id, #882).
        if let incoming = record.userLabelIds {
            let labelShielded = snapshot.userLabel.containsAnyKey(messageId: record.messageId, rfc822MessageId: rfc822)
                || recentlyCompleted[record.messageId] != nil
            let differs = try replaceUserLabels(
                of: existing.id, accountId: folder.accountId, with: incoming, write: !labelShielded, db: db)
            if differs && labelShielded { keptBack = true }
        }
        if let rfc822 = record.rfc822MessageId { existing.rfc822MessageId = rfc822 }
        if let references = record.references { existing.referencesJSON = MessageHeader.encodeReferences(references) }
        // Replied/forwarded: set when the server shows it, never cleared.
        // Not while the user's own tag change is pending: theirs is the one the
        // server must end up with.
        if record.isReplied && !existing.isReplied {
            existing.isReplied = true
            let userTagPending = snapshot.tag.containsAnyKey(messageId: existing.stableId, rfc822MessageId: rfc822)
                || snapshot.tag.contains(record.messageId)
            if !userTagPending {
                try replyDetect(&existing, accountId: folder.accountId, folderPath: folder.path, context: "change merge", db: db)
            }
        }
        if record.isForwarded { existing.isForwarded = true }
        try existing.update(db)
        result.wroteRows = true
        return !keptBack
    }

    /// ReplyDetect: an already-replied message tagged "reply" becomes "none".
    /// The AI cache keeps the model's value; only the row and the server tag change.
    private nonisolated static func replyDetect(
        _ header: inout MessageHeader, accountId: String, folderPath: String, context: String, db: Database
    ) throws {
        guard header.actionTag == .reply else { return }
        // Stamped like any tag write.
        header.setActionTag(ActionTag.none)
        var tagOp = PendingOperation(
            type: .setTag, messageIds: [header.stableId], accountId: accountId,
            folderPath: folderPath, tagValue: ActionTag.none.rawValue)
        try tagOp.insert(db)
        if DebugModeManager.isLoggingEnabled() {
            print("[ReplyDetect] \(context): reply→none for \(header.messageId) (already replied)")
        }
    }

    /// Make a stored row's user-label rows the server's set (`providerLabelIds`):
    /// rows for labels the set leaves out are deleted, missing ones inserted with
    /// the insert arm's label row. Returns whether the stored set differed; with
    /// `write` false nothing is written.
    private nonisolated static func replaceUserLabels(
        of headerId: String, accountId: String, with providerLabelIds: [String], write: Bool, db: Database
    ) throws -> Bool {
        let labels = providerLabelIds.map { UserLabel(accountId: accountId, providerLabelId: $0, name: $0, isSystem: false) }
        let wanted = Set(labels.map(\.id))
        let stored = Set(try MessageUserLabel.filter(Column("messageId") == headerId).fetchAll(db).map(\.userLabelId))
        guard wanted != stored else { return false }
        guard write else { return true }
        if DebugModeManager.isLoggingEnabled() {
            print("[Sync] change apply: user labels of \(headerId): \(stored.sorted()) -> \(wanted.sorted())")
        }
        try MessageUserLabel
            .filter(Column("messageId") == headerId && !wanted.contains(Column("userLabelId")))
            .deleteAll(db)
        for label in labels where !stored.contains(label.id) {
            try label.insert(db, onConflict: .ignore)
            // The join FK is `userLabel.id`, the account-prefixed surrogate (IOS-LABEL-001).
            try MessageUserLabel(messageId: headerId, userLabelId: label.id).insert(db, onConflict: .ignore)
        }
        return true
    }

    /// The insert arm: the header builder, AI-cache restore, reply-detect, orphan
    /// reclaim, Drafts/Sent placeholder dedup (with label and body carry), the
    /// references and user-label rows, and the Sent reply-parent mark.
    private nonisolated static func insertChangeRecord(
        _ info: MessageHeaderInfo, record: ChangeRecord, folder: Folder, snapshot: PendingOperationSnapshot,
        result: inout FolderChangeApplyResult, db: Database
    ) throws -> Bool {
        let accountId = folder.accountId
        if folder.role == .drafts {
            if DebugModeManager.isLoggingEnabled() {
                print("[DraftRekey] change apply: inserting drafts-folder header messageId=\(info.messageId) into \(folder.name)")
            }
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
        header.isReplied = info.isReplied || record.isReplied
        header.isForwarded = info.isForwarded || record.isForwarded
        header.actionTag = info.actionTag
        header.tagSortOrder = info.actionTag?.sortOrder ?? 99
        try MessageAICache.restoreIfCached(into: &header, accountId: accountId, folderPath: folder.path, db: db)
        if header.isReplied {
            try replyDetect(&header, accountId: accountId, folderPath: folder.path, context: "change insert", db: db)
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
