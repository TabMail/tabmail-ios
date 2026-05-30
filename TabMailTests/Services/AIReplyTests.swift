/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.parseComposeResponse")
struct AIReplyTests {

    // MARK: - Body: Extraction

    @Test("Extracts body after Body: marker")
    func extractsBody() {
        let input = "Subject: Re: Hello\nBody: Thanks for your email.\n\nBest regards"
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Thanks for your email.\n\nBest regards")
    }

    @Test("Body extraction is case-insensitive")
    func caseInsensitive() {
        let input = "body: Hello there"
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Hello there")
    }

    @Test("Extracts multiline body content")
    func multilineBody() {
        let input = """
        Subject: Test
        Body: Line one.
        Line two.
        Line three.
        """
        let result = AIService.parseComposeResponse(input)
        #expect(result.contains("Line one."))
        #expect(result.contains("Line two."))
        #expect(result.contains("Line three."))
    }

    // MARK: - Fallback Behavior

    @Test("Returns raw text when no Body: marker found")
    func fallbackRawText() {
        let input = "Just some plain text response without markers"
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Just some plain text response without markers")
    }

    @Test("Trims whitespace from result")
    func trimsWhitespace() {
        let input = "  \n  Body: Hello world  \n  "
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Hello world")
    }

    // MARK: - Edge Cases

    @Test("Empty body after marker returns fallback")
    func emptyAfterMarker() {
        // "Body:" with nothing after → empty body → falls back to... let's check
        // Actually the regex captures everything after Body: including empty
        // If body is empty after trim, the code checks `!body.isEmpty` and skips
        // Then falls through to the fallback which returns the whole trimmed text
        let input = "Subject: Test\nBody:"
        let result = AIService.parseComposeResponse(input)
        // The regex match captures "Body:" with empty content after
        // `body` would be empty → skips → returns full trimmed text as fallback
        #expect(result == "Subject: Test\nBody:")
    }

    @Test("Subject line before Body is excluded from result")
    func subjectExcluded() {
        let input = "Subject: Meeting Tomorrow\nBody: Please confirm your attendance."
        let result = AIService.parseComposeResponse(input)
        #expect(!result.contains("Meeting Tomorrow"))
        #expect(result == "Please confirm your attendance.")
    }

    @Test("Handles Body: at start of text")
    func bodyAtStart() {
        let input = "Body: Direct body content here"
        let result = AIService.parseComposeResponse(input)
        #expect(result == "Direct body content here")
    }

    @Test("Handles empty input")
    func emptyInput() {
        let result = AIService.parseComposeResponse("")
        #expect(result == "")
    }

    @Test("Handles whitespace-only input")
    func whitespaceOnly() {
        let result = AIService.parseComposeResponse("   \n  \n  ")
        #expect(result == "")
    }

    @Test("Body with special characters")
    func specialCharacters() {
        let input = "Body: Hi! How's the Q&A going? <Thanks> & \"regards\""
        let result = AIService.parseComposeResponse(input)
        #expect(result.contains("Q&A"))
        #expect(result.contains("<Thanks>"))
    }

    @Test("Multiple Body: markers uses first one")
    func multipleBodyMarkers() {
        let input = "Body: First body\nBody: Second body"
        let result = AIService.parseComposeResponse(input)
        // Regex captures from first Body: to end, which includes "Second body"
        #expect(result.contains("First body"))
    }

    @Test("Response: before Body: is ignored in output")
    func responseBeforeBody() {
        let input = "Response: I updated your draft\nSubject: New Subject\nBody: The actual email content"
        let result = AIService.parseComposeResponse(input)
        #expect(result == "The actual email content")
        #expect(!result.contains("I updated"))
    }
}
