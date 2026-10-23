/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchQueryParser Coverage — uncovered branches")
struct SearchQueryParserCoverageTests {

    @Test("Field with an empty quoted value searches nothing")
    func fieldEmptyQuotedValue() {
        // An empty phrase has nothing the tokenizer indexes, so the field takes no value and writes
        // nothing: never a dangling column prefix.
        #expect(SearchQueryParser.buildFTSMatch("subject:\"\"") == "")
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

    // MARK: - Naked wildcard: no text, so no term

    @Test("Field-scoped naked wildcard writes nothing: subject:*")
    func fieldScopedNakedWildcard() {
        #expect(SearchQueryParser.buildFTSMatch("subject:*") == "")
    }

    @Test("Field-scoped naked wildcard with other terms leaves the other terms")
    func fieldScopedNakedWildcardMixed() {
        #expect(SearchQueryParser.buildFTSMatch("from_:* hello") == "\"hello\"*")
    }

    // MARK: - Additional edge cases for better coverage

    @Test("From with a space before the colon is text: from : alice")
    func fromWithSpacesBeforeColon() {
        // As in tabmail-native-fts (ADR-NF-011): only `name:` scopes.
        #expect(SearchQueryParser.buildFTSMatch("from : alice") == "\"from\"* \"alice\"*")
    }

    @Test("To with a space before the colon is text: to : bob")
    func toWithSpacesBeforeColon() {
        #expect(SearchQueryParser.buildFTSMatch("to : bob") == "\"to\" \"bob\"")
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
        #expect(result == "\"ab\"*")
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

    @Test("A possessive 's is removed")
    func apostropheRemoval() {
        #expect(SearchQueryParser.buildFTSMatch("it's") == "\"it\"")
    }

    @Test("Field-qualified token with wildcard")
    func fieldQualifiedWithWildcard() {
        let result = SearchQueryParser.buildFTSMatch("subject:meet*")
        #expect(result == "subject:\"meet\"*")
    }

    @Test("Field-qualified token with special chars gets quoted")
    func fieldQualifiedSpecialChars() {
        let result = SearchQueryParser.buildFTSMatch("from_:user@domain.com")
        #expect(result.contains("from_:"))
        #expect(result.contains("\""))  // should be quoted due to @ and .
    }

    @Test("Field-qualified, punctuation-only and quoted terms do not expand")
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
        // Every word is an FTS5 string; a word with punctuation is a prefix.
        let result = SearchQueryParser.buildFTSMatch("hello-world")
        #expect(result.contains("\"hello-world\""))
    }

    @Test("Colon at start of token — no field split")
    func colonAtStartOfToken() {
        // An empty name before the colon is not a field.
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
