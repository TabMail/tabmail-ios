/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for `SyncEngine.canonicalizeLocalRows` — the fullSync upsert step that
/// re-keys optimistic-move remnants ("acct:<oldPath>:<msgId>" PKs whose
/// folderId/folderPath were updated in place) and merges duplicate rows that
/// historical insert paths left behind. Field evidence 2026-06-09: one Gmail
/// message as BOTH "acct:INBOX:gid" (remnant) and "acct:TRASH:gid" (sync row)
/// → phantom 2-member self-thread in Trash.
@Suite("Header Canonicalization (optimistic-move remnants)")
struct HeaderCanonicalizeTests {

    private let trashFolderId = "acc1:TRASH"
    private let trashPath = "TRASH"

    /// Insert a message into INBOX, then move it to TRASH the way
    /// `optimisticMoveToFolder` does — folderId/folderPath/isInInbox updated
    /// in place, PK left at "acc1:INBOX:<messageId>".
    private func insertRemnant(
        _ db: DatabaseQueue,
        messageId: String,
        actionTag: ActionTag? = nil,
        isRead: Bool = false
    ) throws -> MessageHeader {
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: messageId,
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX",
            isInInbox: true, isRead: isRead, actionTag: actionTag
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = 0 WHERE id = ?",
                arguments: [trashFolderId, trashPath, header.id]
            )
        }
        return try db.read { try MessageHeader.fetchOne($0, key: header.id)! }
    }

    /// Insert a message directly in TRASH with the canonical PK.
    private func insertCanonical(
        _ db: DatabaseQueue,
        messageId: String,
        isRead: Bool = false
    ) throws -> MessageHeader {
        try TestDatabase.insertMessageHeader(
            db, messageId: messageId,
            folderId: trashFolderId, accountId: "acc1", folderPath: trashPath,
            isInInbox: false, isRead: isRead
        )
    }

    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db) // INBOX
        try TestDatabase.insertFolder(db, name: "Trash", path: trashPath, role: .trash)
        return db
    }

    private func canonicalize(_ db: DatabaseQueue, messageId: String) throws -> (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?) {
        try db.write { dbConn in
            try SyncEngine.canonicalizeLocalRows(
                accountId: "acc1", folderPath: trashPath,
                folderId: trashFolderId, messageId: messageId,
                isInInbox: false, db: dbConn
            )
        }
    }

    @Test("Remnant-only row is re-keyed to the canonical PK, body preserved")
    func remnantOnlyIsRekeyed() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g1")
        #expect(remnant.id == "acc1:INBOX:g1")
        try TestDatabase.insertMessageBody(db, headerId: remnant.id, htmlContent: "<p>body</p>")
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?", arguments: [remnant.id])
        }

        let result = try canonicalize(db, messageId: "g1")

        #expect(result.ftsRekey?.oldId == "acc1:INBOX:g1")
        #expect(result.ftsRekey?.newId == "acc1:TRASH:g1")
        // The old id is RE-KEYED in FTS, not removed — it must not ride staleIds.
        #expect(result.removedIds.isEmpty)
        #expect(result.row?.id == "acc1:TRASH:g1")
        #expect(result.row?.folderPath == trashPath)

        let rows = try db.read { try MessageHeader.filter(Column("messageId") == "g1").fetchAll($0) }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == "acc1:TRASH:g1")
        // The FTS entry (incl. indexed body) rides the in-place re-key —
        // bodyComplete stays truthful, no refetch churn.
        #expect(rows[0].bodyComplete == true)
        // Body survived the re-key under the new id (CASCADE would have eaten it).
        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:TRASH:g1") }
        #expect(body?.htmlContent == "<p>body</p>")
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:g1") }
        #expect(oldBody == nil)
    }

    @Test("Confirmed-empty body keeps bodyComplete through a re-key")
    func confirmedEmptyBodyNotRequeued() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g6")
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 1, bodyEmptyConfirmed = 1 WHERE id = ?",
                arguments: [remnant.id]
            )
        }

        let result = try canonicalize(db, messageId: "g6")
        #expect(result.ftsRekey != nil)
        // Body flags ride the re-key untouched — no churn.
        let rows = try db.read { try MessageHeader.filter(Column("messageId") == "g6").fetchAll($0) }
        #expect(rows.first?.bodyComplete == true)
        #expect(rows.first?.bodyEmptyConfirmed == true)
    }

    @Test("Duplicate pair merges into the canonical row, AI state preserved")
    func duplicatePairMerged() throws {
        let db = try makeDB()
        // Remnant carries the AI state + body (it was the long-lived row).
        let remnant = try insertRemnant(db, messageId: "g2", actionTag: .reply, isRead: true)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ?, cachedReply = ? WHERE id = ?",
                arguments: ["the blurb", "the reply", remnant.id]
            )
        }
        try TestDatabase.insertMessageBody(db, headerId: remnant.id, htmlContent: "<p>rich</p>")
        // Canonical row from a later sync insert — fresh, no AI state.
        _ = try insertCanonical(db, messageId: "g2")

        let result = try canonicalize(db, messageId: "g2")

        #expect(result.ftsRekey == nil) // survivor was already canonical
        #expect(result.removedIds == ["acc1:INBOX:g2"])

        let rows = try db.read { try MessageHeader.filter(Column("messageId") == "g2").fetchAll($0) }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == "acc1:TRASH:g2")
        // AI/local state merged across from the remnant.
        #expect(rows[0].actionTag == .reply)
        #expect(rows[0].summaryBlurb == "the blurb")
        #expect(rows[0].cachedReply == "the reply")
        #expect(rows[0].isRead == true) // OR-merge: remnant was read
        // The remnant's body reattached under the canonical id.
        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:TRASH:g2") }
        #expect(body?.htmlContent == "<p>rich</p>")
        // Survivor keeps its OWN truthful bodyComplete (false — the canonical
        // row's FTS entry never had a body indexed); no OR-merge faking it.
        // The body pipeline picks it up naturally.
        #expect(rows[0].bodyComplete == false)
    }

    @Test("Clean canonical row is untouched")
    func cleanRowUntouched() throws {
        let db = try makeDB()
        let canonical = try insertCanonical(db, messageId: "g3")

        let result = try canonicalize(db, messageId: "g3")

        #expect(result.ftsRekey == nil)
        #expect(result.removedIds.isEmpty)
        #expect(result.row?.id == canonical.id)
        let count = try db.read { try MessageHeader.filter(Column("messageId") == "g3").fetchCount($0) }
        #expect(count == 1)
    }

    @Test("No local rows returns nil")
    func noRowsReturnsNil() throws {
        let db = try makeDB()
        let result = try canonicalize(db, messageId: "missing")
        #expect(result.row == nil)
        #expect(result.removedIds.isEmpty)
        #expect(result.ftsRekey == nil)
    }

    @Test("Re-key is skipped when the canonical PK is held by a row in another folder")
    func rekeySkippedOnCanonicalCollision() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g7")
        // A row holding the canonical PK but living in ANOTHER folder — a
        // message optimistically moved OUT of trash keeps its trash-keyed PK.
        let squatter = try TestDatabase.insertMessageHeader(
            db, messageId: "g7",
            folderId: trashFolderId, accountId: "acc1", folderPath: trashPath,
            isInInbox: false
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = 1 WHERE id = ?",
                arguments: ["acc1:INBOX", "INBOX", squatter.id]
            )
        }

        let result = try canonicalize(db, messageId: "g7")

        // No re-key (would collide), no data loss — remnant keeps its PK.
        #expect(result.ftsRekey == nil)
        #expect(result.row?.id == remnant.id)
        let count = try db.read { try MessageHeader.filter(Column("messageId") == "g7").fetchCount($0) }
        #expect(count == 2)
    }

    @Test("Canonical row keeps its own AI state when both rows carry one")
    func canonicalStateWinsOverRemnant() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g4", actionTag: .delete)
        _ = remnant
        // Canonical row already has its own tag — must NOT be overwritten.
        let canonical = try TestDatabase.insertMessageHeader(
            db, messageId: "g4",
            folderId: trashFolderId, accountId: "acc1", folderPath: trashPath,
            isInInbox: false, actionTag: .archive
        )
        _ = canonical

        let result = try canonicalize(db, messageId: "g4")
        #expect(result.row?.actionTag == .archive)
    }
}

// MARK: - SearchIndex.rekeyHeaders

/// The FTS-side primitive used by sync re-keys (UID remap, remnant
/// canonicalization): moves an entry to a new header id IN PLACE, keeping the
/// rowid — and with it the indexed body text and the embedding.
@Suite("SearchIndex rekeyHeaders", .serialized, .processGlobalState)
struct SearchIndexRekeyTests {

    private var index: SearchIndex { SearchIndex.shared }
    private let prefix = "test_rekey"

    private func makeRecord(_ headerId: String, subject: String) -> FTSHeaderRecord {
        FTSHeaderRecord(
            headerId: headerId, messageId: "m-\(headerId.suffix(4))",
            subject: subject,
            from: "a@a.com", to: "b@b.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000),
            folderId: "\(prefix):INBOX"
        )
    }

    @Test("rekey moves the entry — searchable under new id, body text preserved")
    func rekeyPreservesEntry() async throws {
        let oldId = "\(prefix)_mv:INBOX:1"
        let newId = "\(prefix)_mv:TRASH:1"
        try? await index.removeMessages(headerIds: [oldId, newId])

        _ = try await index.indexHeaders([makeRecord(oldId, subject: "Rekeymovetest unique subject")])
        _ = try await index.updateBodies([(headerId: oldId, body: "rekeybodytoken unmistakable content")])

        try await index.rekeyHeaders([(oldId: oldId, newId: newId, newMessageId: nil)])

        // Body text searchable, hit resolves to the NEW id; old id gone.
        let hits = try await index.keywordSearch(query: "rekeybodytoken")
        #expect(hits.contains { $0.headerId == newId })
        #expect(!hits.contains { $0.headerId == oldId })

        try? await index.removeMessages(headerIds: [oldId, newId])
    }

    @Test("rekey collision keeps the existing new-id entry and drops the old one")
    func rekeyCollisionDropsOld() async throws {
        let oldId = "\(prefix)_col:INBOX:1"
        let newId = "\(prefix)_col:TRASH:1"
        try? await index.removeMessages(headerIds: [oldId, newId])

        _ = try await index.indexHeaders([
            makeRecord(oldId, subject: "Rekeycollisionold unique subject"),
            makeRecord(newId, subject: "Rekeycollisionnew unique subject"),
        ])

        try await index.rekeyHeaders([(oldId: oldId, newId: newId, newMessageId: nil)])

        // The pre-existing new-id entry survives; the old entry is removed
        // (two FTS rows must never share a headerId).
        let newHits = try await index.keywordSearch(query: "rekeycollisionnew")
        #expect(newHits.contains { $0.headerId == newId })
        let oldHits = try await index.keywordSearch(query: "rekeycollisionold")
        #expect(oldHits.isEmpty)

        try? await index.removeMessages(headerIds: [oldId, newId])
    }
}
