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

    /// ⚠️ This assertion used to be `#expect(!result.isEmpty)`, which was VACUOUS: the parser scanned
    /// UTF-8 bytes and rebuilt the string with `Character(UnicodeScalar(byte))`, so `café` came out as
    /// `cafÃ©` — non-empty, so the test passed, while every non-ASCII search silently matched nothing.
    /// A non-emptiness check cannot distinguish correct output from corrupted output. Assert the
    /// CHARACTERS survive.
    @Test("Unicode terms survive byte-level parsing uncorrupted")
    func unicodeTerms() {
        let result = SearchQueryParser.buildFTSMatch("café résumé")
        #expect(result.contains("café"), "expected 'café' to survive; got \(result)")
        #expect(result.contains("résumé"), "expected 'résumé' to survive; got \(result)")
        // The specific mojibake the Latin-1 remap produced — named so a regression is unmistakable.
        #expect(!result.contains("Ã"), "UTF-8 bytes were reinterpreted as Latin-1: \(result)")
    }

    @Test("Non-ASCII survives alongside a field alias, which is the byte-scanning path")
    func unicodeWithFieldAlias() {
        // translateAliases is the function that scans bytes, so the alias must be rewritten AND the
        // non-ASCII text after it preserved — the two must hold at the same time.
        let result = SearchQueryParser.buildFTSMatch("from:josé budget")
        #expect(result.contains("from_:"), "alias not translated: \(result)")
        #expect(result.contains("josé"), "non-ASCII corrupted by the alias scan: \(result)")
        #expect(!result.contains("Ã"), "mojibake present: \(result)")
    }

    @Test("CJK and emoji survive the parser")
    func unicodeNonLatinScripts() {
        // Latin-1 remapping mangles any multi-byte scalar, not just accented Latin.
        let result = SearchQueryParser.buildFTSMatch("会議 プロジェクト")
        #expect(result.contains("会議"), "CJK corrupted: \(result)")
        #expect(result.contains("プロジェクト"), "CJK corrupted: \(result)")
    }

    @Test("A pasted URL is searched as text, not split into a bogus FTS column")
    func urlIsNotTreatedAsFieldQuery() {
        // `https://…` split at the first colon into field `https`, which is not an FTS5 column, so
        // FTS5 rejected the whole expression and the user got nothing back from an ordinary paste.
        let result = SearchQueryParser.buildFTSMatch("https://example.com/order/123")
        // The whole token must come out as a QUOTED PHRASE, which is how FTS5 is told to treat it as
        // text. Checking for the absence of the substring "https:" would be wrong — it appears inside
        // those quotes legitimately. What matters is that it is not an unquoted `column:value`.
        #expect(result.contains("\"https://example.com/order/123\""), "URL not treated as phrase text: \(result)")
        #expect(!result.hasPrefix("https:"), "URL scheme emitted as an FTS column: \(result)")
    }

    @Test("Only real FTS columns are honoured as field prefixes")
    func onlyKnownFieldsAreColumns() {
        // Two-sided: a real column must still work, or this passes by rejecting everything.
        #expect(SearchQueryParser.buildFTSMatch("subject:budget").contains("subject:"))
        #expect(SearchQueryParser.buildFTSMatch("from:alice").contains("from_:"))
        // An invented column must fall through as phrase TEXT, not be emitted as a column prefix.
        // It is quoted because ':' is a character requiring quotes, so assert the quoting rather than
        // the absence of the substring.
        let bogus = SearchQueryParser.buildFTSMatch("nosuchfield:value")
        #expect(bogus.contains("\"nosuchfield:value\""), "unknown field not treated as text: \(bogus)")
        #expect(!bogus.hasPrefix("nosuchfield:"), "unknown column emitted into MATCH: \(bogus)")
    }

    /// ⚠️ This replaces a test named `quoteInFieldPrefixIsNotAColumn`, which was VACUOUS: it asserted
    /// `!result.contains("a\"b:")` for the input `a"b:c`, but `buildFTSMatch` splits the query on every
    /// `"` BEFORE tokenising, so no token can ever contain a quote and the assertion already held
    /// against the unfixed parser. It pinned a rationale that was itself false. The real half of that
    /// class — a field prefix reaching the MATCH expression — is the QUOTED route below, which was
    /// genuinely open because it never calls `splitField`.
    @Test("A field:\"quoted value\" prefix is honoured only for real FTS columns")
    func quotedFieldOnlyForRealColumns() {
        // Two-sided: a real column must still produce a column-scoped phrase.
        let good = SearchQueryParser.buildFTSMatch("subject:\"quarterly budget\"")
        #expect(good.contains("subject:\"quarterly budget\""), "real column lost its phrase: \(good)")

        // An invented column must NOT be emitted as a column. `extractFieldQuoted` used to re-emit any
        // ident-led prefix verbatim, so FTS5 raised "no such column: tag", keywordSearchShard threw,
        // and the user got nothing back — the same silent empty result as the pasted-URL case.
        let bogus = SearchQueryParser.buildFTSMatch("tag:\"urgent\"")
        #expect(!bogus.contains("tag:\"urgent\""), "unknown column emitted into MATCH: \(bogus)")
        #expect(bogus.lowercased().contains("urgent"), "the value must still be searchable as text: \(bogus)")

        // Any ordinary word does it, not just a suspicious one.
        // Structural, not substring: `note:` inside a quoted phrase is text. The fix turns the prefix
        // into quoted text, so asserting the absence of the substring would fail against the fix.
        let note = SearchQueryParser.buildFTSMatch("note:\"call mom\"")
        #expect(!note.hasPrefix("note:"), "unknown column emitted into MATCH: \(note)")
        #expect(note.contains("\"note:\""), "the prefix should be quoted as text: \(note)")
    }

    @Test("A non-ASCII field prefix is not mistaken for a column")
    func nonASCIIFieldPrefixIsNotAColumn() {
        // `isIdentStart`/`isIdentChar` built a Character from a single byte, so UTF-8 continuation
        // bytes were read as Latin-1 letters: `ê` is `C3 AA`, and both bytes reported isLetter == true.
        // `ê:"x"` was therefore accepted as a field named `ê` and emitted into the MATCH expression.
        let result = SearchQueryParser.buildFTSMatch("ê:\"x\"")
        #expect(!result.hasPrefix("ê:"), "non-ASCII prefix emitted as a column: \(result)")
        #expect(!result.contains("Ã"), "mojibake reintroduced: \(result)")
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
