/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

/// Helper to insert an OutboxMessage via raw SQL, giving full control over every column.
@discardableResult
private func insertOutboxMessageSQL(
    _ db: DatabaseQueue,
    id: String = UUID().uuidString,
    accountId: String = "acc1",
    toJSON: String = "[\"to@test.com\"]",
    ccJSON: String = "[]",
    bccJSON: String = "[]",
    subject: String = "Test",
    body: String = "Body",
    isHTML: Bool = false,
    inReplyTo: String? = nil,
    referencesJSON: String? = nil,
    attachmentsDirName: String? = nil,
    status: String = "queued",
    errorMessage: String? = nil,
    retryCount: Int = 0,
    createdAt: Date = Date(),
    originalMessageHeaderId: String? = nil,
    isForward: Bool = false,
    sentAt: Date? = nil,
    sentMessageId: String? = nil,
    appendedToSent: Bool = false
) throws -> String {
    try db.write { dbConn in
        try dbConn.execute(
            sql: """
                INSERT INTO outboxMessage
                (id, accountId, toJSON, ccJSON, bccJSON, subject, body, isHTML,
                 inReplyTo, referencesJSON, attachmentsDirName, status, errorMessage,
                 retryCount, createdAt, originalMessageHeaderId, isForward,
                 sentAt, sentMessageId, appendedToSent)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, accountId, toJSON, ccJSON, bccJSON, subject, body, isHTML,
                inReplyTo, referencesJSON, attachmentsDirName, status, errorMessage,
                retryCount, createdAt, originalMessageHeaderId, isForward,
                sentAt, sentMessageId, appendedToSent
            ]
        )
    }
    return id
}

// MARK: - Suite 1: Reconcile Outbox Crash Recovery

@Suite("Reconcile Outbox Crash Recovery")
struct ReconcileOutboxCrashRecoveryTests {

    /// Replicate the reconcileOutbox logic at DB level.
    private func runReconcile(_ db: DatabaseQueue) throws -> [String] {
        try db.write { dbConn in
            let stale = try OutboxMessage
                .filter(Column("status") == OutboxStatus.sending.rawValue)
                .fetchAll(dbConn)
            var dirsToClean: [String] = []
            for msg in stale {
                if msg.sentAt != nil {
                    if msg.appendedToSent {
                        try OutboxMessage.deleteOne(dbConn, key: msg.id)
                        if let dirName = msg.attachmentsDirName {
                            dirsToClean.append(dirName)
                        }
                    }
                    // else: keep for drainPendingSentAppends (sentAt set, appendedToSent false)
                } else {
                    try dbConn.execute(
                        sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                        arguments: [OutboxStatus.queued.rawValue, msg.id]
                    )
                }
            }
            return dirsToClean
        }
    }

    @Test("sentAt set + appendedToSent true -> delete (fully completed)")
    func fullyCompletedIsDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let id = try insertOutboxMessageSQL(
            db, status: "sending", sentAt: Date(),
            sentMessageId: "<done@example.com>", appendedToSent: true
        )

        let dirs = try runReconcile(db)

        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(remaining == nil)
        #expect(dirs.isEmpty) // no attachmentsDirName set
    }

    @Test("sentAt set + appendedToSent true with attachments -> returns dir for cleanup")
    func fullyCompletedWithAttachmentsReturnsDirName() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let id = try insertOutboxMessageSQL(
            db, attachmentsDirName: "some-dir", status: "sending",
            sentAt: Date(), sentMessageId: "<done@example.com>", appendedToSent: true
        )

        let dirs = try runReconcile(db)

        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(remaining == nil)
        #expect(dirs == ["some-dir"])
    }

    @Test("sentAt set + appendedToSent false -> keep for Sent append retry")
    func sentButNotAppendedIsKept() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let id = try insertOutboxMessageSQL(
            db, status: "sending", sentAt: Date(),
            sentMessageId: "<partial@example.com>", appendedToSent: false
        )

        let dirs = try runReconcile(db)

        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(remaining != nil)
        #expect(remaining?.sentAt != nil)
        #expect(remaining?.appendedToSent == false)
        // Status stays as "sending" -- drainPendingSentAppends queries by sentAt != nil + !appendedToSent
        #expect(remaining?.status == OutboxStatus.sending.rawValue)
        #expect(dirs.isEmpty)
    }

    @Test("sentAt nil + status sending -> reset to queued")
    func midSendCrashResetsToQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let id = try insertOutboxMessageSQL(db, status: "sending")

        let dirs = try runReconcile(db)

        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(remaining != nil)
        #expect(remaining?.outboxStatus == .queued)
        #expect(dirs.isEmpty)
    }

    @Test("Queued messages are untouched by reconcile")
    func queuedUntouched() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let id = try insertOutboxMessageSQL(db, subject: "Still queued", status: "queued")

        _ = try runReconcile(db)

        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(remaining != nil)
        #expect(remaining?.outboxStatus == .queued)
        #expect(remaining?.subject == "Still queued")
    }

    @Test("Failed messages are untouched by reconcile")
    func failedUntouched() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let id = try insertOutboxMessageSQL(
            db, status: "failed", errorMessage: "SMTP error", retryCount: 3
        )

        _ = try runReconcile(db)

        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(remaining != nil)
        #expect(remaining?.outboxStatus == .failed)
        #expect(remaining?.errorMessage == "SMTP error")
    }

    @Test("Mixed states: reconcile handles all three sending sub-states correctly")
    func mixedSendingStates() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // 1. Fully completed (sentAt + appendedToSent) -> delete
        let id1 = try insertOutboxMessageSQL(
            db, subject: "Done", status: "sending",
            sentAt: Date(), sentMessageId: "<1@x.com>", appendedToSent: true
        )
        // 2. Sent but not appended -> keep
        let id2 = try insertOutboxMessageSQL(
            db, subject: "SentNoAppend", status: "sending",
            sentAt: Date(), sentMessageId: "<2@x.com>", appendedToSent: false
        )
        // 3. Mid-send crash -> reset to queued
        let id3 = try insertOutboxMessageSQL(
            db, subject: "MidSend", status: "sending"
        )

        _ = try runReconcile(db)

        let all = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(all.count == 2)

        let ids = Set(all.map(\.id))
        #expect(!ids.contains(id1)) // deleted
        #expect(ids.contains(id2))  // kept
        #expect(ids.contains(id3))  // kept, reset

        let msg2 = all.first { $0.id == id2 }
        #expect(msg2?.status == OutboxStatus.sending.rawValue)
        #expect(msg2?.sentAt != nil)

        let msg3 = all.first { $0.id == id3 }
        #expect(msg3?.outboxStatus == .queued)
    }
}

// MARK: - Suite 2: Retry Escalation

@Suite("Outbox Retry Escalation")
struct OutboxRetryEscalationTests {

    /// Replicate the drain retry logic: determine new status based on retryCount.
    private func simulateFailedSend(
        _ db: DatabaseQueue, id: String, currentRetryCount: Int, error: String
    ) throws {
        let newRetryCount = currentRetryCount + 1
        let shouldAutoRetry = newRetryCount < 3
        let newStatus = shouldAutoRetry ? OutboxStatus.queued.rawValue : OutboxStatus.failed.rawValue
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = ? WHERE id = ?",
                arguments: [newStatus, error, newRetryCount, id]
            )
        }
    }

    @Test("retryCount 0 -> 1: stays queued (auto-retry)")
    func firstFailStaysQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, retryCount: 0)

        try simulateFailedSend(db, id: id, currentRetryCount: 0, error: "Timeout")

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg?.outboxStatus == .queued)
        #expect(msg?.retryCount == 1)
    }

    @Test("retryCount 1 -> 2: stays queued (auto-retry)")
    func secondFailStaysQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, retryCount: 1)

        try simulateFailedSend(db, id: id, currentRetryCount: 1, error: "Timeout")

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg?.outboxStatus == .queued)
        #expect(msg?.retryCount == 2)
    }

    @Test("retryCount 2 -> 3: escalates to failed (boundary)")
    func thirdFailEscalatesToFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, retryCount: 2)

        try simulateFailedSend(db, id: id, currentRetryCount: 2, error: "Auth rejected")

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg?.outboxStatus == .failed)
        #expect(msg?.retryCount == 3)
        #expect(msg?.errorMessage == "Auth rejected")
    }

    @Test("retryCount already at 3: further fail keeps failed (>= 3 threshold)")
    func beyondThresholdStaysFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, status: "queued", retryCount: 3)

        try simulateFailedSend(db, id: id, currentRetryCount: 3, error: "Permanent error")

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg?.outboxStatus == .failed)
        #expect(msg?.retryCount == 4)
    }
}

// MARK: - Suite 3: Discard Guard

@Suite("Outbox Discard Guard")
struct OutboxDiscardGuardTests {

    /// Replicate discardOutboxMessageConfirmed DB logic: atomic fetch+check+delete.
    private func simulateDiscard(_ db: DatabaseQueue, id: String) throws -> Bool {
        try db.write { dbConn in
            guard let msg = try OutboxMessage.fetchOne(dbConn, key: id) else { return false }
            guard msg.outboxStatus != .sending else { return false }
            try OutboxMessage.deleteOne(dbConn, key: id)
            return true
        }
    }

    @Test("Cannot discard a message with status sending")
    func refusesDiscardWhenSending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, status: "sending")

        let discarded = try simulateDiscard(db, id: id)
        #expect(discarded == false)

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg != nil)
    }

    @Test("Can discard a queued message")
    func allowsDiscardWhenQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, status: "queued")

        let discarded = try simulateDiscard(db, id: id)
        #expect(discarded == true)

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg == nil)
    }

    @Test("Can discard a failed message")
    func allowsDiscardWhenFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, status: "failed", retryCount: 3)

        let discarded = try simulateDiscard(db, id: id)
        #expect(discarded == true)

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg == nil)
    }

    @Test("Discard of nonexistent message returns false")
    func nonexistentReturnsfalse() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let discarded = try simulateDiscard(db, id: "nonexistent-id")
        #expect(discarded == false)
    }

    @Test("Discard is atomic: fetch and delete in same transaction")
    func atomicFetchAndDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, status: "queued")

        // The atomic pattern: in one write transaction, fetch, check, delete.
        // If another thread changed status to "sending" between read and delete,
        // the write transaction serializes them.
        let result = try db.write { dbConn -> String? in
            guard let msg = try OutboxMessage.fetchOne(dbConn, key: id) else { return nil }
            guard msg.outboxStatus != .sending else { return nil }
            try OutboxMessage.deleteOne(dbConn, key: id)
            return msg.attachmentsDirName
        }

        #expect(result == nil) // no attachmentsDirName was set
        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg == nil)
    }
}

// MARK: - Suite 4: Retry Outbox Message

@Suite("Outbox Retry Reset")
struct OutboxRetryResetTests {

    /// Replicate retryOutboxMessage logic: reset status, errorMessage, retryCount.
    private func simulateRetry(_ db: DatabaseQueue, id: String) throws -> Bool {
        do {
            try db.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE outboxMessage SET status = ?, errorMessage = NULL, retryCount = 0 WHERE id = ?",
                    arguments: [OutboxStatus.queued.rawValue, id]
                )
            }
            return true
        } catch {
            return false
        }
    }

    @Test("Retry resets status to queued")
    func resetsStatusToQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(
            db, status: "failed", errorMessage: "Network error", retryCount: 5
        )

        let success = try simulateRetry(db, id: id)
        #expect(success)

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg?.outboxStatus == .queued)
        #expect(msg?.retryCount == 0)
        #expect(msg?.errorMessage == nil)
    }

    @Test("Retry on queued message is idempotent")
    func retryOnQueuedIsIdempotent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(db, status: "queued", retryCount: 1)

        let success = try simulateRetry(db, id: id)
        #expect(success)

        let msg = try db.read { try OutboxMessage.fetchOne($0, key: id) }
        #expect(msg?.outboxStatus == .queued)
        #expect(msg?.retryCount == 0)
    }

    @Test("After retry, message appears in drain query")
    func afterRetryAppearInDrainQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let id = try insertOutboxMessageSQL(
            db, status: "failed", retryCount: 3
        )

        // Before retry: not in drain set
        let beforeDrain = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(beforeDrain.isEmpty)

        _ = try simulateRetry(db, id: id)

        // After retry: in drain set
        let afterDrain = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(afterDrain.count == 1)
        #expect(afterDrain[0].id == id)
    }
}

// MARK: - Suite 5: Generate Message ID

@Suite("Generate Message ID Format")
struct GenerateMessageIdFormatTests {

    @Test("Format is <UUID@domain> for standard email")
    func standardFormat() {
        let id = AccountManager.generateMessageId(senderEmail: "user@example.com")
        #expect(id.hasPrefix("<"))
        #expect(id.hasSuffix(">"))
        #expect(id.contains("@example.com"))
        // UUID portion: 36 chars between < and @
        let inner = String(id.dropFirst().dropLast())
        let atIndex = inner.firstIndex(of: "@")!
        let uuidPart = inner[inner.startIndex..<atIndex]
        #expect(uuidPart.count == 36)
    }

    @Test("Extracts domain from email with subdomain")
    func subdomainEmail() {
        let id = AccountManager.generateMessageId(senderEmail: "user@mail.corp.example.com")
        #expect(id.hasSuffix("@mail.corp.example.com>"))
    }

    @Test("Falls back to tabmail.local for empty string")
    func emptyStringFallback() {
        let id = AccountManager.generateMessageId(senderEmail: "")
        #expect(id.hasSuffix("@tabmail.local>"))
    }

    @Test("Multiple @ signs: uses last segment")
    func multipleAtSigns() {
        let id = AccountManager.generateMessageId(senderEmail: "bad@format@real.com")
        #expect(id.hasSuffix("@real.com>"))
    }

    @Test("Each call generates a unique ID")
    func uniqueness() {
        let ids = (0..<10).map { _ in AccountManager.generateMessageId(senderEmail: "user@test.com") }
        let uniqueIds = Set(ids)
        #expect(uniqueIds.count == 10)
    }
}

// MARK: - Suite 6: Finalize Outbox ReplyDetect

@Suite("Finalize Outbox ReplyDetect")
struct FinalizeOutboxReplyDetectTests {

    /// Replicate the DB-level logic of finalizeOutboxMessage for reply detection.
    /// Returns the originalMessageHeaderId if reply detect fired (actionTag was .reply).
    private func simulateFinalize(
        _ db: DatabaseQueue, outboxId: String
    ) throws -> String? {
        try db.write { dbConn in
            guard let msg = try OutboxMessage.fetchOne(dbConn, key: outboxId) else { return nil }
            try OutboxMessage.deleteOne(dbConn, key: outboxId)

            if let originalId = msg.originalMessageHeaderId {
                if msg.isForward {
                    try dbConn.execute(
                        sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?",
                        arguments: [originalId]
                    )
                    if let original = try MessageHeader.fetchOne(dbConn, key: originalId) {
                        var markForwardedOp = PendingOperation(
                            type: .markForwarded,
                            messageIds: [original.stableId],
                            accountId: original.accountId,
                            folderPath: original.folderPath
                        )
                        try markForwardedOp.insert(dbConn)
                    }
                } else {
                    if var original = try MessageHeader.fetchOne(dbConn, key: originalId) {
                        original.isReplied = true
                        var markRepliedOp = PendingOperation(
                            type: .markReplied,
                            messageIds: [original.stableId],
                            accountId: original.accountId,
                            folderPath: original.folderPath
                        )
                        try markRepliedOp.insert(dbConn)
                        if original.actionTag == .reply {
                            original.actionTag = ActionTag.none
                            original.tagSortOrder = ActionTag.none.sortOrder
                            var tagOp = PendingOperation(
                                type: .setTag,
                                messageIds: [original.stableId],
                                accountId: original.accountId,
                                folderPath: original.folderPath,
                                tagValue: ActionTag.none.rawValue
                            )
                            try tagOp.insert(dbConn)
                            try original.update(dbConn)
                            return originalId
                        }
                        try original.update(dbConn)
                    }
                }
            }
            return nil
        }
    }

    @Test("Reply to message with actionTag .reply: sets isReplied, clears tag, queues ops")
    func replyDetectClearsReplyTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: folder.id, actionTag: .reply
        )

        let outboxId = try insertOutboxMessageSQL(
            db, originalMessageHeaderId: header.id, isForward: false
        )

        let replyDetectId = try simulateFinalize(db, outboxId: outboxId)

        #expect(replyDetectId == header.id)

        // Outbox message deleted
        let outbox = try db.read { try OutboxMessage.fetchOne($0, key: outboxId) }
        #expect(outbox == nil)

        // Original header updated
        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        #expect(updated?.actionTag == ActionTag.none)
        #expect(updated?.tagSortOrder == ActionTag.none.sortOrder)

        // Two pending ops: markReplied + setTag
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2)
        let opTypes = Set(ops.map(\.type))
        #expect(opTypes.contains(.markReplied))
        #expect(opTypes.contains(.setTag))
        let setTagOp = ops.first { $0.type == .setTag }
        #expect(setTagOp?.tagValue == ActionTag.none.rawValue)
    }

    @Test("Reply to message with actionTag != .reply: sets isReplied but does NOT clear tag")
    func replyWithoutReplyTagSetsIsRepliedOnly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "101", folderId: folder.id, actionTag: .archive
        )

        let outboxId = try insertOutboxMessageSQL(
            db, originalMessageHeaderId: header.id, isForward: false
        )

        let replyDetectId = try simulateFinalize(db, outboxId: outboxId)

        // No reply detect fired (tag was not .reply)
        #expect(replyDetectId == nil)

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        // actionTag unchanged
        #expect(updated?.actionTag == .archive)

        // Only markReplied pending op (no setTag)
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markReplied)
    }

    @Test("Reply to message with no actionTag: sets isReplied, no tag ops")
    func replyWithNoTagSetsIsReplied() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "102", folderId: folder.id, actionTag: nil
        )

        let outboxId = try insertOutboxMessageSQL(
            db, originalMessageHeaderId: header.id, isForward: false
        )

        let replyDetectId = try simulateFinalize(db, outboxId: outboxId)
        #expect(replyDetectId == nil)

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markReplied)
    }

    @Test("Forward: sets isForwarded and queues markForwarded op")
    func forwardSetsIsForwarded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "103", folderId: folder.id
        )

        let outboxId = try insertOutboxMessageSQL(
            db, originalMessageHeaderId: header.id, isForward: true
        )

        let replyDetectId = try simulateFinalize(db, outboxId: outboxId)
        #expect(replyDetectId == nil) // reply detect only fires for non-forward + .reply tag

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isForwarded == true)
        #expect(updated?.isReplied == false)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markForwarded)
    }

    @Test("No originalMessageHeaderId: deletes outbox message, no pending ops")
    func noOriginalHeaderJustDeletes() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let outboxId = try insertOutboxMessageSQL(db, originalMessageHeaderId: nil)

        let replyDetectId = try simulateFinalize(db, outboxId: outboxId)
        #expect(replyDetectId == nil)

        let outbox = try db.read { try OutboxMessage.fetchOne($0, key: outboxId) }
        #expect(outbox == nil)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty)
    }

    @Test("originalMessageHeaderId references deleted header: deletes outbox, no crash")
    func deletedOriginalHeaderNoCrash() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Reference a header that does not exist
        let outboxId = try insertOutboxMessageSQL(
            db, originalMessageHeaderId: "nonexistent-header-id", isForward: false
        )

        let replyDetectId = try simulateFinalize(db, outboxId: outboxId)
        #expect(replyDetectId == nil)

        let outbox = try db.read { try OutboxMessage.fetchOne($0, key: outboxId) }
        #expect(outbox == nil)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty)
    }
}

// MARK: - Suite 7: Drain Ordering and Filtering

@Suite("Outbox Drain Ordering and Filtering")
struct OutboxDrainOrderingTests {

    @Test("FIFO: messages ordered by createdAt ascending")
    func fifoOrdering() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Insert in reverse chronological order
        try insertOutboxMessageSQL(
            db, id: "msg-3", subject: "Third",
            createdAt: Date(timeIntervalSince1970: 3000)
        )
        try insertOutboxMessageSQL(
            db, id: "msg-1", subject: "First",
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        try insertOutboxMessageSQL(
            db, id: "msg-2", subject: "Second",
            createdAt: Date(timeIntervalSince1970: 2000)
        )

        let ordered = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        #expect(ordered.count == 3)
        #expect(ordered[0].subject == "First")
        #expect(ordered[1].subject == "Second")
        #expect(ordered[2].subject == "Third")
    }

    @Test("Only queued messages picked up by drain query")
    func onlyQueuedInDrain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try insertOutboxMessageSQL(db, id: "q1", subject: "Queued", status: "queued")
        try insertOutboxMessageSQL(db, id: "s1", subject: "Sending", status: "sending")
        try insertOutboxMessageSQL(db, id: "f1", subject: "Failed", status: "failed", retryCount: 3)

        let drainable = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        #expect(drainable.count == 1)
        #expect(drainable[0].subject == "Queued")
    }

    @Test("Failed accounts are skipped in drain loop")
    func failedAccountsSkipped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "acc2@example.com")

        try insertOutboxMessageSQL(
            db, id: "a1m1", accountId: "acc1", subject: "Acc1-1",
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        try insertOutboxMessageSQL(
            db, id: "a1m2", accountId: "acc1", subject: "Acc1-2",
            createdAt: Date(timeIntervalSince1970: 2000)
        )
        try insertOutboxMessageSQL(
            db, id: "a2m1", accountId: "acc2", subject: "Acc2-1",
            createdAt: Date(timeIntervalSince1970: 3000)
        )

        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        // Simulate: acc1 fails on first message
        var failedAccounts = Set<String>()
        failedAccounts.insert("acc1")

        var processed: [String] = []
        for msg in messages {
            if failedAccounts.contains(msg.accountId) { continue }
            processed.append(msg.subject)
        }

        #expect(processed == ["Acc2-1"])
    }

    @Test("Pending sent appends query finds sentAt!=nil + appendedToSent==false")
    func pendingSentAppendsQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Sent but not appended
        try insertOutboxMessageSQL(
            db, id: "pending1", status: "sending",
            sentAt: Date(), sentMessageId: "<x@y.com>", appendedToSent: false
        )
        // Fully done (should not appear)
        try insertOutboxMessageSQL(
            db, id: "done1", status: "sending",
            sentAt: Date(), sentMessageId: "<z@y.com>", appendedToSent: true
        )
        // Still queued (should not appear)
        try insertOutboxMessageSQL(db, id: "queued1", status: "queued")

        let pending = try db.read {
            try OutboxMessage
                .filter(Column("sentAt") != nil)
                .filter(Column("appendedToSent") == false)
                .fetchAll($0)
        }

        #expect(pending.count == 1)
        #expect(pending[0].id == "pending1")
    }
}

// MARK: - Suite 8: Optimistic isReplied/isForwarded on Queue

@Suite("Outbox Optimistic Reply Flag")
struct OutboxOptimisticReplyFlagTests {

    @Test("Queue reply sets isReplied on original message")
    func queueReplySetsIsReplied() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100", rfc822MessageId: "<orig@example.com>")

        // Simulate queueSend transaction: insert outbox + optimistic flag
        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "Re: Test", inReplyTo: "<orig@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        #expect(updated?.isForwarded == false)
    }

    @Test("Queue forward sets isForwarded on original message")
    func queueForwardSetsIsForwarded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "200", rfc822MessageId: "<fwd@example.com>")

        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "Fwd: Test", inReplyTo: "<fwd@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: true
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [header.id])
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isForwarded == true)
        #expect(updated?.isReplied == false)
    }

    @Test("Idempotent: setting isReplied twice does not error")
    func idempotentIsReplied() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "300", rfc822MessageId: "<idem@example.com>")

        // Set once (optimistic)
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }
        // Set again (finalize — simulates finalizeOutboxMessage)
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
    }

    @Test("nil replyToHeaderId does not touch any message")
    func nilReplyToHeaderIdIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "400")

        // Simulate queueSend with no replyToHeaderId
        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "New message"),
                originalMessageHeaderId: nil,
                isForward: false
            )
            try outbox.insert(dbConn)
            // No flag update — replyToHeaderId is nil
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == false)
        #expect(updated?.isForwarded == false)
    }

    /// ⚠️ RE-SCOPED (`IOS-TEST-004`). **Previous display name: *"Original message not
    /// found — no crash"*.** That name was the honest description of a test that
    /// asserted nothing: the body contained **zero `#expect`s**, it named
    /// `resolveOriginalMessage` only in a comment while hand-writing the raw SQL
    /// itself, it read `SELECT changes()` **before** the `UPDATE` it was meant to
    /// measure (the unused-`count` warning the compiler raised here), and it ended
    /// with *"If we reach here, no crash — test passes"* — it could fail only by
    /// throwing. "Does not crash" is not the property; **"mutates nothing"** is.
    ///
    /// It now drives the real production completion path,
    /// `AccountManager.deleteCompletedSendAtomic`, whose FIRST act on a reply is
    /// `resolveOriginalMessage(originalId:inReplyTo:accountId:db:)` — the function
    /// the old body only mentioned. With an `originalMessageHeaderId` that names no
    /// row, that resolve returns nil and the whole flag/tag block is skipped. The
    /// assertions are the END STATE, not the mechanism: no message row anywhere is
    /// touched, no durable `.markReplied` / `.setTag` op is queued, the disposition
    /// reports no reply-detect target, and the completion still cleans up its own
    /// outbox row rather than stranding it (Outbox rule 3 — `sentAt` is stamped, so
    /// this row must not survive to be re-sent).
    ///
    /// The bystander header carries the SAME `inReplyTo` RFC id the outbox names, so
    /// a resolver that ever fell back to an RFC search instead of the provider key
    /// would land on it and this test would go red — which is `IOS-IMAP-002`'s
    /// banned mechanism, pinned here as an end state.
    @Test("A completion whose original cannot be resolved mutates no message row and queues no op")
    func originalNotFoundIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let bystander = try TestDatabase.insertMessageHeader(
            db, messageId: "700", rfc822MessageId: "<ghost@example.com>")

        var outbox = OutboxMessage(
            accountId: "acc1",
            draft: DraftMessage(to: ["to@test.com"], subject: "Re: Ghost", inReplyTo: "<ghost@example.com>"),
            originalMessageHeaderId: "nonexistent-id",
            isForward: false
        )
        outbox.status = OutboxStatus.sending.rawValue
        outbox.sentAt = Date()
        outbox.appendedToSent = true
        let seeded = outbox
        try db.write { try seeded.insert($0) }

        let disposition = try db.write { dbConn in
            try AccountManager.deleteCompletedSendAtomic(outboxId: seeded.id, db: dbConn)
        }

        // Nothing was resolved, so nothing downstream of the resolve may have run.
        #expect(disposition.replyDetectHeaderId == nil)

        let after = try db.read { try MessageHeader.fetchOne($0, key: bystander.id) }
        #expect(after?.isReplied == false)
        #expect(after?.isForwarded == false)
        #expect(after?.actionTag == nil)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty, "an unresolvable original may not produce a durable gesture: \(ops.map(\.type))")

        // The completion still finishes: the row is gone, not stranded at `.sending`
        // with `sentAt` set, which is the double-send shape Outbox rule 3 forbids.
        let remaining = try db.read { try OutboxMessage.fetchOne($0, key: seeded.id) }
        #expect(remaining == nil)
    }

    @Test("Multiple replies to same message — idempotent flag")
    func multipleRepliesToSameMessage() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "600", rfc822MessageId: "<multi@example.com>")

        // First reply
        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["a@test.com"], subject: "Re: Multi", inReplyTo: "<multi@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }
        // Second reply to same message
        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["b@test.com"], subject: "Re: Re: Multi", inReplyTo: "<multi@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        let outboxCount = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(outboxCount == 2)
    }

    @Test("Reply + forward to same message — both flags set independently")
    func replyAndForwardToSameMessage() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "700", rfc822MessageId: "<both@example.com>")

        // Reply
        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["a@test.com"], subject: "Re: Both", inReplyTo: "<both@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }
        // Forward same message
        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["b@test.com"], subject: "Fwd: Both", inReplyTo: "<both@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: true
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [header.id])
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        #expect(updated?.isForwarded == true)
    }

    @Test("Finalize after optimistic still creates PendingOperation for server flag")
    func finalizeCreatesPendingOpAfterOptimistic() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "800", rfc822MessageId: "<pending@example.com>")

        // Step 1: optimistic update (queueSend)
        let outboxId = UUID().uuidString
        try db.write { dbConn in
            var outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "Re: Pending", inReplyTo: "<pending@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            outbox.id = outboxId
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
        }

        // Verify no PendingOperation yet (optimistic doesn't queue server flag)
        let pendingBefore = try db.read {
            try PendingOperation.filter(Column("type") == OperationType.markReplied.rawValue).fetchCount($0)
        }
        #expect(pendingBefore == 0)

        // Step 2: simulate finalizeOutboxMessage (after send succeeds)
        try db.write { dbConn in
            try OutboxMessage.deleteOne(dbConn, key: outboxId)
            // finalizeOutboxMessage sets flag again (idempotent) + queues PendingOp
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
            var markRepliedOp2 = PendingOperation(
                type: .markReplied,
                messageIds: [header.stableId],
                accountId: header.accountId,
                folderPath: header.folderPath
            )
            try markRepliedOp2.insert(dbConn)
        }

        // PendingOperation now exists for server-side \Answered flag
        let pendingAfter = try db.read {
            try PendingOperation.filter(Column("type") == OperationType.markReplied.rawValue).fetchCount($0)
        }
        #expect(pendingAfter == 1)

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
    }

    @Test("Transaction rolls back both outbox and flag on failure")
    func transactionRollbackOnFailure() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "500", rfc822MessageId: "<rollback@example.com>")

        // Simulate transaction failure after flag update but before commit
        do {
            try db.write { dbConn in
                let outbox = OutboxMessage(
                    accountId: "acc1",
                    draft: DraftMessage(to: ["to@test.com"], subject: "Re: Rollback", inReplyTo: "<rollback@example.com>"),
                    originalMessageHeaderId: header.id,
                    isForward: false
                )
                try outbox.insert(dbConn)
                try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
                // Force a rollback by throwing
                throw CancellationError()
            }
        } catch is CancellationError {
            // Expected
        }

        // Both outbox insert and flag update should be rolled back
        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == false)
        let outboxCount = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(outboxCount == 0)
    }

    @Test("Queue reply clears actionTag .reply to .none optimistically")
    func queueReplyClearsReplyTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "900", rfc822MessageId: "<tag@example.com>", actionTag: .reply
        )
        #expect(header.actionTag == .reply)

        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "Re: Tag", inReplyTo: "<tag@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
            // Clear reply tag optimistically
            try dbConn.execute(
                sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ? WHERE id = ?",
                arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, header.id]
            )
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        #expect(updated?.actionTag == ActionTag.none)
    }

    @Test("Queue reply does NOT clear non-reply actionTags")
    func queueReplyPreservesOtherTags() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "910", rfc822MessageId: "<keep@example.com>", actionTag: .archive
        )

        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "Re: Keep", inReplyTo: "<keep@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: false
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE id = ?", arguments: [header.id])
            // Only clear if actionTag == .reply — archive should be preserved
            let current = try MessageHeader.fetchOne(dbConn, key: header.id)
            if current?.actionTag == .reply {
                try dbConn.execute(
                    sql: "UPDATE messageHeader SET actionTag = ?, tagSortOrder = ? WHERE id = ?",
                    arguments: [ActionTag.none.rawValue, ActionTag.none.sortOrder, header.id]
                )
            }
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isReplied == true)
        #expect(updated?.actionTag == .archive)
    }

    @Test("Forward does NOT clear actionTag .reply")
    func forwardDoesNotClearReplyTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "920", rfc822MessageId: "<fwdtag@example.com>", actionTag: .reply
        )

        try db.write { dbConn in
            let outbox = OutboxMessage(
                accountId: "acc1",
                draft: DraftMessage(to: ["to@test.com"], subject: "Fwd: Tag", inReplyTo: "<fwdtag@example.com>"),
                originalMessageHeaderId: header.id,
                isForward: true
            )
            try outbox.insert(dbConn)
            try dbConn.execute(sql: "UPDATE messageHeader SET isForwarded = 1 WHERE id = ?", arguments: [header.id])
            // Forward path should NOT clear reply tag
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(updated?.isForwarded == true)
        #expect(updated?.actionTag == .reply)
    }
}
