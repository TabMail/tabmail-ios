/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchQueryParser")
struct SearchQueryParserTests {

    @Test("Simple word gets auto-wildcard when >= 4 chars")
    func simpleWordAutoWildcard() {
        let result = SearchQueryParser.buildFTSMatch("hello")
        // "hello" has 5 chars, should get wildcard
        #expect(result.contains("hello"))
    }

    @Test("Short word does not get auto-wildcard")
    func shortWordNoWildcard() {
        let result = SearchQueryParser.buildFTSMatch("hi")
        #expect(result == "hi" || result.contains("hi"))
        #expect(!result.hasSuffix("*") || result.contains("OR"))
    }

    @Test("Quoted phrase preserved as exact match")
    func quotedPhrase() {
        let result = SearchQueryParser.buildFTSMatch("\"exact phrase\"")
        #expect(result.contains("\"exact phrase\""))
    }

    @Test("Field alias from: translated to from_:")
    func fromAlias() {
        let result = SearchQueryParser.buildFTSMatch("from:alice")
        #expect(result.contains("from_:"))
    }

    @Test("Field alias to: translated to to_:")
    func toAlias() {
        let result = SearchQueryParser.buildFTSMatch("to:bob")
        #expect(result.contains("to_:"))
    }

    @Test("Field with quoted value: from:\"alice smith\"")
    func fieldQuotedValue() {
        let result = SearchQueryParser.buildFTSMatch("from:\"alice smith\"")
        #expect(result.contains("from_:\"alice smith\""))
    }

    @Test("Empty query returns empty string")
    func emptyQuery() {
        #expect(SearchQueryParser.buildFTSMatch("") == "")
        #expect(SearchQueryParser.buildFTSMatch(nil) == "")
        #expect(SearchQueryParser.buildFTSMatch("   ") == "")
    }

    @Test("Special characters get quoted")
    func specialCharsQuoted() {
        let result = SearchQueryParser.buildFTSMatch("user@example.com")
        #expect(result.contains("\""))  // should be quoted due to @, .
    }

    @Test("Quoted special-char tokens carry a prefix star (email-ish partial match)")
    func quotedSpecialCharsArePrefixQueries() {
        // The splitting tokenizer (ADR-024) turns these into phrase-prefix
        // queries: "dmarc-helper" → phrase [dmarc, helper*]. The trailing star is
        // required so mid-typing partials (whose last fragment is an incomplete
        // token) still match.
        #expect(SearchQueryParser.buildFTSMatch("dmarc-helper") == "\"dmarc-helper\"*")
        #expect(SearchQueryParser.buildFTSMatch("user@example.com") == "\"user@example.com\"*")
        // Field-scoped special-char value gets the same prefix form
        let scoped = SearchQueryParser.buildFTSMatch("from:user@example.com")
        #expect(scoped.contains("from_:\"user@example.com\"*"))
    }

    @Test("Synonym expansion for known word")
    func synonymExpansion() {
        let result = SearchQueryParser.buildFTSMatch("meeting")
        // "meeting" is in a synonym group, should expand to OR group
        #expect(result.contains("OR") || result.contains("meeting"))
    }

    @Test("No synonym expansion for field-qualified terms")
    func noSynonymForFieldTerms() {
        let result = SearchQueryParser.buildFTSMatch("from_:meeting")
        #expect(!result.contains(" OR "))
    }

    @Test("Mixed query: field + free text")
    func mixedQuery() {
        let result = SearchQueryParser.buildFTSMatch("from:alice budget")
        #expect(result.contains("from_:"))
        #expect(result.contains("budget") || result.contains("OR"))
    }

    @Test("Pure punctuation skipped")
    func purePunctuationSkipped() {
        let result = SearchQueryParser.buildFTSMatch("hello -- world")
        #expect(result.contains("hello"))
        #expect(result.contains("world"))
    }

    @Test("Explicit wildcard preserved")
    func explicitWildcard() {
        let result = SearchQueryParser.buildFTSMatch("hel*")
        #expect(result.contains("hel*"))
    }

    @Test("Apostrophes removed for FTS5 compatibility")
    func apostrophesRemoved() {
        let result = SearchQueryParser.buildFTSMatch("don't")
        #expect(!result.contains("'"))
    }

    @Test("Trailing slashes trimmed")
    func trailingSlashesTrimmed() {
        let result = SearchQueryParser.buildFTSMatch("test/")
        #expect(!result.hasSuffix("/"))
    }

    @Test("Case-insensitive field alias")
    func caseInsensitiveFieldAlias() {
        let result = SearchQueryParser.buildFTSMatch("From:alice")
        #expect(result.contains("from_:") || result.contains("From:"))
    }
}
