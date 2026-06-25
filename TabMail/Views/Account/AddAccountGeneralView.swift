/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct AddAccountGeneralView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationStore.self) private var navigationStore
    private var manager = AccountManager.shared
    @State private var selectedProvider: AccountProvider?
    @State private var displayName = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var includeCalendar = true
    @State private var showCalendarFailedAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 40)

                Text("Add Account")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Choose your email provider")
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    providerButton(.gmail, label: "Gmail") {
                        Image("GoogleLogo").renderingMode(.original).resizable().scaledToFit()
                    }
                    providerButton(.outlook, label: "Outlook") {
                        Image("MicrosoftLogo").renderingMode(.original).resizable().scaledToFit()
                    }
                    providerButton(.icloud, label: "iCloud") {
                        Image(systemName: "apple.logo")
                    }
                    providerButton(.imap, label: "Other (IMAP)") {
                        Image(systemName: "envelope")
                    }
                }
                .padding(.horizontal, 40)

                if selectedProvider == .icloud {
                    icloudForm
                }

                if selectedProvider == .imap {
                    imapForm
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(Theme.errorFg)
                        .font(.caption)
                        .padding(.horizontal, 40)
                }

                Spacer()
                    .frame(height: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Palette.previewPaneBg)
        // No `.navigationTitle` — the inline `Text("Add Account")` is
        // the canonical title for this screen. When this view is
        // pushed via `NavigationLink` from Settings, dropping the
        // navigationTitle keeps the system back chevron but avoids
        // rendering a second "Add Account" in the toolbar.
        .lockOrientation(.portrait)
        .alert("Calendar Not Connected", isPresented: $showCalendarFailedAlert) {
            Button("Continue") { Task { await finishAddAndDismiss() } }
        } message: {
            Text("Your iCloud email was added, but iCloud Calendar couldn't be set up right now. You can try connecting it again later.")
        }
    }

    private func providerButton<Icon: View>(_ provider: AccountProvider, label: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            selectedProvider = provider
            errorMessage = nil
            switch provider {
            case .gmail: connectGmail()
            case .outlook: connectOutlook()
            case .icloud: break // Show iCloud form
            case .imap: break
            case .caldav: break
            }
        } label: {
            HStack {
                icon()
                    .frame(width: 24, height: 16)
                Text(label)
                    .fontWeight(.medium)
                Spacer()
                if isConnecting && selectedProvider == provider {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Theme.buttonBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }

    private var imapForm: some View {
        VStack(spacing: 12) {
            TextField("Name", text: $displayName)
                .textContentType(.name)
                .textFieldStyle(.roundedBorder)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            TextField("Username (if different from email)", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            TextField("IMAP Server", text: $imapHost)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            TextField("SMTP Server", text: $smtpHost)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            Button("Connect") {
                connectIMAP()
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || imapHost.isEmpty || isConnecting)
        }
        .padding(.horizontal, 24)
    }

    private func connectGmail() {
        isConnecting = true
        Task {
            do {
                let _ = try await manager.addGmailAccount()
                await finishAddAndDismiss()
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Google sign-in failed: \(error.userFacingDescription)"
            }
            isConnecting = false
        }
    }

    private func connectOutlook() {
        isConnecting = true
        Task {
            do {
                let _ = try await manager.addOutlookAccount()
                await finishAddAndDismiss()
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Microsoft sign-in failed: \(error.userFacingDescription)"
            }
            isConnecting = false
        }
    }

    private var icloudForm: some View {
        VStack(spacing: 12) {
            TextField("Apple ID Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            SecureField("App-Specific Password", text: $password)
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

            Toggle("Also connect iCloud Calendar", isOn: $includeCalendar)

            Button("Connect") {
                connectICloud()
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || isConnecting)
        }
        .padding(.horizontal, 24)
    }

    private func connectICloud() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                let account = try await manager.addICloudAccount(
                    email: email,
                    appSpecificPassword: password,
                    includeCalendar: includeCalendar
                )
                isConnecting = false
                if account.calendarSetupFailed {
                    // Email added; surface the calendar failure, then the
                    // alert's Continue button proceeds via finishAddAndDismiss().
                    showCalendarFailedAlert = true
                } else {
                    await finishAddAndDismiss()
                }
                return
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

    private func connectIMAP() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                let _ = try await manager.addIMAPAccount(
                    displayName: displayName,
                    email: email,
                    username: username,
                    password: password,
                    imapHost: imapHost,
                    imapPort: Int(imapPort) ?? 993,
                    smtpHost: smtpHost.isEmpty ? imapHost.replacingOccurrences(of: "imap", with: "smtp") : smtpHost,
                    smtpPort: Int(smtpPort) ?? 587
                )
                await finishAddAndDismiss()
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

    /// Refresh the sidebar store BEFORE dismissing, so the Settings accounts
    /// list (`ForEach(navigationStore.accounts)`) already shows the new account
    /// when we pop back. `navigationStore.accounts` is otherwise only
    /// repopulated ~100ms later via the debounced `.backgroundDataDidChange`
    /// listener (see `NavigationStore.loadInitialData`), so on return the list
    /// looks unchanged for that gap — the "blink, nothing happened" after a
    /// successful add. The account row is committed before each `add…` call
    /// returns, so the refresh is guaranteed to read it.
    @MainActor
    private func finishAddAndDismiss() async {
        await navigationStore.refresh()
        dismiss()
    }
}
