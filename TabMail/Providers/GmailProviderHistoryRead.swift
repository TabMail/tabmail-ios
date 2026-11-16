/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// What one change pass read of a Gmail account's history (`readHistory`):
/// every message the records it took name, read, and the bookmark to store.
struct GmailHistoryRead {
    /// The bookmark to store: the first page's `historyId` when the history was
    /// read to its end, the id of the last record taken when the pass stopped
    /// early. Nil when the time budget ran out before a record was taken (the
    /// bookmark stays).
    var bookmark: String?
    /// The history was read to its end.
    var complete = false
    /// Records taken.
    var recordCount = 0
    /// Messages a taken record deleted.
    var deleted = Set<String>()
    /// Every message id asked for this pass (changed messages and re-reads).
    var requested = Set<String>()
    /// The latest answer for each message read, by id; a gone message has none.
    var details: [String: GmailMessageDetail] = [:]
    /// Messages whose own answer could not be used this pass.
    var unreadable = Set<String>()
    /// A failure about the account while reading messages: the pass keeps its
    /// bookmark.
    var failure: (any Error)?
}

/// Gmail's history, read record by record within the pass's time budget
/// (ADR-IOS-111, #491).
///
/// - The first page is always read (the pass's turn started within its budget);
///   a later page starts only while the budget lasts, and at most
///   `GmailAPI.historyMaxPages` pages are read.
/// - Every record after the pass's first is taken only while the budget lasts.
///   A record's added or relabelled messages are queued and read
///   `GmailAPI.maxConcurrentRequests` at a time (`fetchMessageDetails`) once the
///   queue holds that many, and at the end; a record that names more is read
///   whole. Its deleted messages leave the queue and what was read.
/// - A record newer than the first page's `historyId` was written after this
///   pass's first reads began, so a message it names that was already read is
///   read again.
/// - Read to its end, the bookmark is the first page's `historyId`. Stopped
///   early, it is the id of the last record taken (`users.history.list` returns
///   the records after `startHistoryId`, in increasing id), so the next pass
///   resumes there with nothing listed again.
///
/// Nil when the history can no longer be read from the bookmark: Gmail answers
/// 404 (expired), the record to resume after does not carry a numeric id past
/// the bookmark, or `GmailAPI.historyMaxPages` pages were read without taking a
/// record (#938). A page that cannot be read throws.
extension GmailProvider {
    func readHistory(
        since start: String, recheck: Set<String>, context: ChangeContext
    ) async throws -> GmailHistoryRead? {
        let http = authedHTTP
        var read = GmailHistoryRead()
        var queue = recheck.sorted()
        read.requested = recheck
        var firstPageHistoryId: String?
        var lastTaken: String?
        var pageToken: String?
        var pagesRead = 0

        reading: while pagesRead < GmailAPI.historyMaxPages {
            if pagesRead > 0, !context.hasBudget() { break }
            let page: HistoryPage?
            do {
                page = try await GmailAPI.historyPage(http: http, startHistoryId: start, pageToken: pageToken)
            } catch {
                BackgroundSyncLogger.logDebug("[Gmail] readHistory: page failed: \(error)")
                throw ProviderError.networkError(underlying: error)
            }
            guard let page else { return nil }
            pagesRead += 1
            if firstPageHistoryId == nil { firstPageHistoryId = page.historyId }
            let snapshot = UInt64(firstPageHistoryId ?? "")
            for record in page.records {
                if lastTaken != nil, !context.hasBudget() { break reading }
                for id in record.changes.removed.map(\.providerMessageId) {
                    read.deleted.insert(id)
                    read.details[id] = nil
                    read.unreadable.remove(id)
                    queue.removeAll { $0 == id }
                }
                let written = UInt64(record.id).map { id in snapshot.map { id > $0 } ?? true } ?? true
                let named = record.changes.added.map(\.providerMessageId)
                    + record.changes.labelsAdded.map(\.providerMessageId)
                    + record.changes.labelsRemoved.map(\.providerMessageId)
                for id in named where !read.deleted.contains(id) && !queue.contains(id) {
                    guard written || !read.requested.contains(id) else { continue }
                    read.requested.insert(id)
                    queue.append(id)
                }
                lastTaken = record.id
                read.recordCount += 1
                if queue.count >= GmailAPI.maxConcurrentRequests {
                    await readQueued(&queue, into: &read, context: context)
                    if read.failure != nil { break reading }
                }
            }
            guard let next = page.nextPageToken else {
                read.complete = true
                break
            }
            pageToken = next
        }
        // The page cap reached with no record taken: there is nothing to resume
        // after, and a history that kept answering this way would hold every
        // pass on this bookmark until it expires. Refused like an expired
        // history, so the pass re-lists (#938). A pass stopped by its time
        // budget keeps its bookmark.
        if !read.complete, lastTaken == nil, pagesRead >= GmailAPI.historyMaxPages {
            BackgroundSyncLogger.logDebug("[Gmail] readHistory: \(pagesRead) pages from \(start) without a record")
            return nil
        }
        await readQueued(&queue, into: &read, context: context)
        guard read.failure == nil else { return read }

        if read.complete {
            read.bookmark = firstPageHistoryId ?? ""
        } else if let lastTaken {
            // The pass resumes after the last record it took: that id must be a
            // history id past the bookmark it read from.
            guard let startId = UInt64(start), let lastId = UInt64(lastTaken), lastId > startId else {
                BackgroundSyncLogger.logDebug("[Gmail] readHistory: cannot resume after record \(lastTaken) (from \(start))")
                return nil
            }
            read.bookmark = lastTaken
        }
        return read
    }

    /// Reads the queued messages into `read` and empties the queue. Nothing is
    /// read once a failure about the account stopped the pass.
    private func readQueued(_ queue: inout [String], into read: inout GmailHistoryRead, context: ChangeContext) async {
        guard read.failure == nil, !queue.isEmpty else { return }
        let ids = queue
        queue.removeAll()
        do {
            // A record's user labels are the message's whole set only once
            // the label catalog has loaded (#882).
            if !isUserLabelCatalogLoaded { _ = try await fetchFolders() }
            context.onProgress(ids.count)
            let batch = try await fetchMessageDetails(ids: ids)
            for id in ids {
                read.details[id] = nil
                read.unreadable.remove(id)
            }
            for detail in batch.details { read.details[detail.header.messageId] = detail }
            read.unreadable.formUnion(batch.unreadable)
        } catch {
            read.failure = error
        }
    }
}
