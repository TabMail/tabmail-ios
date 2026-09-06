/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
import GRDB
@testable import TabMail

// MARK: - Test doubles

/// Thread-safe recorder for walk-effect closures (Mutex per Resilience Rule 5).
private final class WalkRecorder: Sendable {
    let searchedChunks = Mutex<[[UInt32]]>([])
    let deletedChunks = Mutex<[[UInt32]]>([])

    func recordSearch(_ chunk: [UInt32]) { searchedChunks.withLock { $0.append(chunk) } }
    func recordDelete(_ ghosts: [UInt32]) { deletedChunks.withLock { $0.append(ghosts) } }

    var searchCalls: [[UInt32]] { searchedChunks.withLock { $0 } }
    var deleteCalls: [[UInt32]] { deletedChunks.withLock { $0 } }
}

/// Error whose description matches none of `SyncEngine.isConnectionError`'s
/// substrings — a "transient non-connection" SEARCH failure.
private struct PlainSearchError: Error, CustomStringConvertible {
    var description: String { "plain search rejection" }
}

/// Scripted per-chunk SEARCH behavior (Sendable — capturable by the walk's
/// `@Sendable` effect closures under Swift 6 strict concurrency).
private enum ChunkScript: Sendable {
    case found(Set<UInt32>, uidValidity: UInt32)
    /// Throws a non-connection error (chunk is skipped, walk continues).
    case fail
    /// Throws a connection-class error (walk aborts).
    case failConnection
    /// Throws the TYPED epoch refusal `ProviderError.uidValidityChanged` (T4.S1).
    /// Its description matches none of `isConnectionError`'s or
    /// `isSelectFailedError`'s substrings, so without the typed arm the walk
    /// classifies it as an ordinary per-chunk failure and keeps walking.
    case failEpochRefused
}

/// The typed refusal a chunk's SEARCH raises when the epoch it was served under
/// disagrees with the epoch the caller admitted. `stored`/`live` are fixture
/// values — the walk must not read them (see `epochRefusalNeverClaimsTurnover`).
private func epochRefusal() -> ProviderError {
    .uidValidityChanged(folderPath: "INBOX", stored: 7, live: 9)
}

// MARK: - Pure decision functions

@Suite("DeletionReconcile — pure decision functions")
struct DeletionReconcilePureFunctionTests {

    @Test("shouldReconcileDeletions: equal counts do not trigger")
    func equalCountsNoTrigger() {
        #expect(!SyncEngine.shouldReconcileDeletions(localCount: 10, serverCount: 10, tolerance: 0))
    }

    @Test("shouldReconcileDeletions: local excess triggers at tolerance 0")
    func localExcessTriggers() {
        #expect(SyncEngine.shouldReconcileDeletions(localCount: 11, serverCount: 10, tolerance: 0))
    }

    @Test("shouldReconcileDeletions: excess at tolerance boundary does not trigger")
    func excessAtToleranceBoundary() {
        #expect(!SyncEngine.shouldReconcileDeletions(localCount: 12, serverCount: 10, tolerance: 2))
    }

    @Test("shouldReconcileDeletions: excess above tolerance triggers")
    func excessAboveTolerance() {
        #expect(SyncEngine.shouldReconcileDeletions(localCount: 13, serverCount: 10, tolerance: 2))
    }

    @Test("shouldReconcileDeletions: server larger (backfill incomplete) never triggers")
    func serverLargerNeverTriggers() {
        #expect(!SyncEngine.shouldReconcileDeletions(localCount: 5, serverCount: 10, tolerance: 0))
        #expect(!SyncEngine.shouldReconcileDeletions(localCount: 0, serverCount: 10, tolerance: 0))
    }

    @Test("selectGhostUIDs: subset found — the missing UIDs are ghosts")
    func ghostsSubset() {
        let ghosts = SyncEngine.selectGhostUIDs(localChunk: [10, 20, 30, 40], serverFound: [10, 30])
        #expect(ghosts == [20, 40])
    }

    @Test("selectGhostUIDs: all found — no ghosts")
    func ghostsAllFound() {
        let ghosts = SyncEngine.selectGhostUIDs(localChunk: [10, 20], serverFound: [10, 20])
        #expect(ghosts.isEmpty)
    }

    @Test("selectGhostUIDs: none found — all local UIDs are ghosts")
    func ghostsAllGone() {
        let ghosts = SyncEngine.selectGhostUIDs(localChunk: [10, 20, 30], serverFound: [])
        #expect(ghosts == [10, 20, 30])
    }

    @Test("selectGhostUIDs: empty chunk — no ghosts")
    func ghostsEmptyChunk() {
        let ghosts = SyncEngine.selectGhostUIDs(localChunk: [], serverFound: [10])
        #expect(ghosts.isEmpty)
    }

    @Test("selectGhostUIDs: superset serverFound (extra UIDs outside the chunk) is chunk-relative")
    func ghostsSupersetFound() {
        let ghosts = SyncEngine.selectGhostUIDs(localChunk: [10, 20], serverFound: [5, 10, 20, 99])
        #expect(ghosts.isEmpty)
    }

    @Test("planReconcileChunks: exact multiple splits evenly")
    func chunksExactMultiple() {
        let chunks = SyncEngine.planReconcileChunks(uids: (1...10).map { UInt32($0) }, chunkSize: 5)
        #expect(chunks.count == 2)
        guard chunks.count == 2 else { return }
        #expect(chunks[0] == [1, 2, 3, 4, 5])
        #expect(chunks[1] == [6, 7, 8, 9, 10])
    }

    @Test("planReconcileChunks: remainder forms a short final chunk")
    func chunksRemainder() {
        let chunks = SyncEngine.planReconcileChunks(uids: (1...11).map { UInt32($0) }, chunkSize: 5)
        #expect(chunks.count == 3)
        guard chunks.count == 3 else { return }
        #expect(chunks[2] == [11])
    }

    @Test("planReconcileChunks: empty local set yields no chunks")
    func chunksEmpty() {
        #expect(SyncEngine.planReconcileChunks(uids: [], chunkSize: 5).isEmpty)
    }

    @Test("planReconcileChunks: chunk size larger than count yields one chunk, sorted ascending")
    func chunksSingleSorted() {
        let chunks = SyncEngine.planReconcileChunks(uids: [30, 10, 20], chunkSize: 500)
        #expect(chunks.count == 1)
        guard chunks.count == 1 else { return }
        #expect(chunks[0] == [10, 20, 30])
    }
}

// MARK: - Walk semantics (injected effects)

@Suite("DeletionReconcile — walk semantics")
struct DeletionReconcileWalkTests {

    /// Convenience: run the walk with scripted per-chunk search results.
    /// `script[i]` drives the i-th SEARCH call.
    private func runWalk(
        localUIDs: [UInt32],
        chunkSize: Int,
        storedUidValidity: Int?,
        script: [ChunkScript],
        recorder: WalkRecorder,
        deleteThrows: Bool = false,
        maxDeletions: Int = Int.max
    ) async -> DeletionReconcileOutcome {
        let callIndex = Mutex<Int>(0)
        return await SyncEngine.runDeletionReconcileWalk(
            localUIDs: localUIDs,
            chunkSize: chunkSize,
            storedUidValidity: storedUidValidity,
            maxDeletions: maxDeletions,
            interChunkDelaySeconds: 0,
            search: { chunk in
                recorder.recordSearch(chunk)
                let i = callIndex.withLock { let v = $0; $0 += 1; return v }
                guard i < script.count else {
                    return UIDExistenceResult(found: Set(chunk), uidValidity: 1)
                }
                switch script[i] {
                case .found(let found, let validity):
                    return UIDExistenceResult(found: found, uidValidity: validity)
                case .fail:
                    throw PlainSearchError()
                case .failConnection:
                    throw URLError(.notConnectedToInternet)
                case .failEpochRefused:
                    throw epochRefusal()
                }
            },
            deleteGhosts: { ghosts in
                if deleteThrows { throw PlainSearchError() }
                recorder.recordDelete(ghosts)
                return ghosts.count
            }
        )
    }

    @Test("All UIDs exist — nothing deleted, all chunks searched")
    func allExist() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [
                .found([1, 2], uidValidity: 7),
                .found([3, 4], uidValidity: 7),
            ],
            recorder: recorder
        )
        #expect(outcome == DeletionReconcileOutcome(deletedCount: 0, failedChunks: 0, searchedChunks: 2, aborted: false, abortReason: nil))
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("Ghosts deleted per chunk via the shared deletion path")
    func ghostsDeletedPerChunk() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [
                .found([1], uidValidity: 7),   // ghost: 2
                .found([], uidValidity: 7),    // ghosts: 3, 4
            ],
            recorder: recorder
        )
        #expect(outcome.deletedCount == 3)
        #expect(outcome.searchedChunks == 2)
        #expect(!outcome.aborted)
        let deletes = recorder.deleteCalls
        #expect(deletes.count == 2)
        guard deletes.count == 2 else { return }
        #expect(deletes[0] == [2])
        #expect(deletes[1] == [3, 4])
    }

    @Test("Failed SEARCH chunk deletes NOTHING from it and the walk continues")
    func failedChunkSkipsDeletes() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [
                .fail,                               // chunk [1,2] fails
                .found([3], uidValidity: 7),  // ghost: 4
            ],
            recorder: recorder
        )
        #expect(outcome.failedChunks == 1)
        #expect(outcome.searchedChunks == 1)
        #expect(!outcome.aborted)
        #expect(outcome.deletedCount == 1)
        let deletes = recorder.deleteCalls
        #expect(deletes.count == 1)
        guard deletes.count == 1 else { return }
        #expect(deletes[0] == [4]) // nothing from the failed chunk [1,2]
    }

    @Test("Connection error aborts the walk — later chunks are not searched")
    func connectionErrorAborts() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [.failConnection],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.failedChunks == 1)
        #expect(recorder.searchCalls.count == 1) // second chunk never searched
        #expect(recorder.deleteCalls.isEmpty)
    }

    // MARK: T4.S1 — the typed epoch refusal is a WHOLE-WALK abort, not a skipped chunk

    /// T4.S1. A SEARCH that THROWS `ProviderError.uidValidityChanged` says the UID
    /// numbering this walk is judging against is in doubt — for the whole mailbox,
    /// not for one chunk. Before the typed arm, that error matched neither
    /// `isConnectionError` nor `isSelectFailedError`, so it fell to the generic
    /// `continue`: the walk carried on and deleted every later chunk's local UIDs as
    /// "ghosts" on the strength of a numbering nothing had reconciled.
    ///
    /// RED-FIRST (the arm removed, so the refusal falls through to `continue`):
    /// chunk 1 is skipped, chunk 2 is searched and its two UIDs are deleted —
    /// `deletedCount → 2`, `aborted → false`, `searchCalls.count → 2`.
    @Test("A typed UIDVALIDITY refusal from SEARCH aborts the whole walk — later chunks are never searched")
    func epochRefusalAbortsWholeWalk() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [
                .failEpochRefused,             // chunk [1,2] — the numbering is refused
                .found([], uidValidity: 7),    // chunk [3,4] — must never be reached
            ],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.abortReason?.hasPrefix("uidValidity changed") == true)
        #expect(outcome.failedChunks == 1)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.searchCalls.count == 1) // the walk stopped, it did not skip
        #expect(recorder.deleteCalls.isEmpty)
    }

    /// T4.S1, mid-walk. The refusal stops the walk where it lands: deletions already
    /// confirmed by chunks the server DID serve under the expected epoch stand (they
    /// were proven against a numbering that agreed), and not one UID beyond the
    /// refusal is judged.
    ///
    /// RED-FIRST (arm removed): chunk 2 is skipped and chunk 3 is searched and swept,
    /// so `deletedCount → 3`, `searchCalls.count → 3`, `aborted → false`.
    @Test("A typed UIDVALIDITY refusal mid-walk stops further deletion and leaves earlier deletions intact")
    func epochRefusalMidWalkStopsFurtherDeletion() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4, 5, 6], chunkSize: 2, storedUidValidity: 7,
            script: [
                .found([1], uidValidity: 7),   // chunk [1,2] — ghost: 2, epoch agrees
                .failEpochRefused,             // chunk [3,4] — the numbering is refused
                .found([], uidValidity: 7),    // chunk [5,6] — must never be reached
            ],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.deletedCount == 1)
        #expect(recorder.searchCalls.count == 2)
        let deletes = recorder.deleteCalls
        #expect(deletes.count == 1)
        guard deletes.count == 1 else { return }
        #expect(deletes[0] == [2])
    }

    /// T4.S1 — the abort must NOT be upgraded into a purge. `uidValidityMismatch` is
    /// the caller's trigger for `fireUidValidityChangeHandler`, which purges the
    /// folder and resyncs it; that is destructive and unrecoverable, so it may only
    /// ever be founded on this walk's OWN stored-vs-observed comparison. A thrown
    /// refusal's `stored` comes from a different authority (on v3,
    /// `IMAPProvider.requireUidValidity` reports a queued operation's admitted
    /// epoch), so this leg refuses to delete and claims nothing about a turnover.
    ///
    /// RED-FIRST: pre-fix the walk did not abort at all, so `aborted` fails here too;
    /// the `uidValidityMismatch` assertion pins the direction a future change must
    /// not flip.
    @Test("A typed UIDVALIDITY refusal never claims a folder turnover — the purge reaction is not fired")
    func epochRefusalNeverClaimsTurnover() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2], chunkSize: 2, storedUidValidity: 7,
            script: [.failEpochRefused],
            recorder: recorder
        )
        #expect(outcome.aborted)
        // `uidValidityMismatch` is a TUPLE optional, so read it into a Bool rather
        // than relying on tuple equality inside the macro.
        let claimedTurnover = outcome.uidValidityMismatch != nil
        #expect(!claimedTurnover)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("UIDVALIDITY mismatch vs stored value aborts before any delete")
    func storedValidityMismatchAborts() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [.found([], uidValidity: 8)], // all-gone BUT validity changed
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("UIDVALIDITY change mid-walk aborts — the changed chunk deletes nothing")
    func midWalkValidityChangeAborts() async {
        let recorder = WalkRecorder()
        // T4.S6b: stored is 7, NOT nil. Under the head-of-walk refusal a nil stored
        // epoch would abort before the first SEARCH, making this test vacuous — it
        // would still be green while proving nothing about the MID-WALK change it is
        // named for.
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 7,
            script: [
                .found([1, 2], uidValidity: 7),
                .found([], uidValidity: 9), // changed → abort
            ],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.deleteCalls.isEmpty)
        #expect(recorder.searchCalls.count == 2) // it really did reach the 2nd chunk
    }

    /// T4.S6b (supersedes "Nil stored UIDVALIDITY is bootstrapped exactly once from
    /// the first SELECT"). The walk no longer ADOPTS the first SELECT's epoch onto a
    /// folder whose rows nobody has verified — that adoption is precisely what made
    /// the stored-vs-live comparison equal by construction and turned the walk into
    /// an unguarded mass deleter. A nil stored epoch now REFUSES, before any SEARCH.
    ///
    /// RED-FIRST EVIDENCE — MEASURED 2026-07-31 with the adopt-and-delete branch
    /// restored in place (`var expectedValidity = knownUidValidity(storedUidValidity)…`
    /// at the head, plus an `expectedValidity = result.uidValidity` adopt arm in the
    /// chunk loop). Verbatim:
    ///
    /// ```
    /// ✘ Test "Nil stored UIDVALIDITY refuses the walk outright — no SEARCH, no delete"
    ///   recorded an issue at SyncEngineDeletionReconcileTests.swift:300:9:
    ///   Expectation failed: (outcome → DeletionReconcileOutcome(deletedCount: 0,
    ///   failedChunks: 0, searchedChunks: 2, aborted: false, abortReason: nil,
    ///   uidValidityMismatch: nil)).aborted → false
    ///   … :301:9: (outcome.abortReason → nil) == "epoch unverified"
    ///   … :303:9: (outcome.searchedChunks → 2) == 0
    ///   … :305:9: (recorder.searchCalls → [[1, 2], [3, 4]]).isEmpty → false
    /// ✘ Test "Stored UIDVALIDITY of 0 is 'unknown', not an epoch — the walk refuses"
    ///   … :322:9 … :323:9 … :324:9: (recorder.searchCalls → [[1, 2]]).isEmpty → false
    /// ✘ Test run with 24 tests in 2 suites failed after 1.523 seconds with 7 issues.
    /// ```
    ///
    /// `searchedChunks → 2` with `aborted → false` is the defect: the walk searched
    /// every chunk and judged each local UID against an epoch it had just invented.
    /// Every other test in this suite stayed green under that inversion.
    @Test("Nil stored UIDVALIDITY refuses the walk outright — no SEARCH, no delete")
    func nilStoredValidityRefusesTheWalk() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: nil,
            script: [
                .found([1, 2], uidValidity: 42),
                .found([3, 4], uidValidity: 42),
            ],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.abortReason == "epoch unverified")
        #expect(outcome.deletedCount == 0)
        #expect(outcome.searchedChunks == 0)
        // Not one round trip is spent: the refusal is at the head, not per chunk.
        #expect(recorder.searchCalls.isEmpty)
        #expect(recorder.deleteCalls.isEmpty)
    }

    /// A STORED 0 is structurally impossible (RFC 3501 types UIDVALIDITY as
    /// `nz-number`), but `knownUidValidity` treats it as "not reported" everywhere
    /// else, and the walk must agree — a 0 that read as a real epoch would compare
    /// unequal to every live value and, worse, could be reached by an `== 0` live
    /// side.
    @Test("Stored UIDVALIDITY of 0 is 'unknown', not an epoch — the walk refuses")
    func zeroStoredValidityRefusesTheWalk() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2], chunkSize: 2, storedUidValidity: 0,
            script: [.found([1, 2], uidValidity: 5)],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.abortReason == "epoch unverified")
        #expect(recorder.searchCalls.isEmpty)
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("Unreported live UIDVALIDITY (0) aborts — never delete on uncertainty")
    func zeroValidityAborts() async {
        let recorder = WalkRecorder()
        // Stored 5, NOT nil: the point of this test is the LIVE 0, which is only
        // reachable once the head-of-walk guard has been satisfied.
        let outcome = await runWalk(
            localUIDs: [1, 2], chunkSize: 2, storedUidValidity: 5,
            script: [.found([], uidValidity: 0)],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.abortReason == "uidValidity unreported")
        #expect(recorder.searchCalls.count == 1)
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("Delete failure (e.g. DB suspension) aborts the walk")
    func deleteFailureAborts() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 3,
            script: [
                .found([], uidValidity: 3),
                .found([], uidValidity: 3),
            ],
            recorder: recorder,
            deleteThrows: true
        )
        #expect(outcome.aborted)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.searchCalls.count == 1) // aborted before the second chunk
    }

    // MARK: Deletion circuit breaker (cap = expected mismatch + slack)

    @Test("deletions within the cap proceed across chunks")
    func deletionsWithinCapProceed() async {
        let recorder = WalkRecorder()
        // 4 UIDs, 2 chunks; server reports every UID gone → 4 ghosts, cap 4.
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 3,
            script: [
                .found([], uidValidity: 3),
                .found([], uidValidity: 3),
            ],
            recorder: recorder,
            maxDeletions: 4
        )
        #expect(!outcome.aborted)
        #expect(outcome.deletedCount == 4)
        #expect(recorder.deleteCalls.count == 2)
    }

    @Test("chunk that would exceed the cap aborts with nothing deleted from it")
    func capExceededAbortsBeforeOffendingChunk() async {
        let recorder = WalkRecorder()
        // Chunk 1 deletes 2 (within cap=3); chunk 2's 2 ghosts would total 4
        // > cap → abort BEFORE deleting anything from chunk 2. This is the
        // falsely-empty-SEARCH worst-case firewall.
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: 3,
            script: [
                .found([], uidValidity: 3),
                .found([], uidValidity: 3),
            ],
            recorder: recorder,
            maxDeletions: 3
        )
        #expect(outcome.aborted)
        #expect(outcome.abortReason?.contains("deletion cap exceeded") == true)
        #expect(outcome.deletedCount == 2)       // only chunk 1's ghosts
        #expect(recorder.deleteCalls.count == 1) // chunk 2 never reached deleteGhosts
    }

    @Test("first chunk larger than the cap deletes nothing at all")
    func capSmallerThanFirstChunkDeletesNothing() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 4, storedUidValidity: 3,
            script: [.found([], uidValidity: 3)],
            recorder: recorder,
            maxDeletions: 2
        )
        #expect(outcome.aborted)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("exactly-at-cap boundary is allowed")
    func exactCapBoundaryAllowed() async {
        let recorder = WalkRecorder()
        // 3 ghosts against cap 3 — boundary must pass (cap is inclusive).
        let outcome = await runWalk(
            localUIDs: [1, 2, 3], chunkSize: 3, storedUidValidity: 3,
            script: [.found([], uidValidity: 3)],
            recorder: recorder,
            maxDeletions: 3
        )
        #expect(!outcome.aborted)
        #expect(outcome.deletedCount == 3)
    }
}

// MARK: - Shared server-confirmed deletion path (in-memory GRDB)

@Suite("DeletionReconcile — shared deletion path")
struct DeletionReconcileDeletePathTests {

    private func makeImapFixture() throws -> (db: DatabaseQueue, folder: Folder) {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return (db, folder)
    }

    @Test("Deletes exactly the named UIDs; unknown UIDs are no-ops")
    func deletesNamedUIDsOnly() throws {
        let (db, folder) = try makeImapFixture()
        let kept = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: folder.id, accountId: "acc1", folderPath: folder.path
        )
        let doomed = try TestDatabase.insertMessageHeader(
            db, messageId: "101", folderId: folder.id, accountId: "acc1", folderPath: folder.path
        )
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: folder.id, folderPath: folder.path, accountId: "acc1",
                folderRole: .inbox, uids: [101, 999], // 999 unknown → no-op
                recentlyCompleted: [:], db: conn
            )
        }
        #expect(deletedIds == [doomed.id])
        let remaining = try db.read { try MessageHeader.fetchAll($0) }
        #expect(remaining.count == 1)
        guard remaining.count == 1 else { return }
        #expect(remaining[0].id == kept.id)
    }

    @Test("Empty UID set is a no-op")
    func emptyUIDSetNoOp() throws {
        let (db, folder) = try makeImapFixture()
        try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: folder.id, accountId: "acc1", folderPath: folder.path
        )
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: folder.id, folderPath: folder.path, accountId: "acc1",
                folderRole: .inbox, uids: [],
                recentlyCompleted: [:], db: conn
            )
        }
        #expect(deletedIds.isEmpty)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
    }

    @Test("Pending op keyed by rfc822 protects the row (source folder)")
    func pendingOpProtects() throws {
        let (db, folder) = try makeImapFixture()
        let rfc822 = "<pending-1@example.com>"
        try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: folder.id, accountId: "acc1",
            folderPath: folder.path, rfc822MessageId: EmailFilter.normalizeMessageId(rfc822)
        )
        try db.write { conn in
            var markReadOp = PendingOperation(
                type: .markRead,
                messageIds: [EmailFilter.normalizeMessageId(rfc822)],
                accountId: "acc1",
                folderPath: folder.path
            )
            try markReadOp.insert(conn)
        }
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: folder.id, folderPath: folder.path, accountId: "acc1",
                folderRole: .inbox, uids: [200],
                recentlyCompleted: [:], db: conn
            )
        }
        #expect(deletedIds.isEmpty)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
    }

    @Test("Pending op TARGETING this folder (destinationPath) protects the optimistically-moved row")
    func pendingOpDestinationProtects() throws {
        let (db, folder) = try makeImapFixture()
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        // Optimistic move Archive → INBOX: row sits in INBOX with the source UID.
        try TestDatabase.insertMessageHeader(
            db, messageId: "300", folderId: folder.id, accountId: "acc1", folderPath: folder.path
        )
        try db.write { conn in
            var moveOp = PendingOperation(
                type: .move,
                messageIds: ["300"],
                accountId: "acc1",
                folderPath: "Archive",
                destinationPath: folder.path
            )
            try moveOp.insert(conn)
        }
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: folder.id, folderPath: folder.path, accountId: "acc1",
                folderRole: .inbox, uids: [300],
                recentlyCompleted: [:], db: conn
            )
        }
        #expect(deletedIds.isEmpty)
    }

    @Test("Recently-completed op protects by messageId and by rfc822")
    func recentlyCompletedProtects() throws {
        let (db, folder) = try makeImapFixture()
        try TestDatabase.insertMessageHeader(
            db, messageId: "400", folderId: folder.id, accountId: "acc1", folderPath: folder.path
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "401", folderId: folder.id, accountId: "acc1",
            folderPath: folder.path, rfc822MessageId: "recent-401@example.com"
        )
        let now = Date()
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: folder.id, folderPath: folder.path, accountId: "acc1",
                folderRole: .inbox, uids: [400, 401],
                recentlyCompleted: ["400": now, "recent-401@example.com": now],
                db: conn
            )
        }
        #expect(deletedIds.isEmpty)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 2)
    }

    @Test("In-flight outbox send protects the optimistic Sent row")
    func outboxProtectsSentRow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        let sent = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        let rfc822 = "sent-1@example.com"
        try TestDatabase.insertMessageHeader(
            db, messageId: "500", folderId: sent.id, accountId: "acc1",
            folderPath: sent.path, isInInbox: false, rfc822MessageId: rfc822
        )
        try db.write { conn in
            var outbox = OutboxMessage(accountId: "acc1", draft: DraftMessage(to: ["peer@example.com"], subject: "Hi", body: "Hello"))
            outbox.sentMessageId = "<\(rfc822)>" // stored raw; the filter normalizes
            try outbox.insert(conn)
        }
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: sent.id, folderPath: sent.path, accountId: "acc1",
                folderRole: .sent, uids: [500],
                recentlyCompleted: [:], db: conn
            )
        }
        #expect(deletedIds.isEmpty)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 1)
    }

    @Test("Unprotected ghost with an unrelated pending op in ANOTHER folder is deleted")
    func unrelatedPendingOpDoesNotProtect() throws {
        let (db, folder) = try makeImapFixture()
        try TestDatabase.insertMessageHeader(
            db, messageId: "600", folderId: folder.id, accountId: "acc1", folderPath: folder.path
        )
        try db.write { conn in
            var markReadOp2 = PendingOperation(
                type: .markRead,
                messageIds: ["600"],
                accountId: "acc1",
                folderPath: "Archive" // different folder, not targeting INBOX
            )
            try markReadOp2.insert(conn)
        }
        let deletedIds = try db.write { conn in
            try SyncEngine.deleteConfirmedGhostHeaders(
                folderId: folder.id, folderPath: folder.path, accountId: "acc1",
                folderRole: .inbox, uids: [600],
                recentlyCompleted: [:], db: conn
            )
        }
        #expect(deletedIds.count == 1)
        #expect(try db.read { try MessageHeader.fetchCount($0) } == 0)
    }

    @Test("v63: Folder.lastKnownUidValidity round-trips through GRDB")
    func uidValidityColumnRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        let folder = try TestDatabase.insertFolder(db, accountId: "acc1")
        #expect(folder.lastKnownUidValidity == nil)
        try db.write { conn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(conn, Column("lastKnownUidValidity").set(to: 12345))
        }
        let reloaded = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(reloaded?.lastKnownUidValidity == 12345)
    }
}
