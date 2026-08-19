/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct SubscriptionStatusView: View {
    let accountInfo: AccountInfo?

    var body: some View {
        if let info = accountInfo, info.hasSubscription == true {
            HStack(spacing: 8) {
                // Plan pill (display-mapped: backend "BYOK" renders as "Zero",
                // "Trial" as "Free Trial")
                Text(info.planTier.map { StoreKitManager.displayPlanName(forTier: $0) } ?? "Plan")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                // Trial badge, with the remaining days when we can compute them
                if let label = Self.trialBadgeLabel(for: info) {
                    Text(label)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }

                // Cancellation countdown
                if let cancellation = info.pendingCancellation, cancellation.cancelAt != nil {
                    let label = cancellation.cancelAtFormatted ?? cancellation.cancelAt.map { formatTimestamp($0) } ?? ""
                    Text("Cancels \(label)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
        } else if let info = accountInfo, info.trialState() == .ended {
            // No subscription, but this account did have a trial and it ran out.
            HStack(spacing: 8) {
                Text(Self.trialEndedBadgeText)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())

                Spacer()
            }
        }
    }

    /// Shared by both render paths so the ended-trial wording has one definition.
    static let trialEndedBadgeText = "Trial ended"

    /// Badge text for a subscribed account's trial, or `nil` when no trial badge
    /// belongs on the row.
    ///
    /// - An `active` trial reads "Trial · N days left" so the user can see the
    ///   clock without opening the dashboard.
    /// - An account marked `is_trial` whose end date we cannot derive (missing
    ///   `trial_end`) keeps today's plain "Trial" badge.
    /// - `now` is not injected here: the view reads the wall clock, and the
    ///   day arithmetic itself is covered by `AccountInfo.trialState(now:)`.
    static func trialBadgeLabel(for info: AccountInfo) -> String? {
        switch info.trialState() {
        case .active(let daysRemaining):
            return "Trial · \(daysRemaining) \(daysRemaining == 1 ? "day" : "days") left"
        case .ended:
            return Self.trialEndedBadgeText
        case .noTrial:
            guard let trial = info.trial, trial.isTrial else { return nil }
            return "Trial"
        }
    }

    private func formatTimestamp(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }
}
