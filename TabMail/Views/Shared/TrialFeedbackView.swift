/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct InboxTrialFeedback: View {
    let isInbox: Bool
    let isDemo: Bool
    let hasSession: Bool
    @State private var presented = false
    private let prompt = TrialFeedbackPromptState.shared

    private var eligible: Bool {
        let gate = AISubscriptionGate.shared
        return isInbox && !isDemo && hasSession && gate.lastAuthoritativeApplyAt != nil
            && gate.trialHasEnded && !gate.isActive && !prompt.isSuppressed && !prompt.deferredThisRun
    }

    var body: some View {
        Group {
            if eligible {
                Button { presented = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Help improve TabMail").font(.caption.weight(.semibold))
                            Text("What's keeping you from subscribing?").font(.caption2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("Feedback").font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .foregroundStyle(Palette.accentColor)
                    .frame(maxWidth: .infinity)
                    .background(Palette.accentColor.opacity(0.06))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox-trial-feedback")
                .accessibilityHint("Opens an optional feedback form")
            }
        }
        .sheet(isPresented: $presented, onDismiss: {
            if !prompt.isSuppressed { prompt.notNow() }
        }) {
            TrialFeedbackForm(flow: TrialFeedbackFlow(prompt: prompt))
        }
        .onChange(of: eligible) { _, canInvite in
            if !canInvite, !prompt.isSuppressed { presented = false }
        }
    }
}

struct TrialFeedbackForm: View {
    @State var flow: TrialFeedbackFlow
    @State private var submissionRequested = false
    @Environment(\.dismiss) private var dismiss

    private func select(_ reason: TrialFeedbackReason) {
        guard !submissionRequested, !flow.isSubmitting else { return }
        flow.selectedReason = reason
    }

    private func requestSubmission() {
        guard !submissionRequested, flow.canSubmit else { return }
        submissionRequested = true
    }

    private func leave() {
        if !flow.isComplete { flow.prompt.notNow() }
        dismiss()
    }

    private func decline() {
        flow.prompt.doNotAskAgain()
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                if flow.isComplete {
                    Section {
                        Label("Thanks for your feedback", systemImage: "checkmark.circle")
                            .foregroundStyle(Palette.accentColor)
                        Button("Done") { dismiss() }
                    }
                } else {
                    Section("What's the main reason you haven't subscribed?") {
                        ForEach(TrialFeedbackReason.allCases) { reason in
                            Button {
                                select(reason)
                            } label: {
                                HStack {
                                    Text(reason.label).foregroundStyle(Palette.textColor)
                                    Spacer(minLength: 8)
                                    Image(systemName: flow.selectedReason == reason ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(Palette.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(flow.isSubmitting || submissionRequested)
                            .accessibilityAddTraits(flow.selectedReason == reason ? .isSelected : [])
                            .accessibilityIdentifier("trial-feedback-reason-\(reason.rawValue)")
                        }
                    }
                    Section {
                        Text("Optional feedback to help improve TabMail. We send your selected reason without attaching your TabMail account, email or a device identifier. We keep answer totals.")
                        Text("Cloudflare processes network information such as your IP address to deliver and protect this request.")
                        Link("Privacy Policy", destination: URL(string: "https://tabmail.ai/privacy")!)
                    }
                    .font(.footnote)
                    if let error = flow.errorText {
                        Section { Text(error).foregroundStyle(Palette.textMuted) }
                    }
                    Section {
                        Button(action: requestSubmission) {
                            HStack {
                                Text("Submit feedback")
                                if flow.isSubmitting { ProgressView() }
                            }
                        }
                        .disabled(!flow.canSubmit || submissionRequested)
                        .accessibilityIdentifier("trial-feedback-submit")
                        Button("Don't ask again", action: decline)
                            .accessibilityIdentifier("trial-feedback-decline")
                    }
                }
            }
            .tint(Palette.accentColor)
            .navigationTitle("Help improve TabMail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.isComplete ? "Close" : "Not now", action: leave)
                        .accessibilityIdentifier("trial-feedback-not-now")
                }
            }
        }
        .task(id: submissionRequested) {
            guard submissionRequested else { return }
            await flow.submit()
            guard !Task.isCancelled else { return }
            submissionRequested = false
        }
    }
}
