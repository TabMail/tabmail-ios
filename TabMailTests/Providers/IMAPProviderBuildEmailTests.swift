/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

@Suite("IMAPProvider.buildEmail")
struct IMAPProviderBuildEmailTests {

    private func subjectFieldBody(in message: String) -> String? {
        let headerLines = (message.components(separatedBy: "\r\n\r\n").first ?? message)
            .components(separatedBy: "\r\n")
        guard let subjectIndex = headerLines.firstIndex(where: { $0.hasPrefix("Subject: ") }) else {
            return nil
        }

        var body = String(headerLines[subjectIndex].dropFirst("Subject: ".count))
        var index = subjectIndex + 1
        while index < headerLines.count,
              headerLines[index].hasPrefix(" ") || headerLines[index].hasPrefix("\t") {
            body += "\r\n" + headerLines[index]
            index += 1
        }
        return body
    }

    private func subjectPhysicalLines(in message: String) -> [String] {
        let headerLines = (message.components(separatedBy: "\r\n\r\n").first ?? message)
            .components(separatedBy: "\r\n")
        guard let subjectIndex = headerLines.firstIndex(where: { $0.hasPrefix("Subject: ") }) else {
            return []
        }

        var lines = [headerLines[subjectIndex]]
        var index = subjectIndex + 1
        while index < headerLines.count,
              headerLines[index].hasPrefix(" ") || headerLines[index].hasPrefix("\t") {
            lines.append(headerLines[index])
            index += 1
        }
        return lines
    }

    // MARK: - Control characters reaching an outbound header line

    /// **The IMAP path is vulnerable through the LIBRARY, not through our code, and
    /// "we hand SwiftMail a structured field" is not a defence.** SwiftMail's
    /// `Email+Content` emits `"Subject: \(subject.rfc2047EncodedHeader())\r\n"`, and
    /// `String+RFC2047Encode` opens with the same `guard contains(where: { !$0.isASCII })`
    /// our own helper had before `1d28552c1` — CR and LF are ASCII, so a CRLF-bearing
    /// subject is passed through untouched and ends the header field. That historical
    /// duplication is why the library residual remains tracked upstream. The app
    /// helper now deliberately owns a stricter Subject boundary and is no longer kept
    /// byte-for-byte in step with SwiftMail.
    ///
    /// We therefore encode at OUR boundary. Upstream still needs its own fix (a
    /// library must not emit an unencoded control character in a header regardless of
    /// caller) — `IOS-IMAP-016`, and that PR goes to Cocoanetics, not the fork.
    @Test("A control-bearing subject is encoded before SwiftMail sees it")
    func controlBearingSubjectEncodedAtBoundary() throws {
        let injected = "Fwd: Hi\r\nBcc: attacker@evil.example"
        let email = try IMAPProvider.buildEmail(
            from: DraftMessage(to: ["alice@example.com"], subject: injected, body: "body"),
            senderEmail: "sender@example.com"
        )

        #expect(!email.subject.unicodeScalars.contains { $0 == "\r" || $0 == "\n" },
                "a raw CRLF reached SwiftMail's header emitter")
        #expect(email.subject.hasPrefix("=?UTF-8?B?"))
        // Nothing lost: the recipient still reads the sender's text.
        #expect(RFC5322Parse.decodeRFC2047(email.subject) == injected)
        // Composes with the library rather than fighting it — our output is pure
        // ASCII, so SwiftMail's own encoder is a NO-OP on it and cannot double-encode.
        #expect(email.subject.rfc2047EncodedHeader() == email.subject)
    }

    @Test("Final IMAP emitter preserves a literal RFC 2047-shaped subject")
    func literalEncodedWordShapeRoundTripsThroughFinalEmitter() throws {
        let subject = "Re: =?UTF-8?B?SGVsbG8=?= explained"
        let email = try IMAPProvider.buildEmail(
            from: DraftMessage(to: ["alice@example.com"], subject: subject, body: "body"),
            senderEmail: "sender@example.com"
        )

        let emittedSubject = subjectFieldBody(in: email.constructContent())
        #expect(emittedSubject != nil)
        guard let emittedSubject else { return }
        #expect(RFC5322Parse.decodeRFC2047(emittedSubject) == subject)
        #expect(emittedSubject.decodeMIMEHeader() == subject)
        let physicalLines = subjectPhysicalLines(in: email.constructContent())
        #expect(!physicalLines.isEmpty)
        guard !physicalLines.isEmpty else { return }
        for line in physicalLines {
            #expect(line.utf8.count <= 76, "physical Subject line was \(line.utf8.count) octets")
        }
        #expect(email.subject.rfc2047EncodedHeader() == email.subject,
                "SwiftMail must not double-encode the app boundary's ASCII encoded-word")
    }

    @Test("Final IMAP emitter protects complete substrings consumed by SwiftMail")
    func decoderConsumableSubstringsRoundTripThroughFinalEmitter() throws {
        let validWord = "=?UTF-8?B?SGVsbG8=?="
        let subjects = ["prefix\(validWord)", "Re: \(validWord)suffix", "=?="]

        for subject in subjects {
            if subject != "=?=" {
                #expect(subject.decodeMIMEHeader() != subject,
                        "the raw compatibility control must be consumed before protection")
            }
            let email = try IMAPProvider.buildEmail(
                from: DraftMessage(to: ["alice@example.com"], subject: subject, body: "body"),
                senderEmail: "sender@example.com"
            )

            let content = email.constructContent()
            let emittedSubject = subjectFieldBody(in: content)
            #expect(emittedSubject != nil)
            guard let emittedSubject else { continue }
            #expect(emittedSubject != subject)
            #expect(emittedSubject.decodeMIMEHeader() == subject)
            let physicalLines = subjectPhysicalLines(in: content)
            #expect(!physicalLines.isEmpty)
            for line in physicalLines {
                #expect(line.utf8.count <= 76, "physical Subject line was \(line.utf8.count) octets")
            }
        }
    }

    @Test("Final IMAP emitter keeps every encoded-word within 75 octets")
    func scalarBoundaryKeepsFinalEmitterWithinEncodedWordLimit() throws {
        let subject = "a" + String(repeating: "\u{0301}", count: 23)
            + String(repeating: "b", count: 50)
        let email = try IMAPProvider.buildEmail(
            from: DraftMessage(to: ["alice@example.com"], subject: subject, body: "body"),
            senderEmail: "sender@example.com"
        )

        let emittedSubject = subjectFieldBody(in: email.constructContent())
        #expect(emittedSubject != nil)
        guard let emittedSubject else { return }
        #expect(RFC5322Parse.decodeRFC2047(emittedSubject) == subject)
        #expect(emittedSubject.decodeMIMEHeader() == subject)
        let words = emittedSubject.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        #expect(!words.isEmpty)
        for word in words {
            #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
            #expect(word.utf8.count <= 75, "encoded-word was \(word.utf8.count) octets")
        }
        let physicalLines = subjectPhysicalLines(in: email.constructContent())
        #expect(!physicalLines.isEmpty)
        guard !physicalLines.isEmpty else { return }
        for line in physicalLines {
            #expect(line.utf8.count <= 76, "physical Subject line was \(line.utf8.count) octets")
        }
        #expect(email.subject.rfc2047EncodedHeader() == email.subject,
                "SwiftMail must not double-encode the app boundary's ASCII encoded-word")
    }

    /// Non-vacuity: boundary encoding must not change common mail on the wire. A
    /// benign ASCII subject stays literal, and an ordinary non-ASCII subject is
    /// byte-identical to what SwiftMail previously produced on its own.
    @Test("Pre-encoding leaves benign and non-ASCII subjects behaving as before")
    func preEncodingDoesNotChangeNormalMail() throws {
        let ascii = try IMAPProvider.buildEmail(
            from: DraftMessage(to: ["alice@example.com"], subject: "Q3 numbers (final)", body: "b"),
            senderEmail: "sender@example.com"
        )
        #expect(ascii.subject == "Q3 numbers (final)")

        let korean = "회의 일정 안내"
        let nonASCII = try IMAPProvider.buildEmail(
            from: DraftMessage(to: ["alice@example.com"], subject: korean, body: "b"),
            senderEmail: "sender@example.com"
        )
        let previousWireValue = korean.rfc2047EncodedHeader()
        #expect(nonASCII.subject == previousWireValue)
        #expect(nonASCII.subject.rfc2047EncodedHeader() == nonASCII.subject)
        #expect(subjectFieldBody(in: nonASCII.constructContent()) == previousWireValue)
    }

    // MARK: - Basic construction

    // MARK: - Recipients

    @Test("Recipients go out in the form SwiftMail's parser reads")
    func recipientsNormalisedByParser() throws {
        let draft = DraftMessage(to: ["taro.@example.com"], cc: [".taro@example.com"], subject: "Hi")
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.map(\.address) == [#""taro."@example.com"#])
        #expect(email.ccRecipients.map(\.address) == [#"".taro"@example.com"#])
    }

    /// The send must fail where the user can see it — a fatal outbox error,
    /// never a silent send to a different or mangled address.
    @Test("A recipient SwiftMail cannot read fails the send as fatal")
    func unreadableRecipientFailsSendFatally() {
        for draft in [
            DraftMessage(to: ["ann@example.com", "not an address"], subject: "Hi"),
            DraftMessage(to: ["ann@example.com"], cc: ["foo@@example.com"], subject: "Hi")
        ] {
            do {
                _ = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
                Issue.record("an unreadable recipient was accepted for sending")
            } catch {
                #expect(AccountManager.isFatalSendError(error))
            }
        }
    }

    @Test("A saved draft keeps a recipient SwiftMail cannot read as typed")
    func draftKeepsUnreadableRecipientsAsTyped() {
        let draft = DraftMessage(to: ["not an address"], cc: ["foo@@example.com"], subject: "Hi")
        let email = IMAPProvider.buildDraftEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.map(\.address) == ["not an address"])
        #expect(email.ccRecipients.map(\.address) == ["foo@@example.com"])
    }

    /// A pasted group or address list is not one mailbox; saving only its first
    /// member would silently drop the rest from the server's draft copy.
    @Test("A saved draft keeps a group or several addresses in one token as typed")
    func draftKeepsMultiMailboxTokensAsTyped() {
        let group = "Team: a@example.com, b@example.com;"
        let list = "a@example.com, b@example.com"
        let draft = DraftMessage(to: [group], cc: [list], subject: "Hi")
        let email = IMAPProvider.buildDraftEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.map(\.address) == [group])
        #expect(email.ccRecipients.map(\.address) == [list])
    }

    /// Another client resuming the draft must read a name and an address, not
    /// one encoded word holding the whole text.
    @Test("A saved draft writes a name-and-address recipient as a name-addr")
    func draftWritesNamedRecipientAsNameAddr() throws {
        let draft = DraftMessage(to: ["Bob <bob@example.com>"], cc: ["ann@example.com"], subject: "Hi")
        let email = IMAPProvider.buildDraftEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.map(\.address) == ["bob@example.com"])
        #expect(email.recipients.map(\.name) == ["Bob"])
        let toLine = try #require(
            email.constructContent().components(separatedBy: "\r\n").first { $0.hasPrefix("To: ") }
        )
        #expect(toLine.contains("<bob@example.com>"))
        #expect(!toLine.contains("=?"))
        #expect(email.ccRecipients.map(\.address) == ["ann@example.com"])
    }

    @Test("Builds email with basic to-only draft")
    func basicToOnly() throws {
        let draft = DraftMessage(
            to: ["alice@example.com"],
            subject: "Hello",
            body: "Plain text body"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "sender@example.com")
        #expect(email.sender.address == "sender@example.com")
        #expect(email.recipients.count == 1)
        #expect(email.recipients[0].address == "alice@example.com")
        #expect(email.subject == "Hello")
        #expect(email.textBody == "Plain text body")
        #expect(email.htmlBody == nil)
    }

    @Test("Builds email with multiple to recipients")
    func multipleToRecipients() throws {
        let draft = DraftMessage(
            to: ["a@test.com", "b@test.com", "c@test.com"],
            subject: "Multi"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.count == 3)
        #expect(email.recipients[0].address == "a@test.com")
        #expect(email.recipients[1].address == "b@test.com")
        #expect(email.recipients[2].address == "c@test.com")
    }

    // MARK: - CC and BCC

    @Test("Builds email with CC recipients")
    func withCC() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            cc: ["cc1@test.com", "cc2@test.com"],
            subject: "With CC"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.ccRecipients.count == 2)
        #expect(email.ccRecipients[0].address == "cc1@test.com")
        #expect(email.ccRecipients[1].address == "cc2@test.com")
    }

    /// SwiftMail's send addresses RCPT TO to `allRecipients`, so a BCC recipient
    /// missing there is never delivered; one named in the content is exposed.
    @Test("BCC recipients are sent to but never named in the message")
    func bccRecipientsAreSentButNotNamed() throws {
        let draft = DraftMessage(
            to: ["to@example.com"],
            cc: ["cc@example.com"],
            bcc: ["hidden@example.com", "Hidden Two <hidden2@example.com>"],
            subject: "With BCC"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@example.com")
        #expect(email.bccRecipients.map(\.address) == ["hidden@example.com", "hidden2@example.com"])
        #expect(email.allRecipients.map(\.address)
            == ["to@example.com", "cc@example.com", "hidden@example.com", "hidden2@example.com"])

        let content = email.constructContent()
        #expect(content.contains("to@example.com"))
        #expect(content.contains("cc@example.com"))
        #expect(!content.contains("hidden"))
        #expect(!content.lowercased().contains("\r\nbcc:"))
    }

    @Test("A BCC recipient SwiftMail cannot read fails the send as fatal")
    func unreadableBccFailsSendFatally() {
        let draft = DraftMessage(to: ["ann@example.com"], bcc: ["not an address"], subject: "Hi")
        do {
            _ = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@example.com")
            Issue.record("an unreadable BCC recipient was accepted for sending")
        } catch {
            #expect(AccountManager.isFatalSendError(error))
        }
    }

    @Test("Builds email with both CC and to recipients")
    func ccAndTo() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            cc: ["cc@test.com"],
            subject: "Both"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.count == 1)
        #expect(email.ccRecipients.count == 1)
        #expect(email.allRecipients.count >= 2)
    }

    // MARK: - HTML vs plain text body

    @Test("Plain text draft sets textBody and nil htmlBody")
    func plainTextBody() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Plain",
            body: "Just text",
            isHTML: false
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.textBody == "Just text")
        #expect(email.htmlBody == nil)
    }

    @Test("HTML draft sets htmlBody and derives textBody from HTML")
    func htmlBody() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "HTML",
            body: "<p>Hello</p>",
            isHTML: true
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.htmlBody == "<p>Hello</p>")
        // textBody is derived from HTML via htmlToPlainText — should contain "Hello"
        #expect(email.textBody.contains("Hello"))
        #expect(!email.textBody.isEmpty)
    }

    @Test("HTML body with complex markup preserved")
    func complexHtmlBody() throws {
        let html = "<html><body><h1>Title</h1><p>Content with <b>bold</b> and <a href=\"https://example.com\">link</a></p></body></html>"
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Complex HTML",
            body: html,
            isHTML: true
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.htmlBody == html)
    }

    // MARK: - In-Reply-To header

    @Test("Sets In-Reply-To header when inReplyTo is present")
    func withInReplyTo() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Hello",
            body: "Reply body",
            inReplyTo: "<original-msg-id@example.com>"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<original-msg-id@example.com>")
    }

    @Test("No In-Reply-To header when inReplyTo is nil")
    func withoutInReplyTo() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "New message"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == nil)
    }

    // MARK: - References header

    @Test("Sets References header from references array")
    func withReferences() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            body: "Reply",
            references: ["<msg1@example.com>", "<msg2@example.com>"]
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<msg1@example.com> <msg2@example.com>")
    }

    @Test("No References header when references array is empty")
    func emptyReferences() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "New"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == nil)
    }

    @Test("Single reference joined without trailing space")
    func singleReference() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Single",
            references: ["<only-ref@example.com>"]
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<only-ref@example.com>")
    }

    // MARK: - Both In-Reply-To and References

    @Test("Sets both In-Reply-To and References headers together")
    func inReplyToAndReferences() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            inReplyTo: "<parent@example.com>",
            references: ["<root@example.com>", "<parent@example.com>"]
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<parent@example.com>")
        #expect(email.additionalHeaders?["References"] == "<root@example.com> <parent@example.com>")
    }

    // MARK: - No additional headers

    @Test("additionalHeaders is nil when no threading headers")
    func noAdditionalHeaders() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Simple"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders == nil)
    }

    // MARK: - Subject encoding

    @Test("Subject with Unicode characters preserved")
    func unicodeSubject() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Rendezvous: cafe discussion"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject == "Rendezvous: cafe discussion")
    }

    @Test("Subject with Japanese characters preserved")
    func japaneseSubject() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Meeting agenda"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject == "Meeting agenda")
    }

    @Test("Subject with emoji preserved")
    func emojiSubject() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Hello World"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject.contains("Hello"))
    }

    @Test("Empty subject preserved")
    func emptySubject() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: ""
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.subject == "")
    }

    // MARK: - Message ID

    @Test("Pre-generated messageId set on email")
    func withMessageId() throws {
        var draft = DraftMessage(
            to: ["to@test.com"],
            subject: "With ID"
        )
        draft.messageId = "<unique-id-123@tabmail.ai>"
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.messageID != nil)
        #expect(email.messageID?.description == "<unique-id-123@tabmail.ai>")
    }

    @Test("No messageId when draft.messageId is nil")
    func withoutMessageId() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "No ID"
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.messageID == nil)
    }

    // MARK: - Attachments

    @Test("Attachments mapped from DraftAttachment to SwiftMail Attachment")
    func withAttachments() throws {
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
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.attachments?.count == 1)
        #expect(email.attachments?[0].filename == "report.pdf")
        #expect(email.attachments?[0].mimeType == "application/pdf")
    }

    @Test("No attachments when draft has empty attachments array")
    func emptyAttachments() throws {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "No attachments",
            attachments: []
        )
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.attachments == nil)
    }

    @Test("Multiple attachments all mapped")
    func multipleAttachments() throws {
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
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.attachments?.count == 3)
        #expect(email.attachments?[0].filename == "a.pdf")
        #expect(email.attachments?[1].filename == "b.png")
        #expect(email.attachments?[2].filename == "c.txt")
    }

    // MARK: - Sender

    @Test("Sender email address correctly set")
    func senderAddress() throws {
        let draft = DraftMessage(to: ["to@test.com"], subject: "Test")
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "my-email@domain.com")
        #expect(email.sender.address == "my-email@domain.com")
    }

    // MARK: - Empty recipients

    @Test("Empty to array produces empty recipients")
    func emptyTo() throws {
        let draft = DraftMessage(to: [], subject: "No recipients")
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.recipients.isEmpty)
    }

    @Test("Empty cc array produces empty ccRecipients")
    func emptyCc() throws {
        let draft = DraftMessage(to: ["to@test.com"], cc: [], subject: "No CC")
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.ccRecipients.isEmpty)
    }
}
