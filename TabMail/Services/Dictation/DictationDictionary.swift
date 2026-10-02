/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Observation

/// The user's dictation dictionary (ADR-IOS-086): names and terms spelled their way, typed in
/// Settings or learned from their own corrections of a dictation. Sent with every dictation, to the
/// transcription and the cleanup, so they come out right. Kept on this device only, in
/// UserDefaults, and not synced. The same rules as TabMail Voice's (ADR-DESK-038): at most
/// `dictionaryMaxEntries` words, `dictionaryMaxTypedWords` of them typed; learned words fill the
/// rest, the one used least recently making way for a new one.
@MainActor
@Observable
final class DictationDictionary {
    struct Entry: Codable, Equatable, Sendable {
        var word: String
        /// Learned from a correction rather than typed.
        var learned: Bool
        /// The entry's latest use (added, typed or learned again, or in a dictation's text), larger
        /// the more recent: a count, not a time, so a clock set back can't reorder it. A full
        /// dictionary drops the learned word of the smallest for a new one.
        var lastUsed: Int

        init(word: String, learned: Bool, lastUsed: Int) {
            self.word = word
            self.learned = learned
            self.lastUsed = lastUsed
        }

        /// An entry stored before `lastUsed` was kept, or with an invalid one, reads as never used.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            word = try container.decode(String.self, forKey: .word)
            learned = try container.decode(Bool.self, forKey: .learned)
            lastUsed = max((try? container.decodeIfPresent(Int.self, forKey: .lastUsed)) ?? 0, 0)
        }
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

    /// Adds a typed word, refused (`full`) at `dictionaryMaxTypedWords` typed words. One already
    /// there, whatever its case, is not added twice but takes the spelling typed, the user's latest;
    /// a learned one typed again becomes typed, so it is refused at the cap too. A full dictionary
    /// drops the learned word used least recently for a new one.
    @discardableResult
    func add(_ raw: String) -> AddResult {
        guard let word = Self.word(raw) else { return .invalid }
        let use = nextUse
        let typedFull = entries.count(where: { !$0.learned }) >= DictationConfig.dictionaryMaxTypedWords
        if let existing = entries.firstIndex(where: { Self.isSameWord($0.word, word) }) {
            if entries[existing].learned && typedFull { return .full }
            entries[existing] = Entry(word: word, learned: false, lastUsed: use)
        } else {
            guard !typedFull, makeRoom(before: use) else { return .full }
            entries.append(Entry(word: word, learned: false, lastUsed: use))
        }
        save()
        return .added
    }

    /// Adds words learned from a correction, those not already there; a full dictionary drops the
    /// learned word used least recently for each, never one learned in the same call. One already
    /// there counts as used, marked before any is added so that no new word drops it, wherever it
    /// comes in `words`. Returns the ones added.
    @discardableResult
    func learn(_ words: [String]) -> [String] {
        let use = nextUse
        var fresh: [String] = []
        var changed = false
        for raw in words {
            guard let word = Self.word(raw) else { continue }
            if let existing = entries.firstIndex(where: { Self.isSameWord($0.word, word) }) {
                guard entries[existing].lastUsed != use else { continue }
                entries[existing].lastUsed = use
                changed = true
            } else {
                fresh.append(word)
            }
        }
        var added: [String] = []
        for word in fresh {
            guard !entries.contains(where: { Self.isSameWord($0.word, word) }), makeRoom(before: use) else { continue }
            entries.append(Entry(word: word, learned: true, lastUsed: use))
            added.append(word)
        }
        if changed || !added.isEmpty { save() }
        return added
    }

    /// Marks the words found in a dictation's `texts` (the transcript, and the text it pasted) as
    /// used now, whatever their case, so a full dictionary keeps them over the learned words not
    /// used since. A word inside a longer one counts ("TabMail" in "TabMail's"): the scripts without
    /// spaces between words have no edge to look for.
    func use(_ texts: [String]) {
        let said = texts.joined(separator: "\n").lowercased()
        let use = nextUse
        var changed = false
        for index in entries.indices where said.contains(entries[index].word.lowercased()) {
            entries[index].lastUsed = use
            changed = true
        }
        if changed { save() }
    }

    /// Removes the entry spelled exactly `word`.
    func remove(_ word: String) {
        entries.removeAll { $0.word == word }
        save()
    }

    /// The `lastUsed` of a use now: after every entry's.
    private var nextUse: Int {
        (entries.map(\.lastUsed).max() ?? 0) + 1
    }

    /// Makes room for one more word: true when there was room, or after dropping the learned word
    /// used least recently before `use` (the earliest of a tie); false when there is none to drop.
    private func makeRoom(before use: Int) -> Bool {
        guard entries.count >= DictationConfig.dictionaryMaxEntries else { return true }
        let learned = entries.indices.filter { entries[$0].learned && entries[$0].lastUsed < use }
        guard let dropped = learned.min(by: { entries[$0].lastUsed < entries[$1].lastUsed }) else { return false }
        entries.remove(at: dropped)
        BackgroundSyncLogger.logDebug("[Dictation] dictionary full; dropped the learned word used least recently")
        return true
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
    /// most `dictionaryMaxEntries`. One without a valid `lastUsed` reads as never used.
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
