/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

/// Both IMAP writers — the main app's `IMAPProvider.mapMessageInfo` and the
/// NSE's `NSEIMAPConnection.mapInfoToMetadata` — store address fields a display
/// name cannot break: a crafted name holding quotes, a comma and an address
/// reads back as the one mailbox it belongs to, in To, a Cc group and Bcc, and
/// an incomplete address — whose quoted local-part holds an address, or an
/// unclosed quote ahead of the crafted name — stays text.
///
/// `.serialized` — each test binds a listening socket for the fake server.
@Suite("IMAP writers store escaped mailbox text", .serialized)
struct IMAPWriterEscapedMailboxTests {

    private static let crafted = #"x" <hidden@example.com>, "y"#
    private static let messageID = "<escaped-names@example.com>"

    /// RFC 5322 `Date:` header, generated from the current clock — never a
    /// literal, so it cannot go stale (Testing Rule 7).
    private static let rfc5322DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    /// The same names in the RFC 5322 header and the ENVELOPE: To is one named
    /// mailbox, Cc a group of one between two addresses whose host is no domain
    /// (SwiftMail reads each as invalid text; the first's local-part is an
    /// unclosed quote), Bcc one named mailbox (RFC 3501 §7.4.2).
    private func startServer() throws -> FakeIMAPServer {
        let date = Self.rfc5322DateFormatter.string(from: Date())
        let quotedName = #""x\" <hidden@example.com>, \"y""#
        let raw = """
        From: Sender <sender@example.com>\r
        To: \(quotedName) <bob@example.com>\r
        Cc: "x\\""@company.com., Team: \(quotedName) <ann@example.com>;, "a, <hidden@example.com>, b"@company.com.\r
        Bcc: \(quotedName) <bex@example.com>\r
        Subject: Escaped names\r
        Date: \(date)\r
        Message-ID: \(Self.messageID)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        SYNTHETIC BODY\r

        """
        let from = #"(("Sender" NIL "sender" "example.com"))"#
        let to = "((\(quotedName) NIL \"bob\" \"example.com\"))"
        let cc = "((NIL NIL \"x\\\"\" \"company.com.\") (NIL NIL \"Team\" NIL) (\(quotedName) NIL \"ann\" \"example.com\") (NIL NIL NIL NIL)"
            + " (NIL NIL \"a, <hidden@example.com>, b\" \"company.com.\"))"
        let bcc = "((\(quotedName) NIL \"bex\" \"example.com\"))"
        let parsed = FakeIMAPServer.makeMessage(uid: 101, rfc822Text: raw)
        // The main-app fetch reads numeric section 1 even for a flat text/plain body.
        let message = FakeIMAPServer.Message(
            uid: parsed.uid, raw: parsed.raw, subject: parsed.subject, from: parsed.from,
            to: parsed.to, date: parsed.date, internalDate: parsed.internalDate,
            messageID: parsed.messageID, contentType: parsed.contentType, charset: parsed.charset,
            body: parsed.body, headerData: parsed.headerData, customBodystructure: nil,
            partBodies: ["1": parsed.body],
            customEnvelope: "(\"\(date)\" \"Escaped names\" \(from) \(from) \(from) \(to) \(cc) \(bcc) NIL \"\(Self.messageID)\")"
        )
        let server = FakeIMAPServer(messages: [message])
        try server.start()
        return server
    }

    private func expectOneMailboxEach(to: String, cc: String, bcc: String) {
        for (field, address) in [(to, "bob@example.com"), (cc, "ann@example.com"), (bcc, "bex@example.com")] {
            #expect(AddressParser.parseAddressList(field).flatMap(\.mailboxes)
                == [SwiftMail.EmailAddress(name: Self.crafted, address: address)])
        }
        #expect(PromptVariables.classifyRecipientStatus(toField: to, ccField: cc,
            fromField: "sender@example.com", claimEmails: ["hidden@example.com"]) == "")
        #expect(PromptVariables.classifyRecipientStatus(toField: to, ccField: cc,
            fromField: "sender@example.com", claimEmails: ["ann@example.com"]) == "cc")
    }

    @Test("The main-app writer keeps each crafted name inside its own mailbox")
    func mainAppWriter() async throws {
        let server = try startServer()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
        let info: FullMessageInfo
        do {
            try await provider.connect()
            info = try await provider.fetchMessage(id: "101", folder: "INBOX")
            try await provider.disconnect()
        } catch {
            try? await provider.disconnect()
            throw error
        }
        #expect(info.header.messageId == "101")
        expectOneMailboxEach(to: info.header.to, cc: info.header.cc, bcc: info.header.bcc)
    }

    @Test("The NSE writer keeps each crafted name inside its own mailbox")
    func nseWriter() async throws {
        let server = try startServer()
        defer { server.stop() }
        let result = try #require(await NSEIMAPConnection.fetch(
            accountId: "acc1",
            host: "127.0.0.1",
            port: server.port,
            useTLS: false,
            username: server.username,
            password: server.password,
            rfc822MessageId: Self.messageID
        ))
        #expect(result.metadata.messageId == "101")
        expectOneMailboxEach(to: result.metadata.to, cc: result.metadata.cc, bcc: result.metadata.bcc)
    }
}
