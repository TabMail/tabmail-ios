/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - GmailPart Decodable edge cases

@Suite("GmailPart Decodable extended")
struct GmailPartDecodableExtendedTests {

    @Test("Decodes three levels of nested parts")
    func threeLevelNesting() throws {
        let json = """
        {
            "mimeType": "multipart/mixed",
            "parts": [
                {
                    "mimeType": "multipart/alternative",
                    "parts": [
                        {"mimeType": "text/plain"},
                        {"mimeType": "text/html"}
                    ]
                },
                {
                    "mimeType": "application/pdf",
                    "filename": "invoice.pdf",
                    "body": {"size": 4096}
                }
            ]
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.parts?.count == 2)
        #expect(decoded.parts?[0].parts?.count == 2)
        #expect(decoded.parts?[0].parts?[0].mimeType == "text/plain")
        #expect(decoded.parts?[1].filename == "invoice.pdf")
        #expect(decoded.parts?[1].body?.size == 4096)
    }

    @Test("Decodes part with empty parts array")
    func emptyPartsArray() throws {
        let json = #"{"mimeType": "multipart/mixed", "parts": []}"#
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.parts?.isEmpty == true)
    }

    @Test("Decodes part with empty filename string")
    func emptyFilenameString() throws {
        let json = #"{"mimeType": "text/plain", "filename": ""}"#
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.filename == "")
    }

    @Test("Decodes part with body containing only attachmentId")
    func bodyAttachmentIdOnly() throws {
        let json = """
        {
            "mimeType": "image/jpeg",
            "filename": "photo.jpg",
            "body": {"attachmentId": "ANGjdJ_xyz"}
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.body?.attachmentId == "ANGjdJ_xyz")
        #expect(decoded.body?.data == nil)
        #expect(decoded.body?.size == nil)
    }

    @Test("Decodes part with headers containing Content-Disposition")
    func contentDispositionHeader() throws {
        let json = """
        {
            "mimeType": "application/octet-stream",
            "filename": "data.bin",
            "headers": [
                {"name": "Content-Disposition", "value": "attachment; filename=\\"data.bin\\""},
                {"name": "Content-Transfer-Encoding", "value": "base64"}
            ]
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.headers?.count == 2)
        #expect(decoded.headers?[0].name == "Content-Disposition")
        #expect(decoded.headers?[1].value == "base64")
    }

    @Test("Decodes multipart/related with inline image part")
    func multipartRelatedInlineImage() throws {
        let json = """
        {
            "mimeType": "multipart/related",
            "parts": [
                {"mimeType": "text/html", "body": {"data": "PGh0bWw-", "size": 100}},
                {
                    "mimeType": "image/png",
                    "filename": "logo.png",
                    "headers": [{"name": "Content-Id", "value": "<logo@cid>"}],
                    "body": {"attachmentId": "att-logo", "size": 2048}
                }
            ]
        }
        """
        let decoded = try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
        #expect(decoded.parts?.count == 2)
        let imagePart = decoded.parts?[1]
        #expect(imagePart?.mimeType == "image/png")
        #expect(imagePart?.headers?[0].value == "<logo@cid>")
        #expect(imagePart?.body?.attachmentId == "att-logo")
    }
}

// MARK: - GmailHeader Decodable edge cases

@Suite("GmailHeader Decodable extended")
struct GmailHeaderDecodableExtendedTests {

    @Test("Decodes header with very long value")
    func longValue() throws {
        let longVal = String(repeating: "x", count: 5000)
        let json = #"{"name":"Subject","value":"\#(longVal)"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.value.count == 5000)
    }

    @Test("Decodes header with unicode value")
    func unicodeValue() throws {
        let json = #"{"name":"Subject","value":"Re: Projet de collaboration"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.value.contains("Projet"))
    }

    @Test("Decodes header with newline in value (folded header)")
    func foldedHeader() throws {
        let json = #"{"name":"Received","value":"from mx.google.com\r\n        by smtp.example.com"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.name == "Received")
        #expect(decoded.value.contains("mx.google.com"))
    }

    @Test("Decodes header with email address containing plus")
    func plusAddress() throws {
        let json = #"{"name":"To","value":"user+tag@example.com"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.value == "user+tag@example.com")
    }

    @Test("Decodes Message-ID header with angle brackets")
    func messageIdHeader() throws {
        let json = #"{"name":"Message-ID","value":"<CAG+abc123@mail.gmail.com>"}"#
        let decoded = try JSONDecoder().decode(GmailHeader.self, from: Data(json.utf8))
        #expect(decoded.name == "Message-ID")
        #expect(decoded.value.hasPrefix("<"))
        #expect(decoded.value.hasSuffix(">"))
    }
}

// MARK: - GmailBody Decodable edge cases

@Suite("GmailBody Decodable extended")
struct GmailBodyDecodableExtendedTests {

    @Test("Decodes body with large size value")
    func largeSize() throws {
        let json = #"{"size": 104857600}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.size == 104857600) // 100MB
    }

    @Test("Decodes body with base64url data (no padding)")
    func base64urlNoPadding() throws {
        let json = #"{"data": "SGVsbG8gV29ybGQ"}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.data == "SGVsbG8gV29ybGQ")
    }

    @Test("Decodes body with empty data string")
    func emptyDataString() throws {
        let json = #"{"data": "", "size": 0}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.data == "")
        #expect(decoded.size == 0)
    }

    @Test("Decodes body with attachmentId and size but no data")
    func attachmentIdNoData() throws {
        let json = #"{"attachmentId": "ANGjdJ_xyz123", "size": 51200}"#
        let decoded = try JSONDecoder().decode(GmailBody.self, from: Data(json.utf8))
        #expect(decoded.attachmentId == "ANGjdJ_xyz123")
        #expect(decoded.size == 51200)
        #expect(decoded.data == nil)
    }
}

// MARK: - hasAttachmentParts complex nesting

@Suite("GmailProvider.hasAttachmentParts complex nesting")
struct GmailHasAttachmentPartsComplexTests {

    @Test("Four-level nesting with attachment at leaf")
    func fourLevelNesting() {
        let leaf = GmailPart(mimeType: "application/zip", filename: "data.zip", headers: nil, body: nil, parts: nil)
        let level3 = GmailPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [leaf])
        let level2 = GmailPart(mimeType: "multipart/related", filename: nil, headers: nil, body: nil, parts: [level3])
        let level1 = GmailPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil, parts: [level2])
        #expect(GmailProvider.hasAttachmentParts([level1]) == true)
    }

    @Test("Multiple branches, only one has attachment")
    func multipleBranchesOneAttachment() {
        let textBranch = GmailPart(mimeType: "text/plain", filename: nil, headers: nil, body: nil, parts: nil)
        let htmlBranch = GmailPart(mimeType: "text/html", filename: nil, headers: nil, body: nil, parts: nil)
        let attachBranch = GmailPart(mimeType: "image/jpeg", filename: "photo.jpg", headers: nil, body: nil, parts: nil)
        let alt = GmailPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil, parts: [textBranch, htmlBranch])
        let mixed = GmailPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [alt, attachBranch])
        #expect(GmailProvider.hasAttachmentParts([mixed]) == true)
    }

    @Test("text/calendar nested inside multipart/alternative")
    func calendarInAlternative() {
        let text = GmailPart(mimeType: "text/plain", filename: nil, headers: nil, body: nil, parts: nil)
        let calendar = GmailPart(mimeType: "text/calendar", filename: nil, headers: nil, body: nil, parts: nil)
        let alt = GmailPart(mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil, parts: [text, calendar])
        #expect(GmailProvider.hasAttachmentParts([alt]) == true)
    }

    @Test("Nil mimeType but non-empty filename is an attachment")
    func nilMimeWithFilename() {
        let part = GmailPart(mimeType: nil, filename: "unknown.dat", headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([part]) == true)
    }

    @Test("Empty parts array at each level returns false")
    func emptyPartsAtEachLevel() {
        let inner = GmailPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [])
        let outer = GmailPart(mimeType: "multipart/mixed", filename: nil, headers: nil, body: nil, parts: [inner])
        #expect(GmailProvider.hasAttachmentParts([outer]) == false)
    }

    @Test("Sibling parts both with attachments")
    func siblingAttachments() {
        let pdf = GmailPart(mimeType: "application/pdf", filename: "a.pdf", headers: nil, body: nil, parts: nil)
        let docx = GmailPart(mimeType: "application/docx", filename: "b.docx", headers: nil, body: nil, parts: nil)
        #expect(GmailProvider.hasAttachmentParts([pdf, docx]) == true)
    }
}

// MARK: - gmailDisplayName edge cases

@Suite("GmailProvider.gmailDisplayName additional cases")
struct GmailDisplayNameAdditionalTests {

    @Test("Returns numeric-only label unchanged")
    func numericLabel() {
        #expect(GmailProvider.gmailDisplayName("12345") == "12345")
    }

    @Test("Returns label with spaces unchanged")
    func labelWithSpaces() {
        #expect(GmailProvider.gmailDisplayName("My Projects") == "My Projects")
    }

    @Test("Returns single character label unchanged")
    func singleCharLabel() {
        #expect(GmailProvider.gmailDisplayName("X") == "X")
    }

    @Test("Does not map DRAFTS (only DRAFT maps)")
    func draftsNotMapped() {
        #expect(GmailProvider.gmailDisplayName("DRAFTS") == "DRAFTS")
    }

    @Test("Does not map JUNK (not a Gmail system label)")
    func junkNotMapped() {
        #expect(GmailProvider.gmailDisplayName("JUNK") == "JUNK")
    }

    @Test("Returns label with forward slash hierarchy unchanged")
    func nestedLabel() {
        #expect(GmailProvider.gmailDisplayName("Work/Clients/Acme") == "Work/Clients/Acme")
    }
}

// MARK: - parseFromHeader edge cases

@Suite("GmailProvider.parseFromHeader additional cases")
struct GmailParseFromHeaderAdditionalTests {

    @Test("Handles RFC 2047 encoded name (raw — no decoding expected)")
    func rfc2047Encoded() {
        // parseFromHeader does not decode RFC 2047 — Gmail API provides decoded values
        let result = GmailProvider.parseFromHeader("=?UTF-8?B?5pel5pys?= <jp@example.com>")
        #expect(result.address == "jp@example.com")
        // The raw encoded string is returned as-is for the display name
        #expect(result.displayName == "=?UTF-8?B?5pel5pys?=")
    }

    @Test("Handles name with Unicode characters")
    func unicodeName() {
        let result = GmailProvider.parseFromHeader("Jean-Pierre Dupont <jp@example.fr>")
        #expect(result.displayName == "Jean-Pierre Dupont")
        #expect(result.address == "jp@example.fr")
    }

    @Test("Handles address with subaddressing (plus)")
    func plusAddress() {
        let result = GmailProvider.parseFromHeader("User <user+tag@example.com>")
        #expect(result.address == "user+tag@example.com")
    }

    @Test("Handles name with parentheses comment")
    func nameWithParenComment() {
        let result = GmailProvider.parseFromHeader("Support (Urgent) <support@company.com>")
        #expect(result.displayName == "Support (Urgent)")
        #expect(result.address == "support@company.com")
    }

    @Test("Handles bare domain without TLD")
    func bareDomain() {
        let result = GmailProvider.parseFromHeader("admin@localhost")
        #expect(result.displayName == "admin@localhost")
        #expect(result.address == "admin@localhost")
    }

    @Test("Handles name with leading/trailing whitespace and quotes")
    func whitespaceAndQuotes() {
        let result = GmailProvider.parseFromHeader("  \"  Alice  \"  <alice@test.com>")
        #expect(result.address == "alice@test.com")
        // Outer whitespace trimmed, then quotes stripped, inner whitespace preserved
        #expect(result.displayName == "  Alice  ")
    }

    @Test("Handles very long display name")
    func longDisplayName() {
        let longName = String(repeating: "A", count: 200)
        let result = GmailProvider.parseFromHeader("\(longName) <long@test.com>")
        #expect(result.displayName == longName)
        #expect(result.address == "long@test.com")
    }
}
