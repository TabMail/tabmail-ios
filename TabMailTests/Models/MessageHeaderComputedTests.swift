/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageHeader Computed Properties & Codable")
struct MessageHeaderComputedTests {

    // MARK: - Codable round-trip

    @Test("MessageHeader Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var header = MessageHeader(
            messageId: "42",
            subject: "Important Meeting",
            from: "Alice Smith",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: Date(timeIntervalSince1970: 1700000000),
            snippet: "Let's discuss the Q4 budget...",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.cc = "carol@example.com"
        header.bcc = "dave@example.com"
        header.replyTo = "alice-reply@example.com"
        header.rfc822MessageId = "<msg42@example.com>"
        header.inReplyTo = "<msg41@example.com>"
        header.threadId = "thread-abc"
        header.isRead = true
        header.isFlagged = true
        header.hasAttachments = true
        header.isReplied = true
        header.isForwarded = true
        header.actionTag = .archive
        header.tagSortOrder = ActionTag.archive.sortOrder
        header.summaryBlurb = "Budget discussion"
        header.summaryTodos = "• Review slides • Send notes"
        header.reminderDate = "2024-03-20"
        header.reminderTime = "14:00"
        header.reminderContent = "Follow up on budget"
        header.cachedReply = "Thanks for the update."

        let encoder = JSONEncoder()
        let data = try encoder.encode(header)
        let decoded = try JSONDecoder().decode(MessageHeader.self, from: data)

        #expect(decoded.id == header.id)
        #expect(decoded.messageId == "42")
        #expect(decoded.subject == "Important Meeting")
        #expect(decoded.from == "Alice Smith")
        #expect(decoded.fromAddress == "alice@example.com")
        #expect(decoded.to == "bob@example.com")
        #expect(decoded.cc == "carol@example.com")
        #expect(decoded.bcc == "dave@example.com")
        #expect(decoded.replyTo == "alice-reply@example.com")
        #expect(decoded.rfc822MessageId == "<msg42@example.com>")
        #expect(decoded.inReplyTo == "<msg41@example.com>")
        #expect(decoded.threadId == "thread-abc")
        #expect(decoded.folderId == "acc1:INBOX")
        #expect(decoded.accountId == "acc1")
        #expect(decoded.folderPath == "INBOX")
        #expect(decoded.isInInbox == true)
        #expect(decoded.isRead == true)
        #expect(decoded.isFlagged == true)
        #expect(decoded.hasAttachments == true)
        #expect(decoded.isReplied == true)
        #expect(decoded.isForwarded == true)
        #expect(decoded.actionTag == .archive)
        #expect(decoded.tagSortOrder == 2)
        #expect(decoded.summaryBlurb == "Budget discussion")
        #expect(decoded.summaryTodos == "• Review slides • Send notes")
        #expect(decoded.reminderDate == "2024-03-20")
        #expect(decoded.reminderTime == "14:00")
        #expect(decoded.reminderContent == "Follow up on budget")
        #expect(decoded.cachedReply == "Thanks for the update.")
    }

    @Test("MessageHeader Codable round-trip with nil optional fields")
    func codableRoundTripNils() throws {
        let header = MessageHeader(
            messageId: "1",
            subject: "",
            from: "",
            fromAddress: "",
            to: "",
            date: Date(timeIntervalSince1970: 0),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: false
        )

        let data = try JSONEncoder().encode(header)
        let decoded = try JSONDecoder().decode(MessageHeader.self, from: data)

        #expect(decoded.rfc822MessageId == nil)
        #expect(decoded.inReplyTo == nil)
        #expect(decoded.threadId == nil)
        #expect(decoded.replyTo == nil)
        #expect(decoded.actionTag == nil)
        #expect(decoded.summaryBlurb == nil)
        #expect(decoded.summaryTodos == nil)
        #expect(decoded.reminderDate == nil)
        #expect(decoded.reminderTime == nil)
        #expect(decoded.reminderContent == nil)
        #expect(decoded.cachedReply == nil)
    }

    // MARK: - stableId edge cases

    @Test("stableId with UInt32.max boundary messageId uses rfc822MessageId")
    func stableIdUInt32Max() {
        var header = MessageHeader(
            messageId: "4294967295", // UInt32.max
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<boundary@example.com>"
        #expect(header.stableId == "<boundary@example.com>")
    }

    @Test("stableId with messageId just beyond UInt32 range uses messageId")
    func stableIdBeyondUInt32() {
        var header = MessageHeader(
            messageId: "4294967296", // UInt32.max + 1
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<rfc@example.com>"
        // 4294967296 overflows UInt32 → UInt32() returns nil → uses messageId
        #expect(header.stableId == "4294967296")
    }

    @Test("stableId with messageId 0 and rfc822MessageId uses rfc822MessageId")
    func stableIdZeroUid() {
        var header = MessageHeader(
            messageId: "0",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<zero@example.com>"
        #expect(header.stableId == "<zero@example.com>")
    }

    @Test("stableId with negative-looking messageId uses messageId (not numeric UID)")
    func stableIdNegative() {
        var header = MessageHeader(
            messageId: "-1",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.rfc822MessageId = "<neg@example.com>"
        // -1 is not a valid UInt32 → uses messageId
        #expect(header.stableId == "-1")
    }

    // MARK: - GRDB persistence of fields not covered by existing tests

    @Test("isReplied and isForwarded persist through GRDB")
    func repliedForwardedPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.isReplied = true
        header.isForwarded = true
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.isReplied == true)
        #expect(fetched?.isForwarded == true)
    }

    @Test("hasAttachments persists through GRDB")
    func hasAttachmentsPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.hasAttachments = true
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.hasAttachments == true)
    }

    @Test("replyTo and inReplyTo persist through GRDB")
    func replyToInReplyToPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.replyTo = "replyto@example.com"
        header.inReplyTo = "<parent-msg@example.com>"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.replyTo == "replyto@example.com")
        #expect(fetched?.inReplyTo == "<parent-msg@example.com>")
    }

    @Test("threadId persists through GRDB")
    func threadIdPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.threadId = "thread-xyz-999"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.threadId == "thread-xyz-999")
    }

    @Test("cc and bcc persist through GRDB")
    func ccBccPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        header.cc = "carol@example.com, dave@example.com"
        header.bcc = "eve@example.com"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cc == "carol@example.com, dave@example.com")
        #expect(fetched?.bcc == "eve@example.com")
    }

    // MARK: - ActionTag optional decoding in MessageHeader context

    @Test("MessageHeader with nil actionTag decodes correctly")
    func nilActionTagDecodes() throws {
        let header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(timeIntervalSince1970: 1000),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        let data = try JSONEncoder().encode(header)
        let decoded = try JSONDecoder().decode(MessageHeader.self, from: data)
        #expect(decoded.actionTag == nil)
        #expect(decoded.tagSortOrder == 99)
    }

    @Test("MessageHeader with each actionTag case round-trips via Codable")
    func actionTagCasesRoundTrip() throws {
        for tag in ActionTag.allCases {
            var header = MessageHeader(
                messageId: "tag-\(tag.rawValue)",
                subject: "Test",
                from: "a@b.com",
                fromAddress: "a@b.com",
                to: "c@d.com",
                date: Date(timeIntervalSince1970: 1000),
                snippet: "",
                folderId: "acc1:INBOX",
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            header.actionTag = tag
            header.tagSortOrder = tag.sortOrder

            let data = try JSONEncoder().encode(header)
            let decoded = try JSONDecoder().decode(MessageHeader.self, from: data)
            #expect(decoded.actionTag == tag)
            #expect(decoded.tagSortOrder == tag.sortOrder)
        }
    }

    // MARK: - ID construction edge cases

    @Test("ID with special characters in folderPath")
    func idSpecialCharsInPath() {
        let header = MessageHeader(
            messageId: "100",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX/Sub Folder/Nested",
            accountId: "acc1",
            folderPath: "INBOX/Sub Folder/Nested",
            isInInbox: false
        )
        #expect(header.id == "acc1:INBOX/Sub Folder/Nested:100")
    }

    @Test("ID with empty folderPath")
    func idEmptyFolderPath() {
        let header = MessageHeader(
            messageId: "100",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "",
            accountId: "acc1",
            folderPath: "",
            isInInbox: false
        )
        #expect(header.id == "acc1::100")
    }
}
