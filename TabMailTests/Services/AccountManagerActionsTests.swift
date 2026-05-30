/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the DB write patterns used by AccountManagerActions.
/// AccountManager itself is a singleton coupled to AppDatabase.dbPool,
/// so we test the underlying GRDB write logic directly with TestDatabase.
/// This validates optimistic UI patterns, PendingOperation creation,
/// and undo logic at the database level.
@Suite("AccountManagerActions - DB Patterns")
struct AccountManagerActionsTests {

    // MARK: - markRead / markUnread patterns

    @Test("markRead pattern: updates isRead=1 and creates PendingOperation(.markRead)")
    func markReadPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)

        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [msg.id])
            try PendingOperation(type: .markRead, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX").insert(dbConn)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.isRead == true)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markRead)
        #expect(ops[0].messageIds == [msg.stableId])
    }

    @Test("markRead with multiple messages in same folder creates single PendingOperation")
    func markReadMultipleSameFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: false)

        let messages = [msg1, msg2]
        let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }

        try db.write { dbConn in
            for (_, msgs) in grouped {
                let stableIds = msgs.map(\.stableId)
                for msg in msgs {
                    try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [msg.id])
                }
                try PendingOperation(type: .markRead, messageIds: stableIds, accountId: msgs[0].accountId, folderPath: msgs[0].folderPath).insert(dbConn)
            }
        }

        // Both messages should be read
        let all = try db.read { try MessageHeader.fetchAll($0) }
        #expect(all.allSatisfy { $0.isRead == true })

        // Single PendingOperation with both stableIds
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].messageIds.count == 2)
    }

    @Test("markUnread pattern: updates isRead=0 and creates PendingOperation(.markUnread)")
    func markUnreadPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: true)

        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 0 WHERE id = ?", arguments: [msg.id])
            try PendingOperation(type: .markUnread, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX").insert(dbConn)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.isRead == false)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markUnread)
    }

    // MARK: - expandWithSiblingsByRfc822

    @Test("expandWithSiblings: includes sibling rows in other folders sharing rfc822MessageId")
    func expandSiblingsAcrossFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Self-send: same rfc822MessageId in both folders
        let inboxMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "100",
            folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        let sentMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "200",
            folderId: sentFolder.id, folderPath: "Sent",
            isInInbox: false, isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        // Unrelated message — must NOT be included
        let unrelated = try TestDatabase.insertMessageHeader(
            db, messageId: "300",
            folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "other@example.com"
        )

        let expanded = try db.read { dbConn in
            try AccountManager.expandWithSiblingsByRfc822(messages: [inboxMsg], db: dbConn)
        }

        let ids = Set(expanded.map(\.id))
        #expect(ids.count == 2)
        #expect(ids.contains(inboxMsg.id))
        #expect(ids.contains(sentMsg.id))
        #expect(!ids.contains(unrelated.id))
    }

    @Test("expandWithSiblings: returns input unchanged when rfc822MessageId is nil")
    func expandSiblingsNoRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false, rfc822MessageId: nil)

        let expanded = try db.read { dbConn in
            try AccountManager.expandWithSiblingsByRfc822(messages: [msg], db: dbConn)
        }
        #expect(expanded.count == 1)
        #expect(expanded[0].id == msg.id)
    }

    @Test("expandWithSiblings: dedupes when input already contains both siblings")
    func expandSiblingsAlreadyIncluded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let inboxMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        let sentMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: sentFolder.id, folderPath: "Sent",
            isInInbox: false, isRead: false, rfc822MessageId: "selfsend@example.com"
        )

        let expanded = try db.read { dbConn in
            try AccountManager.expandWithSiblingsByRfc822(messages: [inboxMsg, sentMsg], db: dbConn)
        }
        #expect(expanded.count == 2)
    }

    @Test("expandWithSiblings: does not cross account boundaries")
    func expandSiblingsAccountScoped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@example.com")
        let folder1 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let folder2 = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        let msgA = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: folder1.id, accountId: "acc1", folderPath: "INBOX",
            isRead: false, rfc822MessageId: "shared@example.com"
        )
        // Different account, same rfc822 — must NOT be returned
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: folder2.id, accountId: "acc2", folderPath: "INBOX",
            isRead: false, rfc822MessageId: "shared@example.com"
        )

        let expanded = try db.read { dbConn in
            try AccountManager.expandWithSiblingsByRfc822(messages: [msgA], db: dbConn)
        }
        #expect(expanded.count == 1)
        #expect(expanded[0].id == msgA.id)
    }

    /// Replicates `AccountManager.markRead` transaction body against an in-memory DB,
    /// using the SAME `countCurrentlyUnread` SQL the production code uses, so tests
    /// validate the count math (not just the simple "all unread → all read" case).
    private func simulateMarkRead(_ messages: [MessageHeader], db: DatabaseQueue) throws {
        try db.write { dbConn in
            let expanded = try AccountManager.expandWithSiblingsByRfc822(messages: messages, db: dbConn)
            let grouped = Dictionary(grouping: expanded) { "\($0.accountId)|\($0.folderPath)" }
            for (_, msgs) in grouped {
                let msgIds = msgs.map(\.id)
                let stableIds = msgs.map(\.stableId)
                let folderId = msgs[0].folderId
                // Mirror countCurrentlyUnread: COUNT WHERE id IN (...) AND isRead = 0
                let placeholders = msgIds.map { _ in "?" }.joined(separator: ",")
                let newlyRead = try Int.fetchOne(
                    dbConn,
                    sql: "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND isRead = 0",
                    arguments: StatementArguments(msgIds)
                ) ?? 0
                try MessageHeader
                    .filter(msgIds.contains(Column("id")))
                    .updateAll(dbConn, Column("isRead").set(to: true))
                if newlyRead > 0 {
                    try dbConn.execute(
                        sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?",
                        arguments: [newlyRead, folderId]
                    )
                }
                try PendingOperation(
                    type: .markRead, messageIds: stableIds,
                    accountId: msgs[0].accountId, folderPath: msgs[0].folderPath
                ).insert(dbConn)
            }
        }
    }

    /// Mirror of `simulateMarkRead` for `markUnread`.
    private func simulateMarkUnread(_ messages: [MessageHeader], db: DatabaseQueue) throws {
        try db.write { dbConn in
            let expanded = try AccountManager.expandWithSiblingsByRfc822(messages: messages, db: dbConn)
            let grouped = Dictionary(grouping: expanded) { "\($0.accountId)|\($0.folderPath)" }
            for (_, msgs) in grouped {
                let msgIds = msgs.map(\.id)
                let stableIds = msgs.map(\.stableId)
                let folderId = msgs[0].folderId
                let placeholders = msgIds.map { _ in "?" }.joined(separator: ",")
                let alreadyUnread = try Int.fetchOne(
                    dbConn,
                    sql: "SELECT COUNT(*) FROM messageHeader WHERE id IN (\(placeholders)) AND isRead = 0",
                    arguments: StatementArguments(msgIds)
                ) ?? 0
                let newlyUnread = msgIds.count - alreadyUnread
                try MessageHeader
                    .filter(msgIds.contains(Column("id")))
                    .updateAll(dbConn, Column("isRead").set(to: false))
                if newlyUnread > 0 {
                    try dbConn.execute(
                        sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?",
                        arguments: [newlyUnread, folderId]
                    )
                }
                try PendingOperation(
                    type: .markUnread, messageIds: stableIds,
                    accountId: msgs[0].accountId, folderPath: msgs[0].folderPath
                ).insert(dbConn)
            }
        }
    }

    @Test("markRead with self-send: both folder rows become read, both unread counts decremented, two PendingOps")
    func markReadSelfSendPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let inboxMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: sentFolder.id, folderPath: "Sent",
            isInInbox: false, isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [inboxFolder.id])
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [sentFolder.id])
        }

        try simulateMarkRead([inboxMsg], db: db)

        // Both rows are now read
        let allHeaders = try db.read { try MessageHeader.fetchAll($0) }
        #expect(allHeaders.count == 2)
        guard allHeaders.count == 2 else { return }
        #expect(allHeaders.allSatisfy { $0.isRead == true })

        // Both folders dropped to 0
        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 0)
        #expect(sentAfter?.unreadCount == 0)

        // One PendingOperation per folder
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2)
        guard ops.count == 2 else { return }
        let folderPaths = Set(ops.map(\.folderPath))
        #expect(folderPaths == ["INBOX", "Sent"])
        #expect(ops.allSatisfy { $0.type == .markRead })
    }

    @Test("markUnread with self-send: both folder rows become unread, both unread counts incremented, two PendingOps")
    func markUnreadSelfSendPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Both rows initially READ
        let inboxMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: true, rfc822MessageId: "selfsend@example.com"
        )
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: sentFolder.id, folderPath: "Sent",
            isInInbox: false, isRead: true, rfc822MessageId: "selfsend@example.com"
        )
        // Both folders start with unreadCount=0
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = ?", arguments: [inboxFolder.id])
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = ?", arguments: [sentFolder.id])
        }

        try simulateMarkUnread([inboxMsg], db: db)

        let allHeaders = try db.read { try MessageHeader.fetchAll($0) }
        #expect(allHeaders.count == 2)
        guard allHeaders.count == 2 else { return }
        #expect(allHeaders.allSatisfy { $0.isRead == false })

        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 1)
        #expect(sentAfter?.unreadCount == 1)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2)
        guard ops.count == 2 else { return }
        #expect(Set(ops.map(\.folderPath)) == ["INBOX", "Sent"])
        #expect(ops.allSatisfy { $0.type == .markUnread })
    }

    @Test("markRead with self-send: sibling already read — count math doesn't double-decrement Sent folder")
    func markReadSelfSendSiblingAlreadyRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Inbox row UNREAD, Sent row already READ
        let inboxMsg = try TestDatabase.insertMessageHeader(
            db, messageId: "100", folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "200", folderId: sentFolder.id, folderPath: "Sent",
            isInInbox: false, isRead: true, rfc822MessageId: "selfsend@example.com"
        )
        // Inbox folder has 1 unread, Sent folder has 0 (sibling already read)
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [inboxFolder.id])
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = ?", arguments: [sentFolder.id])
        }

        try simulateMarkRead([inboxMsg], db: db)

        // Both rows now read
        let allHeaders = try db.read { try MessageHeader.fetchAll($0) }
        #expect(allHeaders.allSatisfy { $0.isRead == true })

        // Inbox: 1 → 0. Sent: 0 → 0 (already read sibling, no double-decrement, no negative).
        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 0)
        #expect(sentAfter?.unreadCount == 0)

        // Still creates a PendingOp for both folders (idempotent server-side)
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2)
    }

    @Test("markRead mixed batch: standalone msg + self-send msg → standalone gets one PendingOp, self-send gets two")
    func markReadMixedSiblingsAndStandalone() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Standalone unread inbox message (no sibling)
        let standalone = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "lone@example.com"
        )
        // Self-send pair
        let selfInbox = try TestDatabase.insertMessageHeader(
            db, messageId: "2", folderId: inboxFolder.id, folderPath: "INBOX",
            isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        _ = try TestDatabase.insertMessageHeader(
            db, messageId: "3", folderId: sentFolder.id, folderPath: "Sent",
            isInInbox: false, isRead: false, rfc822MessageId: "selfsend@example.com"
        )
        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = ?", arguments: [inboxFolder.id])
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = ?", arguments: [sentFolder.id])
        }

        try simulateMarkRead([standalone, selfInbox], db: db)

        // All three rows now read
        let allHeaders = try db.read { try MessageHeader.fetchAll($0) }
        #expect(allHeaders.count == 3)
        #expect(allHeaders.allSatisfy { $0.isRead == true })

        // Inbox: 2 → 0 (both inbox rows). Sent: 1 → 0 (sibling fanout).
        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 0)
        #expect(sentAfter?.unreadCount == 0)

        // Two PendingOps total: one for INBOX (covering both standalone+selfInbox), one for Sent (sibling).
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2)
        guard ops.count == 2 else { return }
        let inboxOp = ops.first { $0.folderPath == "INBOX" }
        let sentOp = ops.first { $0.folderPath == "Sent" }
        #expect(inboxOp?.messageIds.count == 2)  // standalone + selfInbox grouped together
        #expect(sentOp?.messageIds.count == 1)   // sibling alone
    }

    @Test("expandWithSiblings: empty input list returns empty")
    func expandSiblingsEmptyInput() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let expanded = try db.read { dbConn in
            try AccountManager.expandWithSiblingsByRfc822(messages: [], db: dbConn)
        }
        #expect(expanded.isEmpty)
    }

    // MARK: - markFlagged pattern

    @Test("markFlagged=true: updates isFlagged and creates PendingOperation(.markFlagged)")
    func markFlaggedPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1")

        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [true, msg.id])
            try PendingOperation(type: .markFlagged, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX").insert(dbConn)
        }

        let updated = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(updated?.isFlagged == true)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .markFlagged)
    }

    @Test("markFlagged=false: creates PendingOperation(.markUnflagged)")
    func markUnflaggedPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1")

        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [false, msg.id])
            try PendingOperation(type: .markUnflagged, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX").insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops[0].type == .markUnflagged)
    }

    // MARK: - Optimistic Move Pattern

    @Test("optimisticMoveToFolder: reassigns folderId, folderPath, isInInbox + creates PendingOperation with destination")
    func movePattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)

        let destFolderId = "acc1:Archive"
        let destPath = "Archive"

        try db.write { dbConn in
            // Replicate optimisticMoveToFolder logic
            let destFolder = try Folder.fetchOne(dbConn, key: destFolderId)
            let destIsInbox = destFolder?.role == .inbox

            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: destPath),
                Column("isInInbox").set(to: destIsInbox)
            )
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", destinationPath: destPath).insert(dbConn)
        }

        let moved = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(moved?.folderId == destFolderId)
        #expect(moved?.folderPath == destPath)
        #expect(moved?.isInInbox == false)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .move)
        #expect(ops[0].destinationPath == destPath)
    }

    @Test("optimisticMoveToFolder: moving to inbox sets isInInbox=true")
    func moveToInboxSetsFlag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)

        try db.write { dbConn in
            let destFolder = try Folder.fetchOne(dbConn, key: "acc1:INBOX")
            let destIsInbox = destFolder?.role == .inbox

            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: "acc1:INBOX"),
                Column("folderPath").set(to: "INBOX"),
                Column("isInInbox").set(to: destIsInbox)
            )
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: "Archive", destinationPath: "INBOX").insert(dbConn)
        }

        let moved = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(moved?.isInInbox == true)
    }

    // MARK: - Self-move guard

    @Test("Self-move is a no-op: no PendingOperation created, no local state changed")
    func selfMoveNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)

        // Replicate the guard from optimisticMoveToFolder
        let folderPath = "Archive"
        let destinationPath = "Archive"

        if folderPath != destinationPath {
            try db.write { dbConn in
                try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                    Column("folderId").set(to: "acc1:Archive"),
                    Column("folderPath").set(to: destinationPath),
                    Column("isInInbox").set(to: false)
                )
                try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: folderPath, destinationPath: destinationPath).insert(dbConn)
            }
        }

        // No PendingOperation should be created
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty, "Self-move should not create any PendingOperation")

        // Message state should be unchanged
        let unchanged = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(unchanged?.folderId == "acc1:Archive")
        #expect(unchanged?.folderPath == "Archive")
    }

    // MARK: - Tag removal on inbox exit

    @Test("Tag removal: removeTag ops queued BEFORE move op (FIFO ordering)")
    func moveWithTagRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX",
            isInInbox: true, actionTag: .reply
        )

        try db.write { dbConn in
            let leavingInbox = msg.isInInbox
            let removeTagsIfLeavingInbox = true

            // Tag removal BEFORE move (FIFO ordering) — mirrors optimisticMoveToFolder
            if removeTagsIfLeavingInbox && leavingInbox {
                if let tag = msg.actionTag {
                    try PendingOperation(type: .removeTag, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", tagValue: tag.rawValue).insert(dbConn)
                }
            }

            // Then the move
            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive").insert(dbConn)
        }

        let ops = try db.read { dbConn in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(dbConn)
        }
        #expect(ops.count == 2)
        #expect(ops[0].type == .removeTag, "removeTag must appear BEFORE move in FIFO order")
        #expect(ops[0].tagValue == "reply")
        #expect(ops[1].type == .move)
    }

    @Test("Tag removal: multiple tagged messages each get separate removeTag ops")
    func multipleTaggedMessagesRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        let msg1 = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX",
            isInInbox: true, actionTag: .reply
        )
        let msg2 = try TestDatabase.insertMessageHeader(
            db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX",
            isInInbox: true, actionTag: .archive
        )

        let msgs = [msg1, msg2]

        try db.write { dbConn in
            // Replicate optimisticMoveToFolder: tag removal per message
            let leavingInbox = msgs[0].isInInbox
            if leavingInbox {
                for msg in msgs where msg.actionTag != nil {
                    try PendingOperation(type: .removeTag, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", tagValue: msg.actionTag?.rawValue).insert(dbConn)
                }
            }

            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Trash"),
                Column("folderPath").set(to: "Trash"),
                Column("isInInbox").set(to: false)
            )
            try PendingOperation(type: .delete, messageIds: msgs.map(\.stableId), accountId: "acc1", folderPath: "INBOX", destinationPath: "Trash").insert(dbConn)
        }

        let ops = try db.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
        #expect(ops.count == 3, "2 removeTag ops + 1 delete op")
        #expect(ops[0].type == OperationType.removeTag)
        #expect(ops[1].type == OperationType.removeTag)
        #expect(ops[2].type == OperationType.delete)
    }

    // MARK: - Tag removal skipped for non-inbox

    @Test("Tag removal skipped: moving from non-inbox folder does NOT create removeTag ops")
    func tagRemovalSkippedForNonInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:Sent", folderPath: "Sent",
            isInInbox: false, actionTag: .reply
        )

        try db.write { dbConn in
            let leavingInbox = msg.isInInbox
            let removeTagsIfLeavingInbox = true

            // This condition should NOT fire because isInInbox is false
            if removeTagsIfLeavingInbox && leavingInbox {
                if let tag = msg.actionTag {
                    try PendingOperation(type: .removeTag, messageIds: [msg.stableId], accountId: "acc1", folderPath: "Sent", tagValue: tag.rawValue).insert(dbConn)
                }
            }

            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Trash"),
                Column("folderPath").set(to: "Trash"),
                Column("isInInbox").set(to: false)
            )
            try PendingOperation(type: .delete, messageIds: [msg.stableId], accountId: "acc1", folderPath: "Sent", destinationPath: "Trash").insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1, "Only the delete op — no removeTag for non-inbox source")
        #expect(ops[0].type == .delete)
    }

    @Test("Tag removal skipped: message with nil actionTag does NOT create removeTag op")
    func tagRemovalSkippedForNilTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX",
            isInInbox: true, actionTag: nil
        )

        try db.write { dbConn in
            let leavingInbox = msg.isInInbox
            if leavingInbox {
                // msg.actionTag is nil, so this block is skipped
                if msg.actionTag != nil {
                    try PendingOperation(type: .removeTag, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", tagValue: msg.actionTag?.rawValue).insert(dbConn)
                }
            }

            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            try PendingOperation(type: .archive, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive").insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1, "Only archive op — no removeTag for nil actionTag")
        #expect(ops[0].type == .archive)
    }

    // MARK: - Multi-message grouping

    @Test("Grouped messages from different folders create separate PendingOperations per group")
    func groupedOperations() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX")
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX")
        let msg3 = try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false)

        let messages = [msg1, msg2, msg3]
        let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }

        try db.write { dbConn in
            for (_, msgs) in grouped {
                let accountId = msgs[0].accountId
                let folderPath = msgs[0].folderPath
                let stableIds = msgs.map(\.stableId)
                for msg in msgs {
                    try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [msg.id])
                }
                try PendingOperation(type: .markRead, messageIds: stableIds, accountId: accountId, folderPath: folderPath).insert(dbConn)
            }
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2, "One PendingOperation for INBOX group, one for Sent group")

        // Verify all messages are read
        let headers = try db.read { try MessageHeader.fetchAll($0) }
        #expect(headers.allSatisfy { $0.isRead == true })
    }

    @Test("Grouped messages from different accounts create separate PendingOperations")
    func groupedOperationsMultiAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "b@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc2:INBOX", accountId: "acc2", folderPath: "INBOX")

        let messages = [msg1, msg2]
        let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }

        try db.write { dbConn in
            for (_, msgs) in grouped {
                let stableIds = msgs.map(\.stableId)
                for msg in msgs {
                    try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [msg.id])
                }
                try PendingOperation(type: .markRead, messageIds: stableIds, accountId: msgs[0].accountId, folderPath: msgs[0].folderPath).insert(dbConn)
            }
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 2, "Separate PendingOperations for different accounts")
        let accountIds = Set(ops.map(\.accountId))
        #expect(accountIds == ["acc1", "acc2"])
    }

    // MARK: - archive() resolves archive folder

    @Test("archive resolves archive folder from DB and moves to it")
    func archiveResolvesFolderAndMoves() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)

        // Replicate archive() logic: resolve archive folder path via DB query
        let archivePath: String? = try db.read { dbConn in
            try Folder.filter(Column("accountId") == msg.accountId && Column("role") == FolderRole.archive.rawValue)
                .fetchOne(dbConn)?.path
        }
        #expect(archivePath == "Archive", "Should resolve archive folder from DB")

        // Then perform the move
        try db.write { dbConn in
            let destFolderId = "\(msg.accountId):\(archivePath!)"
            let destFolder = try Folder.fetchOne(dbConn, key: destFolderId)
            let destIsInbox = destFolder?.role == .inbox

            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: archivePath!),
                Column("isInInbox").set(to: destIsInbox)
            )
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: msg.accountId, folderPath: "INBOX", destinationPath: archivePath!).insert(dbConn)
        }

        let moved = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(moved?.folderId == "acc1:Archive")
        #expect(moved?.folderPath == "Archive")
        #expect(moved?.isInInbox == false)
    }

    @Test("archive returns early when no archive folder exists")
    func archiveNoFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        // No archive folder inserted

        let archivePath: String? = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") == FolderRole.archive.rawValue)
                .fetchOne(dbConn)?.path
        }
        #expect(archivePath == nil, "No archive folder should be found")

        // No PendingOperation should be created
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty)
    }

    // MARK: - delete() resolves trash folder

    @Test("delete resolves trash folder from DB and moves to it")
    func deleteResolvesFolderAndMoves() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)

        // Replicate delete() logic: resolve trash folder path via DB query
        let trashPath: String? = try db.read { dbConn in
            try Folder.filter(Column("accountId") == msg.accountId && Column("role") == FolderRole.trash.rawValue)
                .fetchOne(dbConn)?.path
        }
        #expect(trashPath == "Trash", "Should resolve trash folder from DB")

        // Then perform the move
        try db.write { dbConn in
            let destFolderId = "\(msg.accountId):\(trashPath!)"
            let destFolder = try Folder.fetchOne(dbConn, key: destFolderId)
            let destIsInbox = destFolder?.role == .inbox

            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: trashPath!),
                Column("isInInbox").set(to: destIsInbox)
            )
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: msg.accountId, folderPath: "INBOX", destinationPath: trashPath!).insert(dbConn)
        }

        let moved = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(moved?.folderId == "acc1:Trash")
        #expect(moved?.folderPath == "Trash")
    }

    @Test("delete returns early when no trash folder exists")
    func deleteNoFolder() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        // No trash folder inserted

        let trashPath: String? = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1" && Column("role") == FolderRole.trash.rawValue)
                .fetchOne(dbConn)?.path
        }
        #expect(trashPath == nil, "No trash folder should be found")

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.isEmpty)
    }

    // MARK: - Undo: cancel queued ops and restore

    @Test("undoDestructiveAction: cancels queued op and restores message to original folder via save (upsert)")
    func undoCancelsQueuedOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )

        // Simulate archive: move to Archive
        try db.write { dbConn in
            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive").insert(dbConn)
        }

        // Simulate undo: cancel the queued op and restore
        try db.write { dbConn in
            let queuedOps = try PendingOperation
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(dbConn)

            let idsSet = Set([msg.messageId])
            let stableIdsSet = Set([msg.stableId])
            var cancelledOriginal = false

            for op in queuedOps {
                let opMsgIds = Set(op.messageIds)
                if (!opMsgIds.isDisjoint(with: idsSet) || !opMsgIds.isDisjoint(with: stableIdsSet)) &&
                   (op.type == .move || op.type == .removeTag) {
                    var cancelled = op
                    cancelled.status = PendingStatus.cancelled.rawValue
                    try cancelled.save(dbConn)
                    if op.type == .move { cancelledOriginal = true }
                }
            }

            #expect(cancelledOriginal == true)

            // Restore message — use save() (upsert)
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(dbConn)
        }

        let restoredMsg = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(restoredMsg?.folderId == "acc1:INBOX")
        #expect(restoredMsg?.isInInbox == true)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].status == PendingStatus.cancelled.rawValue)
    }

    @Test("undoDestructiveAction: also cancels associated removeTag ops")
    func undoCancelsRemoveTagOps() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX",
            isInInbox: true, actionTag: .reply
        )

        // Simulate archive with tag removal
        try db.write { dbConn in
            try PendingOperation(type: .removeTag, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", tagValue: "reply").insert(dbConn)
            try PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive").insert(dbConn)
        }

        // Undo should cancel both removeTag AND move
        try db.write { dbConn in
            let queuedOps = try PendingOperation
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(dbConn)

            let stableIdsSet = Set([msg.stableId])
            for op in queuedOps {
                let opMsgIds = Set(op.messageIds)
                if !opMsgIds.isDisjoint(with: stableIdsSet) &&
                   (op.type == .move || op.type == .removeTag) {
                    var cancelled = op
                    cancelled.status = PendingStatus.cancelled.rawValue
                    try cancelled.save(dbConn)
                }
            }
        }

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        let allCancelled = ops.allSatisfy { $0.status == PendingStatus.cancelled.rawValue }
        #expect(allCancelled, "Both removeTag and move ops should be cancelled")
        #expect(ops.count == 2)
    }

    @Test("undoDestructiveAction: save() (upsert) re-creates message when drain deleted the row")
    func undoUpsertRecreatesDeletedRow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // Create then delete (simulating drain cleanup)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        try db.write { _ = try MessageHeader.deleteOne($0, key: msg.id) }

        // Verify deleted
        let deleted = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(deleted == nil)

        // save() should re-insert the row
        try db.write { dbConn in
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(dbConn)
        }

        let header = try db.read { try MessageHeader.fetchOne($0, key: msg.id) }
        #expect(header != nil, "save() should re-create the deleted row")
        #expect(header?.folderId == "acc1:INBOX")
    }

    // MARK: - Undo: move-back when original already executed

    @Test("undoDestructiveAction: queues move-back PendingOperation when original op is in-flight")
    func undoQueuesMoveBackForInFlightOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "gmail-id-1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )

        // Simulate archive with in-flight status (already being executed)
        try db.write { dbConn in
            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            var op = PendingOperation(type: .move, messageIds: [msg.stableId], accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive")
            op.status = PendingStatus.inFlight.rawValue
            try op.insert(dbConn)
        }

        // Simulate undo: no queued ops to cancel, so queue a move-back
        try db.write { dbConn in
            let queuedOps = try PendingOperation
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == PendingStatus.queued.rawValue)
                .fetchAll(dbConn)

            // No queued ops to cancel — in-flight ops are not cancellable
            #expect(queuedOps.isEmpty)

            // Restore message locally
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(dbConn)

            // Queue move-back — Gmail uses messageId (stable across moves)
            let account = try Account.fetchOne(dbConn, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            let moveBack = PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "Archive", destinationPath: "INBOX")
            try moveBack.insert(dbConn)
        }

        let ops = try db.read { dbConn in
            try PendingOperation.filter(Column("status") == PendingStatus.queued.rawValue).fetchAll(dbConn)
        }
        #expect(ops.count == 1)
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == "Archive")
        #expect(ops[0].destinationPath == "INBOX")
        #expect(ops[0].messageIds == ["gmail-id-1"], "Gmail move-back uses messageId")
    }

    // MARK: - IMAP/iCloud undo uses rfc822MessageId for move-back

    @Test("IMAP undo: move-back uses rfc822MessageId (UIDs change on MOVE)")
    func imapUndoUsesRfc822MessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "500", folderId: "acc1:Trash", accountId: "acc1",
            folderPath: "Trash", isInInbox: false, rfc822MessageId: "<unique-msg@example.com>"
        )

        // Simulate undo for IMAP — no queued ops, must queue move-back
        try db.write { dbConn in
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(dbConn)

            let account = try Account.fetchOne(dbConn, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            try PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "Trash", destinationPath: "INBOX").insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].messageIds == ["<unique-msg@example.com>"], "IMAP undo must use rfc822MessageId for resolveUID")
    }

    @Test("iCloud undo: uses rfc822MessageId like IMAP")
    func icloudUndoUsesRfc822MessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .icloud)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "300", folderId: "acc1:Trash", accountId: "acc1",
            folderPath: "Trash", isInInbox: false, rfc822MessageId: "<icloud-msg@me.com>"
        )

        try db.write { dbConn in
            let account = try Account.fetchOne(dbConn, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            try PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "Trash", destinationPath: "INBOX").insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops[0].messageIds == ["<icloud-msg@me.com>"], "iCloud undo must use rfc822MessageId like IMAP")
    }

    // MARK: - Gmail undo uses messageId for move-back

    @Test("Gmail undo: uses stable messageId for move-back (IDs don't change on move)")
    func gmailUndoUsesMessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "TRASH", path: "TRASH", role: .trash)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "gmail-stable-id", folderId: "acc1:TRASH", accountId: "acc1",
            folderPath: "TRASH", isInInbox: false, rfc822MessageId: "<msg@example.com>"
        )

        try db.write { dbConn in
            let account = try Account.fetchOne(dbConn, key: "acc1")
            let moveBackIds: [String]
            if account?.provider == .imap || account?.provider == .icloud {
                moveBackIds = [msg].compactMap(\.rfc822MessageId)
            } else {
                moveBackIds = [msg.messageId]
            }
            try PendingOperation(type: .move, messageIds: moveBackIds, accountId: "acc1", folderPath: "TRASH", destinationPath: "INBOX").insert(dbConn)
        }

        let ops = try db.read { try PendingOperation.filter(Column("type") == OperationType.move.rawValue).fetchAll($0) }
        #expect(ops[0].messageIds == ["gmail-stable-id"], "Gmail undo must use stable messageId")
    }

    // MARK: - stableId computation

    @Test("stableId prefers rfc822MessageId for numeric messageId (IMAP)")
    func stableIdIMAPPreference() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "42", rfc822MessageId: "<unique@example.com>"
        )
        #expect(msg.stableId == "<unique@example.com>")
    }

    @Test("stableId uses messageId for non-numeric IDs (Gmail/Exchange)")
    func stableIdGmailExchange() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .gmail)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "gmail-msg-id-abc", rfc822MessageId: "<unique@example.com>"
        )
        #expect(msg.stableId == "gmail-msg-id-abc")
    }

    @Test("stableId falls back to messageId when rfc822MessageId is nil")
    func stableIdFallback() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(
            db, messageId: "42", rfc822MessageId: nil
        )
        #expect(msg.stableId == "42")
    }

    // MARK: - Inline unread count updates (same-transaction)

    @Test("markRead pattern: decrements folder.unreadCount in same transaction")
    func markReadDecrementsUnreadCount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Set initial unreadCount = 3
        try db.write { try $0.execute(sql: "UPDATE folder SET unreadCount = 3 WHERE id = 'acc1:INBOX'") }

        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: false)
        let msgs = [msg1, msg2]

        // Replicate markRead inline unread count pattern
        try db.write { dbConn in
            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn, Column("isRead").set(to: true))
            let folderId = msgs[0].folderId
            let newlyRead = msgs.filter { !$0.isRead }.count
            if newlyRead > 0 {
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, folderId])
            }
            try PendingOperation(type: .markRead, messageIds: msgs.map(\.stableId), accountId: "acc1", folderPath: "INBOX").insert(dbConn)
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 1, "3 - 2 newly read = 1")
    }

    @Test("markRead pattern: skips already-read messages (no double-decrement)")
    func markReadSkipsAlreadyRead() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write { try $0.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = 'acc1:INBOX'") }

        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: true) // already read
        let msgs = [msg1, msg2]

        try db.write { dbConn in
            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn, Column("isRead").set(to: true))
            let folderId = msgs[0].folderId
            let newlyRead = msgs.filter { !$0.isRead }.count // only msg1
            if newlyRead > 0 {
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, folderId])
            }
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 1, "2 - 1 newly read = 1 (already-read msg2 not counted)")
    }

    @Test("markUnread pattern: increments folder.unreadCount in same transaction")
    func markUnreadIncrementsUnreadCount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write { try $0.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = 'acc1:INBOX'") }

        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: true)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: true)
        let msgs = [msg1, msg2]

        try db.write { dbConn in
            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn, Column("isRead").set(to: false))
            let folderId = msgs[0].folderId
            let newlyUnread = msgs.filter { $0.isRead }.count
            if newlyUnread > 0 {
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [newlyUnread, folderId])
            }
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 3, "1 + 2 newly unread = 3")
    }

    @Test("markUnread pattern: skips already-unread messages (no double-increment)")
    func markUnreadSkipsAlreadyUnread() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try db.write { try $0.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = 'acc1:INBOX'") }

        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: true)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", isRead: false) // already unread
        let msgs = [msg1, msg2]

        try db.write { dbConn in
            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn, Column("isRead").set(to: false))
            let folderId = msgs[0].folderId
            let newlyUnread = msgs.filter { $0.isRead }.count // only msg1
            if newlyUnread > 0 {
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [newlyUnread, folderId])
            }
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 3, "2 + 1 newly unread = 3 (already-unread msg2 not counted)")
    }

    @Test("markRead pattern: unreadCount never goes negative")
    func markReadUnreadCountFloorZero() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Start at 0 (stale/wrong count)
        try db.write { try $0.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = 'acc1:INBOX'") }

        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false)

        try db.write { dbConn in
            try dbConn.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [msg.id])
            let newlyRead = 1
            try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [newlyRead, "acc1:INBOX"])
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.unreadCount == 0, "MAX(0, 0-1) = 0, never negative")
    }

    @Test("move pattern: decrements source and increments destination unreadCount")
    func moveAdjustsBothFolderCounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        try db.write {
            try $0.execute(sql: "UPDATE folder SET unreadCount = 5 WHERE id = 'acc1:INBOX'")
            try $0.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = 'acc1:Archive'")
        }

        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isRead: false)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX", isRead: false)
        let msgs = [msg1, msg2]

        // Replicate optimisticMoveToFolder inline unread count pattern
        try db.write { dbConn in
            let destFolderId = "acc1:Archive"
            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            let unreadMoving = msgs.filter { !$0.isRead }.count
            if unreadMoving > 0 {
                let sourceFolderId = msgs[0].folderId
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, sourceFolderId])
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
            }
            try PendingOperation(type: .move, messageIds: msgs.map(\.stableId), accountId: "acc1", folderPath: "INBOX", destinationPath: "Archive").insert(dbConn)
        }

        let inbox = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        let archive = try db.read { try Folder.fetchOne($0, key: "acc1:Archive") }
        #expect(inbox?.unreadCount == 3, "5 - 2 unread moved = 3")
        #expect(archive?.unreadCount == 4, "2 + 2 unread moved = 4")
    }

    @Test("move pattern: all-read messages don't change unread counts")
    func moveAllReadNoCountChange() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)

        try db.write {
            try $0.execute(sql: "UPDATE folder SET unreadCount = 3 WHERE id = 'acc1:INBOX'")
            try $0.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = 'acc1:Trash'")
        }

        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isRead: true)

        try db.write { dbConn in
            let destFolderId = "acc1:Trash"
            try MessageHeader.filter(Column("id") == msg.id).updateAll(dbConn,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: "Trash"),
                Column("isInInbox").set(to: false)
            )
            let unreadMoving = [msg].filter { !$0.isRead }.count
            if unreadMoving > 0 {
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, msg.folderId])
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
            }
        }

        let inbox = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        let trash = try db.read { try Folder.fetchOne($0, key: "acc1:Trash") }
        #expect(inbox?.unreadCount == 3, "No change — moved message was read")
        #expect(trash?.unreadCount == 0, "No change — moved message was read")
    }

    @Test("move pattern: mixed read/unread batch adjusts only unread count")
    func moveMixedReadUnreadBatch() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        try db.write {
            try $0.execute(sql: "UPDATE folder SET unreadCount = 4 WHERE id = 'acc1:INBOX'")
            try $0.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = 'acc1:Archive'")
        }

        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isRead: false)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX", isRead: true)
        let msg3 = try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:INBOX", folderPath: "INBOX", isRead: false)
        let msgs = [msg1, msg2, msg3]

        try db.write { dbConn in
            let destFolderId = "acc1:Archive"
            let msgIds = msgs.map(\.id)
            try MessageHeader.filter(msgIds.contains(Column("id"))).updateAll(dbConn,
                Column("folderId").set(to: destFolderId),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
            let unreadMoving = msgs.filter { !$0.isRead }.count // 2 unread
            if unreadMoving > 0 {
                let sourceFolderId = msgs[0].folderId
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadMoving, sourceFolderId])
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadMoving, destFolderId])
            }
        }

        let inbox = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        let archive = try db.read { try Folder.fetchOne($0, key: "acc1:Archive") }
        #expect(inbox?.unreadCount == 2, "4 - 2 unread moved = 2")
        #expect(archive?.unreadCount == 2, "0 + 2 unread moved = 2")
    }

    @Test("undo pattern: restores unread counts on both source and destination folders")
    func undoRestoresUnreadCounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // State after archive: inbox lost 2 unread, archive gained 2
        try db.write {
            try $0.execute(sql: "UPDATE folder SET unreadCount = 3 WHERE id = 'acc1:INBOX'")
            try $0.execute(sql: "UPDATE folder SET unreadCount = 2 WHERE id = 'acc1:Archive'")
        }

        // Messages currently in archive (post-move), originally unread
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false, isRead: false)
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false, isRead: false)
        let messages = [msg1, msg2]

        // Replicate undoDestructiveAction inline unread count pattern
        let toFolderId = "acc1:INBOX"
        let fromFolderPath = "Archive"
        let accountId = "acc1"

        try db.write { dbConn in
            // Restore messages
            for msg in messages {
                var restored = msg
                restored.folderId = toFolderId
                try restored.save(dbConn)
            }

            // Inline unread count update
            let unreadRestored = messages.filter { !$0.isRead }.count
            if unreadRestored > 0 {
                let fromFolderId = "\(accountId):\(fromFolderPath)"
                if !fromFolderPath.isEmpty {
                    try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadRestored, fromFolderId])
                }
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadRestored, toFolderId])
            }
        }

        let inbox = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        let archive = try db.read { try Folder.fetchOne($0, key: "acc1:Archive") }
        #expect(inbox?.unreadCount == 5, "3 + 2 restored unread = 5")
        #expect(archive?.unreadCount == 0, "2 - 2 restored unread = 0")
    }

    @Test("undo pattern: read messages don't change unread counts")
    func undoReadMessagesNoCountChange() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash)

        try db.write {
            try $0.execute(sql: "UPDATE folder SET unreadCount = 1 WHERE id = 'acc1:INBOX'")
            try $0.execute(sql: "UPDATE folder SET unreadCount = 0 WHERE id = 'acc1:Trash'")
        }

        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:Trash", folderPath: "Trash", isInInbox: false, isRead: true)

        try db.write { dbConn in
            var restored = msg
            restored.folderId = "acc1:INBOX"
            try restored.save(dbConn)

            let unreadRestored = [msg].filter { !$0.isRead }.count
            if unreadRestored > 0 {
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?", arguments: [unreadRestored, "acc1:Trash"])
                try dbConn.execute(sql: "UPDATE folder SET unreadCount = unreadCount + ? WHERE id = ?", arguments: [unreadRestored, "acc1:INBOX"])
            }
        }

        let inbox = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        let trash = try db.read { try Folder.fetchOne($0, key: "acc1:Trash") }
        #expect(inbox?.unreadCount == 1, "No change — restored message was read")
        #expect(trash?.unreadCount == 0, "No change — restored message was read")
    }
}
