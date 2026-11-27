/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// The one-time database upgrade's screen (ADR-IOS-121), full screen: first the
/// notice (what it does, how long it can take, Upgrade now and Later), then, after
/// Upgrade now, one progress bar for both databases with the minutes left
/// (`DatabaseUpgradeProgress`), with the screen kept awake (`keepScreenAwake`, as Fast
/// Sync), then the result. State and actions are `DatabaseUpgrade`'s.
struct DatabaseUpgradeView: View {
    @Bindable var upgrade: DatabaseUpgrade

    @Environment(\.scenePhase) private var scenePhase

    static let noticeTitle = "Database update"
    static let noticeWhat = "For the best experience, TabMail needs to update your database."
    static let upgradeNowTitle = "Update now"
    static let laterTitle = "Later"
    static let upgradingTitle = "Updating your database."
    static let upgradingHint = "Keep TabMail open."
    static let doneTitle = "Update complete"
    static let doneMessage = "Your database is up to date."
    static let failedTitle = "The update could not finish"
    static let failedMessage = "Nothing was lost. You can try again later from the banner in your inbox."
    static let powerMessage = "Plug in your phone first: the battery is low."
    static let lessThanAMinuteRemaining = "Less than a minute remaining"
    static let almostDone = "Almost done"

    /// The notice's time: `minutes` from `DatabaseUpgrade.noticeMinutes`.
    static func noticeTime(minutes: Int) -> String {
        "It can take up to \(minutesText(minutes)). Keep TabMail open while it runs."
    }

    /// What the running screen says under the bar.
    static func remainingText(_ remaining: DatabaseUpgradeProgress.Remaining) -> String {
        switch remaining {
        case .minutes(let minutes): "About \(minutesText(minutes)) remaining"
        case .lessThanAMinute: lessThanAMinuteRemaining
        case .almostDone: almostDone
        }
    }

    private static func minutesText(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// The space free right now, not what iPhone Storage shows as available (which
    /// counts space iOS could purge): the upgrade writes its copy at once.
    static func spaceMessage(bytesNeeded: Int64) -> String {
        "TabMail needs \(ByteCountFormatter.string(fromByteCount: bytesNeeded, countStyle: .file)) free right now. Free up space, then try again."
    }

    /// Centred on the screen while it fits; at large text sizes the content keeps its
    /// full height and scrolls (#1589), so no text is cut off and every button stays
    /// reachable.
    var body: some View {
        GeometryReader { screen in
            ScrollView {
                VStack(spacing: 20) {
                    switch upgrade.screen {
                    case .notice: notice
                    case .upgrading: upgrading
                    case .done: result(title: Self.doneTitle, message: Self.doneMessage, symbol: "checkmark.circle.fill", tint: .green)
                    case .failed: result(title: Self.failedTitle, message: Self.failedMessage, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: screen.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.previewPaneBg)
        .keepScreenAwake(while: upgrade.screen == .upgrading)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                if upgrade.screen == .notice { await upgrade.refreshConditions() }
                await upgrade.appBecameActive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            guard upgrade.screen == .notice else { return }
            Task { await upgrade.refreshConditions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            guard upgrade.screen == .notice else { return }
            Task { await upgrade.refreshConditions() }
        }
    }

    private var notice: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(Self.noticeTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textColor)
            Text(Self.noticeWhat)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textColor)
            Text(Self.noticeTime(minutes: upgrade.noticeMinutes ?? SyncConfig.databaseUpgradeNoticeFallbackMinutes))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textMuted)
            if upgrade.showsSpaceMessage {
                warning(Self.spaceMessage(bytesNeeded: upgrade.bytesNeeded))
            }
            if upgrade.needsPower {
                warning(Self.powerMessage)
            }
            Button {
                Task { await upgrade.upgradeNow() }
            } label: {
                Text(Self.upgradeNowTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!upgrade.canStart)
            Button(Self.laterTitle) { upgrade.later() }
                .controlSize(.large)
        }
    }

    /// Recomputed every `SyncConfig.databaseUpgradeProgressRefreshSeconds`, and at once
    /// when a database finishes (`DatabaseUpgrade.progress` is observed).
    private var upgrading: some View {
        TimelineView(.periodic(from: .now, by: SyncConfig.databaseUpgradeProgressRefreshSeconds)) { _ in
            DatabaseUpgradeRunningContent(progress: upgrade.progress?.progress(at: .now))
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func result(title: String, message: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textColor)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textMuted)
            Button {
                upgrade.close()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

/// The running screen's content: the title, the bar and the minutes left. Before the
/// run has read the databases' data (`progress` nil) the bar is empty and no time shows.
struct DatabaseUpgradeRunningContent: View {
    let progress: DatabaseUpgradeProgress?

    var body: some View {
        VStack(spacing: 16) {
            Text(DatabaseUpgradeView.upgradingTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textColor)
            ProgressView(value: progress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text(DatabaseUpgradeView.upgradingTitle))
            if let progress {
                Text(DatabaseUpgradeView.remainingText(progress.remaining))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textColor)
                    .monospacedDigit()
            }
            Text(DatabaseUpgradeView.upgradingHint)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textMuted)
        }
    }
}
