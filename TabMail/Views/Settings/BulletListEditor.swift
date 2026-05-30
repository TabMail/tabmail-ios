/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Reusable editor for markdown bullet items (`- item`).
/// Takes a `Binding<String>` (raw markdown), parses into individual rows,
/// and serializes back on changes. Same UX as template instructions.
struct BulletListEditor: View {
    @Binding var text: String
    var placeholder: String = "Add item..."

    @State private var newItem = ""
    @FocusState private var fieldFocused: Bool

    /// Parse "- item1\n- item2" → ["item1", "item2"]
    private var items: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    /// Serialize ["item1", "item2"] → "- item1\n- item2"
    private func setItems(_ newItems: [String]) {
        text = newItems.map { "- \($0)" }.joined(separator: "\n")
    }

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            Text(item)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        var current = items
                        current.remove(at: index)
                        setItems(current)
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
    }

    private func addItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = items
        current.append(trimmed)
        setItems(current)
        newItem = ""
        fieldFocused = true
    }
}
