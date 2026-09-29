/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The names and terms picked from what a dictation is about (ADR-IOS-086), sent with it beside the
/// user's dictionary.
struct DictationContextTermsTests {
    private func terms(_ text: String, excluding: [String] = [], max: Int = DictationConfig.contextTermsMax) -> [String] {
        DictationContextTerms.terms(in: text, excluding: excluding, max: max)
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
        #expect(DictationConfig.contextTermsMax == 100)
    }

    @Test func picksInAnyScript() {
        #expect(terms("회의는 내일 Brevalle 에서") == ["Brevalle"])
        #expect(terms("회의는 내일") == [])
    }
}
