/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The read-through merge's signature skip (`NSEDataBridge.shouldSkipReadThroughMerge`).
/// The skip must be DEFERRAL-ONLY: an exact signature match within TTL skips;
/// every mismatch (any stage transition) or TTL expiry merges.
@Suite("Staging signature skip (read-through merge churn fix)")
struct StagingSignatureSkipTests {

    private func sig(
        count: Int = 1,
        maxProcessedAt: Double = 1_000_000,
        bodied: Int = 0,
        summaried: Int = 0,
        aiDone: Int = 0
    ) -> NSEDataBridge.StagingSignature {
        NSEDataBridge.StagingSignature(
            count: count, maxProcessedAt: maxProcessedAt,
            bodiedCount: bodied, summariedCount: summaried, aiCompletedCount: aiDone
        )
    }

    @Test("no recorded signature → merge (never skip on first sight)")
    func noRecordMerges() {
        let now = CFAbsoluteTimeGetCurrent()
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(current: sig(), last: nil, now: now))
    }

    @Test("exact match within TTL → skip (the churn case)")
    func matchWithinTTLSkips() {
        let now = CFAbsoluteTimeGetCurrent()
        let last = (sig: sig(), at: now - 1)
        #expect(NSEDataBridge.shouldSkipReadThroughMerge(current: sig(), last: last, now: now, ttl: 5))
    }

    @Test("TTL expiry → merge even on exact match (retry/self-heal backstop)")
    func ttlExpiryMerges() {
        let now = CFAbsoluteTimeGetCurrent()
        let last = (sig: sig(), at: now - 6)
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(current: sig(), last: last, now: now, ttl: 5))
    }

    @Test("every stage transition changes the signature → merge")
    func stageTransitionsMerge() {
        let now = CFAbsoluteTimeGetCurrent()
        let base = sig()
        let last = (sig: base, at: now - 1)
        // New header row arrives (count + maxProcessedAt move).
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(
            current: sig(count: 2, maxProcessedAt: 1_000_050), last: last, now: now, ttl: 5))
        // stageBody lands (html/text NULL→non-NULL) — processedAt does NOT move.
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(
            current: sig(bodied: 1), last: last, now: now, ttl: 5))
        // stageSummary lands.
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(
            current: sig(summaried: 1), last: last, now: now, ttl: 5))
        // Terminal persist flips aiCompleted.
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(
            current: sig(aiDone: 1), last: last, now: now, ttl: 5))
        // Merge's own terminal delete shrinks the set (settling re-merge).
        #expect(!NSEDataBridge.shouldSkipReadThroughMerge(
            current: sig(count: 0, maxProcessedAt: 0), last: last, now: now, ttl: 5))
    }
}
