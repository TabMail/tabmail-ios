/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UserNotifications

/// Warning shown above the reminder cards when the user will not actually receive
/// push notifications for new/approaching reminders. Two failure modes:
///   1. The in-app proactive-notify toggle is OFF (user disabled in Settings).
///   2. iOS notification permission is denied (user denied at the system level).
/// Either case means the reminders panel is the *only* surface for these alerts.
struct RemindersNotificationWarning: View {
    @AppStorage(ProactiveNotifyService.enabledKey) private var proactiveEnabled = true
    @State private var iosAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var hasLoadedAuthStatus = false
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Pure decision logic (unit-tested in RemindersNotificationWarningTests)

    /// True if iOS-level notification permission is in a non-deliverable state.
    /// `.notDetermined` is treated as a failure too — until the user grants
    /// permission, no notifications will fire.
    static func iosNotificationsBlocked(status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return false
        case .denied, .notDetermined:
            return true
        @unknown default:
            return true
        }
    }

    /// Whether the warning banner should be visible.
    /// Suppressed until the iOS auth status has been loaded (avoids a flash of
    /// the warning on first render before the async settings fetch completes).
    static func shouldShow(
        hasLoadedAuthStatus: Bool,
        proactiveEnabled: Bool,
        iosAuthStatus: UNAuthorizationStatus
    ) -> Bool {
        guard hasLoadedAuthStatus else { return false }
        return !proactiveEnabled || iosNotificationsBlocked(status: iosAuthStatus)
    }

    /// Copy shown in the warning. The in-app toggle takes precedence: if the
    /// user turned the feature off in-app, tell them where to turn it back on
    /// in-app. Otherwise point at the iOS Settings fix.
    static func warningText(
        proactiveEnabled: Bool,
        iosAuthStatus: UNAuthorizationStatus
    ) -> String {
        if !proactiveEnabled {
            return "Reminder notifications are off. Turn them on in Settings → Notifications to be alerted when reminders are new or approaching."
        }
        // iOS-level block
        return "iOS notifications are off for TabMail. Enable them in iOS Settings to be alerted when reminders are new or approaching."
    }

    private var shouldShowComputed: Bool {
        Self.shouldShow(
            hasLoadedAuthStatus: hasLoadedAuthStatus,
            proactiveEnabled: proactiveEnabled,
            iosAuthStatus: iosAuthStatus
        )
    }

    private var warningTextComputed: String {
        Self.warningText(proactiveEnabled: proactiveEnabled, iosAuthStatus: iosAuthStatus)
    }

    var body: some View {
        Group {
            if shouldShowComputed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(warningTextComputed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .task {
            await refreshAuthStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await refreshAuthStatus() }
            }
        }
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            self.iosAuthStatus = settings.authorizationStatus
            self.hasLoadedAuthStatus = true
        }
    }
}

/// A single reminder card for the chat pill's top section.
/// Tap to expand/collapse. Dismiss button hidden for past (locked) sessions.
struct ReminderTopCard: View {
    let reminder: Reminder
    let canDismiss: Bool
    @Binding var expandedReminderHash: String?
    @Binding var hiddenReminderHashes: Set<String>

    private var isUrgent: Bool { ReminderBuilder.isUrgent(reminder) }
    private var isCardExpanded: Bool { expandedReminderHash == reminder.hash }
    private var isHidden: Bool { hiddenReminderHashes.contains(reminder.hash) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                if let dueLabel = ReminderBuilder.formatDueLabelForCard(reminder) {
                    Text(dueLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isUrgent ? Theme.accent : Theme.textPrimary)
                        .strikethrough(isHidden)
                }

                Text(reminder.content)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(isCardExpanded ? nil : 2)
                    .strikethrough(isHidden)

                if isCardExpanded {
                    sourceContextView
                    if canDismiss {
                        HStack {
                            dismissButton
                            Spacer()
                            if reminder.source == "message", let realId = reminder.messageId, !realId.isEmpty {
                                openEmailButton(realId: realId)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isCardExpanded ? 90 : 0))
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.boxBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedReminderHash = isCardExpanded ? nil : reminder.hash
            }
        }
        .reportConcern(contentType: .chatMessage, content: reminder.content)
        .opacity(isHidden ? 0.6 : 1.0)
    }

    @ViewBuilder
    private var sourceContextView: some View {
        if reminder.source == "message", let subject = reminder.subject, !subject.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "envelope")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Text(subject)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .strikethrough(isHidden)
                if let from = reminder.from, !from.isEmpty {
                    Text("— \(from)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.top, 1)
        } else if reminder.source == "kb" {
            HStack(spacing: 4) {
                Image(systemName: "book.closed")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Text("From your knowledge base")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 1)
        }
    }

    private func openEmailButton(realId: String) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .emailPillTapped,
                object: nil,
                userInfo: ["realId": realId]
            )
        } label: {
            Text("open email")
                .font(.caption2)
                .foregroundStyle(Theme.accent)
        }
    }

    private var dismissButton: some View {
        Button {
            if isHidden {
                DisabledRemindersStore.setEnabled(hash: reminder.hash, enabled: true)
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = hiddenReminderHashes.remove(reminder.hash)
                }
            } else {
                DisabledRemindersStore.setEnabled(hash: reminder.hash, enabled: false)
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = hiddenReminderHashes.insert(reminder.hash)
                }
            }
        } label: {
            Text(isHidden ? "unhide reminder" : "don't show again")
                .font(.caption2)
                .foregroundStyle(isHidden ? Theme.accent : Theme.destructive.opacity(0.55))
        }
        .padding(.top, 2)
    }
}
