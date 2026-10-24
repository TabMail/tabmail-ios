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
    /// As many octets in UTF-8 (RFC 6532 allows it), in far fewer characters, so a
    /// fold that counts characters instead of octets leaves the line too long.
    private static let longUTF8Parent = "q" + String(repeating: "\u{0301}", count: 485) + "q@example.com"

    /// The identity Gmail's reader takes from an incoming Message-ID, so the
    /// identifiers below are ones a reply can carry.
    private func receivedIdentity(_ messageID: String) throws -> String? {
        let metadata = try #require(GmailParse.parseMessage([
            "id": "parent", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)),
            "payload": ["headers": [["name": "Message-ID", "value": "<\(messageID)>"]]]
        ]))
        return MessageIdentity.comparableRfc822Identity(metadata.rfc822MessageId)
    }

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
          arguments: Serializer.allCases, [Self.longParent, Self.longUTF8Parent])
    func longParentID(_ serializer: Serializer, parent: String) throws {
        #expect("Message-ID: <\(parent)>".utf8.count == Self.hardLineLimit)
        #expect(try receivedIdentity(parent) == parent)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [parent])
        let message = raw(draft, serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.inReplyTo == parent)
        #expect(metadata.references == [parent])
    }

    @Test("A long UTF-8 ancestor before a short parent is folded by octets",
          arguments: Serializer.allCases)
    func longUTF8Ancestor(_ serializer: Serializer) throws {
        let parent = "parent@example.com"
        #expect(try receivedIdentity(Self.longUTF8Parent) == Self.longUTF8Parent)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [Self.longUTF8Parent, parent])
        let message = raw(draft, serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.references == [Self.longUTF8Parent, parent])
        #expect(metadata.inReplyTo == parent)
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
