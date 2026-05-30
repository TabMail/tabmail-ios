/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - Test Actor

/// Replicates the on-demand body fetch decision from MessageDetailViewModel.loadBody():
/// if the body queue already has the message queued/in-flight, skip IMAP fetch and poll instead.
private actor TestOnDemandFetch {
    enum FetchResult {
        case bodyAlreadyLoaded
        case deferredToBackgroundQueue  // body queue has it — poll instead of IMAP fetch
        case fetchedFromServer
        case fetchFailed(String)
    }

    /// Simulates the body queue's enqueued set
    private var queuedHeaderIds: Set<String> = []
    /// Simulates MessageBody existence in GRDB
    private var bodiesInDB: Set<String> = []
    /// Whether IMAP fetch should succeed
    private var imapFetchSucceeds = true

    func setImapFetchSucceeds(_ value: Bool) {
        imapFetchSucceeds = value
    }

    func enqueueInBodyQueue(_ headerId: String) {
        queuedHeaderIds.insert(headerId)
    }

    func completeBodyFetch(_ headerId: String) {
        queuedHeaderIds.remove(headerId)
        bodiesInDB.insert(headerId)
    }

    func isQueuedOrInFlight(_ headerId: String) -> Bool {
        queuedHeaderIds.contains(headerId)
    }

    func hasBody(_ headerId: String) -> Bool {
        bodiesInDB.contains(headerId)
    }

    /// Replicates the loadBody() decision logic
    func loadBody(headerId: String) async -> FetchResult {
        // 1. Body already loaded?
        if hasBody(headerId) { return .bodyAlreadyLoaded }

        // 2. Body queue has it? → defer to poll
        if isQueuedOrInFlight(headerId) { return .deferredToBackgroundQueue }

        // 3. Fetch from server
        if imapFetchSucceeds {
            bodiesInDB.insert(headerId)
            return .fetchedFromServer
        } else {
            return .fetchFailed("Cannot connect to server")
        }
    }
}

// MARK: - Suite 1: Queue Check Decision

@Suite("On-Demand Body Fetch - Queue Check")
struct QueueCheckTests {

    @Test("Body already in DB — returns immediately, no queue check needed")
    func bodyAlreadyLoaded() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.completeBodyFetch("msg1")

        let result = await fetcher.loadBody(headerId: "msg1")
        guard case .bodyAlreadyLoaded = result else {
            Issue.record("Expected .bodyAlreadyLoaded, got \(result)")
            return
        }
    }

    @Test("Body queue has message in-flight — defers to poll, no IMAP fetch")
    func defersToBackgroundQueue() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")

        let result = await fetcher.loadBody(headerId: "msg1")
        guard case .deferredToBackgroundQueue = result else {
            Issue.record("Expected .deferredToBackgroundQueue, got \(result)")
            return
        }
    }

    @Test("Body queue does NOT have message — fetches from server")
    func fetchesFromServer() async {
        let fetcher = TestOnDemandFetch()

        let result = await fetcher.loadBody(headerId: "msg1")
        guard case .fetchedFromServer = result else {
            Issue.record("Expected .fetchedFromServer, got \(result)")
            return
        }
    }

    @Test("Body queue has message but IMAP would fail — no error shown (deferred)")
    func noErrorWhenDeferred() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")
        await fetcher.setImapFetchSucceeds(false)  // Would fail if attempted

        let result = await fetcher.loadBody(headerId: "msg1")
        // Should defer, NOT attempt IMAP and get a failure
        guard case .deferredToBackgroundQueue = result else {
            Issue.record("Expected .deferredToBackgroundQueue, got \(result)")
            return
        }
    }

    @Test("Not in queue + IMAP fails — shows error")
    func showsErrorWhenNotQueued() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.setImapFetchSucceeds(false)

        let result = await fetcher.loadBody(headerId: "msg1")
        guard case .fetchFailed = result else {
            Issue.record("Expected .fetchFailed, got \(result)")
            return
        }
    }
}

// MARK: - Suite 2: Race Timing

@Suite("On-Demand Body Fetch - Race Timing")
struct RaceTimingTests {

    @Test("Background queue completes after user opens — poll finds body")
    func backgroundCompletesAfterOpen() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")

        // User opens message — defers to poll
        let result = await fetcher.loadBody(headerId: "msg1")
        guard case .deferredToBackgroundQueue = result else {
            Issue.record("Expected .deferredToBackgroundQueue")
            return
        }
        #expect(await fetcher.hasBody("msg1") == false)

        // Background queue completes
        await fetcher.completeBodyFetch("msg1")

        // Poll finds body
        #expect(await fetcher.hasBody("msg1") == true)
    }

    @Test("Background queue completes BEFORE user opens — body already loaded")
    func backgroundCompletesBeforeOpen() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")
        await fetcher.completeBodyFetch("msg1")

        let result = await fetcher.loadBody(headerId: "msg1")
        guard case .bodyAlreadyLoaded = result else {
            Issue.record("Expected .bodyAlreadyLoaded, got \(result)")
            return
        }
    }

    @Test("Multiple messages: one queued, one not — correct decision per message")
    func mixedQueueState() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")
        // msg2 not queued

        let result1 = await fetcher.loadBody(headerId: "msg1")
        let result2 = await fetcher.loadBody(headerId: "msg2")

        guard case .deferredToBackgroundQueue = result1 else {
            Issue.record("msg1 should defer")
            return
        }
        guard case .fetchedFromServer = result2 else {
            Issue.record("msg2 should fetch from server")
            return
        }
    }

    @Test("User opens, defers, then opens again after body arrives — loads from DB")
    func reopenAfterBodyArrives() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")

        // First open — defers
        let result1 = await fetcher.loadBody(headerId: "msg1")
        guard case .deferredToBackgroundQueue = result1 else {
            Issue.record("First open should defer")
            return
        }

        // Background completes
        await fetcher.completeBodyFetch("msg1")

        // Second open — body in DB
        let result2 = await fetcher.loadBody(headerId: "msg1")
        guard case .bodyAlreadyLoaded = result2 else {
            Issue.record("Second open should find body, got \(result2)")
            return
        }
    }
}

// MARK: - Suite 3: isQueuedOrInFlight

@Suite("On-Demand Body Fetch - Queue Membership")
struct QueueMembershipTests {

    @Test("isQueuedOrInFlight returns true for enqueued message")
    func enqueuedReturnsTrue() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")
        #expect(await fetcher.isQueuedOrInFlight("msg1") == true)
    }

    @Test("isQueuedOrInFlight returns false for unknown message")
    func unknownReturnsFalse() async {
        let fetcher = TestOnDemandFetch()
        #expect(await fetcher.isQueuedOrInFlight("msg1") == false)
    }

    @Test("isQueuedOrInFlight returns false after completion")
    func completedReturnsFalse() async {
        let fetcher = TestOnDemandFetch()
        await fetcher.enqueueInBodyQueue("msg1")
        await fetcher.completeBodyFetch("msg1")
        #expect(await fetcher.isQueuedOrInFlight("msg1") == false)
    }
}
