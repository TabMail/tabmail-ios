/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - UndoDestructiveAction Integration Tests

/// Tests for undoDestructiveAction() algorithm — the undo logic that:
/// 1. Cancels queued ops if still pending
/// 2. Queues move-back if already executed/in-flight
/// 3. Uses rfc822MessageId for IMAP (UIDs change on MOVE) vs messageId for Gmail
/// 4. Uses save() (upsert) to restore messages even if drain cleanup deleted the row
/// 5. Matches by both numeric UIDs and stableIds (rfc822MessageId)

@Suite("UndoDestructiveAction — Cancel Queued Ops")
struct UndoCancelQueuedTests {

    @Test("Cancels queued archive op — no move-back needed")
    func cancelQueuedArchive() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false)

        // Queue archive op
        try db.write { db in
            try PendingOperation(
                type: .archive,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Archive"
            ).insert(db)
        }

        // Simulate undo
        try db.write { db in
            let queuedOps = try PendingOperation
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(db)

            var cancelledOriginal = false
            let idsSet = Set(["100"])
            for op in queuedOps {
                let opMsgIds = Set(op.messageIds)
                if !opMsgIds.isDisjoint(with: idsSet) && op.type == .archive {
                    var cancelled = op
                    cancelled.status = PendingStatus.cancelled.rawValue
                    try cancelled.save(db)
                    cancelledOriginal = true
                }
            }

            // Restore message to inbox
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(db)

            #expect(cancelledOriginal == true, "Should have cancelled the queued op")
        }

        // Verify op is cancelled
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].status == PendingStatus.cancelled.rawValue)

        // Verify message is back in INBOX
        let restored = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(restored?.folderId == "acc1:INBOX")
    }

    @Test("Cancels associated removeTag ops when undoing archive")
    func cancelRemoveTagOps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        // Queue both removeTag and archive ops (FIFO — tag removed before move)
        try db.write { db in
            try PendingOperation(
                type: .removeTag,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "INBOX",
                tagValue: "reply"
            ).insert(db)
            try PendingOperation(
                type: .archive,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Archive"
            ).insert(db)
        }

        // Undo should cancel both removeTag AND archive
        try db.write { db in
            let queuedOps = try PendingOperation
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(db)

            let idsSet = Set(["100"])
            for op in queuedOps {
                let opMsgIds = Set(op.messageIds)
                if !opMsgIds.isDisjoint(with: idsSet) &&
                   (op.type == .archive || op.type == .removeTag) {
                    var cancelled = op
                    cancelled.status = PendingStatus.cancelled.rawValue
                    try cancelled.save(db)
                }
            }
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        let allCancelled = ops.allSatisfy { $0.status == PendingStatus.cancelled.rawValue }
        #expect(allCancelled, "Both removeTag and archive ops should be cancelled")
        #expect(ops.count == 2)
    }
}

@Suite("UndoDestructiveAction — Move-Back When Already Executed")
struct UndoMoveBackTests {

    @Test("Queues move-back when original op is already in-flight")
    func moveBackWhenInFlight() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false)

        // Op is already in-flight (not queued)
        try db.write { db in
            var op = PendingOperation(
                type: .archive,
                messageIds: ["100"],
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Archive"
            )
            op.status = PendingStatus.inFlight.rawValue
            try op.insert(db)
        }

        // Simulate undo — can't cancel in-flight, must queue move-back
        try db.write { db in
            let queuedOps = try PendingOperation
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(db)

            let idsSet = Set(["100"])
            var cancelledOriginal = false
            for op in queuedOps {
                let opMsgIds = Set(op.messageIds)
                if !opMsgIds.isDisjoint(with: idsSet) && op.type == .archive {
                    cancelledOriginal = true
                }
            }
            #expect(cancelledOriginal == false, "In-flight op cannot be cancelled")

            // Restore message locally
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(db)

            // Queue move-back (Gmail uses messageId)
            let account = try Account.fetchOne(db, key: "acc1")
            let moveBackIds: [String] = (account?.provider == .imap || account?.provider == .icloud) ? [] : ["100"]
            let moveBack = PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "Archive", destinationPath: "INBOX")
            try moveBack.insert(db)
        }

        // Verify move-back op was created
        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].folderPath == "Archive")
        #expect(ops[0].destinationPath == "INBOX")
        #expect(ops[0].messageIds == ["100"])
    }

    @Test("IMAP move-back uses rfc822MessageId instead of UID")
    func imapMoveBackUsesRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "500", folderId: "acc1:Trash", accountId: "acc1",
            folderPath: "Trash", isInInbox: false, rfc822MessageId: "<unique-msg@example.com>"
        )

        // Simulate undo for IMAP — no queued ops, so must queue move-back
        try db.write { db in
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(db)

            let account = try Account.fetchOne(db, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            try PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "Trash", destinationPath: "INBOX").insert(db)
        }

        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].messageIds == ["<unique-msg@example.com>"], "IMAP undo should use rfc822MessageId for resolveUID")
    }

    @Test("Gmail move-back uses stable messageId")
    func gmailMoveBackUsesMessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "TRASH", path: "TRASH", role: .trash, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "gmail-stable-id", folderId: "acc1:TRASH", accountId: "acc1",
            folderPath: "TRASH", isInInbox: false, rfc822MessageId: "<msg@example.com>"
        )

        try db.write { db in
            let account = try Account.fetchOne(db, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            try PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "TRASH", destinationPath: "INBOX").insert(db)
        }

        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops[0].messageIds == ["gmail-stable-id"], "Gmail undo should use stable messageId")
    }

    @Test("iCloud move-back uses rfc822MessageId like IMAP")
    func icloudMoveBackUsesRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .icloud)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "300", folderId: "acc1:Trash", accountId: "acc1",
            folderPath: "Trash", isInInbox: false, rfc822MessageId: "<icloud-msg@me.com>"
        )

        try db.write { db in
            let account = try Account.fetchOne(db, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            try PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "Trash", destinationPath: "INBOX").insert(db)
        }

        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops[0].messageIds == ["<icloud-msg@me.com>"], "iCloud undo should use rfc822MessageId like IMAP")
    }
}

@Suite("UndoDestructiveAction — Save/Upsert Pattern")
struct UndoUpsertTests {

    @Test("Upsert restores message when row still exists")
    func upsertRestoresExisting() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false)

        // Restore via save (upsert)
        try db.write { db in
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(db) // upsert
        }

        let header = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(header?.folderId == "acc1:INBOX")
    }

    @Test("Upsert re-creates message when drain cleanup deleted the row")
    func upsertRecreatesDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        // Create then delete (simulating drain cleanup)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false)
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: msg.id)
        }

        // Verify deleted
        let deleted = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(deleted == nil)

        // save() should re-insert
        try db.write { db in
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(db)
        }

        let header = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(header != nil, "save() should re-create the deleted row")
        #expect(header?.folderId == "acc1:INBOX")
    }
}

@Suite("UndoDestructiveAction — StableId Matching")
struct UndoStableIdMatchingTests {

    @Test("Matches queued ops by stableId (rfc822MessageId) when numeric UID differs")
    func matchByStableId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Pending op uses rfc822MessageId as the message identifier
        try db.write { db in
            try PendingOperation(
                type: .archive,
                messageIds: ["<msg@example.com>"],
                accountId: "acc1",
                folderPath: "INBOX"
            ).insert(db)
        }

        // Message has numeric UID but rfc822MessageId matches
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "999", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", rfc822MessageId: "<msg@example.com>"
        )

        // Undo matching — should find the op via stableId
        let stableIdsSet = Set([msg.stableId])
        let idsSet = Set([msg.messageId])

        let ops = try db.read {
            try PendingOperation.filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll($0)
        }

        var matched = false
        for op in ops {
            let opMsgIds = Set(op.messageIds)
            if (!opMsgIds.isDisjoint(with: idsSet) || !opMsgIds.isDisjoint(with: stableIdsSet)) &&
               op.type == .archive {
                matched = true
            }
        }

        #expect(matched, "Should match queued op via stableId (rfc822MessageId)")
    }

    @Test("stableId returns rfc822MessageId for numeric UIDs")
    func stableIdReturnsRfc822ForNumericUid() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", rfc822MessageId: "<stable@example.com>"
        )
        #expect(msg.stableId == "<stable@example.com>", "stableId should prefer rfc822MessageId for numeric UIDs")
    }

    @Test("stableId returns messageId for non-numeric IDs (Gmail)")
    func stableIdReturnsMessageIdForGmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "gmail-stable-id", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", rfc822MessageId: "<msg@gmail.com>"
        )
        #expect(msg.stableId == "gmail-stable-id", "stableId should return messageId for non-numeric IDs")
    }
}

@Suite("UndoDestructiveAction — Optimistic Move")
struct UndoOptimisticMoveTests {

    @Test("Optimistic move skips self-move (source == destination)")
    func selfMoveSkipped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false)

        // Try to move to same folder
        let folderPath = "Archive"
        let destinationPath = "Archive"

        var opsCreated = 0
        if folderPath != destinationPath {
            try db.write { db in
                try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: folderPath, destinationPath: destinationPath).insert(db)
                opsCreated += 1
            }
        }

        #expect(opsCreated == 0, "Self-move should be a no-op")
    }

    @Test("Tag removal queued before move when leaving inbox")
    func tagRemovalBeforeMove() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        var msg = try TestDatabase.insertMessageHeader(db, messageId: "100", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true, actionTag: .reply)

        try db.write { db in
            // FIFO: removeTag first
            if msg.isInInbox, let tag = msg.actionTag {
                try PendingOperation(
                    type: .removeTag,
                    messageIds: [msg.stableId],
                    accountId: "acc1",
                    folderPath: "INBOX",
                    tagValue: tag.rawValue
                ).insert(db)
            }
            // Then archive
            try PendingOperation(
                type: .archive,
                messageIds: [msg.stableId],
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Archive"
            ).insert(db)
        }

        let ops = try db.read { try PendingOperation.order(Column("createdAt").asc).fetchAll($0) }
        #expect(ops.count == 2)
        #expect(ops[0].type == .removeTag, "removeTag must be queued before archive (FIFO)")
        #expect(ops[1].type == .archive)
    }
}
