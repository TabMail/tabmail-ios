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
            textMessage: "New body",
            changeCommand: "ask for a later date",
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
            textMessage: nil,
            changeCommand: nil,
            raw: "raw text"
        )
        #expect(result.response == nil)
        #expect(result.subject == nil)
        #expect(result.body == nil)
        #expect(result.raw == "raw text")
    }
}

/// The compose edit as the backend sends it to a client at the JSON protocol (2.0.0): every field,
/// in the shape the backend validates (`readStructuredComposeEdit`).
enum ComposeEditJSON {
    static func make(
        response: Any = "Made it shorter.",
        addTo: Any = [[String: Any]](), removeTo: Any = [String](),
        addCc: Any = [[String: Any]](), removeCc: Any = [String](),
        addBcc: Any = [[String: Any]](), removeBcc: Any = [String](),
        subject: Any = "Re: Offsite",
        body: Any = "Hi Sam,\n\nCount me in.\n\nBest,\nAlex",
        textMessage: Any = "Count me in.",
        changeCommand: Any = "decline instead",
        drop: String? = nil, extra: [String: Any] = [:]
    ) -> String {
        var object: [String: Any] = [
            "response": response, "add_to": addTo, "remove_to": removeTo, "add_cc": addCc,
            "remove_cc": removeCc, "add_bcc": addBcc, "remove_bcc": removeBcc, "subject": subject,
            "body": body, "text_message": textMessage, "change_command": changeCommand,
        ]
        if let drop { object[drop] = nil }
        object.merge(extra) { $1 }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("AIService.parseInlineEditResponse — the 2.0.0 compose edit JSON")
struct ParseInlineEditResponseTests {

    @Test("Reads every field of the compose edit")
    func readsEveryField() throws {
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make()))
        #expect(result.response == "Made it shorter.")
        #expect(result.subject == "Re: Offsite")
        #expect(result.body == "Hi Sam,\n\nCount me in.\n\nBest,\nAlex")
        #expect(result.textMessage == "Count me in.")
        #expect(result.changeCommand == "decline instead")
        #expect(result.toDelta == nil && result.ccDelta == nil && result.bccDelta == nil, "[] and [] leave a field unchanged")
    }

    @Test("The body is kept as the backend wrote it")
    func bodyVerbatim() throws {
        let body = "  Hi,\n\n  indented line\n"
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(body: body)))
        #expect(result.body == body)
    }

    @Test("An add item is one recipient with its name; an empty name shows the email")
    func addItems() throws {
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(
            addTo: [["name": "Doe, Ann \"A\"", "email": "ann@example.com"], ["name": "", "email": "bob@example.com"]])))
        let to = try #require(result.toDelta)
        #expect(to.adds.recipients == [
            RecipientEntry.Recipient(address: "ann@example.com", name: "Doe, Ann \"A\""),
            RecipientEntry.Recipient(address: "bob@example.com", name: nil),
        ])
        #expect(to.adds.leftovers.isEmpty)
        #expect(to.removes.isEmpty)
    }

    @Test("Removals are emails, matched in lower case; [\"*\"] clears the field")
    func removals() throws {
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(
            removeCc: ["Carol@Example.com"], removeBcc: ["*"])))
        #expect(result.ccDelta?.removes == ["carol@example.com"])
        #expect(result.bccDelta?.clearsField == true)
        #expect(result.toDelta == nil)
    }

    @Test("A blank subject is no subject from the model (the draft keeps its own); a written one is kept as written",
          arguments: ["", "   "])
    func blankSubjectIsNoSubject(_ blank: String) throws {
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(subject: blank)))
        #expect(result.subject == nil)
        // Control: a subject is kept as written.
        #expect(AIService.parseInlineEditResponse(ComposeEditJSON.make(subject: " Re: Offsite"))?.subject == " Re: Offsite")
    }

    @Test("One mailbox per item, a display name included, is read")
    func oneMailboxWithItsName() throws {
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(
            addTo: [["name": "", "email": "Ann <ann@example.com>"]], removeCc: ["\"Doe, Bob\" <Bob@example.com>"])))
        #expect(result.toDelta?.adds.recipients.map(\.address) == ["ann@example.com"])
        #expect(result.ccDelta?.removes == ["bob@example.com"])
    }

    @Test("Keys it does not know are ignored")
    func unknownKeysIgnored() throws {
        let result = try #require(AIService.parseInlineEditResponse(ComposeEditJSON.make(extra: ["tone": "warm", "v": 3])))
        #expect(result.textMessage == "Count me in.")
    }

    @Test("A missing or malformed known field is an error, never a body", arguments: [
        ComposeEditJSON.make(drop: "body"),
        ComposeEditJSON.make(body: "  \n"),
        ComposeEditJSON.make(drop: "text_message"),
        ComposeEditJSON.make(textMessage: " "),
        ComposeEditJSON.make(drop: "change_command"),
        ComposeEditJSON.make(drop: "response"),
        ComposeEditJSON.make(drop: "subject"),
        ComposeEditJSON.make(drop: "add_cc"),
        ComposeEditJSON.make(drop: "remove_bcc"),
        ComposeEditJSON.make(subject: 3),
        ComposeEditJSON.make(addTo: ["ann@example.com"]),
        ComposeEditJSON.make(addTo: [["name": "Ann"]]),
        ComposeEditJSON.make(addTo: [["name": "Ann", "email": " "]]),
        ComposeEditJSON.make(removeTo: [""]),
        ComposeEditJSON.make(removeTo: ["*", "bob@example.com"]),
        ComposeEditJSON.make(removeTo: "bob@example.com"),
        // One mailbox per item: an item naming several, or text with no address, is malformed.
        ComposeEditJSON.make(addTo: [["name": "", "email": "ann@example.com, bob@example.com"]]),
        ComposeEditJSON.make(addTo: [["name": "", "email": "Ann"]]),
        ComposeEditJSON.make(removeCc: ["ann@example.com; bob@example.com"]),
        ComposeEditJSON.make(removeCc: ["Ann"]),
        // The same mailbox twice is still two elements, and a group is not one mailbox.
        ComposeEditJSON.make(addTo: [["name": "", "email": "ann@example.com, ann@example.com"]]),
        ComposeEditJSON.make(removeTo: ["ann@example.com, ANN@example.com"]),
        ComposeEditJSON.make(addCc: [["name": "", "email": "Team: ann@example.com;"]]),
        ComposeEditJSON.make(removeBcc: ["Team: ann@example.com;"]),
    ])
    func malformedIsAnError(json: String) {
        #expect(AIService.parseInlineEditResponse(json) == nil)
    }

    @Test("Labelled text, empty text and prose are not a compose edit", arguments: [
        "Response: Updated.\nSubject: Re: Offsite\nBody: Hi Sam,\n\nCount me in.",
        "Hi Sam,\n\nCount me in.",
        "",
        "   \n ",
        "[]",
        "```json\n{}\n```",
    ])
    func notTheJSONIsAnError(text: String) {
        #expect(AIService.parseInlineEditResponse(text) == nil)
    }
}
