/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - /whoami Response

struct AccountInfo: Decodable, Sendable {
    let loggedIn: Bool
    let hasSubscription: Bool?
    let email: String?
    let planTier: String?
    let trial: TrialInfo?
    let subscriptionStatus: String?
    let pendingCancellation: PendingCancellation?
    let pendingDowngrade: PendingDowngrade?
    let subscriptionProvider: String?
    let quotaPercentage: Double?
    let queueMode: String?
    let usedCostCents: Double?
    let limitCostCents: Double?
    /// Unix timestamp (seconds)
    let billingPeriodEnd: Double?
    /// Unix timestamp (seconds)
    let billingPeriodStart: Double?
    let maxMonthlyCostCents: Double?
    let consentRequired: Bool?
    let consent: ConsentInfo?
    let consentPath: String?

    enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
        case hasSubscription = "has_subscription"
        case email
        case planTier = "plan_tier"
        case trial
        case subscriptionStatus = "subscription_status"
        case pendingCancellation = "pending_cancellation"
        case pendingDowngrade = "pending_downgrade"
        case subscriptionProvider = "subscription_provider"
        case quotaPercentage = "quota_percentage"
        case queueMode = "queue_mode"
        case usedCostCents = "used_cost_cents"
        case limitCostCents = "limit_cost_cents"
        case billingPeriodEnd = "billing_period_end"
        case billingPeriodStart = "billing_period_start"
        case maxMonthlyCostCents = "max_monthly_cost_cents"
        case consentRequired = "consent_required"
        case consent
        case consentPath = "consent_path"
    }
}

struct ConsentInfo: Decodable, Sendable {
    let confirmedAge18: Bool?
    let agreedToTerms: Bool?
    let agreedToPrivacy: Bool?

    enum CodingKeys: String, CodingKey {
        case confirmedAge18 = "confirmed_age_18"
        case agreedToTerms = "agreed_to_terms"
        case agreedToPrivacy = "agreed_to_privacy"
    }
}

struct TrialInfo: Decodable, Sendable {
    let isTrial: Bool
    /// Unix timestamp (seconds)
    let trialEnd: Int?

    enum CodingKeys: String, CodingKey {
        case isTrial = "is_trial"
        case trialEnd = "trial_end"
    }
}

struct PendingCancellation: Decodable, Sendable {
    /// Unix timestamp (seconds)
    let cancelAt: Int?
    let cancelAtFormatted: String?

    enum CodingKeys: String, CodingKey {
        case cancelAt = "cancel_at"
        case cancelAtFormatted = "cancel_at_formatted"
    }
}

struct PendingDowngrade: Decodable, Sendable {
    let toPlan: String?
    /// Unix timestamp (seconds)
    let effectiveAt: Int?
    let effectiveAtFormatted: String?
    let changeType: String?

    enum CodingKeys: String, CodingKey {
        case toPlan = "to_plan"
        case effectiveAt = "effective_at"
        case effectiveAtFormatted = "effective_at_formatted"
        case changeType = "change_type"
    }
}

// MARK: - /usage/stats Response

struct UsageStats: Decodable, Sendable {
    let today: DayStats
    let dailyStats: [DayStats]

    enum CodingKeys: String, CodingKey {
        case today
        case dailyStats = "daily_stats"
    }
}

struct DayStats: Decodable, Sendable, Identifiable {
    let date: String?
    let calls: Double
    let tokensInput: Double
    let tokensOutput: Double
    let tokensTotal: Double
    let costCents: Double

    var id: String { date ?? "today" }

    enum CodingKeys: String, CodingKey {
        case date
        case calls
        case tokensInput = "tokens_input"
        case tokensOutput = "tokens_output"
        case tokensTotal = "tokens_total"
        case costCents = "cost_cents"
    }

    init(date: String?, calls: Double, tokensInput: Double, tokensOutput: Double, tokensTotal: Double, costCents: Double) {
        self.date = date
        self.calls = calls
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
        self.tokensTotal = tokensTotal
        self.costCents = costCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        calls = (try? container.decode(Double.self, forKey: .calls)) ?? 0
        tokensInput = (try? container.decode(Double.self, forKey: .tokensInput)) ?? 0
        tokensOutput = (try? container.decode(Double.self, forKey: .tokensOutput)) ?? 0
        tokensTotal = (try? container.decode(Double.self, forKey: .tokensTotal)) ?? 0
        costCents = (try? container.decode(Double.self, forKey: .costCents)) ?? 0
    }
}
