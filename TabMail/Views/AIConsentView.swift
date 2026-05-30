/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// First-launch AI consent dialog (Apple Guideline 5.1.2(i)).
/// Shown once after account setup, before the mail UI appears.
/// If the user declines, sets `privacy_opt_out_all_ai = true` which
/// gates all LLM backend calls while keeping core email functionality.
struct AIConsentView: View {
    /// Called when the user makes a choice. `true` = AI enabled, `false` = AI declined.
    var onComplete: (_ aiEnabled: Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer()
                    .frame(height: 40)

                Image("TabMailLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)

                Text("AI Features")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.textPrimary)

                Text("TabMail uses AI to summarize emails, classify messages, and suggest replies.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text("**Data sent:** email subject, body, sender, and calendar events. When using the AI chat assistant, contact names may also be included as context.")
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    Label {
                        Text("**Sent to:** our server at tabmail.ai, which forwards to third-party AI providers **Groq** and **OpenRouter** for processing.")
                    } icon: {
                        Image(systemName: "arrow.right.circle")
                    }
                    Label {
                        Text("**Zero retention:** your data is processed transiently and never stored at rest on our servers or by AI providers.")
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                    }
                    Label {
                        Text("**Not used for training:** your data is never used to train AI models.")
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)

                Link("Privacy Policy", destination: URL(string: "https://tabmail.ai/privacy")!)
                    .font(.subheadline)

                Spacer()
                    .frame(height: 16)

                Button {
                    // Caller decides where to persist the choice. Production
                    // RootView writes `AIService.optOutAllAIKey = false` in
                    // its onComplete; demo RootView writes `demo.aiEnabled = true`
                    // and leaves the production opt-out flag untouched.
                    onComplete(true)
                } label: {
                    Text("Enable AI Features")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    onComplete(false)
                } label: {
                    Text("No Thanks")
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 4)

                Text("You can change this anytime in Settings.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }
}
