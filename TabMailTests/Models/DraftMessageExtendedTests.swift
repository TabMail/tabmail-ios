/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DraftMessage Extended")
struct DraftMessageExtendedTests {

    @Test("Default init has empty arrays and strings")
    func defaultInit() {
        let draft = DraftMessage()
        #expect(draft.to.isEmpty)
        #expect(draft.cc.isEmpty)
        #expect(draft.bcc.isEmpty)
        #expect(draft.subject.isEmpty)
        #expect(draft.body.isEmpty)
        #expect(draft.isHTML == false)
        #expect(draft.inReplyTo == nil)
        #expect(draft.references.isEmpty)
        #expect(draft.attachments.isEmpty)
        #expect(draft.messageId == nil)
    }

    @Test("Full init preserves all fields")
    func fullInit() {
        let draft = DraftMessage(
            to: ["alice@example.com"],
            cc: ["bob@example.com"],
            bcc: ["carol@example.com"],
            subject: "Meeting",
            body: "<p>Hello</p>",
            isHTML: true,
            inReplyTo: "<original@example.com>",
            references: ["<ref1@example.com>", "<ref2@example.com>"]
        )
        #expect(draft.to == ["alice@example.com"])
        #expect(draft.cc == ["bob@example.com"])
        #expect(draft.bcc == ["carol@example.com"])
        #expect(draft.subject == "Meeting")
        #expect(draft.isHTML == true)
        #expect(draft.inReplyTo == "<original@example.com>")
        #expect(draft.references.count == 2)
    }

    @Test("Multiple recipients in to/cc/bcc")
    func multipleRecipients() {
        let draft = DraftMessage(
            to: ["a@b.com", "c@d.com", "e@f.com"],
            cc: ["g@h.com", "i@j.com"],
            bcc: ["k@l.com"]
        )
        #expect(draft.to.count == 3)
        #expect(draft.cc.count == 2)
        #expect(draft.bcc.count == 1)
    }

    @Test("messageId can be pre-set for SMTP/IMAP consistency")
    func presetMessageId() {
        var draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        draft.messageId = "<unique-id@tabmail.ai>"
        #expect(draft.messageId == "<unique-id@tabmail.ai>")
    }
}
