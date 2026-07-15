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
        actionTagSetAt: Date? = nil,
        isRead: Bool = false
    ) throws -> MessageHeader {
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: messageId,
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX",
            isInInbox: true, isRead: isRead, actionTag: actionTag,
            actionTagSetAt: actionTagSetAt
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

    private func canonicalize(
        _ db: DatabaseQueue,
        messageId: String
    ) throws -> (
        row: MessageHeader?,
        removedIds: [String],
        ftsRekeys: [(oldId: String, newId: String)]
    ) {
        try db.write { dbConn in
            try SyncEngine.canonicalizeLocalRows(
                accountId: "acc1", folderPath: trashPath,
                folderId: trashFolderId, messageId: messageId,
                isInInbox: false, db: dbConn
            )
        }
    }

    private func attachmentJSON(_ attachments: [AttachmentInfo]) throws -> String {
        let data = try JSONEncoder().encode(attachments)
        return try #require(String(data: data, encoding: .utf8))
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

        #expect(result.ftsRekeys.count == 1)
        guard result.ftsRekeys.count == 1 else { return }
        #expect(result.ftsRekeys[0].oldId == "acc1:INBOX:g1")
        #expect(result.ftsRekeys[0].newId == "acc1:TRASH:g1")
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
        #expect(!result.ftsRekeys.isEmpty)
        // Body flags ride the re-key untouched — no churn.
        let rows = try db.read { try MessageHeader.filter(Column("messageId") == "g6").fetchAll($0) }
        #expect(rows.first?.bodyComplete == true)
        #expect(rows.first?.bodyEmptyConfirmed == true)
    }

    @Test("Duplicate pair merges into the canonical row, action tag is retained (Round D-0)")
    func duplicatePairMerged() throws {
        let db = try makeDB()
        // Remnant carries the AI state + body (it was the long-lived row).
        // actionTagSetAt is a few days old and deliberately NOT "now" — proves
        // `mergeLocalIdentityFields` CARRIES the source's stamp onto the
        // survivor instead of re-stamping it fresh (Round D-0b TTL semantics).
        let remnantActionTagSetAt = Date().addingTimeInterval(-3 * 86_400)
        let remnant = try insertRemnant(
            db, messageId: "g2", actionTag: .reply,
            actionTagSetAt: remnantActionTagSetAt, isRead: true
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ?, cachedReply = ?, notified = 1 WHERE id = ?",
                arguments: ["the blurb", "the reply", remnant.id]
            )
            try UserLabel(id: "label-remnant", accountId: "acc1", name: "Remnant", isSystem: false)
                .insert(dbConn)
            try UserLabel(id: "label-canonical", accountId: "acc1", name: "Canonical", isSystem: false)
                .insert(dbConn)
            try MessageUserLabel(
                messageId: remnant.id,
                accountId: "acc1",
                userLabelId: "label-remnant"
            )
                .insert(dbConn)
            try MessageReference(
                messageHeaderId: remnant.id,
                referencedRfc822Id: "<remnant-ref@example.com>"
            ).insert(dbConn)
        }
        try TestDatabase.insertMessageBody(db, headerId: remnant.id, htmlContent: "<p>rich</p>")
        // Canonical row from a later sync insert — fresh, no AI state.
        let canonical = try insertCanonical(db, messageId: "g2")
        try TestDatabase.insertMessageBody(db, headerId: canonical.id, htmlContent: "")
        try db.write { dbConn in
            try MessageUserLabel(
                messageId: canonical.id,
                accountId: "acc1",
                userLabelId: "label-canonical"
            )
                .insert(dbConn)
            try MessageReference(
                messageHeaderId: canonical.id,
                referencedRfc822Id: "<canonical-ref@example.com>"
            ).insert(dbConn)
        }

        let result = try canonicalize(db, messageId: "g2")

        #expect(result.ftsRekeys.count == 1)
        guard result.ftsRekeys.count == 1 else { return }
        #expect(result.ftsRekeys[0].oldId == "acc1:INBOX:g2")
        #expect(result.ftsRekeys[0].newId == "acc1:TRASH:g2")
        #expect(result.removedIds == ["acc1:INBOX:g2"])

        let rows = try db.read { try MessageHeader.filter(Column("messageId") == "g2").fetchAll($0) }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == "acc1:TRASH:g2")
        // The canonical survivor is outside Inbox, but Round D-0 retains the
        // local-only action tag regardless of folder — it merges in from the
        // remnant exactly like the other local-only AI state.
        #expect(rows[0].actionTag == .reply)
        #expect(rows[0].tagSortOrder == ActionTag.reply.sortOrder)
        // Round D-0b: the survivor's actionTagSetAt is CARRIED from the
        // remnant, not re-stamped to the merge's own wall-clock time.
        let survivorSetAt = try #require(rows[0].actionTagSetAt)
        #expect(abs(survivorSetAt.timeIntervalSince(remnantActionTagSetAt)) < 1)
        #expect(rows[0].summaryBlurb == "the blurb")
        #expect(rows[0].cachedReply == "the reply")
        // Independently mutable user-intention fields are not OR-merged. The
        // canonical generation remains authoritative unless the production caller
        // supplies an exact pending/recent value through `fieldAuthority`.
        #expect(rows[0].isRead == false)
        #expect(rows[0].notified == true)
        // The remnant's body reattached under the canonical id.
        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:TRASH:g2") }
        #expect(body?.htmlContent == "<p>rich</p>")
        let labels = try db.read { dbConn in
            try MessageUserLabel
                .filter(Column("messageId") == rows[0].id)
                .fetchAll(dbConn)
                .map(\.userLabelId)
        }
        #expect(Set(labels) == ["label-remnant", "label-canonical"])
        let references = try db.read { dbConn in
            try MessageReference
                .filter(Column("messageHeaderId") == rows[0].id)
                .fetchAll(dbConn)
                .map(\.referencedRfc822Id)
        }
        #expect(Set(references) == [
            "<remnant-ref@example.com>",
            "<canonical-ref@example.com>",
        ])
        // Survivor keeps its OWN truthful bodyComplete (false — the canonical
        // row's FTS entry never had a body indexed); no OR-merge faking it.
        // The body pipeline picks it up naturally.
        #expect(rows[0].bodyComplete == false)
    }

    /// Round G candidate 1 (`MessageBody.merged`): complementary body/attachment
    /// fields from two identity-proven duplicate rows must both survive a merge.
    @Test("Duplicate bodies merge complementary HTML, calendar, attachments, and freshness field by field")
    func duplicateBodiesMergeComplementaryFields() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g-body-fields")
        let canonical = try insertCanonical(db, messageId: "g-body-fields")
        let now = Date()
        let older = now.addingTimeInterval(-120)
        let newest = now.addingTimeInterval(-15)

        let remnantOnly = AttachmentInfo(
            filename: "report.pdf", contentType: "application/pdf",
            section: "2", size: 2048, encoding: "base64"
        )
        let canonicalOnly = AttachmentInfo(
            filename: "agenda.ics", contentType: "text/calendar",
            section: "1", size: 512, encoding: nil
        )
        let shared = AttachmentInfo(
            filename: "shared.txt", contentType: "text/plain",
            section: "3", size: 128, encoding: "quoted-printable"
        )

        var remnantBody = MessageBody(
            headerId: remnant.id,
            htmlContent: "<p>This is the longest rendered HTML body.</p>"
        )
        remnantBody.attachmentsJSON = try attachmentJSON([remnantOnly, shared])
        remnantBody.fetchedAt = older
        remnantBody.icsText = "BEGIN:VCALENDAR\nEND:VCALENDAR"

        var canonicalBody = MessageBody(
            headerId: canonical.id,
            htmlContent: "<p>short</p>"
        )
        canonicalBody.attachmentsJSON = try attachmentJSON([shared, canonicalOnly])
        canonicalBody.fetchedAt = newest
        canonicalBody.icsText = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Longer calendar payload
        END:VEVENT
        END:VCALENDAR
        """
        try db.write { dbConn in
            try remnantBody.insert(dbConn)
            try canonicalBody.insert(dbConn)
        }

        _ = try canonicalize(db, messageId: "g-body-fields")

        let merged = try #require(try db.read {
            try MessageBody.fetchOne($0, key: canonical.id)
        })
        #expect(merged.htmlContent == remnantBody.htmlContent)
        #expect(merged.icsText == canonicalBody.icsText)
        #expect(abs(merged.fetchedAt.timeIntervalSince(newest)) < 0.001)
        let attachments = merged.attachments
        #expect(attachments.count == 3)
        guard attachments.count == 3 else { return }
        #expect(attachments.map(\.section) == ["1", "2", "3"],
                "attachment union is de-duplicated and encoded in stable key order")
        #expect(attachments.map(\.filename) == ["agenda.ics", "report.pdf", "shared.txt"])
    }

    @Test("Malformed nonempty attachment JSON rolls back canonicalization and preserves every source row and body")
    func malformedAttachmentJSONRollsBackCanonicalization() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g-malformed-body")
        let canonical = try insertCanonical(db, messageId: "g-malformed-body")

        var remnantBody = MessageBody(headerId: remnant.id, htmlContent: "<p>remnant</p>")
        remnantBody.attachmentsJSON = try attachmentJSON([
            AttachmentInfo(
                filename: "valid.pdf", contentType: "application/pdf",
                section: "1", size: 1024, encoding: "base64"
            ),
        ])
        var canonicalBody = MessageBody(headerId: canonical.id, htmlContent: "<p>canonical</p>")
        canonicalBody.attachmentsJSON = "{malformed-nonempty-json"
        try db.write { dbConn in
            try remnantBody.insert(dbConn)
            try canonicalBody.insert(dbConn)
        }

        #expect(throws: MessageBodyMergeError.self) {
            _ = try canonicalize(db, messageId: "g-malformed-body")
        }

        let rows = try db.read {
            try MessageHeader
                .filter(Column("messageId") == "g-malformed-body")
                .fetchAll($0)
        }
        #expect(rows.count == 2)
        let preservedRemnant = try db.read { try MessageBody.fetchOne($0, key: remnant.id) }
        let preservedCanonical = try db.read { try MessageBody.fetchOne($0, key: canonical.id) }
        #expect(preservedRemnant?.htmlContent == remnantBody.htmlContent)
        #expect(preservedRemnant?.attachmentsJSON == remnantBody.attachmentsJSON)
        #expect(preservedCanonical?.htmlContent == canonicalBody.htmlContent)
        #expect(preservedCanonical?.attachmentsJSON == canonicalBody.attachmentsJSON)
    }

    /// Round G candidate 2 (full-sync canonicalization): every independently
    /// proven old-to-survivor re-key must reach the FTS channel, not just one.
    @Test("Every duplicate loser emits an FTS rekey to the final survivor")
    func multipleDuplicateLosersEmitFtsRekeys() throws {
        let db = try makeDB()
        let firstLoser = try insertRemnant(db, messageId: "g-many-losers")
        let secondLoser = try TestDatabase.insertMessageHeader(
            db, messageId: "g-many-losers",
            folderId: trashFolderId, accountId: "acc1", folderPath: "Legacy",
            isInInbox: false
        )
        let canonical = try insertCanonical(db, messageId: "g-many-losers")

        let result = try canonicalize(db, messageId: "g-many-losers")

        let loserIds = Set([firstLoser.id, secondLoser.id])
        #expect(Set(result.removedIds) == loserIds)
        #expect(result.ftsRekeys.count == 2)
        let emitted = Set(result.ftsRekeys.map { "\($0.oldId)->\($0.newId)" })
        #expect(emitted == Set(loserIds.map { "\($0)->\(canonical.id)" }))
        #expect(result.ftsRekeys.allSatisfy { $0.newId == canonical.id })

        let rows = try db.read {
            try MessageHeader
                .filter(Column("messageId") == "g-many-losers")
                .fetchAll($0)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == canonical.id)
    }

    @Test("Clean canonical row is untouched")
    func cleanRowUntouched() throws {
        let db = try makeDB()
        let canonical = try insertCanonical(db, messageId: "g3")

        let result = try canonicalize(db, messageId: "g3")

        #expect(result.ftsRekeys.isEmpty)
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
        #expect(result.ftsRekeys.isEmpty)
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
        #expect(result.ftsRekeys.isEmpty)
        #expect(result.row?.id == remnant.id)
        let count = try db.read { try MessageHeader.filter(Column("messageId") == "g7").fetchCount($0) }
        #expect(count == 2)
    }

    @Test("Canonical non-inbox row RETAINS its own action tag after merge (Round D-0) — the remnant's tag never overwrites a non-nil target")
    func canonicalStateWinsOverRemnant() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g4", actionTag: .delete)
        _ = remnant
        // The canonical row already carries its OWN tag outside Inbox — Round
        // D-0 retains it regardless of folder, and `mergeLocalIdentityFields`
        // only fills a NIL target from a duplicate, so the remnant's
        // `.delete` must not overwrite the canonical's `.archive`.
        let canonical = try TestDatabase.insertMessageHeader(
            db, messageId: "g4",
            folderId: trashFolderId, accountId: "acc1", folderPath: trashPath,
            isInInbox: false, actionTag: .archive
        )
        _ = canonical

        let result = try canonicalize(db, messageId: "g4")
        #expect(result.row?.actionTag == .archive, "the canonical row's own tag is retained, not cleared for being outside the inbox")
        #expect(result.row?.tagSortOrder == ActionTag.archive.sortOrder)
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

    /// Round G candidate 5 (FTS collision selection): the richer body/vector
    /// must win a rekey collision, not whichever generation happened to land first.
    @Test("rekey collision preserves the old indexed body when the new id is header-only")
    func rekeyCollisionPreservesRicherOldBody() async throws {
        let oldId = "\(prefix)_rich:INBOX:1"
        let newId = "\(prefix)_rich:TRASH:1"
        try? await index.removeMessages(headerIds: [oldId, newId])

        _ = try await index.indexHeaders([
            makeRecord(oldId, subject: "Old body carrier"),
            makeRecord(newId, subject: "New skeletal header"),
        ])
        _ = try await index.updateBodies([(
            headerId: oldId,
            body: "receiptcollisionbodytoken body and vector must follow identity"
        )])

        try await index.rekeyHeaders([(
            oldId: oldId,
            newId: newId,
            newMessageId: "graph-current-id"
        )])

        #expect(try await index.bodyText(headerId: newId)?.contains(
            "receiptcollisionbodytoken"
        ) == true)
        #expect(try await index.isIndexed(headerId: oldId) == false)
        let hits = try await index.keywordSearch(query: "receiptcollisionbodytoken")
        #expect(hits.contains { $0.headerId == newId })

        try? await index.removeMessages(headerIds: [oldId, newId])
    }

    /// Round G candidate 4 (`SearchIndex.rekeyHeaders` self-rekey): rekeying an
    /// id to itself must be an explicit no-op, not a collision-delete of the row.
    @Test("self rekey is an explicit no-op that preserves body and embedding")
    func rekeySelfPreservesEntry() async throws {
        let headerId = "\(prefix)_self:INBOX:1"
        try? await index.removeMessages(headerIds: [headerId])

        _ = try await index.indexHeaders([
            makeRecord(headerId, subject: "Self rekey subject token")
        ])
        _ = try await index.updateBodies([(
            headerId: headerId,
            body: "selfrekeybodytoken must survive"
        )])
        try await index.storeEmbedding(
            headerId: headerId,
            embedding: [Float](repeating: 0.75, count: SearchConfig.embeddingDims)
        )
        let rowid = try #require(try await index.testRowidForHeader(headerId))

        try await index.rekeyHeaders([(
            oldId: headerId,
            newId: headerId,
            newMessageId: "must-not-rewrite-self"
        )])

        #expect(try await index.isIndexed(headerId: headerId))
        #expect(try await index.bodyText(headerId: headerId)
                == "selfrekeybodytoken must survive")
        #expect(try await index.testRowidForHeader(headerId) == rowid)
        #expect(try await index.testHasEmbeddingForHeader(headerId))

        try await index.removeMessages(headerIds: [headerId])
    }
}
