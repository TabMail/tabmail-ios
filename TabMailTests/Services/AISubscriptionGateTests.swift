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
}
