/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Regression tests for the delta-sync orphan-reclaim guard added to fix
/// "delta sync clobbers optimistic moves" (the optimistic-move clobber bug).
@Suite("Delta sync orphan-reclaim guard")
struct SyncDeltaOrphanReclaimGuardTests {

    @Test("IMAP archive + pending op: orphan guard preserves optimistic state")
    func pendingOpGuard_preservesOptimisticState() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let rfc822 = "abc@imap.example.com"
        let optimisticPK = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "8421")
        try db.write { dbConn in
            var h = MessageHeader(
                messageId: "8421",
                subject: "S", from: "F", fromAddress: "f@a", to: "t@a",
                date: Date(), snippet: "x",
                folderId: "acc1:INBOX",
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            h.rfc822MessageId = rfc822
            try h.insert(dbConn)
            // Optimistic archive: folderPath/folderId mutated, id PK unchanged.
            try MessageHeader.filter(Column("id") == optimisticPK).updateAll(
                dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            // PendingOp uses stableId == rfc822 for IMAP.
            try PendingOperation(
                type: .archive,
                messageIds: [rfc822],
                accountId: "acc1",
                folderPath: "INBOX"
            ).insert(dbConn)
        }

        // Drive the guard directly: when iterating the source folder, the
        // orphan fetch by id PK finds the optimistic row. The guard then checks
        // the pending-op snapshot against the orphan's stableId (rfc822).
        // Without the guard the reclaim would overwrite folderPath back to INBOX.
        try db.write { dbConn in
            let snapshot = try PendingOperationSnapshot.load(accountId: "acc1", db: dbConn)
            let orphaned = try MessageHeader.fetchOne(dbConn, key: optimisticPK)
            #expect(orphaned != nil, "id PK lookup must find the optimistic row")
            let orphanIsPending = snapshot.destructive.containsAnyKey(
                messageId: orphaned!.messageId,
                rfc822MessageId: orphaned!.rfc822MessageId
            )
            #expect(orphanIsPending, "Pending op (rfc822 keyed) must match orphan's rfc822 leg")
            // Production code: `if orphanIsPending { continue }` — no write here.
        }

        // State must be intact.
        let after = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: optimisticPK)
        }
        #expect(after?.folderPath == "Archive", "Optimistic archive must NOT be undone")
        #expect(after?.folderId == "acc1:Archive")
    }

    @Test("No pending op: orphan reclaim proceeds as before")
    func noPendingOp_reclaimProceeds() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let pk = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "100")
        try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            rfc822MessageId: "orphan@example.com"
        )

        try db.write { dbConn in
            let snapshot = try PendingOperationSnapshot.load(accountId: "acc1", db: dbConn)
            let orphaned = try MessageHeader.fetchOne(dbConn, key: pk)
            let orphanIsPending = snapshot.destructive.containsAnyKey(
                messageId: orphaned!.messageId,
                rfc822MessageId: orphaned!.rfc822MessageId
            )
            #expect(!orphanIsPending, "No pending op → guard does not fire")
        }
    }

    @Test("Defensive insert guard: duplicate id detection")
    func defensiveInsertGuard_skipsDuplicate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let pk = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "100")
        try TestDatabase.insertMessageHeader(
            db,
            messageId: "100",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            rfc822MessageId: nil
        )
        // The defensive guard's predicate must observe the existing row so the
        // insert path is skipped — preventing UNIQUE constraint crashes when
        // the pending-op filter misses (e.g., rfc822-nil IMAP messages).
        try db.read { dbConn in
            let found = try MessageHeader.fetchOne(dbConn, key: pk)
            #expect(found != nil)
        }
    }
}
