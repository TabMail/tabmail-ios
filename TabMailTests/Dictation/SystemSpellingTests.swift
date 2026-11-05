/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Which words none of the preferred languages' spelling dictionaries knows (ADR-IOS-101).
@MainActor
struct SystemSpellingTests {
    /// Dictionaries as fakes: a language "works" when it flags the probe word, and knows exactly the
    /// words listed for it; a language not listed knows every word, as `UITextChecker` does for one
    /// it cannot check.
    @MainActor private final class FakeDictionaries {
        let known: [String: Set<String>]
        private(set) var calls: [(word: String, language: String)] = []

        init(_ known: [String: Set<String>]) { self.known = known }

        func isKnown(_ word: String, _ language: String) -> Bool {
            calls.append((word, language))
            guard let words = known[language] else { return true }
            return words.contains(word)
        }
    }

    private func unknown(_ words: Set<String>, _ languages: [String], _ dictionaries: FakeDictionaries) async -> Set<String>? {
        await SystemSpelling.unknownWords(among: words, preferredLanguages: languages, isKnown: dictionaries.isKnown)
    }

    @Test func aWordNoWorkingDictionaryKnowsIsUnknown() async {
        let dictionaries = FakeDictionaries(["en-US": ["report", "monday"]])
        #expect(await unknown(["report", "xyvora", "monday"], ["en-US"], dictionaries) == ["xyvora"])
    }

    /// A word any working dictionary knows is known: a French user's "Paris" or an English one's.
    @Test func aWordKnownToAnyPreferredLanguageIsKnown() async {
        let dictionaries = FakeDictionaries(["en-US": ["report"], "fr-FR": ["rapport", "paris"]])
        #expect(await unknown(["report", "rapport", "paris", "xyvora"], ["en-US", "fr-FR"], dictionaries) == ["xyvora"])
    }

    /// A language whose dictionary knows the probe word is `UITextChecker` calling everything correct
    /// (Korean, Polish in the simulator): it must not make every word known.
    @Test func aLanguageThatKnowsTheProbeWordIsLeftOut() async {
        let dictionaries = FakeDictionaries([
            "en-US": ["report"],
            "pl-PL": [DictationConfig.spellingProbeWord, "xyvora"],
            "ko-KR": [],
        ])
        #expect(await unknown(["xyvora", "report"], ["pl-PL", "en-US"], dictionaries) == ["xyvora"])
        #expect(dictionaries.calls.filter { $0.language == "pl-PL" }.map(\.word) == [DictationConfig.spellingProbeWord])
    }

    /// No preferred language has a working dictionary: nil, so the earlier rule applies.
    @Test func noWorkingDictionaryIsNil() async {
        let dictionaries = FakeDictionaries([:])
        #expect(await unknown(["xyvora"], ["ko-KR", "ja-JP"], dictionaries) == nil)
        #expect(await unknown(["xyvora"], [], dictionaries) == nil)
        #expect(await unknown([], ["ko-KR"], dictionaries) == nil)
    }

    /// With a working dictionary and nothing to ask about, the answer is an empty set, not nil: the
    /// dictionary rule applies and there are no terms.
    @Test func noCandidatesWithAWorkingDictionaryIsEmpty() async {
        let dictionaries = FakeDictionaries(["en-US": []])
        #expect(await unknown([], ["en-US"], dictionaries) == [])
    }

    /// Each language is probed once, however often it is listed, and a known word stops at the first
    /// dictionary that knows it.
    @Test func eachLanguageIsProbedOnceAndAKnownWordStopsEarly() async {
        let dictionaries = FakeDictionaries(["en-US": ["report"], "fr-FR": ["rapport"]])
        _ = await unknown(["report"], ["en-US", "fr-FR", "en-US"], dictionaries)
        #expect(dictionaries.calls.filter { $0.word == DictationConfig.spellingProbeWord }.map(\.language) == ["en-US", "fr-FR"])
        #expect(dictionaries.calls.filter { $0.word == "report" }.map(\.language) == ["en-US"])
    }

    /// A long batch is worked through in slices with a yield between, and stops when the task is
    /// cancelled (the dictation ended): the main thread is never held for the whole batch.
    @Test func aCancelledBatchStopsAfterItsFirstSlice() async {
        let dictionaries = FakeDictionaries(["en-US": []])
        let words = Set((0..<DictationConfig.spellingSliceWords * 20).map { "word\($0)" })
        let task = Task { @MainActor in
            await SystemSpelling.unknownWords(among: words, preferredLanguages: ["en-US"], isKnown: dictionaries.isKnown)
        }
        task.cancel()
        let unknown = await task.value
        #expect(dictionaries.calls.count <= 1 + DictationConfig.spellingSliceWords)
        #expect((unknown?.count ?? 0) <= DictationConfig.spellingSliceWords)
    }

    /// Slicing changes nothing about the answer when the task runs to its end.
    @Test func aLongBatchIsAnsweredWhole() async {
        let dictionaries = FakeDictionaries(["en-US": ["known"]])
        let words = Set((0..<DictationConfig.spellingSliceWords * 4).map { "word\($0)" }).union(["known"])
        let unknown = await SystemSpelling.unknownWords(among: words, preferredLanguages: ["en-US"], isKnown: dictionaries.isKnown)
        #expect(unknown == words.subtracting(["known"]))
    }

    /// The batch gives the main actor back between slices: other main-actor work queued behind it
    /// (the pill's animation) runs after at most one slice, not after the whole batch. Pins the effect
    /// rather than the yield, and the answer stays whole.
    @Test func otherMainActorWorkRunsBeforeALongBatchEnds() async {
        let dictionaries = FakeDictionaries(["en-US": []])
        let words = Set((0..<DictationConfig.spellingSliceWords * 4).map { "word\($0)" })
        var lookupsWhenObserverRan: Int?
        let observer = Task { @MainActor in lookupsWhenObserverRan = dictionaries.calls.count }

        let unknown = await SystemSpelling.unknownWords(among: words, preferredLanguages: ["en-US"], isKnown: dictionaries.isKnown)
        await observer.value

        #expect(unknown == words)
        #expect(dictionaries.calls.count == 1 + words.count)
        let seen = lookupsWhenObserverRan ?? Int.max
        #expect(seen <= 1 + DictationConfig.spellingSliceWords, "the observer ran after \(seen) of \(dictionaries.calls.count) lookups")
    }

    /// The device's dictionaries, for English: a made-up word is flagged and an everyday word known
    /// (the one dictionary every simulator and device carries). Korean has no spell checker.
    @Test func theSystemsEnglishDictionaryFlagsMadeUpWordsAndKnowsEverydayOnes() async throws {
        let unknown = try #require(await SystemSpelling.unknownWords(
            among: ["the", "report", "xyvora", "brevalle"], preferredLanguages: ["en-US"]))
        #expect(unknown == ["xyvora", "brevalle"])
        #expect(await SystemSpelling.unknownWords(among: ["xyvora"], preferredLanguages: ["ko-KR"]) == nil)
        #expect(await SystemSpelling.unknownWords(among: ["xyvora"], preferredLanguages: ["zz"]) == nil)
    }

    /// The range handed to the checker is the word's UTF-16 length: a decomposed accent (a letter and a
    /// combining mark) is two units but one character.
    @Test func aDecomposedAccentedWordIsCheckedWhole() async {
        let word = "re\u{301}sume\u{301}"
        #expect(await SystemSpelling.unknownWords(among: [word], preferredLanguages: ["en-US"]) == [])
    }
}
