/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Horizontally scrollable row of active filter chips, shown above the bottom toolbar.
///
/// - "Unread" chip: always present; tapping toggles unread filtering on/off.
/// - Label chips: shown for each active label filter; tapping opens the label picker sheet.
/// - "+" chip: at the end; tapping opens the label picker sheet to add more labels.
struct FilterChipBar: View {
    @Binding var filterUnread: Bool
    @Binding var filterLabelIds: Set<String>
    let accountId: String
    var onFilterChanged: () -> Void
    var onOpenLabelPicker: () -> Void

    @State private var resolvedLabels: [(id: String, name: String)] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Unread chip — tap toggles on/off
                filterChip(
                    title: "Unread",
                    systemImage: "envelope.badge",
                    isActive: filterUnread
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        filterUnread.toggle()
                    }
                    onFilterChanged()
                }

                // Active label chips — tap opens label picker
                ForEach(resolvedLabels, id: \.id) { label in
                    filterChip(
                        title: label.name,
                        systemImage: "tag.fill",
                        isActive: true
                    ) {
                        onOpenLabelPicker()
                    }
                }

                // "+" chip — add label filters
                Button {
                    onOpenLabelPicker()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .onAppear { loadLabelNames() }
        .onChange(of: filterLabelIds) { loadLabelNames() }
    }

    // MARK: - Chip builder

    private func filterChip(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.white : .secondary)
            .background(isActive ? Theme.accent : Color(.systemGray5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func loadLabelNames() {
        guard !filterLabelIds.isEmpty else {
            resolvedLabels = []
            return
        }
        let ids = filterLabelIds
        resolvedLabels = (try? AppDatabase.dbPool.read { db in
            try UserLabelStore.labels(ids: ids, accountId: accountId, in: db)
                .map { (id: $0.id, name: $0.name) }
        }) ?? []
    }
}
