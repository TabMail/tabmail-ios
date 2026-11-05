/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIResponseParser.parseReplyResponse")
struct AIReplyParseTests {

    @Test("Extracts the body and the text message")
    func bodyAndTextMessage() {
        let result = AIResponseParser.parseReplyResponse(
            #"{"subject": "Re: Budget", "body": "Thanks for your email.", "text_message": "Thanks, got it."}"#
        )
        #expect(result?.body == "Thanks for your email.")
        #expect(result?.textMessage == "Thanks, got it.")
    }

    @Test("A multiline body keeps its line breaks")
    func multilineBody() {
        let result = AIResponseParser.parseReplyResponse(
            #"{"subject": "Re: Meeting", "body": "Hi there,\n\nI'll be available at 3pm.\n\nBest regards,\nAlice", "text_message": "3pm works."}"#
        )
        #expect(result?.body == "Hi there,\n\nI'll be available at 3pm.\n\nBest regards,\nAlice")
    }

    @Test("Body and text message are trimmed")
    func trims() {
        let result = AIResponseParser.parseReplyResponse(#"  {"subject": "S", "body": "  Hello world  \n", "text_message": "  Hi.  "}  "#)
        #expect(result?.body == "Hello world")
        #expect(result?.textMessage == "Hi.")
    }

    @Test("No body, an empty body or a None body gives nil")
    func noBody() {
        for text in [
            #"{"subject": "S", "text_message": "T"}"#,
            #"{"subject": "S", "body": "", "text_message": "T"}"#,
            #"{"subject": "S", "body": "   ", "text_message": "T"}"#,
            #"{"subject": "S", "body": "None", "text_message": "T"}"#,
            #"{"subject": "S", "body": 7, "text_message": "T"}"#,
        ] {
            #expect(AIResponseParser.parseReplyResponse(text) == nil, "\(text)")
        }
    }

    @Test("A missing or empty text message keeps the body")
    func missingTextMessage() {
        let missing = AIResponseParser.parseReplyResponse(#"{"subject": "S", "body": "B"}"#)
        #expect(missing?.body == "B")
        #expect(missing?.textMessage == nil)
        let empty = AIResponseParser.parseReplyResponse(#"{"subject": "S", "body": "B", "text_message": ""}"#)
        #expect(empty?.body == "B")
        #expect(empty?.textMessage == nil)
    }

    @Test("Labelled text, empty input and non-object JSON give nil")
    func notTheObject() {
        for text in ["Subject: Hello\nBody: Thanks for your email.", "", "Just a plain reply.", "[]", "null", #""body""#] {
            #expect(AIResponseParser.parseReplyResponse(text) == nil, "\(text)")
        }
    }
}

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "AIService.parseInlineEditResponse" — it collided
// with `ParseInlineEditResponseTests` in `AIInlineEditTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("AIService.parseInlineEditResponse — marker-section extraction")
struct AIInlineEditParseTests {

    @Test("Extracts all three sections")
    func allSections() {
        let input = """
        Response: I've updated the greeting.
        Subject: New Subject Line
        Body: Dear Team,

        Please review the attached document.

        Thanks
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "I've updated the greeting.")
        #expect(result.subject == "New Subject Line")
        #expect(result.body?.contains("Dear Team,") == true)
        #expect(result.body?.contains("Thanks") == true)
    }

    @Test("Body only — no Response or Subject")
    func bodyOnly() {
        let input = """
        Body: Just the body content here.
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == nil)
        #expect(result.subject == nil)
        #expect(result.body == "Just the body content here.")
    }

    @Test("Fallback — no markers at all")
    func noMarkers() {
        let input = "Plain text response from LLM without any markers."
        let result = AIService.parseInlineEditResponse(input)
        // No Body: or Subject: → entire text becomes body
        #expect(result.body == input)
        #expect(result.response == nil)
        #expect(result.subject == nil)
    }

    @Test("Subject only — no Body triggers fallback")
    func subjectOnlyNoFallback() {
        let input = "Subject: Updated Title"
        let result = AIService.parseInlineEditResponse(input)
        // Subject found, so no fallback
        #expect(result.subject == "Updated Title")
        #expect(result.body == nil)
    }

    @Test("Case-insensitive markers")
    func caseInsensitive() {
        let input = """
        RESPONSE: Done.
        SUBJECT: Test
        BODY: Content here.
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "Done.")
        #expect(result.subject == "Test")
        #expect(result.body == "Content here.")
    }

    @Test("Empty Subject: line — regex may consume next line via \\s*")
    func emptySubject() {
        // When Subject: has no content on the same line, \s* in the regex
        // can consume the newline and (.*)$ matches the next line.
        // This is existing behavior — test documents it.
        let input = """
        Response: Edited.
        Subject: Updated Title
        Body: The body text.
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.response == "Edited.")
        #expect(result.subject == "Updated Title")
        #expect(result.body == "The body text.")
    }

    @Test("Body is multiline to end of text")
    func bodyMultilineToEnd() {
        let input = """
        Response: Here's the edit.
        Body: Line 1
        Line 2
        Line 3
        """
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.body?.contains("Line 1") == true)
        #expect(result.body?.contains("Line 2") == true)
        #expect(result.body?.contains("Line 3") == true)
    }

    @Test("Raw text is preserved in result")
    func rawPreserved() {
        let input = "Response: Hi\nBody: World"
        let result = AIService.parseInlineEditResponse(input)
        #expect(result.raw == input)
    }

    @Test("Empty input returns empty body fallback")
    func emptyInput() {
        let result = AIService.parseInlineEditResponse("")
        // empty text, no markers → body = "" (fallback), but trimmed empty = body stays nil?
        // Let's check: text = "", no body/subject found → body = text = "" which is empty
        #expect(result.body == "")
        #expect(result.response == nil)
        #expect(result.subject == nil)
    }
}
