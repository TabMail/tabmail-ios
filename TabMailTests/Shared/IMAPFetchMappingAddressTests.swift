/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

/// How an IMAP message's address fields become the strings TabMail stores and
/// shows. SwiftMail's `from` / `to` strings are RFC 5322 header text — quoted,
/// escaped, groups ending in `;`, every From author joined — so the app reads the
/// structured entries instead and writes them in its own shape.
@Suite("IMAPFetchMapping addresses")
struct IMAPFetchMappingAddressTests {

    private func info(from: [AddressListEntry] = [], to: [AddressListEntry] = []) -> MessageInfo {
        var info = MessageInfo(sequenceNumber: SequenceNumber(1))
        info.fromAddresses = from
        info.toAddresses = to
        return info
    }

    private func mailbox(_ address: String, name: String? = nil) -> AddressListEntry {
        .mailbox(SwiftMail.EmailAddress(name: name, address: address))
    }

    // MARK: - Sender

    @Test("The sender is the first From mailbox, by its display name as written")
    func senderIsFirstMailboxByName() throws {
        let sender = try #require(IMAPFetchMapping.sender(from: info(from: [
            mailbox("jane@example.com", name: #"Jane "JJ" Doe, PhD"#),
            mailbox("bob@example.com", name: "Bob")
        ])))
        #expect(sender.name == #"Jane "JJ" Doe, PhD"#)
        #expect(sender.email == "jane@example.com")
    }

    @Test("A sender with no display name is listed by address")
    func senderWithoutNameUsesAddress() throws {
        let sender = try #require(IMAPFetchMapping.sender(from: info(from: [mailbox("jane@example.com")])))
        #expect(sender.name == "jane@example.com")
        #expect(sender.email == "jane@example.com")
    }

    @Test("A From group is listed under its first member")
    func senderFromGroupIsFirstMember() throws {
        let sender = try #require(IMAPFetchMapping.sender(from: info(from: [
            .group(name: "Team", members: [SwiftMail.EmailAddress(name: "Ann", address: "ann@example.com")])
        ])))
        #expect(sender.name == "Ann")
        #expect(sender.email == "ann@example.com")
    }

    @Test("A From with no valid mailbox shows its text, with no address")
    func invalidSenderShowsTextWithoutAddress() throws {
        let sender = try #require(IMAPFetchMapping.sender(from: info(from: [.invalid("Mailer Daemon <<broken")])))
        #expect(sender.name == "Mailer Daemon <<broken")
        #expect(sender.email == "")
    }

    @Test("A message with no From has no sender")
    func noFromHasNoSender() {
        #expect(IMAPFetchMapping.sender(from: info()) == nil)
    }

    // MARK: - Address fields

    @Test("Address fields store one entry per mailbox, groups flattened to members")
    func groupsFlattenToMembers() {
        let field = IMAPFetchMapping.addressField([
            .group(name: "Team", members: [
                SwiftMail.EmailAddress(address: "ann@example.com"),
                SwiftMail.EmailAddress(name: "Doe, Jane", address: "jane@example.com")
            ]),
            mailbox("bob@example.com")
        ])
        #expect(field == #"ann@example.com, "Doe, Jane" <jane@example.com>, bob@example.com"#)
        // The stored field reads back to exactly the three addresses.
        #expect(AddressParser.parseAddressList(field).flatMap(\.mailboxes).map(\.address)
            == ["ann@example.com", "jane@example.com", "bob@example.com"])
    }

    @Test("A display name holding quotes, backslashes, commas or an address reads back as that one mailbox")
    func craftedDisplayNamesReadBackAsOneMailbox() {
        let names = [
            #"x" <me@example.com>, "y"#,
            #"Back\slash, "Q""#,
            "Trailing\\",
            "q\"\u{301} <me@example.com>, \"z"
        ]
        let entries = names.enumerated().map { index, name in
            mailbox("user\(index)@example.com", name: name)
        }
        let field = IMAPFetchMapping.addressField(entries)
        #expect(AddressParser.parseAddressList(field) == entries)
        let members = entries.flatMap(\.mailboxes)
        let groupField = IMAPFetchMapping.addressField([.group(name: "Team", members: members)])
        #expect(AddressParser.parseAddressList(groupField).flatMap(\.mailboxes) == members)
        #expect(IMAPFetchMapping.addressField([mailbox("bob@example.com", name: #"x" <me@example.com>, "y"#)])
            == #""x\" <me@example.com>, \"y" <bob@example.com>"#)
    }

    @Test("An empty group contributes nothing")
    func emptyGroupContributesNothing() {
        #expect(IMAPFetchMapping.addressField([.group(name: "undisclosed-recipients", members: [])]) == "")
    }

    @Test("Invalid entries stay visible in the field")
    func invalidEntriesStayVisible() {
        let field = IMAPFetchMapping.addressField([mailbox("ann@example.com"), .invalid("foo@@example.com")])
        #expect(AddressParser.parseAddressList(field) == [mailbox("ann@example.com"), .invalid("foo@@example.com")])
        #expect(MessageViewHelpers.extractNames(field) == "ann@example.com, foo@@example.com")
    }

    /// Invalid text that reads back as itself alone can still hold an unclosed
    /// `"`; joined into the field, that quote must not swallow the quoting of
    /// the crafted name after it.
    @Test("An unclosed quote in invalid text leaves the next mailbox whole", arguments: [
        #"x"@company.com."#, "x\"\u{1}@company.com"
    ])
    func unclosedQuoteInInvalidTextStaysInside(text: String) {
        let crafted = SwiftMail.EmailAddress(name: "y <hidden@example.com>, z", address: "bob@example.com")
        let field = IMAPFetchMapping.addressField([.invalid(text), .mailbox(crafted)])
        let entries = AddressParser.parseAddressList(field)
        #expect(entries.count == 2)
        #expect(entries.flatMap(\.mailboxes) == [crafted])
        #expect(PromptVariables.classifyRecipientStatus(toField: "other@example.com", ccField: field,
            fromField: "sender@example.com", claimEmails: ["hidden@example.com"]) == "")
        #expect(PromptVariables.classifyRecipientStatus(toField: "other@example.com", ccField: field,
            fromField: "sender@example.com", claimEmails: ["bob@example.com"]) == "cc")
    }

    /// An incomplete ENVELOPE address can carry a quoted local-part holding
    /// commas and an address; SwiftMail reads it as invalid text, and so must
    /// every reader of the stored field.
    @Test("Invalid text that would read back as a mailbox is stored quoted, still visible")
    func invalidTextNeverReadsBackAsMailbox() {
        let text = "a, <hidden@example.com>, b@company.com."
        let field = IMAPFetchMapping.addressField([mailbox("ann@example.com"), .invalid(text)])
        #expect(AddressParser.parseAddressList(field) == [mailbox("ann@example.com"), .invalid(text)])
        #expect(MessageViewHelpers.extractNames(field) == "ann@example.com, \(text)")
    }

    @Test("A carried message's header block uses the same address shape")
    func envelopeUsesStoredShape() {
        var carried = info(
            from: [mailbox("jane@example.com", name: "Jane")],
            to: [.group(name: "Team", members: [SwiftMail.EmailAddress(address: "ann@example.com")])]
        )
        carried.ccAddresses = [mailbox("bob@example.com")]
        let envelope = IMAPFetchMapping.envelope(of: carried)
        #expect(envelope.from == #""Jane" <jane@example.com>"#)
        #expect(envelope.to == ["ann@example.com"])
        #expect(envelope.cc == ["bob@example.com"])
    }
}
