/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Recipient text is split into entries first, and only then is each entry read
/// (ADR-IOS-092). Each test starts from the raw text a route receives (a field,
/// an AI response, a contact, a mailto link, an agent tool argument) and checks
/// the recipients Send would send, or that Send refuses.
@Suite("Recipient text is split before it is read", .serialized)
struct RecipientSplitFirstTests {
    private static let to = ComposeDraftGuards.RecipientField(tokens: ["intended@example.com"])

    // MARK: - Text that names no address stays text

    /// The bug this guards: a quoted string names no mailbox, but the text kept
    /// for the input line was its decoded form, which reads as an address, so
    /// the next commit or a save and reopen made it a recipient with no edit.
    @Test("Quoted text that names no mailbox is never sent, even after a commit or a save and reopen", arguments: [
        "\"extra@example.com\"",
        "\"first@example.com, second@example.com\""
    ])
    func quotedTextStaysText(text: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses.isEmpty)
        #expect(entry.unparsed == text)
        let field = ComposeDraftGuards.fieldState(entry)
        let committed = ComposeDraftGuards.pendingCommitted(field)
        #expect(committed.tokens.isEmpty)
        let stored = ComposeDraftGuards.committedRecipients(tokens: committed.tokens, input: committed.input)
        let reopened = ComposeDraftGuards.pendingCommitted(ComposeDraftGuards.fieldState(RecipientEntry(stored)))
        #expect(reopened.tokens.isEmpty)
        for cc in [committed, reopened] {
            guard case .refused = ComposeDraftGuards.sendRecipients(to: Self.to, cc: cc, bcc: .init()) else {
                Issue.record("\(text) became a recipient without an edit")
                continue
            }
        }
    }

    @Test("Once the user removes the quotes, the address is a recipient")
    func correctedTextIsSent() throws {
        let field = ComposeDraftGuards.fieldState(RecipientEntry("\"extra@example.com\""))
        let fixed = try #require(ComposeDraftGuards.committing("extra@example.com,", to: field, room: 10))
        let cc = ComposeDraftGuards.RecipientField(tokens: fixed.tokens)
        #expect(ComposeDraftGuards.sendRecipients(to: Self.to, cc: cc, bcc: .init())
            == .send(to: ["intended@example.com"], cc: ["extra@example.com"], bcc: []))
    }

    /// An entry holding a mailbox and text that is not one is kept whole, so
    /// the text is never dropped while the mailbox goes out.
    @Test("An entry that is partly not a mailbox is kept whole as text", arguments: [
        "Team: a@example.com, helpdesk@localhost;",
        "<a@example.com>x"
    ])
    func partlyUnreadableEntryIsText(text: String) {
        let entry = RecipientEntry(text)
        #expect(entry.addresses.isEmpty)
        #expect(entry.unparsed == text)
    }

    // MARK: - AI edits

    /// The bug this guards: the AI's line was pre-parsed by taking the first
    /// `<...>` of each comma piece, so a list in another separator added or
    /// removed only its first mailbox, and a removed Bcc recipient was sent.
    @Test("An AI add or removal covers every mailbox its line names", arguments: [", ", "; ", " "])
    func aiLineCoversEveryMailbox(separator: String) throws {
        let list = "First <first@example.com>" + separator + "Second <second@example.com>"
        let added = AIService.parseInlineEditResponse("+Bcc: \(list)\nBody: Body")
        let addedBcc = ComposeDraftGuards.applying(try #require(added.bccDelta), to: .init())
        #expect(addedBcc.tokens == ["first@example.com", "second@example.com"])
        #expect(addedBcc.displayNames == ["first@example.com": "First", "second@example.com": "Second"])
        #expect(addedBcc.input.isEmpty)

        let removed = AIService.parseInlineEditResponse("-Bcc: \(list)\nBody: Body")
        let removedBcc = ComposeDraftGuards.applying(try #require(removed.bccDelta), to: addedBcc)
        #expect(ComposeDraftGuards.sendRecipients(
            to: Self.to, cc: .init(), bcc: ComposeDraftGuards.pendingCommitted(removedBcc))
            == .send(to: ["intended@example.com"], cc: [], bcc: []))
    }

    @Test("Text in an AI add that names no address stays visible, and Send refuses it")
    func aiAddKeepsText() throws {
        let parsed = AIService.parseInlineEditResponse("+Bcc: First <first@example.com>; unfinished\nBody: Body")
        let bcc = ComposeDraftGuards.applying(try #require(parsed.bccDelta), to: .init())
        #expect(bcc.tokens == ["first@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(bcc.input) == "unfinished")
        guard case .refused = ComposeDraftGuards.sendRecipients(
            to: Self.to, cc: .init(), bcc: ComposeDraftGuards.pendingCommitted(bcc)) else {
            Issue.record("The AI add's text was dropped and Send went ahead")
            return
        }
    }

    // MARK: - Contact pick

    /// The bug this guards: the contact's name was wrapped around its whole
    /// email value before splitting, so a value holding a list added nobody.
    @Test("A contact's email value holding a list splits, with or without a name",
          arguments: ["", "Team"], [", ", "; ", " "])
    func contactListSplits(name: String, separator: String) {
        let list = "first@example.com" + separator + "second@example.com"
        let result = ComposeDraftGuards.picking(list, name: name, to: .init(), room: 10)
        #expect(result.tokens == ["first@example.com", "second@example.com"])
        #expect(result.displayNames.isEmpty)
        #expect(result.input.isEmpty)
    }

    @Test("A contact naming one address shows the contact's name")
    func contactNameForOneAddress() {
        var field = ComposeDraftGuards.RecipientField(tokens: ["old@example.com"], input: "bob, ann")
        field = ComposeDraftGuards.picking("ann@example.com", name: "Ann, Lee", to: field, room: 10)
        #expect(field.tokens == ["old@example.com", "ann@example.com"])
        #expect(field.displayNames == ["ann@example.com": "Ann, Lee"])
        #expect(ComposeDraftGuards.trimmedInput(field.input) == "bob")
    }

    // MARK: - Over the cap

    @Test("An address over the recipient cap keeps its name in the input line")
    func overCapKeepsName() throws {
        let field = try #require(ComposeDraftGuards.committing(
            "a@example.com, \"Doe, Bob\" <bob@example.com>,", to: .init(), room: 1))
        #expect(field.tokens == ["a@example.com"])
        let committed = ComposeDraftGuards.pendingCommitted(field)
        #expect(committed.tokens == ["a@example.com", "bob@example.com"])
        #expect(committed.displayNames["bob@example.com"] == "Doe, Bob")
    }

    // MARK: - mailto links

    /// The bug this guards: the link's value was split on every comma before
    /// compose read it, breaking a quoted name in two.
    @Test("A mailto link's recipients keep a quoted name with a comma")
    func mailtoKeepsQuotedName() throws {
        let url = try #require(URL(string:
            "mailto:%22Doe,%20John%22%20%3Cjohn@example.com%3E,ann@example.com?bcc=%22Lee,%20B%22%20%3Cb@example.com%3E;c@example.com"))
        let request = try #require(MailtoRequest.parse(url))
        let to = ComposeDraftGuards.fieldState(RecipientEntry(request.to))
        #expect(to.tokens == ["john@example.com", "ann@example.com"])
        #expect(to.displayNames == ["john@example.com": "Doe, John"])
        #expect(to.input.isEmpty)
        let bcc = ComposeDraftGuards.fieldState(RecipientEntry(request.bcc))
        #expect(bcc.tokens == ["b@example.com", "c@example.com"])
        #expect(bcc.input.isEmpty)
    }

    // MARK: - Agent reply tool

    /// The bug this guards: a removal was compared as raw text, so a named or
    /// listed address was never removed and went out with the reply.
    @Test("The reply tool's removals match each address they name", arguments: [
        ["\"Bob\" <bob@example.com>", "Carol <carol@example.com>"],
        ["bob@example.com; carol@example.com"]
    ])
    func replyToolRemovals(removes: [String]) {
        let result = EmailReplyTool.applyRecipientDelta(
            base: ["bob@example.com", "carol@example.com", "dave@example.com"], adds: [], removes: removes)
        #expect(result == ["dave@example.com"])
        #expect(EmailReplyTool.applyRecipientDelta(base: result, adds: ["e@example.com"], removes: [" * "])
            == ["e@example.com"])
    }

    // MARK: - At the provider

    @Test("A removed Bcc recipient is not on the message the provider sends", arguments: ["; ", " "])
    func removedBccNotSent(separator: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/send", method: "POST", response: .json(raw: #"{"id":"sent-test"}"#))
        let provider = GmailProvider(userEmail: "sender@example.com", accessToken: { _ in "tok" }, session: http.session)
        let start = ComposeDraftGuards.RecipientField(tokens: ["first@example.com", "second@example.com"])
        let parsed = AIService.parseInlineEditResponse(
            "-Bcc: First <first@example.com>\(separator)Second <second@example.com>\nBody: Body")
        let bcc = ComposeDraftGuards.applying(try #require(parsed.bccDelta), to: start)
        guard case .send(let to, let cc, let bccs) = ComposeDraftGuards.sendRecipients(
            to: Self.to, cc: .init(), bcc: ComposeDraftGuards.pendingCommitted(bcc)) else {
            Issue.record("Send was refused")
            return
        }
        try await provider.send(draft: DraftMessage(to: to, cc: cc, bcc: bccs, subject: "Test", body: "Body text"))
        let call = try #require(http.recordedCalls().first)
        let body = try #require(call.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        var encoded = try #require(json["raw"] as? String)
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        let data = try #require(Data(base64Encoded: encoded))
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("To: intended@example.com"))
        #expect(raw.contains("Body text"))
        #expect(!raw.contains("first@example.com"))
        #expect(!raw.contains("second@example.com"))
    }
}
