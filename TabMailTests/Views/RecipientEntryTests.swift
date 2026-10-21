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
        ("\"Doe; Bob\" <bob@example.com>; Team: a@example.com; ann@example.com", ["bob@example.com", "a@example.com", "ann@example.com"]),
        // A pasted column or row: the field turns line breaks into spaces and keeps tabs.
        ("a@example.com b@example.com", ["a@example.com", "b@example.com"]),
        ("a@example.com\tb@example.com", ["a@example.com", "b@example.com"]),
        ("Ann <ann@example.com> Bob Lee <bob@example.com>", ["ann@example.com", "bob@example.com"]),
        // Quoted-pairs and comments hold no separator.
        ("\"Doe \\\" Bob\" <bob@example.com>; ann@example.com", ["bob@example.com", "ann@example.com"]),
        ("bob@example.com (work); ann@example.com", ["bob@example.com", "ann@example.com"]),
        ("bob@example.com (a (b) c; d); ann@example.com", ["bob@example.com", "ann@example.com"]),
        // A comment after an address belongs to it; spaces after the comment end the entry.
        ("a@example.com (work) b@example.com", ["a@example.com", "b@example.com"]),
        ("Ann <a@example.com> (work) b@example.com", ["a@example.com", "b@example.com"])
    ])
    func splitsIntoAddresses(text: String, expected: [String]) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == expected)
        #expect(entry.leftovers.isEmpty)
    }

    @Test("Text that names no sendable address is kept as text, never as a recipient", arguments: [
        ("bob", [String](), "bob"),
        ("bob, carol@example.com", ["carol@example.com"], "bob"),
        ("local@localhost", [], "local@localhost"),
        ("foo@@example.com, ann@example.com", ["ann@example.com"], "foo@@example.com")
    ])
    func keepsTextThatIsNotAnAddress(text: String, addresses: [String], leftover: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == addresses)
        #expect(entry.leftovers == [leftover])
    }

    /// The bug this guards: an empty group and a comment name nobody, and the
    /// parser returns no address for them, so they vanished from the field.
    @Test("Text naming nobody is kept as text, beside the addresses", arguments: [
        ("undisclosed-recipients:;", [String](), "undisclosed-recipients:;"),
        ("(just a note)", [], "(just a note)"),
        ("undisclosed-recipients:;, ann@example.com", ["ann@example.com"], "undisclosed-recipients:;"),
        ("(note), ann@example.com", ["ann@example.com"], "(note)")
    ])
    func keepsTextNamingNobody(text: String, addresses: [String], leftover: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == addresses)
        #expect(entry.leftovers == [leftover])
    }

    @Test("Text naming nobody survives a save and reopen, and Send names it", arguments: [
        "undisclosed-recipients:;, ann@example.com,", "(just a note), ann@example.com,"
    ])
    func textNamingNobodySurvivesSave(typed: String) throws {
        let field = try #require(ComposeDraftGuards.committing(typed, to: .init(), room: 10))
        #expect(field.tokens == ["ann@example.com"])
        #expect(field.rejected.count == 1)
        let leftover = try #require(field.rejected.first)
        let stored = ComposeDraftGuards.committedRecipients(field)
        #expect(stored == ["ann@example.com", leftover])
        let reopened = ComposeDraftGuards.fieldState(RecipientEntry(stored))
        #expect(reopened.tokens == ["ann@example.com"])
        #expect(reopened.rejected == [leftover])
        guard case .refused(let message) = ComposeDraftGuards.sendRecipients(
            to: ComposeDraftGuards.pendingCommitted(reopened), cc: .init(), bcc: .init()) else {
            Issue.record("Send was not refused")
            return
        }
        #expect(message.contains(leftover))
    }

    @Test("A group's members become recipients, and nothing of it is left as text")
    func groupWithMembers() {
        let entry = RecipientEntry("Team: a@example.com, b@example.com;, c@example.com")
        #expect(entry.addresses == ["a@example.com", "b@example.com", "c@example.com"])
        #expect(entry.leftovers.isEmpty)
    }

    @Test("Display names come with their addresses")
    func keepsDisplayNames() {
        let entry = RecipientEntry("\"Doe, Bob\" <bob@example.com>, ann@example.com")
        #expect(entry.recipients.map(\.name) == ["Doe, Bob", nil])
    }

    @Test("Spaces split addresses only after an address", arguments: [
        "Ann Lee <ann@example.com>", "ann@example.com (work)"
    ])
    func spacesInsideOneMailboxDoNotSplit(text: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == ["ann@example.com"])
        #expect(entry.leftovers.isEmpty)
        if text.hasPrefix("Ann Lee") { #expect(entry.recipients.first?.name == "Ann Lee") }
    }

    /// Kept text must read back as the same text: a named mailbox TabMail
    /// cannot send to keeps its quotes, so a comma or address inside its name
    /// never becomes a recipient when the input line is read again.
    @Test("Text kept for a named mailbox reads back unchanged")
    func keptNamedMailboxReadsBack() {
        let entry = RecipientEntry("\"Alice <alice@example.com>, Bob\" <helpdesk@localhost>")
        #expect(entry.addresses.isEmpty)
        let again = RecipientEntry(entry.leftovers)
        #expect(again.addresses.isEmpty)
        #expect(again.leftovers == entry.leftovers)
    }

    /// The property the whole change exists for: every recipient a field holds
    /// is one address TabMail's send path reads as one mailbox. (SwiftMail's
    /// SMTP check is stricter for some valid addresses, such as a non-ASCII
    /// domain; those fail visibly at send, as `IMAPProvider.buildEmail` notes.)
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

    /// The sender's name names the whole From field, so it goes with the
    /// address only when From names exactly one mailbox.
    @Test("A reply to a From naming two mailboxes gives neither the sender's name")
    func replyToTwoSenders() {
        let entry = RecipientEntry.reply(to: Self.header(from: "a@example.com, b@example.com", name: "Shared Name"))
        #expect(entry.addresses == ["a@example.com", "b@example.com"])
        #expect(entry.recipients.map(\.name) == [nil, nil])
    }

    @Test("A Reply-To that names no mailbox is a rejected entry, not a recipient")
    func replyToWithoutMailbox() {
        let field = ComposeDraftGuards.fieldState(RecipientEntry.reply(to: Self.header(replyTo: "nobody")))
        #expect(field.tokens.isEmpty)
        #expect(field.rejected == ["nobody"])
        #expect(field.input.isEmpty)
    }

    /// Reply-all opens compose through `prefillTo`; the reply target's text that
    /// names no sendable address must stay visible there, as for Reply.
    @Test("Reply-all keeps a Reply-To TabMail cannot send to as a rejected entry, never a recipient")
    func replyAllKeepsUnsendableReplyTo() {
        let header = Self.header(replyTo: "Help <helpdesk@localhost>, ann@example.com")
        let recipients = buildReplyAllRecipients(for: header, allAccounts: [])
        let field = ComposeDraftGuards.fieldState(RecipientEntry(recipients.to))
        #expect(field.tokens == ["ann@example.com", "me@example.com"])
        #expect(field.rejected == ["Help <helpdesk@localhost>"])
    }

    /// Each entry of the Reply-To that names no sendable address reaches compose
    /// as its own element, never joined to another into one line of text.
    @Test("Reply-all passes each unsendable Reply-To entry on separately")
    func replyAllKeepsEntriesApart() {
        let header = Self.header(replyTo: "nobody; Help <helpdesk@localhost>, ann@example.com")
        let recipients = buildReplyAllRecipients(for: header, allAccounts: [])
        #expect(recipients.to == ["ann@example.com", "nobody", "Help <helpdesk@localhost>", "me@example.com"])
        let field = ComposeDraftGuards.fieldState(RecipientEntry(recipients.to))
        #expect(field.tokens == ["ann@example.com", "me@example.com"])
        #expect(field.rejected == ["nobody", "Help <helpdesk@localhost>"])
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

    @Test("Each entry that names no address becomes its own rejected entry, as written", arguments: [
        ("bob,", ["bob"]), ("\"Doe, J", ["\"Doe, J"]), ("ann@exa", ["ann@exa"]),
        ("bob; \"carol", ["bob", "\"carol"]), ("\"x\" , y", ["\"x\"", "y"])
    ])
    func committingRejectsEachEntry(text: String, rejected: [String]) throws {
        let result = try #require(ComposeDraftGuards.committing(text, to: Self.field, room: 10))
        #expect(result.tokens == Self.field.tokens)
        #expect(result.rejected == rejected)
        #expect(result.input.isEmpty)
    }

    @Test("Text holding no entry leaves the field exactly as it was", arguments: ["  ", ",", " ; "])
    func committingNothingChangesNothing(text: String) {
        #expect(ComposeDraftGuards.committing(text, to: Self.field, room: 10) == nil)
    }

    @Test("Text beside an address becomes a rejected entry")
    func committingKeepsLeftoverText() throws {
        let result = try #require(ComposeDraftGuards.committing("bob, ann@example.com", to: Self.field, room: 10))
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(result.rejected == ["bob"])
        #expect(result.input.isEmpty)
    }

    @Test("Addresses over the recipient cap stay in the input line")
    func committingRespectsTheCap() throws {
        let result = try #require(ComposeDraftGuards.committing(
            "a@example.com, b@example.com, c@example.com", to: Self.field, room: 1))
        #expect(result.tokens == ["old@example.com", "a@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(result.input) == "b@example.com, c@example.com")
    }

    @Test("An address already in the field moves to the end without using the cap")
    func committingMovesAnExistingAddress() throws {
        var field = Self.field
        field.tokens.append("ann@example.com")
        let result = try #require(ComposeDraftGuards.committing("OLD@example.com,", to: field, room: 0))
        #expect(result.tokens == ["ann@example.com", "OLD@example.com"])
    }

    @Test("A typed separator splits the text up to the last separator", arguments: [
        ("a@example.com", "a@example.com,", "a@example.com,", ""),
        ("bob, carol@example.com", "bob, carol@example.com;", "bob, carol@example.com;", ""),
        ("bob carol@example.c", "bob, carol@example.c", "bob,", " carol@example.c"),
        ("a@example.com, \"Doe J", "a@example.com, \"Doe, J", "a@example.com,", " \"Doe, J")
    ])
    func typingSplitsUpToTheLastSeparator(old: String, text: String, split: String, typing: String) throws {
        let result = try #require(ComposeDraftGuards.inputToSplit(was: old, now: text))
        #expect(result.text == split)
        #expect(result.typing == typing)
    }

    /// The bug this guards: a paste over selected text was told apart from
    /// typing by how much the line grew, so a list pasted over a longer query
    /// was not split.
    @Test("A paste over selected text is split whole", arguments: [
        ("an-unfinished-query-longer-than-the-paste", "a@example.com b@example.com"),
        ("ann@example.com, xyzxyzxyzxyzxyzxyzxyzxyzxyz", "ann@example.com, a@example.com b@example.com")
    ])
    func pasteOverSelectionSplitsWhole(old: String, text: String) throws {
        let pasted = try #require(ComposeDraftGuards.inputToSplit(was: old, now: text))
        #expect(pasted.text == text)
        #expect(pasted.typing.isEmpty)
    }

    @Test("A paste is split whole, with or without commas", arguments: [
        "a@example.com, b@example.com", "a@example.com b@example.com", "a@example.com\tb@example.com"
    ])
    func pasteSplitsWhole(pasted text: String) throws {
        let pasted = try #require(ComposeDraftGuards.inputToSplit(was: "", now: text))
        #expect(pasted.text == text)
        #expect(pasted.typing.isEmpty)
        let field = try #require(ComposeDraftGuards.committing(pasted.text, to: .init(), room: 10))
        #expect(field.tokens == ["a@example.com", "b@example.com"])
    }

    /// A keystroke that adds no separator splits nothing, even when the line
    /// already holds one: re-splitting the unchanged text before it commits an
    /// address the user is still fixing in place.
    @Test("Typing with no separator is not split")
    func typingWithoutSeparator() {
        #expect(ComposeDraftGuards.inputToSplit(was: "a@example.co", now: "a@example.com") == nil)
        #expect(ComposeDraftGuards.inputToSplit(was: "a@example.com", now: "a@example.com ") == nil)
        #expect(ComposeDraftGuards.inputToSplit(was: "bob, carol@example.", now: "bob, carol@example.c") == nil)
        #expect(ComposeDraftGuards.inputToSplit(was: "a@example.com; ", now: "a@example.com; b") == nil)
        #expect(ComposeDraftGuards.inputToSplit(was: "bob@example., ", now: "bob@example.c, ") == nil)
    }

    /// The bug this guards: the split point was the last separator anywhere in
    /// the line, so typing the comma of `"Doe, John" <john@example.com>` cut
    /// the quoted name in two before it was finished.
    @Test("A separator inside quotes, angle brackets, a comment or a group is not a split point", arguments: [
        "\"Doe,", "Ann <ann@example.com,", "a@example.com (work,", "Team: a@example.com,"
    ])
    func separatorInsideQuotesDoesNotSplit(text: String) {
        #expect(ComposeDraftGuards.inputToSplit(was: String(text.dropLast()), now: text) == nil)
        #expect(ComposeDraftGuards.typedEntry(text) == text)
    }

    @Test("A quoted name typed with a comma becomes one recipient under that name", arguments: [
        ("\"Doe, John\" <john@example.com>,", "Doe, John"),
        ("\"Doe \\\", John\" <john@example.com>,", "Doe \", John"),
        ("\"\u{0301}Doe, John\" <john@example.com>,", "\u{0301}Doe, John")
    ])
    func typingQuotedNameWithComma(typed: String, name: String) {
        let field = Self.typing(typed, into: .init())
        #expect(field.tokens == ["john@example.com"])
        #expect(field.displayNames == ["john@example.com": name])
        #expect(field.rejected.isEmpty)
        #expect(field.input.isEmpty)
    }

    /// A comment after an address closes before the separator that follows it,
    /// so that separator ends the entry as it would after the bare address.
    @Test("A separator typed after a closed comment adds the address", arguments: [
        "a@example.com (work),", "Ann <a@example.com> (work);", "a@example.com (work (home)),"
    ])
    func typingAfterClosedComment(typed: String) {
        let field = Self.typing(typed, into: .init())
        #expect(field.tokens == ["a@example.com"])
        #expect(field.rejected.isEmpty)
        #expect(field.input.isEmpty)
    }

    @Test("A picked contact becomes a recipient under its name")
    func pickingAddsContact() {
        var field = Self.field
        field.input = "an"
        let result = ComposeDraftGuards.picking("ann@example.com", name: "Ann Lee", to: field, room: 10)
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(result.displayNames["ann@example.com"] == "Ann Lee")
        #expect(result.input.isEmpty)
    }

    /// A contact's address TabMail cannot send to must not make the tap do
    /// nothing: it replaces the query, and Send then names it.
    @Test("A picked contact TabMail cannot send to becomes a rejected entry, and Send names it")
    func pickingUnsendableContact() {
        var field = Self.field
        field.input = "bo"
        let result = ComposeDraftGuards.picking("bob@localhost", name: "Bob", to: field, room: 10)
        #expect(result.tokens == Self.field.tokens)
        #expect(result.rejected == ["bob@localhost"])
        #expect(result.input.isEmpty)
        guard case .refused(let message) = ComposeDraftGuards.sendRecipients(to: result, cc: .init(), bcc: .init()) else {
            Issue.record("Send was not refused")
            return
        }
        #expect(message.contains("bob@localhost"))
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
        #expect(field.rejected == ["bob"])
        #expect(field.input.isEmpty)
    }

    // MARK: - Leftover text followed by more typing

    /// The keystrokes TokenField sees: each character is inserted, the input
    /// line split as `inputToSplit` says, and the result replaces the field.
    private static func typing(_ text: String, into start: ComposeDraftGuards.RecipientField) -> ComposeDraftGuards.RecipientField {
        var field = start
        for character in text {
            let old = field.input
            field.input.append(character)
            if let split = ComposeDraftGuards.inputToSplit(was: old, now: field.input),
               let next = ComposeDraftGuards.committing(split.text, typing: split.typing, to: field, room: 10) {
                field = next
            }
        }
        return field
    }

    private static func pasting(_ text: String, into start: ComposeDraftGuards.RecipientField) -> ComposeDraftGuards.RecipientField {
        var field = start
        let old = field.input
        field.input += text
        if let split = ComposeDraftGuards.inputToSplit(was: old, now: field.input),
           let next = ComposeDraftGuards.committing(split.text, typing: split.typing, to: field, room: 10) {
            field = next
        }
        return field
    }

    /// Return, or leaving the field: the whole line is committed.
    private static func pressingReturn(_ start: ComposeDraftGuards.RecipientField) -> ComposeDraftGuards.RecipientField {
        ComposeDraftGuards.committing(start.input, to: start, room: 10) ?? start
    }

    /// Every way a rejected entry reaches a field.
    private static let leftoverRoutes: [(String, ComposeDraftGuards.RecipientField)] = [
        ("typed", typing("bob,", into: .init())),
        ("typed beside an address", typing("bob, ann@example.com,", into: .init())),
        ("pasted", pasting("Doe, John <john@example.com>; Smith", into: .init())),
        ("reopened draft", ComposeDraftGuards.fieldState(RecipientEntry(["a@example.com", "Bob"]))),
        ("reply", ComposeDraftGuards.fieldState(RecipientEntry.reply(to: header(replyTo: "nobody")))),
        ("AI add", ComposeDraftGuards.applying(
            Self.delta(add: "Jane"), to: .init())),
        ("unsendable pick", ComposeDraftGuards.picking("bob@localhost", name: "Bob", to: .init(), room: 10))
    ]

    /// The bug this guards: leftover text sat in the input line with nothing
    /// after it, so the next address typed was joined to it, and
    /// `bob` + `dave@example.com` became a recipient `bobdave@example.com`.
    /// A rejected entry now stays apart from the input line.
    @Test("An address typed or pasted after a rejected entry becomes its own recipient", arguments: [
        "type", "type after a space", "paste", "type and press Return"
    ])
    func addressAfterLeftoverText(followUp: String) throws {
        for (route, start) in Self.leftoverRoutes {
            #expect(!start.rejected.isEmpty, "\(route) rejected nothing")
            #expect(start.input.isEmpty, "\(route): \(start.input)")
            let after: ComposeDraftGuards.RecipientField
            switch followUp {
            case "type": after = Self.typing("dave@example.com,", into: start)
            case "type after a space": after = Self.typing(" dave@example.com,", into: start)
            case "paste": after = Self.pasting("dave@example.com", into: start)
            default: after = Self.pressingReturn(Self.typing("dave@example.com", into: start))
            }
            #expect(after.tokens == start.tokens + ["dave@example.com"], "\(route): \(after.tokens)")
            #expect(after.rejected == start.rejected, "\(route): \(after.rejected)")
            #expect(after.input.isEmpty, "\(route): \(after.input)")
            let sent = ComposeDraftGuards.sendRecipients(
                to: ComposeDraftGuards.pendingCommitted(after), cc: .init(), bcc: .init())
            guard case .refused(let message) = sent else {
                Issue.record("\(route): Send was not refused: \(sent)")
                continue
            }
            #expect(message.contains(start.rejected[0]), "\(route): \(message)")
        }
    }

    // MARK: - A rejected entry tapped and fixed

    /// The keystrokes of an edit made in place: each character goes in at the
    /// caret, and when a commit rewrites the line the caret moves to its end, as
    /// a text field's does when its text is replaced. Returns every token list
    /// the field held along the way, so a test can check none was unfinished.
    private static func typing(
        _ text: String, at offset: Int, into start: ComposeDraftGuards.RecipientField
    ) -> (field: ComposeDraftGuards.RecipientField, seen: [[String]]) {
        var field = start
        var caret = offset
        var seen: [[String]] = []
        for character in text {
            let old = field.input
            var line = Array(old)
            line.insert(character, at: caret)
            field.input = String(line)
            caret += 1
            if let split = ComposeDraftGuards.inputToSplit(was: old, now: field.input),
               let next = ComposeDraftGuards.committing(split.text, typing: split.typing, to: field, room: 10) {
                field = next
                caret = field.input.count
            }
            seen.append(field.tokens)
        }
        return (field, seen)
    }

    /// The bug this guards: Send asks the user to fix leftover text, and fixing
    /// it re-split the line on every keystroke, so `bob@example.c` became a
    /// recipient before `om` was typed. A tapped rejected entry goes back to the
    /// input line, and nothing is added until the user ends it.
    @Test("A rejected entry tapped and fixed adds only the finished address", arguments: [
        ("bob@example,", ".com", ["bob@example.com"]),
        ("bob, ann@example.com,", "@example.com", ["ann@example.com", "bob@example.com"]),
        ("bob, carol@example.com", "@example.com", ["carol@example.com", "bob@example.com"])
    ])
    func leftoverFixedInPlace(typed: String, fix: String, sent: [String]) {
        let start = Self.typing(typed, into: .init())
        #expect(start.rejected.count == 1)
        let editing = ComposeDraftGuards.editingRejected(at: 0, in: start, room: 10)
        #expect(editing.rejected.isEmpty)
        let (fixed, seen) = Self.typing(fix, at: editing.input.count, into: editing)
        for tokens in seen {
            #expect(tokens == editing.tokens, "a recipient was added mid-edit: \(tokens)")
        }
        let outcome = ComposeDraftGuards.sendRecipients(
            to: ComposeDraftGuards.pendingCommitted(fixed), cc: .init(), bcc: .init())
        #expect(outcome == .send(to: sent, cc: [], bcc: []), "\(fixed.tokens) \(fixed.input)")
    }

    /// Tapping a rejected entry puts its text, and only its text, back in the
    /// input line: text already there is committed first, so the two are never
    /// joined into one entry, and the other rejected entries stay as they are.
    @Test("A tapped rejected entry goes to the input line on its own")
    func editingRejectedEntry() {
        let field = ComposeDraftGuards.RecipientField(
            tokens: ["a@example.com"], rejected: ["\"First", "Second\" <joined@example.com>"], input: "dave@example.com")
        let edited = ComposeDraftGuards.editingRejected(at: 1, in: field, room: 10)
        #expect(edited.tokens == ["a@example.com", "dave@example.com"])
        #expect(edited.rejected == ["\"First"])
        #expect(edited.input == "Second\" <joined@example.com>")
        #expect(ComposeDraftGuards.pendingCommitted(edited).tokens == edited.tokens)

        let unfinished = ComposeDraftGuards.RecipientField(rejected: ["bob"], input: "carol")
        let swapped = ComposeDraftGuards.editingRejected(at: 0, in: unfinished, room: 10)
        #expect(swapped.rejected == ["carol"])
        #expect(swapped.input == "bob")

        let full = ComposeDraftGuards.RecipientField(rejected: ["bob"], input: "x@example.com")
        let capped = ComposeDraftGuards.editingRejected(at: 0, in: full, room: 0)
        #expect(capped.tokens.isEmpty)
        #expect(capped.rejected.isEmpty)
        #expect(RecipientEntry(capped.input).addresses == ["x@example.com"])
        #expect(RecipientEntry(capped.input).leftovers == ["bob"])

        #expect(ComposeDraftGuards.editingRejected(at: 1, in: unfinished, room: 10) == unfinished)
    }

    @Test("Contact suggestions match the entry being typed, not leftover text before it")
    func suggestionsMatchTheTypedEntry() {
        #expect(ComposeDraftGuards.typedEntry("bob, da") == "da")
        #expect(ComposeDraftGuards.typedEntry("da") == "da")
        #expect(ComposeDraftGuards.typedEntry("bob, ").isEmpty)
    }

    @Test("A picked contact replaces the typed entry, and the text before it is a rejected entry")
    func pickingKeepsLeftoverText() {
        var field = Self.field
        field.input = "bob, an"
        let result = ComposeDraftGuards.picking("ann@example.com", name: "Ann", to: field, room: 10)
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(result.rejected == ["bob"])
        #expect(result.input.isEmpty)
    }

    /// When a pick adds no recipient (a contact TabMail cannot send to, or a
    /// field at the recipient cap), the picked text is kept, and so is the text
    /// before it, so neither is lost or sent.
    @Test("A pick that adds no recipient keeps the text before it", arguments: [
        ("bob@localhost", 10, ["carol", "bob@localhost"], ""),
        ("ann@example.com", 0, ["carol"], "\"Pick\" <ann@example.com>")
    ])
    func pickingAddsNothingKeepsLeftover(address: String, room: Int, rejected: [String], input: String) {
        var field = Self.field
        field.input = "carol, bo"
        let result = ComposeDraftGuards.picking(address, name: "Pick", to: field, room: room)
        #expect(result.tokens == Self.field.tokens)
        #expect(result.rejected == rejected)
        #expect(ComposeDraftGuards.trimmedInput(result.input) == input)
        let stored = ComposeDraftGuards.committedRecipients(result)
        #expect(Array(stored.prefix(Self.field.tokens.count + rejected.count)) == Self.field.tokens + rejected)
        guard case .refused(let message) = ComposeDraftGuards.sendRecipients(to: result, cc: .init(), bcc: .init()) else {
            Issue.record("Send was not refused")
            return
        }
        #expect(message.contains("carol"))
    }

    @Test("Text still being typed stays in the input line")
    func committingKeepsTypedText() throws {
        let result = try #require(ComposeDraftGuards.committing(
            "bob, ann@example.com,", typing: " ca", to: Self.field, room: 10))
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(result.rejected == ["bob"])
        #expect(result.input == "ca")
    }

    // MARK: - Drafts and Send

    /// A saved draft keeps each rejected entry beside its addresses, so nothing
    /// typed is lost; reopening shows each as a rejected entry again.
    @Test("A saved field reopens with the same addresses and rejected entries")
    func savedFieldRoundTrips() {
        let field = ComposeDraftGuards.RecipientField(tokens: ["a@example.com", "b@example.com"], rejected: ["bob"])
        let saved = ComposeDraftGuards.committedRecipients(field)
        #expect(saved == ["a@example.com", "b@example.com", "bob"])
        let reopened = ComposeDraftGuards.fieldState(RecipientEntry(saved))
        #expect(reopened == field)
        #expect(ComposeDraftGuards.committedRecipients(reopened) == saved)
    }

    @Test("A draft saved as one comma-separated recipient reopens as separate addresses")
    func oldDraftReopensSplit() {
        let reopened = ComposeDraftGuards.fieldState(RecipientEntry(["Ann <ann@example.com>, bob@example.com"]))
        #expect(reopened.tokens == ["ann@example.com", "bob@example.com"])
        #expect(reopened.displayNames == ["ann@example.com": "Ann"])
        #expect(reopened.input.isEmpty)
    }

    /// What Send sends, end to end from the fields: pending input is committed,
    /// each field's addresses go in that field, and text that names no address
    /// refuses Send, naming the field.
    @Test("Send sends each field's addresses, pending input included")
    func sendSendsEachField() {
        let to = ComposeDraftGuards.pendingCommitted(.init(tokens: ["a@example.com"], input: "b@example.com, c@example.com"))
        let cc = ComposeDraftGuards.pendingCommitted(.init(tokens: [], input: " "))
        let bcc = ComposeDraftGuards.pendingCommitted(.init(tokens: [], input: "hidden@example.com"))
        #expect(ComposeDraftGuards.sendRecipients(to: to, cc: cc, bcc: bcc) == .send(
            to: ["a@example.com", "b@example.com", "c@example.com"], cc: [], bcc: ["hidden@example.com"]))
    }

    @Test("Send is refused while an input line holds text that names no address", arguments: [
        ("To", "bob"), ("Cc", "bob, carol@example.com"), ("Bcc", "local@localhost")
    ])
    func sendRefusesUnaddressedText(label: String, input: String) {
        func field(_ name: String) -> ComposeDraftGuards.RecipientField {
            ComposeDraftGuards.pendingCommitted(.init(tokens: ["x@example.com"], input: name == label ? input : ""))
        }
        guard case .refused(let message) = ComposeDraftGuards.sendRecipients(to: field("To"), cc: field("Cc"), bcc: field("Bcc")) else {
            Issue.record("Send was not refused")
            return
        }
        #expect(message.contains("in \(label) "))
        #expect(message.contains(input.components(separatedBy: ",")[0]))
    }

    // MARK: - AI recipient edits

    /// The delta the real AI response parser makes from raw `+To:` / `-To:` lines.
    static func delta(add: String? = nil, remove: String? = nil) -> RecipientDelta {
        let lines = [add.map { "+To: \($0)" }, remove.map { "-To: \($0)" }].compactMap { $0 }
        return AIService.parseDeltaForField(lines.joined(separator: "\n"), field: "To")
            ?? RecipientDelta(adds: RecipientEntry([String]()), removes: [])
    }

    @Test("An AI add naming several addresses adds one recipient each", arguments: [
        "a@example.com, b@example.com", "a@example.com; b@example.com", "a@example.com b@example.com"
    ])
    func aiAddSplits(add: String) {
        let field = ComposeDraftGuards.applying(Self.delta(add: add), to: .init())
        #expect(field.tokens == ["a@example.com", "b@example.com"])
        #expect(field.input.isEmpty)
    }

    @Test("An AI add's text that names no address is a rejected entry, and the input line is untouched")
    func aiAddWithoutAddressIsInputText() {
        let start = ComposeDraftGuards.RecipientField(tokens: ["x@example.com"], input: "typed")
        let field = ComposeDraftGuards.applying(Self.delta(add: "Jane, b@example.com"), to: start)
        #expect(field.tokens == ["x@example.com", "b@example.com"])
        #expect(field.rejected == ["Jane"])
        #expect(field.input == "typed")
    }

    @Test("AI removes ignore case, a clear empties the field, and an add already listed is not repeated")
    func aiRemovesClearsAndDedupes() {
        let start = ComposeDraftGuards.RecipientField(tokens: ["a@example.com", "B@example.com"])
        let removed = ComposeDraftGuards.applying(
            Self.delta(add: "A@EXAMPLE.COM, c@example.com", remove: "b@example.com"), to: start)
        #expect(removed.tokens == ["a@example.com", "c@example.com"])
        let cleared = ComposeDraftGuards.applying(Self.delta(add: "c@example.com", remove: "*"), to: start)
        #expect(cleared.tokens == ["c@example.com"])
    }

    /// The bug this guards: at the recipient cap a pasted address waits in the
    /// input line, and an AI clear or removal left it there, so Send went to a
    /// recipient the user had removed.
    @Test("AI removes and clears cover addresses waiting in the input line")
    func aiRemovesCoverPendingInput() throws {
        let capped = try #require(ComposeDraftGuards.committing(
            "a@example.com b@example.com", to: .init(), room: 1))
        #expect(capped.tokens == ["a@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(capped.input) == "b@example.com")
        let to = ComposeDraftGuards.RecipientField(tokens: ["to@example.com"])
        for delta in [Self.delta(remove: "*"), Self.delta(remove: "a@example.com, B@EXAMPLE.COM")] {
            let bcc = ComposeDraftGuards.applying(delta, to: capped)
            #expect(ComposeDraftGuards.sendRecipients(
                to: to, cc: .init(), bcc: ComposeDraftGuards.pendingCommitted(bcc))
                == .send(to: ["to@example.com"], cc: [], bcc: []), "\(delta.removes): \(bcc)")
        }
    }

    @Test("An AI removal keeps the other addresses in the input line, and its other text as rejected entries")
    func aiRemoveKeepsOtherInput() {
        let field = ComposeDraftGuards.RecipientField(
            tokens: ["a@example.com"], input: ComposeDraftGuards.inputLine(["bob", "b@example.com", "c@example.com"]))
        let result = ComposeDraftGuards.applying(Self.delta(remove: "b@example.com"), to: field)
        #expect(result.tokens == ["a@example.com"])
        #expect(result.rejected == ["bob"])
        let entry = RecipientEntry(result.input)
        #expect(entry.addresses == ["c@example.com"])
        #expect(entry.leftovers.isEmpty)
        let untouched = ComposeDraftGuards.applying(Self.delta(remove: "a@example.com"), to: field)
        #expect(untouched.input == field.input)
    }

    @Test("An AI add keeps each address's own name, quoted commas included")
    func aiAddNames() {
        let one = ComposeDraftGuards.applying(Self.delta(add: "Ann Lee <ann@example.com>"), to: .init())
        #expect(one.displayNames == ["ann@example.com": "Ann Lee"])
        let several = ComposeDraftGuards.applying(
            Self.delta(add: "\"Doe, Bob\" <bob@example.com>; carol@example.com"), to: .init())
        #expect(several.tokens == ["bob@example.com", "carol@example.com"])
        #expect(several.displayNames == ["bob@example.com": "Doe, Bob"])
    }
}
