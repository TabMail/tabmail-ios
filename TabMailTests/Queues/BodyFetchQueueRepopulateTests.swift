/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ActiveBodyQueue.repopulateFromDatabase — all folders included")
struct ActiveBodyQueueRepopulateTests {

    // MARK: - Helpers

    /// Queries headers that would be returned by repopulateFromDatabase's DB query.
    /// Mirrors the production query without the actor/FTS dependency so we can test
    /// the SQL filter in isolation.
    private func queryRepopulateCandidates(_ db: DatabaseQueue, limit: Int = 100) throws -> [MessageHeader] {
        try db.read { dbConn in
            try MessageHeader
                .order(Column("date").desc)
                .limit(limit)
                .fetchAll(dbConn)
        }
    }

    // MARK: - Tests

    @Test("Repopulate query includes inbox messages")
    func includesInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", isInInbox: true)

        let candidates = try queryRepopulateCandidates(db)
        #expect(candidates.count == 1)
        guard candidates.count == 1 else { return }
        #expect(candidates[0].isInInbox == true)
    }

    @Test("Repopulate query includes sent folder messages")
    func includesSent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", snippet: "",
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )

        let candidates = try queryRepopulateCandidates(db)
        #expect(candidates.count == 1)
        guard candidates.count == 1 else { return }
        #expect(candidates[0].isInInbox == false)
        #expect(candidates[0].folderPath == "Sent")
    }

    @Test("Repopulate query includes archive folder messages")
    func includesArchive() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", snippet: "",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )

        let candidates = try queryRepopulateCandidates(db)
        #expect(candidates.count == 1)
        guard candidates.count == 1 else { return }
        #expect(candidates[0].folderPath == "Archive")
    }

    @Test("Repopulate query includes messages from multiple folders")
    func includesMultipleFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db) // INBOX
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let now = Date()
        try TestDatabase.insertMessageHeader(
            db, messageId: "1", date: now.addingTimeInterval(-300),
            folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "2", date: now.addingTimeInterval(-200),
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "3", date: now.addingTimeInterval(-100),
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )

        let candidates = try queryRepopulateCandidates(db)
        #expect(candidates.count == 3)
        guard candidates.count == 3 else { return }
        // Ordered by date desc
        #expect(candidates[0].folderPath == "Archive")
        #expect(candidates[1].folderPath == "Sent")
        #expect(candidates[2].folderPath == "INBOX")
    }

    @Test("Repopulate query respects limit")
    func respectsLimit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        for i in 0..<10 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "\(i)", date: now.addingTimeInterval(Double(-i * 60))
            )
        }

        let candidates = try queryRepopulateCandidates(db, limit: 3)
        #expect(candidates.count == 3)
    }

    @Test("Repopulate query orders by date descending — newest first")
    func orderedByDateDesc() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        try TestDatabase.insertMessageHeader(db, messageId: "old", date: now.addingTimeInterval(-3600))
        try TestDatabase.insertMessageHeader(db, messageId: "new", date: now)

        let candidates = try queryRepopulateCandidates(db)
        #expect(candidates.count == 2)
        guard candidates.count == 2 else { return }
        #expect(candidates[0].messageId == "new")
        #expect(candidates[1].messageId == "old")
    }
}
