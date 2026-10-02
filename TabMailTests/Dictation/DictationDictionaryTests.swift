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
        #expect(relaunched.entries == [.init(word: "Xyvora", learned: false, lastUsed: 1), .init(word: "Kaelthorne Drake", learned: true, lastUsed: 2)])
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
        #expect(dictionary.entries == [.init(word: "TabMail", learned: false, lastUsed: 2)])
        dictionary.add("XyVora")
        #expect(dictionary.add("Xyvora") == .added)
        #expect(dictionary.entries == [.init(word: "TabMail", learned: false, lastUsed: 2), .init(word: "Xyvora", learned: false, lastUsed: 4)])
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

    /// Owner, 2026-10-02: of the 200 words the backend takes with a dictation, the dictionary's
    /// come first, at most 150, at most 100 of them typed; learned words fill the rest, all 150 when
    /// none is typed; the context's terms fill what the dictionary leaves.
    @Test func holdsTheWordsSentBesideTheContextsAtMost100Typed() {
        #expect([DictationConfig.vocabularyMaxTerms, DictationConfig.dictionaryMaxEntries, DictationConfig.dictionaryMaxTypedWords] as [Int] == [200, 150, 100])
        let dictionary = DictationDictionary(defaults: defaults)
        let learned = (0..<DictationConfig.dictionaryMaxEntries).map { "Learned\($0)" }
        #expect(dictionary.learn(learned).count == DictationConfig.dictionaryMaxEntries)
        #expect(dictionary.learn(["Xyvora"]) == ["Xyvora"])
        #expect(dictionary.entries.count == DictationConfig.dictionaryMaxEntries)
        for index in 0..<DictationConfig.dictionaryMaxTypedWords { #expect(dictionary.add("Typed\(index)") == .added) }
        #expect(dictionary.add("Brevalle") == .full)
        #expect(dictionary.entries.count == DictationConfig.dictionaryMaxEntries)
        #expect(dictionary.entries.count(where: { !$0.learned }) == DictationConfig.dictionaryMaxTypedWords)
        #expect(dictionary.entries.count(where: \.learned) == DictationConfig.dictionaryMaxEntries - DictationConfig.dictionaryMaxTypedWords)
    }

    /// At the cap a learned word typed again would be one more typed word: refused, and it stays
    /// learned. A typed word typed again adds none: it takes the spelling typed.
    @Test func refusesALearnedWordTypedAgainAtTheTypedCap() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.learn(["Xyvora"])
        for index in 0..<DictationConfig.dictionaryMaxTypedWords { dictionary.add("Typed\(index)") }
        #expect(dictionary.add("XYVORA") == .full)
        #expect(dictionary.entries.first == .init(word: "Xyvora", learned: true, lastUsed: 1))
        #expect(dictionary.add("TYPED0") == .added)
        #expect(dictionary.entries.dropFirst().first == .init(word: "TYPED0", learned: false, lastUsed: DictationConfig.dictionaryMaxTypedWords + 2))
        dictionary.remove("Typed1")
        #expect(dictionary.add("xyvora") == .added)
        #expect(dictionary.entries.first == .init(word: "xyvora", learned: false, lastUsed: DictationConfig.dictionaryMaxTypedWords + 3))
    }

    // MARK: When full (owner, 2026-10-02): a new word, learned or typed (below the typed cap), takes
    // the place of the learned word used least recently (not the one learned first); a typed word is
    // never dropped.

    /// A dictionary of `typed` typed words, then learned ones, each used once, in order.
    private func full(typed: Int) -> DictationDictionary {
        let dictionary = DictationDictionary(defaults: defaults)
        for index in 0..<typed { dictionary.add("typed\(index)") }
        for index in typed..<DictationConfig.dictionaryMaxEntries { dictionary.learn(["learned\(index)"]) }
        #expect(dictionary.entries.count == DictationConfig.dictionaryMaxEntries)
        return dictionary
    }

    @Test func aLearnedWordTakesThePlaceOfTheLearnedWordUsedLeastRecently() {
        let dictionary = full(typed: 10)
        // The oldest learned word, used in a dictation since: the next oldest goes instead.
        dictionary.use(["she said learned10 twice"])
        #expect(dictionary.learn(["Xyvora"]) == ["Xyvora"])
        let words = dictionary.entries.map(\.word)
        #expect(words.count == DictationConfig.dictionaryMaxEntries)
        #expect(words.contains("learned10") && !words.contains("learned11"))
        #expect(words.last == "Xyvora")
        // Next goes the one after it; learned10 and Xyvora, used later, stay.
        dictionary.learn(["Kaelthorne Drake"])
        let after = dictionary.entries.map(\.word)
        #expect(!after.contains("learned12"))
        #expect(["learned10", "Xyvora", "Kaelthorne Drake"].allSatisfy(after.contains))
    }

    @Test func aWordLearnedAgainCountsAsUsed() {
        let dictionary = full(typed: 0)
        #expect(dictionary.learn(["LEARNED0"]) == [])
        // Learning nothing new still keeps the use across a launch.
        #expect(DictationDictionary(defaults: defaults).entries.first == .init(word: "learned0", learned: true, lastUsed: DictationConfig.dictionaryMaxEntries + 1))
        dictionary.learn(["Xyvora"])
        let words = dictionary.entries.map(\.word)
        #expect(words.contains("learned0") && !words.contains("learned1"))
    }

    @Test func aTypedWordTakesThePlaceOfTheLearnedWordUsedLeastRecently() {
        let dictionary = full(typed: 10)
        dictionary.use(["learned10"])
        #expect(dictionary.add("Xyvora") == .added)
        let words = dictionary.entries.map(\.word)
        #expect(words.count == DictationConfig.dictionaryMaxEntries)
        #expect(words.contains("learned10") && !words.contains("learned11"))
        #expect(dictionary.entries.last == .init(word: "Xyvora", learned: false, lastUsed: DictationConfig.dictionaryMaxEntries + 2))
    }

    /// At the typed cap a typed word is refused; learning goes on in the learned words' room, and
    /// however much is learned, no typed word is dropped.
    @Test func neverDropsATypedWord() {
        let dictionary = full(typed: DictationConfig.dictionaryMaxTypedWords)
        #expect(dictionary.add("Xyvora") == .full)
        let learned = (0..<DictationConfig.dictionaryMaxEntries).map { "later\($0)" }
        for word in learned { #expect(dictionary.learn([word]) == [word]) }
        let words = dictionary.entries.map(\.word)
        #expect(words.count == DictationConfig.dictionaryMaxEntries)
        #expect(Array(words.prefix(DictationConfig.dictionaryMaxTypedWords)) == (0..<DictationConfig.dictionaryMaxTypedWords).map { "typed\($0)" })
        #expect(Array(words.dropFirst(DictationConfig.dictionaryMaxTypedWords)) == Array(learned.suffix(DictationConfig.dictionaryMaxEntries - DictationConfig.dictionaryMaxTypedWords)))
    }

    /// A correction that respells a word already there and a new one: the word already there is
    /// used now, so the new one never drops it, whichever comes first in the correction.
    @Test(arguments: [true, false])
    func keepsAWordLearnedAgainInTheSameCorrection(newFirst: Bool) {
        // With the typed words at their cap: the learned word used least recently, then the next.
        let oldest = "learned\(DictationConfig.dictionaryMaxTypedWords)"
        let next = "learned\(DictationConfig.dictionaryMaxTypedWords + 1)"
        let dictionary = full(typed: DictationConfig.dictionaryMaxTypedWords)
        #expect(dictionary.learn(newFirst ? ["Xyvora", oldest] : [oldest, "Xyvora"]) == ["Xyvora"])
        let words = dictionary.entries.map(\.word)
        #expect(words.contains(oldest) && !words.contains(next))
        #expect(dictionary.entries.first { $0.word == oldest }?.lastUsed == DictationConfig.dictionaryMaxEntries + 1)
    }

    /// A typed word respelled in a correction counts as used, beside a new word learned.
    @Test func marksATypedWordUsedInTheSameCorrectionAsANewWord() {
        let dictionary = full(typed: DictationConfig.dictionaryMaxTypedWords)
        #expect(dictionary.learn(["Xyvora", "typed0"]) == ["Xyvora"])
        #expect(dictionary.entries.first == .init(word: "typed0", learned: false, lastUsed: DictationConfig.dictionaryMaxEntries + 1))
    }

    /// Words learned together don't push each other out: once every learned word there is one of
    /// them, the next is not learned.
    @Test func doesNotDropAWordLearnedInTheSameCorrection() {
        let dictionary = full(typed: DictationConfig.dictionaryMaxTypedWords)
        let room = DictationConfig.dictionaryMaxEntries - DictationConfig.dictionaryMaxTypedWords
        let correction = (0...room).map { "new\($0)" }
        #expect(dictionary.learn(correction) == Array(correction.prefix(room)))
        #expect(Array(dictionary.entries.map(\.word).dropFirst(DictationConfig.dictionaryMaxTypedWords)) == Array(correction.prefix(room)))
    }

    /// Of learned words never used since they were stored (`lastUsed` 0), the earliest goes first.
    @Test func dropsTheEarliestOfWordsUsedAsLongAgo() throws {
        let stored = (0..<DictationConfig.dictionaryMaxEntries).map { ["word": "word\($0)", "learned": true] as [String: Any] }
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: DictationDictionary.entriesKey)
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.learn(["Xyvora"])
        #expect(dictionary.entries.first?.word == "word1")
        #expect(dictionary.entries.last?.word == "Xyvora")
    }

    /// A dictation's text marks the words in it used, typed or learned, whatever their case, a word
    /// inside a longer one too (scripts without spaces have no word edge); only a change is written.
    @Test func marksTheWordsInADictationsTextUsed() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.add("TabMail")
        dictionary.learn(["탭메일"])
        dictionary.learn(["Xyvora"])
        dictionary.learn(["Brevalle"])
        dictionary.use(["send it with tabmail's", "탭메일로 보내 XYVORACORP"])
        #expect(dictionary.entries.map(\.lastUsed) == [5, 5, 5, 4])
        dictionary.use(["nothing here"])
        #expect(DictationDictionary(defaults: defaults).entries.map(\.lastUsed) == [5, 5, 5, 4])
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
    /// refuses, at most the limit. One stored before `lastUsed` was kept, or with an invalid one,
    /// reads as never used.
    @Test func readsBackOnlyValidEntries() throws {
        let stored: [[String: Any]] = [
            ["word": "Xyvora", "learned": false], ["word": "XYVORA", "learned": true], ["word": "Xy<vora", "learned": false],
            ["word": " Brevalle", "learned": false], ["word": "Brevalle", "learned": true, "lastUsed": 7],
            ["word": "Zivora", "learned": true, "lastUsed": -1], ["word": "Ostrava", "learned": true, "lastUsed": "7"],
            ["word": "Quill", "learned": true, "lastUsed": 1.5],
        ] + (0..<DictationConfig.dictionaryMaxEntries).map { ["word": "Word\($0)", "learned": false] }
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: DictationDictionary.entriesKey)

        let entries = DictationDictionary(defaults: defaults).entries
        #expect(entries.count == DictationConfig.dictionaryMaxEntries)
        #expect(Array(entries.prefix(6)) == [
            .init(word: "Xyvora", learned: false, lastUsed: 0), .init(word: "Brevalle", learned: true, lastUsed: 7),
            .init(word: "Zivora", learned: true, lastUsed: 0), .init(word: "Ostrava", learned: true, lastUsed: 0),
            .init(word: "Quill", learned: true, lastUsed: 0), .init(word: "Word0", learned: false, lastUsed: 0),
        ])

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
        let picked = DictationContextTerms.terms(in: "met \(raw) today", excluding: [], max: DictationConfig.vocabularyMaxTerms)
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
        for index in 1..<DictationConfig.dictionaryMaxTypedWords { dictionary.add("Word\(index)") }
        #expect(DictationDictionaryView.submit("Brevalle", to: dictionary) == ("Brevalle", DictationDictionaryView.fullMessage))
        #expect(DictationDictionaryView.fullMessage == "You can add up to 100 words. Remove one to add another.")
        #expect(dictionary.entries.count == DictationConfig.dictionaryMaxTypedWords)
    }

    /// Settings lists the typed words first, then the learned ones, each alphabetically whatever
    /// the case (owner, 2026-10-02), neither in the order added nor by last use.
    @Test func settingsListsTypedThenLearnedEachAlphabetically() {
        let dictionary = DictationDictionary(defaults: defaults)
        dictionary.learn(["TabMail"])
        dictionary.add("Xyvora")
        dictionary.learn(["Brevalle"])
        dictionary.add("Kaelthorne Drake")
        dictionary.learn(["ostrava"])
        dictionary.add("zivora")
        dictionary.add("Aldrin")
        dictionary.use(["zivora"])
        #expect(DictationDictionaryView.shown(dictionary.entries).map(\.word) == ["Aldrin", "Kaelthorne Drake", "Xyvora", "zivora", "Brevalle", "ostrava", "TabMail"])
    }

    /// Settings lists the rows as `shown` orders them, the order a swipe's offsets are read in.
    @Test func settingsListsTheRowsAsShown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Settings/DictationDictionaryView.swift"), encoding: .utf8)
        #expect(view.contains("ForEach(Self.shown(dictionary.entries), id: \\.word) { entry in"))
        #expect(view.contains(".onDelete { Self.remove(at: $0, from: dictionary) }"))
    }

    /// Settings: swiping rows away removes their words, and only those, as the rows are listed.
    @Test func settingsRemovesTheRowsSwipedAway() {
        let dictionary = DictationDictionary(defaults: defaults)
        ["Xyvora", "Brevalle", "Quill", "Kaelthorne"].forEach { dictionary.add($0) }
        dictionary.learn(["Aldrin"])
        // Listed: Brevalle, Kaelthorne, Quill, Xyvora, then Aldrin (learned).
        DictationDictionaryView.remove(at: IndexSet([1, 3, 4]), from: dictionary)
        #expect(dictionary.entries.map(\.word) == ["Brevalle", "Quill"])
    }
}
