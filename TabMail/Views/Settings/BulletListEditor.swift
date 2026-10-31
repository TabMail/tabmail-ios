/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// What the editor's Add and Delete controls do, apart from the view: a hosted SwiftUI control publishes
/// no element a test can tap, so the tests call these, and the controls' closures only call them.
@MainActor
enum BulletListEditorActions {
    /// DS-DISPLAYED: deletes exactly the labels the row showed.
    static func delete(_ shown: ShownBullet, from section: PromptSection, in store: PromptStore) -> Task<PromptEditOutcome, Never> {
        store.gesture("delete \(section.key) bullet") { try $0.deleteShown(shown, from: section) }
    }

    enum Add {
        /// Nothing typed.
        case nothing
        /// The line was not added; the text is shown under the field.
        case refused(String)
        /// Being added; the field is cleared once it is `.saved` or `.unchanged`.
        case adding(Task<PromptEditOutcome, Never>)
    }

    static func add(_ typed: String, to section: PromptSection, in store: PromptStore) -> Add {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .nothing }
        guard !PromptStore.holdsSectionMarker(trimmed, in: section) else { return .refused(PromptStore.sectionMarkerRefusal) }
        return .adding(store.gesture("add \(section.key) bullet") { try $0.addBullet(trimmed, to: section) })
    }
}

/// Editor for one section's bullets. Each add or delete is its own change to that bullet (Device Sync's
/// DS-ADD and DS-DISPLAYED): a bullet that arrived from another device while this is open is never
/// removed by it. Same UX as template instructions.
struct BulletListEditor: View {
    let store: PromptStore
    let section: PromptSection
    var placeholder: String = "Add item..."
    /// An item the guided tutorial points at (its sample action rule).
    var highlightedItem: String?

    @State private var newItem = ""
    /// Why the line typed was not added , shown under the field.
    @State private var refusal: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ForEach(store.shown(section)) { shown in
            let item = shown.text
            Text(item)
                .padding(.horizontal, item == highlightedItem ? 6 : 0)
                .overlay {
                    if item == highlightedItem {
                        TutorialPulseRing(shape: RoundedRectangle(cornerRadius: 6), lineWidth: 2, outset: 2)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        _ = BulletListEditorActions.delete(shown, from: section, in: store)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }

        HStack {
            TextField(placeholder, text: $newItem)
                .focused($fieldFocused)
                .onSubmit {
                    addItem()
                }
            Button {
                addItem()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
            .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        if let refusal {
            Text(refusal)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func addItem() {
        switch BulletListEditorActions.add(newItem, to: section, in: store) {
        case .nothing:
            return
        case .refused(let text):
            refusal = text
        case .adding(let adding):
            refusal = nil
            Task {
                let outcome = await adding.value
                guard outcome == .saved || outcome == .unchanged else { return }
                newItem = ""
                fieldFocused = true
            }
        }
    }
}
