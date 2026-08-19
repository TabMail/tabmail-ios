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
}

/// The account's free-trial state as the CLIENT sees it.
///
/// Derived **only** from fields `/whoami` already returns — `has_subscription`
/// and the existing `trial` object (`is_trial` / `trial_end`). There is no
/// "trial ended" flag on the wire and none is expected: an ended trial is
/// simply "no active subscription" plus a `trial_end` that is already in the
/// past. Any account whose response carries no `trial` object at all resolves
/// to `.noTrial`, so every surface behaves exactly as it does today until the
/// backend starts granting trials.
///
/// The case is spelled `noTrial`, not `none`, to stay clear of the
/// `Optional.none` shadowing trap this codebase has been bitten by before.
enum TrialState: Equatable {
    /// No trial information on the response (or the trial is not the account's
    /// current story — e.g. a paid subscriber whose old trial converted).
    case noTrial
    /// A trial that is still running. `daysRemaining` is at least 1 and rounds
    /// UP, so the last partial day still reads "1 day left" rather than "0".
    case active(daysRemaining: Int)
    /// The trial's end date has passed and the account has no subscription.
    case ended
}

extension AccountInfo {
    /// Resolve the client-visible trial state from the decoded `/whoami` fields.
    ///
    /// - Parameter now: injected for tests; production callers use the default.
    func trialState(now: Date = Date()) -> TrialState {
        guard let trial, trial.isTrial, let trialEnd = trial.trialEnd else { return .noTrial }
        let endDate = Date(timeIntervalSince1970: TimeInterval(trialEnd))
        let remaining = endDate.timeIntervalSince(now)
        guard remaining > 0 else {
            // Past the end date. It only reads as an ended trial while the
            // account has no active subscription — a subscriber whose trial
            // converted is just a subscriber.
            return hasSubscription == true ? .noTrial : .ended
        }
        let days = Int(ceil(remaining / AccountPlanConfig.secondsPerDay))
        return .active(daysRemaining: max(days, 1))
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
