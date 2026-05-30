/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct TemplateDetailView: View {
    let templateId: String
    @State private var store = PromptStore.shared
    @State private var newInstruction = ""
    @State private var isSharing = false
    @State private var didShare = false
    @State private var shareResult: String?
    @State private var shareError: String?
    @FocusState private var instructionFieldFocused: Bool

    private var templateBinding: Binding<ReplyTemplate> {
        Binding(
            get: { store.templates.first { $0.id == templateId } ?? ReplyTemplate() },
            set: { store.updateTemplate($0) }
        )
    }

    var body: some View {
        Form {
            Group {
            Section("Name") {
                TextField("Template name", text: templateBinding.name)
            }

            Section {
                Toggle("Enabled", isOn: templateBinding.enabled)
            }

            Section {
                ForEach(Array(templateBinding.wrappedValue.instructions.enumerated()), id: \.offset) { index, instruction in
                    Text(instruction)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                var updated = templateBinding.wrappedValue
                                updated.instructions.remove(at: index)
                                store.updateTemplate(updated)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }

                HStack {
                    TextField("Add instruction...", text: $newInstruction)
                        .focused($instructionFieldFocused)
                        .onSubmit {
                            addInstruction()
                        }
                    Button {
                        addInstruction()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .disabled(newInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Instructions")
            } footer: {
                Text("Rules the AI follows when using this template. Swipe to delete.")
            }

            Section {
                TextEditor(text: templateBinding.exampleReply)
                    .frame(minHeight: 120)
                    .scrollDisabled(true)
            } header: {
                Text("Example Reply")
            } footer: {
                Text("An example of what a reply using this template should look like. Use placeholders like [sender's first name].")
            }
            Section {
                Button {
                    Task { await shareTemplate() }
                } label: {
                    HStack {
                        if isSharing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text("Share to Marketplace")
                    }
                }
                .disabled(isSharing || didShare || templateBinding.wrappedValue.name.isEmpty || templateBinding.wrappedValue.instructions.isEmpty)

                if let shareResult {
                    Text(shareResult)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let shareError {
                    Text(shareError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Share this template with the community. It will be reviewed before appearing in the marketplace.")
            }
            }
            .listRowBackground(Palette.boxBg)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.previewPaneBg)
        .navigationTitle(templateBinding.wrappedValue.name)
        .navigationBarTitleDisplayMode(.inline)
        .dismissKeyboardOnTap()
    }

    @MainActor
    private func shareTemplate() async {
        guard !isSharing else { return }
        isSharing = true
        shareResult = nil
        shareError = nil

        do {
            let template = templateBinding.wrappedValue
            let response = try await TemplateMarketplaceClient.shared.uploadTemplate(template)
            shareResult = response.message
            didShare = true
        } catch {
            shareError = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.localizedDescription
        }

        isSharing = false
    }

    private func addInstruction() {
        let text = newInstruction.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var updated = templateBinding.wrappedValue
        updated.instructions.append(text)
        store.updateTemplate(updated)
        newInstruction = ""
        instructionFieldFocused = true
    }
}
