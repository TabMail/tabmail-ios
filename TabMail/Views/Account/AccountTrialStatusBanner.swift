/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The real account/plan consumer, usable without loading billing over the network.
struct AccountTrialStatusBanner: View {
    enum Context { case account, plans }
    let accountInfo: AccountInfo?
    let context: Context
    var now = Date()

    var presentation: (icon: String, text: String, color: Color)? {
        switch accountInfo?.trialState(now: now) {
        case .active(let days):
            let remaining = "\(days) \(days == 1 ? "day" : "days") left"
            let text = context == .account ? "Free trial · \(remaining)"
                : "Card-free trial · \(remaining). Eligible subscriptions start a new free period at purchase, shown on each plan. Your existing expiry won't be brought forward."
            return ("clock", text, .blue)
        case .ended:
            let text = context == .account ? "Your free trial has ended — subscribe to continue"
                : "Your free trial has ended — subscribe to continue using AI features."
            return ("clock.badge.exclamationmark", text, .orange)
        default:
            guard let end = accountInfo?.subscriptionTrialEnd(now: now) else { return nil }
            let date = end.formatted(date: .abbreviated, time: .omitted)
            let cancelled = accountInfo?.pendingCancellation != nil
            if context == .account {
                return ("clock", "Subscription trial until \(date). " + (cancelled
                    ? "Renewal is cancelled." : "Payment begins when the trial ends unless cancelled."), .blue)
            }
            return ("clock", "Subscription trial ends \(date). " + (cancelled
                ? "Renewal is cancelled." : "Payment begins afterward unless cancelled."), .blue)
        }
    }

    var body: some View {
        if let presentation {
            StatusBanner(icon: presentation.icon, text: presentation.text, color: presentation.color)
        }
    }
}
