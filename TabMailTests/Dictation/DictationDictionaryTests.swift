/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The user's dictation dictionary (ADR-IOS-086), kept on this device: TabMail Voice's rules
/// (ADR-DESK-038), in a UserDefaults suite of the test's own.
@MainActor
struct DictationDictionaryTests {
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "DictationDictionaryTests-\(UUID().uuidString)"))
    }

    @Test func isEmptyAndLearnsWordsByDefault() {
        let dictionary = DictationDictionary(defaults: defaults)
        #expect(dictionary.entries.isEmpty)
        #expect(dictionary.snapshot == .init(words: [], learnsWords: true))
    }

    @Test func keepsTypedAndLearnedWordsInOrderAcrossALaunch() {
        let dictionary = DictationDictionary(defaults: defaults)
        #expect(dictionary.add("Xyvora") == .added)
        #expect(dictionary.learn(["Kaelthorne Drake"]) == ["Kaelthorne Drake"])
        dictionary.learnsWords = false

        let relaunched = DictationDictionary(defaults: defaults)
        #expect(relaunched.entries == [.init(word: "Xyvora", learned: false), .init(word: "Kaelthorne Drake", learned: true)])
        #expect(relaunched.snapshot == .init(words: ["Xyvora", "Kaelthorne Drake"], learnsWords: false))
    }

    @Test func aWordAlreadyThereIsNotAddedTwiceWhateverItsCase() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.add("Xyvora")
        #expect(dictionary.add("XYVORA") == .added)
        #expect(dictionary.learn(["xyvora", "Brevalle"]) == ["Brevalle"])
        #expect(dictionary.entries.map(\.word) == ["XYVORA", "Brevalle"])
    }

    /// Typing a word already there, in another spelling, is the user's latest word for it: it takes
    /// that spelling, and one learned no longer shows as learned.
    @Test func typingAWordAlreadyThereTakesTheSpellingTyped() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.learn(["Tabmail"])
        #expect(dictionary.add("TabMail") == .added)
        #expect(dictionary.entries == [.init(word: "TabMail", learned: false)])
        dictionary.add("XyVora")
        #expect(dictionary.add("Xyvora") == .added)
        #expect(dictionary.entries == [.init(word: "TabMail", learned: false), .init(word: "Xyvora", learned: false)])
    }

    @Test(arguments: [
        "", "   ", String(repeating: "x", count: DictationConfig.dictionaryWordMaxChars + 1),
        "one two three four five six seven", "Xy<vora", "Xy>vora", "Xy\u{7}vora", "Xy\u{7F}vora", "Xy\u{9F}vora",
        // U+FEFF is a space to the backend (JavaScript's `\s` and `trim`): nothing, or a seventh word.
        "\u{FEFF}", "one two three four five six\u{FEFF}seven",
    ])
    func refuses(_ word: String) {
        let dictionary = DictationDictionary(defaults: defaults)
        #expect(dictionary.add(word) == .invalid)
        #expect(dictionary.learn([word]) == [])
        #expect(dictionary.entries.isEmpty)
    }

    /// The backend counts UTF-16 code units: 50 fit, whatever the script.
    @Test func takesTheLongestWordTheBackendTakes() {
        let dictionary = DictationDictionary(defaults: defaults)
        let longest = String(repeating: "한", count: DictationConfig.dictionaryWordMaxChars)
        #expect(dictionary.add(longest) == .added)
        #expect(dictionary.add(String(repeating: "😀", count: DictationConfig.dictionaryWordMaxChars / 2 + 1)) == .invalid)
        #expect(dictionary.add("one two three four five six") == .added)
    }

    @Test func collapsesAWordsSpaces() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.add("  Kaelthorne \n  Drake ")
        // A next-line character is a line break too: collapsed, not refused as a control.
        dictionary.add("Brevalle\u{85}Labs")
        // So is U+FEFF, as the backend counts it.
        dictionary.add("\u{FEFF}Xyvora\u{FEFF}Quill\u{FEFF}")
        #expect(dictionary.entries.map(\.word) == ["Kaelthorne Drake", "Brevalle Labs", "Xyvora Quill"])
    }

    /// Half the words sent with a dictation: the other half is picked from its context.
    @Test func holdsAtMostItsHalfOfTheWordsSent() {
        let dictionary = DictationDictionary(defaults: defaults)
        for index in 0..<DictationConfig.dictionaryMaxEntries { dictionary.add("Word\(index)") }
        #expect(dictionary.add("Xyvora") == .full)
        #expect(dictionary.learn(["Brevalle"]) == [])
        // A word already there is still made typed when full.
        #expect(dictionary.add("word0") == .added)
        #expect(dictionary.entries.count == DictationConfig.dictionaryMaxEntries)
        #expect(DictationConfig.dictionaryMaxEntries + DictationConfig.contextTermsMax == 200)
    }

    @Test func removesAWordByItsSpelling() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.add("Xyvora")
        dictionary.add("Brevalle")
        dictionary.remove("xyvora")
        #expect(dictionary.entries.map(\.word) == ["Xyvora", "Brevalle"])
        dictionary.remove("Xyvora")
        #expect(DictationDictionary(defaults: defaults).entries.map(\.word) == ["Brevalle"])
    }

    /// Whatever is stored, only valid entries are read back: no duplicates, no word the backend
    /// refuses, at most the limit.
    @Test func readsBackOnlyValidEntries() throws {
        let stored: [DictationDictionary.Entry] = [
            .init(word: "Xyvora", learned: false), .init(word: "XYVORA", learned: true), .init(word: "Xy<vora", learned: false),
            .init(word: " Brevalle", learned: false), .init(word: "Brevalle", learned: true),
        ] + (0..<DictationConfig.dictionaryMaxEntries).map { .init(word: "Word\($0)", learned: false) }
        defaults.set(try JSONEncoder().encode(stored), forKey: DictationDictionary.entriesKey)

        let entries = DictationDictionary(defaults: defaults).entries
        #expect(entries.count == DictationConfig.dictionaryMaxEntries)
        #expect(Array(entries.prefix(3)) == [.init(word: "Xyvora", learned: false), .init(word: "Brevalle", learned: true), .init(word: "Word0", learned: false)])

        defaults.set(Data("not json".utf8), forKey: DictationDictionary.entriesKey)
        #expect(DictationDictionary(defaults: defaults).entries.isEmpty)
    }

    /// The backend's count (JavaScript's `trim` and split on `\s+`), scalar by scalar: its white
    /// space is these, and no other.
    private static let backendSpaces: Set<Unicode.Scalar> = Set(
        ["\u{9}", "\u{A}", "\u{B}", "\u{C}", "\u{D}", "\u{20}", "\u{A0}", "\u{1680}", "\u{2028}", "\u{2029}",
         "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}"] + (0x2000...0x200A).compactMap(Unicode.Scalar.init)
    )

    private static func backendWords(_ word: String) -> [String] {
        word.unicodeScalars.split { backendSpaces.contains($0) }.map { String($0) }
    }

    /// Whatever the client takes, typed, learned or picked, the backend takes as it was counted: as
    /// many words, none empty; else it refuses the whole dictation.
    @Test(arguments: [
        "A\u{600} B\u{600} C\u{600} D\u{600} E\u{600} F\u{600} G", "\u{600} ", "Xyvora\u{6DD} Quill",
        "\u{FEFF}", "one\u{FEFF}two three four five six", "Brevalle\u{85}Labs", "Kaelthorne\u{3000}Drake",
    ])
    func whatIsTakenTheBackendCountsTheSame(raw: String) {
        let dictionary = DictationDictionary(defaults: defaults)
        let picked = DictationContextTerms.terms(in: "met \(raw) today", excluding: [], max: DictationConfig.contextTermsMax)
        for word in [DictationDictionary.word(raw)].compactMap({ $0 }) + picked {
            let counted = Self.backendWords(word)
            #expect(!counted.isEmpty && counted.count <= DictationConfig.dictionaryWordMaxWords, "\(word.unicodeScalars.map { String($0.value, radix: 16) })")
            // As many as the client joined with spaces (scalars: a space can join the mark before it).
            #expect(counted.count == word.unicodeScalars.split(separator: " ").count)
        }
        if dictionary.add(raw) == .added {
            #expect(dictionary.entries.allSatisfy { Self.backendWords($0.word).count <= DictationConfig.dictionaryWordMaxWords })
        }
    }

    /// Settings: a word added empties the field; one refused stays, with the reason.
    @Test func settingsAddsOrSaysWhy() {
        let dictionary = DictationDictionary(defaults: defaults)
        #expect(DictationDictionaryView.submit("Xyvora", to: dictionary) == ("", nil))
        #expect(DictationDictionaryView.submit("Xy<vora", to: dictionary) == ("Xy<vora", DictationDictionaryView.invalidMessage))
        for index in 1..<DictationConfig.dictionaryMaxEntries { dictionary.add("Word\(index)") }
        #expect(DictationDictionaryView.submit("Brevalle", to: dictionary) == ("Brevalle", DictationDictionaryView.fullMessage))
        #expect(dictionary.entries.count == DictationConfig.dictionaryMaxEntries)
    }

    /// Settings: swiping rows away removes their words, and only those.
    @Test func settingsRemovesTheRowsSwipedAway() {
        let dictionary = DictationDictionary(defaults: defaults)
        ["Xyvora", "Brevalle", "Quill", "Kaelthorne"].forEach { dictionary.add($0) }
        DictationDictionaryView.remove(at: IndexSet([1, 3]), from: dictionary)
        #expect(dictionary.entries.map(\.word) == ["Xyvora", "Quill"])
    }
}
