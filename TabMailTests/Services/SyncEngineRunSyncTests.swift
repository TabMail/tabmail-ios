/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
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
/// ⚠ **DELIBERATELY OMITTED: provider-address ownership** (T5.11 — the
/// canonicalizer, existing-merge, and orphan-reclaim gates). This simulation keeps the
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

        // Stale detection — delegate to the production source of truth
        // (`SyncEngine.selectStaleHeaders`, ADR-IOS-042) so this harness can never
        // drift from real sync behavior. Same idiom as the sibling harness in
        // `E2ESyncScenarioTests`.
        //
        // Coverage models a server that returned `messages` verbatim for a window of
        // `limit` — the harness feeds `selectStaleHeaders` directly, so there is no
        // provider narrowing between the two and `messages.count` IS the server's
        // record count here. Real providers must NOT derive coverage this way; see
        // `FetchCoverage`.
        //
        // `.date` preserves the window this harness has always applied. The
        // UID-vs-date choice itself is pinned against real providers in
        // `E2ESyncScenarioTests`; nothing here decides it.
        let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn)
        let stale = SyncEngine.selectStaleHeaders(
            candidates: allLocal, fetched: messages,
            coverage: FetchCoverage(
                serverRecordCount: messages.count,
                spansEntireFolder: messages.count < limit,
                unmaterialisedIds: []),
            windowMode: .date)

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
            // Mirrors production (`SyncEngineFullSync` UID-remap leg): fetch the body
            // BEFORE deleting the header, then delete its row EXPLICITLY. Stage D
            // (`v70_dropMessageBodyHeaderFK`) removed the FK cascade that used to do
            // the second half, and without it the old row survives alongside the copy
            // re-inserted under the new id — a duplicate plus a leak.
            let oldBody = try MessageBody.fetchOne(dbConn, key: oldId)
            try staleMsg.delete(dbConn)
            _ = try MessageBody.deleteOne(dbConn, key: ContentKey(rawValue: oldId))
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
        guard result.staleIds.count == 1 else { return }
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
        guard result.staleIds.count == 1 else { return }
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
        guard result.replyDetectIds.count == 1 else { return }
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

    /// ⚠ This test USED to pass for a reason that no longer exists. Its "old body is
    /// gone" assertion was satisfied by the FK cascade firing on the header delete;
    /// Stage D (`v70_dropMessageBodyHeaderFK`) removed that cascade, so the same
    /// assertion is now satisfied only by the explicit `MessageBody.deleteOne` the
    /// remap leg gained. Keeping it green therefore means something different — and
    /// it is the NEW failure mode (a leftover row under the OLD key, alongside the
    /// copy under the new one) that it now guards.
    @Test("UID remap: body moves to the new id and leaves NO row under the old key")
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

        // THE NEW FAILURE MODE: no leftover row under the OLD key. With the cascade
        // gone this is exactly what an unfixed remap leg would leave behind, and the
        // count is asserted (not just `fetchOne == nil`) so a duplicate is visible.
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:300") }
        #expect(oldBody == nil, "a leftover body under the pre-remap key is a duplicate AND a leak")
        let totalBodies = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageBody") ?? -1
        }
        #expect(totalBodies == 1, "the re-key must MOVE the body, not copy it")

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
        guard result.newHeaders.count == 1 else { return }
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
        let mock = MockEmailProvider(staleWindowMode: .uid)
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
        #expect(result.headerRekeys == [HeaderRekeyRecord(
            oldHeaderId: "racc:INBOX:100",
            newHeaderId: "racc:INBOX:200",
            newProviderMessageId: "200",
            carriesProviderAuthority: false)])
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

    @Test("Committed UID remap publishes the exact active-view identity mapping")
    func remapPublishesActiveViewMapping() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        let appDB = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDB
            return prior
        }
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let date = Date()
        let folder = try await pool.write { db -> Folder in
            var account = Account(
                emailAddress: "remap-notify@example.com", displayName: "Test", provider: .imap)
            account.id = "notify-account"
            try account.insert(db)
            let folder = Folder(
                name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
            try folder.insert(db)
            var header = MessageHeader(
                messageId: "301", subject: "Pending AI update",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "remap-notify@example.com", date: date, snippet: "Body",
                folderId: folder.id, accountId: account.id, folderPath: folder.path,
                isInInbox: true)
            header.rfc822MessageId = "<sync-ui-rekey@example.com>"
            header.headerComplete = true
            header.actionTag = .reply
            header.summaryBlurb = "AI result survives the key change"
            try header.insert(db)
            return folder
        }

        let published = Mutex<[HeaderRekeyRecord]>([])
        let token = NotificationCenter.default.addObserver(
            forName: .messageHeadersRekeyed, object: nil, queue: nil
        ) { notification in
            guard let records = notification.object as? [HeaderRekeyRecord] else { return }
            published.withLock { $0.append(contentsOf: records) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: "302", rfc822MessageId: "<sync-ui-rekey@example.com>",
                subject: "Pending AI update", date: date)
        ])

        try await SyncEngine().syncMessages(for: folder, provider: provider, limit: 50)

        let records = published.withLock { $0 }
        #expect(records == [HeaderRekeyRecord(
            oldHeaderId: "notify-account:INBOX:301",
            newHeaderId: "notify-account:INBOX:302",
            newProviderMessageId: "302",
            carriesProviderAuthority: false)])
        let migrated = try await pool.read {
            try MessageHeader.fetchOne($0, key: "notify-account:INBOX:302")
        }
        #expect(migrated?.actionTag == .reply)
        #expect(migrated?.summaryBlurb == "AI result survives the key change")
    }

    @Test("Date-window RFC repair does not publish an actionable active-view mapping")
    func dateWindowRepairKeepsViewCarrierEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        try AppDatabase.runMigrations(on: pool)

        let date = Date().addingTimeInterval(-600)
        try await pool.write { db in
            var account = Account(
                emailAddress: "graph-remap@example.com", displayName: "T", provider: .outlook)
            account.id = "graph-remap"
            try account.insert(db)
            let folder = Folder(
                name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
            try folder.insert(db)
            var header = MessageHeader(
                messageId: "old-graph-id", subject: "Same RFC", from: "a@x", fromAddress: "a@x",
                to: "b@x", date: date, snippet: "s", folderId: folder.id,
                accountId: account.id, folderPath: folder.path, isInInbox: true)
            header.rfc822MessageId = "<duplicate-rfc@example.com>"
            header.headerComplete = true
            try header.insert(db)
        }

        let folder = try await pool.read {
            try Folder.fetchOne($0, key: "graph-remap:INBOX")!
        }
        let provider = MockEmailProvider(staleWindowMode: .date)
        await provider.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: "new-graph-id", rfc822MessageId: "<duplicate-rfc@example.com>",
                subject: "Same RFC", date: date)
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: provider, limit: 50,
            dbPool: PrioritizedDatabase(pool: pool))

        #expect(result.ftsRekeys.count == 1, "durable/FTS repair remains unchanged")
        #expect(result.headerRekeys.isEmpty,
                "weak date-window correlation must not become active provider-id state")
    }

    @Test("Full sync publishes UID remap through the view model's production observer")
    @MainActor func fullSyncPublishesThroughViewModelObserver() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        let appDB = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDB
            return prior
        }
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let date = Date().addingTimeInterval(-300)
        let (account, folder) = try await pool.write { db -> (Account, Folder) in
            var account = Account(
                emailAddress: "full-remap@example.com", displayName: "T", provider: .imap)
            account.id = "full-remap"
            try account.insert(db)
            let folder = Folder(
                name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
            try folder.insert(db)
            var header = MessageHeader(
                messageId: "401", subject: "Full sync remap", from: "a@x", fromAddress: "a@x",
                to: "b@x", date: date, snippet: "s", folderId: folder.id,
                accountId: account.id, folderPath: folder.path, isInInbox: true)
            header.rfc822MessageId = "<full-sync-rekey@example.com>"
            header.headerComplete = true
            try header.insert(db)
            return (account, folder)
        }

        let viewModel = InboxViewModel(folders: [folder])
        viewModel.start()
        viewModel.loadInitialPage()
        #expect(viewModel.loadedMessages.map(\.id) == ["full-remap:INBOX:401"])

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchFoldersResult([
            FolderInfo(
                name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0,
                totalCount: 1, uidNext: 403, uidValidity: nil)
        ])
        await provider.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: "402", rfc822MessageId: "<full-sync-rekey@example.com>",
                subject: "Full sync remap", date: date)
        ])

        try await SyncEngine().fullSync(account: account, provider: provider)

        #expect(!viewModel.loadedMessages.contains { $0.id == "full-remap:INBOX:401" })
        #expect(viewModel.loadedMessages.filter { $0.id == "full-remap:INBOX:402" }.count == 1)
    }
}

// MARK: - Suite: R16-8 — the dedup / reclaim carriers must route their old ids

/// 🚨 THE INVARIANT, as the system property and not the mechanism (`MIS-015`):
/// **no FTS entry survives at an id that names no header** ("indexed but
/// unfindable"), and **a re-keyed header's FTS entry MOVES to the new id rather
/// than being left behind**.
///
/// `runSyncMessages` owns two channels out of its write closure: `ftsRekeys` (the
/// entry moves in place, preserving the indexed body text and the `messages_vec`
/// embedding) and `staleIds` (the entry is deleted). Its UID-remap carrier routes
/// through both correctly. Four sibling legs in the SAME closure did not: the
/// DraftDedup block's collision and success legs, and the pre-sync reclaim's
/// success leg and its `dropFirst()` tail deletes. Each of those blocks ends in
/// `continue`, which bypasses every shared disposition below, so an old id that is
/// not routed EXPLICITLY rides neither channel and is simply forgotten.
///
/// ⚠️ NOT a "the next sync repairs it" case. The compensating sweep
/// `pruneFTSOrphans` has ONE production caller, `oneTimeFTSReconciliation`, gated on
/// a `UserDefaults` flag it sets on first success with no production reset — so it
/// provably cannot run a second time (`MIS-024`). The leak is permanent.
///
/// Asserted on the RESULT CHANNELS rather than on `SearchIndex` itself because the
/// channels are what `syncMessages` hands to `SearchIndex.rekeyHeaders` /
/// `removeHeadersFromFTS` verbatim, and driving the real FTS store would make the
/// fixture, not the routing, the thing under test. This is the tightest seam that
/// still runs the REAL `runSyncMessages`.
@Suite("runSyncMessages — R16-8 dedup/reclaim FTS routing", .serialized, .processGlobalState)
struct RunSyncDedupReclaimFtsRoutingTests {

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        try AppDatabase.runMigrations(on: pool)
        return (pool, dir)
    }

    private static let syncDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// A local row, inserted verbatim (no id derivation), so a fixture can express
    /// folder drift.
    private static func insertHeader(
        _ db: Database, messageId: String, folderPath: String, folderId: String,
        rfc822: String?, isInInbox: Bool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "fixture", from: "a@x", fromAddress: "a@x",
            to: "b@x", date: Self.syncDate, snippet: "s",
            folderId: folderId, accountId: "racc", folderPath: folderPath,
            isInInbox: isInInbox)
        header.rfc822MessageId = rfc822
        header.headerComplete = true
        header.bodyComplete = true
        try header.insert(db)
        return header
    }

    /// THE SUCCESS LEG of the DraftDedup block: the optimistic placeholder's body is
    /// CARRIED to the server-assigned address, so its FTS entry must move with it.
    @Test("DraftDedup replacing an optimistic placeholder re-keys the FTS entry instead of orphaning it")
    func draftDedupSuccessRoutesTheOldIdToFtsRekeys() async throws {
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let rfc = "draft-r16-8@example.com"
        let placeholderId = MessageIdentity.headerId(
            accountId: "racc", folderPath: "Drafts", messageId: "draft-local-1")
        try await pool.write { db in
            var acc = Account(emailAddress: "d@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "racc").insert(db)
            _ = try Self.insertHeader(
                db, messageId: "draft-local-1", folderPath: "Drafts",
                folderId: "racc:Drafts", rfc822: rfc, isInInbox: false)
            try MessageBody(
                contentKey: ContentKey(rawValue: placeholderId),
                htmlContent: "<p>authored</p>").insert(db)
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Drafts")! }
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "42", rfc822MessageId: rfc, subject: "fixture", date: Self.syncDate)
        ])

        // limit == message count ⇒ the mock reports a PARTIAL fetch, so complete-
        // knowledge stale detection is off and the non-numeric placeholder id is not
        // a UID-stale candidate. Without that the placeholder would be deleted by the
        // stale channel and this leg would never run.
        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 1, dbPool: PrioritizedDatabase(pool: pool))

        // Non-vacuity: the dedup really did replace the placeholder with the server row.
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: placeholderId) } == nil,
                "setup: the optimistic placeholder must have been replaced — got a surviving row")
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: "racc:Drafts:42") } != nil,
                "setup: the server-addressed row must exist")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: "racc:Drafts:42") }?.htmlContent
                == "<p>authored</p>",
                "setup: the body was CARRIED, which is why the FTS entry must move rather than be deleted")

        #expect(result.ftsRekeys.contains {
            $0.oldId == placeholderId && $0.newId == "racc:Drafts:42" && $0.newMessageId == "42"
        }, """
        the placeholder's indexed text was carried to the server address, so its FTS \
        entry must MOVE there. Routed through neither channel it stays filed under a \
        header id that no longer exists — an entry search can hit and never resolve — \
        and `pruneFTSOrphans` provably cannot run again to clean it. \
        Got ftsRekeys=\(result.ftsRekeys.map { "\($0.oldId)→\($0.newId)" })
        """)
        #expect(!result.staleIds.contains(placeholderId),
                "and it must NOT ride the removal channel — deleting the entry would throw away the indexed body text and its embedding for content that still exists")
    }

    /// THE COLLISION LEG of the same block: the placeholder is DISCARDED (already
    /// deleted, its deferred body never inserted), so the old id names content that no
    /// longer exists anywhere and must ride the REMOVAL channel.
    ///
    /// This is the two-sided half (`MIS-026`): the two legs of one block need
    /// OPPOSITE channels, so a fix that routed everything to `ftsRekeys` would be its
    /// own defect — re-keying an entry onto a row whose content was never written.
    @Test("A collided DraftDedup routes the discarded placeholder to the removal channel")
    func draftDedupCollisionRoutesTheOldIdToStaleIds() async throws {
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let rfc = "draft-r16-8-collided@example.com"
        let placeholderId = MessageIdentity.headerId(
            accountId: "racc", folderPath: "Drafts", messageId: "draft-local-1")
        try await pool.write { db in
            var acc = Account(emailAddress: "d@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "racc").insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "racc").insert(db)
            _ = try Self.insertHeader(
                db, messageId: "draft-local-1", folderPath: "Drafts",
                folderId: "racc:Drafts", rfc822: rfc, isInInbox: false)
            // A row already occupying the server-assigned PK, but whose folderId
            // column points elsewhere — so the per-message existence lookup (which
            // filters on folderId) does not see it and the dedup block's own
            // `fetchOne(key:)` does. That is the reachable shape of the block's
            // "already exists (post-snapshot)" guard.
            _ = try Self.insertHeader(
                db, messageId: "42", folderPath: "Drafts", folderId: "racc:INBOX",
                rfc822: "someone-else@example.com", isInInbox: false)
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Drafts")! }
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "42", rfc822MessageId: rfc, subject: "fixture", date: Self.syncDate)
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 1, dbPool: PrioritizedDatabase(pool: pool))

        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: placeholderId) } == nil,
                "setup: the collision leg deletes the placeholder before returning — got a surviving row")
        #expect(result.staleIds.contains(placeholderId),
                """
                the placeholder was DISCARDED, not migrated: its row is deleted and its \
                deferred body was never inserted, so its FTS entry names content that \
                exists nowhere. Unrouted it is a permanent orphan. \
                Got staleIds=\(result.staleIds)
                """)
        #expect(!result.ftsRekeys.contains { $0.oldId == placeholderId },
                "and it must NOT ride the re-key channel — there is no carried content to move it onto")
    }

    /// THE PRE-SYNC RECLAIM, both legs at once: the FIRST drifted row is reclaimed
    /// (its body is carried to the canonical address ⇒ re-key channel) and every TAIL
    /// duplicate is deleted outright (⇒ removal channel). One fixture, two opposite
    /// dispositions, which is what makes it non-vacuous in both directions.
    @Test("Pre-sync reclaim re-keys the row it migrates and removes the duplicates it deletes")
    func preSyncReclaimRoutesBothLegs() async throws {
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let rfc = "reclaim-r16-8@example.com"
        let firstDriftedId = MessageIdentity.headerId(
            accountId: "racc", folderPath: "NSE-A", messageId: "42")
        let secondDriftedId = MessageIdentity.headerId(
            accountId: "racc", folderPath: "NSE-B", messageId: "42")
        let driftedIds = [firstDriftedId, secondDriftedId]
        try await pool.write { db in
            var acc = Account(emailAddress: "r@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "racc").insert(db)
            try Folder(name: "NSE-A", path: "NSE-A", role: .custom, accountId: "racc").insert(db)
            try Folder(name: "NSE-B", path: "NSE-B", role: .custom, accountId: "racc").insert(db)
            _ = try Self.insertHeader(
                db, messageId: "42", folderPath: "NSE-A", folderId: "racc:NSE-A",
                rfc822: rfc, isInInbox: true)
            try MessageBody(
                contentKey: ContentKey(rawValue: firstDriftedId),
                htmlContent: "<p>reclaimed</p>").insert(db)
            _ = try Self.insertHeader(
                db, messageId: "42", folderPath: "NSE-B", folderId: "racc:NSE-B",
                rfc822: rfc, isInInbox: true)
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:INBOX")! }
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "42", rfc822MessageId: rfc, subject: "fixture", date: Self.syncDate)
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: "racc:INBOX:42") } != nil,
                "setup: the reclaim must have produced the canonical inbox row")
        let survivingDrifted = try await pool.read { db in
            try driftedIds.filter { try MessageHeader.fetchOne(db, key: $0) != nil }
        }
        #expect(survivingDrifted.isEmpty,
                "setup: both drifted rows are consumed by the reclaim — got \(survivingDrifted)")

        let rekeyedOldIds = result.ftsRekeys.map(\.oldId).filter { driftedIds.contains($0) }
        #expect(rekeyedOldIds.count == 1,
                """
                exactly one drifted row is RECLAIMED — its body is carried to the canonical \
                address, so its indexed text must move with it rather than stay filed under \
                a header id the reclaim just deleted. \
                Got ftsRekeys=\(result.ftsRekeys.map { "\($0.oldId)→\($0.newId)" })
                """)
        guard rekeyedOldIds.count == 1 else { return }
        let reclaimedId = rekeyedOldIds[0]
        #expect(result.ftsRekeys.contains { $0.oldId == reclaimedId && $0.newId == "racc:INBOX:42" },
                "and it must move to the canonical inbox address")

        let droppedIds = driftedIds.filter { $0 != reclaimedId }
        #expect(droppedIds.count == 1)
        guard droppedIds.count == 1 else { return }
        #expect(result.staleIds.contains(droppedIds[0]),
                """
                the TAIL duplicate is deleted outright, not migrated, so its FTS entry must \
                go with it. This is the third member of the same class, enumerated by \
                "a header row this block destroys or re-keys" rather than by \
                "a block that re-keys". Got staleIds=\(result.staleIds)
                """)
        #expect(!result.ftsRekeys.contains { $0.oldId == droppedIds[0] },
                "and the deleted duplicate must not be re-keyed onto the survivor's address")
    }

    /// IOS-PERF-012 group 1 — this probe is destructive: the selected row is
    /// deleted and its body is carried onto the server-assigned address. The
    /// fixture makes insertion order disagree with id order so an order-blind
    /// statement cannot accidentally satisfy the assertion.
    @Test("Same-folder duplicate RFC placeholders: the lowest-id row is the one collapsed")
    func draftDedupPicksTheLowestIdDuplicateDeterministically() async throws {
        let (pool, dir) = try makePool()
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let rfc = "draft-perf012-duplicate@example.com"
        let selectedId = MessageIdentity.headerId(
            accountId: "racc", folderPath: "Drafts", messageId: "draft-local-a")
        let decoyId = MessageIdentity.headerId(
            accountId: "racc", folderPath: "Drafts", messageId: "draft-local-z")
        try await pool.write { db in
            var acc = Account(emailAddress: "d@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "racc").insert(db)
            _ = try Self.insertHeader(
                db, messageId: "draft-local-z", folderPath: "Drafts",
                folderId: "racc:Drafts", rfc822: rfc, isInInbox: false)
            try MessageBody(
                contentKey: ContentKey(rawValue: decoyId),
                htmlContent: "<p>decoy draft</p>").insert(db)
            _ = try Self.insertHeader(
                db, messageId: "draft-local-a", folderPath: "Drafts",
                folderId: "racc:Drafts", rfc822: rfc, isInInbox: false)
            try MessageBody(
                contentKey: ContentKey(rawValue: selectedId),
                htmlContent: "<p>selected draft</p>").insert(db)
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Drafts")! }
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "42", rfc822MessageId: rfc, subject: "fixture", date: Self.syncDate)
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 1, dbPool: PrioritizedDatabase(pool: pool))

        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: "racc:Drafts:42") } != nil,
                "setup: the server-addressed row must exist")
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: selectedId) } == nil,
                "the lowest-id duplicate is the row the destructive dedup must collapse")
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: decoyId) } != nil,
                "the higher-id duplicate must survive untouched")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: "racc:Drafts:42") }?.htmlContent
                == "<p>selected draft</p>",
                "the selected row's authored body must land on the server address")
        #expect(try await pool.read { try MessageBody.fetchOne($0, key: decoyId) }?.htmlContent
                == "<p>decoy draft</p>",
                "the surviving duplicate must retain its own body")
        #expect(result.ftsRekeys.contains { $0.oldId == selectedId && $0.newId == "racc:Drafts:42" },
                "the selected row's FTS entry must move with its body")
        #expect(!result.ftsRekeys.contains { $0.oldId == decoyId },
                "the survivor's FTS entry must not be re-keyed")
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

// MARK: - A3.6: SyncEngine.upsertInsertedIdSummary (pure formatter)

/// `SyncEngine.upsertInsertedIdSummary` is the PURE renderer behind each
/// segment of the debug-gated `fullSync upsert[...]` `[MoveTrace]` diagnostic
/// (`SyncEngineFullSync.swift`: rendered inside `runSyncMessages`'s write
/// closure, emitted by `BackgroundSyncLogger.logQueue` only after that write
/// has COMMITTED — see the call site). Extracted so both its branches are
/// directly unit-testable without a debug gate, a DB, or a sync fixture that
/// has to produce `SyncConfig.upsertInsertedIdLogCap` (20) inserted headers in
/// one pass.
///
/// Global `CLAUDE.md` rule 11: the cap is a DISPLAY cap on synthetic header
/// ids only — it bounds no fetch, no batch and nothing written to the
/// database. This suite pins the FORMATTER's contract in isolation; the real
/// full-sync path (proving the cap never truncates the DURABLE row) is
/// pinned in `SyncEngineFullSyncUpsertDiagnosticTests` below.
@Suite("SyncEngine.upsertInsertedIdSummary")
struct SyncEngineUpsertInsertedIdSummaryTests {

    @Test("Under the cap renders every id verbatim with no overflow suffix")
    func underCapRendersEveryIdVerbatim() {
        let ids = ["hdr-a", "hdr-b", "hdr-c"]
        let summary = SyncEngine.upsertInsertedIdSummary(ids)
        #expect(summary == "inserted 3 header(s): hdr-a,hdr-b,hdr-c")
    }

    @Test("Exactly at the cap renders every id with no overflow suffix — elided > 0, not >= 0")
    func exactlyAtCapRendersNoOverflowSuffix() {
        let cap = SyncConfig.upsertInsertedIdLogCap
        let ids = (0..<cap).map { "hdr-\($0)" }
        let summary = SyncEngine.upsertInsertedIdSummary(ids)
        #expect(summary == "inserted \(cap) header(s): " + ids.joined(separator: ","))
        #expect(!summary.contains("more)"),
                "exactly-cap must not trigger the overflow suffix: \(summary)")
    }

    @Test("Over the cap renders exactly cap ids and states the elided remainder arithmetically")
    func overCapElidesAndStatesRemainderArithmetically() {
        let cap = SyncConfig.upsertInsertedIdLogCap
        let extra = 7
        let total = cap + extra
        let ids = (0..<total).map { "hdr-\($0)" }
        let summary = SyncEngine.upsertInsertedIdSummary(ids)

        let prefixLabel = "inserted \(total) header(s): "
        #expect(summary.hasPrefix(prefixLabel), "total must be stated exactly: \(summary)")
        guard summary.hasPrefix(prefixLabel) else { return }
        let remainder = summary.dropFirst(prefixLabel.count)

        guard let overflowRange = remainder.range(of: " (+") else {
            Issue.record("missing overflow suffix in: \(summary)")
            return
        }
        let renderedIdsJoined = remainder[remainder.startIndex..<overflowRange.lowerBound]
        let renderedIds = renderedIdsJoined.isEmpty
            ? [] : renderedIdsJoined.split(separator: ",").map(String.init)
        #expect(renderedIds.count == cap, "exactly cap ids must render: got \(renderedIds.count)")
        #expect(renderedIds == Array(ids.prefix(cap)))

        let suffix = remainder[overflowRange.lowerBound...]
        guard suffix.hasSuffix(" more)") else {
            Issue.record("overflow suffix malformed: \(suffix)")
            return
        }
        let digits = suffix.dropFirst(" (+".count).dropLast(" more)".count)
        guard let elidedFromString = Int(digits) else {
            Issue.record("overflow count not parseable: \(suffix)")
            return
        }
        // Arithmetic, not a hardcoded literal: whatever the elided count says,
        // it must exactly account for what the cap left out — this must hold
        // regardless of what `extra` above is set to.
        #expect(elidedFromString + cap == total,
                "elided(\(elidedFromString)) + cap(\(cap)) must equal total(\(total))")
    }

    @Test("Empty input renders the zero-insert line verbatim — total 0, no ids, no overflow suffix, trailing separator retained")
    func emptyInputRendersZeroInsertLineVerbatim() {
        let summary = SyncEngine.upsertInsertedIdSummary([])
        // Exact string, trailing space included: `"inserted \(0) header(s): "`
        // + `""` (no ids) + `""` (no overflow). A phantom id, a clamped
        // count, or a dropped separator each changes this text.
        #expect(summary == "inserted 0 header(s): ")
        #expect(!summary.contains("more)"), "an empty input must not render an overflow suffix: \(summary)")
    }

    @Test("The verb is a parameter — a `reclaimed` segment renders with the same shape, cap and overflow arithmetic as `inserted`")
    func reclaimedVerbRendersWithTheSameShapeCapAndOverflow() {
        #expect(SyncEngine.upsertInsertedIdSummary([], verb: "reclaimed") == "reclaimed 0 header(s): ")
        #expect(SyncEngine.upsertInsertedIdSummary(["hdr-a", "hdr-b"], verb: "reclaimed")
                == "reclaimed 2 header(s): hdr-a,hdr-b")

        // Same cap, same elision arithmetic — only the verb differs.
        let cap = SyncConfig.upsertInsertedIdLogCap
        let total = cap + 3
        let ids = (0..<total).map { "hdr-\($0)" }
        let reclaimed = SyncEngine.upsertInsertedIdSummary(ids, verb: "reclaimed")
        let inserted = SyncEngine.upsertInsertedIdSummary(ids)
        #expect(reclaimed.hasPrefix("reclaimed \(total) header(s): "), "total must be stated exactly: \(reclaimed)")
        #expect(reclaimed.dropFirst("reclaimed".count) == inserted.dropFirst("inserted".count),
                "the two verbs must render byte-identical bodies: \(reclaimed) vs \(inserted)")
        #expect(reclaimed.hasSuffix(" (+\(total - cap) more)"), "the elided remainder must be stated: \(reclaimed)")
    }
}

// MARK: - A3.6: full-sync upsert diagnostic — real runSyncMessages, [MoveTrace] queue line

/// Drives the REAL `SyncEngine.runSyncMessages` end to end (real DB, real
/// `AppLogStore`/`DebugModeManager` gate) to pin the debug-gated
/// `[MoveTrace] fullSync upsert[...]` diagnostic that `SyncEngineFullSync.swift`
/// writes via `BackgroundSyncLogger.logQueue` — the `.queue` channel line this
/// round added alongside `SyncEngine.upsertInsertedIdSummary`.
///
/// `.serialized, .processGlobalState`: every test here rebinds the same
/// process globals `AppLogStoreTests` and `AccountManagerQueueDrainTests` do
/// (`AppLogStore.fileURLOverride`, `DebugModeManager.loggingEnabledOverrideForTesting`).
@Suite("SyncEngine full-sync upsert diagnostic — [MoveTrace] fullSync upsert", .serialized, .processGlobalState)
struct SyncEngineFullSyncUpsertDiagnosticTests {

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        try AppDatabase.runMigrations(on: pool)
        return (pool, dir)
    }

    /// Redirect the single app log at a private temp file and force the
    /// runtime debug gate for the duration of `body`, then restore both
    /// unconditionally. Async-safe form of `AppLogStoreTests`' synchronous
    /// `withTempLog`/`withDebugLogging` pair (that helper's `body` is
    /// `() throws -> T`, not `async`, so it cannot wrap the `async throws`
    /// bodies below) — mirrors the setup/`defer` shape in
    /// `AccountManagerQueueDrainTests.drainLaneInstrumentationIsReadableFromTheExportedLog`.
    private func withTempLogAndDebugGate<T>(
        enabled: Bool, _ body: () async throws -> T
    ) async throws -> T {
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fullsync_upsert_log_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = enabled }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }
        return try await body()
    }

    /// Insert an account + one inbox folder named `folderName`, feed the mock
    /// `count` distinct brand-new remote messages (empty local DB — every one
    /// is an INSERT, so the diagnostic's `!newHeaders.isEmpty` gate always
    /// opens), and drive the REAL `SyncEngine.runSyncMessages`.
    private func runFullSyncUpsert(
        pool: DatabasePool, accountId: String, folderName: String, count: Int
    ) async throws -> (result: SyncEngine.SyncMessagesResult, expectedIds: [String]) {
        let folderPath = "INBOX"
        try await pool.write { db in
            var acc = Account(emailAddress: "\(accountId)@example.com", displayName: "T", provider: .imap)
            acc.id = accountId
            try acc.insert(db)
            try Folder(name: folderName, path: folderPath, role: .inbox, accountId: accountId).insert(db)
        }
        let folder = try await pool.read { try Folder.fetchOne($0, key: "\(accountId):\(folderPath)")! }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedIds = (0..<count).map { "\(accountId):\(folderPath):hdr-\($0)" }
        let remoteMessages = (0..<count).map { i in
            makeHeaderInfo(
                messageId: "hdr-\(i)", rfc822MessageId: "<hdr-\(i)@example.com>",
                date: date.addingTimeInterval(Double(i)))
        }
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult(remoteMessages)

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: PrioritizedDatabase(pool: pool))
        return (result, expectedIds)
    }

    /// Bound fetch epoch for the update-only fixture. `MockEmailProvider(staleWindowMode: .uid)`
    /// reports NO epoch unless told to, and `SyncEngine.providerAddressOwnershipProven`
    /// (`.uid` arm) refuses any existing-row merge without an epoch > 0 — the row would
    /// take the "merge REFUSED" no-op branch and its read flag would never change. With
    /// the epoch bound, the canonical PK carries the proof and the row is UPDATED,
    /// exactly as `MessageHeaderObservationEpochTests.canonicalUpdateReplacesEpoch`.
    private static let updateOnlyFetchEpoch: UInt32 = 101

    /// Update/no-op-only pass: account + one inbox folder + ONE pre-existing
    /// header (unread), then the mock serves the SAME message with `isRead: true`.
    /// `newHeaders` is therefore EMPTY while `upsUpdated > 0` — the branch of the
    /// diagnostic's condition that emits `inserted 0 header(s): `.
    private func runFullSyncUpdateOnly(
        pool: DatabasePool, accountId: String, folderName: String
    ) async throws -> (result: SyncEngine.SyncMessagesResult, existingId: String) {
        let folderPath = "INBOX"
        let existingId = "\(accountId):\(folderPath):hdr-0"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await pool.write { db in
            var acc = Account(emailAddress: "\(accountId)@example.com", displayName: "T", provider: .imap)
            acc.id = accountId
            try acc.insert(db)
            try Folder(name: folderName, path: folderPath, role: .inbox, accountId: accountId).insert(db)
            var existing = MessageHeader(
                messageId: "hdr-0", subject: "Test Subject", from: "Alice Smith",
                fromAddress: "alice@example.com", to: "bob@example.com", date: date,
                snippet: "Test snippet", folderId: "\(accountId):\(folderPath)",
                accountId: accountId, folderPath: folderPath, isInInbox: true)
            existing.rfc822MessageId = "<hdr-0@example.com>"
            existing.isRead = false
            try existing.insert(db)
        }
        let folder = try await pool.read { try Folder.fetchOne($0, key: "\(accountId):\(folderPath)")! }

        let remote = makeHeaderInfo(
            messageId: "hdr-0", rfc822MessageId: "<hdr-0@example.com>", date: date, isRead: true)
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setMockedBoundFetchEpoch(Self.updateOnlyFetchEpoch, folderPath: folderPath)
        await mock.setFetchMessagesResult([remote])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: PrioritizedDatabase(pool: pool))
        return (result, existingId)
    }

    /// Orphan-reclaim fixture — the `IOS-QUEUE-008` event itself. Seeds an
    /// account, the inbox folder `folderName` (path `INBOX`) plus an `Archive`
    /// folder, and ONE committed row whose PRIMARY KEY names the inbox
    /// (`<acc>:INBOX:m1`) while its membership columns say `Archive` — the
    /// durable shape an optimistic move leaves behind on a stable-id provider
    /// (the same fixture shape as `RFC822IdentityMergeGuardTests.insertHeader`).
    /// The mock then serves `m1` in the inbox again (plus a brand-new `m2` when
    /// `withGenuineInsert`) under a `.date` stale window — the Gmail/Exchange
    /// arm, where `SyncEngine.providerAddressOwnershipProven` holds on the
    /// account + messageId match alone — so the REAL `runSyncMessages` takes
    /// its orphan-reclaim arm: the existing row is UPDATED in place back into
    /// this folder (no insert), while `m2`, if served, is an ordinary insert.
    private func runFullSyncOrphanReclaim(
        pool: DatabasePool, accountId: String, folderName: String, withGenuineInsert: Bool
    ) async throws -> (result: SyncEngine.SyncMessagesResult, reclaimedId: String, insertedId: String?) {
        let folderPath = "INBOX"
        let reclaimedId = "\(accountId):\(folderPath):m1"
        let insertedId = withGenuineInsert ? "\(accountId):\(folderPath):m2" : nil
        let date = Date().addingTimeInterval(-60)
        try await pool.write { db in
            var acc = Account(emailAddress: "\(accountId)@example.com", displayName: "T", provider: .gmail)
            acc.id = accountId
            try acc.insert(db)
            try Folder(name: folderName, path: folderPath, role: .inbox, accountId: accountId).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId).insert(db)
            var orphan = MessageHeader(
                messageId: "m1", subject: "Test Subject", from: "Alice Smith",
                fromAddress: "alice@example.com", to: "bob@example.com", date: date,
                snippet: "Test snippet", folderId: "\(accountId):\(folderPath)",
                accountId: accountId, folderPath: folderPath, isInInbox: true)
            orphan.rfc822MessageId = "<m1@example.com>"
            try orphan.insert(db)
            // The optimistic move: the membership columns move, the PK does not.
            try MessageHeader.filter(Column("id") == orphan.id).updateAll(
                db,
                Column("folderId").set(to: "\(accountId):Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false))
        }
        let folder = try await pool.read { try Folder.fetchOne($0, key: "\(accountId):\(folderPath)")! }

        var remote = [makeHeaderInfo(messageId: "m1", rfc822MessageId: "<m1@example.com>", date: date)]
        if withGenuineInsert {
            remote.append(makeHeaderInfo(
                messageId: "m2", rfc822MessageId: "<m2@example.com>", date: date.addingTimeInterval(1)))
        }
        let mock = MockEmailProvider(staleWindowMode: .date)
        await mock.setFetchMessagesResult(remote)

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
            dbPool: PrioritizedDatabase(pool: pool))
        return (result, reclaimedId, insertedId)
    }

    /// A GRDB `TransactionObserver` that REFUSES the commit of any transaction
    /// which wrote `messageHeader` — the standard GRDB way to force a commit
    /// failure: `databaseWillCommit()` throws → SQLite's commit hook aborts the
    /// COMMIT → GRDB rolls the transaction back and rethrows this very error to
    /// `pool.write`'s caller. A real production possibility (an I/O error or a
    /// full disk at COMMIT), not a manufactured writer. Keyed on the header
    /// write and counting its refusals, so a test can prove the refusal landed
    /// on the sync's own upsert transaction (`MIS-027`: red for the right reason).
    private final class HeaderCommitRefuser: TransactionObserver, Sendable {
        struct CommitRefused: Error {}
        private let sawHeaderWrite = Mutex(false)
        let refusals = Mutex(0)

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            eventKind.tableName == MessageHeader.databaseTableName
        }
        func databaseDidChange(with event: DatabaseEvent) {
            sawHeaderWrite.withLock { $0 = true }
        }
        func databaseWillCommit() throws {
            guard sawHeaderWrite.withLock({ $0 }) else { return }
            refusals.withLock { $0 += 1 }
            throw CommitRefused()
        }
        func databaseDidCommit(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
        func databaseDidRollback(_ db: Database) {
            sawHeaderWrite.withLock { $0 = false }
        }
    }

    /// Every `[MoveTrace] fullSync upsert[<folderName>] — …` entry on the
    /// `.queue` channel, with `AppLogStore.append`'s `[<ts>] [QUEUE] ` prefix
    /// stripped so assertions compare against exactly what the call site
    /// built (the timestamp is non-deterministic and not part of the
    /// contract under test).
    private func moveTraceUpsertBodies(in queueLog: String, folderName: String) -> [String] {
        let marker = "[MoveTrace] fullSync upsert[\(folderName)] — "
        return queueLog
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let range = line.range(of: marker) else { return nil }
                return String(line[range.lowerBound...])
            }
    }

    /// One segment of a `[MoveTrace] fullSync upsert[...]` body —
    /// `<verb> N header(s): a,b (+K more)` — decomposed.
    private struct ParsedSegment {
        let total: Int
        let renderedIds: [String]
        /// nil when the segment carries no `(+N more)` suffix at all.
        let elided: Int?
    }

    /// One `[MoveTrace] fullSync upsert[...]` body, decomposed into its
    /// `inserted` segment and its `reclaimed` segment. Independent of
    /// `SyncEngine.upsertInsertedIdSummary`'s own implementation — it PARSES
    /// the rendered text rather than recomputing the formula, so a fix that
    /// changed the formula but kept the observable text would still be
    /// caught by these structural assertions.
    ///
    /// `reclaimed` is optional in the PARSER only, so that a line which omits
    /// the segment still parses and the assertion that needs it fails on the
    /// segment — not on a parse failure that a `guard … else { return }` would
    /// silently swallow (`MIS-027`: red for the right reason). The pinned
    /// shape itself always carries both segments.
    private struct ParsedUpsertLine {
        let inserted: ParsedSegment
        let reclaimed: ParsedSegment?
    }

    private func parseSegment(_ segment: String, verb: String) -> ParsedSegment? {
        let verbPrefix = "\(verb) "
        guard segment.hasPrefix(verbPrefix) else { return nil }
        let afterVerb = segment.dropFirst(verbPrefix.count)
        guard let headerRange = afterVerb.range(of: " header(s): ") else { return nil }
        guard let total = Int(afterVerb[afterVerb.startIndex..<headerRange.lowerBound]) else { return nil }
        var rest = afterVerb[headerRange.upperBound...]
        var elided: Int?
        if let overflowRange = rest.range(of: " (+") {
            let suffix = rest[overflowRange.lowerBound...]
            guard suffix.hasSuffix(" more)") else { return nil }
            let digits = suffix.dropFirst(" (+".count).dropLast(" more)".count)
            elided = Int(digits)
            rest = rest[rest.startIndex..<overflowRange.lowerBound]
        }
        let renderedIds = rest.isEmpty ? [] : rest.split(separator: ",").map(String.init)
        return ParsedSegment(total: total, renderedIds: renderedIds, elided: elided)
    }

    private func parseUpsertBody(_ body: String) -> ParsedUpsertLine? {
        guard let insertedRange = body.range(of: "inserted ") else { return nil }
        let segments = String(body[insertedRange.lowerBound...]).components(separatedBy: " | ")
        guard let first = segments.first, let inserted = parseSegment(first, verb: "inserted") else { return nil }
        guard segments.count <= 2 else { return nil }
        var reclaimed: ParsedSegment?
        if segments.count == 2 {
            guard let parsed = parseSegment(segments[1], verb: "reclaimed") else { return nil }
            reclaimed = parsed
        }
        return ParsedUpsertLine(inserted: inserted, reclaimed: reclaimed)
    }

    /// The shape every SUCCESSFUL pass renders: both segments present, and the
    /// reclaimed one empty unless the test says otherwise. Used by the
    /// insert-only and update-only cases so a dropped segment fails loudly.
    private func expectEmptyReclaimedSegment(_ parsed: ParsedUpsertLine, in body: String) {
        #expect(parsed.reclaimed?.total == 0, "every pass renders a reclaimed segment; expected `reclaimed 0`: \(body)")
        #expect(parsed.reclaimed?.renderedIds.isEmpty == true, "no id may be reported as reclaimed here: \(body)")
        #expect(parsed.reclaimed?.elided == nil, "an empty reclaimed segment must render no overflow suffix: \(body)")
    }

    // MARK: - Under / at the cap

    @Test("Single inserted header — exact total, id and DB row; no overflow suffix")
    func fullSyncUpsertLogsSingleInsertedHeader() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-one"
            let folderName = "OneHeaderFolder"
            let (result, expectedIds) = try await runFullSyncUpsert(
                pool: pool, accountId: accountId, folderName: folderName, count: 1)
            #expect(result.newHeaders.count == 1)
            guard result.newHeaders.count == 1 else { return }

            let queueLog = AppLogStore.read(channel: .queue)
            let bodies = moveTraceUpsertBodies(in: queueLog, folderName: folderName)
            #expect(bodies.count == 1, "expected exactly one matching entry, got: \(bodies)")
            guard bodies.count == 1 else { return }
            guard let parsed = parseUpsertBody(bodies[0]) else {
                Issue.record("upsert line did not parse: \(bodies[0])")
                return
            }

            #expect(parsed.inserted.total == 1)
            #expect(parsed.inserted.renderedIds == expectedIds)
            #expect(parsed.inserted.elided == nil, "a single inserted header must render no overflow suffix")
            expectEmptyReclaimedSegment(parsed, in: bodies[0])

            let dbIds = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0).map(\.id)
            }
            #expect(Set(dbIds) == Set(expectedIds))
        }
    }

    @Test("Exactly cap inserted headers — every id rendered, no overflow suffix (elided > 0, not >= 0)")
    func fullSyncUpsertLogsExactlyCapInsertedHeadersNoOverflow() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-atcap"
            let folderName = "AtCapFolder"
            let cap = SyncConfig.upsertInsertedIdLogCap
            let (result, expectedIds) = try await runFullSyncUpsert(
                pool: pool, accountId: accountId, folderName: folderName, count: cap)
            #expect(result.newHeaders.count == cap)
            guard result.newHeaders.count == cap else { return }

            let queueLog = AppLogStore.read(channel: .queue)
            let bodies = moveTraceUpsertBodies(in: queueLog, folderName: folderName)
            #expect(bodies.count == 1, "expected exactly one matching entry, got: \(bodies)")
            guard bodies.count == 1 else { return }
            guard let parsed = parseUpsertBody(bodies[0]) else {
                Issue.record("upsert line did not parse: \(bodies[0])")
                return
            }

            #expect(parsed.inserted.total == cap)
            #expect(parsed.inserted.renderedIds == expectedIds)
            #expect(parsed.inserted.elided == nil, "exactly-cap must not trigger the overflow suffix")
            expectEmptyReclaimedSegment(parsed, in: bodies[0])

            let dbIds = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0).map(\.id)
            }
            #expect(Set(dbIds) == Set(expectedIds))
        }
    }

    // MARK: - Over the cap — rule 11's DB half

    @Test("Cap+1 inserted headers — the log line elides the last id; the DB still holds all cap+1 rows")
    func fullSyncUpsertLogsCapPlusOneElidesLastIdButDBHoldsAll() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-overcap"
            let folderName = "OverCapFolder"
            let cap = SyncConfig.upsertInsertedIdLogCap
            let count = cap + 1
            let (result, expectedIds) = try await runFullSyncUpsert(
                pool: pool, accountId: accountId, folderName: folderName, count: count)
            #expect(result.newHeaders.count == count)
            guard result.newHeaders.count == count else { return }

            let queueLog = AppLogStore.read(channel: .queue)
            let bodies = moveTraceUpsertBodies(in: queueLog, folderName: folderName)
            #expect(bodies.count == 1, "expected exactly one matching entry, got: \(bodies)")
            guard bodies.count == 1 else { return }
            guard let parsed = parseUpsertBody(bodies[0]) else {
                Issue.record("upsert line did not parse: \(bodies[0])")
                return
            }

            #expect(parsed.inserted.total == count)
            #expect(parsed.inserted.renderedIds.count == cap)
            #expect(parsed.inserted.renderedIds == Array(expectedIds.prefix(cap)))
            expectEmptyReclaimedSegment(parsed, in: bodies[0])
            guard let elided = parsed.inserted.elided else {
                Issue.record("cap+1 inserted headers must render an overflow suffix — got: \(bodies[0])")
                return
            }
            // Arithmetic, not a hardcoded literal — whatever the line says was
            // elided must exactly account for what the cap left out.
            #expect(elided + cap == count)

            let elidedId = expectedIds[cap] // the one id past the cap, in insertion order
            #expect(!bodies[0].contains(elidedId),
                    "the DISPLAY cap must elide this id from the log line")

            // Rule 11's DB half: the display cap never truncates the STORED
            // copy — every one of the cap+1 rows, including the elided id, is
            // a durable, independently-fetched DB row.
            let dbIds = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0).map(\.id)
            }
            #expect(Set(dbIds) == Set(expectedIds))
            #expect(dbIds.contains(elidedId),
                    "the elided-from-the-log id must still be a durable DB row")
        }
    }

    // MARK: - Two-sided non-vacuity: the gate, not an absent sync

    @Test("Debug gate closed — no [MoveTrace] fullSync upsert line reaches the queue channel, though the sync itself still ran")
    func fullSyncUpsertDiagnosticAbsentWhenGateClosed() async throws {
        try await withTempLogAndDebugGate(enabled: false) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-gated"
            let folderName = "GatedUpsertFolder"
            let (result, expectedIds) = try await runFullSyncUpsert(
                pool: pool, accountId: accountId, folderName: folderName, count: 3)
            #expect(result.newHeaders.count == 3)

            let queueLog = AppLogStore.read(channel: .queue)
            #expect(moveTraceUpsertBodies(in: queueLog, folderName: folderName).isEmpty,
                    "a gate-closed sync must not write the diagnostic: \(queueLog)")
            #expect(!queueLog.contains(folderName),
                    "the folder's unique marker must not reach the queue channel while the gate is closed")

            // Non-vacuity: the sync really ran and really inserted rows — the
            // silence above is the closed gate, not an absent sync.
            let dbIds = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0).map(\.id)
            }
            #expect(Set(dbIds) == Set(expectedIds))
        }
    }

    // MARK: - Update/no-op-only pass — the zero-insert line is still emitted

    @Test("Update-only pass (no inserts) — exactly one line, total 0, no ids, no overflow suffix; the pre-existing row is updated in place")
    func fullSyncUpsertLogsZeroInsertedHeadersOnUpdateOnlyPass() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-updateonly"
            let folderName = "UpdateOnlyFolder"
            let (result, existingId) = try await runFullSyncUpdateOnly(
                pool: pool, accountId: accountId, folderName: folderName)
            #expect(result.newHeaders.isEmpty,
                    "an update-only pass must insert nothing, got \(result.newHeaders.map(\.id))")
            guard result.newHeaders.isEmpty else { return }

            let queueLog = AppLogStore.read(channel: .queue)
            let bodies = moveTraceUpsertBodies(in: queueLog, folderName: folderName)
            #expect(bodies.count == 1, "expected exactly one matching entry, got: \(bodies)")
            guard bodies.count == 1 else { return }
            let marker = "[MoveTrace] fullSync upsert[\(folderName)] — "
            // ONE fixed shape, both segments always rendered — the empty inserted
            // segment keeps its trailing space before the ` | ` separator, and the
            // empty reclaimed segment keeps its own trailing space.
            #expect(bodies[0] == marker + "inserted 0 header(s):  | reclaimed 0 header(s): ",
                    "the zero-insert line must be rendered verbatim (both segments, trailing spaces included), got: \(bodies[0])")
            guard let parsed = parseUpsertBody(bodies[0]) else {
                Issue.record("zero-insert line did not parse: \(bodies[0])")
                return
            }
            #expect(parsed.inserted.total == 0)
            #expect(parsed.inserted.renderedIds.isEmpty, "no id may be rendered for an update-only pass, got \(parsed.inserted.renderedIds)")
            #expect(parsed.inserted.elided == nil, "an update-only pass must render no overflow suffix")
            expectEmptyReclaimedSegment(parsed, in: bodies[0])

            // The pre-existing row is still the ONLY row, and it was UPDATED in
            // place (unread → read, epoch stamped) — the sync really merged.
            let rows = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0)
            }
            #expect(rows.count == 1, "the pre-existing row must be the only row, got \(rows.map(\.id))")
            guard rows.count == 1 else { return }
            #expect(rows[0].id == existingId)
            #expect(rows[0].isRead == true, "the remote read flag must have been merged into the pre-existing row")
            #expect(rows[0].observedUidValidity == Int(Self.updateOnlyFetchEpoch))
        }
    }

    @Test("Debug gate closed — an update-only pass writes no [MoveTrace] fullSync upsert line, though the row was still updated")
    func fullSyncUpsertZeroInsertDiagnosticAbsentWhenGateClosed() async throws {
        try await withTempLogAndDebugGate(enabled: false) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-updateonly-gated"
            let folderName = "GatedUpdateOnlyFolder"
            let (result, existingId) = try await runFullSyncUpdateOnly(
                pool: pool, accountId: accountId, folderName: folderName)
            #expect(result.newHeaders.isEmpty)

            let queueLog = AppLogStore.read(channel: .queue)
            #expect(moveTraceUpsertBodies(in: queueLog, folderName: folderName).isEmpty,
                    "a gate-closed sync must not write the diagnostic: \(queueLog)")
            #expect(!queueLog.contains(folderName),
                    "the folder's unique marker must not reach the queue channel while the gate is closed")

            // Non-vacuity: the sync really ran and really merged — the silence
            // above is the closed gate, not an absent sync.
            let rows = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0)
            }
            #expect(rows.count == 1)
            guard rows.count == 1 else { return }
            #expect(rows[0].id == existingId)
            #expect(rows[0].isRead == true)
        }
    }

    // MARK: - Orphan reclaim — the IOS-QUEUE-008 event is reported as what it is

    @Test("Orphan reclaim — the re-homed row is reported under `reclaimed`, never under `inserted`, and is back in the synced folder")
    func fullSyncUpsertReportsOrphanReclaimAsReclaimedNotInserted() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-reclaim"
            let folderName = "ReclaimFolder"
            let (result, reclaimedId, _) = try await runFullSyncOrphanReclaim(
                pool: pool, accountId: accountId, folderName: folderName, withGenuineInsert: false)
            // `newHeaders` is untouched in kind: the reclaimed row still rides it
            // for the FTS / body-queue consumers downstream.
            #expect(result.newHeaders.map(\.id) == [reclaimedId])

            // The row was RE-HOMED — same PK, membership rewritten back to this
            // folder — and it is the ONLY row for the message: nothing was inserted.
            let rows = try await pool.read {
                try MessageHeader
                    .filter(Column("accountId") == accountId && Column("messageId") == "m1")
                    .fetchAll($0)
            }
            #expect(rows.count == 1, "the orphan must be reclaimed in place, not duplicated: \(rows.map(\.id))")
            guard rows.count == 1 else { return }
            #expect(rows[0].id == reclaimedId)
            #expect(rows[0].folderId == "\(accountId):INBOX")
            #expect(rows[0].folderPath == "INBOX")
            #expect(rows[0].isInInbox == true)

            let queueLog = AppLogStore.read(channel: .queue)
            let bodies = moveTraceUpsertBodies(in: queueLog, folderName: folderName)
            #expect(bodies.count == 1, "expected exactly one matching entry, got: \(bodies)")
            guard bodies.count == 1 else { return }
            guard let parsed = parseUpsertBody(bodies[0]) else {
                Issue.record("upsert line did not parse: \(bodies[0])")
                return
            }
            #expect(parsed.reclaimed?.renderedIds == [reclaimedId],
                    "a row re-homed in place must be reported as reclaimed: \(bodies[0])")
            #expect(parsed.reclaimed?.total == 1, "exactly one row was reclaimed: \(bodies[0])")
            #expect(!parsed.inserted.renderedIds.contains(reclaimedId),
                    "an in-place update must NOT be reported as an insert: \(bodies[0])")
            #expect(parsed.inserted.total == 0, "nothing was inserted in this pass: \(bodies[0])")
            #expect(parsed.inserted.renderedIds.isEmpty, "no id may be reported as inserted: \(bodies[0])")
        }
    }

    @Test("Mixed pass — one genuine insert plus one orphan reclaim renders both segments, in exactly this shape")
    func fullSyncUpsertMixedPassRendersBothSegmentsVerbatim() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-mixed"
            let folderName = "MixedPassFolder"
            let (result, reclaimedId, insertedId) = try await runFullSyncOrphanReclaim(
                pool: pool, accountId: accountId, folderName: folderName, withGenuineInsert: true)
            guard let insertedId else {
                Issue.record("the mixed fixture must name the genuinely inserted id")
                return
            }
            #expect(Set(result.newHeaders.map(\.id)) == [reclaimedId, insertedId])

            let queueLog = AppLogStore.read(channel: .queue)
            let bodies = moveTraceUpsertBodies(in: queueLog, folderName: folderName)
            #expect(bodies.count == 1, "expected exactly one matching entry, got: \(bodies)")
            guard bodies.count == 1 else { return }
            let marker = "[MoveTrace] fullSync upsert[\(folderName)] — "
            #expect(bodies[0] == marker + "inserted 1 header(s): \(insertedId) | reclaimed 1 header(s): \(reclaimedId)",
                    "the mixed line must render both segments verbatim, got: \(bodies[0])")

            // Both rows are committed in the synced folder — the reclaimed PK
            // re-homed, the new PK inserted — and the Archive membership is gone.
            let dbIds = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll($0).map(\.id)
            }
            #expect(Set(dbIds) == [reclaimedId, insertedId])
            let archiveCount = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):Archive").fetchCount($0)
            }
            #expect(archiveCount == 0, "the reclaimed row must have left its Archive membership")
        }
    }

    // MARK: - Rolled-back pass — the line is emitted only after COMMIT

    @Test("Rolled-back pass — a commit refused after the header insert leaves NO [MoveTrace] fullSync upsert line and NO header row")
    func fullSyncUpsertEmitsNothingWhenTheWriteRollsBack() async throws {
        try await withTempLogAndDebugGate(enabled: true) {
            let (pool, dir) = try makePool()
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let accountId = "upsert-rollback"
            let folderName = "RollbackFolder"
            let folderPath = "INBOX"
            try await pool.write { db in
                var acc = Account(emailAddress: "\(accountId)@example.com", displayName: "T", provider: .imap)
                acc.id = accountId
                try acc.insert(db)
                try Folder(name: folderName, path: folderPath, role: .inbox, accountId: accountId).insert(db)
            }
            let folder = try await pool.read { try Folder.fetchOne($0, key: "\(accountId):\(folderPath)")! }
            let remote = makeHeaderInfo(
                messageId: "hdr-0", rfc822MessageId: "<hdr-0@example.com>",
                date: Date().addingTimeInterval(-60))
            let mock = MockEmailProvider(staleWindowMode: .uid)
            await mock.setFetchMessagesResult([remote])

            // Installed AFTER the fixture seeding, so the only header-writing
            // transaction it can refuse is the sync's own upsert.
            let refuser = HeaderCommitRefuser()
            pool.add(transactionObserver: refuser, extent: .databaseLifetime)

            await #expect(throws: HeaderCommitRefuser.CommitRefused.self) {
                _ = try await SyncEngine.runSyncMessages(
                    for: folder, provider: mock, limit: SyncConfig.syncMessageLimit,
                    dbPool: PrioritizedDatabase(pool: pool))
            }
            // Non-vacuity: the sync reached its header insert and the COMMIT of
            // that very transaction was refused, exactly once.
            #expect(refuser.refusals.withLock { $0 } == 1,
                    "the refusal must land on the sync's own upsert transaction, exactly once")

            // The property: a rolled-back pass reports nothing — no line for
            // rows that never became durable …
            let queueLog = AppLogStore.read(channel: .queue)
            #expect(moveTraceUpsertBodies(in: queueLog, folderName: folderName).isEmpty,
                    "a rolled-back pass must emit no upsert line: \(queueLog)")
            // … and no row.
            let rowCount = try await pool.read {
                try MessageHeader.filter(Column("folderId") == "\(accountId):\(folderPath)").fetchCount($0)
            }
            #expect(rowCount == 0, "a refused commit must leave no header row")
        }
    }
}
