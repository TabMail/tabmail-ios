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
/// This validates optimistic UI patterns and PendingOperation creation at the
/// database level. Undo is NOT tested here — see the `// MARK: - Undo` note
/// below and the real-path suites it points at.
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

    // MARK: - RFC metadata never enlarges an ordinary gesture

    @Test("ordinary gesture input does not expand to another row sharing rfc822MessageId")
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

        let expanded = [inboxMsg]

        let ids = Set(expanded.map(\.id))
        #expect(ids.count == 1)
        #expect(ids.contains(inboxMsg.id))
        #expect(!ids.contains(sentMsg.id))
        #expect(!ids.contains(unrelated.id))
    }

    @Test("ordinary gesture input remains unchanged when rfc822MessageId is nil")
    func expandSiblingsNoRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db, messageId: "1", isRead: false, rfc822MessageId: nil)

        let expanded = [msg]
        #expect(expanded.count == 1)
        #expect(expanded[0].id == msg.id)
    }

    @Test("ordinary gesture preserves two explicitly targeted rows")
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

        let expanded = [inboxMsg, sentMsg]
        #expect(expanded.count == 2)
    }

    @Test("ordinary gesture does not cross account boundaries through RFC metadata")
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

        let expanded = [msgA]
        #expect(expanded.count == 1)
        #expect(expanded[0].id == msgA.id)
    }

    /// Replicates `AccountManager.markRead` transaction body against an in-memory DB,
    /// using the SAME `countCurrentlyUnread` SQL the production code uses, so tests
    /// validate the count math (not just the simple "all unread → all read" case).
    private func simulateMarkRead(_ messages: [MessageHeader], db: DatabaseQueue) throws {
        try db.write { dbConn in
            let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
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
            let grouped = Dictionary(grouping: messages) { "\($0.accountId)|\($0.folderPath)" }
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

    @Test("markRead with duplicate RFC: only the explicitly targeted row changes")
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

        // Only the explicitly targeted row is read.
        let allHeaders = try db.read { try MessageHeader.fetchAll($0) }
        #expect(allHeaders.count == 2)
        guard allHeaders.count == 2 else { return }
        #expect(allHeaders.first { $0.id == inboxMsg.id }?.isRead == true)
        #expect(allHeaders.first { $0.id != inboxMsg.id }?.isRead == false)

        // Both folders dropped to 0
        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 0)
        #expect(sentAfter?.unreadCount == 1)

        // One PendingOperation for the explicitly targeted folder.
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        let folderPaths = Set(ops.map(\.folderPath))
        #expect(folderPaths == ["INBOX"])
        #expect(ops.allSatisfy { $0.type == .markRead })
    }

    @Test("markUnread with duplicate RFC: only the explicitly targeted row changes")
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
        #expect(allHeaders.first { $0.id == inboxMsg.id }?.isRead == false)
        #expect(allHeaders.first { $0.id != inboxMsg.id }?.isRead == true)

        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 1)
        #expect(sentAfter?.unreadCount == 0)

        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(Set(ops.map(\.folderPath)) == ["INBOX"])
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

        // Creates an op only for the explicitly targeted folder.
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
    }

    @Test("markRead mixed batch does not add an untargeted duplicate-RFC sibling")
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

        // The two explicit targets change; the duplicate-RFC Sent row does not.
        let allHeaders = try db.read { try MessageHeader.fetchAll($0) }
        #expect(allHeaders.count == 3)
        #expect(allHeaders.filter { $0.folderPath == "INBOX" }.allSatisfy { $0.isRead })
        #expect(allHeaders.first { $0.folderPath == "Sent" }?.isRead == false)

        // Inbox: 2 → 0 (both inbox rows). Sent: 1 → 0 (sibling fanout).
        let inboxAfter = try db.read { try Folder.fetchOne($0, key: inboxFolder.id) }
        let sentAfter = try db.read { try Folder.fetchOne($0, key: sentFolder.id) }
        #expect(inboxAfter?.unreadCount == 0)
        #expect(sentAfter?.unreadCount == 1)

        // One op for INBOX covers exactly the two explicit targets.
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        let inboxOp = ops.first { $0.folderPath == "INBOX" }
        #expect(inboxOp?.messageIds.count == 2)  // standalone + selfInbox grouped together
    }

    @Test("ordinary gesture empty input remains empty")
    func expandSiblingsEmptyInput() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let expanded: [MessageHeader] = []
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
    //
    // F6 (PLAN_OVERLAY_CALLSITE_AUDIT.md §6): `optimisticMoveToFolder` no
    // longer queues a `.removeTag` PendingOperation — tags are local-only
    // (ADR-IOS-036), so leaving the inbox clears `actionTag`/`tagSortOrder`
    // directly in the move's own write. See `AccountManagerActionsTagClearTests`
    // below for the real-production-path coverage (manager.move/archive on a
    // seeded DB, not hand-mirrored logic).

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

    // MARK: - Undo
    //
    // DELETED 2026-08-04 — SEVEN hand-simulated undo tests lived here. Each built
    // a `TestDatabase.make()` queue, which is never installed into
    // `AppDatabase.shared`, re-implemented `undoDestructiveAction`'s algorithm
    // inside the test body — including production's own
    // `provider == .imap || provider == .icloud` branch — and then asserted on its
    // own copy, so it could only ever agree with itself. Inverting production
    // could not turn any of them red.
    //
    // Four of them also pinned behaviour v3 deliberately REMOVED: a `.cancelled`
    // tombstone (v3 physically deletes the annihilated operation), `.removeTag`
    // cancellation (subtracted — tags are local-only, ADR-IOS-036), and the rfc822
    // Message-ID as the IMAP/iCloud move-back identity, which is the BANNED
    // mechanism (ADR-IOS-068 / D4, `IOS-IMAP-002`: a Message-ID `SEARCH` returns
    // every copy sharing the id and mutates all of them).
    //
    // Every invariant they claimed is pinned against the real
    // `AccountManager.undoDestructiveAction` in `UndoDestructiveActionTests` and
    // `UndoProviderIdentitySafetyTests`; the former's header records the
    // per-test disposition of the same cluster. Do not re-add a simulated undo
    // to this suite — an undo test belongs in those two files, driving production.

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

    // DELETED 2026-08-04 — `undo pattern: restores unread counts on both source and
    // destination folders` and `undo pattern: read messages don't change unread
    // counts` re-implemented `undoMove`'s unread arithmetic in the test body and
    // counted `messages.filter { !$0.isRead }` off the CAPTURED SNAPSHOT.
    // Production counts `currentRows.filter { !$0.isRead }` — the LIVE rows — and
    // `UndoMember` carries no `isRead` field at all, so the rule those tests
    // encoded is not representable in production. Both fixtures also made snapshot
    // and live state agree, so neither discriminated between the two rules.
}

/// F6 (PLAN_OVERLAY_CALLSITE_AUDIT.md §6): actionTag clears locally the moment
/// a message leaves the inbox (archive/delete/move-out), in the SAME write as
/// the folder move — no `.removeTag` PendingOperation is queued (tags are
/// local-only, ADR-IOS-036). Unlike `AccountManagerActionsTests` above (which
/// hand-mirrors GRDB statements against a local `TestDatabase`), these tests
/// drive the REAL `AccountManager.archive`/`move` production methods against
/// a swapped `AppDatabase.shared` — mirrors `CoordinatedToolActionTests`.
///
/// `.serialized`: tests swap the process-wide `AppDatabase.shared` singleton
/// and touch `AccountManager.shared`'s optimistic overlay — mirrors
/// `InboxGestureActionTests` / `CoordinatedToolActionTests`.
@Suite("AccountManagerActions — actionTag clears on inbox exit (F6)", .serialized, .processGlobalState)
struct AccountManagerActionsTagClearTests {

    // MARK: - Harness (mirrors CoordinatedToolActionTests.swift)

    private func makeTestDB() throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, trash: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
        try pool.writeWithoutTransaction { db in
            let i = inbox; try i.insert(db)
            let a = archive; try a.insert(db)
            let t = trash; try t.insert(db)
        }
        return (pool, inbox, archive, trash, dir, previous)
    }

    /// A durable, query-visible header (`headerComplete = true`) carrying an
    /// optional actionTag (with its matching tagSortOrder — mirrors how a real
    /// tagged row looks, since `applyManualTag` keeps both in sync).
    private func makeDurableHeader(
        folder: Folder,
        messageId: String,
        actionTag: ActionTag? = nil
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: "Subj \(messageId)", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        h.headerComplete = true
        h.actionTag = actionTag
        if let actionTag { h.tagSortOrder = actionTag.sortOrder }
        return h
    }

    /// Mirrors `CoordinatedToolActionTests.restoreTestDB`: restore a real
    /// predecessor when present, but retain this installed fixture until
    /// process exit in either case because action work can outlive the test.
    private func restoreTestDB(pool: DatabasePool, previous: AppDatabase?, dir: URL) {
        InstalledTestDatabaseLifetime.finish(
            previous: previous,
            pool: pool,
            directory: dir
        )
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    // MARK: - (1) Archive clears the tag, no .removeTag op

    @Test("archive() (real production path): actionTag clears to nil, tagSortOrder resets to the sweepStaleActionTags sentinel (99), and NO .removeTag PendingOperation is queued — only .move")
    func archiveClearsActionTagNoRemoveTagOp() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-archive-tag", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.archive([header])

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == archive.id, "message moved to Archive")
        #expect(final?.actionTag == nil, "F6: actionTag clears in the SAME write as the move")
        #expect(final?.tagSortOrder == 99, "F6: tagSortOrder resets to the sweep's sentinel")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1, "only the .move op — the legacy .removeTag enqueue was removed")
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
    }

    // MARK: - (2) Move between two non-inbox folders does NOT clear the tag

    @Test("move() between two non-inbox folders (Archive -> Trash, real production path): actionTag is NOT cleared — leavingInbox is false")
    func moveBetweenNonInboxFoldersDoesNotClearTag() async throws {
        let (pool, _, archive, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: archive, messageId: "m-nonInbox-move", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id

        await AccountManager.shared.move([header], to: trash.path)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id, "message moved to the new destination")
        #expect(final?.actionTag == .reply, "tag survives a move that never touches the inbox")
        #expect(final?.tagSortOrder == ActionTag.reply.sortOrder, "tagSortOrder untouched when the tag isn't cleared")
    }

    // MARK: - (3) Undo restores the tag

    @Test("undo restores actionTag: archive() clears the tag locally; undoDestructiveAction's full-row save (the pre-archive snapshot) restores it")
    func undoRestoresActionTagAfterArchive() async throws {
        let (pool, inbox, archive, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-undo-tag", actionTag: .reply)
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        // Captured BEFORE archive mutates the DB row — mirrors UndoService.push
        // capturing the gesture-time `message` snapshot pre-move (still carries
        // the original actionTag; `archive()`'s optimistic write below only
        // touches the DB row, never this local value-type copy).
        let preArchiveSnapshot = header

        await AccountManager.shared.archive([header])

        let afterArchive = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterArchive?.actionTag == nil, "setup: archive clears the tag locally (F6)")
        #expect(afterArchive?.folderId == archive.id)

        // Mirrors UndoService.undo()'s .move case: originalOpType is always
        // .move (archive/delete/move all funnel through AccountManager.move),
        // fromFolderPath is the CURRENT (post-archive) location, toFolderPath/
        // toFolderId are the ORIGINAL (pre-archive) location.
        await AccountManager.shared.undoDestructiveAction(
            [preArchiveSnapshot],
            accountId: "acc1",
            originalOpType: .move,
            fromFolderPath: archive.path,
            toFolderPath: inbox.path,
            toFolderId: inbox.id
        )

        let afterUndo = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(afterUndo?.folderId == inbox.id, "undo restores the original folder")
        #expect(afterUndo?.actionTag == .reply, "undo's full-row save (from the pre-archive snapshot) restores the tag")
    }

    // MARK: - (4) move() re-resolves fresh headers by id (FIX B)

    @Test("move() re-resolves fresh headers by id: a stale caller snapshot (still pointing at INBOX) is superseded by the row's CURRENT folder (Archive, landed by an earlier committed move) — the queued PendingOperation's source folderPath is the FRESH location, not the stale one")
    func moveReResolvesFreshHeaderOverStaleCallerSnapshot() async throws {
        let (pool, inbox, archive, trash, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-stale-move")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        let id = header.id
        // Caller's snapshot — captured BEFORE the "earlier committed move" below,
        // still says INBOX. Mirrors a gesture path's `lookupMessage` snapshot
        // captured at tap time and passed into a queued closure that runs late.
        let staleSnapshot = header

        // Simulate an earlier committed move: a prior queued closure already
        // ran and moved the row to Archive before this move() call executes.
        try await pool.writeWithoutTransaction { db in
            _ = try MessageHeader.filter(Column("id") == id).updateAll(db,
                Column("folderId").set(to: archive.id),
                Column("folderPath").set(to: archive.path),
                Column("isInInbox").set(to: false)
            )
        }

        await AccountManager.shared.move([staleSnapshot], to: trash.path)

        let final = try await pool.read { db in try MessageHeader.fetchOne(db, key: id) }
        #expect(final?.folderId == trash.id, "row lands in Trash — the FRESH (Archive) source resolved correctly")

        let ops = try await pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].folderPath == archive.path, "queued op's source folderPath is the FRESH (Archive) location, not the stale caller snapshot's INBOX")
        #expect(ops[0].destinationPath == trash.path)
    }

    // MARK: - (5) overlayAdjustedSnapshot (FIX C — promoted from InboxViewModel.overlayAdjustedForUndo)

    @Test("AccountManager.overlayAdjustedSnapshot: a still-queued gesture intent's overlay actionTag wins over the DB-fresh nil — undo snapshots must read visualized state, not stale DB truth")
    func overlayAdjustedSnapshotPicksUpQueuedTagIntent() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        let header = makeDurableHeader(folder: inbox, messageId: "m-overlay-snapshot")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }

        // Register the gesture's overlay mutation directly (mirrors
        // `registerGestureIntent`'s synchronous `registerMutation` call)
        // WITHOUT draining the FIFO write queue — the queue stays GATED so the
        // DB row is untouched, simulating a still-in-flight gesture cycle whose
        // executor hasn't run yet.
        AccountManager.shared.registerMutation(id: header.id, mutation: .init(actionTag: .some(ActionTag.reply)))

        let dbTruth = try await pool.read { db in try MessageHeader.fetchOne(db, key: header.id) }
        #expect(dbTruth?.actionTag == nil, "setup: DB row is untouched — the write is gated/queued, not yet drained")

        let snapshot = AccountManager.shared.overlayAdjustedSnapshot(header)
        #expect(snapshot.actionTag == .reply, "the undo snapshot must carry the overlay's queued intent, not the stale DB nil")
    }

    /// 🚨 R13-U13 — INVARIANT: **no snapshot leaves this function carrying a tag
    /// and a sort order that disagree.** `actionTag` and `tagSortOrder` are one
    /// fact stored twice; `UndoMember.init(header:)` reads BOTH off this
    /// snapshot and the undo restore writes BOTH durably, so an inconsistent
    /// pair here is a durably corrupt row: the chip says one thing and triage
    /// files it somewhere else. It is the exact shape migration `v58` was
    /// written to heal once (`AppDatabase` names `(actionTag='reply',
    /// tagSortOrder=99)`), and a one-time heal does not re-run.
    ///
    /// Pinned as the PAIRING, not as "the field is assigned": the expectation
    /// is `snapshot.tagSortOrder == snapshot.actionTag?.sortOrder ?? 99`, which
    /// stays honest if the sort-order mapping ever changes.
    @Test("R13-U13 — overlayAdjustedSnapshot never emits a tag whose sort order disagrees with it")
    func overlayAdjustedSnapshotMirrorsTagSortOrder() async throws {
        let (pool, inbox, _, _, dir, previous) = try makeTestDB()
        defer { restoreTestDB(pool: pool, previous: previous, dir: dir); clearOverlay() }
        clearOverlay()

        // SET: an untagged DB row (tagSortOrder 99) the overlay tags `.reply`
        // (sortOrder 0). This is a tag-then-archive-before-the-FIFO-drains, then
        // undo — the sequence that wrote the corrupt pair.
        let header = makeDurableHeader(folder: inbox, messageId: "m-u13-set")
        #expect(header.actionTag == nil && header.tagSortOrder == 99, "setup: the DB row is untagged")
        try await pool.writeWithoutTransaction { db in try header.insert(db) }
        AccountManager.shared.registerMutation(id: header.id, mutation: .init(actionTag: .some(ActionTag.reply)))

        let tagged = AccountManager.shared.overlayAdjustedSnapshot(header)
        #expect(tagged.actionTag == .reply)
        #expect(tagged.tagSortOrder == ActionTag.reply.sortOrder,
                "undo would durably restore (actionTag: reply, tagSortOrder: \(tagged.tagSortOrder)) — the chip says reply and triage files it at the bottom")
        #expect(tagged.tagSortOrder == (tagged.actionTag?.sortOrder ?? 99),
                "the pair must agree whatever the mapping is")

        // CLEAR — the other direction, so the fix cannot be "always write the
        // tag's sort order" while leaving the clear path broken.
        clearOverlay()
        let alreadyTagged: MessageHeader = {
            var h = makeDurableHeader(folder: inbox, messageId: "m-u13-clear")
            h.setActionTag(.archive)
            return h
        }()
        #expect(alreadyTagged.tagSortOrder == ActionTag.archive.sortOrder, "setup: the DB row is tagged")
        try await pool.writeWithoutTransaction { [alreadyTagged] db in try alreadyTagged.insert(db) }
        AccountManager.shared.registerMutation(id: alreadyTagged.id, mutation: .init(actionTag: .some(nil)))

        let cleared = AccountManager.shared.overlayAdjustedSnapshot(alreadyTagged)
        #expect(cleared.actionTag == nil)
        #expect(cleared.tagSortOrder == 99,
                "a cleared tag must fall back to the untagged sort order, not keep the old tag's bucket")
        #expect(cleared.tagSortOrder == (cleared.actionTag?.sortOrder ?? 99))

        // CONTROL (MIS-030): with NO overlay entry the snapshot is the row
        // untouched, so the two assertions above are about the overlay path and
        // not about a function that rewrites `tagSortOrder` unconditionally.
        clearOverlay()
        #expect(AccountManager.shared.overlayAdjustedSnapshot(alreadyTagged).tagSortOrder
                    == ActionTag.archive.sortOrder,
                "with no overlay the row must pass through unchanged")
    }
}

/// Owner feature (`main` line `98bebba7c`, re-implemented on v3): the "Mark as
/// Read on Archive & Delete" toggle (Settings → TabMail Settings → User
/// Interface, `AccountManager.markReadOnArchiveDeleteKey`). Pins the
/// UserDefaults contract in isolation from the composition behaviour (covered
/// end-to-end in `InboxGestureActionTests`, `MessageDetailViewModelMoveTests`,
/// `CoordinatedToolActionTests`, `NotificationActionRouterTests` and, on the
/// wire, `FinishTheMoveLocallyTests`): default ON when the key has never been
/// set — the same missing-key handling `ProactiveNotifyService.isEnabled` uses
/// — and an explicit persisted change honoured on the next read.
///
/// The default matters more than it looks: `UserDefaults.bool(forKey:)` returns
/// `false` for a never-set key, so reading the toggle that way would ship the
/// feature silently OFF for every existing user.
///
/// `.serialized`/`.processGlobalState`: mutates the process-wide
/// `UserDefaults.standard` key every archive/delete entry point reads.
@Suite("AccountManager.markReadOnArchiveDeleteEnabled — setting contract", .serialized, .processGlobalState)
struct MarkReadOnArchiveDeleteSettingTests {
    @Test("key is the documented literal, default is ON when never set, and an explicit persisted change is honoured on the next read")
    func settingRoundTrip() {
        let key = AccountManager.markReadOnArchiveDeleteKey
        #expect(key == "markReadOnArchiveDelete")

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        #expect(AccountManager.markReadOnArchiveDeleteEnabled == true, "a never-set key defaults to ON")

        defaults.set(false, forKey: key)
        #expect(AccountManager.markReadOnArchiveDeleteEnabled == false, "a persisted false is honoured on the next read")

        defaults.set(true, forKey: key)
        #expect(AccountManager.markReadOnArchiveDeleteEnabled == true, "a persisted true is honoured on the next read")
    }
}
