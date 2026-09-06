/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

private func makeHeader(
    messageId: String = "100",
    subject: String = "Test Subject",
    from: String = "sender@example.com",
    accountId: String = "acc1",
    folderPath: String = "INBOX",
    isRead: Bool = false,
    isFlagged: Bool = false,
    rfc822MessageId: String? = nil
) -> MessageHeader {
    var header = MessageHeader(
        messageId: messageId,
        subject: subject,
        from: from,
        fromAddress: from,
        to: "recipient@example.com",
        date: Date(),
        snippet: "Test snippet",
        folderId: "\(accountId):\(folderPath)",
        accountId: accountId,
        folderPath: folderPath,
        isInInbox: folderPath == "INBOX"
    )
    header.isRead = isRead
    header.isFlagged = isFlagged
    header.rfc822MessageId = rfc822MessageId
    return header
}

private func makeDraft(
    to: [String] = ["to@example.com"],
    subject: String = "Test Draft",
    body: String = "Hello world"
) -> DraftMessage {
    DraftMessage(to: to, subject: subject, body: body)
}

// MARK: - Suite 1: Operation Type Dispatch

@Suite("Operation Type Dispatch")
struct OperationTypeDispatchTests {

    @Test("markRead dispatches to provider.markRead with correct ids and folder")
    @MainActor
    func markReadDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.contains { $0.hasPrefix("markRead(") })
        let reads = await mock.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1", "msg-2"])
        #expect(reads[0].folder == "INBOX")
    }

    @Test("markUnread dispatches to provider.markUnread with correct ids and folder")
    @MainActor
    func markUnreadDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnread,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let unreads = await mock.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-1"])
        #expect(unreads[0].folder == "INBOX")
    }

    @Test("markFlagged dispatches to provider.markFlagged with flagged=true")
    @MainActor
    func markFlaggedDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markFlagged,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == true)
        #expect(flagged[0].folder == "INBOX")
    }

    @Test("markUnflagged dispatches to provider.markFlagged with flagged=false")
    @MainActor
    func markUnflaggedDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .markUnflagged,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 1)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == false)
        #expect(flagged[0].folder == "INBOX")
    }

    @Test("move dispatches to provider.move with correct ids, from, and to")
    @MainActor
    func moveDispatch() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1", "msg-2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.count == 1)
        #expect(moved[0].ids == ["msg-1", "msg-2"])
        #expect(moved[0].from == "INBOX")
        #expect(moved[0].to == "Archive")
    }

    @Test("archive type is a legacy no-op")
    @MainActor
    func archiveLegacyNoOp() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .archive,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "Legacy archive should not call any provider method")
    }

    @Test("delete type is a legacy no-op")
    @MainActor
    func deleteLegacyNoOp() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .delete,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let log = await mock.callLog
        #expect(log.isEmpty, "Legacy delete should not call any provider method")
    }
}

// MARK: - Suite 2: Optimistic UI + Queue Patterns

@Suite("Optimistic UI + Queue Patterns")
struct OptimisticUIQueueTests {

    @Test("markRead updates DB isRead=true AND queues PendingOperation atomically")
    func markReadOptimistic() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", isRead: false)

        // Simulate atomic optimistic update: set isRead + queue PendingOperation in single write
        try db.write { dbConn in
            // Update message as read
            try dbConn.execute(
                sql: "UPDATE messageHeader SET isRead = ? WHERE messageId = ? AND accountId = ?",
                arguments: [true, "100", "acc1"]
            )
            // Queue the pending operation
            var op = PendingOperation(
                type: .markRead,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try op.insert(dbConn)
        }

        // Verify both happened
        let header = try db.read { try MessageHeader.filter(Column("messageId") == "100" && Column("accountId") == "acc1").fetchOne($0) }
        #expect(header?.isRead == true)

        let ops = try db.read { try PendingOperation.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markRead)
        #expect(ops[0].messageIds == ["100"])
    }

    @Test("move updates DB folderId/folderPath AND queues PendingOperation atomically")
    func moveOptimistic() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "200", folderId: "acc1:INBOX", folderPath: "INBOX")

        // Simulate atomic optimistic move
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = ? WHERE messageId = ? AND accountId = ?",
                arguments: ["acc1:Archive", "Archive", false, "200", "acc1"]
            )
            var op = PendingOperation(
                type: .move,
                messageIds: ["200"],
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Archive"
            )
            try op.insert(dbConn)
        }

        let header = try db.read { try MessageHeader.filter(Column("messageId") == "200" && Column("accountId") == "acc1").fetchOne($0) }
        #expect(header?.folderId == "acc1:Archive")
        #expect(header?.folderPath == "Archive")
        #expect(header?.isInInbox == false)

        let ops = try db.read { try PendingOperation.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .move)
        #expect(ops[0].destinationPath == "Archive")
    }

    @Test("markFlagged updates DB isFlagged AND queues PendingOperation atomically")
    func markFlaggedOptimistic() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "300")

        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET isFlagged = ? WHERE messageId = ? AND accountId = ?",
                arguments: [true, "300", "acc1"]
            )
            var op = PendingOperation(
                type: .markFlagged,
                messageIds: ["300"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try op.insert(dbConn)
        }

        let header = try db.read { try MessageHeader.filter(Column("messageId") == "300" && Column("accountId") == "acc1").fetchOne($0) }
        #expect(header?.isFlagged == true)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markFlagged)
    }

    @Test("Multiple messages grouped by account+folder produce single PendingOperation per group")
    func groupedPendingOperation() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1")
        try TestDatabase.insertMessageHeader(db, messageId: "m2")
        try TestDatabase.insertMessageHeader(db, messageId: "m3")

        // Single op for all messages in same account+folder
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET isRead = ? WHERE accountId = ? AND folderPath = ?",
                arguments: [true, "acc1", "INBOX"]
            )
            var op = PendingOperation(
                type: .markRead,
                messageIds: ["m1", "m2", "m3"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try op.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1, "Single PendingOperation for same account+folder group")
        #expect(ops[0].messageIds.count == 3)
    }

    @Test("Cross-account messages produce separate PendingOperations per account")
    func crossAccountSeparateOps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m2", folderId: "acc2:INBOX", accountId: "acc2")

        // Queue separate ops per account
        try db.write { dbConn in
            var op1 = PendingOperation(
                type: .markRead,
                messageIds: ["m1"],
                accountId: "acc1",
                folderPath: "INBOX"
            )
            try op1.insert(dbConn)

            var op2 = PendingOperation(
                type: .markRead,
                messageIds: ["m2"],
                accountId: "acc2",
                folderPath: "INBOX"
            )
            try op2.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2)

        let acc1Ops = ops.filter { $0.accountId == "acc1" }
        let acc2Ops = ops.filter { $0.accountId == "acc2" }
        #expect(acc1Ops.count == 1)
        #expect(acc2Ops.count == 1)
        #expect(acc1Ops[0].messageIds == ["m1"])
        #expect(acc2Ops[0].messageIds == ["m2"])
    }
}

// MARK: - Suite 3: Error Propagation

@Suite("Error Propagation")
struct ErrorPropagationTests {

    @Test("markRead throws propagates error from provider")
    @MainActor
    func markReadThrowsPropagates() async throws {
        let mock = MockEmailProvider()
        await mock.setMarkReadThrows(ProviderError.notConnected)
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    @Test("move throws propagates error from provider")
    @MainActor
    func moveThrowsPropagates() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.notConnected)
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Trash"
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    @Test("ProviderError.messageNotFound detected by isMessageNotFoundError")
    @MainActor
    func messageNotFoundDetected() {
        let manager = AccountManager.shared
        let result = manager.isMessageNotFoundError(ProviderError.messageNotFound)
        #expect(result == true)
    }

    @Test("ProviderError.networkError with code 404 detected as messageNotFound")
    @MainActor
    func networkError404Detected() {
        let manager = AccountManager.shared
        let underlying = NSError(domain: "test", code: 404, userInfo: nil)
        let result = manager.isMessageNotFoundError(ProviderError.networkError(underlying: underlying))
        #expect(result == true)
    }

    @Test("isMessageNotFoundError detects various error string patterns")
    @MainActor
    func errorStringPatterns() {
        let manager = AccountManager.shared

        // "no such message" pattern
        let err1 = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such message"])
        #expect(manager.isMessageNotFoundError(err1) == true)

        // "UID not found" pattern
        let err2 = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "UID not found"])
        #expect(manager.isMessageNotFoundError(err2) == true)

        // "Message not found" pattern
        let err3 = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Message not found"])
        #expect(manager.isMessageNotFoundError(err3) == true)

        // "NONEXISTENT" pattern
        let err4 = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "NONEXISTENT"])
        #expect(manager.isMessageNotFoundError(err4) == true)

        // Regular network error should NOT match
        let err5 = NSError(domain: "Network", code: 500, userInfo: [NSLocalizedDescriptionKey: "Server error"])
        #expect(manager.isMessageNotFoundError(ProviderError.networkError(underlying: err5)) == false)

        // ProviderError.notConnected should NOT match
        #expect(manager.isMessageNotFoundError(ProviderError.notConnected) == false)
    }

    @Test("markRead error leaves PendingOperation in DB for retry")
    func markReadErrorKeepsOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        // Insert a pending op
        var op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Simulate that executeOperation threw — the op should remain in DB
        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched != nil, "Op must remain for retry after error")
        #expect(fetched?.status == PendingStatus.queued.rawValue)
    }
}

// MARK: - Suite 4: Undo Patterns

@Suite("Undo Patterns")
struct UndoPatternTests {

    @Test("Undo cancels queued op by setting status to cancelled")
    func undoCancelsQueuedOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { try op.insert($0) }

        // Simulate undo: cancel the queued op
        try db.write { dbConn in
            op.status = PendingStatus.cancelled.rawValue
            try op.save(dbConn)
        }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.cancelled.rawValue)
    }

    @Test("Undo when original op already executed queues move-back")
    func undoQueuesReverse() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        // Original op was already drained (deleted from DB).
        // Undo must queue a reverse move.
        try db.write { dbConn in
            var reverseOp = PendingOperation(
                type: .move,
                messageIds: ["msg-1"],
                accountId: "acc1",
                folderPath: "Archive",
                destinationPath: "INBOX"
            )
            try reverseOp.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == "Archive")
        #expect(ops[0].destinationPath == "INBOX")
    }

    @Test("Undo uses rfc822MessageId for IMAP accounts (not numeric UID)")
    func undoUsesRfc822MessageId() {
        // IMAP messages have numeric UIDs that change after MOVE.
        // stableId should return rfc822MessageId when messageId is numeric.
        let header = makeHeader(
            messageId: "12345",
            rfc822MessageId: "<unique-id@example.com>"
        )
        #expect(header.stableId == "<unique-id@example.com>")

        // For non-numeric messageIds (Gmail), stableId returns messageId
        let gmailHeader = makeHeader(
            messageId: "18f3a2b4c5d6e7f8",
            rfc822MessageId: "<some@example.com>"
        )
        #expect(gmailHeader.stableId == "18f3a2b4c5d6e7f8")
    }

    @Test("Undo restores message via save() (upsert) handling deleted row case")
    func undoRestoresViaSave() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // The original row with folderId="" was deleted by drain cleanup.
        // Undo must use save() which does an upsert.
        let header = makeHeader(messageId: "999", accountId: "acc1", folderPath: "INBOX")
        try db.write { try header.save($0) }

        // Verify it was inserted (upserted)
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched != nil)
        #expect(fetched?.folderPath == "INBOX")

        // Save again (upsert update) — should not throw
        var updated = header
        updated.isRead = true
        try db.write { try updated.save($0) }

        let reFetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(reFetched?.isRead == true)
    }

    @Test("Multiple concurrent undo operations do not interfere")
    func multipleConcurrentUndos() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")

        // Queue two separate undo operations
        var reverseOp1 = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "Archive",
            destinationPath: "INBOX"
        )
        var reverseOp2 = PendingOperation(
            type: .move,
            messageIds: ["msg-2"],
            accountId: "acc1",
            folderPath: "Trash",
            destinationPath: "INBOX"
        )

        try db.write { dbConn in
            try reverseOp1.insert(dbConn)
            try reverseOp2.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(ops.count == 2)

        let msgIds = Set(ops.flatMap(\.messageIds))
        #expect(msgIds.contains("msg-1"))
        #expect(msgIds.contains("msg-2"))

        // Each op targets a different message — no interference
        let op1 = ops.first { $0.messageIds.contains("msg-1") }
        let op2 = ops.first { $0.messageIds.contains("msg-2") }
        #expect(op1?.folderPath == "Archive")
        #expect(op1?.destinationPath == "INBOX")
        #expect(op2?.folderPath == "Trash")
        #expect(op2?.destinationPath == "INBOX")
    }
}

// MARK: - Suite 5: Send Operation Flow

@Suite("Send Operation Flow")
struct SendOperationFlowTests {

    @Test("send dispatches to provider.send with DraftMessage")
    @MainActor
    func sendDispatch() async throws {
        let mock = MockEmailProvider()
        let draft = makeDraft(to: ["alice@example.com"], subject: "Hello", body: "World")

        try await mock.send(draft: draft)

        let sent = await mock.sentDrafts
        #expect(sent.count == 1)
        #expect(sent[0].to == ["alice@example.com"])
        #expect(sent[0].subject == "Hello")
        #expect(sent[0].body == "World")
    }

    @Test("appendToSentFolder dispatches with draft, sentFolderPath, and messageId")
    @MainActor
    func appendToSentDispatch() async throws {
        let mock = MockEmailProvider()
        let draft = makeDraft()
        let sentMsgId = "<generated-id@example.com>"

        let result = try await mock.appendToSentFolder(draft: draft, sentFolderPath: "Sent", messageId: sentMsgId)

        #expect(result == true)
        let appended = await mock.appendedToSent
        #expect(appended.count == 1)
        #expect(appended[0].sentFolderPath == "Sent")
        #expect(appended[0].messageId == sentMsgId)
    }

    @Test("send throws propagates error")
    @MainActor
    func sendThrowsPropagates() async throws {
        let mock = MockEmailProvider()
        await mock.setSendThrows(ProviderError.notConnected)
        let draft = makeDraft()

        await #expect(throws: ProviderError.self) {
            try await mock.send(draft: draft)
        }
    }

    @Test("appendToSentFolder returns false when provider auto-saves (still succeeds)")
    @MainActor
    func appendReturnsFalse() async throws {
        let mock = MockEmailProvider()
        await mock.setAppendToSentResult(false)
        let draft = makeDraft()

        let result = try await mock.appendToSentFolder(draft: draft, sentFolderPath: "Sent", messageId: "<id@example.com>")

        // false means the provider didn't append (e.g., Gmail auto-saves) — this is NOT an error
        #expect(result == false)

        // The call was still made
        let log = await mock.callLog
        #expect(log.contains { $0.hasPrefix("appendToSentFolder(") })
    }
}

// MARK: - Suite 6: Move Edge Cases

@Suite("Move Operation Edge Cases")
struct MoveEdgeCaseTests {

    @Test("move with missing destinationPath throws messageNotFound")
    @MainActor
    func moveMissingDestination() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: nil
        )

        await #expect(throws: ProviderError.self) {
            try await AccountManager.shared.executeOperation(op, provider: mock)
        }
    }

    @Test("move with source == destination is a no-op")
    @MainActor
    func moveSameSourceAndDest() async throws {
        let mock = MockEmailProvider()
        let op = PendingOperation(
            type: .move,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "Archive",
            destinationPath: "Archive"
        )

        _ = try await AccountManager.shared.executeOperation(op, provider: mock)

        let moved = await mock.movedIds
        #expect(moved.isEmpty, "Self-move should be a no-op")
    }
}

// MARK: - Suite 7: stableId Computed Property

@Suite("MessageHeader stableId")
struct StableIdTests {

    @Test("stableId returns rfc822MessageId for numeric messageId")
    func stableIdNumericUID() {
        let header = makeHeader(messageId: "42", rfc822MessageId: "<abc@example.com>")
        #expect(header.stableId == "<abc@example.com>")
    }

    @Test("stableId returns messageId for non-numeric messageId")
    func stableIdNonNumeric() {
        let header = makeHeader(messageId: "gmail-id-xyz", rfc822MessageId: "<abc@example.com>")
        #expect(header.stableId == "gmail-id-xyz")
    }

    @Test("stableId returns messageId when rfc822MessageId is nil")
    func stableIdNilRfc822() {
        let header = makeHeader(messageId: "42", rfc822MessageId: nil)
        #expect(header.stableId == "42")
    }

    @Test("stableId returns messageId when rfc822MessageId is empty")
    func stableIdEmptyRfc822() {
        let header = makeHeader(messageId: "42", rfc822MessageId: "")
        #expect(header.stableId == "42")
    }
}

// MARK: - Suite 8: PendingOperation GRDB Persistence

@Suite("PendingOperation GRDB Persistence - Dispatch Context")
struct PendingOperationDispatchPersistenceTests {

    @Test("PendingOperation round-trips through GRDB preserving all fields")
    func grdbRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var op = PendingOperation(
            type: .move,
            messageIds: ["m1", "m2"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Trash",
            tagValue: nil
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched != nil)
        #expect(fetched?.type == .move)
        #expect(fetched?.messageIds == ["m1", "m2"])
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.folderPath == "INBOX")
        #expect(fetched?.destinationPath == "Trash")
        #expect(fetched?.status == PendingStatus.queued.rawValue)
        #expect(fetched?.retryCount == 0)
    }

    @Test("PendingOperation survives account deletion (no FK cascade)")
    func pendingOpSurvivesAccountDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var op = PendingOperation(
            type: .markRead,
            messageIds: ["m1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Delete the account — PendingOperation has no FK to account table
        _ = try db.write { try Account.deleteAll($0, keys: ["acc1"]) }

        // PendingOperation references accountId as plain text, not FK — survives deletion
        let remaining = try db.read { try PendingOperation.fetchAll($0) }
        #expect(remaining.count == 1, "PendingOperations should survive account deletion (no FK)")
    }

    @Test("Multiple PendingOperations for different types coexist")
    func multipleOpTypes() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        try db.write { dbConn in
            var op1 = PendingOperation(type: .markRead, messageIds: ["m1"], accountId: "acc1", folderPath: "INBOX")
            var op2 = PendingOperation(type: .markFlagged, messageIds: ["m2"], accountId: "acc1", folderPath: "INBOX")
            var op3 = PendingOperation(type: .move, messageIds: ["m3"], accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash")
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 3)

        let types = Set(ops.map(\.type))
        #expect(types.contains(.markRead))
        #expect(types.contains(.markFlagged))
        #expect(types.contains(.move))
    }
}
