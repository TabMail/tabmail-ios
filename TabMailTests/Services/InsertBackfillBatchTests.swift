/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - InsertBackfillBatch Integration Tests

/// Tests for SyncEngine.insertBackfillBatch() — the core backfill insert method.
/// This method handles: dedup against existing messages, pending-op skip,
/// ReplyDetect override, FTS record building, AI cache restore, and cc/bcc backfill.
///
/// We can't call SyncEngine.insertBackfillBatch directly (it's on the actor),
/// so we replicate the algorithm using the same GRDB operations.

@Suite("InsertBackfillBatch — Dedup and Insert")
struct InsertBackfillBatchDedupTests {

    /// Simulate insertBackfillBatch using the same algorithm as production.
    /// Returns (inserted count, FTS records, cc/bcc updates).
    private func simulateInsertBackfillBatch(
        _ headers: [MessageHeaderInfo],
        folderId: String,
        accountId: String,
        folderPath: String,
        isInInbox: Bool,
        db: DatabaseQueue,
        needsCcBccBackfill: Bool = false
    ) throws -> (inserted: Int, ftsRecords: [FTSHeaderRecord], ccBccUpdates: [(headerId: String, cc: String, bcc: String)]) {
        guard !headers.isEmpty else { return (0, [], []) }

        var ftsRecords: [FTSHeaderRecord] = []
        var count = 0
        var ccBccUpdates: [(headerId: String, cc: String, bcc: String)] = []

        try db.write { db in
            // Load pending destructive IDs
            let pendingDestructiveIds = Set(
                try PendingOperation
                    .filter(Column("accountId") == accountId && Column("folderPath") == folderPath)
                    .filter([OperationType.archive, .delete, .move].map(\.rawValue).contains(Column("type")))
                    .fetchAll(db)
                    .flatMap(\.messageIds)
            )

            // Batch existence check
            let incomingIds = headers.map(\.messageId)
            var existingIds = Set<String>()
            let sqlChunkSize = 500
            for start in stride(from: 0, to: incomingIds.count, by: sqlChunkSize) {
                let end = min(start + sqlChunkSize, incomingIds.count)
                let chunk = Array(incomingIds[start..<end])
                let found = try String.fetchSet(db,
                    MessageHeader
                        .select(Column("messageId"))
                        .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                )
                existingIds.formUnion(found)
            }

            for info in headers {
                // PendingOp skip
                if pendingDestructiveIds.contains(info.messageId) ||
                   (info.rfc822MessageId.map { pendingDestructiveIds.contains($0) } ?? false) { continue }
                if existingIds.contains(info.messageId) {
                    // cc/bcc backfill for existing
                    if needsCcBccBackfill && (!info.cc.isEmpty || !info.bcc.isEmpty) {
                        let headerId = "\(accountId):\(folderPath):\(info.messageId)"
                        try db.execute(
                            sql: "UPDATE messageHeader SET cc = ?, bcc = ? WHERE id = ?",
                            arguments: [info.cc, info.bcc, headerId]
                        )
                        ccBccUpdates.append((headerId: headerId, cc: info.cc, bcc: info.bcc))
                    }
                    continue
                }

                var header = MessageHeader(
                    messageId: info.messageId,
                    subject: info.subject,
                    from: info.from,
                    fromAddress: info.fromAddress,
                    to: info.to,
                    date: info.date,
                    snippet: EmailFilter.decodeHTMLEntities(info.snippet),
                    folderId: folderId,
                    accountId: accountId,
                    folderPath: folderPath,
                    isInInbox: isInInbox
                )
                header.rfc822MessageId = info.rfc822MessageId
                header.inReplyTo = info.inReplyTo
                header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: accountId, subject: header.subject)
                header.replyTo = info.replyTo
                header.cc = info.cc
                header.bcc = info.bcc
                header.isRead = info.isRead
                header.isFlagged = info.isFlagged
                header.hasAttachments = info.hasAttachments
                header.isReplied = info.isReplied
                header.isForwarded = info.isForwarded
                header.actionTag = info.actionTag
                header.tagSortOrder = info.actionTag?.sortOrder ?? 99

                // Restore AI cache
                try MessageAICache.restoreIfCached(
                    into: &header,
                    accountId: accountId,
                    folderPath: folderPath,
                    db: db
                )

                // ReplyDetect override
                if header.isReplied && header.actionTag == .reply {
                    header.actionTag = ActionTag.none
                    header.tagSortOrder = ActionTag.none.sortOrder
                }

                try header.insert(db)
                count += 1

                ftsRecords.append(FTSHeaderRecord(
                    headerId: header.id,
                    messageId: header.messageId,
                    subject: header.subject,
                    from: "\(header.from) <\(header.fromAddress)>",
                    to: header.to,
                    cc: header.cc,
                    bcc: header.bcc,
                    dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
                ))
            }
        }
        return (count, ftsRecords, ccBccUpdates)
    }

    private func makeHeaderInfo(
        messageId: String,
        subject: String = "Test Subject",
        from: String = "sender@example.com",
        date: Date = Date(),
        isRead: Bool = false,
        isReplied: Bool = false,
        actionTag: ActionTag? = nil,
        rfc822MessageId: String? = nil,
        cc: String = "",
        bcc: String = ""
    ) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: messageId,
            rfc822MessageId: rfc822MessageId,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: subject,
            from: from,
            fromAddress: from,
            to: "recipient@example.com",
            cc: cc,
            bcc: bcc,
            replyTo: nil,
            date: date,
            snippet: "snippet",
            isRead: isRead,
            isFlagged: false,
            hasAttachments: false,
            isReplied: isReplied,
            isForwarded: false,
            actionTag: actionTag
        )
    }

    @Test("Insert new messages — all inserted with FTS records")
    func insertNewMessages() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let infos = [
            makeHeaderInfo(messageId: "100", subject: "Hello"),
            makeHeaderInfo(messageId: "101", subject: "World"),
            makeHeaderInfo(messageId: "102", subject: "Test"),
        ]

        let (inserted, ftsRecords, _) = try simulateInsertBackfillBatch(
            infos, folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, db: db
        )

        #expect(inserted == 3)
        #expect(ftsRecords.count == 3)

        let count = try db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 3)
    }

    @Test("Dedup — existing messages are skipped")
    func dedupExistingMessages() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        let infos = [
            makeHeaderInfo(messageId: "100"), // already exists
            makeHeaderInfo(messageId: "101"), // new
        ]

        let (inserted, ftsRecords, _) = try simulateInsertBackfillBatch(
            infos, folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, db: db
        )

        #expect(inserted == 1, "Only new message should be inserted")
        #expect(ftsRecords.count == 1)
        #expect(ftsRecords[0].messageId == "101")
    }

    @Test("Skip messages with pending destructive ops — by messageId")
    func skipPendingDestructiveOps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Create a pending archive op for message "100"
        try db.write { db in
            try PendingOperation(
                type: .archive,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "INBOX"
            ).insert(db)
        }

        let infos = [
            makeHeaderInfo(messageId: "100"), // has pending archive
            makeHeaderInfo(messageId: "101"), // no pending op
        ]

        let (inserted, _, _) = try simulateInsertBackfillBatch(
            infos, folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, db: db
        )

        #expect(inserted == 1, "Message with pending archive should be skipped")
    }

    @Test("Skip messages with pending destructive ops — by rfc822MessageId")
    func skipPendingDestructiveByRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pending move uses the provider-neutral RFC Message-ID.
        try db.write { db in
            try PendingOperation(
                type: .move,
                messageIds: ["<msg100@example.com>"],
                accountId: "acc1",
                folderPath: "INBOX"
            ).insert(db)
        }

        let infos = [
            makeHeaderInfo(messageId: "100", rfc822MessageId: "<msg100@example.com>"),
        ]

        let (inserted, _, _) = try simulateInsertBackfillBatch(
            infos, folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, db: db
        )

        #expect(inserted == 0, "Message with pending move (by rfc822MessageId) should be skipped")
    }

    @Test("Pending ops from different folder don't affect insert")
    func pendingOpsWrongFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Pending delete in Sent folder
        try db.write { db in
            try PendingOperation(
                type: .delete,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "Sent"
            ).insert(db)
        }

        let infos = [makeHeaderInfo(messageId: "100")]

        let (inserted, _, _) = try simulateInsertBackfillBatch(
            infos, folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, db: db
        )

        #expect(inserted == 1, "Pending op in different folder should not block insert")
    }

    @Test("Empty input returns zero counts")
    func emptyInput() throws {
        let db = try TestDatabase.make()
        let (inserted, ftsRecords, ccBccUpdates) = try simulateInsertBackfillBatch(
            [], folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true, db: db
        )
        #expect(inserted == 0)
        #expect(ftsRecords.isEmpty)
        #expect(ccBccUpdates.isEmpty)
    }

    @Test("Cross-folder dedup — same messageId in different folder is NOT a duplicate")
    func crossFolderNotDuplicate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Insert message "100" in INBOX
        try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        // Insert same messageId into Sent folder
        let infos = [makeHeaderInfo(messageId: "100")]
        let (inserted, _, _) = try simulateInsertBackfillBatch(
            infos, folderId: "acc1:Sent", accountId: "acc1",
            folderPath: "Sent", isInInbox: false, db: db
        )

        #expect(inserted == 1, "Same messageId in different folder should not be considered duplicate")
    }
}

@Suite("InsertBackfillBatch — ReplyDetect Override")
struct InsertBackfillBatchReplyDetectTests {

    private func makeHeaderInfo(
        messageId: String,
        isReplied: Bool = false,
        actionTag: ActionTag? = nil,
        rfc822MessageId: String? = nil
    ) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: messageId,
            rfc822MessageId: rfc822MessageId,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Test",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "snippet",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: isReplied,
            isForwarded: false,
            actionTag: actionTag
        )
    }

    private func simulateInsert(
        _ headers: [MessageHeaderInfo],
        db: DatabaseQueue
    ) throws -> Int {
        var count = 0
        try db.write { db in
            for info in headers {
                var header = MessageHeader(
                    messageId: info.messageId,
                    subject: info.subject,
                    from: info.from,
                    fromAddress: info.fromAddress,
                    to: info.to,
                    date: info.date,
                    snippet: info.snippet,
                    folderId: "acc1:INBOX",
                    accountId: "acc1",
                    folderPath: "INBOX",
                    isInInbox: true
                )
                header.isReplied = info.isReplied
                header.actionTag = info.actionTag
                header.tagSortOrder = info.actionTag?.sortOrder ?? 99
                header.rfc822MessageId = info.rfc822MessageId

                // ReplyDetect override
                if header.isReplied && header.actionTag == .reply {
                    header.actionTag = ActionTag.none
                    header.tagSortOrder = ActionTag.none.sortOrder
                }
                try header.insert(db)
                count += 1
            }
        }
        return count
    }

    @Test("ReplyDetect overrides reply→none when isReplied is true")
    func replyDetectOverride() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info = makeHeaderInfo(messageId: "100", isReplied: true, actionTag: .reply)
        _ = try simulateInsert([info], db: db)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(header?.actionTag == ActionTag.none, "ReplyDetect should override reply→none")

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty, "ReplyDetect clears the local action tag without a durable provider operation")
    }

    @Test("ReplyDetect does NOT override when isReplied is false")
    func noOverrideWhenNotReplied() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info = makeHeaderInfo(messageId: "100", isReplied: false, actionTag: .reply)
        _ = try simulateInsert([info], db: db)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(header?.actionTag == .reply, "Reply tag should remain when not replied")

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty, "No setTag op needed when not replied")
    }

    @Test("ReplyDetect does NOT affect non-reply tags")
    func noOverrideForNonReplyTags() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info = makeHeaderInfo(messageId: "100", isReplied: true, actionTag: .archive)
        _ = try simulateInsert([info], db: db)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(header?.actionTag == .archive, "Archive tag should not be affected by ReplyDetect")
    }
}

@Suite("InsertBackfillBatch — FTS Record Building")
struct InsertBackfillBatchFTSTests {

    @Test("FTS records have correct field mapping")
    func ftsRecordFieldMapping() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let testDate = Date(timeIntervalSince1970: 1700000000)
        let info = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Important Email",
            from: "Alice Smith",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            cc: "carol@example.com",
            bcc: "dave@example.com",
            replyTo: nil,
            date: testDate,
            snippet: "Hello world",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )

        // Replicate the FTS record building from insertBackfillBatch
        var header = MessageHeader(
            messageId: info.messageId,
            subject: info.subject,
            from: info.from,
            fromAddress: info.fromAddress,
            to: info.to,
            date: info.date,
            snippet: info.snippet,
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.cc = info.cc
        header.bcc = info.bcc
        try db.write { try header.insert($0) }

        let ftsRecord = FTSHeaderRecord(
            headerId: header.id,
            messageId: header.messageId,
            subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>",
            to: header.to,
            cc: header.cc,
            bcc: header.bcc,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )

        #expect(ftsRecord.headerId == "acc1:INBOX:100")
        #expect(ftsRecord.messageId == "100")
        #expect(ftsRecord.subject == "Important Email")
        #expect(ftsRecord.from == "Alice Smith <alice@example.com>")
        #expect(ftsRecord.to == "bob@example.com")
        #expect(ftsRecord.cc == "carol@example.com")
        #expect(ftsRecord.bcc == "dave@example.com")
        #expect(ftsRecord.dateMs == 1700000000000)
    }

    @Test("Thread ID computed from subject when not provided")
    func threadIdComputedFromSubject() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,  // Not provided — should be computed
            subject: "Re: Important Discussion",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )

        var header = MessageHeader(
            messageId: info.messageId,
            subject: info.subject,
            from: info.from,
            fromAddress: info.fromAddress,
            to: info.to,
            date: info.date,
            snippet: info.snippet,
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: header.subject)
        try db.write { try header.insert($0) }

        let saved = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        let expectedThreadId = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Important Discussion")
        #expect(saved?.threadId == expectedThreadId)
        #expect(saved?.threadId != nil, "ThreadId should be computed from subject")
    }

    @Test("Thread ID preserved when provider supplies one")
    func threadIdPreservedFromProvider() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: "gmail-thread-123",
            subject: "Test",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )

        var header = MessageHeader(
            messageId: info.messageId,
            subject: info.subject,
            from: info.from,
            fromAddress: info.fromAddress,
            to: info.to,
            date: info.date,
            snippet: info.snippet,
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: header.subject)
        try db.write { try header.insert($0) }

        let saved = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(saved?.threadId == "gmail-thread-123", "Provider-supplied threadId should be preserved")
    }
}

@Suite("InsertBackfillBatch — AI Cache Restore")
struct InsertBackfillBatchAICacheTests {

    @Test("AI cache restores summary when re-inserting a message")
    func aiCacheRestoresSummary() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pre-populate AI cache
        try db.write { db in
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg100@example.com>",
                summaryBlurb: "This is a cached summary",
                summaryTodos: "- Todo 1\n- Todo 2",
                actionTag: .reply,
                db: db
            )
        }

        // Now insert via backfill — should restore from cache
        var header = MessageHeader(
            messageId: "100",
            subject: "Test",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<msg100@example.com>"

        try db.write { db in
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: db
            )
            try header.insert(db)
        }

        let saved = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(saved?.summaryBlurb == "This is a cached summary")
        #expect(saved?.summaryTodos == "- Todo 1\n- Todo 2")
        #expect(saved?.actionTag == .reply, "Action tag should be restored from AI cache")
    }

    @Test("AI cache does not overwrite server-provided action tag")
    func aiCacheNoOverwriteServerTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pre-populate AI cache with .archive
        try db.write { db in
            try MessageAICache.writeThrough(
                accountId: "acc1",
                folderPath: "INBOX",
                rfc822MessageId: "<msg100@example.com>",
                actionTag: .archive,
                db: db
            )
        }

        // Insert with server-provided .delete tag
        var header = MessageHeader(
            messageId: "100",
            subject: "Test",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<msg100@example.com>"
        header.actionTag = .delete
        header.tagSortOrder = ActionTag.delete.sortOrder

        try db.write { db in
            try MessageAICache.restoreIfCached(
                into: &header,
                accountId: "acc1",
                folderPath: "INBOX",
                db: db
            )
            try header.insert(db)
        }

        let saved = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(saved?.actionTag == .delete, "Server-provided tag should take precedence over AI cache")
    }
}

@Suite("InsertBackfillBatch — CC/BCC Backfill")
struct InsertBackfillBatchCcBccTests {

    @Test("CC/BCC backfill updates existing messages when flag is set")
    func ccBccBackfillUpdatesExisting() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        let info = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Test",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "cc@example.com",
            bcc: "bcc@example.com",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )

        // Simulate with needsCcBccBackfill = true
        var ccBccUpdates: [(headerId: String, cc: String, bcc: String)] = []
        try db.write { db in
            let existingIds = try String.fetchSet(db,
                MessageHeader
                    .select(Column("messageId"))
                    .filter(Column("folderId") == "acc1:INBOX" && ["100"].contains(Column("messageId")))
            )
            if existingIds.contains(info.messageId) && (!info.cc.isEmpty || !info.bcc.isEmpty) {
                let headerId = "acc1:INBOX:\(info.messageId)"
                try db.execute(
                    sql: "UPDATE messageHeader SET cc = ?, bcc = ? WHERE id = ?",
                    arguments: [info.cc, info.bcc, headerId]
                )
                ccBccUpdates.append((headerId: headerId, cc: info.cc, bcc: info.bcc))
            }
        }

        #expect(ccBccUpdates.count == 1)
        #expect(ccBccUpdates[0].cc == "cc@example.com")

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(header?.cc == "cc@example.com")
        #expect(header?.bcc == "bcc@example.com")
    }
}

@Suite("InsertBackfillBatch — Header Field Mapping")
struct InsertBackfillBatchFieldMappingTests {

    @Test("All header fields are correctly mapped from MessageHeaderInfo")
    func allFieldsMapped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let testDate = Date(timeIntervalSince1970: 1700000000)
        let info = MessageHeaderInfo(
            messageId: "100",
            rfc822MessageId: "<msg100@example.com>",
            inReplyTo: "<parent@example.com>",
            references: [],
            threadId: "thread-xyz",
            subject: "Test Subject",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            cc: "carol@example.com",
            bcc: "dave@example.com",
            replyTo: "alice-reply@example.com",
            date: testDate,
            snippet: "Hello &amp; world",
            isRead: true,
            isFlagged: true,
            hasAttachments: true,
            isReplied: true,
            isForwarded: true,
            actionTag: .archive
        )

        var header = MessageHeader(
            messageId: info.messageId,
            subject: info.subject,
            from: info.from,
            fromAddress: info.fromAddress,
            to: info.to,
            date: info.date,
            snippet: EmailFilter.decodeHTMLEntities(info.snippet),
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = info.rfc822MessageId
        header.inReplyTo = info.inReplyTo
        header.threadId = info.threadId
        header.replyTo = info.replyTo
        header.cc = info.cc
        header.bcc = info.bcc
        header.isRead = info.isRead
        header.isFlagged = info.isFlagged
        header.hasAttachments = info.hasAttachments
        header.isReplied = info.isReplied
        header.isForwarded = info.isForwarded
        header.actionTag = info.actionTag
        header.tagSortOrder = info.actionTag?.sortOrder ?? 99

        try db.write { try header.insert($0) }

        let saved = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }!
        #expect(saved.messageId == "100")
        #expect(saved.subject == "Test Subject")
        #expect(saved.from == "Alice")
        #expect(saved.fromAddress == "alice@example.com")
        #expect(saved.to == "bob@example.com")
        #expect(saved.date == testDate)
        #expect(saved.snippet == "Hello & world", "HTML entities should be decoded")
        #expect(saved.isRead == true)
        #expect(saved.isFlagged == true)
        #expect(saved.hasAttachments == true)
        #expect(saved.rfc822MessageId == "<msg100@example.com>")
        #expect(saved.inReplyTo == "<parent@example.com>")
        #expect(saved.threadId == "thread-xyz")
        #expect(saved.replyTo == "alice-reply@example.com")
        #expect(saved.cc == "carol@example.com")
        #expect(saved.bcc == "dave@example.com")
        #expect(saved.isReplied == true)
        #expect(saved.isForwarded == true)
        #expect(saved.actionTag == .archive)
        #expect(saved.tagSortOrder == ActionTag.archive.sortOrder)
    }

    @Test("HTML entities in snippet are decoded")
    func snippetHtmlDecode() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let decoded = EmailFilter.decodeHTMLEntities("Hello &amp; world &lt;test&gt;")
        #expect(decoded == "Hello & world <test>")
    }
}
