/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Tuning constants for the plan/trial display derivations below.
/// (No hardcoded numerics at the call sites — see the repo's development rules.)
enum AccountPlanConfig {
    /// Seconds in a day, used to convert a trial-end timestamp into whole days.
    static let secondsPerDay: TimeInterval = 86_400
    /// Backend tier string for the server-granted free trial.
    static let trialTierKey = "Trial"
    /// Backend tier string for the bring-your-own-key plan (displayed as "Zero").
    static let byokTierKey = "BYOK"
    /// Backend tier string for the entry paid plan.
    static let basicTierKey = "Basic"
    /// Backend tier string for the top paid plan.
    static let proTierKey = "Pro"
    /// Backend tier string used when no tier could be resolved.
    static let unknownTierKey = "Unknown"
    /// `subscription_provider` value that marks the server-granted signup trial —
    /// as opposed to a purchase made through a payment provider.
    static let signupProviderKey = "signup"
}

/// The account's free-trial state as the CLIENT sees it.
///
/// Derived **only** from fields `/whoami` already returns — `has_subscription`,
/// `plan_tier`, and the existing `trial` object (`is_trial` / `trial_end`).
/// There is no "trial ended" flag on the wire and none is expected.
///
/// This enum describes the **server-granted signup trial** and nothing else. A
/// legacy card trial — a Stripe or Apple subscription still inside its
/// introductory period — also carries a `trial` object, but it is a purchased
/// plan on tier `Basic`/`Pro`, and every surface must keep treating it as the
/// ordinary subscription it is. `plan_tier == "Trial"` is what separates the
/// two, so `.active` requires it.
///
/// The case is spelled `noTrial`, not `none`, to stay clear of the
/// `Optional.none` shadowing trap this codebase has been bitten by before.
enum TrialState: Equatable {
    /// No signup-trial story on the response — including a paid subscriber,
    /// with or without a card trial of their own.
    case noTrial
    /// A signup trial that is still running. `daysRemaining` is at least 1 and
    /// rounds UP, so the last partial day still reads "1 day left" rather
    /// than "0".
    case active(daysRemaining: Int)
    /// The trial's end date has passed and the account has no subscription.
    case ended
}

extension AccountInfo {
    /// Resolve the client-visible trial state from the decoded `/whoami` fields.
    ///
    /// The two wire shapes this reads:
    ///
    /// - **Running signup trial** — `has_subscription: true`, `plan_tier:
    ///   "Trial"`, `subscription_provider: "signup"`, and a `trial` object whose
    ///   `trial_end` is in the future. `plan_tier` is the discriminator: without
    ///   it a legacy Stripe/Apple card trial (`plan_tier` `Basic`/`Pro`, also
    ///   carrying a `trial` object with a future end) would read as `.active`
    ///   and flip that subscriber's dashboard and paywall copy.
    /// - **Expired signup trial** — `has_subscription: false` and the `trial`
    ///   KEY still present, though its value may be an explicit `null` and both
    ///   `plan_tier` and `subscription_provider` are dropped. Every other
    ///   no-subscription state omits the key entirely, so key presence is the
    ///   signal and `AccountInfo.trialKeyPresent` is what preserves it (a null
    ///   value and an absent key are the same `nil` to a synthesized decoder).
    ///   `is_trial` is deliberately NOT required here: it is not guaranteed on
    ///   the expired body, and the key's presence already carries the fact.
    ///
    /// - Parameter now: injected for tests; production callers use the default.
    func trialState(now: Date = Date()) -> TrialState {
        let endDate = trial?.trialEnd.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let remaining = endDate.map { $0.timeIntervalSince(now) }
        let isStillRunning = (remaining ?? 0) > 0

        // A running server-granted trial: active access the user did not buy.
        if hasSubscription == true,
           planTier == AccountPlanConfig.trialTierKey,
           let trial, trial.isTrial,
           let remaining, remaining > 0 {
            let days = Int(ceil(remaining / AccountPlanConfig.secondsPerDay))
            return .active(daysRemaining: max(days, 1))
        }

        // No subscription, but the response still mentioned a trial: it ran out.
        // A subscriber whose trial converted is just a subscriber, which is why
        // this arm requires `has_subscription != true` (nil included — an
        // absent authority is not an active subscription).
        if hasSubscription != true, trialKeyPresent, !isStillRunning {
            return .ended
        }

        return .noTrial
    }

    /// Denominator for the account dashboard's daily-quota chart, or `nil` when
    /// the chart must be hidden entirely.
    ///
    /// A zero-priority-budget plan reports `max_monthly_cost_cents` as an
    /// **explicit zero** rather than omitting it — Trial and BYOK both do — so
    /// the guard must reject zero, not merely absence. Every bar would otherwise
    /// divide by zero. The single definition also means the chart cannot be
    /// shown from one predicate and scaled by another (ADR-IOS-040 D6).
    var dailyQuotaChartDenominator: Double? {
        guard let maxMonthlyCostCents, maxMonthlyCostCents > 0 else { return nil }
        return maxMonthlyCostCents
    }
}

/// The plan picker's purchase-button copy, as a pure function so the decision
/// can be tested without building a `Product` or a SwiftUI view.
///
/// The card never advertises a StoreKit introductory offer: the App Store
/// Connect offers were removed when the server-granted signup trial launched
/// (2026-08-19), and the client-side trial-badge machinery that read them was
/// deleted with them (issue #55). The free trial a user sees today is the
/// server-granted one, described by the whoami-driven banner — not by the card.
enum PlanCardCTA {
    /// Purchase button text. Rank-driven upgrade/downgrade direction; ranks are
    /// passed in so this stays free of StoreKit.
    static func buttonLabel(
        hasAnyAppleSub: Bool,
        currentRank: Int,
        cardRank: Int
    ) -> String {
        guard hasAnyAppleSub else { return "Subscribe" }
        guard currentRank > 0 else { return "Switch" }
        if cardRank > currentRank { return "Upgrade" }
        if cardRank < currentRank { return "Downgrade" }
        return "Switch"
    }
}

/// Plans that carry **no** priority AI budget. A quota percentage is meaningless
/// for them, so the account dashboard renders "N/A" plus a plan-specific caption
/// instead of a progress bar (site dashboard precedent).
enum ZeroBudgetPlan: Equatable {
    /// Bring-your-own-key plan — displayed as "Zero".
    case zero
    /// Server-granted free trial — displayed as "Free Trial".
    case trial

    /// Map a backend tier string onto a zero-budget plan, or `nil` when the plan
    /// does have a priority budget (Basic / Pro / unknown).
    static func forTier(_ tier: String?) -> ZeroBudgetPlan? {
        switch tier {
        case AccountPlanConfig.byokTierKey: return .zero
        case AccountPlanConfig.trialTierKey: return .trial
        default: return nil
        }
    }

    /// Explanation shown under the "N/A" quota reading. Each plan needs its own:
    /// Zero has no budget because AI runs on the user's own keys, whereas a trial
    /// has no budget because it rides the shared queue until the user subscribes.
    var quotaCaption: String {
        switch self {
        case .zero:
            return "Zero includes no priority AI budget — AI runs on your own keys, or via the slower shared queue."
        case .trial:
            return "Free Trial runs on the shared queue — subscribe for priority AI speed."
        }
    }
}
