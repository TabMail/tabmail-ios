/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// An additional entry shown in the long-press popover under "Report Concern"
/// (e.g. "Hide Summary Bubbles" on the AI summary bubble, iOS #153).
struct ReportConcernExtraAction {
    let title: String
    let systemImage: String
    let action: () -> Void
}

/// Adds a long-press "Report Concern" flow to any view displaying
/// AI-generated or community-driven content.
/// Required by App Store Guidelines 1.2, 4.7.1.
///
/// Flow: long-press → popover with Report Concern → tap → report sheet
///
/// Uses `simultaneousGesture` so it works on any view — Buttons, Menu labels,
/// views inside List rows — without conflicting with existing gestures or
/// getting promoted to the List row level.
struct ReportConcernModifier: ViewModifier {
    let contentType: ReportContentType
    let content: String
    let extraAction: ReportConcernExtraAction?

    @State private var showPopover = false
    @State private var showSheet = false
    @State private var showSubmitted = false
    @State private var selectedCategory: ReportCategory = .offensive
    @State private var reason = ""
    @State private var isSubmitting = false

    func body(content view: Content) -> some View {
        view
            .scaleEffect(showPopover ? 1.03 : 1.0)
            .shadow(color: showPopover ? .black.opacity(0.25) : .clear, radius: showPopover ? 16 : 0, y: showPopover ? 8 : 0)
            .simultaneousGesture(LongPressGesture().onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showPopover = true }
            })
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        showPopover = false
                        showSheet = true
                    } label: {
                        Label("Report Concern", systemImage: "exclamationmark.bubble")
                            .font(.body)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)

                    if let extraAction {
                        Divider()
                        Button {
                            showPopover = false
                            extraAction.action()
                        } label: {
                            Label(extraAction.title, systemImage: extraAction.systemImage)
                                .font(.body)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(minWidth: 220)
                .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showSheet) {
                reportSheet
            }
            .alert("Report Submitted", isPresented: $showSubmitted) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Thank you. We'll review this content.")
            }
    }

    private var reportSheet: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(ReportCategory.allCases, id: \.self) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Reason (Optional)") {
                    TextField("Describe the issue...", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Text("The reported content will be stored on TabMail's servers for review by our team. By submitting, you consent to this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Report Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") {
                        submit()
                    }
                    .disabled(isSubmitting)
                    .bold()
                    .foregroundStyle(.red)
                }
            }
            .dismissKeyboardOnTap()
            .interactiveDismissDisabled(isSubmitting)
        }
        .presentationDetents([.fraction(0.8)])
    }

    private func submit() {
        isSubmitting = true
        Task {
            let success = await ReportConcernService.report(
                contentType: contentType,
                content: content,
                category: selectedCategory,
                reason: reason.isEmpty ? nil : reason
            )
            isSubmitting = false
            showSheet = false
            if success {
                showSubmitted = true
            }
            selectedCategory = .offensive
            reason = ""
        }
    }
}

extension View {
    func reportConcern(
        contentType: ReportContentType,
        content: String,
        extraAction: ReportConcernExtraAction? = nil
    ) -> some View {
        modifier(ReportConcernModifier(contentType: contentType, content: content, extraAction: extraAction))
    }
}
