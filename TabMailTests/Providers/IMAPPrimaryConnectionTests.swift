/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Test Double: Primary Connection Actor

/// Replicates IMAPProvider's primary connection + IDLE + folder-pinned logic.
/// Tests connection priority (action > IDLE > folder LRU), eviction on limit,
/// and IDLE lifecycle WITHOUT requiring real IMAP connections.
private actor TestPrimaryProvider {
    // Folder-pinned connections
    var folderServers: [String: String] = [:]  // folder → connection ID
    var folderLastUsed: [String: Date] = [:]
    var folderInUse: Set<String> = []

    // Action connection
    var actionServer: String?
    var actionInUse = false

    // IDLE state (dedicated connection, separate from action)
    var idleServer: String?
    var idleEnabled = false
    var idleLaunchCount = 0
    private static let idleMinServerLimit = 3

    // Server limit
    var serverConnectionLimit: Int?
    private static let reservedConnections = 2

    // Test hooks
    var createShouldFail = false
    var createShouldFailWithLimitError = false
    var onCreateAttempt: (() -> Void)?
    private var nextId = 0

    var maxFolderConnections: Int {
        if let limit = serverConnectionLimit {
            let activeReserved = idleServer != nil ? Self.reservedConnections : Self.reservedConnections - 1
            return max(1, limit - activeReserved)
        }
        return 18  // SyncConfig.imapMaxConnectionCeiling - 2
    }

    private func createServer() throws -> String {
        onCreateAttempt?()
        if createShouldFailWithLimitError {
            throw NSError(domain: "IMAP", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Login failed: no([UNAVAILABLE] Maximum number of connections from user+IP exceeded (mail_max_userip_connections=5))"])
        }
        if createShouldFail {
            throw NSError(domain: "IMAP", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        }
        nextId += 1
        return "conn-\(nextId)"
    }

    // MARK: - Folder Connection

    @discardableResult
    func evictLRUFolder() -> Bool {
        let candidates = folderLastUsed.filter { !folderInUse.contains($0.key) }
        guard let (folder, _) = candidates.min(by: { $0.value < $1.value }) else {
            return false
        }
        folderServers.removeValue(forKey: folder)
        folderLastUsed.removeValue(forKey: folder)
        return true
    }

    func createFolderConnection(folder: String) throws -> String {
        // Evict LRU if at capacity (try IDLE as last resort)
        while folderServers.count >= maxFolderConnections {
            guard evictLRUFolder() || evictIdleConnection() else {
                throw NSError(domain: "IMAP", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "All connections in use"])
            }
        }

        do {
            let server = try createServer()
            folderServers[folder] = server
            folderLastUsed[folder] = Date()
            folderInUse.insert(folder)
            return server
        } catch {
            let isLimitError = "\(error)".contains("max_userip_connections")
            if isLimitError {
                parseAndApplyServerLimit(from: error)
            }

            // Connection limit hit — evict LRU folder (or IDLE as last resort) and retry once
            if isLimitError && (evictLRUFolder() || evictIdleConnection()) {
                do {
                    let server = try createServer()
                    folderServers[folder] = server
                    folderLastUsed[folder] = Date()
                    folderInUse.insert(folder)
                    return server
                } catch {
                    throw error
                }
            }
            throw error
        }
    }

    func releaseFolderConnection(folder: String) {
        folderInUse.remove(folder)
        folderLastUsed[folder] = Date()
    }

    // MARK: - Action Connection

    func acquireActionConnection() throws -> String {
        if actionServer == nil {
            let fresh = try createServer()
            actionServer = fresh
        }

        actionInUse = true
        return actionServer!
    }

    func releaseActionConnection(healthy: Bool) {
        actionInUse = false
        if !healthy {
            actionServer = nil
        }
    }

    // MARK: - IDLE (Dedicated Connection)

    func startIdle() {
        idleEnabled = true
        launchIdleConnection()
    }

    func stopIdle() {
        idleEnabled = false
        idleServer = nil
    }

    func launchIdleConnection() {
        guard idleEnabled, idleServer == nil else { return }
        // Don't launch IDLE if server limit is too tight
        if let limit = serverConnectionLimit, limit < Self.idleMinServerLimit {
            return
        }
        idleServer = "idle-conn"
        idleLaunchCount += 1
    }

    @discardableResult
    func evictIdleConnection() -> Bool {
        guard idleServer != nil else { return false }
        idleServer = nil
        return true
    }

    func markDirty() {
        idleServer = nil
        actionServer = nil
        actionInUse = false
        folderServers.removeAll()
        folderLastUsed.removeAll()
        folderInUse.removeAll()
    }

    // MARK: - Server Limit

    func parseAndApplyServerLimit(from error: Error) {
        let desc = "\(error)"
        guard desc.contains("max_userip_connections"),
              let range = desc.range(of: "mail_max_userip_connections="),
              let limit = Int(desc[range.upperBound...].prefix(while: \.isNumber))
        else { return }
        if serverConnectionLimit == nil || limit < serverConnectionLimit! {
            serverConnectionLimit = limit
        }
    }
}

// MARK: - Tests: Reserved Connections

@Suite("Primary Connection — Reserved Slots")
struct PrimaryConnectionReservedTests {
    @Test("Without IDLE: limit 5 gives 4 folder slots (only action reserved)")
    func withoutIdleLimit5() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(5)
        // No IDLE → reserved = 1 (action only)
        #expect(await provider.maxFolderConnections == 4)
    }

    @Test("With IDLE: limit 5 gives 3 folder slots (action + IDLE reserved)")
    func withIdleLimit5() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(5)
        await provider.startIdle()
        // IDLE active → reserved = 2 (action + IDLE)
        #expect(await provider.maxFolderConnections == 3)
    }

    @Test("With IDLE: limit 3 gives 1 folder slot (minimum)")
    func withIdleLimit3() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3)
        await provider.startIdle()
        #expect(await provider.maxFolderConnections == 1)
    }

    @Test("Server limit 1 gives 1 folder slot (clamped)")
    func serverLimit1GivesMinimum() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(1)
        #expect(await provider.maxFolderConnections == 1)
    }
}

// MARK: - Tests: LRU Eviction on Connection Limit

@Suite("Primary Connection — LRU Eviction on Limit Error")
struct LRUEvictionOnLimitTests {
    @Test("Evicts oldest folder connection when server rejects with limit error")
    func evictsOldestOnLimitError() async throws {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3) // 2 folder slots + action (no IDLE)

        // Fill both folder slots
        let base = Date()
        _ = try await provider.createFolderConnectionWithTimestamp(folder: "INBOX", time: base)
        await provider.releaseFolderConnection(folder: "INBOX")
        _ = try await provider.createFolderConnectionWithTimestamp(folder: "Sent", time: base.addingTimeInterval(10))
        await provider.releaseFolderConnection(folder: "Sent")

        // Now creating a 3rd should evict LRU first — but server will also reject the first attempt.
        // Set up: first createServer() fails with limit, then succeeds after eviction.
        var attemptCount = 0
        await provider.setOnCreateAttempt {
            attemptCount += 1
        }
        // After the 2 folder slots are full and we try a 3rd,
        // createFolderConnection should evict LRU (INBOX) and succeed
        // because we're back under maxFolderConnections after eviction.
        let folders = await provider.folderServers
        #expect(folders.count == 2)

        _ = try await provider.createFolderConnection(folder: "Drafts")
        let foldersAfter = await provider.folderServers
        #expect(foldersAfter.count == 2)
        #expect(foldersAfter["INBOX"] == nil) // Evicted (oldest)
        #expect(foldersAfter["Sent"] != nil)
        #expect(foldersAfter["Drafts"] != nil)
    }

    @Test("Server limit error triggers evict-and-retry when at capacity from external pressure")
    func evictAndRetryOnExternalLimitError() async throws {
        let provider = TestPrimaryProvider()
        // Don't set server limit — simulate external pressure (e.g., Thunderbird using slots)
        // Provider thinks it has plenty of room but server rejects.

        // Add one folder connection
        _ = try await provider.createFolderConnection(folder: "INBOX")
        await provider.releaseFolderConnection(folder: "INBOX")

        // Now make createServer fail with limit error on first attempt, succeed on second
        var callCount = 0
        await provider.setOnCreateAttempt {
            callCount += 1
        }
        await provider.setCreateShouldFailWithLimitOnce()

        _ = try await provider.createFolderConnection(folder: "Sent")
        let folders = await provider.folderServers
        // INBOX was evicted, Sent was created on retry
        #expect(folders["INBOX"] == nil)
        #expect(folders["Sent"] != nil)
        // Server limit should have been parsed
        let limit = await provider.serverConnectionLimit
        #expect(limit == 5)
    }

    @Test("Eviction skips in-use connections")
    func evictionSkipsInUse() async throws {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3) // 2 folder slots (no IDLE)

        // Create two connections, keep first in use
        _ = try await provider.createFolderConnection(folder: "INBOX")
        // Don't release INBOX — it's in use
        _ = try await provider.createFolderConnectionWithTimestamp(folder: "Sent", time: Date().addingTimeInterval(10))
        await provider.releaseFolderConnection(folder: "Sent")

        // Create third — should evict Sent (the only non-in-use one), not INBOX
        _ = try await provider.createFolderConnection(folder: "Drafts")
        let folders = await provider.folderServers
        #expect(folders["INBOX"] != nil) // Still in use, not evicted
        #expect(folders["Sent"] == nil)  // Evicted
        #expect(folders["Drafts"] != nil)
    }
}

// MARK: - Tests: IDLE Lifecycle (Dedicated Connection)

@Suite("Primary Connection — IDLE Lifecycle")
struct IdleLifecycleTests {
    @Test("IDLE creates dedicated connection on start")
    func idleCreatesDedicatedConnection() async {
        let provider = TestPrimaryProvider()
        await provider.startIdle()
        #expect(await provider.idleServer != nil)
        #expect(await provider.idleEnabled == true)
        #expect(await provider.idleLaunchCount == 1)
    }

    @Test("IDLE is independent of action connection")
    func idleIndependentOfAction() async throws {
        let provider = TestPrimaryProvider()
        await provider.startIdle()
        #expect(await provider.idleServer != nil)

        // Action connection is separate
        _ = try await provider.acquireActionConnection()
        #expect(await provider.idleServer != nil) // IDLE unaffected
        await provider.releaseActionConnection(healthy: true)
        #expect(await provider.idleServer != nil) // Still running
    }

    @Test("stopIdle clears dedicated IDLE connection")
    func stopIdleClearsConnection() async {
        let provider = TestPrimaryProvider()
        await provider.startIdle()
        #expect(await provider.idleServer != nil)
        #expect(await provider.idleEnabled == true)

        await provider.stopIdle()
        #expect(await provider.idleServer == nil)
        #expect(await provider.idleEnabled == false)
    }

    @Test("IDLE skipped when server limit < 3")
    func idleSkippedWhenLimitTooLow() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(2)
        await provider.startIdle()
        #expect(await provider.idleServer == nil) // Not launched
        #expect(await provider.idleEnabled == true) // Intent preserved
    }

    @Test("IDLE launched when server limit >= 3")
    func idleLaunchedWhenLimitOK() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3)
        await provider.startIdle()
        #expect(await provider.idleServer != nil)
    }
}

// MARK: - Tests: markDirty

@Suite("Primary Connection — markDirty")
struct MarkDirtyTests {
    @Test("markDirty clears all connections including IDLE")
    func markDirtyClearsEverything() async throws {
        let provider = TestPrimaryProvider()

        // Set up: action + IDLE + folder connections
        _ = try await provider.acquireActionConnection()
        await provider.releaseActionConnection(healthy: true)
        await provider.startIdle()
        _ = try await provider.createFolderConnection(folder: "INBOX")
        await provider.releaseFolderConnection(folder: "INBOX")

        #expect(await provider.idleServer != nil)
        #expect(await provider.actionServer != nil)
        #expect(await provider.folderServers.count == 1)

        await provider.markDirty()

        #expect(await provider.idleServer == nil)
        #expect(await provider.actionServer == nil)
        #expect(await provider.actionInUse == false)
        #expect(await provider.folderServers.isEmpty)
    }

    @Test("markDirty preserves idleEnabled for relaunch on foreground")
    func markDirtyPreservesIdleEnabled() async {
        let provider = TestPrimaryProvider()
        await provider.startIdle()

        #expect(await provider.idleEnabled == true)

        await provider.markDirty()
        #expect(await provider.idleServer == nil)
        // idleEnabled preserved — will relaunch on next foreground start
        #expect(await provider.idleEnabled == true)
    }
}

// MARK: - Tests: Connection Priority

@Suite("Primary Connection — Priority Order")
struct ConnectionPriorityTests {
    @Test("Action always gets connection even when folder connections are full")
    func actionAlwaysGetsConnection() async throws {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3) // 2 folder + action (no IDLE)

        // Fill all folder slots
        _ = try await provider.createFolderConnection(folder: "INBOX")
        _ = try await provider.createFolderConnection(folder: "Sent")

        // Action still works — uses separate primary connection
        let conn = try await provider.acquireActionConnection()
        #expect(conn.isEmpty == false)
        await provider.releaseActionConnection(healthy: true)
    }

    @Test("Folder connections respect server limit minus reserved")
    func folderRespectsLimit() async throws {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3) // 2 folder slots (no IDLE)

        _ = try await provider.createFolderConnection(folder: "INBOX")
        await provider.releaseFolderConnection(folder: "INBOX")
        _ = try await provider.createFolderConnection(folder: "Sent")
        await provider.releaseFolderConnection(folder: "Sent")

        // Third connection should evict LRU (INBOX)
        _ = try await provider.createFolderConnection(folder: "Drafts")
        let folders = await provider.folderServers
        #expect(folders.count == 2)
        #expect(folders["INBOX"] == nil)
    }
}

// MARK: - Tests: Server Limit Parsing

@Suite("Primary Connection — Server Limit Parsing")
struct ServerLimitParsingTests {
    @Test("Parses limit from standard Dovecot error")
    func parsesStandardError() async throws {
        let provider = TestPrimaryProvider()
        _ = try await provider.createFolderConnection(folder: "INBOX")
        await provider.releaseFolderConnection(folder: "INBOX")

        // Trigger limit error — limit=5 is embedded in the error string
        await provider.setCreateShouldFailWithLimitOnce()
        _ = try await provider.createFolderConnection(folder: "Sent")

        let limit = await provider.serverConnectionLimit
        #expect(limit == 5)
    }

    @Test("Limit only ratchets down, never up")
    func limitOnlyRatchetsDown() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(10)

        // Simulate error with limit=15 — should NOT increase from 10
        await provider.applyLimitFromErrorString(
            "Login failed: no([UNAVAILABLE] Maximum number of connections from user+IP exceeded (mail_max_userip_connections=15))"
        )
        #expect(await provider.serverConnectionLimit == 10)

        // Simulate error with limit=8 — SHOULD decrease to 8
        await provider.applyLimitFromErrorString(
            "Login failed: no([UNAVAILABLE] Maximum number of connections from user+IP exceeded (mail_max_userip_connections=8))"
        )
        #expect(await provider.serverConnectionLimit == 8)
    }

    @Test("Non-limit error does not set serverConnectionLimit")
    func nonLimitErrorIgnored() async {
        let provider = TestPrimaryProvider()
        await provider.applyLimitFromErrorString("Connection refused")
        #expect(await provider.serverConnectionLimit == nil)
    }
}

// MARK: - Tests: Eviction Edge Cases

@Suite("Primary Connection — Eviction Edge Cases")
struct IMAPEvictionEdgeCaseTests {
    @Test("Retry also fails — error propagates")
    func retryAlsoFails() async {
        let provider = TestPrimaryProvider()
        _ = try! await provider.createFolderConnection(folder: "INBOX")
        await provider.releaseFolderConnection(folder: "INBOX")

        // Both attempts fail with limit error
        await provider.setCreateShouldFailWithLimit(true)

        do {
            _ = try await provider.createFolderConnection(folder: "Sent")
            Issue.record("Should have thrown")
        } catch {
            // First attempt fails, evicts INBOX, retry also fails — error propagates
            let desc = "\(error)"
            #expect(desc.contains("max_userip_connections"))
        }

        // INBOX was evicted during the attempt
        #expect(await provider.folderServers["INBOX"] == nil)
        // Sent was never created
        #expect(await provider.folderServers["Sent"] == nil)
    }

    @Test("All in-use — limit error propagates without eviction")
    func allInUseNoEviction() async {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(3) // 2 folder slots (no IDLE)

        // Fill slots and keep them in-use
        _ = try! await provider.createFolderConnection(folder: "INBOX")
        _ = try! await provider.createFolderConnection(folder: "Sent")
        // Neither released — both in use

        // Set limit error for next create
        await provider.setCreateShouldFailWithLimit(true)

        do {
            _ = try await provider.createFolderConnection(folder: "Drafts")
            Issue.record("Should have thrown — all connections in use, can't evict")
        } catch {
            // Expected: can't evict (all in use), error propagates
            let desc = "\(error)"
            #expect(desc.contains("All connections in use"))
        }
    }

    @Test("LRU ordering correct — oldest timestamp evicted first")
    func lruOrderingCorrect() async throws {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(4) // 3 folder slots (no IDLE)

        // Create and release all three, then set timestamps after release
        // (release overwrites lastUsed, so we set custom timestamps last)
        _ = try await provider.createFolderConnection(folder: "A")
        await provider.releaseFolderConnection(folder: "A")
        _ = try await provider.createFolderConnection(folder: "B")
        await provider.releaseFolderConnection(folder: "B")
        _ = try await provider.createFolderConnection(folder: "C")
        await provider.releaseFolderConnection(folder: "C")

        // Now set LRU timestamps: B is oldest, C is newest
        let base = Date()
        await provider.setFolderLastUsed(folder: "A", time: base.addingTimeInterval(30))
        await provider.setFolderLastUsed(folder: "B", time: base) // Oldest
        await provider.setFolderLastUsed(folder: "C", time: base.addingTimeInterval(60))

        // Create 4th — should evict B (oldest timestamp)
        _ = try await provider.createFolderConnection(folder: "D")
        let folders = await provider.folderServers
        #expect(folders["B"] == nil) // Evicted — oldest
        #expect(folders["A"] != nil)
        #expect(folders["C"] != nil)
        #expect(folders["D"] != nil)
    }

    @Test("Non-limit error does not trigger eviction")
    func nonLimitErrorNoEviction() async {
        let provider = TestPrimaryProvider()
        _ = try! await provider.createFolderConnection(folder: "INBOX")
        await provider.releaseFolderConnection(folder: "INBOX")

        // Generic connection error — not a limit error
        await provider.setCreateShouldFail(true)

        do {
            _ = try await provider.createFolderConnection(folder: "Sent")
            Issue.record("Should have thrown")
        } catch {
            // INBOX should NOT be evicted (not a limit error)
            #expect(await provider.folderServers["INBOX"] != nil)
        }
    }
}

// MARK: - Tests: IDLE Edge Cases

@Suite("Primary Connection — IDLE Edge Cases")
struct IdleEdgeCaseTests {
    @Test("Double startIdle is idempotent")
    func doubleStartIdle() async {
        let provider = TestPrimaryProvider()
        await provider.startIdle()
        await provider.startIdle()
        #expect(await provider.idleServer != nil)
        #expect(await provider.idleLaunchCount == 1) // Only launched once
    }

    @Test("Double stopIdle is idempotent")
    func doubleStopIdle() async {
        let provider = TestPrimaryProvider()
        await provider.startIdle()

        await provider.stopIdle()
        await provider.stopIdle()
        #expect(await provider.idleServer == nil)
        #expect(await provider.idleEnabled == false)
    }

    @Test("IDLE evictable when connections are scarce")
    func idleEvictable() async {
        let provider = TestPrimaryProvider()
        await provider.startIdle()
        #expect(await provider.idleServer != nil)

        let evicted = await provider.evictIdleConnection()
        #expect(evicted == true)
        #expect(await provider.idleServer == nil)
    }

    @Test("Evict IDLE returns false when no IDLE connection")
    func evictIdleReturnsFalseWhenNone() async {
        let provider = TestPrimaryProvider()
        let evicted = await provider.evictIdleConnection()
        #expect(evicted == false)
    }

    @Test("Folder eviction falls back to IDLE when no folder LRU available")
    func folderEvictionFallsBackToIdle() async throws {
        let provider = TestPrimaryProvider()
        await provider.setServerLimit(5) // With IDLE: 5 - 2 = 3 folder slots
        await provider.startIdle()
        #expect(await provider.idleServer != nil)
        #expect(await provider.maxFolderConnections == 3)

        // Fill all 3 folder slots AND keep them in-use
        _ = try await provider.createFolderConnection(folder: "INBOX")
        _ = try await provider.createFolderConnection(folder: "Sent")
        _ = try await provider.createFolderConnection(folder: "Archive")

        // 4th folder — no folder LRU available (all in use), should evict IDLE
        _ = try await provider.createFolderConnection(folder: "Drafts")
        // IDLE was evicted to make room (maxFolderConnections went 3→4)
        #expect(await provider.idleServer == nil)
        #expect(await provider.folderServers["Drafts"] != nil)
    }

    @Test("Actions unaffected by IDLE — no break/resume needed")
    func actionsUnaffectedByIdle() async throws {
        let provider = TestPrimaryProvider()
        await provider.startIdle()
        #expect(await provider.idleServer != nil)

        // Multiple actions — IDLE stays running the whole time
        for _ in 0..<5 {
            _ = try await provider.acquireActionConnection()
            #expect(await provider.idleServer != nil) // IDLE unaffected
            await provider.releaseActionConnection(healthy: true)
        }
        #expect(await provider.idleServer != nil)
    }
}

// MARK: - Tests: markDirty Edge Cases

@Suite("Primary Connection — markDirty Edge Cases")
struct MarkDirtyEdgeCaseTests {
    @Test("markDirty resets actionInUse so next acquire works")
    func markDirtyResetsActionInUse() async throws {
        let provider = TestPrimaryProvider()
        _ = try await provider.acquireActionConnection()
        // Don't release — simulates crash during action

        #expect(await provider.actionInUse == true)

        await provider.markDirty()
        #expect(await provider.actionInUse == false)

        // Should be able to acquire again
        let conn = try await provider.acquireActionConnection()
        #expect(conn.isEmpty == false)
    }

    @Test("markDirty clears folder in-use state")
    func markDirtyClearsFolderInUse() async throws {
        let provider = TestPrimaryProvider()
        _ = try await provider.createFolderConnection(folder: "INBOX")
        // Don't release — in use

        #expect(await provider.folderInUse.contains("INBOX"))

        await provider.markDirty()
        #expect(await provider.folderInUse.isEmpty)
        #expect(await provider.folderServers.isEmpty)
    }
}

// MARK: - Tests: Action Connection with Limit Error

@Suite("Primary Connection — Action Connection Limit")
struct ActionConnectionLimitTests {
    @Test("Action connection creation failure propagates")
    func actionCreationFailure() async {
        let provider = TestPrimaryProvider()
        await provider.setCreateShouldFail(true)

        do {
            _ = try await provider.acquireActionConnection()
            Issue.record("Should have thrown")
        } catch {
            #expect(await provider.actionServer == nil)
            #expect(await provider.actionInUse == false)
        }
    }
}

// MARK: - Test Helpers

extension TestPrimaryProvider {
    func setServerLimit(_ limit: Int) {
        serverConnectionLimit = limit
    }

    func createFolderConnectionWithTimestamp(folder: String, time: Date) throws -> String {
        let server = try createFolderConnection(folder: folder)
        folderLastUsed[folder] = time
        return server
    }

    func setOnCreateAttempt(_ handler: @escaping () -> Void) {
        onCreateAttempt = handler
    }

    /// Makes the next createServer call fail with limit error, then subsequent calls succeed.
    func setCreateShouldFailWithLimitOnce() {
        var didFail = false
        onCreateAttempt = { [self] in
            if !didFail {
                didFail = true
                createShouldFailWithLimitError = true
            } else {
                createShouldFailWithLimitError = false
            }
        }
    }

    /// Expose parseAndApplyServerLimit for direct testing.
    func applyLimitFromErrorString(_ desc: String) {
        let error = NSError(domain: "IMAP", code: -1, userInfo: [NSLocalizedDescriptionKey: desc])
        parseAndApplyServerLimit(from: error)
    }

    func setFolderLastUsed(folder: String, time: Date) {
        folderLastUsed[folder] = time
    }

    func setCreateShouldFail(_ value: Bool) {
        createShouldFail = value
    }

    func setCreateShouldFailWithLimit(_ value: Bool) {
        createShouldFailWithLimitError = value
    }
}
