/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The `vocabulary` sent with a dictation (ADR-IOS-086), in importance order. The speech models take a
/// prefix of it and never reorder, so the first `speechVocabularyTerms` words are the ones that
/// matter: the typed dictionary words, then the terms of what the dictation is about, then the learned
/// words. The room is split by reserves, not caps: the context's terms get at least
/// `speechVocabularyMinContextTerms` of the first words, the learned words at least
/// `speechVocabularyMinLearnedWords`, and the dictionary (typed and learned) at most
/// `speechVocabularyMaxDictionaryWords` while the terms fill their reserve; a group with fewer words
/// leaves its room to the others. The words that did not fit follow (the rest of the dictionary, then
/// the remaining terms), up to `vocabularyMaxTerms`, for the AI cleanup alone: with Smart Dictation
/// off only the first words are sent. As TabMail Voice's.
enum DictationVocabulary {
    /// `words` is the dictionary, typed words first (`typedCount` of them; nil: all typed).
    static func list(words: [String], typedCount: Int?, terms: [String], includesOverflow: Bool) -> [String] {
        let typedTotal = min(max(typedCount ?? words.count, 0), words.count)
        let typed = Array(words[..<typedTotal])
        let learned = Array(words[typedTotal...])
        let room = DictationConfig.speechVocabularyTerms
        let dictionaryRoom = DictationConfig.speechVocabularyMaxDictionaryWords

        let typedTake = min(
            typed.count,
            room - min(terms.count, DictationConfig.speechVocabularyMinContextTerms)
                - min(learned.count, DictationConfig.speechVocabularyMinLearnedWords))
        let termsTake = min(terms.count, room - typedTake - min(learned.count, max(0, dictionaryRoom - typedTake)))
        let learnedTake = min(learned.count, room - typedTake - termsTake)

        var list = Array(typed.prefix(typedTake)) + Array(terms.prefix(termsTake)) + Array(learned.prefix(learnedTake))
        guard includesOverflow else { return list }
        list += typed.dropFirst(typedTake) + learned.dropFirst(learnedTake) + terms.dropFirst(termsTake)
        var seen = Set<String>()
        list = list.filter { seen.insert($0.lowercased()).inserted }
        return Array(list.prefix(DictationConfig.vocabularyMaxTerms))
    }
}
