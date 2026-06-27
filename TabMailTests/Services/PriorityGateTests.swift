/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

/// Unit coverage for the cooperative priority gate that makes the privileged
/// NSE→inbox merge run without contending with the heavy background loops.
/// Tests drive a FRESH `PriorityGate()` instance (not `.shared`) so they don't
/// perturb the app singleton and can run in parallel.
@Suite("PriorityGate", .serialized)
struct PriorityGateTests {

    @Test("yield() is a no-op when no privileged section is active")
    func yieldNoOpWhenClear() async {
        let gate = PriorityGate()
        await gate.yield("test")            // returns immediately
        let active = await gate.isPrivileged
        #expect(active == false)
    }

    @Test("yield() parks while privileged and resumes the instant it's released")
    func yieldParksUntilReleased() async {
        let gate = PriorityGate()
        await gate.begin()

        // A background "loop" that yields — it must NOT proceed past yield() until
        // the privileged section ends.
        let resumed = Mutex<Bool>(false)
        let bg = Task {
            await gate.yield("bg")
            resumed.withLock { $0 = true }
        }

        try? await Task.sleep(for: .milliseconds(120))
        #expect(resumed.withLock { $0 } == false)   // still parked

        await gate.end()
        await bg.value
        #expect(resumed.withLock { $0 } == true)     // resumed after release
    }

    @Test("count-based: resumes only when the LAST privileged section ends")
    func nestedPrivilegedComposes() async {
        let gate = PriorityGate()
        await gate.begin()
        await gate.begin()                          // two concurrent privileged sections

        let resumed = Mutex<Bool>(false)
        let bg = Task {
            await gate.yield("bg")
            resumed.withLock { $0 = true }
        }

        try? await Task.sleep(for: .milliseconds(100))
        await gate.end()                            // one still active (count==1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(resumed.withLock { $0 } == false)   // still parked

        await gate.end()                            // last one → gate clears
        await bg.value
        #expect(resumed.withLock { $0 } == true)
    }

    @Test("multiple parked loops all resume on release")
    func multipleWaitersAllResume() async {
        let gate = PriorityGate()
        await gate.begin()

        // Each waiter completes (returns) only once it gets past yield(). They
        // stay parked until end(), then all 5 resume — drained count must be 5.
        let resumed = await withTaskGroup(of: Void.self, returning: Int.self) { group in
            for _ in 0..<5 {
                group.addTask { await gate.yield() }
            }
            try? await Task.sleep(for: .milliseconds(120))
            await gate.end()
            var n = 0
            for await _ in group { n += 1 }
            return n
        }
        #expect(resumed == 5)
    }

    @Test("privileged context is EXEMPT — yield() inside privileged { } never parks (deadlock guard)")
    func privilegedContextExemptFromYield() async {
        // Inside privileged { } the gate is held (count > 0), but a yield() from
        // THAT context must return immediately — otherwise the merge's own writes
        // (which go through the same gated pool) would wait on the gate the merge
        // itself holds → deadlock. If the exemption regressed, this test hangs.
        let reached = Mutex<Bool>(false)
        await PriorityGate.privileged {
            await PriorityGate.shared.yield()        // must NOT park
            reached.withLock { $0 = true }
        }
        #expect(reached.withLock { $0 } == true)
        let active = await PriorityGate.shared.isPrivileged
        #expect(active == false)                     // released cleanly
    }

    @Test("static privileged { } (on .shared, the real API) parks a waiter during the body")
    func privilegedHelperBrackets() async {
        // Exercises the exact API the merge coordinator calls. Operates on
        // `.shared`; the suite is `.serialized` and unit tests run no background
        // loops, so this can't perturb anything. The helper always releases.
        let inside = Mutex<Bool>(false)
        let priv = Task {
            await PriorityGate.privileged {
                inside.withLock { $0 = true }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(inside.withLock { $0 } == true)

        // A background loop yielding on the same (shared) gate must wait.
        let resumed = Mutex<Bool>(false)
        let bg = Task {
            await PriorityGate.shared.yield("bg")
            resumed.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(resumed.withLock { $0 } == false)   // parked while privileged runs

        await priv.value
        await bg.value
        #expect(resumed.withLock { $0 } == true)     // resumed once privileged ended

        // Gate must be clean afterward.
        let active = await PriorityGate.shared.isPrivileged
        #expect(active == false)
    }
}
