/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.parseActionResponse")
struct AIActionParsingTests {

    // MARK: - Valid Actions

    @Test("Parses delete action")
    func parseDelete() {
        let result = AIService.parseActionResponse(#"{"action": "delete"}"#)
        #expect(result == .delete)
    }

    @Test("Parses archive action")
    func parseArchive() {
        let result = AIService.parseActionResponse(#"{"action": "archive"}"#)
        #expect(result == .archive)
    }

    @Test("Parses reply action")
    func parseReply() {
        let result = AIService.parseActionResponse(#"{"action": "reply"}"#)
        #expect(result == .reply)
    }

    @Test("Parses none action")
    func parseNone() {
        let result = AIService.parseActionResponse(#"{"action": "none"}"#)
        #expect(result == ActionTag.none)
    }

    // MARK: - Case Insensitivity

    @Test("Parses uppercase action")
    func parseUppercase() {
        let result = AIService.parseActionResponse(#"{"action": "DELETE"}"#)
        #expect(result == .delete)
    }

    @Test("Parses mixed case action")
    func parseMixedCase() {
        let result = AIService.parseActionResponse(#"{"action": "Archive"}"#)
        #expect(result == .archive)
    }

    // MARK: - Code Fences

    @Test("Strips ```json code fence")
    func stripsJsonFence() {
        let input = "```json\n{\"action\": \"reply\"}\n```"
        let result = AIService.parseActionResponse(input)
        #expect(result == .reply)
    }

    @Test("Strips plain ``` code fence")
    func stripsPlainFence() {
        let input = "```\n{\"action\": \"archive\"}\n```"
        let result = AIService.parseActionResponse(input)
        #expect(result == .archive)
    }

    // MARK: - Invalid Input

    @Test("Returns nil for empty string")
    func emptyString() {
        let result = AIService.parseActionResponse("")
        #expect(result == nil)
    }

    @Test("Returns nil for non-JSON")
    func nonJSON() {
        let result = AIService.parseActionResponse("I think you should delete this email")
        #expect(result == nil)
    }

    @Test("Returns nil for JSON without action field")
    func noActionField() {
        let result = AIService.parseActionResponse(#"{"result": "delete"}"#)
        #expect(result == nil)
    }

    @Test("Returns nil for unknown action value")
    func unknownAction() {
        let result = AIService.parseActionResponse(#"{"action": "forward"}"#)
        #expect(result == nil)
    }

    @Test("Returns nil for malformed JSON")
    func malformedJSON() {
        let result = AIService.parseActionResponse("{action: delete}")
        #expect(result == nil)
    }

    @Test("Handles whitespace around input")
    func whitespaceAround() {
        let result = AIService.parseActionResponse("  \n {\"action\": \"none\"} \n  ")
        #expect(result == ActionTag.none)
    }
}
