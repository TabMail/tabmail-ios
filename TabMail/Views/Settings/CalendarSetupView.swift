/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// "Add Calendar" page — lets users add any CalDAV calendar independent of email accounts.
/// Options: iCloud Calendar, Google Calendar, Outlook Calendar, Other CalDAV.
struct CalendarSetupView: View {
    @Environment(\.dismiss) private var dismiss
    private var manager = AccountManager.shared

    @State private var selectedOption: CalendarOption?
    @State private var isConnecting = false
    @State private var errorMessage: String?

    // CalDAV form fields
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""

    // iCloud form fields
    @State private var icloudEmail = ""
    @State private var icloudPassword = ""

    enum CalendarOption {
        case icloud
        case google
        case outlook
        case caldav
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Text("Add Calendar")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Choose your calendar provider")
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    optionButton(.icloud, label: "iCloud Calendar") {
                        Image(systemName: "apple.logo")
                    }
                    optionButton(.google, label: "Google Calendar") {
                        Image("GoogleLogo").renderingMode(.original).resizable().scaledToFit()
                    }
                    optionButton(.outlook, label: "Outlook Calendar") {
                        Image("MicrosoftLogo").renderingMode(.original).resizable().scaledToFit()
                    }
                    optionButton(.caldav, label: "Other CalDAV") {
                        Image(systemName: "server.rack")
                    }
                }
                .padding(.horizontal, 40)

                if selectedOption == .icloud {
                    icloudForm
                }

                if selectedOption == .caldav {
                    caldavForm
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(Theme.errorFg)
                        .font(.caption)
                        .padding(.horizontal, 40)
                }

                Spacer().frame(height: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Palette.previewPaneBg)
        .navigationTitle("Add Calendar")
    }

    // MARK: - Option Buttons

    private func optionButton<Icon: View>(_ option: CalendarOption, label: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            selectedOption = option
            errorMessage = nil
            switch option {
            case .icloud, .caldav:
                break // Show form
            case .google:
                connectGoogleCalendar()
            case .outlook:
                connectOutlookCalendar()
            }
        } label: {
            HStack {
                icon()
                    .frame(width: 24, height: 16)
                Text(label)
                    .fontWeight(.medium)
                Spacer()
                if isConnecting && selectedOption == option {
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

    // MARK: - iCloud Form

    private var icloudForm: some View {
        VStack(spacing: 12) {
            TextField("Apple ID Email", text: $icloudEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            SecureField("App-Specific Password", text: $icloudPassword)
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

            Button("Connect") {
                connectICloudCalendar()
            }
            .buttonStyle(.borderedProminent)
            .disabled(icloudEmail.isEmpty || icloudPassword.isEmpty || isConnecting)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - CalDAV Form

    private var caldavForm: some View {
        VStack(spacing: 12) {
            TextField("CalDAV Server URL", text: $serverURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            TextField("Username", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            TextField("Display Name (optional)", text: $displayName)
                .textFieldStyle(.roundedBorder)

            Button("Connect") {
                connectCalDAV()
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Connect Actions

    private func connectICloudCalendar() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                _ = try await manager.addCalDAVAccount(
                    serverURL: ICloudConfig.caldavURL,
                    username: icloudEmail,
                    password: icloudPassword,
                    displayName: "iCloud Calendar"
                )
                dismiss()
            } catch CalDAVError.authFailed {
                errorMessage = "Authentication failed. Check your Apple ID and app-specific password."
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Connection failed: \(error.userFacingDescription)"
            }
            isConnecting = false
        }
    }

    private func connectCalDAV() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                var url = serverURL
                if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
                    url = "https://\(url)"
                }
                _ = try await manager.addCalDAVAccount(
                    serverURL: url,
                    username: username,
                    password: password,
                    displayName: displayName.isEmpty ? nil : displayName
                )
                dismiss()
            } catch CalDAVError.authFailed {
                errorMessage = "Authentication failed. Check your credentials."
            } catch CalDAVError.discoveryFailed(let msg) {
                errorMessage = "Could not discover CalDAV service: \(msg)"
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Connection failed: \(error.userFacingDescription)"
            }
            isConnecting = false
        }
    }

    private func connectGoogleCalendar() {
        isConnecting = true
        Task {
            do {
                // Reuse Google OAuth — creates synthetic account with calendarOnly=true
                let tokens = try await manager.oauthService.authenticateGoogle()
                let userInfo = try await manager.oauthService.fetchGoogleUserInfo(accessToken: tokens.accessToken)

                // Check if existing Gmail account already has calendar
                let existingAccount = try await AppDatabase.dbPool.read { db in
                    try Account.filter(Column("emailAddress") == userInfo.email && Column("provider") == AccountProvider.gmail.rawValue).fetchOne(db)
                }
                if existingAccount != nil {
                    // Calendar already available via existing account
                    dismiss()
                    return
                }

                // Create calendar-only Gmail account
                var account = Account(emailAddress: userInfo.email, displayName: userInfo.name, provider: .gmail)
                account.calendarOnly = true
                let acct = account
                try await AppDatabase.dbPool.write { db in try acct.insert(db) }
                try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: account.id))
                if let refresh = tokens.refreshToken {
                    try KeychainHelper.save(refresh, for: KeychainHelper.refreshTokenKey(accountId: account.id))
                }
                try await manager.connectAccount(account)
                dismiss()
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Google Calendar setup failed: \(error.userFacingDescription)"
            }
            isConnecting = false
        }
    }

    private func connectOutlookCalendar() {
        isConnecting = true
        Task {
            do {
                let tokens = try await manager.oauthService.authenticateMicrosoft()
                let userInfo = try await manager.oauthService.fetchMicrosoftUserInfo(accessToken: tokens.accessToken)

                let existingAccount = try await AppDatabase.dbPool.read { db in
                    try Account.filter(Column("emailAddress") == userInfo.email && Column("provider") == AccountProvider.outlook.rawValue).fetchOne(db)
                }
                if existingAccount != nil {
                    dismiss()
                    return
                }

                var account = Account(emailAddress: userInfo.email, displayName: userInfo.name, provider: .outlook)
                account.calendarOnly = true
                let acct = account
                try await AppDatabase.dbPool.write { db in try acct.insert(db) }
                try KeychainHelper.save(tokens.accessToken, for: KeychainHelper.accessTokenKey(accountId: account.id))
                if let refresh = tokens.refreshToken {
                    try KeychainHelper.save(refresh, for: KeychainHelper.refreshTokenKey(accountId: account.id))
                }
                try await manager.connectAccount(account)
                dismiss()
            } catch {
                errorMessage = SyncEngine.isConnectionError(error) ? "Connection failed. Please check your network and try again." : "Outlook Calendar setup failed: \(error.userFacingDescription)"
            }
            isConnecting = false
        }
    }
}
