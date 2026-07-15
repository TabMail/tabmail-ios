/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// Configurable mock EmailProvider for testing services that depend on email operations.
/// Records all method calls for assertion. Can be configured to throw errors or return specific results.
actor MockEmailProvider: EmailProvider {
    // MARK: - Stale-detection window mode (configurable per test; .uid mimics IMAP)

    nonisolated let staleWindowMode: StaleWindowMode
    nonisolated let messageFieldScope: MessageFieldScope

    init(
        staleWindowMode: StaleWindowMode = .date,
        messageFieldScope: MessageFieldScope = .folder
    ) {
        self.staleWindowMode = staleWindowMode
        self.messageFieldScope = messageFieldScope
    }

    // MARK: - Call Recording

    var callLog: [String] = []

    /// Optional provider-side mailbox model for black-box queue/Undo acceptance tests.
    /// Keys are the durable RFC Message-IDs accepted by `EmailProvider`; a missing key
    /// is an authoritative stale target and therefore remains a no-op.
    private struct StatefulMessage {
        var folder: String
        var providerMessageId: String
        var nextProviderMessageIdAfterMove: String?
    }

    private var statefulMessagesByRFCMessageId: [String: StatefulMessage]?

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
    /// Configures `move(ids:from:to:)` to simulate a batch that fails PARTWAY
    /// through (e.g. an IMAP MOVE command that drops the connection
    /// mid-batch): every id BEFORE `failingId` is recorded into `movedIds` as
    /// if it had already succeeded, then `error` is thrown once `failingId`
    /// is reached — ids at/after it are never attempted/recorded. Set via
    /// `setMoveThrowsOnId`, cleared via `clearMoveThrowsOnId`. Takes
    /// precedence over `moveThrows` when both are configured and `ids`
    /// contains the failing id.
    var moveThrowsOnId: (id: String, error: Error)?
    var sendThrows: Error?
    var appendToSentResult: Bool = true
    var appendToSentThrows: Error?
    var fetchHistoryResult: HistoryResponse?
    var fetchHistoryThrows: Error?
    var fetchMessageHeadersResult: [MessageHeaderInfo] = []
    var fetchMessageHeadersThrows: Error?
    var legacyIdentityResolutions: [String: LegacyMessageActionIdentityResolution] = [:]
    var legacyIdentityResolutionErrors: [String: any Error] = [:]
    var legacyIdentityResolutionHandler: (@Sendable (
        _ providerMessageId: String,
        _ sourceFolder: String,
        _ destinationFolder: String?
    ) async throws -> LegacyMessageActionIdentityResolution)?
    var markReadHook: (@Sendable () async -> Void)?
    var saveDraftHook: (@Sendable () async -> Void)?
    /// Awaited BEFORE `move()` records or mutates anything — lets a test
    /// suspend the provider call itself (not just the durable write queue)
    /// so it can observe/act while the claimed row is genuinely in flight
    /// (§14.4 scenario 2). Never held while any gate is held — this fires
    /// entirely outside `pendingOperationMutationGate`, mirroring production.
    var moveHook: (@Sendable () async -> Void)?

    // MARK: - Parameter Tracking

    var markedReadIds: [(ids: [String], folder: String)] = []
    var markedUnreadIds: [(ids: [String], folder: String)] = []
    var markedFlaggedIds: [(ids: [String], flagged: Bool, folder: String)] = []
    var markedRepliedIds: [(ids: [String], folder: String)] = []
    var markedForwardedIds: [(ids: [String], folder: String)] = []
    var userLabelChanges: [(ids: [String], labelId: String, present: Bool, folder: String)] = []
    var movedIds: [(ids: [String], from: String, to: String)] = []
    var sentDrafts: [DraftMessage] = []
    var appendedToSent: [(draft: DraftMessage, sentFolderPath: String, messageId: String)] = []
    var legacyIdentityResolutionCalls: [(
        providerMessageId: String,
        sourceFolder: String,
        destinationFolder: String?
    )] = []

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
        if let statefulMessagesByRFCMessageId {
            return statefulMessagesByRFCMessageId
                .filter { $0.value.folder == folder }
                .sorted { $0.key < $1.key }
                .dropFirst(offset)
                .prefix(limit)
                .map { rfcMessageId, message in
                    MessageHeaderInfo(
                        messageId: message.providerMessageId,
                        rfc822MessageId: "<\(rfcMessageId)>",
                        inReplyTo: nil,
                        references: [],
                        threadId: nil,
                        subject: "Stateful provider message",
                        from: "Sender",
                        fromAddress: "sender@example.com",
                        to: "recipient@example.com",
                        cc: "",
                        bcc: "",
                        replyTo: nil,
                        date: Date(),
                        snippet: "Stateful provider message",
                        isRead: false,
                        isFlagged: false,
                        hasAttachments: false,
                        isReplied: false,
                        isForwarded: false,
                        actionTag: nil
                    )
                }
        }
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
        if let markReadHook { await markReadHook() }
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

    func markReplied(ids: [String], folder: String) async throws {
        callLog.append("markReplied(ids:\(ids),folder:\(folder))")
        markedRepliedIds.append((ids: ids, folder: folder))
    }

    func markForwarded(ids: [String], folder: String) async throws {
        callLog.append("markForwarded(ids:\(ids),folder:\(folder))")
        markedForwardedIds.append((ids: ids, folder: folder))
    }

    func setUserLabel(ids: [String], labelId: String, present: Bool, folder: String) async throws {
        callLog.append("setUserLabel(ids:\(ids),labelId:\(labelId),present:\(present),folder:\(folder))")
        userLabelChanges.append((ids: ids, labelId: labelId, present: present, folder: folder))
    }

    func move(ids: [String], from: String, to: String) async throws {
        callLog.append("move(ids:\(ids),from:\(from),to:\(to))")
        if let moveHook { await moveHook() }
        if let (failingId, error) = moveThrowsOnId, ids.contains(failingId) {
            // Partial-batch progress: record everything BEFORE the failing id
            // as if it had already succeeded on the wire (mirrors an IMAP
            // batch MOVE that aborts mid-command on a connection drop), then
            // throw. Ids at/after the failing one are never attempted.
            let succeededPrefix = Array(ids.prefix(while: { $0 != failingId }))
            if !succeededPrefix.isEmpty {
                movedIds.append((ids: succeededPrefix, from: from, to: to))
            }
            throw error
        }
        movedIds.append((ids: ids, from: from, to: to))
        if let error = moveThrows { throw error }
        if var messages = statefulMessagesByRFCMessageId {
            for id in ids where messages[id]?.folder == from {
                messages[id]?.folder = to
                if let nextProviderMessageId = messages[id]?.nextProviderMessageIdAfterMove {
                    messages[id]?.providerMessageId = nextProviderMessageId
                    messages[id]?.nextProviderMessageIdAfterMove = nil
                }
            }
            statefulMessagesByRFCMessageId = messages
        }
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

    func resolveLegacyMessageActionIdentity(
        providerMessageId: String,
        sourceFolder: String,
        destinationFolder: String?
    ) async throws -> LegacyMessageActionIdentityResolution {
        callLog.append("resolveLegacyMessageActionIdentity(id:\(providerMessageId))")
        legacyIdentityResolutionCalls.append((
            providerMessageId: providerMessageId,
            sourceFolder: sourceFolder,
            destinationFolder: destinationFolder
        ))
        if let legacyIdentityResolutionHandler {
            return try await legacyIdentityResolutionHandler(
                providerMessageId,
                sourceFolder,
                destinationFolder
            )
        }
        if let error = legacyIdentityResolutionErrors[providerMessageId] {
            throw error
        }
        guard let resolution = legacyIdentityResolutions[providerMessageId] else {
            throw ProviderError.actionIdentityResolutionFailed(providerMessageId)
        }
        return resolution
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
        if let saveDraftHook { await saveDraftHook() }
        if let error = saveDraftThrows { throw error }
        return saveDraftResult
    }

    func deleteDraft(draftId: String, draftsFolderPath: String) async throws {
        callLog.append("deleteDraft(draftId:\(draftId),draftsFolderPath:\(draftsFolderPath))")
        deletedDraftIds.append((draftId: draftId, draftsFolderPath: draftsFolderPath))
        if let error = deleteDraftThrows { throw error }
    }

    // MARK: - Test Helpers

    func seedStatefulMessage(
        id: String,
        folder: String,
        providerMessageId: String,
        nextProviderMessageIdAfterMove: String? = nil
    ) {
        if statefulMessagesByRFCMessageId == nil {
            statefulMessagesByRFCMessageId = [:]
        }
        statefulMessagesByRFCMessageId?[id] = StatefulMessage(
            folder: folder,
            providerMessageId: providerMessageId,
            nextProviderMessageIdAfterMove: nextProviderMessageIdAfterMove
        )
    }

    func statefulFolder(messageId: String) -> String? {
        statefulMessagesByRFCMessageId?[messageId]?.folder
    }

    /// Set moveThrows from outside the actor.
    func setMoveThrows(_ error: Error?) {
        moveThrows = error
    }

    /// See `moveThrowsOnId` doc comment.
    func setMoveThrowsOnId(_ id: String, error: Error) {
        moveThrowsOnId = (id, error)
    }

    /// Clears a previously configured `setMoveThrowsOnId` — simulates the
    /// failure condition clearing (e.g. connection restored) so a retry
    /// against the SAME mock instance succeeds and its call recordings
    /// (`movedIds`) accumulate across both attempts.
    func clearMoveThrowsOnId() {
        moveThrowsOnId = nil
    }

    func setLegacyIdentityResolution(
        providerMessageId: String,
        result: LegacyMessageActionIdentityResolution
    ) {
        legacyIdentityResolutions[providerMessageId] = result
        legacyIdentityResolutionErrors.removeValue(forKey: providerMessageId)
    }

    func setLegacyIdentityResolutionError(
        providerMessageId: String,
        error: any Error
    ) {
        legacyIdentityResolutionErrors[providerMessageId] = error
        legacyIdentityResolutions.removeValue(forKey: providerMessageId)
    }

    func setLegacyIdentityResolutionHandler(
        _ handler: @escaping @Sendable (
            _ providerMessageId: String,
            _ sourceFolder: String,
            _ destinationFolder: String?
        ) async throws -> LegacyMessageActionIdentityResolution
    ) {
        legacyIdentityResolutionHandler = handler
    }

    func setMarkReadHook(_ hook: (@Sendable () async -> Void)?) {
        markReadHook = hook
    }

    func setSaveDraftHook(_ hook: (@Sendable () async -> Void)?) {
        saveDraftHook = hook
    }

    func setMoveHook(_ hook: (@Sendable () async -> Void)?) {
        moveHook = hook
    }

    /// Reset all recorded state.
    func reset() {
        callLog.removeAll()
        markedReadIds.removeAll()
        markedUnreadIds.removeAll()
        markedFlaggedIds.removeAll()
        markedRepliedIds.removeAll()
        markedForwardedIds.removeAll()
        userLabelChanges.removeAll()
        movedIds.removeAll()
        sentDrafts.removeAll()
        appendedToSent.removeAll()
        legacyIdentityResolutions.removeAll()
        legacyIdentityResolutionErrors.removeAll()
        legacyIdentityResolutionHandler = nil
        markReadHook = nil
        saveDraftHook = nil
        moveHook = nil
        legacyIdentityResolutionCalls.removeAll()
        statefulMessagesByRFCMessageId = nil
    }
}
