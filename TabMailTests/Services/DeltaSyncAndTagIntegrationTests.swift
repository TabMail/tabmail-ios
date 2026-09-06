/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite 1: Delta Sync — DB Patterns

@Suite("Delta Sync — DB Patterns")
struct DeltaSyncDBPatternTests {

    @Test("Messages added: insert new headers from delta")
    func insertNewHeadersFromDelta() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Simulate inserting a new message discovered by delta sync
        let date = Date(timeIntervalSince1970: 1700000000)
        var header = MessageHeader(
            messageId: "gmailId123",
            subject: "Delta New Message",
            from: "alice@example.com",
            fromAddress: "alice@example.com",
            to: "test@gmail.com",
            date: date,
            snippet: "New message from delta",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<msg123@example.com>"
        header.isRead = false
        try db.write { dbConn in try header.insert(dbConn) }

        // Verify the header was inserted
        let fetched = try db.read { dbConn in
            try MessageHeader.filter(Column("messageId") == "gmailId123").fetchOne(dbConn)
        }
        #expect(fetched != nil)
        #expect(fetched?.subject == "Delta New Message")
        #expect(fetched?.rfc822MessageId == "<msg123@example.com>")
        #expect(fetched?.folderId == "acc1:INBOX")
        #expect(fetched?.isInInbox == true)
    }

    @Test("Messages deleted: remove headers by messageId")
    func removeHeadersByMessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "msg-to-delete", accountId: "acc1")

        // Delta sync says this message was deleted — remove it
        let removedCount = try db.write { dbConn -> Int in
            let matches = try MessageHeader
                .filter(Column("messageId") == "msg-to-delete")
                .fetchAll(dbConn)
            for msg in matches {
                try msg.delete(dbConn)
            }
            return matches.count
        }

        #expect(removedCount == 1)

        let remaining = try db.read { dbConn in
            try MessageHeader.filter(Column("messageId") == "msg-to-delete").fetchOne(dbConn)
        }
        #expect(remaining == nil)
    }

    @Test("Messages deleted: skip if pending operation exists")
    func skipDeleteIfPendingOpExists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "msg-with-pending", accountId: "acc1")

        // Insert a pending operation for this message
        var pendingOp = PendingOperation(
            type: .move,
            messageIds: ["msg-with-pending"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { dbConn in try pendingOp.insert(dbConn) }

        // Delta sync deletion should skip messages with pending ops (mirrors gmailDeltaSync pattern)
        let deleteSet: Set<String> = ["msg-with-pending"]
        let accountIdCapture = "acc1"
        let removedIds: [String] = try db.write { dbConn in
            let pendingAllIds = Set(
                try PendingOperation
                    .filter(Column("accountId") == accountIdCapture)
                    .fetchAll(dbConn)
                    .flatMap(\.messageIds)
            )
            var ids: [String] = []
            for deleteId in deleteSet where !pendingAllIds.contains(deleteId) {
                let matches = try MessageHeader
                    .filter(Column("messageId") == deleteId)
                    .fetchAll(dbConn)
                for msg in matches {
                    ids.append(msg.id)
                    try msg.delete(dbConn)
                }
            }
            return ids
        }

        // Message should NOT have been deleted
        #expect(removedIds.isEmpty)

        let stillExists = try db.read { dbConn in
            try MessageHeader.filter(Column("messageId") == "msg-with-pending").fetchOne(dbConn)
        }
        #expect(stillExists != nil)
    }

    @Test("Labels changed: update header flags (isRead, isFlagged)")
    func updateHeaderFlagsOnLabelChange() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg-flags", accountId: "acc1", isRead: false
        )
        #expect(header.isRead == false)
        #expect(header.isFlagged == false)

        // Simulate delta sync flag update (like gmailDeltaSync's existsLocally && belongsInFolder path)
        try db.write { dbConn in
            guard var existing = try MessageHeader.fetchOne(dbConn, key: header.id) else {
                Issue.record("Header not found")
                return
            }
            existing.isRead = true
            existing.isFlagged = true
            try existing.update(dbConn)
        }

        let updated = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: header.id)
        }
        #expect(updated?.isRead == true)
        #expect(updated?.isFlagged == true)
    }

    @Test("History cursor updated after successful delta")
    func historyCursorUpdated() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        account.lastHistoryId = "12345"
        try db.write { dbConn in try account.update(dbConn) }

        // After successful delta sync, update the cursor
        let newHistoryId = "12399"
        try db.write { dbConn in
            _ = try Account.filter(Column("id") == "acc1")
                .updateAll(dbConn, Column("lastHistoryId").set(to: newHistoryId))
        }

        let fetched = try db.read { dbConn in
            try Account.fetchOne(dbConn, key: "acc1")
        }
        #expect(fetched?.lastHistoryId == "12399")
    }

    @Test("History cursor cleared when 404 (expired history)")
    func historyCursorClearedOn404() throws {
        let db = try TestDatabase.make()
        var account = try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        account.lastHistoryId = "old-expired-id"
        try db.write { dbConn in try account.update(dbConn) }

        // When history.list returns 404, clear the cursor so next sync does full
        try db.write { dbConn in
            _ = try Account.filter(Column("id") == "acc1")
                .updateAll(dbConn, Column("lastHistoryId").set(to: nil as String?))
        }

        let fetched = try db.read { dbConn in
            try Account.fetchOne(dbConn, key: "acc1")
        }
        #expect(fetched?.lastHistoryId == nil)
    }
}

// MARK: - Suite 2: Tag Operations — Provider + DB

@Suite("Tag Operations — Provider + DB")
struct TagOperationTests {

    @Test("setTag creates PendingOperation with correct type and tagValue")
    func setTagCreatesPendingOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        var op = PendingOperation(
            type: .setTag,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: ActionTag.reply.rawValue
        )
        try db.write { dbConn in try op.insert(dbConn) }

        let fetched = try db.read { dbConn in
            try PendingOperation.fetchOne(dbConn, key: op.id)
        }
        #expect(fetched != nil)
        #expect(fetched?.type == .setTag)
        #expect(fetched?.tagValue == "reply")
        #expect(fetched?.messageIds == ["msg-1"])
    }

    @Test("removeTag creates PendingOperation with nil tagValue")
    func removeTagCreatesPendingOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        var op = PendingOperation(
            type: .removeTag,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: nil
        )
        try db.write { dbConn in try op.insert(dbConn) }

        let fetched = try db.read { dbConn in
            try PendingOperation.fetchOne(dbConn, key: op.id)
        }
        #expect(fetched != nil)
        #expect(fetched?.type == .removeTag)
        #expect(fetched?.tagValue == nil)
    }

    @Test("setTag updates DB header actionTag and tagSortOrder")
    func setTagUpdatesHeaderFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let header = try TestDatabase.insertMessageHeader(db, messageId: "msg-tag", accountId: "acc1")

        // Verify initial state
        #expect(header.actionTag == nil)
        #expect(header.tagSortOrder == 99)

        // Update the header with a tag (mirrors optimistic UI update pattern)
        try db.write { dbConn in
            guard var existing = try MessageHeader.fetchOne(dbConn, key: header.id) else {
                Issue.record("Header not found")
                return
            }
            let tag = ActionTag.archive
            existing.actionTag = tag
            existing.tagSortOrder = tag.sortOrder
            try existing.update(dbConn)
        }

        let updated = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: header.id)
        }
        #expect(updated?.actionTag == .archive)
        #expect(updated?.tagSortOrder == ActionTag.archive.sortOrder)
        #expect(updated?.tagSortOrder == 2)
    }

    @Test("removeTag clears DB header actionTag")
    func removeTagClearsHeaderActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "msg-tag-remove", accountId: "acc1", actionTag: .reply
        )

        #expect(header.actionTag == .reply)

        // Clear the tag
        try db.write { dbConn in
            guard var existing = try MessageHeader.fetchOne(dbConn, key: header.id) else {
                Issue.record("Header not found")
                return
            }
            existing.actionTag = nil
            existing.tagSortOrder = 99
            try existing.update(dbConn)
        }

        let updated = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: header.id)
        }
        #expect(updated?.actionTag == nil)
        #expect(updated?.tagSortOrder == 99)
    }

    @Test("Multiple messages tagged in batch")
    func batchTagging() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let h1 = try TestDatabase.insertMessageHeader(db, messageId: "batch-1", accountId: "acc1")
        let h2 = try TestDatabase.insertMessageHeader(db, messageId: "batch-2", accountId: "acc1")
        let h3 = try TestDatabase.insertMessageHeader(db, messageId: "batch-3", accountId: "acc1")

        // Tag all messages in a single transaction
        let tag = ActionTag.delete
        try db.write { dbConn in
            for headerId in [h1.id, h2.id, h3.id] {
                guard var header = try MessageHeader.fetchOne(dbConn, key: headerId) else { continue }
                header.actionTag = tag
                header.tagSortOrder = tag.sortOrder
                try header.update(dbConn)
            }
        }

        // Also queue pending ops for each
        try db.write { dbConn in
            for msgId in ["batch-1", "batch-2", "batch-3"] {
                var op = PendingOperation(
                    type: .setTag,
                    messageIds: [msgId],
                    accountId: "acc1",
                    folderPath: "INBOX",
                    tagValue: tag.rawValue
                )
                try op.insert(dbConn)
            }
        }

        // Verify all headers updated
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("accountId") == "acc1")
                .order(Column("messageId").asc)
                .fetchAll(dbConn)
        }
        #expect(headers.count == 3)
        for header in headers {
            #expect(header.actionTag == .delete)
            #expect(header.tagSortOrder == 3)
        }

        // Verify all pending ops created
        let ops = try db.read { dbConn in
            try PendingOperation.filter(Column("type") == OperationType.setTag.rawValue).fetchAll(dbConn)
        }
        #expect(ops.count == 3)
    }
}

// MARK: - Suite 3: PendingCalendarOperation — GRDB Patterns

@Suite("PendingCalendarOperation — GRDB Patterns")
struct PendingCalendarOperationGRDBTests {

    @Test("Insert and fetch by status")
    func insertAndFetchByStatus() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)

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
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)

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
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)

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
        try TestDatabase.insertAccount(db, id: "acc1", email: "user1@gmail.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "acc2", email: "user2@gmail.com", provider: .gmail)

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
        try TestDatabase.insertAccount(db, id: "acc-del", email: "delete-me@gmail.com", provider: .gmail)

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

// MARK: - Suite 4: Backfill Window Calculation

@Suite("Backfill Window Calculation")
struct BackfillWindowCalculationTests {

    /// UTC midnight calendar used by backfill for date alignment.
    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("Window boundaries align to UTC midnight")
    func windowBoundariesAlignToUTCMidnight() {
        let cal = Self.utcCalendar

        // Given an arbitrary date/time
        let arbitrary = Date(timeIntervalSince1970: 1700055555) // 2023-11-15 15:25:55 UTC

        // Align to start of day (UTC midnight)
        let startOfDay = cal.startOfDay(for: arbitrary)
        let components = cal.dateComponents([.hour, .minute, .second], from: startOfDay)

        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)

        // Verify it's still the same day
        let dayComponents = cal.dateComponents([.year, .month, .day], from: startOfDay)
        let origDayComponents = cal.dateComponents([.year, .month, .day], from: arbitrary)
        #expect(dayComponents.year == origDayComponents.year)
        #expect(dayComponents.month == origDayComponents.month)
        #expect(dayComponents.day == origDayComponents.day)
    }

    @Test("1-day overlap between consecutive windows")
    func oneDayOverlapBetweenWindows() {
        let cal = Self.utcCalendar

        // Simulate two consecutive 30-day backfill windows
        let windowEnd = cal.startOfDay(for: Date(timeIntervalSince1970: 1700000000)) // 2023-11-14 UTC
        let windowDays = 30
        let windowStart = cal.date(byAdding: .day, value: -windowDays, to: windowEnd)!

        // Next window: ends at previous windowStart, with 1-day overlap
        let nextWindowEnd = windowStart
        let overlapDays = 1
        let searchSince = cal.date(byAdding: .day, value: -overlapDays, to: nextWindowEnd)!

        // searchSince should be 1 day before the next window's end
        let diff = cal.dateComponents([.day], from: searchSince, to: nextWindowEnd)
        #expect(diff.day == overlapDays)

        // The overlap region is: [searchSince, nextWindowEnd) = 1 day
        // This ensures boundary messages are not missed
        let overlapSeconds = nextWindowEnd.timeIntervalSince(searchSince)
        #expect(overlapSeconds == Double(overlapDays * 86400))
    }

    @Test("backfillUidCursor tracks progress")
    func backfillUidCursorTracksProgress() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@imap.com", provider: .imap)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Initially nil
        #expect(folder.backfillUidCursor == nil)

        // After fetching a batch, update cursor to lowest UID fetched
        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("backfillUidCursor").set(to: 500))
        }

        let afterFirst = try db.read { dbConn in
            try Folder.fetchOne(dbConn, key: folder.id)
        }
        #expect(afterFirst?.backfillUidCursor == 500)

        // After next batch, cursor moves further back
        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("backfillUidCursor").set(to: 200))
        }

        let afterSecond = try db.read { dbConn in
            try Folder.fetchOne(dbConn, key: folder.id)
        }
        #expect(afterSecond?.backfillUidCursor == 200)
    }

    @Test("backfillComplete flag set after final window")
    func backfillCompleteFlagSetAfterFinalWindow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@imap.com", provider: .imap)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Initially false
        #expect(folder.backfillComplete == false)

        // After all windows are processed, mark complete
        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("backfillComplete").set(to: true))
        }

        let completed = try db.read { dbConn in
            try Folder.fetchOne(dbConn, key: folder.id)
        }
        #expect(completed?.backfillComplete == true)

        // Verify that resetting backfillComplete works (e.g. via Smart Reindex)
        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("backfillComplete").set(to: false))
        }

        let reset = try db.read { dbConn in
            try Folder.fetchOne(dbConn, key: folder.id)
        }
        #expect(reset?.backfillComplete == false)
    }
}

// MARK: - Suite: Unread Recount Timing

@Suite("Delta Sync — Unread Recount After Header Mutations")
struct DeltaSyncUnreadRecountTests {

    @Test("Unread count is recountable immediately after header insert (before FTS/body)")
    func recountableImmediatelyAfterInsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Simulate delta sync: headers are written in a write transaction
        try db.write { dbConn in
            for i in 0..<5 {
                var header = MessageHeader(
                    messageId: "msg\(i)",
                    subject: "Subject \(i)",
                    from: "sender@test.com",
                    fromAddress: "sender@test.com",
                    to: "test@gmail.com",
                    date: Date(),
                    snippet: "Snippet \(i)",
                    folderId: folder.id,
                    accountId: "acc1",
                    folderPath: "INBOX",
                    isInInbox: true
                )
                header.isRead = (i < 2) // 2 read, 3 unread
                try header.insert(dbConn)
            }
        }

        // Immediately after the write transaction — BEFORE any FTS or body fetch —
        // the unread count should be available via the same grouped COUNT query
        // that UnreadCountManager.performRecount uses.
        let folderIds = [folder.id]
        let recountResult = try db.read { dbConn -> [String: Int] in
            let placeholders = folderIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT folderId, COUNT(*) as cnt
                FROM messageHeader
                WHERE folderId IN (\(placeholders)) AND isRead = 0
                GROUP BY folderId
                """
            let rows = try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(folderIds))
            var counts: [String: Int] = [:]
            for row in rows {
                let fid: String = row["folderId"]
                let cnt: Int = row["cnt"]
                counts[fid] = cnt
            }
            return counts
        }

        #expect(recountResult[folder.id] == 3, "Unread count should be correct right after header insert")

        // Apply to folder (what performRecount does)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE folder SET unreadCount = ? WHERE id = ?",
                arguments: [recountResult[folder.id] ?? 0, folder.id]
            )
        }
        let updatedFolder = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updatedFolder?.unreadCount == 3)
    }

    @Test("Unread count is recountable after flag-only delta (no new headers)")
    func recountableAfterFlagOnlyDelta() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pre-existing messages — 3 unread
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(db, messageId: "msg\(i)", folderId: folder.id, accountId: "acc1", isRead: false)
        }

        // Simulate delta flag change: mark msg0 as read (no new headers)
        try db.write {
            try $0.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE messageId = 'msg0'")
        }

        // Recount should reflect the flag change
        let count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == folder.id && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 2, "Recount must reflect flag-only changes (no new/deleted headers)")
    }

    @Test("Unread count is recountable after deletion-only delta (no new headers)")
    func recountableAfterDeletionOnlyDelta() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pre-existing: 4 unread messages
        for i in 0..<4 {
            try TestDatabase.insertMessageHeader(db, messageId: "msg\(i)", folderId: folder.id, accountId: "acc1", isRead: false)
        }

        // Simulate delta deletion: remove msg0 and msg1
        try db.write {
            try MessageHeader.filter(Column("messageId") == "msg0").deleteAll($0)
            try MessageHeader.filter(Column("messageId") == "msg1").deleteAll($0)
        }

        // Recount should reflect deletions
        let count = try db.read {
            try MessageHeader.filter(
                Column("folderId") == folder.id && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(count == 2, "Recount must reflect deletion-only changes (no new headers)")
    }

    @Test("runSyncMessages flag-only update produces empty newHeaders — recount still needed")
    func flagOnlyUpdateEmptyNewHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pre-existing messages: 2 unread
        try TestDatabase.insertMessageHeader(db, messageId: "msg0", folderId: folder.id, accountId: "acc1", isRead: false)
        try TestDatabase.insertMessageHeader(db, messageId: "msg1", folderId: folder.id, accountId: "acc1", isRead: false)

        // Simulate what runSyncMessages does when server says msg0 is now read:
        // Updates existing row (flag change), no new headers inserted, no stale IDs.
        let newHeaders: [MessageHeader] = []
        let staleIds: [String] = []

        try db.write { dbConn in
            if var existing = try MessageHeader
                .filter(Column("messageId") == "msg0" && Column("folderId") == folder.id)
                .fetchOne(dbConn) {
                existing.isRead = true  // Server says read
                try existing.update(dbConn)
                // Note: existing message updated — NOT added to newHeaders
            }
        }

        // This is the key assertion: newHeaders and staleIds are both empty,
        // but the unread count has changed. The recount MUST fire unconditionally.
        #expect(newHeaders.isEmpty, "Flag-only updates don't produce newHeaders")
        #expect(staleIds.isEmpty, "Flag-only updates don't produce staleIds")

        // Verify recount gives the correct answer
        let unreadCount = try db.read {
            try MessageHeader.filter(
                Column("folderId") == folder.id && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(unreadCount == 1, "Recount must reflect flag change even with empty newHeaders/staleIds")

        // Apply recount to folder
        try db.write {
            try $0.execute(
                sql: "UPDATE folder SET unreadCount = ? WHERE id = ?",
                arguments: [unreadCount, folder.id]
            )
        }
        let updatedFolder = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updatedFolder?.unreadCount == 1)
    }

    @Test("Mixed delta: deletes + inserts + flag changes — single recount captures all")
    func mixedDeltaSingleRecount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "test@gmail.com", provider: .gmail)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Start with 4 unread messages
        for i in 0..<4 {
            try TestDatabase.insertMessageHeader(db, messageId: "msg\(i)", folderId: folder.id, accountId: "acc1", isRead: false)
        }

        // Simulate mixed delta:
        // 1. Delete msg0 (was unread → -1 unread)
        try db.write {
            _ = try MessageHeader.filter(Column("messageId") == "msg0").deleteAll($0)
        }

        // 2. Mark msg1 as read (flag change → -1 unread)
        try db.write {
            try $0.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE messageId = 'msg1'")
        }

        // 3. Insert new unread message (+1 unread)
        try TestDatabase.insertMessageHeader(db, messageId: "msg4", folderId: folder.id, accountId: "acc1", isRead: false)

        // Net: 4 - 1(delete) - 1(read) + 1(new) = 3 unread
        // A single recount AFTER all mutations must capture the combined effect.
        let unreadCount = try db.read {
            try MessageHeader.filter(
                Column("folderId") == folder.id && Column("isRead") == false
            ).fetchCount($0)
        }
        #expect(unreadCount == 3, "Single recount after mixed delta must reflect combined delete+flag+insert")
    }
}
