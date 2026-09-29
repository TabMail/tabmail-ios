/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Settings › Personalization › Voice Dictation Dictionary (ADR-IOS-086): the words and names the
/// user wants dictation to spell their way, typed here or learned from their corrections.
struct DictationDictionaryView: View {
    @State private var dictionary = DictationDictionary.shared
    @State private var newWord = ""
    @State private var refusal: String?

    static let invalidMessage = "A word or name of up to \(DictationConfig.dictionaryWordMaxWords) words, without < or >."
    static let fullMessage = "The dictionary holds \(DictationConfig.dictionaryMaxEntries) words. Remove one to add another."
    static let learningNote = "For \(Int(DictationConfig.correctionWatchDuration.components.seconds)) seconds after a dictation, TabMail watches the chat field it went into. When you correct how a word or name was spelled, the new spelling is added here. The field's text stays on this iPhone."

    var body: some View {
        Form {
            Group {
                Section {
                    HStack {
                        TextField("Add a word or name", text: $newWord)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let refusal {
                        Text(refusal)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Names and terms spelled your way, kept on this iPhone. They're sent with each dictation so they come out right, and TabMail doesn't keep them.")
                }

                Section {
                    if dictionary.entries.isEmpty {
                        Text("No words yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dictionary.entries, id: \.word) { entry in
                        HStack {
                            Text(entry.word)
                            if entry.learned {
                                Text("Learned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { Self.remove(at: $0, from: dictionary) }
                }

                Section {
                    Toggle("Learn from My Corrections", isOn: $dictionary.learnsWords)
                } footer: {
                    Text(Self.learningNote)
                }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .scrollDismissesKeyboard(.interactively)
        .dismissKeyboardOnTap()
        .navigationTitle("Voice Dictation Dictionary")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        (newWord, refusal) = Self.submit(newWord, to: dictionary)
    }

    /// What submitting `word` leaves in the field and under it: the field emptied once the word is
    /// added; else the word kept, with why it wasn't.
    static func submit(_ word: String, to dictionary: DictationDictionary) -> (draft: String, refusal: String?) {
        switch dictionary.add(word) {
        case .added: ("", nil)
        case .invalid: (word, invalidMessage)
        case .full: (word, fullMessage)
        }
    }

    /// Removes the rows at `offsets` of the list, by their words.
    static func remove(at offsets: IndexSet, from dictionary: DictationDictionary) {
        offsets.map { dictionary.entries[$0].word }.forEach(dictionary.remove)
    }
}
