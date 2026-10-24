/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import SwiftMail
@testable import TabMail

/// A part with a Content-ID and no filename, which SwiftMail names after its
/// Content-ID, read through the fake IMAP server by the main app and by the
/// notification extension. Only an image directly in a related body is inline;
/// a related document, and a part inside an attached message's own mixed body,
/// stay files (#283 review).
@Suite("IMAP parts named by their Content-ID", .serialized)
struct IMAPContentIdPartWireTests {

    private static let png = Data([0x89, 0x50, 0x4E, 0x47])

    private struct Reads {
        let app: FullMessageInfo
        /// The bytes the app fetches for each attachment it lists, by section.
        let appFiles: [String: Data]
        let nse: (metadata: NSEMessageMetadata, body: RenderedBody)
    }

    /// Serves one message with `bodystructure` as written and reads it both ways.
    private func read(contentType: String, body: Data, bodystructure: String,
                      partBodies: [String: Data]) async throws -> Reads {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        let date = TestFixtureDate.rfc2822()
        let messageID = "<content-id-part@example.com>"
        let header = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Content-ID part\r\n"
            + "Date: \(date)\r\nMessage-ID: \(messageID)\r\nContent-Type: \(contentType)\r\n\r\n"
        let stored = FakeIMAPServer.makeMultipartMessage(
            uid: 5, subject: "Content-ID part", from: "sender@example.com", to: "recipient@example.com",
            date: date, internalDate: formatter.string(from: TestFixtureDate.anchor), messageID: messageID,
            rawHeader: header, fullMessage: Data(header.utf8) + body, bodystructure: bodystructure,
            partBodies: partBodies)
        let server = FakeIMAPServer(messages: [stored])
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        let app: FullMessageInfo
        var appFiles: [String: Data] = [:]
        do {
            app = try await provider.fetchMessage(id: "5", folder: "INBOX")
            for file in app.attachments {
                appFiles[file.section] = try await provider.fetchAttachment(
                    messageId: "5", folder: "INBOX", section: file.section, encoding: file.encoding)
            }
            try await provider.disconnect()
        } catch {
            try? await provider.disconnect()
            throw error
        }
        let nse = try #require(await NSEIMAPConnection.fetch(
            accountId: "content-id-part", host: "127.0.0.1", port: server.port, useTLS: false,
            username: server.username, password: server.password, rfc822MessageId: messageID))
        return Reads(app: app, appFiles: appFiles, nse: nse)
    }

    @Test("A related body's document named by its Content-ID stays a file", arguments: ["PDF", "OCTET-STREAM"])
    func relatedDocumentStaysAFile(subtype: String) async throws {
        let html = Data("<p>See <a href=\"cid:document@example.com\">the document</a></p>".utf8)
        let document = Data("document bytes".utf8)
        let wire = Data(document.base64EncodedString().utf8)
        let reads = try await read(
            contentType: "multipart/related; boundary=b; type=\"text/html\"",
            body: Data("--b\r\nContent-Type: text/html\r\n\r\n".utf8) + html
                + Data("\r\n--b\r\nContent-Type: application/\(subtype.lowercased())\r\nContent-ID: <document@example.com>\r\n".utf8)
                + Data("Content-Transfer-Encoding: base64\r\n\r\n".utf8) + wire + Data("\r\n--b--\r\n".utf8),
            bodystructure: "((\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(html.count) 1)"
                + "(\"APPLICATION\" \"\(subtype)\" NIL \"<document@example.com>\" NIL \"BASE64\" \(wire.count)) \"RELATED\")",
            partBodies: ["1": html, "2": wire])
        #expect(reads.app.header.hasAttachments)
        #expect(reads.app.attachments.map(\.filename) == ["document@example.com"])
        #expect(reads.appFiles["2"] == document)
        #expect(reads.nse.metadata.hasAttachments)
        #expect(reads.nse.body.attachments.map(\.filename) == ["document@example.com"])
    }

    /// An HTML body in an `outer` multipart, and an attached message whose own body
    /// is an `inner` multipart holding its text and a Content-ID image.
    @Test("An attached message's image is classified by the attached message's own body",
          arguments: [("related", "mixed", true), ("mixed", "mixed", true), ("related", "related", false), ("mixed", "related", false)])
    func attachedMessageImageUsesItsOwnBody(outer: String, inner: String, isFile: Bool) async throws {
        let outerHTML = Data("<p>Outer body</p>".utf8)
        let innerText = Data((inner == "related" ? "<p>Inner <img src=\"cid:logo@example.com\"></p>" : "Inner body").utf8)
        let innerType = inner == "related" ? "HTML" : "PLAIN"
        let imageWire = Data(Self.png.base64EncodedString().utf8)
        let innerMessage = Data(("From: inner@example.com\r\nTo: recipient@example.com\r\nSubject: Inner\r\n"
            + "Message-ID: <inner@example.com>\r\nContent-Type: multipart/\(inner); boundary=c\r\n\r\n"
            + "--c\r\nContent-Type: text/\(innerType.lowercased())\r\n\r\n").utf8) + innerText
            + Data("\r\n--c\r\nContent-Type: image/png\r\nContent-ID: <logo@example.com>\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8)
            + imageWire + Data("\r\n--c--\r\n".utf8)
        let innerAddress = "((NIL NIL \"inner\" \"example.com\"))"
        let envelope = "(NIL \"Inner\" \(innerAddress) \(innerAddress) \(innerAddress) ((NIL NIL \"recipient\" \"example.com\")) NIL NIL NIL \"<inner@example.com>\")"
        let innerStructure = "((\"TEXT\" \"\(innerType)\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(innerText.count) 1)"
            + "(\"IMAGE\" \"PNG\" NIL \"<logo@example.com>\" NIL \"BASE64\" \(imageWire.count)) \"\(inner.uppercased())\")"
        let reads = try await read(
            contentType: "multipart/\(outer); boundary=b; type=\"text/html\"",
            body: Data("--b\r\nContent-Type: text/html\r\n\r\n".utf8) + outerHTML
                + Data("\r\n--b\r\nContent-Type: message/rfc822; name=\"forwarded.eml\"\r\n".utf8)
                + Data("Content-Disposition: attachment; filename=\"forwarded.eml\"\r\n\r\n".utf8)
                + innerMessage + Data("\r\n--b--\r\n".utf8),
            bodystructure: "((\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(outerHTML.count) 1)"
                + "(\"MESSAGE\" \"RFC822\" (\"NAME\" \"forwarded.eml\") NIL NIL \"7BIT\" \(innerMessage.count) "
                + "\(envelope) \(innerStructure) 10) \"\(outer.uppercased())\")",
            partBodies: ["1": outerHTML, "2": innerMessage, "2.1": innerText, "2.2": imageWire])
        let expected = isFile ? ["forwarded.eml", "logo@example.com"] : ["forwarded.eml"]
        #expect(reads.app.attachments.map(\.filename) == expected)
        #expect(reads.app.inlineImages.first?.data == Self.png)
        if isFile {
            #expect(reads.app.attachments.last?.parentEmlSection == "2")
            #expect(reads.appFiles["2.2"] == Self.png)
        }
        #expect(reads.nse.body.attachments.map(\.filename) == expected)
    }

    @Test("A related image with no disposition is inline, with no app or NSE paperclip")
    func relatedImageWithoutDispositionIsInline() async throws {
        let html = Data("<p>Body <img src=\"cid:logo@example.com\"></p>".utf8)
        let wire = Data(Self.png.base64EncodedString().utf8)
        let reads = try await read(
            contentType: "multipart/related; boundary=b; type=\"text/html\"",
            body: Data("--b\r\nContent-Type: text/html\r\n\r\n".utf8) + html
                + Data("\r\n--b\r\nContent-Type: image/png\r\nContent-ID: <logo@example.com>\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8)
                + wire + Data("\r\n--b--\r\n".utf8),
            bodystructure: "((\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(html.count) 1)"
                + "(\"IMAGE\" \"PNG\" NIL \"<logo@example.com>\" NIL \"BASE64\" \(wire.count)) \"RELATED\")",
            partBodies: ["1": html, "2": wire])
        #expect(!reads.app.header.hasAttachments)
        #expect(reads.app.attachments.isEmpty)
        #expect(reads.app.inlineImages.map(\.contentId) == ["logo@example.com"])
        #expect(reads.app.inlineImages.first?.data == Self.png)
        #expect(!reads.nse.metadata.hasAttachments)
        #expect(reads.nse.body.attachments.isEmpty)
        #expect(reads.nse.body.htmlContent?.contains("Body") == true)
        #expect(!reads.nse.body.hasUnresolvedCIDs)
    }
}
