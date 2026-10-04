/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A long dictation's text, from its chunks' texts in order (ADR-IOS-087; TabMail Voice's
/// `joinChunkTexts`, ADR-DESK-048, rule for rule).
///
/// - An ellipsis where two chunks meet is taken out (owner, 2026-10-03): it is the pause the cut fell
///   in, not the speaker's. One inside a chunk stays.
/// - Chunks cut at a pause are joined with a space, or none between scripts written without spaces.
/// - A chunk that starts inside the one before it (no pause to cut at) holds the same speech as the
///   end of that one: the two are joined where their words first run together for at least
///   `chunkOverlapMinimumRun` words, the run kept once: its first word as the earlier chunk wrote
///   it, mid-sentence, since a chunk's first word comes capitalised as the start of its text (owner,
///   2026-10-03: "capitalization mid breaks"), the rest as the later one did. With no such run they are joined whole
///   (owner, 2026-10-03: "better than losing things"): a few words may repeat, none are lost.
/// - An empty chunk adds nothing, and the chunk after it is joined whole: it overlaps only the empty
///   one, so matching it against an earlier chunk's words would cut out the speech between them.
///   Nothing else is changed: no capital is lowered, no punctuation added.
enum DictationChunkJoin {
    /// One chunk's text, and whether its audio started inside the chunk before it
    /// (`DictationChunkCut.overlapped`).
    struct Part: Sendable, Equatable {
        let text: String
        let overlapped: Bool
    }

    static func join(_ parts: [Part]) -> String {
        var joined = ""
        var previousHeard = false
        for part in parts {
            var text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { text = text.replacing(leadingEllipsis, with: "") }
            let overlapsJoined = part.overlapped && previousHeard
            previousHeard = !text.isEmpty
            if text.isEmpty { continue }
            if joined.isEmpty {
                joined = text
                continue
            }
            joined = joined.replacing(trailingEllipsis, with: "")
            joined = overlapsJoined ? joinOverlapping(joined, text) : joinedWith(joined, text)
        }
        return joined
    }

    /// An ellipsis at the end or the start of a text: a model may write the pause a chunk was cut at
    /// as one.
    private nonisolated(unsafe) static let trailingEllipsis = #/(?:\s*(?:\.{3}|…))+\s*$/#
    private nonisolated(unsafe) static let leadingEllipsis = #/^\s*(?:(?:\.{3}|…)\s*)+/#

    /// Scripts written without spaces between words: no space is added where one meets another chunk.
    private static let unspacedScript: NSRegularExpression = {
        // Built once from a constant pattern; it cannot fail.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "[\\p{Script=Han}\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Thai}\\p{Script=Lao}\\p{Script=Khmer}\\p{Script=Myanmar}]")
    }()

    /// `left` and `right` with a space between, or none where either side is a script without spaces.
    private static func joinedWith(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        let last = left.unicodeScalars.last.map { String($0) } ?? ""
        let first = right.unicodeScalars.first.map { String($0) } ?? ""
        return isUnspaced(last) || isUnspaced(first) ? left + right : left + " " + right
    }

    private static func isUnspaced(_ character: String) -> Bool {
        unspacedScript.firstMatch(in: character, range: NSRange(character.startIndex..., in: character)) != nil
    }

    /// `left` and `right`, which both hold the speech around a cut, joined on the longest run of words
    /// the end of one and the start of the other share: `left` up to the run's first word, `right`
    /// from its second. Each side is cut at a word's place in its own text, so its line breaks and
    /// spacing stay as they were.
    private static func joinOverlapping(_ left: String, _ right: String) -> String {
        let leftWords = left.ranges(of: /\S+/)
        let rightWords = Array(right.ranges(of: /\S+/).prefix(DictationConfig.chunkOverlapSearchWords))
        let leftFrom = max(0, leftWords.count - DictationConfig.chunkOverlapSearchWords)
        let leftKeys = leftWords[leftFrom...].map { matchKey(left[$0]) }
        let rightKeys = rightWords.map { matchKey(right[$0]) }
        guard let run = longestRun(leftKeys, rightKeys), run.length >= DictationConfig.chunkOverlapMinimumRun else {
            BackgroundSyncLogger.logDebug("[Dictation] no shared words where two chunks overlap; joined whole")
            return joinedWith(left, right)
        }
        BackgroundSyncLogger.logDebug("[Dictation] overlapping chunks joined on a run of \(run.length) words")
        // A run holds at least `chunkOverlapMinimumRun` (more than one) words, so both have a second word.
        let leftNext = leftFrom + run.left + 1
        let leftEnd = leftNext < leftWords.count ? leftWords[leftNext].lowerBound : left.endIndex
        let rightStart = run.right + 1 < rightWords.count ? rightWords[run.right + 1].lowerBound : right.endIndex
        return joinedWith(String(left[..<leftEnd]).trimmingCharacters(in: .whitespacesAndNewlines), String(right[rightStart...]))
    }

    /// A word as the two chunks' texts are compared: lower case, letters and digits only, so the
    /// punctuation and capitals a cut changes around it don't count.
    private static func matchKey(_ word: Substring) -> String {
        var key = String.UnicodeScalarView()
        for scalar in word.lowercased().unicodeScalars where isLetterOrNumber(scalar) {
            key.append(scalar)
        }
        return String(key)
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// The longest run of words, none empty, that `left` and `right` share: where it starts in each.
    private static func longestRun(_ left: [String], _ right: [String]) -> (left: Int, right: Int, length: Int)? {
        var best: (left: Int, right: Int, length: Int)?
        var previous = [Int](repeating: 0, count: right.count + 1)
        for i in stride(from: 1, through: left.count, by: 1) {
            var current = [Int](repeating: 0, count: right.count + 1)
            let key = left[i - 1]
            for j in stride(from: 1, through: right.count, by: 1) where !key.isEmpty && key == right[j - 1] {
                let length = previous[j - 1] + 1
                current[j] = length
                if length > (best?.length ?? 0) { best = (i - length, j - length, length) }
            }
            previous = current
        }
        return best
    }
}
