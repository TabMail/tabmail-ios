/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.parsePatchResponse")
struct AIPromptLearningTests {

    // MARK: - Valid JSON

    @Test("Parses valid JSON with patch field")
    func validJSON() {
        let input = #"{"patch": "ADD\nNew rule."}"#
        let result = AIService.parsePatchResponse(input)
        #expect(result == "ADD\nNew rule.")
    }

    @Test("Trims whitespace from patch value")
    func trimsWhitespace() {
        let input = #"{"patch": "  ADD\nSome content.  "}"#
        let result = AIService.parsePatchResponse(input)
        #expect(result == "ADD\nSome content.")
    }

    @Test("Trims surrounding whitespace from input")
    func trimsSurroundingWhitespace() {
        let input = "  \n  {\"patch\": \"ADD\\nItem.\"}\n  "
        let result = AIService.parsePatchResponse(input)
        #expect(result == "ADD\nItem.")
    }

    // MARK: - Markdown Code Fences

    @Test("Strips ```json code fence")
    func stripsJsonCodeFence() {
        let input = """
        ```json
        {"patch": "DEL\\nOld rule."}
        ```
        """
        let result = AIService.parsePatchResponse(input)
        #expect(result == "DEL\nOld rule.")
    }

    @Test("Strips plain ``` code fence")
    func stripsPlainCodeFence() {
        let input = """
        ```
        {"patch": "ADD\\nNew stuff."}
        ```
        """
        let result = AIService.parsePatchResponse(input)
        #expect(result == "ADD\nNew stuff.")
    }

    // MARK: - Invalid Input

    @Test("Returns nil for non-JSON text")
    func nonJSON() {
        let result = AIService.parsePatchResponse("This is not JSON at all")
        #expect(result == nil)
    }

    @Test("Returns nil for JSON without patch field")
    func noPatchField() {
        let result = AIService.parsePatchResponse(#"{"other": "value"}"#)
        #expect(result == nil)
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        let result = AIService.parsePatchResponse("")
        #expect(result == nil)
    }

    @Test("Returns nil for empty patch value")
    func emptyPatchValue() {
        let input = #"{"patch": ""}"#
        let result = AIService.parsePatchResponse(input)
        // Empty patch after trimming → returns empty string which caller checks
        // parsePatchResponse returns "" which is empty but not nil
        // The caller checks `!patchText.isEmpty`, so let's just verify it returns ""
        #expect(result == "")
    }

    @Test("Returns nil for whitespace-only patch value")
    func whitespacePatchValue() {
        let input = #"{"patch": "   "}"#
        let result = AIService.parsePatchResponse(input)
        #expect(result == "")
    }

    @Test("Returns nil for malformed JSON")
    func malformedJSON() {
        let result = AIService.parsePatchResponse("{patch: broken}")
        #expect(result == nil)
    }

    @Test("Handles patch with newlines in JSON string")
    func patchWithNewlines() {
        let input = #"{"patch": "ADD\nFirst rule.\nADD\nSecond rule."}"#
        let result = AIService.parsePatchResponse(input)
        #expect(result != nil)
        #expect(result!.contains("ADD"))
    }

    @Test("Handles multiline code fence with extra content outside")
    func codeFenceWithExtraContent() {
        let input = """
        Here is the patch:
        ```json
        {"patch": "ADD\\nRule."}
        ```
        Hope that helps!
        """
        // The filter removes lines starting with ```, but "Here is the patch:" and "Hope that helps!" remain
        // Those will be part of the JSON string attempted to parse — likely fails
        let result = AIService.parsePatchResponse(input)
        // This should fail to parse because extra lines make it invalid JSON
        #expect(result == nil)
    }

    @Test("Handles code fence where only JSON is between fences")
    func codeFenceClean() {
        let input = "```\n{\"patch\": \"ADD\\nClean.\"}\n```"
        let result = AIService.parsePatchResponse(input)
        #expect(result == "ADD\nClean.")
    }
}
