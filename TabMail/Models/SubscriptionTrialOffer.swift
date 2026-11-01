/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A free offer actually returned by StoreKit for an eligible Apple ID.
/// Kept separate from the backend's card-free signup trial.
struct SubscriptionTrialOffer: Equatable, Sendable {
    private static let daysPerWeek = 7
    enum Unit: Sendable { case day, week, month, year }
    let value: Int
    let unit: Unit

    var durationDescription: String {
        let name: String
        switch unit {
        case .day: name = "day"
        case .week: name = "week"
        case .month: name = "month"
        case .year: name = "year"
        }
        return "\(value) \(name)\(value == 1 ? "" : "s")"
    }

    func endDate(from now: Date, calendar: Calendar = .current) -> Date? {
        guard value > 0 else { return nil }
        let component: Calendar.Component
        switch unit {
        case .day:
            return now.addingTimeInterval(TimeInterval(value) * AccountPlanConfig.secondsPerDay)
        case .week:
            return now.addingTimeInterval(TimeInterval(value * Self.daysPerWeek) * AccountPlanConfig.secondsPerDay)
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.date(byAdding: component, value: value, to: now)
    }
}

enum SubscriptionTrialPurchasePolicy {
    /// Never exchange an existing card-free trial for an earlier first charge.
    /// No account answer is uncertainty, not permission to purchase.
    static func restriction(
        account: AccountInfo?, offer: SubscriptionTrialOffer?, now: Date = Date()
    ) -> String? {
        guard let account else { return "Checking your current trial. Please try again shortly." }
        guard case .active = account.trialState(now: now),
              let end = account.trial?.trialEnd else { return nil }
        let promisedEnd = Date(timeIntervalSince1970: TimeInterval(end))
        if let offerEnd = offer?.endDate(from: now), offerEnd >= promisedEnd { return nil }
        return "Your current free trial lasts until \(promisedEnd.formatted(date: .abbreviated, time: .omitted)). Subscribe closer to its end to keep all your free time."
    }
}

extension AccountInfo {
    /// A purchased plan's free period is not a card-free signup trial and must
    /// keep the subscriber's normal plan-management controls.
    func subscriptionTrialEnd(now: Date = Date()) -> Date? {
        guard hasSubscription == true,
              subscriptionProvider == "apple" || subscriptionProvider == "stripe",
              planTier != AccountPlanConfig.trialTierKey,
              let trial, trial.isTrial, let end = trial.trialEnd else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(end))
        return date > now ? date : nil
    }
}
