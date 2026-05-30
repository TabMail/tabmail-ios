/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct AccountDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var deletionComplete = false

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

            // What will be deleted
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your TabMail account will be permanently deleted. This includes:")
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
                Text("I understand this is permanent")
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
                    Text("Delete My Account")
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

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Account Deleted")
                .font(.title2.bold())

            Text("Your TabMail account has been deleted. Your email accounts and messages remain on this device.")
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

            // Scoped cleanup: clear TabMail account data, preserve email accounts & messages
            await scopedTabMailCleanup()

            // Show confirmation instead of dismissing immediately
            withAnimation {
                deletionComplete = true
            }
        } catch {
            errorMessage = "Failed to delete account. Please try again."
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
