/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// The one-time database upgrade's screen (ADR-IOS-121), full screen: first the
/// notice (what it does, Upgrade now and Later), then, after Upgrade now, a spinner
/// with the screen kept awake (`keepScreenAwake`, as Fast Sync), then the result.
/// State and actions are `DatabaseUpgrade`'s.
struct DatabaseUpgradeView: View {
    @Bindable var upgrade: DatabaseUpgrade

    @Environment(\.scenePhase) private var scenePhase

    static let noticeTitle = "Database update"
    static let noticeWhat = "For the best experience, TabMail needs to update your database."
    static let noticeTime = "It takes up to about 5 minutes. Keep TabMail open while it runs."
    static let upgradeNowTitle = "Update now"
    static let laterTitle = "Later"
    static let upgradingTitle = "Updating your database."
    static let upgradingHint = "Keep TabMail open."
    static let doneTitle = "Update complete"
    static let doneMessage = "Your database is up to date."
    static let failedTitle = "The update could not finish"
    static let failedMessage = "Nothing was lost. You can try again later from the banner in your inbox."
    static let powerMessage = "Plug in your phone first: the battery is low."

    /// The space free right now, not what iPhone Storage shows as available (which
    /// counts space iOS could purge): the upgrade writes its copy at once.
    static func spaceMessage(bytesNeeded: Int64) -> String {
        "TabMail needs \(ByteCountFormatter.string(fromByteCount: bytesNeeded, countStyle: .file)) free right now. Free up space, then try again."
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            switch upgrade.screen {
            case .notice: notice
            case .upgrading: upgrading
            case .done: result(title: Self.doneTitle, message: Self.doneMessage, symbol: "checkmark.circle.fill", tint: .green)
            case .failed: result(title: Self.failedTitle, message: Self.failedMessage, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundStyle(Palette.textColor)
            Text(Self.noticeWhat)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textColor)
            Text(Self.noticeTime)
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

    private var upgrading: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(Self.upgradingTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textColor)
            Text(Self.upgradingHint)
                .foregroundStyle(Palette.textMuted)
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
