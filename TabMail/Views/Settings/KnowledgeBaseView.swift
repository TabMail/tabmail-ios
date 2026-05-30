/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct KnowledgeBaseView: View {
    @State private var store = PromptStore.shared
    @State private var syncService = DeviceSyncService.shared
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Group {
            Section {
                Text("Behavioral directives and preemptive knowledge the AI should always consider — your role, company info, preferences, and contextual facts. Swipe to delete.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                BulletListEditor(text: $store.knowledgeBase)
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Knowledge Base")
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
                store.resetKB()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your knowledge base with the defaults.")
        }
    }
}
