/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// How often a word on screen is seen in the word list (`WordList`).
enum WordSeen: Equatable, Sendable {
    /// No list is written in the word's script (or it mixes scripts no language mixes in one word).
    case noList
    /// Zipf in tenths (`56` is once in about 2,500 words); 0 when no list written in its script
    /// has the word.
    case tenths(Int)
}

/// The word list the screen terms are judged by (ADR-IOS-101): 41 languages' lists from FrequencyWords'
/// counts merged into one, each word with the most often any of them sees it, in `Vendor/wordlist`
/// (the same files TabMail Voice ships). A word on screen is looked up in each form the lists
/// written in its script store their words in, and gets the most any of them sees it.
///
/// The list is a text file of `word<TAB>tenths` lines sorted by the word's UTF-8 bytes, read in
/// place (memory-mapped, so only the pages a search touches are read) and searched by bisection. No
/// UIKit and no main actor: a lookup runs on whatever task asks.
final class WordList: Sendable {
    /// The list the app ships; nil when its files are missing or unreadable, in which case no word
    /// has an answer and no term is picked.
    static let bundled: WordList? = Bundle.main.url(forResource: "wordlist", withExtension: nil).flatMap { WordList(folder: $0) }

    /// How a word is put in the form a list has its words in (`languages.json`): wordfreq's
    /// `preprocess_text` for the list's language (the code the list was generated with).
    private struct Form: Hashable {
        /// NFKC rather than NFC.
        var compatibility: Bool
        /// The name of the table each letter is replaced through (Serbian's Cyrillic to Latin,
        /// Chinese's Traditional to Simplified), if any.
        var letters: String?
        /// Marks (abjad vowel points) and the Arabic tatweel removed.
        var marks: Bool
        /// Turkish's dotted and dotless i.
        var dotlessI: Bool
        /// The s and t below which a cedilla becomes a comma (Romanian) or a comma a cedilla
        /// (Turkish), if either.
        var under: Under?
    }

    private enum Under: String, Hashable {
        case commas, cedillas
    }

    /// A language's list: the scripts one of its writings mixes (Japanese's Han and kana; Serbo-Croatian's
    /// Latin, or its Cyrillic) and its words' form.
    private struct List {
        var writings: [Set<Int32>]
        var form: Form
    }

    private let lists: [List]
    private let tables: [String: [Unicode.Scalar: String]]
    private let words: Data

    /// The ICU script codes (`UScriptCode`) a word's letters are told apart by: Common ("-", digits,
    /// "ー") and Inherited (a combining mark) go with whatever script surrounds them, Unknown is an
    /// unassigned character.
    private static let commonScript: Int32 = 0, inheritedScript: Int32 = 1, unknownScript: Int32 = 103

    /// A letter of each script a list is written in, to read its ICU script code from (ISO 15924).
    private static let scriptLetters: [String: Unicode.Scalar] = [
        "Arab": "\u{0627}", "Beng": "\u{0995}", "Cyrl": "\u{0430}", "Deva": "\u{0915}", "Grek": "\u{03B1}",
        "Hang": "\u{D55C}", "Hani": "\u{4E00}", "Hebr": "\u{05D0}", "Hira": "\u{3042}", "Kana": "\u{30AB}",
        "Latn": "a", "Taml": "\u{0BA4}",
    ]

    /// The characters that join the parts of a word ("что-то", "don't", Catalan's "col·legi" with its
    /// middle dot, Persian's zero-width non-joiner); a word none of the lists has is as often seen as
    /// its least seen part when every part is in one list.
    private static let joiners: Set<Unicode.Scalar> = ["-", "'", "\u{2019}", "\u{02BC}", "\u{00B7}", "\u{200C}", "\u{200D}"]

    /// The list in `folder` (`languages.json`, `words.txt`); nil when either can't be read.
    init?(folder: URL) {
        guard let described = try? Data(contentsOf: folder.appendingPathComponent("languages.json")),
              let root = (try? JSONSerialization.jsonObject(with: described)) as? [String: Any],
              let letterTables = root["letters"] as? [String: [String: String]],
              let languages = root["lists"] as? [String: [String: Any]],
              let words = try? Data(contentsOf: folder.appendingPathComponent("words.txt"), options: .alwaysMapped)
        else { return nil }
        var tables: [String: [Unicode.Scalar: String]] = [:]
        for (name, letters) in letterTables {
            var replaced: [Unicode.Scalar: String] = [:]
            for (letter, by) in letters {
                let scalars = Array(letter.unicodeScalars)
                guard scalars.count == 1 else { return nil }
                replaced[scalars[0]] = by
            }
            tables[name] = replaced
        }
        var lists: [List] = []
        for language in languages.values {
            guard let writings = language["writings"] as? [[String]], !writings.isEmpty,
                  let normal = language["normal"] as? String, normal == "NFC" || normal == "NFKC",
                  let marks = language["marks"] as? Bool, let dotlessI = language["dotless_i"] as? Bool
            else { return nil }
            var scripts: [Set<Int32>] = []
            for writing in writings {
                let codes = writing.map { Self.scriptLetters[$0].map(Self.script(of:)) }
                guard !codes.isEmpty, !codes.contains(where: { $0 == nil }) else { return nil }
                scripts.append(Set(codes.compactMap { $0 }))
            }
            var letters: String?
            if let table = language["letters"] as? String {
                guard tables[table] != nil else { return nil }
                letters = table
            }
            var under: Under?
            if let name = language["under"] as? String {
                guard let parsed = Under(rawValue: name) else { return nil }
                under = parsed
            }
            lists.append(List(
                writings: scripts,
                form: Form(compatibility: normal == "NFKC", letters: letters, marks: marks, dotlessI: dotlessI, under: under)))
        }
        guard !lists.isEmpty, !words.isEmpty else { return nil }
        self.lists = lists
        self.tables = tables
        self.words = words
    }

    /// How often each of `words` is seen, keyed by the word as asked. Stops when the task is
    /// cancelled, leaving the rest unanswered (an unanswered word is never a term), and gives the
    /// thread back every `DictationConfig.wordListYieldWords` words.
    func seen(_ words: [String]) async -> [String: WordSeen] {
        var answers: [String: WordSeen] = [:]
        for (index, word) in words.enumerated() {
            if index > 0, index % DictationConfig.wordListYieldWords == 0 { await Task.yield() }
            if Task.isCancelled { break }
            answers[word] = seen(word)
        }
        return answers
    }

    /// How often one word is seen: the most any form a list written in its script gives it is seen,
    /// or `.noList` when no list is written in its script.
    func seen(_ word: String) -> WordSeen {
        let scripts = Set(word.unicodeScalars.map(Self.script(of:))).subtracting([Self.commonScript, Self.inheritedScript, Self.unknownScript])
        guard !scripts.isEmpty else { return .noList }
        var forms: Set<Form> = []
        for list in lists where list.writings.contains(where: { scripts.isSubset(of: $0) }) { forms.insert(list.form) }
        guard !forms.isEmpty else { return .noList }
        let listed = Set(forms.map { listedForm(of: word, in: $0) })
        return .tenths(listed.map(tenths(ofListed:)).max() ?? 0)
    }

    private static func script(of scalar: Unicode.Scalar) -> Int32 {
        u_getIntPropertyValue(Int32(bitPattern: scalar.value), UCHAR_SCRIPT)
    }

    // MARK: - The form a word is listed under

    /// The form a word is listed under in a list, in wordfreq's order: the list's normal form; its
    /// letters replaced through its table ("Већ" is "Već", "電腦" is "电脑"); its marks removed where
    /// the list's language drops them; case-folded as wordfreq does, not just lowercased ("Straße" is
    /// "strasse", a final sigma σ, the ligature "ﬁ" of PDF text "fi"; Turkish's dotted and dotless i
    /// in its own); s and t with the mark below the language writes ("şi" is "și" in Romanian); then
    /// NFC, the apostrophe straight.
    private func listedForm(of word: String, in form: Form) -> String {
        var scalars = Array((form.compatibility ? word.precomposedStringWithCompatibilityMapping : word.precomposedStringWithCanonicalMapping).unicodeScalars)
        if let name = form.letters, let table = tables[name] {
            var replaced = String.UnicodeScalarView()
            for scalar in scalars {
                if let by = table[scalar] { replaced.append(contentsOf: by.unicodeScalars) } else { replaced.append(scalar) }
            }
            scalars = Array(replaced)
        }
        if form.marks {
            scalars.removeAll { $0.value == 0x640 || Self.isMark($0) }
        }
        if form.dotlessI {
            scalars = scalars.flatMap { scalar -> [Unicode.Scalar] in
                switch scalar {
                case "I": ["\u{0131}"]
                case "\u{0130}": ["i"]
                default: [scalar]
                }
            }
        }
        var folded = Self.caseFolded(String(String.UnicodeScalarView(scalars)))
        folded = folded.replacingOccurrences(of: "i\u{0307}", with: "i")
        var listed = String.UnicodeScalarView()
        for scalar in folded.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch (scalar, form.under) {
            case ("\u{2019}", _), ("\u{02BC}", _): listed.append("'")
            case ("\u{015F}", .commas?): listed.append("\u{0219}")
            case ("\u{0163}", .commas?): listed.append("\u{021B}")
            case ("\u{0219}", .cedillas?): listed.append("\u{015F}")
            case ("\u{021B}", .cedillas?): listed.append("\u{0163}")
            default: listed.append(scalar)
            }
        }
        return String(listed)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// Unicode's full case folding (CaseFolding.txt, statuses C and F), not locale-dependent.
    private static func caseFolded(_ text: String) -> String {
        let source = Array(text.utf16)
        // Folding lengthens a string by at most three times.
        var folded = [UInt16](repeating: 0, count: source.count * 3 + 8)
        var status = U_ZERO_ERROR
        let length = u_strFoldCase(&folded, Int32(folded.count), source, Int32(source.count), 0, &status)
        // Cannot fail with this capacity; the word would then simply not be found.
        guard status.rawValue <= U_ZERO_ERROR.rawValue, length >= 0 else { return text }
        return String(decoding: folded[0..<Int(length)], as: UTF16.self)
    }

    // MARK: - The sorted file

    /// How often a word in a listed form is seen: its own entry, else its least seen part when every
    /// part joined by a hyphen or an apostrophe has one; 0 when neither.
    private func tenths(ofListed form: String) -> Int {
        if let tenths = entry(form) { return tenths }
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in form.unicodeScalars {
            if Self.joiners.contains(scalar) {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        parts.append(String(current))
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return 0 }
        return parts.map { entry($0) ?? 0 }.min() ?? 0
    }

    /// The Zipf in tenths of `word` as the file lists it; nil when it isn't there. A bisection over
    /// the file's lines: `low` is always the start of a line, `high` the start of one or the end.
    private func entry(_ word: String) -> Int? {
        let target = Array(word.utf8)
        return words.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var low = 0, high = bytes.count
            while low < high {
                let middle = low + (high - low) / 2
                var start = middle
                while start > low, bytes[start - 1] != 0x0A { start -= 1 }
                var tab = start
                while tab < bytes.count, bytes[tab] != 0x09, bytes[tab] != 0x0A { tab += 1 }
                var end = tab
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                guard tab < end, bytes[tab] == 0x09 else { return nil }
                switch Self.compare(bytes[start..<tab], target) {
                case 0:
                    var tenths = 0
                    for byte in bytes[(tab + 1)..<end] {
                        guard byte >= 0x30, byte <= 0x39 else { return nil }
                        tenths = tenths * 10 + Int(byte - 0x30)
                    }
                    return tenths
                case ..<0: low = end + 1
                default: high = start
                }
            }
            return nil
        }
    }

    /// Bytewise, as the file is sorted: negative when `line` sorts before `target`.
    private static func compare(_ line: Slice<UnsafeBufferPointer<UInt8>>, _ target: [UInt8]) -> Int {
        var index = 0
        for byte in line {
            if index == target.count { return 1 }
            if byte != target[index] { return byte < target[index] ? -1 : 1 }
            index += 1
        }
        return index == target.count ? 0 : -1
    }
}
