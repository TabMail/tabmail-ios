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

    /// RFC 5322 §2.1.1 asks for lines of at most 78 characters. An identifier that
    /// fits a line of its own, but not after its field's name, starts the next line.
    @Test("A Message-ID that would take its field's first line past 78 octets starts the next line",
          arguments: Serializer.allCases, [67, 76])
    func messageIDCountedAfterTheFieldName(_ serializer: Serializer, bracketedLength: Int) throws {
        let parent = String(repeating: "m", count: bracketedLength - 2 - "@example.com".utf8.count) + "@example.com"
        #expect("<\(parent)>".utf8.count == bracketedLength)
        #expect("References: <\(parent)>".utf8.count > 78)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [parent])
        let message = raw(draft, serializer)
        let lines = headerLines(message)
        for name in ["In-Reply-To", "References"] {
            let start = try #require(lines.firstIndex { $0.hasPrefix(name + ":") })
            let fieldLines = [lines[start]] + lines[(start + 1)...].prefix { $0.hasPrefix(" ") }
            #expect(fieldLines.allSatisfy { $0.utf8.count <= 78 }, "\(fieldLines)")
            #expect(fieldLines.last == " <\(parent)>", "\(fieldLines)")
        }
        let metadata = try readBack(message)
        #expect(metadata.inReplyTo == parent)
        #expect(metadata.references == [parent])
    }

    /// The soft limit is inclusive: a field line of exactly 78 octets is within it,
    /// so it is written on one line.
    @Test("A thread header line of exactly 78 octets stays on one line", arguments: Serializer.allCases)
    func exactlySoftLimitUnfolded(_ serializer: Serializer) {
        let first = String(repeating: "f", count: 78 - "References: <".utf8.count - "@example.com> <b@example.com>".utf8.count) + "@example.com"
        let referencesLine = "References: <\(first)> <b@example.com>"
        #expect(referencesLine.utf8.count == 78)
        let parent = String(repeating: "i", count: 78 - "In-Reply-To: <".utf8.count - "@example.com>".utf8.count) + "@example.com"
        let inReplyToLine = "In-Reply-To: <\(parent)>"
        #expect(inReplyToLine.utf8.count == 78)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [first, "b@example.com"])
        let lines = headerLines(raw(draft, serializer))
        #expect(lines.contains(referencesLine), "\(lines)")
        #expect(lines.contains(inReplyToLine), "\(lines)")
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

    /// Forty recipients of about 40 octets each: one `To:` line of them is about
    /// 1,700 octets (#430).
    private static let recipients = (0..<40).map { "recipient-\($0)-" + String(repeating: "r", count: 12) + "@example.com" }

    @Test("Long To, Cc and Bcc lists are folded and read back whole, in order",
          arguments: Serializer.allCases)
    func longRecipientLists(_ serializer: Serializer) throws {
        #expect(("To: " + Self.recipients.joined(separator: ", ")).utf8.count > Self.hardLineLimit)
        let draft = DraftMessage(
            to: Self.recipients, cc: Self.recipients.map { "cc-" + $0 }, bcc: Self.recipients.map { "bcc-" + $0 },
            subject: "Hello", body: "body")
        let message = raw(draft, serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.to.map(\.email) == Self.recipients)
        #expect(metadata.cc.map(\.email) == Self.recipients.map { "cc-" + $0 })
        #expect(metadata.bcc.map(\.email) == Self.recipients.map { "bcc-" + $0 })
    }

    /// Twenty-seven recipients whose addresses shrink from 71 to 19 octets. Each fold
    /// depends on the length already on the line, so a fold that stopped counting the
    /// addresses still folds after the long ones and then leaves the short ones on one
    /// line of over 1,200 octets; uniform addresses do not show that.
    private static let shrinkingRecipients = (0..<27).map { index -> String in
        let length = 71 - (71 - 19) * index / 26
        let local = "r\(index)-"
        return local + String(repeating: "r", count: length - local.count - "@example.com".count) + "@example.com"
    }

    @Test("Recipient lists of shrinking addresses are folded by the length on the line",
          arguments: Serializer.allCases)
    func shrinkingRecipientLists(_ serializer: Serializer) throws {
        #expect(Self.shrinkingRecipients.first?.utf8.count == 71)
        #expect(Self.shrinkingRecipients.last?.utf8.count == 19)
        #expect(("To: " + Self.shrinkingRecipients.joined(separator: ", ")).utf8.count > Self.hardLineLimit)
        let cc = Self.shrinkingRecipients.map { "cc-" + $0 }
        let bcc = Self.shrinkingRecipients.map { "bcc-" + $0 }
        let draft = DraftMessage(to: Self.shrinkingRecipients, cc: cc, bcc: bcc, subject: "Hello", body: "body")
        let message = raw(draft, serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.to.map(\.email) == Self.shrinkingRecipients)
        #expect(metadata.cc.map(\.email) == cc)
        #expect(metadata.bcc.map(\.email) == bcc)
    }

    enum Field: String, CaseIterable {
        case to = "To", cc = "Cc", bcc = "Bcc"

        func draft(_ recipients: [String]) -> DraftMessage {
            switch self {
            case .to: DraftMessage(to: recipients, subject: "Hello", body: "body")
            case .cc: DraftMessage(to: ["you@example.com"], cc: recipients, subject: "Hello", body: "body")
            case .bcc: DraftMessage(to: ["you@example.com"], bcc: recipients, subject: "Hello", body: "body")
            }
        }

        func recipients(_ metadata: MessageMetadata) -> [EmailAddress] {
            switch self {
            case .to: metadata.to
            case .cc: metadata.cc
            case .bcc: metadata.bcc
            }
        }
    }

    /// A send queued by an earlier version can carry a named recipient. One whose
    /// name fills the field's first line to exactly 998 octets still needs the comma
    /// before the next recipient, which must not land on that line.
    @Test("A first recipient that fills the field's line keeps its comma within the limit",
          arguments: Serializer.allCases, Field.allCases)
    func firstRecipientFillingTheLine(_ serializer: Serializer, field: Field) throws {
        let name = String(repeating: "N", count: Self.hardLineLimit - "\(field.rawValue): ".utf8.count - " <a@example.com>".utf8.count)
        #expect("\(field.rawValue): \(name) <a@example.com>".utf8.count == Self.hardLineLimit)
        let message = raw(field.draft(["\(name) <a@example.com>", "b@example.com"]), serializer)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let written = field.recipients(try readBack(message))
        #expect(written.map(\.email) == ["a@example.com", "b@example.com"])
        #expect(written.first?.name == name)
    }

    /// RFC 5322 §2.1.1 asks for lines of at most 78 characters. A recipient that
    /// fills the first line to exactly 78 octets leaves no room for its comma.
    @Test("A recipient whose comma would pass 78 octets starts the next line",
          arguments: Serializer.allCases, Field.allCases)
    func commaCountedAgainstTheSoftLimit(_ serializer: Serializer, field: Field) throws {
        let prefix = "\(field.rawValue): "
        let local = String(repeating: "s", count: 78 - prefix.utf8.count - "@example.com".utf8.count)
        let first = local + "@example.com"
        #expect((prefix + first).utf8.count == 78)
        let message = raw(field.draft([first, "b@example.com"]), serializer)
        let lines = headerLines(message)
        let fieldStart = try #require(lines.firstIndex { $0.hasPrefix(field.rawValue + ":") })
        let fieldLines = [lines[fieldStart]] + lines[(fieldStart + 1)...].prefix { $0.hasPrefix(" ") }
        #expect(fieldLines.allSatisfy { $0.utf8.count <= 78 }, "\(fieldLines)")
        #expect(field.recipients(try readBack(message)).map(\.email) == [first, "b@example.com"])
    }

    /// The soft limit is inclusive: a recipient line of exactly 78 octets, its comma
    /// counted, is within it, so it is written on one line.
    @Test("A recipient line of exactly 78 octets stays on one line",
          arguments: Serializer.allCases, Field.allCases)
    func recipientLineAtTheSoftLimit(_ serializer: Serializer, field: Field) throws {
        let prefix = "\(field.rawValue): "
        let second = "b@example.com"
        let first = String(repeating: "s", count: 78 - prefix.utf8.count - ", ".utf8.count - second.utf8.count - "@example.com".utf8.count) + "@example.com"
        let line = prefix + first + ", " + second
        #expect(line.utf8.count == 78)
        let message = raw(field.draft([first, second]), serializer)
        #expect(headerLines(message).contains(line), "\(headerLines(message))")
        #expect(field.recipients(try readBack(message)).map(\.email) == [first, second])
    }

    /// A reply can copy a UTF-8 address from a received header (RFC 6532), and one
    /// can hold far more octets than characters. The line limit counts octets, so a
    /// fold measured in characters would leave it on the line after a short ASCII
    /// recipient, and the next recipient on its line.
    @Test("A UTF-8 recipient after an ASCII one is folded by octets",
          arguments: Serializer.allCases, Field.allCases)
    func utf8RecipientFoldedByOctets(_ serializer: Serializer, field: Field) throws {
        let lead = String(repeating: "a", count: 44) + "@example.com"
        let list = [lead, Self.longUTF8Parent, "b@example.com"]
        let message = raw(field.draft(list), serializer)
        let longest = headerLines(message).map { $0.utf8.count }.max() ?? 0
        #expect(longest <= Self.hardLineLimit, "longest header line \(longest) octets")
        #expect(field.recipients(try readBack(message)).map(\.email) == list)
    }

    /// `DraftStore` saves an unfinished draft whose To list can still be empty.
    @Test("A draft with no recipients names none", arguments: Serializer.allCases)
    func draftWithoutRecipients(_ serializer: Serializer) throws {
        let message = raw(DraftMessage(to: [], subject: "Draft", body: "body"), serializer)
        let metadata = try readBack(message)
        #expect(metadata.to.isEmpty)
        #expect(metadata.cc.isEmpty)
        #expect(metadata.bcc.isEmpty)
        let lines = headerLines(message)
        #expect(lines.contains { $0.hasPrefix("Subject:") }, "the header section was not read")
        #expect(lines.contains { $0.hasPrefix("To:") }, "control: the To field the scan below reads is written")
        var inRecipientField = false
        for line in lines {
            if !line.hasPrefix(" ") { inRecipientField = ["To:", "Cc:", "Bcc:"].contains { line.hasPrefix($0) } }
            #expect(!(inRecipientField && line.contains("@")), "an address was written into a draft that names none: \(line)")
        }
    }

    @Test("A short recipient list stays on one line", arguments: Serializer.allCases)
    func shortRecipientsUnfolded(_ serializer: Serializer) {
        let draft = DraftMessage(
            to: ["a@example.com", "b@example.com"], cc: ["c@example.com"], subject: "Hello", body: "body")
        let lines = headerLines(raw(draft, serializer))
        #expect(lines.contains("To: a@example.com, b@example.com"))
        #expect(lines.contains("Cc: c@example.com"))
    }
}
