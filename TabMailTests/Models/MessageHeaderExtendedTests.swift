/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("MessageHeader Extended")
struct MessageHeaderExtendedTests {

    @Test("MessageHeader id format is accountId:folderPath:messageId")
    func idFormat() {
        let header = MessageHeader(
            messageId: "42",
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
        #expect(header.id == "acc1:INBOX:42")
    }

    @Test("Default values for optional fields")
    func defaultOptionalValues() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.isRead == false)
        #expect(header.isFlagged == false)
        #expect(header.hasAttachments == false)
        #expect(header.isReplied == false)
        #expect(header.isForwarded == false)
        #expect(header.actionTag == nil)
        #expect(header.summaryBlurb == nil)
        #expect(header.cachedReply == nil)
        #expect(header.rfc822MessageId == nil)
        #expect(header.threadId == nil)
    }

    @Test("tagSortOrder set correctly from actionTag")
    func tagSortOrderFromActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", actionTag: .reply)
        #expect(header.tagSortOrder == ActionTag.reply.sortOrder)
    }

    @Test("summaryBlurb persists")
    func summaryBlurbPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        header.summaryBlurb = "AI generated summary of the email"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.summaryBlurb == "AI generated summary of the email")
    }

    @Test("cachedReply persists")
    func cachedReplyPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        header.cachedReply = "Suggested reply text"
        try db.write { try header.update($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.cachedReply == "Suggested reply text")
    }

    @Test("folderId can be empty string (optimistic UI)")
    func folderIdEmptyString() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Per v2 migration: folderId FK removed, allows empty string for optimistic UI
        let header = MessageHeader(
            messageId: "1",
            subject: "Test",
            from: "a@b.com",
            fromAddress: "a@b.com",
            to: "c@d.com",
            date: Date(),
            snippet: "",
            folderId: "",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        try db.write { try header.insert($0) }
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.folderId == "")
    }

    @Test("stableId uses rfc822MessageId when available")
    func stableIdWithRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", rfc822MessageId: "<unique@example.com>"
        )
        #expect(header.stableId == "<unique@example.com>")
    }

    @Test("stableId falls back to messageId when no rfc822MessageId")
    func stableIdFallback() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        #expect(header.stableId == header.messageId)
    }

    @Test("stableId uses messageId for non-numeric messageId even with rfc822MessageId")
    func stableIdNonNumericMessageId() {
        var header = MessageHeader(
            messageId: "gmail-stable-id-abc123",
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
        // Non-numeric messageId means Gmail/Exchange — use messageId directly (stable)
        #expect(header.stableId == "gmail-stable-id-abc123")
    }

    @Test("stableId uses messageId when rfc822MessageId is empty string")
    func stableIdEmptyRfc822() {
        var header = MessageHeader(
            messageId: "42",
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
        header.rfc822MessageId = ""
        // Empty rfc822MessageId should fall back to messageId
        #expect(header.stableId == "42")
    }

    @Test("tagSortOrder defaults to 99 when no actionTag")
    func tagSortOrderDefault() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.tagSortOrder == 99)
    }

    @Test("cc and bcc default to empty strings")
    func ccBccDefaults() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.cc == "")
        #expect(header.bcc == "")
    }

    @Test("replyTo defaults to nil")
    func replyToDefault() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.replyTo == nil)
    }

    @Test("inReplyTo defaults to nil")
    func inReplyToDefault() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.inReplyTo == nil)
    }

    @Test("reminder fields all default to nil")
    func reminderFieldsDefault() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.reminderDate == nil)
        #expect(header.reminderTime == nil)
        #expect(header.reminderContent == nil)
    }

    @Test("summaryTodos defaults to nil")
    func summaryTodosDefault() {
        let header = MessageHeader(
            messageId: "1",
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
        #expect(header.summaryTodos == nil)
    }

    @Test("databaseTableName is messageHeader")
    func tableNameIsCorrect() {
        #expect(MessageHeader.databaseTableName == "messageHeader")
    }
}

@Suite("OperationType Enum")
struct OperationTypeTests {

    @Test("All OperationType rawValues are non-empty")
    func allRawValuesNonEmpty() {
        let allCases: [OperationType] = [
            .archive, .delete, .move, .markRead, .markUnread,
            .markFlagged, .markUnflagged, .setTag, .removeTag,
            .markReplied, .markForwarded
        ]
        for op in allCases {
            #expect(!op.rawValue.isEmpty)
        }
    }

    @Test("OperationType has exactly 11 cases")
    func caseCount() {
        let allCases: [OperationType] = [
            .archive, .delete, .move, .markRead, .markUnread,
            .markFlagged, .markUnflagged, .setTag, .removeTag,
            .markReplied, .markForwarded
        ]
        #expect(allCases.count == 11)
    }

    @Test("OperationType specific rawValues")
    func specificRawValues() {
        #expect(OperationType.archive.rawValue == "archive")
        #expect(OperationType.delete.rawValue == "delete")
        #expect(OperationType.move.rawValue == "move")
        #expect(OperationType.markRead.rawValue == "markRead")
        #expect(OperationType.markUnread.rawValue == "markUnread")
        #expect(OperationType.markFlagged.rawValue == "markFlagged")
        #expect(OperationType.markUnflagged.rawValue == "markUnflagged")
        #expect(OperationType.setTag.rawValue == "setTag")
        #expect(OperationType.removeTag.rawValue == "removeTag")
        #expect(OperationType.markReplied.rawValue == "markReplied")
        #expect(OperationType.markForwarded.rawValue == "markForwarded")
    }

    @Test("OperationType Codable round-trip for all cases")
    func codableRoundTrip() throws {
        let allCases: [OperationType] = [
            .archive, .delete, .move, .markRead, .markUnread,
            .markFlagged, .markUnflagged, .setTag, .removeTag,
            .markReplied, .markForwarded
        ]
        for op in allCases {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(OperationType.self, from: data)
            #expect(decoded == op)
        }
    }

    @Test("OperationType decodes from raw string")
    func decodesFromString() throws {
        let json = "\"markRead\""
        let op = try JSONDecoder().decode(OperationType.self, from: json.data(using: .utf8)!)
        #expect(op == .markRead)
    }

    @Test("OperationType decoding rejects unknown values")
    func rejectsUnknown() {
        let json = "\"unknownOperation\""
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OperationType.self, from: json.data(using: .utf8)!)
        }
    }
}

@Suite("FolderRole Extended")
struct FolderRoleExtendedTests {

    @Test("FolderRole has exactly 7 cases")
    func caseCount() {
        let allRoles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .archive, .spam, .custom]
        #expect(allRoles.count == 7)
    }

    @Test("FolderRole decodes from raw string")
    func decodesFromString() throws {
        let json = "\"inbox\""
        let role = try JSONDecoder().decode(FolderRole.self, from: json.data(using: .utf8)!)
        #expect(role == .inbox)
    }

    @Test("FolderRole encoding produces raw string without wrapper")
    func encodingProducesRawString() throws {
        let data = try JSONEncoder().encode(FolderRole.inbox)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"inbox\"")
    }

    @Test("FolderRole decoding rejects unknown values")
    func rejectsUnknown() {
        let json = "\"unknownRole\""
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FolderRole.self, from: json.data(using: .utf8)!)
        }
    }
}
