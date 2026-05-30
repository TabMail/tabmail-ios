/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

private struct SectionVisibility: Equatable {
    let id: String
    let minY: CGFloat
    let maxY: CGFloat
}

private struct SectionVisibilityKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [SectionVisibility] = []
    static func reduce(value: inout [SectionVisibility], nextValue: () -> [SectionVisibility]) {
        value.append(contentsOf: nextValue())
    }
}

private struct SectionInfo {
    let id: String
    let title: String
    let subtitle: String
    let color: Color
}

struct ActionRulesView: View {
    @State private var store = PromptStore.shared
    @State private var syncService = DeviceSyncService.shared
    @State private var showResetConfirmation = false
    @State private var activeSectionId: String = "delete"
    @State private var listHeight: CGFloat = 600

    private let syncTip = DeviceSyncTip()

    private let sections: [SectionInfo] = [
        SectionInfo(id: "delete", title: "Emails to Delete", subtitle: "Emails matching these rules will be suggested for deletion. Swipe to delete.", color: Theme.tagColor(.delete)),
        SectionInfo(id: "archive", title: "Emails to Archive", subtitle: "Emails matching these rules will be suggested for archiving.", color: Theme.tagColor(.archive)),
        SectionInfo(id: "reply", title: "Emails to Reply", subtitle: "Emails matching these rules will be flagged as needing a reply.", color: Theme.tagColor(.reply)),
        SectionInfo(id: "none", title: "Emails to Mark as None", subtitle: "Emails that don't fit other categories.", color: Theme.tagColor(.none)),
    ]

    private var activeSection: SectionInfo {
        sections.first { $0.id == activeSectionId } ?? sections[0]
    }

    var body: some View {
        Form {
            TipView(syncTip)
                .listRowBackground(Color.clear)

            Group {
            Section {
                BulletListEditor(text: $store.deleteRules)
                    .background(sectionTracker("delete"))
            } header: {
                sectionHeader(title: "Emails to Delete", subtitle: "Emails matching these rules will be suggested for deletion. Swipe to delete.", color: Theme.tagColor(.delete))
            }

            Section {
                BulletListEditor(text: $store.archiveRules)
                    .background(sectionTracker("archive"))
            } header: {
                sectionHeader(title: "Emails to Archive", subtitle: "Emails matching these rules will be suggested for archiving.", color: Theme.tagColor(.archive))
            }

            Section {
                BulletListEditor(text: $store.replyRules)
                    .background(sectionTracker("reply"))
            } header: {
                sectionHeader(title: "Emails to Reply", subtitle: "Emails matching these rules will be flagged as needing a reply.", color: Theme.tagColor(.reply))
            }

            Section {
                BulletListEditor(text: $store.noneRules)
                    .background(sectionTracker("none"))
            } header: {
                sectionHeader(title: "Emails to Mark as None", subtitle: "Emails that don't fit other categories.", color: Theme.tagColor(.none))
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .coordinateSpace(name: "actionRulesList")
        .background(GeometryReader { geo in
            Color.clear.onAppear { listHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in listHeight = h }
        })
        .onPreferenceChange(SectionVisibilityKey.self) { vis in
            guard let best = vis.max(by: {
                let i1 = max(0, min($0.maxY, listHeight) - max($0.minY, 0))
                let i2 = max(0, min($1.maxY, listHeight) - max($1.minY, 0))
                return i1 < i2
            }) else { return }
            if best.id != activeSectionId {
                activeSectionId = best.id
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle().fill(activeSection.color).frame(width: 8, height: 8)
                    Text(activeSection.title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
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
                store.resetAction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your action classification rules with the defaults.")
        }
    }

    private func sectionTracker(_ id: String) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("actionRulesList"))
            Color.clear.preference(
                key: SectionVisibilityKey.self,
                value: [SectionVisibility(id: id, minY: frame.minY, maxY: frame.maxY)]
            )
        }
    }

    private func sectionHeader(title: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
