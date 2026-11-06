/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The word list the screen terms are judged by (ADR-IOS-101): the lookup forms of the languages'
/// lists, the bisection over the sorted file, and the cases TabMail Voice runs against the same list.
struct WordListTests {
    private func list() throws -> WordList {
        try #require(WordList.bundled, "the word list is missing from the app")
    }

    /// The lookup cases TabMail Voice runs: names, made-up and everyday words, other scripts and
    /// forms (ß, a final sigma, Turkish's i, Serbian's Cyrillic, Chinese's Traditional, an abjad's
    /// vowel marks), hyphen and apostrophe words, a script no list is written in.
    @Test func theSharedLookupCasesHold() throws {
        let list = try list()
        for entry in try WordListCases.load().frequencies {
            guard entry.words.count == entry.zipf.count else {
                Issue.record("\(entry.name): words and answers differ in number")
                continue
            }
            for (word, expected) in zip(entry.words, entry.zipf) {
                #expect(list.seen(word) == expected, "\(entry.name): \(word) \(word.unicodeScalars.map { String($0.value, radix: 16) })")
            }
        }
    }

    /// A tiny list in a folder, to test the lookup mechanics without the real one's size.
    private func folder(words: [String], languages: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wordlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data((languages ?? #"{"letters": {}, "lists": {"en": {"dotless_i": false, "letters": null, "marks": false, "normal": "NFC", "under": null, "writings": [["Latn"]]}}}"#).utf8)
            .write(to: url.appendingPathComponent("languages.json"))
        try Data(words.joined().utf8).write(to: url.appendingPathComponent("words.txt"))
        return url
    }

    /// Every entry of a sorted file is found, and no word between, before or after them.
    @Test func theBisectionFindsEveryEntryAndNothingElse() throws {
        let entries = ["a", "ab", "abc", "b", "caf\u{E9}", "d", "dd", "e", "zz", "\u{1F600}x"].sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let url = try folder(words: entries.enumerated().map { "\($1)\t\(10 + $0)\n" })
        defer { try? FileManager.default.removeItem(at: url) }
        let list = try #require(WordList(folder: url))
        for (index, entry) in entries.enumerated() where entry.unicodeScalars.allSatisfy({ $0.isASCII || $0 == "\u{E9}" }) {
            #expect(list.seen(entry) == .tenths(10 + index), "\(entry)")
        }
        #expect(list.seen("") == .noList)
        for missing in ["aa", "abd", "bb", "c", "cafe", "ddd", "f", "zzz", "zy"] {
            #expect(list.seen(missing) == .tenths(0), "\(missing)")
        }
    }

    /// One entry, and a file whose last line has no newline, are searched without a mistake.
    @Test func aSingleEntryAndAMissingFinalNewline() throws {
        for words in [["abc\t42\n"], ["abc\t42"], ["abb\t10\n", "abc\t42"]] {
            let url = try folder(words: words)
            defer { try? FileManager.default.removeItem(at: url) }
            let list = try #require(WordList(folder: url))
            #expect(list.seen("abc") == .tenths(42), "\(words)")
            #expect(list.seen("abd") == .tenths(0))
            #expect(list.seen("aba") == .tenths(0))
        }
    }

    /// A word joined by hyphens or apostrophes is as often seen as its least seen part, when every
    /// part is listed.
    @Test func aJoinedWordIsAsOftenSeenAsItsLeastSeenPart() throws {
        let url = try folder(words: ["don\t62\n", "known\t51\n", "t\t30\n", "well\t54\n"])
        defer { try? FileManager.default.removeItem(at: url) }
        let list = try #require(WordList(folder: url))
        #expect(list.seen("well-known") == .tenths(51))
        #expect(list.seen("Well\u{2019}Known") == .tenths(51))
        #expect(list.seen("don't") == .tenths(30))
        #expect(list.seen("don\u{2019}t") == .tenths(30))
        #expect(list.seen("well-xyvora") == .tenths(0))
        #expect(list.seen("-well") == .tenths(0))
        #expect(list.seen("well--known") == .tenths(0))
    }

    /// A folder without either file, or whose languages are described wrongly, gives no list.
    @Test func aBrokenFolderGivesNoList() throws {
        #expect(WordList(folder: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")) == nil)
        for languages in [
            "not json", #"{"letters": {}, "lists": {}}"#,
            #"{"letters": {}, "lists": {"xx": {"dotless_i": false, "letters": null, "marks": false, "normal": "NFC", "under": null, "writings": [["Zzzz"]]}}}"#,
            #"{"letters": {}, "lists": {"xx": {"dotless_i": false, "letters": "nope", "marks": false, "normal": "NFC", "under": null, "writings": [["Latn"]]}}}"#,
            #"{"letters": {}, "lists": {"xx": {"dotless_i": false, "letters": null, "marks": false, "normal": "NFD", "under": null, "writings": [["Latn"]]}}}"#,
        ] {
            let url = try folder(words: ["a\t1\n"], languages: languages)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(WordList(folder: url) == nil, "\(languages)")
        }
        let empty = try folder(words: [])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(WordList(folder: empty) == nil)
    }

    /// A lookup stops when its task is cancelled, leaving the rest unanswered; one not cancelled
    /// answers every word.
    @Test func aCancelledLookupStopsAndAnUncancelledOneAnswersAll() async throws {
        let list = try list()
        let words = (0..<5_000).map { "xyvoraq\($0)" }
        let all = await list.seen(words)
        #expect(all.count == Set(words).count)
        let task = Task { () -> [String: WordSeen] in
            await Task.yield()
            return await list.seen(words)
        }
        task.cancel()
        let partial = await task.value
        #expect(partial.count < all.count)
    }

    /// The lookup runs on no actor and touches no UIKit, so it can never hold the main thread (the
    /// words are looked up from a detached task).
    @Test func theLookupIsFreeOfTheMainActorAndUIKit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/WordList.swift"), encoding: .utf8)
        for forbidden in ["import UIKit", "import SwiftUI", "@MainActor", "UITextChecker", "DispatchQueue.main"] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
        let terms = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/DictationContextTerms.swift"), encoding: .utf8)
        #expect(!terms.contains("@MainActor"))
    }
}
