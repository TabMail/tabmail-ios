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
/// The named builders below encode the THREE real shapes the backend emits, each
/// with the fields it actually carries and without the ones it does not:
///
/// | shape | `has_subscription` | `plan_tier` | `subscription_provider` | `trial` |
/// |---|---|---|---|---|
/// | running signup trial | `true` | `"Trial"` | `"signup"` | object |
/// | expired signup trial | `false` | *absent* | *absent* | key present, object **or null** |
/// | legacy card trial | `true` | `"Basic"`/`"Pro"` | `"stripe"`/`"apple"` | object |
///
/// Any other no-subscription state omits the `trial` key entirely. Getting these
/// shapes wrong is how a test can pass while the client misreads the live wire.
///
/// Every timestamp is computed from `Date()` at run time. A hardcoded date would
/// quietly go stale and start failing for reasons unrelated to the logic.
enum WhoamiFixture {
    /// General builder. `includeTrialKey` controls whether the `trial` KEY is
    /// emitted at all, which is a different question from whether it has a
    /// value — see `trialIsNull`.
    static func accountInfo(
        hasSubscription: Bool?,
        planTier: String? = nil,
        provider: String? = nil,
        isTrial: Bool? = nil,
        trialEnd: Date? = nil,
        includeTrialEnd: Bool = true,
        includeTrialKey: Bool = true,
        trialIsNull: Bool = false,
        maxMonthlyCostCents: Double? = nil
    ) throws -> AccountInfo {
        var json: [String: Any] = ["logged_in": true]
        if let hasSubscription { json["has_subscription"] = hasSubscription }
        if let planTier { json["plan_tier"] = planTier }
        if let provider { json["subscription_provider"] = provider }
        if let maxMonthlyCostCents { json["max_monthly_cost_cents"] = maxMonthlyCostCents }
        if trialIsNull {
            json["trial"] = NSNull()
        } else if let isTrial, includeTrialKey {
            var trial: [String: Any] = ["is_trial": isTrial]
            if includeTrialEnd, let trialEnd {
                trial["trial_end"] = Int(trialEnd.timeIntervalSince1970)
            }
            json["trial"] = trial
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(AccountInfo.self, from: data)
    }

    /// A running server-granted signup trial.
    static func runningSignupTrial(daysLeft: Double, reference: Date) throws -> AccountInfo {
        try accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            provider: AccountPlanConfig.signupProviderKey,
            isTrial: true,
            trialEnd: date(daysFromNow: daysLeft, reference: reference)
        )
    }

    /// An expired signup trial: the subscription is gone and the tier and
    /// provider are dropped, but the `trial` key survives — as an object when
    /// the entitlement still carries one, and as an explicit `null` when it
    /// does not.
    static func expiredSignupTrial(
        endedDaysAgo: Double,
        reference: Date,
        trialIsNull: Bool = false
    ) throws -> AccountInfo {
        try accountInfo(
            hasSubscription: false,
            isTrial: trialIsNull ? nil : true,
            trialEnd: date(daysFromNow: -endedDaysAgo, reference: reference),
            trialIsNull: trialIsNull
        )
    }

    /// A legacy Stripe/Apple card trial — a real purchased subscription that
    /// happens to be inside its introductory period. It is NOT a signup trial
    /// and every surface must keep treating it as the subscription it is.
    static func cardTrial(
        provider: String,
        planTier: String,
        daysLeft: Double,
        reference: Date
    ) throws -> AccountInfo {
        try accountInfo(
            hasSubscription: true,
            planTier: planTier,
            provider: provider,
            isTrial: true,
            trialEnd: date(daysFromNow: daysLeft, reference: reference)
        )
    }

    /// A signed-in account with no subscription and no trial mentioned at all —
    /// today's shipped shape for a lapsed or never-subscribed user.
    static func signedInWithoutSubscription() throws -> AccountInfo {
        try accountInfo(hasSubscription: false)
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
        let info = try WhoamiFixture.runningSignupTrial(daysLeft: Double(daysLeft), reference: now)
        #expect(info.trialState(now: now) == .active(daysRemaining: daysLeft))
    }

    @Test("A trial in its final hours still reads as one day left, never zero")
    func finalHoursReportOneDayLeft() throws {
        let now = Date()
        let twoHours: TimeInterval = 2 * 60 * 60
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            provider: AccountPlanConfig.signupProviderKey,
            isTrial: true,
            trialEnd: now.addingTimeInterval(twoHours)
        )
        #expect(info.trialState(now: now) == .active(daysRemaining: 1))
    }

    @Test("Past trial end with no subscription is the ended state")
    func expiredTrialWithoutSubscriptionIsEnded() throws {
        let now = Date()
        let info = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
        #expect(info.trialState(now: now) == .ended)
    }

    /// The fail-closed shape: the backend emits `trial: ent.trial ?? null`, so an
    /// expired trial can arrive with the KEY present and the VALUE null. Swift's
    /// synthesized decoding maps that to the same `nil` as an absent key, which
    /// would silently degrade the account to "no trial" and make every
    /// ended-trial surface vanish for exactly the users who need it.
    @Test("An explicit null trial value still reads as an ended trial")
    func nullTrialValueIsEnded() throws {
        let now = Date()
        let info = try WhoamiFixture.expiredSignupTrial(
            endedDaysAgo: 1,
            reference: now,
            trialIsNull: true
        )
        #expect(info.trial == nil)
        #expect(info.trialKeyPresent == true)
        #expect(info.trialState(now: now) == .ended)
    }

    /// `trial.trial_end` is typed `string | number` upstream — historical webhook
    /// writers stored ISO strings. A synthesized decoder throws `typeMismatch` on
    /// the string form, and that throw fails the ENTIRE `/whoami` parse: one
    /// legacy row would blank the whole account screen. It must degrade to an
    /// undatable trial instead, which on this body is the ended state.
    @Test("A string trial_end does not fail the whole response — it degrades to ended")
    func stringTrialEndDegradesRatherThanThrowing() throws {
        let json = """
        {
          "logged_in": true,
          "has_subscription": false,
          "trial": {"is_trial": true, "trial_end": "2027-01-01T00:00:00Z"}
        }
        """
        let info = try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
        #expect(info.loggedIn == true)
        #expect(info.trial?.isTrial == true)
        #expect(info.trial?.trialEnd == nil)
        #expect(info.trialKeyPresent == true)
        #expect(info.trialState(now: Date()) == .ended)
    }

    @Test("A trial object missing is_trial decodes as not-a-trial rather than failing")
    func missingIsTrialDecodes() throws {
        let json = #"{"logged_in": true, "has_subscription": true, "trial": {}}"#
        let info = try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
        #expect(info.trial?.isTrial == false)
        #expect(info.trial?.trialEnd == nil)
        #expect(info.trialKeyPresent == true)
        // Subscribed, so it is a subscriber and not an ended trial.
        #expect(info.trialState(now: Date()) == .noTrial)
    }

    @Test("An absent trial key is not an ended trial — it is no trial at all")
    func absentTrialKeyIsNeutral() throws {
        let now = Date()
        let info = try WhoamiFixture.signedInWithoutSubscription()
        #expect(info.trialKeyPresent == false)
        #expect(info.trialState(now: now) == .noTrial)
    }

    /// A legacy Stripe/Apple subscription inside its introductory period carries
    /// a `trial` object with a FUTURE end date and `has_subscription: true`, and
    /// is an ordinary paying subscriber. Reading it as a signup trial flips the
    /// dashboard's "Change Plan" action to "Subscribe", changes the banner, and
    /// puts a trial banner on the paywall for someone who already bought a plan.
    /// `plan_tier` is what separates the two.
    @Test("A legacy card trial is a subscription, not a signup trial")
    func cardTrialIsNotASignupTrial() throws {
        let now = Date()
        for (provider, tier) in [("stripe", "Basic"), ("apple", "Pro"), ("stripe", "Pro")] {
            let info = try WhoamiFixture.cardTrial(
                provider: provider,
                planTier: tier,
                daysLeft: 9,
                reference: now
            )
            #expect(info.trialState(now: now) == .noTrial)
            // And the paywall must not suppress Apple's introductory offer for
            // them — that suppression is scoped to running signup trials.
            #expect(PlanCardIntroOffer.suppressesIntroOffer(for: info, now: now) == false)
        }
    }

    @Test("Past trial end while subscribed is not an ended trial — it is just a subscriber")
    func expiredTrialWithSubscriptionIsNotEnded() throws {
        let now = Date()
        let info = try WhoamiFixture.cardTrial(
            provider: "stripe",
            planTier: "Pro",
            daysLeft: -30,
            reference: now
        )
        #expect(info.trialState(now: now) == .noTrial)
    }

    @Test("No trial object — today's shipped response shape — stays neutral")
    func missingTrialObjectIsNeutral() throws {
        let now = Date()
        let subscribed = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: "Basic",
            provider: "stripe"
        )
        let unsubscribed = try WhoamiFixture.signedInWithoutSubscription()
        #expect(subscribed.trialState(now: now) == .noTrial)
        #expect(unsubscribed.trialState(now: now) == .noTrial)
    }

    /// A subscribed account whose trial object has no end date cannot be dated,
    /// so it is not a RUNNING trial. It still has a subscription, so it is not
    /// an ended one either.
    @Test("A subscribed trial with no end date cannot be dated, so it stays neutral")
    func subscribedTrialWithoutEndDateIsNeutral() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            provider: AccountPlanConfig.signupProviderKey,
            isTrial: true,
            trialEnd: nil,
            includeTrialEnd: false
        )
        #expect(info.trialState(now: now) == .noTrial)
    }

    /// The unsubscribed counterpart resolves the other way, and deliberately so:
    /// the account has no subscription and the response still mentioned a trial,
    /// which is the ended shape. `is_trial` is not required on that body, so the
    /// derivation must not depend on it.
    @Test("An unsubscribed trial key with no usable end date fails closed to ended")
    func unsubscribedTrialWithoutEndDateIsEnded() throws {
        let now = Date()
        let noEndDate = try WhoamiFixture.accountInfo(
            hasSubscription: false,
            isTrial: true,
            trialEnd: nil,
            includeTrialEnd: false
        )
        let isTrialFalse = try WhoamiFixture.accountInfo(
            hasSubscription: false,
            isTrial: false,
            trialEnd: WhoamiFixture.date(daysFromNow: -5, reference: now)
        )
        #expect(noEndDate.trialState(now: now) == .ended)
        #expect(isTrialFalse.trialState(now: now) == .ended)
    }

    @Test("is_trial false with a future end date is never a running trial")
    func isTrialFalseIsNeverActive() throws {
        let now = Date()
        let future = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            provider: AccountPlanConfig.signupProviderKey,
            isTrial: false,
            trialEnd: WhoamiFixture.date(daysFromNow: 5, reference: now)
        )
        #expect(future.trialState(now: now) == .noTrial)
    }

    /// A missing `has_subscription` is an absent authority, not an active
    /// subscription, so it fails to the same side as an explicit `false`.
    @Test("A missing subscription authority with a trial key reads as ended")
    func missingSubscriptionAuthorityIsEnded() throws {
        let now = Date()
        let info = try WhoamiFixture.accountInfo(
            hasSubscription: nil,
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: -3, reference: now)
        )
        #expect(info.trialState(now: now) == .ended)
    }
}

@Suite("Daily quota chart denominator")
struct DailyQuotaChartTests {

    /// A zero-priority-budget plan reports `max_monthly_cost_cents` as an
    /// EXPLICIT zero rather than omitting it, so the guard has to reject zero
    /// and not merely absence — every bar would otherwise divide by zero.
    @Test("An explicit-zero monthly budget hides the chart for a trial account")
    func explicitZeroHidesChart() throws {
        let now = Date()
        let trial = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: AccountPlanConfig.trialTierKey,
            provider: AccountPlanConfig.signupProviderKey,
            isTrial: true,
            trialEnd: WhoamiFixture.date(daysFromNow: 7, reference: now),
            maxMonthlyCostCents: 0
        )
        #expect(trial.maxMonthlyCostCents == 0)
        #expect(trial.dailyQuotaChartDenominator == nil)
    }

    @Test("An absent budget also hides the chart; a positive one scales it")
    func absentAndPositiveBudgets() throws {
        let absent = try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Basic")
        #expect(absent.dailyQuotaChartDenominator == nil)

        let budgeted = try WhoamiFixture.accountInfo(
            hasSubscription: true,
            planTier: "Basic",
            provider: "stripe",
            maxMonthlyCostCents: 999
        )
        #expect(budgeted.dailyQuotaChartDenominator == 999)
    }
}

@Suite("Plan picker introductory offer")
struct PlanCardIntroOfferTests {

    /// While App Store Connect still carries the introductory offers, a user on
    /// a running signup trial would otherwise see "2 weeks free" and a "Start
    /// Free Trial" button on the same page as a banner saying their trial is
    /// running — and Apple would genuinely grant the offer on top.
    @Test("A running signup trial hides the intro offer and asks for a subscription")
    func runningSignupTrialSuppressesIntroOffer() throws {
        let now = Date()
        let info = try WhoamiFixture.runningSignupTrial(daysLeft: 9, reference: now)
        let suppressed = PlanCardIntroOffer.suppressesIntroOffer(for: info, now: now)
        #expect(suppressed == true)

        // Eligible group, product carries an offer, no Apple subscription: the
        // exact combination that shows the badge for everyone else.
        let showsBadge = PlanCardIntroOffer.showsTrialBadge(
            isEligibleForTrial: true,
            hasAnyAppleSub: false,
            hasIntroOffer: true,
            suppressesIntroOffer: suppressed
        )
        #expect(showsBadge == false)
        #expect(
            PlanCardIntroOffer.buttonLabel(
                showsTrialBadge: showsBadge,
                hasAnyAppleSub: false,
                currentRank: 0,
                cardRank: 2
            ) == "Subscribe"
        )
    }

    @Test("Every other account keeps today's intro-offer badge and call to action")
    func nonTrialAccountsAreUnchanged() throws {
        let now = Date()
        let controls: [AccountInfo?] = [
            nil,
            try WhoamiFixture.signedInWithoutSubscription(),
            try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 2, reference: now),
            try WhoamiFixture.cardTrial(provider: "apple", planTier: "Pro", daysLeft: 5, reference: now)
        ]
        for info in controls {
            let suppressed = PlanCardIntroOffer.suppressesIntroOffer(for: info, now: now)
            #expect(suppressed == false)
            let showsBadge = PlanCardIntroOffer.showsTrialBadge(
                isEligibleForTrial: true,
                hasAnyAppleSub: false,
                hasIntroOffer: true,
                suppressesIntroOffer: suppressed
            )
            #expect(showsBadge == true)
            #expect(
                PlanCardIntroOffer.buttonLabel(
                    showsTrialBadge: showsBadge,
                    hasAnyAppleSub: false,
                    currentRank: 0,
                    cardRank: 2
                ) == "Start Free Trial"
            )
        }
    }

    @Test("Suppression does not disturb the rank-driven upgrade direction")
    func rankDirectionIsUnchanged() {
        // No badge, an existing Apple subscriber: labels come from the ranks,
        // exactly as before.
        #expect(
            PlanCardIntroOffer.buttonLabel(
                showsTrialBadge: false, hasAnyAppleSub: true, currentRank: 2, cardRank: 3
            ) == "Upgrade"
        )
        #expect(
            PlanCardIntroOffer.buttonLabel(
                showsTrialBadge: false, hasAnyAppleSub: true, currentRank: 3, cardRank: 1
            ) == "Downgrade"
        )
        #expect(
            PlanCardIntroOffer.buttonLabel(
                showsTrialBadge: false, hasAnyAppleSub: true, currentRank: 2, cardRank: 2
            ) == "Switch"
        )
        #expect(
            PlanCardIntroOffer.buttonLabel(
                showsTrialBadge: false, hasAnyAppleSub: true, currentRank: 0, cardRank: 2
            ) == "Switch"
        )
    }

    @Test("A product with no introductory offer never shows the badge")
    func productWithoutOfferNeverBadges() {
        #expect(
            PlanCardIntroOffer.showsTrialBadge(
                isEligibleForTrial: true,
                hasAnyAppleSub: false,
                hasIntroOffer: false,
                suppressesIntroOffer: false
            ) == false
        )
    }
}

@Suite("Zero-budget plan quota display")
struct ZeroBudgetPlanTests {

    @Test("BYOK and Trial are the zero-budget plans; budgeted plans are not")
    func tierMapping() {
        #expect(ZeroBudgetPlan.forTier(AccountPlanConfig.byokTierKey) == .zero)
        #expect(ZeroBudgetPlan.forTier(AccountPlanConfig.trialTierKey) == .trial)
        #expect(ZeroBudgetPlan.forTier(AccountPlanConfig.basicTierKey) == nil)
        #expect(ZeroBudgetPlan.forTier(AccountPlanConfig.proTierKey) == nil)
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

@Suite("AI subscription gate — trial copy signal", .serialized, .processGlobalState)
@MainActor
struct AISubscriptionGateTrialTests {

    /// The real UserDefaults key the gate persists `isActive` to. Asserted
    /// directly because the residue this suite must not leave is a write to the
    /// user's own defaults, not just an in-memory flag.
    private static let lastKnownActiveKey = "ai_subscription_last_known_active"

    /// Restores the gate's trial flag so this suite leaves no residue for the
    /// other suites that share the singleton.
    private func withRestoredGate(_ body: () throws -> Void) rethrows {
        let gate = AISubscriptionGate.shared
        let originalActive = gate.isActive
        let originalEnded = gate.trialHasEnded
        defer {
            // ORDER MATTERS. `restore(endedFlag:)` drives the flag through
            // `apply`, which itself opens or closes the gate as a side effect —
            // so it must run BEFORE `isActive` is put back. Restoring `isActive`
            // first lets the restoring fixture reopen the gate afterwards and
            // persist a last-known-active the user never had.
            restore(endedFlag: originalEnded)
            if originalActive { gate.openGate() } else { gate.closeGate() }
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
            info = try? WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
        } else {
            info = try? WhoamiFixture.accountInfo(
                hasSubscription: true,
                planTier: AccountPlanConfig.proTierKey,
                provider: "stripe"
            )
        }
        if let info { gate.apply(info, now: now) }
    }

    @Test("An expired trial raises the ended flag and closes the gate")
    func expiredTrialRaisesFlag() throws {
        try withRestoredGate {
            let now = Date()
            let info = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
            AISubscriptionGate.shared.apply(info, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == true)
            #expect(AISubscriptionGate.shared.isActive == false)
        }
    }

    @Test("A running trial is active access and never raises the ended flag")
    func runningTrialKeepsFlagDown() throws {
        try withRestoredGate {
            let now = Date()
            let expired = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
            AISubscriptionGate.shared.apply(expired, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == true)

            let running = try WhoamiFixture.runningSignupTrial(daysLeft: 5, reference: now)
            AISubscriptionGate.shared.apply(running, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == false)
            #expect(AISubscriptionGate.shared.isActive == true)
        }
    }

    @Test("A response with no trial information leaves the flag down")
    func noTrialInformationLeavesFlagDown() throws {
        try withRestoredGate {
            let now = Date()
            let info = try WhoamiFixture.signedInWithoutSubscription()
            AISubscriptionGate.shared.apply(info, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == false)
            #expect(AISubscriptionGate.shared.isActive == false)
        }
    }

    @Test("Bare closeGate does not clobber the ended flag — it carries no trial information")
    func bareCloseGateLeavesFlagAlone() throws {
        try withRestoredGate {
            let now = Date()
            let expired = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now)
            AISubscriptionGate.shared.apply(expired, now: now)
            #expect(AISubscriptionGate.shared.trialHasEnded == true)

            // The AI 402/403 paths call this directly with no whoami body.
            AISubscriptionGate.shared.openGate()
            AISubscriptionGate.shared.closeGate()
            #expect(AISubscriptionGate.shared.trialHasEnded == true)
        }
    }

    /// The helper above is itself process-global state handling, so it gets its
    /// own proof. Entering closed with no ended trial and applying an expired
    /// one is the sequence that exposes the ordering: restoring `isActive`
    /// first, then the flag, leaves the gate OPEN and writes a last-known-active
    /// of `true` into the real user defaults for every suite that follows.
    @Test("Gate restoration leaves neither the gate nor its persisted mirror open")
    func restorationLeavesNoResidue() throws {
        let gate = AISubscriptionGate.shared
        let outerActive = gate.isActive
        let outerEnded = gate.trialHasEnded
        defer {
            restore(endedFlag: outerEnded)
            if outerActive { gate.openGate() } else { gate.closeGate() }
        }

        let now = Date()
        gate.apply(try WhoamiFixture.signedInWithoutSubscription(), now: now)
        #expect(gate.isActive == false)
        #expect(gate.trialHasEnded == false)

        try withRestoredGate {
            gate.apply(try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now), now: now)
            #expect(gate.trialHasEnded == true)
        }

        #expect(gate.isActive == false)
        #expect(gate.trialHasEnded == false)
        #expect(UserDefaults.standard.bool(forKey: Self.lastKnownActiveKey) == false)
    }

    /// RED-FIRST characterization (2026-08-19): the invariant expressed through
    /// the PRE-FIX mechanism the two `PlanPickerView` purchase/restore sites
    /// used. A local StoreKit purchase has already `openGate()`d; the `/whoami`
    /// body fetched immediately after races the detached `verifyPurchaseWithBackend`
    /// write and can still be the pre-purchase `{has_subscription:false, trial:null}`
    /// shape. Routing THAT through `apply` runs its else-branch `closeGate`,
    /// slamming shut the gate the user just paid to open. On the pre-fix code
    /// this assertion FAILS (isActive == false) — kept as the permanent proof of
    /// why the purchase sites must NOT use `apply`.
    @Test("apply() closes a just-opened gate on a raced pre-purchase whoami — purchase sites must not use it")
    func applyClosesJustOpenedGateOnRacedPrePurchaseWhoami() throws {
        try withRestoredGate {
            let now = Date()
            let racedPrePurchase = try WhoamiFixture.expiredSignupTrial(
                endedDaysAgo: 1, reference: now, trialIsNull: true
            )
            // Wire-accurate raced body: signed-in, no subscription yet, trial key
            // present-but-null (the real ended-signup-trial → upgrading shape).
            #expect(racedPrePurchase.hasSubscription == false)
            #expect(racedPrePurchase.trialKeyPresent == true)

            AISubscriptionGate.shared.openGate()                    // local StoreKit truth
            AISubscriptionGate.shared.apply(racedPrePurchase, now: now)  // races backend verify
            // Pre-fix mechanism CLOSES the just-opened gate — this is the hazard
            // the fix removes, pinned here as a permanent contrast to the
            // `refreshAfterLocalPurchase` path (asserted open below). Red-first
            // evidence 2026-08-19: with `== true` here the pre-fix code failed
            // (isActive → false) at this exact line.
            #expect(AISubscriptionGate.shared.isActive == false)
        }
    }

    /// THE INVARIANT (green): after a local StoreKit purchase/restore has opened
    /// the gate, applying a raced pre-purchase `{has_subscription:false,
    /// trial:null}` body through `refreshAfterLocalPurchase` must leave the gate
    /// OPEN. This is the same flow as `applyClosesJustOpenedGateOnRacedPrePurchaseWhoami`
    /// above, but through the fixed seam — the two together pin exactly why the
    /// purchase sites switched off `apply`.
    @Test("A local purchase keeps the AI gate open when the post-purchase whoami races backend verification")
    func localPurchaseGateStaysOpenWhenWhoamiRacesBackendVerification() throws {
        try withRestoredGate {
            let now = Date()
            let racedPrePurchase = try WhoamiFixture.expiredSignupTrial(
                endedDaysAgo: 1, reference: now, trialIsNull: true
            )
            AISubscriptionGate.shared.openGate()   // local StoreKit truth
            #expect(AISubscriptionGate.shared.isActive == true)
            let checkedBefore = AISubscriptionGate.shared.hasCheckedOnce

            AISubscriptionGate.shared.refreshAfterLocalPurchase(racedPrePurchase, now: now)

            // The just-paid gate stays OPEN despite the raced pre-purchase body.
            #expect(AISubscriptionGate.shared.isActive == true)
            // The no-op branch does not force-stamp `hasCheckedOnce`, so it cannot
            // by itself flip the sidebar into the subscribe/ended banner.
            #expect(AISubscriptionGate.shared.hasCheckedOnce == checkedBefore)
        }
    }

    /// Non-vacuous proof that the no-subscription branch is a true no-op: it is
    /// run from a state where `apply` would VISIBLY change things (gate open,
    /// trial-ended flag down), and every observable flag is required to stay put.
    /// `apply(racedNoSub)` here would both close the gate and raise `trialHasEnded`;
    /// `refreshAfterLocalPurchase` must do neither.
    @Test("refreshAfterLocalPurchase ignores a no-subscription body — it never closes and never raises trial-ended")
    func refreshAfterLocalPurchaseIgnoresNoSubscriptionBody() throws {
        try withRestoredGate {
            let now = Date()
            let racedNoSub = try WhoamiFixture.expiredSignupTrial(
                endedDaysAgo: 1, reference: now, trialIsNull: true   // trialState == .ended
            )
            // Seed a state apply(racedNoSub) would demonstrably mutate.
            let running = try WhoamiFixture.runningSignupTrial(daysLeft: 5, reference: now)
            AISubscriptionGate.shared.apply(running, now: now)   // isActive=true, trialHasEnded=false
            #expect(AISubscriptionGate.shared.isActive == true)
            #expect(AISubscriptionGate.shared.trialHasEnded == false)
            let checkedBefore = AISubscriptionGate.shared.hasCheckedOnce

            AISubscriptionGate.shared.refreshAfterLocalPurchase(racedNoSub, now: now)

            #expect(AISubscriptionGate.shared.isActive == true)        // did NOT close
            #expect(AISubscriptionGate.shared.trialHasEnded == false)  // did NOT raise ended
            #expect(AISubscriptionGate.shared.hasCheckedOnce == checkedBefore)  // did NOT re-stamp
        }
    }

    /// Positive case: when the body already confirms the subscription (the
    /// backend write landed before the read), the open-only seam DOES open a
    /// closed gate and keeps the trial-ended flag down.
    @Test("refreshAfterLocalPurchase opens the gate when the body confirms the subscription")
    func refreshAfterLocalPurchaseOpensOnConfirmedSubscription() throws {
        try withRestoredGate {
            let now = Date()
            let confirmed = try WhoamiFixture.accountInfo(
                hasSubscription: true,
                planTier: AccountPlanConfig.proTierKey,
                provider: "apple"
            )
            AISubscriptionGate.shared.closeGate()   // start closed to prove it opens
            #expect(AISubscriptionGate.shared.isActive == false)

            AISubscriptionGate.shared.refreshAfterLocalPurchase(confirmed, now: now)

            #expect(AISubscriptionGate.shared.isActive == true)
            #expect(AISubscriptionGate.shared.trialHasEnded == false)
        }
    }
}
