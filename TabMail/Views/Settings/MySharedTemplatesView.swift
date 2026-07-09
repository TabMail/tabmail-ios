/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct MySharedTemplatesView: View {
    @State private var templates: [TemplateMarketplaceClient.MyTemplate] = []
    @State private var limits: TemplateMarketplaceClient.TemplateLimits?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        // ZStack, NOT Group: Group is a transparent pass-through, so the
        // `.task` below effectively hangs on the isLoading conditional —
        // whose branches loadMyTemplates' own isLoading writes flip,
        // cancelling/restarting the task (the Account-page infinite-
        // spinner footgun; see PROJECT_MEMORY stuck-isLoading rule).
        ZStack {
            if isLoading && templates.isEmpty {
                ProgressView("Loading...")
            } else if let errorMessage, templates.isEmpty {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await loadMyTemplates() } }
                }
            } else if templates.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Shared Templates",
                    systemImage: "square.and.arrow.up",
                    description: Text("Templates you share will appear here.")
                )
            } else {
                List {
                    if let limits {
                        Section {
                            LabeledContent("Shared", value: "\(limits.current_count) / \(limits.max_templates)")
                        }
                        .listRowBackground(Palette.boxBg)
                    }

                    Section {
                        ForEach(templates) { template in
                            NavigationLink {
                                SharedTemplateDetailView(template: template) {
                                    templates.removeAll { $0.id == template.id }
                                    if let l = limits {
                                        limits = TemplateMarketplaceClient.TemplateLimits(
                                            max_templates: l.max_templates,
                                            current_count: l.current_count - 1,
                                            remaining: l.remaining + 1
                                        )
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(template.name)
                                            .lineLimit(1)
                                        Spacer()
                                        StatusBadge(status: template.status)
                                    }

                                    HStack(spacing: 12) {
                                        Label("\(template.instructions.count) rules", systemImage: "list.bullet")
                                        Label("\(template.download_count)", systemImage: "arrow.down.circle")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                    if let reason = template.rejection_reason, !reason.isEmpty {
                                        Text("Rejected: \(reason)")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .listRowBackground(Palette.boxBg)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.previewPaneBg)
        .navigationTitle("My Shared Templates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMyTemplates() }
    }

    private func loadMyTemplates() async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await TemplateMarketplaceClient.shared.myTemplates()
            templates = response.templates
            limits = response.limits
        } catch {
            errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
        }

        isLoading = false
    }
}

// MARK: - Shared Template Detail (read-only)

private struct SharedTemplateDetailView: View {
    let template: TemplateMarketplaceClient.MyTemplate
    let onUnshare: () -> Void

    @State private var showConfirmation = false
    @State private var isUnsharing = false
    @State private var unshareError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Group {
                Section("Status") {
                    HStack {
                        Text("Review Status")
                        Spacer()
                        StatusBadge(status: template.status)
                    }
                    LabeledContent("Downloads", value: "\(template.download_count)")

                    if let reason = template.rejection_reason, !reason.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rejection Reason")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(reason)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if let description = template.description, !description.isEmpty {
                    Section("Description") {
                        Text(description)
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

                if template.status != "removed" {
                    Section {
                        Button(role: .destructive) {
                            showConfirmation = true
                        } label: {
                            HStack {
                                if isUnsharing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "xmark.circle")
                                }
                                Text("Unshare from Marketplace")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isUnsharing)

                        if let unshareError {
                            Text(unshareError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } footer: {
                        Text("This will permanently remove the template from the marketplace and free up your quota.")
                    }
                }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unshare Template?", isPresented: $showConfirmation) {
            Button("Unshare", role: .destructive) {
                Task { await performUnshare() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(template.name)\" from the marketplace.")
        }
    }

    @MainActor
    private func performUnshare() async {
        guard !isUnsharing else { return }
        isUnsharing = true
        unshareError = nil

        do {
            try await TemplateMarketplaceClient.shared.unshareTemplate(id: template.id)
            onUnshare()
            dismiss()
        } catch {
            unshareError = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.localizedDescription
        }

        isUnsharing = false
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(displayText)
            .font(.caption2)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .clipShape(Capsule())
    }

    private var displayText: String {
        switch status {
        case "pending_review": return "Pending"
        case "approved", "auto_approved": return "Approved"
        case "rejected": return "Rejected"
        default: return status.capitalized
        }
    }

    private var foregroundColor: Color {
        switch status {
        case "approved", "auto_approved": return .green
        case "rejected": return .red
        case "pending_review": return .orange
        default: return .secondary
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.15)
    }
}
