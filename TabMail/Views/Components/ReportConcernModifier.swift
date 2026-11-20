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
                        popoverRow("Report Concern", systemImage: "exclamationmark.bubble")
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)

                    if let extraAction {
                        Divider()
                        Button {
                            showPopover = false
                            extraAction.action()
                        } label: {
                            popoverRow(extraAction.title, systemImage: extraAction.systemImage)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, Self.popoverVerticalInset)
                .frame(minWidth: 220)
                .presentationCompactAdaptation(.popover)
            }
            .reportConcernSheet(isPresented: $showSheet, contentType: contentType, content: { content })
    }

    // MARK: - Popover rows

    /// Outer breathing room above the first row and below the last one.
    private static let popoverVerticalInset: CGFloat = 6
    /// Per-row padding; two rows plus the divider need more air than the old
    /// single-entry popover had.
    private static let popoverRowVerticalPadding: CGFloat = 10
    private static let popoverRowHorizontalPadding: CGFloat = 14
    /// Fixed icon column so titles line up regardless of each SF Symbol's
    /// intrinsic width (an eye is wider than a speech bubble).
    private static let popoverIconWidth: CGFloat = 24

    /// One popover entry: fixed-width icon column + title, so multiple rows
    /// share the same text x-origin and the same height.
    private func popoverRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: Self.popoverIconWidth, alignment: .center)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.body)
        .padding(.horizontal, Self.popoverRowHorizontalPadding)
        .padding(.vertical, Self.popoverRowVerticalPadding)
        .contentShape(Rectangle())
    }
}

/// The lines under the report form: an optional line saying what the report sends, then consent.
enum ReportConcernSheetText {
    static let storedForReview = "The reported content will be stored on TabMail's servers for review by our team. By submitting, you consent to this."

    static func consentLines(contentNotice: String?) -> [String] {
        (contentNotice.map { [$0] } ?? []) + [storedForReview]
    }
}

/// Sends one report: its type, content, category and optional reason; true once the backend took it.
typealias ReportConcernSend = @MainActor (ReportContentType, String, ReportCategory, String?) async -> Bool

/// Which presentation of a report sheet is current. A send's answer acts only for the
/// presentation that sent it: one that ended (dismissed, or its owner removed) is retired, and a
/// new one starts afresh, so a late answer never closes, finishes or confirms a later report.
@MainActor
final class ReportPresentation {
    private(set) var current = 0

    func next() { current += 1 }
}

/// The report sheet, presented by `isPresented`: category, optional reason, Report. Shared by the
/// long-press flow and any other entry point that reports AI content.
struct ReportConcernSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let contentType: ReportContentType
    /// Read when the report is sent.
    let content: () -> String
    /// An extra line saying what the report sends, when that is more than the pressed content.
    let contentNotice: String?
    let send: ReportConcernSend
    /// Called once the report is done: the sheet closed with nothing more to show, or the
    /// Submitted alert was dismissed.
    var onFinish: (() -> Void)?

    @State private var showSubmitted = false
    /// The backend took the report: "Report Submitted" shows once the sheet has gone.
    @State private var submitted = false
    @State private var selectedCategory: ReportCategory = .offensive
    @State private var reason = ""
    @State private var isSubmitting = false
    /// Set by a caller whose `isPresented` flag outlives the view this sheet is attached to (the
    /// notice's flag lives on its button, the sheet on the popover's content): the caller then
    /// owns the presentation too and retires it when the sheet's view goes. Otherwise the sheet
    /// owns it, with the same lifetime as its flag.
    var ownerPresentation: ReportPresentation?

    @State private var ownPresentation = ReportPresentation()

    private var presentation: ReportPresentation { ownerPresentation ?? ownPresentation }

    func body(content view: Content) -> some View {
        view
            .onChange(of: isPresented) { _, shows in
                // A new presentation starts with its own state.
                guard shows else { return }
                presentation.next()
                submitted = false
                isSubmitting = false
                selectedCategory = .offensive
                reason = ""
            }
            .sheet(isPresented: $isPresented, onDismiss: {
                // This presentation has ended: an answer still on its way acts on nothing.
                presentation.next()
                // The alert waits until the sheet has gone: UIKit refuses to present it while the
                // sheet is still closing.
                if submitted {
                    submitted = false
                    showSubmitted = true
                } else {
                    // Cancel, a swipe down, or a report the backend did not take.
                    onFinish?()
                }
            }) {
                reportSheet
            }
            .alert("Report Submitted", isPresented: $showSubmitted) {
                Button("OK", role: .cancel) { onFinish?() }
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
                    ForEach(ReportConcernSheetText.consentLines(contentNotice: contentNotice), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Report Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    // While the report is sending, the sheet stays, as it does for a swipe down:
                    // a reply after the sheet had gone would have no sheet to show its result.
                    .disabled(isSubmitting)
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
        let sending = presentation
        let sentFor = sending.current
        Task {
            let success = await send(contentType, content(), selectedCategory, reason.isEmpty ? nil : reason)
            // The presentation that sent this has ended: its answer touches nothing, not even
            // the caller's binding, which may now show a later report.
            guard sending.current == sentFor else { return }
            isSubmitting = false
            submitted = success
            isPresented = false
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

    func reportConcernSheet(
        isPresented: Binding<Bool>,
        contentType: ReportContentType,
        content: @escaping () -> String,
        contentNotice: String? = nil,
        send: @escaping ReportConcernSend = ReportConcernService.sendReport,
        onFinish: (() -> Void)? = nil,
        presentation: ReportPresentation? = nil
    ) -> some View {
        modifier(ReportConcernSheetModifier(isPresented: isPresented, contentType: contentType,
                                            content: content, contentNotice: contentNotice, send: send,
                                            onFinish: onFinish, ownerPresentation: presentation))
    }
}
