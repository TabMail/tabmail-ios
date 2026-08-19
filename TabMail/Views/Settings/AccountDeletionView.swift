/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct AccountDeletionView: View {
    /// Length of the server-side deletion grace period, mirrored from
    /// `GRACE_PERIOD_DAYS` in the billing worker's `handlers/accountDeletion.ts`.
    /// Used for copy only, and only *before* the request is made — once the
    /// server responds, the authoritative date arrives in
    /// `DeletionResponse.deletion_date` and is what we actually show.
    private static let gracePeriodDays = 30

    @Environment(\.dismiss) private var dismiss
    @Environment(StoreKitManager.self) private var storeKit
    @State private var confirmed = false
    @State private var deletionAttemptGate = AccountDeletionAttemptGate()
    @State private var progressMessage = "Schedule Deletion"
    @State private var errorMessage: String?
    @State private var deletionComplete = false
    /// Formatted `deletion_date` from the server response. Nil when the
    /// timestamp could not be parsed — we then omit the date rather than
    /// promise one we don't have.
    @State private var scheduledDateText: String?

    var body: some View {
        ScrollView {
            if deletionComplete {
                deletionConfirmationContent
            } else {
                deletionFormContent
            }
        }
        .background(Palette.previewPaneBg)
        .navigationTitle(deletionComplete ? "" : "Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(deletionComplete || deletionAttemptGate.isRunning)
        .dismissKeyboardOnTap()
    }

    // MARK: - Deletion form

    private var deletionFormContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Delete Your Account")
                    .font(.title2.bold())
            }
            .padding(.bottom, 4)

            // Grace period — the first thing the user needs to know, because
            // it contradicts what a "Delete Account" screen normally implies.
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AccountDeletionCopy.gracePeriodDescription(days: Self.gracePeriodDays))
                        .font(.subheadline)

                    BulletPoint(
                        "To call it off, sign in to TabMail again before that date and tap Keep Account " +
                            "on the banner at the top of your inbox."
                    )
                    BulletPoint("If you do nothing, the deletion goes ahead on its own and cannot be undone.")
                }
                .padding(.vertical, 4)
            } label: {
                Label(
                    "You have \(Self.gracePeriodDays) days to change your mind",
                    systemImage: "clock.arrow.circlepath"
                )
                    .font(.headline)
            }

            // What will be deleted
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "After \(Self.gracePeriodDays) days, your TabMail account and associated data " +
                            "are deleted, subject to the Privacy Policy and legally or operationally " +
                            "required retention."
                    )
                        .font(.subheadline)

                    BulletPoint("Your account credentials and profile")
                    BulletPoint("Active AI processing and sync")
                }
                .padding(.vertical, 4)
            } label: {
                Label("What will be deleted", systemImage: "trash")
                    .font(.headline)
            }

            // What is NOT affected
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This does NOT affect:")
                        .font(.subheadline)

                    BulletPoint("Your email accounts and messages on this device")
                    BulletPoint("Emails on your mail provider (Gmail, IMAP server, etc.)")
                }
                .padding(.vertical, 4)
            } label: {
                Label("Not affected", systemImage: "checkmark.shield")
                    .font(.headline)
            }

            // Subscription info
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Renewal must be off before account deletion.")
                        .font(.subheadline)
                    Text(
                        "Stripe is handled automatically. If an Apple subscription is still " +
                            "renewing, you’ll briefly open Apple Subscriptions to turn off auto-renew."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } label: {
                Label("Subscription", systemImage: "creditcard")
                    .font(.headline)
            }

            Divider()

            // Confirmation toggle
            Toggle(isOn: $confirmed) {
                Text("I understand my account will be permanently deleted after \(Self.gracePeriodDays) days")
                    .font(.subheadline.bold())
            }
            .tint(.red)

            // Error
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            // Delete button
            Button(role: .destructive) {
                startDeletion()
            } label: {
                HStack {
                    if deletionAttemptGate.isRunning {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(progressMessage)
                        .bold()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!confirmed || deletionAttemptGate.isRunning)
            .padding(.top, 4)
        }
        .padding()
    }

    // MARK: - Deletion confirmation

    private var deletionConfirmationContent: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text("Deletion Scheduled")
                .font(.title2.bold())

            // The date comes from the server response. If it could not be
            // parsed we say nothing about timing rather than invent a date.
            Text(scheduledDateText.map {
                "Your TabMail account is scheduled for permanent deletion on \($0). " +
                    "Your email accounts and messages remain on this device."
            } ?? (
                "Your TabMail account is scheduled for permanent deletion. " +
                    "Your email accounts and messages remain on this device."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(
                "Changed your mind? Sign in to TabMail again before then and tap Keep Account on the " +
                    "banner at the top of your inbox. After that date the deletion is permanent."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(AccountDeletionCopy.keepAccountConsequence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }
}

private extension AccountDeletionView {
    // MARK: - Actions

    private func startDeletion() {
        // Claim the operation synchronously in the button action. Two rapid
        // activations therefore cannot enqueue overlapping StoreKit sheets or
        // cancellation requests before SwiftUI has time to re-render.
        guard deletionAttemptGate.begin() else { return }
        errorMessage = nil
        progressMessage = "Checking Subscription…"
        // This operation intentionally outlives a transient view redraw. The
        // back button is hidden while it runs, and cancelling an in-flight
        // destructive POST would itself create an ambiguous outcome.
        Task {
            await deleteAccount()
        }
    }

    private func deleteAccount() async {
        defer {
            deletionAttemptGate.finish()
            progressMessage = "Schedule Deletion"
        }

        do {
            let billingClient = BillingClient()
            let backendClient = BackendClient()
            let execution = try await AccountDeletionSubscriptionCoordinator.execute(
                fetchAccountInfo: { try await backendClient.fetchAccountInfo() },
                cancelStripe: { try await billingClient.cancelSubscription() },
                appleRenewalState: {
                    guard let userId = TabMailAuthService.getSession()?.userId else {
                        return .unavailable
                    }
                    return await storeKit.accountDeletionRenewalState(
                        currentUserId: userId
                    )
                },
                manageAppleSubscription: { await presentAppleSubscriptions() },
                scheduleDeletion: { try await billingClient.requestAccountDeletion() },
                fetchDeletionStatus: { try await billingClient.checkDeletionStatus() },
                progress: { progressMessage = $0.buttonLabel }
            )

            let deletionDate: String?
            switch execution {
            case .scheduled(let scheduledDate):
                deletionDate = scheduledDate
            case .schedulingNotConfirmed:
                errorMessage = AccountDeletionCopy.schedulingNotConfirmed
                return
            case .blocked(let preparation):
                errorMessage = blockedMessage(for: preparation)
                return
            }
            // Show the server's scheduled date, not a locally computed one.
            // Stays nil if the timestamp doesn't parse, in which case the
            // confirmation screen omits the date entirely.
            scheduledDateText = deletionDate.flatMap(Date.fromISO8601)
                .map { $0.formatted(date: .long, time: .omitted) }

            // Scoped cleanup: clear TabMail account data, preserve email accounts & messages
            await scopedTabMailCleanup()

            // Show confirmation instead of dismissing immediately
            withAnimation {
                deletionComplete = true
            }
        } catch {
            errorMessage = "We couldn’t confirm subscription status, so deletion wasn’t scheduled. Please try again."
            if DebugModeManager.isLoggingEnabled() {
                print("[AccountDeletion] Error: \(error)")
            }
        }
    }

    private func blockedMessage(
        for outcome: AccountDeletionSubscriptionCoordinator.Outcome
    ) -> String {
        switch outcome {
        case .ready:
            assertionFailure("A ready deletion must execute the scheduling request")
            return "Couldn't schedule the deletion. Please try again."
        case .cancellationNotConfirmed:
            return "Renewal could not be confirmed as off. Please try again."
        case .cancellationStillUpdating:
            return "Cancellation is still updating. Please try again in a moment."
        case .appleManagementUnavailable:
            return "Open Apple Subscriptions, turn off auto-renew, then try again."
        case .appleConfirmationPending:
            return AccountDeletionCopy.appleConfirmationPending
        case .appleStatusUnavailable:
            return "We couldn’t check Apple subscription status. Please try again."
        case .unsupportedActiveProvider:
            return "Turn off subscription renewal before deleting your account."
        }
    }

    private func presentAppleSubscriptions() async -> Bool {
        let outcome = await StoreKitManager.presentManageSubscriptions()
        if case .failed(let error) = outcome, DebugModeManager.isLoggingEnabled() {
            print("[AccountDeletion] Failed to open Apple subscriptions: \(error)")
        }
        // Fails closed on both a missing window scene and a thrown presentation
        // error: the deletion gate must not proceed on an unpresented sheet.
        return outcome.didPresent
    }

    /// Clears TabMail session and stops AI processing while preserving all local data.
    private func scopedTabMailCleanup() async {
        // 1. Cancel all in-flight AI tasks (prevents stale JWTs from hitting backend)
        await AccountManager.shared.cancelAllAIProcessing()

        // 2. Clear TabMail session (Keychain)
        TabMailAuthService.clearSession()

        // 3. Disconnect Device Sync
        DeviceSyncService.shared.disconnect()

        if DebugModeManager.isLoggingEnabled() {
            print("[AccountDeletion] Scoped cleanup complete — email accounts and messages preserved")
        }

        // 4. Signal sign-out → RootView stays in inbox (email accounts still exist)
        NotificationCenter.default.post(name: .tabMailDidSignOut, object: nil)
    }

}

private struct BulletPoint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .font(.subheadline)
            Text(text)
                .font(.subheadline)
        }
    }
}
