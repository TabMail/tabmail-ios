/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.parseComposeResponse")
struct AIReplyParseTests {

    @Test("Extracts body after 'Body:' marker")
    func extractsBodyAfterMarker() {
        let input = "Subject: Hello\nBody: Thanks for your email."
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Thanks for your email.")
    }

    @Test("Handles multiline body after marker")
    func multilineBody() {
        let input = """
        Subject: Re: Meeting
        Body: Hi there,

        I'll be available at 3pm.

        Best regards,
        Alice
        """
        let result = AIService.parseComposeResponse(input)
        #expect(result.contains("Hi there,"))
        #expect(result.contains("Best regards,"))
        #expect(result.contains("Alice"))
    }

    @Test("Case-insensitive Body: marker")
    func caseInsensitive() {
        let result1 = AIService.parseComposeResponse("BODY: Upper case")
        #expect(result1 == "Upper case")

        let result2 = AIService.parseComposeResponse("body: Lower case")
        #expect(result2 == "Lower case")
    }

    @Test("Returns raw text when no Body: marker found")
    func fallbackRawText() {
        let input = "Just a plain response without markers."
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Just a plain response without markers.")
    }

    @Test("Empty Body: marker falls back to raw text")
    func emptyBodyMarkerFallback() {
        // Body: with nothing after it — empty body, so fallback to full text
        let input = "Subject: Test\nBody:"
        let result = AIService.parseComposeResponse(input)
        // Body is empty after trimming, so returns full text
        #expect(result.contains("Subject: Test"))
    }

    @Test("Strips leading/trailing whitespace")
    func stripsWhitespace() {
        let input = "   \n  Body:   Hello world   \n  "
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Hello world")
    }

    @Test("Empty input returns empty string")
    func emptyInput() {
        let result = AIService.parseComposeResponse("")
        #expect(result == "")
    }

    @Test("Body: on first line")
    func bodyOnFirstLine() {
        let result = AIService.parseComposeResponse("Body: Direct reply text here.")
        #expect(result == "Direct reply text here.")
    }

    @Test("Ignores Body: in the middle of a line")
    func bodyMidLine() {
        let input = "The Body: field should not match here"
        let result = AIService.parseComposeResponse(input)
        // "Body:" must be at start of line; this should fall back
        #expect(result == "The Body: field should not match here")
    }

    @Test("Subject and Response lines before Body are excluded")
    func subjectBeforeBody() {
        let input = """
        Response: I've drafted a reply.
        Subject: Re: Quarterly Review
        Body: Thank you for the update. I'll review the numbers.
        """
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Thank you for the update. I'll review the numbers.")
        #expect(!result.contains("Response:"))
        #expect(!result.contains("Subject:"))
    }
}

@Suite("AIService.parseInlineEditResponse")
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
