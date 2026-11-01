/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Display-only, in-memory copy of an authoritative free-period deadline.
/// Never controls access and never assumes a configured trial duration.
struct TrialCountdownNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case signup, subscription }
    let kind: Kind
    let end: Date
    let renewalCancelled: Bool

    struct Presentation: Equatable {
        let title: String
        let detail: String
        let actionTitle: String
    }

    static func from(_ account: AccountInfo, now: Date = Date()) -> Self? {
        guard account.planTier != AccountPlanConfig.byokTierKey else { return nil }
        if case .active = account.trialState(now: now), let end = account.trial?.trialEnd {
            return Self(kind: .signup, end: Date(timeIntervalSince1970: TimeInterval(end)), renewalCancelled: false)
        }
        if let end = account.subscriptionTrialEnd(now: now) {
            return Self(kind: .subscription, end: end, renewalCancelled: account.pendingCancellation != nil)
        }
        return nil
    }

    func presentation(now: Date) -> Presentation? {
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let date = end.formatted(date: .abbreviated, time: .omitted)
        switch kind {
        case .signup:
            let days = max(1, Int(ceil(remaining / AccountPlanConfig.secondsPerDay)))
            return Presentation(title: "Free trial · \(days) \(days == 1 ? "day" : "days") left",
                                detail: "Ends \(date)", actionTitle: "Plans")
        case .subscription:
            return Presentation(title: "Free until \(date)",
                                detail: renewalCancelled ? "Renewal is cancelled." : "Payment begins afterward unless cancelled.",
                                actionTitle: "Manage")
        }
    }
}
