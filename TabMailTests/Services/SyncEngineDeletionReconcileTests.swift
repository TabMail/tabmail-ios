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
    let persistedValidities = Mutex<[UInt32]>([])

    func recordSearch(_ chunk: [UInt32]) { searchedChunks.withLock { $0.append(chunk) } }
    func recordDelete(_ ghosts: [UInt32]) { deletedChunks.withLock { $0.append(ghosts) } }
    func recordPersist(_ v: UInt32) { persistedValidities.withLock { $0.append(v) } }

    var searchCalls: [[UInt32]] { searchedChunks.withLock { $0 } }
    var deleteCalls: [[UInt32]] { deletedChunks.withLock { $0 } }
    var persistCalls: [UInt32] { persistedValidities.withLock { $0 } }
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
        persistThrows: Bool = false
    ) async -> DeletionReconcileOutcome {
        let callIndex = Mutex<Int>(0)
        return await SyncEngine.runDeletionReconcileWalk(
            localUIDs: localUIDs,
            chunkSize: chunkSize,
            storedUidValidity: storedUidValidity,
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
                }
            },
            deleteGhosts: { ghosts in
                if deleteThrows { throw PlainSearchError() }
                recorder.recordDelete(ghosts)
                return ghosts.count
            },
            persistUidValidity: { v in
                if persistThrows { throw PlainSearchError() }
                recorder.recordPersist(v)
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
        #expect(recorder.persistCalls.isEmpty) // never overwrite the stored value
    }

    @Test("UIDVALIDITY change mid-walk aborts — the changed chunk deletes nothing")
    func midWalkValidityChangeAborts() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: nil,
            script: [
                .found([1, 2], uidValidity: 7),
                .found([], uidValidity: 9), // changed → abort
            ],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(outcome.deletedCount == 0)
        #expect(recorder.deleteCalls.isEmpty)
    }

    @Test("Nil stored UIDVALIDITY is bootstrapped exactly once from the first SELECT")
    func validityBootstrap() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2, 3, 4], chunkSize: 2, storedUidValidity: nil,
            script: [
                .found([1, 2], uidValidity: 42),
                .found([3, 4], uidValidity: 42),
            ],
            recorder: recorder
        )
        #expect(!outcome.aborted)
        #expect(recorder.persistCalls == [42])
    }

    @Test("Unreported UIDVALIDITY (0) aborts — never delete on uncertainty")
    func zeroValidityAborts() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2], chunkSize: 2, storedUidValidity: nil,
            script: [.found([], uidValidity: 0)],
            recorder: recorder
        )
        #expect(outcome.aborted)
        #expect(recorder.deleteCalls.isEmpty)
        #expect(recorder.persistCalls.isEmpty)
    }

    @Test("Persist failure aborts the walk")
    func persistFailureAborts() async {
        let recorder = WalkRecorder()
        let outcome = await runWalk(
            localUIDs: [1, 2], chunkSize: 2, storedUidValidity: nil,
            script: [.found([], uidValidity: 5)],
            recorder: recorder,
            persistThrows: true
        )
        #expect(outcome.aborted)
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
            try PendingOperation(
                type: .markRead,
                messageIds: [EmailFilter.normalizeMessageId(rfc822)],
                accountId: "acc1",
                folderPath: folder.path
            ).insert(conn)
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
            try PendingOperation(
                type: .move,
                messageIds: ["300"],
                accountId: "acc1",
                folderPath: "Archive",
                destinationPath: folder.path
            ).insert(conn)
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
            try PendingOperation(
                type: .markRead,
                messageIds: ["600"],
                accountId: "acc1",
                folderPath: "Archive" // different folder, not targeting INBOX
            ).insert(conn)
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
