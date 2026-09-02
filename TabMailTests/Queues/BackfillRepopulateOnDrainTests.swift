/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Backfill Body

/// SQL correctness tests for `BackfillBodyQueue.repopulateOnDrain`.
/// Mirrors the production query without the actor/NetworkMonitor/provider dependency
/// so we can test the SQL filter in isolation. The query is asserted to match the
/// production one verbatim — if production changes, the helper must change with it.
@Suite("BackfillBodyQueue.repopulateOnDrain — query correctness")
struct BackfillBodyRepopulateOnDrainTests {

    /// Runs the exact SQL from `BackfillBodyQueue.repopulateOnDrain`.
    private func queryRepopulateOnDrain(_ db: DatabaseQueue) throws -> [Row] {
        try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: """
                SELECT id, accountId, folderPath, messageId, isInInbox
                FROM messageHeader
                WHERE headerComplete = 1 AND bodyComplete = 0 AND bodyEmptyConfirmed = 0 AND isInInbox = 0
                  AND bodyMetadataOversized = 0
                ORDER BY date DESC
                """)
        }
    }

    /// Flip messageHeader completion flags directly.
    private func setFlags(
        _ db: DatabaseQueue,
        id: String,
        headerComplete: Bool = true,
        bodyComplete: Bool = false,
        bodyEmptyConfirmed: Bool = false
    ) throws {
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET headerComplete = ?, bodyComplete = ?, bodyEmptyConfirmed = ? WHERE id = ?",
                arguments: [headerComplete, bodyComplete, bodyEmptyConfirmed, id]
            )
        }
    }

    // MARK: -

    @Test("Non-inbox header with headerComplete=1, bodyComplete=0 is included")
    func includesNonInboxPendingBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: h.id, headerComplete: true)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect((rows[0]["messageId"] as String) == "1")
        #expect((rows[0]["isInInbox"] as Bool) == false)
    }

    @Test("Inbox header is excluded (that's the Active queue's job)")
    func excludesInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1", isInInbox: true)
        try setFlags(db, id: h.id, headerComplete: true)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.isEmpty)
    }

    @Test("headerComplete=0 excluded (body can't be fetched before headers are indexed)")
    func excludesIncompleteHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: h.id, headerComplete: false)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.isEmpty)
    }

    @Test("bodyComplete=1 excluded (already fetched)")
    func excludesAlreadyFetched() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: h.id, headerComplete: true, bodyComplete: true)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.isEmpty)
    }

    @Test("bodyEmptyConfirmed=1 excluded (confirmed empty, don't retry)")
    func excludesEmptyConfirmed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let h = try TestDatabase.insertMessageHeader(
            db, messageId: "1",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: h.id, headerComplete: true, bodyEmptyConfirmed: true)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.isEmpty)
    }

    @Test("Multiple non-inbox matching rows ordered by date descending")
    func orderedByDateDesc() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let now = Date()
        let older = try TestDatabase.insertMessageHeader(
            db, messageId: "old", date: now.addingTimeInterval(-3600),
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        let newer = try TestDatabase.insertMessageHeader(
            db, messageId: "new", date: now,
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: older.id, headerComplete: true)
        try setFlags(db, id: newer.id, headerComplete: true)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.count == 2)
        guard rows.count == 2 else { return }
        #expect((rows[0]["messageId"] as String) == "new")
        #expect((rows[1]["messageId"] as String) == "old")
    }

    @Test("Mixed: inbox + non-inbox + complete bodies — only non-inbox pending returned")
    func mixedScope() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)                                              // INBOX
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // Inbox, headerComplete, body pending → excluded (Active queue's scope)
        let a = try TestDatabase.insertMessageHeader(db, messageId: "inbox-pending", isInInbox: true)
        try setFlags(db, id: a.id, headerComplete: true)

        // Archive, headerComplete, body pending → INCLUDED
        let b = try TestDatabase.insertMessageHeader(
            db, messageId: "archive-pending",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: b.id, headerComplete: true)

        // Archive, body already complete → excluded
        let c = try TestDatabase.insertMessageHeader(
            db, messageId: "archive-done",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: c.id, headerComplete: true, bodyComplete: true)

        let rows = try queryRepopulateOnDrain(db)
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect((rows[0]["messageId"] as String) == "archive-pending")
    }
}

// MARK: - Backfill Embedding

/// SQL correctness tests for `BackfillEmbeddingQueue.repopulateOnDrain`.
@Suite("BackfillEmbeddingQueue.repopulateOnDrain — query correctness")
struct BackfillEmbeddingRepopulateOnDrainTests {

    /// Runs the exact SQL from `BackfillEmbeddingQueue.repopulateOnDrain`.
    private func queryRepopulateOnDrain(_ db: DatabaseQueue) throws -> [String] {
        try db.read { dbConn in
            try String.fetchAll(dbConn, sql: """
                SELECT id FROM messageHeader
                WHERE bodyComplete = 1 AND embeddingComplete = 0 AND bodyEmptyConfirmed = 0
                ORDER BY isInInbox DESC, date DESC
                LIMIT 500
                """)
        }
    }

    private func setFlags(
        _ db: DatabaseQueue,
        id: String,
        bodyComplete: Bool = true,
        embeddingComplete: Bool = false,
        bodyEmptyConfirmed: Bool = false
    ) throws {
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET bodyComplete = ?, embeddingComplete = ?, bodyEmptyConfirmed = ? WHERE id = ?",
                arguments: [bodyComplete, embeddingComplete, bodyEmptyConfirmed, id]
            )
        }
    }

    // MARK: -

    @Test("Header with bodyComplete=1, embeddingComplete=0 is included")
    func includesPendingEmbedding() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try setFlags(db, id: h.id, bodyComplete: true)

        let ids = try queryRepopulateOnDrain(db)
        #expect(ids.count == 1)
    }

    @Test("bodyComplete=0 excluded (no body to embed)")
    func excludesNoBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try setFlags(db, id: h.id, bodyComplete: false)

        let ids = try queryRepopulateOnDrain(db)
        #expect(ids.isEmpty)
    }

    @Test("embeddingComplete=1 excluded (already embedded)")
    func excludesAlreadyEmbedded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try setFlags(db, id: h.id, bodyComplete: true, embeddingComplete: true)

        let ids = try queryRepopulateOnDrain(db)
        #expect(ids.isEmpty)
    }

    @Test("bodyEmptyConfirmed=1 excluded (nothing to embed)")
    func excludesEmptyConfirmed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let h = try TestDatabase.insertMessageHeader(db, messageId: "1")
        try setFlags(db, id: h.id, bodyComplete: true, bodyEmptyConfirmed: true)

        let ids = try queryRepopulateOnDrain(db)
        #expect(ids.isEmpty)
    }

    @Test("Ordering: isInInbox DESC then date DESC — inbox newest first")
    func orderInboxThenDate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)                                              // INBOX
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let now = Date()
        let inboxOld = try TestDatabase.insertMessageHeader(
            db, messageId: "inbox-old", date: now.addingTimeInterval(-3600), isInInbox: true
        )
        let inboxNew = try TestDatabase.insertMessageHeader(
            db, messageId: "inbox-new", date: now, isInInbox: true
        )
        let archiveNew = try TestDatabase.insertMessageHeader(
            db, messageId: "archive-new", date: now.addingTimeInterval(-100),
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )
        try setFlags(db, id: inboxOld.id, bodyComplete: true)
        try setFlags(db, id: inboxNew.id, bodyComplete: true)
        try setFlags(db, id: archiveNew.id, bodyComplete: true)

        let ids = try queryRepopulateOnDrain(db)
        #expect(ids.count == 3)
        guard ids.count == 3 else { return }
        // Inbox rows come first (by date desc), then non-inbox.
        #expect(ids[0] == inboxNew.id)
        #expect(ids[1] == inboxOld.id)
        #expect(ids[2] == archiveNew.id)
    }
}
