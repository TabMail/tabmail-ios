/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Data Integrity Edge Cases")
struct DatabaseDataIntegrityTests {

    @Test("MessageHeader folderId='' allowed post-v2 (optimistic UI)")
    func emptyFolderIdAllowed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Optimistic UI sets folderId="" during archive
        header.folderId = ""
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.folderId == "")
    }

    @Test("MessageHeader with folderId='' can be restored to valid folder")
    func emptyFolderIdRestorable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Archive
        header.folderId = ""
        try db.write { try header.update($0) }

        // Undo: restore
        header.folderId = "acc1:INBOX"
        try db.write { try header.save($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.folderId == "acc1:INBOX")
    }

    @Test("MessageAICache survives full account cascade")
    func aiCacheSurvivesAccountCascade() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "<msg@ex.com>")

        // Insert AI cache (no FK to account)
        try db.write { db in
            var cache = MessageAICache(key: "acc1:INBOX:<msg@ex.com>", rfc822MessageId: "<msg@ex.com>")
            cache.summaryBlurb = "Survived"
            try cache.insert(db)
        }

        // Delete account (cascades headers, folders, etc.)
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        // AI cache is intentionally NOT cascaded
        let cache = try db.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:<msg@ex.com>") }
        #expect(cache?.summaryBlurb == "Survived")
    }

    @Test("INSERT OR IGNORE prevents body overwrite from background queue")
    func insertOrIgnorePreventOverwrite() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        // User opens message — body created
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>User content</p>")

        // Background body render tries INSERT OR IGNORE
        try db.write { db in
            var body = MessageBody( contentKey: ContentKey(rawValue: "acc1:INBOX:1"), htmlContent: "<p>Background content</p>")
            try body.insert(db, onConflict: .ignore)
        }

        // User content preserved
        let fetched = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.htmlContent == "<p>User content</p>")
    }

    @Test("Foreign key enforcement prevents orphan folder")
    func fkPreventsOrphanFolder() throws {
        let db = try TestDatabase.make()
        // No account inserted
        do {
            var folder = Folder(name: "Orphan", path: "Orphan", role: .custom, accountId: "nonexistent")
            try db.write { try folder.insert($0) }
            Issue.record("Expected FK violation")
        } catch {
            // Expected
        }
    }

    @Test("Foreign key enforcement prevents orphan header (invalid accountId)")
    func fkPreventsOrphanHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Try header with non-existent accountId
        do {
            var header = MessageHeader(
                messageId: "1", subject: "Orphan", from: "a@b.com",
                fromAddress: "a@b.com", to: "c@d.com", date: Date(),
                snippet: "", folderId: "acc1:INBOX",
                accountId: "nonexistent", folderPath: "INBOX", isInInbox: true
            )
            try db.write { try header.insert($0) }
            Issue.record("Expected FK violation")
        } catch {
            // Expected
        }
    }

    /// The cascade chain stops at `messageHeader` from Stage D
    /// (`v70_dropMessageBodyHeaderFK`) — see
    /// `DatabaseSchemaValidationTests.cascadeDeleteChain` for why, and
    /// `removeAccountLeavesNoCachedMailBehind` for the production path that reclaims
    /// the body instead.
    @Test("Cascade chain: account → folder → header, and no longer → body")
    func fullCascadeChain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:1", htmlContent: "<p>test</p>")

        // Verify all exist
        #expect(try db.read { try Account.fetchCount($0) } == 1)
        #expect(try db.read { try Folder.fetchCount($0) } == 1)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
        #expect(try db.read { try MessageBody.fetchCount($0) } == 1)

        // Delete account
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        // Header-space rows cascaded…
        #expect(try db.read { try Account.fetchCount($0) } == 0)
        #expect(try db.read { try Folder.fetchCount($0) } == 0)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 0)
        // …and the content row did not ride along.
        #expect(try db.read { try MessageBody.fetchCount($0) } == 1)
    }

    @Test("ChatTurn persists with all fields including sessionId")
    func chatTurnAllFields() throws {
        let db = try TestDatabase.make()

        let turn = ChatTurn(
            id: "t1",
            timestamp: 1234567890.0,
            role: "user",
            content: "Hello",
            userMessage: "Hello from user",
            type: "normal",
            chars: 5,
            renderedContent: "<p>Hello</p>",
            sessionId: "session-abc",
            remindersSnapshot: "[{\"content\":\"test\"}]",
            emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "t1") }
        #expect(fetched?.sessionId == "session-abc")
        #expect(fetched?.remindersSnapshot?.contains("test") == true)
        #expect(fetched?.renderedContent == "<p>Hello</p>")
    }

    @Test("MessageHeader date ordering preserved after update")
    func dateOrderingPreserved() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert 3 messages with different dates
        let now = Date()
        for i in 0..<3 {
            var header = MessageHeader(
                messageId: "\(i)", subject: "Msg \(i)",
                from: "a@b.com", fromAddress: "a@b.com", to: "c@d.com",
                date: now.addingTimeInterval(Double(i) * -3600),
                snippet: "", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            try db.write { try header.insert($0) }
        }

        // Query by date descending
        let ordered = try db.read {
            try MessageHeader.order(Column("date").desc).fetchAll($0)
        }
        #expect(ordered.count == 3)
        #expect(ordered[0].date >= ordered[1].date)
        #expect(ordered[1].date >= ordered[2].date)
    }

    @Test("Concurrent writes to different accounts succeed")
    func concurrentWritesDifferentAccounts() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@test.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@test.com", provider: .imap)
        try TestDatabase.insertFolder(db, accountId: "acc1")
        try TestDatabase.insertFolder(db, accountId: "acc2")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<10 {
                    try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "acc1:INBOX", accountId: "acc1")
                }
            }
            group.addTask {
                for i in 0..<10 {
                    try TestDatabase.insertMessageHeader(db, messageId: "\(i)", folderId: "acc2:INBOX", accountId: "acc2")
                }
            }
            try await group.waitForAll()
        }

        let total = try await db.read { try MessageHeader.fetchCount($0) }
        #expect(total == 20)
    }
}
