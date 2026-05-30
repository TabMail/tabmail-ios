/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AIService.parseActionResponse")
struct AIActionParsingExtendedTests {

    @Test("Parses delete action from plain JSON")
    func parseDelete() {
        let result = AIService.parseActionResponse(#"{"action":"delete"}"#)
        #expect(result == .delete)
    }

    @Test("Parses archive action from plain JSON")
    func parseArchive() {
        let result = AIService.parseActionResponse(#"{"action":"archive"}"#)
        #expect(result == .archive)
    }

    @Test("Parses reply action from plain JSON")
    func parseReply() {
        let result = AIService.parseActionResponse(#"{"action":"reply"}"#)
        #expect(result == .reply)
    }

    @Test("Parses none action from plain JSON")
    func parseNone() {
        let result = AIService.parseActionResponse(#"{"action":"none"}"#)
        #expect(result == ActionTag.none)
    }

    @Test("Case insensitive: DELETE")
    func caseInsensitive() {
        let result = AIService.parseActionResponse(#"{"action":"DELETE"}"#)
        #expect(result == .delete)
    }

    @Test("Case insensitive: Archive")
    func caseInsensitiveMixed() {
        let result = AIService.parseActionResponse(#"{"action":"Archive"}"#)
        #expect(result == .archive)
    }

    @Test("Strips markdown code fences")
    func stripMarkdownFences() {
        let text = """
        ```json
        {"action":"reply"}
        ```
        """
        let result = AIService.parseActionResponse(text)
        #expect(result == .reply)
    }

    @Test("Unknown action returns nil")
    func unknownAction() {
        let result = AIService.parseActionResponse(#"{"action":"forward"}"#)
        #expect(result == nil)
    }

    @Test("Invalid JSON returns nil")
    func invalidJSON() {
        let result = AIService.parseActionResponse("not json at all")
        #expect(result == nil)
    }

    @Test("Empty string returns nil")
    func emptyString() {
        let result = AIService.parseActionResponse("")
        #expect(result == nil)
    }

    @Test("Whitespace-wrapped JSON parses correctly")
    func whitespaceWrapped() {
        let result = AIService.parseActionResponse("  \n  {\"action\":\"delete\"}  \n  ")
        #expect(result == .delete)
    }

    @Test("Missing action field returns nil")
    func missingField() {
        let result = AIService.parseActionResponse(#"{"result":"delete"}"#)
        #expect(result == nil)
    }
}

@Suite("ChatIdTranslator.collectRefs")
struct ChatIdTranslatorCollectRefsTests {

    @Test("Extracts Email refs")
    func extractEmailRefs() {
        let text = "Check [Email](42) for details"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.contains(42))
        #expect(refs.count == 1)
    }

    @Test("Extracts Contact refs")
    func extractContactRefs() {
        let text = "Contact [Contact](7) for info"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.contains(7))
    }

    @Test("Extracts Event refs")
    func extractEventRefs() {
        let text = "See [Event](99) tomorrow"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.contains(99))
    }

    @Test("Extracts multiple refs")
    func extractMultipleRefs() {
        let text = "See [Email](1) and [Email](2) and [Contact](3)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs == Set([1, 2, 3]))
    }

    @Test("Handles compound IDs")
    func compoundIds() {
        let text = "See [Event](5:10)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.contains(5))
        #expect(refs.contains(10))
    }

    @Test("No refs in plain text")
    func noRefs() {
        let text = "Hello, this is plain text"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.isEmpty)
    }

    @Test("Empty string returns empty set")
    func emptyString() {
        let refs = ChatIdTranslator.collectRefs(from: "")
        #expect(refs.isEmpty)
    }

    @Test("Deduplicates refs")
    func deduplicates() {
        let text = "[Email](5) and again [Email](5)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.count == 1)
        #expect(refs.contains(5))
    }

    @Test("Does not match non-entity patterns")
    func nonEntityPatterns() {
        let text = "[Link](42) and [Other](7)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.isEmpty)
    }
}

@Suite("AIService.normalizeUnicode Extended")
struct NormalizeUnicodeExtendedTests {

    @Test("Ellipsis normalized to three dots")
    func ellipsis() {
        let result = AIService.normalizeUnicode("hello\u{2026}world")
        #expect(result.contains("..."))
    }

    @Test("Fullwidth brackets normalized")
    func fullwidthBrackets() {
        let result = AIService.normalizeUnicode("\u{3010}title\u{3011}")
        #expect(result == "[title]")
    }

    @Test("Plain ASCII unchanged")
    func plainAsciiUnchanged() {
        let result = AIService.normalizeUnicode("Hello world 123!")
        #expect(result == "Hello world 123!")
    }

    @Test("Empty string returns empty")
    func emptyString() {
        let result = AIService.normalizeUnicode("")
        #expect(result == "")
    }
}
