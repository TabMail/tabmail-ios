/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database MessageAICache")
struct DatabaseAICacheTests {

    @Test("AI cache stores all nullable fields independently")
    func allFieldsIndependent() throws {
        let db = try TestDatabase.make()
        let key = "acc1:INBOX:<msg1@example.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg1@example.com>")
            cache.summaryBlurb = "Brief summary"
            cache.actionTag = .archive
            cache.cachedReply = "Auto reply text"
            try cache.insert(db)
        }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched?.summaryBlurb == "Brief summary")
        #expect(fetched?.actionTag == .archive)
        #expect(fetched?.cachedReply == "Auto reply text")
    }

    @Test("AI cache allows partial updates")
    func partialUpdates() throws {
        let db = try TestDatabase.make()
        let key = "acc1:INBOX:<msg2@example.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg2@example.com>")
            cache.summaryBlurb = "Initial summary"
            try cache.insert(db)
        }

        try db.write { db in
            try db.execute(
                sql: "UPDATE messageAICache SET cachedReply = ? WHERE key = ?",
                arguments: ["New reply", key]
            )
        }

        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched?.summaryBlurb == "Initial summary")
        #expect(fetched?.cachedReply == "New reply")
    }

    @Test("AI cache persists across message header deletion")
    func persistsAcrossHeaderDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<msg@ex.com>")

        let key = "acc1:INBOX:<msg@ex.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg@ex.com>")
            cache.summaryBlurb = "Preserved"
            try cache.insert(db)
        }

        // Delete message header
        try db.write { _ = try MessageHeader.deleteAll($0, keys: ["acc1:INBOX:1"]) }

        // Cache should survive
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched?.summaryBlurb == "Preserved")
    }

    @Test("AI cache delete removes entry")
    func deleteRemovesEntry() throws {
        let db = try TestDatabase.make()
        let key = "acc1:INBOX:<msg@ex.com>"
        try db.write { db in
            var cache = MessageAICache(key: key, rfc822MessageId: "<msg@ex.com>")
            cache.summaryBlurb = "To be deleted"
            try cache.insert(db)
        }

        try db.write { _ = try MessageAICache.deleteOne($0, key: key) }
        let fetched = try db.read { try MessageAICache.fetchOne($0, key: key) }
        #expect(fetched == nil)
    }

    @Test("AI cache multiple entries for different messages")
    func multipleEntries() throws {
        let db = try TestDatabase.make()
        for i in 0..<5 {
            try db.write { db in
                var cache = MessageAICache(key: "key\(i)", rfc822MessageId: "<msg\(i)@ex.com>")
                cache.summaryBlurb = "Summary \(i)"
                try cache.insert(db)
            }
        }

        let count = try db.read { try MessageAICache.fetchCount($0) }
        #expect(count == 5)
    }
}
