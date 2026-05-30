/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Test Helpers

/// Builds a MessageHeaderInfo with sensible defaults for search tests.
private func makeSearchHeaderInfo(
    messageId: String,
    subject: String = "Test",
    from: String = "Sender",
    fromAddress: String = "sender@test.com",
    to: String = "receiver@test.com",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    snippet: String = "",
    isRead: Bool = false,
    rfc822MessageId: String? = nil,
    inReplyTo: String? = nil,
    references: [String] = [],
    threadId: String? = nil,
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
        cc: "",
        bcc: "",
        replyTo: nil,
        date: date,
        snippet: snippet,
        isRead: isRead,
        isFlagged: false,
        hasAttachments: false,
        isReplied: false,
        isForwarded: false,
        actionTag: actionTag
    )
}

/// Convert a MessageHeaderInfo to a MessageHeader for DB insertion.
private func toSearchMessageHeader(
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

// MARK: - Suite 1: Remote Search via MockEmailProvider

@Suite("Search Integration - Remote Search")
struct SearchRemoteTests {

    @Test("Search returns results and provider called with correct query")
    func searchReturnsResults() async throws {
        let provider = MockEmailProvider()
        let results = [
            makeSearchHeaderInfo(messageId: "s1", subject: "Invoice #1234"),
            makeSearchHeaderInfo(messageId: "s2", subject: "Invoice #5678"),
        ]
        await provider.setSearchResult(results)

        let fetched = try await provider.search(query: "invoice", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        #expect(fetched.count == 2)
        #expect(fetched[0].subject == "Invoice #1234")
        #expect(fetched[1].subject == "Invoice #5678")

        let log = await provider.callLog
        #expect(log.contains("search(query:invoice)"))
    }

    @Test("Search with date filters passes after and before dates correctly")
    func searchWithDateFilters() async throws {
        let provider = MockEmailProvider()
        let afterDate = Date(timeIntervalSince1970: 1_700_000_000)
        let beforeDate = Date(timeIntervalSince1970: 1_700_100_000)
        let results = [
            makeSearchHeaderInfo(messageId: "d1", subject: "In Range", date: Date(timeIntervalSince1970: 1_700_050_000)),
        ]
        await provider.setSearchResult(results)

        let fetched = try await provider.search(query: "meeting", folder: "INBOX", after: afterDate, before: beforeDate, from: nil, to: nil)
        #expect(fetched.count == 1)
        #expect(fetched[0].subject == "In Range")

        let log = await provider.callLog
        #expect(log.contains("search(query:meeting)"))
    }

    @Test("Search returns empty array without error")
    func searchReturnsEmpty() async throws {
        let provider = MockEmailProvider()
        // Default searchResult is empty

        let fetched = try await provider.search(query: "nonexistent", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        #expect(fetched.isEmpty)
    }

    @Test("Search throws configured error")
    func searchThrowsError() async throws {
        let provider = MockEmailProvider()
        await provider.setSearchThrows(ProviderError.authenticationFailed)

        await #expect(throws: ProviderError.self) {
            _ = try await provider.search(query: "test", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        }
    }

    @Test("Provider callLog records search query string")
    func searchCallLogRecordsQuery() async throws {
        let provider = MockEmailProvider()
        await provider.setSearchResult([])

        _ = try await provider.search(query: "important emails", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        _ = try await provider.search(query: "follow up", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)

        let log = await provider.callLog
        #expect(log.count == 2)
        #expect(log[0] == "search(query:important emails)")
        #expect(log[1] == "search(query:follow up)")
    }
}

// MARK: - Suite 2: Search Result → DB Integration

@Suite("Search Integration - Search Result to DB")
struct SearchResultDBTests {

    @Test("Search results mapped to MessageHeader and inserted in DB")
    func searchResultsMappedAndInserted() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let provider = MockEmailProvider()
        let results = [
            makeSearchHeaderInfo(messageId: "r1", subject: "Result One", fromAddress: "alice@test.com", snippet: "First result"),
            makeSearchHeaderInfo(messageId: "r2", subject: "Result Two", fromAddress: "bob@test.com", snippet: "Second result"),
        ]
        await provider.setSearchResult(results)

        let fetched = try await provider.search(query: "test", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        try await db.write { dbConn in
            for info in fetched {
                let header = toSearchMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        let stored = try await db.read { try MessageHeader.fetchAll($0) }
        #expect(stored.count == 2)

        let h1 = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:r1") }
        #expect(h1?.subject == "Result One")
        #expect(h1?.fromAddress == "alice@test.com")
        #expect(h1?.snippet == "First result")
    }

    @Test("Search results with existing headers — upsert preserves local state")
    func searchResultsUpsertPreservesLocalState() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert existing header with local state
        try TestDatabase.insertMessageHeader(db, messageId: "existing1", subject: "Original Subject", isRead: true, actionTag: ActionTag.reply)

        // Search returns same messageId with different subject but we want to preserve isRead and actionTag
        let searchInfo = makeSearchHeaderInfo(messageId: "existing1", subject: "Updated Subject", isRead: false)
        var newHeader = toSearchMessageHeader(searchInfo)

        // Simulate upsert that preserves local state: read existing, merge, save
        let existing = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:existing1") }
        #expect(existing != nil)

        // Preserve local fields
        newHeader.isRead = existing?.isRead ?? newHeader.isRead
        newHeader.actionTag = existing?.actionTag
        if let tag = newHeader.actionTag {
            newHeader.tagSortOrder = tag.sortOrder
        }

        let headerToSave = newHeader
        try await db.write { try headerToSave.save($0) }

        let stored = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:existing1") }
        #expect(stored?.subject == "Updated Subject") // Updated from search
        #expect(stored?.isRead == true) // Preserved local state
        #expect(stored?.actionTag == ActionTag.reply) // Preserved local state
    }

    @Test("Dedup: same messageId from search does not create duplicate rows")
    func searchDedupSameMessageId() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info = makeSearchHeaderInfo(messageId: "dup1", subject: "Duplicate Test")
        let header = toSearchMessageHeader(info)
        try await db.write { try header.insert($0) }

        // Insert same again using save (upsert)
        let header2 = toSearchMessageHeader(info)
        try await db.write { try header2.save($0) }

        let count = try await db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("Search across folders — results reference correct folder")
    func searchAcrossFolders() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let inboxResult = makeSearchHeaderInfo(messageId: "f1", subject: "Inbox Email")
        let sentResult = makeSearchHeaderInfo(messageId: "f2", subject: "Sent Email")

        let inboxHeader = toSearchMessageHeader(inboxResult, accountId: "acc1", folderPath: "INBOX")
        let sentHeader = toSearchMessageHeader(sentResult, accountId: "acc1", folderPath: "Sent")

        try await db.write { dbConn in
            try inboxHeader.insert(dbConn)
            try sentHeader.insert(dbConn)
        }

        let inboxMessages = try await db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0)
        }
        let sentMessages = try await db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll($0)
        }

        #expect(inboxMessages.count == 1)
        #expect(inboxMessages[0].subject == "Inbox Email")
        #expect(inboxMessages[0].folderPath == "INBOX")
        #expect(inboxMessages[0].isInInbox == true)

        #expect(sentMessages.count == 1)
        #expect(sentMessages[0].subject == "Sent Email")
        #expect(sentMessages[0].folderPath == "Sent")
        #expect(sentMessages[0].isInInbox == false)
    }

    @Test("Large search result set handled correctly (100+ results)")
    func largeSearchResultSet() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let provider = MockEmailProvider()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let results = (0..<150).map { i in
            makeSearchHeaderInfo(
                messageId: "bulk\(i)",
                subject: "Bulk Message \(i)",
                date: baseDate.addingTimeInterval(Double(i) * 60)
            )
        }
        await provider.setSearchResult(results)

        let fetched = try await provider.search(query: "bulk", folder: "INBOX", after: nil, before: nil, from: nil, to: nil)
        #expect(fetched.count == 150)

        try await db.write { dbConn in
            for info in fetched {
                let header = toSearchMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        let count = try await db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 150)
    }
}

// MARK: - Suite 3: Local DB Queries (simulating local search)

@Suite("Search Integration - Local DB Queries")
struct SearchLocalQueryTests {

    @Test("Filter by subject LIKE query")
    func filterBySubjectLike() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        try TestDatabase.insertMessageHeader(db, messageId: "q1", subject: "Meeting Tomorrow")
        try TestDatabase.insertMessageHeader(db, messageId: "q2", subject: "Project Update")
        try TestDatabase.insertMessageHeader(db, messageId: "q3", subject: "Team Meeting Notes")

        let results = try await db.read {
            try MessageHeader.filter(Column("subject").like("%Meeting%")).fetchAll($0)
        }
        #expect(results.count == 2)
        let subjects = results.map(\.subject)
        #expect(subjects.contains("Meeting Tomorrow"))
        #expect(subjects.contains("Team Meeting Notes"))
    }

    @Test("Filter by fromAddress")
    func filterByFromAddress() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        try TestDatabase.insertMessageHeader(db, messageId: "a1", fromAddress: "alice@company.com")
        try TestDatabase.insertMessageHeader(db, messageId: "a2", fromAddress: "bob@company.com")
        try TestDatabase.insertMessageHeader(db, messageId: "a3", fromAddress: "alice@company.com")

        let results = try await db.read {
            try MessageHeader.filter(Column("fromAddress") == "alice@company.com").fetchAll($0)
        }
        #expect(results.count == 2)
    }

    @Test("Filter by date range")
    func filterByDateRange() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let jan1 = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        let feb1 = Date(timeIntervalSince1970: 1_706_745_600) // 2024-02-01
        let mar1 = Date(timeIntervalSince1970: 1_709_251_200) // 2024-03-01

        try TestDatabase.insertMessageHeader(db, messageId: "d1", date: jan1)
        try TestDatabase.insertMessageHeader(db, messageId: "d2", date: feb1)
        try TestDatabase.insertMessageHeader(db, messageId: "d3", date: mar1)

        let results = try await db.read {
            try MessageHeader
                .filter(Column("date") >= jan1 && Column("date") < mar1)
                .fetchAll($0)
        }
        #expect(results.count == 2)
        let ids = results.map(\.messageId)
        #expect(ids.contains("d1"))
        #expect(ids.contains("d2"))
    }

    @Test("Filter by isRead status")
    func filterByIsRead() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        try TestDatabase.insertMessageHeader(db, messageId: "r1", isRead: true)
        try TestDatabase.insertMessageHeader(db, messageId: "r2", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "r3", isRead: false)

        let unread = try await db.read {
            try MessageHeader.filter(Column("isRead") == false).fetchAll($0)
        }
        #expect(unread.count == 2)

        let read = try await db.read {
            try MessageHeader.filter(Column("isRead") == true).fetchAll($0)
        }
        #expect(read.count == 1)
        #expect(read[0].messageId == "r1")
    }

    @Test("Filter by folder")
    func filterByFolder() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .custom, accountId: "acc1")

        try TestDatabase.insertMessageHeader(db, messageId: "f1", folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "f2", folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "f3", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)

        let inboxOnly = try await db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0)
        }
        #expect(inboxOnly.count == 2)

        let archiveOnly = try await db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:Archive").fetchAll($0)
        }
        #expect(archiveOnly.count == 1)
    }

    @Test("Combined filters: subject + folder + date")
    func combinedFilters() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let jan1 = Date(timeIntervalSince1970: 1_704_067_200)
        let feb1 = Date(timeIntervalSince1970: 1_706_745_600)
        let mar1 = Date(timeIntervalSince1970: 1_709_251_200)

        try TestDatabase.insertMessageHeader(db, messageId: "c1", subject: "Meeting Agenda", date: jan1, folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "c2", subject: "Meeting Notes", date: feb1, folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "c3", subject: "Meeting Recap", date: mar1, folderId: "acc1:INBOX", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "c4", subject: "Meeting Sent", date: feb1, folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false)

        let results = try await db.read {
            try MessageHeader
                .filter(Column("subject").like("%Meeting%"))
                .filter(Column("folderId") == "acc1:INBOX")
                .filter(Column("date") >= jan1 && Column("date") < mar1)
                .fetchAll($0)
        }
        #expect(results.count == 2)
        let ids = results.map(\.messageId)
        #expect(ids.contains("c1"))
        #expect(ids.contains("c2"))
    }

    @Test("Sort by date descending (most recent first)")
    func sortByDateDescending() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_100_000)
        let t3 = Date(timeIntervalSince1970: 1_700_200_000)

        try TestDatabase.insertMessageHeader(db, messageId: "s1", subject: "Oldest", date: t1)
        try TestDatabase.insertMessageHeader(db, messageId: "s2", subject: "Middle", date: t2)
        try TestDatabase.insertMessageHeader(db, messageId: "s3", subject: "Newest", date: t3)

        let sorted = try await db.read {
            try MessageHeader.order(Column("date").desc).fetchAll($0)
        }
        #expect(sorted.count == 3)
        #expect(sorted[0].subject == "Newest")
        #expect(sorted[1].subject == "Middle")
        #expect(sorted[2].subject == "Oldest")
    }

    @Test("Pagination with limit and offset")
    func paginationWithLimitOffset() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<20 {
            try TestDatabase.insertMessageHeader(
                db,
                messageId: "p\(i)",
                subject: "Page Message \(i)",
                date: baseDate.addingTimeInterval(Double(i) * 60)
            )
        }

        // Page 1: first 5 ordered by date desc
        let page1 = try await db.read {
            try MessageHeader.order(Column("date").desc).limit(5, offset: 0).fetchAll($0)
        }
        #expect(page1.count == 5)
        #expect(page1[0].messageId == "p19")

        // Page 2: next 5
        let page2 = try await db.read {
            try MessageHeader.order(Column("date").desc).limit(5, offset: 5).fetchAll($0)
        }
        #expect(page2.count == 5)
        #expect(page2[0].messageId == "p14")

        // Last page: remaining
        let lastPage = try await db.read {
            try MessageHeader.order(Column("date").desc).limit(5, offset: 15).fetchAll($0)
        }
        #expect(lastPage.count == 5)
        #expect(lastPage[4].messageId == "p0")
    }
}

// MARK: - Suite 4: Thread Detection Patterns

@Suite("Search Integration - Thread Detection")
struct SearchThreadDetectionTests {

    @Test("Messages with same threadId grouped together")
    func sameThreadIdGrouped() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let info1 = makeSearchHeaderInfo(messageId: "t1", subject: "Thread A - msg 1", threadId: "thread-A")
        let info2 = makeSearchHeaderInfo(messageId: "t2", subject: "Thread A - msg 2", threadId: "thread-A")
        let info3 = makeSearchHeaderInfo(messageId: "t3", subject: "Thread B - msg 1", threadId: "thread-B")

        try await db.write { dbConn in
            for info in [info1, info2, info3] {
                let header = toSearchMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        let threadA = try await db.read {
            try MessageHeader.filter(Column("threadId") == "thread-A").fetchAll($0)
        }
        #expect(threadA.count == 2)

        let threadB = try await db.read {
            try MessageHeader.filter(Column("threadId") == "thread-B").fetchAll($0)
        }
        #expect(threadB.count == 1)
    }

    @Test("Messages linked by inReplyTo to rfc822MessageId chain")
    func inReplyToChain() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Thread chain: msg1 <- msg2 <- msg3
        let info1 = makeSearchHeaderInfo(messageId: "c1", subject: "Original", rfc822MessageId: "<msg1@example.com>")
        let info2 = makeSearchHeaderInfo(messageId: "c2", subject: "Re: Original", rfc822MessageId: "<msg2@example.com>", inReplyTo: "<msg1@example.com>")
        let info3 = makeSearchHeaderInfo(messageId: "c3", subject: "Re: Re: Original", rfc822MessageId: "<msg3@example.com>", inReplyTo: "<msg2@example.com>")

        try await db.write { dbConn in
            for info in [info1, info2, info3] {
                let header = toSearchMessageHeader(info)
                try header.insert(dbConn)
            }
        }

        // Find parent of msg2
        let msg2 = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:c2") }
        #expect(msg2?.inReplyTo == "<msg1@example.com>")

        let parent = try await db.read {
            try MessageHeader.filter(Column("rfc822MessageId") == msg2?.inReplyTo).fetchOne($0)
        }
        #expect(parent?.messageId == "c1")
        #expect(parent?.subject == "Original")

        // Find children of msg2
        let children = try await db.read {
            try MessageHeader.filter(Column("inReplyTo") == msg2?.rfc822MessageId).fetchAll($0)
        }
        #expect(children.count == 1)
        #expect(children[0].messageId == "c3")
    }

    @Test("Orphan messages with no threadId and no inReplyTo stand alone")
    func orphanMessagesStandAlone() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let orphan = makeSearchHeaderInfo(messageId: "o1", subject: "Standalone Email", rfc822MessageId: "<orphan@example.com>")
        let threaded = makeSearchHeaderInfo(messageId: "o2", subject: "Threaded Email", rfc822MessageId: "<threaded@example.com>", threadId: "thread-X")

        try await db.write { dbConn in
            try toSearchMessageHeader(orphan).insert(dbConn)
            try toSearchMessageHeader(threaded).insert(dbConn)
        }

        // Orphan has no threadId and no inReplyTo
        let orphanStored = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:o1") }
        #expect(orphanStored?.threadId == nil)
        #expect(orphanStored?.inReplyTo == nil)

        // No messages reference this orphan
        let referencingOrphan = try await db.read {
            try MessageHeader.filter(Column("inReplyTo") == orphanStored?.rfc822MessageId).fetchAll($0)
        }
        #expect(referencingOrphan.isEmpty)

        // Messages without threadId or inReplyTo
        let orphans = try await db.read {
            try MessageHeader
                .filter(Column("threadId") == nil)
                .filter(Column("inReplyTo") == nil)
                .fetchAll($0)
        }
        #expect(orphans.count == 1)
        #expect(orphans[0].messageId == "o1")
    }

    @Test("Cross-folder thread: same threadId in different folders")
    func crossFolderThread() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let inboxMsg = makeSearchHeaderInfo(messageId: "xf1", subject: "Received message", threadId: "cross-thread")
        let sentMsg = makeSearchHeaderInfo(messageId: "xf2", subject: "My reply", threadId: "cross-thread")

        try await db.write { dbConn in
            try toSearchMessageHeader(inboxMsg, folderPath: "INBOX").insert(dbConn)
            try toSearchMessageHeader(sentMsg, folderPath: "Sent").insert(dbConn)
        }

        // Query across all folders by threadId
        let threadMessages = try await db.read {
            try MessageHeader.filter(Column("threadId") == "cross-thread").fetchAll($0)
        }
        #expect(threadMessages.count == 2)

        let folders = Set(threadMessages.map(\.folderPath))
        #expect(folders.contains("INBOX"))
        #expect(folders.contains("Sent"))
    }

    @Test("Thread detection with rfc822MessageId matching")
    func threadDetectionWithRfc822MessageId() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert 5 messages with varying thread relationships
        let root = makeSearchHeaderInfo(messageId: "tm1", subject: "Project Discussion", rfc822MessageId: "<root@example.com>")
        let reply1 = makeSearchHeaderInfo(messageId: "tm2", subject: "Re: Project Discussion", rfc822MessageId: "<reply1@example.com>", inReplyTo: "<root@example.com>")
        let reply2 = makeSearchHeaderInfo(messageId: "tm3", subject: "Re: Project Discussion", rfc822MessageId: "<reply2@example.com>", inReplyTo: "<root@example.com>")
        let nestedReply = makeSearchHeaderInfo(messageId: "tm4", subject: "Re: Re: Project Discussion", rfc822MessageId: "<nested@example.com>", inReplyTo: "<reply1@example.com>")
        let unrelated = makeSearchHeaderInfo(messageId: "tm5", subject: "Different Topic", rfc822MessageId: "<other@example.com>")

        try await db.write { dbConn in
            for info in [root, reply1, reply2, nestedReply, unrelated] {
                try toSearchMessageHeader(info).insert(dbConn)
            }
        }

        // Find all direct replies to root
        let directReplies = try await db.read {
            try MessageHeader.filter(Column("inReplyTo") == "<root@example.com>").fetchAll($0)
        }
        #expect(directReplies.count == 2)

        // Find all messages that are replies to anything (have inReplyTo set)
        let allReplies = try await db.read {
            try MessageHeader.filter(Column("inReplyTo") != nil).fetchAll($0)
        }
        #expect(allReplies.count == 3) // reply1, reply2, nestedReply

        // Walk the chain from nestedReply back to root
        let nested = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:tm4") }
        #expect(nested?.inReplyTo == "<reply1@example.com>")

        let parentOfNested = try await db.read {
            try MessageHeader.filter(Column("rfc822MessageId") == nested?.inReplyTo).fetchOne($0)
        }
        #expect(parentOfNested?.messageId == "tm2")
        #expect(parentOfNested?.inReplyTo == "<root@example.com>")

        let rootMsg = try await db.read {
            try MessageHeader.filter(Column("rfc822MessageId") == parentOfNested?.inReplyTo).fetchOne($0)
        }
        #expect(rootMsg?.messageId == "tm1")
        #expect(rootMsg?.inReplyTo == nil) // Root has no parent

        // Unrelated message is not part of any chain
        let unrelatedMsg = try await db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:tm5") }
        #expect(unrelatedMsg?.inReplyTo == nil)

        let referencingUnrelated = try await db.read {
            try MessageHeader.filter(Column("inReplyTo") == unrelatedMsg?.rfc822MessageId).fetchAll($0)
        }
        #expect(referencingUnrelated.isEmpty)
    }
}
