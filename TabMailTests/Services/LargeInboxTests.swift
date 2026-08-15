/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the large inbox support feature (matching TB's inboxManagement):
/// 1. SyncConfig constants exist and are reasonable
/// 2. Automatic AI repopulation only considers unfinished work inside the N
///    most recent inbox messages
/// 3. Direct event jobs are not re-gated by inbox age after selection
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

    // MARK: - AI queue backlog selection and direct-event execution

    @Test("Automatic repopulation returns at most the newest maxRecentEmails inbox messages")
    func repopulateQueryCap() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        for i in 0..<150 {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            try db.write { try header.update($0) }
        }

        let candidates = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }

        #expect(candidates.count == SyncConfig.maxRecentEmails)
        #expect(candidates.first?.headerId.hasSuffix(":msg0") == true)
        #expect(candidates.last?.headerId.hasSuffix(":msg99") == true)
        #expect(!candidates.contains { $0.headerId.hasSuffix(":msg100") })
    }

    @Test("Automatic repopulation filters within the recent window instead of backfilling older rows")
    func repopulateQueryFiltersAI() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        for i in 0...SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            if i < SyncConfig.maxRecentEmails {
                header.summaryBlurb = "Summary"
                header.actionTag = .reply
                header.cachedReply = "Reply"
            }
            try db.write { try header.update($0) }
        }

        let candidates = try db.read { db in
            try ActiveAIQueue.repopulationCandidates(db: db)
        }

        #expect(
            candidates.isEmpty,
            "the unfinished 101st row is outside the automatic backlog window")
    }

    @Test("Automatic body production excludes an old row while a direct job executes it")
    func directOldJobExecutesOutsideBacklogWindow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let now = Date()
        var target: MessageHeader?
        for i in 0...SyncConfig.maxRecentEmails {
            var header = try TestDatabase.insertMessageHeader(
                db, messageId: "msg\(i)", date: now.addingTimeInterval(Double(-i) * 3600),
                folderId: folder.id, accountId: "acc1", folderPath: "INBOX",
                isInInbox: true
            )
            header.bodyComplete = true
            if i < SyncConfig.maxRecentEmails {
                header.summaryBlurb = "Summary"
                header.actionTag = .reply
                header.cachedReply = "Reply"
            } else {
                target = header
            }
            try db.write { try header.update($0) }
        }

        guard let target else {
            Issue.record("Expected the directly selected target")
            return
        }
        let processed = BodyFetchProcessor.ProcessedItem(
            contentKey: ContentKey(rawValue: target.id),
            headerId: target.id,
            accountId: target.accountId,
            isInInbox: true,
            body: "old body producer fixture",
            snippet: "old body producer fixture")
        let evidence = try db.read { db -> (Int, [BodyFetchProcessor.ProcessedItem]) in
            let newerCount = try MessageHeader
                .filter(Column("isInInbox") == true)
                .filter(Column("date") > target.date)
                .fetchCount(db)
            let candidates = try BodyFetchProcessor.automaticAIEnqueueCandidates(
                from: [processed], db: db)
            return (newerCount, candidates)
        }
        #expect(evidence.0 == SyncConfig.maxRecentEmails)
        #expect(evidence.1.isEmpty)
        #expect(ActiveAIQueue.jobStartDisposition(
            message: target, jobType: .summary, admission: .admissible) == .execute)
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

}
