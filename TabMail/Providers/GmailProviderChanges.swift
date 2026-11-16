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
/// - The history cannot be read from the bookmark (expired): every folder
///   `.refused`, the bookmark cleared.
/// - Otherwise the history is read record by record within the pass's time
///   budget (`readHistory`, #491). A pass that runs out of time stops after a
///   record and stores that record's id, so the next pass resumes there with
///   nothing listed again; a pass that reads to the end stores the history's
///   current id. A deleted message is a removal in every folder; every other
///   changed message, and every message the engine asks to re-read, is fetched
///   and is a record in each folder its labels put it in and a removal in
///   every other folder. A message that is asked to be re-read and is gone is a
///   removal everywhere. A message whose own answer cannot be used is put on
///   every folder's `rereadLater` and the rest of the pass lands, bookmark
///   included. A failure about the account (connection, credentials) keeps the
///   removals, reports `.failed` and keeps the bookmark.
/// - A record carries the message's user-label set only when it is complete:
///   the label catalog is loaded before any message is read, and reloaded once
///   when a message carries a label id it does not know; a set still
///   incomplete is unknown (nil) (#882).
///
/// `inboxOnly` changes nothing but the folder list: the history is one read for
/// the whole account. A turn that starts with no read budget left reads nothing.
extension GmailProvider {
    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        // A pass whose turn started with no read budget left reads nothing and
        // keeps its bookmark (`SyncEngine.changeReadEnd`).
        guard request.context.hasBudget() else {
            return .uniform(request, account: .keep, status: .notRun)
        }
        let folderList: FolderListUpdate? = request.scope == .all ? .complete(try await fetchFolders()) : nil

        guard let historyId = cursor.account else {
            BackgroundSyncLogger.log("gmailDelta: \(userEmail) noHistoryId")
            // The candidate is read BEFORE any listing of this pass.
            guard let candidate = try await getCurrentHistoryId() else {
                return .uniform(request, account: .keep, status: .notRun, folderList: folderList)
            }
            return .uniform(request, account: .candidate(candidate), status: .baselineReady, folderList: folderList)
        }

        BackgroundSyncLogger.logDebug("[Sync] Gmail delta: reading history since \(historyId) for \(userEmail)")
        let recheck = Set(request.recheck.values.flatMap { $0 })
        guard let history = try await readHistory(since: historyId, recheck: recheck, context: request.context) else {
            // Expired (404), a stop point that is not a history id past the
            // bookmark, or the page cap reached with no record taken: the
            // changes in the gap reach no read, so the engine re-lists and
            // starts a new bookmark.
            BackgroundSyncLogger.logDebug("[Sync] Gmail delta: history expired for \(userEmail)")
            BackgroundSyncLogger.log("gmailDelta: \(userEmail) historyExpired")
            return .uniform(request, account: .clear, status: .refused(.expired), folderList: folderList)
        }

        let deltaLog = "gmailDelta: \(userEmail) hid=\(historyId)→\(history.bookmark ?? "keep") records=\(history.recordCount) complete=\(history.complete) read=\(history.requested.count) -\(history.deleted.count)"
        BackgroundSyncLogger.logDebug("[Sync] \(deltaLog)")
        BackgroundSyncLogger.log(deltaLog)

        let failure = history.failure
        let account: AccountCursorUpdate = failure == nil ? history.bookmark.map { .set($0) } ?? .keep : .keep
        let deleted = history.deleted
        if deleted.isEmpty && history.requested.isEmpty {
            return .uniform(request, account: account, status: .tracked, folderList: folderList)
        }

        var batch = GmailDetailBatch(
            details: history.details.keys.sorted().compactMap { history.details[$0] },
            unreadable: history.unreadable.sorted())
        // A message carrying a label id the catalog does not know (a label
        // created on the server after the catalog loaded): reload the catalog
        // once this pass and extract the labels again. A label still unknown
        // leaves that message's set unknown (nil in its record): the apply keeps
        // the stored labels, and the message goes on the re-read list
        // (`rereadLater`) of every folder its record lands in, so a later read
        // that knows the set lands it. A failed reload leaves those sets unknown
        // the same way (#882).
        if failure == nil, batch.details.contains(where: { !$0.header.userLabelIdsAreAuthoritative }) {
            do {
                _ = try await fetchFolders()
                batch = reextractUserLabels(batch)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                BackgroundSyncLogger.logDebug("[Sync] Gmail delta: label list reload failed, unknown label sets stay unknown: \(error)")
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
            removedEverywhere.formUnion(recheck.subtracting(deleted).subtracting(answered))
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
                    if !detail.header.userLabelIdsAreAuthoritative {
                        changes.rereadLater.append(detail.header.messageId)
                    }
                } else {
                    changes.removals.append(detail.header.messageId)
                }
            }
            return changes
        }
        return ChangeSet(account: account, folderList: folderList, folders: folders)
    }
}
