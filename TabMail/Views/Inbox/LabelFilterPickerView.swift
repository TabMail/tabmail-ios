/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Sheet for selecting labels to filter inbox by.
/// Toggles update the filter in realtime — inbox refreshes as labels are selected/deselected.
struct LabelFilterPickerView: View {
    @Binding var selectedLabelIds: Set<String>
    let accountId: String
    /// Called when selection changes so the inbox can refresh.
    var onChanged: () -> Void
    @State private var searchText = ""
    @State private var allLabels: [UserLabel] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredLabels) { label in
                    Button {
                        toggle(label)
                    } label: {
                        HStack {
                            Image(systemName: selectedLabelIds.contains(label.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.secondary)
                            Text(label.name)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search labels...")
            .navigationTitle("Filter by Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { loadLabels() }
        .dismissKeyboardOnTap()
    }

    private var filteredLabels: [UserLabel] {
        guard !searchText.isEmpty else { return allLabels }
        return allLabels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadLabels() {
        allLabels = (try? AppDatabase.dbPool.read { db in
            try UserLabelStore.allLabels(accountId: accountId, in: db)
        }) ?? []
    }

    private func toggle(_ label: UserLabel) {
        if selectedLabelIds.contains(label.id) {
            selectedLabelIds.remove(label.id)
        } else {
            selectedLabelIds.insert(label.id)
        }
        onChanged()
    }
}
