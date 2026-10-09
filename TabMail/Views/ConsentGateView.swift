/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The age and terms screen shown before first use (owner 2026-10-08): a
/// neutral date-of-birth entry plus agreement to the Terms of Service and
/// Privacy Policy. Matches the website's `consent.html` / `consent.js`.
///
/// The date of birth lives only in this view's `@State`: it is compared with
/// the minimum age here and never sent or stored. A pass saves the same
/// consent flags as before; a failure shows the "can't create an account"
/// view, asks the billing worker to delete the account, and blocks this
/// device (`AgeAndTermsConsent`). A device that is already blocked opens
/// straight on that view.
struct ConsentGateView: View {
    /// When true (default), submit() writes consent metadata to Supabase via
    /// `TabMailAuthService.updateUserMetadata`. Set to false from demo mode —
    /// the demo session has no Supabase user, so
    /// the metadata write would 401 with "Invalid session data". The parent
    /// owns demo-prefixed flag persistence in that case. Demo also has no
    /// account to delete after a failed age check.
    var persistsToBackend: Bool = true
    var onComplete: () -> Void
    /// Runs when the person taps OK on the "can't create an account" view: the
    /// parent signs out (or leaves demo).
    var onIneligible: () async -> Void = {}

    @State private var birthMonth: Int?
    @State private var birthDay: Int?
    @State private var birthYear: Int?
    @State private var agreedToTerms = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isIneligible = AgeAndTermsConsent.isDeviceBlocked()
    @State private var deletionRequested = false
    @State private var isLeaving = false

    private var birthDateEntered: Bool {
        birthMonth != nil && birthDay != nil && birthYear != nil
    }

    private var canContinue: Bool {
        birthDateEntered && agreedToTerms
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

                    Text(isIneligible ? "We can\u{2019}t create a TabMail account for you" : "Before You Continue")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)

                    if isIneligible {
                        Text(ineligibleMessage)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Please enter your date of birth and accept our legal terms.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)

                        VStack(spacing: 16) {
                            birthDateFields

                            checkboxRow(
                                isChecked: $agreedToTerms,
                                label: {
                                    Text("I have read and agree to the [Terms of Service](https://tabmail.ai/terms) and [Privacy Policy](https://tabmail.ai/privacy).")
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

                        Text("We store only that you passed the age check and when you accepted the Terms of Service and Privacy Policy. Your date of birth is not stored.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 32)
            }

            VStack(spacing: 12) {
                if isIneligible {
                    Button {
                        leave()
                    } label: {
                        Group {
                            if isLeaving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("OK")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isLeaving)
                } else {
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
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .padding(.top, 16)
        }
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }

    private var ineligibleMessage: String {
        persistsToBackend
            ? "Based on the information you entered, you aren\u{2019}t able to use TabMail.\n\nWe\u{2019}ll delete your TabMail account and sign you out."
            : "Based on the information you entered, you aren\u{2019}t able to use TabMail."
    }

    // MARK: - Date of Birth

    /// Three menus with no preselected value, like the website: nothing on the
    /// screen suggests an answer or reveals the minimum age.
    private var birthDateFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Date of birth")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                birthDateMenu("Month", selection: $birthMonth, values: Array(1...12)) { month in
                    AgeAndTermsConsent.monthNames[month - 1]
                }
                birthDateMenu("Day", selection: $birthDay, values: Array(1...31)) { String($0) }
                birthDateMenu("Year", selection: $birthYear, values: AgeAndTermsConsent.birthYears(today: Date())) { String($0) }
            }

            Text("Used only to confirm you can use TabMail. We don\u{2019}t store your date of birth.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func birthDateMenu(
        _ placeholder: String,
        selection: Binding<Int?>,
        values: [Int],
        title: @escaping (Int) -> String
    ) -> some View {
        Menu {
            Picker(placeholder, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(title(value)).tag(Optional(value))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.map(title) ?? placeholder)
                    .foregroundStyle(selection.wrappedValue == nil ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.separator))
        }
        .accessibilityLabel(placeholder)
        .accessibilityValue(selection.wrappedValue.map(title) ?? "Not selected")
        .onChange(of: selection.wrappedValue) { _, _ in errorMessage = nil }
    }

    // MARK: - Checkbox Row

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
        guard canContinue, !isSubmitting,
              let year = birthYear, let month = birthMonth, let day = birthDay else { return }
        errorMessage = nil

        switch AgeAndTermsConsent.check(year: year, month: month, day: day) {
        case .invalidDate:
            errorMessage = "Please enter a valid date of birth."
            return
        case .ineligible:
            failAgeCheck()
            return
        case .eligible:
            // Only the outcome is kept; the entered date is discarded here.
            birthMonth = nil
            birthDay = nil
            birthYear = nil
        }

        isSubmitting = true

        if !persistsToBackend {
            onComplete()
            return
        }

        let timestamp = Date().iso8601String()

        Task {
            do {
                try await TabMailAuthService.updateUserMetadata(AgeAndTermsConsent.agreementMetadata(at: timestamp))

                // Force-refresh token so backend JWT has updated user_metadata claims
                let refreshResult = await TabMailTokenCoordinator.shared.forceRefresh()
                switch refreshResult {
                case .success:
                    BackgroundSyncLogger.logDebug("[ConsentGate] Token refreshed with updated consent metadata")
                case .permanentFailure, .noSession:
                    BackgroundSyncLogger.logDebug("[ConsentGate] Token refresh failed permanently — consent saved but token stale")
                case .transientFailure:
                    BackgroundSyncLogger.logDebug("[ConsentGate] Token refresh transient failure — consent saved, will refresh on next call")
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

    // MARK: - Failed Age Check

    /// Discard the entered date, show the refusal and ask for the account to
    /// be deleted (`AgeAndTermsConsent.check` has blocked this device).
    /// Consent is never saved.
    private func failAgeCheck() {
        birthMonth = nil
        birthDay = nil
        birthYear = nil
        agreedToTerms = false
        withAnimation { isIneligible = true }
        Task { await requestDeletionOnce() }
    }

    /// OK on the refusal: make sure the deletion was asked for (a device that
    /// was already blocked has not asked yet), then hand over to the parent.
    private func leave() {
        guard !isLeaving else { return }
        isLeaving = true
        Task {
            await requestDeletionOnce()
            await onIneligible()
            isLeaving = false
        }
    }

    /// A failed request is not retried here: the billing worker's hourly
    /// sweep deletes an account that never finishes this screen once it is
    /// 7 days old and unused for 30 days.
    private func requestDeletionOnce() async {
        guard persistsToBackend, !deletionRequested else { return }
        deletionRequested = true
        do {
            try await BillingClient().requestAgeIneligibleDeletion()
            BackgroundSyncLogger.logDebug("[ConsentGate] Age-ineligible account deletion requested")
        } catch {
            BackgroundSyncLogger.logDebug("[ConsentGate] Age-ineligible deletion request failed (unfinished accounts are removed automatically): \(error)")
        }
    }
}
