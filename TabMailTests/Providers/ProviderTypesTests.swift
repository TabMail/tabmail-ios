/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Provider Types")
struct ProviderTypesTests {

    // MARK: - AttachmentInfo Codable

    @Test("AttachmentInfo decodes all fields")
    func decodeAttachmentInfo() throws {
        let json = """
        {"filename": "report.pdf", "contentType": "application/pdf", "section": "1.2", "size": 102400, "encoding": "base64"}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(AttachmentInfo.self, from: json)
        #expect(a.filename == "report.pdf")
        #expect(a.contentType == "application/pdf")
        #expect(a.section == "1.2")
        #expect(a.size == 102400)
        #expect(a.encoding == "base64")
    }

    @Test("AttachmentInfo decodes with null encoding")
    func decodeAttachmentInfoNullEncoding() throws {
        let json = """
        {"filename": "photo.jpg", "contentType": "image/jpeg", "section": "2", "size": 50000, "encoding": null}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(AttachmentInfo.self, from: json)
        #expect(a.encoding == nil)
        #expect(a.filename == "photo.jpg")
    }

    @Test("AttachmentInfo decodes with missing encoding key")
    func decodeAttachmentInfoMissingEncoding() throws {
        let json = """
        {"filename": "doc.txt", "contentType": "text/plain", "section": "3", "size": 256}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(AttachmentInfo.self, from: json)
        #expect(a.encoding == nil)
        #expect(a.size == 256)
    }

    @Test("AttachmentInfo round-trips through encode/decode")
    func roundTripAttachmentInfo() throws {
        let original = AttachmentInfo(
            filename: "spreadsheet.xlsx",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            section: "1.1",
            size: 999999,
            encoding: "quoted-printable"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AttachmentInfo.self, from: data)
        #expect(decoded.filename == original.filename)
        #expect(decoded.contentType == original.contentType)
        #expect(decoded.section == original.section)
        #expect(decoded.size == original.size)
        #expect(decoded.encoding == original.encoding)
    }

    @Test("AttachmentInfo with zero size")
    func decodeAttachmentInfoZeroSize() throws {
        let json = """
        {"filename": "empty.txt", "contentType": "text/plain", "section": "1", "size": 0, "encoding": null}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(AttachmentInfo.self, from: json)
        #expect(a.size == 0)
    }

    @Test("AttachmentInfo array decodes correctly")
    func decodeAttachmentInfoArray() throws {
        let json = """
        [
            {"filename": "a.pdf", "contentType": "application/pdf", "section": "1", "size": 100, "encoding": "base64"},
            {"filename": "b.png", "contentType": "image/png", "section": "2", "size": 200, "encoding": null}
        ]
        """.data(using: .utf8)!
        let arr = try JSONDecoder().decode([AttachmentInfo].self, from: json)
        #expect(arr.count == 2)
        #expect(arr[0].filename == "a.pdf")
        #expect(arr[1].filename == "b.png")
    }

    // MARK: - ProviderError

    @Test("ProviderError.notConnected has correct description")
    func notConnectedDescription() {
        let error = ProviderError.notConnected
        #expect(error.errorDescription == "Not connected to mail server.")
    }

    @Test("ProviderError.messageNotFound has correct description")
    func messageNotFoundDescription() {
        let error = ProviderError.messageNotFound
        #expect(error.errorDescription == "Message not found.")
    }

    @Test("ProviderError.authenticationFailed has correct description")
    func authFailedDescription() {
        let error = ProviderError.authenticationFailed
        #expect(error.errorDescription == "Authentication failed. Please check your credentials.")
    }

    @Test("ProviderError.invalidURL includes the URL")
    func invalidURLDescription() {
        let error = ProviderError.invalidURL("https://bad-url")
        #expect(error.errorDescription == "Invalid URL: https://bad-url")
    }

    @Test("ProviderError.networkError wraps underlying error description")
    func networkErrorDescription() {
        struct TestError: LocalizedError {
            var errorDescription: String? { "Connection timed out" }
        }
        let error = ProviderError.networkError(underlying: TestError())
        #expect(error.errorDescription?.contains("Connection timed out") == true)
    }
}
