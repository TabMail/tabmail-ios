/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Regression coverage for the Fast Sync / backfill completion gate.
//
// Bug: `BackfillProgress.isFullyComplete` used to be `headersDone && totalEmails
// > 0 && ftsIndexed >= totalEmails`. For Gmail/Exchange, `totalEmails` is a
// server-reported count (Exchange: SUM(folder.totalItemCount) incl. Deleted
// Items, Junk, hidden/system folders, and non-mail items dropped on parse;
// Gmail: dedup'd messagesTotal vs. our per-label rows). That denominator counts
// a different population than the mail headers we store, so it can permanently
// exceed `ftsIndexed`, making `isFullyComplete` unsatisfiable — the Outlook
// account never showed "Sync Complete". The fix gates completion on
// `pendingBodyCount == 0` (body-eligible headers still awaiting fetch).
@Suite("BackfillProgress completion gate")
struct BackfillProgressCompletionTests {

    private func progress(
        headersDone: Bool,
        totalEmails: Int,
        ftsIndexed: Int,
        pendingBodyCount: Int,
        unindexedBodyCount: Int = 0,
        uidTotal: Int = 0
    ) -> BackfillProgress {
        var p = BackfillProgress(
            accountId: "acct",
            email: "user@example.com",
            startedAt: Date(),
            isPaused: false,
            headersDone: headersDone,
            totalEmails: totalEmails,
            ftsIndexed: ftsIndexed
        )
        p.uidTotal = uidTotal
        p.pendingBodyCount = pendingBodyCount
        p.unindexedBodyCount = unindexedBodyCount
        return p
    }

    @Test("Exchange: inflated server total no longer wedges completion")
    func exchangeInflatedServerTotalCompletes() {
        // The reported bug: server-reported total (SUM of folder totalItemCount,
        // incl. deleted/hidden/non-mail items) permanently exceeds what we store.
        // headers walked, every fetchable body indexed → must be complete even
        // though ftsIndexed (4200) < totalEmails (5000).
        let p = progress(headersDone: true, totalEmails: 5000, ftsIndexed: 4200, pendingBodyCount: 0)
        #expect(p.ftsIndexed < p.totalEmails)          // old gate would have been false
        #expect(p.isFullyComplete)                     // new gate: pendingBodyCount == 0
    }

    @Test("Not complete while body-eligible headers remain")
    func pendingBodiesBlockCompletion() {
        // Even if ftsIndexed already meets/exceeds the displayed total, an
        // outstanding body-fetch keeps it incomplete.
        let p = progress(headersDone: true, totalEmails: 1000, ftsIndexed: 1000, pendingBodyCount: 7)
        #expect(!p.isFullyComplete)
    }

    @Test("Not complete until header walk finishes")
    func headerWalkGatesCompletion() {
        let p = progress(headersDone: false, totalEmails: 1000, ftsIndexed: 1000, pendingBodyCount: 0)
        #expect(!p.isFullyComplete)
    }

    @Test("Empty/initializing account (totalEmails == 0) is not complete")
    func zeroTotalNotComplete() {
        let p = progress(headersDone: true, totalEmails: 0, ftsIndexed: 0, pendingBodyCount: 0)
        #expect(!p.isFullyComplete)
    }

    @Test("IMAP sound path stays sound")
    func imapCompletes() {
        // IMAP uses grdbTotal as the denominator (uidTotal > 0). Walk done, no
        // bodies pending → complete.
        let p = progress(headersDone: true, totalEmails: 800, ftsIndexed: 800, pendingBodyCount: 0, uidTotal: 12_000)
        #expect(p.isFullyComplete)
    }

    @Test("Terminal-unindexed bodies allow truthful completion and a full progress bar")
    func terminalUnindexedCompletesTruthfully() {
        let p = progress(
            headersDone: true,
            totalEmails: 100,
            ftsIndexed: 98,
            pendingBodyCount: 0,
            unindexedBodyCount: 2
        )
        #expect(p.isFullyComplete)
        #expect(p.unindexedBodyCount == 2)
        #expect(p.fractionComplete == 1.0)
        #expect(BodyIndexingProgressText.completion(unindexedCount: 2)
                == "Sync complete with 2 messages not indexed")
    }

    @Test("Terminal completion text handles singular and clean completion")
    func terminalCompletionTextGrammar() {
        #expect(BodyIndexingProgressText.completion(unindexedCount: 0) == "Sync complete")
        #expect(BodyIndexingProgressText.completion(unindexedCount: 1)
                == "Sync complete with 1 message not indexed")
    }

    @Test("Display fraction is unchanged (still ftsIndexed / totalEmails)")
    func fractionStillUsesDisplayCounts() {
        // Completion decoupled from the bar, but the bar still reflects indexed
        // progress against the displayed total.
        let p = progress(headersDone: true, totalEmails: 1000, ftsIndexed: 250, pendingBodyCount: 3)
        #expect(abs(p.fractionComplete - 0.25) < 0.0001)
    }
}
