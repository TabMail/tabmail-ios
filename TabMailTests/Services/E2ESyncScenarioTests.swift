/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Test Helpers

/// Builds a realistic MessageHeaderInfo with sensible defaults.
private func makeHeaderInfo(
    messageId: String = "100",
    rfc822MessageId: String? = "<msg-100@example.com>",
    inReplyTo: String? = nil,
    references: [String] = [],
    threadId: String? = nil,
    subject: String = "Test Subject",
    from: String = "Alice Smith",
    fromAddress: String = "alice@example.com",
    to: String = "bob@example.com",
    cc: String = "",
    bcc: String = "",
    replyTo: String? = nil,
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    snippet: String = "Test snippet",
    isRead: Bool = false,
    isFlagged: Bool = false,
    hasAttachments: Bool = false,
    isReplied: Bool = false,
    isForwarded: Bool = false,
    actionTag: ActionTag? = nil
) -> MessageHeaderInfo {
    MessageHeaderInfo(
        messageId: messageId,
        rfc822MessageId: rfc822MessageId,
        inReplyTo: inReplyTo,
        references: [],
        threadId: threadId,
        subject: subject,
        from: from,
        fromAddress: fromAddress,
        to: to,
        cc: cc,
        bcc: bcc,
        replyTo: replyTo,
        date: date,
        snippet: snippet,
        isRead: isRead,
        isFlagged: isFlagged,
        hasAttachments: hasAttachments,
        isReplied: isReplied,
        isForwarded: isForwarded,
        actionTag: actionTag
    )
}

/// Simulates the core of `SyncEngine.runSyncMessages()` against a DatabaseQueue.
/// Replicates upsert + stale detection logic for testing.
private func simulateRunSyncMessages(
    db: DatabaseQueue,
    folder: Folder,
    messages: [MessageHeaderInfo],
    limit: Int,
    undoProtectedIds: Set<String> = [],
    windowMode: StaleWindowMode = .date
) throws -> (newHeaders: [MessageHeader], staleIds: [String]) {
    let folderPath = folder.path
    let folderId = folder.id
    let accountId = folder.accountId
    let isInInbox = folder.role == .inbox

    return try db.write { dbConn in
        // Load pending operations
        let pendingOps = try PendingOperation.fetchAll(dbConn)
        let opsForThisFolder = pendingOps.filter { $0.accountId == accountId && $0.folderPath == folderPath }
        let pendingDestructiveIds = Set(
            opsForThisFolder
                .filter { [.archive, .delete, .move].contains($0.type) }
                .flatMap(\.messageIds)
        )
        let pendingFlagIds = Set(
            opsForThisFolder
                .filter { [.markRead, .markUnread, .markFlagged, .markUnflagged, .setTag, .removeTag].contains($0.type) }
                .flatMap(\.messageIds)
        )
        let isPendingDestructive: (MessageHeaderInfo) -> Bool = { info in
            pendingDestructiveIds.contains(info.messageId) ||
            (info.rfc822MessageId.map { pendingDestructiveIds.contains($0) } ?? false)
        }
        let isPendingFlag: (MessageHeaderInfo) -> Bool = { info in
            pendingFlagIds.contains(info.messageId) ||
            (info.rfc822MessageId.map { pendingFlagIds.contains($0) } ?? false)
        }
        let opsTargetingThisFolder = pendingOps.filter {
            $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
        }
        let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))

        var newHeaders: [MessageHeader] = []
        var staleIds: [String] = []

        // Stale detection — delegate to the production source of truth
        // (SyncEngine.selectStaleHeaders) so this harness can never drift from
        // real sync behavior. windowMode selects the UID (IMAP) vs date window.
        // Coverage models a server that returned `messages` verbatim for a window of
        // `limit` — the harness feeds `selectStaleHeaders` directly, so there is no
        // provider narrowing between the two and `messages.count` IS the server's
        // record count here. Real providers must NOT derive coverage this way; see
        // `FetchCoverage`.
        let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn)
        let stale = SyncEngine.selectStaleHeaders(
            candidates: allLocal, fetched: messages,
            coverage: FetchCoverage(
                serverRecordCount: messages.count,
                spansEntireFolder: messages.count < limit,
                unmaterialisedIds: []),
            windowMode: windowMode)

        let protectedIds = pendingAllIds.union(undoProtectedIds)
        let isProtected: (MessageHeader) -> Bool = { msg in
            protectedIds.contains(msg.messageId) ||
            (msg.rfc822MessageId.map { protectedIds.contains($0) } ?? false)
        }
        let staleFiltered = stale.filter { !isProtected($0) }
        staleIds = staleFiltered.map(\.id)
        for msg in staleFiltered {
            try msg.delete(dbConn)
        }

        // Upsert
        for info in messages where !isPendingDestructive(info) {
            if var existing = try MessageHeader
                .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                .fetchOne(dbConn) {
                let hasPendingFlags = isPendingFlag(info)
                if !hasPendingFlags {
                    existing.isRead = info.isRead
                    existing.isFlagged = info.isFlagged
                    if isInInbox, let serverTag = info.actionTag {
                        existing.actionTag = serverTag
                        existing.tagSortOrder = serverTag.sortOrder
                    }
                }
                existing.date = info.date
                existing.from = info.from
                existing.fromAddress = info.fromAddress
                existing.to = info.to
                try existing.update(dbConn)
            } else {
                var header = MessageHeader(
                    messageId: info.messageId,
                    subject: info.subject,
                    from: info.from,
                    fromAddress: info.fromAddress,
                    to: info.to,
                    date: info.date,
                    snippet: info.snippet,
                    folderId: folderId,
                    accountId: accountId,
                    folderPath: folderPath,
                    isInInbox: isInInbox
                )
                header.isRead = info.isRead
                header.isFlagged = info.isFlagged
                header.rfc822MessageId = info.rfc822MessageId
                header.threadId = info.threadId
                header.actionTag = info.actionTag
                if let tag = info.actionTag {
                    header.tagSortOrder = tag.sortOrder
                }
                try header.insert(dbConn)
                newHeaders.append(header)
            }
        }

        return (newHeaders, staleIds)
    }
}

/// Simple test error for provider failure simulation.
private struct TestSyncError: Error, Equatable {
    let message: String
    init(_ message: String = "test error") { self.message = message }
}

// MARK: - Suite 1: E2E Sync — Multi-Account

@Suite("E2E Sync — Multi-Account")
struct E2ESyncMultiAccountTests {

    @Test("Two accounts sync independently, messages don't cross-contaminate")
    func twoAccountsSyncIndependently() throws {
        let db = try TestDatabase.make()

        // Create two accounts
        try TestDatabase.insertAccount(db, id: "acc1", email: "user1@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "user2@example.com")

        // Create folders for each account
        let folder1 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let folder2 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        // Messages for account 1
        let acc1Messages = [
            makeHeaderInfo(messageId: "101", subject: "Acc1 Message 1", fromAddress: "alice@example.com"),
            makeHeaderInfo(messageId: "102", subject: "Acc1 Message 2", fromAddress: "alice@example.com"),
        ]

        // Messages for account 2
        let acc2Messages = [
            makeHeaderInfo(messageId: "201", subject: "Acc2 Message 1", fromAddress: "bob@example.com"),
            makeHeaderInfo(messageId: "202", subject: "Acc2 Message 2", fromAddress: "bob@example.com"),
            makeHeaderInfo(messageId: "203", subject: "Acc2 Message 3", fromAddress: "bob@example.com"),
        ]

        // Simulate sync for each account
        let result1 = try simulateRunSyncMessages(db: db, folder: folder1, messages: acc1Messages, limit: 50)
        let result2 = try simulateRunSyncMessages(db: db, folder: folder2, messages: acc2Messages, limit: 50)

        #expect(result1.newHeaders.count == 2)
        #expect(result2.newHeaders.count == 3)

        // Verify account isolation
        let acc1Headers = try db.read { try MessageHeader.filter(Column("accountId") == "acc1").fetchAll($0) }
        let acc2Headers = try db.read { try MessageHeader.filter(Column("accountId") == "acc2").fetchAll($0) }

        #expect(acc1Headers.count == 2)
        #expect(acc2Headers.count == 3)

        // No cross-contamination: acc1 subjects only belong to acc1
        let acc1Subjects = Set(acc1Headers.map(\.subject))
        #expect(acc1Subjects.contains("Acc1 Message 1"))
        #expect(acc1Subjects.contains("Acc1 Message 2"))
        #expect(!acc1Subjects.contains("Acc2 Message 1"))

        let acc2Subjects = Set(acc2Headers.map(\.subject))
        #expect(acc2Subjects.contains("Acc2 Message 1"))
        #expect(!acc2Subjects.contains("Acc1 Message 1"))
    }

    @Test("Delete account cascades to all its folders and messages")
    func deleteAccountCascades() throws {
        let db = try TestDatabase.make()

        try TestDatabase.insertAccount(db, id: "acc1", email: "user1@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        try TestDatabase.insertMessageHeader(db, messageId: "101", subject: "Hello", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "102", subject: "World", folderId: "acc1:Sent", accountId: "acc1", folderPath: "Sent", isInInbox: false)
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:101", htmlContent: "<p>Body</p>")

        // Verify data exists
        let headersBefore = try db.read { try MessageHeader.filter(Column("accountId") == "acc1").fetchCount($0) }
        #expect(headersBefore == 2)

        // Delete account — FK CASCADE should remove folders and messages
        try db.write { dbConn in
            let account = try Account.fetchOne(dbConn, key: "acc1")!
            try account.delete(dbConn)
        }

        // Verify cascade
        let accountsAfter = try db.read { try Account.fetchCount($0) }
        let foldersAfter = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchCount($0) }
        let headersAfter = try db.read { try MessageHeader.filter(Column("accountId") == "acc1").fetchCount($0) }

        #expect(accountsAfter == 0)
        #expect(foldersAfter == 0)
        #expect(headersAfter == 0)
    }

    @Test("Same subject different accounts — different threadIds")
    func sameSubjectDifferentAccountsDifferentThreadIds() throws {
        let db = try TestDatabase.make()

        try TestDatabase.insertAccount(db, id: "acc1", email: "user1@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "user2@example.com")
        let folder1 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let folder2 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        // Same subject, different thread IDs per account
        let msg1 = makeHeaderInfo(messageId: "101", threadId: "thread-acc1-1", subject: "Shared Subject")
        let msg2 = makeHeaderInfo(messageId: "201", threadId: "thread-acc2-1", subject: "Shared Subject")

        _ = try simulateRunSyncMessages(db: db, folder: folder1, messages: [msg1], limit: 50)
        _ = try simulateRunSyncMessages(db: db, folder: folder2, messages: [msg2], limit: 50)

        let h1 = try db.read { try MessageHeader.filter(Column("accountId") == "acc1").fetchOne($0)! }
        let h2 = try db.read { try MessageHeader.filter(Column("accountId") == "acc2").fetchOne($0)! }

        #expect(h1.subject == h2.subject)
        #expect(h1.threadId != h2.threadId)
        #expect(h1.threadId == "thread-acc1-1")
        #expect(h2.threadId == "thread-acc2-1")
    }
}

// MARK: - Suite 2: E2E Sync — Error Recovery

@Suite("E2E Sync — Error Recovery")
struct E2ESyncErrorRecoveryTests {

    @Test("Provider throws during fetchMessages — previously inserted folders preserved")
    func providerThrowsFetchMessagesFoldersPreserved() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")

        // Step 1: fetchFolders succeeds — insert folders into DB
        let folderInfos = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 5, totalCount: 20),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 10),
        ]
        await provider.setFetchFoldersResult(folderInfos)

        let folders = try await provider.fetchFolders()
        for info in folders {
            try TestDatabase.insertFolder(db, name: info.name, path: info.path, role: info.role, accountId: "acc1")
        }

        // Step 2: fetchMessages throws
        await provider.setFetchMessagesThrows(TestSyncError("IMAP timeout"))

        do {
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
            Issue.record("Expected fetchMessages to throw")
        } catch {
            // Expected
        }

        // Verify folders are still in DB
        let folderCount = try await db.read { try Folder.filter(Column("accountId") == "acc1").fetchCount($0) }
        #expect(folderCount == 2)
    }

    @Test("Provider throws during fetchMessage (body) — header preserved, no body")
    func providerThrowsFetchMessageHeaderPreservedNoBody() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        // fetchMessage (body fetch) throws
        await provider.setFetchMessageThrows(TestSyncError("body fetch failed"))

        do {
            _ = try await provider.fetchMessage(id: "100", folder: "INBOX")
            Issue.record("Expected fetchMessage to throw")
        } catch {
            // Expected — do NOT create a MessageBody
        }

        // Header still exists
        let headerExists = try await db.read { try MessageHeader.fetchOne($0, key: header.id) != nil }
        #expect(headerExists)

        // No body was created (data integrity: never mark unfetched as fetched)
        let bodyExists = try await db.read { try MessageBody.fetchOne($0, key: header.id) != nil }
        #expect(!bodyExists)
    }

    @Test("Provider throws during move — PendingOperation stays in queue for retry")
    func providerThrowsMoveOperationStaysForRetry() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        // Insert PendingOperation for move
        let op = PendingOperation(
            type: .archive,
            messageIds: ["100"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        let opId = op.id
        try await db.write { _ = try op.inserted($0) }

        // Provider throws on move
        await provider.setMoveThrows(TestSyncError("connection lost"))

        do {
            try await provider.move(ids: ["100"], from: "INBOX", to: "Archive")
            Issue.record("Expected move to throw")
        } catch {
            // Simulate drain failure: increment retryCount
            try await db.write { dbConn in
                if var pendingOp = try PendingOperation.fetchOne(dbConn, key: opId) {
                    pendingOp.retryCount += 1
                    try pendingOp.update(dbConn)
                }
            }
        }

        // PendingOperation still in queue with incremented retryCount
        let pendingOp = try await db.read { try PendingOperation.fetchOne($0, key: opId) }
        #expect(pendingOp != nil)
        #expect(pendingOp?.retryCount == 1)
        #expect(pendingOp?.status == PendingStatus.queued.rawValue)
    }

    @Test("Provider throws during send — OutboxMessage marked for retry")
    func providerThrowsSendOutboxMarkedForRetry() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")

        // Create OutboxMessage
        let draft = DraftMessage(
            to: ["recipient@example.com"],
            subject: "Test Send",
            body: "Hello world",
            isHTML: false
        )
        let outbox = OutboxMessage(accountId: "acc1", draft: draft)
        let outboxId = outbox.id
        try await db.write { try outbox.insert($0) }

        // Provider throws on send
        await provider.setSendThrows(TestSyncError("SMTP connection failed"))

        do {
            try await provider.send(draft: draft)
            Issue.record("Expected send to throw")
        } catch {
            // Simulate drain: increment retryCount, mark failed if >= 3
            try await db.write { dbConn in
                if var msg = try OutboxMessage.fetchOne(dbConn, key: outboxId) {
                    msg.retryCount += 1
                    if msg.retryCount >= 3 {
                        msg.status = OutboxStatus.failed.rawValue
                    }
                    try msg.update(dbConn)
                }
            }
        }

        // OutboxMessage still in DB with incremented retryCount
        let outboxMsg = try await db.read { try OutboxMessage.fetchOne($0, key: outboxId) }
        #expect(outboxMsg != nil)
        #expect(outboxMsg?.retryCount == 1)
        #expect(outboxMsg?.status == OutboxStatus.queued.rawValue)
    }
}

// MARK: - Suite 3: E2E Sync — Optimistic UI Flow

@Suite("E2E Sync — Optimistic UI Flow")
struct E2ESyncOptimisticUITests {

    @Test("Archive flow: optimistic move + PendingOperation + provider call + cleanup")
    func archiveOptimisticFlow() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", subject: "Important", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        // 1. Optimistic: move message to archive locally (create new header in archive, delete from inbox)
        try await db.write { dbConn in
            // Delete from inbox
            try MessageHeader.filter(Column("id") == "acc1:INBOX:100").deleteAll(dbConn)
            // Insert in archive
            let archived = MessageHeader(
                messageId: "100",
                subject: "Important",
                from: "Alice Smith",
                fromAddress: "alice@example.com",
                to: "bob@example.com",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                snippet: "Test snippet",
                folderId: "acc1:Archive",
                accountId: "acc1",
                folderPath: "Archive",
                isInInbox: false
            )
            try archived.insert(dbConn)
        }

        // 2. Queue PendingOperation
        let op = PendingOperation(
            type: .archive,
            messageIds: ["100"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        let opId = op.id
        try await db.write { _ = try op.inserted($0) }

        // 3. Drain: execute provider call
        try await provider.move(ids: ["100"], from: "INBOX", to: "Archive")

        // Delete PendingOperation on success
        try await db.write { dbConn in
            _ = try PendingOperation.deleteOne(dbConn, key: opId)
        }

        // 4. Verify
        let inboxCount = try await db.read { try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount($0) }
        let archiveCount = try await db.read { try MessageHeader.filter(Column("folderId") == "acc1:Archive").fetchCount($0) }
        let pendingCount = try await db.read { try PendingOperation.fetchCount($0) }

        #expect(inboxCount == 0)
        #expect(archiveCount == 1)
        #expect(pendingCount == 0)

        // Verify provider was called correctly
        let moved = await provider.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["100"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Archive")
    }

    @Test("Mark read flow: optimistic update + drain + verify provider called")
    func markReadOptimisticFlow() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isRead: false)

        // 1. Optimistic: mark read locally
        try await db.write { dbConn in
            if var header = try MessageHeader.fetchOne(dbConn, key: "acc1:INBOX:100") {
                header.isRead = true
                try header.update(dbConn)
            }
        }

        // 2. Queue PendingOperation
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["100"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        let opId = op.id
        try await db.write { _ = try op.inserted($0) }

        // 3. Drain
        try await provider.markRead(ids: ["100"], folder: "INBOX")
        try await db.write { _ = try PendingOperation.deleteOne($0, key: opId) }

        // 4. Verify
        let header = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(header?.isRead == true)

        let pendingCount = try await db.read { try PendingOperation.fetchCount($0) }
        #expect(pendingCount == 0)

        let markedRead = await provider.markedReadIds
        #expect(markedRead.count == 1)
        #expect(markedRead[0].ids == ["100"])
        #expect(markedRead[0].folder == "INBOX")
    }

    @Test("Flag flow: optimistic + drain + provider call")
    func flagOptimisticFlow() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        // 1. Optimistic: set flagged
        try await db.write { dbConn in
            if var header = try MessageHeader.fetchOne(dbConn, key: "acc1:INBOX:100") {
                header.isFlagged = true
                try header.update(dbConn)
            }
        }

        // 2. Queue
        let op = PendingOperation(
            type: .markFlagged,
            messageIds: ["100"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        let opId = op.id
        try await db.write { _ = try op.inserted($0) }

        // 3. Drain
        try await provider.markFlagged(ids: ["100"], flagged: true, folder: "INBOX")
        try await db.write { _ = try PendingOperation.deleteOne($0, key: opId) }

        // 4. Verify
        let header = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(header?.isFlagged == true)

        let flagged = await provider.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["100"])
        #expect(flagged[0].flagged == true)
    }

    @Test("Undo archive: restore message to inbox + delete PendingOperation")
    func undoArchiveRestoreToInbox() async throws {
        let db = try TestDatabase.make()
        let provider = MockEmailProvider()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        // Start with archived message
        try TestDatabase.insertMessageHeader(db, messageId: "100", subject: "Undone", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false)

        // 1. Optimistic undo: move back to inbox
        try await db.write { dbConn in
            try MessageHeader.filter(Column("id") == "acc1:Archive:100").deleteAll(dbConn)
            let restored = MessageHeader(
                messageId: "100",
                subject: "Undone",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: Date(),
                snippet: "Test snippet",
                folderId: "acc1:INBOX",
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            try restored.insert(dbConn)
        }

        // 2. Queue undo PendingOperation (move back)
        let op = PendingOperation(
            type: .move,
            messageIds: ["100"],
            accountId: "acc1",
            folderPath: "Archive",
            destinationPath: "INBOX"
        )
        let opId = op.id
        try await db.write { _ = try op.inserted($0) }

        // 3. Drain
        try await provider.move(ids: ["100"], from: "Archive", to: "INBOX")
        try await db.write { _ = try PendingOperation.deleteOne($0, key: opId) }

        // 4. Verify
        let inboxCount = try await db.read { try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchCount($0) }
        let archiveCount = try await db.read { try MessageHeader.filter(Column("folderId") == "acc1:Archive").fetchCount($0) }

        #expect(inboxCount == 1)
        #expect(archiveCount == 0)

        let moved = await provider.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].from == "Archive")
        #expect(moved[0].to == "INBOX")
    }
}

// MARK: - Suite 4: E2E Sync — Incremental Sync

@Suite("E2E Sync — Incremental Sync")
struct E2ESyncIncrementalTests {

    @Test("Second sync: new messages added, existing preserved")
    func secondSyncNewMessagesAdded() throws {
        let db = try TestDatabase.make()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // First sync: 3 messages
        let firstBatch = [
            makeHeaderInfo(messageId: "101", subject: "Msg 1", date: Date(timeIntervalSince1970: 1_700_000_001)),
            makeHeaderInfo(messageId: "102", subject: "Msg 2", date: Date(timeIntervalSince1970: 1_700_000_002)),
            makeHeaderInfo(messageId: "103", subject: "Msg 3", date: Date(timeIntervalSince1970: 1_700_000_003)),
        ]
        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: firstBatch, limit: 50)

        let countAfterFirst = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchCount($0) }
        #expect(countAfterFirst == 3)

        // Second sync: 3 old + 2 new
        let secondBatch = firstBatch + [
            makeHeaderInfo(messageId: "104", subject: "Msg 4", date: Date(timeIntervalSince1970: 1_700_000_004)),
            makeHeaderInfo(messageId: "105", subject: "Msg 5", date: Date(timeIntervalSince1970: 1_700_000_005)),
        ]
        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: secondBatch, limit: 50)

        #expect(result.newHeaders.count == 2)

        let countAfterSecond = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchCount($0) }
        #expect(countAfterSecond == 5)
    }

    @Test("Second sync: deleted messages removed as stale")
    func secondSyncDeletedMessagesRemoved() throws {
        let db = try TestDatabase.make()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // First sync: 3 messages
        let firstBatch = [
            makeHeaderInfo(messageId: "101", subject: "Msg 1"),
            makeHeaderInfo(messageId: "102", subject: "Msg 2"),
            makeHeaderInfo(messageId: "103", subject: "Msg 3"),
        ]
        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: firstBatch, limit: 50)

        // Second sync: only 2 returned (message 102 deleted server-side)
        let secondBatch = [
            makeHeaderInfo(messageId: "101", subject: "Msg 1"),
            makeHeaderInfo(messageId: "103", subject: "Msg 3"),
        ]
        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: secondBatch, limit: 50)

        #expect(result.staleIds.count == 1)
        guard result.staleIds.count == 1 else { return }
        #expect(result.staleIds[0] == "acc1:INBOX:102")

        let countAfterSecond = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchCount($0) }
        #expect(countAfterSecond == 2)
    }

    @Test("Second sync: flag changes applied")
    func secondSyncFlagChangesApplied() throws {
        let db = try TestDatabase.make()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // First sync: message unread
        let firstBatch = [
            makeHeaderInfo(messageId: "101", subject: "Msg 1", isRead: false, isFlagged: false),
        ]
        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: firstBatch, limit: 50)

        let headerBefore = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:101") }
        #expect(headerBefore?.isRead == false)
        #expect(headerBefore?.isFlagged == false)

        // Second sync: same message now read and flagged
        let secondBatch = [
            makeHeaderInfo(messageId: "101", subject: "Msg 1", isRead: true, isFlagged: true),
        ]
        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: secondBatch, limit: 50)

        let headerAfter = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:101") }
        #expect(headerAfter?.isRead == true)
        #expect(headerAfter?.isFlagged == true)
    }

    @Test("Concurrent sync and user action: pending op protects message from stale removal")
    func pendingOpProtectsMessageFromStaleRemoval() throws {
        let db = try TestDatabase.make()

        try TestDatabase.insertAccount(db, id: "acc1", email: "test@example.com")
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // First sync: 2 messages
        let firstBatch = [
            makeHeaderInfo(messageId: "101", subject: "Keep Me"),
            makeHeaderInfo(messageId: "102", subject: "Archive Me"),
        ]
        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: firstBatch, limit: 50)

        // User archives message 102 — PendingOperation exists
        let op = PendingOperation(
            type: .archive,
            messageIds: ["102"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { _ = try op.inserted($0) }

        // Second sync: server still shows 102 (hasn't processed archive yet)
        // But what if server no longer shows 102? The pending op protects it.
        let secondBatch = [
            makeHeaderInfo(messageId: "101", subject: "Keep Me"),
            // 102 not returned — normally would be stale
        ]
        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: secondBatch, limit: 50)

        // 102 should NOT be removed because of pending destructive op
        #expect(result.staleIds.isEmpty)

        let count = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchCount($0) }
        #expect(count == 2)
    }
}

// MARK: - Suite 5: E2E Sync — Provider Call Ordering

@Suite("E2E Sync — Provider Call Ordering")
struct E2ESyncProviderCallOrderingTests {

    @Test("Full sync: connect → fetchFolders → fetchMessages per folder → verify call log")
    func fullSyncCallOrdering() async throws {
        let provider = MockEmailProvider()

        let folderInfos = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 2, totalCount: 10),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 5),
        ]
        await provider.setFetchFoldersResult(folderInfos)
        await provider.setFetchMessagesResult([
            makeHeaderInfo(messageId: "101", subject: "Test"),
        ])

        // Simulate full sync sequence
        try await provider.connect()
        let folders = try await provider.fetchFolders()
        for folder in folders {
            _ = try await provider.fetchMessages(folder: folder.path, limit: 50, offset: 0)
        }

        let log = await provider.callLog
        #expect(log.count == 4)
        #expect(log[0] == "connect")
        #expect(log[1] == "fetchFolders")
        #expect(log[2].hasPrefix("fetchMessages(folder:INBOX"))
        #expect(log[3].hasPrefix("fetchMessages(folder:Sent"))
    }

    @Test("Action drain: markRead → move → send → verify ordering")
    func actionDrainCallOrdering() async throws {
        let provider = MockEmailProvider()

        let draft = DraftMessage(
            to: ["recipient@example.com"],
            subject: "Test",
            body: "Body"
        )

        // Simulate drain sequence
        try await provider.markRead(ids: ["100"], folder: "INBOX")
        try await provider.move(ids: ["101"], from: "INBOX", to: "Archive")
        try await provider.send(draft: draft)

        let log = await provider.callLog
        #expect(log.count == 3)
        #expect(log[0].hasPrefix("markRead"))
        #expect(log[1].hasPrefix("move"))
        #expect(log[2] == "send")
    }

    @Test("Body fetch: fetchMessage for each header → verify correct ids")
    func bodyFetchCallOrdering() async throws {
        let provider = MockEmailProvider()

        let bodyResult = FullMessageInfo(
            header: makeHeaderInfo(messageId: "100"),
            htmlBody: "<p>Body</p>",
            textBody: nil
        )
        await provider.setFetchMessageResult(bodyResult)

        let messageIds = ["100", "101", "102"]
        for msgId in messageIds {
            _ = try await provider.fetchMessage(id: msgId, folder: "INBOX")
        }

        let log = await provider.callLog
        #expect(log.count == 3)
        #expect(log[0] == "fetchMessage(id:100,folder:INBOX)")
        #expect(log[1] == "fetchMessage(id:101,folder:INBOX)")
        #expect(log[2] == "fetchMessage(id:102,folder:INBOX)")
    }
}

// MARK: - Stale-detection window (Archive month-gap data-loss regression)

/// Regression for the IMAP Archive "missing months" data-loss bug.
///
/// Full-sync fetches only the newest `limit` messages, then stale-deletes local rows
/// that fall *inside the fetched slice* but aren't in the server's response. The
/// slice MUST be measured in the provider's fetch-ordering dimension. IMAP returns
/// the highest UIDs (= archive-time), which is DECORRELATED from message date:
/// archiving an OLD-dated email gives it a fresh HIGH UID. A *date* window then lets
/// that one old-dated row drag the floor backwards and falsely delete every
/// mid-range message the fetch never returned — wiping whole months from Archive.
///
/// These drive the production source of truth `SyncEngine.selectStaleHeaders`
/// (via `simulateRunSyncMessages`), so they fail if anyone reverts IMAP to a date
/// window or reintroduces a divergent copy of the logic.
@Suite("E2E Sync — Stale Window (Archive month-gap data-loss)")
struct StaleDetectionWindowTests {
    private func daysAgo(_ d: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -d, to: Date())!
    }

    /// Decorrelated Archive: two mid-range rows (mid UID / mid date), two recent rows
    /// (high UID / recent date), and one just-archived OLD-dated row (HIGHEST UID /
    /// OLDEST date — the date-floor poison).
    @discardableResult
    private func seedArchive(_ db: DatabaseQueue) throws -> Folder {
        try TestDatabase.insertAccount(db, id: "acc1", provider: .imap)
        let archive = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", date: daysAgo(40), folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<a100@example.com>")
        try TestDatabase.insertMessageHeader(db, messageId: "101", date: daysAgo(38), folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<a101@example.com>")
        try TestDatabase.insertMessageHeader(db, messageId: "200", date: daysAgo(5), folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<a200@example.com>")
        try TestDatabase.insertMessageHeader(db, messageId: "201", date: daysAgo(4), folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<a201@example.com>")
        try TestDatabase.insertMessageHeader(db, messageId: "202", date: daysAgo(60), folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<a202@example.com>")
        return archive
    }

    /// The server's newest-3-by-UID = {202, 201, 200}. Excludes the mid-range rows
    /// 100/101 (lower UIDs); its OLDEST date is 202's (the poison).
    private func newestThreeFetch() -> [MessageHeaderInfo] {
        [
            makeHeaderInfo(messageId: "202", rfc822MessageId: "<a202@example.com>", date: daysAgo(60)),
            makeHeaderInfo(messageId: "201", rfc822MessageId: "<a201@example.com>", date: daysAgo(4)),
            makeHeaderInfo(messageId: "200", rfc822MessageId: "<a200@example.com>", date: daysAgo(5)),
        ]
    }

    @Test("IMAP .uid window: archiving an old-dated mail must NOT delete mid-range Archive mail")
    func uidWindowPreservesMidRange() throws {
        let db = try TestDatabase.make()
        let archive = try seedArchive(db)
        let result = try simulateRunSyncMessages(db: db, folder: archive, messages: newestThreeFetch(), limit: 3, windowMode: .uid)

        #expect(!result.staleIds.contains("acc1:Archive:100"))
        #expect(!result.staleIds.contains("acc1:Archive:101"))
        let survives100 = try db.read { try MessageHeader.fetchOne($0, key: "acc1:Archive:100") != nil }
        let survives101 = try db.read { try MessageHeader.fetchOne($0, key: "acc1:Archive:101") != nil }
        #expect(survives100, "row 100 (UID < min fetched UID → outside window) must survive")
        #expect(survives101, "row 101 must survive")
    }

    @Test("Characterization: a .date window over-deletes the same mid-range rows (the bug we fixed)")
    func dateWindowOverDeletes() throws {
        let db = try TestDatabase.make()
        let archive = try seedArchive(db)
        // .date is what IMAP used to do — proves the test discriminates and that
        // switching IMAP to .uid is what stops the data loss.
        let result = try simulateRunSyncMessages(db: db, folder: archive, messages: newestThreeFetch(), limit: 3, windowMode: .date)
        #expect(result.staleIds.contains("acc1:Archive:100"))
        #expect(result.staleIds.contains("acc1:Archive:101"))
    }

    @Test("IMAP .uid window still deletes a row INSIDE the fetched UID slice that the server dropped")
    func uidWindowStillDeletesGenuinelyStale() throws {
        let db = try TestDatabase.make()
        let archive = try seedArchive(db)
        // UID 203 > floor(200): inside the window. Server's newest-3 is still
        // {202,201,200} (203 was deleted server-side) → 203 must be stale-deleted.
        try TestDatabase.insertMessageHeader(db, messageId: "203", date: daysAgo(3), folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<a203@example.com>")
        let result = try simulateRunSyncMessages(db: db, folder: archive, messages: newestThreeFetch(), limit: 3, windowMode: .uid)

        #expect(result.staleIds.contains("acc1:Archive:203"), "row 203 (UID ≥ floor, gone from server) must still be deleted")
        #expect(!result.staleIds.contains("acc1:Archive:100"), "mid-range row 100 must still survive")
    }
}

// MARK: - v59 one-time heal scoping (ADR-IOS-042)

/// `AppDatabase.rewalkImapArchiveFolders` (the v59 migration body) must reset backfill
/// ONLY for archive-role folders on IMAP accounts — so field users who already lost
/// Archive mail auto-re-walk on upgrade — and must leave everything else alone.
@Suite("Archive re-walk heal — scoping (ADR-IOS-042)")
struct ArchiveRewalkHealTests {
    private func folderState(_ db: DatabaseQueue, _ id: String) throws -> (complete: Bool, cursor: Int?) {
        try db.read { dbConn in
            let row = try Row.fetchOne(dbConn, sql: "SELECT backfillComplete, backfillUidCursor FROM folder WHERE id = ?", arguments: [id])!
            return ((row["backfillComplete"] as Int) != 0, row["backfillUidCursor"] as Int?)
        }
    }

    @Test("Resets only IMAP archive folders; leaves IMAP inbox + Gmail archive intact")
    func scopesToImapArchiveOnly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "imap1", provider: .imap)
        try TestDatabase.insertAccount(db, id: "gmail1", provider: .gmail)
        let imapArchive = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "imap1")
        let imapInbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "imap1")
        let gmailArchive = try TestDatabase.insertFolder(db, name: "All Mail", path: "__GMAIL_ALL_MAIL__", role: .archive, accountId: "gmail1")
        // All three start "complete" with a non-null cursor.
        try db.write { dbConn in
            for fid in [imapArchive.id, imapInbox.id, gmailArchive.id] {
                try dbConn.execute(sql: "UPDATE folder SET backfillComplete = 1, backfillUidCursor = 999 WHERE id = ?", arguments: [fid])
            }
        }

        let reset = try db.write { try AppDatabase.rewalkImapArchiveFolders($0) }
        #expect(reset == 1, "exactly one folder (IMAP archive) should be reset")

        let archiveState = try folderState(db, imapArchive.id)
        #expect(archiveState.complete == false, "IMAP archive must be re-walked")
        #expect(archiveState.cursor == nil, "IMAP archive cursor must be cleared")

        let inboxState = try folderState(db, imapInbox.id)
        #expect(inboxState.complete == true, "IMAP inbox (chronological) must be untouched")
        #expect(inboxState.cursor == 999)

        let gmailState = try folderState(db, gmailArchive.id)
        #expect(gmailState.complete == true, "Gmail archive (date-ordered fetch) must be untouched")
        #expect(gmailState.cursor == 999)
    }
}

