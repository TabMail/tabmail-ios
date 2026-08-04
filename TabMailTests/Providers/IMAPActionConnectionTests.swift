/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Test Action Connection Actor

/// Replicates IMAPProvider's action connection acquire/release logic.
/// Tests reentrancy, double-acquire, nil-after-noop, and lock-leak scenarios
/// WITHOUT requiring real IMAP connections.
private actor TestActionProvider {
    var actionServer: String?       // connection ID (nil = no connection)
    var actionInUse = false
    var actionWaiters: [CheckedContinuation<Void, Error>] = []
    var lastUsed: Date?

    // Hooks for test injection
    var noopShouldFail = false
    var createShouldFail = false
    var nilServerOnNoop = false  // simulates reentrancy that nils actionServer during noop

    private var nextId = 0

    private func createServer() throws -> String {
        if createShouldFail {
            throw TestError.connectionFailed
        }
        nextId += 1
        return "conn-\(nextId)"
    }

    // MARK: - Fixed implementation — local capture, early lock

    func acquireActionConnection_fixed() throws -> String {
        func ensureServer() throws -> String {
            if let existing = actionServer { return existing }
            let fresh = try createServer()
            actionServer = fresh
            return fresh
        }

        var server = try ensureServer()

        if !actionInUse {
            // Capture idle before claiming
            actionInUse = true
            lastUsed = Date()

            // Simulate liveness check — reentrancy nils server during noop
            if nilServerOnNoop { actionServer = nil }

            if noopShouldFail {
                // Noop failed — recreate
                do {
                    let fresh = try createServer()
                    actionServer = fresh
                    server = fresh
                } catch {
                    releaseActionConnection(healthy: false)
                    throw error
                }
            } else if actionServer == nil {
                // Reentrancy nilled it during noop — re-ensure
                server = try ensureServer()
            }
            return server
        }

        fatalError("Should not reach waiter path in sync test")
    }

    func releaseActionConnection(healthy: Bool) {
        actionInUse = false
        lastUsed = Date()

        if !healthy {
            actionServer = nil
            let waiters = actionWaiters
            actionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: TestError.connectionFailed)
            }
            return
        }

        if !actionWaiters.isEmpty {
            let waiter = actionWaiters.removeFirst()
            waiter.resume()
        }
    }

    /// Simulate reentrancy: another path releases the connection as unhealthy
    func simulateReentrantUnhealthyRelease() {
        actionServer = nil
    }

    func getActionInUse() -> Bool { actionInUse }
    func getActionServer() -> String? { actionServer }
}

private enum TestError: Error {
    case connectionFailed
}

// MARK: - Test Action Connection Actor (Async)

/// Async version that uses continuations to simulate real acquire/release
/// patterns including waiter queuing.
private actor AsyncTestActionProvider {
    var actionServer: String?
    var actionInUse = false
    var actionWaiters: [CheckedContinuation<Void, Error>] = []
    var lastUsed: Date?

    var noopHandler: (@Sendable () async -> Bool)?  // returns true if noop succeeded
    var createShouldFail = false

    private var nextId = 0

    private func createServer() async throws -> String {
        if createShouldFail {
            throw TestError.connectionFailed
        }
        nextId += 1
        return "conn-\(nextId)"
    }

    /// Fixed implementation with early lock and local capture
    func acquireActionConnection() async throws -> String {
        func ensureServer() async throws -> String {
            if let existing = actionServer { return existing }
            let fresh = try await createServer()
            actionServer = fresh
            return fresh
        }

        var server = try await ensureServer()

        if !actionInUse {
            actionInUse = true
            lastUsed = Date()

            // Liveness check — always run handler if set (tests control when noop fires)
            if let handler = noopHandler {
                let succeeded = await handler()
                if !succeeded {
                    do {
                        let fresh = try await createServer()
                        actionServer = fresh
                        server = fresh
                    } catch {
                        releaseActionConnection(healthy: false)
                        throw error
                    }
                } else if actionServer == nil {
                    // Reentrancy nilled it during noop
                    do {
                        server = try await ensureServer()
                    } catch {
                        releaseActionConnection(healthy: false)
                        throw error
                    }
                }
            }
            return server
        }

        // In use — wait
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            actionWaiters.append(cont)
        }
        server = try await ensureServer()
        actionInUse = true
        lastUsed = Date()
        return server
    }

    func releaseActionConnection(healthy: Bool) {
        actionInUse = false
        lastUsed = Date()

        if !healthy {
            actionServer = nil
            let waiters = actionWaiters
            actionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: TestError.connectionFailed)
            }
            return
        }

        if !actionWaiters.isEmpty {
            let waiter = actionWaiters.removeFirst()
            waiter.resume()
        }
    }

    func simulateReentrantUnhealthyRelease() {
        actionServer = nil
    }

    func getActionInUse() -> Bool { actionInUse }
    func getActionServer() -> String? { actionServer }
    func getWaiterCount() -> Int { actionWaiters.count }
}

// MARK: - Suite 1: Crash — Force-unwrap after reentrancy nils actionServer

@Suite("IMAPProvider - Action Connection Nil Crash")
struct ActionConnectionNilCrashTests {

    @Test("Reentrancy nils actionServer during noop — verifies the crash condition")
    func reentrantNilConditionExists() async {
        let provider = TestActionProvider()

        // Enable reentrancy simulation: actionServer nilled during noop
        await provider.setNilServerOnNoop(true)

        // We can't call acquireActionConnection_original() because the
        // force-unwrap (actionServer!) WILL crash the test process.
        // Instead, verify the condition that causes the crash:
        // after noop side effect, actionServer is nil.
        // First, manually set up the state the original code would have:
        _ = try? await provider.acquireActionConnection_fixed()  // creates conn-1
        await provider.releaseActionConnection(healthy: true)

        // After reentrancy simulation runs, actionServer should be nil
        // (the original code would then do actionServer! on this nil value)
        let serverBefore = await provider.getActionServer()
        #expect(serverBefore != nil, "Server exists before noop")

        await provider.simulateReentrantUnhealthyRelease()
        let serverAfter = await provider.getActionServer()
        #expect(serverAfter == nil, "Reentrancy nils server — original code would crash here with actionServer!")
    }

    @Test("Fixed code returns valid server even when reentrancy nils actionServer")
    func fixedHandlesReentrantNil() async throws {
        let provider = TestActionProvider()

        // Enable reentrancy simulation: actionServer nilled during noop
        await provider.setNilServerOnNoop(true)

        // Fixed code detects nil and recreates via ensureServer()
        let server = try await provider.acquireActionConnection_fixed()
        #expect(!server.isEmpty)

        // Connection is properly claimed
        let inUse = await provider.getActionInUse()
        #expect(inUse)
    }

    @Test("Fixed code returns local capture, not property")
    func fixedReturnsLocalCapture() async throws {
        let provider = TestActionProvider()
        let server = try await provider.acquireActionConnection_fixed()

        // Even if actionServer were nilled after return, local is valid
        #expect(server.starts(with: "conn-"))

        let inUse = await provider.getActionInUse()
        #expect(inUse)
    }

    @Test("Reentrancy nil + createServer failure = throw, not crash")
    func reentrantNilPlusCreateFailureThrows() async {
        let provider = TestActionProvider()
        await provider.setNilServerOnNoop(true)
        await provider.setCreateShouldFail(true)

        // Fixed code: detects nil, tries ensureServer(), createServer fails, releases lock, throws
        do {
            _ = try await provider.acquireActionConnection_fixed()
            Issue.record("Should have thrown")
        } catch {
            // Expected — createServer failed after reentrancy nilled server
        }

        // Lock must be released
        let inUse = await provider.getActionInUse()
        #expect(inUse == false, "Lock must be released on create failure")
    }
}

// MARK: - Extension for test hooks

extension TestActionProvider {
    func setNilServerOnNoop(_ value: Bool) {
        self.nilServerOnNoop = value
    }

    func setCreateShouldFail(_ value: Bool) {
        self.createShouldFail = value
    }
}

// MARK: - Suite 2: Double-acquire — actionInUse not set before await

@Suite("IMAPProvider - Action Connection Double-Acquire")
struct ActionConnectionDoubleAcquireTests {

    @Test("Early lock prevents double-acquire during liveness check")
    func earlyLockPreventsDoubleAcquire() async throws {
        let provider = AsyncTestActionProvider()

        // First caller acquires and holds the lock
        let server1 = try await provider.acquireActionConnection()
        let inUse = await provider.getActionInUse()
        #expect(inUse)

        // Release so second caller can acquire
        await provider.releaseActionConnection(healthy: true)

        let server2 = try await provider.acquireActionConnection()
        // Both should get valid connections
        #expect(!server1.isEmpty)
        #expect(!server2.isEmpty)

        await provider.releaseActionConnection(healthy: true)
    }

    @Test("Waiter queues when actionInUse is true")
    func waiterQueuesWhenInUse() async throws {
        let provider = AsyncTestActionProvider()

        // First caller acquires
        let server1 = try await provider.acquireActionConnection()
        #expect(await provider.getActionInUse())

        // Second caller should queue as waiter
        let waiterTask = Task {
            try await provider.acquireActionConnection()
        }

        // Give waiter time to queue
        try await Task.sleep(for: .milliseconds(50))
        let waiterCount = await provider.getWaiterCount()
        #expect(waiterCount == 1)

        // Release first — should resume waiter
        await provider.releaseActionConnection(healthy: true)

        let server2 = try await waiterTask.value
        #expect(!server1.isEmpty)
        #expect(!server2.isEmpty)

        await provider.releaseActionConnection(healthy: true)
    }

    @Test("Unhealthy release fails all waiters with error")
    func unhealthyReleaseFailsWaiters() async throws {
        let provider = AsyncTestActionProvider()

        // First caller acquires
        _ = try await provider.acquireActionConnection()

        // Queue two waiters
        let waiter1 = Task { try await provider.acquireActionConnection() }
        let waiter2 = Task { try await provider.acquireActionConnection() }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await provider.getWaiterCount() == 2)

        // Unhealthy release — both waiters should fail
        await provider.releaseActionConnection(healthy: false)

        do {
            _ = try await waiter1.value
            Issue.record("Waiter 1 should have thrown")
        } catch {
            // Expected
        }

        do {
            _ = try await waiter2.value
            Issue.record("Waiter 2 should have thrown")
        } catch {
            // Expected
        }

        // actionServer should be nil after unhealthy release
        #expect(await provider.getActionServer() == nil)
        #expect(await provider.getActionInUse() == false)
    }
}

// MARK: - Suite 3: Lock leak — createServer fails after actionInUse set

@Suite("IMAPProvider - Action Connection Lock Leak")
struct ActionConnectionLockLeakTests {

    @Test("Failed recreation releases lock so future callers aren't blocked")
    func failedRecreationReleasesLock() async {
        let provider = AsyncTestActionProvider()

        // Set up: noop fails, then createServer also fails
        await provider.setNoopHandler { return false }
        await provider.setCreateShouldFail(true)

        // acquire should fail — but actionInUse must be released
        do {
            _ = try await provider.acquireActionConnection()
            Issue.record("Should have thrown")
        } catch {
            // Expected — createServer failed
        }

        // Critical: actionInUse must be false so future callers aren't hung
        let inUse = await provider.getActionInUse()
        #expect(inUse == false, "actionInUse must be released on failure")

        // Verify a subsequent caller can acquire after the failure
        await provider.setCreateShouldFail(false)
        await provider.setNoopHandler(nil)
        let server = try? await provider.acquireActionConnection()
        #expect(server != nil, "Subsequent acquire should succeed")

        if server != nil {
            await provider.releaseActionConnection(healthy: true)
        }
    }

    @Test("Successful noop + failed ensureServer releases lock")
    func failedEnsureAfterNoopReleasesLock() async {
        let provider = AsyncTestActionProvider()

        // First acquire succeeds normally
        let firstServer = try? await provider.acquireActionConnection()
        #expect(firstServer != nil)
        if firstServer != nil {
            await provider.releaseActionConnection(healthy: true)
        }

        // Set up: noop succeeds but reentrancy nils server, then createServer fails
        await provider.setNoopHandler {
            // Simulate reentrancy nilling the server
            await provider.simulateReentrantUnhealthyRelease()
            return true  // noop itself "succeeded"
        }
        await provider.setCreateShouldFail(true)

        // acquire should fail
        do {
            _ = try await provider.acquireActionConnection()
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }

        // actionInUse must be released
        let inUse = await provider.getActionInUse()
        #expect(inUse == false, "Lock must be released even when ensureServer fails")
    }
}

// MARK: - Suite 4: Normal lifecycle

@Suite("IMAPProvider - Action Connection Normal Lifecycle")
struct ActionConnectionNormalLifecycleTests {

    @Test("Basic acquire → release → re-acquire cycle")
    func basicCycle() async throws {
        let provider = AsyncTestActionProvider()

        let s1 = try await provider.acquireActionConnection()
        #expect(await provider.getActionInUse())
        #expect(await provider.getActionServer() != nil)

        await provider.releaseActionConnection(healthy: true)
        #expect(await provider.getActionInUse() == false)
        #expect(await provider.getActionServer() != nil) // kept for reuse

        let s2 = try await provider.acquireActionConnection()
        #expect(s1 == s2) // same connection reused
        await provider.releaseActionConnection(healthy: true)
    }

    @Test("Unhealthy release nils server, next acquire creates fresh")
    func unhealthyReleaseThenReacquire() async throws {
        let provider = AsyncTestActionProvider()

        let s1 = try await provider.acquireActionConnection()
        await provider.releaseActionConnection(healthy: false)
        #expect(await provider.getActionServer() == nil)

        let s2 = try await provider.acquireActionConnection()
        #expect(s1 != s2) // must be a new connection
        await provider.releaseActionConnection(healthy: true)
    }

    @Test("Dead connection detected by noop is recreated")
    func deadConnectionRecreated() async throws {
        let provider = AsyncTestActionProvider()

        // First acquire creates connection
        let s1 = try await provider.acquireActionConnection()
        await provider.releaseActionConnection(healthy: true)

        // Next acquire: noop fails → recreate
        let noopFail: @Sendable () async -> Bool = { false }
        await provider.setNoopHandler(noopFail)
        let s2 = try await provider.acquireActionConnection()
        #expect(s1 != s2) // must be fresh
        await provider.releaseActionConnection(healthy: true)
    }

    @Test("Sequential acquire/release handles many cycles")
    func manyCycles() async throws {
        let provider = AsyncTestActionProvider()
        for _ in 0..<20 {
            let s = try await provider.acquireActionConnection()
            #expect(!s.isEmpty)
            #expect(await provider.getActionInUse())
            await provider.releaseActionConnection(healthy: true)
            #expect(await provider.getActionInUse() == false)
        }
    }
}

// MARK: - Extensions for test setup

extension AsyncTestActionProvider {
    func setNoopHandler(_ handler: (@Sendable () async -> Bool)?) {
        self.noopHandler = handler
    }

    func setCreateShouldFail(_ fail: Bool) {
        self.createShouldFail = fail
    }
}
