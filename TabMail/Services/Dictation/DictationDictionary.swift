/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// The user's dictation dictionary (ADR-IOS-086): names and terms spelled their way, typed in
/// Settings or learned from their own corrections of a dictation. Sent with every dictation, to the
/// transcription and the cleanup, so they come out right. Kept on this device only, in
/// UserDefaults, and not synced. The same rules as TabMail Voice's (ADR-DESK-038).
@MainActor
@Observable
final class DictationDictionary {
    struct Entry: Codable, Equatable, Sendable {
        var word: String
        /// Learned from a correction rather than typed.
        var learned: Bool
    }

    /// What one dictation uses, read when it starts: a change mid-dictation applies to the next.
    struct Snapshot: Equatable, Sendable {
        var words: [String]
        var learnsWords: Bool
    }

    enum AddResult: Equatable {
        case added
        case invalid
        case full
    }

    static let entriesKey = "dictationDictionary"
    static let learnsWordsKey = "dictationLearnsWords"

    static let shared = DictationDictionary()

    private(set) var entries: [Entry]
    /// "Learn from my corrections"; on unless switched off.
    var learnsWords: Bool {
        didSet { defaults.set(learnsWords, forKey: Self.learnsWordsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.stored(defaults.data(forKey: Self.entriesKey))
        learnsWords = defaults.object(forKey: Self.learnsWordsKey) as? Bool ?? true
    }

    var snapshot: Snapshot {
        Snapshot(words: entries.map(\.word), learnsWords: learnsWords)
    }

    /// Adds a typed word. One already there, whatever its case, is not added twice but takes the
    /// spelling typed, the user's latest; a learned one typed again becomes typed.
    @discardableResult
    func add(_ raw: String) -> AddResult {
        guard let word = Self.word(raw) else { return .invalid }
        if let existing = entries.firstIndex(where: { Self.isSameWord($0.word, word) }) {
            entries[existing] = Entry(word: word, learned: false)
        } else {
            guard entries.count < DictationConfig.dictionaryMaxEntries else { return .full }
            entries.append(Entry(word: word, learned: false))
        }
        save()
        return .added
    }

    /// Adds words learned from a correction: those not already there, up to the limit. Returns the
    /// ones added.
    @discardableResult
    func learn(_ words: [String]) -> [String] {
        var added: [String] = []
        for raw in words {
            guard let word = Self.word(raw), entries.count < DictationConfig.dictionaryMaxEntries,
                  !entries.contains(where: { Self.isSameWord($0.word, word) }) else { continue }
            entries.append(Entry(word: word, learned: true))
            added.append(word)
        }
        if !added.isEmpty { save() }
        return added
    }

    /// Removes the entry spelled exactly `word`.
    func remove(_ word: String) {
        entries.removeAll { $0.word == word }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.entriesKey)
    }

    /// `raw` as a dictionary word, its spaces collapsed; nil when it is empty, too long, of too many
    /// words, or has a character the backend refuses (a control character, or `<` `>`, which the
    /// speech providers refuse and which could close the cleanup prompt's dictionary block). Spaces
    /// are the backend's, JavaScript's `\s`, found scalar by scalar as it does: Unicode's, and
    /// U+FEFF, which Swift doesn't count. A grapheme hides a space joined to the mark before it
    /// (U+0600 and its kind prepend), so words are not split by character; else a word of U+FEFF
    /// alone, or one more word than the backend counts, is sent and fails the dictation.
    nonisolated static func word(_ raw: String) -> String? {
        let parts = raw.unicodeScalars.split { $0.properties.isWhitespace || $0 == "\u{FEFF}" }.map { String($0) }
        let word = parts.joined(separator: " ")
        guard !word.isEmpty, word.utf16.count <= DictationConfig.dictionaryWordMaxChars,
              parts.count <= DictationConfig.dictionaryWordMaxWords,
              !word.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == "<" || $0 == ">" })
        else { return nil }
        return word
    }

    /// Whether two words are the same entry: the case aside, as the backend dedupes.
    nonisolated static func isSameWord(_ first: String, _ second: String) -> Bool {
        first.lowercased() == second.lowercased()
    }

    /// A stored list read back: valid entries only, the first of any two that are the same word, at
    /// most `dictionaryMaxEntries`.
    nonisolated static func stored(_ data: Data?) -> [Entry] {
        guard let data, let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        var entries: [Entry] = []
        for entry in decoded where entries.count < DictationConfig.dictionaryMaxEntries {
            guard word(entry.word) == entry.word, !entries.contains(where: { isSameWord($0.word, entry.word) }) else { continue }
            entries.append(entry)
        }
        return entries
    }
}
