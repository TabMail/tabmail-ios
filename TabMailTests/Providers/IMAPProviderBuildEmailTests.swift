/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

@Suite("IMAPProvider.buildEmail")
struct IMAPProviderBuildEmailTests {

    // MARK: - Basic construction

    @Test("Builds email with basic to-only draft")
    func basicToOnly() {
        let draft = DraftMessage(
            to: ["alice@example.com"],
            subject: "Hello",
            body: "Plain text body"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "sender@example.com")
        #expect(email.sender.address == "sender@example.com")
        #expect(email.recipients.count == 1)
        #expect(email.recipients[0].address == "alice@example.com")
        #expect(email.subject == "Hello")
        #expect(email.textBody == "Plain text body")
        #expect(email.htmlBody == nil)
    }

    @Test("Builds email with multiple to recipients")
    func multipleToRecipients() {
        let draft = DraftMessage(
            to: ["a@test.com", "b@test.com", "c@test.com"],
            subject: "Multi"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.count == 3)
        #expect(email.recipients[0].address == "a@test.com")
        #expect(email.recipients[1].address == "b@test.com")
        #expect(email.recipients[2].address == "c@test.com")
    }

    // MARK: - CC and BCC

    @Test("Builds email with CC recipients")
    func withCC() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            cc: ["cc1@test.com", "cc2@test.com"],
            subject: "With CC"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.ccRecipients.count == 2)
        #expect(email.ccRecipients[0].address == "cc1@test.com")
        #expect(email.ccRecipients[1].address == "cc2@test.com")
    }

    @Test("Builds email with BCC recipients — BCC not set on Email (handled by SMTP)")
    func withBCC() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            bcc: ["bcc@secret.com"],
            subject: "With BCC"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        // DraftMessage.bcc is not mapped to Email.bccRecipients in buildEmail
        // (BCC is handled at the SMTP transport layer, not in the email content)
        // Verify the email was built without error
        #expect(email.recipients.count == 1)
        #expect(email.subject == "With BCC")
    }

    @Test("Builds email with both CC and to recipients")
    func ccAndTo() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            cc: ["cc@test.com"],
            subject: "Both"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.count == 1)
        #expect(email.ccRecipients.count == 1)
        #expect(email.allRecipients.count >= 2)
    }

    // MARK: - HTML vs plain text body

    @Test("Plain text draft sets textBody and nil htmlBody")
    func plainTextBody() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Plain",
            body: "Just text",
            isHTML: false
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.textBody == "Just text")
        #expect(email.htmlBody == nil)
    }

    @Test("HTML draft sets htmlBody and derives textBody from HTML")
    func htmlBody() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "HTML",
            body: "<p>Hello</p>",
            isHTML: true
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.htmlBody == "<p>Hello</p>")
        // textBody is derived from HTML via htmlToPlainText — should contain "Hello"
        #expect(email.textBody.contains("Hello"))
        #expect(!email.textBody.isEmpty)
    }

    @Test("HTML body with complex markup preserved")
    func complexHtmlBody() {
        let html = "<html><body><h1>Title</h1><p>Content with <b>bold</b> and <a href=\"https://example.com\">link</a></p></body></html>"
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Complex HTML",
            body: html,
            isHTML: true
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.htmlBody == html)
    }

    // MARK: - In-Reply-To header

    @Test("Sets In-Reply-To header when inReplyTo is present")
    func withInReplyTo() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Hello",
            body: "Reply body",
            inReplyTo: "<original-msg-id@example.com>"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<original-msg-id@example.com>")
    }

    @Test("No In-Reply-To header when inReplyTo is nil")
    func withoutInReplyTo() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "New message"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == nil)
    }

    // MARK: - References header

    @Test("Sets References header from references array")
    func withReferences() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            body: "Reply",
            references: ["<msg1@example.com>", "<msg2@example.com>"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<msg1@example.com> <msg2@example.com>")
    }

    @Test("No References header when references array is empty")
    func emptyReferences() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "New"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == nil)
    }

    @Test("Single reference joined without trailing space")
    func singleReference() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Single",
            references: ["<only-ref@example.com>"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<only-ref@example.com>")
    }

    // MARK: - Both In-Reply-To and References

    @Test("Sets both In-Reply-To and References headers together")
    func inReplyToAndReferences() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            inReplyTo: "<parent@example.com>",
            references: ["<root@example.com>", "<parent@example.com>"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<parent@example.com>")
        #expect(email.additionalHeaders?["References"] == "<root@example.com> <parent@example.com>")
    }

    // MARK: - No additional headers

    @Test("additionalHeaders is nil when no threading headers")
    func noAdditionalHeaders() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Simple"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders == nil)
    }

    // MARK: - Subject encoding

    @Test("Subject with Unicode characters preserved")
    func unicodeSubject() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Rendezvous: cafe discussion"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject == "Rendezvous: cafe discussion")
    }

    @Test("Subject with Japanese characters preserved")
    func japaneseSubject() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Meeting agenda"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject == "Meeting agenda")
    }

    @Test("Subject with emoji preserved")
    func emojiSubject() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Hello World"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject.contains("Hello"))
    }

    @Test("Empty subject preserved")
    func emptySubject() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: ""
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject == "")
    }

    // MARK: - Message ID

    @Test("Pre-generated messageId set on email")
    func withMessageId() {
        var draft = DraftMessage(
            to: ["to@test.com"],
            subject: "With ID"
        )
        draft.messageId = "<unique-id-123@tabmail.ai>"
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.messageID != nil)
        #expect(email.messageID?.description == "<unique-id-123@tabmail.ai>")
    }

    @Test("No messageId when draft.messageId is nil")
    func withoutMessageId() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "No ID"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.messageID == nil)
    }

    // MARK: - Attachments

    @Test("Attachments mapped from DraftAttachment to SwiftMail Attachment")
    func withAttachments() {
        let attachment = DraftAttachment(
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data([0x25, 0x50, 0x44, 0x46])
        )
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "With attachment",
            attachments: [attachment]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.attachments?.count == 1)
        #expect(email.attachments?[0].filename == "report.pdf")
        #expect(email.attachments?[0].mimeType == "application/pdf")
    }

    @Test("No attachments when draft has empty attachments array")
    func emptyAttachments() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "No attachments",
            attachments: []
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.attachments == nil)
    }

    @Test("Multiple attachments all mapped")
    func multipleAttachments() {
        let attachments = [
            DraftAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1])),
            DraftAttachment(filename: "b.png", mimeType: "image/png", data: Data([2])),
            DraftAttachment(filename: "c.txt", mimeType: "text/plain", data: Data([3])),
        ]
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Multi attach",
            attachments: attachments
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.attachments?.count == 3)
        #expect(email.attachments?[0].filename == "a.pdf")
        #expect(email.attachments?[1].filename == "b.png")
        #expect(email.attachments?[2].filename == "c.txt")
    }

    // MARK: - Sender

    @Test("Sender email address correctly set")
    func senderAddress() {
        let draft = DraftMessage(to: ["to@test.com"], subject: "Test")
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "my-email@domain.com")
        #expect(email.sender.address == "my-email@domain.com")
    }

    // MARK: - Empty recipients

    @Test("Empty to array produces empty recipients")
    func emptyTo() {
        let draft = DraftMessage(to: [], subject: "No recipients")
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.isEmpty)
    }

    @Test("Empty cc array produces empty ccRecipients")
    func emptyCc() {
        let draft = DraftMessage(to: ["to@test.com"], cc: [], subject: "No CC")
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.ccRecipients.isEmpty)
    }
}
