/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// The words sent with a dictation go most important first, and only the first 100 reach the speech
/// models (ADR-IOS-086).
struct DictationVocabularyTests {
    private func words(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    private func list(typed: Int, learned: Int, terms: Int, overflow: Bool) -> [String] {
        DictationVocabulary.list(
            words: words("typed", typed) + words("learned", learned), typedCount: typed,
            terms: words("term", terms), includesOverflow: overflow)
    }

    /// 150 dictionary words (100 typed, 50 learned) and 80 terms, cleanup off: 100 words, the typed
    /// ones first (50), then 30 terms, then the learned (20).
    @Test func aFullDictionaryLeavesTheTermsTheirShare() {
        let sent = list(typed: 100, learned: 50, terms: 80, overflow: false)
        #expect(sent == words("typed", 50) + words("term", 30) + words("learned", 20))
    }

    /// Cleanup on: the first 100 are the same, and the words that did not fit follow, the rest of the
    /// dictionary and then the remaining terms, up to 200.
    @Test func withCleanupTheOverflowFollowsTheFirstHundred() {
        let sent = list(typed: 100, learned: 50, terms: 80, overflow: true)
        #expect(Array(sent.prefix(100)) == list(typed: 100, learned: 50, terms: 80, overflow: false))
        let rest = Array(words("typed", 100).dropFirst(50)) + Array(words("learned", 50).dropFirst(20)) + Array(words("term", 80).dropFirst(30))
        #expect(Array(sent[100...]) == Array(rest.prefix(100)))
        #expect(sent.count == 200)
        #expect(Set(sent.map { $0.lowercased() }).count == sent.count)
    }

    @Test func overflowIsCappedAtTheBackendsLimit() {
        let sent = list(typed: 100, learned: 50, terms: 150, overflow: true)
        #expect(sent.count == DictationConfig.vocabularyMaxTerms)
        #expect(Array(sent.prefix(100)) == words("typed", 50) + words("term", 30) + words("learned", 20))
    }

    /// An empty dictionary sends up to 100 terms; with no terms, up to 100 dictionary words.
    @Test func eitherSideFillsAllHundredWhenTheOtherHasNothing() {
        #expect(list(typed: 0, learned: 0, terms: 150, overflow: false) == words("term", 100))
        #expect(list(typed: 100, learned: 0, terms: 0, overflow: false) == words("typed", 100))
        #expect(list(typed: 100, learned: 50, terms: 0, overflow: false) == words("typed", 80) + words("learned", 20))
        #expect(list(typed: 0, learned: 150, terms: 0, overflow: false) == words("learned", 100))
    }

    /// The terms keep their 30 against a dictionary of typed words alone (the dictionary gets 70).
    @Test func typedWordsAloneLeaveTheTermsTheirThirty() {
        #expect(list(typed: 100, learned: 0, terms: 80, overflow: false) == words("typed", 70) + words("term", 30))
    }

    /// A few terms leave their room to the dictionary: the dictionary then takes more than its 70.
    @Test func fewTermsLeaveTheirRoomToTheDictionary() {
        let sent = list(typed: 100, learned: 50, terms: 5, overflow: false)
        #expect(sent == words("typed", 75) + words("term", 5) + words("learned", 20))
    }

    /// Typed words are never crowded out of the first 100 by learned ones, and no word is lost with
    /// cleanup on: every dictionary word is in the overflow if it is not in the first 100.
    @Test(arguments: [(0, 0, 0), (10, 5, 3), (60, 60, 40), (100, 50, 200), (3, 90, 30), (0, 150, 80)])
    func everyWordIsSentOnceWithCleanup(counts: (Int, Int, Int)) {
        let (typed, learned, terms) = counts
        let sent = list(typed: typed, learned: learned, terms: terms, overflow: true)
        let all = words("typed", typed) + words("learned", learned) + words("term", terms)
        #expect(sent.count == min(all.count, DictationConfig.vocabularyMaxTerms))
        let firstHundred = Array(sent.prefix(100))
        #expect(firstHundred.count == min(all.count, 100))
        #expect(Array(firstHundred.filter { $0.hasPrefix("typed") }) == Array(words("typed", typed).prefix(firstHundred.filter { $0.hasPrefix("typed") }.count)))
    }

    /// No typed words, only learned ones, with the context competing: the terms keep their 30 and the
    /// learned words take the other 70; a learned word is never promoted ahead of the terms.
    @Test func learnedWordsAloneLeaveTheTermsTheirThirty() {
        let off = list(typed: 0, learned: 150, terms: 50, overflow: false)
        #expect(off == words("term", 30) + words("learned", 70))
        let on = list(typed: 0, learned: 150, terms: 50, overflow: true)
        #expect(on == words("term", 30) + words("learned", 70) + Array(words("learned", 150).dropFirst(70)) + Array(words("term", 50).dropFirst(30)))
        #expect(on.count == DictationConfig.vocabularyMaxTerms)
    }

    /// Fewer than 20 learned words under typed pressure: the learned words keep only what exist, and the
    /// typed words take the rest (65 typed, 30 terms, 5 learned), in that order.
    @Test func fewLearnedWordsReserveOnlyWhatExists() {
        let off = list(typed: 100, learned: 5, terms: 50, overflow: false)
        #expect(off == words("typed", 65) + words("term", 30) + words("learned", 5))
        let on = list(typed: 100, learned: 5, terms: 50, overflow: true)
        #expect(on == off + Array(words("typed", 100).dropFirst(65)) + Array(words("term", 50).dropFirst(30)))
    }

    /// A term that is a dictionary word in another case is sent once, as the dictionary's.
    @Test func aTermMatchingADictionaryWordInAnotherCaseIsSentOnce() {
        let sent = DictationVocabulary.list(words: ["Xyvora", "Brevalle"], typedCount: 2, terms: ["xyvora", "Kaelthorne"], includesOverflow: true)
        #expect(sent == ["Xyvora", "Brevalle", "Kaelthorne"])
    }

    /// A snapshot without a typed count reads every word as typed.
    @Test func withoutATypedCountEveryWordIsTyped() {
        let dictionary = words("typed", 10)
        #expect(DictationVocabulary.list(words: dictionary, typedCount: nil, terms: [], includesOverflow: false) == dictionary)
    }
}
