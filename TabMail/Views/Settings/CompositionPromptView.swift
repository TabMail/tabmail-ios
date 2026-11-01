/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

struct CompositionPromptView: View {
    @State private var store = PromptStore.shared
    @State private var syncService = DeviceSyncService.shared
    @State private var showResetConfirmation = false
    private let syncTip = DeviceSyncTip()

    var body: some View {
        Form {
            TipView(syncTip)
                .listRowBackground(Color.clear)

            Group {
            Section {
                BulletListEditor(store: store, section: .writingStyle)
            } header: {
                sectionHeader(title: "General Writing Style", subtitle: "Describe your preferred tone, sign-off style, and writing conventions. Swipe to delete.")
            }

            Section {
                BulletListEditor(store: store, section: .language)
            } header: {
                sectionHeader(title: "Language", subtitle: "Specify which language(s) the AI should use when composing emails.")
            }

            Section {
                BulletListEditor(store: store, section: .usefulLinks, placeholder: "Add link...")
            } header: {
                sectionHeader(title: "Useful Links", subtitle: "Personal or company links the AI can reference in replies (e.g., website, support page).")
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Composition")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Reset") {
                    showResetConfirmation = true
                }
            }
        }
        .refreshable {
            guard syncService.isAutoEnabled else { return }
            syncService.syncNow()
            try? await Task.sleep(for: .milliseconds(500))
        }
        .confirmationDialog("Reset to Default?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                store.gesture("reset composition") { hold in
                    try hold.reset(.composition)
                    return .saved
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your composition settings with the defaults.")
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
