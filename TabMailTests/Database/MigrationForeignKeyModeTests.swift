/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The invariant `foreignKeyChecks: .immediate` must not break.
///
/// `v68…v83` used to run on the wrapper's `.deferred` default, which made GRDB
/// append a whole-database `PRAGMA foreign_key_check` to EVERY one of the 16
/// migrations — measured at 69–74% of the entire upgrade's wall clock, and at
/// 70% of it (19,312 ms of 27,601 ms) on the owner's real device. Fifteen of them
/// now declare `.immediate` instead, which enforces foreign keys LIVE on the
/// writes the body actually makes and runs no trailing scan.
///
/// 🚨 **THE PROPERTY PINNED HERE IS THE END STATE, NOT THE MODE TABLE.** A test
/// that asserted "v72 is `.immediate`" would pass on a chain that leaves the
/// database referentially broken, and would fail on a future migration that is
/// correctly re-adjudicated — it would pin the fix's mechanism instead of the
/// system property the mechanism exists to preserve. What matters is that a
/// populated, FK-bearing database that walks the whole chain comes out with zero
/// foreign-key violations.
///
/// The second test is the non-vacuity proof: with one dangling child row the
/// chain must FAIL rather than wave it through, and it must fail at
/// `v82_accountScopedUserLabelIdentity` — the LAST whole-database gate left in
/// the range. ⚠️ **This used to name `v71_addOutboxDraftRfc822MessageId` and call
/// it "the single whole-database gate the range deliberately keeps".** `v71` was
/// deliberately flipped to `.immediate` on 2026-08-06: its gate cost 12,083 ms of
/// the owner's 27,601 ms upgrade to guard a single `ALTER TABLE … ADD COLUMN`,
/// and the orphan class it ran early to catch is the one `v82` repairs itself
/// (step 1 deletes associations whose header is gone; step 3a rebuilds a parent
/// for a dangling label id). Read `v71`'s registration comment for the full
/// argument.
@Suite("Migration foreign-key modes (v68…v83)")
struct MigrationForeignKeyModeTests {

    // MARK: - Fixture

    private static let v67 = "v67_addUidResolutionRetryCount"

    /// A database migrated only as far as `v67` — the exact shape every existing
    /// device arrives at `v68` on.
    private static func makeV67Database() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: v67)
        return db
    }

    private static func migrateToHead(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db)
    }

    private static func registeredIdentifiers() -> [String] {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        return migrator.migrations
    }

    private static func appliedIdentifiers(_ db: DatabaseQueue) throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
    }

    /// Every `(child table, violating rowid, parent table, fk index)` the whole
    /// database still carries. Empty is the invariant.
    private static func foreignKeyViolations(_ db: DatabaseQueue) throws -> [String] {
        try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").map(\.description)
        }
    }

    /// Raw SQL, not the model types: `Draft` carries `lastTouchedSeq` (v79),
    /// `UserLabel` carries `providerLabelId` (v82) and `MessageHeader` carries
    /// `observedUidValidity` (v77) — none of which exist yet at v67, so a model
    /// insert would fail against the very schema this test needs to seed.
    ///
    /// Seeds EVERY foreign-key edge present at v67, on both a provider whose
    /// drafts `v73` rewrites (`imap`) and one it leaves alone (`gmail`):
    /// `account ← {caldavConfig, draft, folder, messageHeader, outboxMessage,
    /// pendingCalendarOperation, userLabel}`, `messageHeader ← {messageBody,
    /// messageReference, messageUserLabel}`, `userLabel ← {messageUserLabel}`.
    private static func seed(_ db: DatabaseQueue) throws {
        try db.write { db in
            for (accountId, provider) in [("acc-imap", "imap"), ("acc-gmail", "gmail")] {
                try db.execute(sql: """
                    INSERT INTO account (id, emailAddress, displayName, provider, createdAt)
                    VALUES (?, ?, 'Test', ?, 1)
                    """, arguments: [accountId, "\(accountId)@example.com", provider])
                try db.execute(sql: """
                    INSERT INTO caldavConfig (id, accountId, serverURL, username, createdAt)
                    VALUES (?, ?, 'https://caldav.example.com', 'user', 1)
                    """, arguments: ["\(accountId):caldav", accountId])
                try db.execute(sql: """
                    INSERT INTO pendingCalendarOperation
                        (id, operationType, accountId, argumentsJSON, createdAt)
                    VALUES (?, 'create', ?, '{}', 1)
                    """, arguments: ["\(accountId):cal-op", accountId])
                try db.execute(sql: """
                    INSERT INTO outboxMessage
                        (id, accountId, toJSON, ccJSON, bccJSON, subject, body, createdAt)
                    VALUES (?, ?, '["to@example.com"]', '[]', '[]', 'subject', 'body', 1)
                    """, arguments: ["\(accountId):outbox", accountId])
                // `pendingOperation` has NO declared FK to `account` at v67 (its
                // `accountId` is a bare TEXT column) — seeded anyway because `v74`
                // deletes every row and `v76`/`v78` alter the table.
                try db.execute(sql: """
                    INSERT INTO pendingOperation
                        (id, type, messageIdsJSON, accountId, folderPath, createdAt)
                    VALUES (?, 'archive', '["1"]', ?, 'INBOX', 1)
                    """, arguments: ["\(accountId):op", accountId])
                // Two drafts: one with a server address (v73 clears it for `imap`
                // accounts only), one purely local.
                try db.execute(sql: """
                    INSERT INTO draft
                        (id, accountId, subject, body, createdAt, updatedAt,
                         serverDraftId, serverPushStatus)
                    VALUES (?, ?, 'draft subject', 'draft body', 1, 2, '42', 'pushed')
                    """, arguments: ["\(accountId):draft-pushed", accountId])
                try db.execute(sql: """
                    INSERT INTO draft
                        (id, accountId, subject, body, createdAt, updatedAt)
                    VALUES (?, ?, 'local draft', 'local body', 1, 2)
                    """, arguments: ["\(accountId):draft-local", accountId])

                // A label that IS applied to messages, and one the user created but
                // never applied — v82 rebuilds `userLabel` and must keep both.
                //
                // Both ids carry the account prefix because at v67 `userLabel.id` is
                // the PRIMARY KEY and is NOT account-scoped — two accounts cannot
                // hold the same label id, which is precisely the collision `v82`
                // exists to make representable.
                try db.execute(sql: """
                    INSERT INTO userLabel (id, accountId, name) VALUES (?, ?, 'Applied')
                    """, arguments: ["\(accountId):label-applied", accountId])
                try db.execute(sql: """
                    INSERT INTO userLabel (id, accountId, name) VALUES (?, ?, 'Unapplied')
                    """, arguments: ["\(accountId):label-unapplied", accountId])

                for folderPath in ["INBOX", "Archive"] {
                    let folderId = "\(accountId):\(folderPath)"
                    try db.execute(sql: """
                        INSERT INTO folder (id, accountId, name, path, role)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [
                            folderId, accountId, folderPath, folderPath,
                            folderPath == "INBOX" ? "inbox" : "archive",
                        ])
                    for uid in 1...3 {
                        let headerId = "\(folderId):\(uid)"
                        try db.execute(sql: """
                            INSERT INTO messageHeader
                                (id, folderId, accountId, folderPath, isInInbox, messageId,
                                 rfc822MessageId, subject, `from`, fromAddress, `to`, date,
                                 isRead, actionTag, tagSortOrder)
                            VALUES (?, ?, ?, ?, ?, ?, ?, 'subject',
                                    'sender@example.com', 'sender@example.com',
                                    'recipient@example.com', 1, ?, ?, ?)
                            """, arguments: [
                                headerId, folderId, accountId, folderPath,
                                folderPath == "INBOX", String(uid),
                                "rfc-\(headerId)@example.com",
                                uid == 1, uid == 2 ? "todo" : nil, uid == 2 ? 1 : 99,
                            ])
                        try db.execute(sql: """
                            INSERT INTO messageBody (id, htmlContent, fetchedAt)
                            VALUES (?, '<p>body</p>', 1)
                            """, arguments: [headerId])
                        try db.execute(sql: """
                            INSERT INTO messageReference (messageHeaderId, referencedRfc822Id)
                            VALUES (?, ?)
                            """, arguments: [headerId, "rfc-parent-\(uid)@example.com"])
                        try db.execute(sql: """
                            INSERT INTO messageUserLabel (messageId, userLabelId)
                            VALUES (?, ?)
                            """, arguments: [headerId, "\(accountId):label-applied"])
                    }
                }
            }
        }
    }

    // MARK: - 1. The invariant

    @Test("v68…v83 leave a populated database foreign-key clean")
    func chainLeavesDatabaseForeignKeyClean() throws {
        let db = try Self.makeV67Database()
        try Self.seed(db)

        // Sanity: the fixture itself is clean, so anything the chain produces is
        // the chain's doing and not the seed's.
        #expect(try Self.foreignKeyViolations(db).isEmpty)

        try Self.migrateToHead(db)

        let violations = try Self.foreignKeyViolations(db)
        #expect(violations.isEmpty, "chain left \(violations.count) FK violation(s): \(violations)")

        let registered = Self.registeredIdentifiers()
        let applied = try Self.appliedIdentifiers(db)
        #expect(applied == Set(registered), "not every registered migration applied")
        #expect(applied.contains("v83_markAllAsReadUnreadSweepIndex"))
    }

    // MARK: - 2. Non-vacuity — the check above is actually checking

    @Test("A pre-existing orphan still FAILS the chain, at the v82 whole-database gate")
    func preExistingOrphanFailsTheChainAtV82() throws {
        let db = try Self.makeV67Database()
        try Self.seed(db)

        // `messageReference → messageHeader` is the edge to break: it is declared
        // at v27 and NO migration in v68…v83 rebuilds that table, so the orphan
        // survives all the way to whichever gate is meant to catch it. (An orphan
        // in `messageBody` would prove nothing — v70 drops the table outright.)
        //
        // Foreign keys have to be off to CREATE the orphan, which is the whole
        // point: a real one arrives the same way — written under a schema or a
        // code path that did not enforce the edge — and is then found later.
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO messageReference (messageHeaderId, referencedRfc822Id)
                VALUES ('acc-imap:INBOX:does-not-exist', 'rfc-orphan@example.com')
                """)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        #expect(try Self.foreignKeyViolations(db).count == 1, "orphan injection did not take")

        var thrown: (any Error)?
        do {
            try Self.migrateToHead(db)
        } catch {
            thrown = error
        }
        #expect(
            thrown != nil,
            """
            the chain accepted a database with a dangling messageReference row — the \
            clean result in the sibling test is vacuous
            """)

        let applied = try Self.appliedIdentifiers(db)
        #expect(
            applied.contains("v71_addOutboxDraftRfc822MessageId"),
            """
            every `.immediate` migration before the gate should still apply — \
            `.immediate` enforces only the writes the body makes, and none of them \
            touch the orphan. (`v71` is in this set as of 2026-08-06; it used to be \
            the gate and is now one of the migrations that walks past the orphan.)
            """)
        #expect(
            !applied.contains("v82_accountScopedUserLabelIdentity"),
            """
            v82 is the LAST whole-database FK gate in this range; if it stopped being \
            `.deferred`, nothing in v68…v83 catches a pre-existing orphan at all
            """)
        #expect(!applied.contains("v83_markAllAsReadUnreadSweepIndex"))
    }
}
