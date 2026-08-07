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

    /// These fixtures model a stable-id provider, where the native message id
    /// itself proves ownership and no IMAP epoch is involved.
    private func canonicalize(
        _ db: DatabaseQueue,
        messageId: String
    ) throws -> (row: MessageHeader?, removedIds: [String], ftsRekey: (oldId: String, newId: String)?, sourceAddressProven: Bool) {
        try db.write { dbConn in
            try SyncEngine.canonicalizeLocalRows(
                accountId: "acc1", folderPath: trashPath,
                folderId: trashFolderId, messageId: messageId,
                isInInbox: false, windowMode: .date,
                sourceBoundEpoch: nil,
                incomingRfc822Identity: nil, db: dbConn
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
        // The body moved to the new id, and — the NEW failure mode — left NO row
        // behind under the old one.
        //
        // ⚠ Both halves used to be satisfied by the FK cascade firing on the
        // canonicalizer's delete+reinsert. Stage D (`v70_dropMessageBodyHeaderFK`)
        // removed that cascade, so the second half now depends entirely on the
        // explicit `MessageBody.deleteOne` the re-key leg gained. The count
        // assertion makes a leftover visible as a DUPLICATE, not just as a
        // survivor.
        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:TRASH:g1") }
        #expect(body?.htmlContent == "<p>body</p>")
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:g1") }
        #expect(oldBody == nil, "a leftover body under the pre-re-key id is a duplicate AND a leak")
        let totalBodies = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageBody") ?? -1
        }
        #expect(totalBodies == 1, "the re-key must MOVE the body, not copy it")
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

    // MARK: - R17-1 — a header primary-key change must carry its FK children

    /// Give a header a user label and a threading edge to `parentRfc`, the two
    /// child tables that declare `.references("messageHeader", onDelete: .cascade)`
    /// and are therefore destroyed by any delete of the parent row.
    private func attachChildren(
        _ db: DatabaseQueue,
        headerId: String,
        labelId: String,
        parentRfc: String
    ) throws {
        try db.write { dbConn in
            var header = try MessageHeader.fetchOne(dbConn, key: headerId)!
            header.inReplyTo = parentRfc
            try header.update(dbConn)
            let label = UserLabel(
                accountId: "acc1", providerLabelId: labelId, name: labelId, isSystem: false)
            try label.insert(dbConn, onConflict: .ignore)
            try MessageUserLabel(messageId: headerId, userLabelId: label.id).insert(dbConn)
            try ThreadUtils.insertMessageReferences(for: header, db: dbConn)
        }
    }

    private func labelIds(_ db: DatabaseQueue, headerId: String) throws -> [String] {
        try db.read {
            try MessageUserLabel
                .filter(Column("messageId") == headerId)
                .fetchAll($0)
                .map(\.userLabelId)
                .sorted()
        }
    }

    private func threadEdges(_ db: DatabaseQueue, headerId: String) throws -> [String] {
        try db.read {
            try String.fetchAll(
                $0,
                sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ? ORDER BY 1",
                arguments: [headerId])
        }
    }

    /// 🚨 THE INVARIANT, stated as the system property rather than the mechanism
    /// (`MIS-015`): **a header that changes its primary key keeps its labels and
    /// its threading edges.** No assertion below names `MessageHeaderRekey.apply`
    /// — any carrier that leaves both children reachable at the address the
    /// message now has will pass.
    ///
    /// `canonicalizeLocalRows`' `willRekey` leg is a member of the class *"every
    /// code path that changes a header's primary key"*, and it hand-rolled
    /// `delete` → reassign `id` → `insert`. `messageHeader` has exactly two
    /// surviving cascading children — `messageUserLabel.messageId` (`v82`) and
    /// `messageReference.messageHeaderId` (`v27`) — and the re-insert restored
    /// NEITHER. The label loss is permanent: nothing else in the database knows
    /// which labels the user applied. The edge loss drops the message out of its
    /// own conversation, and the existing-row merge branch in `runSyncMessages`
    /// updates `referencesJSON` without ever calling
    /// `ThreadUtils.insertMessageReferences`, so nothing rebuilt it either.
    ///
    /// Asserted at the STORE, as end state, against the NEW key — which also
    /// proves the carry landed on the re-keyed address rather than merely that
    /// some row survived somewhere.
    @Test("A canonicalizing re-key carries the message's labels and threading edges")
    func rekeyCarriesLabelsAndThreadEdges() throws {
        let db = try makeDB()
        let remnant = try insertRemnant(db, messageId: "g20")
        let parentRfc = "r17-1-parent@example.com"
        try attachChildren(db, headerId: remnant.id, labelId: "follow-up", parentRfc: parentRfc)

        // MIS-030 — anchor the fixture BEFORE the act: the precondition really
        // holds, so a later `== 0`/`isEmpty` cannot pass on a row that never had
        // children in the first place.
        #expect(remnant.id == "acc1:INBOX:g20")
        #expect(try labelIds(db, headerId: remnant.id) == ["acc1:follow-up"],
                "precondition: the user applied a label to the remnant")
        #expect(try threadEdges(db, headerId: remnant.id) == [parentRfc],
                "precondition: the remnant has a threading edge to its parent")

        let result = try canonicalize(db, messageId: "g20")

        #expect(result.ftsRekey?.oldId == "acc1:INBOX:g20")
        #expect(result.ftsRekey?.newId == "acc1:TRASH:g20")
        #expect(result.row?.id == "acc1:TRASH:g20")

        #expect(try labelIds(db, headerId: "acc1:TRASH:g20") == ["acc1:follow-up"],
                """
                the user's label must follow the message to its canonical address — \
                the re-key's delete cascades `messageUserLabel` and NOTHING in the \
                database can rebuild it, so a re-key that does not carry it destroys \
                the label silently and permanently
                """)
        #expect(try threadEdges(db, headerId: "acc1:TRASH:g20") == [parentRfc],
                """
                and the threading edge must exist at the canonical address, or the \
                message falls out of the conversation it belongs to
                """)
        #expect(try labelIds(db, headerId: "acc1:INBOX:g20").isEmpty,
                "and nothing may be left filed under the retired id")
        #expect(try threadEdges(db, headerId: "acc1:INBOX:g20").isEmpty)
    }

    /// 🚨 **THE MIRROR IMAGE, AND IT WOULD BE STRICTLY WORSE THAN THE BUG
    /// (`MIS-005`).** The merge loop above the re-key deletes duplicate LOSERS,
    /// and **their** cascade loss is INTENDED — they are being discarded, not
    /// re-addressed. Only the survivor's `delete → reassign id → insert` is an
    /// address change wearing a deletion's clothes.
    ///
    /// A "restore the cascaded children" fix applied across the whole function
    /// would let distinct duplicates donate unrelated labels to the survivor:
    /// label misattribution across messages, which no sync repairs because both
    /// the junction row and the label are locally authoritative. This test is the
    /// other side of `rekeyCarriesLabelsAndThreadEdges` and the pair is
    /// two-sided by construction (`feedback_non_vacuity_must_be_two_sided`) —
    /// the survivor's own label must arrive, the loser's must not.
    @Test("A merge loser's labels are never grafted onto the re-keyed survivor")
    func loserLabelsAreNotGraftedOntoSurvivor() throws {
        let db = try makeDB()
        // Two non-canonical rows for the same (messageId, folderId): the first
        // inserted is the survivor, the second is a merge loser. Neither holds
        // the canonical PK, so the survivor's leg re-keys.
        let survivorRemnant = try insertRemnant(db, messageId: "g21")
        let loser = try TestDatabase.insertMessageHeader(
            db, messageId: "g21",
            folderId: "acc1:ARCHIVE", accountId: "acc1", folderPath: "ARCHIVE",
            isInInbox: false
        )
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = 0 WHERE id = ?",
                arguments: [trashFolderId, trashPath, loser.id]
            )
        }
        try attachChildren(
            db, headerId: survivorRemnant.id, labelId: "mine", parentRfc: "r17-1-mine@example.com")
        try attachChildren(
            db, headerId: loser.id, labelId: "not-mine", parentRfc: "r17-1-not-mine@example.com")

        // MIS-030 — anchor both fixtures, and anchor that they are DISTINCT rows.
        #expect(survivorRemnant.id == "acc1:INBOX:g21")
        #expect(loser.id == "acc1:ARCHIVE:g21")
        #expect(try labelIds(db, headerId: survivorRemnant.id) == ["acc1:mine"])
        #expect(try labelIds(db, headerId: loser.id) == ["acc1:not-mine"])

        let result = try canonicalize(db, messageId: "g21")

        #expect(result.row?.id == "acc1:TRASH:g21")
        #expect(result.removedIds == ["acc1:ARCHIVE:g21"])
        #expect(try labelIds(db, headerId: "acc1:TRASH:g21") == ["acc1:mine"],
                """
                the survivor keeps EXACTLY its own label. `acc1:not-mine` appearing \
                here is the mirror-image failure: a discarded duplicate donating a \
                label to a message the user never applied it to — misattribution, and \
                nothing in sync repairs it because both the junction row and the label \
                are locally authoritative
                """)
        #expect(try threadEdges(db, headerId: "acc1:TRASH:g21") == ["r17-1-mine@example.com"],
                "and the survivor's own threading edge, not the loser's")
        #expect(try labelIds(db, headerId: "acc1:ARCHIVE:g21").isEmpty,
                "the loser's junction rows go with the loser — its cascade loss is INTENDED")
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
        FTSHeaderRecord( contentKey: ContentKey(rawValue: headerId),
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
        try? await index.removeMessages( contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))

        _ = try await index.indexHeaders([makeRecord(oldId, subject: "Rekeymovetest unique subject")])
        _ = try await index.updateBodies([(headerId: oldId, body: "rekeybodytoken unmistakable content")].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })

        try await index.rekeyHeaders([(oldId: oldId, newId: newId, newMessageId: nil)].map { (oldKey: ContentKey(rawValue: $0.oldId), newKey: ContentKey(rawValue: $0.newId), newMessageId: $0.newMessageId) })

        // Body text searchable, hit resolves to the NEW id; old id gone.
        let hits = try await index.keywordSearch(query: "rekeybodytoken")
        #expect(hits.contains { $0.contentKey.rawValue == newId })
        #expect(!hits.contains { $0.contentKey.rawValue == oldId })

        try? await index.removeMessages( contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))
    }

    @Test("rekey collision keeps the existing new-id entry and drops the old one")
    func rekeyCollisionDropsOld() async throws {
        let oldId = "\(prefix)_col:INBOX:1"
        let newId = "\(prefix)_col:TRASH:1"
        try? await index.removeMessages( contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))

        _ = try await index.indexHeaders([
            makeRecord(oldId, subject: "Rekeycollisionold unique subject"),
            makeRecord(newId, subject: "Rekeycollisionnew unique subject"),
        ])

        try await index.rekeyHeaders([(oldId: oldId, newId: newId, newMessageId: nil)].map { (oldKey: ContentKey(rawValue: $0.oldId), newKey: ContentKey(rawValue: $0.newId), newMessageId: $0.newMessageId) })

        // The pre-existing new-id entry survives; the old entry is removed
        // (two FTS rows must never share a headerId). Both entries here are
        // header-only, so the richness compare is a TIE and the tie keeps the
        // pre-existing new-key entry — the behaviour this test always pinned.
        let newHits = try await index.keywordSearch(query: "rekeycollisionnew")
        #expect(newHits.contains { $0.contentKey.rawValue == newId })
        let oldHits = try await index.keywordSearch(query: "rekeycollisionold")
        #expect(oldHits.isEmpty)

        try? await index.removeMessages( contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))
    }

    // MARK: - Collisions resolve by CONTENT, not by arrival order

    /// THE INVARIANT: a re-key collision never destroys the pair's indexed body or
    /// embedding. Exactly one of the two entries must go — `message_ids.headerId` is
    /// the primary key — but which one is a content question. Dropping the old entry
    /// unconditionally discards a fully indexed body because a skeletal header-only
    /// row for the new key happened to land first, and neither the body nor the
    /// embedding is recoverable without a full re-fetch of the message.

    @Test("A rekey collision keeps the old entry's indexed body over a skeletal new key")
    func rekeyCollisionKeepsTheRicherOldEntry() async throws {
        let oldId = "\(prefix)_rich:INBOX:1"
        let newId = "\(prefix)_rich:TRASH:1"
        try? await index.removeMessages(contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))

        _ = try await index.indexHeaders([
            makeRecord(oldId, subject: "Rekeyricholdsubject unique"),
            makeRecord(newId, subject: "Rekeyrichnewsubject unique"),
        ])
        // Only the OLD entry has been given a body — the expensive part.
        _ = try await index.updateBodies([
            (contentKey: ContentKey(rawValue: oldId), body: "rekeyrichbodytoken unmistakable content"),
        ])

        try await index.rekeyHeaders([(oldKey: ContentKey(rawValue: oldId),
                                       newKey: ContentKey(rawValue: newId),
                                       newMessageId: nil)])

        // The indexed body survived and is reachable under the NEW key.
        let bodyHits = try await index.keywordSearch(query: "rekeyrichbodytoken")
        #expect(bodyHits.contains { $0.contentKey.rawValue == newId },
                "the richer entry's indexed body must survive the collision, under the new key")
        #expect(!bodyHits.contains { $0.contentKey.rawValue == oldId })
        let body = try await index.bodyText(contentKey: ContentKey(rawValue: newId))
        #expect(body?.contains("rekeyrichbodytoken") == true,
                "the body text itself must be readable under the new key")

        // The skeletal entry is the one that goes, and only one entry remains.
        let skeletalHits = try await index.keywordSearch(query: "rekeyrichnewsubject")
        #expect(skeletalHits.isEmpty, "the skeletal entry that lost the compare must be gone")
        #expect(try await index.isIndexed(contentKey: ContentKey(rawValue: oldId)) == false,
                "the old key must no longer be minted — the entry moved, it was not copied")

        try? await index.removeMessages(contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))
    }

    @Test("A rekey collision still drops the old entry when the new one is no poorer")
    func rekeyCollisionStillDropsThePoorerOldEntry() async throws {
        let oldId = "\(prefix)_poor:INBOX:1"
        let newId = "\(prefix)_poor:TRASH:1"
        try? await index.removeMessages(contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))

        _ = try await index.indexHeaders([
            makeRecord(oldId, subject: "Rekeypooroldsubject unique"),
            makeRecord(newId, subject: "Rekeypoornewsubject unique"),
        ])
        // The other side of the compare: here the NEW entry is the richer one.
        _ = try await index.updateBodies([
            (contentKey: ContentKey(rawValue: newId), body: "rekeypoorbodytoken unmistakable content"),
        ])

        try await index.rekeyHeaders([(oldKey: ContentKey(rawValue: oldId),
                                       newKey: ContentKey(rawValue: newId),
                                       newMessageId: nil)])

        let bodyHits = try await index.keywordSearch(query: "rekeypoorbodytoken")
        #expect(bodyHits.contains { $0.contentKey.rawValue == newId },
                "the richer new-key entry must survive untouched")
        let oldHits = try await index.keywordSearch(query: "rekeypooroldsubject")
        #expect(oldHits.isEmpty,
                "the poorer old entry must still be dropped — the compare is not 'always keep the old'")

        try? await index.removeMessages(contentKeys: [oldId, newId].map(ContentKey.init(rawValue:)))
    }

    @Test("A self-rekey is a no-op and never deletes the entry it converged on")
    func selfRekeyIsANoOp() async throws {
        let key = "\(prefix)_self:INBOX:1"
        let contentKey = ContentKey(rawValue: key)
        try? await index.removeMessages(contentKeys: [contentKey])

        _ = try await index.indexHeaders([makeRecord(key, subject: "Rekeyselfsubject unique")])
        _ = try await index.updateBodies([
            (contentKey: contentKey, body: "rekeyselfbodytoken unmistakable content"),
        ])

        // Already converged. Without the explicit no-op the collision branch compares
        // the entry with ITSELF, finds neither side richer, and deletes it outright.
        try await index.rekeyHeaders([(oldKey: contentKey, newKey: contentKey, newMessageId: nil)])

        #expect(try await index.isIndexed(contentKey: contentKey),
                "a self-rekey must leave the entry indexed")
        let bodyHits = try await index.keywordSearch(query: "rekeyselfbodytoken")
        #expect(bodyHits.contains { $0.contentKey.rawValue == key },
                "a self-rekey must not destroy the entry's indexed body")

        try? await index.removeMessages(contentKeys: [contentKey])
    }
}
