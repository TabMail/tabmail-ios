/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("OutboxMessage Persistence")
struct OutboxMessagePersistenceTests {

    // MARK: - Basic GRDB persistence

    @Test("Insert and fetch by id")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(
            to: ["a@b.com"],
            cc: ["c@d.com"],
            bcc: ["e@f.com"],
            subject: "Test",
            body: "Hello world",
            isHTML: false,
            inReplyTo: "<orig@example.com>",
            references: ["<ref1@example.com>", "<ref2@example.com>"]
        )
        let msg = OutboxMessage(accountId: "acc1", draft: draft, originalMessageHeaderId: "hdr-1", isForward: true)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched != nil)
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.to == ["a@b.com"])
        #expect(fetched?.cc == ["c@d.com"])
        #expect(fetched?.bcc == ["e@f.com"])
        #expect(fetched?.subject == "Test")
        #expect(fetched?.body == "Hello world")
        #expect(fetched?.isHTML == false)
        #expect(fetched?.inReplyTo == "<orig@example.com>")
        #expect(fetched?.references == ["<ref1@example.com>", "<ref2@example.com>"])
        #expect(fetched?.originalMessageHeaderId == "hdr-1")
        #expect(fetched?.isForward == true)
        #expect(fetched?.outboxStatus == .queued)
        #expect(fetched?.retryCount == 0)
        #expect(fetched?.sentAt == nil)
        #expect(fetched?.sentMessageId == nil)
        #expect(fetched?.appendedToSent == false)
    }

    @Test("Delete from database")
    func deleteFromDb() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Del", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        _ = try db.write { try msg.delete($0) }
        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched == nil)
    }

    @Test("Fetch all for account")
    func fetchAllForAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")

        let d1 = DraftMessage(to: ["a@b.com"], subject: "One", body: "Body1")
        let d2 = DraftMessage(to: ["a@b.com"], subject: "Two", body: "Body2")
        let d3 = DraftMessage(to: ["a@b.com"], subject: "Three", body: "Body3")
        try db.write {
            try OutboxMessage(accountId: "acc1", draft: d1).insert($0)
            try OutboxMessage(accountId: "acc1", draft: d2).insert($0)
            try OutboxMessage(accountId: "acc2", draft: d3).insert($0)
        }

        let acc1Messages = try db.read {
            try OutboxMessage.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Messages.count == 2)

        let acc2Messages = try db.read {
            try OutboxMessage.filter(Column("accountId") == "acc2").fetchAll($0)
        }
        #expect(acc2Messages.count == 1)
    }

    // MARK: - sentAt / sentMessageId / appendedToSent persistence

    @Test("sentAt persists through update")
    func sentAtPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Sent", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let sentDate = Date()
        msg.sentAt = sentDate
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
    }

    @Test("sentMessageId persists through update")
    func sentMessageIdPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Sent", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        msg.sentMessageId = "<generated-uuid@tabmail.ai>"
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentMessageId == "<generated-uuid@tabmail.ai>")
    }

    @Test("appendedToSent persists through update")
    func appendedToSentPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Sent", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        msg.appendedToSent = true
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.appendedToSent == true)
    }

    // MARK: - Computed properties

    @Test("references computed property setter round-trip")
    func referencesSetterRoundTrip() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.references = ["<ref-a@mail.com>", "<ref-b@mail.com>", "<ref-c@mail.com>"]
        #expect(msg.references == ["<ref-a@mail.com>", "<ref-b@mail.com>", "<ref-c@mail.com>"])
    }

    @Test("to setter updates toJSON")
    func toSetterUpdatesJSON() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.to = ["x@y.com", "z@w.com"]
        #expect(msg.to == ["x@y.com", "z@w.com"])
    }

    @Test("cc setter updates ccJSON")
    func ccSetterUpdatesJSON() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.cc = ["cc@mail.com"]
        #expect(msg.cc == ["cc@mail.com"])
    }

    @Test("bcc setter updates bccJSON")
    func bccSetterUpdatesJSON() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.bcc = ["bcc@secret.com"]
        #expect(msg.bcc == ["bcc@secret.com"])
    }

    @Test("outboxStatus maps all valid raw values")
    func outboxStatusAllValues() {
        let draft = DraftMessage(to: ["a@b.com"])
        var msg = OutboxMessage(accountId: "acc1", draft: draft)

        msg.status = "queued"
        #expect(msg.outboxStatus == .queued)

        msg.status = "sending"
        #expect(msg.outboxStatus == .sending)

        msg.status = "failed"
        #expect(msg.outboxStatus == .failed)
    }

    // MARK: - attachmentsDirName

    @Test("attachmentsDirName is nil when draft has no attachments")
    func attachmentsDirNilNoAttachments() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDirName == nil)
    }

    @Test("attachmentsDirName is set when draft has attachments")
    func attachmentsDirSetWithAttachments() {
        let attachment = DraftAttachment(filename: "doc.pdf", mimeType: "application/pdf", data: Data([0x01, 0x02]))
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body", attachments: [attachment])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDirName == msg.id)
    }

    @Test("attachmentsDir returns nil when attachmentsDirName is nil")
    func attachmentsDirNilProperty() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDir == nil)
    }

    @Test("attachmentsDir returns URL when attachmentsDirName is set")
    func attachmentsDirReturnsURL() {
        let attachment = DraftAttachment(filename: "doc.pdf", mimeType: "application/pdf", data: Data([0x01]))
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body", attachments: [attachment])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        let dir = msg.attachmentsDir
        #expect(dir != nil)
        #expect(dir?.lastPathComponent == msg.id)
    }

    // MARK: - toDraftMessage (without disk attachments)

    @Test("toDraftMessage round-trips fields (no attachments)")
    func toDraftMessageRoundTrip() throws {
        let draft = DraftMessage(
            to: ["a@b.com", "c@d.com"],
            cc: ["e@f.com"],
            bcc: ["g@h.com"],
            subject: "Round trip",
            body: "<p>HTML body</p>",
            isHTML: true,
            inReplyTo: "<orig@test.com>",
            references: ["<ref1@test.com>"]
        )
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        let restored = try msg.toDraftMessage()

        #expect(restored.to == ["a@b.com", "c@d.com"])
        #expect(restored.cc == ["e@f.com"])
        #expect(restored.bcc == ["g@h.com"])
        #expect(restored.subject == "Round trip")
        #expect(restored.body == "<p>HTML body</p>")
        #expect(restored.isHTML == true)
        #expect(restored.inReplyTo == "<orig@test.com>")
        #expect(restored.references == ["<ref1@test.com>"])
        #expect(restored.attachments.isEmpty)
    }

    // MARK: - Edge cases

    @Test("Empty to array")
    func emptyToArray() {
        let draft = DraftMessage(to: [], subject: "No recipients", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.to.isEmpty)
    }

    @Test("Empty subject and body")
    func emptySubjectAndBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "", body: "")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.subject == "")
        #expect(fetched?.body == "")
    }

    @Test("References empty array round-trip")
    func referencesEmptyArray() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body", references: [])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.references.isEmpty)
    }

    @Test("databaseTableName is outboxMessage")
    func tableName() {
        #expect(OutboxMessage.databaseTableName == "outboxMessage")
    }

    @Test("errorMessage persists")
    func errorMessagePersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Err", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = OutboxStatus.failed.rawValue
        msg.errorMessage = "SMTP connection timeout after 30s"
        msg.retryCount = 3
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.errorMessage == "SMTP connection timeout after 30s")
        #expect(fetched?.retryCount == 3)
        #expect(fetched?.outboxStatus == .failed)
    }

    @Test("isHTML false for plain text messages")
    func isHTMLFalse() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Plain", body: "Just text", isHTML: false)
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.isHTML == false)
    }

    @Test("isHTML true for HTML messages")
    func isHTMLTrue() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Rich", body: "<b>Bold</b>", isHTML: true)
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.isHTML == true)
    }

    @Test("Full lifecycle: queued → sending → sentAt stamped → appendedToSent → delete")
    func fullLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Lifecycle", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }
        #expect(msg.outboxStatus == .queued)

        // Sending
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }

        // SMTP succeeded — stamp sentAt first (double-send firewall)
        msg.sentAt = Date()
        msg.sentMessageId = "<sent-id@tabmail.ai>"
        try db.write { try msg.update($0) }

        // Appended to Sent folder
        msg.appendedToSent = true
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
        #expect(fetched?.sentMessageId == "<sent-id@tabmail.ai>")
        #expect(fetched?.appendedToSent == true)

        // Delete after fully completed
        _ = try db.write { try msg.delete($0) }
        let deleted = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(deleted == nil)
    }

    @Test("Filter queued messages only")
    func filterQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var m1 = OutboxMessage(accountId: "acc1", draft: DraftMessage(to: ["a@b.com"], subject: "Q1", body: ""))
        var m2 = OutboxMessage(accountId: "acc1", draft: DraftMessage(to: ["a@b.com"], subject: "S1", body: ""))
        m2.status = OutboxStatus.sending.rawValue
        var m3 = OutboxMessage(accountId: "acc1", draft: DraftMessage(to: ["a@b.com"], subject: "F1", body: ""))
        m3.status = OutboxStatus.failed.rawValue

        try db.write {
            try m1.insert($0)
            try m2.insert($0)
            try m3.insert($0)
        }

        let queued = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.queued.rawValue).fetchAll($0)
        }
        #expect(queued.count == 1)
        #expect(queued.first?.subject == "Q1")
    }

    @Test("inReplyTo nil when not a reply")
    func inReplyToNilForNewMessage() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "New", body: "Fresh message")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.inReplyTo == nil)
    }

    @Test("originalMessageHeaderId nil when not a reply")
    func originalMessageHeaderIdNilForNewMessage() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "New", body: "Fresh message")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.originalMessageHeaderId == nil)
    }
}
