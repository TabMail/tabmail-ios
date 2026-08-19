/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct SubscriptionStatusView: View {
    let accountInfo: AccountInfo?

    var body: some View {
        if let info = accountInfo, info.hasSubscription == true {
            HStack(spacing: 8) {
                // Plan pill (display-mapped: backend "BYOK" renders as "Zero")
                Text(info.planTier.map { StoreKitManager.displayPlanName(forTier: $0) } ?? "Plan")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                // Trial badge
                if let trial = info.trial, trial.isTrial {
                    Text("Trial")
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
