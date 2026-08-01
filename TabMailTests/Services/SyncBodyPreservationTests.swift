/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Shared Helpers

/// Builds a MessageHeaderInfo for simulating server-side messages.
private func makeHeaderInfo(
    messageId: String = "100",
    rfc822MessageId: String? = nil,
    inReplyTo: String? = nil,
    references: [String] = [],
    threadId: String? = nil,
    subject: String = "Test Subject",
    from: String = "Test Sender",
    fromAddress: String = "sender@example.com",
    to: String = "to@test.com",
    cc: String = "",
    bcc: String = "",
    replyTo: String? = nil,
    date: Date = Date(),
    snippet: String = "Test snippet",
    isRead: Bool = true,
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
        references: references,
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

/// Simulate full sync with UID remap + rfc822 dedup + outbox protection (matches production).
private func simulateFullSync(
    db: DatabaseQueue,
    folder: Folder,
    messages: [MessageHeaderInfo],
    limit: Int = 500,
    undoProtectedIds: Set<String> = []
) throws -> (newHeaders: [MessageHeader], staleIds: [String], uidMigratedOldIds: [String]) {
    let folderPath = folder.path
    let folderId = folder.id
    let accountId = folder.accountId

    let remoteIds = Set(messages.map(\.messageId))

    return try db.write { dbConn in
        let pendingOps = try PendingOperation.fetchAll(dbConn)
        let opsTargetingThisFolder = pendingOps.filter {
            $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
        }
        let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))
        let pendingDestructiveIds = Set(
            opsTargetingThisFolder
                .filter { [.archive, .delete, .move].contains($0.type) }
                .flatMap(\.messageIds)
        )
        let isPendingDestructive: (MessageHeaderInfo) -> Bool = { info in
            pendingDestructiveIds.contains(info.messageId) ||
            (info.rfc822MessageId.map { pendingDestructiveIds.contains($0) } ?? false)
        }

        var newHeaders: [MessageHeader] = []
        var staleIds: [String] = []

        // Stale detection
        let stale: [MessageHeader]
        if messages.count < limit {
            let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn)
            stale = allLocal.filter { !remoteIds.contains($0.messageId) }
        } else {
            stale = []
        }

        // Outbox protection
        var outboxProtectedRfc822s = Set<String>()
        if folder.role == .sent {
            let outboxRfc822s = try String.fetchAll(dbConn, sql: """
                SELECT sentMessageId FROM outboxMessage
                WHERE accountId = ? AND sentMessageId IS NOT NULL
            """, arguments: [accountId])
            for raw in outboxRfc822s {
                outboxProtectedRfc822s.insert(EmailFilter.normalizeMessageId(raw))
            }
        }

        // UID remap detection (fetch body BEFORE delete)
        var uidMigratedRemoteIds = Set<String>()
        var uidMigratedOldMsgIds: [String] = []
        let localMsgIds = Set(try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn).map(\.messageId))
        let newRemoteIds = remoteIds.subtracting(localMsgIds)
        var newMessagesByRfc822: [String: [MessageHeaderInfo]] = [:]
        for msg in messages where newRemoteIds.contains(msg.messageId) {
            if let rfc822 = msg.rfc822MessageId, !rfc822.isEmpty {
                newMessagesByRfc822[rfc822, default: []].append(msg)
            }
        }
        for staleMsg in stale {
            guard let rfc822 = staleMsg.rfc822MessageId, !rfc822.isEmpty else { continue }
            guard let match = newMessagesByRfc822[rfc822]?.first(where: {
                !uidMigratedRemoteIds.contains($0.messageId)
            }) else { continue }
            let oldId = staleMsg.id
            let newMsgId = match.messageId
            let newId = "\(accountId):\(folderPath):\(newMsgId)"
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
            pendingAllIds.contains(msg.messageId) ||
            (msg.rfc822MessageId.map { pendingAllIds.contains($0) } ?? false) ||
            (msg.rfc822MessageId.map { outboxProtectedRfc822s.contains($0) } ?? false)
        }
        let staleFiltered = stale.filter { !isProtected($0) && !uidMigratedSet.contains($0.messageId) }
        staleIds = staleFiltered.map(\.id)
        for msg in staleFiltered {
            try msg.delete(dbConn)
        }

        // Upsert with rfc822 dedup
        for info in messages where !isPendingDestructive(info) && !uidMigratedRemoteIds.contains(info.messageId) {
            if try MessageHeader
                .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                .fetchOne(dbConn) != nil {
                continue
            }

            var header = MessageHeader(
                messageId: info.messageId,
                subject: info.subject,
                from: info.from,
                fromAddress: info.fromAddress,
                to: info.to,
                date: info.date,
                snippet: EmailFilter.cleanSnippet(info.snippet),
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: folder.role == .inbox
            )
            header.rfc822MessageId = info.rfc822MessageId
            header.inReplyTo = info.inReplyTo
            header.referencesJSON = MessageHeader.encodeReferences(info.references)
            header.isRead = info.isRead
            header.isFlagged = info.isFlagged
            header.hasAttachments = info.hasAttachments
            header.isReplied = info.isReplied
            header.isForwarded = info.isForwarded
            try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: info.threadId, db: dbConn)

            // rfc822 dedup for Drafts/Sent (deferred body insert for FK safety)
            var deferredBody: MessageBody?
            if (folder.role == .drafts || folder.role == .sent),
               let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
               let optimistic = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                .fetchOne(dbConn) {
                let oldId = optimistic.id
                if let body = try MessageBody.fetchOne(dbConn, key: ContentKey(rawValue: oldId)) {
                    var newBody = body
                    newBody.id = ContentKey(rawValue: header.id)
                    try MessageBody.deleteOne(dbConn, key: ContentKey(rawValue: oldId))
                    deferredBody = newBody
                }
                try optimistic.delete(dbConn)
            }

            try header.insert(dbConn)
            if let body = deferredBody { try body.insert(dbConn) }
            try ThreadUtils.insertMessageReferences(for: header, db: dbConn)
            newHeaders.append(header)
        }

        return (newHeaders, staleIds, uidMigratedOldMsgIds)
    }
}

/// Insert an optimistic draft header + body (simulates queueDraftSave).
@discardableResult
private func insertOptimisticDraftHeader(
    _ db: DatabaseQueue,
    draftId: String,
    rfc822MessageId: String,
    accountId: String = "acc1",
    draftsFolderPath: String = "Drafts",
    subject: String = "Draft Subject",
    body: String = "Draft body"
) throws -> MessageHeader {
    try db.write { dbConn in
        let folderId = "\(accountId):\(draftsFolderPath)"
        let placeholderMsgId = "draft-\(draftId)"
        let headerId = "\(accountId):\(draftsFolderPath):\(placeholderMsgId)"
        let senderEmail = try Account.fetchOne(dbConn, key: accountId)?.emailAddress ?? accountId

        var header = MessageHeader(
            messageId: placeholderMsgId,
            subject: subject,
            from: senderEmail,
            fromAddress: senderEmail,
            to: "to@test.com",
            date: Date(),
            snippet: EmailFilter.snippetFromPlainText(body),
            folderId: folderId,
            accountId: accountId,
            folderPath: draftsFolderPath,
            isInInbox: false
        )
        header.rfc822MessageId = rfc822MessageId
        header.isRead = true
        try header.insert(dbConn)

        let htmlBody = MessageBody.plainTextToHTML(body)
        let messageBody = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: htmlBody)
        try messageBody.save(dbConn)

        return header
    }
}

// MARK: - Suite 1: Draft Body Preservation Through rfc822 Dedup

@Suite("Draft Body Preservation — rfc822 Dedup")
struct DraftBodyDedupTests {

    @Test("sync replaces optimistic draft with real server draft, body preserved")
    func draftDedupPreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        let rfc822 = "draft-abc@example.com"

        // Insert optimistic draft header + body
        let optimistic = try insertOptimisticDraftHeader(
            db, draftId: "abc", rfc822MessageId: rfc822,
            subject: "My Draft", body: "Draft content here"
        )

        // Verify body exists
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBody != nil)

        // Server sync returns real draft with same rfc822MessageId but real IMAP UID
        let serverMsg = makeHeaderInfo(
            messageId: "imap-uid-42",
            rfc822MessageId: rfc822,
            subject: "My Draft"
        )

        _ = try simulateFullSync(db: db, folder: draftsFolder, messages: [serverMsg])

        // Only one header should remain
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Drafts").fetchAll(dbConn)
        }
        #expect(headers.count == 1)
        #expect(headers[0].messageId == "imap-uid-42")

        // Body should be migrated to new header ID
        let realHeaderId = "acc1:Drafts:imap-uid-42"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: realHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent?.contains("Draft content here") == true)

        // Old body gone
        let oldBodyAfter = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBodyAfter == nil)
    }

    @Test("draft dedup works when optimistic draft has been updated multiple times")
    func draftDedupAfterMultipleUpdates() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        let rfc822 = "multi-update@example.com"

        // Insert initial optimistic draft
        let optimistic = try insertOptimisticDraftHeader(
            db, draftId: "multi", rfc822MessageId: rfc822,
            body: "First draft"
        )

        // Simulate updating the draft body (as queueDraftSave does on re-save)
        try db.write { dbConn in
            let htmlBody = MessageBody.plainTextToHTML("Updated draft content v3")
            let body = MessageBody( contentKey: ContentKey(rawValue: optimistic.id), htmlContent: htmlBody)
            try body.save(dbConn) // upsert
        }

        // Verify updated body
        let updatedBody = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(updatedBody?.htmlContent?.contains("Updated draft content v3") == true)

        // Server returns real draft
        let serverMsg = makeHeaderInfo(
            messageId: "uid-888",
            rfc822MessageId: rfc822,
            subject: "Draft Subject"
        )

        _ = try simulateFullSync(db: db, folder: draftsFolder, messages: [serverMsg])

        // Body should be the latest version, migrated to new ID
        let realHeaderId = "acc1:Drafts:uid-888"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: realHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent?.contains("Updated draft content v3") == true)
    }

    @Test("draft UID remap preserves body (UIDVALIDITY change)")
    func draftUIDRemapPreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        let rfc822 = "draft-remap@example.com"

        // Insert a draft header with a real UID (already synced once)
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "old-uid-10", subject: "Synced Draft",
                from: "test@example.com", fromAddress: "test@example.com",
                to: "to@test.com", date: Date(), snippet: "Draft text",
                folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts", isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.isRead = true
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:Drafts:old-uid-10"), htmlContent: "<p>Preserved draft body</p>")
            try body.insert(dbConn)
        }

        // Server returns same draft with new UID (UIDVALIDITY changed)
        let serverMsg = makeHeaderInfo(
            messageId: "new-uid-99",
            rfc822MessageId: rfc822,
            subject: "Synced Draft"
        )

        let result = try simulateFullSync(db: db, folder: draftsFolder, messages: [serverMsg])

        // Should be handled by UID remap
        #expect(result.uidMigratedOldIds.contains("old-uid-10"))

        // Body preserved under new ID
        let newBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:Drafts:new-uid-99") }
        #expect(newBody != nil)
        #expect(newBody?.htmlContent == "<p>Preserved draft body</p>")
    }
}

// MARK: - Suite 2: Draft Stale Protection via PendingOperation

@Suite("Draft Stale Protection — PendingOperation")
struct DraftStaleProtectionTests {

    @Test("optimistic draft protected by PendingOperation placeholder messageId")
    func placeholderProtected() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        let draftId = "protected-draft"
        let rfc822 = "protected@example.com"

        // Insert optimistic draft
        try insertOptimisticDraftHeader(db, draftId: draftId, rfc822MessageId: rfc822)

        // Insert PendingOperation with placeholder messageId (as queueDraftSave does)
        let opPlaceholder = "draft-\(draftId)"
        try db.write { dbConn in
            try PendingOperation(
                type: .saveDraft,
                messageIds: [draftId, opPlaceholder, rfc822],
                accountId: "acc1",
                folderPath: "Drafts"
            ).insert(dbConn)
        }

        // Sync with empty server — placeholder should NOT be deleted
        let result = try simulateFullSync(db: db, folder: draftsFolder, messages: [])

        #expect(result.staleIds.isEmpty)

        let count = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Drafts").fetchCount($0) }
        #expect(count == 1)
    }

    @Test("optimistic draft protected by rfc822MessageId in PendingOperation")
    func rfc822Protected() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        let rfc822 = "rfc822-protected@example.com"

        // Insert optimistic draft
        try insertOptimisticDraftHeader(db, draftId: "rfc-test", rfc822MessageId: rfc822)

        // PendingOperation includes rfc822MessageId (third element, as queueDraftSave does)
        try db.write { dbConn in
            try PendingOperation(
                type: .saveDraft,
                messageIds: ["rfc-test", "draft-rfc-test", rfc822],
                accountId: "acc1",
                folderPath: "Drafts"
            ).insert(dbConn)
        }

        // Sync with empty server — protected by rfc822
        let result = try simulateFullSync(db: db, folder: draftsFolder, messages: [])
        #expect(result.staleIds.isEmpty)
    }

    @Test("optimistic draft IS deleted when PendingOperation is drained (no protection)")
    func noProtectionAfterDrain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        // Insert optimistic draft with NO PendingOperation
        try insertOptimisticDraftHeader(db, draftId: "orphan", rfc822MessageId: "orphan@example.com")

        // Sync with empty server — no protection → stale deleted
        let result = try simulateFullSync(db: db, folder: draftsFolder, messages: [])
        #expect(result.staleIds.count == 1)

        let count = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Drafts").fetchCount($0) }
        #expect(count == 0)
    }

    @Test("PendingOperation with destinationPath also protects draft placeholder")
    func destinationPathProtection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let draftsFolder = try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert a placeholder header in Drafts
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "dest-protected", subject: "Test",
                from: "test@example.com", fromAddress: "test@example.com",
                to: "to@test.com", date: Date(), snippet: "test",
                folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts", isInInbox: false
            )
            header.rfc822MessageId = "dest@example.com"
            try header.insert(dbConn)
        }

        // PendingOperation targets Drafts via destinationPath
        try db.write { dbConn in
            try PendingOperation(
                type: .move,
                messageIds: ["dest-protected"],
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Drafts"
            ).insert(dbConn)
        }

        let result = try simulateFullSync(db: db, folder: draftsFolder, messages: [])
        #expect(result.staleIds.isEmpty)
    }
}

// MARK: - Suite 3: Move + UID Remap Body Preservation

@Suite("Move + UID Remap — Body Preservation")
struct MoveUIDRemapBodyTests {

    @Test("message moved to Archive, UID remapped, body preserved")
    func moveAndRemapPreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archiveFolder = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let rfc822 = "moved-msg@example.com"

        // Message in Archive (after optimistic move) with old UID
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "old-uid-50", subject: "Archived Message",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "Important",
                folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false
            )
            header.rfc822MessageId = rfc822
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:Archive:old-uid-50"), htmlContent: "<p>Must survive move+remap</p>")
            try body.insert(dbConn)
        }

        // Server returns same message with new UID (IMAP MOVE changed UID)
        let serverMsg = makeHeaderInfo(
            messageId: "new-uid-75",
            rfc822MessageId: rfc822,
            subject: "Archived Message"
        )

        let result = try simulateFullSync(db: db, folder: archiveFolder, messages: [serverMsg])
        #expect(result.uidMigratedOldIds.contains("old-uid-50"))

        // Body preserved under new ID
        let newBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:Archive:new-uid-75") }
        #expect(newBody != nil)
        #expect(newBody?.htmlContent == "<p>Must survive move+remap</p>")

        // Only one header
        let count = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Archive").fetchCount($0) }
        #expect(count == 1)
    }

    @Test("message with PendingOperation.move is not stale-deleted during sync")
    func pendingMoveProtectsFromStaleDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archiveFolder = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let rfc822 = "pending-move@example.com"

        // Message optimistically moved to Archive (PendingOp not yet drained)
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "move-uid-10", subject: "Moving",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "test",
                folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false
            )
            header.rfc822MessageId = rfc822
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:Archive:move-uid-10"), htmlContent: "<p>Protected body</p>")
            try body.insert(dbConn)

            // PendingOperation from INBOX → Archive, messageIds contain stableId
            try PendingOperation(
                type: .archive,
                messageIds: [rfc822], // stableId = rfc822MessageId for IMAP
                accountId: "acc1",
                folderPath: "INBOX",
                destinationPath: "Archive"
            ).insert(dbConn)
        }

        // Sync Archive with empty server (server hasn't processed the MOVE yet)
        let result = try simulateFullSync(db: db, folder: archiveFolder, messages: [])

        // Should be protected by PendingOperation's destinationPath
        #expect(result.staleIds.isEmpty)

        // Body still exists
        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:Archive:move-uid-10") }
        #expect(body != nil)
    }

    @Test("multiple UID remaps in same sync batch preserve all bodies")
    func multipleRemapsPreserveBodies() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert 3 messages with bodies, all will get UID-remapped
        for i in 1...3 {
            try db.write { dbConn in
                var header = MessageHeader(
                    messageId: "old-\(i)", subject: "Msg \(i)",
                    from: "sender@example.com", fromAddress: "sender@example.com",
                    to: "me@example.com", date: Date(), snippet: "snippet \(i)",
                    folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
                )
                header.rfc822MessageId = "msg\(i)@example.com"
                try header.insert(dbConn)
                let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:INBOX:old-\(i)"), htmlContent: "<p>Body \(i)</p>")
                try body.insert(dbConn)
            }
        }

        // Server returns all 3 with new UIDs
        let serverMsgs = (1...3).map { i in
            makeHeaderInfo(
                messageId: "new-\(i)",
                rfc822MessageId: "msg\(i)@example.com",
                subject: "Msg \(i)"
            )
        }

        let result = try simulateFullSync(db: db, folder: inboxFolder, messages: serverMsgs)
        #expect(result.uidMigratedOldIds.count == 3)

        // All bodies preserved
        for i in 1...3 {
            let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:new-\(i)") }
            #expect(body != nil, "Body \(i) should be preserved")
            #expect(body?.htmlContent == "<p>Body \(i)</p>")
        }
    }
}

// MARK: - Suite 4: ActiveBodyQueue Race with UID Remap

@Suite("ActiveBodyQueue — UID Remap Race Condition")
struct ActiveBodyQueueRaceTests {

    @Test("body write to stale headerId fails gracefully (FK constraint)")
    func bodyWriteToStaleHeaderIdFails() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert a message, then UID-remap it (deleting the old header)
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "uid-100", subject: "Test",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "test",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = "race@example.com"
            try header.insert(dbConn)
        }

        let oldHeaderId = "acc1:INBOX:uid-100"

        // Simulate UID remap: old header deleted, new one inserted
        try db.write { dbConn in
            try MessageHeader.deleteOne(dbConn, key: oldHeaderId)
            var newHeader = MessageHeader(
                messageId: "uid-200", subject: "Test",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "test",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            newHeader.rfc822MessageId = "race@example.com"
            try newHeader.insert(dbConn)
        }

        // ActiveBodyQueue completion: tries to insert body for the OLD headerId
        // This should fail with FK constraint (header no longer exists)
        let bodyInsertResult = try db.write { dbConn -> Bool in
            let body = MessageBody( contentKey: ContentKey(rawValue: oldHeaderId), htmlContent: "<p>Fetched body</p>")
            do {
                try body.insert(dbConn)
                return true // inserted
            } catch {
                // FK constraint violation expected
                return false
            }
        }
        #expect(bodyInsertResult == false, "Body insert should fail — header no longer exists")

        // Body should NOT exist under old ID
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: oldHeaderId) }
        #expect(oldBody == nil)
    }

    @Test("body .save() to stale headerId also fails (upsert still checks FK)")
    func bodySaveToStaleHeaderIdFails() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let oldHeaderId = "acc1:INBOX:gone-uid"
        // No header exists for this ID

        let saveResult = try db.write { dbConn -> Bool in
            let body = MessageBody( contentKey: ContentKey(rawValue: oldHeaderId), htmlContent: "<p>Orphan body</p>")
            do {
                try body.save(dbConn)
                return true
            } catch {
                return false
            }
        }
        #expect(saveResult == false, "save() should also fail — FK prevents orphan body")
    }

    @Test("snippet update to stale headerId is no-op (UPDATE WHERE id = ?)")
    func snippetUpdateToStaleHeaderIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        let staleHeaderId = "acc1:INBOX:deleted-uid"

        // This simulates ActiveBodyQueue's snippet update after body fetch
        // UPDATE messageHeader SET snippet = ? WHERE id = ? — should be a silent no-op
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE messageHeader SET snippet = ? WHERE id = ?",
                arguments: ["New snippet", staleHeaderId]
            )
        }

        // No crash, no error — UPDATE simply affects 0 rows
        let count = try db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 0) // No headers exist
    }

    @Test("body fetch queue item becomes stale mid-flight — header re-verified before write")
    func headerGoneBeforeBodyWrite() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert header
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "uid-300", subject: "Stale Check",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "test",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = "stale-check@example.com"
            try header.insert(dbConn)
        }

        let headerId = "acc1:INBOX:uid-300"

        // Simulate: header exists when enqueued, but deleted before body write
        // (UID remap or stale detection happened)
        try db.write { dbConn in
            try MessageHeader.deleteOne(dbConn, key: headerId)
        }

        // Re-verify header exists before writing body (production pattern)
        let headerStillExists = try db.read { dbConn in
            try MessageHeader.fetchOne(dbConn, key: headerId) != nil
        }
        #expect(headerStillExists == false)

        // Body write would fail with FK — correct behavior
    }
}

// MARK: - Suite 5: Optimistic Move Body Preservation

@Suite("Optimistic Move — Body Preservation")
struct OptimisticMoveBodyTests {

    @Test("optimisticMoveToFolder preserves body (UPDATE not DELETE+INSERT)")
    func movePreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let headerId = "acc1:INBOX:uid-500"

        // Insert message with body in INBOX
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "uid-500", subject: "To Archive",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "test",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = "archive-me@example.com"
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>Body to preserve</p>")
            try body.insert(dbConn)
        }

        // Simulate optimistic move (UPDATE folderId, folderPath, isInInbox)
        // This is how optimisticMoveToFolder works — it does NOT delete+re-insert
        try db.write { dbConn in
            try MessageHeader.filter(Column("id") == headerId).updateAll(dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
        }

        // Header moved but body FK uses the same PK (unchanged) — body preserved
        let body = try db.read { try MessageBody.fetchOne($0, key: headerId) }
        #expect(body != nil)
        #expect(body?.htmlContent == "<p>Body to preserve</p>")

        // Header is now in Archive
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.folderId == "acc1:Archive")
        #expect(header?.folderPath == "Archive")
        #expect(header?.isInInbox == false)
    }

    @Test("body survives optimistic move → sync → UID remap chain")
    func bodyEndToEndMoveThenRemap() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let archiveFolder = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let rfc822 = "e2e-move@example.com"

        // 1. Message in INBOX with body
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "inbox-uid-10", subject: "E2E Move",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "test",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = rfc822
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: "acc1:INBOX:inbox-uid-10"), htmlContent: "<p>E2E body</p>")
            try body.insert(dbConn)
        }

        // 2. Optimistic move to Archive (UPDATE, same PK)
        try db.write { dbConn in
            try MessageHeader.filter(Column("id") == "acc1:INBOX:inbox-uid-10").updateAll(dbConn,
                Column("folderId").set(to: "acc1:Archive"),
                Column("folderPath").set(to: "Archive"),
                Column("isInInbox").set(to: false)
            )
        }

        // Verify body still exists after move
        let bodyAfterMove = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:inbox-uid-10") }
        #expect(bodyAfterMove != nil)

        // 3. Sync Archive — server has the message with a NEW UID (IMAP MOVE changed it)
        // But our local message has messageId="inbox-uid-10" and is now in acc1:Archive
        // The PK is still "acc1:INBOX:inbox-uid-10" (UPDATE didn't change id)
        // Stale detection: our local msg has messageId="inbox-uid-10" not in remoteIds → stale
        // UID remap: rfc822 matches → migrate
        let serverMsg = makeHeaderInfo(
            messageId: "archive-uid-77",
            rfc822MessageId: rfc822,
            subject: "E2E Move"
        )

        let result = try simulateFullSync(db: db, folder: archiveFolder, messages: [serverMsg])

        // UID remap should have occurred
        #expect(result.uidMigratedOldIds.contains("inbox-uid-10"))

        // Body should be under new ID
        let finalBody = try db.read { try MessageBody.fetchOne($0, key: "acc1:Archive:archive-uid-77") }
        #expect(finalBody != nil)
        #expect(finalBody?.htmlContent == "<p>E2E body</p>")

        // Only one header in Archive
        let count = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Archive").fetchCount($0) }
        #expect(count == 1)
    }
}
