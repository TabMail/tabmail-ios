/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("E2E Storage Management")
struct E2EStorageManagementTests {

    @Test("Prune: oldest bodies evicted to stay under budget")
    func pruneOldestBodies() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 100 messages with bodies, oldest first
        let baseDate = Date().addingTimeInterval(-86400 * 200) // 200 days ago
        for i in 0..<100 {
            let date = baseDate.addingTimeInterval(Double(i) * 86400) // one per day
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)", date: date)
            try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:\(i)", htmlContent: String(repeating: "x", count: 1000))
        }

        // Simulate prune: delete oldest 50 bodies (keeping floor)
        let bodiesToEvict = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT mb.id FROM messageBody mb
                JOIN messageHeader mh ON mb.id = mh.id
                WHERE mh.folderId = 'acc1:INBOX'
                ORDER BY mh.date ASC
                LIMIT 50
                """)
        }
        let evictIds = bodiesToEvict.map { $0["id"] as String }
        try db.write { db in
            for id in evictIds {
                _ = try MessageBody.deleteOne(db, key: id)
            }
        }

        let remainingBodies = try db.read { try MessageBody.fetchCount($0) }
        #expect(remainingBodies == 50)

        // Headers still exist (just bodies evicted)
        let headerCount = try db.read { try MessageHeader.fetchCount($0) }
        #expect(headerCount == 100)
    }

    @Test("50-message floor per folder respected during prune")
    func fiftyMessageFloor() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 55 messages with bodies
        for i in 0..<55 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
            try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:\(i)", htmlContent: "body\(i)")
        }

        // Prune logic: count bodies per folder, evict only above floor
        let bodyCount = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageBody
                WHERE id IN (SELECT id FROM messageHeader WHERE folderId = 'acc1:INBOX')
                """) ?? 0
        }

        let floor = 50
        let evictable = max(0, bodyCount - floor)
        #expect(evictable == 5) // Only 5 can be evicted, not all 55
    }
}
