/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchQueryParser Extended")
struct SearchQueryParserExtendedTests {

    @Test("Multiple quoted phrases preserved")
    func multipleQuotedPhrases() {
        let result = SearchQueryParser.buildFTSMatch("\"hello world\" \"foo bar\"")
        #expect(result.contains("\"hello world\""))
        #expect(result.contains("\"foo bar\""))
    }

    @Test("from: field generates from_ column filter")
    func fromFieldFilter() {
        let result = SearchQueryParser.buildFTSMatch("from:alice@example.com")
        #expect(result.contains("from_"))
    }

    @Test("to: field generates to_ column filter")
    func toFieldFilter() {
        let result = SearchQueryParser.buildFTSMatch("to:bob@example.com")
        #expect(result.contains("to_"))
    }

    @Test("subject: field generates subject column filter")
    func subjectFieldFilter() {
        let result = SearchQueryParser.buildFTSMatch("subject:meeting")
        #expect(result.contains("subject"))
    }

    @Test("Mixed field and non-field terms")
    func mixedFieldAndTerms() {
        let result = SearchQueryParser.buildFTSMatch("from:alice important meeting")
        #expect(!result.isEmpty)
    }

    @Test("Numbers preserved in query")
    func numbersPreserved() {
        let result = SearchQueryParser.buildFTSMatch("invoice 12345")
        #expect(result.contains("12345"))
    }

    @Test("Unicode terms handled")
    func unicodeTerms() {
        let result = SearchQueryParser.buildFTSMatch("café résumé")
        #expect(!result.isEmpty)
    }

    @Test("Very long query doesn't crash")
    func veryLongQuery() {
        let longQuery = (0..<100).map { "word\($0)" }.joined(separator: " ")
        let result = SearchQueryParser.buildFTSMatch(longQuery)
        #expect(!result.isEmpty)
    }

    @Test("Parentheses in input don't break FTS5")
    func parenthesesHandled() {
        let result = SearchQueryParser.buildFTSMatch("(hello) world")
        #expect(!result.isEmpty)
    }

    @Test("Colon without field prefix treated as literal")
    func colonWithoutField() {
        let result = SearchQueryParser.buildFTSMatch("time: 3:00pm")
        #expect(!result.isEmpty)
    }
}
