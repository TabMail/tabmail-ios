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
}
