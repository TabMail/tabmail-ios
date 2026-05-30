/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Consent gate shown before first use — requires age confirmation (18+) and
/// agreement to Terms of Service and Privacy Policy. Matches the web consent flow
/// (`consent.js`) and Thunderbird addon consent behavior.
struct ConsentGateView: View {
    /// When true (default), submit() writes consent metadata to Supabase via
    /// `TabMailAuthService.updateUserMetadata`. Set to false from demo mode —
    /// the demo session has no Supabase user, so
    /// the metadata write would 401 with "Invalid session data". The parent
    /// owns demo-prefixed flag persistence in that case.
    var persistsToBackend: Bool = true
    var onComplete: () -> Void

    @State private var confirmedAge = false
    @State private var agreedToTerms = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    /// Legal document version — matches web's `public-config.js` LEGAL_VERSION_ISO
    private let legalVersion = "2026-01-19"

    private var canContinue: Bool {
        confirmedAge && agreedToTerms
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer()
                        .frame(height: 40)

                    Image("TabMailLogo")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)

                    Text("Before You Continue")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)

                    Text("Please confirm the following to use TabMail.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 16) {
                        checkboxRow(
                            isChecked: $confirmedAge,
                            text: "I confirm that I am at least 18 years old"
                        )

                        checkboxRow(
                            isChecked: $agreedToTerms,
                            label: {
                                Text("I agree to the [Terms of Service](https://tabmail.ai/terms) and [Privacy Policy](https://tabmail.ai/privacy)")
                            }
                        )
                    }
                    .padding(.top, 8)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                Button {
                    submit()
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Continue")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canContinue ? Theme.accent : Theme.accent.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canContinue || isSubmitting)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .padding(.top, 16)
        }
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }

    // MARK: - Checkbox Rows

    @ViewBuilder
    private func checkboxRow(isChecked: Binding<Bool>, text: String) -> some View {
        Button {
            isChecked.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked.wrappedValue ? Theme.accent : Theme.textSecondary)
                    .font(.title3)

                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func checkboxRow(isChecked: Binding<Bool>, @ViewBuilder label: () -> Text) -> some View {
        Button {
            isChecked.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked.wrappedValue ? Theme.accent : Theme.textSecondary)
                    .font(.title3)

                label()
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .tint(Theme.accent)

                Spacer()
            }
        }
    }

    // MARK: - Submit

    private func submit() {
        guard canContinue, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        if !persistsToBackend {
            onComplete()
            return
        }

        let timestamp = Date().iso8601String()

        Task {
            do {
                try await TabMailAuthService.updateUserMetadata([
                    "confirmed_age_18": true,
                    "confirmed_age_min_years": 18,
                    "confirmed_age_at": timestamp,
                    "agreed_to_terms": true,
                    "agreed_to_terms_version": legalVersion,
                    "agreed_to_terms_at": timestamp,
                    "agreed_to_privacy": true,
                    "agreed_to_privacy_version": legalVersion,
                    "agreed_to_privacy_at": timestamp,
                    "consent_source": "ios/consent",
                ])

                // Force-refresh token so backend JWT has updated user_metadata claims
                let refreshResult = await TabMailTokenCoordinator.shared.forceRefresh()
                switch refreshResult {
                case .success:
                    print("[ConsentGate] Token refreshed with updated consent metadata")
                case .permanentFailure, .noSession:
                    print("[ConsentGate] Token refresh failed permanently — consent saved but token stale")
                case .transientFailure:
                    print("[ConsentGate] Token refresh transient failure — consent saved, will refresh on next call")
                }

                await MainActor.run {
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Failed to save consent: \(error.userFacingDescription)"
                }
            }
        }
    }
}
