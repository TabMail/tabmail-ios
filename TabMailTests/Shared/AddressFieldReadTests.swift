/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// A From field value and the sender a message with it is listed under.
struct AddressFieldSenderRow: Sendable, CustomTestStringConvertible {
    let from: String
    let name: String
    let email: String
    var testDescription: String { from }
}

/// An address field value and the mailboxes it names, in order.
struct AddressFieldListRow: Sendable, CustomTestStringConvertible {
    let field: String
    let mailboxes: [EmailAddress]
    var testDescription: String { field }
}

private let senderRows: [AddressFieldSenderRow] = [
    // Ordinary forms.
    AddressFieldSenderRow(from: "John Doe <john@example.com>", name: "John Doe", email: "john@example.com"),
    AddressFieldSenderRow(from: "\"Doe, John\" <john@example.com>", name: "Doe, John", email: "john@example.com"),
    AddressFieldSenderRow(from: "john@example.com", name: "john@example.com", email: "john@example.com"),
    AddressFieldSenderRow(from: "<john@example.com>", name: "john@example.com", email: "john@example.com"),
    AddressFieldSenderRow(from: "  Alice   <alice@example.com>", name: "Alice", email: "alice@example.com"),
    AddressFieldSenderRow(from: "\"Bob Smith\" <bob@example.com>", name: "Bob Smith", email: "bob@example.com"),
    AddressFieldSenderRow(from: "\"O'Brien\" <ob@example.com>", name: "O'Brien", email: "ob@example.com"),
    AddressFieldSenderRow(from: "  user@example.com  ", name: "user@example.com", email: "user@example.com"),
    AddressFieldSenderRow(from: "  \"  Alice  \"  <alice@example.com>", name: "  Alice  ", email: "alice@example.com"),
    AddressFieldSenderRow(from: "Jean-Pierre Dupont <jp@example.net>", name: "Jean-Pierre Dupont", email: "jp@example.net"),
    AddressFieldSenderRow(from: "User <user+tag@example.com>", name: "User", email: "user+tag@example.com"),
    AddressFieldSenderRow(from: "admin@localhost", name: "admin@localhost", email: "admin@localhost"),
    AddressFieldSenderRow(from: String(repeating: "A", count: 200) + " <long@example.com>",
              name: String(repeating: "A", count: 200), email: "long@example.com"),
    AddressFieldSenderRow(from: "\"user@example.com >> User Name\" <user@example.com>",
              name: "user@example.com >> User Name", email: "user@example.com"),
    AddressFieldSenderRow(from: "", name: "", email: ""),
    AddressFieldSenderRow(from: "    ", name: "", email: ""),
    // A legacy `address (Name)` mailbox is named by its comment.
    AddressFieldSenderRow(from: "b@example.net (Ann)", name: "Ann", email: "b@example.net"),
    // An encoded-word is decoded as a display-name word.
    AddressFieldSenderRow(from: "=?UTF-8?B?5pel5pys?= <jp@example.com>", name: "日本", email: "jp@example.com"),
    // A comment is not part of the name.
    AddressFieldSenderRow(from: "Team (Engineering) <eng@example.com>", name: "Team", email: "eng@example.com"),
    // Text that is not one mailbox names no address: no part of it is guessed at.
    AddressFieldSenderRow(from: "Name <first@example.com> <second@example.net>",
              name: "Name <first@example.com> <second@example.net>", email: ""),
    AddressFieldSenderRow(from: "a > b <ab@example.com>", name: "a > b <ab@example.com>", email: ""),
    AddressFieldSenderRow(from: "plain > text", name: "plain > text", email: ""),
    AddressFieldSenderRow(from: "Name <", name: "Name <", email: ""),
    AddressFieldSenderRow(from: "MAILER-DAEMON", name: "MAILER-DAEMON", email: ""),
    AddressFieldSenderRow(from: "\"Ann <a@example.org>", name: "\"Ann <a@example.org>", email: ""),
    // A group with no members is listed under its name; several entries that
    // are no mailbox, under their texts joined.
    AddressFieldSenderRow(from: "undisclosed-recipients:;", name: "undisclosed-recipients", email: ""),
    AddressFieldSenderRow(from: "Team:;, Doe", name: "Team, Doe", email: ""),
    // A name's quoted, commented or encoded text is never read as an address.
    AddressFieldSenderRow(from: "\"Support <help@example.org>\" <other@example.net>",
              name: "Support <help@example.org>", email: "other@example.net"),
    AddressFieldSenderRow(from: "\"Ann \\\"x\\\" <a@example.org>\" <b@example.net>",
              name: "Ann \"x\" <a@example.org>", email: "b@example.net"),
    AddressFieldSenderRow(from: "\"\u{301}Ann <a@example.org>\" <b@example.net>",
              name: "\u{301}Ann <a@example.org>", email: "b@example.net"),
    AddressFieldSenderRow(from: "Ann (see <a@example.org>) <b@example.net>", name: "Ann", email: "b@example.net"),
    AddressFieldSenderRow(from: "Ann (a (b <x@example.org>) c) <b@example.net>", name: "Ann", email: "b@example.net"),
    AddressFieldSenderRow(from: "<b@example.net> (Ann <a@example.org>)", name: "b@example.net", email: "b@example.net"),
    AddressFieldSenderRow(from: "b@example.net (Ann <a@example.org>)", name: "Ann <a@example.org>", email: "b@example.net"),
    AddressFieldSenderRow(from: "Ann <\"a>b\"@example.net>", name: "Ann", email: "\"a>b\"@example.net"),
    AddressFieldSenderRow(from: "=?UTF-8?B?eCIgPG1lQGV4YW1wbGUuY29tPiwgInk=?= <bob@example.net>",
              name: "x\" <me@example.com>, \"y", email: "bob@example.net"),
    // Inside a quoted-string an encoded-word is literal text (RFC 2047 §5).
    AddressFieldSenderRow(from: "=?UTF-8?Q?x\"_<me@example.com>,_\"y?= <bob@example.net>",
              name: "=?UTF-8?Q?x_<me@example.com>,_y?=", email: "bob@example.net"),
    // A From that names several mailboxes is listed under the first.
    AddressFieldSenderRow(from: "a@example.org, Bob <b@example.net>", name: "a@example.org", email: "a@example.org"),
    AddressFieldSenderRow(from: "Doe, John <john@example.com>", name: "John", email: "john@example.com"),
    AddressFieldSenderRow(from: "Team: a@example.org, b@example.net;", name: "a@example.org", email: "a@example.org"),
]

private func mailbox(_ address: String, _ name: String? = nil) -> EmailAddress {
    EmailAddress(name: name ?? address, email: address)
}

private let listRows: [AddressFieldListRow] = [
    AddressFieldListRow(field: "\"Ann \\\", <a@example.org>\" <b@example.net>, c@example.net",
            mailboxes: [mailbox("b@example.net", "Ann \", <a@example.org>"), mailbox("c@example.net")]),
    AddressFieldListRow(field: "Ann (x, y) <a@example.org>, b@example.net",
            mailboxes: [mailbox("a@example.org", "Ann"), mailbox("b@example.net")]),
    AddressFieldListRow(field: "=?UTF-8?B?eCIgPG1lQGV4YW1wbGUuY29tPiwgInk=?= <bob@example.net>, c@example.net",
            mailboxes: [mailbox("bob@example.net", "x\" <me@example.com>, \"y"), mailbox("c@example.net")]),
    AddressFieldListRow(field: "Team: a@example.org, b@example.net;, c@example.net",
            mailboxes: [mailbox("a@example.org"), mailbox("b@example.net"), mailbox("c@example.net")]),
    AddressFieldListRow(field: "Doe, John <john@example.com>", mailboxes: [mailbox("john@example.com", "John")]),
]

/// A Gmail `users.messages.get` response carrying `headers`.
private func gmailMetadata(_ headers: [(String, String)]) -> MessageMetadata? {
    let millis = Int64(Date().timeIntervalSince1970 * 1000)
    let json: [String: Any] = [
        "id": "m1",
        "internalDate": String(millis),
        "payload": ["headers": headers.map { ["name": $0.0, "value": $0.1] }],
    ]
    return GmailParse.parseMessage(json)
}

/// A message built from raw RFC 5322 header fields.
private func rawMetadata(_ headers: [String: String]) -> MessageMetadata? {
    RFC5322Parse.buildMetadata(uid: "1", headers: headers, internalDate: Date(), flags: [], hasAttachments: false)
}

/// Gmail and raw RFC 5322 headers read every address field whole, with
/// SwiftMail's parser: structure first (quoted-strings, comments, angle-addrs,
/// list commas), encoded-words decoded only as display-name words after that.
@Suite("Address fields are read structure first")
struct AddressFieldReadTests {

    @Test("A message is listed under the first mailbox of its From", arguments: senderRows)
    func sender(_ row: AddressFieldSenderRow) throws {
        let expected = EmailAddress(name: row.name, email: row.email)
        let gmail = try #require(gmailMetadata([("From", row.from)]))
        #expect(gmail.from == expected)
        let raw = try #require(rawMetadata(["From": row.from]))
        #expect(raw.from == expected)
    }

    @Test("An address list splits only at commas outside names", arguments: listRows)
    func recipients(_ row: AddressFieldListRow) throws {
        let gmail = try #require(gmailMetadata([("To", row.field), ("Cc", row.field), ("Bcc", row.field)]))
        let raw = try #require(rawMetadata(["To": row.field, "Cc": row.field, "Bcc": row.field]))
        for metadata in [gmail, raw] {
            #expect(metadata.to == row.mailboxes)
            #expect(metadata.cc == row.mailboxes)
            #expect(metadata.bcc == row.mailboxes)
        }
    }

    @Test("Reply-To names its first mailbox", arguments: listRows)
    func replyTo(_ row: AddressFieldListRow) throws {
        let first = row.mailboxes.first
        let gmail = try #require(gmailMetadata([("Reply-To", row.field)]))
        #expect(gmail.replyTo == first)
        let raw = try #require(rawMetadata(["Reply-To": row.field]))
        #expect(raw.replyTo == first)
    }

    @Test("A message with no Reply-To has none")
    func noReplyTo() throws {
        let gmail = try #require(gmailMetadata([("From", "john@example.com")]))
        #expect(gmail.replyTo == nil)
        let raw = try #require(rawMetadata(["From": "john@example.com"]))
        #expect(raw.replyTo == nil)
    }
}
