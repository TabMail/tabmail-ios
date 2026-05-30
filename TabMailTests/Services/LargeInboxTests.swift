/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the large inbox support feature (matching TB's inboxManagement):
/// 1. SyncConfig constants exist and are reasonable
/// 2. AI queue repopulate only considers the N most recent inbox messages
/// 3. AI queue recency gate skips old messages in large inboxes
/// 4. Large inbox detection logic (total >= maxRecentEmails AND old > 0)
/// 5. Bulk archive query selects correct messages by age cutoff
@Suite("Large Inbox Support")
struct LargeInboxTests {

    // MARK: - SyncConfig constants

    @Test("maxRecentEmails matches TB default of 100")
    func maxRecentEmailsValue() {
        #expect(SyncConfig.maxRecentEmails == 100)
    }

    @Test("archiveAgeDays matches TB default of 14")
    func archiveAgeDaysValue() {
        #expect(SyncConfig.archiveAgeDays == 14)
    }

    @Test("maxRecentEmails is positive")
    func maxRecentEmailsPositive() {
        #expect(SyncConfig.maxRecentEmails > 0)
    }

    @Test("archiveAgeDays is positive")
    func archiveAgeDaysPositive() {
        #expect(SyncConfig.archiveAgeDays > 0)
    }

    // MARK: - AI queue repopulate cap (query pattern)

    @Test("Repopulate query returns at most maxRecentEmails messages")
    func repopulateQueryCap() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        // Insert 150 inbox messages (more than maxRecentEmails), all missing AI data
        let now = Date()
        for i in 0..<150 {
            let date = now.addingTimeInterval(Double(-i) * 3600) // 1hr apart
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: date,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        // Query matching repopulateFromDatabase: top N by date, then filter missing AI
        let recentHeaders = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").desc)
                .limit(SyncConfig.maxRecentEmails)
                .fetchAll(db)
        }

        #expect(recentHeaders.count == SyncConfig.maxRecentEmails)
        guard let oldestRecent = recentHeaders.last?.date else { return }

        // Verify the oldest message in results is newer than the oldest overall
        let oldestOverall = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").asc)
                .fetchOne(db)?.date
        }
        guard let oldestOverall else {
            Issue.record("Expected at least one message in database")
            return
        }
        #expect(oldestRecent > oldestOverall)
    }

    @Test("Repopulate query filters to messages missing AI data within recent window")
    func repopulateQueryFiltersAI() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        // 5 recent messages: 3 missing summary, 2 fully processed
        for i in 0..<3 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "missing\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<2 {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "done\(i)", date: now.addingTimeInterval(Double(-(i + 3)) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true, actionTag: .reply
            )
            header.summaryBlurb = "Summary"
            header.cachedReply = "Reply"
            try db.write { try header.update($0) }
        }

        // Repopulate pattern: fetch recent, filter in Swift
        let recentHeaders = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").desc)
                .limit(SyncConfig.maxRecentEmails)
                .fetchAll(db)
        }

        let needsAI = recentHeaders.filter { h in
            h.summaryBlurb == nil || h.summaryBlurb?.isEmpty == true ||
            h.actionTag == nil || h.cachedReply == nil
        }

        #expect(recentHeaders.count == 5)
        #expect(needsAI.count == 3)
    }

    // MARK: - Recency gate (processItem pattern)

    @Test("Recency gate: message within top N passes")
    func recencyGatePasses() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        // Insert exactly maxRecentEmails messages
        for i in 0..<SyncConfig.maxRecentEmails {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        // The most recent message should pass the gate
        let newest = try db.read { db in
            try MessageHeader.filter(Column("messageId") == "msg0").fetchOne(db)!
        }
        let newerCount = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(Column("date") > newest.date)
                .fetchCount(db)
        }
        #expect(newerCount < SyncConfig.maxRecentEmails)
    }

    @Test("Recency gate: message outside top N is rejected")
    func recencyGateRejects() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        // Insert maxRecentEmails + 10 messages
        let total = SyncConfig.maxRecentEmails + 10
        for i in 0..<total {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        // The oldest message (msg109) should fail the gate
        let oldest = try db.read { db in
            try MessageHeader.filter(Column("messageId") == "msg\(total - 1)").fetchOne(db)!
        }
        let newerCount = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(Column("date") > oldest.date)
                .fetchCount(db)
        }
        #expect(newerCount >= SyncConfig.maxRecentEmails)
    }

    @Test("Recency gate: non-inbox messages are not subject to the gate")
    func recencyGateSkipsNonInbox() throws {
        // The gate only applies to isInInbox messages.
        // Non-inbox messages (sent, drafts) don't count.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let now = Date()
        // 50 inbox + 60 sent = 110 total, but only 50 inbox
        for i in 0..<50 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "inbox\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<60 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "sent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: "acc1:Sent", accountId: "acc1", folderPath: "Sent",
                isInInbox: false
            )
        }

        // The oldest inbox message should still pass (only 50 inbox, < 100)
        let oldestInbox = try db.read { db in
            try MessageHeader.filter(Column("messageId") == "inbox49").fetchOne(db)!
        }
        let newerInboxCount = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(Column("date") > oldestInbox.date)
                .fetchCount(db)
        }
        #expect(newerInboxCount < SyncConfig.maxRecentEmails)
    }

    // MARK: - Large inbox detection

    @Test("Inbox with 100+ messages and old messages is detected as large")
    func largeInboxDetected() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // 80 recent + 30 old = 110 total
        for i in 0..<80 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<30 {
            let oldDate = archiveCutoff.addingTimeInterval(Double(-(i + 1)) * 86400)
            try TestDatabase.insertMessageHeader(
                db, messageId: "old\(i)", date: oldDate,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let (totalCount, oldCount) = try db.read { db -> (Int, Int) in
            let total = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .fetchCount(db)
            let old = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        #expect(isLarge == true)
        #expect(totalCount == 110)
        #expect(oldCount == 30)
    }

    @Test("Inbox with fewer than 100 messages is not large")
    func smallInboxNotLarge() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // 50 recent + 20 old = 70 total (< 100)
        for i in 0..<50 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<20 {
            let oldDate = archiveCutoff.addingTimeInterval(Double(-(i + 1)) * 86400)
            try TestDatabase.insertMessageHeader(
                db, messageId: "old\(i)", date: oldDate,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let (totalCount, oldCount) = try db.read { db -> (Int, Int) in
            let total = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .fetchCount(db)
            let old = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        #expect(isLarge == false)
        #expect(totalCount == 70)
    }

    @Test("Inbox with 100+ messages but none old is not large")
    func largeButNoOldNotLarge() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        // 120 messages, all within last 2 days (well within archiveAgeDays)
        for i in 0..<120 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!
        let (totalCount, oldCount) = try db.read { db -> (Int, Int) in
            let total = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .fetchCount(db)
            let old = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchCount(db)
            return (total, old)
        }

        let isLarge = totalCount >= SyncConfig.maxRecentEmails && oldCount > 0
        #expect(isLarge == false)
        #expect(totalCount == 120)
        #expect(oldCount == 0)
    }

    // MARK: - Bulk archive query

    @Test("Bulk archive selects only messages older than cutoff")
    func bulkArchiveSelectsOldOnly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // 5 recent, 3 old
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }
        for i in 0..<3 {
            let oldDate = archiveCutoff.addingTimeInterval(Double(-(i + 1)) * 86400)
            try TestDatabase.insertMessageHeader(
                db, messageId: "old\(i)", date: oldDate,
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let oldMessages = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .order(Column("date").asc)
                .fetchAll(db)
        }

        #expect(oldMessages.count == 3)
        for msg in oldMessages {
            #expect(msg.messageId.hasPrefix("old"))
            #expect(msg.date < archiveCutoff)
        }
    }

    @Test("Bulk archive groups messages by account")
    func bulkArchiveGroupsByAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com")
        let folder1 = try TestDatabase.insertFolder(db, accountId: "acc1")
        let folder2 = try TestDatabase.insertFolder(db, accountId: "acc2")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc2")

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!
        let oldDate = archiveCutoff.addingTimeInterval(-86400)

        try TestDatabase.insertMessageHeader(
            db, messageId: "acc1msg", date: oldDate,
            folderId: folder1.id, accountId: "acc1", folderPath: "INBOX",
            isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "acc2msg", date: oldDate,
            folderId: folder2.id, accountId: "acc2", folderPath: "INBOX",
            isInInbox: true
        )

        // Simulate the grouping logic from archiveOldMessages
        let inboxFolderIds: Set<String> = [folder1.id, folder2.id]
        let oldMessages = try db.read { db in
            try MessageHeader
                .filter(inboxFolderIds.contains(Column("folderId")))
                .filter(Column("date") < archiveCutoff)
                .order(Column("date").asc)
                .fetchAll(db)
        }

        let byAccount = Dictionary(grouping: oldMessages, by: \.accountId)
        #expect(byAccount.count == 2)
        #expect(byAccount["acc1"]?.count == 1)
        #expect(byAccount["acc2"]?.count == 1)

        // Verify archive folders exist for both accounts
        for accountId in byAccount.keys {
            let archiveFolder = try db.read { db in
                try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.archive.rawValue).fetchOne(db)
            }
            #expect(archiveFolder != nil)
        }
    }

    @Test("Bulk archive returns empty when no messages older than cutoff")
    func bulkArchiveEmptyWhenNoOld() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let archiveCutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.archiveAgeDays, to: now)!

        // All recent
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "recent\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        let oldMessages = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folder.id)
                .filter(Column("date") < archiveCutoff)
                .fetchAll(db)
        }

        #expect(oldMessages.isEmpty)
    }

    // MARK: - Edge cases

    @Test("Recency gate with exactly maxRecentEmails messages — all pass")
    func recencyGateExactLimit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        for i in 0..<SyncConfig.maxRecentEmails {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        // Even the oldest (msg99) should pass — exactly 99 newer messages
        let oldest = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").asc)
                .fetchOne(db)!
        }
        let newerCount = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(Column("date") > oldest.date)
                .fetchCount(db)
        }
        #expect(newerCount == SyncConfig.maxRecentEmails - 1)
        #expect(newerCount < SyncConfig.maxRecentEmails) // passes gate
    }

    @Test("Recency gate with maxRecentEmails + 1 — oldest is rejected")
    func recencyGateOnePastLimit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        let total = SyncConfig.maxRecentEmails + 1
        for i in 0..<total {
            try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
        }

        // The 101st oldest (msg100) should fail the gate
        let oldest = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .order(Column("date").asc)
                .fetchOne(db)!
        }
        let newerCount = try db.read { db in
            try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(Column("date") > oldest.date)
                .fetchCount(db)
        }
        #expect(newerCount == SyncConfig.maxRecentEmails) // exactly at limit = rejected
        #expect(newerCount >= SyncConfig.maxRecentEmails)
    }
}
