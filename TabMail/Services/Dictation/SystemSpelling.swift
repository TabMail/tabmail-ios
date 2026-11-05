/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit

/// The system's spelling dictionaries (`UITextChecker`) as the screen-term rule reads them
/// (ADR-IOS-101): which of a set of words none of the user's preferred languages knows.
///
/// `UITextChecker` is main-actor isolated, so the one batch of words goes over in one hop, worked
/// through in slices of `DictationConfig.spellingSliceWords` with a yield between them (a flagged
/// word costs about 0.15 to 0.3 ms, so 1,500 names would hold the main thread for a quarter to half a second), and
/// dropped when the task is cancelled. It calls every word of a language it cannot check correct (Korean, Japanese, Chinese, and many languages
/// it lists as available), so a language counts only if its dictionary flags a made-up word
/// (`DictationConfig.spellingProbeWord`); the others are left out.
enum SystemSpelling {
    /// Whether `language`'s dictionary knows `word`.
    typealias IsKnown = @MainActor (_ word: String, _ language: String) -> Bool

    /// The words of `words` that every working dictionary among `preferredLanguages` flags as
    /// misspelled; nil when none of them has a working dictionary.
    @MainActor
    static func unknownWords(among words: Set<String>, preferredLanguages: [String]) async -> Set<String>? {
        let checker = UITextChecker()
        return await unknownWords(among: words, preferredLanguages: preferredLanguages) { word, language in
            checker.rangeOfMisspelledWord(
                in: word, range: NSRange(location: 0, length: (word as NSString).length),
                startingAt: 0, wrap: false, language: language
            ).location == NSNotFound
        }
    }

    @MainActor
    static func unknownWords(among words: Set<String>, preferredLanguages: [String], isKnown: IsKnown) async -> Set<String>? {
        var seen: Set<String> = []
        let working = preferredLanguages.filter { seen.insert($0).inserted && !isKnown(DictationConfig.spellingProbeWord, $0) }
        guard !working.isEmpty else { return nil }
        var unknown: Set<String> = []
        for (index, word) in words.enumerated() {
            if index > 0, index % DictationConfig.spellingSliceWords == 0 {
                await Task.yield()
                if Task.isCancelled { break }
            }
            if working.allSatisfy({ !isKnown(word, $0) }) { unknown.insert(word) }
        }
        return unknown
    }
}
