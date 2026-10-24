/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The raw message Gmail receives is RFC 2822 MIME, so no physical header line may
/// pass 998 octets (RFC 5322 §2.1.1). In-Reply-To and References carry a parent's
/// whole identifier and its ancestors' history, which can pass that on one line;
/// both serializers fold them, and a reader that unfolds gets every identifier back
/// in order (#278 review).
@Suite("Gmail thread headers stay within the line limit")
struct GmailThreadHeaderFoldingTests {

    enum Serializer: String, CaseIterable {
        case rfc822, mime
    }

    private static let hardLineLimit = 998

    private func raw(_ draft: DraftMessage, _ serializer: Serializer) -> String {
        let provider = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        switch serializer {
        case .rfc822: return provider.buildRFC822(draft: draft)
        case .mime: return String(decoding: provider.buildMIMEMessage(draft: draft), as: UTF8.self)
        }
    }

    private func headerLines(_ message: String) -> [String] {
        (message.components(separatedBy: "\r\n\r\n").first ?? message).components(separatedBy: "\r\n")
    }

    /// Unfolds the header section (RFC 5322 §2.2.3) and reads it with the app's own
    /// RFC 5322 header reader.
    private func readBack(_ message: String) throws -> MessageMetadata {
        var fields: [String: String] = [:]
        var current: (name: String, value: String)?
        for line in headerLines(message) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                current?.value += line
                continue
            }
            if let field = current { fields[field.name] = field.value }
            let colon = try #require(line.firstIndex(of: ":"))
            current = (String(line[..<colon]), String(line[line.index(after: colon)...]))
        }
        if let field = current { fields[field.name] = field.value }
        return try #require(RFC5322Parse.buildMetadata(
            uid: "1", headers: fields, internalDate: nil, flags: [], hasAttachments: false))
    }

    private static let ancestors = (0..<40).map { "ancestor-\($0)-" + String(repeating: "a", count: 32) + "@example.com" }
    // "Message-ID: <id>" is a legal 998-octet line; "In-Reply-To: <id>" is one octet longer.
    private static let longParent = String(repeating: "p", count: 972) + "@example.com"

    @Test("A long References history is folded and reads back whole, in order",
          arguments: Serializer.allCases, [false, true])
    func longHistory(_ serializer: Serializer, withAttachment: Bool) throws {
        let parent = "parent@example.com"
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: Self.ancestors + [parent],
            attachments: withAttachment
                ? [DraftAttachment(filename: "file.txt", mimeType: "text/plain", data: Data("file".utf8))] : [])
        let message = raw(draft, serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.references == Self.ancestors + [parent])
        #expect(metadata.inReplyTo == parent)
    }

    @Test("A parent Message-ID as long as a legal Message-ID line is kept whole",
          arguments: Serializer.allCases)
    func longParentID(_ serializer: Serializer) throws {
        #expect("Message-ID: <\(Self.longParent)>".utf8.count == Self.hardLineLimit)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: Self.longParent, references: [Self.longParent])
        let message = raw(draft, serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.inReplyTo == Self.longParent)
        #expect(metadata.references == [Self.longParent])
    }

    @Test("Short thread headers stay on one line each", arguments: Serializer.allCases)
    func shortHeadersUnfolded(_ serializer: Serializer) {
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: "b@example.com", references: ["a@example.com", "<b@example.com>"])
        let lines = headerLines(raw(draft, serializer))
        #expect(lines.contains("In-Reply-To: <b@example.com>"))
        #expect(lines.contains("References: <a@example.com> <b@example.com>"))
    }
}
