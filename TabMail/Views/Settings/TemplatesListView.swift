/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

private struct TemplateSheetItem: Identifiable {
    let id: String
}

struct TemplatesListView: View {
    @State private var store = PromptStore.shared
    @State private var syncService = DeviceSyncService.shared
    @State private var showMarketplace = false
    @State private var showMyShared = false
    @State private var templateSheetItem: TemplateSheetItem?
    private let syncTip = DeviceSyncTip()

    var body: some View {
        List {
            TipView(syncTip)
                .listRowBackground(Color.clear)

            Section {
                Button {
                    showMarketplace = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get More Templates")
                            Text("Browse community templates")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .foregroundStyle(.primary)
                }

                Button {
                    showMyShared = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My Shared Templates")
                            Text("View your uploads and their status")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(.primary)
                }
            }
            .listRowBackground(Palette.boxBg)

            Section {
            ForEach(store.visibleTemplates) { template in
                Button {
                    templateSheetItem = TemplateSheetItem(id: template.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(template.name)
                                .lineLimit(1)
                            Text("\(template.instructions.count) instruction\(template.instructions.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 4)
                        Toggle("", isOn: Binding(
                            get: { template.enabled },
                            set: { newValue in
                                var updated = template
                                updated.enabled = newValue
                                store.updateTemplate(updated)
                            }
                        ))
                            .labelsHidden()
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let visible = store.visibleTemplates
                for offset in offsets {
                    store.deleteTemplate(id: visible[offset].id)
                }
            }
            .listRowBackground(Palette.boxBg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle("Reply Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.addTemplate()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showMarketplace) {
            TemplateMarketplaceView()
        }
        .sheet(isPresented: $showMyShared) {
            NavigationStack {
                MySharedTemplatesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showMyShared = false }
                        }
                    }
            }
        }
        .refreshable {
            guard syncService.isAutoEnabled else { return }
            syncService.syncNow()
            try? await Task.sleep(for: .milliseconds(500))
        }
        .sheet(item: $templateSheetItem) { item in
            NavigationStack {
                TemplateDetailView(templateId: item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { templateSheetItem = nil }
                        }
                    }
            }
        }
    }
}
