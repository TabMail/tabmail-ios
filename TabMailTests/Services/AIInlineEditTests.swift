/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ComposeEditContext")
struct ComposeEditContextTests {

    @Test("Init stores all fields")
    func initFields() {
        let ctx = ComposeEditContext(
            recipients: ["a@b.com", "c@d.com"],
            toRecipients: ["a@b.com", "c@d.com"],
            ccRecipients: [],
            bccRecipients: [],
            toDisplayNames: [:],
            ccDisplayNames: [:],
            bccDisplayNames: [:],
            senderName: "Alice",
            senderEmail: "alice@test.com",
            mode: "edit_reply",
            compositionPrompt: "Be professional",
            kbText: "KB content",
            relatedDate: "2024-01-15",
            relatedSubject: "Re: Budget",
            relatedFrom: "bob@test.com",
            relatedTo: "alice@test.com",
            relatedCc: "cc@test.com",
            bodyText: "Original body"
        )
        #expect(ctx.recipients.count == 2)
        #expect(ctx.mode == "edit_reply")
        #expect(ctx.senderName == "Alice")
        #expect(ctx.kbText == "KB content")
    }

    @Test("Mode values for all edit types")
    func modeValues() {
        let modes = ["edit_new", "edit_reply", "edit_forward"]
        for mode in modes {
            let ctx = ComposeEditContext(
                recipients: [], toRecipients: [], ccRecipients: [], bccRecipients: [],
                toDisplayNames: [:], ccDisplayNames: [:], bccDisplayNames: [:],
                senderName: "", senderEmail: "", mode: mode,
                compositionPrompt: "", kbText: "", relatedDate: "", relatedSubject: "",
                relatedFrom: "", relatedTo: "", relatedCc: "", bodyText: ""
            )
            #expect(ctx.mode == mode)
        }
    }
}

@Suite("InlineEditTurn")
struct InlineEditTurnTests {

    @Test("Init stores all fields")
    func initFields() {
        let turn = InlineEditTurn(
            userRequest: "Make it shorter",
            bodyAtRequest: "Long body text here...",
            subjectAtRequest: "Meeting Notes",
            assistantResponse: "I've shortened the body."
        )
        #expect(turn.userRequest == "Make it shorter")
        #expect(turn.bodyAtRequest == "Long body text here...")
        #expect(turn.subjectAtRequest == "Meeting Notes")
    }
}

@Suite("InlineEditResult")
struct InlineEditResultTests {

    @Test("Init with all fields")
    func initAllFields() {
        let result = InlineEditResult(
            response: "Updated your draft",
            subject: "New Subject",
            body: "New body content",
            toDelta: nil,
            ccDelta: nil,
            bccDelta: nil,
            raw: "Response: Updated\nSubject: New Subject\nBody: New body"
        )
        #expect(result.response == "Updated your draft")
        #expect(result.subject == "New Subject")
        #expect(result.body == "New body content")
        #expect(result.raw.contains("Response:"))
    }

    @Test("Init with nil optional fields")
    func initNilFields() {
        let result = InlineEditResult(
            response: nil,
            subject: nil,
            body: nil,
            toDelta: nil,
            ccDelta: nil,
            bccDelta: nil,
            raw: "raw text"
        )
        #expect(result.response == nil)
        #expect(result.subject == nil)
        #expect(result.body == nil)
        #expect(result.raw == "raw text")
    }
}

@Suite("AIService.parseInlineEditResponse")
struct ParseInlineEditResponseTests {

    // MARK: - Full Format (Response + Subject + Body)

    @Test("Parses all three fields")
    func parsesAllFields() {
        let input = """
        Response: I updated your email.
        Subject: New Meeting Time
        Body: Hi team,

        The meeting has been moved to 3pm.
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "I updated your email.")
        #expect(result.subject == "New Meeting Time")
        #expect(result.body != nil)
        #expect(result.body!.contains("meeting has been moved"))
    }

    @Test("Stores raw text unchanged")
    func storesRawText() {
        let input = "Response: Done.\nSubject: Test\nBody: Content"
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.raw == input)
    }

    // MARK: - Partial Fields

    @Test("Parses with only Body field")
    func bodyOnly() {
        let input = "Body: Just the body content here."
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == nil)
        #expect(result.subject == nil)
        #expect(result.body == "Just the body content here.")
    }

    @Test("Parses Response and Body without Subject")
    func responseAndBody() {
        let input = "Response: Made it shorter.\nBody: Short content."
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "Made it shorter.")
        #expect(result.subject == nil)
        #expect(result.body == "Short content.")
    }

    @Test("Parses Subject and Body without Response")
    func subjectAndBody() {
        let input = "Subject: Updated\nBody: New body text."
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == nil)
        #expect(result.subject == "Updated")
        #expect(result.body == "New body text.")
    }

    // MARK: - Fallback Behavior

    @Test("No markers treats entire text as body")
    func noMarkersFallback() {
        let input = "This is just plain text with no markers at all."
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == nil)
        #expect(result.subject == nil)
        #expect(result.body == input)
    }

    @Test("Only Response marker — rest becomes body via fallback")
    func onlyResponseMarker() {
        // Response: is found but no Body: and no Subject:
        // → body == nil AND subject == nil → fallback: body = full text
        let input = "Response: I made changes."
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "I made changes.")
        // No Subject or Body markers → fallback sets body to entire text
        // But wait — body == nil AND subject == nil → fallback triggers
        #expect(result.body == input)
    }

    // MARK: - Multiline Body

    @Test("Body captures multiline content")
    func multilineBody() {
        let input = """
        Response: Updated draft.
        Subject: Q1 Report
        Body: Dear Team,

        Please find attached the Q1 report.

        Key findings:
        - Revenue up 15%
        - Costs down 3%

        Best regards
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.body != nil)
        #expect(result.body!.contains("Revenue up 15%"))
        #expect(result.body!.contains("Best regards"))
    }

    // MARK: - Case Insensitivity

    @Test("Field labels are case-insensitive")
    func caseInsensitive() {
        let input = "response: Did it.\nsubject: Lower Case\nbody: lowercase body"
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "Did it.")
        #expect(result.subject == "Lower Case")
        #expect(result.body == "lowercase body")
    }

    // MARK: - Edge Cases

    @Test("Empty input")
    func emptyInput() {
        let result = AIService.parseInlineEditResponse("")
        #expect(result.body == "")
        #expect(result.raw == "")
    }

    @Test("Whitespace-only input")
    func whitespaceOnly() {
        let result = AIService.parseInlineEditResponse("   \n  \n  ")
        #expect(result.body == "")
    }

    @Test("Empty Subject field with space before Body")
    func emptySubject() {
        // When Subject: has no value, \s* in regex eats the newline,
        // so "Body: Some content" becomes the subject match.
        // The parser requires explicit subject text after "Subject:".
        let input = "Subject: \n\nBody: Some content"
        let result = AIService.parseInlineEditResponse(input)
        // Subject regex .*$ stops at newline, so empty subject → nil
        // Body regex matches the "Body:" line
        #expect(result.body == "Some content")
    }

    @Test("Empty Body field triggers no body, falls to checking subject")
    func emptyBody() {
        let input = "Subject: Has Subject\nBody:"
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.subject == "Has Subject")
        // Body: with nothing after → empty → nil
        // But subject is non-nil, so fallback doesn't trigger
        #expect(result.body == nil)
    }

    // MARK: - v1.5.16: +/- recipient deltas

    @Test("Parses +/- delta lines into toDelta/ccDelta/bccDelta")
    func parsesDeltaLines() {
        let input = """
        Response: Swapped Bob for Alice and added Carol to cc.
        +To: Alice Anderson <alice@example.com>
        -To: bob@example.com
        +Cc: Carol <carol@example.com>
        Subject: Re: Budget
        Body: Hi all
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.toDelta?.adds.count == 1)
        #expect(result.toDelta?.adds.first?.name == "Alice Anderson")
        #expect(result.toDelta?.adds.first?.email == "alice@example.com")
        #expect(result.toDelta?.removes == ["bob@example.com"])
        #expect(result.ccDelta?.adds.count == 1)
        #expect(result.ccDelta?.adds.first?.email == "carol@example.com")
        #expect(result.ccDelta?.removes.isEmpty == true)
        // Bcc had no +/- line at all → no change signal.
        #expect(result.bccDelta == nil)
    }

    @Test("Absent delta lines leave the field untouched (nil)")
    func absentDeltaLinesReturnNil() {
        let input = """
        Response: Minor wording change.
        Subject: Re: Budget
        Body: Hi team
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.toDelta == nil)
        #expect(result.ccDelta == nil)
        #expect(result.bccDelta == nil)
    }

    @Test("-Cc: * is recognised as clear-all sentinel")
    func clearAllSentinel() {
        let input = """
        Response: Dropped everyone from cc.
        -Cc: *
        Subject: Re: Budget
        Body: Hi team
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.ccDelta != nil)
        #expect(result.ccDelta?.clearsField == true)
        #expect(result.ccDelta?.removes.contains("*") == true)
        #expect(result.ccDelta?.adds.isEmpty == true)
    }

    @Test("Multiple emails on a -To: line populate removes correctly")
    func multipleRemoves() {
        let input = """
        -To: bob@example.com, dave@example.com
        Subject: x
        Body: y
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.toDelta?.removes == ["bob@example.com", "dave@example.com"])
        #expect(result.toDelta?.adds.isEmpty == true)
    }

    @Test("Quoted display names with commas on +To: are not split")
    func quotedDisplayNamesInAdds() {
        let input = """
        +To: "Doe, John" <john@example.com>, "Smith, Jane" <jane@example.com>
        Subject: Test
        Body: body
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.toDelta?.adds.count == 2)
        #expect(result.toDelta?.adds[0].name == "Doe, John")
        #expect(result.toDelta?.adds[0].email == "john@example.com")
        #expect(result.toDelta?.adds[1].name == "Smith, Jane")
    }

    @Test("Bare emails in +To: are accepted with empty name")
    func bareEmailsInAdds() {
        let input = """
        +To: alice@example.com, bob@example.com
        Subject: Test
        Body: body
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.toDelta?.adds.count == 2)
        #expect(result.toDelta?.adds[0].email == "alice@example.com")
        #expect(result.toDelta?.adds[0].name == "")
        #expect(result.toDelta?.adds[1].email == "bob@example.com")
    }

    @Test("Both +Cc: and -Cc: in the same response produce one delta with both sides")
    func addAndRemoveSameField() {
        let input = """
        +Cc: new@example.com
        -Cc: old@example.com
        Subject: x
        Body: y
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.ccDelta?.adds.count == 1)
        #expect(result.ccDelta?.adds.first?.email == "new@example.com")
        #expect(result.ccDelta?.removes == ["old@example.com"])
    }

    @Test("-To: lowercases emails for case-insensitive matching")
    func removalsLowercased() {
        let input = """
        -To: Bob@Example.COM
        Subject: x
        Body: y
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.toDelta?.removes == ["bob@example.com"])
    }
}
