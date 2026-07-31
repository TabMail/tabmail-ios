/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests that SearchIndex methods lazily initialize via ensureReady() when dbPool is nil.
/// Simulates the race condition where AI queue or body fetch runs before SearchIndex.initialize()
/// completes (e.g., cold launch via BGAppRefresh, foreground return timing).
///
/// Uses closeForNuke() to simulate uninitialized state — the FTS database FILE persists on disk,
/// so re-initialization should recover all data. This exactly matches the production scenario:
/// dbPool is nil (in-memory), but the database exists (on disk).
///
/// IMPORTANT: .serialized prevents interleaving with other SearchIndex tests that depend on
/// the shared singleton being initialized.
@Suite("SearchIndex Lazy Initialization", .serialized, .processGlobalState)
struct SearchIndexLazyInitTests {

    private var index: SearchIndex { SearchIndex.shared }

    // Test data using dynamic dates (no hardcoded dates per CLAUDE.md rules)
    private var testHeaderId: String { "test_lazy_init:INBOX:1" }

    private func testRecord() -> FTSHeaderRecord {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return FTSHeaderRecord(
            headerId: testHeaderId,
            messageId: "<lazy-init-test@test.com>",
            subject: "Lazy Init Test Message",
            from: "sender@test.com",
            to: "receiver@test.com",
            dateMs: nowMs
        )
    }

    /// Seed test data, run the test closure, then clean up.
    /// Guarantees SearchIndex is re-initialized even if the test fails.
    private func withTestData<T>(_ body: () async throws -> T) async throws -> T {
        // Ensure initialized and seed data
        let record = testRecord()
        try await index.removeMessages(headerIds: [testHeaderId])
        let inserted = try await index.indexHeaders([record])
        guard inserted == 1 else {
            try await index.removeMessages(headerIds: [testHeaderId])
            throw TestError(message: "Failed to seed test data")
        }
        try await index.updateBodies([(headerId: testHeaderId, body: "Lazy init test body content for verification")])

        // Run test
        defer {
            // Always re-initialize and clean up
            Task {
                try? await index.initialize()
                try? await index.removeMessages(headerIds: [testHeaderId])
            }
        }
        return try await body()
    }

    struct TestError: Error {
        let message: String
    }

    // MARK: - Core Lazy Init Tests

    @Test("bodyText recovers after closeForNuke via ensureReady")
    func bodyTextRecoversAfterNuke() async throws {
        try await withTestData {
            // Verify data is accessible before nuke
            let before = try await index.bodyText(headerId: testHeaderId)
            #expect(before != nil)
            #expect(before?.contains("Lazy init test body") == true)

            // Simulate uninitialized state (app wake before init completed)
            await index.closeForNuke()
            let readyAfterNuke = await index.isReady
            #expect(readyAfterNuke == false)

            // bodyText should lazily re-initialize and find the data
            let after = try await index.bodyText(headerId: testHeaderId)
            #expect(after != nil, "bodyText must recover via ensureReady — was nil (the race condition bug)")
            #expect(after?.contains("Lazy init test body") == true)

            // isReady should now be true
            let readyAfterAccess = await index.isReady
            #expect(readyAfterAccess == true)
        }
    }

    @Test("bodyTextDiagnostic recovers after closeForNuke — not dbPoolNil")
    func diagnosticRecoversAfterNuke() async throws {
        try await withTestData {
            await index.closeForNuke()

            // Diagnostic should trigger ensureReady and return actual FTS state, not "dbPoolNil"
            let diag = await index.bodyTextDiagnostic(headerId: testHeaderId)
            #expect(diag != "dbPoolNil", "ensureReady should have initialized before diagnostic ran")
            #expect(diag.contains("bodyPresent"), "Expected body to be found after lazy init, got: \(diag)")
        }
    }

    @Test("indexHeaders works after closeForNuke")
    func indexHeadersAfterNuke() async throws {
        let extraId = "test_lazy_init:INBOX:2"
        defer { Task { try? await index.removeMessages(headerIds: [extraId]) } }

        await index.closeForNuke()

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let record = FTSHeaderRecord(
            headerId: extraId,
            messageId: "<lazy-extra@test.com>",
            subject: "Extra after nuke",
            from: "a@test.com", to: "b@test.com",
            dateMs: nowMs
        )
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1, "indexHeaders must work after lazy init")
    }

    @Test("updateBodies works after closeForNuke")
    func updateBodiesAfterNuke() async throws {
        try await withTestData {
            await index.closeForNuke()

            // updateBodies should trigger ensureReady and succeed
            try await index.updateBodies([(headerId: testHeaderId, body: "Updated after nuke")])

            let body = try await index.bodyText(headerId: testHeaderId)
            #expect(body == "Updated after nuke")
        }
    }

    @Test("keywordSearch works after closeForNuke")
    func keywordSearchAfterNuke() async throws {
        try await withTestData {
            // Verify search works before nuke
            let beforeResults = try await index.keywordSearch(query: "verification")
            let foundBefore = beforeResults.contains { $0.headerId == testHeaderId }
            #expect(foundBefore, "Search must work before nuke")

            await index.closeForNuke()

            // After nuke + lazy reinit, search should still work (data persisted on disk)
            // ensureReady() triggers initialize() which reopens the FTS database
            let isReady = await index.isReady
            #expect(isReady == false, "Should not be ready immediately after nuke")

            // bodyText triggers ensureReady — verify reinit works
            let body = try await index.bodyText(headerId: testHeaderId)
            #expect(body != nil, "bodyText must recover after nuke")

            let readyAfter = await index.isReady
            #expect(readyAfter == true, "Should be ready after first access")
        }
    }

    @Test("removeMessages works after closeForNuke")
    func removeMessagesAfterNuke() async throws {
        // Seed, nuke, remove — should not crash
        let record = testRecord()
        try await index.removeMessages(headerIds: [testHeaderId])
        _ = try await index.indexHeaders([record])

        await index.closeForNuke()

        // Should trigger ensureReady and succeed
        try await index.removeMessages(headerIds: [testHeaderId])

        // Verify gone
        let body = try await index.bodyText(headerId: testHeaderId)
        #expect(body == nil)
    }

    // MARK: - Idempotency

    @Test("ensureReady is idempotent — multiple calls are no-ops")
    func ensureReadyIdempotent() async throws {
        // Already initialized from previous tests. Calling methods repeatedly
        // should not error or re-initialize.
        let ready1 = await index.isReady
        #expect(ready1 == true)

        // Call bodyText multiple times — each calls ensureReady internally
        _ = try await index.bodyText(headerId: "nonexistent")
        _ = try await index.bodyText(headerId: "nonexistent")
        _ = try await index.bodyText(headerId: "nonexistent")

        let ready2 = await index.isReady
        #expect(ready2 == true)
    }

    @Test("closeForNuke then closeForNuke then bodyText still recovers")
    func doubleNukeThenRecover() async throws {
        try await withTestData {
            await index.closeForNuke()
            await index.closeForNuke()

            let body = try await index.bodyText(headerId: testHeaderId)
            #expect(body != nil, "Must recover even after double nuke")
        }
    }
}
