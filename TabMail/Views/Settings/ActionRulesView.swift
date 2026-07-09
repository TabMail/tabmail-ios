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
    @State private var activeSectionId: String = "settings"
    @State private var listHeight: CGFloat = 600
    @AppStorage(PromptStore.actionCompactThresholdKey) private var actionCompactThreshold = PromptStore.defaultActionCompactThreshold
    @AppStorage(PromptStore.actionCompactThresholdCharsKey) private var actionCompactThresholdChars = PromptStore.defaultActionCompactThresholdChars

    // Compact button state
    @State private var isCompacting = false
    @State private var compactStatusMessage: String? = nil

    private let syncTip = DeviceSyncTip()

    private let sections: [SectionInfo] = [
        SectionInfo(id: "delete", title: "Emails to Delete", subtitle: "Emails matching these rules will be suggested for deletion. Swipe to delete.", color: Theme.tagColor(.delete)),
        SectionInfo(id: "archive", title: "Emails to Archive", subtitle: "Emails matching these rules will be suggested for archiving.", color: Theme.tagColor(.archive)),
        SectionInfo(id: "reply", title: "Emails to Reply", subtitle: "Emails matching these rules will be flagged as needing a reply.", color: Theme.tagColor(.reply)),
        SectionInfo(id: "none", title: "Emails to Mark as None", subtitle: "Emails that don't fit other categories.", color: Theme.tagColor(.none)),
    ]

    /// Pseudo-section for the threshold-settings area at the top of the form —
    /// the nav title reads "Action Classification" until a rule section
    /// dominates the viewport.
    private let settingsSection = SectionInfo(
        id: "settings",
        title: "Action Classification",
        subtitle: "",
        color: .clear
    )

    private var activeSection: SectionInfo {
        if activeSectionId == settingsSection.id { return settingsSection }
        return sections.first { $0.id == activeSectionId } ?? settingsSection
    }

    var body: some View {
        Form {
            TipView(syncTip)
                .listRowBackground(Color.clear)

            Section {
                Group {
                    Label {
                        Text("Rules threshold: \(actionCompactThreshold)")
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(actionCompactThreshold) },
                            set: { actionCompactThreshold = Int($0) }
                        ),
                        in: 20...500,
                        step: 10
                    )

                    Label {
                        Text("Size threshold: \(actionCompactThresholdChars) chars")
                    } icon: {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(actionCompactThresholdChars) },
                            set: { actionCompactThresholdChars = Int($0) }
                        ),
                        in: 2000...40000,
                        step: 1000
                    )

                    Button {
                        Task {
                            isCompacting = true
                            compactStatusMessage = nil
                            let result = await AIService.shared.compactActionRulesNow()
                            isCompacting = false
                            switch result {
                            case .applied(let opsCount):
                                compactStatusMessage = "Merged \(opsCount) rule\(opsCount == 1 ? "" : "s")"
                            case .nothingToCompact:
                                compactStatusMessage = "Nothing to compact"
                            case .skipped(let reason):
                                compactStatusMessage = reason
                            case .failed(let message):
                                compactStatusMessage = "Error: \(message)"
                            }
                        }
                    } label: {
                        HStack {
                            if isCompacting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Compacting…")
                            } else {
                                Label("Compact now", systemImage: "arrow.triangle.merge")
                            }
                        }
                    }
                    .disabled(isCompacting)

                    if let msg = compactStatusMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .background(sectionTracker("settings"))
            } header: {
                Text("Rules are automatically merged during refinement when either limit is exceeded.")
                    .textCase(nil)
            }
            .listRowBackground(Palette.boxBg)

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

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Reset to Defaults")
                        Spacer()
                    }
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
            // Sum visible height per section id: the settings tracker is applied
            // to a Group, which emits one entry per row — summing weighs the
            // whole settings area fairly against the single-entry rule editors.
            var totals: [String: CGFloat] = [:]
            for v in vis {
                totals[v.id, default: 0] += max(0, min(v.maxY, listHeight) - max(v.minY, 0))
            }
            guard let best = totals.max(by: { $0.value < $1.value }) else { return }
            if best.key != activeSectionId {
                activeSectionId = best.key
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    if activeSection.id != settingsSection.id {
                        Circle().fill(activeSection.color).frame(width: 8, height: 8)
                    }
                    Text(activeSection.title)
                        .font(.headline)
                        .lineLimit(1)
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
