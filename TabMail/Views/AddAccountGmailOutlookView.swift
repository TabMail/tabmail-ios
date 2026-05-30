/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// First-launch email-account consent screen for Gmail and Outlook.
///
/// Shown after the TabMail sign-in completes and we know which email
/// address (and provider) the user signed in with — but BEFORE we kick
/// off the OAuth flow that requests mail scopes. Replaces the previous
/// behaviour where Gmail/Outlook scopes were requested silently in the
/// same OAuth popup as the auth scopes, then the inbox appeared with
/// no warning.
///
/// Scope: only Gmail and Outlook. iCloud has its own dedicated gate
/// (`AddAccountICloudView`) that handles the app-specific password
/// flow; Apple-OTP and email-OTP users land directly on
/// `AddAccountGeneralView` since nothing is auto-added in those paths.
///
/// Layout (top → bottom): provider logo, "Connect your <Provider>"
/// title, subtitle copy, suggested-account chip, notes bullets,
/// **Connect** / **Later** buttons. The caller marks the gate as
/// seen regardless of which button was tapped so the screen does not
/// reappear on the next launch.
struct AddAccountGmailOutlookView: View {
    /// Providers supported by this gate. Intentionally narrower than
    /// `AccountProvider` — see the file header for why iCloud / IMAP
    /// are excluded.
    enum Provider {
        case gmail
        case outlook

        var displayName: String {
            switch self {
            case .gmail: return "Gmail"
            case .outlook: return "Outlook"
            }
        }
    }

    /// Provider that will be connected. Drives the icon and copy.
    let provider: Provider
    /// Email address that will be added — shown verbatim to the user so
    /// they can verify which account is about to be connected.
    let email: String
    /// Called when the user taps **Connect**. The caller runs the
    /// provider OAuth scope-grant flow and creates the account. May
    /// throw — the view will catch and display the error inline so
    /// the user stays on this gate instead of being silently routed
    /// to the general add-account screen on failure. (Only **Later**
    /// should route them out of this gate.)
    var onConnect: () async throws -> Void
    /// Called when the user taps **Later**. The caller skips the
    /// account-add step; the user can add accounts from settings.
    var onLater: () -> Void

    @State private var isProceeding = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 32)

                providerLogo
                    .frame(width: 80, height: 80)

                Text("Connect your \(provider.displayName)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("TabMail will fetch and send mail using your \(provider.displayName) account. You can always connect it later from Email Accounts.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                accountChip
                    .padding(.top, 4)

                bullets
                    .padding(.top, 4)

                Spacer().frame(height: 8)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.errorFg)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    isProceeding = true
                    errorMessage = nil
                    Task {
                        do {
                            try await onConnect()
                            // Success: parent clears PendingAccountAdd
                            // and the gate is dismissed in the next
                            // render — nothing more to do here.
                        } catch {
                            switch ConnectErrorClassifier.classify(error) {
                            case .silentRetry:
                                break
                            case .showError(let message):
                                errorMessage = message
                            }
                        }
                        isProceeding = false
                    }
                } label: {
                    Group {
                        if isProceeding {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isProceeding)

                Button {
                    onLater()
                } label: {
                    Text("No Thanks")
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                .disabled(isProceeding)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }

    // MARK: - Provider logo (centered, top of screen)

    @ViewBuilder
    private var providerLogo: some View {
        switch provider {
        case .gmail:
            Image("GoogleLogo").renderingMode(.original).resizable().scaledToFit()
        case .outlook:
            Image("MicrosoftLogo").renderingMode(.original).resizable().scaledToFit()
        }
    }

    // MARK: - Account chip (which account is being added)

    private var accountChip: some View {
        HStack(spacing: 12) {
            providerLogo
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(email)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .font(.title3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.buttonBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Privacy / scope bullets

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("**On-device:** mail is stored locally on your phone — never on our servers.")
            } icon: {
                Image(systemName: "iphone")
            }
            Label {
                Text("**Read & send:** TabMail uses standard mail APIs to fetch headers, bodies, and send replies you compose.")
            } icon: {
                Image(systemName: "envelope")
            }
            Label {
                Text("**Revocable:** disconnect any time from Email Accounts; tokens are discarded immediately.")
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textSecondary)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Theme.accent)
    }
}
