/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The names and terms picked from what a dictation is about (ADR-IOS-086), sent with it beside the
/// user's dictionary.
struct DictationContextTermsTests {
    private func terms(_ text: String, excluding: [String] = [], max: Int = DictationConfig.vocabularyMaxTerms) -> [String] {
        DictationContextTerms.terms(in: text, excluding: excluding, max: max, rule: .legacy)
    }

    @Test func picksNamesAndTermsNotEverydayWords() {
        #expect(terms("I spoke with Xyvora about the launch plan.") == ["Xyvora"])
        #expect(terms("the brevalle report is late") == [])
    }

    /// A capital at a sentence's start is the sentence's, not a name's; after `.`, `!` or `?`, or at
    /// a line's start, a new sentence starts.
    @Test func aCapitalStartingASentenceIsNotATerm() {
        #expect(terms("Tomorrow works. Friday works too? Maybe ask Xyvora.") == ["Xyvora"])
        #expect(terms("Tomorrow works\nFriday too") == [])
        #expect(terms("It works.\" Friday too") == [])
        // A bullet or a dash is not a word: the sentence still starts after it.
        #expect(terms("- Review the launch\n• Tomorrow we ship\nDone. — Monday works") == [])
    }

    /// A capital inside a word marks a term wherever it is: "TabMail", "OKR", "iOS".
    @Test func aCapitalInsideAWordIsATermAnywhere() {
        #expect(terms("TabMail ships the OKR list for iOS.") == ["TabMail", "OKR", "iOS"])
    }

    /// Names of more than one word are kept together, up to a dictionary word's length; punctuation
    /// between them splits them; a longer run of capitals is a heading, its words counted alone.
    @Test func runsOfCapitalsAreKeptTogether() {
        #expect(terms("From: Kaelthorne Drake") == ["Kaelthorne Drake"])
        #expect(terms("I met Kaelthorne, Drake and Xyvora.") == ["Kaelthorne", "Drake", "Xyvora"])
        #expect(terms("Thanks Xyvora [Brevalle Labs] shipped it") == ["Xyvora", "Brevalle Labs"])
        #expect(terms("met Xyvora (Brevalle Labs) and cc Kaelthorne \"Drake\" today") == ["Xyvora", "Brevalle Labs", "Kaelthorne", "Drake"])
        let heading = terms("see the Quarterly Planning Review Notes Brevalle Engineering Staff")
        #expect(heading.contains("Brevalle") && heading.contains("Quarterly") && !heading.contains { $0.contains(" ") })
    }

    @Test func everydayWordsAndAddressesAreNotTerms() {
        #expect(terms("and then The report came") == [])
        #expect(terms("write to Xyvora <person@example.com> or https://Example.com/Brevalle") == ["Xyvora"])
        #expect(terms("or write to Person@Example.com today") == [])
        #expect(terms("ask 2026 or ### today") == [])
    }

    /// Each term is one the backend takes: never a refused character, a short word or a long one.
    @Test func everyTermIsAValidDictionaryWord() {
        #expect(terms("ask Al and Bo about Xy<vora today") == [])
        let long = "X" + String(repeating: "y", count: DictationConfig.dictionaryWordMaxChars)
        #expect(terms("ask \(long) today") == [])
        #expect(terms("a Kaelthorne Drake note, from Brevalle Xyvora Labs") == ["Kaelthorne Drake", "Brevalle Xyvora Labs"])
    }

    /// The most frequent first, then the earliest; none twice, whatever its case; none already in
    /// the user's dictionary; at most `max`.
    @Test func mostFrequentFirstDistinctAndCapped() {
        let text = "ask Brevalle and Xyvora. then Xyvora again, and XYVORA, and Kaelthorne"
        #expect(terms(text) == ["Xyvora", "Brevalle", "Kaelthorne"])
        #expect(terms(text, excluding: ["xyvora"]) == ["Brevalle", "Kaelthorne"])
        #expect(terms(text, max: 1) == ["Xyvora"])
        // A dictionary word in the context takes none of the room: the cap counts only the terms sent.
        #expect(terms(text, excluding: ["xyvora"], max: 2) == ["Brevalle", "Kaelthorne"])
    }

    @Test func picksInAnyScript() {
        #expect(terms("회의는 내일 Brevalle 에서") == ["Brevalle"])
        #expect(terms("회의는 내일") == [])
    }

    // MARK: The dictionary rule (ADR-IOS-101)

    /// The terms when the dictionaries know exactly `known` of the candidates (lowercase), as
    /// `SystemSpelling` would answer.
    private func dictionaryTerms(
        _ text: String, known: Set<String> = [], excluding: [String] = [], max: Int = DictationConfig.vocabularyMaxTerms
    ) -> [String] {
        let unknown = DictationContextTerms.candidates(in: text).subtracting(known)
        return DictationContextTerms.terms(in: text, excluding: excluding, max: max, rule: .dictionary(unknown: unknown))
    }

    /// The rule: a capital (or a script without case), no digit, and a lowercase form no dictionary
    /// knows. A name opening a line or a sentence is a term like any other.
    @Test func aNameAtTheStartOfALineOrSentenceIsATerm() {
        #expect(dictionaryTerms("Xyvora Brevalle  4:12 PM", known: ["pm"]) == ["Xyvora Brevalle"])
        #expect(dictionaryTerms("Tomorrow works. Xyvora agrees.", known: ["tomorrow", "works", "agrees"]) == ["Xyvora"])
        #expect(dictionaryTerms("Done.\nBrevalle ships", known: ["done", "ships"]) == ["Brevalle"])
    }

    /// A capitalised word a dictionary knows is an everyday word, not a term; one it does not know is.
    @Test func aCapitalisedWordTheDictionariesKnowIsNotATerm() {
        let text = "ask Monday about the Report from Xyvora"
        #expect(dictionaryTerms(text, known: ["report", "ask", "about", "the", "from"]) == ["Monday", "Xyvora"])
        #expect(dictionaryTerms(text, known: ["monday", "report", "ask", "about", "the", "from"]) == ["Xyvora"])
    }

    /// A word with no capital is never a term, whatever the dictionaries say; a word with a digit
    /// is never one either.
    @Test func lowercaseWordsAndWordsWithDigitsAreNotTerms() {
        #expect(dictionaryTerms("the brevalle report is late") == [])
        #expect(dictionaryTerms("ask Xyvora2 and Q3 and Brevalle") == ["Brevalle"])
        #expect(DictationContextTerms.candidates(in: "the brevalle report ask Xyvora2 Brevalle") == ["brevalle"])
    }

    /// A word in a script without case has no capital to ask for: the dictionaries decide.
    @Test func aScriptWithoutCaseIsJudgedByTheDictionariesAlone() {
        #expect(dictionaryTerms("회의는 내일 Brevalle 에서", known: ["회의는", "내일", "에서"]) == ["Brevalle"])
        // Words the dictionaries do not know run together like any other terms.
        #expect(dictionaryTerms("회의는 내일 Brevalle 에서") == ["회의는 내일 Brevalle 에서"])
        #expect(DictationContextTerms.candidates(in: "회의는 Brevalle") == ["회의는", "brevalle"])
        #expect(dictionaryTerms("회의는 내일", known: ["회의는", "내일"]) == [])
        #expect(dictionaryTerms("회의는 내일") == ["회의는 내일"])
    }

    /// A name that starts with a titlecase letter (a digraph such as U+01C5) has a capital like any
    /// other; the same name in lowercase has none.
    @Test func aTitlecaseLetterIsACapital() {
        let titlecase = "\u{01C5}uro", lowercase = "\u{01C6}uro"
        #expect(DictationContextTerms.candidates(in: "\(titlecase) and \(lowercase)") == [lowercase])
        #expect(dictionaryTerms("\(titlecase) and \(lowercase)") == [titlecase])
        #expect(dictionaryTerms("\(titlecase) and \(lowercase)", known: [lowercase]) == [])
    }

    /// Runs, headings, frequency, the dictionary's own words, the cap and the backend's limits work as
    /// they do under the earlier rule.
    @Test func runsFrequencyAndLimitsAreAsBefore() {
        #expect(dictionaryTerms("From: Kaelthorne Drake", known: ["from"]) == ["Kaelthorne Drake"])
        #expect(dictionaryTerms("I met Kaelthorne, Drake and Xyvora.", known: ["i", "met", "and"]) == ["Kaelthorne", "Drake", "Xyvora"])
        let text = "ask Brevalle and Xyvora. then Xyvora again, and XYVORA, and Kaelthorne"
        let known: Set = ["ask", "and", "then", "again"]
        #expect(dictionaryTerms(text, known: known) == ["Xyvora", "Brevalle", "Kaelthorne"])
        #expect(dictionaryTerms(text, known: known, excluding: ["xyvora"]) == ["Brevalle", "Kaelthorne"])
        #expect(dictionaryTerms(text, known: known, max: 1) == ["Xyvora"])
        #expect(dictionaryTerms("ask Al and Xy<vora today", known: ["ask", "and", "today"]) == [])
    }

    @Test func addressesAreNotTermsUnderTheDictionaryRule() {
        let text = "write to Xyvora <person@example.com> or https://Example.com/Brevalle or Person@Example.com"
        #expect(dictionaryTerms(text, known: ["write", "to", "or"]) == ["Xyvora"])
    }

    /// No dictionary is asked about a word that cannot be a term.
    @Test func candidatesAreTheLowercaseFormsOfWordsThatCouldBeTerms() {
        #expect(DictationContextTerms.candidates(in: "Ask Xyvora, (Brevalle) and XYVORA about iOS 26 at 4:12") == ["ask", "xyvora", "brevalle", "ios"])
        #expect(DictationContextTerms.candidates(in: "") == [])
    }
}
