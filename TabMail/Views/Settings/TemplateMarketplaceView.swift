/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct TemplateMarketplaceView: View {
    @State private var templates: [TemplateMarketplaceClient.MarketplaceTemplate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sortOrder: TemplateMarketplaceClient.SortOrder = .popular
    @State private var hasMore = false
    @State private var offset = 0
    @State private var installedIds: Set<String> = []
    @State private var loadTask: Task<Void, Never>?

    @State private var store = PromptStore.shared
    @Environment(\.dismiss) private var dismiss

    private let pageSize = 20

    var body: some View {
        NavigationStack {
            // ZStack, NOT Group: Group is a transparent pass-through, so the
            // `.task` below effectively hangs on the isLoading conditional —
            // whose branches loadTemplates' own isLoading writes flip,
            // cancelling/restarting the task (the Account-page infinite-
            // spinner footgun; see PROJECT_MEMORY stuck-isLoading rule).
            ZStack {
                if isLoading && templates.isEmpty {
                    ProgressView("Loading templates...")
                } else if let errorMessage, templates.isEmpty {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { reload() }
                    }
                } else if templates.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Templates Found",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search term.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(templates) { template in
                                NavigationLink(value: template.id) {
                                    MarketplaceTemplateRow(
                                        template: template,
                                        isInstalled: installedIds.contains(template.id)
                                    )
                                }
                                .reportConcern(
                                    contentType: .communityTemplate,
                                    content: template.name + ": " + (template.description ?? "")
                                )
                                .onAppear {
                                    if template.id == templates.last?.id && hasMore && !isLoading {
                                        Task { await loadTemplates(reset: false) }
                                    }
                                }
                            }
                            .listRowBackground(Palette.boxBg)

                            if isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Palette.previewPaneBg)
            .navigationTitle("Template Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { templateId in
                if let template = templates.first(where: { $0.id == templateId }) {
                    MarketplaceTemplateDetailView(
                        template: template,
                        isInstalled: installedIds.contains(template.id),
                        onInstall: { installedIds.insert($0) }
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            Text("Popular").tag(TemplateMarketplaceClient.SortOrder.popular)
                            Text("Recent").tag(TemplateMarketplaceClient.SortOrder.recent)
                            Text("Name").tag(TemplateMarketplaceClient.SortOrder.name)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .onChange(of: searchText) { _, _ in
                loadTask?.cancel()
                loadTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await loadTemplates(reset: true)
                }
            }
            .onChange(of: sortOrder) { _, _ in
                reload()
            }
            .task {
                refreshInstalledIds()
                await loadTemplates(reset: true)
            }
            .dismissKeyboardOnTap()
        }
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await loadTemplates(reset: true) }
    }

    private func loadTemplates(reset: Bool) async {
        if reset { offset = 0 }
        isLoading = true
        errorMessage = nil

        do {
            let response = try await TemplateMarketplaceClient.shared.listTemplates(
                sort: sortOrder,
                search: searchText.isEmpty ? nil : searchText,
                limit: pageSize,
                offset: offset
            )
            guard !Task.isCancelled else {
                isLoading = false
                return
            }
            if reset {
                templates = response.templates
            } else {
                templates.append(contentsOf: response.templates)
            }
            hasMore = response.pagination.has_more
            offset = templates.count
        } catch {
            guard !Task.isCancelled else {
                isLoading = false
                return
            }
            errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
        }

        isLoading = false
    }

    private func refreshInstalledIds() {
        installedIds = Set(store.visibleTemplates.map(\.id))
    }
}
