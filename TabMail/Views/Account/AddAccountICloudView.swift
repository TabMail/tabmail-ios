/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// First-launch consent screen for connecting iCloud Mail / Calendar.
///
/// Shown after the user signs in with Apple if their email belongs to
/// an Apple domain (`icloud.com` / `me.com` / `mac.com`) or is an
/// Apple private-relay address. iCloud cannot be auto-added like
/// Gmail/Outlook because it requires an app-specific password — so
/// this gate doubles as the credential-entry form.
///
/// Layout (top → bottom): Apple logo, "Connect your iCloud" title,
/// subtitle copy, Mail+Calendar / Calendar-Only picker, email +
/// app-specific-password fields with a help link, scope bullets,
/// **Connect** / **Later** buttons. Visual structure mirrors
/// `AddAccountGmailOutlookView`.
struct AddAccountICloudView: View {
    private var manager = AccountManager.shared

    @State private var appleEmail = ""
    @State private var appPassword = ""
    @State private var selectedOption: ICloudOption = .both
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showCalendarFailedAlert = false

    let detectedEmail: String
    /// Called after the iCloud account is successfully added. Caller
    /// (typically `RootView`) refreshes the sidebar store, then clears
    /// `PendingAccountAdd` and the router moves to the next step. Async
    /// so the **Connect** spinner stays up until the screen actually
    /// changes (no early button re-enable / double-add window).
    var onConnected: () async -> Void = {}
    /// Called when the user taps **Later**. Caller clears
    /// `PendingAccountAdd` and marks `icloud_setup_prompted` so we
    /// don't re-prompt.
    var onLater: () -> Void = {}

    init(
        detectedEmail: String,
        onConnected: @escaping () async -> Void = {},
        onLater: @escaping () -> Void = {}
    ) {
        self.detectedEmail = detectedEmail
        self.onConnected = onConnected
        self.onLater = onLater
    }

    enum ICloudOption {
        case both
        case calendarOnly
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 32)

                Image(systemName: "apple.logo")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 80, height: 80)

                Text("Connect your iCloud")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Connect iCloud Mail and Calendar with an app-specific password. You can always connect it later from Email Accounts.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $selectedOption) {
                    Text("Mail + Calendar").tag(ICloudOption.both)
                    Text("Calendar Only").tag(ICloudOption.calendarOnly)
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)

                credentialFields
                    .padding(.top, 4)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(Theme.errorFg)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                bullets
                    .padding(.top, 4)

                Spacer().frame(height: 8)

                Button {
                    connect()
                } label: {
                    Group {
                        if isConnecting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canConnect ? Theme.accent : Theme.accent.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canConnect || isConnecting)

                Button {
                    UserDefaults.standard.set(true, forKey: "icloud_setup_prompted")
                    onLater()
                } label: {
                    Text("No Thanks")
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                .disabled(isConnecting)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Palette.previewPaneBg)
        .onAppear {
            // Pre-fill email if we detected an Apple domain
            if ICloudConfig.isAppleDomain(detectedEmail) && !detectedEmail.contains("privaterelay") {
                appleEmail = detectedEmail
            }
        }
        .lockOrientation(.portrait)
        .alert("Calendar Not Connected", isPresented: $showCalendarFailedAlert) {
            Button("Continue") { Task { await onConnected() } }
        } message: {
            Text("Your iCloud email was connected, but iCloud Calendar couldn't be set up right now. You can connect it later from Settings.")
        }
    }

    private var canConnect: Bool {
        !appleEmail.isEmpty && !appPassword.isEmpty
    }

    // MARK: - Credentials

    private var credentialFields: some View {
        VStack(spacing: 12) {
            TextField("Apple ID Email", text: $appleEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            SecureField("App-Specific Password", text: $appPassword)
                .textFieldStyle(.roundedBorder)

            Button {
                if let url = URL(string: "https://appleid.apple.com/account/manage/section/security") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                    Text("How to get an app-specific password")
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Privacy / scope bullets
    //
    // Differs from `AddAccountGmailOutlookView`'s bullets: iCloud
    // doesn't use OAuth tokens that we can revoke from inside the app,
    // so the third bullet points to appleid.apple.com (where the user
    // generated the app-specific password) instead.

    private var bullets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("**On-device:** mail and calendar are stored locally on your phone — never on our servers.")
            } icon: {
                Image(systemName: "iphone")
            }
            Label {
                Text("**IMAP & CalDAV:** TabMail uses Apple's standard mail and calendar protocols.")
            } icon: {
                Image(systemName: "envelope")
            }
            Label {
                Text("**Revocable:** revoke the app-specific password any time at appleid.apple.com.")
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textSecondary)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Theme.accent)
    }

    // MARK: - Submit

    private func connect() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                var calendarFailed = false
                switch selectedOption {
                case .both:
                    let account = try await manager.addICloudAccount(
                        email: appleEmail,
                        appSpecificPassword: appPassword,
                        includeCalendar: true
                    )
                    calendarFailed = account.calendarSetupFailed
                case .calendarOnly:
                    _ = try await manager.addCalDAVAccount(
                        serverURL: ICloudConfig.caldavURL,
                        username: appleEmail,
                        password: appPassword,
                        displayName: "iCloud Calendar"
                    )
                }
                UserDefaults.standard.set(true, forKey: "icloud_setup_prompted")
                isConnecting = false
                if calendarFailed {
                    // Email connected; surface the calendar failure, then the
                    // alert's Continue button proceeds via onConnected().
                    showCalendarFailedAlert = true
                } else {
                    await onConnected()
                }
                return
            } catch CalDAVError.authFailed {
                errorMessage = "Authentication failed. Check your Apple ID and app-specific password."
            } catch {
                if SyncEngine.isConnectionError(error) {
                    errorMessage = "Connection failed. Please check your network and try again."
                } else {
                    errorMessage = "Connection failed: \(error.userFacingDescription)"
                }
            }
            isConnecting = false
        }
    }
}
