/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The FTS5 expressions `SearchQueryParser.buildFTSMatch` writes, pinned to the same strings as
/// tabmail-native-fts `query::tests` (ADR-NF-011, native-fts #14 and #31), so the two builders stay
/// one (ADR-IOS-008). What those expressions find is checked on real tables in
/// `SearchQueryTextSearchTests`.
@Suite("SearchQueryParser writes the native-fts expressions")
struct SearchQueryBuilderTests {

    private func build(_ q: String) -> String {
        SearchQueryParser.buildFTSMatch(q)
    }

    @Test("words and phrases are strings")
    func wordsAndPhrasesAreStrings() {
        #expect(build("café") == #""café"*"#)
        #expect(build("50% off") == #""50%"* "off""#)
        #expect(build("NOT (budget") == #""(budget"*"#)
        #expect(build(#"say "hi there"#) == #""say" "hi there""#)
        // One possessive 's is removed; a word with an inner apostrophe searches both spellings.
        #expect(build("it's gone?") == #""it" "gone"*"#)
        #expect(build("Sarah\u{2019}s O'Brien's don't") == #""Sarah"* AND ("O'Brien"* OR "OBrien"*) AND ("don't" OR "dont"*)"#)
        // A possessive looks up its word with the `s`: `clients` has no synonyms, so its
        // neighbours keep their stars; `comments` has.
        #expect(build("client's notes") == #""client"* "notes"*"#)
        #expect(build("comment's").contains("feedback"))
        // A possessive's `s` counts toward the automatic star's 4 bytes.
        #expect(build("Tom's it's") == #""Tom"* "it""#)
        // A possessive is read at the end of the word's text, before any trailing punctuation.
        #expect(build("Sarah's. (Sarah's) John's?.") == #""Sarah"* "(Sarah"* "John"*"#)
        #expect(build("O'Brien.") == #""O'Brien."*"#)
        // Quote marks around a word are not part of it.
        #expect(build("'budget'") == build("budget"))
        #expect(build("\u{2018}abcd\u{2019}") == #""abcd"*"#)
        #expect(build("budg*") == #""budg"*"#)
        // A user's star keeps a short word a prefix, and a starred word never expands.
        #expect(build("ab*") == #""ab"*"#)
        #expect(build("meeting*") == #""meeting"*"#)
        // An underscore is part of a word, not punctuation: no star on a short one.
        #expect(build("a_b") == #""a_b""#)
        // A NUL separates words, also when a combining mark follows it (one character).
        #expect(build("ab\u{0}cd") == #""ab" "cd""#)
        #expect(build("zebra\u{0}\u{301}") == #""zebra"*"#)
        #expect(build("subject:zebra\u{0}\u{301}") == #"subject:"zebra"*"#)
        #expect(build("''budget''") == build("budget"))
        #expect(build("\u{b2}") == "\"\u{b2}\"")
        #expect(build(#"-- "" _ ?"#) == "")
        #expect(build("*") == "")
        #expect(build("") == "")
        #expect(SearchQueryParser.buildFTSMatch(nil) == "")
        // Text the tokenizer does not index is dropped: enclosed-letter symbols and lone marks.
        // Private-use characters are indexed, so they stay.
        #expect(build("\u{24d0} \u{1f17f}\u{fe0f} \u{0301} \u{93e}") == "")
        #expect(build("\u{e000}") == "\"\u{e000}\"")
        // A short word in another script is a prefix: the star counts bytes.
        #expect(build("会議") == #""会議"*"#)
        #expect(build("Zür") == #""Zür"*"#)
        // Any whitespace separates words.
        #expect(build("abcd\tefgh\u{a0}ijkl\u{3000}mnop") == #""abcd"* "efgh"* "ijkl"* "mnop"*"#)
    }

    @Test("a word with an inner apostrophe searches both spellings")
    func aWordWithAnInnerApostropheSearchesBothSpellings() {
        // The typed spelling is a prefix unless its last part is one letter; the joined one is a
        // plain word (a star from 4 bytes); a user's star stars both.
        #expect(build("I'm we'll") == #"("I'm" OR "Im") AND ("we'll"* OR "well"*)"#)
        #expect(build("don\u{2019}t*") == "(\"don\u{2019}t\"* OR \"dont\"*)")
        #expect(build("rock'n'roll") == #"("rock'n'roll"* OR "rocknroll"*)"#)
        #expect(build("I'm*") == #"("I'm"* OR "Im"*)"#)
        // One letter counts characters, not bytes; a possessive counts toward the 4 bytes.
        #expect(build("c'\u{e8}") == "(\"c'\u{e8}\" OR \"c\u{e8}\")")
        #expect(build("a'bc's") == #"("a'bc"* OR "abc"*)"#)
        // The joined spelling's 4 bytes are counted in bytes: `lét` is 4.
        #expect(build("l'\u{e9}t") == "(\"l'\u{e9}t\"* OR \"l\u{e9}t\"*)")
        // Any other punctuation: one spelling, as typed.
        #expect(build("a'b-c") == #""a'b-c"*"#)
        // A field's value is searched as typed.
        #expect(build("from:o'brien") == #"from_:"o'brien"*"#)
        #expect(build("subject: O'Brien") == #"subject:"O'Brien"*"#)
        // A spelling group leaves its neighbours' stars alone, and a kept NOT excludes both
        // spellings.
        #expect(build("don't forg") == #"("don't" OR "dont"*) AND "forg"*"#)
        #expect(build("abcd NOT don't") == #""abcd"* NOT ("don't" OR "dont"*)"#)
        // Beside a synonym group, the joined spelling gets no automatic star, as any word.
        let q = build("meeting don't")
        #expect(q.hasPrefix("(") && q.hasSuffix(#") AND ("don't" OR "dont")"#), "\(q)")
        let starred = build("meeting we'll*")
        #expect(starred.hasPrefix("(") && starred.hasSuffix(#") AND ("we'll"* OR "well"*)"#), "\(starred)")
    }

    @Test("only the documented fields scope")
    func onlyNamedColumnsScope() {
        #expect(build("From:alice") == #"from_:"alice"*"#)
        #expect(build(#"from: "a b" x"#) == #"from_:"a b" "x""#)
        #expect(build("subject: budget") == #"subject:"budget"*"#)
        #expect(build("subject:") == "")
        #expect(build(#"subject:"""#) == "")
        #expect(build("subject:*") == "")
        #expect(build("note:launch") == #""note:launch"*"#)
        // `from :` with a space before the colon does not scope.
        #expect(build("from : alice") == #""from"* "alice"*"#)
        // Fields that are not documented are text, so FTS5 never sees an unknown column.
        #expect(build("msgId:abc") == #""msgId:abc"*"#)
        #expect(build(#"tag:"urgent""#) == #""tag:"* "urgent""#)
        #expect(build("ê:x") == #""ê:x"*"#)
        #expect(build("https://example.com/x") == #""https://example.com/x"*"#)
        // A field's value may hold a colon: the field is the text before the first one.
        #expect(build("subject:Re:") == #"subject:"Re:"*"#)
        for (typed, column) in [("subject", "subject"), ("from", "from_"), ("from_", "from_"), ("to", "to_"),
                                ("to_", "to_"), ("cc", "cc"), ("bcc", "bcc"), ("body", "body")] {
            #expect(build("\(typed.uppercased()):zorblax") == "\(column):\"zorblax\"*", "\(typed)")
        }
    }

    @Test("operators between terms stay operators")
    func operatorsBetweenTermsStayOperators() {
        #expect(build("from:alice OR from:bob") == #"from_:"alice"* OR from_:"bob""#)
        #expect(build(#""a b" NOT zebra"#) == #""a b" NOT "zebra"*"#)
        #expect(build("abcd AND efgh") == #""abcd"* AND "efgh"*"#)
        // An operator replaces one join only.
        #expect(build("abcd OR efgh ijkl") == #""abcd"* OR "efgh"* "ijkl"*"#)
        // First, last, doubled, or left with no term after it: dropped.
        #expect(build("OR abcd") == #""abcd"*"#)
        #expect(build("abcd NOT") == #""abcd"*"#)
        #expect(build("abcd OR NOT efgh") == #""abcd"* OR "efgh"*"#)
        #expect(build("abcd OR -- efgh") == #""abcd"* OR "efgh"*"#)
        #expect(build("OR AND NOT") == "")
        // Lowercase, quoted, or a field's value: text.
        #expect(build("abcd or efgh") == #""abcd"* "or" "efgh"*"#)
        #expect(build(#"abcd "OR" efgh"#) == #""abcd"* "OR" "efgh"*"#)
        #expect(build("subject: OR") == #"subject:"OR""#)
        // Beside a synonym group, an operator replaces the AND join.
        let q = build("meeting OR zebra")
        #expect(q.hasPrefix("(") && q.hasSuffix(#") OR "zebra""#), "\(q)")
        // A kept NOT excludes the word typed, not its synonyms; a dropped NOT changes nothing.
        let excluded = build("invoice NOT receipt")
        #expect(excluded.hasPrefix("(") && excluded.hasSuffix(#") NOT "receipt""#), "\(excluded)")
        #expect(build("NOT receipt") == build("receipt"))
        // At most 100 capital NOTs are kept (FTS5 nests each one); an exclusion past them is left
        // out. The decided number, not read from the config it pins.
        let cap = 100
        let nots = (0..<(cap + 5)).map { " NOT qz" + String(format: "%03d", $0) }.joined()
        let capped = build("abcd" + nots)
        #expect(capped.components(separatedBy: " NOT ").count - 1 == cap, "\(capped)")
        #expect(capped.hasSuffix("NOT \"qz" + String(format: "%03d", cap - 1) + "\"*"), "\(capped)")
        // The cap counts NOTs only: every word of a longer OR list is kept.
        let ors = build("abcd" + (0..<(cap + 5)).map { " OR qz" + String(format: "%03d", $0) }.joined())
        #expect(ors.components(separatedBy: " OR ").count - 1 == cap + 5, "\(ors)")
    }

    @Test("synonym groups are joined with AND")
    func synonymGroupsAreJoinedWithAnd() {
        let q = build(#"meeting "budget plan" from:alice"#)
        #expect(q.hasPrefix("(") && q.contains(" OR meeting OR "), "\(q)")
        // No word in a group's run of words (between quoted phrases) gets an automatic star;
        // a word in another run does.
        #expect(q.hasSuffix(#") AND "budget plan" AND from_:"alice"*"#), "\(q)")
        let runs = build(#"notes "Jane Doe" roadmapping meeting"#)
        #expect(runs.hasPrefix(#""notes"* AND "Jane Doe" AND "roadmapping" AND ("#), "\(runs)")
        // A phrase beside a word with synonyms is joined with AND, so FTS5 accepts it.
        let phrase = build(#""jane doe" meeting"#)
        #expect(phrase.hasPrefix(#""jane doe" AND ("#), "\(phrase)")
        // The user's star survives beside a group.
        let starred = build("meeting budg*")
        #expect(starred.hasPrefix("(") && starred.hasSuffix(#") AND "budg"*"#), "\(starred)")
        // Fields with no value: each takes the next item, and the joiner follows what is written.
        let empty = build("from: subject: meeting")
        #expect(empty.hasPrefix(#"from_:"subject:"* AND ("#), "\(empty)")
        // A field's value beside a group gets no automatic star either.
        for text in ["meeting from:alex", "meeting from: alex"] {
            let scoped = build(text)
            #expect(scoped.hasSuffix(#") AND from_:"alex""#), "\(scoped)")
        }
        // A parenthesis inside a word is text: it is not a group and changes no join or star.
        #expect(build("f(x) budg") == #""f(x)"* "budg"*"#)
        // A field's value is never expanded, and does not cause groups.
        #expect(build("subject:meeting zebra") == #"subject:"meeting"* "zebra"*"#)
    }
}
