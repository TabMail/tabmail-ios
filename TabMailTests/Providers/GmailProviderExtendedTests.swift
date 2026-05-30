/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - GmailHeader Codable

@Suite("GmailHeader Decodable")
struct GmailHeaderDecodableTests {

    @Test("Decodes name and value from JSON")
    func decodesNameAndValue() throws {
        let json = #"{"name":"From","value":"alice@example.com"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.name == "From")
        #expect(decoded.value == "alice@example.com")
    }

    @Test("Decodes Subject header")
    func decodesSubject() throws {
        let json = #"{"name":"Subject","value":"Hello World"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.name == "Subject")
        #expect(decoded.value == "Hello World")
    }

    @Test("Decodes empty strings for name and value")
    func emptyStrings() throws {
        let json = #"{"name":"","value":""}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.name == "")
        #expect(decoded.value == "")
    }

    @Test("Decodes special characters in value")
    func specialCharacters() throws {
        let json = #"{"name":"From","value":"\"Doe, John\" <john@example.com>"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.value == "\"Doe, John\" <john@example.com>")
    }
}

// MARK: - GmailBody Codable

@Suite("GmailBody Codable")
struct GmailBodyCodableTests {

    @Test("Round-trip with all fields populated")
    func fullRoundTrip() throws {
        let json = #"{"data":"SGVsbG8=","size":5,"attachmentId":"att-123"}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.data == "SGVsbG8=")
        #expect(decoded.size == 5)
        #expect(decoded.attachmentId == "att-123")
    }

    @Test("Decodes with all fields nil/missing")
    func allFieldsMissing() throws {
        let json = #"{}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.data == nil)
        #expect(decoded.size == nil)
        #expect(decoded.attachmentId == nil)
    }

    @Test("Decodes with only data field")
    func dataOnly() throws {
        let json = #"{"data":"dGVzdA=="}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.data == "dGVzdA==")
        #expect(decoded.size == nil)
        #expect(decoded.attachmentId == nil)
    }

    @Test("Decodes with only size field")
    func sizeOnly() throws {
        let json = #"{"size":1024}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.data == nil)
        #expect(decoded.size == 1024)
    }

    @Test("Decodes zero size")
    func zeroSize() throws {
        let json = #"{"size":0}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.size == 0)
    }
}

// MARK: - GmailPart Codable

@Suite("GmailPart Codable")
struct GmailPartCodableTests {

    @Test("Decodes minimal part with all nil optional fields")
    func minimalPart() throws {
        let json = #"{}"#
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.mimeType == nil)
        #expect(decoded.filename == nil)
        #expect(decoded.headers == nil)
        #expect(decoded.body == nil)
        #expect(decoded.parts == nil)
    }

    @Test("Decodes part with mimeType and filename")
    func mimeAndFilename() throws {
        let json = #"{"mimeType":"application/pdf","filename":"report.pdf"}"#
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.mimeType == "application/pdf")
        #expect(decoded.filename == "report.pdf")
    }

    @Test("Decodes nested parts recursively")
    func nestedParts() throws {
        let json = """
        {
            "mimeType": "multipart/mixed",
            "parts": [
                {"mimeType": "text/plain", "filename": ""},
                {"mimeType": "application/pdf", "filename": "doc.pdf"}
            ]
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.mimeType == "multipart/mixed")
        #expect(decoded.parts?.count == 2)
        #expect(decoded.parts?[0].mimeType == "text/plain")
        #expect(decoded.parts?[1].filename == "doc.pdf")
    }

    @Test("Decodes part with body containing attachmentId")
    func bodyWithAttachmentId() throws {
        let json = """
        {
            "mimeType": "image/png",
            "filename": "screenshot.png",
            "body": {"attachmentId": "ANGjdJ_abc", "size": 2048}
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.body?.attachmentId == "ANGjdJ_abc")
        #expect(decoded.body?.size == 2048)
    }

    @Test("Decodes part with headers array")
    func headersArray() throws {
        let json = """
        {
            "mimeType": "text/html",
            "headers": [
                {"name": "Content-Type", "value": "text/html; charset=utf-8"},
                {"name": "Content-Id", "value": "<image001@host>"}
            ]
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.headers?.count == 2)
        #expect(decoded.headers?[0].name == "Content-Type")
        #expect(decoded.headers?[1].value == "<image001@host>")
    }
}

// MARK: - GmailProvider.archivePath

@Suite("GmailProvider.archivePath")
struct GmailArchivePathTests {

    @Test("archivePath is a known synthetic path")
    func archivePathValue() {
        #expect(GmailProvider.archivePath == "__GMAIL_ALL_MAIL__")
    }

    @Test("archivePath is not empty")
    func archivePathNotEmpty() {
        #expect(!GmailProvider.archivePath.isEmpty)
    }

    @Test("archivePath does not look like a real Gmail label ID")
    func archivePathNotRealLabel() {
        // Real Gmail label IDs are things like "INBOX", "Label_123", etc.
        #expect(GmailProvider.archivePath.hasPrefix("__"))
        #expect(GmailProvider.archivePath.hasSuffix("__"))
    }
}

// MARK: - GmailProvider.hasAttachmentParts edge cases

@Suite("GmailProvider.hasAttachmentParts extended")
struct GmailHasAttachmentPartsExtendedTests {

    @Test("Returns true for application/ics with filename")
    func icsWithFilename() {
        let part = GmailPart(mimeType: "application/ics", filename: "invite.ics", headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == true)
    }

    @Test("Returns false for text/html without filename")
    func textHtmlNoFilename() {
        let part = GmailPart(mimeType: "text/html", filename: nil, headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == false)
    }

    @Test("Returns true for text/calendar with mixed case")
    func textCalendarMixedCase() {
        let part = GmailPart(mimeType: "Text/Calendar", filename: nil, headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == true)
    }

    @Test("Returns true when attachment is deeply nested (3 levels)")
    func deeplyNestedAttachment() {
        let leaf = GmailPart(mimeType: "application/zip", filename: "archive.zip", headers: nil, body: nil, parts: nil)
        let mid = GmailPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [leaf])
        let outer = GmailPart(mimeType: "multipart/related", filename: nil, headers: nil, body: nil, parts: [mid])
        #expect(GmailProvider.hasAttachmentParts([outer]) == true)
    }

    @Test("Returns false for nil mimeType and nil filename")
    func nilMimeTypeAndFilename() {
        let part = GmailPart(mimeType: nil, filename: nil, headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == false)
    }

    @Test("Returns true when one of multiple parts has an attachment")
    func multiplePartsOneAttachment() {
        let textPart = GmailPart(mimeType: "text/plain", filename: nil, headers: nil, body: nil, parts: nil)
        let htmlPart = GmailPart(mimeType: "text/html", filename: nil, headers: nil, body: nil, parts: nil)
        let pdfPart = GmailPart(mimeType: "application/pdf", filename: "doc.pdf", headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([textPart, htmlPart, pdfPart]) == true)
    }

    @Test("Returns false for multipart with only text children")
    func multipartTextOnly() {
        let text = GmailPart(mimeType: "text/plain", filename: nil, headers: nil, body: nil, parts: nil)
        let html = GmailPart(mimeType: "text/html", filename: nil, headers: nil, body: nil, parts: nil)
        let container = GmailPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil, parts: [text, html])
        #expect(GmailProvider.hasAttachmentParts([container]) == false)
    }
}

// MARK: - GmailProvider.parseFromHeader edge cases

@Suite("GmailProvider.parseFromHeader extended")
struct GmailParseFromHeaderExtendedTests {

    @Test("Handles multiple angle brackets (takes first pair)")
    func multipleAngleBrackets() {
        let result = GmailProvider.parseFromHeader("Name <first@test.com> <second@test.com>")
        #expect(result.address == "first@test.com")
        #expect(result.displayName == "Name")
    }

    @Test("Handles name with nested quotes")
    func nestedQuotes() {
        let result = GmailProvider.parseFromHeader("\"O'Brien\" <ob@test.com>")
        #expect(result.displayName == "O'Brien")
        #expect(result.address == "ob@test.com")
    }

    @Test("Address-only with surrounding whitespace is trimmed (parser improvement)")
    func addressWithWhitespace() {
        // Post-consolidation behavior: EmailAddress.parse trims outer
        // whitespace. Pre-refactor GmailProvider.parseFromHeader preserved
        // whitespace, which meant GRDB-stored addresses could include
        // surrounding whitespace — a latent data-quality bug. Trimmed
        // output is the intentional improvement; downstream consumers
        // see clean email addresses.
        let result = GmailProvider.parseFromHeader("  user@test.com  ")
        #expect(result.displayName == "user@test.com")
        #expect(result.address == "user@test.com")
    }

    @Test("Handles name with special characters before angle bracket")
    func specialCharsInName() {
        let result = GmailProvider.parseFromHeader("Team (Engineering) <eng@company.com>")
        #expect(result.displayName == "Team (Engineering)")
        #expect(result.address == "eng@company.com")
    }
}

// MARK: - GmailProvider.gmailDisplayName extended

@Suite("GmailProvider.gmailDisplayName extended")
struct GmailDisplayNameExtendedTests {

    @Test("Does not map partial matches")
    func partialMatch() {
        #expect(GmailProvider.gmailDisplayName("INBOX2") == "INBOX2")
        #expect(GmailProvider.gmailDisplayName("MY_INBOX") == "MY_INBOX")
    }

    @Test("Does not map mixed case")
    func mixedCase() {
        #expect(GmailProvider.gmailDisplayName("Inbox") == "Inbox")
        #expect(GmailProvider.gmailDisplayName("Sent") == "Sent")
    }

    @Test("Preserves user label with slash hierarchy")
    func hierarchicalLabel() {
        #expect(GmailProvider.gmailDisplayName("Work/Projects") == "Work/Projects")
    }

    @Test("Preserves label with unicode characters")
    func unicodeLabel() {
        #expect(GmailProvider.gmailDisplayName("Projets") == "Projets")
    }
}
