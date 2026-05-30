/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// Configurable mock EmailProvider for testing services that depend on email operations.
/// Records all method calls for assertion. Can be configured to throw errors or return specific results.
actor MockEmailProvider: EmailProvider {
    // MARK: - Call Recording

    var callLog: [String] = []

    // MARK: - Configurable Results

    var connectThrows: Error?
    var disconnectThrows: Error?
    var fetchFoldersResult: [FolderInfo] = []
    var fetchFoldersThrows: Error?
    var fetchMessagesResult: [MessageHeaderInfo] = []
    var fetchMessagesThrows: Error?
    var fetchMessageResult: FullMessageInfo?
    var fetchMessageThrows: Error?
    var searchResult: [MessageHeaderInfo] = []
    var searchThrows: Error?
    var markReadThrows: Error?
    var markUnreadThrows: Error?
    var markFlaggedThrows: Error?
    var moveThrows: Error?
    var sendThrows: Error?
    var appendToSentResult: Bool = true
    var appendToSentThrows: Error?
    var fetchHistoryResult: HistoryResponse?
    var fetchHistoryThrows: Error?
    var fetchMessageHeadersResult: [MessageHeaderInfo] = []
    var fetchMessageHeadersThrows: Error?

    // MARK: - Parameter Tracking

    var markedReadIds: [(ids: [String], folder: String)] = []
    var markedUnreadIds: [(ids: [String], folder: String)] = []
    var markedFlaggedIds: [(ids: [String], flagged: Bool, folder: String)] = []
    var movedIds: [(ids: [String], from: String, to: String)] = []
    var sentDrafts: [DraftMessage] = []
    var appendedToSent: [(draft: DraftMessage, sentFolderPath: String, messageId: String)] = []

    // MARK: - EmailProvider Protocol

    func connect() async throws {
        callLog.append("connect")
        if let error = connectThrows { throw error }
    }

    func disconnect() async throws {
        callLog.append("disconnect")
        if let error = disconnectThrows { throw error }
    }

    func fetchFolders() async throws -> [FolderInfo] {
        callLog.append("fetchFolders")
        if let error = fetchFoldersThrows { throw error }
        return fetchFoldersResult
    }

    func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] {
        callLog.append("fetchMessages(folder:\(folder),limit:\(limit),offset:\(offset))")
        if let error = fetchMessagesThrows { throw error }
        return fetchMessagesResult
    }

    func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
        callLog.append("fetchMessage(id:\(id),folder:\(folder))")
        if let error = fetchMessageThrows { throw error }
        guard let result = fetchMessageResult else {
            throw ProviderError.messageNotFound
        }
        return result
    }

    func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] {
        callLog.append("search(query:\(query))")
        if let error = searchThrows { throw error }
        return searchResult
    }

    func markRead(ids: [String], folder: String) async throws {
        callLog.append("markRead(ids:\(ids),folder:\(folder))")
        markedReadIds.append((ids: ids, folder: folder))
        if let error = markReadThrows { throw error }
    }

    func markUnread(ids: [String], folder: String) async throws {
        callLog.append("markUnread(ids:\(ids),folder:\(folder))")
        markedUnreadIds.append((ids: ids, folder: folder))
        if let error = markUnreadThrows { throw error }
    }

    func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {
        callLog.append("markFlagged(ids:\(ids),flagged:\(flagged),folder:\(folder))")
        markedFlaggedIds.append((ids: ids, flagged: flagged, folder: folder))
        if let error = markFlaggedThrows { throw error }
    }

    func move(ids: [String], from: String, to: String) async throws {
        callLog.append("move(ids:\(ids),from:\(from),to:\(to))")
        movedIds.append((ids: ids, from: from, to: to))
        if let error = moveThrows { throw error }
    }

    func send(draft: DraftMessage) async throws {
        callLog.append("send")
        sentDrafts.append(draft)
        if let error = sendThrows { throw error }
    }

    func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool {
        callLog.append("appendToSentFolder(sentFolderPath:\(sentFolderPath),messageId:\(messageId))")
        appendedToSent.append((draft: draft, sentFolderPath: sentFolderPath, messageId: messageId))
        if let error = appendToSentThrows { throw error }
        return appendToSentResult
    }

    func fetchHistory(since historyId: String) async throws -> HistoryResponse? {
        callLog.append("fetchHistory(since:\(historyId))")
        if let error = fetchHistoryThrows { throw error }
        return fetchHistoryResult
    }

    func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] {
        callLog.append("fetchMessageHeaders(ids:\(ids))")
        if let error = fetchMessageHeadersThrows { throw error }
        return fetchMessageHeadersResult
    }

    func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] {
        callLog.append("fetchTextBodies(ids:\(ids.count),folder:\(folder))")
        return []
    }

    // MARK: - Draft Operations

    var saveDraftResult: DraftSaveResult = DraftSaveResult(serverId: "mock-draft-id")
    var saveDraftThrows: Error?
    var deleteDraftThrows: Error?
    var savedDrafts: [(draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String)] = []
    var deletedDraftIds: [(draftId: String, draftsFolderPath: String)] = []

    func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult {
        callLog.append("saveDraft(existingDraftId:\(existingDraftId ?? "nil"),draftsFolderPath:\(draftsFolderPath))")
        savedDrafts.append((draft: draft, existingDraftId: existingDraftId, draftsFolderPath: draftsFolderPath))
        if let error = saveDraftThrows { throw error }
        return saveDraftResult
    }

    func deleteDraft(draftId: String, draftsFolderPath: String) async throws {
        callLog.append("deleteDraft(draftId:\(draftId),draftsFolderPath:\(draftsFolderPath))")
        deletedDraftIds.append((draftId: draftId, draftsFolderPath: draftsFolderPath))
        if let error = deleteDraftThrows { throw error }
    }

    // MARK: - Test Helpers

    /// Set moveThrows from outside the actor.
    func setMoveThrows(_ error: Error?) {
        moveThrows = error
    }

    /// Reset all recorded state.
    func reset() {
        callLog.removeAll()
        markedReadIds.removeAll()
        markedUnreadIds.removeAll()
        markedFlaggedIds.removeAll()
        movedIds.removeAll()
        sentDrafts.removeAll()
        appendedToSent.removeAll()
    }
}
