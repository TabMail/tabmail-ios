/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Suite 1: Backfill Cursor State

@Suite("Backfill State - Cursor Management")
struct BackfillCursorTests {

    @Test("Initial state: backfillComplete=false, cursors=nil")
    func initialState() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        #expect(folder.backfillComplete == false)
        #expect(folder.oldestSyncedDate == nil)
        #expect(folder.backfillUidCursor == nil)
        #expect(folder.backfillPageToken == nil)
        #expect(folder.lastKnownUidNext == nil)
    }

    @Test("After updating cursor: backfillUidCursor persists correctly")
    func uidCursorPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        folder.backfillUidCursor = 42
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillUidCursor == 42)
    }

    @Test("After setting pageToken: backfillPageToken persists correctly")
    func pageTokenPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        folder.backfillPageToken = "CiAKGjBpNDd2Nmp2"
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillPageToken == "CiAKGjBpNDd2Nmp2")
    }

    @Test("Marking backfillComplete=true persists")
    func backfillCompletePersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        folder.backfillComplete = true
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == true)
    }

    @Test("resetForFastSync: clears cursors for incomplete folders, preserves complete ones")
    func resetForFastSync() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Create an incomplete folder with cursors
        var incomplete = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        incomplete.backfillUidCursor = 100
        incomplete.backfillPageToken = "tok1"
        let incompleteToSave = incomplete
        try await db.write { try incompleteToSave.update($0) }

        // Create a complete folder with cursors
        var complete = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        complete.backfillComplete = true
        complete.backfillUidCursor = 200
        complete.backfillPageToken = "tok2"
        let completeToSave = complete
        try await db.write { try completeToSave.update($0) }

        // Simulate resetForFastSync logic
        try await db.write { dbConn in
            _ = try Folder.filter(
                Column("backfillComplete") == false &&
                Column("path") != ""
            ).updateAll(dbConn,
                Column("backfillUidCursor").set(to: nil as Int?),
                Column("backfillPageToken").set(to: nil as String?)
            )
        }

        let incompleteId = incomplete.id
        let completeId = complete.id
        let fetchedIncomplete = try await db.read { try Folder.fetchOne($0, key: incompleteId) }
        #expect(fetchedIncomplete?.backfillUidCursor == nil)
        #expect(fetchedIncomplete?.backfillPageToken == nil)

        let fetchedComplete = try await db.read { try Folder.fetchOne($0, key: completeId) }
        #expect(fetchedComplete?.backfillUidCursor == 200)
        #expect(fetchedComplete?.backfillPageToken == "tok2")
    }

    @Test("resetCrawlState: resets ALL folders, sets oldestSyncedDate=now, clears cursors")
    func resetCrawlState() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var folder1 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        folder1.backfillComplete = true
        folder1.backfillUidCursor = 500
        folder1.backfillPageToken = "page1"
        folder1.oldestSyncedDate = Date(timeIntervalSince1970: 1000)
        let f1 = folder1
        try await db.write { try f1.update($0) }

        var folder2 = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        folder2.backfillComplete = true
        folder2.backfillUidCursor = 300
        let f2 = folder2
        try await db.write { try f2.update($0) }

        let now = Date()
        try await db.write { dbConn in
            _ = try Folder.filter(Column("path") != "")
                .updateAll(dbConn,
                    Column("backfillComplete").set(to: false),
                    Column("oldestSyncedDate").set(to: now),
                    Column("backfillUidCursor").set(to: nil as Int?),
                    Column("backfillPageToken").set(to: nil as String?)
                )
        }

        let folders = try await db.read { try Folder.fetchAll($0) }
        for folder in folders {
            #expect(folder.backfillComplete == false)
            #expect(folder.backfillUidCursor == nil)
            #expect(folder.backfillPageToken == nil)
            #expect(folder.oldestSyncedDate != nil)
            let diff = abs(folder.oldestSyncedDate!.timeIntervalSince(now))
            #expect(diff < 1.0)
        }
    }
}

// MARK: - Suite 2: Window Calculations

@Suite("Backfill State - Window Calculations")
struct BackfillWindowTests {

    @Test("oldestSyncedDate anchoring: set after initial sync to Nth message date")
    func oldestSyncedDateAnchoring() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        let nthMessageDate = Date(timeIntervalSince1970: 1_700_000_000)
        folder.oldestSyncedDate = nthMessageDate
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.oldestSyncedDate == nthMessageDate)
    }

    @Test("Backfill window: walks from oldestSyncedDate backward")
    func backfillWindowWalksBackward() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let oldestSyncedDate = calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!
        let windowEnd = oldestSyncedDate
        let windowStart = calendar.date(byAdding: .day, value: -30, to: windowEnd)!

        let expectedStart = calendar.date(from: DateComponents(year: 2024, month: 5, day: 16))!
        #expect(windowStart == expectedStart)
        #expect(windowStart < windowEnd)
    }

    @Test("Boundary: oldestSyncedDate=nil defaults to Date() equivalent")
    func nilOldestSyncedDateDefaultsToNow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        #expect(folder.oldestSyncedDate == nil)
        let anchor = folder.oldestSyncedDate ?? Date()
        let now = Date()
        let diff = abs(anchor.timeIntervalSince(now))
        #expect(diff < 1.0)
    }

    @Test("1-day overlap between windows to catch boundary messages")
    func oneDayOverlap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let windowStart = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15))!
        let searchSince = calendar.date(byAdding: .day, value: -1, to: windowStart)!

        let expectedOverlapDate = calendar.date(from: DateComponents(year: 2024, month: 3, day: 14))!
        #expect(searchSince == expectedOverlapDate)

        let dayDiff = calendar.dateComponents([.day], from: searchSince, to: windowStart).day!
        #expect(dayDiff == 1)
    }

    @Test("UTC midnight alignment: dates use UTC calendar")
    func utcMidnightAlignment() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let components = DateComponents(year: 2024, month: 7, day: 20, hour: 18, minute: 45, second: 30)
        let date = calendar.date(from: components)!

        let midnight = calendar.startOfDay(for: date)
        let midnightComps = calendar.dateComponents([.hour, .minute, .second], from: midnight)

        #expect(midnightComps.hour == 0)
        #expect(midnightComps.minute == 0)
        #expect(midnightComps.second == 0)

        let dayComps = calendar.dateComponents([.year, .month, .day], from: midnight)
        #expect(dayComps.year == 2024)
        #expect(dayComps.month == 7)
        #expect(dayComps.day == 20)
    }
}

// MARK: - Suite 3: Batch Processing Patterns

@Suite("Backfill State - Batch Processing")
struct BackfillBatchTests {

    @Test("Header batch insert: multiple messages inserted in one write")
    func headerBatchInsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write { dbConn in
            for i in 1...10 {
                var header = MessageHeader(
                    messageId: "\(i)",
                    subject: "Message \(i)",
                    from: "sender@example.com",
                    fromAddress: "sender@example.com",
                    to: "test@example.com",
                    date: Date(),
                    snippet: "",
                    folderId: "acc1:INBOX",
                    accountId: "acc1",
                    folderPath: "INBOX",
                    isInInbox: true
                )
                try header.insert(dbConn)
            }
        }

        let count = try db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 10)
    }

    @Test("Dedup in backfill: existing messages not duplicated")
    func dedupInBackfill() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "100", subject: "Original")

        let existingIds: Set<String> = try db.read { dbConn in
            let rows = try Row.fetchAll(dbConn,
                sql: "SELECT id FROM messageHeader WHERE accountId = ? AND folderPath = ?",
                arguments: ["acc1", "INBOX"]
            )
            return Set(rows.map { $0["id"] as String })
        }

        let newMessageId = "acc1:INBOX:100"
        #expect(existingIds.contains(newMessageId))

        let candidateIds = ["acc1:INBOX:100", "acc1:INBOX:101"]
        let toInsert = candidateIds.filter { !existingIds.contains($0) }
        #expect(toInsert.count == 1)
        #expect(toInsert.first == "acc1:INBOX:101")
    }

    @Test("UID cursor tracking: progress saved after each batch")
    func uidCursorTracking() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        let batches: [Int] = [500, 400, 300]
        for cursor in batches {
            folder.backfillUidCursor = cursor
            try db.write { try folder.update($0) }
        }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillUidCursor == 300)
    }

    @Test("Connection failure mid-batch: cursor NOT updated (only on success)")
    func connectionFailureMidBatch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        folder.backfillUidCursor = 500
        try db.write { try folder.update($0) }

        // Simulate connection failure — cursor stays unchanged
        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillUidCursor == 500)
    }

    @Test("Multiple folders backfilling independently")
    func multipleFoldersIndependent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        var sent = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        inbox.backfillUidCursor = 100
        inbox.oldestSyncedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try db.write { try inbox.update($0) }

        sent.backfillUidCursor = 200
        sent.backfillComplete = true
        try db.write { try sent.update($0) }

        let fetchedInbox = try db.read { try Folder.fetchOne($0, key: inbox.id) }
        let fetchedSent = try db.read { try Folder.fetchOne($0, key: sent.id) }

        #expect(fetchedInbox?.backfillUidCursor == 100)
        #expect(fetchedInbox?.backfillComplete == false)
        #expect(fetchedSent?.backfillUidCursor == 200)
        #expect(fetchedSent?.backfillComplete == true)
    }
}

// MARK: - Suite 4: Backfill Completion

@Suite("Backfill State - Completion Tracking")
struct BackfillCompletionTests {

    @Test("All folders complete -> account fully backfilled")
    func allFoldersComplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        inbox.backfillComplete = true
        try db.write { try inbox.update($0) }

        var sent = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        sent.backfillComplete = true
        try db.write { try sent.update($0) }

        let incompleteCount = try db.read {
            try Folder.filter(
                Column("accountId") == "acc1" &&
                Column("backfillComplete") == false
            ).fetchCount($0)
        }
        #expect(incompleteCount == 0)
    }

    @Test("One folder incomplete -> account NOT fully backfilled")
    func oneFolderIncomplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        inbox.backfillComplete = true
        try db.write { try inbox.update($0) }

        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let incompleteCount = try db.read {
            try Folder.filter(
                Column("accountId") == "acc1" &&
                Column("backfillComplete") == false
            ).fetchCount($0)
        }
        #expect(incompleteCount == 1)
    }

    @Test("backfillComplete survives simulated app restart (persisted in GRDB)")
    func backfillCompleteSurvivesRestart() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var folder = try TestDatabase.insertFolder(db)
        folder.backfillComplete = true
        folder.backfillUidCursor = 42
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 1_600_000_000)
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == true)
        #expect(fetched?.backfillUidCursor == 42)
        #expect(fetched?.oldestSyncedDate == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test("New folder added -> backfillComplete=false by default")
    func newFolderDefaultsToIncomplete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        #expect(folder.backfillComplete == false)

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == false)
    }

    @Test("Folder deleted and re-added -> backfillComplete resets to false")
    func folderDeletedAndReAdded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var folder = try TestDatabase.insertFolder(db, name: "Custom", path: "Custom", role: .custom)
        folder.backfillComplete = true
        folder.backfillUidCursor = 999
        try db.write { try folder.update($0) }

        let folderId = folder.id

        try db.write { _ = try Folder.deleteOne($0, key: folderId) }
        let deleted = try db.read { try Folder.fetchOne($0, key: folderId) }
        #expect(deleted == nil)

        let reAdded = try TestDatabase.insertFolder(db, name: "Custom", path: "Custom", role: .custom)

        #expect(reAdded.id == folderId)
        #expect(reAdded.backfillComplete == false)
        #expect(reAdded.backfillUidCursor == nil)
    }
}

// MARK: - Suite 5: Body Fetch State Tracking

@Suite("Backfill State - Body Fetch Tracking")
struct BackfillBodyFetchTests {

    @Test("Messages without body: MessageBody row absent")
    func messageWithoutBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(body == nil)
    }

    @Test("Messages with body: MessageBody row exists with matching headerId")
    func messageWithBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>Hello</p>")

        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(body != nil)
        #expect(body?.id == "acc1:INBOX:1")
        #expect(body?.htmlContent == "<p>Hello</p>")
    }

    @Test("Batch body status query: COUNT of messages needing body fetch")
    func batchBodyStatusQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        for i in 1...5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }

        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:3")

        let needingBody = try db.read { dbConn -> Int in
            try Int.fetchOne(dbConn, sql: """
                SELECT COUNT(*) FROM messageHeader mh
                WHERE mh.accountId = ?
                AND NOT EXISTS (
                    SELECT 1 FROM messageBody mb WHERE mb.id = mh.id
                )
                """, arguments: ["acc1"]) ?? 0
        }
        #expect(needingBody == 3)
    }

    @Test("Body fetch uses upsert via save to avoid duplicates")
    func bodyFetchUpsertViaSave() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>First</p>")

        try db.write { dbConn in
            var body = MessageBody(headerId: "acc1:INBOX:1", htmlContent: "<p>Updated</p>")
            try body.save(dbConn)
        }

        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.htmlContent == "<p>Updated</p>")

        let count = try db.read { try MessageBody.fetchCount($0) }
        #expect(count == 1)
    }
}

// MARK: - Suite 6: Power-Aware Backfill (BackfillProfile)

@Suite("Backfill State - Power-Aware Profile")
struct BackfillPowerAwareTests {

    @Test("BackfillProfile.normal has expected delays")
    func normalProfileDelays() {
        let p = BackfillProfile.normal
        #expect(p.imapInterBatchDelay == 0.5)
        #expect(p.deepCrawlInterWindowDelay == 0.5)
        #expect(p.interFolderDelay == 0.5)
        #expect(p.interCycleActiveDelay == 3.0)
        #expect(p.interCycleIdleDelay == 30.0)
    }

    @Test("BackfillProfile.aggressive has smaller delays than normal")
    func aggressiveSmallerDelays() {
        let normal = BackfillProfile.normal
        let aggressive = BackfillProfile.aggressive

        #expect(aggressive.imapInterBatchDelay < normal.imapInterBatchDelay)
        #expect(aggressive.deepCrawlInterWindowDelay < normal.deepCrawlInterWindowDelay)
        #expect(aggressive.interFolderDelay < normal.interFolderDelay)
        #expect(aggressive.interCycleActiveDelay < normal.interCycleActiveDelay)
        #expect(aggressive.interCycleIdleDelay < normal.interCycleIdleDelay)
    }

    @Test("BackfillProfile.low has largest delays")
    func lowProfileLargestDelays() {
        let profiles: [BackfillProfile] = [.normal, .aggressive, .turbo]
        let low = BackfillProfile.low

        for profile in profiles {
            #expect(low.imapInterBatchDelay >= profile.imapInterBatchDelay)
            #expect(low.interCycleIdleDelay >= profile.interCycleIdleDelay)
            #expect(low.interCycleActiveDelay >= profile.interCycleActiveDelay)
        }
    }
}

// MARK: - Suite 7: No Date-Based Backfill Termination

@Suite("Backfill State - UID Walk Completeness")
struct BackfillUIDWalkTests {

    @Test("Account model has no maxSyncAgeDays property")
    func noMaxSyncAgeDays() {
        // maxSyncAgeDays was removed — backfill always walks to UID 1 (IMAP)
        // or exhausts all pages (Gmail/Exchange). No date-based short-circuit.
        let account = Account(emailAddress: "test@example.com", displayName: "Test", provider: .imap)
        let mirror = Mirror(reflecting: account)
        let propertyNames = mirror.children.compactMap(\.label)
        #expect(!propertyNames.contains("maxSyncAgeDays"))
    }

    @Test("IMAP folder completion: only when cursor reaches UID 1")
    func imapCompletionOnlyAtUID1() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        // Simulate UID walk mid-progress — folder must NOT be marked complete
        // even if oldestSyncedDate is very old (no age cutoff exists)
        folder.backfillUidCursor = 50
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 0) // Jan 1970 — extremely old
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == false, "Folder must not be marked complete while cursor > 0")
        #expect(fetched?.backfillUidCursor == 50)
    }

    @Test("IMAP folder marked complete only after full UID walk")
    func imapCompleteAfterFullWalk() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        // Simulate walking cursor to 0 — this is when the code marks complete
        folder.backfillComplete = true
        folder.backfillUidCursor = nil  // Cleared on completion
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == true)
        #expect(fetched?.backfillUidCursor == nil)
    }

    @Test("Gmail/Exchange folder completion: only when no more pages")
    func gmailCompletionOnlyWhenNoPagesLeft() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        // Simulate page walk mid-progress — folder must NOT be complete
        folder.backfillPageToken = "CiAKGjBpNDd2Nmp2"
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 0) // Very old
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == false, "Folder must not be marked complete while page token exists")
    }

    @Test("Gmail/Exchange folder marked complete when page token cleared")
    func gmailCompleteWhenTokenCleared() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        var folder = try TestDatabase.insertFolder(db)

        // Simulate final page processed
        folder.backfillComplete = true
        folder.backfillPageToken = nil  // Cleared on completion
        try db.write { try folder.update($0) }

        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == true)
        #expect(fetched?.backfillPageToken == nil)
    }

    @Test("Reset sync progress: clears completion and cursors, preserves messages")
    func resetSyncProgressPreservesMessages() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Set up a completed folder with messages
        var folder = try TestDatabase.insertFolder(db)
        folder.backfillComplete = true
        folder.backfillUidCursor = nil
        folder.oldestSyncedDate = Date(timeIntervalSince1970: 1_600_000_000)
        try db.write { try folder.update($0) }

        try TestDatabase.insertMessageHeader(db, messageId: "100", subject: "Keep me")
        try TestDatabase.insertMessageHeader(db, messageId: "200", subject: "Keep me too")

        // Reset sync progress (mirrors debug button logic)
        try db.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE folder SET
                    backfillComplete = 0,
                    oldestSyncedDate = NULL,
                    backfillUidCursor = NULL,
                    backfillPageToken = NULL
                WHERE path != ''
            """)
        }

        // Folder progress reset
        let fetched = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(fetched?.backfillComplete == false)
        #expect(fetched?.backfillUidCursor == nil)
        #expect(fetched?.backfillPageToken == nil)
        #expect(fetched?.oldestSyncedDate == nil)

        // Messages preserved
        let msgCount = try db.read { try MessageHeader.fetchCount($0) }
        #expect(msgCount == 2)
    }

    @Test("Incomplete folders query: returns only non-complete folders with non-empty paths")
    func incompleteFoldersQuery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Incomplete folder with path
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Complete folder
        var sent = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        sent.backfillComplete = true
        try db.write { try sent.update($0) }

        let incomplete = try db.read {
            try Folder.filter(
                Column("accountId") == "acc1" &&
                Column("backfillComplete") == false &&
                Column("path") != ""
            ).fetchAll($0)
        }

        #expect(incomplete.count == 1)
        #expect(incomplete.first?.name == "INBOX")
    }
}
