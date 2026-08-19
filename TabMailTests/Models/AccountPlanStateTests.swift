/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Fixtures are shaped exactly like a `/whoami` body and decoded through the real
/// `AccountInfo` parser, so these tests pin the derivation the app actually runs —
/// not a hand-built struct that could drift from the wire format.
///
/// Every timestamp is computed from `Date()` at run time. A hardcoded date would
/// quietly go stale and start failing for reasons unrelated to the logic.
enum WhoamiFixture {
    /// Build a `/whoami` payload. `trialEnd` is an absolute date; pass `nil` for
    /// the `trial` object to be omitted entirely (today's shipped shape).
    static func accountInfo(
        hasSubscription: Bool?,
        planTier: String? = nil,
        isTrial: Bool? = nil,
        trialEnd: Date? = nil,
        includeTrialEnd: Bool = true
    ) throws -> AccountInfo {
        var json: [String: Any] = ["logged_in": true]
        if let hasSubscription { json["has_subscription"] = hasSubscription }
        if let planTier { json["plan_tier"] = planTier }
        if let isTrial {
            var trial: [String: Any] = ["is_trial": isTrial]
            if includeTrialEnd, let trialEnd {
                trial["trial_end"] = Int(trialEnd.timeIntervalSince1970)
            }
            json["trial"] = trial
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(AccountInfo.self, from: data)
    }

    /// A date `days` whole days away from `reference` (negative = in the past).
    static func date(daysFromNow days: Double, reference: Date) -> Date {
        reference.addingTimeInterval(days * AccountPlanConfig.secondsPerDay)
    }
}

@Suite("AccountInfo trial state")
struct AccountInfoTrialStateTests {

    @Test("Running trial reports the whole days remaining")
    func activeTrialReportsDaysRemaining() throws {
        let now = Date()
        let daysLeft = 10
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: Double(daysLeft), reference: now)
        )
        #expect(info.trialState(now: now) == .active(daysRemaining: daysLeft))
    }

    @Test("A trial in its final hours still reads as one day left, never zero")
    func finalHoursReportOneDayLeft() throws {
        let now = Date()
        let twoHours: TimeInterval = 2 * 60 * 60
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: now.addingTimeInterval(twoHours)
        )
        #expect(info.trialState(now: now) == .active(daysRemaining: 1))
    }

    @Test("Past trial end with no subscription is the ended state")
    func expiredTrialWithoutSubscriptionIsEnded() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: false,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: -1, reference: now)
        )
        #expect(info.trialState(now: now) == .ended)
    }

    @Test("Past trial end while subscribed is not an ended trial — it is just a subscriber")
    func expiredTrialWithSubscriptionIsNotEnded() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: "Pro",
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: -30, reference: now)
        )
        #expect(info.trialState(now: now) == .noTrial)
    }

    @Test("No trial object — today's shipped response shape — stays neutral")
    func missingTrialObjectIsNeutral() throws {
        let now = Date()
        let subscribed = try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Basic")
        let unsubscribed = try WhoamiFixture.accountInfo(hasSubscription: false)
        #expect(subscribed.trialState(now: now) == .noTrial)
        #expect(unsubscribed.trialState(now: now) == .noTrial)
    }

    @Test("Trial object without an end date cannot be dated, so it stays neutral")
    func trialWithoutEndDateIsNeutral() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: false,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: nil,
            includeTrialEnd: false
        )
        #expect(info.trialState(now: now) == .noTrial)
    }

    @Test("is_trial false is never a trial, whatever the end date says")
    func isTrialFalseIsNeutral() throws {
        let now = Date()
        let future = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            isTrial: false,
            trialEnd: WhoamiFixture.date(daysFromNow: 5, reference: now)
        )
        let past = try WhoamiFixture.accountInfo(
            hasSubscription: false,
            isTrial: false,
            trialEnd: WhoamiFixture.date(daysFromNow: -5, reference: now)
        )
        #expect(future.trialState(now: now) == .noTrial)
        #expect(past.trialState(now: now) == .noTrial)
    }
}

@Suite("Zero-budget plan quota display")
struct ZeroBudgetPlanTests {

    @Test("BYOK and Trial are the zero-budget plans; budgeted plans are not")
    func tierMapping() {
        #expect(ZeroBudgetPlan.forTier(AccountPlanConfig.byokTierKey) == .zero)
        #expect(ZeroBudgetPlan.forTier(AccountPlanConfig.trialTierKey) == .trial)
        #expect(ZeroBudgetPlan.forTier("Basic") == nil)
        #expect(ZeroBudgetPlan.forTier("Pro") == nil)
        #expect(ZeroBudgetPlan.forTier(nil) == nil)
        #expect(ZeroBudgetPlan.forTier("Something Else") == nil)
    }

    @Test("Each zero-budget plan explains itself in its own words")
    func captionsArePlanSpecific() {
        let zero = ZeroBudgetPlan.zero.quotaCaption
        let trial = ZeroBudgetPlan.trial.quotaCaption
        #expect(zero != trial)
        #expect(zero.contains("Zero"))
        #expect(zero.contains("your own keys"))
        #expect(trial.contains("Free Trial"))
        #expect(trial.contains("shared queue"))
        #expect(trial.contains("priority"))
        // The trial caption must not inherit the BYOK story — a trial user has
        // no keys of their own to run on.
        #expect(!trial.contains("your own keys"))
    }
}

@Suite("Subscription status badge")
@MainActor
struct SubscriptionStatusBadgeTests {

    @Test("Running trial badge carries the days remaining")
    func activeTrialBadge() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: 7, reference: now)
        )
        let label = SubscriptionStatusView.trialBadgeLabel(for: info)
        #expect(label == "Trial · 7 days left")
    }

    @Test("A one-day trial badge uses the singular unit")
    func singularDayBadge() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: now.addingTimeInterval(60 * 60)
        )
        let label = SubscriptionStatusView.trialBadgeLabel(for: info)
        #expect(label == "Trial · 1 day left")
    }

    @Test("A trial with no end date keeps today's plain badge")
    func plainTrialBadge() throws {
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: nil,
            includeTrialEnd: false
        )
        #expect(SubscriptionStatusView.trialBadgeLabel(for: info) == "Trial")
    }

    @Test("No trial information means no badge — today's behaviour is unchanged")
    func noBadgeWithoutTrial() throws {
        let info = try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Pro")
        #expect(SubscriptionStatusView.trialBadgeLabel(for: info) == nil)
    }

    @Test("An expired trial reads as ended")
    func endedTrialBadge() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: false,
            planTier: AccountPlanConfig.trialTierKey,
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: -2, reference: now)
        )
        #expect(SubscriptionStatusView.trialBadgeLabel(for: info) == "Trial ended")
    }
}

@Suite("AI subscription gate — trial copy signal", .serialized, .processGlobalState)
@MainActor
struct AISubscriptionGateTrialTests {

    /// Restores the gate's trial flag so this suite leaves no residue for the
    /// other suites that share the singleton.
    private func withRestoredGate(_ body: () throws -> Void) rethrows {
        let gate = AISubscriptionGate.shared
        let originalActive = gate.isActive
        let originalEnded = gate.trialHasEnded
        defer {
            if originalActive { gate.openGate() } else { gate.closeGate() }
            restore(endedFlag: originalEnded)
        }
        try body()
    }

    private func restore(endedFlag: Bool) {
        let gate = AISubscriptionGate.shared
        guard gate.trialHasEnded != endedFlag else { return }
        // The flag is only written through `apply`, so drive it back with a
        // fixture that produces the wanted value.
        let now = Date()
        let info: AccountInfo?
        if endedFlag {
            info = try? WhoamiFixture.accountInfo(
                hasSubscription: false,
                planTier: AccountPlanConfig.trialTierKey,
                isTrial: true,
                trialEnd: WhoamiFixture.date(daysFromNow: -1, reference: now)
            )
        } else {
            info = try? WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Pro")
        }
        if let info { gate.apply(info, now: now) }
    }

    @Test("An expired trial raises the ended flag and closes the gate")
    func expiredTrialRaisesFlag() throws {
        try withRestoredGate {
            let now = Date()
            let info = try WhoamiFixture.accountInfo(
                hasSubscription: false,
                planTier: AccountPlanConfig.trialTierKey,
                isTrial: true,
                trialEnd: WhoamiFixture.date(daysFromNow: -1, reference: now)
            )
            AISubscriptionGate.shared.apply(info, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == true)
            #expect(AISubscriptionGate.shared.isActive == false)
        }
    }

    @Test("A running trial is active access and never raises the ended flag")
    func runningTrialKeepsFlagDown() throws {
        try withRestoredGate {
            let now = Date()
            let expired = try WhoamiFixture.accountInfo(
                hasSubscription: false,
                planTier: AccountPlanConfig.trialTierKey,
                isTrial: true,
                trialEnd: WhoamiFixture.date(daysFromNow: -1, reference: now)
            )
            AISubscriptionGate.shared.apply(expired, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == true)

            let running = try WhoamiFixture.accountInfo(
                hasSubscription: true,
                planTier: AccountPlanConfig.trialTierKey,
                isTrial: true,
                trialEnd: WhoamiFixture.date(daysFromNow: 5, reference: now)
            )
            AISubscriptionGate.shared.apply(running, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == false)
            #expect(AISubscriptionGate.shared.isActive == true)
        }
    }

    @Test("A response with no trial information leaves the flag down")
    func noTrialInformationLeavesFlagDown() throws {
        try withRestoredGate {
            let now = Date()
            let info = try WhoamiFixture.accountInfo(hasSubscription: false)
            AISubscriptionGate.shared.apply(info, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == false)
            #expect(AISubscriptionGate.shared.isActive == false)
        }
    }

    @Test("Bare closeGate does not clobber the ended flag — it carries no trial information")
    func bareCloseGateLeavesFlagAlone() throws {
        try withRestoredGate {
            let now = Date()
            let expired = try WhoamiFixture.accountInfo(
                hasSubscription: false,
                planTier: AccountPlanConfig.trialTierKey,
                isTrial: true,
                trialEnd: WhoamiFixture.date(daysFromNow: -1, reference: now)
            )
            AISubscriptionGate.shared.apply(expired, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == true)

            // The AI 402/403 paths call this directly with no whoami body.
            AISubscriptionGate.shared.openGate()
            AISubscriptionGate.shared.closeGate()
            #expect(AISubscriptionGate.shared.trialHasEnded == true)
        }
    }
}
