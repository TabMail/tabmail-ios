/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DraftMessage Edge Cases")
struct DraftMessageEdgeCaseTests {

    @Test("Default init has empty arrays")
    func defaultInit() {
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

    @Test("Full init preserves all fields")
    func fullInit() {
        let draft = DraftMessage(
            to: ["a@b.com", "c@d.com"],
            cc: ["e@f.com"],
            bcc: ["g@h.com"],
            subject: "Test Subject",
            body: "<p>HTML body</p>",
            isHTML: true,
            inReplyTo: "<original@test.com>",
            references: ["<ref1@test.com>", "<ref2@test.com>"]
        )
        #expect(draft.to.count == 2)
        #expect(draft.cc.count == 1)
        #expect(draft.bcc.count == 1)
        #expect(draft.subject == "Test Subject")
        #expect(draft.body == "<p>HTML body</p>")
        #expect(draft.isHTML == true)
        #expect(draft.inReplyTo == "<original@test.com>")
        #expect(draft.references.count == 2)
    }

    @Test("DraftMessage is Sendable")
    func isSendable() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "S", body: "B")
        // Prove Sendable by sending across isolation boundary
        let _: any Sendable = draft
    }

    @Test("messageId field can be set")
    func messageIdField() {
        var draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        draft.messageId = "<custom-id@tabmail.ai>"
        #expect(draft.messageId == "<custom-id@tabmail.ai>")
    }

    @Test("Empty subject is valid")
    func emptySubject() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "", body: "Body")
        #expect(draft.subject.isEmpty)
    }

    @Test("Body with special characters")
    func bodySpecialChars() {
        let body = "Hello <world> & 'friends' \"everyone\" ñoño"
        let draft = DraftMessage(to: ["a@b.com"], subject: "S", body: body)
        #expect(draft.body == body)
    }

    @Test("Large recipient list")
    func largeRecipientList() {
        let recipients = (0..<100).map { "user\($0)@test.com" }
        let draft = DraftMessage(to: recipients, subject: "Mass email", body: "Hi all")
        #expect(draft.to.count == 100)
    }

    @Test("References list preserves order")
    func referencesOrder() {
        let refs = ["<a@t.com>", "<b@t.com>", "<c@t.com>"]
        let draft = DraftMessage(references: refs)
        #expect(draft.references == refs)
    }
}

@Suite("DraftAttachment")
struct DraftAttachmentTests {

    @Test("Init stores all fields")
    func initFields() {
        let data = Data("test content".utf8)
        let att = DraftAttachment(filename: "test.pdf", mimeType: "application/pdf", data: data)
        #expect(att.filename == "test.pdf")
        #expect(att.mimeType == "application/pdf")
        #expect(att.data == data)
        #expect(att.isAlternative == false)
    }

    @Test("isAlternative for ICS calendar invitations")
    func isAlternative() {
        let data = Data("BEGIN:VCALENDAR".utf8)
        var att = DraftAttachment(filename: "invite.ics", mimeType: "text/calendar", data: data)
        att.isAlternative = true
        #expect(att.isAlternative == true)
    }

    @Test("DraftAttachment is Sendable")
    func isSendable() {
        let att = DraftAttachment(filename: "f", mimeType: "t", data: Data())
        let _: any Sendable = att
    }

    @Test("Empty data is valid")
    func emptyData() {
        let att = DraftAttachment(filename: "empty.txt", mimeType: "text/plain", data: Data())
        #expect(att.data.isEmpty)
    }
}
