/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Dispatch
import Foundation
import GRDB
import Synchronization
@testable import TabMail

private final class GmailDeltaMetadataRequestGate: @unchecked Sendable {
    private struct State {
        var isEnabled = false
        var requestArrived = false
        var arrivalWaiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func enable() {
        state.withLock {
            $0.isEnabled = true
            $0.requestArrived = false
            $0.arrivalWaiter = nil
        }
    }

    func arriveAndWaitForRelease() {
        let arrival: (shouldWait: Bool, waiter: CheckedContinuation<Void, Never>?) =
            state.withLock {
                guard $0.isEnabled else { return (false, nil) }
                $0.requestArrived = true
                let waiter = $0.arrivalWaiter
                $0.arrivalWaiter = nil
                return (true, waiter)
            }
        arrival.waiter?.resume()
        if arrival.shouldWait {
            releaseSemaphore.wait()
        }
    }

    func waitUntilRequestArrives() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock {
                if $0.requestArrived {
                    return true
                }
                $0.arrivalWaiter = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let release = state.withLock {
            guard $0.isEnabled else { return false }
            $0.isEnabled = false
            if $0.requestArrived {
                return true
            }
            $0.arrivalWaiter?.resume()
            $0.arrivalWaiter = nil
            return false
        }
        if release { releaseSemaphore.signal() }
    }
}

private actor GmailDeltaProtectionCheckpointGate {
    private var didArrive = false
    private var shouldRelease = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWaitForRelease() async {
        didArrive = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil

        guard !shouldRelease else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilArrival() async {
        guard !didArrive else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiter = continuation
        }
    }

    func release() {
        shouldRelease = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class GmailDeltaFolderScopeURLProtocol: URLProtocol, @unchecked Sendable {
    private struct RemoteFlags: Sendable {
        var isRead = true
        var isFlagged = true
        var labelIds = ["Folder_A", "Folder_B", "Folder_X"]
        var historyDeletesMessage = false
    }

    static let messageId = "gmail-delta-folder-scope-message"
    static let sourcePath = "Folder_A"
    static let destinationPath = "Folder_B"
    static let externalPath = "Folder_X"
    static let metadataGate = GmailDeltaMetadataRequestGate()
    private static let remoteFlags = Mutex(RemoteFlags())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func configureRemoteFlags(isRead: Bool, isFlagged: Bool) {
        remoteFlags.withLock {
            $0.isRead = isRead
            $0.isFlagged = isFlagged
            // Every existing test starts from the canonical three-membership
            // response. A removal test may narrow this afterwards without
            // leaking static URLProtocol state into the next case.
            $0.labelIds = [sourcePath, destinationPath, externalPath]
            $0.historyDeletesMessage = false
        }
    }

    static func configureRemoteLabels(_ labelIds: [String]) {
        remoteFlags.withLock { $0.labelIds = labelIds }
    }

    static func configureMessageDeletedHistory() {
        remoteFlags.withLock { $0.historyDeletesMessage = true }
    }

    override func startLoading() {
        guard let url = request.url else {
            respond(statusCode: 400, body: Data())
            return
        }

        if url.path.hasSuffix("/history") {
            respond(statusCode: 200, body: Data(Self.historyJSON.utf8))
        } else if url.path.contains("/messages/\(Self.messageId)") {
            let body = Data(Self.messageJSON.utf8)
            Self.metadataGate.arriveAndWaitForRelease()
            respond(statusCode: 200, body: body)
        } else {
            respond(
                statusCode: 599,
                body: Data("unmatched Gmail delta test request".utf8)
            )
        }
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, body: Data) {
        let url = request.url ?? URL(string: "about:blank")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static var historyJSON: String {
        if remoteFlags.withLock({ $0.historyDeletesMessage }) {
            return """
            {
              "historyId": "history-after",
              "history": [{
                "messagesDeleted": [{
                  "message": {"id": "\(messageId)"}
                }]
              }]
            }
            """
        }
        return """
        {
          "historyId": "history-after",
          "history": [{
            "labelsAdded": [{
              "message": {
                "id": "\(messageId)",
                "labelIds": [\(labelIdsJSON)]
              },
              "labelIds": ["\(externalPath)"]
            }]
          }]
        }
        """
    }

    private static var messageJSON: String {
        let internalDate = Int64(Date().timeIntervalSince1970 * 1000)
        return """
        {
          "id": "\(messageId)",
          "threadId": "gmail-delta-folder-scope-thread",
          "internalDate": "\(internalDate)",
          "labelIds": [\(labelIdsJSON)],
          "payload": {
            "mimeType": "text/plain",
            "headers": [
              {"name": "Subject", "value": "Folder scoped delta"},
              {"name": "From", "value": "sender@example.com"},
              {"name": "To", "value": "recipient@example.com"},
              {"name": "Message-Id", "value": "<gmail-delta-folder-scope@example.com>"}
            ]
          }
        }
        """
    }

    private static var labelIdsJSON: String {
        let flags = remoteFlags.withLock { $0 }
        var labelIds = flags.labelIds
        if !flags.isRead { labelIds.append("UNREAD") }
        if flags.isFlagged { labelIds.append("STARRED") }
        return labelIds.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GmailDeltaFolderScopeURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ExchangeDeltaFieldURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var messageId = ""
        var folderPath = ""
        var receivedDateTime = ""
        var isRead = false
        var isFlagged = false
    }

    private static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func configure(
        messageId: String,
        folderPath: String,
        receivedDateTime: String,
        isRead: Bool,
        isFlagged: Bool
    ) {
        state.withLock {
            $0.messageId = messageId
            $0.folderPath = folderPath
            $0.receivedDateTime = receivedDateTime
            $0.isRead = isRead
            $0.isFlagged = isFlagged
        }
    }

    override func startLoading() {
        guard let url = request.url else {
            respond(statusCode: 400, body: Data())
            return
        }
        let snapshot = Self.state.withLock { $0 }
        if url.path.contains("field-purpose-delta") {
            let json = """
            {
              "value": [{"id": "\(snapshot.messageId)"}],
              "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/messages/field-purpose-delta-after"
            }
            """
            respond(statusCode: 200, body: Data(json.utf8))
        } else if url.path.contains("/messages/\(snapshot.messageId)") {
            let flagStatus = snapshot.isFlagged ? "flagged" : "notFlagged"
            let json = """
            {
              "id": "\(snapshot.messageId)",
              "subject": "Exchange field purpose",
              "from": {"emailAddress": {"name": "Sender", "address": "sender@example.com"}},
              "toRecipients": [{"emailAddress": {"address": "recipient@example.com"}}],
              "receivedDateTime": "\(snapshot.receivedDateTime)",
              "isRead": \(snapshot.isRead),
              "flag": {"flagStatus": "\(flagStatus)"},
              "hasAttachments": false,
              "internetMessageId": "<exchange-field-purpose@example.com>",
              "conversationId": "exchange-field-purpose-thread",
              "bodyPreview": "remote",
              "parentFolderId": "\(snapshot.folderPath)"
            }
            """
            respond(statusCode: 200, body: Data(json.utf8))
        } else {
            respond(
                statusCode: 599,
                body: Data("unmatched Exchange delta field test request".utf8)
            )
        }
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, body: Data) {
        let url = request.url ?? URL(string: "about:blank")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExchangeDeltaFieldURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Suite 1b: Gmail Delta — Folder-Scoped Recent Completion

/// Drives both real production paths involved in the regression: queue completion
/// publishes recent protection, then `SyncEngine.performDeltaSync` consumes a real
/// Gmail history + metadata response through `GmailProvider`.
@Suite("Gmail Delta — folder-scoped recent completion", .serialized, .processGlobalState)
struct GmailDeltaFolderScopedRecentCompletionTests {

    private func makeTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        return (pool, dir, previous)
    }

    private func restoreTestDB(
        pool: DatabasePool,
        previous: AppDatabase?,
        dir: URL
    ) {
        AppDatabase.shared.withLock { $0 = previous }
        try? pool.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private func verifyCompletedFieldOperation(
        _ operationType: OperationType,
        initialIsRead: Bool,
        initialIsFlagged: Bool,
        remoteIsRead: Bool,
        remoteIsFlagged: Bool,
        expectedIsRead: Bool,
        expectedIsFlagged: Bool,
        removeLocalBeforeDelta: Bool = false
    ) async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: remoteIsRead,
            isFlagged: remoteIsFlagged
        )

        let accountId = "gmail-delta-field-purpose-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        let durableMessageId = "gmail-delta-folder-scope@example.com"
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"

        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        var header = MessageHeader(
            messageId: messageId,
            subject: "Field-purpose delta",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        header.rfc822MessageId = durableMessageId
        header.headerComplete = true
        header.isRead = initialIsRead
        header.isFlagged = initialIsFlagged

        var operation = PendingOperation(
            type: operationType,
            messageIds: [durableMessageId],
            accountId: accountId,
            folderPath: destination.path
        )
        operation.status = PendingStatus.inFlight.rawValue

        let syncedAccount = account
        let persistedHeader = header
        let claimedOperation = operation
        try await pool.write { db in
            try syncedAccount.insert(db)
            try destination.insert(db)
            try persistedHeader.insert(db)
            try claimedOperation.insert(db)
        }

        let manager = AccountManager.shared
        await manager.recordRecentlyCompleted(
            messageIds: [messageId, "gmail-delta-folder-scope@example.com"],
            ttl: -1
        )
        await manager.pruneRecentlyCompleted()

        // Match Gmail's account-wide message identity. A folder-scoped mock
        // would publish keys the real Gmail delta consumer never reads.
        let actionProvider = MockEmailProvider(messageFieldScope: .account)
        let outcome = await manager.executeSingleOp(
            claimedOperation,
            provider: actionProvider,
            context: AccountManager.DrainContext()
        )
        #expect(outcome == .proceed)
        let completedValue: MessageIdentity.RecentlyCompletedFieldValue
        switch operationType {
        case .markRead:
            let readCalls = await actionProvider.markedReadIds
            #expect(readCalls.map(\.ids) == [[durableMessageId]])
            #expect(readCalls.map(\.folder) == [destination.path])
            completedValue = .read(true)
        case .markUnread:
            let unreadCalls = await actionProvider.markedUnreadIds
            #expect(unreadCalls.map(\.ids) == [[durableMessageId]])
            #expect(unreadCalls.map(\.folder) == [destination.path])
            completedValue = .read(false)
        case .markFlagged, .markUnflagged:
            let flagCalls = await actionProvider.markedFlaggedIds
            #expect(flagCalls.map(\.ids) == [[durableMessageId]])
            #expect(flagCalls.map(\.flagged) == [operationType == .markFlagged])
            #expect(flagCalls.map(\.folder) == [destination.path])
            completedValue = .flagged(operationType == .markFlagged)
        default:
            Issue.record("unsupported completed field operation \(operationType.rawValue)")
            return
        }

        let recentAfterCompletion = await manager.recentlyCompleted
        #expect(recentAfterCompletion[MessageIdentity.recentlyCompletedFieldKey(
            accountId: accountId,
            messageId: durableMessageId,
            field: completedValue.field
        )] != nil)
        #expect(recentAfterCompletion[MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: accountId,
            messageId: durableMessageId,
            value: completedValue
        )] != nil)
        #expect(recentAfterCompletion[messageId] == nil,
                "queue completion must not regress to an unscoped legacy id")

        if removeLocalBeforeDelta {
            let removed = try await pool.write { db in
                try MessageHeader.deleteOne(db, key: persistedHeader.id)
            }
            #expect(removed)
        }

        let gmailProvider = GmailProvider(
            userEmail: syncedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let result = try await SyncEngine().performDeltaSync(
            account: syncedAccount,
            provider: gmailProvider
        )
        #expect(result.succeeded)
        #expect(result.hadChanges)

        let refreshed = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedHeader.id)
        }
        let requiredRefreshed = try #require(refreshed)
        #expect(requiredRefreshed.isRead == expectedIsRead)
        #expect(requiredRefreshed.isFlagged == expectedIsFlagged)
        let advancedAccount = try await pool.read { db in
            try Account.fetchOne(db, key: accountId)
        }
        #expect(advancedAccount?.lastHistoryId == "history-after")
    }

    private func rowSurvivesDeletedHistory(
        pendingOperationType: OperationType?
    ) async throws -> Bool {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: true,
            isFlagged: false
        )
        GmailDeltaFolderScopeURLProtocol.configureMessageDeletedHistory()

        let accountId = "gmail-delta-delete-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"
        let folder = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        var header = MessageHeader(
            messageId: messageId,
            subject: "Deleted history",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "local",
            folderId: folder.id,
            accountId: accountId,
            folderPath: folder.path,
            isInInbox: false
        )
        header.rfc822MessageId = "<gmail-delta-delete@example.com>"
        header.headerComplete = true

        let persistedAccount = account
        let persistedHeader = header
        try await pool.write { db in
            try persistedAccount.insert(db)
            try folder.insert(db)
            try persistedHeader.insert(db)
            if let pendingOperationType {
                try PendingOperation(
                    type: pendingOperationType,
                    messageIds: ["gmail-delta-delete@example.com"],
                    accountId: accountId,
                    folderPath: folder.path
                ).insert(db)
            }
        }

        let provider = GmailProvider(
            userEmail: persistedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let result = try await SyncEngine().performDeltaSync(
            account: persistedAccount,
            provider: provider
        )
        #expect(result.succeeded)
        #expect(result.hadChanges)

        let advancedAccount = try await pool.read { db in
            try Account.fetchOne(db, key: accountId)
        }
        #expect(advancedAccount?.lastHistoryId == "history-after")
        return try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedHeader.id) != nil
        }
    }

    private func verifyOrphanReclaimReadResolution(
        operationType: OperationType,
        localIsRead: Bool,
        remoteIsRead: Bool,
        expectedIsRead: Bool,
        operationCompleted: Bool
    ) async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: remoteIsRead,
            isFlagged: true
        )
        GmailDeltaFolderScopeURLProtocol.configureRemoteLabels([
            GmailDeltaFolderScopeURLProtocol.destinationPath,
        ])

        let accountId = "gmail-delta-orphan-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        let durableMessageId = "gmail-delta-folder-scope@example.com"
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"
        let allMail = Folder(
            name: "All Mail",
            path: GmailProvider.archivePath,
            role: .archive,
            accountId: accountId
        )
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        // The primary key encodes Folder B, but the persisted folderId points at
        // synthetic All Mail. Gmail's tracked-folder loop skips All Mail, then
        // reaches Folder B through the real orphan-reclaim branch.
        var orphan = MessageHeader(
            messageId: messageId,
            subject: "Orphan reclaim",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "local",
            folderId: allMail.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        orphan.rfc822MessageId = "<\(durableMessageId)>"
        orphan.headerComplete = true
        orphan.isRead = localIsRead
        orphan.isFlagged = false

        var readOperation = PendingOperation(
            type: operationType,
            messageIds: [durableMessageId],
            accountId: accountId,
            folderPath: destination.path
        )
        if operationCompleted {
            readOperation.status = PendingStatus.inFlight.rawValue
        }
        let persistedAccount = account
        let persistedOrphan = orphan
        let persistedReadOperation = readOperation
        try await pool.write { db in
            try persistedAccount.insert(db)
            try allMail.insert(db)
            try destination.insert(db)
            try persistedOrphan.insert(db)
            try persistedReadOperation.insert(db)
        }

        let manager = AccountManager.shared
        if operationCompleted {
            let outcome = await manager.executeSingleOp(
                persistedReadOperation,
                provider: MockEmailProvider(messageFieldScope: .account),
                context: AccountManager.DrainContext()
            )
            #expect(outcome == .proceed)
        }

        let fieldKey = MessageIdentity.recentlyCompletedFieldKey(
            accountId: accountId,
            messageId: durableMessageId,
            field: .read
        )
        let genericKey = MessageIdentity.recentlyCompletedAccountKey(
            accountId: accountId,
            messageId: durableMessageId
        )
        let provider = GmailProvider(
            userEmail: persistedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )

        do {
            let result = try await SyncEngine().performDeltaSync(
                account: persistedAccount,
                provider: provider
            )
            #expect(result.succeeded)
            #expect(result.hadChanges)

            let reclaimed = try #require(try await pool.read { db in
                try MessageHeader.fetchOne(db, key: persistedOrphan.id)
            })
            #expect(reclaimed.folderId == destination.id)
            #expect(reclaimed.folderPath == destination.path)
            #expect(reclaimed.isRead == expectedIsRead)
            #expect(reclaimed.isFlagged,
                    "an unrelated remote flagged change must still converge")
        } catch {
            await ActiveBodyQueue.shared.cancelAllInFlight()
            try? await SearchIndex.shared.removeMessages(headerIds: [persistedOrphan.id])
            await manager.recordRecentlyCompleted(
                messageIds: [fieldKey, genericKey],
                ttl: -1
            )
            await manager.pruneRecentlyCompleted()
            throw error
        }

        await ActiveBodyQueue.shared.cancelAllInFlight()
        try await SearchIndex.shared.removeMessages(headerIds: [persistedOrphan.id])
        await manager.recordRecentlyCompleted(
            messageIds: [fieldKey, genericKey],
            ttl: -1
        )
        await manager.pruneRecentlyCompleted()
    }

    @Test("completed markRead protects read state but not an unrelated remote star")
    func completedMarkReadDoesNotSuppressRemoteStar() async throws {
        try await verifyCompletedFieldOperation(
            .markRead,
            initialIsRead: true,
            initialIsFlagged: false,
            remoteIsRead: false,
            remoteIsFlagged: true,
            expectedIsRead: true,
            expectedIsFlagged: true
        )
    }

    @Test("completed markFlagged protects star state but not an unrelated remote read")
    func completedMarkFlaggedDoesNotSuppressRemoteRead() async throws {
        try await verifyCompletedFieldOperation(
            .markFlagged,
            initialIsRead: false,
            initialIsFlagged: true,
            remoteIsRead: true,
            remoteIsFlagged: false,
            expectedIsRead: true,
            expectedIsFlagged: true
        )
    }

    @Test("completed markUnread restores a missing row with its exact negative value")
    func completedMarkUnreadRestoresMissingRowWithNegativeValue() async throws {
        try await verifyCompletedFieldOperation(
            .markUnread,
            initialIsRead: false,
            initialIsFlagged: false,
            remoteIsRead: true,
            remoteIsFlagged: true,
            expectedIsRead: false,
            expectedIsFlagged: true,
            removeLocalBeforeDelta: true
        )
    }

    @Test("unprotected deleted history removes the durable row")
    func deletedHistoryRemovesUnprotectedRow() async throws {
        let survives = try await rowSurvivesDeletedHistory(pendingOperationType: nil)
        #expect(survives == false)
    }

    @Test("pending destructive operation protects a row from deleted history")
    func pendingDeleteProtectsRowFromDeletedHistory() async throws {
        let survives = try await rowSurvivesDeletedHistory(pendingOperationType: .delete)
        #expect(survives)
    }

    @Test("orphan reclaim preserves pending read but applies remote flagged")
    func orphanReclaimPreservesPendingReadIntent() async throws {
        try await verifyOrphanReclaimReadResolution(
            operationType: .markRead,
            localIsRead: true,
            remoteIsRead: false,
            expectedIsRead: true,
            operationCompleted: false
        )
    }

    @Test("orphan reclaim preserves completed read but applies remote flagged")
    func orphanReclaimPreservesCompletedReadIntent() async throws {
        try await verifyOrphanReclaimReadResolution(
            operationType: .markRead,
            localIsRead: true,
            remoteIsRead: false,
            expectedIsRead: true,
            operationCompleted: true
        )
    }

    @Test("orphan reclaim preserves pending unread but applies remote flagged")
    func orphanReclaimPreservesPendingUnreadIntent() async throws {
        try await verifyOrphanReclaimReadResolution(
            operationType: .markUnread,
            localIsRead: false,
            remoteIsRead: true,
            expectedIsRead: false,
            operationCompleted: false
        )
    }

    @Test("orphan reclaim preserves completed unread but applies remote flagged")
    func orphanReclaimPreservesCompletedUnreadIntent() async throws {
        try await verifyOrphanReclaimReadResolution(
            operationType: .markUnread,
            localIsRead: false,
            remoteIsRead: true,
            expectedIsRead: false,
            operationCompleted: true
        )
    }

    @Test("push provenance survives field completion and protects only its exact row")
    func pushAndCompletedFieldComposeWithoutLosingRowProtection() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: false,
            isFlagged: false
        )
        GmailDeltaFolderScopeURLProtocol.configureRemoteLabels([])

        let accountId = "gmail-delta-push-protection-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        let unprotectedFolder = Folder(
            name: "Folder X",
            path: GmailDeltaFolderScopeURLProtocol.externalPath,
            role: .custom,
            accountId: accountId
        )
        var header = MessageHeader(
            messageId: messageId,
            subject: "Push-merged delta protection",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "local push metadata",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        header.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        header.headerComplete = true
        header.isRead = true
        header.isFlagged = true
        var unprotectedHeader = header
        unprotectedHeader.id = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: unprotectedFolder.path,
            messageId: messageId
        )
        unprotectedHeader.folderId = unprotectedFolder.id
        unprotectedHeader.folderPath = unprotectedFolder.path

        var operation = PendingOperation(
            type: .markRead,
            messageIds: ["gmail-delta-folder-scope@example.com"],
            accountId: accountId,
            folderPath: destination.path
        )
        operation.status = PendingStatus.inFlight.rawValue

        let persistedAccount = account
        let persistedHeader = header
        let persistedUnprotectedHeader = unprotectedHeader
        let claimedOperation = operation
        try await pool.write { db in
            try persistedAccount.insert(db)
            try destination.insert(db)
            try unprotectedFolder.insert(db)
            try persistedHeader.insert(db)
            try persistedUnprotectedHeader.insert(db)
            try claimedOperation.insert(db)
        }

        let manager = AccountManager.shared
        let rfcIdentity = "gmail-delta-folder-scope@example.com"
        let providerPushKey = MessageIdentity.recentlyCompletedPushKey(
            accountId: accountId,
            folderPath: destination.path,
            messageId: messageId
        )
        let rfcPushKey = MessageIdentity.recentlyCompletedPushKey(
            accountId: accountId,
            folderPath: destination.path,
            messageId: rfcIdentity
        )
        await manager.recordRecentlyCompleted(
            messageIds: [providerPushKey, rfcPushKey],
            ttl: SyncConfig.pushMergeStaleProtectionTTLSeconds
        )

        // A real queue completion now publishes a narrower field-purpose key.
        // The push row must retain its independent provenance and longer lifetime.
        let actionProvider = MockEmailProvider(messageFieldScope: .account)
        let outcome = await manager.executeSingleOp(
            claimedOperation,
            provider: actionProvider,
            context: AccountManager.DrainContext()
        )
        #expect(outcome == .proceed)
        let recentAfterCompletion = await manager.recentlyCompleted
        #expect(recentAfterCompletion[providerPushKey] != nil)
        #expect(recentAfterCompletion[MessageIdentity.recentlyCompletedFieldKey(
            accountId: accountId,
            messageId: rfcIdentity,
            field: .read
        )] != nil)

        let provider = GmailProvider(
            userEmail: persistedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let result = try await SyncEngine().performDeltaSync(
            account: persistedAccount,
            provider: provider
        )
        #expect(result.succeeded)
        #expect(result.hadChanges)

        let refreshed = try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedHeader.id)
        })
        #expect(refreshed.isRead)
        #expect(refreshed.isFlagged)
        let unprotectedSurvived = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedUnprotectedHeader.id) != nil
        }
        #expect(unprotectedSurvived == false,
                "push provenance must not blanket another folder membership")
    }

    @Test("push provenance protects an exact row from a transient deleted event")
    func pushProtectsExactRowFromDeletedHistory() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: true,
            isFlagged: true
        )
        GmailDeltaFolderScopeURLProtocol.configureMessageDeletedHistory()

        let accountId = "gmail-delta-push-delete-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        let unprotectedFolder = Folder(
            name: "Folder X",
            path: GmailDeltaFolderScopeURLProtocol.externalPath,
            role: .custom,
            accountId: accountId
        )
        var header = MessageHeader(
            messageId: messageId,
            subject: "Push delete protection",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "local push metadata",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        header.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        header.headerComplete = true
        var unprotectedHeader = header
        unprotectedHeader.id = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: unprotectedFolder.path,
            messageId: messageId
        )
        unprotectedHeader.folderId = unprotectedFolder.id
        unprotectedHeader.folderPath = unprotectedFolder.path

        let persistedAccount = account
        let persistedHeader = header
        let persistedUnprotectedHeader = unprotectedHeader
        try await pool.write { db in
            try persistedAccount.insert(db)
            try destination.insert(db)
            try unprotectedFolder.insert(db)
            try persistedHeader.insert(db)
            try persistedUnprotectedHeader.insert(db)
        }

        await AccountManager.shared.recordRecentlyCompleted(
            messageIds: [MessageIdentity.recentlyCompletedPushKey(
                accountId: accountId,
                folderPath: destination.path,
                messageId: messageId
            )],
            ttl: SyncConfig.pushMergeStaleProtectionTTLSeconds
        )

        let provider = GmailProvider(
            userEmail: persistedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let result = try await SyncEngine().performDeltaSync(
            account: persistedAccount,
            provider: provider
        )
        #expect(result.succeeded)
        #expect(result.hadChanges)

        let rowSurvived = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedHeader.id) != nil
        }
        #expect(rowSurvived)
        let unprotectedSurvived = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedUnprotectedHeader.id) != nil
        }
        #expect(unprotectedSurvived == false,
                "push provenance must protect only the exact deleted membership")
    }

    @Test("legacy bare recent id from another account cannot protect this account")
    func bareRecentIdentityCannotCrossAccounts() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: false,
            isFlagged: false
        )

        let accountId = "gmail-delta-cross-account-b-\(UUID().uuidString)"
        let otherAccountId = "gmail-delta-cross-account-a-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        var header = MessageHeader(
            messageId: messageId,
            subject: "Cross-account protection",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "local",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        header.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        header.headerComplete = true
        header.isRead = true
        header.isFlagged = true

        let persistedAccount = account
        let persistedHeader = header
        try await pool.write { db in
            try persistedAccount.insert(db)
            try destination.insert(db)
            try persistedHeader.insert(db)
        }

        let manager = AccountManager.shared
        await manager.recordRecentlyCompleted(messageIds: [
            messageId,
            MessageIdentity.recentlyCompletedFieldKey(
                accountId: otherAccountId,
                messageId: messageId,
                field: .read
            ),
        ])

        do {
            let provider = GmailProvider(
                userEmail: persistedAccount.emailAddress,
                accessToken: { _ in "test-token" },
                session: GmailDeltaFolderScopeURLProtocol.makeSession()
            )
            let result = try await SyncEngine().performDeltaSync(
                account: persistedAccount,
                provider: provider
            )
            #expect(result.succeeded)
            #expect(result.hadChanges)

            let refreshed = try #require(try await pool.read { db in
                try MessageHeader.fetchOne(db, key: persistedHeader.id)
            })
            #expect(refreshed.isRead == false)
            #expect(refreshed.isFlagged == false)
        } catch {
            await manager.recordRecentlyCompleted(messageIds: [messageId], ttl: -1)
            await manager.pruneRecentlyCompleted()
            throw error
        }

        await manager.recordRecentlyCompleted(messageIds: [messageId], ttl: -1)
        await manager.pruneRecentlyCompleted()
    }

    @Test("pending field operation does not suppress an unrelated remote label removal")
    func pendingReadDoesNotSuppressRemoteLabelRemoval() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: true,
            isFlagged: false
        )
        GmailDeltaFolderScopeURLProtocol.configureRemoteLabels([
            GmailDeltaFolderScopeURLProtocol.externalPath
        ])

        let accountId = "gmail-delta-field-membership-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"
        let source = Folder(
            name: "Folder A",
            path: GmailDeltaFolderScopeURLProtocol.sourcePath,
            role: .custom,
            accountId: accountId
        )
        let external = Folder(
            name: "Folder X",
            path: GmailDeltaFolderScopeURLProtocol.externalPath,
            role: .custom,
            accountId: accountId
        )
        var sourceHeader = MessageHeader(
            messageId: messageId,
            subject: "Remote label removal",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: source.id,
            accountId: accountId,
            folderPath: source.path,
            isInInbox: false
        )
        sourceHeader.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        sourceHeader.headerComplete = true
        sourceHeader.isRead = true
        let pendingRead = PendingOperation(
            type: .markRead,
            messageIds: ["gmail-delta-folder-scope@example.com"],
            accountId: accountId,
            folderPath: source.path
        )

        let persistedAccount = account
        let persistedSourceHeader = sourceHeader
        try await pool.write { db in
            try persistedAccount.insert(db)
            try source.insert(db)
            try external.insert(db)
            try persistedSourceHeader.insert(db)
            try pendingRead.insert(db)
        }

        let provider = GmailProvider(
            userEmail: persistedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let result = try await SyncEngine().performDeltaSync(
            account: persistedAccount,
            provider: provider
        )
        #expect(result.succeeded)
        #expect(result.hadChanges)

        let sourceHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: source.path,
            messageId: messageId
        )
        let externalHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: external.path,
            messageId: messageId
        )
        let memberships = try await pool.read { db in
            try MessageHeader
                .filter(Column("accountId") == accountId && Column("messageId") == messageId)
                .fetchAll(db)
        }
        #expect(memberships.contains(where: { $0.id == sourceHeaderId }) == false)
        #expect(memberships.contains(where: { $0.id == externalHeaderId }))

        await ActiveBodyQueue.shared.cancelAllInFlight()
        try? await SearchIndex.shared.removeMessages(
            headerIds: [sourceHeaderId, externalHeaderId]
        )
    }

    @Test("recent move protects only its source membership; external label and remote flags still apply")
    func recentMoveDoesNotSuppressUnrelatedExternalLabelOrFlags() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: true,
            isFlagged: true
        )

        let accountId = "gmail-delta-folder-scope-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"

        let source = Folder(
            name: "Folder A",
            path: GmailDeltaFolderScopeURLProtocol.sourcePath,
            role: .custom,
            accountId: accountId
        )
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        let external = Folder(
            name: "Folder X",
            path: GmailDeltaFolderScopeURLProtocol.externalPath,
            role: .custom,
            accountId: accountId
        )

        var destinationHeader = MessageHeader(
            messageId: messageId,
            subject: "Folder scoped delta",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        destinationHeader.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        destinationHeader.headerComplete = true

        var operation = PendingOperation(
            type: .move,
            messageIds: ["gmail-delta-folder-scope@example.com"],
            accountId: accountId,
            folderPath: source.path,
            destinationPath: destination.path
        )
        operation.status = PendingStatus.inFlight.rawValue

        let syncedAccount = account
        let persistedDestinationHeader = destinationHeader
        let claimedOperation = operation
        try await pool.write { db in
            try syncedAccount.insert(db)
            try source.insert(db)
            try destination.insert(db)
            try external.insert(db)
            try persistedDestinationHeader.insert(db)
            try claimedOperation.insert(db)
        }

        let moveProvider = MockEmailProvider()
        let outcome = await AccountManager.shared.executeSingleOp(
            claimedOperation,
            provider: moveProvider,
            context: AccountManager.DrainContext()
        )
        #expect(outcome == .proceed)
        let moveCalls = await moveProvider.movedIds
        #expect(moveCalls.map { $0.from } == [source.path])
        #expect(moveCalls.map { $0.to } == [destination.path])

        let gmailProvider = GmailProvider(
            userEmail: syncedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let syncEngine = SyncEngine()

        let sourceHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: source.path,
            messageId: messageId
        )
        let destinationHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: destination.path,
            messageId: messageId
        )
        let externalHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: external.path,
            messageId: messageId
        )
        let cleanupHeaderIds = [sourceHeaderId, destinationHeaderId, externalHeaderId]

        do {
            let result = try await syncEngine.performDeltaSync(
                account: syncedAccount,
                provider: gmailProvider
            )
            #expect(result.succeeded)
            #expect(result.hadChanges)

            let memberships = try await pool.read { db in
                try MessageHeader
                    .filter(
                        Column("accountId") == accountId &&
                        Column("messageId") == messageId
                    )
                    .fetchAll(db)
            }
            #expect(Set(memberships.map(\.folderPath)) == Set([destination.path, external.path]))
            #expect(memberships.contains(where: { $0.id == sourceHeaderId }) == false)
            #expect(memberships.contains(where: { $0.id == destinationHeaderId }))
            #expect(memberships.contains(where: { $0.id == externalHeaderId }))
            let refreshedDestination = try #require(
                memberships.first(where: { $0.id == destinationHeaderId })
            )
            #expect(refreshedDestination.isRead)
            #expect(refreshedDestination.isFlagged)
        } catch {
            await ActiveBodyQueue.shared.cancelAllInFlight()
            try? await SearchIndex.shared.removeMessages(headerIds: cleanupHeaderIds)
            throw error
        }

        await ActiveBodyQueue.shared.cancelAllInFlight()
        try? await SearchIndex.shared.removeMessages(headerIds: cleanupHeaderIds)
    }

    @Test("delta snapshot before move completion still protects the stale source membership")
    func moveCompletionDuringMetadataFetchProtectsSourceMembership() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: true,
            isFlagged: true
        )

        let accountId = "gmail-delta-snapshot-race-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"

        let source = Folder(
            name: "Folder A",
            path: GmailDeltaFolderScopeURLProtocol.sourcePath,
            role: .custom,
            accountId: accountId
        )
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        let external = Folder(
            name: "Folder X",
            path: GmailDeltaFolderScopeURLProtocol.externalPath,
            role: .custom,
            accountId: accountId
        )

        var destinationHeader = MessageHeader(
            messageId: messageId,
            subject: "Folder scoped delta",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        destinationHeader.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        destinationHeader.headerComplete = true

        var operation = PendingOperation(
            type: .move,
            messageIds: ["gmail-delta-folder-scope@example.com"],
            accountId: accountId,
            folderPath: source.path,
            destinationPath: destination.path
        )
        operation.status = PendingStatus.inFlight.rawValue

        let syncedAccount = account
        let persistedDestinationHeader = destinationHeader
        let claimedOperation = operation
        try await pool.write { db in
            try syncedAccount.insert(db)
            try source.insert(db)
            try destination.insert(db)
            try external.insert(db)
            try persistedDestinationHeader.insert(db)
            try claimedOperation.insert(db)
        }

        let sourceHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: source.path,
            messageId: messageId
        )
        let destinationHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: destination.path,
            messageId: messageId
        )
        let externalHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: external.path,
            messageId: messageId
        )
        let cleanupHeaderIds = [sourceHeaderId, destinationHeaderId, externalHeaderId]
        let sourceMembershipKey = MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: source.path,
            messageId: "gmail-delta-folder-scope@example.com",
            membership: .removedSource
        )

        let manager = AccountManager.shared
        await manager.recordRecentlyCompleted(
            messageIds: [sourceMembershipKey],
            ttl: -1
        )
        await manager.pruneRecentlyCompleted()
        let recentBeforeDelta = await manager.recentlyCompleted
        #expect(recentBeforeDelta[sourceMembershipKey] == nil)

        let gmailProvider = GmailProvider(
            userEmail: syncedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let syncEngine = SyncEngine()
        let metadataGate = GmailDeltaFolderScopeURLProtocol.metadataGate
        metadataGate.enable()

        let deltaTask = Task {
            try await syncEngine.performDeltaSync(
                account: syncedAccount,
                provider: gmailProvider
            )
        }

        do {
            // Reaching the metadata request proves delta already captured its old
            // recently-completed snapshot. Hold the response while the real action
            // path publishes the source-membership completion.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await metadataGate.waitUntilRequestArrives()
            }

            let moveProvider = MockEmailProvider()
            let outcome = await manager.executeSingleOp(
                claimedOperation,
                provider: moveProvider,
                context: AccountManager.DrainContext()
            )
            #expect(outcome == .proceed)

            let recentAfterCompletion = await manager.recentlyCompleted
            #expect(recentAfterCompletion[sourceMembershipKey] != nil)

            metadataGate.release()
            let result = try await deltaTask.value
            #expect(result.succeeded)
            #expect(result.hadChanges)

            let memberships = try await pool.read { db in
                try MessageHeader
                    .filter(
                        Column("accountId") == accountId &&
                        Column("messageId") == messageId
                    )
                    .fetchAll(db)
            }
            #expect(Set(memberships.map(\.folderPath)) == Set([destination.path, external.path]))
            #expect(memberships.contains(where: { $0.id == sourceHeaderId }) == false)
            #expect(memberships.contains(where: { $0.id == destinationHeaderId }))
            #expect(memberships.contains(where: { $0.id == externalHeaderId }))
        } catch {
            metadataGate.release()
            deltaTask.cancel()
            _ = try? await deltaTask.value
            await ActiveBodyQueue.shared.cancelAllInFlight()
            try? await SearchIndex.shared.removeMessages(headerIds: cleanupHeaderIds)
            throw error
        }

        await ActiveBodyQueue.shared.cancelAllInFlight()
        try? await SearchIndex.shared.removeMessages(headerIds: cleanupHeaderIds)
    }

    @Test("move completion between recent and pending snapshots protects stale source membership")
    func moveCompletionInProtectionSnapshotMicrogapProtectsSourceMembership() async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }
        GmailDeltaFolderScopeURLProtocol.metadataGate.release()
        GmailDeltaFolderScopeURLProtocol.configureRemoteFlags(
            isRead: true,
            isFlagged: true
        )

        let accountId = "gmail-delta-protection-microgap-\(UUID().uuidString)"
        let messageId = GmailDeltaFolderScopeURLProtocol.messageId
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = "history-before"

        let source = Folder(
            name: "Folder A",
            path: GmailDeltaFolderScopeURLProtocol.sourcePath,
            role: .custom,
            accountId: accountId
        )
        let destination = Folder(
            name: "Folder B",
            path: GmailDeltaFolderScopeURLProtocol.destinationPath,
            role: .custom,
            accountId: accountId
        )
        let external = Folder(
            name: "Folder X",
            path: GmailDeltaFolderScopeURLProtocol.externalPath,
            role: .custom,
            accountId: accountId
        )

        var destinationHeader = MessageHeader(
            messageId: messageId,
            subject: "Folder scoped delta",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: destination.id,
            accountId: accountId,
            folderPath: destination.path,
            isInInbox: false
        )
        destinationHeader.rfc822MessageId = "gmail-delta-folder-scope@example.com"
        destinationHeader.headerComplete = true

        var operation = PendingOperation(
            type: .move,
            messageIds: ["gmail-delta-folder-scope@example.com"],
            accountId: accountId,
            folderPath: source.path,
            destinationPath: destination.path
        )
        operation.status = PendingStatus.inFlight.rawValue

        let syncedAccount = account
        let persistedDestinationHeader = destinationHeader
        let claimedOperation = operation
        try await pool.write { db in
            try syncedAccount.insert(db)
            try source.insert(db)
            try destination.insert(db)
            try external.insert(db)
            try persistedDestinationHeader.insert(db)
            try claimedOperation.insert(db)
        }

        let sourceHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: source.path,
            messageId: messageId
        )
        let sourceMembershipKey = MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: source.path,
            messageId: "gmail-delta-folder-scope@example.com",
            membership: .removedSource
        )
        let destinationHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: destination.path,
            messageId: messageId
        )
        let externalHeaderId = MessageIdentity.headerId(
            accountId: accountId,
            folderPath: external.path,
            messageId: messageId
        )
        let cleanupHeaderIds = [sourceHeaderId, destinationHeaderId, externalHeaderId]

        let manager = AccountManager.shared
        await manager.recordRecentlyCompleted(
            messageIds: [sourceMembershipKey],
            ttl: -1
        )
        await manager.pruneRecentlyCompleted()
        let recentBeforeDelta = await manager.recentlyCompleted
        #expect(recentBeforeDelta[sourceMembershipKey] == nil)

        let checkpoint = SyncEngine.GmailDeltaProtectionCheckpointForTesting
            .afterNetworkBeforeProtectionReservation(accountId: accountId)
        let checkpointGate = GmailDeltaProtectionCheckpointGate()
        SyncEngine.gmailDeltaProtectionCheckpointHooksForTesting.withLock {
            $0[checkpoint] = {
                await checkpointGate.arriveAndWaitForRelease()
            }
        }

        let gmailProvider = GmailProvider(
            userEmail: syncedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: GmailDeltaFolderScopeURLProtocol.makeSession()
        )
        let syncEngine = SyncEngine()
        let deltaTask = Task {
            try await syncEngine.performDeltaSync(
                account: syncedAccount,
                provider: gmailProvider
            )
        }

        do {
            // Delta has completed its network reads but has not yet reserved the
            // writer and sampled actor + durable protection as one boundary.
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
                await checkpointGate.waitUntilArrival()
            }

            let moveProvider = MockEmailProvider()
            let outcome = await manager.executeSingleOp(
                claimedOperation,
                provider: moveProvider,
                context: AccountManager.DrainContext()
            )
            #expect(outcome == .proceed)

            let recentAfterCompletion = await manager.recentlyCompleted
            #expect(recentAfterCompletion[sourceMembershipKey] != nil)

            await checkpointGate.release()
            let result = try await deltaTask.value
            #expect(result.succeeded)
            #expect(result.hadChanges)

            let memberships = try await pool.read { db in
                try MessageHeader
                    .filter(
                        Column("accountId") == accountId &&
                        Column("messageId") == messageId
                    )
                    .fetchAll(db)
            }
            #expect(Set(memberships.map(\.folderPath)) == Set([destination.path, external.path]))
            #expect(memberships.contains(where: { $0.id == sourceHeaderId }) == false)
            #expect(memberships.contains(where: { $0.id == destinationHeaderId }))
            #expect(memberships.contains(where: { $0.id == externalHeaderId }))
        } catch {
            SyncEngine.gmailDeltaProtectionCheckpointHooksForTesting.withLock {
                _ = $0.removeValue(forKey: checkpoint)
            }
            await checkpointGate.release()
            deltaTask.cancel()
            _ = try? await deltaTask.value
            await ActiveBodyQueue.shared.cancelAllInFlight()
            try? await SearchIndex.shared.removeMessages(headerIds: cleanupHeaderIds)
            throw error
        }

        SyncEngine.gmailDeltaProtectionCheckpointHooksForTesting.withLock {
            _ = $0.removeValue(forKey: checkpoint)
        }
        await ActiveBodyQueue.shared.cancelAllInFlight()
        try? await SearchIndex.shared.removeMessages(headerIds: cleanupHeaderIds)
    }
}

// MARK: - Suite 1c: Exchange Delta — Field-Scoped Protection

/// Drives real Graph delta/history parsing and the real Exchange upsert. Advancing
/// the delta cursor makes a cross-field suppression permanent, so a read intention
/// may protect only read and a flagged intention may protect only flagged.
@Suite("Exchange Delta — field-scoped protection", .serialized, .processGlobalState)
struct ExchangeDeltaFieldScopedProtectionTests {
    private enum ProtectedField {
        case read
        case flagged

        var operationType: OperationType {
            switch self {
            case .read: .markRead
            case .flagged: .markFlagged
            }
        }
    }

    private func makeTestDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        return (pool, dir, previous)
    }

    private func restoreTestDB(
        pool: DatabasePool,
        previous: AppDatabase?,
        dir: URL
    ) {
        AppDatabase.shared.withLock { $0 = previous }
        try? pool.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private func verifyProtection(
        _ protectedField: ProtectedField,
        operationCompleted: Bool
    ) async throws {
        let (pool, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir) }

        let accountId = "exchange-delta-field-\(UUID().uuidString)"
        let messageId = "exchange-current-\(UUID().uuidString)"
        let folderPath = "graph-folder-d"
        let now = Date()
        let receivedDateTime = ISO8601DateFormatter().string(from: now)
        let protectsRead = protectedField.operationType == .markRead

        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .outlook
        )
        account.id = accountId
        account.lastHistoryId =
            "https://graph.microsoft.com/v1.0/me/messages/field-purpose-delta-before"
        let folder = Folder(
            name: "Folder D",
            path: folderPath,
            role: .inbox,
            accountId: accountId
        )
        var header = MessageHeader(
            messageId: messageId,
            subject: "Exchange field purpose",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: now.addingTimeInterval(-60),
            snippet: "local",
            folderId: folder.id,
            accountId: accountId,
            folderPath: folder.path,
            isInInbox: true
        )
        header.rfc822MessageId = "exchange-field-purpose@example.com"
        let durableMessageId = "exchange-field-purpose@example.com"
        header.headerComplete = true
        header.isRead = protectsRead
        header.isFlagged = !protectsRead

        var operation = PendingOperation(
            type: protectedField.operationType,
            messageIds: [durableMessageId],
            accountId: accountId,
            folderPath: folder.path
        )
        operation.status = operationCompleted
            ? PendingStatus.inFlight.rawValue
            : PendingStatus.queued.rawValue

        let persistedAccount = account
        let persistedHeader = header
        let persistedOperation = operation
        try await pool.write { db in
            try persistedAccount.insert(db)
            try folder.insert(db)
            try persistedHeader.insert(db)
            try persistedOperation.insert(db)
        }

        if operationCompleted {
            let actionProvider = MockEmailProvider(messageFieldScope: .account)
            let outcome = await AccountManager.shared.executeSingleOp(
                persistedOperation,
                provider: actionProvider,
                context: AccountManager.DrainContext()
            )
            #expect(outcome == .proceed)
            let completedValue: MessageIdentity.RecentlyCompletedFieldValue = protectsRead
                ? .read(true)
                : .flagged(true)
            let recentlyCompleted = await AccountManager.shared.recentlyCompleted
            #expect(recentlyCompleted[MessageIdentity.recentlyCompletedFieldKey(
                accountId: accountId,
                messageId: durableMessageId,
                field: completedValue.field
            )] != nil)
            #expect(recentlyCompleted[MessageIdentity.recentlyCompletedFieldValueKey(
                accountId: accountId,
                messageId: durableMessageId,
                value: completedValue
            )] != nil)
        }

        ExchangeDeltaFieldURLProtocol.configure(
            messageId: messageId,
            folderPath: folder.path,
            receivedDateTime: receivedDateTime,
            isRead: !protectsRead,
            isFlagged: protectsRead
        )
        let provider = ExchangeProvider(
            userEmail: persistedAccount.emailAddress,
            accessToken: { _ in "test-token" },
            session: ExchangeDeltaFieldURLProtocol.makeSession()
        )
        let result = try await SyncEngine().performDeltaSync(
            account: persistedAccount,
            provider: provider
        )
        #expect(result.succeeded)
        #expect(result.hadChanges)

        let refreshed = try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedHeader.id)
        })
        #expect(refreshed.isRead)
        #expect(refreshed.isFlagged)
        let advancedAccount = try #require(try await pool.read { db in
            try Account.fetchOne(db, key: accountId)
        })
        #expect(advancedAccount.lastHistoryId?.contains("field-purpose-delta-after") == true)
    }

    @Test("pending markRead protects read but applies unrelated remote flagged")
    func pendingReadDoesNotSuppressRemoteFlagged() async throws {
        try await verifyProtection(.read, operationCompleted: false)
    }

    @Test("completed markRead protects read but applies unrelated remote flagged")
    func completedReadDoesNotSuppressRemoteFlagged() async throws {
        try await verifyProtection(.read, operationCompleted: true)
    }

    @Test("pending markFlagged protects flagged but applies unrelated remote read")
    func pendingFlaggedDoesNotSuppressRemoteRead() async throws {
        try await verifyProtection(.flagged, operationCompleted: false)
    }

    @Test("completed markFlagged protects flagged but applies unrelated remote read")
    func completedFlaggedDoesNotSuppressRemoteRead() async throws {
        try await verifyProtection(.flagged, operationCompleted: true)
    }
}

// MARK: - Suite 3: PendingCalendarOperation — GRDB Patterns

@Suite("PendingCalendarOperation — GRDB Patterns")
struct PendingCalendarOperationGRDBTests {

    @Test("Insert and fetch by status")
    func insertAndFetchByStatus() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(
            db, id: "acc1", email: "calendar@example.com", provider: .gmail
        )

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            eventId: "evt-1",
            arguments: ["summary": .string("Team Meeting"), "all_day": .bool(false)]
        )
        try db.write { dbConn in try op.insert(dbConn) }

        // Fetch by queued status
        let queued = try db.read { dbConn in
            try PendingCalendarOperation
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(dbConn)
        }
        #expect(queued.count == 1)
        guard queued.count == 1 else { return }
        #expect(queued[0].id == op.id)
        #expect(queued[0].operationType == CalendarOperationType.create.rawValue)
        #expect(queued[0].eventId == "evt-1")
        #expect(queued[0].status == PendingStatus.queued.rawValue)

        // Fetch by inFlight status — should be empty
        let inFlight = try db.read { dbConn in
            try PendingCalendarOperation
                .filter(Column("status") == PendingStatus.inFlight.rawValue)
                .fetchAll(dbConn)
        }
        #expect(inFlight.isEmpty)
    }

    @Test("Status transitions: pending → inFlight → completed (deleted)")
    func statusTransitions() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(
            db, id: "acc1", email: "calendar@example.com", provider: .gmail
        )

        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            eventId: "evt-2",
            arguments: ["summary": .string("Updated Meeting")]
        )
        try db.write { dbConn in try op.insert(dbConn) }

        // Transition to inFlight
        try db.write { dbConn in
            guard var fetched = try PendingCalendarOperation.fetchOne(dbConn, key: op.id) else {
                Issue.record("Op not found")
                return
            }
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(dbConn)
        }

        let inFlight = try db.read { dbConn in
            try PendingCalendarOperation.fetchOne(dbConn, key: op.id)
        }
        #expect(inFlight?.status == PendingStatus.inFlight.rawValue)

        // On success, delete the operation (completed)
        try db.write { dbConn in
            _ = try PendingCalendarOperation.deleteOne(dbConn, key: op.id)
        }

        let deleted = try db.read { dbConn in
            try PendingCalendarOperation.fetchOne(dbConn, key: op.id)
        }
        #expect(deleted == nil)
    }

    @Test("Retry count increment on failure")
    func retryCountIncrement() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(
            db, id: "acc1", email: "calendar@example.com", provider: .gmail
        )

        let op = PendingCalendarOperation(
            operationType: .delete,
            accountId: "acc1",
            eventId: "evt-3",
            arguments: [:]
        )
        try db.write { dbConn in try op.insert(dbConn) }
        #expect(op.retryCount == 0)

        // Simulate failure: mark inFlight, then reset to queued with retryCount incremented
        try db.write { dbConn in
            guard var fetched = try PendingCalendarOperation.fetchOne(dbConn, key: op.id) else {
                Issue.record("Op not found")
                return
            }
            fetched.status = PendingStatus.inFlight.rawValue
            try fetched.save(dbConn)
        }

        // Transient error — reset to queued, increment retry
        try db.write { dbConn in
            guard var fetched = try PendingCalendarOperation.fetchOne(dbConn, key: op.id) else {
                Issue.record("Op not found")
                return
            }
            fetched.status = PendingStatus.queued.rawValue
            fetched.retryCount += 1
            try fetched.save(dbConn)
        }

        let afterFirstRetry = try db.read { dbConn in
            try PendingCalendarOperation.fetchOne(dbConn, key: op.id)
        }
        #expect(afterFirstRetry?.retryCount == 1)
        #expect(afterFirstRetry?.status == PendingStatus.queued.rawValue)

        // Second failure
        try db.write { dbConn in
            guard var fetched = try PendingCalendarOperation.fetchOne(dbConn, key: op.id) else {
                Issue.record("Op not found")
                return
            }
            fetched.status = PendingStatus.queued.rawValue
            fetched.retryCount += 1
            try fetched.save(dbConn)
        }

        let afterSecondRetry = try db.read { dbConn in
            try PendingCalendarOperation.fetchOne(dbConn, key: op.id)
        }
        #expect(afterSecondRetry?.retryCount == 2)
    }

    @Test("Filter by accountId")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(
            db, id: "acc1", email: "calendar-one@example.com", provider: .gmail
        )
        try TestDatabase.insertAccount(
            db, id: "acc2", email: "calendar-two@example.com", provider: .gmail
        )

        let op1 = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: ["summary": .string("Meeting 1")]
        )
        let op2 = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc2",
            arguments: ["summary": .string("Meeting 2")]
        )
        let op3 = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            eventId: "evt-x",
            arguments: ["summary": .string("Updated")]
        )
        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let acc1Ops = try db.read { dbConn in
            try PendingCalendarOperation
                .filter(Column("accountId") == "acc1")
                .fetchAll(dbConn)
        }
        #expect(acc1Ops.count == 2)

        let acc2Ops = try db.read { dbConn in
            try PendingCalendarOperation
                .filter(Column("accountId") == "acc2")
                .fetchAll(dbConn)
        }
        #expect(acc2Ops.count == 1)
    }

    @Test("Cascade delete with account")
    func cascadeDeleteWithAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(
            db, id: "acc-del", email: "delete-me@example.com", provider: .gmail
        )

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc-del",
            arguments: ["summary": .string("Will be cascade deleted")]
        )
        try db.write { dbConn in try op.insert(dbConn) }

        // Verify it exists
        let beforeDelete = try db.read { dbConn in
            try PendingCalendarOperation.filter(Column("accountId") == "acc-del").fetchCount(dbConn)
        }
        #expect(beforeDelete == 1)

        // Delete the account — FK CASCADE should delete the calendar op
        try db.write { dbConn in
            _ = try Account.deleteOne(dbConn, key: "acc-del")
        }

        let afterDelete = try db.read { dbConn in
            try PendingCalendarOperation.filter(Column("accountId") == "acc-del").fetchCount(dbConn)
        }
        #expect(afterDelete == 0)
    }
}
