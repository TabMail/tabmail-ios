/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

/// A compose recipient field is a list of addresses, never free text
/// (ADR-IOS-092): typed, pasted, prefilled, reopened and reply text is split
/// into addresses, and text that names none never becomes a recipient.
@Suite("Recipient fields are lists of addresses")
struct RecipientEntryTests {
    private static func header(from: String = "sender@example.com", name: String = "", replyTo: String? = nil) -> MessageHeader {
        var header = MessageHeader(
            messageId: "100", subject: "Test", from: name.isEmpty ? from : name, fromAddress: from,
            to: "me@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.replyTo = replyTo
        return header
    }

    // MARK: - Splitting

    @Test("Text naming several addresses splits into one recipient each", arguments: [
        ("a@example.com, b@example.com", ["a@example.com", "b@example.com"]),
        ("a@example.com; b@example.com", ["a@example.com", "b@example.com"]),
        ("a@example.com\nb@example.com", ["a@example.com", "b@example.com"]),
        ("\"Doe, Bob\" <bob@example.com>, Ann <ann@example.com>", ["bob@example.com", "ann@example.com"]),
        ("Team: a@example.com, b@example.com;", ["a@example.com", "b@example.com"]),
        ("a@example.com, A@EXAMPLE.COM", ["a@example.com"]),
        ("\"Doe; Bob\" <bob@example.com>; Team: a@example.com; ann@example.com", ["bob@example.com", "a@example.com", "ann@example.com"])
    ])
    func splitsIntoAddresses(text: String, expected: [String]) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == expected)
        #expect(entry.unparsed.isEmpty)
    }

    @Test("Text that names no sendable address is kept as text, never as a recipient", arguments: [
        ("bob", [String](), "bob"),
        ("bob, carol@example.com", ["carol@example.com"], "bob"),
        ("local@localhost", [], "local@localhost"),
        ("foo@@example.com, ann@example.com", ["ann@example.com"], "foo@@example.com")
    ])
    func keepsTextThatIsNotAnAddress(text: String, addresses: [String], unparsed: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == addresses)
        #expect(entry.unparsed == unparsed)
    }

    @Test("An empty group names nobody and adds nothing")
    func emptyGroupAddsNothing() {
        let entry = RecipientEntry("undisclosed-recipients:;")
        #expect(entry.recipients.isEmpty)
        #expect(entry.unparsed.isEmpty)
    }

    @Test("Display names come with their addresses")
    func keepsDisplayNames() {
        let entry = RecipientEntry("\"Doe, Bob\" <bob@example.com>, ann@example.com")
        #expect(entry.recipients.map(\.name) == ["Doe, Bob", nil])
    }

    /// The property the whole change exists for: every recipient a field holds
    /// is one address every send path accepts, so no send can refuse it.
    @Test("Every recipient a field holds is accepted by the send path", arguments: [
        "a@example.com, b@example.com",
        "\"Doe, Bob\" <bob@example.com>; Ann <ann@example.com>",
        "Team: a@example.com, b@example.com;",
        "a@example.com\r\nBcc: hidden@example.com",
        "bob, carol@example.com, local@localhost, x@@y.example.com",
        "J\u{F6}rg <joerg@example.com>"
    ])
    func everyRecipientIsSendable(text: String) throws {
        let addresses = RecipientEntry(text).addresses
        #expect(!addresses.isEmpty)
        #expect(try IMAPProvider.sendableRecipients(addresses).map(\.address) == addresses)
        for address in addresses { #expect(isValidEmailAddress(address), "\(address)") }
    }

    // MARK: - Replies

    /// Gmail keeps the raw Reply-To header, which can name several mailboxes.
    @Test("A reply goes to every mailbox its Reply-To names, and Gmail writes each one")
    func replyGoesToEveryReplyToMailbox() throws {
        let entry = RecipientEntry.reply(to: Self.header(
            replyTo: "Alice <alice@example.com>, \"Doe, Bob\" <bob@example.com>"))
        #expect(entry.addresses == ["alice@example.com", "bob@example.com"])
        #expect(entry.recipients.map(\.name) == ["Alice", "Doe, Bob"])

        let gmail = GmailProvider(userEmail: "me@example.com", accessToken: { _ in "tok" })
        let raw = gmail.buildRFC822(draft: DraftMessage(to: entry.addresses, subject: "Re: Test", body: "Body"))
        let toLines = raw.components(separatedBy: "\r\n").filter { $0.hasPrefix("To: ") }
        #expect(toLines == ["To: alice@example.com, bob@example.com"])
    }

    @Test("A reply with no Reply-To goes to the sender, under the sender's name")
    func replyWithoutReplyToGoesToSender() {
        let entry = RecipientEntry.reply(to: Self.header(name: "Sender Name"))
        #expect(entry.addresses == ["sender@example.com"])
        #expect(entry.recipients.map(\.name) == ["Sender Name"])
    }

    @Test("A Reply-To that names no mailbox goes to the input line, not to a recipient")
    func replyToWithoutMailbox() {
        let field = ComposeDraftGuards.fieldState(RecipientEntry.reply(to: Self.header(replyTo: "nobody")))
        #expect(field.tokens.isEmpty)
        #expect(field.input == "nobody")
    }

    // MARK: - The input line

    private static let field = ComposeDraftGuards.RecipientField(
        tokens: ["old@example.com"], displayNames: ["old@example.com": "Old"], input: "")

    @Test("A typed or pasted list adds each address and clears the input line")
    func committingAddsEachAddress() throws {
        let result = try #require(ComposeDraftGuards.committing(
            "Ann <ann@example.com>, bob@example.com,", to: Self.field, room: 10))
        #expect(result.tokens == ["old@example.com", "ann@example.com", "bob@example.com"])
        #expect(result.displayNames == ["old@example.com": "Old", "ann@example.com": "Ann"])
        #expect(result.input.isEmpty)
    }

    @Test("Text that names no address leaves the field exactly as it was", arguments: [
        "bob,", "\"Doe, J", "ann@exa", "  "
    ])
    func committingNothingChangesNothing(text: String) {
        #expect(ComposeDraftGuards.committing(text, to: Self.field, room: 10) == nil)
    }

    @Test("Text beside an address stays in the input line")
    func committingKeepsLeftoverText() throws {
        let result = try #require(ComposeDraftGuards.committing("bob, ann@example.com", to: Self.field, room: 10))
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(result.input == "bob")
    }

    @Test("Addresses over the recipient cap stay in the input line")
    func committingRespectsTheCap() throws {
        let result = try #require(ComposeDraftGuards.committing(
            "a@example.com, b@example.com, c@example.com", to: Self.field, room: 1))
        #expect(result.tokens == ["old@example.com", "a@example.com"])
        #expect(result.input == "b@example.com, c@example.com")
    }

    @Test("An address already in the field moves to the end without using the cap")
    func committingMovesAnExistingAddress() throws {
        var field = Self.field
        field.tokens.append("ann@example.com")
        let result = try #require(ComposeDraftGuards.committing("OLD@example.com,", to: field, room: 0))
        #expect(result.tokens == ["ann@example.com", "OLD@example.com"])
    }

    @Test("While typing, only the text up to the last separator is split", arguments: [
        ("a@example.com", "a@example.com,", "a@example.com,", ""),
        ("bob, carol@example.", "bob, carol@example.c", "bob,", " carol@example.c"),
        ("a@example.com; ", "a@example.com; b", "a@example.com;", " b")
    ])
    func typingSplitsUpToTheLastSeparator(old: String, text: String, split: String, typing: String) throws {
        let result = try #require(ComposeDraftGuards.inputToSplit(was: old, now: text))
        #expect(result.text == split)
        #expect(result.typing == typing)
    }

    @Test("A paste is split whole, and a line with no separator is not split")
    func pasteSplitsWhole() throws {
        let pasted = try #require(ComposeDraftGuards.inputToSplit(was: "", now: "a@example.com, b@example.com"))
        #expect(pasted.text == "a@example.com, b@example.com")
        #expect(pasted.typing.isEmpty)
        #expect(ComposeDraftGuards.inputToSplit(was: "a@example.co", now: "a@example.com") == nil)
    }

    /// The typing bug this guards: once `bob, ` sat in the input line, each
    /// keystroke re-split the whole line, so `carol@example.c` became a recipient
    /// before `om` was typed.
    @Test("A half-typed address after leftover text is never added")
    func halfTypedAddressIsNotAdded() throws {
        var field = ComposeDraftGuards.RecipientField()
        var line = ""
        for character in "bob, carol@example.com," {
            let old = line
            line.append(character)
            field.input = line
            if let split = ComposeDraftGuards.inputToSplit(was: old, now: line),
               let next = ComposeDraftGuards.committing(split.text, typing: split.typing, to: field, room: 10) {
                field = next
                line = next.input
            }
        }
        #expect(field.tokens == ["carol@example.com"])
        #expect(field.input == "bob")
    }

    @Test("Text still being typed stays after the leftover text")
    func committingKeepsTypedText() throws {
        let result = try #require(ComposeDraftGuards.committing(
            "bob, ann@example.com,", typing: " ca", to: Self.field, room: 10))
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(result.input == "bob, ca")
    }

    // MARK: - Drafts and Send

    /// A saved draft keeps text that names no address beside its addresses, so
    /// nothing typed is lost; reopening puts that text back in the input line.
    @Test("A saved field reopens with the same addresses and input text")
    func savedFieldRoundTrips() {
        let saved = ComposeDraftGuards.committedRecipients(tokens: ["a@example.com", "b@example.com"], input: "bob")
        let reopened = ComposeDraftGuards.fieldState(RecipientEntry(saved))
        #expect(reopened.tokens == ["a@example.com", "b@example.com"])
        #expect(reopened.input == "bob")
        #expect(ComposeDraftGuards.committedRecipients(tokens: reopened.tokens, input: reopened.input) == saved)
    }

    @Test("A draft saved as one comma-separated recipient reopens as separate addresses")
    func oldDraftReopensSplit() {
        let reopened = ComposeDraftGuards.fieldState(RecipientEntry(["Ann <ann@example.com>, bob@example.com"]))
        #expect(reopened.tokens == ["ann@example.com", "bob@example.com"])
        #expect(reopened.displayNames == ["ann@example.com": "Ann"])
        #expect(reopened.input.isEmpty)
    }

    @Test("Send is refused while an input line holds text that names no address")
    func sendRefusesUnaddressedText() {
        #expect(ComposeDraftGuards.unaddressedRecipientMessage(to: "", cc: " ", bcc: "") == nil)
        let message = ComposeDraftGuards.unaddressedRecipientMessage(to: "", cc: "bob", bcc: "")
        #expect(message?.contains("bob") == true)
        #expect(message?.contains("Cc") == true)
    }
}
