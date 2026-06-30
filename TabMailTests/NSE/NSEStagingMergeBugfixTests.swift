/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the staging merge bugfix landed 2026-04-27.
///
/// Coverage focuses on the testable primitives that the merge depends on:
/// schema migration backfill, the `populated=1` filter at the SELECT, the
/// orphan-reap DELETE, `AIOwnershipLease.ensureRow` leaving `populated=0`,
/// and GRDB's `db.inSavepoint` rollback-on-throw semantics that per-message
/// savepoint isolation in `mergeNSEStagingData` relies on.
///
/// `mergeNSEStagingData` itself is not invoked end-to-end here because it
/// resolves the staging file via the App Group container path. The pieces
/// it composes are each unit-tested below.
@Suite("NSE staging merge — bugfix invariants")
struct NSEStagingMergeBugfixTests {

    // MARK: - Helpers

    /// Build a staging DB matching the v6 production schema (post-bugfix).
    /// Mirrors `AppDatabase.createNSEStagingDBIfNeeded` end state.
    private func makeStagingDB() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderPath TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0,
                    htmlContent TEXT, textContent TEXT,
                    attachmentsJSON TEXT, icsText TEXT,
                    hasUnresolvedCIDs INTEGER DEFAULT 0,
                    toRaw TEXT DEFAULT '', ccRaw TEXT DEFAULT '', bccRaw TEXT DEFAULT '',
                    replyToRaw TEXT, inReplyTo TEXT, referencesJSON TEXT,
                    isFlagged INTEGER DEFAULT 0, hasAttachments INTEGER DEFAULT 0,
                    providerLabelsJSON TEXT,
                    isReplied INTEGER DEFAULT 0, isForwarded INTEGER DEFAULT 0,
                    aiOwner TEXT, aiHeartbeatMs INTEGER,
                    populated INTEGER NOT NULL DEFAULT 0
                )
                """)
        }
        return db
    }

    /// Build a staging DB at the v5 schema (pre-`populated`) so we can run the
    /// v6 migration ourselves and verify the heuristic backfill end-to-end.
    private func makeStagingDBAtV5() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let db = try DatabaseQueue(configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderPath TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0,
                    htmlContent TEXT, textContent TEXT,
                    attachmentsJSON TEXT, icsText TEXT,
                    hasUnresolvedCIDs INTEGER DEFAULT 0,
                    toRaw TEXT DEFAULT '', ccRaw TEXT DEFAULT '', bccRaw TEXT DEFAULT '',
                    replyToRaw TEXT, inReplyTo TEXT, referencesJSON TEXT,
                    isFlagged INTEGER DEFAULT 0, hasAttachments INTEGER DEFAULT 0,
                    providerLabelsJSON TEXT,
                    isReplied INTEGER DEFAULT 0, isForwarded INTEGER DEFAULT 0,
                    aiOwner TEXT, aiHeartbeatMs INTEGER
                )
                """)
        }
        return db
    }

    /// Apply the v6 migration: ADD COLUMN populated + heuristic backfill.
    /// Mirrors the production migration in `AppDatabase.createNSEStagingDBIfNeeded`.
    private func applyV6Migration(_ db: DatabaseQueue) throws {
        try db.write { db in
            do {
                try db.execute(sql: "ALTER TABLE nse_processed_message ADD COLUMN populated INTEGER NOT NULL DEFAULT 0")
            } catch {
                let msg = "\(error)".lowercased()
                if !msg.contains("duplicate column") { throw error }
            }
            try db.execute(sql: """
                UPDATE nse_processed_message SET populated = 1
                WHERE provider IS NOT NULL AND provider != ''
                  AND accountEmail IS NOT NULL AND accountEmail != ''
                """)
        }
    }

    private func insertRealRow(
        _ db: DatabaseQueue,
        id: String,
        provider: String = "gmail",
        accountEmail: String = "user@gmail.com",
        processedAt: Double = Date().timeIntervalSince1970,
        populated: Int? = nil
    ) throws {
        try db.write { db in
            if let populated {
                try db.execute(sql: """
                    INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId,
                     subject, senderName, processedAt, populated)
                    VALUES (?, 'acc1', ?, ?, ?, 'Real subject', 'Alice', ?, ?)
                    """, arguments: [id, accountEmail, provider, "msg-\(id)", processedAt, populated])
            } else {
                try db.execute(sql: """
                    INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId,
                     subject, senderName, processedAt)
                    VALUES (?, 'acc1', ?, ?, ?, 'Real subject', 'Alice', ?)
                    """, arguments: [id, accountEmail, provider, "msg-\(id)", processedAt])
            }
        }
    }

    /// Insert a row matching what `AIOwnershipLease.ensureRow` writes —
    /// empty provider, empty accountEmail, no metadata.
    private func insertPlaceholder(
        _ db: DatabaseQueue,
        id: String,
        processedAt: Double = Date().timeIntervalSince1970
    ) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, processedAt)
                VALUES (?, 'acc1', '', '', ?, ?)
                """, arguments: [id, "msg-\(id)", processedAt])
        }
    }

    // MARK: - Test 9: migration backfill heuristic

    @Test("v6 migration: real rows backfill to populated=1, placeholders stay populated=0")
    func migrationBackfillHeuristic() throws {
        let db = try makeStagingDBAtV5()
        let now = Date().timeIntervalSince1970

        // Seed BEFORE migration — column doesn't exist yet, so insert without it.
        try insertRealRow(db, id: "real-gmail", provider: "gmail",
                          accountEmail: "alice@gmail.com", processedAt: now, populated: nil)
        try insertRealRow(db, id: "real-outlook", provider: "outlook",
                          accountEmail: "bob@outlook.com", processedAt: now, populated: nil)
        try insertRealRow(db, id: "real-imap", provider: "imap_new_mail",
                          accountEmail: "carol@example.com", processedAt: now, populated: nil)
        try insertPlaceholder(db, id: "placeholder-1", processedAt: now)
        try insertPlaceholder(db, id: "placeholder-2", processedAt: now)

        // Run the migration.
        try applyV6Migration(db)

        // Real rows should be populated=1; placeholders should be populated=0.
        let realPopulated = try db.read { try Int.fetchAll($0, sql: """
            SELECT populated FROM nse_processed_message
            WHERE id IN ('real-gmail', 'real-outlook', 'real-imap')
            ORDER BY id
            """) }
        #expect(realPopulated == [1, 1, 1])

        let placeholderPopulated = try db.read { try Int.fetchAll($0, sql: """
            SELECT populated FROM nse_processed_message
            WHERE id LIKE 'placeholder-%' ORDER BY id
            """) }
        #expect(placeholderPopulated == [0, 0])
    }

    @Test("v6 migration: idempotent on re-run — second migration is a no-op")
    func migrationIdempotent() throws {
        let db = try makeStagingDBAtV5()
        let now = Date().timeIntervalSince1970
        try insertRealRow(db, id: "real-1", processedAt: now, populated: nil)
        try insertPlaceholder(db, id: "ph-1", processedAt: now)

        try applyV6Migration(db)
        try applyV6Migration(db)   // second run must not throw or re-flip

        let counts = try db.read { db in
            (
                real: try Int.fetchOne(db, sql: "SELECT populated FROM nse_processed_message WHERE id = 'real-1'") ?? -1,
                ph: try Int.fetchOne(db, sql: "SELECT populated FROM nse_processed_message WHERE id = 'ph-1'") ?? -1
            )
        }
        #expect(counts.real == 1)
        #expect(counts.ph == 0)
    }

    // MARK: - Test 1: placeholder filtering

    @Test("Merge SELECT filter: WHERE populated=1 hides placeholders")
    func mergeSelectFilter() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970

        // Mix of populated and placeholder rows.
        try insertRealRow(db, id: "real-1", processedAt: now, populated: 1)
        try insertRealRow(db, id: "real-2", processedAt: now, populated: 1)
        try insertPlaceholder(db, id: "ph-1", processedAt: now)
        try insertPlaceholder(db, id: "ph-2", processedAt: now)

        // The merge's SELECT.
        let visibleIds = try db.read { try String.fetchAll($0, sql: """
            SELECT id FROM nse_processed_message WHERE populated = 1 ORDER BY id
            """) }
        #expect(visibleIds == ["real-1", "real-2"])

        // Without the filter we'd see all four — confirms the filter is what isolates them.
        let unfilteredCount = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM nse_processed_message
            """) ?? 0 }
        #expect(unfilteredCount == 4)
    }

    // MARK: - Test 7: orphan reap — only stale placeholders deleted

    @Test("Orphan reap: deletes only populated=0 rows older than threshold")
    func orphanReapStale() throws {
        let db = try makeStagingDB()
        let now = Date().timeIntervalSince1970
        let oldEnoughToReap = now - 120         // 2 min old, > 60s threshold
        let tooFreshToReap = now - 30           // 30s old, < 60s threshold
        let veryOldRealRow = now - 3600         // 1 hour old but populated=1

        try insertPlaceholder(db, id: "ph-stale", processedAt: oldEnoughToReap)
        try insertPlaceholder(db, id: "ph-fresh", processedAt: tooFreshToReap)
        try insertRealRow(db, id: "real-old", processedAt: veryOldRealRow, populated: 1)

        // The reap SQL — exactly as run in mergeNSEStagingData.
        let cutoff = now - 60   // orphanThresholdSeconds
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM nse_processed_message
                WHERE populated = 0 AND processedAt < ?
                """, arguments: [cutoff])
        }

        let surviving = try db.read { try String.fetchAll($0, sql: """
            SELECT id FROM nse_processed_message ORDER BY id
            """) }
        // Stale placeholder reaped; fresh placeholder + populated=1 row preserved.
        #expect(surviving == ["ph-fresh", "real-old"])
    }

    @Test("Orphan reap: never touches populated=1 rows regardless of age")
    func orphanReapPreservesReal() throws {
        let db = try makeStagingDB()
        let ancient = Date().timeIntervalSince1970 - 86_400   // 24 hours

        try insertRealRow(db, id: "real-ancient", processedAt: ancient, populated: 1)

        let cutoff = Date().timeIntervalSince1970 - 60
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM nse_processed_message
                WHERE populated = 0 AND processedAt < ?
                """, arguments: [cutoff])
        }

        let count = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM nse_processed_message WHERE id = 'real-ancient'
            """) ?? 0 }
        #expect(count == 1)
    }

    // MARK: - AIOwnershipLease.ensureRow leaves populated=0

    @Test("AIOwnershipLease.ensureRow writes a placeholder with populated=0")
    func ensureRowDefaultsToPopulatedZero() throws {
        let db = try makeStagingDB()
        AIOwnershipLease.ensureRow(db: db, accountId: "acc1", messageId: "msg-1")

        let row = try db.read { try Row.fetchOne($0, sql: """
            SELECT id, accountEmail, provider, populated
            FROM nse_processed_message WHERE id = 'acc1:msg-1'
            """) }
        guard let row else {
            Issue.record("ensureRow did not insert"); return
        }
        let accountEmail: String = row["accountEmail"]
        let provider: String = row["provider"]
        let populated: Int = row["populated"]
        #expect(accountEmail == "")
        #expect(provider == "")
        #expect(populated == 0)
    }

    @Test("AIOwnershipLease lease ops do not flip populated to 1")
    func leaseOpsDoNotFlipPopulated() throws {
        let db = try makeStagingDB()

        // ensureRow + tryClaim + refresh + release — none of these should
        // ever write populated=1. Only NSEStagingDB.persistProcessedMessage
        // is allowed to flip the flag.
        AIOwnershipLease.ensureRow(db: db, accountId: "acc1", messageId: "msg-1")
        _ = AIOwnershipLease.tryClaim(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse)
        AIOwnershipLease.refresh(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse)
        AIOwnershipLease.release(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse)

        let populated = try db.read { try Int.fetchOne($0, sql: """
            SELECT populated FROM nse_processed_message WHERE id = 'acc1:msg-1'
            """) ?? -1 }
        #expect(populated == 0)
    }

    // MARK: - AIOwnershipLease.release — conditional + idempotent
    //
    // The NSE now releases its lease from EVERY exit path (the natural
    // top-of-process `defer`, the graceful-exit watchdog, and
    // `serviceExtensionTimeWillExpire`) — "lease all the time", so the main app
    // never waits out a stale lease after a clean NSE exit. That is only safe
    // because `release` is (a) conditional on still owning (`WHERE aiOwner='nse'`)
    // and (b) idempotent. These two tests pin both invariants.

    @Test("release(owner:.nse) does NOT clobber a lease a stale-takeover handed to mainApp")
    func releaseIsConditionalOnOwner() throws {
        let db = try makeStagingDB()
        // NSE claims, then "dies": backdate its heartbeat past staleMs.
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse))
        let staleHb = Int64(Date().timeIntervalSince1970 * 1000) - (AIOwnershipLease.staleMs + 1000)
        try db.write { try $0.execute(sql: "UPDATE nse_processed_message SET aiHeartbeatMs = ?", arguments: [staleHb]) }
        // Main app takes over the stale lease.
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: "acc1", messageId: "msg-1", owner: .mainApp))

        // The dead NSE's late exit (watchdog / expiration) fires `release(.nse)`.
        // It must be a no-op — mainApp's takeover survives.
        AIOwnershipLease.release(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse)

        let owner = try db.read { try String.fetchOne($0, sql: """
            SELECT aiOwner FROM nse_processed_message WHERE id = 'acc1:msg-1'
            """) }
        #expect(owner == "mainApp")
    }

    @Test("release is idempotent — the NSE's multiple exit paths releasing twice is harmless")
    func releaseIsIdempotent() throws {
        let db = try makeStagingDB()
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse))

        // First release (natural `defer`), then a second (watchdog/expiration that
        // raced the same exit). Neither throws; the slot ends genuinely free.
        AIOwnershipLease.release(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse)
        AIOwnershipLease.release(db: db, accountId: "acc1", messageId: "msg-1", owner: .nse)

        let owner = try db.read { try String.fetchOne($0, sql: """
            SELECT aiOwner FROM nse_processed_message WHERE id = 'acc1:msg-1'
            """) }
        #expect(owner == nil)
        // The freed slot is claimable by the next actor (main app takes over).
        #expect(AIOwnershipLease.tryClaim(db: db, accountId: "acc1", messageId: "msg-1", owner: .mainApp))
    }

    // MARK: - GRDB inSavepoint rollback-on-throw semantics

    /// Insert a minimal MessageHeader on an existing GRDB `Database` (inside
    /// an active transaction). `TestDatabase.insertMessageHeader` opens its
    /// own `dbPool.write`, which would deadlock or fail if called inside a
    /// savepoint; this helper drives the GRDB record's `insert(db)` on the
    /// active connection.
    private func rawInsertHeader(
        _ db: GRDB.Database,
        messageId: String,
        accountId: String = "acc1",
        folderPath: String = "INBOX"
    ) throws {
        let header = MessageHeader(
            messageId: messageId,
            subject: "subj",
            from: "Sender",
            fromAddress: "sender@x.com",
            to: "to@x.com",
            date: Date(),
            snippet: "snip",
            folderId: "\(accountId):\(folderPath)",
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: true
        )
        try header.insert(db)
    }

    /// The per-message savepoint in `mergeNSEStagingData` relies on
    /// `db.inSavepoint` rolling back on throw and re-throwing the error to
    /// the surrounding `do/catch`, while leaving the outer transaction alive
    /// so sibling messages can still commit. This test pins that contract.
    @Test("inSavepoint rolls back on throw, outer tx survives, sibling commits")
    func savepointRollbackOnThrow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@x.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX",
                                      role: .inbox, accountId: "acc1")

        struct PerRowError: Error {}

        var committed: [String] = []
        try db.write { db in
            // First savepoint throws — should be rolled back, outer tx alive.
            do {
                try db.inSavepoint {
                    try self.rawInsertHeader(db, messageId: "doomed")
                    throw PerRowError()
                }
                committed.append("doomed")  // not reached
            } catch {
                // Expected. Outer tx still alive.
            }

            // Second savepoint commits — should survive even though the
            // first one threw.
            try db.inSavepoint {
                try self.rawInsertHeader(db, messageId: "good")
                return .commit
            }
            committed.append("good")
        }

        #expect(committed == ["good"])

        // Only the second header should be in the DB — the first was rolled back.
        let surviving = try db.read { try String.fetchAll($0, sql: """
            SELECT messageId FROM messageHeader WHERE accountId = 'acc1' ORDER BY messageId
            """) }
        #expect(surviving == ["good"])
    }

    @Test("inSavepoint with .rollback completion: rolls back, no error, outer tx alive")
    func savepointExplicitRollback() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@x.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX",
                                      role: .inbox, accountId: "acc1")

        try db.write { db in
            try db.inSavepoint {
                try self.rawInsertHeader(db, messageId: "rolled-back")
                return .rollback
            }
            // Outer tx still alive — sibling work commits.
            try self.rawInsertHeader(db, messageId: "kept")
        }

        let surviving = try db.read { try String.fetchAll($0, sql: """
            SELECT messageId FROM messageHeader WHERE accountId = 'acc1' ORDER BY messageId
            """) }
        #expect(surviving == ["kept"])
    }
}
