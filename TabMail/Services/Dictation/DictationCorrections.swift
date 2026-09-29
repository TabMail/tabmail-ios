/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The words to learn from the user's edit of a dictation (ADR-IOS-086), TabMail Voice's
/// `learnedCorrections` (ADR-DESK-038) with the same rules: the input field's text `before` the
/// edit, holding the `pasted` dictation, and `after` it. Only a respelling within the dictation
/// counts: "Zivora" corrected to "Xyvora", "tab mail" to "TabMail". Nothing is learned from an edit
/// that reaches outside the dictation, a rewrite of more than `correctionMaxChangedShare` of its
/// words, a replacement by a different word (`correctionMaxEditShare`), another form of a lowercase
/// word (`correctionMinStemShare`), a short or everyday word, or a change of case alone at a word's
/// start.
///
/// The approach is OpenWhispr's `correctionLearner` (MIT, https://github.com/OpenWhispr/openwhispr):
/// a word-level longest common subsequence between the dictation and what the user kept, and its
/// limits for a rewrite (half the words), a replaced word (an edit distance of 0.65 of its length)
/// and a short word (3 characters). This is our own implementation, not its code.
enum DictationCorrections {
    static func learned(pasted: String, before: String, after: String) -> [String] {
        guard let edited = editedPaste(Array(pasted), before: Array(before), after: Array(after)) else { return [] }
        let heardWords = words(pasted)
        let runs = changedRuns(heardWords, words(String(edited)))
        let changed = runs.reduce(0) { $0 + $1.heard.count }
        guard Double(changed) <= Double(heardWords.count) * DictationConfig.correctionMaxChangedShare else { return [] }
        var learned: [String] = []
        for run in runs {
            guard let word = respelling(heard: run.heard, corrected: run.corrected),
                  !learned.contains(where: { DictationDictionary.isSameWord($0, word) }) else { continue }
            learned.append(word)
        }
        return learned
    }

    /// `pasted` with the edit from `before` to `after` applied, or nil when there is no edit or it
    /// is not all within one place `pasted` is in `before`.
    private static func editedPaste(_ pasted: [Character], before: [Character], after: [Character]) -> [Character]? {
        guard !pasted.isEmpty, before != after else { return nil }
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let changeEnd = before.count - suffix
        var start = 0
        while start + pasted.count <= before.count {
            if start <= prefix, changeEnd <= start + pasted.count, before[start..<start + pasted.count].elementsEqual(pasted) {
                return Array(pasted[..<(prefix - start)]) + after[prefix..<(after.count - suffix)] + pasted[(changeEnd - start)...]
            }
            start += 1
        }
        return nil
    }

    /// The text's words, without the punctuation around them.
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(DictationContextTerms.trimmed).filter { !$0.isEmpty }
    }

    private struct ChangedRun {
        var heard: [String] = []
        var corrected: [String] = []
    }

    /// Where `corrected` differs from `heard`: the runs of words between those both keep (a longest
    /// common subsequence). A change of case is a change: "tabmail" → "TabMail" is a respelling.
    private static func changedRuns(_ heard: [String], _ corrected: [String]) -> [ChangedRun] {
        let (a, b) = (heard, corrected)
        // kept[i][j]: the most words a[i…] and b[j…] have in common, in order.
        var kept = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                kept[i][j] = a[i] == b[j] ? kept[i + 1][j + 1] + 1 : max(kept[i + 1][j], kept[i][j + 1])
            }
        }
        var runs: [ChangedRun] = []
        var run = ChangedRun()
        func close() {
            if !run.heard.isEmpty || !run.corrected.isEmpty { runs.append(run) }
            run = ChangedRun()
        }
        var (i, j) = (0, 0)
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                close()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || kept[i][j + 1] >= kept[i + 1][j] {
                run.corrected.append(b[j])
                j += 1
            } else {
                run.heard.append(a[i])
                i += 1
            }
        }
        close()
        return runs
    }

    /// The corrected words, when they respell the heard ones rather than replace them; else nil.
    private static func respelling(heard: [String], corrected: [String]) -> String? {
        guard !heard.isEmpty, !corrected.isEmpty,
              let word = DictationDictionary.word(corrected.joined(separator: " ")),
              word.unicodeScalars.count >= DictationConfig.correctionMinWordLength else { return nil }
        if corrected.count == 1, DictationConfig.correctionCommonWords.contains(word.lowercased()) { return nil }
        let from = Array(heard.joined().lowercased().unicodeScalars)
        let to = Array(corrected.joined().lowercased().unicodeScalars)
        if from == to {
            // Only the case or the spacing changed: learned when the spacing did ("tab mail" →
            // "TabMail"), or a capital went inside a word ("tabmail" → "TabMail"), not a capital at
            // a word's start alone.
            let isInnerCapital = corrected.contains { part in
                part.unicodeScalars.dropFirst().contains { $0.properties.generalCategory == .uppercaseLetter }
            }
            return heard.count != corrected.count || isInnerCapital ? word : nil
        }
        // A lowercase word changed at its end alone is the same word in another form ("report" →
        // "reports", "send" → "sent", "review" → "revise"), not a name or term respelled; a capital
        // marks a name ("Steven" → "Stephen"), and a script without case has no lowercase to go by.
        let stem = zip(from, to).prefix { $0 == $1 }.count
        let scalars = word.unicodeScalars
        if Double(stem) >= Double(min(from.count, to.count)) * DictationConfig.correctionMinStemShare,
           scalars.contains(where: { $0.properties.generalCategory == .lowercaseLetter }),
           !scalars.contains(where: { $0.properties.generalCategory == .uppercaseLetter }) { return nil }
        return Double(editDistance(from, to)) <= Double(max(from.count, to.count)) * DictationConfig.correctionMaxEditShare ? word : nil
    }

    /// The fewest single-character insertions, deletions and substitutions that turn `a` into `b`.
    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var current = [i]
            for j in 1...max(b.count, 1) where j <= b.count {
                current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
