/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Invariant tests for the `pending_plan_navigation` latch (issue #56).
///
/// The system property these pin — NOT the fix's mechanism: **a user whose
/// entitlement is authoritatively active is never routed to the plan
/// picker by the post-login flow, regardless of a pre-existing latch or
/// `/whoami` timing; a genuinely unentitled user still is; and an unknown
/// gate defers rather than deciding.** Pre-fix, the consumer navigated on
/// a bare latch read (no entitlement check at all) and the AI-consent
/// writer left a stale armed latch for active subscribers.
///
/// Each test uses an isolated `UserDefaults` suite. The latch's `clear`
/// writes an explicit `false` (never `removeObject`) precisely so suite
/// isolation cannot fall through to `.standard` — see the test-isolation
/// memory topic on `UserDefaults(suiteName:)`.
@Suite("PendingPlanNavigationLatch")
struct PendingPlanNavigationLatchTests {

    /// Fresh, uniquely-named defaults suite per test.
    private func makeDefaults() -> UserDefaults {
        let name = "PendingPlanNavigationLatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Consumer invariants

    @Test("Active entitlement never navigates: latch armed + authoritative open gate → cleared without navigation")
    func activeEntitlementNeverNavigates() {
        let defaults = makeDefaults()
        PendingPlanNavigationLatch.set(defaults)
        #expect(PendingPlanNavigationLatch.isSet(defaults)) // setup took effect

        let outcome = PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: true,
            gateIsActive: true,
            aiOptedOut: false,
            defaults: defaults
        )
        #expect(outcome == .clearedWithoutNavigation)
        // Two-sided: the stale latch must also be gone, or it would misfire
        // on a later mount.
        #expect(!PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("Unknown gate defers: latch armed + no authoritative /whoami this process → wait, latch preserved")
    func unknownGateDefersAndPreservesLatch() {
        let defaults = makeDefaults()
        PendingPlanNavigationLatch.set(defaults)
        #expect(PendingPlanNavigationLatch.isSet(defaults))

        let outcome = PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: false,
            gateIsActive: false, // hydrated default — must NOT be trusted
            aiOptedOut: false,
            defaults: defaults
        )
        #expect(outcome == .waitForAuthoritativeGate)
        // The user's intent survives until an authoritative answer arrives.
        #expect(PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("Genuinely unentitled user still reaches the plan picker (two-sided)")
    func unentitledUserStillNavigates() {
        let defaults = makeDefaults()
        PendingPlanNavigationLatch.set(defaults)
        #expect(PendingPlanNavigationLatch.isSet(defaults))

        let outcome = PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: true,
            gateIsActive: false,
            aiOptedOut: false,
            defaults: defaults
        )
        #expect(outcome == .navigateToPlanPicker)
        #expect(!PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("AI opt-out clears the latch without navigating")
    func aiOptOutClearsWithoutNavigation() {
        let defaults = makeDefaults()
        PendingPlanNavigationLatch.set(defaults)

        let outcome = PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: true,
            gateIsActive: false,
            aiOptedOut: true,
            defaults: defaults
        )
        #expect(outcome == .clearedWithoutNavigation)
        #expect(!PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("No latch → noLatch, and nothing is written")
    func noLatchIsInert() {
        let defaults = makeDefaults()
        #expect(!PendingPlanNavigationLatch.isSet(defaults))

        let outcome = PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: true,
            gateIsActive: true,
            aiOptedOut: false,
            defaults: defaults
        )
        #expect(outcome == .noLatch)
        #expect(!PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("Deferred latch is consumed once the gate turns authoritative — active clears, inactive navigates")
    func deferredLatchConsumesOnAuthoritative() {
        // The full post-login sequence: latch armed pre-sign-in, first
        // consume attempt runs before /whoami lands, second runs after.
        let defaults = makeDefaults()
        PendingPlanNavigationLatch.set(defaults)

        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: false, gateIsActive: false, aiOptedOut: false, defaults: defaults
        ) == .waitForAuthoritativeGate)

        // Subscriber: the whoami that lands reports active.
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: true, gateIsActive: true, aiOptedOut: false, defaults: defaults
        ) == .clearedWithoutNavigation)
        #expect(!PendingPlanNavigationLatch.isSet(defaults))

        // And the unentitled counterpart still navigates after the wait.
        PendingPlanNavigationLatch.set(defaults)
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: false, gateIsActive: true, aiOptedOut: false, defaults: defaults
        ) == .waitForAuthoritativeGate)
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: true, gateIsActive: false, aiOptedOut: false, defaults: defaults
        ) == .navigateToPlanPicker)
    }

    // MARK: - Writer invariants (AI-consent completion)

    @Test("AI consent for an active subscriber disarms a stale latch (the pre-fix fall-through)")
    func consentActiveSubscriberDisarmsStaleLatch() {
        let defaults = makeDefaults()
        // Stale latch from a signed-out banner tap in some earlier session.
        PendingPlanNavigationLatch.set(defaults)
        #expect(PendingPlanNavigationLatch.isSet(defaults))

        PendingPlanNavigationLatch.recordAfterAIConsent(
            aiEnabled: true,
            gateIsActive: true,
            gateIsAuthoritative: true,
            defaults: defaults
        )
        // Invariant: after the consent screen completes for an
        // AUTHORITATIVELY active subscriber, no plan navigation remains
        // pending.
        #expect(!PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("AI consent on hydrated-but-unverified active state still arms (authority required to disarm)")
    func consentHydratedActiveUnverifiedArms() {
        let defaults = makeDefaults()
        #expect(!PendingPlanNavigationLatch.isSet(defaults))

        // `isActive == true` here is only the UserDefaults-hydrated
        // last-known value (a previous subscriber on this device); the
        // current user's /whoami has not landed. Clearing on it would deny
        // a genuinely unentitled user the plan picker forever — the later
        // authoritative closed response would find nothing to consume. Arm;
        // the entitlement-aware consumer clears silently if the
        // authoritative answer turns out active.
        PendingPlanNavigationLatch.recordAfterAIConsent(
            aiEnabled: true,
            gateIsActive: true,
            gateIsAuthoritative: false,
            defaults: defaults
        )
        #expect(PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("AI consent with AI declined disarms the latch")
    func consentAIDeclinedDisarms() {
        let defaults = makeDefaults()
        PendingPlanNavigationLatch.set(defaults)

        PendingPlanNavigationLatch.recordAfterAIConsent(
            aiEnabled: false,
            gateIsActive: false,
            gateIsAuthoritative: false,
            defaults: defaults
        )
        #expect(!PendingPlanNavigationLatch.isSet(defaults))
    }

    @Test("AI consent with AI enabled and gate not active arms the latch (two-sided)")
    func consentUnentitledArms() {
        let defaults = makeDefaults()
        #expect(!PendingPlanNavigationLatch.isSet(defaults))

        PendingPlanNavigationLatch.recordAfterAIConsent(
            aiEnabled: true,
            gateIsActive: false,
            gateIsAuthoritative: true,
            defaults: defaults
        )
        // The unentitled user's plan navigation must still be recorded —
        // the entitlement-aware consumer is what protects subscribers,
        // not a writer that never arms.
        #expect(PendingPlanNavigationLatch.isSet(defaults))
    }
}
