/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - 1. FolderInfo → Folder GRDB Insert

@Suite("Sync Patterns - FolderInfo to Folder Insert")
struct FolderInfoToFolderInsertTests {

    @Test("FolderInfo converts to Folder and inserts into DB")
    func folderInfoConvertsAndInserts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let infos = [
            FolderInfo(name: "Inbox", path: "INBOX", role: .inbox, unreadCount: 5, totalCount: 100, uidNext: 501),
            FolderInfo(name: "Sent", path: "Sent", role: .sent, unreadCount: 0, totalCount: 50),
            FolderInfo(name: "Trash", path: "Trash", role: .trash, unreadCount: 0, totalCount: 10),
        ]

        try db.write { dbConn in
            for info in infos {
                var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: "acc1")
                folder.totalCount = info.totalCount
                folder.lastKnownUidNext = info.uidNext
                try folder.insert(dbConn)
            }
        }

        let folders = try db.read { dbConn in
            try Folder.filter(Column("accountId") == "acc1").fetchAll(dbConn)
        }

        #expect(folders.count == 3)

        let inbox = folders.first(where: { $0.path == "INBOX" })
        #expect(inbox != nil)
        #expect(inbox?.name == "Inbox")
        #expect(inbox?.role == .inbox)
        #expect(inbox?.totalCount == 100)
        #expect(inbox?.lastKnownUidNext == 501)
        #expect(inbox?.id == "acc1:INBOX")

        let sent = folders.first(where: { $0.path == "Sent" })
        #expect(sent != nil)
        #expect(sent?.lastKnownUidNext == nil)
    }

    @Test("Folder id is accountId:path")
    func folderIdFormat() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        #expect(folder.id == "acc1:Archive")
    }
}

// MARK: - 2. MessageHeaderInfo → MessageHeader Conversion + Insert

@Suite("Sync Patterns - MessageHeaderInfo to MessageHeader Insert")
struct MessageHeaderInfoToMessageHeaderInsertTests {

    @Test("MessageHeaderInfo converts to MessageHeader with correct field mapping")
    func headerInfoConvertsToHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let date = Date(timeIntervalSince1970: 1700000000)
        let info = MessageHeaderInfo(
            messageId: "42",
            rfc822MessageId: "<msg42@example.com>",
            inReplyTo: "<msg41@example.com>",
            references: [],
            threadId: nil,
            subject: "Re: Meeting Notes",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            cc: "carol@example.com",
            bcc: "dave@example.com",
            replyTo: "alice-reply@example.com",
            date: date,
            snippet: "Please review the notes",
            isRead: true,
            isFlagged: false,
            hasAttachments: true,
            isReplied: false,
            isForwarded: false,
            actionTag: .reply
        )

        let folderId = "acc1:INBOX"
        let accountId = "acc1"
        let folderPath = "INBOX"
        let isInInbox = true

        try db.write { dbConn in
            var header = MessageHeader(
                messageId: info.messageId,
                subject: info.subject,
                from: info.from,
                fromAddress: info.fromAddress,
                to: info.to,
                date: info.date,
                snippet: info.snippet,
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
            try header.insert(dbConn)
        }

        let fetched = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn)
        }

        #expect(fetched.count == 1)
        let h = fetched[0]
        #expect(h.id == "acc1:INBOX:42")
        #expect(h.messageId == "42")
        #expect(h.rfc822MessageId == "<msg42@example.com>")
        #expect(h.inReplyTo == "<msg41@example.com>")
        #expect(h.subject == "Re: Meeting Notes")
        #expect(h.from == "Alice")
        #expect(h.fromAddress == "alice@example.com")
        #expect(h.to == "bob@example.com")
        #expect(h.cc == "carol@example.com")
        #expect(h.bcc == "dave@example.com")
        #expect(h.replyTo == "alice-reply@example.com")
        #expect(h.date == date)
        #expect(h.snippet == "Please review the notes")
        #expect(h.isRead == true)
        #expect(h.isFlagged == false)
        #expect(h.hasAttachments == true)
        #expect(h.actionTag == .reply)
        #expect(h.tagSortOrder == ActionTag.reply.sortOrder)
        #expect(h.isInInbox == true)
    }

    /// ⚠️ RE-SCOPED (`IOS-TEST-004`). **Previous display name: *"Action tags are only
    /// applied for inbox messages"*** — kept, because it is the right claim; the body
    /// was what did not meet it. It bound `let isInInbox = false` and then branched on
    /// `if isInInbox`, so the tag-applying arm was unreachable **by construction**
    /// (that is the source of its `will never be executed` diagnostic) and the whole
    /// test degenerated to "a header inserted with no tag has no tag". A constant is
    /// not the rule; it is a restatement of the answer.
    ///
    /// It is now TWO-SIDED and derives the gate the way production derives it —
    /// `SyncEngine`'s `let isInInbox = folder.role == .inbox`, read off the
    /// real `Folder` row this test inserted, feeding the same `if isInInbox` guard
    /// that wraps `header.actionTag = info.actionTag`. The inbox cell makes that arm
    /// execute (so the archive cell's `nil` is a refusal, not an absence), and the
    /// archive cell pins the sentinel `tagSortOrder` 99 that `sweepStaleActionTags`
    /// also restores.
    @Test("Action tags are only applied for inbox messages")
    func actionTagsOnlyForInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let archive = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let inbox = try TestDatabase.insertFolder(db, name: "Inbox", path: "INBOX", role: .inbox)

        func insertTagged(into folder: Folder, messageId: String) throws -> MessageHeader {
            // The production derivation, not a literal: inbox membership is a
            // property of the FOLDER's role (`SyncEngineFullSync`).
            let isInInbox = folder.role == .inbox
            var header = MessageHeader(
                messageId: messageId,
                subject: "Test",
                from: "Alice",
                fromAddress: "alice@example.com",
                to: "bob@example.com",
                date: Date(),
                snippet: "test",
                folderId: folder.id,
                accountId: "acc1",
                folderPath: folder.path,
                isInInbox: isInInbox
            )
            // The sync pattern under test: only apply actionTag if isInInbox.
            if isInInbox {
                header.actionTag = .archive
                header.tagSortOrder = ActionTag.archive.sortOrder
            }
            try db.write { try header.insert($0) }
            return header
        }

        let archived = try insertTagged(into: archive, messageId: "100")
        let inboxed = try insertTagged(into: inbox, messageId: "101")

        // NON-VACUITY — the tag-applying arm is reachable and does run, so the
        // archive row's `nil` below is the gate refusing rather than the branch
        // being dead code.
        let inboxFetched = try db.read { try MessageHeader.fetchOne($0, key: inboxed.id) }
        #expect(inboxFetched?.isInInbox == true)
        #expect(inboxFetched?.actionTag == .archive)
        #expect(inboxFetched?.tagSortOrder == ActionTag.archive.sortOrder)

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: archived.id) }
        #expect(fetched?.isInInbox == false)
        #expect(fetched?.actionTag == nil)
        #expect(fetched?.tagSortOrder == 99)
    }

    @Test("ThreadId computed from subject when provider returns nil")
    func threadIdFromSubject() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var header = MessageHeader(
            messageId: "200",
            subject: "Re: Project Update",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            date: Date(),
            snippet: "test",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true
        )
        // Simulate sync pattern: provider threadId is nil, compute from subject
        let providerThreadId: String? = nil
        header.threadId = providerThreadId ?? ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: header.subject)

        try db.write { try header.insert($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.threadId == "subj:acc1:project update")
    }
}

// MARK: - 3. Folder Sync: Unread/Total Count Updates

@Suite("Sync Patterns - Folder Sync Updates")
struct FolderSyncUpdateTests {

    @Test("Existing folder updated with new totalCount and uidNext")
    func existingFolderUpdated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        // Simulate fullSync update pattern
        let remoteFolders = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 3, totalCount: 150, uidNext: 600)
        ]

        try db.write { dbConn in
            let localFolders = try Folder.filter(Column("accountId") == "acc1").fetchAll(dbConn)
            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
                    existing.name = info.name
                    existing.totalCount = info.totalCount
                    if let uidNext = info.uidNext { existing.lastKnownUidNext = uidNext }
                    try existing.update(dbConn)
                }
            }
        }

        let folder = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(folder?.totalCount == 150)
        #expect(folder?.lastKnownUidNext == 600)
    }

    @Test("New folder added during folder sync")
    func newFolderAdded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remoteFolders = [
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 100),
            FolderInfo(name: "Projects", path: "Projects", role: .custom, unreadCount: 0, totalCount: 25),
        ]

        try db.write { dbConn in
            let localFolders = try Folder.filter(Column("accountId") == "acc1").fetchAll(dbConn)
            for info in remoteFolders {
                if var existing = localFolders.first(where: { $0.path == info.path }) {
                    existing.totalCount = info.totalCount
                    try existing.update(dbConn)
                } else {
                    var folder = Folder(name: info.name, path: info.path, role: info.role, accountId: "acc1")
                    folder.totalCount = info.totalCount
                    try folder.insert(dbConn)
                }
            }
        }

        let folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 2)
        let projects = folders.first(where: { $0.path == "Projects" })
        #expect(projects != nil)
        #expect(projects?.role == .custom)
        #expect(projects?.totalCount == 25)
    }

    @Test("Deleted remote folder is removed locally, messages cleaned up manually")
    func deletedFolderCleanup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "OldFolder", path: "OldFolder", role: .custom)
        try TestDatabase.insertMessageHeader(db, messageId: "msg1", folderId: "acc1:OldFolder", folderPath: "OldFolder", isInInbox: false)

        // Remote only has INBOX — OldFolder was deleted server-side
        let remotePaths: Set<String> = ["INBOX"]

        try db.write { dbConn in
            let localFolders = try Folder.filter(Column("accountId") == "acc1").fetchAll(dbConn)
            for folder in localFolders where !remotePaths.contains(folder.path) {
                // v2 migration removed FK on messageHeader.folderId, so no CASCADE.
                // Sync engine must manually delete messages in deleted folders.
                let folderId = folder.id
                try MessageHeader.filter(Column("folderId") == folderId).deleteAll(dbConn)
                try folder.delete(dbConn)
            }
        }

        let folders = try db.read { try Folder.filter(Column("accountId") == "acc1").fetchAll($0) }
        #expect(folders.count == 1)
        #expect(folders[0].path == "INBOX")

        // Messages in deleted folder manually removed
        let orphanedMsgs = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:OldFolder").fetchAll($0) }
        #expect(orphanedMsgs.isEmpty)
    }
}

// MARK: - 4. Message Dedup (Upsert Behavior)

@Suite("Sync Patterns - Message Dedup")
struct MessageDedupTests {

    @Test("Same messageId in same folder does not create duplicate")
    func sameMessageIdNoDuplicate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Insert first time
        try TestDatabase.insertMessageHeader(db, messageId: "42", subject: "Original Subject")

        // Simulate sync upsert: check if exists, then update
        try db.write { dbConn in
            let folderId = "acc1:INBOX"
            if var existing = try MessageHeader
                .filter(Column("messageId") == "42" && Column("folderId") == folderId)
                .fetchOne(dbConn) {
                existing.subject = "Updated Subject"
                existing.isRead = true
                try existing.update(dbConn)
            }
        }

        let all = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0) }
        #expect(all.count == 1)
        #expect(all[0].subject == "Updated Subject")
        #expect(all[0].isRead == true)
    }

    @Test("Same messageId in different folders creates separate records")
    func sameMessageIdDifferentFolders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "All Mail", path: "AllMail", role: .custom)

        try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: "acc1:AllMail", folderPath: "AllMail", isInInbox: false
        )

        let total = try db.read { try MessageHeader.fetchCount($0) }
        #expect(total == 2)

        let inbox = try db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0)
        }
        let allMail = try db.read {
            try MessageHeader.filter(Column("folderId") == "acc1:AllMail").fetchAll($0)
        }
        #expect(inbox.count == 1)
        #expect(allMail.count == 1)
        #expect(inbox[0].id != allMail[0].id)
    }

    @Test("Update preserves replied/forwarded flags — only upgrades from false to true")
    func repliedForwardedOnlyUpgrade() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        var header = try TestDatabase.insertMessageHeader(db, messageId: "42")
        // Manually set isReplied = true locally
        try db.write { dbConn in
            header.isReplied = true
            try header.update(dbConn)
        }

        // Simulate sync update where server says isReplied=false (e.g. Gmail API limitation)
        let serverIsReplied = false
        try db.write { dbConn in
            if var existing = try MessageHeader
                .filter(Column("messageId") == "42" && Column("folderId") == "acc1:INBOX")
                .fetchOne(dbConn) {
                // Pattern from sync engine: only upgrade, never downgrade
                existing.isReplied = existing.isReplied || serverIsReplied
                try existing.update(dbConn)
            }
        }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.isReplied == true) // Preserved local true despite server false
    }
}

// MARK: - 5. Stale Message Detection

@Suite("Sync Patterns - Stale Message Detection")
struct StaleMessageDetectionTests {

    @Test("Messages not in remote set are identified as stale")
    func staleMessagesIdentified() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Local messages: 1, 2, 3
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")
        try TestDatabase.insertMessageHeader(db, messageId: "3")

        // Remote only has 1 and 3
        let remoteIds: Set<String> = ["1", "3"]

        let stale = try db.read { dbConn in
            let allLocal = try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll(dbConn)
            return allLocal.filter { !remoteIds.contains($0.messageId) }
        }

        #expect(stale.count == 1)
        #expect(stale[0].messageId == "2")
    }

    @Test("Stale messages are deleted from DB")
    func staleMessagesDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")
        try TestDatabase.insertMessageHeader(db, messageId: "3")

        let remoteIds: Set<String> = ["1", "3"]

        try db.write { dbConn in
            let allLocal = try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll(dbConn)
            let stale = allLocal.filter { !remoteIds.contains($0.messageId) }
            for msg in stale {
                try msg.delete(dbConn)
            }
        }

        let remaining = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0) }
        #expect(remaining.count == 2)
        #expect(Set(remaining.map(\.messageId)) == Set(["1", "3"]))
    }

    @Test("Date-bounded stale detection only checks overlap window")
    func dateBoundedStaleDetection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let now = Date()
        // Old message outside the remote fetch window
        try TestDatabase.insertMessageHeader(db, messageId: "old", date: now.addingTimeInterval(-86400 * 30))
        // Recent message inside the window
        try TestDatabase.insertMessageHeader(db, messageId: "recent", date: now.addingTimeInterval(-3600))
        // Message that is stale (in window but not in remote set)
        try TestDatabase.insertMessageHeader(db, messageId: "stale", date: now.addingTimeInterval(-1800))

        // Remote messages — simulating limit was reached
        let remoteMessages = [
            ("recent", now.addingTimeInterval(-3600)),
            ("new", now.addingTimeInterval(-600)),
        ]
        let remoteIds = Set(remoteMessages.map(\.0))
        let fetchCutoff = remoteMessages.min(by: { $0.1 < $1.1 })!.1

        let stale = try db.read { dbConn in
            let candidates = try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX" && Column("date") >= fetchCutoff)
                .fetchAll(dbConn)
            return candidates.filter { !remoteIds.contains($0.messageId) }
        }

        #expect(stale.count == 1)
        #expect(stale[0].messageId == "stale")
        // "old" message should NOT be in stale set (outside window)
    }
}

// MARK: - 6. Thread Grouping via ThreadUtils

@Suite("Sync Patterns - Thread Grouping")
struct ThreadGroupingTests {

    @Test("Messages with same normalized subject get same threadId")
    func sameSubjectSameThreadId() {
        let t1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting Notes")
        let t2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Meeting Notes")
        let t3 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Fwd: Re: Meeting Notes")

        #expect(t1 != nil)
        #expect(t1 == t2)
        #expect(t1 == t3)
    }

    @Test("Different subjects get different threadIds")
    func differentSubjectDifferentThreadId() {
        let t1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting Notes")
        let t2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Lunch Plans")
        #expect(t1 != t2)
    }

    @Test("Same subject different accounts get different threadIds")
    func differentAccountDifferentThreadId() {
        let t1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting")
        let t2 = ThreadUtils.computeSubjectThreadId(accountId: "acc2", subject: "Meeting")
        #expect(t1 != t2)
    }

    @Test("Empty subject returns nil threadId")
    func emptySubjectNilThreadId() {
        let t = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "")
        #expect(t == nil)
    }

    @Test("No subject sentinel returns nil threadId")
    func noSubjectSentinelNilThreadId() {
        let t = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "(no subject)")
        #expect(t == nil)
    }

    @Test("Subject with only Re/Fwd prefixes returns nil threadId")
    func onlyPrefixesNilThreadId() {
        let t = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Fwd: Re:")
        #expect(t == nil)
    }

    @Test("Messages stored in DB with computed threadId can be queried as a group")
    func threadGroupQueryable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let subjects = ["Meeting Notes", "Re: Meeting Notes", "Fwd: Meeting Notes"]
        for (i, subject) in subjects.enumerated() {
            var header = MessageHeader(
                messageId: "\(i)",
                subject: subject,
                from: "Alice",
                fromAddress: "alice@example.com",
                to: "bob@example.com",
                date: Date().addingTimeInterval(Double(i) * 60),
                snippet: "test",
                folderId: "acc1:INBOX",
                accountId: "acc1",
                folderPath: "INBOX",
                isInInbox: true
            )
            header.threadId = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: subject)
            try db.write { try header.insert($0) }
        }

        let threadId = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting Notes")!
        let threadMessages = try db.read {
            try MessageHeader.filter(Column("threadId") == threadId).fetchAll($0)
        }
        #expect(threadMessages.count == 3)
    }

    @Test("Non-English prefixes are stripped for thread grouping")
    func nonEnglishPrefixes() {
        // German Aw:, Swedish Sv:, Norwegian Vs:
        let base = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Besprechung")
        let aw = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Aw: Besprechung")
        let sv = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Sv: Besprechung")
        let vs = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Vs: Besprechung")

        #expect(base == aw)
        #expect(base == sv)
        #expect(base == vs)
    }
}

// MARK: - 7. Folder Backfill State

@Suite("Sync Patterns - Folder Backfill State")
struct FolderBackfillStateTests {

    @Test("backfillComplete defaults to false")
    func backfillCompleteDefaultFalse() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        #expect(folder.backfillComplete == false)
    }

    @Test("backfillComplete can be updated to true")
    func backfillCompleteUpdatable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("backfillComplete").set(to: true))
        }

        let updated = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updated?.backfillComplete == true)
    }

    @Test("oldestSyncedDate defaults to nil")
    func oldestSyncedDateDefaultNil() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)
        #expect(folder.oldestSyncedDate == nil)
    }

    @Test("oldestSyncedDate can be set and persisted")
    func oldestSyncedDatePersisted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        let anchorDate = Date(timeIntervalSince1970: 1700000000)
        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("oldestSyncedDate").set(to: anchorDate))
        }

        let updated = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updated?.oldestSyncedDate != nil)
        // Compare with small tolerance for Date encoding
        #expect(abs(updated!.oldestSyncedDate!.timeIntervalSince1970 - anchorDate.timeIntervalSince1970) < 1)
    }

    @Test("backfillUidCursor can be set and persisted")
    func backfillUidCursorPersisted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        try db.write { dbConn in
            _ = try Folder.filter(Column("id") == folder.id)
                .updateAll(dbConn, Column("backfillUidCursor").set(to: 450))
        }

        let updated = try db.read { try Folder.fetchOne($0, key: folder.id) }
        #expect(updated?.backfillUidCursor == 450)
    }

    @Test("Oldest synced date anchored from Nth most recent message")
    func oldestSyncedDateAnchoredFromNthRecent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db)

        // Insert 5 messages with different dates
        let now = Date()
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(
                db, messageId: "\(i)",
                date: now.addingTimeInterval(Double(-i) * 3600) // each 1 hour older
            )
        }

        // Simulate the anchor pattern from fullSync: Nth most recent message
        let n = 3
        let oldestDate = try db.read { dbConn in
            try Date.fetchOne(dbConn,
                MessageHeader
                    .select(Column("date"))
                    .filter(Column("folderId") == folder.id)
                    .order(Column("date").desc)
                    .limit(1, offset: n - 1)
            )
        }

        #expect(oldestDate != nil)
        // Should be the 3rd most recent (offset 2)
        let expectedDate = now.addingTimeInterval(-2 * 3600)
        #expect(abs(oldestDate!.timeIntervalSince1970 - expectedDate.timeIntervalSince1970) < 1)
    }
}

// MARK: - 8. Message Query Patterns

@Suite("Sync Patterns - Message Query Patterns")
struct MessageQueryPatternTests {

    @Test("Filter messages by folderId")
    func filterByFolderId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false)

        let inbox = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll($0) }
        let sent = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll($0) }

        #expect(inbox.count == 2)
        #expect(sent.count == 1)
    }

    @Test("Filter messages by accountId")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user1@example.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "user2@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc2:INBOX", accountId: "acc2", folderPath: "INBOX")

        let acc1Msgs = try db.read { try MessageHeader.filter(Column("accountId") == "acc1").fetchAll($0) }
        let acc2Msgs = try db.read { try MessageHeader.filter(Column("accountId") == "acc2").fetchAll($0) }

        #expect(acc1Msgs.count == 1)
        #expect(acc1Msgs[0].messageId == "1")
        #expect(acc2Msgs.count == 1)
        #expect(acc2Msgs[0].messageId == "2")
    }

    @Test("Filter messages by isInInbox")
    func filterByIsInInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false)
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true)

        let inboxOnly = try db.read {
            try MessageHeader.filter(Column("isInInbox") == true).fetchAll($0)
        }
        #expect(inboxOnly.count == 2)
        #expect(Set(inboxOnly.map(\.messageId)) == Set(["1", "3"]))
    }

    @Test("Filter messages by actionTag")
    func filterByActionTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", actionTag: .reply)
        try TestDatabase.insertMessageHeader(db, messageId: "2", actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "3", actionTag: ActionTag.none)
        try TestDatabase.insertMessageHeader(db, messageId: "4", actionTag: .delete)
        try TestDatabase.insertMessageHeader(db, messageId: "5") // nil actionTag

        let replies = try db.read {
            try MessageHeader.filter(Column("actionTag") == ActionTag.reply.rawValue).fetchAll($0)
        }
        #expect(replies.count == 1)
        #expect(replies[0].messageId == "1")

        let archives = try db.read {
            try MessageHeader.filter(Column("actionTag") == ActionTag.archive.rawValue).fetchAll($0)
        }
        #expect(archives.count == 1)
        #expect(archives[0].messageId == "2")

        let nones = try db.read {
            try MessageHeader.filter(Column("actionTag") == ActionTag.none.rawValue).fetchAll($0)
        }
        #expect(nones.count == 1)
        #expect(nones[0].messageId == "3")

        let untagged = try db.read {
            try MessageHeader.filter(Column("actionTag") == nil).fetchAll($0)
        }
        #expect(untagged.count == 1)
        #expect(untagged[0].messageId == "5")
    }

    @Test("tagSortOrder enables triage sorting")
    func tagSortOrderTriageSorting() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        try TestDatabase.insertMessageHeader(db, messageId: "1", actionTag: .delete)   // sortOrder 3
        try TestDatabase.insertMessageHeader(db, messageId: "2", actionTag: .reply)    // sortOrder 0
        try TestDatabase.insertMessageHeader(db, messageId: "3", actionTag: .archive)  // sortOrder 2
        try TestDatabase.insertMessageHeader(db, messageId: "4", actionTag: ActionTag.none) // sortOrder 1
        try TestDatabase.insertMessageHeader(db, messageId: "5") // nil tag, sortOrder 99

        let sorted = try db.read {
            try MessageHeader
                .filter(Column("folderId") == "acc1:INBOX")
                .order(Column("tagSortOrder").asc)
                .fetchAll($0)
        }

        #expect(sorted.count == 5)
        #expect(sorted[0].messageId == "2") // reply, 0
        #expect(sorted[1].messageId == "4") // none, 1
        #expect(sorted[2].messageId == "3") // archive, 2
        #expect(sorted[3].messageId == "1") // delete, 3
        #expect(sorted[4].messageId == "5") // nil, 99
    }

    @Test("Compound filter: inbox messages with specific actionTag")
    func compoundFilterInboxAndTag() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        try TestDatabase.insertMessageHeader(db, messageId: "1", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true, actionTag: .reply)
        try TestDatabase.insertMessageHeader(db, messageId: "2", folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true, actionTag: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "3", folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false, actionTag: .reply)

        let inboxReplies = try db.read {
            try MessageHeader
                .filter(Column("isInInbox") == true && Column("actionTag") == ActionTag.reply.rawValue)
                .fetchAll($0)
        }
        #expect(inboxReplies.count == 1)
        #expect(inboxReplies[0].messageId == "1")
    }
}
