/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The names and terms picked from what a dictation is about (ADR-IOS-086, ADR-IOS-101), sent with it
/// beside the user's dictionary.
struct DictationContextTermsTests {
    /// The answers for `text`'s candidates: `answers` where given, else `fallback`.
    private func frequencies(_ text: String, _ answers: [String: WordSeen] = [:], fallback: WordSeen = .tenths(0)) -> [String: WordSeen] {
        Dictionary(uniqueKeysWithValues: DictationContextTerms.candidates(in: text).map { ($0, answers[$0] ?? fallback) })
    }

    private func terms(
        _ text: String, _ answers: [String: WordSeen] = [:], fallback: WordSeen = .tenths(0),
        excluding: [String] = [], max: Int = DictationConfig.vocabularyMaxTerms, cutoff: Int = DictationConfig.screenTermCommonZipf
    ) -> [String] {
        DictationContextTerms.terms(
            in: text, frequencies: frequencies(text, answers, fallback: fallback), excluding: excluding, max: max, cutoff: cutoff)
    }

    /// The cases TabMail Voice runs too (`word-list-cases.json`): the candidates are exactly the
    /// words the case's answers name, and the terms are its terms, from those answers and from the
    /// word list's own.
    @Test func theSharedTermCasesHold() throws {
        let cases = try WordListCases.load()
        for term in cases.terms {
            let candidates = DictationContextTerms.candidates(in: term.text)
            #expect(Set(candidates) == Set(term.zipf.keys), "\(term.name): candidates \(candidates)")
            #expect(DictationContextTerms.terms(in: term.text, frequencies: term.zipf, excluding: [], max: 1000, cutoff: cases.cutoff) == term.terms, "\(term.name)")
            guard let list = WordList.bundled else {
                Issue.record("the word list is missing")
                return
            }
            let asked = Dictionary(uniqueKeysWithValues: candidates.map { ($0, list.seen($0)) })
            #expect(asked == term.zipf, "\(term.name): the word list's answers differ")
        }
    }

    /// A word is asked about once, as written, trimmed of the punctuation around it: with a letter in
    /// it, no digit, no part of an address, and no longer than a dictionary word.
    @Test func candidatesAreTheWordsAskedAboutOnceAsWritten() {
        #expect(DictationContextTerms.candidates(in: "Today, today! (Paris) \"Paris\" -- Xyvora's O'Neil") == ["Today", "today", "Paris", "Xyvora's", "O'Neil"])
        #expect(DictationContextTerms.candidates(in: "Xyvora4 2026 4x Q3 A²") == [])
        #expect(DictationContextTerms.candidates(in: "Xyvora\u{2160} Brevalle") == ["Brevalle"])
        #expect(DictationContextTerms.candidates(in: "jordan@example.com https://example.com/Brevalle Quill") == ["Quill"])
        #expect(DictationContextTerms.candidates(in: "... -- !! ?") == [])
        let fifty = String(repeating: "x", count: DictationConfig.dictionaryWordMaxChars)
        #expect(DictationContextTerms.candidates(in: fifty + " " + fifty + "y") == [fifty])
        // The backend counts UTF-16 units: 25 astral letters are 50, 26 are 52.
        let astral = String(repeating: "\u{10400}", count: 25)
        #expect(DictationContextTerms.candidates(in: astral + " " + astral + "\u{10400}") == [astral])
    }

    /// The address checks compare scalars, not characters: a mark after the "@" doesn't hide it.
    @Test func anAddressIsRecognizedWhateverFollowsItsMarks() {
        #expect(DictationContextTerms.candidates(in: "Person@\u{301}Example.com Quill") == ["Quill"])
        #expect(DictationContextTerms.candidates(in: "https://\u{301}Example.com Quill") == ["Quill"])
    }

    /// Words are split where JavaScript's `\s` and the next-line character split them.
    @Test(arguments: ["\u{85}", "\u{A0}", "\u{FEFF}", "\u{3000}", "\u{2028}", "\u{2029}", "\u{1680}", "\u{202F}", "\t", "\r\n", "\u{B}"])
    func wordsAreSplitOnWhitespace(space: String) {
        #expect(DictationContextTerms.candidates(in: "Xyvora\(space)Brevalle") == ["Xyvora", "Brevalle"])
    }

    /// A term is a word the list sees below the cutoff; at it, the word is ordinary.
    @Test func aWordBelowTheCutoffIsATerm() {
        let answers: [String: WordSeen] = ["Xyvora": .tenths(39), "Brevalle": .tenths(40), "Quill": .tenths(0), "Kaelthorne": .tenths(75)]
        #expect(terms("Xyvora Brevalle Quill Kaelthorne", answers) == ["Quill", "Xyvora"])
        #expect(terms("Xyvora Brevalle Quill Kaelthorne", answers, cutoff: 41) == ["Quill", "Xyvora", "Brevalle"])
        #expect(terms("Xyvora Brevalle", answers, cutoff: 0) == [])
    }

    /// The capital rule is for a script no list is written in alone: with a list, an everyday word is
    /// no term whatever its case, and a rare one is a term without a capital.
    @Test func caseDecidesOnlyWhereNoListCoversTheScript() {
        let answers: [String: WordSeen] = ["Արամ": .noList, "արամ": .noList, "Today": .tenths(56), "today": .tenths(56), "kubectl": .tenths(0), "Kubectl": .tenths(0)]
        #expect(terms("Արամ արամ Today today kubectl", answers) == ["Արամ", "kubectl"])
        // A titlecase letter (the digraph U+01C5) is a capital.
        #expect(terms("\u{01C5}uro \u{01C6}uro", ["\u{01C5}uro": .noList, "\u{01C6}uro": .noList]) == ["\u{01C5}uro"])
    }

    /// A word the list has no answer for is no term, whatever it looks like.
    @Test func aWordWithoutAnAnswerIsNoTerm() {
        let text = "Xyvora Brevalle"
        #expect(DictationContextTerms.terms(in: text, frequencies: ["Xyvora": .tenths(0)], excluding: [], max: 10) == ["Xyvora"])
        #expect(DictationContextTerms.terms(in: text, frequencies: [:], excluding: [], max: 10) == [])
        // The answer is for the word as written: "xyvora" is another word.
        #expect(DictationContextTerms.terms(in: text, frequencies: ["xyvora": .tenths(0)], excluding: [], max: 10) == [])
    }

    /// Each word stands alone: a name's words are judged one by one, not joined.
    @Test func eachWordStandsAlone() {
        #expect(terms("From: Kaelthorne Drake", ["From": .tenths(66), "Kaelthorne": .tenths(0), "Drake": .tenths(40)]) == ["Kaelthorne"])
        #expect(terms("Xyvora Brevalle Labs") == ["Xyvora", "Brevalle", "Labs"])
    }

    /// The rarest first (no answer in the list, or a script without one, counting as 0), then the
    /// most often on screen, then the earliest; the same word in another case is one term, spelled
    /// as first seen.
    @Test func theRarestComeFirstThenTheMostOftenThenTheEarliest() {
        let answers: [String: WordSeen] = ["Nairobi": .tenths(35), "Priya": .tenths(36), "Tolkien": .tenths(34), "Zorbel": .noList]
        #expect(terms("Nairobi met Priya. Brevalle, Xyvora and Xyvora met Nairobi and Tolkien Zorbel", answers.merging(["met": .tenths(70), "and": .tenths(74)]) { $1 })
            == ["Xyvora", "Brevalle", "Zorbel", "Tolkien", "Nairobi", "Priya"])
        #expect(terms("xyvora Xyvora XYVORA Brevalle") == ["xyvora", "Brevalle"])
    }

    /// Only a word of at least `correctionMinWordLength` characters that the backend takes is a term;
    /// the dictionary's own words are left out, and at most `max` are returned.
    @Test func aTermIsAValidDictionaryWordNotOneTheUserHasAndAtMostMax() {
        #expect(terms("Xy Qu Brevalle") == ["Brevalle"])
        #expect(terms("Xyvora Brevalle Quill", excluding: ["quill"]) == ["Xyvora", "Brevalle"])
        #expect(terms("Xyvora Brevalle Quill", max: 2) == ["Xyvora", "Brevalle"])
        #expect(terms("Xyvora Brevalle Quill", max: 0) == [])
    }
}

/// `word-list-cases.json`, the cases TabMail Voice runs against the same word list.
struct WordListCases {
    struct Frequency {
        var name: String
        var words: [String]
        var zipf: [WordSeen]
    }

    struct Terms {
        var name: String
        var text: String
        var zipf: [String: WordSeen]
        var terms: [String]
    }

    var frequencies: [Frequency]
    var terms: [Terms]
    var cutoff: Int

    private final class Token {}

    static func load() throws -> WordListCases {
        let bundle = Bundle(for: Token.self)
        let url = try #require(bundle.url(forResource: "word-list-cases", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func seen(_ value: Any) -> WordSeen {
            (value as? Int).map(WordSeen.tenths) ?? .noList
        }
        let frequencies = try #require(root["frequencies"] as? [[String: Any]]).map { entry in
            Frequency(
                name: entry["name"] as? String ?? "", words: entry["words"] as? [String] ?? [],
                zipf: (entry["zipf"] as? [Any] ?? []).map(seen))
        }
        let terms = try #require(root["terms"] as? [[String: Any]]).map { entry in
            Terms(
                name: entry["name"] as? String ?? "", text: entry["text"] as? String ?? "",
                zipf: (entry["zipf"] as? [String: Any] ?? [:]).mapValues(seen), terms: entry["terms"] as? [String] ?? [])
        }
        return WordListCases(frequencies: frequencies, terms: terms, cutoff: try #require(root["cutoff"] as? Int))
    }
}
