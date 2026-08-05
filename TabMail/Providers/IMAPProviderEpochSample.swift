/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// T4.S6b — `IMAPProvider`'s override of
/// `EmailProvider.sampleHeadersForEpochVerification(folder:uids:)`.
///
/// This is an `extension IMAPProvider`; there is no `IMAPProviderEpochSample`
/// TYPE to cite. It lives in its own file DELIBERATELY: `IMAPProvider.swift` is
/// concurrently modified on this branch, and a one-function override does not
/// justify a merge conflict in a 5,000-line file. Nothing here may grow into
/// general IMAP plumbing — if this file ever needs a second member, that is the
/// signal to fold it back into `IMAPProvider.swift` on a clean tree.
extension IMAPProvider {

    /// Delegates to `fetchMessageHeadersWithObservedEpoch`, which already returns
    /// exactly the pair this seam is specified to produce: `MessageHeaderInfo`s
    /// carrying `messageId` (the UID as a string) and an ALREADY-NORMALIZED
    /// `rfc822MessageId` (`IMAPFetchMapping.rfc822MessageId` runs
    /// `EmailFilter.normalizeMessageId`), plus the UIDVALIDITY of the SELECT that
    /// served the fetch — taken from the returned `Mailbox.Selection`, never from
    /// the shared `lastObservedUidValidityBox` mirror.
    ///
    /// **`batchSize` is sized so exactly ONE SELECT happens.**
    /// `fetchMessageHeadersWithObservedEpoch` collapses `observedEpoch` to nil when
    /// ANY batch's SELECT reported none OR two batches reported different values.
    /// Both collapses are fail-closed, but only a single batch makes
    /// `observedEpoch == nil` mean the ONE thing the consumer's anti-brick rule keys
    /// on: *this* SELECT reported no UIDVALIDITY. `SyncConfig
    /// .uidValidityVerifyFetchBatchSize` is the sample's own total size, and the
    /// consumer never asks for more UIDs than that.
    ///
    /// `interBatchDelay: 0` is stated rather than defaulted: with one batch the
    /// delay is unreachable (`fetchMessageHeadersWithObservedEpoch` sleeps only when
    /// `offset < uids.count` after a batch), and 0 makes the "one round trip"
    /// intent explicit rather than dependent on that reachability argument.
    ///
    /// ⚠ **No `options:` parameter, deliberately.** This inherits
    /// `FetchMessageInfoOptions.default` (envelope + internalDate + flags +
    /// bodyStructure + fullHeader), which is heavier than the envelope-only fetch
    /// this seam actually needs. For <10 UIDs, once per folder per upgrade, that is
    /// negligible — and adding an `options:` parameter means editing
    /// `IMAPProvider.swift`, which this file exists to avoid. If the payload ever
    /// matters, `FetchMessageInfoOptions.slim` exists in the pinned SwiftMail fork;
    /// that is a later, separate change.
    ///
    /// ⚠ **The SELECT will never refuse on the consumer's behalf.**
    /// `IMAPProvider.selectMailboxTracked` in this tree is a bare mirror write: it
    /// carries no stored-vs-observed comparison and no
    /// `ProviderError.uidValidityChanged` throw. ⚠️ CORRECTED 2026-08-05: this
    /// justified itself with "(`rg -n "uidValidityChanged" TabMail/` finds no
    /// declaration and no throw site — every hit is prose)", which became false at
    /// `065a827ca` (2026-08-02), inside the release range. The case is DECLARED in
    /// `ProviderError` (`EmailProvider.swift`) and THROWN by
    /// `IMAPProvider.requireUidValidity` — on the ACTION path, never in
    /// `selectMailboxTracked`. The warning above is therefore still correct: this
    /// SELECT will never refuse on the consumer's behalf. Every
    /// comparison is the consumer's own responsibility.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`**: `git grep -n
    /// "fetchMessageHeadersWithObservedEpoch" v2final` returns ZERO hits, and the
    /// reference has no epoch-verification seam of any shape (see
    /// `SyncEngine.verifyAndBootstrapPrePopulatedFolderEpoch`'s own ⚑ note for the
    /// three disproof searches).
    func sampleHeadersForEpochVerification(
        folder: String, uids: [UInt32]
    ) async throws -> (messages: [MessageHeaderInfo], observedEpoch: UInt32?) {
        // An empty request performs no SELECT and therefore observes no epoch —
        // `fetchMessageHeadersWithObservedEpoch` guards this too, restated here so
        // the "nil means THIS SELECT reported none" contract holds by construction
        // rather than by delegation.
        guard !uids.isEmpty else { return ([], nil) }
        return try await fetchMessageHeadersWithObservedEpoch(
            folder: folder,
            uids: uids,
            batchSize: max(uids.count, SyncConfig.uidValidityVerifyFetchBatchSize),
            interBatchDelay: 0
        )
    }
}
