/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// FTS5 query builder, ported from tabmail-native-fts `fts::query::build_fts_match` (ADR-NF-011,
// native-fts #14 and #31). Thunderbird is the reference (ADR-IOS-008): keep the two in step.
// Text is read as Unicode scalars throughout, as Rust reads chars, and lengths are UTF-8 bytes.

enum SearchQueryParser {

    /// Fields a mail search may scope to (`from:alice`): typed name → shard column, as
    /// native-fts `QUERY_COLUMNS`. Each column is in `SearchIndex.columnScopePrefixes`, so a
    /// scoped hybrid search filters its vector candidates.
    private static let queryColumns: [(typed: String, column: String)] = [
        ("subject", "subject"),
        ("from", "from_"),
        ("from_", "from_"),
        ("to", "to_"),
        ("to_", "to_"),
        ("cc", "cc"),
        ("bcc", "bcc"),
        ("body", "body"),
    ]

    /// Builds the FTS5 MATCH expression for a search query a user typed or a model wrote.
    ///
    /// Every word and every `"quoted phrase"` reaches FTS5 as a string, so nothing typed breaks the
    /// query: parentheses and punctuation are searched as text, and non-ASCII text is kept whole.
    /// A capital AND, OR or NOT between two terms stays the operator; anywhere else it is dropped.
    /// At most `SearchConfig.searchMaxKeptNots` NOTs are kept, and a later exclusion is left out
    /// (FTS5 nests each NOT and refuses an expression deeper than 256).
    /// A word whose only punctuation is an inner apostrophe searches both spellings (`don't`, `dont`).
    /// `name:word`, `name:"phrase"` and `name: word` scope to a column only when `queryColumns`
    /// names it (typed name, ASCII case-insensitive → table column); any other `x:` is text.
    static func buildFTSMatch(_ query: String?) -> String {
        guard let query else { return "" }
        let items = scan(query)

        // A word with synonyms becomes an OR group, and so does a word with an inner apostrophe (its
        // two spellings); FTS5 then needs an explicit AND between all terms. No word in the same run
        // of words (between quoted phrases) as a synonym group gets an automatic prefix star; a
        // spelling group leaves its neighbours' stars alone. Which runs have a synonym group is read
        // from the terms written, so it can't disagree with how they were written.
        // A capital AND, OR or NOT standing between two terms stays the FTS5 operator
        // (`from:"a@example.com" OR to:"a@example.com"`); anywhere else (first, last, after another
        // operator) it is dropped.
        let render = { (groupedRuns: [Bool]) -> [Term] in
            var out: [Term] = []
            var pendingOperator: String?
            var run = 0
            var keptNots = 0
            var i = 0
            while i < items.count {
                let item = items[i]
                i += 1
                if case .word(let w) = item, let op = operators.first(where: { $0 == w }) {
                    if pendingOperator == nil {
                        pendingOperator = op
                    }
                    continue
                }
                // A synonym group in this run of words; a spelling group does not count.
                let hasOrGroups = run < groupedRuns.count && groupedRuns[run]
                let term: (text: String, synonymGroup: Bool)?
                switch item {
                case .phrase(let p):
                    run += 1
                    term = phrase(p).map { ($0, false) }
                case .word(let w):
                    if let (column, value) = scopedColumn(w) {
                        if value.isEmpty {
                            // name:"phrase" and name: word take the next item as the value.
                            let next = i < items.count ? items[i] : nil
                            i += 1
                            switch next {
                            case .phrase(let p)?:
                                term = phrase(p).map { ("\(column):\($0)", false) }
                            case .word(let v)?:
                                term = word(v, useSynonyms: false, spellings: false, hasOrGroups: hasOrGroups)
                                    .map { ("\(column):\($0.text)", false) }
                            case nil:
                                term = nil
                            }
                        } else {
                            // A field's value is searched as typed: no synonyms, no second spelling.
                            term = word(value, useSynonyms: false, spellings: false, hasOrGroups: hasOrGroups)
                                .map { ("\(column):\($0.text)", false) }
                        }
                    } else {
                        // A kept NOT excludes the word typed: its synonyms would exclude the left
                        // side's too (`invoice NOT receipt` would find nothing). Both spellings are
                        // the word typed, so `NOT don't` excludes "Dont" too.
                        let excluded = pendingOperator == "NOT" && !out.isEmpty
                        term = word(w, useSynonyms: !excluded, spellings: true, hasOrGroups: hasOrGroups)
                    }
                }
                guard let term else { continue }
                let op = pendingOperator
                pendingOperator = nil
                if op == "NOT" && !out.isEmpty {
                    // Past the cap, an exclusion is left out: the query still answers.
                    if keptNots == SearchConfig.searchMaxKeptNots {
                        continue
                    }
                    keptNots += 1
                }
                out.append(Term(op: op, text: term.text, run: run, synonymGroup: term.synonymGroup))
            }
            return out
        }

        let terms = render([])
        var groupedRuns = [Bool](repeating: false, count: terms.last.map { $0.run + 1 } ?? 0)
        for t in terms where t.synonymGroup {
            groupedRuns[t.run] = true
        }
        if groupedRuns.contains(true) {
            return join(render(groupedRuns), " AND ")
        }
        // Only a group starts with "(": words and phrases start with a quote, scoped terms with
        // their column.
        if terms.contains(where: { $0.text.hasPrefix("(") }) {
            return join(terms, " AND ")
        }
        return join(terms, " ")
    }

    /// A written term: the operator kept before it, its FTS5 text, its run of words, and whether it
    /// is a synonym group (which takes the automatic prefix star off the words in its run).
    private struct Term {
        let op: String?
        let text: String
        let run: Int
        let synonymGroup: Bool
    }

    private static func join(_ terms: [Term], _ joiner: String) -> String {
        var s = ""
        for (n, term) in terms.enumerated() {
            if n > 0 {
                s += term.op.map { " \($0) " } ?? joiner
            }
            s += term.text
        }
        return s
    }

    /// FTS5's binary operators, which are case-sensitive.
    private static let operators = ["AND", "OR", "NOT"]

    private enum Item {
        /// Text between double quotes (an unclosed quote runs to the end).
        case phrase(String)
        /// A run of characters without whitespace or double quotes.
        case word(String)
    }

    private static func scan(_ q: String) -> [Item] {
        // FTS5 reads a NUL as the end of the query, leaving a string open; the tokenizer treats it
        // as a separator anyway. Replaced per scalar: a String replacement compares characters,
        // and a NUL followed by a combining mark is one character, so it would be left in place.
        let scalars = q.unicodeScalars.map { $0 == "\0" ? " " : $0 }
        var items: [Item] = []
        var i = 0
        while true {
            while i < scalars.count && scalars[i].properties.isWhitespace {
                i += 1
            }
            if i == scalars.count {
                return items
            }
            if scalars[i] == "\"" {
                let start = i + 1
                let end = scalars[start...].firstIndex(of: "\"") ?? scalars.count
                items.append(.phrase(string(scalars[start..<end])))
                i = min(end + 1, scalars.count)
            } else {
                let end = scalars[i...].firstIndex { $0.properties.isWhitespace || $0 == "\"" } ?? scalars.count
                items.append(.word(string(scalars[i..<end])))
                i = end
            }
        }
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `(table column, value)` when `w` is `name:value` with `name` one of `queryColumns`.
    private static func scopedColumn(_ w: String) -> (column: String, value: String)? {
        let scalars = Array(w.unicodeScalars)
        guard let colon = scalars.firstIndex(of: ":") else { return nil }
        let name = string(scalars[..<colon])
        guard let entry = queryColumns.first(where: { asciiCaseInsensitiveEqual($0.typed, name) }) else {
            return nil
        }
        return (entry.column, string(scalars[(colon + 1)...]))
    }

    private static func asciiCaseInsensitiveEqual(_ a: String, _ b: String) -> Bool {
        let lower = { (byte: UInt8) -> UInt8 in (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }
        return a.utf8.elementsEqual(b.utf8) { lower($0) == lower($1) }
    }

    /// Whether text has a character the tokenizer indexes (a term with none matches nothing).
    /// unicode61 indexes letters, numbers and private-use characters (`L* N* Co`); the
    /// Alphabetic property also counts the marks and enclosed-letter symbols (Ⓜ, 🅿) that
    /// unicode61 does not index.
    private static func hasText<S: Sequence>(_ s: S) -> Bool where S.Element == Unicode.Scalar {
        s.contains(where: isText)
    }

    private static func isText(_ c: Unicode.Scalar) -> Bool {
        let category = c.properties.generalCategory
        return (isAlphanumeric(c) && !isMark(category) && !isSymbol(category)) || category == .privateUse
    }

    /// Rust's `char::is_alphanumeric`: the Alphabetic property, or a number category.
    private static func isAlphanumeric(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return c.properties.isAlphabetic
        }
    }

    private static func isMark(_ category: Unicode.GeneralCategory) -> Bool {
        category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
    }

    private static func isSymbol(_ category: Unicode.GeneralCategory) -> Bool {
        category == .mathSymbol || category == .currencySymbol || category == .modifierSymbol || category == .otherSymbol
    }

    private static func phrase(_ p: String) -> String? {
        hasText(p.unicodeScalars) ? "\"\(p)\"" : nil
    }

    /// Quote marks removed from either end of a word (`'budget'`).
    private static let quoteMarks: Set<Unicode.Scalar> = ["'", "\u{2018}", "\u{2019}"]

    /// Apostrophes a word may hold inside it (`don't`, `don’t`); also a possessive's.
    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}"]

    /// A word's searched text, whether the user ended it with `*`, and whether a possessive was
    /// removed: one trailing `*`, then trailing `/` and `?`, then quote marks at either end
    /// (`'budget'`), then one possessive `'s` are removed. A possessive is found at the end of the
    /// word's text, so `Sarah's.` reads as `Sarah's`. Any other apostrophe stays: the tokenizer
    /// splits `O'Brien` into `o` and `brien`, and the quoted word searches them as a phrase.
    /// `John's` searches `John`, which (stemmed) also finds "John's".
    private static func prepareWord(_ w: String) -> (core: String, star: Bool, possessive: Bool)? {
        var s = Array(w.unicodeScalars)
        let star = s.last == "*"
        if star {
            s.removeLast()
        }
        while let last = s.last, last == "/" || last == "?" {
            s.removeLast()
        }
        while let last = s.last, quoteMarks.contains(last) {
            s.removeLast()
        }
        while let first = s.first, quoteMarks.contains(first) {
            s.removeFirst()
        }
        var text = s
        while let last = text.last, !isText(last) {
            text.removeLast()
        }
        let possessive = text.count >= 2 && apostrophes.contains(text[text.count - 2])
            && (text[text.count - 1] == "s" || text[text.count - 1] == "S")
        let core = possessive ? Array(text.dropLast(2)) : s
        return hasText(core) ? (string(core), star, possessive) : nil
    }

    private static func hasPunctuation(_ core: String) -> Bool {
        core.unicodeScalars.contains { !isAlphanumeric($0) && $0 != "_" && $0.properties.generalCategory != .privateUse }
    }

    /// The word written without its apostrophes, when an inner apostrophe is its only punctuation
    /// (`don't` → `dont`, `rock'n'roll` → `rocknroll`; `a'b-c` has none).
    private static func joinedSpelling(_ core: String) -> String? {
        let joined = string(core.unicodeScalars.filter { !apostrophes.contains($0) })
        return joined.utf8.count < core.utf8.count && !hasPunctuation(joined) ? joined : nil
    }

    /// The FTS5 text of a word, and whether it is a synonym group. `spellings` lets a word with an
    /// inner apostrophe search both spellings.
    private static func word(_ w: String, useSynonyms: Bool, spellings: Bool, hasOrGroups: Bool) -> (text: String, synonymGroup: Bool)? {
        guard let (core, star, possessive) = prepareWord(w) else { return nil }
        // A possessive looks up its word with the `s`, as 0.11.8 did: `comment's` gets the synonyms
        // of `comments`, and `client's` (`clients` has none) keeps its neighbours' prefix stars.
        // Only a word the user did not star expands (every synonym is plain letters).
        let key = possessive ? core + "s" : core
        if useSynonyms && !star && SearchSynonyms.wouldExpand(key) {
            return (SearchSynonyms.expand(key), true)
        }
        let possessiveBytes = possessive ? 1 : 0
        let starMark = { (prefix: Bool) in prefix ? "*" : "" }
        // A word with an inner apostrophe finds the text as written (the tokenizer indexed `don't` as
        // `don` `t`) and the spelling without it ("Dont"), as 0.11.8 searched it. The typed spelling
        // is a prefix, as any word with punctuation, unless its last part is one letter: `t*` would
        // merge every indexed word starting with t (no one-letter prefix index), and finds "Don took".
        // The joined spelling is a plain word.
        if spellings, let joined = joinedSpelling(core) {
            let scalars = Array(core.unicodeScalars)
            let lastPart = scalars.lastIndex(where: { apostrophes.contains($0) }).map { scalars.count - $0 - 1 }
            let typed = star || lastPart != 1
            let plain = star || (joined.utf8.count + possessiveBytes >= SearchConfig.autoPrefixMinBytes && !hasOrGroups)
            return ("(\"\(core)\"\(starMark(typed)) OR \"\(joined)\"\(starMark(plain)))", false)
        }
        // A word with punctuation is a phrase of its parts ("dmarc-supp" → [dmarc, supp]); the star
        // keeps a partial address matching while it is typed (ADR-024). Plain words of 4+ bytes get
        // one too, unless synonym groups are present; a possessive's `s` counts, as 0.11.8 searched
        // `Tom's` as `Toms*`.
        let prefix = star || hasPunctuation(core)
            || (core.utf8.count + possessiveBytes >= SearchConfig.autoPrefixMinBytes && !hasOrGroups)
        return ("\"\(core)\"\(starMark(prefix))", false)
    }
}
