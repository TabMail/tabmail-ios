/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Names and terms in what the dictation is about (ADR-IOS-086): sent with a dictation beside the
/// user's own dictionary, so the speech model spells them as they appear there. A dictionary built
/// on the fly from the context, picked on this device; only the words picked are sent. TabMail
/// Voice picks them by the same rule (ADR-DESK-038, `contextTerms.ts`).
enum DictationContextTerms {
    /// The words in `text` that `terms` asks `WordList` about, each once as written: every word,
    /// split on whitespace with the punctuation around it trimmed, that has a letter, no digit, is no
    /// part of an address, and is no longer than a dictionary word (a longer one is never a term, so
    /// it isn't asked about).
    static func candidates(in text: String) -> [String] {
        var seen: Set<String> = []
        var candidates: [String] = []
        for token in tokens(of: text) {
            let word = trimmed(token)
            if isCandidate(word, raw: token), seen.insert(word).inserted { candidates.append(word) }
        }
        return candidates
    }

    /// The terms in `text`: the candidates the word list sees less often than `cutoff` (Zipf in
    /// tenths), or, in a script no list is written in, with a capital letter. Each word stands alone.
    /// The rarest first (a word no list has, or in a script without a list, counts as 0), then the
    /// most often on screen, then the earliest; none the same word as one in `excluding` or another,
    /// the case aside; each a valid dictionary word; at most `max`. A word `frequencies` has no
    /// answer for is no term.
    static func terms(
        in text: String, frequencies: [String: WordSeen], excluding: [String], max: Int,
        cutoff: Int = DictationConfig.screenTermCommonZipf
    ) -> [String] {
        var tallies: [String: (term: String, zipf: Int, count: Int, first: Int)] = [:]
        for token in tokens(of: text) {
            let word = trimmed(token)
            guard isCandidate(word, raw: token), let seen = frequencies[word] else { continue }
            let zipf: Int
            switch seen {
            case .noList:
                guard hasCapital(word) else { continue }
                zipf = 0
            case .tenths(let tenths):
                guard tenths < cutoff else { continue }
                zipf = tenths
            }
            guard let term = DictationDictionary.word(word),
                  term.unicodeScalars.count >= DictationConfig.correctionMinWordLength else { continue }
            let key = term.lowercased()
            if let existing = tallies[key] {
                tallies[key]?.count = existing.count + 1
            } else {
                tallies[key] = (term, zipf, 1, tallies.count)
            }
        }
        let excluded = Set(excluding.map { $0.lowercased() })
        return tallies.values
            .filter { !excluded.contains($0.term.lowercased()) }
            .sorted { $0.zipf != $1.zipf ? $0.zipf < $1.zipf : $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(max)
            .map(\.term)
    }

    /// The text split on whitespace (as JavaScript's `\s` and the next-line character split it).
    private static func tokens(of text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: isSpace).map { String(String.UnicodeScalarView($0)) }
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.value == 0xFEFF
    }

    /// Whether a word is asked about: a letter in it, no digit, not part of an address (`raw` is the
    /// token it came from), not longer than a dictionary word.
    private static func isCandidate(_ word: String, raw: String) -> Bool {
        guard word.utf16.count <= DictationConfig.dictionaryWordMaxChars, !isAddress(raw) else { return false }
        var hasLetter = false
        for scalar in word.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber: return false
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: hasLetter = true
            default: break
            }
        }
        return hasLetter
    }

    /// Whether a token holds "@" or "://", compared scalar by scalar.
    private static func isAddress(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        if scalars.contains("@") { return true }
        return scalars.indices.dropLast(2).contains { scalars[$0] == ":" && scalars[$0 + 1] == "/" && scalars[$0 + 2] == "/" }
    }

    /// Whether a word has an uppercase or titlecase letter.
    private static func hasCapital(_ word: String) -> Bool {
        word.unicodeScalars.contains { $0.properties.generalCategory == .uppercaseLetter || $0.properties.generalCategory == .titlecaseLetter }
    }

    /// The token without the punctuation around it.
    static func trimmed(_ token: String) -> String {
        let scalars = Array(token.unicodeScalars)
        guard let first = scalars.firstIndex(where: isWordScalar),
              let last = scalars.lastIndex(where: isWordScalar) else { return "" }
        var word = String.UnicodeScalarView()
        word.append(contentsOf: scalars[first...last])
        return String(word)
    }

    /// A letter, a number or a mark: what a word is made of.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}
