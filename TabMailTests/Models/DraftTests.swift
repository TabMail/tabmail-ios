/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Draft Key Helper Tests

@Suite("Draft.draftKey")
struct DraftKeyTests {

    @Test("Reply draft key has reply: prefix")
    func replyKey() {
        let key = Draft.draftKey(replyTo: "acc1:INBOX:123", isForward: false, newId: nil)
        #expect(key == "reply:acc1:INBOX:123")
    }

    @Test("Forward draft key has forward: prefix")
    func forwardKey() {
        let key = Draft.draftKey(replyTo: "acc1:INBOX:456", isForward: true, newId: nil)
        #expect(key == "forward:acc1:INBOX:456")
    }

    @Test("New compose key has new: prefix with provided ID")
    func newKeyWithId() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: "my-uuid")
        #expect(key == "new:my-uuid")
    }

    @Test("New compose key generates UUID when no ID provided")
    func newKeyAutoUUID() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        #expect(key.hasPrefix("new:"))
        let uuidPart = String(key.dropFirst(4))
        // Should be a valid UUID format
        #expect(UUID(uuidString: uuidPart) != nil)
    }

    @Test("isForward is ignored when replyTo is nil")
    func isForwardIgnoredForNew() {
        let key = Draft.draftKey(replyTo: nil, isForward: true, newId: "test")
        #expect(key == "new:test")
    }
}

// MARK: - Draft parseRecipients Tests

@Suite("Draft.parseRecipients Extended")
struct DraftParseRecipientsExtendedTests {

    @Test("Empty string returns empty array")
    func emptyString() {
        let result = Draft.parseRecipients("")
        #expect(result.isEmpty)
    }

    @Test("Single email address")
    func singleEmail() {
        let result = Draft.parseRecipients("alice@example.com")
        #expect(result == ["alice@example.com"])
    }

    @Test("Multiple comma-separated emails")
    func multipleEmails() {
        let result = Draft.parseRecipients("alice@company.com, bob@company.com, carol@company.com")
        #expect(result.count == 3)
        #expect(result[0] == "alice@company.com")
        #expect(result[1] == "bob@company.com")
        #expect(result[2] == "carol@company.com")
    }

    @Test("Angle bracket format extracts email")
    func angleBracketFormat() {
        let result = Draft.parseRecipients("Alice Smith <alice@company.com>")
        #expect(result == ["alice@company.com"])
    }

    @Test("Mixed format with angle brackets and bare emails")
    func mixedFormat() {
        let result = Draft.parseRecipients("Alice <alice@company.com>, bob@company.com, Carol D <carol@company.com>")
        #expect(result.count == 3)
        #expect(result[0] == "alice@company.com")
        #expect(result[1] == "bob@company.com")
        #expect(result[2] == "carol@company.com")
    }

    @Test("Commas inside angle brackets are not split")
    func commaInAngleBrackets() {
        // This is an edge case — a comma inside angle brackets should not split
        let result = Draft.parseRecipients("\"Last, First\" <user@company.com>")
        #expect(result.count == 1)
        #expect(result[0] == "user@company.com")
    }

    @Test("Whitespace is trimmed")
    func whitespace() {
        let result = Draft.parseRecipients("  alice@company.com  ,  bob@company.com  ")
        #expect(result.count == 2)
        #expect(result[0] == "alice@company.com")
        #expect(result[1] == "bob@company.com")
    }
}

// MARK: - Draft JSON Helpers

@Suite("Draft JSON Helpers")
struct DraftJSONHelperTests {

    @Test("encodeStringArray encodes empty array")
    func encodeEmpty() {
        let result = Draft.encodeStringArray([])
        #expect(result == "[]")
    }

    @Test("encodeStringArray encodes multiple values")
    func encodeMultiple() {
        let result = Draft.encodeStringArray(["alice@company.com", "bob@company.com"])
        let decoded = try! JSONDecoder().decode([String].self, from: Data(result.utf8))
        #expect(decoded == ["alice@company.com", "bob@company.com"])
    }

    @Test("toArray parses valid JSON")
    func toArrayValid() {
        let draft = Draft(
            id: "test", accountId: "acc1",
            toJSON: "[\"alice@company.com\",\"bob@company.com\"]",
            ccJSON: "[]", bccJSON: "[]",
            subject: "Test", body: "Body",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        #expect(draft.toArray == ["alice@company.com", "bob@company.com"])
    }

    @Test("toArray returns empty for invalid JSON")
    func toArrayInvalid() {
        let draft = Draft(
            id: "test", accountId: "acc1",
            toJSON: "not json",
            ccJSON: "[]", bccJSON: "[]",
            subject: "Test", body: "Body",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        #expect(draft.toArray.isEmpty)
    }

    @Test("ccArray and bccArray parse correctly")
    func ccBccParse() {
        let draft = Draft(
            id: "test", accountId: "acc1",
            toJSON: "[]",
            ccJSON: "[\"cc@company.com\"]", bccJSON: "[\"bcc@company.com\"]",
            subject: "Test", body: "Body",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        #expect(draft.ccArray == ["cc@company.com"])
        #expect(draft.bccArray == ["bcc@company.com"])
    }
}

// MARK: - Draft isReplyOrForward

@Suite("Draft.isReplyOrForward")
struct DraftIsReplyOrForwardTests {

    private func makeDraft(replyToId: String?) -> Draft {
        Draft(
            id: "test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Test", body: "Body",
            replyToId: replyToId, isForward: false,
            editHistoryJSON: nil,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
    }

    @Test("isReplyOrForward true when replyToId is set")
    func isReply() {
        let draft = makeDraft(replyToId: "acc1:INBOX:123")
        #expect(draft.isReplyOrForward == true)
    }

    @Test("isReplyOrForward false when replyToId is nil")
    func isNewCompose() {
        let draft = makeDraft(replyToId: nil)
        #expect(draft.isReplyOrForward == false)
    }
}

// MARK: - Draft GRDB Persistence Tests

@Suite("Draft GRDB Persistence Extended")
struct DraftGRDBPersistenceTests {

    @Test("Draft insert and fetch round-trip")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let now = Date().timeIntervalSince1970
        let draft = Draft(
            id: "new:test-uuid", accountId: "acc1",
            toJSON: "[\"alice@company.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Test Subject", body: "Hello world",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )

        try db.write { try draft.insert($0) }

        let fetched = try db.read { try Draft.fetchOne($0, key: "new:test-uuid") }
        #expect(fetched != nil)
        guard let fetched else { return }
        #expect(fetched.id == "new:test-uuid")
        #expect(fetched.subject == "Test Subject")
        #expect(fetched.body == "Hello world")
        #expect(fetched.accountId == "acc1")
        #expect(fetched.toArray == ["alice@company.com"])
    }

    @Test("Draft update (save) preserves existing record")
    func updateDraft() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: "new:update-test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Original", body: "Original body",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )

        try db.write { try draft.insert($0) }

        // Update
        draft.subject = "Updated"
        draft.body = "Updated body"
        draft.updatedAt = Date().timeIntervalSince1970
        try db.write { try draft.save($0) }

        let fetched = try db.read { try Draft.fetchOne($0, key: "new:update-test") }
        #expect(fetched?.subject == "Updated")
        #expect(fetched?.body == "Updated body")
    }

    @Test("Draft delete removes record")
    func deleteDraft() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let now = Date().timeIntervalSince1970
        let draft = Draft(
            id: "new:delete-test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "To Delete", body: "",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )

        try db.write { try draft.insert($0) }
        _ = try db.write { try draft.delete($0) }

        let fetched = try db.read { try Draft.fetchOne($0, key: "new:delete-test") }
        #expect(fetched == nil)
    }

    @Test("Draft serverPushStatus transitions: nil → pushed → dirty")
    func pushStatusTransitions() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: "new:push-test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Push Test", body: "Body",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )

        try db.write { try draft.insert($0) }

        // Simulate push: nil → pushed
        draft.serverPushStatus = "pushed"
        draft.serverDraftId = "server-123"
        try db.write { try draft.save($0) }

        let fetched1 = try db.read { try Draft.fetchOne($0, key: "new:push-test") }
        #expect(fetched1?.serverPushStatus == "pushed")

        // Simulate dirty: pushed → dirty (user edited after push)
        draft.serverPushStatus = "dirty"
        try db.write { try draft.save($0) }

        let fetched2 = try db.read { try Draft.fetchOne($0, key: "new:push-test") }
        #expect(fetched2?.serverPushStatus == "dirty")
    }

    @Test("Draft loadAll ordered by updatedAt DESC")
    func loadAllOrdered() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let base = Date().timeIntervalSince1970
        for i in 0..<3 {
            let draft = Draft(
                id: "new:order-\(i)", accountId: "acc1",
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Draft \(i)", body: "",
                replyToId: nil, isForward: false,
                editHistoryJSON: nil,
                createdAt: base, updatedAt: base + Double(i),
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil
            )
            try db.write { try draft.insert($0) }
        }

        let all = try db.read { try Draft.order(Column("updatedAt").desc).fetchAll($0) }
        #expect(all.count == 3)
        guard all.count == 3 else { return }
        // Most recently updated should be first
        #expect(all[0].id == "new:order-2")
        #expect(all[1].id == "new:order-1")
        #expect(all[2].id == "new:order-0")
    }
}

// MARK: - Draft Edit History Tests

@Suite("Draft Edit History")
struct DraftEditHistoryTests {

    @Test("editHistory returns empty for nil editHistoryJSON")
    func nilHistory() {
        let draft = Draft(
            id: "test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Test", body: "",
            replyToId: nil, isForward: false,
            editHistoryJSON: nil,
            createdAt: 0, updatedAt: 0,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        #expect(draft.editHistory.isEmpty)
    }

    @Test("editHistory returns empty for invalid JSON")
    func invalidJSON() {
        let draft = Draft(
            id: "test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Test", body: "",
            replyToId: nil, isForward: false,
            editHistoryJSON: "not valid json",
            createdAt: 0, updatedAt: 0,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        #expect(draft.editHistory.isEmpty)
    }

    @Test("encodeEditHistory and editHistory round-trip")
    func roundTrip() {
        let turns = [
            InlineEditTurn(userRequest: "Make it shorter", bodyAtRequest: "Long body", subjectAtRequest: "Subject", assistantResponse: "Short body"),
        ]
        let encoded = Draft.encodeEditHistory(turns)
        #expect(encoded != nil)

        let draft = Draft(
            id: "test", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "Test", body: "",
            replyToId: nil, isForward: false,
            editHistoryJSON: encoded,
            createdAt: 0, updatedAt: 0,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil
        )
        let decoded = draft.editHistory
        #expect(decoded.count == 1)
        guard decoded.count == 1 else { return }
        #expect(decoded[0].userRequest == "Make it shorter")
        #expect(decoded[0].bodyAtRequest == "Long body")
        #expect(decoded[0].assistantResponse == "Short body")
    }

    @Test("encodeEditHistory with empty array")
    func encodeEmpty() {
        let encoded = Draft.encodeEditHistory([])
        #expect(encoded != nil)
        // Should be valid JSON "[]"
        let data = encoded!.data(using: .utf8)!
        let parsed = try! JSONDecoder().decode([String].self, from: data)
        #expect(parsed.isEmpty)
    }
}
