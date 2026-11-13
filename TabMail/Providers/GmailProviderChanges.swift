/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Gmail's change reader (ADR-IOS-111): the account's history, read below the
/// seam. It only reads; the engine's generic apply writes.
///
/// - Scope `.all`: the label list (`fetchFolders`, which also loads the user-label
///   catalog) is the ChangeSet's folder list, so a label created, renamed or
///   deleted on the server shows on the next pass.
/// - No bookmark: the profile's current history id is read FIRST, as a candidate,
///   and every folder is `.baselineReady`. The engine lists the folders and only
///   then stores the candidate, so a change made during the listing is read by
///   the next pass.
/// - The history cannot be read (expired, or longer than one pass takes on, which
///   `fetchHistory` reports alike): every folder `.refused`, the bookmark cleared.
/// - Otherwise: a deleted message is a removal in every folder; every other
///   changed message, and every message the engine asks to re-read, is fetched
///   once and is a record in each folder its labels put it in and a removal in
///   every other folder. A message that is asked to be re-read and is gone is a
///   removal everywhere. A message whose own answer cannot be used is put on
///   every folder's `rereadLater` and the rest of the pass lands, bookmark
///   included. A failure about the account (connection, credentials) keeps the
///   removals, reports `.failed` and keeps the bookmark.
///
/// `inboxOnly` changes nothing but the folder list: the history is one call for
/// the whole account.
extension GmailProvider {
    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        let folderList: [FolderInfo]? = request.scope == .all ? try await fetchFolders() : nil

        guard let historyId = cursor.account else {
            BackgroundSyncLogger.log("gmailDelta: \(userEmail) noHistoryId")
            // The candidate is read BEFORE any listing of this pass.
            guard let candidate = try await getCurrentHistoryId() else {
                return .uniform(request, account: .keep, status: .notRun, folderList: folderList)
            }
            return .uniform(request, account: .candidate(candidate), status: .baselineReady, folderList: folderList)
        }

        BackgroundSyncLogger.logDebug("[Sync] Gmail delta: fetching history since \(historyId) for \(userEmail)")
        guard let history = try await fetchHistory(since: historyId) else {
            // Expired (404) or longer than one pass takes on (over
            // `GmailAPI.historyMaxChanges` records or changed messages, or
            // `GmailAPI.historyMaxPages` pages): the changes in the gap reach no
            // read, so the engine re-lists and starts a new bookmark.
            BackgroundSyncLogger.logDebug("[Sync] Gmail delta: history expired or too long for \(userEmail)")
            BackgroundSyncLogger.log("gmailDelta: \(userEmail) historyExpiredOrTooLong")
            return .uniform(request, account: .clear, status: .refused(.expired), folderList: folderList)
        }

        let deltaLog = "gmailDelta: \(userEmail) hid=\(historyId)→\(history.newHistoryId) +\(history.messagesAdded.count) -\(history.messagesDeleted.count) ~\(history.labelsAdded.count + history.labelsRemoved.count)"
        BackgroundSyncLogger.logDebug("[Sync] \(deltaLog)")
        BackgroundSyncLogger.log(deltaLog)

        let deleted = Set(history.messagesDeleted.map(\.messageId))
        var changed = Set(history.messagesAdded.map(\.messageId))
        changed.formUnion(history.labelsAdded.map(\.messageId))
        changed.formUnion(history.labelsRemoved.map(\.messageId))
        changed.subtract(deleted)
        let recheck = Set(request.recheck.values.flatMap { $0 }).subtracting(deleted)
        let toFetch = changed.union(recheck)

        if deleted.isEmpty && toFetch.isEmpty {
            return .uniform(request, account: .set(history.newHistoryId), status: .tracked, folderList: folderList)
        }

        var batch = GmailDetailBatch()
        var failure: (any Error)?
        if !toFetch.isEmpty {
            request.context.onProgress(toFetch.count)
            do {
                batch = try await fetchMessageDetails(ids: Array(toFetch))
            } catch {
                failure = error
            }
        }
        let details = batch.details

        // A message that is gone (404/410) is left out of `details` and of
        // `unreadable`. For a re-read message that is the answer: it is gone
        // everywhere. For a history entry it is skipped, as the history's own
        // delete reports it. A message whose answer could not be used is read
        // again next pass, in whichever folders its labels then put it.
        var removedEverywhere = deleted
        let unreadable = Set(batch.unreadable).sorted()
        if failure == nil {
            let answered = Set(details.map(\.header.messageId)).union(unreadable)
            removedEverywhere.formUnion(recheck.subtracting(answered))
        }

        let folders = request.folders.map { folder -> FolderChanges in
            var changes = FolderChanges(
                folderId: folder.id, status: failure.map { .failed($0) } ?? .tracked,
                removals: removedEverywhere.sorted())
            guard failure == nil else { return changes }
            changes.rereadLater = unreadable
            for detail in details {
                if Self.folder(folder.path, containsMessageWithLabels: detail.labelIds) {
                    changes.records.append(ChangeRecord(header: detail.header))
                } else {
                    changes.removals.append(detail.header.messageId)
                }
            }
            return changes
        }
        return ChangeSet(
            account: failure == nil ? .set(history.newHistoryId) : .keep,
            folderList: folderList, folders: folders)
    }
}
