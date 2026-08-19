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

    /// Whether the response carried a `trial` key **at all** — including one
    /// whose value is an explicit JSON `null`.
    ///
    /// Swift's synthesized decoding collapses "key absent" and "key present but
    /// null" into the same `nil`, but the wire distinguishes them and the
    /// distinction is load-bearing: an account whose free trial has run out
    /// reports no subscription **and still carries the `trial` key**, whose
    /// value may be null. Every other no-subscription state omits the key
    /// entirely. Without this flag an ended trial degrades to "no trial" and the
    /// ended-trial surfaces silently disappear. Not a wire field — never encoded,
    /// never sent — see `trialState(now:)` in `AccountPlanState.swift`.
    let trialKeyPresent: Bool

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

    /// Hand-written because `trialKeyPresent` cannot be synthesized: it records
    /// whether the `trial` KEY appeared, which the synthesized decoder throws
    /// away. Every other field decodes exactly as the synthesized initializer
    /// did (`decodeIfPresent` for the optionals, a required `logged_in`).
    ///
    /// ⚠️ A new stored property on this struct must be added here too — the
    /// compiler stops filling them in once this initializer exists.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loggedIn = try container.decode(Bool.self, forKey: .loggedIn)
        hasSubscription = try container.decodeIfPresent(Bool.self, forKey: .hasSubscription)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        planTier = try container.decodeIfPresent(String.self, forKey: .planTier)
        trial = try container.decodeIfPresent(TrialInfo.self, forKey: .trial)
        subscriptionStatus = try container.decodeIfPresent(String.self, forKey: .subscriptionStatus)
        pendingCancellation = try container.decodeIfPresent(PendingCancellation.self, forKey: .pendingCancellation)
        pendingDowngrade = try container.decodeIfPresent(PendingDowngrade.self, forKey: .pendingDowngrade)
        subscriptionProvider = try container.decodeIfPresent(String.self, forKey: .subscriptionProvider)
        quotaPercentage = try container.decodeIfPresent(Double.self, forKey: .quotaPercentage)
        queueMode = try container.decodeIfPresent(String.self, forKey: .queueMode)
        usedCostCents = try container.decodeIfPresent(Double.self, forKey: .usedCostCents)
        limitCostCents = try container.decodeIfPresent(Double.self, forKey: .limitCostCents)
        billingPeriodEnd = try container.decodeIfPresent(Double.self, forKey: .billingPeriodEnd)
        billingPeriodStart = try container.decodeIfPresent(Double.self, forKey: .billingPeriodStart)
        maxMonthlyCostCents = try container.decodeIfPresent(Double.self, forKey: .maxMonthlyCostCents)
        consentRequired = try container.decodeIfPresent(Bool.self, forKey: .consentRequired)
        consent = try container.decodeIfPresent(ConsentInfo.self, forKey: .consent)
        consentPath = try container.decodeIfPresent(String.self, forKey: .consentPath)
        // `contains` is true for an explicit null; `decodeIfPresent` above is not.
        trialKeyPresent = container.contains(.trial)
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
    /// Unix timestamp (seconds), or `nil` when the value is absent or is not a
    /// number we can use as one.
    let trialEnd: Int?

    enum CodingKeys: String, CodingKey {
        case isTrial = "is_trial"
        case trialEnd = "trial_end"
    }

    /// Decodes leniently, following `DayStats.init(from:)` below.
    ///
    /// `trial_end` is typed `string | number` upstream — historical webhook
    /// writers stored ISO strings — and a synthesized decoder throws
    /// `typeMismatch` on the string form. That throw does not fail just this
    /// object: it fails the WHOLE `/whoami` parse, so one legacy row would take
    /// the entire account screen down rather than degrading one field. A value
    /// we cannot read as an epoch becomes `nil` instead, which on a
    /// no-subscription body with the `trial` key present derives `.ended` — the
    /// correct fail-closed answer. `is_trial` likewise tolerates absence.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isTrial = (try? container.decode(Bool.self, forKey: .isTrial)) ?? false
        trialEnd = try? container.decodeIfPresent(Int.self, forKey: .trialEnd)
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
