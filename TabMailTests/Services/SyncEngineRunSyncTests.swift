/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Test Helpers

/// Builds a realistic MessageHeaderInfo with sensible defaults.
private func makeHeaderInfo(
    messageId: String = "100",
    rfc822MessageId: String? = "<msg-100@example.com>",
    inReplyTo: String? = nil,
    references: [String] = [],
    threadId: String? = nil,
    subject: String = "Test Subject",
    from: String = "Alice Smith",
    fromAddress: String = "alice@example.com",
    to: String = "bob@example.com",
    cc: String = "",
    bcc: String = "",
    replyTo: String? = nil,
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    snippet: String = "Test snippet",
    isRead: Bool = false,
    isFlagged: Bool = false,
    hasAttachments: Bool = false,
    isReplied: Bool = false,
    isForwarded: Bool = false,
    actionTag: ActionTag? = nil
) -> MessageHeaderInfo {
    MessageHeaderInfo(
        messageId: messageId,
        rfc822MessageId: rfc822MessageId,
        inReplyTo: inReplyTo,
        references: [],
        threadId: threadId,
        subject: subject,
        from: from,
        fromAddress: fromAddress,
        to: to,
        cc: cc,
        bcc: bcc,
        replyTo: replyTo,
        date: date,
        snippet: snippet,
        isRead: isRead,
        isFlagged: isFlagged,
        hasAttachments: hasAttachments,
        isReplied: isReplied,
        isForwarded: isForwarded,
        actionTag: actionTag
    )
}

/// Simulates the core of `SyncEngine.runSyncMessages()` against a DatabaseQueue.
/// This replicates the logic from SyncEngineFullSync.swift but accepts DatabaseWriter
/// so it works with the in-memory DatabaseQueue used by tests.
///
/// ⚠ **DELIBERATELY OMITTED: the §5 RFC822 identity guards** (ADR-IOS-061 —
/// `SyncEngine.classifyRFC822Merge` and the assign/keep rule in the `existing`
/// merge branch and the orphan-reclaim branch). This simulation keeps the
/// pre-guard unconditional `rfc822MessageId` assignment because the cases below
/// are about stale detection, insert, UID remap and pending-op protection —
/// every fixture uses one identity per address, where guarded and unguarded
/// behaviour are identical. A simulation is structurally blind to the code it
/// re-implements, so the guards are pinned against the REAL entry point in
/// `RFC822IdentityMergeGuardTests` instead. Do NOT add an identity case here.
///
/// Returns the same tuple shape as SyncMessagesResult.
private func simulateRunSyncMessages(
    db: DatabaseQueue,
    folder: Folder,
    messages: [MessageHeaderInfo],
    limit: Int,
    undoProtectedIds: Set<String> = []
) throws -> (newHeaders: [MessageHeader], staleIds: [String], replyDetectIds: [String], uidMigratedOldIds: [String]) {
    let folderPath = folder.path
    let folderId = folder.id
    let accountId = folder.accountId
    let isInInbox = folder.role == .inbox

    let remoteIds = Set(messages.map(\.messageId))

    return try db.write { dbConn in
        // Load pending operations (same as runSyncMessages)
        let pendingOps = try PendingOperation.fetchAll(dbConn)
        let opsForThisFolder = pendingOps.filter { $0.accountId == accountId && $0.folderPath == folderPath }
        let pendingDestructiveIds = Set(
            opsForThisFolder
                .filter { [.archive, .delete, .move].contains($0.type) }
                .flatMap(\.messageIds)
        )
        let pendingFlagIds = Set(
            opsForThisFolder
                .filter { [.markRead, .markUnread, .markFlagged, .markUnflagged, .setTag, .removeTag].contains($0.type) }
                .flatMap(\.messageIds)
        )
        let isPendingDestructive: (MessageHeaderInfo) -> Bool = { info in
            pendingDestructiveIds.contains(info.messageId) ||
            (info.rfc822MessageId.map { pendingDestructiveIds.contains($0) } ?? false)
        }
        let isPendingFlag: (MessageHeaderInfo) -> Bool = { info in
            pendingFlagIds.contains(info.messageId) ||
            (info.rfc822MessageId.map { pendingFlagIds.contains($0) } ?? false)
        }
        let opsTargetingThisFolder = pendingOps.filter {
            $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
        }
        let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))

        var newHeaders: [MessageHeader] = []
        var staleIds: [String] = []
        var replyDetectIds: [String] = []

        // Stale detection
        let stale: [MessageHeader]
        if messages.count < limit {
            let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn)
            stale = allLocal.filter { !remoteIds.contains($0.messageId) }
        } else if let fetchCutoff = messages.min(by: { $0.date < $1.date })?.date {
            let candidates = try MessageHeader
                .filter(Column("folderId") == folderId && Column("date") >= fetchCutoff)
                .fetchAll(dbConn)
            stale = candidates.filter { !remoteIds.contains($0.messageId) }
        } else {
            stale = []
        }

        let protectedIds = pendingAllIds.union(undoProtectedIds)

        // UID remap detection
        var uidMigratedRemoteIds = Set<String>()
        var uidMigratedOldMsgIds: [String] = []
        let localMsgIds = Set(try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn).map(\.messageId))
        let newRemoteIds = remoteIds.subtracting(localMsgIds)
        for staleMsg in stale {
            guard let rfc822 = staleMsg.rfc822MessageId, !rfc822.isEmpty else { continue }
            guard let match = messages.first(where: {
                newRemoteIds.contains($0.messageId) &&
                !uidMigratedRemoteIds.contains($0.messageId) &&
                $0.rfc822MessageId == rfc822
            }) else { continue }
            let oldId = staleMsg.id
            let newMsgId = match.messageId
            let newId = "\(accountId):\(folderPath):\(newMsgId)"
            // Fetch body BEFORE deleting header — CASCADE would delete body too
            let oldBody = try MessageBody.fetchOne(dbConn, key: oldId)
            try staleMsg.delete(dbConn)
            var migrated = staleMsg
            migrated.id = newId
            migrated.messageId = newMsgId
            migrated.isRead = match.isRead
            migrated.isFlagged = match.isFlagged
            migrated.date = match.date
            try migrated.insert(dbConn)
            if var body = oldBody {
                body.id = ContentKey(rawValue: newId)
                try body.insert(dbConn)
            }
            uidMigratedRemoteIds.insert(newMsgId)
            uidMigratedOldMsgIds.append(staleMsg.messageId)
        }

        let uidMigratedSet = Set(uidMigratedOldMsgIds)
        let isProtected: (MessageHeader) -> Bool = { msg in
            protectedIds.contains(msg.messageId) ||
            (msg.rfc822MessageId.map { protectedIds.contains($0) } ?? false)
        }
        let staleFiltered = stale.filter { !isProtected($0) && !uidMigratedSet.contains($0.messageId) }
        staleIds = staleFiltered.map(\.id)
        for msg in staleFiltered {
            try msg.delete(dbConn)
        }

        // Upsert
        for info in messages where !isPendingDestructive(info) && !uidMigratedRemoteIds.contains(info.messageId) {
            if var existing = try MessageHeader
                .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                .fetchOne(dbConn) {
                let hasPendingFlags = isPendingFlag(info)
                if !hasPendingFlags {
                    existing.isRead = info.isRead
                    existing.isFlagged = info.isFlagged
                    if isInInbox, let serverTag = info.actionTag {
                        existing.actionTag = serverTag
                        existing.tagSortOrder = serverTag.sortOrder
                    }
                }
                existing.date = info.date
                existing.from = info.from
                existing.fromAddress = info.fromAddress
                existing.to = info.to
                existing.cc = info.cc
                existing.bcc = info.bcc
                existing.replyTo = info.replyTo
                existing.isReplied = existing.isReplied || info.isReplied
                existing.isForwarded = existing.isForwarded || info.isForwarded
                existing.rfc822MessageId = info.rfc822MessageId
                // ReplyDetect
                if existing.isReplied && existing.actionTag == .reply {
                    existing.actionTag = ActionTag.none
                    existing.tagSortOrder = ActionTag.none.sortOrder
                    let tagOp = PendingOperation(
                        type: .setTag,
                        messageIds: [existing.stableId],
                        accountId: accountId,
                        folderPath: folderPath,
                        tagValue: ActionTag.none.rawValue
                    )
                    try tagOp.insert(dbConn)
                    replyDetectIds.append(existing.id)
                }
                try existing.update(dbConn)
                continue
            }

            var header = MessageHeader(
                messageId: info.messageId,
                subject: info.subject,
                from: info.from,
                fromAddress: info.fromAddress,
                to: info.to,
                date: info.date,
                snippet: EmailFilter.decodeHTMLEntities(info.snippet),
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: isInInbox
            )
            header.rfc822MessageId = info.rfc822MessageId
            header.inReplyTo = info.inReplyTo
            header.threadId = info.threadId ?? ThreadUtils.computeSubjectThreadId(accountId: accountId, subject: header.subject)
            header.replyTo = info.replyTo
            header.cc = info.cc
            header.bcc = info.bcc
            header.isRead = info.isRead
            header.isFlagged = info.isFlagged
            header.hasAttachments = info.hasAttachments
            header.isReplied = info.isReplied
            header.isForwarded = info.isForwarded
            if isInInbox {
                header.actionTag = info.actionTag
                header.tagSortOrder = info.actionTag?.sortOrder ?? 99
            }
            // ReplyDetect for new inserts
            if header.isReplied && header.actionTag == .reply {
                header.actionTag = ActionTag.none
                header.tagSortOrder = ActionTag.none.sortOrder
                let tagOp = PendingOperation(
                    type: .setTag,
                    messageIds: [header.stableId],
                    accountId: accountId,
                    folderPath: folderPath,
                    tagValue: ActionTag.none.rawValue
                )
                try tagOp.insert(dbConn)
                replyDetectIds.append(header.id)
            }
            // Orphaned row reclaim
            if var orphaned = try MessageHeader.fetchOne(dbConn, key: header.id) {
                orphaned.folderId = folderId
                orphaned.folderPath = folderPath
                orphaned.isInInbox = isInInbox
                orphaned.messageId = header.messageId
                orphaned.isRead = header.isRead
                orphaned.isFlagged = header.isFlagged
                orphaned.date = header.date
                orphaned.from = header.from
                orphaned.fromAddress = header.fromAddress
                orphaned.to = header.to
                orphaned.cc = header.cc
                orphaned.bcc = header.bcc
                orphaned.replyTo = header.replyTo
                orphaned.rfc822MessageId = header.rfc822MessageId
                orphaned.isReplied = orphaned.isReplied || header.isReplied
                orphaned.isForwarded = orphaned.isForwarded || header.isForwarded
                orphaned.subject = header.subject
                orphaned.snippet = header.snippet
                orphaned.hasAttachments = header.hasAttachments
                orphaned.actionTag = header.actionTag
                orphaned.tagSortOrder = header.tagSortOrder
                try orphaned.update(dbConn)
                newHeaders.append(orphaned)
            } else {
                try header.insert(dbConn)
                newHeaders.append(header)
            }
        }

        return (newHeaders, staleIds, replyDetectIds, uidMigratedOldMsgIds)
    }
}

// MARK: - Suite 1: New Message Insert

@Suite("runSyncMessages — New Message Insert")
struct RunSyncNewMessageInsertTests {

    @Test("Empty local DB, remote has messages — all inserted as new")
    func emptyLocalRemoteHasMessages() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let mock = MockEmailProvider()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let remoteMessages = [
            makeHeaderInfo(messageId: "1", rfc822MessageId: "<msg1@ex.com>", subject: "Hello", date: date),
            makeHeaderInfo(messageId: "2", rfc822MessageId: "<msg2@ex.com>", subject: "World", date: date.addingTimeInterval(60)),
            makeHeaderInfo(messageId: "3", rfc822MessageId: "<msg3@ex.com>", subject: "Test", date: date.addingTimeInterval(120)),
        ]
        await mock.setFetchMessagesResult(remoteMessages)

        let fetched = try await mock.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: fetched, limit: 50)

        #expect(result.newHeaders.count == 3)
        #expect(result.staleIds.isEmpty)

        let allHeaders = try await db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchAll($0) }
        #expect(allHeaders.count == 3)

        let subjects = Set(allHeaders.map(\.subject))
        #expect(subjects.contains("Hello"))
        #expect(subjects.contains("World"))
        #expect(subjects.contains("Test"))

        // Verify correct field mapping
        let h1 = allHeaders.first { $0.messageId == "1" }
        #expect(h1?.rfc822MessageId == "<msg1@ex.com>")
        #expect(h1?.from == "Alice Smith")
        #expect(h1?.fromAddress == "alice@example.com")
        #expect(h1?.to == "bob@example.com")
        #expect(h1?.accountId == "acc1")
        #expect(h1?.folderPath == "INBOX")
        #expect(h1?.isInInbox == true)
    }

    @Test("ThreadId computed from subject when provider threadId is nil")
    func threadIdFromSubject() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remoteMessages = [
            makeHeaderInfo(messageId: "10", threadId: nil, subject: "Re: Project Update"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)
        #expect(result.newHeaders.count == 1)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:10") }
        #expect(header?.threadId == ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Project Update"))
        #expect(header?.threadId == "subj:acc1:project update")
    }

    @Test("Action tags applied only for inbox (isInInbox)")
    func actionTagsAppliedForInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remoteMessages = [
            makeHeaderInfo(messageId: "20", actionTag: .archive),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)
        #expect(result.newHeaders.count == 1)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:20") }
        #expect(header?.actionTag == .archive)
        #expect(header?.tagSortOrder == ActionTag.archive.sortOrder)
    }

    @Test("Action tags NOT applied for non-inbox folders")
    func actionTagsNotAppliedForNonInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        let remoteMessages = [
            makeHeaderInfo(messageId: "30", actionTag: .reply),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)
        #expect(result.newHeaders.count == 1)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:Sent:30") }
        #expect(header?.actionTag == nil)
        #expect(header?.tagSortOrder == 99)
        #expect(header?.isInInbox == false)
    }

    @Test("Snippet HTML entities decoded on insert")
    func snippetHTMLEntitiesDecoded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remoteMessages = [
            makeHeaderInfo(messageId: "40", snippet: "Tom &amp; Jerry&#39;s &#x27;show&#x27;"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)
        #expect(result.newHeaders.count == 1)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:40") }
        #expect(header?.snippet == "Tom & Jerry's 'show'")
    }
}

// MARK: - Suite 2: Stale Detection

@Suite("runSyncMessages — Stale Detection")
struct RunSyncStaleDetectionTests {

    @Test("Local messages not in remote set are deleted (count < limit)")
    func staleMessagesDeletedCountBelowLimit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert 3 local messages
        try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "Keep 1")
        try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "Keep 2")
        try TestDatabase.insertMessageHeader(db, messageId: "3", subject: "Stale")

        // Remote only has messages 1 and 2 (count=2 < limit=50)
        let remoteMessages = [
            makeHeaderInfo(messageId: "1", subject: "Keep 1"),
            makeHeaderInfo(messageId: "2", subject: "Keep 2"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        #expect(result.staleIds.count == 1)
        #expect(result.staleIds[0] == "acc1:INBOX:3")

        let remaining = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchAll($0) }
        #expect(remaining.count == 2)
        #expect(Set(remaining.map(\.messageId)) == Set(["1", "2"]))
    }

    @Test("Date-bounded stale when count == limit")
    func dateBoundedStaleDetection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let now = Date()
        // Old message well outside the remote window — should NOT be stale-detected
        try TestDatabase.insertMessageHeader(db, messageId: "old", date: now.addingTimeInterval(-86400 * 30))
        // Recent message inside the window — NOT stale (in remote set)
        try TestDatabase.insertMessageHeader(db, messageId: "recent", date: now.addingTimeInterval(-3600))
        // Message inside window but NOT in remote set — stale
        try TestDatabase.insertMessageHeader(db, messageId: "stale-in-window", date: now.addingTimeInterval(-1800))

        // Remote returns exactly `limit` messages, triggering date-bounded detection
        let remoteMessages = [
            makeHeaderInfo(messageId: "recent", date: now.addingTimeInterval(-3600)),
            makeHeaderInfo(messageId: "new1", date: now.addingTimeInterval(-600)),
        ]
        let limit = 2 // count == limit

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: limit)

        #expect(result.staleIds.count == 1)
        #expect(result.staleIds[0] == "acc1:INBOX:stale-in-window")

        // "old" message should still be in the DB (outside date window)
        let oldMsg = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:old") }
        #expect(oldMsg != nil)
    }

    @Test("Messages with pending ops are NOT deleted as stale")
    func pendingOpsProtectFromStale() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert 2 local messages
        try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "Normal")
        try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "Has pending op")

        // Create a pending archive operation for message "2"
        let pendingOp = PendingOperation(
            type: .archive,
            messageIds: ["2"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try pendingOp.insert($0) }

        // Remote only has message "1" — message "2" is stale but has pending op
        let remoteMessages = [
            makeHeaderInfo(messageId: "1", subject: "Normal"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // Message "2" should NOT be deleted (protected by pending op)
        #expect(result.staleIds.isEmpty)

        let remaining = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchAll($0) }
        #expect(remaining.count == 2)
    }

    @Test("Messages in undoProtectedIds are NOT deleted as stale")
    func undoProtectedIdsPreventStaleDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        try TestDatabase.insertMessageHeader(db, messageId: "1", subject: "Normal")
        try TestDatabase.insertMessageHeader(db, messageId: "2", subject: "Undo protected")

        // Remote only has message "1"
        let remoteMessages = [
            makeHeaderInfo(messageId: "1", subject: "Normal"),
        ]

        let undoProtected: Set<String> = ["2"]
        let result = try simulateRunSyncMessages(
            db: db, folder: folder, messages: remoteMessages, limit: 50,
            undoProtectedIds: undoProtected
        )

        // Message "2" should NOT be deleted (undo protected)
        #expect(result.staleIds.isEmpty)

        let remaining = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchAll($0) }
        #expect(remaining.count == 2)
    }
}

// MARK: - Suite 3: Upsert Existing

@Suite("runSyncMessages — Upsert Existing")
struct RunSyncUpsertExistingTests {

    @Test("Existing message updated with latest remote data")
    func existingMessageUpdated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert existing message: unread, unflagged
        try TestDatabase.insertMessageHeader(db, messageId: "50", subject: "Original", isRead: false)

        // Remote says: read, flagged, updated sender
        let remoteMessages = [
            makeHeaderInfo(
                messageId: "50",
                subject: "Original",
                from: "Updated Sender",
                fromAddress: "updated@example.com",
                isRead: true,
                isFlagged: true
            ),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // No new headers (existing was updated)
        #expect(result.newHeaders.isEmpty)

        let header = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:50") }
        #expect(header?.isRead == true)
        #expect(header?.isFlagged == true)
        #expect(header?.from == "Updated Sender")
        #expect(header?.fromAddress == "updated@example.com")
    }

    @Test("isReplied only upgrades false to true, never downgrades")
    func isRepliedOnlyUpgrades() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert with isReplied=true locally
        let insertedHeader = try TestDatabase.insertMessageHeader(db, messageId: "60", subject: "Replied msg")
        try db.write { dbConn in
            var mutable = insertedHeader
            mutable.isReplied = true
            try mutable.update(dbConn)
        }

        // Server says isReplied=false (e.g. Gmail REST limitation)
        let remoteMessages = [
            makeHeaderInfo(messageId: "60", subject: "Replied msg", isReplied: false),
        ]

        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:60") }
        #expect(fetched?.isReplied == true) // Preserved — never downgrades
    }

    @Test("isForwarded only upgrades false to true")
    func isForwardedOnlyUpgrades() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert with isForwarded=true locally
        let insertedHeader = try TestDatabase.insertMessageHeader(db, messageId: "70", subject: "Forwarded msg")
        try db.write { dbConn in
            var mutable = insertedHeader
            mutable.isForwarded = true
            try mutable.update(dbConn)
        }

        // Server says isForwarded=false
        let remoteMessages = [
            makeHeaderInfo(messageId: "70", subject: "Forwarded msg", isForwarded: false),
        ]

        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:70") }
        #expect(fetched?.isForwarded == true) // Preserved — never downgrades
    }
}

// MARK: - Suite 4: ReplyDetect

@Suite("runSyncMessages — ReplyDetect")
struct RunSyncReplyDetectTests {

    @Test("Replied message with .reply tag — tag becomes .none, PendingOperation created")
    func repliedWithReplyTagOverriddenToNone() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert existing message with isReplied=true and actionTag=.reply
        let insertedHeader = try TestDatabase.insertMessageHeader(
            db, messageId: "80", subject: "Reply me", actionTag: .reply
        )
        try db.write { dbConn in
            var mutable = insertedHeader
            mutable.isReplied = true
            try mutable.update(dbConn)
        }

        // Remote sync returns same message with isReplied=true and actionTag=.reply
        let remoteMessages = [
            makeHeaderInfo(messageId: "80", subject: "Reply me", isReplied: true, actionTag: .reply),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // ReplyDetect should fire
        #expect(result.replyDetectIds.count == 1)
        #expect(result.replyDetectIds[0] == "acc1:INBOX:80")

        // Header should have actionTag = ActionTag.none (not .reply)
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:80") }
        #expect(fetched?.actionTag == ActionTag.none)
        #expect(fetched?.tagSortOrder == ActionTag.none.sortOrder)
        #expect(fetched?.isReplied == true)

        // PendingOperation should be created for the tag change
        let pendingOps = try db.read { try PendingOperation.fetchAll($0) }
        let tagOps = pendingOps.filter { $0.type == .setTag }
        #expect(tagOps.count == 1)
        #expect(tagOps[0].tagValue == ActionTag.none.rawValue)
        #expect(tagOps[0].accountId == "acc1")
        #expect(tagOps[0].folderPath == "INBOX")
    }

    @Test("Replied message with .archive tag — tag unchanged")
    func repliedWithArchiveTagUnchanged() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert existing message with isReplied=true and actionTag=.archive
        let insertedHeader = try TestDatabase.insertMessageHeader(
            db, messageId: "90", subject: "Archive me", actionTag: .archive
        )
        try db.write { dbConn in
            var mutable = insertedHeader
            mutable.isReplied = true
            try mutable.update(dbConn)
        }

        // Remote returns same message
        let remoteMessages = [
            makeHeaderInfo(messageId: "90", subject: "Archive me", isReplied: true, actionTag: .archive),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // ReplyDetect should NOT fire (tag is .archive, not .reply)
        #expect(result.replyDetectIds.isEmpty)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:90") }
        #expect(fetched?.actionTag == .archive) // Unchanged
        #expect(fetched?.isReplied == true)

        // No PendingOperation created
        let pendingOps = try db.read { try PendingOperation.fetchAll($0) }
        #expect(pendingOps.isEmpty)
    }

    @Test("ReplyDetect fires on new insert when isReplied=true and actionTag=.reply")
    func replyDetectOnNewInsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // No existing message — this is a fresh insert
        let remoteMessages = [
            makeHeaderInfo(messageId: "95", subject: "Already replied", isReplied: true, actionTag: .reply),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // ReplyDetect should fire on insert too
        #expect(result.replyDetectIds.count == 1)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:95") }
        #expect(fetched?.actionTag == ActionTag.none) // Overridden from .reply
        #expect(fetched?.isReplied == true)

        let pendingOps = try db.read { try PendingOperation.fetchAll($0) }
        let tagOps = pendingOps.filter { $0.type == .setTag }
        #expect(tagOps.count == 1)
    }
}

// MARK: - Suite 5: UID Remap

@Suite("runSyncMessages — UID Remap")
struct RunSyncUIDRemapTests {

    @Test("Stale message with rfc822MessageId matching new remote message — migrated")
    func uidRemapMigration() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert local message with old UID "100"
        try TestDatabase.insertMessageHeader(
            db, messageId: "100", subject: "Moved msg",
            rfc822MessageId: "<abc@example.com>"
        )

        // Remote returns same message with NEW UID "200" but same rfc822MessageId
        let remoteMessages = [
            makeHeaderInfo(
                messageId: "200",
                rfc822MessageId: "<abc@example.com>",
                subject: "Moved msg",
                isRead: true
            ),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // Verify UID migration
        #expect(result.uidMigratedOldIds.contains("100"))
        #expect(result.staleIds.isEmpty) // Not deleted as stale — migrated

        // Old message should be gone
        let oldMsg = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:100") }
        #expect(oldMsg == nil)

        // New message should exist with same rfc822MessageId
        let newMsg = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:200") }
        #expect(newMsg != nil)
        #expect(newMsg?.rfc822MessageId == "<abc@example.com>")
        #expect(newMsg?.messageId == "200")
        #expect(newMsg?.isRead == true) // Updated from remote

        // Should be exactly 1 message in folder
        let allMsgs = try db.read { try MessageHeader.filter(Column("folderId") == folder.id).fetchAll($0) }
        #expect(allMsgs.count == 1)
    }

    @Test("UID remap: body preserved through CASCADE delete (fetch-before-delete fix)")
    func uidRemapBodyPreserved() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert local message with body
        try TestDatabase.insertMessageHeader(
            db, messageId: "300", subject: "Has body",
            rfc822MessageId: "<body-msg@example.com>"
        )
        try TestDatabase.insertMessageBody(db, headerId: "acc1:INBOX:300", htmlContent: "<p>Important body content</p>")

        // Remote returns same message with new UID
        let remoteMessages = [
            makeHeaderInfo(
                messageId: "400",
                rfc822MessageId: "<body-msg@example.com>",
                subject: "Has body"
            ),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)
        #expect(result.uidMigratedOldIds.contains("300"))

        // Old body is gone (header deleted, CASCADE cleaned up)
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:300") }
        #expect(oldBody == nil)

        // New header exists with correct rfc822MessageId
        let newMsg = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:400") }
        #expect(newMsg != nil)
        #expect(newMsg?.rfc822MessageId == "<body-msg@example.com>")

        // Body migrated to new header ID (fetch-before-delete preserves it)
        let newBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:400") }
        #expect(newBody != nil)
        #expect(newBody?.htmlContent == "<p>Important body content</p>")
    }
}

// MARK: - Suite 6: Pending Op Protection

@Suite("runSyncMessages — Pending Op Protection")
struct RunSyncPendingOpProtectionTests {

    @Test("Messages with pending archive ops not re-inserted")
    func pendingArchiveBlocksInsertion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Create pending archive operation for messageId "42" (user archived it)
        let pendingOp = PendingOperation(
            type: .archive,
            messageIds: ["42"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try pendingOp.insert($0) }

        // Remote still returns message "42" (server hasn't processed the archive yet)
        let remoteMessages = [
            makeHeaderInfo(messageId: "42", subject: "Archived by user"),
            makeHeaderInfo(messageId: "43", subject: "Normal message"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // Only message "43" should be inserted — "42" skipped due to pending destructive op
        #expect(result.newHeaders.count == 1)
        #expect(result.newHeaders[0].messageId == "43")

        let msg42 = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:42") }
        #expect(msg42 == nil) // Should NOT be re-inserted

        let msg43 = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:43") }
        #expect(msg43 != nil) // Normal insertion
    }

    @Test("Messages with pending flag ops still updated but flags not overwritten")
    func pendingFlagOpsPreserveFlags() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Insert existing message: read=true, flagged=true (user set these)
        try TestDatabase.insertMessageHeader(
            db, messageId: "55", subject: "Flagged msg", isRead: true
        )
        // Manually set isFlagged since TestDatabase helper doesn't support it directly
        try db.write { dbConn in
            if var msg = try MessageHeader.fetchOne(dbConn, key: "acc1:INBOX:55") {
                msg.isFlagged = true
                try msg.update(dbConn)
            }
        }

        // Create pending markRead operation (user has in-flight read change)
        let pendingOp = PendingOperation(
            type: .markRead,
            messageIds: ["55"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try pendingOp.insert($0) }

        // Remote says: isRead=false, isFlagged=false (stale server state)
        let remoteMessages = [
            makeHeaderInfo(
                messageId: "55",
                subject: "Flagged msg",
                from: "New Sender",
                fromAddress: "new@example.com",
                isRead: false,
                isFlagged: false
            ),
        ]

        _ = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:55") }
        // Flags should NOT be overwritten (pending flag op)
        #expect(fetched?.isRead == true) // Preserved — pending flag op protects
        #expect(fetched?.isFlagged == true) // Preserved — pending flag op protects
        // Non-flag fields still updated
        #expect(fetched?.from == "New Sender")
        #expect(fetched?.fromAddress == "new@example.com")
    }

    @Test("Pending delete op blocks re-insertion of message")
    func pendingDeleteBlocksInsertion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Create pending delete operation
        let pendingOp = PendingOperation(
            type: .delete,
            messageIds: ["99"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try db.write { try pendingOp.insert($0) }

        // Remote still returns the deleted message
        let remoteMessages = [
            makeHeaderInfo(messageId: "99", subject: "Deleted by user"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        #expect(result.newHeaders.isEmpty)

        let msg = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:99") }
        #expect(msg == nil)
    }

    @Test("Pending move op protects message from stale deletion")
    func pendingMoveOpProtection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Local message exists (user moved it but drain hasn't run yet)
        try TestDatabase.insertMessageHeader(db, messageId: "77", subject: "Moving msg")

        // Create pending move operation
        let pendingOp = PendingOperation(
            type: .move,
            messageIds: ["77"],
            accountId: "acc1",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try db.write { try pendingOp.insert($0) }

        // Remote no longer has message "77" (already moved on server)
        let remoteMessages = [
            makeHeaderInfo(messageId: "88", subject: "Other message"),
        ]

        let result = try simulateRunSyncMessages(db: db, folder: folder, messages: remoteMessages, limit: 50)

        // Message "77" should NOT be stale-deleted (protected by pending move op)
        #expect(result.staleIds.isEmpty)

        let msg77 = try db.read { try MessageHeader.fetchOne($0, key: "acc1:INBOX:77") }
        #expect(msg77 != nil)
    }
}

// MARK: - Suite: UID remap ftsRekeys emission (real runSyncMessages)

/// Drives the REAL `SyncEngine.runSyncMessages` (not the replicated sim above
/// — the real function needs a `DatabasePool`) against `MockEmailProvider` to
/// lock the UID-remap contract introduced with `SearchIndex.rekeyHeaders`:
/// a re-keyed row must ride `ftsRekeys` (its FTS entry MOVES in place,
/// preserving indexed body + embedding) and must NOT ride `staleIds` (which
/// would delete that entry) nor `newHeaders` (header-only re-index).
@Suite("runSyncMessages — UID remap ftsRekeys emission", .serialized, .processGlobalState)
struct RunSyncUIDRemapFtsRekeyTests {

    @Test("Remap emits ftsRekeys with new messageId; old id avoids staleIds/newHeaders")
    func remapEmitsFtsRekey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await pool.write { db in
            var acc = Account(emailAddress: "remap@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "racc")
            try folder.insert(db)
            var header = MessageHeader(
                messageId: "100", subject: "Remap target", from: "a@x", fromAddress: "a@x",
                to: "b@x", date: date, snippet: "s",
                folderId: "racc:INBOX", accountId: "racc", folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = "remap-x@example.com"
            header.headerComplete = true
            header.bodyComplete = true
            try header.insert(db)
            try MessageBody( contentKey: ContentKey(rawValue: "racc:INBOX:100"), htmlContent: "<p>kept</p>").insert(db)
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:INBOX")! }
        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "200", rfc822MessageId: "remap-x@example.com",
                           subject: "Remap target", date: date)
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        // ftsRekeys carries the move, with the new provider message id.
        #expect(result.ftsRekeys.count == 1)
        #expect(result.ftsRekeys.first?.oldId == "racc:INBOX:100")
        #expect(result.ftsRekeys.first?.newId == "racc:INBOX:200")
        #expect(result.ftsRekeys.first?.newMessageId == "200")
        // The old id must NOT be removed from FTS or header-only re-indexed.
        #expect(!result.staleIds.contains("racc:INBOX:100"))
        #expect(!result.newHeaders.contains { $0.id == "racc:INBOX:200" })
        #expect(result.uidMigratedOldIds == ["100"])

        // GRDB row re-keyed in place, body preserved, bodyComplete untouched
        // (its FTS entry rides the rekey — no refetch churn).
        let migrated = try await pool.read { try MessageHeader.fetchOne($0, key: "racc:INBOX:200") }
        #expect(migrated != nil)
        #expect(migrated?.bodyComplete == true)
        let old = try await pool.read { try MessageHeader.fetchOne($0, key: "racc:INBOX:100") }
        #expect(old == nil)
        let body = try await pool.read { try MessageBody.fetchOne($0, key: "racc:INBOX:200") }
        #expect(body?.htmlContent == "<p>kept</p>")
    }
}

// MARK: - FIX A: bounded newRemoteIds membership (SyncEngine.newRemoteIds)

/// Direct coverage for `SyncEngine.newRemoteIds(in:folderId:remoteIds:cachedLocalIds:)`
/// — the bounded membership check that replaced an unbounded full-folder load inside
/// `runSyncMessages` (All Mail was ~7s of write execution). Unlike the rest of this
/// file (which simulates the sync core), these call the REAL production helper, so they
/// guard the chunked-stride path, the empty-`remoteIds` no-op (a raw `IN ()` would be
/// invalid SQL), folder scoping, and equivalence with the full-load subtraction it
/// replaced.
@Suite("runSyncMessages — newRemoteIds (bounded membership)")
struct RunSyncNewRemoteIdsTests {

    @Test("Returns only remote ids not already present locally (DB path)")
    func newIdsFromDB() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")
        try TestDatabase.insertMessageHeader(db, messageId: "3")

        let remote: Set<String> = ["2", "3", "4", "5"]
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: nil)
        }
        #expect(result == ["4", "5"])
    }

    @Test("Empty remoteIds is a valid no-op (no IN () crash)")
    func emptyRemoteIds() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: [], cachedLocalIds: nil)
        }
        #expect(result.isEmpty)
    }

    @Test("All remote already local → empty")
    func allLocal() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")

        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: ["1", "2"], cachedLocalIds: nil)
        }
        #expect(result.isEmpty)
    }

    @Test("No local rows → every remote id is new")
    func noneLocal() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remote: Set<String> = ["7", "8", "9"]
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: nil)
        }
        #expect(result == remote)
    }

    @Test("cachedLocalIds path bypasses the DB entirely")
    func cachedPath() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        // No rows inserted for "2"/"3", yet the cache marks them local → they must be
        // excluded purely from the cache, proving the DB path is not consulted.
        let remote: Set<String> = ["2", "3", "4"]
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: ["2", "3"])
        }
        #expect(result == ["4"])
    }

    @Test("Scoped to the folder — same messageId in another folder is still new")
    func folderScoped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let archive = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        // messageId "5" exists only in Archive.
        try TestDatabase.insertMessageHeader(db, messageId: "5", folderId: archive.id, folderPath: "Archive")

        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: inbox.id, remoteIds: ["5"], cachedLocalIds: nil)
        }
        #expect(result == ["5"])
    }

    @Test("Chunked path (> chunk size) equals full-load subtraction")
    func chunkedEquivalence() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        // 300 local ids "0".."299".
        var localIds = Set<String>()
        for i in 0..<300 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
            localIds.insert("\(i)")
        }
        // 601 remote ids "0".."600" → forces two IN chunks (sqlChunkSize = 500).
        let remote = Set((0...600).map { "\($0)" })
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: nil)
        }
        #expect(result == remote.subtracting(localIds))
    }
}

// MARK: - FIX C: large-folder stale safety (real runSyncMessages)

/// Drives the REAL `SyncEngine.runSyncMessages` via `MockEmailProvider` to lock the
/// FIX C safeguard: when a fetch returns FEWER than `limit` messages, the
/// "complete-knowledge" stale path (delete any local row not returned) is taken ONLY
/// when the local side is <= `SyncConfig.staleDetectionMaxFullScan`. A LARGE folder
/// that returns < limit is a truncated/partial fetch — treating it as complete would
/// mass-stale-delete the rows it never returned (the ADR-IOS-042 data-loss class).
@Suite("runSyncMessages — large-folder stale safety (FIX C)", .serialized, .processGlobalState)
struct RunSyncLargeFolderStaleSafetyTests {

    @Test("Large folder + partial (< limit) fetch does NOT mass-stale-delete unreturned rows")
    func largeFolderPartialFetchNoMassStale() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let oldCount = SyncConfig.staleDetectionMaxFullScan + 50   // exceeds the gate
        try await pool.write { db in
            var acc = Account(emailAddress: "arch@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "racc").insert(db)
            // Many OLD low-UID archive rows (below any realistic fetch floor).
            for uid in 1...oldCount {
                var h = MessageHeader(
                    messageId: "\(uid)", subject: "Old \(uid)", from: "a@x", fromAddress: "a@x",
                    to: "b@x", date: date, snippet: "s",
                    folderId: "racc:Archive", accountId: "racc", folderPath: "Archive", isInInbox: false
                )
                h.rfc822MessageId = "old-\(uid)@example.com"
                h.headerComplete = true
                try h.insert(db)
            }
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Archive")! }
        // Simulate a TRUNCATED fetch of a huge folder: only 3 high-UID messages come back
        // (< limit), none matching the old local rows.
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "900000", rfc822MessageId: "new-900000@example.com", subject: "New", date: date),
            makeHeaderInfo(messageId: "900001", rfc822MessageId: "new-900001@example.com", subject: "New", date: date),
            makeHeaderInfo(messageId: "900002", rfc822MessageId: "new-900002@example.com", subject: "New", date: date),
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        // FIX C: localCount > threshold → bounded windowed path (UID floor = 900000), so
        // none of the old low-UID rows are candidates → nothing stale-deleted. Without the
        // gate this would complete-knowledge-delete all `oldCount` rows (ADR-IOS-042).
        #expect(result.staleIds.isEmpty)
        let survivors = try await pool.read {
            try MessageHeader.filter(Column("folderId") == "racc:Archive").fetchCount($0)
        }
        #expect(survivors >= oldCount)          // all old rows survive (+ the 3 new inserts)
        let firstRow = try await pool.read { try MessageHeader.fetchOne($0, key: "racc:Archive:1") }
        #expect(firstRow != nil)
    }

    @Test("Small folder + partial (< limit) fetch STILL stale-deletes a genuinely-missing row")
    func smallFolderCompleteKnowledgePreserved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await pool.write { db in
            var acc = Account(emailAddress: "arch@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "racc").insert(db)
            for uid in 1...5 {
                var h = MessageHeader(
                    messageId: "\(uid)", subject: "Msg \(uid)", from: "a@x", fromAddress: "a@x",
                    to: "b@x", date: date, snippet: "s",
                    folderId: "racc:Archive", accountId: "racc", folderPath: "Archive", isInInbox: false
                )
                h.rfc822MessageId = "m-\(uid)@example.com"
                h.headerComplete = true
                try h.insert(db)
            }
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Archive")! }
        // Server now returns only UIDs 1-4 (< limit); UID 5 is genuinely gone.
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult((1...4).map { uid in
            makeHeaderInfo(messageId: "\(uid)", rfc822MessageId: "m-\(uid)@example.com", subject: "Msg \(uid)", date: date)
        })

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        // localCount (5) <= threshold → complete-knowledge path preserved → UID 5 is stale.
        #expect(result.staleIds.contains("racc:Archive:5"))
        #expect(!result.staleIds.contains("racc:Archive:1"))
    }
}
