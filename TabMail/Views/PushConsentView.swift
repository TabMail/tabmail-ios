/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Onboarding push-notifications consent screen.
/// Shown once after accounts + AI consent, before the mail UI appears.
/// Upgrading users who haven't seen this screen yet will see it on next launch
/// (gated by `hasSeenPushConsent` — a key that does not exist in prior installs).
///
/// UX mirrors `AIConsentView`: two explicit buttons — primary
/// **Enable Push Notifications** and secondary **No Thanks**. The caller
/// marks the gate as seen regardless of choice so the screen does not
/// reappear on the next launch.
struct PushConsentView: View {
    /// Called when the user makes a choice. `true` = push enabled, `false` = declined.
    var onComplete: (_ pushEnabled: Bool) -> Void

    @State private var isEnabling = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer()
                    .frame(height: 40)

                Image("TabMailLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)

                Text("Instant New Email")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.textPrimary)

                Text("Get new emails instantly — buzzing only for the ones that matter.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text("**Real-time:** providers push notifications to our servers, which wake your device instantly.")
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                    Label {
                        Text("**Smart filtering:** only important emails buzz; the rest stay quiet.")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    Label {
                        Text("**Metadata only:** no email bodies, metadata only, nothing stored at rest.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    Label {
                        Text("**Revocable:** turn off any time; authorization is discarded immediately.")
                    } icon: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)

                Link("Privacy Policy", destination: URL(string: "https://tabmail.ai/privacy")!)
                    .font(.subheadline)

                Spacer()
                    .frame(height: 16)

                Button {
                    enablePushAndComplete()
                } label: {
                    Group {
                        if isEnabling {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Enable")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isEnabling)

                Button {
                    UserDefaults.standard.set(false, forKey: PushConfig.pushNotificationsEnabledKey)
                    NSEDataBridge.mirrorPushSettings()
                    EnableInboxPushTip.pushEnabled = false
                    onComplete(false)
                } label: {
                    Text("No Thanks")
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 4)
                .disabled(isEnabling)

                Text("You can change this anytime in Email Accounts settings.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }

    private func enablePushAndComplete() {
        isEnabling = true
        UserDefaults.standard.set(true, forKey: PushConfig.pushNotificationsEnabledKey)
        NSEDataBridge.mirrorPushSettings()
        // Suppress the "Enable Inbox Push Notifications" banner immediately —
        // we just resolved it.
        EnableInboxPushTip.pushEnabled = true

        Task { @MainActor in
            await PushNotificationService.shared.registerDeviceWithWorker(force: true)
            // Provider-agnostic consent sweep across push-capable accounts.
            // Dispatches the Gmail / Microsoft OAuth flow per account.
            _ = await PushNotificationService.shared.ensurePushConsentForAllAccounts(
                auth: OAuthService()
            )
            onComplete(true)
        }
    }
}
