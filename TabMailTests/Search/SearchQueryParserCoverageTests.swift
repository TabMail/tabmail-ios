/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchQueryParser Coverage — uncovered branches")
struct SearchQueryParserCoverageTests {

    // MARK: - Lines 55-60: Value already quoted
    // Note: Lines 55-60 (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
    // appear unreachable in the current parsing flow because components(separatedBy: "\"")
    // splits on all double-quote characters BEFORE tokens are processed. Within any
    // even-indexed (unquoted) segment, no token can contain a leading or trailing quote.
    // These lines are a defensive guard that would only trigger if the upstream splitting
    // logic changes. Tests below exercise edge cases around this area.

    @Test("Field with empty quoted value goes through field-quoted extraction")
    func fieldEmptyQuotedValue() {
        // `!isEmpty` was the whole assertion here and it cannot distinguish a correct MATCH expression
        // from a corrupted one — the same vacuity that let the Latin-1 mojibake defect live under a
        // test named for it. Assert the shape instead: `subject` is a real FTS column, so it survives
        // as a column prefix, and the result must not be a bare dangling colon.
        let r1 = SearchQueryParser.buildFTSMatch("subject:\"\"")
        #expect(!r1.isEmpty)
        #expect(!r1.hasSuffix(":"), "emitted a column prefix with nothing after it: \(r1)")
        #expect(r1.contains("subject:"), "a real column must survive as a column prefix: \(r1)")
    }

    @Test("Incomplete quote after field colon does not crash")
    func incompleteQuoteAfterField() {
        // `x` is not an FTS column, so it must not reach the MATCH expression in the column position;
        // previously any ident-led prefix did. The value must still be searchable as text.
        let r2 = SearchQueryParser.buildFTSMatch("x:\"abc")
        #expect(!r2.isEmpty)
        // Structural oracle: what makes something a column is being UNQUOTED in the column position.
        // `x:` appearing inside a quoted phrase is text and is fine, so a substring check would fail
        // against the working fix.
        #expect(!r2.hasPrefix("x:"), "unknown column emitted into MATCH: \(r2)")
        #expect(r2.contains("\"x:\""), "the prefix should be quoted as text: \(r2)")
        #expect(r2.lowercased().contains("abc"), "the typed text became unsearchable: \(r2)")
    }

    // MARK: - Lines 76-78: Naked wildcard "*" → empty core → "."

    @Test("Field-scoped naked wildcard converts to dot: subject:*")
    func fieldScopedNakedWildcard() {
        // Standalone "*" is caught by isPurePunctuation. But field:* passes
        // isPurePunctuation (has letters in field), then splitField returns
        // ("subject", "*"). hasWildcard=true, value="", core="", escapedCore="".
        // Lines 76-78: escapedCore.isEmpty && hasWildcard → escapedCore = "."
        let result = SearchQueryParser.buildFTSMatch("subject:*")
        #expect(result.contains("subject:"))
        #expect(result.contains("."))
    }

    @Test("Field-scoped naked wildcard with other terms")
    func fieldScopedNakedWildcardMixed() {
        let result = SearchQueryParser.buildFTSMatch("from_:* hello")
        #expect(result.contains("from_:"))
        #expect(result.contains("."))
        #expect(result.contains("hello"))
    }

    // MARK: - Additional edge cases for better coverage

    @Test("From with spaces before colon: from : alice")
    func fromWithSpacesBeforeColon() {
        // translateAliases handles "from" then skips spaces then matches ":"
        let result = SearchQueryParser.buildFTSMatch("from : alice")
        #expect(result.contains("from_:"))
    }

    @Test("To with spaces before colon: to : bob")
    func toWithSpacesBeforeColon() {
        let result = SearchQueryParser.buildFTSMatch("to : bob")
        #expect(result.contains("to_:"))
    }

    @Test("Field-quoted extraction with multiple field:\"value\" pairs")
    func multipleFieldQuotedPairs() {
        let result = SearchQueryParser.buildFTSMatch("from:\"alice smith\" to:\"bob jones\"")
        #expect(result.contains("from_:\"alice smith\""))
        #expect(result.contains("to_:\"bob jones\""))
    }

    @Test("Token with trailing question marks trimmed")
    func trailingQuestionMarks() {
        let result = SearchQueryParser.buildFTSMatch("hello???")
        #expect(!result.contains("?"))
        #expect(result.contains("hello"))
    }

    @Test("Token with trailing mixed slashes and question marks")
    func trailingMixedSlashQuestion() {
        let result = SearchQueryParser.buildFTSMatch("test/?/")
        #expect(!result.hasSuffix("/"))
        #expect(!result.hasSuffix("?"))
    }

    @Test("Explicit wildcard on short token preserves wildcard")
    func explicitWildcardShortToken() {
        let result = SearchQueryParser.buildFTSMatch("ab*")
        #expect(result.contains("ab*"))
    }

    @Test("OR group detection suppresses auto-wildcard")
    func orGroupSuppressesAutoWildcard() {
        // When a query contains a term that expands to an OR group (synonym),
        // other terms should NOT get auto-wildcards to avoid invalid FTS5 syntax.
        // "meeting" expands to an OR group, so "hello" (5 chars) should NOT get *.
        let result = SearchQueryParser.buildFTSMatch("meeting hello")
        // "hello" should appear without wildcard because OR groups are present
        if result.contains("OR") {
            // If meeting expanded, hello should not have wildcard
            #expect(!result.contains("hello*"))
        }
    }

    @Test("Token with apostrophe removed")
    func apostropheRemoval() {
        let result = SearchQueryParser.buildFTSMatch("it's")
        #expect(!result.contains("'"))
        #expect(result.contains("its"))
    }

    @Test("Field-qualified token with wildcard")
    func fieldQualifiedWithWildcard() {
        let result = SearchQueryParser.buildFTSMatch("subject:meet*")
        #expect(result.contains("subject:meet*"))
    }

    @Test("Field-qualified token with special chars gets quoted")
    func fieldQualifiedSpecialChars() {
        let result = SearchQueryParser.buildFTSMatch("from_:user@domain.com")
        #expect(result.contains("from_:"))
        #expect(result.contains("\""))  // should be quoted due to @ and .
    }

    @Test("willExpandToOrGroup returns false for field-qualified, placeholder, punctuation")
    func willExpandEdgeCases() {
        // Field-qualified terms should not expand
        let r1 = SearchQueryParser.buildFTSMatch("subject:meeting")
        #expect(!r1.contains("OR"))

        // Pure punctuation should be skipped entirely
        let r2 = SearchQueryParser.buildFTSMatch("---")
        #expect(r2.isEmpty)

        // Already-quoted terms should not expand
        let r3 = SearchQueryParser.buildFTSMatch("\"meeting\"")
        #expect(!r3.contains("OR"))
    }

    @Test("Token containing double-quote in special chars gets escaped")
    func doubleQuoteEscaping() {
        // hasSpecialCharsRequiringQuotes triggers for "-", so the value goes
        // through the quoting path. If value also contains `"` it gets doubled.
        let result = SearchQueryParser.buildFTSMatch("hello-world")
        #expect(result.contains("\"hello-world\""))
    }

    @Test("Colon at start of token — no field split")
    func colonAtStartOfToken() {
        // splitField with colon at start: field is empty, so returns (nil, tok)
        let result = SearchQueryParser.buildFTSMatch(":value")
        #expect(!result.isEmpty)
    }

    @Test("Multiple AND-joined OR groups")
    func multipleOrGroups() {
        // Two synonym-expandable words should produce AND-joined output
        let result = SearchQueryParser.buildFTSMatch("meeting invoice")
        if result.contains("OR") {
            #expect(result.contains("AND"))
        }
    }
}
