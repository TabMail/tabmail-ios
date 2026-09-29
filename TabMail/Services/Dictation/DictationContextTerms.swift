/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Names and terms in what the dictation is about (ADR-IOS-086): sent with a dictation beside the
/// user's own dictionary, so the speech model spells them as they appear there. A dictionary built
/// on the fly from the context, picked on this device; only the words picked are sent. TabMail
/// Voice picks them from its screen read by the same rules (ADR-DESK-038).
enum DictationContextTerms {
    /// The terms in `text`: a word with a capital letter anywhere but at the start of a sentence (a
    /// name, "TabMail", "OKR"), runs of such words kept together ("Jordan Lee"), not everyday words,
    /// no addresses. The most frequent first, then the earliest; none the same word as one in
    /// `excluding` or another; each a valid dictionary word; at most `max`.
    static func terms(in text: String, excluding: [String], max: Int) -> [String] {
        var tallies: [String: (term: String, count: Int, first: Int)] = [:]
        func tally(_ term: String) {
            guard let word = DictationDictionary.word(term),
                  word.unicodeScalars.count >= DictationConfig.correctionMinWordLength else { return }
            let key = word.lowercased()
            if let existing = tallies[key] {
                tallies[key]?.count = existing.count + 1
            } else {
                tallies[key] = (word, 1, tallies.count)
            }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            var run: [String] = []
            func endRun() {
                // A longer run is a title or a heading, not a name: its words count one by one.
                if run.count <= DictationConfig.dictionaryWordMaxWords {
                    if !run.isEmpty { tally(run.joined(separator: " ")) }
                } else {
                    run.forEach(tally)
                }
                run = []
            }
            var sentenceStart = true
            for token in line.split(whereSeparator: \.isWhitespace) {
                let word = trimmed(token)
                if isTerm(word, raw: token, sentenceStart: sentenceStart) {
                    run.append(word)
                } else {
                    endRun()
                }
                // Punctuation after a word ends a run ("Jordan, Lee"); a full stop also ends the
                // sentence.
                if word.isEmpty || !token.hasSuffix(word) { endRun() }
                sentenceStart = word.isEmpty ? sentenceStart : endsSentence(token)
            }
            endRun()
        }
        let excluded = Set(excluding.map { $0.lowercased() })
        return tallies.values
            .filter { !excluded.contains($0.term.lowercased()) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(max)
            .map(\.term)
    }

    /// Whether a word is a name or term: a capital inside it, or a capital at its start where no
    /// sentence starts; not an everyday word; not an address.
    private static func isTerm(_ word: String, raw: Substring, sentenceStart: Bool) -> Bool {
        guard !word.isEmpty, !raw.contains("@"), !raw.contains("://") else { return false }
        let scalars = word.unicodeScalars
        let innerCapital = scalars.dropFirst().contains { $0.properties.generalCategory == .uppercaseLetter }
        if innerCapital { return true }
        guard !sentenceStart, let first = scalars.first, first.properties.generalCategory == .uppercaseLetter else { return false }
        return !DictationConfig.correctionCommonWords.contains(word.lowercased())
    }

    /// Whether the punctuation after a word ends its sentence (`Lee.` or `Lee?"`).
    private static func endsSentence(_ token: Substring) -> Bool {
        token.unicodeScalars.reversed().prefix { !isWordScalar($0) }.contains { ".!?".unicodeScalars.contains($0) }
    }

    /// The token without the punctuation around it.
    static func trimmed(_ token: Substring) -> String {
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
