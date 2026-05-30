/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("GmailProvider.gmailDisplayName")
struct GmailDisplayNameTests {

    @Test("Maps INBOX to Inbox")
    func mapsInbox() {
        #expect(GmailProvider.gmailDisplayName("INBOX") == "Inbox")
    }

    @Test("Maps SENT to Sent")
    func mapsSent() {
        #expect(GmailProvider.gmailDisplayName("SENT") == "Sent")
    }

    @Test("Maps DRAFT to Drafts")
    func mapsDraft() {
        #expect(GmailProvider.gmailDisplayName("DRAFT") == "Drafts")
    }

    @Test("Maps TRASH to Trash")
    func mapsTrash() {
        #expect(GmailProvider.gmailDisplayName("TRASH") == "Trash")
    }

    @Test("Maps SPAM to Spam")
    func mapsSpam() {
        #expect(GmailProvider.gmailDisplayName("SPAM") == "Spam")
    }

    @Test("Maps STARRED to Starred")
    func mapsStarred() {
        #expect(GmailProvider.gmailDisplayName("STARRED") == "Starred")
    }

    @Test("Returns custom label name unchanged")
    func customLabel() {
        #expect(GmailProvider.gmailDisplayName("My Custom Label") == "My Custom Label")
    }

    @Test("Returns empty string unchanged")
    func emptyString() {
        #expect(GmailProvider.gmailDisplayName("") == "")
    }

    @Test("Does not map lowercase inbox")
    func lowercaseNotMapped() {
        // Only exact UPPERCASE matches are mapped
        #expect(GmailProvider.gmailDisplayName("inbox") == "inbox")
    }
}

@Suite("GmailProvider.parseFromHeader")
struct GmailParseFromHeaderTests {

    @Test("Parses display name and address from angle-bracket format")
    func parsesDisplayNameAndAddress() {
        let result = GmailProvider.parseFromHeader("John Doe <john@example.com>")
        #expect(result.displayName == "John Doe")
        #expect(result.address == "john@example.com")
    }

    @Test("Parses quoted display name with comma")
    func parsesQuotedDisplayName() {
        let result = GmailProvider.parseFromHeader("\"Doe, John\" <john@example.com>")
        #expect(result.displayName == "Doe, John")
        #expect(result.address == "john@example.com")
    }

    @Test("Returns address as both fields when no angle brackets")
    func bareAddress() {
        let result = GmailProvider.parseFromHeader("john@example.com")
        #expect(result.displayName == "john@example.com")
        #expect(result.address == "john@example.com")
    }

    @Test("Uses address as display name when name part is empty")
    func emptyNamePart() {
        let result = GmailProvider.parseFromHeader("<john@example.com>")
        #expect(result.displayName == "john@example.com")
        #expect(result.address == "john@example.com")
    }

    @Test("Trims whitespace from display name")
    func trimsWhitespace() {
        let result = GmailProvider.parseFromHeader("  Alice   <alice@example.com>")
        #expect(result.displayName == "Alice")
        #expect(result.address == "alice@example.com")
    }

    @Test("Strips surrounding quotes from display name")
    func stripsQuotes() {
        let result = GmailProvider.parseFromHeader("\"Bob Smith\" <bob@example.com>")
        #expect(result.displayName == "Bob Smith")
        #expect(result.address == "bob@example.com")
    }

    @Test("Handles empty string")
    func emptyString() {
        let result = GmailProvider.parseFromHeader("")
        #expect(result.displayName == "")
        #expect(result.address == "")
    }
}

@Suite("GmailProvider.hasAttachmentParts")
struct GmailHasAttachmentPartsTests {

    @Test("Returns false for nil parts")
    func nilParts() {
        #expect(GmailProvider.hasAttachmentParts(nil) == false)
    }

    @Test("Returns false for empty parts array")
    func emptyParts() {
        #expect(GmailProvider.hasAttachmentParts([]) == false)
    }

    @Test("Returns true when part has a non-empty filename")
    func partWithFilename() {
        let part = GmailPart(mimeType: "application/pdf", filename: "doc.pdf", headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == true)
    }

    @Test("Returns false when filename is empty string")
    func emptyFilename() {
        let part = GmailPart(mimeType: "text/plain", filename: "", headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == false)
    }

    @Test("Returns false when filename is nil and mimeType is text/plain")
    func noFilenameTextPlain() {
        let part = GmailPart(mimeType: "text/plain", filename: nil, headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == false)
    }

    @Test("Returns true for text/calendar even without filename")
    func textCalendar() {
        let part = GmailPart(mimeType: "text/calendar", filename: nil, headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == true)
    }

    @Test("Returns true for TEXT/CALENDAR case-insensitive")
    func textCalendarUppercase() {
        let part = GmailPart(mimeType: "TEXT/CALENDAR", filename: nil, headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == true)
    }

    @Test("Recursively finds attachment in nested parts")
    func nestedAttachment() {
        let innerPart = GmailPart(mimeType: "application/pdf", filename: "report.pdf", headers: nil, body: nil, parts: nil)
        let outerPart = GmailPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [innerPart])
        #expect(GmailProvider.hasAttachmentParts([outerPart]) == true)
    }

    @Test("Returns false for deeply nested parts without attachments")
    func nestedNoAttachment() {
        let innerPart = GmailPart(mimeType: "text/plain", filename: nil, headers: nil, body: nil, parts: nil)
        let outerPart = GmailPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil, parts: [innerPart])
        #expect(GmailProvider.hasAttachmentParts([outerPart]) == false)
    }
}
