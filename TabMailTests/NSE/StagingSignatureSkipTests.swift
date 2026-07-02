/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
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

/// `.messagesStaged` re-post suppression (`NSEDataBridge.stagedSetChangedSinceLastPost`):
/// a re-merge of a KEPT gradual row re-reads an UNCHANGED staged set and must not
/// re-post it (observed ~5s cadence for 43+s while NSE AI ran). Pure in-memory
/// memo — no DB read on the render path.
@Suite("Staged-set re-post suppression")
struct StagedSetRepostSuppressionTests {

    private func row(_ messageId: String, snippet: String = "snip") -> StagedInboxRow {
        StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@x>", threadId: nil, inReplyTo: nil, references: [],
            subject: "S", senderName: "N", senderAddress: "s@example.com",
            to: "me@example.com", snippet: snippet, date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    // NOTE: results are bound to locals before `#expect` — the macro captures call
    // arguments for failure diagnostics, which requires Copyable, and `Mutex` isn't.

    @Test("first post fires; identical re-read is suppressed")
    func identicalSetSuppressed() {
        let memo = Mutex<[StagedInboxRow]>([])
        // Reuse the SAME row value — `row()` stamps `Date()`, so two builds differ.
        // A real re-merge re-reads identical staging content, i.e. equal rows.
        let m1 = row("m1")
        let first = NSEDataBridge.stagedSetChangedSinceLastPost([m1], memo: memo)
        let second = NSEDataBridge.stagedSetChangedSinceLastPost([m1], memo: memo)
        #expect(first)
        #expect(!second)
    }

    @Test("order changes don't count as a change (headerId-normalized)")
    func orderInsensitive() {
        let memo = Mutex<[StagedInboxRow]>([])
        let m1 = row("m1")
        let m2 = row("m2")
        let first = NSEDataBridge.stagedSetChangedSinceLastPost([m1, m2], memo: memo)
        let reordered = NSEDataBridge.stagedSetChangedSinceLastPost([m2, m1], memo: memo)
        #expect(first)
        #expect(!reordered)
    }

    @Test("content or membership change re-posts")
    func changedSetPosts() {
        let memo = Mutex<[StagedInboxRow]>([])
        let m1 = row("m1")
        let m2 = row("m2")
        let m1Snippeted = row("m1", snippet: "new")
        let first = NSEDataBridge.stagedSetChangedSinceLastPost([m1], memo: memo)
        // New member (m1 unchanged — the growth alone must trigger the post).
        let grown = NSEDataBridge.stagedSetChangedSinceLastPost([m1, m2], memo: memo)
        // Same members, one row's content changed (e.g. NSE snippet update).
        let mutated = NSEDataBridge.stagedSetChangedSinceLastPost([m1Snippeted, m2], memo: memo)
        // And an unchanged re-read of that same set is suppressed again.
        let settled = NSEDataBridge.stagedSetChangedSinceLastPost([m1Snippeted, m2], memo: memo)
        #expect(first)
        #expect(grown)
        #expect(mutated)
        #expect(!settled)
    }

    @Test("drained set resets the memo — a later identical re-stage posts again")
    func drainResets() {
        let memo = Mutex<[StagedInboxRow]>([])
        let m1 = row("m1")
        let first = NSEDataBridge.stagedSetChangedSinceLastPost([m1], memo: memo)
        // Drained merge (empty read) — no post happens (caller gates on isEmpty),
        // but the memo must reset: the SAME row value must post again after it.
        _ = NSEDataBridge.stagedSetChangedSinceLastPost([], memo: memo)
        let restaged = NSEDataBridge.stagedSetChangedSinceLastPost([m1], memo: memo)
        #expect(first)
        #expect(restaged)
    }
}
