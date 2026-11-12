/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

/// No physical header line of a message sent, kept in Sent or saved as a draft
/// over IMAP/SMTP may pass 998 octets (RFC 5322 §2.1.1). SwiftMail writes the
/// In-Reply-To and References values verbatim, and a long thread's References
/// history passes 998 on one line, which some receiving servers bounce after
/// submission (#430). A reader that unfolds gets every identifier back in order.
/// The To, Cc and Bcc lines are SwiftMail's own (folded there since #447); a
/// literal ASCII Subject longer than the limit is not covered here (#465).
@Suite("IMAP thread headers stay within the line limit")
struct IMAPThreadHeaderFoldingTests {

    /// The three messages the IMAP path writes from one draft.
    enum Copy: String, CaseIterable {
        case sent, keptInSent, draft
    }

    private static let hardLineLimit = 998

    /// The sent message is built as SMTP sends it. The kept-in-Sent copy and the
    /// draft go through the real APPEND to a fake IMAP server, so SwiftMail's header
    /// check (`SMTPServer.checkHeaderFields`, run on APPEND as on send) sees the
    /// folded values, and the test reads the bytes the server stored.
    private func raw(_ draft: DraftMessage, _ copy: Copy) async throws -> String {
        switch copy {
        case .sent:
            return try IMAPProvider.buildEmail(from: draft, senderEmail: "me@example.com").constructContent()
        case .keptInSent, .draft:
            return try await stored(draft, copy)
        }
    }

    private func stored(_ draft: DraftMessage, _ copy: Copy) async throws -> String {
        let mailbox = copy == .draft ? "Drafts" : "Sent"
        let server = FakeIMAPServer(mailboxes: [mailbox: []])
        server.setUidValidity(81_430, for: mailbox)
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }
        var draft = draft
        draft.messageId = "fold-\(UUID().uuidString)@example.com"
        if copy == .draft {
            _ = try await provider.saveDraft(draft, existingIdentity: nil, draftsFolderPath: mailbox)
        } else {
            _ = try await provider.appendToSentFolder(
                draft: draft, sentFolderPath: mailbox, messageId: try #require(draft.messageId))
        }
        let stored = server.snapshotMessagesWithFlags(in: mailbox)
        #expect(stored.count == 1)
        return String(decoding: try #require(stored.first?.message.raw), as: UTF8.self)
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

    /// Fifteen identifiers of 80 octets each, the size of an ordinary Gmail or
    /// Outlook Message-ID: one line of them is about 1,230 octets.
    private static let ancestors = (0..<15).map { index -> String in
        let local = "ancestor-\(index)-"
        return local + String(repeating: "a", count: 80 - 2 - local.count - "@example.com".count) + "@example.com"
    }
    // "Message-ID: <id>" is a legal 998-octet line; "In-Reply-To: <id>" is one octet longer.
    private static let longParent = String(repeating: "p", count: 972) + "@example.com"
    /// As many octets in UTF-8 (RFC 6532 allows it), in far fewer characters, so a
    /// fold that counts characters instead of octets leaves the line too long.
    private static let longUTF8Parent = "q" + String(repeating: "\u{0301}", count: 485) + "q@example.com"

    @Test("A long References history is folded and reads back whole, in order",
          arguments: Copy.allCases)
    func longHistory(_ copy: Copy) async throws {
        #expect(Self.ancestors.allSatisfy { "<\($0)>".utf8.count == 80 })
        #expect(("References: " + Self.ancestors.map { "<\($0)>" }.joined(separator: " ")).utf8.count
            > Self.hardLineLimit)
        let parent = "parent@example.com"
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: Self.ancestors + [parent])
        let message = try await raw(draft, copy)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.references == Self.ancestors + [parent])
        #expect(metadata.inReplyTo == parent)
    }

    @Test("A parent Message-ID as long as a legal Message-ID line is kept whole",
          arguments: Copy.allCases, [Self.longParent, Self.longUTF8Parent])
    func longParentID(_ copy: Copy, parent: String) async throws {
        #expect("Message-ID: <\(parent)>".utf8.count == Self.hardLineLimit)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [parent])
        let message = try await raw(draft, copy)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        // The identifier is too long to share the field name's line, so the value
        // starts with a fold.
        #expect(message.contains("In-Reply-To: \r\n <\(parent)>\r\n"))
        let metadata = try readBack(message)
        #expect(metadata.inReplyTo == parent)
        #expect(metadata.references == [parent])
    }

    @Test("A long UTF-8 ancestor before a short parent is folded by octets",
          arguments: Copy.allCases)
    func longUTF8Ancestor(_ copy: Copy) async throws {
        let parent = "parent@example.com"
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [Self.longUTF8Parent, parent])
        let message = try await raw(draft, copy)
        #expect(headerLines(message).allSatisfy { $0.utf8.count <= Self.hardLineLimit })
        let metadata = try readBack(message)
        #expect(metadata.references == [Self.longUTF8Parent, parent])
        #expect(metadata.inReplyTo == parent)
    }

    /// RFC 5322 §2.1.1 asks for lines of at most 78 characters. An identifier that
    /// fits a line of its own, but not after its field's name, starts the next line.
    @Test("A Message-ID that would take its field's first line past 78 octets starts the next line",
          arguments: Copy.allCases, [67, 76])
    func messageIDCountedAfterTheFieldName(_ copy: Copy, bracketedLength: Int) async throws {
        let parent = String(repeating: "m", count: bracketedLength - 2 - "@example.com".utf8.count) + "@example.com"
        #expect("<\(parent)>".utf8.count == bracketedLength)
        #expect("References: <\(parent)>".utf8.count > 78)
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: parent, references: [parent])
        let message = try await raw(draft, copy)
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

    @Test("Short thread headers stay on one line each", arguments: Copy.allCases)
    func shortHeadersUnfolded(_ copy: Copy) async throws {
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: "b@example.com", references: ["a@example.com", "<b@example.com>"])
        let lines = headerLines(try await raw(draft, copy))
        #expect(lines.contains("In-Reply-To: <b@example.com>"))
        #expect(lines.contains("References: <a@example.com> <b@example.com>"))
    }

    /// SwiftMail's send check (`SMTPServer.checkHeaderFields`, internal to the
    /// library) unfolds CRLF-space and CRLF-tab and refuses a value with any CR or
    /// LF left, which would start a new header field. Every line break this path
    /// writes is a fold, so the folded headers pass that check.
    @Test("Every line break in the thread header values is a fold")
    func onlyFoldsInValues() throws {
        let draft = DraftMessage(
            to: ["you@example.com"], subject: "Re: thread", body: "reply",
            inReplyTo: Self.longParent, references: Self.ancestors + [Self.longParent])
        let email = try IMAPProvider.buildEmail(from: draft, senderEmail: "me@example.com")
        let references = try #require(email.additionalHeaders?["References"])
        let inReplyTo = try #require(email.additionalHeaders?["In-Reply-To"])
        #expect(references.contains("\r\n "))
        #expect(inReplyTo.hasPrefix("\r\n "))
        for value in [references, inReplyTo] {
            let unfolded = value
                .replacingOccurrences(of: "\r\n ", with: " ")
                .replacingOccurrences(of: "\r\n\t", with: "\t")
            #expect(!unfolded.unicodeScalars.contains { $0 == "\r" || $0 == "\n" })
        }
    }
}
