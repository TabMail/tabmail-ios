/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct MarketplaceTemplateDetailView: View {
    let template: TemplateMarketplaceClient.MarketplaceTemplate
    let isInstalled: Bool
    let onInstall: (String) -> Void

    @State private var isInstalling = false
    @State private var installError: String?
    @State private var didInstall = false
    @State private var showReportConfirmation = false
    @State private var store = PromptStore.shared

    var body: some View {
        Form {
            Group {
                Section("About") {
                    LabeledContent("Name", value: template.name)
                    if let description = template.description, !description.isEmpty {
                        Text(description)
                    }
                    LabeledContent("Downloads", value: "\(template.download_count)")
                    if let tags = template.tags, !tags.isEmpty {
                        LabeledContent("Tags") {
                            Text(tags.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Instructions (\(template.instructions.count))") {
                    ForEach(Array(template.instructions.enumerated()), id: \.offset) { _, instruction in
                        Text(instruction)
                            .font(.callout)
                    }
                }

                if !template.example_reply.isEmpty {
                    Section("Example Reply") {
                        Text(template.example_reply)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if isInstalled || didInstall {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await installTemplate() }
                        } label: {
                            HStack {
                                if isInstalling {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text("Install Template")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isInstalling)
                    }

                    if let installError {
                        Text(installError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        reportTemplate()
                    } label: {
                        Label("Report Concern", systemImage: "exclamationmark.bubble")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("Report Submitted", isPresented: $showReportConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thank you for your feedback. We'll review this template.")
        }
    }

    private func reportTemplate() {
        Task {
            await ReportConcernService.report(
                contentType: .communityTemplate,
                content: template.name + ": " + (template.description ?? "")
            )
        }
        showReportConfirmation = true
    }

    @MainActor
    private func installTemplate() async {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil

        do {
            let downloaded = try await TemplateMarketplaceClient.shared.downloadTemplate(id: template.id)

            // Dedup: skip if template with this ID already exists (not soft-deleted)
            guard !store.visibleTemplates.contains(where: { $0.id == downloaded.id }) else {
                didInstall = true
                onInstall(downloaded.id)
                isInstalling = false
                return
            }

            let localTemplate = ReplyTemplate(
                id: downloaded.id,
                name: downloaded.name,
                enabled: downloaded.enabled,
                instructions: downloaded.instructions,
                exampleReply: downloaded.exampleReply
            )
            store.addTemplate(localTemplate)
            didInstall = true
            onInstall(downloaded.id)
        } catch {
            installError = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.localizedDescription
        }

        isInstalling = false
    }
}

struct MarketplaceTemplateRow: View {
    let template: TemplateMarketplaceClient.MarketplaceTemplate
    let isInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(template.name)
                    .lineLimit(1)
                if template.is_official {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.accentColor)
                        .font(.caption)
                }
                if template.is_featured {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                if isInstalled {
                    Text("Installed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.buttonBg)
                        .clipShape(Capsule())
                }
            }

            if let description = template.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label("\(template.instructions.count) rules", systemImage: "list.bullet")
                Label("\(template.download_count)", systemImage: "arrow.down.circle")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
