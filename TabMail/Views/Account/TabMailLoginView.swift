/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct TabMailLoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(NavigationStore.self) private var navigationStore
    @State private var loginState: LoginState = .providers
    @State private var activeProvider: String?
    @State private var errorMessage: String?
    @State private var email: String = ""
    @State private var otpCode: String = ""
    /// Demo Mode store — drives "Try the demo" button visibility/state.
    @Bindable private var demoStore = DemoModeStore.shared
    var onSignedIn: () -> Void

    private let authService = TabMailAuthService()
    /// OAuthService accessed lazily — it's an async computed property on the actor.
    /// All uses are in async contexts (Task blocks) so await is fine.
    private func getOAuthService() async -> OAuthService {
        await AccountManager.shared.oauthService
    }

    private enum LoginState: Equatable {
        case providers
        case emailEntry
        case otpEntry(email: String)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer()
                    .frame(height: 60)

                Image("TabMailLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)

                Text("Tap, Talk, Send")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Spacer()
                    .frame(height: 20)

                switch loginState {
                case .providers:
                    providersView
                case .emailEntry:
                    emailEntryView
                case .otpEntry(let otpEmail):
                    otpEntryView(email: otpEmail)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(Theme.errorFg)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()
                    .frame(height: 40)
            }
            .frame(maxWidth: .infinity, minHeight: (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800)
        }
        .background(Palette.previewPaneBg)
    }

    // MARK: - Providers View

    private var providersView: some View {
        VStack(spacing: 12) {
            // Try the demo — top of the stack so a brand-new visitor sees
            // the "no account needed" path first. Brand purple (matches the
            // brand logo gradient).
            // Hidden after the user adds first real account.
            // Demo entry shown only when user has no email/calendar accounts.
            // Reactive on `navigationStore.hasAnyAccount` (replaces the old
            // sticky `demo.servedItsPurpose` UserDefault — state-based instead
            // of flag-based, so deleting all accounts cleanly restores demo).
            if !navigationStore.hasAnyAccount {
                ProviderButton(
                    label: "Try without Signing In",
                    systemIcon: "eye.fill",
                    foreground: Theme.accent,
                    background: Theme.accent.opacity(0.12),
                    borderColor: Theme.accent.opacity(0.5),
                    isLoading: demoStore.startInProgress,
                    disabled: activeProvider != nil || demoStore.startInProgress
                ) {
                    Task {
                        do {
                            try await DemoModeService.shared.start()
                            // Demo branch in RootView takes over from here.
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }

                HStack {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                }
                .padding(.vertical, 4)
            }

            // Apple — per Apple HIG: black bg / white text in light, white bg / black text in dark
            ProviderButton(
                label: "Sign in with Apple",
                systemIcon: "apple.logo",
                foreground: colorScheme == .dark ? .black : .white,
                background: colorScheme == .dark ? .white : .black,
                isLoading: activeProvider == "apple",
                disabled: activeProvider != nil
            ) {
                signIn(with: .apple)
            }

            // Google — light: white bg, dark text, gray border. dark: #131314 bg, light text
            ProviderButton(
                label: "Sign in with Google",
                assetIcon: "GoogleLogo",
                foreground: colorScheme == .dark ? Color(hex: 0xE3E3E3) : Color(hex: 0x1F1F1F),
                background: colorScheme == .dark ? Color(hex: 0x131314) : .white,
                borderColor: colorScheme == .dark ? Color(hex: 0x8E918F) : Color(hex: 0x747775),
                isLoading: activeProvider == "google",
                disabled: activeProvider != nil
            ) {
                signIn(with: .google)
            }

            // Microsoft — light: #2f2f2f bg, white text. dark: white bg, #2f2f2f text
            ProviderButton(
                label: "Sign in with Microsoft",
                assetIcon: "MicrosoftLogo",
                foreground: colorScheme == .dark ? Color(hex: 0x2F2F2F) : .white,
                background: colorScheme == .dark ? .white : Color(hex: 0x2F2F2F),
                isLoading: activeProvider == "microsoft",
                disabled: activeProvider != nil
            ) {
                signIn(with: .microsoft)
            }

            // Divider
            HStack {
                Rectangle().fill(Color(.separator)).frame(height: 1)
                Text("or")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle().fill(Color(.separator)).frame(height: 1)
            }
            .padding(.vertical, 4)

            // Email — accent color works in both modes, 16px per web
            ProviderButton(
                label: "Sign in with Email",
                systemIcon: "envelope.fill",
                foreground: .white,
                background: Theme.accent,
                isLoading: false,
                disabled: activeProvider != nil
            ) {
                withAnimation { loginState = .emailEntry }
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Email Entry View

    private var emailEntryView: some View {
        VStack(spacing: 16) {
            Text("Enter your email")
                .font(.headline)

            TextField("email@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                sendOTP()
            } label: {
                HStack {
                    if activeProvider == "email_sending" {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(activeProvider == "email_sending" ? "Sending code..." : "Send verification code")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(.white)
                .background(email.contains("@") ? Theme.accent : Theme.accent.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .disabled(!email.contains("@") || activeProvider != nil)

            Button("Back to sign in options") {
                withAnimation {
                    loginState = .providers
                    errorMessage = nil
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - OTP Entry View

    private func otpEntryView(email: String) -> some View {
        VStack(spacing: 16) {
            Text("Check your email")
                .font(.headline)

            Text("We sent a code to\n**\(email)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Enter code", text: $otpCode)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .padding()
                .background(colorScheme == .dark ? Color(.systemGray5) : Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                verifyOTP(email: email)
            } label: {
                HStack {
                    if activeProvider == "email_verifying" {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(activeProvider == "email_verifying" ? "Verifying..." : "Verify code")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(.white)
                .background(otpCode.count >= 6 ? Theme.accent : Theme.accent.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .disabled(otpCode.count < 6 || activeProvider != nil)

            HStack(spacing: 16) {
                Button("Resend code") {
                    resendOTP(email: email)
                }
                Text("·").foregroundStyle(.secondary)
                Button("Use different email") {
                    withAnimation {
                        loginState = .emailEntry
                        otpCode = ""
                        errorMessage = nil
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Back to sign in options") {
                withAnimation {
                    loginState = .providers
                    otpCode = ""
                    self.email = ""
                    errorMessage = nil
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func signIn(with provider: TabMailProvider) {
        activeProvider = provider.rawValue == "azure" ? "microsoft" : provider.rawValue
        errorMessage = nil
        Task {
            do {
                switch provider {
                case .google:
                    try await signInGoogle()
                case .microsoft:
                    try await signInMicrosoft()
                case .apple:
                    let session = try await authService.signInWithProvider(provider)
                    // If the Apple ID's email is on an iCloud-managed
                    // domain (or an Apple private relay), stage the
                    // iCloud consent gate so the user is asked to set
                    // up iCloud Mail/Calendar before the inbox loads
                    // — instead of seeing the prompt only as a sheet
                    // over an empty inbox after onboarding.
                    if ICloudConfig.isAppleDomain(session.userEmail),
                       !UserDefaults.standard.bool(forKey: "icloud_setup_prompted") {
                        PendingAccountAdd.shared.pending = .init(
                            provider: .icloud,
                            email: session.userEmail
                        )
                    }
                    onSignedIn()
                }
            } catch is CancellationError {
                // User cancelled
            } catch let nsError as NSError where nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                // ASWebAuthenticationSession cancelled (code 1)
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Sign in failed: \(error.userFacingDescription)"
            }
            activeProvider = nil
        }
    }

    /// Split Google sign-in: first OAuth requests identity scopes only
    /// (`openid email profile`) so the user sees a small "TabMail wants
    /// to know who you are" dialog. Mail/Calendar scopes are NEVER
    /// requested here — they're only asked for if the user later taps
    /// **Connect** on `AddAccountGmailOutlookView`, which triggers the
    /// full-scope OAuth via `RootView.commitPendingAccountAdd`.
    private func signInGoogle() async throws {
        // Phase 1: Identity-only OAuth (no Gmail / Calendar scopes).
        let identityTokens = try await getOAuthService().authenticateGoogleIdentityOnly()

        guard let idToken = identityTokens.idToken else {
            throw TabMailAuthError.noSession
        }

        // Phase 2: Exchange id_token for Supabase session.
        let _ = try await authService.signInWithIdToken(provider: .google, idToken: idToken)

        // Phase 3: Stage the account-add for `AddAccountGmailOutlookView`.
        // The mail-scope OAuth runs only when the user taps Connect.
        // If user-info fetch fails the gate is skipped — user will
        // land on AddAccountGeneralView and can add manually.
        do {
            let userInfo = try await getOAuthService().fetchGoogleUserInfo(accessToken: identityTokens.accessToken)
            PendingAccountAdd.shared.pending = .init(
                provider: .gmail,
                email: userInfo.email
            )
        } catch {
            print("[Login] Gmail userInfo fetch failed (user will see AddAccountGeneralView): \(error)")
        }

        onSignedIn()
    }

    /// Split Microsoft sign-in — same pattern as Google. First OAuth
    /// is `User.Read openid profile email` only; mail scopes are only
    /// requested on Connect from the gate.
    private func signInMicrosoft() async throws {
        // Phase 1: Identity-only OAuth (no Mail / Calendar scopes).
        let identityTokens = try await getOAuthService().authenticateMicrosoftIdentityOnly()

        guard let idToken = identityTokens.idToken else {
            throw TabMailAuthError.noSession
        }

        // Phase 2: Exchange id_token for Supabase session.
        let _ = try await authService.signInWithIdToken(provider: .microsoft, idToken: idToken)

        // Phase 3: Stage the account-add for the consent gate.
        do {
            let userInfo = try await getOAuthService().fetchMicrosoftUserInfo(accessToken: identityTokens.accessToken)
            PendingAccountAdd.shared.pending = .init(
                provider: .outlook,
                email: userInfo.email
            )
        } catch {
            print("[Login] Outlook userInfo fetch failed (user will see AddAccountGeneralView): \(error)")
        }

        onSignedIn()
    }

    private func sendOTP() {
        activeProvider = "email_sending"
        errorMessage = nil
        let emailToSend = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await authService.sendEmailOTP(email: emailToSend)
                withAnimation {
                    loginState = .otpEntry(email: emailToSend)
                }
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
            }
            activeProvider = nil
        }
    }

    private func verifyOTP(email: String) {
        activeProvider = "email_verifying"
        errorMessage = nil
        Task {
            do {
                let _ = try await authService.verifyEmailOTP(email: email, code: otpCode)
                onSignedIn()
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
            }
            activeProvider = nil
        }
    }

    private func resendOTP(email: String) {
        errorMessage = nil
        Task {
            do {
                try await authService.sendEmailOTP(email: email)
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : error.userFacingDescription
            }
        }
    }
}

// MARK: - ProviderButton

private struct ProviderButton: View {
    let label: String
    var systemIcon: String?
    var assetIcon: String?
    let foreground: Color
    let background: Color
    var borderColor: Color?
    var fontSize: CGFloat = 19
    let isLoading: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(foreground)
                        .frame(width: 20, height: 20)
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 18))
                        .frame(width: 20, height: 20)
                        .offset(y: -1)
                } else if let assetIcon {
                    Image(assetIcon)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Text(label)
                    .font(.system(size: fontSize, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor ?? .clear, lineWidth: borderColor != nil ? 1 : 0)
            )
        }
        .disabled(disabled)
        .opacity(disabled && !isLoading ? 0.5 : 1)
    }
}
