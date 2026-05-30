/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AccountInfo")
struct AccountInfoTests {

    @Test("Decodes full response with snake_case keys")
    func decodesFullResponse() throws {
        let json = """
        {
            "logged_in": true,
            "has_subscription": true,
            "email": "user@example.com",
            "plan_tier": "pro",
            "subscription_status": "active",
            "subscription_provider": "stripe",
            "quota_percentage": 0.45,
            "used_cost_cents": 250.0,
            "limit_cost_cents": 1000.0,
            "billing_period_end": 1700000000.0,
            "billing_period_start": 1697000000.0,
            "max_monthly_cost_cents": 999.0,
            "consent_required": false
        }
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.loggedIn == true)
        #expect(info.hasSubscription == true)
        #expect(info.email == "user@example.com")
        #expect(info.planTier == "pro")
        #expect(info.subscriptionStatus == "active")
        #expect(info.quotaPercentage == 0.45)
    }

    @Test("Decodes minimal response (logged_in only)")
    func decodesMinimalResponse() throws {
        let json = """
        {"logged_in": false}
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.loggedIn == false)
        #expect(info.hasSubscription == nil)
        #expect(info.email == nil)
        #expect(info.planTier == nil)
    }

    @Test("Decodes trial info")
    func decodesTrialInfo() throws {
        let json = """
        {
            "logged_in": true,
            "trial": {"is_trial": true, "trial_end": 1700000000}
        }
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.trial?.isTrial == true)
        #expect(info.trial?.trialEnd == 1700000000)
    }

    @Test("Decodes pending cancellation")
    func decodesPendingCancellation() throws {
        let json = """
        {
            "logged_in": true,
            "pending_cancellation": {"cancel_at": 1700000000, "cancel_at_formatted": "Nov 14, 2023"}
        }
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.pendingCancellation?.cancelAt == 1700000000)
        #expect(info.pendingCancellation?.cancelAtFormatted == "Nov 14, 2023")
    }

    @Test("Decodes pending downgrade")
    func decodesPendingDowngrade() throws {
        let json = """
        {
            "logged_in": true,
            "pending_downgrade": {"to_plan": "free", "effective_at": 1700000000, "change_type": "downgrade"}
        }
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.pendingDowngrade?.toPlan == "free")
        #expect(info.pendingDowngrade?.changeType == "downgrade")
    }

    @Test("Decodes consent info")
    func decodesConsentInfo() throws {
        let json = """
        {
            "logged_in": true,
            "consent_required": true,
            "consent": {"confirmed_age_18": true, "agreed_to_terms": true, "agreed_to_privacy": false},
            "consent_path": "/consent"
        }
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.consentRequired == true)
        #expect(info.consent?.confirmedAge18 == true)
        #expect(info.consent?.agreedToPrivacy == false)
        #expect(info.consentPath == "/consent")
    }
}

@Suite("UsageStats")
struct UsageStatsTests {

    @Test("Decodes usage stats with daily breakdown")
    func decodesUsageStats() throws {
        let json = """
        {
            "today": {"calls": 10, "tokens_input": 5000, "tokens_output": 2000, "tokens_total": 7000, "cost_cents": 0.5},
            "daily_stats": [
                {"date": "2024-01-01", "calls": 5, "tokens_input": 2500, "tokens_output": 1000, "tokens_total": 3500, "cost_cents": 0.25}
            ]
        }
        """
        let stats = try JSONDecoder().decode(UsageStats.self, from: json.data(using: .utf8)!)
        #expect(stats.today.calls == 10)
        #expect(stats.today.tokensTotal == 7000)
        #expect(stats.dailyStats.count == 1)
        #expect(stats.dailyStats[0].date == "2024-01-01")
    }

    @Test("DayStats defaults to 0 for missing fields")
    func dayStatsDefaults() throws {
        let json = """
        {"date": "2024-01-01"}
        """
        let day = try JSONDecoder().decode(DayStats.self, from: json.data(using: .utf8)!)
        #expect(day.calls == 0)
        #expect(day.tokensInput == 0)
        #expect(day.tokensOutput == 0)
        #expect(day.tokensTotal == 0)
        #expect(day.costCents == 0)
    }

    @Test("DayStats id uses date or 'today'")
    func dayStatsId() throws {
        let withDate = try JSONDecoder().decode(DayStats.self, from: """
        {"date": "2024-03-13"}
        """.data(using: .utf8)!)
        #expect(withDate.id == "2024-03-13")

        let withoutDate = try JSONDecoder().decode(DayStats.self, from: """
        {"calls": 0, "tokens_input": 0, "tokens_output": 0, "tokens_total": 0, "cost_cents": 0}
        """.data(using: .utf8)!)
        #expect(withoutDate.id == "today")
    }
}
