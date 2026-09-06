/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("E2E Core Email Flows")
struct E2EEmailLifecycleTests {

    @Test("Archive email: optimistic UI + PendingOp")
    func archiveEmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Optimistic UI: mark as not-in-inbox immediately
        header.isInInbox = false
        header.folderId = "" // v2 FK OK
        try db.write { try header.update($0) }

        // Queue PendingOp
        var op = PendingOperation(
            type: .archive,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        // Verify state
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.isInInbox == false)

        let pendingOp = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(pendingOp?.type == .archive)
    }

    @Test("Delete email: move to trash + PendingOp")
    func deleteEmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Queue PendingOp for delete
        var op = PendingOperation(
            type: .delete,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        #expect(try db.read { try PendingOperation.fetchCount($0) } == 1)
    }

    @Test("Mark read: update isRead + PendingOp")
    func markRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)

        // Optimistic: mark as read
        header.isRead = true
        try db.write { try header.update($0) }

        // Queue PendingOp
        var op = PendingOperation(
            type: .markRead,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.isRead == true)
    }

    @Test("Flag email: toggle isFlagged + PendingOp")
    func flagEmail() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Toggle flag
        header.isFlagged = true
        try db.write { try header.update($0) }

        var op = PendingOperation(
            type: .markFlagged,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.isFlagged == true)
    }

    @Test("Send email lifecycle: queue → send → stamp sentAt → delete")
    func sendEmailLifecycle() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // 1. Queue
        let draft = DraftMessage(to: ["bob@test.com"], subject: "Hi", body: "Hello")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }
        #expect(msg.outboxStatus == .queued)

        // 2. Start sending
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }

        // 3. Send succeeds → stamp sentAt
        msg.sentAt = Date()
        try db.write { try msg.update($0) }
        let stamped = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(stamped?.sentAt != nil)

        // 4. Delete after confirmed
        _ = try db.write { try msg.delete($0) }
        let remaining = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(remaining == 0)
    }

    @Test("Undo archive: message restored to inbox")
    func undoArchive() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Original state
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Archive (optimistic)
        header.isInInbox = false
        header.folderId = ""
        try db.write { try header.update($0) }

        // Undo: restore to inbox using save (upsert)
        header.isInInbox = true
        header.folderId = "acc1:INBOX"
        try db.write { try header.save($0) } // upsert — handles case where drain already deleted row

        let restored = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(restored?.isInInbox == true)
        #expect(restored?.folderId == "acc1:INBOX")
    }

    @Test("Set ActionTag + IMAP keyword PendingOp")
    func setActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1")

        // Set action tag
        header.actionTag = .archive
        try db.write { try header.update($0) }

        // Queue setTag PendingOp
        var op = PendingOperation(
            type: .setTag,
            messageIds: ["1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: ActionTag.archive.rawValue
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:1") }
        #expect(fetched?.actionTag == .archive)
    }
}
