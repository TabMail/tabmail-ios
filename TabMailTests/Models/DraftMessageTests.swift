/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DraftMessage")
struct DraftMessageTests {

    @Test("Default init has empty fields")
    func defaults() {
        let draft = DraftMessage()
        #expect(draft.to.isEmpty)
        #expect(draft.cc.isEmpty)
        #expect(draft.bcc.isEmpty)
        #expect(draft.subject == "")
        #expect(draft.body == "")
        #expect(draft.isHTML == false)
        #expect(draft.inReplyTo == nil)
        #expect(draft.references.isEmpty)
        #expect(draft.attachments.isEmpty)
        #expect(draft.messageId == nil)
    }

    @Test("Init with all fields")
    func fullInit() {
        let draft = DraftMessage(
            to: ["a@b.com"],
            cc: ["c@d.com"],
            bcc: ["e@f.com"],
            subject: "Test",
            body: "<p>Hello</p>",
            isHTML: true,
            inReplyTo: "<orig@example.com>",
            references: ["<ref1@example.com>"],
            attachments: [DraftAttachment(filename: "test.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))]
        )
        #expect(draft.to == ["a@b.com"])
        #expect(draft.cc == ["c@d.com"])
        #expect(draft.bcc == ["e@f.com"])
        #expect(draft.subject == "Test")
        #expect(draft.isHTML == true)
        #expect(draft.inReplyTo == "<orig@example.com>")
        #expect(draft.references.count == 1)
        #expect(draft.attachments.count == 1)
    }

    @Test("DraftAttachment isAlternative defaults to false")
    func attachmentIsAlternativeDefault() {
        let att = DraftAttachment(filename: "test.pdf", mimeType: "application/pdf", data: Data())
        #expect(att.isAlternative == false)
    }

    @Test("DraftAttachment isAlternative can be set for ICS")
    func attachmentIsAlternativeICS() {
        let att = DraftAttachment(filename: "invite.ics", mimeType: "text/calendar", data: Data(), isAlternative: true)
        #expect(att.isAlternative == true)
    }

    @Test("OutboxMessage init from DraftMessage with no attachments sets attachmentsDirName to nil")
    func outboxNoAttachments() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDirName == nil)
    }

    @Test("OutboxMessage init from DraftMessage with attachments sets attachmentsDirName to id")
    func outboxWithAttachments() {
        let att = DraftAttachment(filename: "file.txt", mimeType: "text/plain", data: Data("content".utf8))
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello", attachments: [att])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDirName == msg.id)
    }

    @Test("OutboxMessage references JSON round-trip")
    func outboxReferencesRoundTrip() {
        let refs = ["<ref1@test.com>", "<ref2@test.com>", "<ref3@test.com>"]
        let draft = DraftMessage(to: ["a@b.com"], references: refs)
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.references == refs)
    }

    @Test("OutboxMessage references computed setter")
    func outboxReferencesSetter() {
        let draft = DraftMessage(to: ["a@b.com"])
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.references = ["<new@test.com>"]
        #expect(msg.references == ["<new@test.com>"])
    }

    @Test("OutboxMessage to computed setter")
    func outboxToSetter() {
        let draft = DraftMessage(to: ["a@b.com"])
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.to = ["x@y.com", "z@w.com"]
        #expect(msg.to == ["x@y.com", "z@w.com"])
    }

    @Test("OutboxMessage cc computed setter")
    func outboxCcSetter() {
        let draft = DraftMessage(to: ["a@b.com"])
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.cc = ["cc@test.com"]
        #expect(msg.cc == ["cc@test.com"])
    }

    @Test("OutboxMessage bcc computed setter")
    func outboxBccSetter() {
        let draft = DraftMessage(to: ["a@b.com"])
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.bcc = ["bcc@test.com"]
        #expect(msg.bcc == ["bcc@test.com"])
    }

    @Test("OutboxMessage outboxStatus maps all valid raw values")
    func outboxStatusMapping() {
        let draft = DraftMessage(to: ["a@b.com"])
        var msg = OutboxMessage(accountId: "acc1", draft: draft)

        msg.status = "queued"
        #expect(msg.outboxStatus == .queued)

        msg.status = "sending"
        #expect(msg.outboxStatus == .sending)

        msg.status = "failed"
        #expect(msg.outboxStatus == .failed)
    }

    @Test("OutboxMessage outboxStatus falls back to queued for invalid status")
    func outboxStatusFallback() {
        let draft = DraftMessage()
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = "invalid_status"
        #expect(msg.outboxStatus == .queued)
    }

    @Test("OutboxMessage inReplyTo from DraftMessage")
    func outboxInReplyTo() {
        let draft = DraftMessage(to: ["a@b.com"], inReplyTo: "<parent@msg.com>")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.inReplyTo == "<parent@msg.com>")
    }

    @Test("OutboxMessage isHTML from DraftMessage")
    func outboxIsHTML() {
        let draft = DraftMessage(to: ["a@b.com"], body: "<p>HTML</p>", isHTML: true)
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.isHTML == true)
    }

    @Test("OutboxMessage attachmentsDir returns nil when attachmentsDirName is nil")
    func attachmentsDirNil() {
        let draft = DraftMessage(to: ["a@b.com"])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.attachmentsDir == nil)
    }

    @Test("OutboxMessage attachmentsDir returns URL when attachmentsDirName is set")
    func attachmentsDirURL() {
        let att = DraftAttachment(filename: "f.txt", mimeType: "text/plain", data: Data("x".utf8))
        let draft = DraftMessage(to: ["a@b.com"], attachments: [att])
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        let dir = msg.attachmentsDir
        #expect(dir != nil)
        #expect(dir!.lastPathComponent == msg.id)
    }

    @Test("OutboxMessage databaseTableName is outboxMessage")
    func tableNameIsCorrect() {
        #expect(OutboxMessage.databaseTableName == "outboxMessage")
    }

    @Test("DraftAttachment stores data correctly")
    func attachmentDataStorage() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        let att = DraftAttachment(filename: "photo.jpg", mimeType: "image/jpeg", data: data)
        #expect(att.data == data)
        #expect(att.data.count == 4)
    }

    @Test("DraftMessage with only to field set")
    func minimalDraft() {
        let draft = DraftMessage(to: ["recipient@test.com"])
        #expect(draft.to == ["recipient@test.com"])
        #expect(draft.cc.isEmpty)
        #expect(draft.bcc.isEmpty)
        #expect(draft.subject.isEmpty)
        #expect(draft.body.isEmpty)
    }
}
