/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// The state behind the trial-feedback sheet; its buttons and field call
/// these, and nothing else writes it.
@MainActor
@Observable
final class TrialFeedbackForm {
    private(set) var selected: TrialFeedback.Reason?
    private(set) var comment = ""
    private(set) var isSent = false

    var canSend: Bool { selected != nil && !isSent }

    private let deliver: @Sendable (TrialFeedback.Reason, String) async -> Void

    init(deliver: @escaping @Sendable (TrialFeedback.Reason, String) async -> Void = { reason, comment in
        await TrialFeedback.send(reason, comment: comment)
    }) {
        self.deliver = deliver
    }

    func select(_ reason: TrialFeedback.Reason) {
        selected = reason
    }

    /// An edit of the comment field. One that would pass the cap is refused
    /// whole (the comment keeps its previous text, never cut); returns
    /// whether it was taken.
    @discardableResult
    func edit(_ proposed: String) -> Bool {
        guard TrialFeedback.fits(proposed) else { return false }
        comment = proposed
        return true
    }

    /// Send the answer once, in the background; a second call sends nothing.
    /// The returned task lets a caller wait for the send.
    @discardableResult
    func send() -> Task<Void, Never>? {
        guard let reason = selected, !isSent else { return nil }
        isSent = true
        let text = comment
        let deliver = deliver
        return Task { await deliver(reason, text) }
    }
}

/// The one-time trial-feedback sheet: the five choices with a checkmark on
/// the picked one, an optional comment, "Not now" and "Send".
struct TrialFeedbackSheet: View {
    @State private var form: TrialFeedbackForm
    /// What the field shows. A refused edit puts the previous text back here,
    /// a real change of this state, so the text view redraws: a binding whose
    /// setter only refuses leaves the refused text on screen while Send sends
    /// the older value.
    @State private var fieldText = ""
    @AppStorage(TrialFeedback.sentKey) private var sent = false
    @Environment(\.dismiss) private var dismiss

    init(form: TrialFeedbackForm) {
        _form = State(initialValue: form)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TrialFeedback.Reason.allCases) { reason in
                        choice(reason)
                    }
                } header: {
                    Text(TrialFeedback.question)
                        .textCase(nil)
                } footer: {
                    // Right under the choices, so it shows at the medium detent before Send.
                    Text(TrialFeedback.footnote)
                }
                Section {
                    TextField(TrialFeedback.commentPlaceholder, text: $fieldText, axis: .vertical)
                        .onChange(of: fieldText) { previous, proposed in
                            if !form.edit(proposed) { fieldText = previous }
                        }
                }
            }
            .navigationTitle(TrialFeedback.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TrialFeedback.dismissLabel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(TrialFeedback.sendLabel) {
                        form.send()
                        sent = true
                        dismiss()
                    }
                    .disabled(!form.canSend)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choice(_ reason: TrialFeedback.Reason) -> some View {
        let isSelected = form.selected == reason
        return Button { form.select(reason) } label: {
            HStack {
                Text(reason.label)
                    .foregroundStyle(Palette.textColor)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Whether the trial-feedback sheet is up. One per app: the sheet is hosted
/// once (`trialFeedbackSheetHost()` on `MailNavigationView`), and the inbox's
/// one-time auto-open and both trial-ended banners' Feedback buttons all go
/// through `open()`.
@MainActor
@Observable
final class TrialFeedbackPresentation {
    static let shared = TrialFeedbackPresentation()

    var isPresented = false

    func open() {
        isPresented = true
    }
}

/// Hosts `TrialFeedbackSheet`. It is marked asked when the sheet appears, so
/// after Send, Not now, a swipe down, or the app closing while it is open it
/// never opens by itself again (the banners can still open it).
struct TrialFeedbackSheetHost: ViewModifier {
    let presentation: TrialFeedbackPresentation
    let makeForm: @MainActor () -> TrialFeedbackForm

    @AppStorage(TrialFeedback.askedKey) private var alreadyAsked = false

    func body(content: Content) -> some View {
        @Bindable var presentation = presentation
        content
            .sheet(isPresented: $presentation.isPresented) {
                TrialFeedbackSheet(form: makeForm())
                    .onAppear { alreadyAsked = true }
            }
    }
}

/// Opens the sheet by itself once per install, the first time the inbox
/// appears while the question is due (see `TrialFeedback.shouldPresent`).
struct TrialFeedbackAutoOpen: ViewModifier {
    let isInbox: Bool
    let presentation: TrialFeedbackPresentation
    let isSomethingPresented: @MainActor () -> Bool

    @Environment(\.hasTabMailSession) private var hasTabMailSession
    @AppStorage(TrialFeedback.askedKey) private var alreadyAsked = false

    /// Everything but "something else is presented", which is read only at
    /// the moment of presenting; a change here re-checks.
    private var isDue: Bool {
        TrialFeedback.shouldPresent(
            isInbox: isInbox,
            hasSession: hasTabMailSession,
            isDemo: DemoModeStore.shared.isActive,
            trialState: UsageThrottleStore.shared.trialState,
            alreadyAsked: alreadyAsked,
            somethingPresented: false
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: openIfDue)
            .onChange(of: isDue) { openIfDue() }
    }

    private func openIfDue() {
        guard isDue, !presentation.isPresented, !isSomethingPresented() else { return }
        presentation.open()
    }

    /// Whether the key window already presents something (a sheet or a
    /// full-screen cover from anywhere in the app).
    @MainActor
    static func keyWindowIsPresenting() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .presentedViewController != nil
    }
}

extension View {
    /// Hosts the trial-feedback sheet. Attach once, at the app's mail root.
    func trialFeedbackSheetHost(
        presentation: TrialFeedbackPresentation = .shared,
        makeForm: @escaping @MainActor () -> TrialFeedbackForm = { TrialFeedbackForm() }
    ) -> some View {
        modifier(TrialFeedbackSheetHost(presentation: presentation, makeForm: makeForm))
    }

    /// Opens the trial-feedback sheet by itself once, when this view is the
    /// inbox and the question is due.
    func trialFeedbackAutoOpen(
        isInbox: Bool,
        presentation: TrialFeedbackPresentation = .shared,
        isSomethingPresented: @escaping @MainActor () -> Bool = TrialFeedbackAutoOpen.keyWindowIsPresenting
    ) -> some View {
        modifier(TrialFeedbackAutoOpen(isInbox: isInbox, presentation: presentation, isSomethingPresented: isSomethingPresented))
    }
}
