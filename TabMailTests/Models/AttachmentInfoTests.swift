/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AttachmentInfo")
struct AttachmentInfoTests {

    @Test("Init with all fields")
    func initAllFields() {
        let info = AttachmentInfo(
            filename: "document.pdf",
            contentType: "application/pdf",
            section: "1.2",
            size: 2048,
            encoding: "base64"
        )
        #expect(info.filename == "document.pdf")
        #expect(info.contentType == "application/pdf")
        #expect(info.section == "1.2")
        #expect(info.size == 2048)
        #expect(info.encoding == "base64")
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let info = AttachmentInfo(
            filename: "photo.jpg",
            contentType: "image/jpeg",
            section: "2",
            size: 5000,
            encoding: nil
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(AttachmentInfo.self, from: data)
        #expect(decoded.filename == "photo.jpg")
        #expect(decoded.encoding == nil)
    }

    @Test("Decodes array of attachments")
    func decodesArray() throws {
        let json = """
        [
            {"filename":"a.pdf","contentType":"application/pdf","section":"1","size":100,"encoding":"base64"},
            {"filename":"b.txt","contentType":"text/plain","section":"2","size":50,"encoding":null}
        ]
        """
        let attachments = try JSONDecoder().decode([AttachmentInfo].self, from: json.data(using: .utf8)!)
        #expect(attachments.count == 2)
        #expect(attachments[0].filename == "a.pdf")
        #expect(attachments[1].encoding == nil)
    }
}

@Suite("InlineImage")
struct InlineImageTests {

    @Test("Init with all fields")
    func initAllFields() {
        let data = Data("test image data".utf8)
        let image = InlineImage(contentId: "img001@example.com", contentType: "image/png", data: data)
        #expect(image.contentId == "img001@example.com")
        #expect(image.contentType == "image/png")
        #expect(!image.data.isEmpty)
    }
}
