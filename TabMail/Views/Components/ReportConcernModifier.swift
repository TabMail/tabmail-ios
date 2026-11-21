/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

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

/// Which presentation of a report sheet is current. A send's answer closes and finishes only the
/// presentation that sent it: once a later one has opened, or its caller retired it, the answer
/// leaves the caller alone, so it never closes or finishes a later report. Whether a report the
/// backend took says "Report Submitted" does not depend on this (see `ReportConcernSubmission`).
@MainActor
final class ReportPresentation {
    private(set) var current = 0

    func next() { current += 1 }
}

/// A sent report, from Report to its end. The send holds it, not the view that asked for the
/// report: that view (a list row, or the popover that presented the sheet) may be recycled,
/// removed or closed while the report sends. A report the backend took says "Report Submitted"
/// exactly once, after its sheet has gone; a report not taken says nothing.
@MainActor
final class ReportConcernSubmission {
    /// The backend's answer, once it has come.
    private var accepted: Bool?
    /// The sheet that sent the report has left the screen.
    private var sheetGone = false
    private var settled = false
    /// The report is done: OK on "Report Submitted", or a report not taken.
    private let finish: () -> Void

    init(finish: @escaping () -> Void) {
        self.finish = finish
    }

    func answered(_ accepted: Bool) {
        self.accepted = accepted
        settle()
    }

    func sheetLeft() {
        sheetGone = true
        settle()
    }

    /// Acts once the answer has come and the sheet has gone: UIKit refuses an alert while its
    /// presenter is still closing the sheet.
    private func settle() {
        guard !settled, sheetGone, let accepted else { return }
        settled = true
        if accepted {
            ReportConcernConfirmation.show(onOK: finish)
        } else {
            finish()
        }
    }
}

/// "Report Submitted". UIKit presents it from the top of the key window, not SwiftUI from the view
/// that asked for the report: that view may be recycled, removed or closed by the time the answer
/// comes, and an alert attached to it then never shows (as ADR-IOS-045 found for a preview
/// presented from a list row).
@MainActor
enum ReportConcernConfirmation {
    static let title = "Report Submitted"
    static let message = "Thank you. We'll review this content."
    static let ok = "OK"

    /// Shows the confirmation; `onOK` runs when the user dismisses it.
    static func show(onOK: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ok, style: .cancel) { _ in onOK() })
        // On the next turn, so a presentation already asked for in this one (a sheet the user has
        // just opened) starts first, and the alert waits for it below.
        Task { @MainActor in Self.present(alert) }
    }

    /// Presents `alert` from the top of the key window once nothing there is still opening or
    /// closing: UIKit refuses a presentation while another one is moving.
    private static func present(_ alert: UIAlertController) {
        guard let top = topmost() else {
            BackgroundSyncLogger.logDebug("[ReportConcern] no window to show Report Submitted in")
            return
        }
        if let moving = top.transitionCoordinator {
            _ = moving.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in Self.present(alert) }
            }
            return
        }
        BackgroundSyncLogger.logDebug("[ReportConcern] showing Report Submitted from \(type(of: top))")
        top.present(alert, animated: true)
    }

    /// The view controller on top of the key window, whatever the scene's state: an answer that
    /// comes while the app is inactive still shows.
    private static func topmost() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
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
    /// Submitted alert was dismissed. Not called for a report whose caller has since opened a
    /// later one.
    var onFinish: (() -> Void)?
    /// Set by a caller whose `isPresented` flag outlives the view this sheet is attached to (the
    /// notice's flag lives on its button, the sheet on the popover's content): the caller then
    /// owns the presentation too and retires it whenever it opens that view again. Otherwise the sheet
    /// owns it, with the same lifetime as its flag.
    var ownerPresentation: ReportPresentation?

    @State private var ownPresentation = ReportPresentation()

    private var presentation: ReportPresentation { ownerPresentation ?? ownPresentation }

    func body(content view: Content) -> some View {
        view
            .onChange(of: isPresented) { _, shows in
                // A new presentation: an earlier one's answer no longer closes or finishes anything.
                // The form starts afresh with the sheet's own state.
                if shows { presentation.next() }
            }
            .sheet(isPresented: $isPresented) {
                ReportConcernSheet(isPresented: $isPresented, contentType: contentType, content: content,
                                   contentNotice: contentNotice, send: send, onFinish: onFinish,
                                   presentation: presentation)
            }
    }
}

/// What a report sheet's window probe reads when the sheet leaves its window. A reference, so the
/// probe reads the report sent since it was attached, whether or not SwiftUI has updated it since.
@MainActor
private final class ReportSheetLife {
    /// The sheet is in a window, as its probe last saw.
    var inWindow = false
    /// The report this sheet sent, if any. It settles once the sheet has gone.
    var submission: ReportConcernSubmission?
}

/// The form inside the report sheet. Its state, and the report it sends, live with the sheet, not
/// with the view that presents it: that view (a list row) can be recycled or removed while the
/// report sends.
private struct ReportConcernSheet: View {
    @Binding var isPresented: Bool
    let contentType: ReportContentType
    let content: () -> String
    let contentNotice: String?
    let send: ReportConcernSend
    let onFinish: (() -> Void)?
    let presentation: ReportPresentation

    @State private var selectedCategory: ReportCategory = .offensive
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var life = ReportSheetLife()

    var body: some View {
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
        // Says when the sheet has gone, however it went: closed by Cancel, a swipe or the answer,
        // or taken down with the row or popover that presented it, when its onDismiss may not run.
        .background(WindowProbe(onWindow: { [life] in
            life.inWindow = true
        }, onDetach: { [life, onFinish] in
            life.inWindow = false
            // On the next turn, once UIKit has finished closing the sheet. A sheet UIKit only
            // moved to another container is back in a window by then, and has not gone.
            Task { @MainActor in
                guard !life.inWindow else { return }
                if let submission = life.submission {
                    submission.sheetLeft()
                } else {
                    // Cancel, a swipe down, or a sheet closed before anything was sent.
                    onFinish?()
                }
            }
        }))
    }

    private func submit() {
        isSubmitting = true
        let sentFor = presentation.current
        let sending = ReportConcernSubmission { [weak presentation, onFinish] in
            // The caller has opened a later report since, or is gone: this one finishes nothing.
            guard let presentation, presentation.current == sentFor else { return }
            onFinish?()
        }
        life.submission = sending
        Task { [weak presentation] in
            let accepted = await send(contentType, content(), selectedCategory, reason.isEmpty ? nil : reason)
            isSubmitting = false
            // Only the presentation that sent this closes: the caller's flag may now show a later
            // report, or its owner may be gone.
            if let presentation, presentation.current == sentFor {
                isPresented = false
            }
            // Its own answer, whatever happened to the sheet or the view that presented it.
            sending.answered(accepted)
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
