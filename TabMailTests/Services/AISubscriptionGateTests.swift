/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("AISubscriptionGate")
@MainActor
struct AISubscriptionGateTests {

    @Test("Default state is closed (requires whoami to open)")
    func defaultStateIsClosed() {
        let gate = AISubscriptionGate.shared
        // Note: shared singleton may have been modified by other tests,
        // so we can only verify open/close round-trips here.
        gate.closeGate()
        #expect(gate.isActive == false)
        // Restore for other tests
        gate.openGate()
    }

    @Test("closeGate transitions from open to closed")
    func closeGateTransitions() {
        let gate = AISubscriptionGate.shared
        gate.openGate() // ensure open
        #expect(gate.isActive == true)
        gate.closeGate()
        #expect(gate.isActive == false)
        // Restore
        gate.openGate()
    }

    @Test("openGate transitions from closed to open")
    func openGateTransitions() {
        let gate = AISubscriptionGate.shared
        gate.closeGate() // ensure closed
        #expect(gate.isActive == false)
        gate.openGate()
        #expect(gate.isActive == true)
    }

    @Test("closeGate is idempotent — calling twice does not crash")
    func closeGateIdempotent() {
        let gate = AISubscriptionGate.shared
        gate.openGate() // ensure open
        gate.closeGate()
        #expect(gate.isActive == false)
        // Second call should be a no-op
        gate.closeGate()
        #expect(gate.isActive == false)
        // Restore
        gate.openGate()
    }

    @Test("openGate is idempotent — calling twice does not crash")
    func openGateIdempotent() {
        let gate = AISubscriptionGate.shared
        gate.closeGate() // ensure closed
        gate.openGate()
        #expect(gate.isActive == true)
        // Second call should be a no-op
        gate.openGate()
        #expect(gate.isActive == true)
    }

    @Test("closeGate then openGate round-trips correctly")
    func roundTrip() {
        let gate = AISubscriptionGate.shared
        gate.openGate()
        #expect(gate.isActive == true)
        gate.closeGate()
        #expect(gate.isActive == false)
        gate.openGate()
        #expect(gate.isActive == true)
    }

    @Test("Multiple rapid transitions maintain consistent state")
    func rapidTransitions() {
        let gate = AISubscriptionGate.shared
        for _ in 0..<100 {
            gate.closeGate()
            #expect(gate.isActive == false)
            gate.openGate()
            #expect(gate.isActive == true)
        }
    }

    // MARK: - Authoritative-freshness marker (issue #56)
    //
    // The invariant these pin: routing decisions (the pending-plan-navigation
    // latch) may only trust `isActive` once THIS process has applied a real
    // /whoami — hydrated-from-UserDefaults state must never count as
    // authoritative. So `apply` is the ONLY stamper; the bare 402/403 paths
    // and the post-purchase open-only seam must not stamp (negative cases),
    // and sign-out must forget the marker so the next account cannot inherit
    // the previous account's freshness.

    @Test("apply stamps lastAuthoritativeApplyAt with the injected now — subscriber")
    func applyStampsFreshnessWhenActive() throws {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut()
        #expect(gate.lastAuthoritativeApplyAt == nil)

        let now = Date()
        let info = try WhoamiFixture.accountInfo(hasSubscription: true)
        gate.apply(info, now: now)
        #expect(gate.isActive == true) // the apply really ran (non-vacuous)
        #expect(gate.lastAuthoritativeApplyAt == now)
    }

    @Test("apply stamps lastAuthoritativeApplyAt even when it closes the gate")
    func applyStampsFreshnessWhenInactive() throws {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut()
        #expect(gate.lastAuthoritativeApplyAt == nil)

        let now = Date()
        let info = try WhoamiFixture.accountInfo(hasSubscription: false)
        gate.apply(info, now: now)
        #expect(gate.isActive == false)
        // A "no subscription" answer is just as authoritative as a "yes".
        #expect(gate.lastAuthoritativeApplyAt == now)

        // Restore for other tests: gate open, trial-ended false.
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("Bare openGate does NOT stamp authoritative freshness (negative case)")
    func bareOpenGateDoesNotStamp() {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut()
        gate.closeGate() // make the openGate below a real transition
        gate.openGate()
        #expect(gate.isActive == true) // the call did work…
        #expect(gate.lastAuthoritativeApplyAt == nil) // …but carried no routing authority
    }

    @Test("Bare closeGate does NOT stamp authoritative freshness (negative case)")
    func bareCloseGateDoesNotStamp() {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut()
        gate.openGate() // make the closeGate below a real transition
        gate.closeGate()
        #expect(gate.isActive == false)
        #expect(gate.lastAuthoritativeApplyAt == nil)
        // Restore
        gate.openGate()
    }

    @Test("refreshAfterLocalPurchase does NOT stamp authoritative freshness (negative case)")
    func refreshAfterLocalPurchaseDoesNotStamp() throws {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut()
        gate.closeGate()

        // A confirming body — the seam actually opens the gate here, so the
        // missing stamp is not just an early-return being vacuously inert.
        let info = try WhoamiFixture.accountInfo(hasSubscription: true)
        gate.refreshAfterLocalPurchase(info)
        #expect(gate.isActive == true)
        #expect(gate.lastAuthoritativeApplyAt == nil)
    }

    @Test("noteSignedOut advances the sign-in epoch")
    func noteSignedOutAdvancesEpoch() {
        let gate = AISubscriptionGate.shared
        let before = gate.signInGeneration
        gate.noteSignedOut()
        #expect(gate.signInGeneration == before &+ 1)
    }

    @Test("A /whoami fetched before sign-out never applies: stale epoch is dropped, current epoch applies")
    func staleEpochApplyIsDropped() throws {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut()
        gate.closeGate() // known pre-state: gate closed, marker nil

        // The fetch for account A captured this BEFORE its network await…
        let staleGeneration = gate.signInGeneration
        // …then A signed out (and someone else may have signed in).
        gate.noteSignedOut()

        let activeInfo = try WhoamiFixture.accountInfo(hasSubscription: true)
        gate.applyIfCurrentEpoch(activeInfo, fetchedInGeneration: staleGeneration, now: Date())
        // A's stale ACTIVE answer must neither open the next account's gate
        // nor grant routing authority (either would let the plan-picker
        // latch consumer act on the wrong account's entitlement).
        #expect(gate.isActive == false)
        #expect(gate.lastAuthoritativeApplyAt == nil)

        // Non-vacuity (two-sided): the identical call in the CURRENT epoch
        // does apply.
        let now = Date()
        gate.applyIfCurrentEpoch(activeInfo, fetchedInGeneration: gate.signInGeneration, now: now)
        #expect(gate.isActive == true)
        #expect(gate.lastAuthoritativeApplyAt == now)
    }

    @Test("noteSignedOut clears the freshness marker so the next account cannot inherit it")
    func noteSignedOutClearsFreshness() throws {
        let gate = AISubscriptionGate.shared
        let info = try WhoamiFixture.accountInfo(hasSubscription: true)
        gate.apply(info)
        #expect(gate.lastAuthoritativeApplyAt != nil) // setup observable

        gate.noteSignedOut()
        #expect(gate.lastAuthoritativeApplyAt == nil)
        // Last-known UI state deliberately survives sign-out (global, not
        // account-scoped) — only the routing authority is forgotten.
        #expect(gate.isActive == true)
        #expect(gate.hasCheckedOnce == true)
    }

    // MARK: - Sign-in epoch: resurrection defense-in-depth (merge of #56)
    //
    // A sign-out cleanup's in-flight token refresh can RESURRECT the outgoing
    // account's session into the Keychain AFTER `noteSignedOut` bumped the
    // epoch, so a revalidation can stamp that account's stale entitlement in
    // the SAME epoch the next user signs into — the epoch guard alone cannot
    // tell them apart. `noteSignedIn` closes that: sign-in starts a new epoch
    // and clears the marker, so the resurrected stamp is older-epoch (dropped)
    // and the latch consumer waits for the NEW account's own /whoami. (The
    // token clobber guard is the primary defense; this is defense-in-depth.)

    @Test("noteSignedIn advances the epoch AND clears the freshness marker")
    func noteSignedInAdvancesEpochAndClearsMarker() throws {
        let gate = AISubscriptionGate.shared
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: false)) // marker set (non-vacuous)
        #expect(gate.lastAuthoritativeApplyAt != nil)
        let before = gate.signInGeneration

        gate.noteSignedIn(userId: "user-B-\(UUID().uuidString)")
        #expect(gate.signInGeneration == before &+ 1)
        #expect(gate.lastAuthoritativeApplyAt == nil)

        // Restore for other tests.
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("A resurrected prior-account whoami is dropped once sign-in bumps the epoch")
    func resurrectedPriorAccountApplyDroppedAfterSignIn() throws {
        let gate = AISubscriptionGate.shared
        gate.noteSignedOut() // account A signs out
        // A's cleanup resurrects A's session; a revalidation for A captured
        // THIS (post-sign-out) generation before its network await…
        let resurrectionGeneration = gate.signInGeneration
        gate.noteSignedIn(userId: "user-B-\(UUID().uuidString)") // …then B signs in (our defense)
        // …and A's resurrected-session whoami (closed) lands now.
        gate.applyIfCurrentEpoch(
            try WhoamiFixture.accountInfo(hasSubscription: false),
            fetchedInGeneration: resurrectionGeneration,
            now: Date()
        )
        // Dropped: A's closed entitlement neither closed B's gate nor granted
        // routing authority.
        #expect(gate.lastAuthoritativeApplyAt == nil)

        // Restore for other tests.
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("Active subscriber B is NOT routed to the plan picker after a sign-out of A that resurrected A's closed whoami")
    func activeSubscriberNotPaywalledAfterResurrection() throws {
        let gate = AISubscriptionGate.shared
        let suite = "AISubscriptionGateTests.e2e.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Account A (unentitled) is signed in with an authoritative closed gate.
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: false))
        // A signs out.
        gate.noteSignedOut()
        // A's sign-out cleanup resurrects A's session; a revalidation in THIS
        // epoch stamps A's closed marker — the merge interaction we defend.
        let resurrectionGen = gate.signInGeneration
        gate.applyIfCurrentEpoch(
            try WhoamiFixture.accountInfo(hasSubscription: false),
            fetchedInGeneration: resurrectionGen,
            now: Date()
        )
        #expect(gate.lastAuthoritativeApplyAt != nil) // A's stale closed marker present (setup observable)
        #expect(gate.isActive == false)

        // B signs in: the defense bumps the epoch and clears the marker.
        gate.noteSignedIn(userId: "user-B-\(UUID().uuidString)")

        // B's AI-consent onboarding arms the latch (gate not yet authoritative for B).
        PendingPlanNavigationLatch.recordAfterAIConsent(
            aiEnabled: true,
            gateIsActive: gate.isActive,
            gateIsAuthoritative: gate.lastAuthoritativeApplyAt != nil,
            defaults: defaults
        )
        #expect(PendingPlanNavigationLatch.isSet(defaults))

        // B's MailNavigationView mounts and tries to consume BEFORE B's whoami:
        // the marker was cleared by sign-in, so it WAITS — it does NOT act on
        // A's stale closed entitlement (pre-defense this returned
        // .navigateToPlanPicker — the paywall misroute).
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: gate.lastAuthoritativeApplyAt != nil,
            gateIsActive: gate.isActive,
            aiOptedOut: false,
            defaults: defaults
        ) == .waitForAuthoritativeGate)

        // B's own authoritative whoami (active) lands in B's epoch.
        gate.applyIfCurrentEpoch(
            try WhoamiFixture.accountInfo(hasSubscription: true),
            fetchedInGeneration: gate.signInGeneration,
            now: Date()
        )
        #expect(gate.isActive == true)

        // Consumer fires again on the marker change: active ⇒ cleared, NO paywall.
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: gate.lastAuthoritativeApplyAt != nil,
            gateIsActive: gate.isActive,
            aiOptedOut: false,
            defaults: defaults
        ) == .clearedWithoutNavigation)

        // Restore shared gate for other tests.
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("Two-sided: a genuinely-unentitled B after the same resurrection sequence STILL reaches the plan picker")
    func unentitledUserStillReachesPickerAfterResurrection() throws {
        let gate = AISubscriptionGate.shared
        let suite = "AISubscriptionGateTests.e2e.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: false)) // A closed
        gate.noteSignedOut()
        let resurrectionGen = gate.signInGeneration
        gate.applyIfCurrentEpoch(
            try WhoamiFixture.accountInfo(hasSubscription: false),
            fetchedInGeneration: resurrectionGen,
            now: Date()
        )
        gate.noteSignedIn(userId: "user-B-\(UUID().uuidString)") // B signs in

        PendingPlanNavigationLatch.recordAfterAIConsent(
            aiEnabled: true,
            gateIsActive: gate.isActive,
            gateIsAuthoritative: gate.lastAuthoritativeApplyAt != nil,
            defaults: defaults
        )
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: gate.lastAuthoritativeApplyAt != nil,
            gateIsActive: gate.isActive,
            aiOptedOut: false,
            defaults: defaults
        ) == .waitForAuthoritativeGate)

        // B's own authoritative whoami reports NO subscription.
        gate.applyIfCurrentEpoch(
            try WhoamiFixture.accountInfo(hasSubscription: false),
            fetchedInGeneration: gate.signInGeneration,
            now: Date()
        )
        // The defense must not over-suppress: an unentitled B still navigates.
        #expect(PendingPlanNavigationLatch.consume(
            gateHasAuthoritativeState: gate.lastAuthoritativeApplyAt != nil,
            gateIsActive: gate.isActive,
            aiOptedOut: false,
            defaults: defaults
        ) == .navigateToPlanPicker)

        // Restore shared gate for other tests.
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    // MARK: - Sign-in epoch: the bump is CONDITIONAL on an identity change
    //
    // The three session-write sites also fire when the SAME user
    // re-authenticates (web auth, id-token, OTP). Bumping there would discard a
    // known-good authoritative entitlement and leave the latch consumer waiting
    // on a `/whoami` it did not need. The epoch must track IDENTITY CHANGES,
    // not session writes.

    @Test("Same-user re-authentication does NOT bump the epoch and PRESERVES the authoritative marker")
    func sameUserReauthPreservesEpochAndMarker() throws {
        let gate = AISubscriptionGate.shared
        let subject = "user-A-\(UUID().uuidString)"

        // A signs in, then a /whoami stamps an authoritative marker.
        gate.noteSignedIn(userId: subject)
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        #expect(gate.lastAuthoritativeApplyAt != nil) // known-good state exists (non-vacuous)
        let generationAfterSignIn = gate.signInGeneration
        let markerAfterSignIn = gate.lastAuthoritativeApplyAt

        // A re-authenticates — a NEW session write, but the SAME identity.
        gate.noteSignedIn(userId: subject)

        // Nothing was invalidated: same epoch, same marker instant.
        #expect(gate.signInGeneration == generationAfterSignIn)
        #expect(gate.lastAuthoritativeApplyAt == markerAfterSignIn)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("Cold-start same-user re-auth preserves the marker via previousUserId")
    func coldStartSameUserReauthPreservesMarker() throws {
        let gate = AISubscriptionGate.shared
        let subject = "user-A-\(UUID().uuidString)"

        // Simulate a process that RESTORED A's session from the Keychain at
        // launch: the gate has no recorded epoch owner, but the slot does.
        gate.noteSignedOut() // clears the recorded owner
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        let generationBefore = gate.signInGeneration
        let markerBefore = gate.lastAuthoritativeApplyAt
        #expect(markerBefore != nil)

        // A re-authenticates. The gate has no memory, so the slot's prior
        // subject is what proves this is the same identity.
        gate.noteSignedIn(userId: subject, previousUserId: subject)

        #expect(gate.signInGeneration == generationBefore)
        #expect(gate.lastAuthoritativeApplyAt == markerBefore)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("A DIFFERENT user signing in bumps the epoch and clears the marker")
    func differentUserSignInBumpsAndClearsMarker() throws {
        let gate = AISubscriptionGate.shared
        let userA = "user-A-\(UUID().uuidString)"
        let userB = "user-B-\(UUID().uuidString)"

        gate.noteSignedIn(userId: userA)
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        #expect(gate.lastAuthoritativeApplyAt != nil)
        let generationBefore = gate.signInGeneration

        gate.noteSignedIn(userId: userB, previousUserId: userA)

        #expect(gate.signInGeneration == generationBefore &+ 1)
        #expect(gate.lastAuthoritativeApplyAt == nil)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("An empty or unreadable prior slot is treated as an identity change and BUMPS")
    func unknownPriorIdentityBumps() throws {
        let gate = AISubscriptionGate.shared

        // Both "first ever sign-in" (empty slot) and "slot did not decode"
        // surface here as a nil prior subject. The safe direction is to
        // INVALIDATE — the opposite of the token clobber guard, deliberately.
        gate.noteSignedOut()
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        #expect(gate.lastAuthoritativeApplyAt != nil)
        let generationBefore = gate.signInGeneration

        gate.noteSignedIn(userId: "user-A-\(UUID().uuidString)", previousUserId: nil)

        #expect(gate.signInGeneration == generationBefore &+ 1)
        #expect(gate.lastAuthoritativeApplyAt == nil)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("The notification backstop is idempotent — it cannot undo the write-time preservation")
    func notificationBackstopIsIdempotent() throws {
        let gate = AISubscriptionGate.shared
        let subject = "user-A-\(UUID().uuidString)"

        // The session write opened the epoch for A and a /whoami stamped it.
        gate.noteSignedIn(userId: subject)
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        let generationAfterWrite = gate.signInGeneration
        let markerAfterWrite = gate.lastAuthoritativeApplyAt
        #expect(markerAfterWrite != nil)

        // `.tabMailDidSignIn` fires later; RootView's backstop passes the live
        // subject. It must NOT invalidate what the write already established.
        gate.noteSignedIn(userId: subject)

        #expect(gate.signInGeneration == generationAfterWrite)
        #expect(gate.lastAuthoritativeApplyAt == markerAfterWrite)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }

    @Test("A prior account's whoami landing in the write→notification gap is dropped")
    func priorAccountWhoamiInWriteToNotificationGapIsDropped() throws {
        let gate = AISubscriptionGate.shared
        let userA = "user-A-\(UUID().uuidString)"
        let userB = "user-B-\(UUID().uuidString)"

        // A is signed in and unentitled; its revalidation is in flight and
        // captured the epoch BEFORE its network await.
        gate.noteSignedIn(userId: userA)
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: false))
        let aInFlightGeneration = gate.signInGeneration

        // B's session is WRITTEN. This is the moment identity changes — and
        // the moment the epoch must advance. `.tabMailDidSignIn` has NOT been
        // posted yet: `syncStripeCustomer` (a network round-trip) and the UI
        // plumbing that posts it are still ahead.
        gate.noteSignedIn(userId: userB, previousUserId: userA)

        // A's closed whoami lands INSIDE that gap.
        gate.applyIfCurrentEpoch(
            try WhoamiFixture.accountInfo(hasSubscription: false),
            fetchedInGeneration: aInFlightGeneration,
            now: Date()
        )

        // Dropped — A's entitlement never vouches for B. (With the bump at the
        // notification instead of the write, this apply would have been in the
        // CURRENT epoch and would have stamped the marker.)
        #expect(gate.lastAuthoritativeApplyAt == nil)

        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
    }
}
