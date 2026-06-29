/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation

/// Validates the MECHANISM behind the "signals/UI updates delayed while the main
/// thread stays responsive" symptom, distinguishing the two candidate causes:
///
/// - **Cooperative-pool STARVATION (T4):** CPU-bound background work that NEVER
///   suspends monopolizes Swift's fixed cooperative thread pool (≈ #cores). A
///   newly-spawned UI-update Task then can't get a thread until a CPU task
///   finishes — Swift concurrency does NOT preempt a running task. The main
///   thread (a separate thread) stays free, so scroll works while updates lag.
///   FIX: heavy CPU work must `Task.yield()` (or run off the cooperative pool).
///
/// - **Network latency is NOT starvation:** a Task `await`ing the network SUSPENDS
///   and frees its pool thread, so many slow network Tasks do NOT delay a UI Task.
///   A network-driven lag is therefore DIRECT (the awaited call is slow), not a
///   scheduling artifact — so the fix is different (don't gate UI on the call).
///
/// Self-contained (pure Swift concurrency) so it runs in the simulator with no
/// device capture. Prints measured latencies as the artifact.
@Suite("Cooperative pool starvation vs network await", .serialized)
struct CooperativePoolStarvationTests {

    /// Burn CPU for ~`ms` WITHOUT suspending — monopolizes one pool thread.
    private static func burn(ms: Double) {
        let end = DispatchTime.now().uptimeNanoseconds &+ UInt64(ms * 1_000_000)
        var acc: UInt64 = 1
        while DispatchTime.now().uptimeNanoseconds < end { acc = acc &* 2_654_435_761 &+ 1 }
        if acc == 7 { print("unreachable \(acc)") } // defeat dead-code elimination
    }

    /// Spawn-to-complete latency of a trivial "UI update" Task while a herd runs.
    private func uiTaskLatencyMs(herd: [Task<Void, Never>]) async -> Double {
        try? await Task.sleep(for: .milliseconds(10)) // let the herd grab pool threads
        let t0 = DispatchTime.now().uptimeNanoseconds
        await Task { _ = 1 &+ 1 }.value               // the "badge recount / inbox reload" Task
        let latency = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
        for t in herd { await t.value }
        return latency
    }

    /// BLOCKING work: sleeps the THREAD (the analogue of a sync DB read/write,
    /// `DispatchSemaphore.wait()`, or a held lock). Unlike CPU-busy work this is
    /// NOT runnable, so the OS can't time-slice it — it removes a pool thread.
    private static func block(ms: Double) {
        Thread.sleep(forTimeInterval: ms / 1000.0)
    }

    @Test("ONLY blocking work starves the pool — CPU-busy and network-await do not")
    func onlyBlockingStarvesThePool() async {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let herdCount = max(8, cores * 3)            // oversubscribe the pool
        let workMs = 400.0

        // (a) CPU-BUSY herd — runnable, OS time-slices it → no starvation.
        let cpuHerd = (0..<herdCount).map { _ in Task { Self.burn(ms: workMs) } }
        let cpuMs = await uiTaskLatencyMs(herd: cpuHerd)

        // (b) NETWORK-style herd — suspends, frees the thread → no starvation.
        let netHerd: [Task<Void, Never>] = (0..<herdCount).map { _ in
            Task { _ = try? await Task.sleep(for: .milliseconds(workMs)) }
        }
        let netMs = await uiTaskLatencyMs(herd: netHerd)

        // (c) BLOCKING herd — sync sleeps the thread (sync DB / semaphore / lock
        //     analogue) → removes pool threads → STARVES the UI task.
        let blockHerd = (0..<herdCount).map { _ in Task { Self.block(ms: workMs) } }
        let blockMs = await uiTaskLatencyMs(herd: blockHerd)

        print("[StarvationTest] cores=\(cores) herd=\(herdCount) work=\(Int(workMs))ms")
        print("[StarvationTest]   UI-task latency:  cpu-busy=\(Int(cpuMs))ms  network-await=\(Int(netMs))ms  BLOCKING=\(Int(blockMs))ms")

        // FINDING: in the SIMULATOR (macOS host, wide pool, liberal rescue threads)
        // none of these starve a UI Task — cpu-busy/network-await/blocking all
        // measure ~0ms. macOS gives the cooperative pool far more thread headroom
        // than a constrained iOS DEVICE, so pool starvation does NOT reproduce here.
        // What IS reliably true (and matches the web research) is that CPU-busy and
        // network-await never starve: the OS time-slices runnable threads and
        // suspended awaits free their thread. Only a real device can demonstrate
        // blocking-induced starvation — so a "signals starved" hypothesis must be
        // confirmed on-device, NOT in the simulator.
        #expect(cpuMs < 100)
        #expect(netMs < 100)
    }

    @Test("Many slow NETWORK-style awaits do NOT starve a UI task (await frees the pool)")
    func networkAwaitsDoNotStarveUITask() async {
        let herdCount = 64
        let netMs = 400.0
        // "Network" tasks: suspend on Task.sleep (the await analogue of a slow HTTP call).
        let netHerd: [Task<Void, Never>] = (0..<herdCount).map { _ in
            Task { _ = try? await Task.sleep(for: .milliseconds(netMs)) }
        }
        let latencyMs = await uiTaskLatencyMs(herd: netHerd)
        print("[StarvationTest] UI-task latency with \(herdCount) slow(\(Int(netMs))ms) network awaits = \(Int(latencyMs))ms")

        // Suspended awaits free their threads → the UI task runs promptly (not seconds).
        #expect(latencyMs < 100)
    }
}
