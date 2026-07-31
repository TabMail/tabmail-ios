/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization

/// Time-based throttle for progress updates during parallel backfill.
/// Prevents excessive DB writes while keeping the progress bar responsive.
/// Time-based throttle for progress updates during parallel backfill.
/// Prevents excessive DB writes while keeping the progress bar responsive.
private actor ProgressThrottle {
    private var lastUpdate: Date = .distantPast
    private static let intervalSeconds: TimeInterval = 1

    func shouldUpdate() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= Self.intervalSeconds else { return false }
        lastUpdate = now
        return true
    }
}

/// Thread-safe cursor for distributing UID batches to parallel workers.
/// Unlike UIDWalkCursor which generates contiguous ranges, this consumes
/// a pre-computed list of existing UIDs (from UID SEARCH).
private actor UIDListCursor {
    private let uids: [UInt32]
    private var index: Int = 0
    private let batchSize: Int

    init(uids: [UInt32], batchSize: Int) {
        self.uids = uids
        self.batchSize = batchSize
    }

    func nextBatch() -> [UInt32]? {
        guard index < uids.count else { return nil }
        let end = min(index + batchSize, uids.count)
        let batch = Array(uids[index..<end])
        index = end
        return batch
    }
}

/// What one parallel backfill worker reports back to the walk.
///
/// Round 8: this used to be a bare `Bool` (did-work). The walk now also has to
/// know whether ANY worker saw the folder's UIDVALIDITY move under it, because
/// that decides whether this pass's confirmed-range accounting describes the UID
/// space the walk started in — see `SyncEngine.runBackfill`'s epoch handling.
/// Returned by value rather than accumulated in shared state on purpose: a
/// `TaskGroup` result is already the file's established channel for
/// `workerDidWork`, and adding a second one costs no synchronisation.
private struct BackfillWorkerOutcome: Sendable {
    var didWork = false
    var epochDisagreed = false
}

extension SyncEngine {

    #if DEBUG
    /// Test seam: the resumed branch's epoch-bootstrap transaction THROWS once
    /// for each folder id in here, then the id is consumed.
    ///
    /// It exists because the failure it models — a GRDB write failing while the
    /// rest of the pass keeps working, e.g. under background suspension
    /// (ADR-IOS-046) — has no other seam, and the defect it pins is entirely
    /// about how that throw is CLASSIFIED. `bootstrapCrawledFolderUidValidity`
    /// answers with a `false` (refused: the precondition legitimately does not
    /// hold) and with a throw (the write failed), and round 8 treated the second
    /// pass's `false` as if it were success, which is what turned a one-off write
    /// failure into a folder marked complete with no epoch — see the `catch` at
    /// the resumed bootstrap. Modelled as a one-shot set rather than a closure
    /// because the whole point is that the SECOND attempt must behave normally.
    ///
    /// Same shape as `v2final`'s `backfillWalkCheckpointHooksForTesting` in this
    /// function's file at the tag (one-shot, folder-scoped, removed before use).
    static let epochBootstrapWriteFailureIdsForTesting = Mutex<Set<String>>([])

    /// Marker error for the seam above. DEBUG-only; never reachable in Release.
    struct EpochBootstrapWriteFailureForTesting: Error {}

    private static func consumeEpochBootstrapWriteFailureForTesting(folderId: String) -> Bool {
        epochBootstrapWriteFailureIdsForTesting.withLock { $0.remove(folderId) != nil }
    }

    /// Test seam: the FRESH branch's bookkeeping transaction throws for every
    /// folder id in here, and — unlike `epochBootstrapWriteFailureIdsForTesting`
    /// above — the id is **NOT consumed**.
    ///
    /// That difference is the whole point. The one-shot seam models a TRANSIENT
    /// write failure; the defect this one models is a PERSISTENT one (GRDB
    /// suspension, ADR-IOS-046 / `0xdead10cc`; `SQLITE_FULL`; corruption), where
    /// the folder is handed straight back by the loop's fresh re-read and the
    /// identical failing write is retried at network rate. A one-shot seam
    /// cannot express "every attempt fails", so it cannot exercise the bound.
    static let freshCursorWriteFailureIdsForTesting = Mutex<Set<String>>([])

    /// Marker error for the seam above. DEBUG-only; never reachable in Release.
    struct FreshCursorWriteFailureForTesting: Error {}

    private static func freshCursorWriteShouldFailForTesting(folderId: String) -> Bool {
        freshCursorWriteFailureIdsForTesting.withLock { $0.contains(folderId) }
    }

    /// Named suspension points inside `runBackfill`, so a test can interleave a
    /// SECOND `runBackfill` (or a direct DB write) at the exact instant a race
    /// requires. One-shot and folder-scoped: the hook is removed BEFORE it is
    /// awaited, so a second walk reaching the same checkpoint runs straight
    /// through and cannot consume it twice.
    ///
    /// REFERENCE (`v2final`): PORTED shape —
    /// `BackfillWalkCheckpointForTesting` / `backfillWalkCheckpointHooksForTesting`
    /// in the same function's file at the tag, same one-shot/remove-before-await
    /// discipline, same `Mutex`-boxed dictionary. What differs: the reference has
    /// ONE checkpoint (`afterWorkersJoinedBeforeFinalBookkeeping`) and its hook
    /// is `throws` so an injected failure surfaces; these three are
    /// non-throwing, because every one of them exists to let another task RUN,
    /// not to inject a failure — the failures in this file have their own two
    /// seams above.
    enum BackfillWalkCheckpointForTesting: Hashable, Sendable {
        /// After the walk-start SELECT resolved this pass's epoch and UIDNEXT,
        /// BEFORE the `case .fresh` branch's bookkeeping transaction (both the
        /// `initialCursor < 1` completion write and the initial-cursor planting
        /// write are downstream of it).
        case beforeFreshBookkeepingWrite(folderId: String)
        /// After the walk-start gate decided `.refuseEpochMismatch`, BEFORE
        /// `resetEmptyFolderCrawlEpoch` runs — the window in which the decision
        /// this reset acts on can go stale.
        case beforeEmptyFolderCrawlEpochReset(folderId: String)
        /// Inside a worker, after a chunk's headers are fetched and the
        /// post-FETCH epoch check passed, BEFORE `insertBackfillBatch` — the
        /// "already-fetched batch outside SQLite" window.
        case beforeInsertingFetchedChunk(folderId: String)
    }

    static let backfillWalkCheckpointHooksForTesting = Mutex<[
        BackfillWalkCheckpointForTesting: @Sendable () async -> Void
    ]>([:])

    private static func runBackfillWalkCheckpointForTesting(
        _ checkpoint: BackfillWalkCheckpointForTesting
    ) async {
        let hook = backfillWalkCheckpointHooksForTesting.withLock {
            $0.removeValue(forKey: checkpoint)
        }
        if let hook { await hook() }
    }
    #endif

    // MARK: - T1.3 anti-brick: the crawl's epoch bootstrap, BOUND to its UIDs

    /// Bootstrap `Folder.lastKnownUidValidity` from an epoch the CRAWL observed —
    /// and only when that epoch provably describes every local UID in the folder.
    ///
    /// 🚨 **THE COLUMN'S MEANING IS "the epoch the LOCAL UIDs belong to", NOT
    /// "the epoch the server most recently reported".** `AccountManager
    /// .newGestureRefusedForUnknownEpoch` tests only `lastKnownUidValidity == nil`
    /// — it never compares stored against live — so stamping ANY value, right or
    /// wrong, unlocks every gesture on every header in that folder. A header with
    /// no `rfc822MessageId` has `MessageHeader.stableId` fall back to its bare
    /// numeric UID, and `IMAPProvider.resolveUID` treats a numeric id as a LITERAL
    /// UID. Stamp an epoch the local rows do not belong to and the next gesture
    /// mutates whatever message now occupies that number — constraint C3, the one
    /// hard invariant.
    ///
    /// Hence the `localHeaders == 0` precondition, evaluated INSIDE the caller's
    /// write transaction (the TOCTOU rule: a count read before a network round trip
    /// cannot decide a write that happens after it). With no local rows the claim
    /// "every local UID belongs to `observed`" is vacuously true, and it STAYS true
    /// for the rows the crawl then inserts — because the walk refuses to insert any
    /// chunk whose own SELECT reported a different epoch (see `runBackfill`). Every
    /// caller must therefore stamp BEFORE the walk inserts anything; a post-walk
    /// stamp would find the count non-zero from its own inserts and, worse, would
    /// be sampling an epoch nothing bound to those inserts.
    ///
    /// ⚑ R0 — this precondition has **NO REFERENCE in `v2final`** and is a v3
    /// addition. It is not needed there: `v2final` carries the whole ADR-IOS-061
    /// reset reaction (`uidValidityResetPendingAt` quarantine → purge of the rows
    /// belonging to the old epoch → stamp → resync), so a turnover cannot leave
    /// old-epoch rows sitting under a new-epoch stamp. v3 has ported none of that
    /// machinery. Until it does, a folder that ALREADY holds rows of unproven epoch
    /// cannot be stamped by the crawl, and this fails CLOSED — the folder keeps
    /// refusing gestures. That is the sanctioned trade (C6/C3): a wrong stamp is
    /// silent data corruption, a refusal is a silent no-op.
    ///
    /// ⚠ **RETRACTION (round 10) — round 8 wrote "from this build on,
    /// `backfillUidCursor != nil` implies the epoch was already bootstrapped".
    /// That is FALSE, in two independent ways** (NB6), and a future reader could
    /// lean on it:
    ///  - the fresh-cursor transaction plants `backfillUidCursor` whether or not
    ///    the gated stamp beside it fires — this function RETURNS FALSE (it does
    ///    not throw) when the folder already holds headers, and the cursor write
    ///    is not conditioned on its result;
    ///  - for every folder in `syncableFolders`, full sync inserts headers LONG
    ///    before backfill plants its first cursor, so the count is already
    ///    non-zero on the crawl's first visit and this stamp is refused there
    ///    routinely. That is not a brick — T1.2b's `runSyncMessages` bootstrap
    ///    already stamped those folders — but the implication is still false.
    /// What IS true is narrower: a folder this crawl stamps is stamped at the
    /// moment its count is provably zero, and rule 3 (the per-chunk refusal) keeps
    /// that claim true for everything the walk then inserts.
    ///
    /// Folders left half-crawled by an OLDER build keep a nil epoch; no backward
    /// compatibility is required (owner constraint C6) and Smart Reindex
    /// (`SyncEngine.resetCrawlState`) does not recover them either, since it clears
    /// cursors without clearing headers.
    ///
    /// ⚠ **RETRACTION (round 8) — the crawl is NOT the only pass that reaches a
    /// custom non-favourite folder.** Round 7 asserted that, in five places, and it
    /// is false. `syncableFolders` excludes such a folder from full sync, delta
    /// sync and self-heal, but ON-DEMAND NAVIGATION reaches ANY folder:
    /// `InboxView.onAppear` → `InboxViewModel.startSync()` → `performSync()` →
    /// `AccountManager.syncFolders(_:)` (in `AccountManagerFetch.swift`, which
    /// filters on `!folder.path.isEmpty` alone — no role predicate, no favourite
    /// predicate) → `SyncEngine.syncFolderMessages` → `syncMessages` →
    /// `runSyncMessages`, carrying T1.2b's SELECT-sourced bootstrap.
    /// `SyncEngineFullSync.swift` says so itself, three lines under the
    /// `syncableFolders` construction: *"Custom non-favorited folders sync
    /// on-demand when the user navigates to them."*
    ///
    /// So the pre-fix refusal was never permanent — it was bounded by "the user
    /// opens that folder once". It was still a real and INDEFINITE bug, because
    /// backfill makes that folder's mail reachable by account-wide search while the
    /// user may never open the folder itself, which is why this bootstrap exists.
    /// Say "indefinite until the user opens the folder", never "permanent".
    ///
    /// Returns whether the gated UPDATE was issued — for logging only. The UPDATE
    /// itself is still `bootstrapFolderUidValidity`'s, so it also carries
    /// `lastKnownUidValidity IS NULL` in the statement and can never overwrite.
    /// May a crawl walking under `walk` touch a folder whose local rows are
    /// stamped `stored`?
    ///
    /// A DISAGREEMENT means the mailbox was re-created since the folder's rows
    /// were written: every local UID belongs to a numbering that no longer
    /// exists, and every UID the walk is about to fetch belongs to one those rows
    /// know nothing about. Inserting into that folder mixes two numberings under
    /// one stamp, and half the resulting rows resolve a bare-UID gesture against
    /// the wrong message. There is no correct crawl to run here — only a
    /// purge-and-resync, which v3 has not ported (ADR-IOS-061's reaction). So the
    /// crawl declines the folder, which is fail-closed and costs one SELECT per
    /// cycle until that reaction exists.
    ///
    /// Either side UNKNOWN admits: a nil `stored` is the ordinary first-crawl
    /// case this whole item exists to serve, and a nil `walk` is a server that
    /// does not report UIDVALIDITY on SELECT at all — refusing every crawl for
    /// such an account would be a far larger change than any epoch guard needs.
    ///
    /// REFERENCE (`v2final`): the same observed-vs-stored comparison, expressed
    /// as `uidValidityWalkWriteAllowed` / `uidValidityWriteAllowed`, re-read
    /// inside each bookkeeping write's own transaction and combined there with a
    /// `uidValidityResetPendingAt` quarantine flag v3 does not have. The
    /// comparison ports; the quarantine does not.
    nonisolated static func crawlEpochAgrees(stored: UInt32?, walk: UInt32?) -> Bool {
        guard let stored, let walk else { return true }
        return stored == walk
    }

    /// What `runBackfill` must do with a folder, decided at walk start from the
    /// epoch its rows are stamped with and the epoch this pass observed.
    ///
    /// The three outcomes are kept apart because they have three different
    /// recoveries, and round 8 collapsed two of them into `crawlEpochAgrees`'
    /// single Bool — which is how BOTH of round 9's first two blockers happened.
    enum CrawlEpochGate: Equatable, Sendable {
        /// The walk may proceed under `walk`.
        case proceed
        /// This pass never obtained an epoch, but the folder HAS one — so the
        /// server does report UIDVALIDITY and this pass simply failed to see it.
        /// Every downstream check would degrade to a no-op, so the walk must not
        /// run at all.
        case refuseUnobservedEpoch
        /// Both epochs are known and they differ: the mailbox was re-created
        /// since the folder's rows were written.
        case refuseEpochMismatch
    }

    /// 🚨 **A nil `walk` may only be admitted when `stored` is nil too.**
    ///
    /// Round 8 admitted every nil (`crawlEpochAgrees` returns true when either
    /// side is unknown) and justified it from ONE cause: *"a server that never
    /// reports UIDVALIDITY on SELECT at all — refusing every crawl for such an
    /// account would be a far larger change than any epoch guard needs."* But the
    /// resumed branch's forced fresh observation is wrapped in `try?`, so a
    /// TRANSIENT connect/SELECT failure produces the identical nil — and
    /// `v2final`'s own comment names both causes in one breath (*"the
    /// resumed-branch fresh observation above failed, **or** a broken server never
    /// reports UIDVALIDITY at all"*) and refuses in BOTH
    /// (`guard observedEpoch != nil else { … continue }`, before its final
    /// cursor/complete writes).
    ///
    /// With a nil `walk` the walk's `expectedEpoch` is nil, so the post-SEARCH and
    /// post-FETCH checks return true unconditionally and a later chunk that
    /// succeeds under a NEW epoch inserts its headers into a folder stamped with
    /// the old one. Those rows then hold bare UIDs of a numbering the stamp does
    /// not describe, and the stamp being non-nil keeps them ADMITTED by
    /// `AccountManager.newGestureRefusedForUnknownEpoch` — a gesture resolves an
    /// E1 UID against E2 and mutates the wrong message (C3).
    ///
    /// ⚠ **RETRACTION (round 12) — the argument this gate USED to rest on was
    /// false, and it was the justification for the safety decision.** Round 11
    /// wrote: *"a folder with a non-nil `stored` proves the server reports
    /// UIDVALIDITY"*, and inferred from that that refusing on
    /// `walk == nil && stored != nil` only ever catches a transient failure. The
    /// inference does not hold, because **the two epochs come from independent
    /// channels**: `IMAPProvider.fetchFolders` sources `FolderInfo.uidValidity`
    /// from `IMAPServer.mailboxStatus` — an IMAP **STATUS** command — and
    /// `SyncEngine.fullSync`'s folder-list upsert feeds THAT into
    /// `Folder.lastKnownUidValidity`, while `walk` comes from **SELECT**
    /// (`IMAPProvider.getUidNextWithEpoch` → `selectMailboxTracked`). A stamp
    /// therefore proves the server reports UIDVALIDITY *somewhere*, not that
    /// SELECT does. Nor is `walk == nil` only "the call threw": a SELECT that
    /// SUCCEEDS and reports `UIDVALIDITY 0` normalises to nil at
    /// `IMAPProvider.selectMailboxTracked`'s `observed != 0 ? observed : nil`.
    ///
    /// **The refusal is still correct — on a different and much stronger
    /// argument.** RFC 3501 §6.3.1 (SELECT) lists UIDVALIDITY among the
    /// *REQUIRED OK untagged responses* — UNSEEN, PERMANENTFLAGS, UIDNEXT,
    /// UIDVALIDITY — and states that if it is missing, the server does not
    /// support unique identifiers. RFC 9051 §6.3.2 carries the same requirement.
    /// So a SELECT that omits UIDVALIDITY is a server declaring it does not
    /// support UIDs at all, which is an account this app cannot serve: every
    /// durable action it takes is UID-addressed. Refusing to crawl such a folder
    /// is not a heuristic about transience — it is refusing to guess a UID space
    /// on a server that just said it has none.
    ///
    /// The epochless-server account round 8 protected is untouched: there
    /// `stored` is nil forever (no STATUS epoch either), the gate still says
    /// `.proceed`, and nothing is stamped — `IOS-EPOCH-001`'s accepted window.
    ///
    /// **DISCLOSURE — this refusal is PERMANENT, not self-healing, if the
    /// server never reports again.** `.refuseUnobservedEpoch` mutates nothing,
    /// so the state `stored = E, walk = nil` is re-created on every later call: a
    /// per-call decline container with a DURABLE re-entry condition, which is the
    /// same "transient container + durable re-entry ⇒ permanent refusal" shape
    /// `resetEmptyFolderCrawlEpoch` exists to break. Round 11 disclosed it as
    /// "INDEFINITE … one SELECT that reports again clears it"; that is only true
    /// while the server DOES report again. Stated plainly: while the server keeps
    /// omitting UIDVALIDITY from SELECT for this folder, the crawl re-declines
    /// every cycle forever (cost: one SELECT per cycle) and that folder's
    /// un-crawled mail stays un-indexed. This is fail-closed and C6-legal, and it
    /// is deliberately NOT given a bounded recovery: the only server that reaches
    /// it is nonconforming in a way that makes every UID-addressed action unsafe.
    ///
    /// REFERENCE (`v2final`): PORTED — same refusal, same fail-closed direction,
    /// expressed as the `guard observedEpoch != nil` before its bookkeeping
    /// writes. What does not transfer is the SHAPE: the reference refuses at the
    /// END of the walk (its per-chunk `insertBackfillBatch` guard already covers
    /// the inserts, so only its own bookkeeping needs protecting), whereas v3's
    /// per-chunk check is driven by `expectedEpoch` itself and so must refuse
    /// BEFORE the walk runs.
    nonisolated static func crawlEpochGate(stored: UInt32?, walk: UInt32?) -> CrawlEpochGate {
        guard let walk else {
            return stored == nil ? .proceed : .refuseUnobservedEpoch
        }
        return crawlEpochAgrees(stored: stored, walk: walk) ? .proceed : .refuseEpochMismatch
    }

    /// A crawl pass's premise about a folder's `lastKnownUidValidity`, wrapped so
    /// that "this caller holds NO premise, do not guard" (a nil
    /// `CrawlEpochPremise?`) stays distinguishable from "the premise is that the
    /// folder is UNSTAMPED" (`CrawlEpochPremise(nil)`).
    ///
    /// The distinction is load-bearing, not decorative: the unstamped folder is
    /// precisely the one the guard matters most for. A folder holding rows of
    /// unproven epoch is refused by `bootstrapCrawledFolderUidValidity`, so its
    /// premise IS nil for the whole pass, and a sibling stamping it mid-walk is
    /// the C3 hazard `insertBackfillBatch`'s guard exists to catch. Passing a
    /// bare `UInt32?` and reading nil as "no guard" would drop the guard on
    /// exactly that folder.
    struct CrawlEpochPremise: Sendable, Equatable {
        let epoch: UInt32?
        init(_ epoch: UInt32?) { self.epoch = epoch }
    }

    /// May a bookkeeping write from this pass land on this folder, judged against
    /// the folder row as it stands INSIDE the caller's own write transaction?
    ///
    /// NB4: `runBackfill` reads the folder row ONCE per iteration, BEFORE the
    /// walk-start SELECT round trip, and every bookkeeping write it then makes
    /// happens after it — some of them minutes later, from a parallel worker.
    /// Deciding those writes on that pre-network snapshot is the codebase's own
    /// pending-ops-inside-txn rule violated. Re-reading here closes it.
    ///
    /// **This is a COMPARE-AND-SET on the folder's stamp, not a comparison
    /// against the walk's epoch — and round 12 changed it to that.**
    /// `premiseEpoch` is the value of `Folder.lastKnownUidValidity` this pass's
    /// bookkeeping is accounted under: the row's value at walk start, advanced to
    /// the walk's own epoch if and only if THIS pass's own
    /// `bootstrapCrawledFolderUidValidity` stamped it (see `runBackfill`). The
    /// write is authorised only while the row still holds exactly that value.
    ///
    /// ⚠ **RETRACTION (round 12, NB3) — the premise this function used to state
    /// is stale.** It said: *"The column is monotone (bootstrap-only for values),
    /// so the reachable skew is 'snapshot nil, DB now stamped E'."* That stopped
    /// being true when `resetEmptyFolderCrawlEpoch` landed: it CLEARS the column,
    /// so **value → nil is reachable too**, and the old body
    /// (`crawlEpochAgrees(stored: nil, walk: E)`) ADMITS a nil — the fail-OPEN
    /// direction, on a folder whose identity another pass has just torn down.
    /// The complete writer set is enumerated on
    /// `SyncEngine.bootstrapFolderUidValidity`: three bootstrap-only VALUE
    /// writers (nil → E) plus that one CLEARER (E → nil). A CAS refuses in both
    /// directions and needs no case analysis at all, which is why it replaced the
    /// comparison rather than being added beside it.
    ///
    /// Both refusals are TRANSIENT: a skew means some other pass re-derived this
    /// folder's identity while this one was on the network, so this pass's
    /// cursor/completeness describe a premise that no longer holds, and the NEXT
    /// call reads the new premise and proceeds under it. The value writers are
    /// bootstrap-only, so nil → E can happen at most once per folder.
    ///
    /// 🚨 **ROUND 13, BLOCKER 1 — A MISSING ROW IS NOT AN UNSTAMPED ROW.** The
    /// body used to be one optional chain,
    /// `knownUidValidity(try Folder.fetchOne(db, key: folderId)?.lastKnownUidValidity)`,
    /// which collapses TWO states into one `stored == nil`: *the folder row is
    /// GONE* (the account was removed, the folder was deleted, a folder-list
    /// rebuild is mid-flight) and *the row exists and is genuinely UNSTAMPED*. A
    /// caller holding the legitimate unstamped premise passes `premiseEpoch ==
    /// nil`, so `nil == nil` ADMITTED every write onto a folder that no longer
    /// exists — the fail-OPEN direction, decided from the absence of the very row
    /// the CAS exists to compare against. The `guard let` below splits them: a
    /// missing row REFUSES, an unstamped row still ADMITS a nil premise. That
    /// second half is load-bearing and must not be regressed — the unstamped
    /// folder is exactly the one `CrawlEpochPremise` was introduced to keep
    /// guarded (see its doc), so refusing it would silently un-crawl every folder
    /// holding rows of unproven epoch.
    ///
    /// The in-repo model is this function's own sibling:
    /// `resetEmptyFolderCrawlEpoch` already writes
    /// `guard let current = try Folder.fetchOne(db, key: folderId), …`.
    ///
    /// ⚠ **NOTHING ELSE CATCHES THIS — the database does not.** An earlier draft
    /// of this note claimed SQLite would abort the header insert anyway, because
    /// `v1_createTables` declares `messageHeader.folderId` with
    /// `.references("folder", onDelete: .cascade)`. That is FALSE for any live
    /// database: migration **`v2_dropMessageHeaderFolderFK`** rebuilds the table
    /// with `folderId` as a plain column and no foreign key at all (its own
    /// comment says so). Measured, not reasoned: with the guard inverted, the
    /// premised insert returned `.landed(inserted: 1, …)` and a real
    /// `messageHeader` row was written naming a folder id with no row behind it.
    /// So pre-fix this wrote an ORPHAN header AND told the walk the range had
    /// landed, which the walk reads as licence to `confirmRange` — the crawl
    /// advances past mail on the strength of a row nothing owns.
    ///
    /// What the new refusal costs, stated as the mirror-image check demands: for
    /// a folder whose row is genuinely gone the refusal is PERMANENT, and that is
    /// the correct end state — there is no folder left to describe the rows. For
    /// a folder that is deleted and re-created (`Folder.id` is `accountId:path`,
    /// so a rebuild reuses the id) the refusal is TRANSIENT: the next pass reads
    /// the new row and proceeds under it.
    ///
    /// ⚑ R0 — **DELIBERATE CORRECTION OF THE REFERENCE, NOT A PORT.**
    /// `v2final`'s `uidValidityWalkWriteAllowed` has the identical collapse
    /// (`let folder = try Folder.fetchOne(db, key: folderId)`, then
    /// `folder?.lastKnownUidValidity.flatMap { … }`), so a missing row there
    /// yields `resetPending == false` and `storedEpoch == nil`, and
    /// `uidValidityWriteAllowed` — whose epoch term fails OPEN on either side nil
    /// — admits. The reference shares the defect; it is fixed here anyway.
    ///
    /// REFERENCE (`v2final`): PORTED from `uidValidityWalkWriteAllowed(db:folderId:
    /// observedEpoch:)` in the same function's file at the tag — same in-txn
    /// `Folder.fetchOne`, same use on every cursor/completeness write the walk
    /// makes. TWO deviations, both deliberate: (1) its `uidValidityResetPendingAt`
    /// quarantine term does not transfer — v3 has no such column (T4.S6); (2) the
    /// reference COMPARES (`observedEpoch` vs `storedEpoch`) where this CASes,
    /// because the reference has no clearer — its `lastKnownUidValidity` is
    /// advanced by the reset reaction's purge-then-stamp, so "the row's stamp
    /// changed under me" is a state its quarantine flag already refuses. v3 has
    /// the clearer and not the flag, so the CAS is the ⚑ INVENTED half.
    nonisolated static func crawlWalkWriteAllowed(
        _ db: Database, folderId: String, premiseEpoch: UInt32?
    ) throws -> Bool {
        // No row ⇒ nothing to compare the premise against ⇒ refuse. This is NOT
        // the same as an unstamped row, which is compared below and legitimately
        // matches a nil premise (round 13 blocker 1 — see above).
        guard let folder = try Folder.fetchOne(db, key: folderId) else { return false }
        let stored = knownUidValidity(folder.lastKnownUidValidity)
            .flatMap { UInt32(exactly: $0) }
        return stored == premiseEpoch
    }

    /// Drop the crawl state of a folder that holds ZERO local headers, so the next
    /// iteration re-derives it from the live mailbox. Returns whether it fired.
    ///
    /// 🚨 **THE BRICK THIS EXISTS TO BREAK** (round 9 blocker 1). A fresh EMPTY
    /// folder is stamped E1 by the fresh-cursor transaction — correctly, its count
    /// is zero. The mailbox then turns over to E2 before the walk inserts anything,
    /// the per-chunk guard discards the E2 batch, and the pass skips its final
    /// bookkeeping. The folder is now: empty, incomplete, cursor-bearing, durably
    /// stamped E1. On EVERY later `runBackfill` the fresh SELECT reports E2, the
    /// walk-start gate returns `.refuseEpochMismatch`, and the folder is declined
    /// again. Every epoch value-writer is bootstrap-only and `resetCrawlState`
    /// clears cursors without clearing the stamp, so a restart does not help and a
    /// Smart Reindex does not either. **The decline SET is genuinely transient
    /// (function-local, destroyed when the call returns); the REFUSAL is permanent
    /// because a durable condition re-inserts the folder on every call. A
    /// transient container plus a durable re-entry condition is a permanent
    /// refusal — that is the lesson, and this fix must not re-make it.**
    ///
    /// Why this is NOT the deferred T4.S6 carve-out: that one covers a folder
    /// holding ROWS whose epoch nothing can prove, where advancing the stamp would
    /// assert something false about real data. Here the folder holds ZERO rows.
    /// There is nothing to purge, nothing to resync, and no reaction needed — the
    /// stamp describes an empty set, so replacing it asserts nothing at all. The
    /// count is taken INSIDE the caller's transaction for the same TOCTOU reason
    /// `bootstrapCrawledFolderUidValidity` takes its own there.
    ///
    /// **The cursor goes too, and that is not incidental.** `backfillUidCursor` is
    /// a position in a UID space; under the new epoch the numbering restarted
    /// beneath it. Re-planting it would walk `[1…staleCursor]` in the new mailbox
    /// and never look above `staleCursor` — a silent completeness gap, which is
    /// exactly the failure `v2final`'s §5.5 comment warns about for a re-planted
    /// old-epoch cursor. Clearing it sends the next iteration through the
    /// fresh-cursor branch, which re-derives the cursor from the live `UIDNEXT`.
    ///
    /// **This writes only NULLs.** The stamping is still
    /// `bootstrapFolderUidValidity`'s, on the next iteration, under its own
    /// `lastKnownUidValidity IS NULL` predicate and its own count gate — so the
    /// set of paths that write a VALUE into `Folder.lastKnownUidValidity` stays at
    /// THREE (see that function's enumeration). A fourth path that wrote a value
    /// would have to be added there; this one is enumerated there as a CLEARER.
    ///
    /// ⚑ R0 — **NO REFERENCE in `v2final`**: it cannot have one. There a turnover
    /// raises `uidValidityResetPendingAt`, and the reaction purges the old epoch's
    /// rows and stamps the new one for folders EMPTY AND NON-EMPTY ALIKE, so the
    /// empty-folder case is not distinguished and cannot brick. v3 has no
    /// reaction, so the empty case is the one the crawl can still discharge on its
    /// own, and it is discharged here. The non-empty case stays refused (T4.S6).
    ///
    /// 🚨 **`expectedStoredEpoch` IS THE CAS, AND IT IS LOAD-BEARING** (round 12,
    /// blocker B). The decision to reset is made at the walk-start gate, which is
    /// itself decided from a folder-row snapshot taken BEFORE a network round
    /// trip. Two `runBackfill` calls for the same account overlap for real — the
    /// persistent worker `SyncEngine.startBackfill` launches (reaching
    /// `runBackfill` in `SyncEngineBackfill.swift`) and the BGProcessing pass
    /// `SyncScheduler` drives through `AccountManager.runBackfill` →
    /// `SyncEngine.performBackfill` — and `SyncEngine` is an actor, so both
    /// suspend and interleave at every `await`. Without this predicate the helper
    /// checked only `headerCount == 0` and then updated BY FOLDER ID, so a walk
    /// acting on an ALREADY-STALE mismatch could clear a stamp and cursor that a
    /// sibling walk had, in the meantime, legitimately re-derived from the live
    /// mailbox. The sibling's already-fetched batch — held outside SQLite, so
    /// invisible to the header count — then landed under a nil stamp, and its
    /// final bookkeeping read that nil as agreement and marked the now-populated
    /// folder COMPLETE. Durable end state: rows present, `lastKnownUidValidity`
    /// nil, `backfillComplete` true. Completion excludes it from every later
    /// crawl cycle, and Smart Reindex (`SyncEngine.resetCrawlState`) reopens the
    /// crawl but cannot re-stamp, because the header-count gate below now
    /// refuses. Only an on-open sync could heal it; the crawl never could.
    ///
    /// The predicate re-validates, inside the write transaction, the state the
    /// reset decision was premised on: the folder is still the crawl's
    /// responsibility (`backfillComplete == false`) and still carries the stamp
    /// the gate saw disagree. `walkEpoch` needs no re-validation — it is a
    /// constant of the calling pass — so "the stamp is unchanged" is exactly
    /// "the mismatch that motivated this reset still holds". A refusal is
    /// TRANSIENT: it means a sibling already did the re-derivation this call
    /// wanted, and the next call reads the result.
    ///
    /// ⚑ R0 — **NO REFERENCE for the predicate**, because there is no reference
    /// for the function (see above). The SHAPE is the reference's own, though:
    /// re-read the row inside the writer's transaction and judge against it, as
    /// `v2final`'s `uidValidityWalkWriteAllowed` does for every bookkeeping write
    /// the walk makes. Serialising the two walks per account was considered and
    /// rejected: `v2final` does not serialise them either (its folder loop is
    /// identical and it carries no per-account walk lock), and a lock would
    /// convert a one-cycle skew into a stalled BGProcessing budget.
    nonisolated static func resetEmptyFolderCrawlEpoch(
        _ db: Database, folderId: String, expectedStoredEpoch: UInt32
    ) throws -> Bool {
        let localHeaders = try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        guard localHeaders == 0 else { return false }
        guard let current = try Folder.fetchOne(db, key: folderId),
              current.backfillComplete == false,
              knownUidValidity(current.lastKnownUidValidity).flatMap({ UInt32(exactly: $0) })
                  == expectedStoredEpoch
        else { return false }
        let changed = try Folder
            .filter(Column("id") == folderId)
            .updateAll(db,
                Column("lastKnownUidValidity").set(to: nil as Int?),
                Column("backfillUidCursor").set(to: nil as Int?)
            )
        return changed > 0
    }

    nonisolated static func bootstrapCrawledFolderUidValidity(
        _ db: Database, folderId: String, observed: UInt32?
    ) throws -> Bool {
        guard let observed, let epoch = knownUidValidity(Int(observed)) else { return false }
        let localHeaders = try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        guard localHeaders == 0 else { return false }
        try Self.bootstrapFolderUidValidity(db, folderId: folderId, observed: epoch)
        return true
    }

    // MARK: - Unified Backfill Walk

    /// Crawl folders for this account, inserting headers AND indexing bodies in the same walk.
    /// Gmail/Exchange: single API call per message (format=full) — headers + body together.
    /// IMAP: header fetch then body fetch in the same iteration (protocol limitation).
    /// After walking all folders, runs a cleanup pass for any remaining empty bodies.
    /// Returns true if any work was done.
    func runBackfill(account: Account, deadline: Date? = nil) async -> Bool {
        var didWork = false
        let fastSync = await getIsFastSync()
        let isPastDeadline: () -> Bool = {
            guard let deadline else { return false }
            return Date() >= deadline
        }


        let incompleteFolders: [Folder]
        do {
            incompleteFolders = try await dbPool.read { db in
                try Folder.filter(
                    Column("accountId") == account.id &&
                    Column("backfillComplete") == false &&
                    Column("path") != ""
                ).fetchAll(db)
            }.sorted { a, b in
                func priority(_ f: Folder) -> Int {
                    switch f.role {
                    case .inbox: return 0
                    case .sent: return 1
                    case .archive: return 2
                    case .drafts: return 3
                    case .trash: return 4
                    case .spam: return 5
                    case .custom: return f.isFavorite ? 6 : 7
                    }
                }
                return priority(a) < priority(b)
            }
        } catch {
            print("[Backfill] Failed to fetch folders: \(error)")
            BackgroundSyncLogger.logError("Failed to fetch folders: \(error)", source: "backfill:\(account.emailAddress)")
            return false
        }

        guard !incompleteFolders.isEmpty else { return false }
        guard let provider = providers[account.id] else { return false }
        guard let workQueue = workQueues[account.id] else { return false }

        print("[Backfill] Starting for \(account.emailAddress): \(incompleteFolders.count) folders to backfill")
        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress) walk: \(incompleteFolders.count) incomplete folders")

        var consecutiveConnectionFailures = 0
        var connectionBackoffSeconds: TimeInterval = 5  // Exponential backoff: 5, 10, 20, 40, 60 (max)
        var previousFolderId: String?  // Skip interFolderDelay when continuing same folder
        // Chunk sizes are managed per-folder by UIDWalkCursor (with recovery).
        // No cross-folder contamination — each folder gets a fresh cursor.

        // T1.3 (round 8): folders this CALL has declined on UIDVALIDITY grounds —
        // the walk observed an epoch the folder's rows do not belong to, or the
        // mailbox moved under an in-flight walk. Neither case writes
        // `backfillComplete`, so without this set the loop below re-reads the
        // folder as "still incomplete" and immediately walks it again — under the
        // NEW epoch, inserting exactly the mixed-epoch population the refusal was
        // for. (`v2final` needs no such set: its refusals persist through the
        // `uidValidityResetPendingAt` quarantine column, which v3 has not ported.)
        var epochDeclinedFolderIds = Set<String>()
        // Folders whose stale epoch+cursor this CALL already dropped because they
        // held no headers (`resetEmptyFolderCrawlEpoch`). Bounds that recovery to
        // ONE attempt per folder per call: a mailbox turning over again between
        // the reset and the next iteration's SELECT would otherwise put this loop
        // into a network-rate spin, which is the very NB3 shape the round-9 audit
        // named elsewhere in this function. A second mismatch declines instead.
        var epochReadoptedFolderIds = Set<String>()

        await updateBackfillProgressForAccount(account)

        // ── Backward crawl — one folder at a time, most recent first ──
        // Each iteration picks the incomplete folder whose oldestSyncedDate is most
        // recent (shallowest crawl depth), fetches older messages via UID/page-token walk.
        // IMAP: walks from UIDNEXT-1 backward to UID 1.
        // Gmail/Exchange: page-token walk from newest to oldest.
        while true {
            guard !Task.isCancelled else { return didWork }
            guard !isPastDeadline() else { break }

            // Fresh DB read each iteration so we see folders completed by Step 1 or previous iterations
            let remaining: [Folder]
            do {
                remaining = try await dbPool.read { db in
                    try Folder.filter(
                        Column("accountId") == account.id &&
                        Column("backfillComplete") == false &&
                        Column("path") != ""
                    ).fetchAll(db)
                }
            } catch { break }
            guard !remaining.isEmpty else { break }

            // Pick folder by role priority (inbox→sent→archive→…→custom),
            // then most recent oldestSyncedDate within the same tier.
            func crawlPriority(_ f: Folder) -> Int {
                switch f.role {
                case .inbox: return 0
                case .sent: return 1
                case .archive: return 2
                case .drafts: return 3
                case .trash: return 4
                case .spam: return 5
                case .custom: return f.isFavorite ? 6 : 7
                }
            }
            let isExpensiveNetwork = NetworkMonitor.checkExpensive()
            let folder = remaining
                .filter { f in
                    if epochDeclinedFolderIds.contains(f.id) { return false }
                    if !fastSync && isExpensiveNetwork && !primaryRoles.contains(f.role) { return false }
                    if StorageEstimator.isOverBudget() { return false }
                    return true
                }
                .sorted { a, b in
                    let pa = crawlPriority(a), pb = crawlPriority(b)
                    if pa != pb { return pa < pb }
                    return (a.oldestSyncedDate ?? .distantFuture) > (b.oldestSyncedDate ?? .distantFuture)
                }
                .first

            guard let folder else {
                // All remaining folders are gated — done for this cycle
                break
            }

            let profile = await getBackfillProfile()
            let limit = profile.backfillChunkSize
            do {
                var headers: [MessageHeaderInfo] = []
                var isLastPage = false  // Gmail/Exchange: true when page-token walk has no more pages
                var insertedCount = 0

                if let imapProvider = provider as? IMAPProvider {
                    // IMAP: parallel UID walk with SEARCH-before-FETCH optimization.
                    // Same chunk structure as before (UIDWalkCursor, parallel workers),
                    // but each chunk does UID SEARCH first → if empty, skip FETCH entirely.
                    // For sparse folders (INBOX: 69k UIDs, 6 msgs) this skips ~99% of FETCHes.
                    // For dense folders, the extra SEARCH per chunk is ~3.5KB — negligible.

                    // Where this pass starts, kept apart from the branch that
                    // ACTS on it so the epoch gate below runs exactly once for
                    // both. Round 8 duplicated that gate in the two branches and
                    // the two copies then diverged in what they refused; one
                    // decision site is the fix for that class, not a tidy-up.
                    enum WalkStart {
                        case resumed(cursor: Int)
                        case fresh(uidNext: Int)
                    }
                    // T1.3 — THE WALK'S OWN EPOCH, captured ONCE here and never
                    // re-read live afterwards. Two things depend on it: the gated
                    // bootstrap below (the anti-brick), and every worker's
                    // per-chunk agreement check (the C3 guard). A live re-read at
                    // the END of the walk is exactly the round-7 blocker: by then
                    // the shared per-folder-path mirror can describe a turnover
                    // that happened mid-crawl, and stamping THAT value asserts it
                    // of UIDs the walk inserted under the old numbering.
                    //
                    // Round 10: it comes back FROM the SELECT that produced
                    // `uidNext` (`getUidNextWithEpoch`), not from a separate read
                    // of `lastObservedUidValidity`. The mirror has competing
                    // writers — the walk's own per-chunk SELECTs, and through
                    // `fetchMessageHeaders` also self-heal's and deep backfill's —
                    // and this value is one the walk WRITES, so it must be bound
                    // to its own observation rather than sampled from a shared box.
                    //
                    // REFERENCE (`v2final`): `walkEpoch` in the same function, same
                    // two branches, same rationale (ADR-IOS-061 item C / R4-2) —
                    // including the forced fresh observation on the RESUMED branch,
                    // where the pinned connection may already exist from an earlier
                    // pass and the mirror is therefore cold or stale. The BINDING
                    // is a v3 addition (⚑ NO REFERENCE): the reference samples the
                    // mirror, which it can afford because its own three backfill
                    // SELECTs are the only writers that matter there and its final
                    // consumer is a quarantine-aware comparison.
                    let walkEpoch: UInt32?
                    let walkStart: WalkStart
                    // Whether the walk-start observation ROUND TRIP failed, as
                    // opposed to succeeding and reporting no UIDVALIDITY. The two
                    // are indistinguishable in `walkEpoch` and have different
                    // prognoses, so they are logged apart — see `crawlEpochGate`.
                    var walkStartObservationFailed = false
                    // The epoch the folder's EXISTING rows belong to. `walkEpoch`
                    // must agree with it or the walk is about to mix two
                    // numberings under one stamp — see `crawlEpochGate`.
                    let storedEpoch = Self.knownUidValidity(folder.lastKnownUidValidity)
                        .flatMap { UInt32(exactly: $0) }
                    if let existing = folder.backfillUidCursor {
                        // Force one fresh observation. The pinned connection's own
                        // creation SELECT may have happened in an earlier pass (or
                        // an earlier folder's iteration), so reading the mirror
                        // bare here can hand back an epoch that describes neither
                        // this pass nor this moment.
                        let observation = try? await workQueue.execute(priority: .headerFetch) {
                            try await imapProvider.getUidNextWithEpoch(folder: folder.path)
                        }
                        walkStartObservationFailed = observation == nil
                        walkEpoch = observation?.observedEpoch
                        walkStart = .resumed(cursor: existing)
                    } else {
                        let observation = try await workQueue.execute(priority: .headerFetch) {
                            try await imapProvider.getUidNextWithEpoch(folder: folder.path)
                        }
                        walkEpoch = observation.observedEpoch
                        walkStart = .fresh(uidNext: observation.uidNext)
                    }

                    // ── THE WALK-START EPOCH GATE ── one site, three outcomes.
                    switch Self.crawlEpochGate(stored: storedEpoch, walk: walkEpoch) {
                    case .proceed:
                        break
                    case .refuseUnobservedEpoch:
                        // The folder HAS an epoch, so the server reports one and
                        // this pass just did not see it. Running the walk anyway
                        // would leave `expectedEpoch` nil, which turns BOTH
                        // per-chunk checks into unconditional `true` and lets a
                        // later chunk succeeding under a NEW epoch insert its
                        // headers under the OLD stamp — bare UIDs of a numbering
                        // the stamp does not describe, still ADMITTED for gestures
                        // because the stamp is non-nil (C3).
                        epochDeclinedFolderIds.insert(folder.id)
                        if DebugModeManager.isLoggingEnabled() {
                            let cause = walkStartObservationFailed
                                ? "the walk-start SELECT failed"
                                : "the server reported no UIDVALIDITY on this SELECT"
                            print("[Backfill] \(folder.name) declined: rows are stamped UIDVALIDITY \(String(describing: storedEpoch)) but this pass observed none — \(cause); retry next cycle")
                        }
                        continue
                    case .refuseEpochMismatch:
                        // The mailbox was re-created since this folder's rows were
                        // written. If it holds NO rows, the stamp describes an
                        // empty set and may simply be dropped so the next
                        // iteration re-derives everything from the live mailbox
                        // (round 9 blocker 1 — otherwise this refusal is permanent,
                        // because the durable stamp re-enters the folder into the
                        // decline set on every later call). If it holds rows,
                        // nothing here can prove their epoch and the folder stays
                        // refused until the T4.S6 reset reaction exists.
                        //
                        // ONCE per folder per call: a mailbox turning over between
                        // the reset and the next iteration's SELECT would otherwise
                        // spin this loop at network rate (the NB3 shape).
                        var readopted = false
                        if !epochReadoptedFolderIds.contains(folder.id), let expectedStored = storedEpoch {
                            let folderId = folder.id
                            #if DEBUG
                            await Self.runBackfillWalkCheckpointForTesting(
                                .beforeEmptyFolderCrawlEpochReset(folderId: folderId))
                            #endif
                            // The CAS lives INSIDE the write txn — see
                            // `resetEmptyFolderCrawlEpoch`. `expectedStored` is the
                            // stamp this gate saw disagree; a sibling walk that has
                            // since re-derived the folder's identity moves it, and
                            // this stale decision must then NOT fire.
                            readopted = ((try? await AppDatabase.backgroundPool.write { db in
                                try Self.resetEmptyFolderCrawlEpoch(
                                    db, folderId: folderId, expectedStoredEpoch: expectedStored)
                            }) ?? false)
                        }
                        if readopted {
                            epochReadoptedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name) holds no headers — dropping its stale UIDVALIDITY \(String(describing: storedEpoch)) and cursor, re-crawling under \(String(describing: walkEpoch))")
                            }
                        } else {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name) declined: rows belong to UIDVALIDITY \(String(describing: storedEpoch)), server is at \(String(describing: walkEpoch))")
                            }
                        }
                        continue
                    }

                    // THE PREMISE every bookkeeping write this pass makes is
                    // accounted under: the value of `Folder.lastKnownUidValidity`
                    // this pass's cursor/completeness describe. It starts as the
                    // walk-start snapshot and advances to `walkEpoch` if and only
                    // if THIS pass's own bootstrap stamped the folder — at which
                    // point the row legitimately holds `walkEpoch` and every later
                    // write of this pass must be judged against THAT.
                    // `crawlWalkWriteAllowed` CASes the row against it inside each
                    // write's own transaction (NB3/NB4).
                    var premiseEpoch = storedEpoch

                    // Initialize cursor (from DB or UIDNEXT)
                    let cursorValue: Int
                    switch walkStart {
                    case .resumed(let existing):
                        cursorValue = existing
                        if walkEpoch != nil {
                            let folderId = folder.id
                            let observed = walkEpoch
                            do {
                                let stamped = try await AppDatabase.backgroundPool.write { db in
                                    #if DEBUG
                                    if Self.consumeEpochBootstrapWriteFailureForTesting(folderId: folderId) {
                                        throw EpochBootstrapWriteFailureForTesting()
                                    }
                                    #endif
                                    return try Self.bootstrapCrawledFolderUidValidity(
                                        db, folderId: folderId, observed: observed)
                                }
                                if stamped {
                                    // This pass just moved the row nil → walkEpoch,
                                    // so that is the premise its later writes are
                                    // accounted under, not the nil snapshot.
                                    premiseEpoch = walkEpoch
                                    if DebugModeManager.isLoggingEnabled() {
                                        print("[Backfill] \(folder.name) epoch bootstrapped from resumed walk")
                                    }
                                }
                            } catch {
                                // 🚨 A THROW AND A `false` MEAN DIFFERENT THINGS,
                                // and round 8 conflated them. `false` is a REFUSAL
                                // — the precondition legitimately does not hold
                                // (the folder already holds headers), the common
                                // case, and the walk must carry on. A throw is a
                                // WRITE FAILURE, and the only sound response is to
                                // stop before this pass inserts anything: round 8
                                // instead continued the walk, inserted headers, and
                                // merely withheld `backfillComplete` "so this pass
                                // is retried" — but the retry then found the header
                                // count NON-ZERO, so the bootstrap returned `false`
                                // rather than throwing, `false` was read as success,
                                // and the folder was marked complete with a NIL
                                // stamp. Completion excludes it from every later
                                // pass and Smart Reindex retains the headers, so the
                                // count gate keeps refusing: the claimed retry could
                                // never succeed. Declining here leaves the folder
                                // exactly as this pass found it, so the next call's
                                // retry meets the same preconditions — transient.
                                epochDeclinedFolderIds.insert(folder.id)
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[Backfill] \(folder.name) epoch bootstrap write failed: \(error) — declining this folder before the walk inserts anything, retry next cycle")
                                }
                                continue
                            }
                        }
                    case .fresh(let uidNext):
                        let folderId = folder.id
                        let initialCursor = uidNext - 1
                        // The premise the two writes below are judged against.
                        // Captured here rather than read inside the closures so it
                        // is unambiguously the value the gate above proceeded on.
                        let writePremise = premiseEpoch
                        #if DEBUG
                        await Self.runBackfillWalkCheckpointForTesting(
                            .beforeFreshBookkeepingWrite(folderId: folderId))
                        #endif
                        if initialCursor < 1 {
                            // NB3 (round 8): this early-out used to skip the epoch
                            // bootstrap entirely. It must not: the walk-start
                            // SELECT above observed the epoch, and this branch
                            // fires both for a genuinely empty mailbox
                            // (UIDNEXT == 1) and for a server that reported no
                            // UIDNEXT at all (SwiftMail defaults it to 0, giving
                            // `initialCursor == -1`). Both leave the folder
                            // `backfillComplete` and never revisited — so a folder
                            // that took this branch could never be stamped by any
                            // later pass. Same transaction as the completion write,
                            // so a failure of either leaves the folder incomplete
                            // and it is retried.
                            //
                            // 🚨 ROUND 12, BLOCKER A — THIS WRITE WAS UNGUARDED,
                            // and `9e0c4797e`'s message and `crawlWalkWriteAllowed`'s
                            // own doc both claimed every bookkeeping transaction
                            // re-read the folder row. They were wrong about this one
                            // and about its sibling below. REFERENCE (`v2final`):
                            // PORTED — the reference guards its counterpart with
                            // `uidValidityWalkWriteAllowed` and logs *"skipping
                            // fully-crawled write — UIDVALIDITY quarantine"*. The
                            // failure it closes: this pass observes E1 on an
                            // unstamped folder, a sibling stamps E2 and merges its
                            // recent window while this pass is between the SELECT
                            // and the write, and the stale E1 pass then writes
                            // `backfillComplete = true` — the bootstrap beside it
                            // returns `false` (headers now exist) and that return
                            // is discarded. Completion excludes the folder from
                            // every later crawl, so the E2 mail outside the recent
                            // window is permanently outside automatic backfill.
                            var written = false
                            do {
                                written = try await AppDatabase.backgroundPool.write { db -> Bool in
                                    #if DEBUG
                                    if Self.freshCursorWriteShouldFailForTesting(folderId: folderId) {
                                        throw FreshCursorWriteFailureForTesting()
                                    }
                                    #endif
                                    guard try Self.crawlWalkWriteAllowed(
                                        db, folderId: folderId, premiseEpoch: writePremise
                                    ) else { return false }
                                    _ = try Folder.filter(Column("id") == folderId)
                                        .updateAll(db,
                                            Column("backfillComplete").set(to: true),
                                            Column("lastKnownUidNext").set(to: uidNext)
                                        )
                                    _ = try Self.bootstrapCrawledFolderUidValidity(
                                        db, folderId: folderId, observed: walkEpoch)
                                    return true
                                }
                            } catch {
                                // The folder is still incomplete, so the loop's
                                // fresh re-read would hand it straight back and
                                // this would repeat at network rate under a
                                // persistent write failure (the NB3 shape, in the
                                // sibling of the branch NB3 named). Decline for the
                                // rest of the call; the next call retries.
                                epochDeclinedFolderIds.insert(folder.id)
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[Backfill] \(folder.name) fully-crawled write failed: \(error) — declining for this call, retry next cycle")
                                }
                            }
                            if written {
                                print("[Backfill] \(folder.name) fully crawled (UIDNEXT=1, no messages)")
                            } else if !epochDeclinedFolderIds.contains(folder.id) {
                                // Refused, not thrown: another pass moved the stamp
                                // out from under this one. Same spin argument as the
                                // throw — decline for the rest of the call.
                                epochDeclinedFolderIds.insert(folder.id)
                                if DebugModeManager.isLoggingEnabled() {
                                    print("[Backfill] \(folder.name): skipping fully-crawled write — the folder no longer holds the UIDVALIDITY this pass premised (\(String(describing: writePremise))); declining for this call, retry next cycle")
                                }
                            }
                            didWork = true
                            await updateBackfillProgressForAccount(account)
                            continue
                        }
                        // THE ANTI-BRICK STAMP. Here, not after the walk: this is
                        // the last moment at which the folder provably holds no
                        // local UID this epoch cannot account for, and the gate
                        // inside `bootstrapCrawledFolderUidValidity` is evaluated
                        // in THIS transaction. Sharing the transaction with the
                        // initial-cursor write is deliberate — the two land
                        // together or not at all.
                        //
                        // 🚨 ROUND 12, BLOCKER A — THIS WRITE WAS UNGUARDED TOO.
                        // REFERENCE (`v2final`): PORTED — the reference guards its
                        // counterpart with `uidValidityWalkWriteAllowed` and logs
                        // *"skipping initial cursor write — UIDVALIDITY
                        // quarantine"*. The failure it closes is the C3 one: a
                        // sibling stamps E1 while this pass is between its SELECT
                        // (which observed E2) and this write; the write plants a
                        // cursor and `lastKnownUidNext` in E2 numbering onto an
                        // E1-stamped folder, the walk then runs with
                        // `expectedEpoch = E2` and the per-chunk check compares the
                        // MIRROR against `expectedEpoch` — never against the STORED
                        // stamp — so it agrees and inserts E2 rows into an
                        // E1-stamped folder. The stamp is non-nil, so
                        // `AccountManager.newGestureRefusedForUnknownEpoch` (which
                        // tests only `== nil`) admits gestures on those bare-UID
                        // rows and a numeric id resolves as a literal UID in the
                        // live mailbox. Refusing here is what keeps a folder's rows
                        // and its stamp in ONE epoch.
                        //
                        // 🚨 ROUND 12, BLOCKER C — AND IT WAS A BARE `try await`.
                        // A throw went to the folder loop's outer `catch`, which
                        // for a non-connection, non-auth error only logs; the
                        // folder was still incomplete, still cursor-less and never
                        // declined, so the loop's fresh re-read handed back the
                        // SAME folder, issued another `getUidNextWithEpoch` SELECT
                        // and retried the identical failing write — and
                        // `previousFolderId` was already this folder, so
                        // `interFolderDelay` was skipped too. Under a persistent
                        // write failure (GRDB suspension, ADR-IOS-046 /
                        // `0xdead10cc` — which `freshCursorWriteFailureIdsForTesting`
                        // models — or `SQLITE_FULL`, or corruption) that is an
                        // unbounded SELECT-per-iteration loop against the server
                        // with zero backoff for the whole call. The
                        // `initialCursor < 1` early-out fifteen lines above got
                        // exactly this `catch` in `9e0c4797e` and its argument
                        // applies word-for-word here; it simply was not applied.
                        // ⚑ R0 — DIVERGENCE FROM THE REFERENCE, DELIBERATE:
                        // `v2final`'s counterpart write is ALSO a bare `try await`
                        // with no decline, so this is not a port regression. It is
                        // fixed anyway, because the reference shares the defect.
                        let planted: (landed: Bool, stamped: Bool)
                        do {
                            planted = try await AppDatabase.backgroundPool.write { db -> (landed: Bool, stamped: Bool) in
                                #if DEBUG
                                if Self.freshCursorWriteShouldFailForTesting(folderId: folderId) {
                                    throw FreshCursorWriteFailureForTesting()
                                }
                                #endif
                                guard try Self.crawlWalkWriteAllowed(
                                    db, folderId: folderId, premiseEpoch: writePremise
                                ) else { return (landed: false, stamped: false) }
                                _ = try Folder.filter(Column("id") == folderId)
                                    .updateAll(db,
                                        Column("backfillUidCursor").set(to: initialCursor),
                                        Column("lastKnownUidNext").set(to: uidNext)
                                    )
                                let stamped = try Self.bootstrapCrawledFolderUidValidity(
                                    db, folderId: folderId, observed: walkEpoch)
                                return (landed: true, stamped: stamped)
                            }
                        } catch {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name) initial cursor write failed: \(error) — declining for this call, retry next cycle")
                            }
                            continue
                        }
                        guard planted.landed else {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name): skipping initial cursor write — the folder no longer holds the UIDVALIDITY this pass premised (\(String(describing: writePremise))); declining for this call, retry next cycle")
                            }
                            continue
                        }
                        if planted.stamped { premiseEpoch = walkEpoch }
                        cursorValue = initialCursor
                    }

                    // Frozen for the rest of the pass: the premise every write from
                    // here on (both throttled in-worker cursor writes, both final
                    // writes) is CASed against. Nothing after this point may change
                    // the folder's stamp on this pass's behalf, so a `let` is the
                    // honest shape.
                    let walkWritePremise = premiseEpoch

                    let cursor = UIDWalkCursor(startCursor: cursorValue, chunkSize: limit)
                    let poolMax = await imapProvider.poolMaxConnections()
                    let workerCount = poolMax < Int.max ? poolMax : SyncConfig.imapMaxConnectionCeiling
                    let folderCaptured = folder
                    let batchSize = profile.imapFetchBatchSize
                    let interBatchDelay = profile.imapInterBatchDelay
                    let lastProgressUpdate = ProgressThrottle()
                    let accountCaptured = account

                    // T1.3: the epoch every chunk of this walk must agree with. A
                    // nil here disables both per-chunk checks, and after the
                    // walk-start gate above that is reachable in exactly ONE state:
                    // the folder's stored epoch is nil too, i.e. a server that never
                    // reports UIDVALIDITY on SELECT and therefore has no epoch to
                    // compare against. Nothing is stamped for such a folder either
                    // (`bootstrapCrawledFolderUidValidity` refuses a nil
                    // observation), so its gestures keep being refused — which is
                    // what `IOS-EPOCH-001` documents.
                    //
                    // ⚠ Round 8's note here justified admitting EVERY nil from that
                    // one cause. It missed the second: on the resumed branch the
                    // walk-start observation is wrapped in `try?`, so a transient
                    // connect/SELECT failure produced the identical nil on a server
                    // that DOES have an epoch — and `v2final`'s own comment names
                    // both causes and refuses in both. `crawlEpochGate` now
                    // distinguishes them by the one fact that separates them (a
                    // non-nil stored epoch proves the server reports UIDVALIDITY),
                    // so this line can no longer be reached with a folder that has
                    // one.
                    let expectedEpoch = walkEpoch
                    var epochMovedMidWalk = false
                    await withTaskGroup(of: BackfillWorkerOutcome.self) { group in
                        for workerIndex in 0..<workerCount {
                            group.addTask { [self] in
                                var outcome = BackfillWorkerOutcome()
                                // Round 8: did the epoch just observed on THIS
                                // worker's own SELECT still describe the UID space
                                // the walk started in? A disagreement means the
                                // mailbox was re-created mid-crawl, so the range is
                                // returned UNCONFIRMED and this worker stops — the
                                // rows it would otherwise insert belong to a
                                // different numbering than the one the folder was
                                // stamped with, and mixing them is precisely the C3
                                // hazard. BREAK rather than continue, for the same
                                // reason `v2final` does: failed ranges are served
                                // first by `nextRange`, so looping would re-fetch
                                // the same range forever — the turnover cannot undo
                                // itself mid-pass.
                                let epochStillAgrees: () -> Bool = {
                                    guard let expectedEpoch else { return true }
                                    return imapProvider.lastObservedUidValidity(
                                        folderPath: folderCaptured.path) == expectedEpoch
                                }
                                while let range = await cursor.nextRange() {
                                    guard !Task.isCancelled else {
                                        // Cancelled — return range for retry next cycle
                                        await cursor.failRange(from: range.from, to: range.to)
                                        break
                                    }

                                    // SEARCH first: discover which UIDs exist in this range
                                    let existingUIDs: [UInt32]
                                    do {
                                        existingUIDs = try await workQueue.execute(priority: .headerFetch) {
                                            try await imapProvider.searchExistingUIDs(
                                                folder: folderCaptured.path, from: range.from, to: range.to
                                            )
                                        }
                                    } catch {
                                        // SEARCH failed — return range for retry
                                        await cursor.failRange(from: range.from, to: range.to)
                                        if Self.isConnectionError(error) || Self.isSelectFailedError(error) {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH connection error: \(error)")
                                            break
                                        }
                                        print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH error: \(error)")
                                        continue
                                    }

                                    // Capture-at-fetch: `searchExistingUIDs` just did
                                    // a TRACKED SELECT of this folder, so the mirror
                                    // now holds the epoch this range's answer came
                                    // from. Check BEFORE confirming an empty range —
                                    // "no UIDs here" is a statement about a UID
                                    // space, and confirming it against the wrong one
                                    // advances the cursor past mail that still
                                    // exists in the space the walk is accounting for.
                                    guard epochStillAgrees() else {
                                        await cursor.failRange(from: range.from, to: range.to)
                                        outcome.epochDisagreed = true
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) range \(range.from)...\(range.to) refused after SEARCH — UIDVALIDITY moved mid-walk")
                                        }
                                        break
                                    }

                                    if existingUIDs.isEmpty {
                                        // No messages in this range — confirmed empty, safe to advance
                                        await cursor.confirmRange(from: range.from, to: range.to)
                                        if await lastProgressUpdate.shouldUpdate() {
                                            let snapshotCursor = await cursor.currentCursor
                                            try? await AppDatabase.backgroundPool.write { db in
                                                // NB2/NB4: guarded like every other
                                                // bookkeeping write this walk makes,
                                                // and re-read INSIDE the txn — the
                                                // `storedEpoch` snapshot this pass
                                                // gated on was taken before the
                                                // walk-start round trip and can be
                                                // minutes stale by now. Round 12
                                                // (NB3): the skews are nil → stamped
                                                // AND stamped → nil (the clearer
                                                // `resetEmptyFolderCrawlEpoch`), and
                                                // BOTH fail open under an
                                                // epoch comparison — hence the CAS.
                                                guard try Self.crawlWalkWriteAllowed(
                                                    db, folderId: folderCaptured.id, premiseEpoch: walkWritePremise
                                                ) else {
                                                    if DebugModeManager.isLoggingEnabled() {
                                                        print("[Backfill] \(folderCaptured.name) w\(workerIndex): skipping progress cursor write — the folder no longer holds the UIDVALIDITY this pass premised")
                                                    }
                                                    return
                                                }
                                                _ = try Folder.filter(Column("id") == folderCaptured.id)
                                                    .updateAll(db, Column("backfillUidCursor").set(to: snapshotCursor))
                                            }
                                            await self.updateBackfillProgressForAccount(accountCaptured)
                                        }
                                        continue
                                    }

                                    print("[Backfill] \(folderCaptured.name) w\(workerIndex) SEARCH found \(existingUIDs.count) UIDs in \(range.from)...\(range.to)")

                                    // FETCH only the existing UIDs
                                    let fetchedHeaders: [MessageHeaderInfo]
                                    do {
                                        fetchedHeaders = try await workQueue.execute(priority: .headerFetch) {
                                            try await imapProvider.fetchMessageHeaders(
                                                folder: folderCaptured.path, uids: existingUIDs,
                                                batchSize: batchSize, interBatchDelay: interBatchDelay
                                            )
                                        }
                                    } catch {
                                        let desc = "\(error)"
                                        let isPayloadError = desc.contains("PayloadTooLargeError") || desc.contains("IMAPDecoderError")
                                        let isTimeout = desc.contains("timed out")
                                        if isPayloadError {
                                            let currentChunk = await cursor.currentChunkSize
                                            if currentChunk <= 1 {
                                                // Single UID too large — confirm anyway (can't split further)
                                                print("[Backfill] \(folderCaptured.name) w\(workerIndex) single UID too large — skipping")
                                                await cursor.confirmRange(from: range.from, to: range.to)
                                                continue
                                            }
                                            await cursor.failRange(from: range.from, to: range.to)
                                            let newChunk = await cursor.reduceChunk()
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) payload too large, chunk → \(newChunk)")
                                            continue
                                        } else if isTimeout {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            let newChunk = await cursor.reduceChunk()
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) timeout, chunk → \(newChunk)")
                                            continue
                                        } else if Self.isConnectionError(error) || Self.isSelectFailedError(error) {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) connection error: \(error)")
                                            break
                                        } else {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) error: \(error)")
                                            BackgroundSyncLogger.logError("\(folderCaptured.name) w\(workerIndex) error: \(error)", source: "backfill")
                                            break
                                        }
                                    }

                                    // Capture-at-fetch again, and BEFORE the insert.
                                    // `fetchMessageHeaders` re-SELECTs (tracked) per
                                    // inner batch, so a turnover that happened
                                    // between this range's SEARCH and its FETCH is
                                    // visible here. These headers must NOT reach the
                                    // database: they carry UIDs from a numbering the
                                    // folder's stamped epoch does not describe, and
                                    // a later bare-UID gesture on one of them would
                                    // resolve against whatever now occupies that
                                    // number. `v2final` expresses the same refusal
                                    // as `insertBackfillBatch`'s `refused` return —
                                    // the shape differs, the rule ("a refused range
                                    // is FAILED, never confirmed") does not.
                                    guard epochStillAgrees() else {
                                        await cursor.failRange(from: range.from, to: range.to)
                                        outcome.epochDisagreed = true
                                        if DebugModeManager.isLoggingEnabled() {
                                            print("[Backfill] \(folderCaptured.name) w\(workerIndex) range \(range.from)...\(range.to) refused after FETCH — UIDVALIDITY moved mid-walk, \(fetchedHeaders.count) headers discarded")
                                        }
                                        break
                                    }

                                    // Successfully fetched — insert to DB then confirm
                                    if !fetchedHeaders.isEmpty {
                                        #if DEBUG
                                        await Self.runBackfillWalkCheckpointForTesting(
                                            .beforeInsertingFetchedChunk(folderId: folderCaptured.id))
                                        #endif
                                        // A refused chunk means the folder's STAMP moved
                                        // under this walk (or its row went away entirely)
                                        // — something `epochStillAgrees()` above
                                        // structurally cannot see, since no term in it
                                        // reads the folder row. The range is FAILED,
                                        // never confirmed, and this worker stops: failed
                                        // ranges are served FIRST by `nextRange`, so
                                        // continuing would re-fetch the same range forever
                                        // (the stamp cannot move back mid-pass). Same stop
                                        // rationale, and the same rule, as `v2final`'s
                                        // `chunkRefused` leg. Round 13: the refusal now
                                        // arrives as a CASE rather than a discardable
                                        // tuple member, so this leg cannot be skipped by
                                        // omission — `break` inside `guard else` targets
                                        // the `while` (a `switch` would have swallowed it).
                                        guard case .landed(let inserted, let ftsRecords, let ccBccUpdates) =
                                            await self.insertBackfillBatch(
                                                fetchedHeaders, folderId: folderCaptured.id, accountId: folderCaptured.accountId,
                                                folderPath: folderCaptured.path, folderRole: folderCaptured.role, isInInbox: folderCaptured.role == .inbox,
                                                epochPremise: .init(walkWritePremise)
                                            )
                                        else {
                                            await cursor.failRange(from: range.from, to: range.to)
                                            outcome.epochDisagreed = true
                                            if DebugModeManager.isLoggingEnabled() {
                                                print("[Backfill] \(folderCaptured.name) w\(workerIndex) range \(range.from)...\(range.to) refused at INSERT — the folder no longer holds the UIDVALIDITY this pass premised, \(fetchedHeaders.count) headers discarded")
                                            }
                                            break
                                        }
                                        if !ftsRecords.isEmpty { await self.indexHeadersForFTS(ftsRecords) }
                                        if !ccBccUpdates.isEmpty { try? await SearchIndex.shared.updateCcBcc(ccBccUpdates) }
                                        if inserted > 0 {
                                            outcome.didWork = true
                                            await BackfillBodyQueue.shared.enqueueItems(
                                                ftsRecords: ftsRecords, accountId: folderCaptured.accountId,
                                                folderPath: folderCaptured.path, isInInbox: folderCaptured.role == .inbox
                                            )
                                        }
                                    }

                                    // Confirm AFTER successful DB insert
                                    await cursor.confirmRange(from: range.from, to: range.to)

                                    if await lastProgressUpdate.shouldUpdate() {
                                        let snapshotCursor = await cursor.currentCursor
                                        try? await AppDatabase.backgroundPool.write { db in
                                            // NB2/NB4 — see the empty-range twin above.
                                            guard try Self.crawlWalkWriteAllowed(
                                                db, folderId: folderCaptured.id, premiseEpoch: walkWritePremise
                                            ) else {
                                                if DebugModeManager.isLoggingEnabled() {
                                                    print("[Backfill] \(folderCaptured.name) w\(workerIndex): skipping progress cursor write — the folder no longer holds the UIDVALIDITY this pass premised")
                                                }
                                                return
                                            }
                                            _ = try Folder.filter(Column("id") == folderCaptured.id)
                                                .updateAll(db, Column("backfillUidCursor").set(to: snapshotCursor))
                                        }
                                        await self.updateBackfillProgressForAccount(accountCaptured)
                                    }
                                }
                                return outcome
                            }
                        }
                        for await workerResult in group {
                            if workerResult.didWork { didWork = true }
                            if workerResult.epochDisagreed { epochMovedMidWalk = true }
                        }
                    }

                    // ⚠ THE EPOCH IS STAMPED AT WALK START, NOT HERE. Round 7 put a
                    // single POST-walk read of `imapProvider.lastObservedUidValidity`
                    // at this point and handed it to `bootstrapFolderUidValidity`.
                    // The write was correctly bootstrap-only; the VALUE was the
                    // defect. Nothing bound that sample to the UIDs the walk had
                    // just inserted — on a resumed crawl it could be an epoch the
                    // mailbox rolled to AFTER the previous pass's headers were
                    // written, and stamping it made `newGestureRefusedForUnknown
                    // Epoch` (which tests only for nil, never stored-vs-live) admit
                    // bare-UID gestures that then resolved against a different
                    // message. See `bootstrapCrawledFolderUidValidity` for the
                    // binding rule and `walkEpoch` above for the capture. Do not
                    // reintroduce a mirror read here, per chunk or otherwise.

                    // Persist confirmed cursor — only advances past ranges that succeeded
                    let finalCursor = await cursor.currentCursor
                    let isComplete = await cursor.isComplete
                    // A pass that saw the mailbox re-created under it accounted the
                    // ranges it confirmed AFTER that point against a UID space that
                    // no longer exists — except there are none: a worker that sees
                    // the disagreement fails its range and stops, and every other
                    // worker's confirm is gated on its own post-SEARCH and
                    // post-FETCH checks. So this pass withholds the two writes
                    // DERIVED FROM THE WHOLE PASS: the final cursor and
                    // completeness.
                    //
                    // ⚠ NB2 — round 8's comment here said "neither the cursor nor
                    // completeness … may be persisted", and that was FALSE of the
                    // cursor. The throttled in-worker writes above
                    // (`lastProgressUpdate.shouldUpdate()`, both the empty-range and
                    // post-insert legs) already persisted intermediate cursors about
                    // once a second while the walk ran, and `v2final` guards BOTH of
                    // them where this port had left them bare. They are guarded now
                    // (`crawlWalkWriteAllowed`) — as, since round 12, are the two
                    // `case .fresh` writes `9e0c4797e` left bare while claiming
                    // otherwise; the disproving search is
                    // `rg -n 'Column\("backfillUidCursor"\)\.set|Column\("backfillComplete"\)\.set|Column\("lastKnownUidNext"\)\.set|crawlWalkWriteAllowed'`
                    // over this file, and every IMAP-branch bookkeeping write it
                    // returns now sits under a guard. What they persisted is sound on
                    // its own terms: a cursor can only advance past a range that a
                    // worker confirmed, and a worker only confirms a range whose own
                    // SEARCH and FETCH agreed with `expectedEpoch` — so every
                    // intermediate cursor describes ranges accounted in the epoch the
                    // folder is still stamped with. Say that, not "nothing was
                    // persisted".
                    if epochMovedMidWalk {
                        // …and this CALL must not immediately walk it again. The
                        // loop below re-reads the account's incomplete folders and
                        // would pick this one straight back up — with a fresh
                        // `walkEpoch` read from the mirror, which now describes the
                        // NEW mailbox. That second pass would insert post-turnover
                        // UIDs into a folder still stamped with the old epoch: the
                        // very mixing the per-chunk guard just prevented, one
                        // iteration later. (The stored-vs-walk guard at the top of
                        // the IMAP branch catches the same thing on a LATER call,
                        // once the folder has a stamp; this set covers the case
                        // where it does not yet.)
                        epochDeclinedFolderIds.insert(folder.id)
                        if DebugModeManager.isLoggingEnabled() {
                            print("[Backfill] \(folder.name): UIDVALIDITY moved mid-walk — skipping cursor/completeness bookkeeping, retry next cycle")
                        }
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) UIDVALIDITY moved mid-walk — bookkeeping skipped")
                        didWork = true
                        await updateBackfillProgressForAccount(account)
                        continue
                    }
                    // Both final writes are guarded and re-read the folder row inside
                    // their own transaction (NB4), and both report whether they
                    // actually landed. A write that did NOT land leaves the folder
                    // incomplete, and the loop's fresh re-read would hand the same
                    // folder straight back with no inter-folder delay — a
                    // network-rate spin under a persistent write failure or a
                    // concurrent re-stamp (the NB3 shape). Decline it for the rest
                    // of this call instead; the next call retries.
                    let folderId = folder.id
                    if isComplete {
                        let written = ((try? await AppDatabase.backgroundPool.write { db -> Bool in
                            guard try Self.crawlWalkWriteAllowed(
                                db, folderId: folderId, premiseEpoch: walkWritePremise) else { return false }
                            _ = try Folder.filter(Column("id") == folderId)
                                .updateAll(db,
                                    Column("backfillComplete").set(to: true),
                                    Column("backfillUidCursor").set(to: nil as Int?)
                                )
                            return true
                        }) ?? false)
                        if written {
                            print("[Backfill] \(folder.name) fully crawled (all ranges confirmed)")
                            BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) fully crawled (all ranges confirmed)")
                        } else {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name): fully-crawled write did not land — declining for this call, retry next cycle")
                            }
                        }
                    } else {
                        let written = ((try? await AppDatabase.backgroundPool.write { db -> Bool in
                            guard try Self.crawlWalkWriteAllowed(
                                db, folderId: folderId, premiseEpoch: walkWritePremise) else { return false }
                            _ = try Folder.filter(Column("id") == folderId)
                                .updateAll(db, Column("backfillUidCursor").set(to: finalCursor))
                            return true
                        }) ?? false)
                        if !written {
                            epochDeclinedFolderIds.insert(folder.id)
                            if DebugModeManager.isLoggingEnabled() {
                                print("[Backfill] \(folder.name): cursor persist did not land — declining for this call, retry next cycle")
                            }
                        }
                        let hasPending = await cursor.hasPendingWork
                        if hasPending {
                            print("[Backfill] \(folder.name) has failed ranges — will retry next cycle (cursor at \(finalCursor))")
                            BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) has failed ranges — retry next cycle (cursor at \(finalCursor))")
                        }
                    }
                    didWork = true
                    await updateBackfillProgressForAccount(account)
                    continue

                } else if provider is GmailProvider || provider is ExchangeProvider {
                    // Gmail/Exchange: page-token cursor walk — resumes from stored position.
                    // Each call returns one page of IDs + nextPageToken. No date filter needed;
                    // the token tracks position in the listing (newest→oldest).
                    let pageResult: (ids: [String], nextPageToken: String?)
                    if let gp = provider as? GmailProvider {
                        pageResult = try await workQueue.execute(priority: .headerFetch) {
                            try await gp.listMessageIdsPage(
                                folder: folder.path,
                                pageToken: folder.backfillPageToken,
                                pageSize: limit
                            )
                        }
                    } else {
                        let ep = provider as! ExchangeProvider
                        pageResult = try await workQueue.execute(priority: .headerFetch) {
                            try await ep.listMessageIdsPage(
                                folder: folder.path,
                                pageToken: folder.backfillPageToken,
                                pageSize: limit
                            )
                        }
                    }
                    let (pageIds, nextToken) = pageResult

                    if pageIds.isEmpty && nextToken == nil {
                        // No more pages — folder fully crawled
                        try? await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db,
                                    Column("backfillComplete").set(to: true),
                                    Column("backfillPageToken").set(to: nil as String?)
                                )
                        }
                        print("[Backfill] \(folder.name) fully crawled (no more pages)")
                        BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) fully crawled (no more pages)")
                        didWork = true
                        await updateBackfillProgressForAccount(account)
                        continue
                    }

                    // Page token is stored AFTER processing (not before) so that
                    // cancellation or failure mid-page causes the same page to be
                    // re-fetched next cycle. insertBackfillBatch handles dedup.

                    // Dedup returned IDs against DB
                    let missingIds: [String] = try await dbPool.read { db in
                        let sqlChunkSize = SyncConfig.sqlChunkSize
                        var existingIds = Set<String>()
                        for start in stride(from: 0, to: pageIds.count, by: sqlChunkSize) {
                            let end = min(start + sqlChunkSize, pageIds.count)
                            let chunk = Array(pageIds[start..<end])
                            let found = try String.fetchSet(db,
                                MessageHeader
                                    .select(Column("messageId"))
                                    .filter(Column("folderId") == folder.id && chunk.contains(Column("messageId")))
                            )
                            existingIds.formUnion(found)
                        }
                        return pageIds.filter { !existingIds.contains($0) }
                    }

                    if missingIds.isEmpty {
                        // All IDs on this page already in DB — update anchor for age cutoff tracking
                        let oldestDate: Date? = try? await dbPool.read { db in
                            try Date.fetchOne(db,
                                MessageHeader
                                    .select(min(Column("date")))
                                    .filter(Column("folderId") == folder.id && pageIds.contains(Column("messageId")))
                            )
                        }
                        if let d = oldestDate {
                            try await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db, Column("oldestSyncedDate").set(to: d))
                            }
                        }
                        // Safe to advance — all IDs on this page already exist in GRDB
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillPageToken").set(to: nextToken))
                        }
                        if nextToken == nil {
                            try? await AppDatabase.backgroundPool.write { db in
                                _ = try Folder.filter(Column("id") == folder.id)
                                    .updateAll(db,
                                        Column("backfillComplete").set(to: true),
                                        Column("backfillPageToken").set(to: nil as String?)
                                    )
                            }
                            print("[Backfill] \(folder.name) fully crawled (last page, all exist)")
                            didWork = true
                        } else {
                            print("[Backfill] \(folder.name) all \(pageIds.count) IDs on page already exist — advancing to next page")
                        }
                        await updateBackfillProgressForAccount(account)
                        continue
                    }

                    print("[Backfill] \(folder.name) \(missingIds.count) missing of \(pageIds.count) IDs on page")

                    // Unified fetch: headers + bodies in a single API call per message.
                    // Stream maintains `concurrency` in-flight HTTP requests at all times.
                    // We collect all results, then batch-insert headers and write bodies to FTS.
                    let stream: AsyncStream<BackfillResult>
                    let bodyConcurrency = profile.gmailBodyConcurrency
                    if let gp = provider as? GmailProvider {
                        stream = await gp.fetchBackfillBatch(ids: missingIds, concurrency: bodyConcurrency)
                    } else {
                        stream = await (provider as! ExchangeProvider).fetchBackfillBatch(ids: missingIds, concurrency: bodyConcurrency)
                    }

                    // Consume streaming results — collect headers + bodies together.
                    // Body data is keyed by messageId for matching after GRDB insert.
                    var bodyData: [String: (htmlBody: String?, textBody: String?)] = [:]
                    var streamInterrupted = false

                    for await result in stream {
                        if Task.isCancelled {
                            streamInterrupted = true
                            break
                        }
                        if let header = result.header {
                            headers.append(header)
                            bodyData[result.id] = (htmlBody: result.htmlBody, textBody: result.textBody)
                        }
                        if let error = result.error, case ProviderError.authenticationFailed = error {
                            await AccountManager.shared.markAuthFailed(account.id)
                            throw error
                        }
                    }

                    if !headers.isEmpty {
                        // Step 1: Insert headers to GRDB (batch dedup).
                        // The premise-LESS overload, deliberately: this is the
                        // Gmail/Exchange page walk, and neither provider has a
                        // UIDVALIDITY concept at all, so there is no premise to
                        // hold and nothing a guard could compare. That overload
                        // has no refusal channel to discard (round 13 blocker 3),
                        // so this call site cannot silently swallow one.
                        let (inserted, ftsRecords, ccBccUpdates) = await insertBackfillBatch(
                            headers, folderId: folder.id, accountId: folder.accountId,
                            folderPath: folder.path, folderRole: folder.role, isInInbox: folder.role == .inbox
                        )
                        if !ftsRecords.isEmpty { await indexHeadersForFTS(ftsRecords) }
                        if !ccBccUpdates.isEmpty { try? await SearchIndex.shared.updateCcBcc(ccBccUpdates) }
                        insertedCount = inserted

                        // Step 2: Write bodies to FTS for inserted messages.
                        // Match body data to headerIds using ftsRecords (which have headerId + messageId).
                        var ftsBodyBuffer: [(headerId: String, body: String)] = []
                        var snippetBuffer: [(headerId: String, snippet: String)] = []
                        for ftsRecord in ftsRecords {
                            if let body = bodyData[ftsRecord.messageId] {
                                let plainText = EmailFilter.extractPlainText(htmlBody: body.htmlBody, textBody: body.textBody)
                                if let plainText, !plainText.isEmpty {
                                    ftsBodyBuffer.append((headerId: ftsRecord.headerId, body: plainText))
                                    let snippet = EmailFilter.snippetFromPlainText(plainText)
                                    snippetBuffer.append((headerId: ftsRecord.headerId, snippet: snippet))
                                }
                            }
                        }
                        if !ftsBodyBuffer.isEmpty {
                            do {
                                let writtenIds = try await SearchIndex.shared.updateBodies(ftsBodyBuffer)
                                // Only set bodyComplete for items actually written to FTS.
                                let confirmedSnippets = snippetBuffer.filter { writtenIds.contains($0.headerId) }
                                applySnippetUpdates(confirmedSnippets)
                                let skipped = ftsBodyBuffer.count - writtenIds.count
                                if skipped > 0 {
                                    print("[Backfill] \(folder.name) wrote \(writtenIds.count)/\(ftsBodyBuffer.count) bodies to FTS (\(skipped) deferred)")
                                } else {
                                    print("[Backfill] \(folder.name) wrote \(ftsBodyBuffer.count) bodies to FTS")
                                }
                            } catch {
                                print("[Backfill] FTS body write failed: \(error)")
                                BackgroundSyncLogger.logError("FTS body write failed for \(folder.name): \(error)", source: "backfill")
                            }
                        }

                        // Enqueue to ActiveBodyQueue — items with bodies already in FTS will be
                        // skipped (forwarding inbox items to ActiveAIQueue); items without
                        // bodies will be fetched by the queue.
                        if !ftsRecords.isEmpty {
                            await BackfillBodyQueue.shared.enqueueItems(
                                ftsRecords: ftsRecords, accountId: folder.accountId,
                                folderPath: folder.path, isInInbox: folder.role == .inbox
                            )
                        }
                    }

                    // Only advance page token if the full page was consumed.
                    // If stream was interrupted (cancellation), don't advance — the
                    // same page will be re-fetched next cycle (dedup handles duplicates).
                    if !streamInterrupted {
                        try await AppDatabase.backgroundPool.write { db in
                            _ = try Folder.filter(Column("id") == folder.id)
                                .updateAll(db, Column("backfillPageToken").set(to: nextToken))
                        }
                        if nextToken == nil {
                            isLastPage = true
                        }
                    } else {
                        print("[Backfill] \(folder.name) stream interrupted — NOT advancing page token")
                    }
                } else {
                    break
                }

                if headers.isEmpty {
                    print("[Backfill] \(folder.name) fetch returned 0 headers — will retry next cycle")
                    continue
                }

                print("[Backfill] \(folder.name) fetched \(headers.count) older messages")

                // Update oldestSyncedDate from oldest fetched message
                if let oldest = headers.min(by: { $0.date < $1.date }) {
                    try await AppDatabase.backgroundPool.write { db in
                        _ = try Folder.filter(Column("id") == folder.id)
                            .updateAll(db, Column("oldestSyncedDate").set(to: oldest.date))
                    }
                }

                // Gmail/Exchange: mark folder complete if this was the last page
                if isLastPage {
                    try? await AppDatabase.backgroundPool.write { db in
                        _ = try Folder.filter(Column("id") == folder.id)
                            .updateAll(db,
                                Column("backfillComplete").set(to: true),
                                Column("backfillPageToken").set(to: nil as String?)
                            )
                    }
                    print("[Backfill] \(folder.name) fully crawled (last page processed)")
                    BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) fully crawled (last page processed)")
                }

                if insertedCount > 0 || isLastPage { didWork = true }
                consecutiveConnectionFailures = 0
                connectionBackoffSeconds = 5  // Reset backoff on success
            } catch is CancellationError {
                return didWork
            } catch {
                print("[Backfill] Failed for \(folder.name): \(error)")
                BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) cycle error: \(error)")
                if !Self.isConnectionError(error) && !Self.isSelectFailedError(error) {
                    BackgroundSyncLogger.logError("Failed for \(folder.name): \(error)", source: "backfill:\(account.emailAddress)")
                }
                if case ProviderError.authenticationFailed = error {
                    await AccountManager.shared.markAuthFailed(account.id)
                    return didWork
                }
                if Self.isSelectFailedError(error) || Self.isConnectionError(error) {
                    // Treat SELECT failures as transient in backfill — the folder exists
                    // but the connection may be stale. Exponential backoff instead of aborting.
                    // Pool self-heals: dead connections are discarded on checkin(healthy: false),
                    // next checkout creates a fresh one.
                    consecutiveConnectionFailures += 1
                    print("[Backfill] Connection failure \(consecutiveConnectionFailures) — backing off \(Int(connectionBackoffSeconds))s")
                    BackgroundSyncLogger.logBackfill("[Backfill] \(account.emailAddress)/\(folder.name) connection failure #\(consecutiveConnectionFailures) — backoff \(Int(connectionBackoffSeconds))s")
                    try? await Task.sleep(for: .seconds(connectionBackoffSeconds))
                    connectionBackoffSeconds = min(60, connectionBackoffSeconds * 2)
                }
                // ROUND 12 — the mirror-image hunt looked hard at the `else` of
                // this `if` (an unclassified error gets NO backoff at all) and
                // deliberately left it alone. It is NOT a sibling of the
                // blocker-C spin family, because reaching here does not imply
                // "no progress was made": every error thrown AFTER the walk's
                // final cursor write leaves the cursor advanced, so the next
                // iteration walks the NEXT range rather than re-walking this
                // one. The pre-progress throws all funnel through
                // `selectMailboxTracked` (`getUidNextWithEpoch`), whose failures
                // `isSelectFailedError` classifies, so they DO back off. The one
                // residual — an unclassified, non-connection throw out of
                // `getUidNextWithEpoch` — is reported in the round-12 findings
                // rather than fixed here: a blanket decline in this `catch`
                // would drop a whole folder for the rest of a BGProcessing
                // budget on one transient blip, and `v2final`'s `catch` is
                // byte-identical to this one, so there is no reference to port.
            }

            // Only delay between different folders — same folder continues immediately
            if previousFolderId != nil && previousFolderId != folder.id {
                try? await Task.sleep(for: .seconds(profile.interFolderDelay))
            }
            previousFolderId = folder.id
            await updateBackfillProgressForAccount(account)
        }

        await updateBackfillProgressForAccount(account)
        return didWork
    }

}
