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
    snippet: String = "This is a test snippet",
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

/// Convert a MessageHeaderInfo to a MessageHeader for DB insertion.
private func toMessageHeader(
    _ info: MessageHeaderInfo,
    accountId: String = "acc1",
    folderPath: String = "INBOX"
) -> MessageHeader {
    let folderId = "\(accountId):\(folderPath)"
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
        isInInbox: folderPath == "INBOX"
    )
    header.rfc822MessageId = info.rfc822MessageId
    header.inReplyTo = info.inReplyTo
    header.threadId = info.threadId
    header.cc = info.cc
    header.bcc = info.bcc
    header.replyTo = info.replyTo
    header.isRead = info.isRead
    header.isFlagged = info.isFlagged
    header.hasAttachments = info.hasAttachments
    header.isReplied = info.isReplied
    header.isForwarded = info.isForwarded
    header.actionTag = info.actionTag
    if let tag = info.actionTag {
        header.tagSortOrder = tag.sortOrder
    }
    return header
}

// MARK: - Suite: Folder Fetch → DB Insert

@Suite("MockProvider Integration - FolderInfo → Folder DB")
struct FolderFetchDBTests {

    @Test("fetchFolders returns FolderInfo, convert to Folder records, insert and verify all fields")
    func fetchFoldersAndInsertToDB() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let mock = MockEmailProvider()
        let folderInfos: [FolderInfo] = [
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 5, totalCount: 100, uidNext: 500),
            FolderInfo(name: "Sent Mail", path: "Sent", role: .sent, unreadCount: 0, totalCount: 42),
            FolderInfo(name: "Trash", path: "Trash", role: .trash, unreadCount: 1, totalCount: 10),
            FolderInfo(name: "My Label", path: "Labels/MyLabel", role: .custom, unreadCount: 3, totalCount: 15),
        ]
        await mock.setFetchFoldersResult(folderInfos)

        let fetched = try await mock.fetchFolders()
        #expect(fetched.count == 4)

        // Convert FolderInfo → Folder and insert
        let accountId = "acc1"
        try await db.write { dbConn in
            for info in fetched {
                var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: accountId)
                folder.unreadCount = info.unreadCount
                folder.totalCount = info.totalCount
                folder.lastKnownUidNext = info.uidNext
                try folder.insert(dbConn)
            }
        }

        // Verify all fields preserved
        let stored = try await db.read { try Folder.fetchAll($0) }
        #expect(stored.count == 4)

        let inbox = stored.first { $0.path == "INBOX" }
        #expect(inbox != nil)
        #expect(inbox?.name == "Inbox")
        #expect(inbox?.role == .inbox)
        #expect(inbox?.unreadCount == 5)
        #expect(inbox?.totalCount == 100)
        #expect(inbox?.lastKnownUidNext == 500)
        #expect(inbox?.accountId == "acc1")
        #expect(inbox?.id == "acc1:INBOX")

        let sent = stored.first { $0.path == "Sent" }
        #expect(sent?.name == "Sent Mail")
        #expect(sent?.role == .sent)
        #expect(sent?.unreadCount == 0)
        #expect(sent?.totalCount == 42)
        #expect(sent?.lastKnownUidNext == nil)

        let custom = stored.first { $0.path == "Labels/MyLabel" }
        #expect(custom?.name == "My Label")
        #expect(custom?.role == .custom)
        #expect(custom?.unreadCount == 3)
    }

    @Test("fetchFolders with empty result inserts nothing")
    func fetchFoldersEmpty() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let mock = MockEmailProvider()
        // Default is empty array

        let fetched = try await mock.fetchFolders()
        #expect(fetched.isEmpty)

        let stored = try await db.read { try Folder.fetchAll($0) }
        #expect(stored.isEmpty)
    }
}

// MARK: - Suite: MessageHeader Fetch → DB Insert

@Suite("MockProvider Integration - MessageHeaderInfo → MessageHeader DB")
struct MessageHeaderFetchDBTests {

    @Test("fetchMessages returns MessageHeaderInfo, convert and insert, verify all fields")
    func fetchMessagesAndInsertToDB() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let mock = MockEmailProvider()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let infos: [MessageHeaderInfo] = [
            makeHeaderInfo(
                messageId: "101",
                rfc822MessageId: "<msg-101@example.com>",
                inReplyTo: "<parent@example.com>",
                references: [],
                threadId: "thread-1",
                subject: "Meeting Tomorrow",
                from: "Alice Smith",
                fromAddress: "alice@example.com",
                to: "bob@example.com",
                cc: "charlie@example.com",
                bcc: "hidden@example.com",
                replyTo: "alice-reply@example.com",
                date: date,
                snippet: "Let's meet at 10am",
                isRead: true,
                isFlagged: true,
                hasAttachments: true,
                isReplied: true,
                isForwarded: false,
                actionTag: ActionTag.reply
            ),
            makeHeaderInfo(
                messageId: "102",
                rfc822MessageId: "<msg-102@example.com>",
                subject: "Newsletter",
                from: "News Bot",
                fromAddress: "bot@news.com",
                to: "bob@example.com",
                date: date.addingTimeInterval(3600),
                snippet: "Weekly digest",
                isRead: false,
                isFlagged: false,
                hasAttachments: false,
                actionTag: ActionTag.none
            ),
        ]
        await mock.setFetchMessagesResult(infos)

        let fetched = try await mock.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        #expect(fetched.count == 2)

        // Convert and insert
        try await db.write { dbConn in
            for info in fetched {
                let header = toMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        // Verify first message
        let h1 = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:101") }
        #expect(h1 != nil)
        #expect(h1?.subject == "Meeting Tomorrow")
        #expect(h1?.from == "Alice Smith")
        #expect(h1?.fromAddress == "alice@example.com")
        #expect(h1?.to == "bob@example.com")
        #expect(h1?.cc == "charlie@example.com")
        #expect(h1?.bcc == "hidden@example.com")
        #expect(h1?.replyTo == "alice-reply@example.com")
        #expect(h1?.rfc822MessageId == "<msg-101@example.com>")
        #expect(h1?.inReplyTo == "<parent@example.com>")
        #expect(h1?.threadId == "thread-1")
        #expect(h1?.snippet == "Let's meet at 10am")
        #expect(h1?.isRead == true)
        #expect(h1?.isFlagged == true)
        #expect(h1?.hasAttachments == true)
        #expect(h1?.isReplied == true)
        #expect(h1?.isForwarded == false)
        #expect(h1?.actionTag == ActionTag.reply)
        #expect(h1?.tagSortOrder == ActionTag.reply.sortOrder)
        #expect(h1?.isInInbox == true)
        #expect(h1?.accountId == "acc1")
        #expect(h1?.folderPath == "INBOX")

        // Verify second message
        let h2 = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:102") }
        #expect(h2 != nil)
        #expect(h2?.subject == "Newsletter")
        #expect(h2?.actionTag == ActionTag.none)
        #expect(h2?.tagSortOrder == ActionTag.none.sortOrder)
        #expect(h2?.isRead == false)
    }

    @Test("fetchMessages with pagination parameters logged correctly")
    func fetchMessagesPagination() async throws {
        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([])

        _ = try await mock.fetchMessages(folder: "Sent", limit: 25, offset: 50)

        let log = await mock.callLog
        #expect(log.contains("fetchMessages(folder:Sent,limit:25,offset:50)"))
    }
}

// MARK: - Suite: FullMessageInfo → MessageBody DB

@Suite("MockProvider Integration - FullMessageInfo → MessageBody DB")
struct FullMessageFetchDBTests {

    @Test("fetchMessage with htmlBody and textBody stores htmlBody as MessageBody")
    func fetchMessageWithHtmlAndText() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let dbHeader = try TestDatabase.insertMessageHeader(db, messageId: "300")

        let mock = MockEmailProvider()
        let headerInfo = makeHeaderInfo(messageId: "300")
        let fullMsg = FullMessageInfo(
            header: headerInfo,
            htmlBody: "<div><p>Rich email content</p><img src='cid:image1'/></div>",
            textBody: "Rich email content",
            attachments: [
                AttachmentInfo(filename: "doc.pdf", contentType: "application/pdf", section: "2", size: 102400, encoding: "base64"),
                AttachmentInfo(filename: "photo.jpg", contentType: "image/jpeg", section: "3", size: 50000, encoding: nil),
            ]
        )
        await mock.setFetchMessageResult(fullMsg)

        let result = try await mock.fetchMessage(id: "300", folder: "INBOX")

        // Store body via the real render path (sets attachmentsJSON from the message).
        let (body, _, _) = await BodyFetchProcessor.renderBody(headerId: dbHeader.id, fullMessage: result)

        let bodyToSave = body
        try await db.write { try bodyToSave.save($0) }

        // Verify retrieval
        let stored = try await db.read { try MessageBody.fetchOne($0, key: dbHeader.id) }
        #expect(stored != nil)
        #expect(stored?.htmlContent == "<div><p>Rich email content</p><img src='cid:image1'/></div>")

        // Verify attachments round-trip
        let attachments = stored?.attachments ?? []
        #expect(attachments.count == 2)
        #expect(attachments[0].filename == "doc.pdf")
        #expect(attachments[0].contentType == "application/pdf")
        #expect(attachments[0].size == 102400)
        #expect(attachments[0].encoding == "base64")
        #expect(attachments[1].filename == "photo.jpg")
        #expect(attachments[1].encoding == nil)
    }

    @Test("fetchMessage with textBody only converts to HTML via plainTextToHTML")
    func fetchMessageTextOnly() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let dbHeader = try TestDatabase.insertMessageHeader(db, messageId: "301")

        let mock = MockEmailProvider()
        let headerInfo = makeHeaderInfo(messageId: "301")
        let fullMsg = FullMessageInfo(header: headerInfo, htmlBody: nil, textBody: "Hello world\nSecond line")
        await mock.setFetchMessageResult(fullMsg)

        let result = try await mock.fetchMessage(id: "301", folder: "INBOX")
        let (body, _, _) = await BodyFetchProcessor.renderBody(headerId: dbHeader.id, fullMessage: result)
        try await db.write { try body.save($0) }

        let stored = try await db.read { try MessageBody.fetchOne($0, key: dbHeader.id) }
        #expect(stored?.htmlContent != nil)
        #expect(stored?.htmlContent?.contains("Hello world") == true)
        #expect(stored?.htmlContent?.contains("<div") == true)
    }

    @Test("fetchMessage with no body stores nil htmlContent")
    func fetchMessageNoBody() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let dbHeader = try TestDatabase.insertMessageHeader(db, messageId: "302")

        let mock = MockEmailProvider()
        let headerInfo = makeHeaderInfo(messageId: "302")
        let fullMsg = FullMessageInfo(header: headerInfo, htmlBody: nil, textBody: nil)
        await mock.setFetchMessageResult(fullMsg)

        let result = try await mock.fetchMessage(id: "302", folder: "INBOX")
        let (body, _, _) = await BodyFetchProcessor.renderBody(headerId: dbHeader.id, fullMessage: result)
        try await db.write { try body.save($0) }

        let stored = try await db.read { try MessageBody.fetchOne($0, key: dbHeader.id) }
        #expect(stored != nil)
        #expect(stored?.htmlContent == nil)
    }
}

// MARK: - Suite: Error Scenarios

@Suite("MockProvider Integration - Error Propagation")
struct ProviderErrorTests {

    @Test("fetchFolders throws notConnected")
    func fetchFoldersNotConnected() async throws {
        let mock = MockEmailProvider()
        await mock.setFetchFoldersThrows(ProviderError.notConnected)

        await #expect(throws: ProviderError.self) {
            _ = try await mock.fetchFolders()
        }
    }

    @Test("fetchMessages throws authenticationFailed")
    func fetchMessagesAuthFailed() async throws {
        let mock = MockEmailProvider()
        await mock.setFetchMessagesThrows(ProviderError.authenticationFailed)

        await #expect(throws: ProviderError.self) {
            _ = try await mock.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        }
    }

    @Test("fetchMessage throws networkError")
    func fetchMessageNetworkError() async throws {
        let mock = MockEmailProvider()
        let underlyingError = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        await mock.setFetchMessageThrows(ProviderError.networkError(underlying: underlyingError))

        await #expect(throws: ProviderError.self) {
            _ = try await mock.fetchMessage(id: "1", folder: "INBOX")
        }
    }

    @Test("connect throws notConnected, call log still records the attempt")
    func connectThrowsRecordsCallLog() async throws {
        let mock = MockEmailProvider()
        await mock.setConnectThrows(ProviderError.notConnected)

        do {
            try await mock.connect()
        } catch {
            // Expected
        }

        let log = await mock.callLog
        #expect(log == ["connect"])
    }

    @Test("search throws authenticationFailed")
    func searchThrowsAuth() async throws {
        let mock = MockEmailProvider()
        await mock.setSearchThrows(ProviderError.authenticationFailed)

        await #expect(throws: ProviderError.self) {
            _ = try await mock.search(query: "test", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        }
    }
}

// MARK: - Suite: Search

@Suite("MockProvider Integration - Search")
struct ProviderSearchTests {

    @Test("search returns filtered results matching query")
    func searchReturnsFilteredResults() async throws {
        let mock = MockEmailProvider()
        let results = [
            makeHeaderInfo(messageId: "s1", subject: "Invoice #1234", from: "billing@company.com", fromAddress: "billing@company.com"),
            makeHeaderInfo(messageId: "s2", subject: "Invoice #5678", from: "billing@company.com", fromAddress: "billing@company.com"),
        ]
        await mock.setSearchResult(results)

        let fetched = try await mock.search(query: "invoice", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        #expect(fetched.count == 2)
        #expect(fetched[0].subject == "Invoice #1234")
        #expect(fetched[1].messageId == "s2")

        let log = await mock.callLog
        #expect(log.contains("search(query:invoice)"))
    }

    @Test("search with date range records call log")
    func searchWithDateRange() async throws {
        let mock = MockEmailProvider()
        await mock.setSearchResult([])

        let after = Date(timeIntervalSince1970: 1_700_000_000)
        let before = Date(timeIntervalSince1970: 1_700_100_000)
        _ = try await mock.search(query: "meeting", folder: "INBOX", after: after, before: before, from: nil, to: nil)

        let log = await mock.callLog
        #expect(log.contains("search(query:meeting)"))
    }

    @Test("search results can be converted to MessageHeaders and inserted into DB")
    func searchResultsInsertedToDB() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let mock = MockEmailProvider()
        let results = [
            makeHeaderInfo(messageId: "s10", subject: "Found result", snippet: "matching content"),
        ]
        await mock.setSearchResult(results)

        let fetched = try await mock.search(query: "found", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        try await db.write { dbConn in
            for info in fetched {
                let header = toMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        let stored = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:s10") }
        #expect(stored?.subject == "Found result")
        #expect(stored?.snippet == "matching content")
    }
}

// MARK: - Suite: Send & AppendToSent

@Suite("MockProvider Integration - Send & AppendToSent")
struct ProviderSendTests {

    @Test("send records DraftMessage in sentDrafts with all fields")
    func sendRecordsDraft() async throws {
        let mock = MockEmailProvider()

        let draft = DraftMessage(
            to: ["recipient@example.com", "other@example.com"],
            cc: ["cc@example.com"],
            bcc: ["bcc@example.com"],
            subject: "Important Update",
            body: "<p>Please review the attached document.</p>",
            isHTML: true,
            inReplyTo: "<original@example.com>",
            references: ["<original@example.com>", "<older@example.com>"],
            attachments: [
                DraftAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data([0x25, 0x50, 0x44, 0x46])),
            ]
        )

        try await mock.send(draft: draft)

        let sent = await mock.sentDrafts
        #expect(sent.count == 1)
        #expect(sent[0].to == ["recipient@example.com", "other@example.com"])
        #expect(sent[0].cc == ["cc@example.com"])
        #expect(sent[0].bcc == ["bcc@example.com"])
        #expect(sent[0].subject == "Important Update")
        #expect(sent[0].body == "<p>Please review the attached document.</p>")
        #expect(sent[0].isHTML == true)
        #expect(sent[0].inReplyTo == "<original@example.com>")
        #expect(sent[0].references == ["<original@example.com>", "<older@example.com>"])
        #expect(sent[0].attachments.count == 1)
        #expect(sent[0].attachments[0].filename == "report.pdf")

        let log = await mock.callLog
        #expect(log == ["send"])
    }

    @Test("send throws error, draft not lost")
    func sendThrowsError() async throws {
        let mock = MockEmailProvider()
        await mock.setSendThrows(ProviderError.networkError(underlying: NSError(domain: "", code: -1)))

        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Hi")

        await #expect(throws: ProviderError.self) {
            try await mock.send(draft: draft)
        }

        // Draft is still recorded even though error was thrown (recorded before throw check)
        let sent = await mock.sentDrafts
        #expect(sent.count == 1)
    }

    @Test("appendToSentFolder records args and returns true")
    func appendToSentRecordsArgs() async throws {
        let mock = MockEmailProvider()

        let draft = DraftMessage(to: ["user@test.com"], subject: "Sent copy", body: "Body text")
        let result = try await mock.appendToSentFolder(draft: draft, sentFolderPath: "Sent", messageId: "<msg-abc@example.com>")

        #expect(result == true)

        let appended = await mock.appendedToSent
        #expect(appended.count == 1)
        #expect(appended[0].sentFolderPath == "Sent")
        #expect(appended[0].messageId == "<msg-abc@example.com>")
        #expect(appended[0].draft.subject == "Sent copy")

        let log = await mock.callLog
        #expect(log.contains("appendToSentFolder(sentFolderPath:Sent,messageId:<msg-abc@example.com>)"))
    }

    @Test("appendToSentFolder can return false when configured")
    func appendToSentReturnsFalse() async throws {
        let mock = MockEmailProvider()
        await mock.setAppendToSentResult(false)

        let draft = DraftMessage(to: ["x@y.com"], subject: "Test")
        let result = try await mock.appendToSentFolder(draft: draft, sentFolderPath: "Sent", messageId: "<id>")

        #expect(result == false)
    }
}

// MARK: - Suite: Call Log - Sync Flow Sequence

@Suite("MockProvider Integration - Call Log Sync Flow")
struct CallLogSyncFlowTests {

    @Test("typical sync flow: connect → fetchFolders → fetchMessages records correct sequence")
    func typicalSyncFlowSequence() async throws {
        let mock = MockEmailProvider()
        let folderInfos = [
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 3, totalCount: 50),
        ]
        await mock.setFetchFoldersResult(folderInfos)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "1"),
            makeHeaderInfo(messageId: "2"),
        ])

        // Simulate sync flow
        try await mock.connect()
        let folders = try await mock.fetchFolders()
        #expect(folders.count == 1)

        let messages = try await mock.fetchMessages(folder: folders[0].path, limit: 50, offset: 0)
        #expect(messages.count == 2)

        let log = await mock.callLog
        #expect(log.count == 3)
        #expect(log[0] == "connect")
        #expect(log[1] == "fetchFolders")
        #expect(log[2] == "fetchMessages(folder:INBOX,limit:50,offset:0)")
    }

    @Test("full sync flow with body fetch: connect → fetchFolders → fetchMessages → fetchMessage")
    func fullSyncFlowWithBodyFetch() async throws {
        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 1, totalCount: 1),
        ])
        let headerInfo = makeHeaderInfo(messageId: "42", subject: "Important")
        await mock.setFetchMessagesResult([headerInfo])
        await mock.setFetchMessageResult(FullMessageInfo(header: headerInfo, htmlBody: "<p>Body</p>", textBody: "Body"))

        try await mock.connect()
        _ = try await mock.fetchFolders()
        _ = try await mock.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        _ = try await mock.fetchMessage(id: "42", folder: "INBOX")

        let log = await mock.callLog
        #expect(log.count == 4)
        #expect(log[0] == "connect")
        #expect(log[1] == "fetchFolders")
        #expect(log[2].hasPrefix("fetchMessages"))
        #expect(log[3] == "fetchMessage(id:42,folder:INBOX)")
    }

    @Test("reset clears all recorded state")
    func resetClearsState() async throws {
        let mock = MockEmailProvider()
        try await mock.connect()
        _ = try await mock.fetchFolders()
        await mock.reset()

        let log = await mock.callLog
        #expect(log.isEmpty)
    }
}

// MARK: - Suite: Parameter Tracking (markRead, markUnread, markFlagged, move)

@Suite("MockProvider Integration - Parameter Tracking")
struct ParameterTrackingTests {

    @Test("markRead tracks ids and folder")
    func markReadTracking() async throws {
        let mock = MockEmailProvider()

        try await mock.markRead(ids: ["msg-1", "msg-2", "msg-3"], folder: "INBOX")
        try await mock.markRead(ids: ["msg-10"], folder: "Sent")

        let reads = await mock.markedReadIds
        #expect(reads.count == 2)
        #expect(reads[0].ids == ["msg-1", "msg-2", "msg-3"])
        #expect(reads[0].folder == "INBOX")
        #expect(reads[1].ids == ["msg-10"])
        #expect(reads[1].folder == "Sent")
    }

    @Test("markUnread tracks ids and folder")
    func markUnreadTracking() async throws {
        let mock = MockEmailProvider()

        try await mock.markUnread(ids: ["msg-5"], folder: "INBOX")

        let unreads = await mock.markedUnreadIds
        #expect(unreads.count == 1)
        #expect(unreads[0].ids == ["msg-5"])
        #expect(unreads[0].folder == "INBOX")
    }

    @Test("markFlagged tracks ids, flagged state, and folder")
    func markFlaggedTracking() async throws {
        let mock = MockEmailProvider()

        try await mock.markFlagged(ids: ["msg-1"], flagged: true, folder: "INBOX")
        try await mock.markFlagged(ids: ["msg-2", "msg-3"], flagged: false, folder: "Archive")

        let flagged = await mock.markedFlaggedIds
        #expect(flagged.count == 2)
        #expect(flagged[0].ids == ["msg-1"])
        #expect(flagged[0].flagged == true)
        #expect(flagged[0].folder == "INBOX")
        #expect(flagged[1].ids == ["msg-2", "msg-3"])
        #expect(flagged[1].flagged == false)
        #expect(flagged[1].folder == "Archive")
    }

    @Test("move tracks ids, source, and destination")
    func moveTracking() async throws {
        let mock = MockEmailProvider()

        try await mock.move(ids: ["msg-1", "msg-2"], from: "INBOX", to: "Trash")
        try await mock.move(ids: ["msg-3"], from: "Trash", to: "INBOX")

        let moves = await mock.movedIds
        #expect(moves.count == 2)
        #expect(moves[0].ids == ["msg-1", "msg-2"])
        #expect(moves[0].from == "INBOX")
        #expect(moves[0].to == "Trash")
        #expect(moves[1].ids == ["msg-3"])
        #expect(moves[1].from == "Trash")
        #expect(moves[1].to == "INBOX")
    }

    @Test("markRead throws error but still records parameters")
    func markReadThrowsButRecords() async throws {
        let mock = MockEmailProvider()
        await mock.setMarkReadThrows(ProviderError.notConnected)

        do {
            try await mock.markRead(ids: ["msg-1"], folder: "INBOX")
        } catch {
            // Expected
        }

        // Parameters recorded before throw
        let reads = await mock.markedReadIds
        #expect(reads.count == 1)
        #expect(reads[0].ids == ["msg-1"])
    }

    @Test("move throws error via setMoveThrows helper")
    func moveThrowsViaHelper() async throws {
        let mock = MockEmailProvider()
        await mock.setMoveThrows(ProviderError.notConnected)

        await #expect(throws: ProviderError.self) {
            try await mock.move(ids: ["msg-1"], from: "INBOX", to: "Trash")
        }
    }
}

// MARK: - Suite: Reconnection Pattern

@Suite("MockProvider Integration - Reconnection")
struct ReconnectionTests {

    @Test("disconnect → connect records correct call log sequence")
    func disconnectThenConnect() async throws {
        let mock = MockEmailProvider()

        try await mock.connect()
        try await mock.disconnect()
        try await mock.connect()

        let log = await mock.callLog
        #expect(log == ["connect", "disconnect", "connect"])
    }

    @Test("disconnect throws but connect succeeds after")
    func disconnectThrowsConnectSucceeds() async throws {
        let mock = MockEmailProvider()
        await mock.setDisconnectThrows(ProviderError.notConnected)

        try await mock.connect()

        do {
            try await mock.disconnect()
        } catch {
            // Expected
        }

        // Clear the disconnect error and reconnect
        await mock.setDisconnectThrows(nil)
        try await mock.connect()

        let log = await mock.callLog
        #expect(log == ["connect", "disconnect", "connect"])
    }

    @Test("full reconnection flow: connect → fetchFolders → disconnect → connect → fetchFolders")
    func fullReconnectionFlow() async throws {
        let mock = MockEmailProvider()
        await mock.setFetchFoldersResult([
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 0),
        ])

        try await mock.connect()
        let folders1 = try await mock.fetchFolders()
        #expect(folders1.count == 1)

        try await mock.disconnect()

        try await mock.connect()
        let folders2 = try await mock.fetchFolders()
        #expect(folders2.count == 1)

        let log = await mock.callLog
        #expect(log == ["connect", "fetchFolders", "disconnect", "connect", "fetchFolders"])
    }
}

// MARK: - Suite: fetchHistory & fetchMessageHeaders

@Suite("MockProvider Integration - History & Header Fetch")
struct HistoryAndHeaderFetchTests {

    @Test("fetchHistory returns configured HistoryResponse")
    func fetchHistoryReturnsResult() async throws {
        let mock = MockEmailProvider()
        let response = HistoryResponse(
            newHistoryId: "h500",
            messagesAdded: [HistoryMessageRef(messageId: "new-1", labelIds: ["INBOX"])],
            messagesDeleted: [HistoryMessageRef(messageId: "del-1", labelIds: ["INBOX"])],
            labelsAdded: [HistoryLabelChange(messageId: "chg-1", labelIds: ["STARRED"])],
            labelsRemoved: []
        )
        await mock.setFetchHistoryResult(response)

        let result = try await mock.fetchHistory(since: "h400")
        #expect(result != nil)
        #expect(result?.newHistoryId == "h500")
        #expect(result?.messagesAdded.count == 1)
        #expect(result?.messagesDeleted.count == 1)
        #expect(result?.labelsAdded.count == 1)

        let log = await mock.callLog
        #expect(log.contains("fetchHistory(since:h400)"))
    }

    @Test("fetchHistory returns nil for IMAP providers")
    func fetchHistoryReturnsNil() async throws {
        let mock = MockEmailProvider()
        // fetchHistoryResult is nil by default

        let result = try await mock.fetchHistory(since: "any")
        #expect(result == nil)
    }

    @Test("fetchMessageHeaders returns configured headers by ID")
    func fetchMessageHeaders() async throws {
        let mock = MockEmailProvider()
        let headers = [
            makeHeaderInfo(messageId: "h1", subject: "Header One"),
            makeHeaderInfo(messageId: "h2", subject: "Header Two"),
        ]
        await mock.setFetchMessageHeadersResult(headers)

        let result = try await mock.fetchMessageHeaders(ids: ["h1", "h2"])
        #expect(result.count == 2)
        #expect(result[0].subject == "Header One")
        #expect(result[1].subject == "Header Two")
    }
}

// MARK: - Suite: End-to-End Sync Simulation

@Suite("MockProvider Integration - E2E Sync Simulation")
struct E2ESyncSimulationTests {

    @Test("complete sync: connect → folders → messages → body → DB has all data")
    func completeSyncFlow() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let mock = MockEmailProvider()

        // Configure folders
        let folderInfos = [
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 2, totalCount: 5),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 10),
        ]
        await mock.setFetchFoldersResult(folderInfos)

        // Configure messages
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let msgInfos = [
            makeHeaderInfo(messageId: "m1", subject: "Welcome", from: "Admin", fromAddress: "admin@co.com", date: date, snippet: "Welcome aboard"),
            makeHeaderInfo(messageId: "m2", subject: "Task", from: "Manager", fromAddress: "mgr@co.com", date: date.addingTimeInterval(60), snippet: "Please review"),
        ]
        await mock.setFetchMessagesResult(msgInfos)

        // Configure full message for body fetch
        let fullInfo = FullMessageInfo(
            header: msgInfos[0],
            htmlBody: "<h1>Welcome!</h1><p>We are glad to have you.</p>",
            textBody: "Welcome! We are glad to have you."
        )
        await mock.setFetchMessageResult(fullInfo)

        // Step 1: Connect
        try await mock.connect()

        // Step 2: Fetch and insert folders
        let folders = try await mock.fetchFolders()
        try await db.write { dbConn in
            for info in folders {
                var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: "acc1")
                folder.unreadCount = info.unreadCount
                folder.totalCount = info.totalCount
                try folder.insert(dbConn)
            }
        }

        // Step 3: Fetch and insert messages
        let messages = try await mock.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        try await db.write { dbConn in
            for info in messages {
                let header = toMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        // Step 4: Fetch body for first message
        let fullMsg = try await mock.fetchMessage(id: "m1", folder: "INBOX")
        let (body, _, _) = await BodyFetchProcessor.renderBody(headerId: "acc1:INBOX:m1", fullMessage: fullMsg)
        try await db.write { try body.save($0) }

        // Verify complete state
        let dbFolders = try await db.read { try Folder.fetchAll($0) }
        #expect(dbFolders.count == 2)

        let dbMessages = try await db.read { try MessageHeader.fetchAll($0) }
        #expect(dbMessages.count == 2)

        let dbBody = try await db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:m1") }
        #expect(dbBody?.htmlContent?.contains("Welcome!") == true)

        // No body for second message yet
        let dbBody2 = try await db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:m2") }
        #expect(dbBody2 == nil)

        // Verify call log sequence
        let log = await mock.callLog
        #expect(log.count == 4)
        #expect(log[0] == "connect")
        #expect(log[1] == "fetchFolders")
        #expect(log[2].hasPrefix("fetchMessages"))
        #expect(log[3].hasPrefix("fetchMessage"))
    }

    @Test("ActionTag.none does not collide with Swift Optional.none")
    func actionTagNoneVsOptionalNone() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert with explicit ActionTag.none
        let header = try TestDatabase.insertMessageHeader(db, messageId: "at1", actionTag: ActionTag.none)
        #expect(header.actionTag == ActionTag.none)
        #expect(header.tagSortOrder == ActionTag.none.sortOrder)

        // Insert with nil actionTag (no tag assigned)
        let header2 = try TestDatabase.insertMessageHeader(db, messageId: "at2", actionTag: nil)
        #expect(header2.actionTag == nil)

        // Verify they are different in DB
        let stored1 = try await db.read { try MessageHeader.fetchOne($0, key: header.id) }
        let stored2 = try await db.read { try MessageHeader.fetchOne($0, key: header2.id) }
        #expect(stored1?.actionTag == ActionTag.none)
        #expect(stored2?.actionTag == nil)
        // ActionTag.none has sortOrder 1, nil defaults to 99
        #expect(stored1?.tagSortOrder == 1)
        #expect(stored2?.tagSortOrder == 99)
    }
}

// MARK: - MockEmailProvider setter extensions for test configuration
// Note: setFetchMessageResult is in AccountManagerFetchTests.swift
// Note: setSendThrows / setAppendToSentThrows are in OutboxDrainIntegrationTests.swift

extension MockEmailProvider {
    func setFetchFoldersResult(_ result: [FolderInfo]) { fetchFoldersResult = result }
    func setFetchFoldersThrows(_ error: Error?) { fetchFoldersThrows = error }
    func setFetchMessagesResult(_ result: [MessageHeaderInfo]) { fetchMessagesResult = result }
    func setFetchMessagesThrows(_ error: Error?) { fetchMessagesThrows = error }
    func setFetchMessageThrows(_ error: Error?) { fetchMessageThrows = error }
    func setSearchResult(_ result: [MessageHeaderInfo]) { searchResult = result }
    func setSearchThrows(_ error: Error?) { searchThrows = error }
    func setConnectThrows(_ error: Error?) { connectThrows = error }
    func setDisconnectThrows(_ error: Error?) { disconnectThrows = error }
    func setMarkReadThrows(_ error: Error?) { markReadThrows = error }
    func setAppendToSentResult(_ result: Bool) { appendToSentResult = result }
    func setFetchHistoryResult(_ result: HistoryResponse?) { fetchHistoryResult = result }
    func setFetchMessageHeadersResult(_ result: [MessageHeaderInfo]) { fetchMessageHeadersResult = result }
}
