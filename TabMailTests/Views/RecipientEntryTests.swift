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
        ("bob@example.com (a (b) c; d); ann@example.com", ["bob@example.com", "ann@example.com"])
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

    @Test("Spaces split addresses only after an address", arguments: [
        "Ann Lee <ann@example.com>", "ann@example.com (work)"
    ])
    func spacesInsideOneMailboxDoNotSplit(text: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses == ["ann@example.com"])
        #expect(entry.unparsed.isEmpty)
        if text.hasPrefix("Ann Lee") { #expect(entry.recipients.first?.name == "Ann Lee") }
    }

    /// Kept text must read back as the same text: a named mailbox TabMail
    /// cannot send to keeps its quotes, so a comma or address inside its name
    /// never becomes a recipient when the input line is read again.
    @Test("Text kept for a named mailbox reads back unchanged")
    func keptNamedMailboxReadsBack() {
        let entry = RecipientEntry("\"Alice <alice@example.com>, Bob\" <helpdesk@localhost>")
        #expect(entry.addresses.isEmpty)
        let again = RecipientEntry(entry.unparsed)
        #expect(again.addresses.isEmpty)
        #expect(again.unparsed == entry.unparsed)
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

    @Test("A Reply-To that names no mailbox goes to the input line, not to a recipient")
    func replyToWithoutMailbox() {
        let field = ComposeDraftGuards.fieldState(RecipientEntry.reply(to: Self.header(replyTo: "nobody")))
        #expect(field.tokens.isEmpty)
        #expect(ComposeDraftGuards.trimmedInput(field.input) == "nobody")
    }

    /// Reply-all opens compose through `prefillTo`; the reply target's text that
    /// names no sendable address must reach the To input line there, as for Reply.
    @Test("Reply-all keeps a Reply-To TabMail cannot send to as input text, never a recipient")
    func replyAllKeepsUnsendableReplyTo() {
        let header = Self.header(replyTo: "Help <helpdesk@localhost>, ann@example.com")
        let recipients = buildReplyAllRecipients(for: header, allAccounts: [])
        let field = ComposeDraftGuards.fieldState(RecipientEntry(recipients.to))
        #expect(field.tokens == ["ann@example.com", "me@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(field.input) == "\"Help\" <helpdesk@localhost>")
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
        #expect(ComposeDraftGuards.trimmedInput(result.input) == "bob")
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
        ("bob carol@example.c", "bob, carol@example.c", "bob,", " carol@example.c")
    ])
    func typingSplitsUpToTheLastSeparator(old: String, text: String, split: String, typing: String) throws {
        let result = try #require(ComposeDraftGuards.inputToSplit(was: old, now: text))
        #expect(result.text == split)
        #expect(result.typing == typing)
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
    @Test("A picked contact TabMail cannot send to goes to the input line, and Send names it")
    func pickingUnsendableContact() {
        var field = Self.field
        field.input = "bo"
        let result = ComposeDraftGuards.picking("bob@localhost", name: "Bob", to: field, room: 10)
        #expect(result.tokens == Self.field.tokens)
        #expect(ComposeDraftGuards.trimmedInput(result.input) == "\"Bob\" <bob@localhost>")
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
        #expect(ComposeDraftGuards.trimmedInput(field.input) == "bob")
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

    /// Every way leftover text reaches the input line.
    private static let leftoverRoutes: [(String, ComposeDraftGuards.RecipientField)] = [
        ("typed", typing("bob,", into: .init())),
        ("typed beside an address", typing("bob, ann@example.com,", into: .init())),
        ("pasted", pasting("Doe, John <john@example.com>; Smith", into: .init())),
        ("reopened draft", ComposeDraftGuards.fieldState(RecipientEntry(["a@example.com", "Bob"]))),
        ("reply", ComposeDraftGuards.fieldState(RecipientEntry.reply(to: header(replyTo: "nobody")))),
        ("AI add", ComposeDraftGuards.applying(
            RecipientDelta(adds: [ParsedRecipient(name: "", email: "Jane")], removes: []), to: .init())),
        ("unsendable pick", ComposeDraftGuards.picking("bob@localhost", name: "Bob", to: .init(), room: 10))
    ]

    /// The bug this guards: leftover text sat in the input line with nothing
    /// after it, so the next address typed was joined to it, and
    /// `bob` + `dave@example.com` became a recipient `bobdave@example.com`.
    @Test("An address typed or pasted after leftover text becomes its own recipient", arguments: [
        "type", "type after a space", "paste", "type and press Return"
    ])
    func addressAfterLeftoverText(followUp: String) throws {
        for (route, start) in Self.leftoverRoutes {
            let leftover = ComposeDraftGuards.trimmedInput(start.input)
            #expect(!leftover.isEmpty, "\(route) left no text")
            let after: ComposeDraftGuards.RecipientField
            switch followUp {
            case "type": after = Self.typing("dave@example.com,", into: start)
            case "type after a space": after = Self.typing(" dave@example.com,", into: start)
            case "paste": after = Self.pasting("dave@example.com", into: start)
            default: after = Self.pressingReturn(Self.typing("dave@example.com", into: start))
            }
            #expect(after.tokens == start.tokens + ["dave@example.com"], "\(route): \(after.tokens)")
            #expect(ComposeDraftGuards.trimmedInput(after.input) == leftover, "\(route): \(after.input)")
            let sent = ComposeDraftGuards.sendRecipients(
                to: ComposeDraftGuards.pendingCommitted(after), cc: .init(), bcc: .init())
            guard case .refused(let message) = sent else {
                Issue.record("\(route): Send was not refused: \(sent)")
                continue
            }
            #expect(message.contains(leftover), "\(route): \(message)")
        }
    }

    // MARK: - Leftover text fixed in place

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
    /// it where it is re-split the line on every keystroke, so `bob@example.c`
    /// became a recipient before `om` was typed and `om` landed in the next
    /// address. With `bob, carol@example.com` the message went to
    /// `bob@example.c` and `carol@example.comom`.
    @Test("Leftover text fixed in place adds only the finished address", arguments: [
        ("bob@example,", ".com", ["bob@example.com"]),
        ("bob, ann@example.com,", "@example.com", ["ann@example.com", "bob@example.com"]),
        ("bob, carol@example.com", "@example.com", ["bob@example.com", "carol@example.com"])
    ])
    func leftoverFixedInPlace(typed: String, fix: String, sent: [String]) {
        let start = Self.typing(typed, into: .init())
        let wordEnd = start.input.firstIndex(where: { ComposeDraftGuards.isSeparator($0) || $0 == " " })
            .map { start.input.distance(from: start.input.startIndex, to: $0) } ?? start.input.count
        let (fixed, seen) = Self.typing(fix, at: wordEnd, into: start)
        for tokens in seen {
            #expect(tokens == start.tokens, "a recipient was added mid-edit: \(tokens)")
        }
        let outcome = ComposeDraftGuards.sendRecipients(
            to: ComposeDraftGuards.pendingCommitted(fixed), cc: .init(), bcc: .init())
        #expect(outcome == .send(to: sent, cc: [], bcc: []), "\(fixed.tokens) \(fixed.input)")
    }

    /// Every leftover route: an address typed in place before the leftover text
    /// is never added half-typed, and becomes its own recipient once a
    /// separator follows it, with the leftover text kept for Send to name.
    @Test("An address typed in place before leftover text is added only when finished")
    func addressTypedBeforeLeftoverText() {
        for (route, start) in Self.leftoverRoutes {
            let leftover = ComposeDraftGuards.trimmedInput(start.input)
            let (after, seen) = Self.typing("dave@example.com, ", at: 0, into: start)
            for tokens in seen {
                #expect(tokens == start.tokens || tokens == start.tokens + ["dave@example.com"],
                        "\(route): a recipient was added mid-edit: \(tokens)")
            }
            #expect(after.tokens == start.tokens + ["dave@example.com"], "\(route): \(after.tokens)")
            #expect(ComposeDraftGuards.trimmedInput(after.input) == leftover, "\(route): \(after.input)")
            let sent = ComposeDraftGuards.sendRecipients(
                to: ComposeDraftGuards.pendingCommitted(after), cc: .init(), bcc: .init())
            guard case .refused(let message) = sent else {
                Issue.record("\(route): Send was not refused: \(sent)")
                continue
            }
            #expect(message.contains(leftover), "\(route): \(message)")
        }
    }

    @Test("Contact suggestions match the entry being typed, not leftover text before it")
    func suggestionsMatchTheTypedEntry() {
        #expect(ComposeDraftGuards.typedEntry("bob, da") == "da")
        #expect(ComposeDraftGuards.typedEntry("da") == "da")
        #expect(ComposeDraftGuards.typedEntry("bob, ").isEmpty)
    }

    @Test("A picked contact replaces the typed entry and keeps leftover text before it")
    func pickingKeepsLeftoverText() {
        var field = Self.field
        field.input = "bob, an"
        let result = ComposeDraftGuards.picking("ann@example.com", name: "Ann", to: field, room: 10)
        #expect(result.tokens == ["old@example.com", "ann@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(result.input) == "bob")
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
        #expect(ComposeDraftGuards.trimmedInput(reopened.input) == "bob")
        #expect(ComposeDraftGuards.committedRecipients(tokens: reopened.tokens, input: reopened.input) == saved)
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

    private static func delta(adds: [(String, String)] = [], removes: [String] = []) -> RecipientDelta {
        RecipientDelta(adds: adds.map { ParsedRecipient(name: $0.0, email: $0.1) }, removes: removes)
    }

    @Test("An AI add naming several addresses adds one recipient each", arguments: [
        "a@example.com, b@example.com", "a@example.com; b@example.com", "a@example.com b@example.com"
    ])
    func aiAddSplits(add: String) {
        let field = ComposeDraftGuards.applying(Self.delta(adds: [("", add)]), to: .init())
        #expect(field.tokens == ["a@example.com", "b@example.com"])
        #expect(field.input.isEmpty)
    }

    @Test("An AI add that names no address goes to the input line, after the text already there")
    func aiAddWithoutAddressIsInputText() {
        let start = ComposeDraftGuards.RecipientField(tokens: ["x@example.com"], input: "typed")
        let field = ComposeDraftGuards.applying(Self.delta(adds: [("", "Jane"), ("", "b@example.com")]), to: start)
        #expect(field.tokens == ["x@example.com", "b@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(field.input) == "typed, Jane")
    }

    @Test("AI removes ignore case, a clear empties the field, and an add already listed is not repeated")
    func aiRemovesClearsAndDedupes() {
        let start = ComposeDraftGuards.RecipientField(tokens: ["a@example.com", "B@example.com"])
        let removed = ComposeDraftGuards.applying(
            Self.delta(adds: [("", "A@EXAMPLE.COM"), ("", "c@example.com")], removes: ["b@example.com"]), to: start)
        #expect(removed.tokens == ["a@example.com", "c@example.com"])
        let cleared = ComposeDraftGuards.applying(Self.delta(adds: [("", "c@example.com")], removes: ["*"]), to: start)
        #expect(cleared.tokens == ["c@example.com"])
    }

    @Test("An AI add naming one address takes the AI's name; one naming several keeps each address's own name")
    func aiAddNames() {
        let one = ComposeDraftGuards.applying(Self.delta(adds: [("Ann Lee", "ann@example.com")]), to: .init())
        #expect(one.displayNames == ["ann@example.com": "Ann Lee"])
        let several = ComposeDraftGuards.applying(
            Self.delta(adds: [("Team", "Bob <bob@example.com>, carol@example.com")]), to: .init())
        #expect(several.tokens == ["bob@example.com", "carol@example.com"])
        #expect(several.displayNames == ["bob@example.com": "Bob"])
    }
}
