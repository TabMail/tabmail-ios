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
    @State private var confirmed = false
    @State private var isDeleting = false
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
        .navigationBarBackButtonHidden(deletionComplete)
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
                    Text("Nothing is deleted today. Your TabMail account is scheduled for deletion \(Self.gracePeriodDays) days from now, and keeps working normally until then.")
                        .font(.subheadline)

                    BulletPoint("To call it off, sign in to TabMail again before that date and tap Keep Account on the banner at the top of your inbox.")
                    BulletPoint("If you do nothing, the deletion goes ahead on its own and cannot be undone.")
                }
                .padding(.vertical, 4)
            } label: {
                Label("You have \(Self.gracePeriodDays) days to change your mind", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }

            // What will be deleted
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Once the \(Self.gracePeriodDays) days are up, this is permanently deleted:")
                        .font(.subheadline)

                    BulletPoint("Your account credentials and profile")
                    BulletPoint("All data stored on our servers")
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
                    Text("Active subscriptions will be automatically cancelled at the end of your current billing period.")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            } label: {
                Label("Subscription", systemImage: "creditcard")
                    .font(.headline)
            }

            // Legal
            Text("Anonymized transaction records may be retained for legal compliance.")
                .font(.footnote)
                .foregroundStyle(.secondary)

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
                Task { await deleteAccount() }
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Schedule Deletion")
                        .bold()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!confirmed || isDeleting)
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
                "Your TabMail account is scheduled for permanent deletion on \($0). Your email accounts and messages remain on this device."
            } ?? "Your TabMail account is scheduled for permanent deletion. Your email accounts and messages remain on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Changed your mind? Sign in to TabMail again before then and tap Keep Account on the banner at the top of your inbox. After that date the deletion is permanent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Active subscriptions will be cancelled at the end of your billing period.")
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

    // MARK: - Actions

    private func deleteAccount() async {
        isDeleting = true
        errorMessage = nil

        do {
            let response = try await BillingClient().requestAccountDeletion()
            print("[AccountDeletion] Scheduled: \(response.status), date: \(response.deletion_date)")

            // Show the server's scheduled date, not a locally computed one.
            // Stays nil if the timestamp doesn't parse, in which case the
            // confirmation screen omits the date entirely.
            scheduledDateText = Date.fromISO8601(response.deletion_date)
                .map { $0.formatted(date: .long, time: .omitted) }

            // Scoped cleanup: clear TabMail account data, preserve email accounts & messages
            await scopedTabMailCleanup()

            // Show confirmation instead of dismissing immediately
            withAnimation {
                deletionComplete = true
            }
        } catch {
            errorMessage = "Couldn't schedule the deletion. Please try again."
            print("[AccountDeletion] Error: \(error)")
        }

        isDeleting = false
    }

    /// Clears TabMail session and stops AI processing while preserving all local data.
    private func scopedTabMailCleanup() async {
        // 1. Cancel all in-flight AI tasks (prevents stale JWTs from hitting backend)
        await AccountManager.shared.cancelAllAIProcessing()

        // 2. Clear TabMail session (Keychain)
        TabMailAuthService.clearSession()

        // 3. Disconnect Device Sync
        DeviceSyncService.shared.disconnect()

        print("[AccountDeletion] Scoped cleanup complete — email accounts and messages preserved")

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
