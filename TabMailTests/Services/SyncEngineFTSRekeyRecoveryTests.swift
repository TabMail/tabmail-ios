/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Behavior tests for `SyncEngine.recoverPendingFTSRekeys()` — the retained
/// ordinary-sync GRDB-to-FTS crash journal keyed by
/// `MessageHeader.pendingFTSRekeySourceIdsJSON`. The marker is written by
/// `SyncEngineFullSync` canonicalization (full-sync survivor merges, UID-remap
/// merges) atomically with the header write; `SyncEngine.recoverPendingFTSRekeys`
/// is the real startup entry point that replays it. This is NOT queue/undo
/// receipt state (ADR-IOS-060 §11.3) — it predates and survives the durable
/// queue simplification.
///
/// Prior coverage (`DatabaseMigrationTests`) only pinned the schema/index
/// shape (column existence, sparse-index EXPLAIN QUERY PLAN). These tests
/// drive the real production recovery function end to end, following
/// `SelfHealBackfillFTSTests`' pattern: production `AppDatabase.dbPool` +
/// `SearchIndex.shared` singletons, unique account-scoped ids, explicit
/// cleanup.
@Suite(
    "SyncEngine.recoverPendingFTSRekeys — GRDB/FTS crash journal recovery",
    .serialized,
    .processGlobalState
)
struct SyncEngineFTSRekeyRecoveryTests {

    @Test("Populated marker (crash between GRDB commit and FTS re-key) is re-keyed and cleared")
    func recoversPopulatedMarker() async throws {
        let accountId = "ftsrekey-crash"
        let msgId = "crash-msg-1"
        let oldId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: msgId)
        let newId = MessageIdentity.headerId(accountId: accountId, folderPath: "Archive", messageId: msgId)
        try? await SearchIndex.shared.removeMessages(headerIds: [oldId, newId])

        // FTS still carries the PRE-crash entry under the old id, body indexed —
        // exactly what a crash between the GRDB commit (below) and the FTS
        // rekey call would leave behind.
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(
                headerId: oldId, messageId: msgId, subject: "stale subject", from: "a@x", to: "b@x",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX")
            )
        ])
        _ = try await SearchIndex.shared.updateBodies([(headerId: oldId, body: "the recoverable body text")])

        // GRDB already committed the header under its CURRENT (post-move) id,
        // carrying the durable re-key obligation for the old id — the "GRDB
        // commit landed, FTS rekey did not run yet" crash shape.
        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "crash@example.com", displayName: "T", provider: .gmail)
                account.id = accountId
                try account.insert(db)
            }
            let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: "Archive")
            if try Folder.fetchOne(db, key: folderId) == nil {
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId).insert(db)
            }
            var header = MessageHeader(
                messageId: msgId, subject: "current subject", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "", folderId: folderId, accountId: accountId,
                folderPath: "Archive", isInInbox: false
            )
            header.pendingFTSRekeySourceIds = [oldId]
            try header.insert(db)
        }

        // Preconditions: the new id is not yet indexed, and the marker is set.
        #expect(try await SearchIndex.shared.headerIdsMissingFromFTS([newId]).contains(newId))
        let markerBefore: String? = try await AppDatabase.dbPool.read { db in
            try String.fetchOne(
                db, sql: "SELECT pendingFTSRekeySourceIdsJSON FROM messageHeader WHERE id = ?",
                arguments: [newId]
            )
        }
        #expect(markerBefore != nil, "precondition: marker must be set")

        let engine = SyncEngine()
        await engine.recoverPendingFTSRekeys()

        // The FTS row moved to the current id, preserving its body — not a
        // fresh empty re-index of the new id.
        let missing = try await SearchIndex.shared.headerIdsMissingFromFTS([oldId, newId])
        #expect(missing.contains(oldId), "stale id must be gone from FTS")
        #expect(!missing.contains(newId), "current id must be indexed after recovery")
        let body = try await SearchIndex.shared.bodyText(headerId: newId)
        #expect(body == "the recoverable body text", "recovery must preserve the indexed body, not discard it")

        // The durable marker is cleared only after FTS convergence was verified.
        let markerAfter: String? = try await AppDatabase.dbPool.read { db in
            try String.fetchOne(
                db, sql: "SELECT pendingFTSRekeySourceIdsJSON FROM messageHeader WHERE id = ?",
                arguments: [newId]
            )
        }
        #expect(markerAfter == nil, "marker must be cleared once FTS has converged")

        try? await SearchIndex.shared.removeMessages(headerIds: [oldId, newId])
        try? await AppDatabase.dbPool.write { db in _ = try Account.deleteOne(db, key: accountId) }
    }

    @Test("Empty journal (no pending markers) is a no-op — unrelated FTS state is untouched")
    func emptyJournalIsNoOp() async throws {
        let accountId = "ftsrekey-noop"
        let msgId = "noop-msg-1"
        let headerId = MessageIdentity.headerId(accountId: accountId, folderPath: "INBOX", messageId: msgId)
        try? await SearchIndex.shared.removeMessages(headerIds: [headerId])

        try await AppDatabase.dbPool.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var account = Account(emailAddress: "noop@example.com", displayName: "T", provider: .gmail)
                account.id = accountId
                try account.insert(db)
            }
            let folderId = MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX")
            if try Folder.fetchOne(db, key: folderId) == nil {
                try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
            }
            // No pendingFTSRekeySourceIdsJSON — the ordinary steady state.
            let header = MessageHeader(
                messageId: msgId, subject: "untouched subject", from: "a@x", fromAddress: "a@x", to: "b@x",
                date: Date(), snippet: "", folderId: folderId, accountId: accountId,
                folderPath: "INBOX", isInInbox: true
            )
            try header.insert(db)
        }
        _ = try await SearchIndex.shared.indexHeaders([
            FTSHeaderRecord(
                headerId: headerId, messageId: msgId, subject: "untouched subject", from: "a@x", to: "b@x",
                dateMs: Int64(Date().timeIntervalSince1970 * 1000),
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX")
            )
        ])
        _ = try await SearchIndex.shared.updateBodies([(headerId: headerId, body: "steady state body")])

        let engine = SyncEngine()
        await engine.recoverPendingFTSRekeys()

        // Nothing to recover — the unrelated, unmarked row's FTS entry survives
        // byte-identical.
        let missing = try await SearchIndex.shared.headerIdsMissingFromFTS([headerId])
        #expect(!missing.contains(headerId))
        let body = try await SearchIndex.shared.bodyText(headerId: headerId)
        #expect(body == "steady state body")

        try? await SearchIndex.shared.removeMessages(headerIds: [headerId])
        try? await AppDatabase.dbPool.write { db in _ = try Account.deleteOne(db, key: accountId) }
    }
}
