/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Unit tests for `ReplyParentResolver.markParentsReplied` — the helper that
/// flips the `isReplied` flag on the local parent message when sync ingests
/// a Sent-folder reply from another device.
///
/// Tests use an in-memory GRDB queue (`TestDatabase.make()`) to exercise
/// the helper directly. Each test seeds its own fixtures; fresh DB per test
/// means no cleanup needed.
@Suite("ReplyParentResolver — Sent-folder reply discovery")
struct ReplyParentResolverTests {

    // MARK: - Fixture helpers

    /// Build a Folder with a given role. `id` defaults to `accountId:path`
    /// so it matches the production folderId convention.
    private func folder(role: FolderRole, accountId: String = "acc1", path: String = "Sent") -> Folder {
        Folder(name: path, path: path, role: role, accountId: accountId)
    }

    /// Insert a parent message header with explicit isReplied / actionTag /
    /// rfc822MessageId. Returns the inserted header.
    @discardableResult
    private func insertParent(
        _ db: DatabaseQueue,
        rfc822: String,
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        folderRole: FolderRole = .inbox,
        isReplied: Bool = false,
        actionTag: ActionTag? = nil,
        messageId: String? = nil
    ) throws -> MessageHeader {
        let folderId = "\(accountId):\(folderPath)"
        // Make sure account + folder exist (idempotent across tests in same DB)
        try db.write { db in
            if try Account.fetchOne(db, key: accountId) == nil {
                var acc = Account(emailAddress: "\(accountId)@example.com", displayName: "Test", provider: .gmail)
                acc.id = accountId
                try acc.insert(db)
            }
            if try Folder.fetchOne(db, key: folderId) == nil {
                let f = Folder(name: folderPath, path: folderPath, role: folderRole, accountId: accountId)
                try f.insert(db)
            }
        }
        var header = MessageHeader(
            messageId: messageId ?? "uid-parent-\(rfc822)",
            subject: "Original",
            from: "Other Person",
            fromAddress: "other@example.com",
            to: "me@example.com",
            date: Date(timeIntervalSinceNow: -3600),
            snippet: "original message snippet",
            folderId: folderId,
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: folderRole == .inbox
        )
        header.rfc822MessageId = rfc822
        header.isReplied = isReplied
        header.actionTag = actionTag
        if let tag = actionTag { header.tagSortOrder = tag.sortOrder }
        try db.write { try header.insert($0) }
        return header
    }

    // MARK: - 1. No-op when folder is not Sent

    @Test("Returns empty and does not touch DB when folder.role != .sent")
    func noOpWhenFolderIsNotSent() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .inbox, // <-- not Sent
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.isEmpty)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == false)
        let pendingCount = try db.read { try PendingOperation.fetchCount($0) }
        #expect(pendingCount == 0)
    }

    // MARK: - 2. Marks parent when folder is Sent and parent exists

    @Test("Marks parent.isReplied = true when folder is Sent and parent matches by rfc822MessageId")
    func marksParentInSentFolder() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.count == 1)
        guard updated.count == 1 else { return }
        #expect(updated[0] == parent.id)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == true)
    }

    // MARK: - 3. Normalizes In-Reply-To (strips angle brackets and whitespace)

    @Test("Normalizes In-Reply-To by stripping <> and whitespace")
    func normalizesInReplyTo() throws {
        let db = try TestDatabase.make()
        // Parent stored bare per project convention (feedback_rfc822_normalization.md)
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["  <a@x>  "], // whitespace + angle brackets
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.count == 1)
        guard updated.count == 1 else { return }
        #expect(updated[0] == parent.id)
    }

    // MARK: - 4. No-op when parent not in DB

    @Test("Returns empty when In-Reply-To points at an unknown parent")
    func noOpWhenParentNotInDB() throws {
        let db = try TestDatabase.make()

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["unknown@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.isEmpty)
    }

    // MARK: - 5. No-op when parent already replied

    @Test("Skips parents that are already replied — returns empty, no PendingOp written")
    func noOpWhenParentAlreadyReplied() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", isReplied: true, actionTag: .reply)

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.isEmpty)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.actionTag == .reply, "actionTag must NOT be cleared on already-replied parent")
        let pendingCount = try db.read { try PendingOperation.fetchCount($0) }
        #expect(pendingCount == 0, "no PendingOperation should be written")
    }

    // MARK: - 6. Empty input array

    @Test("Empty inReplyTos returns empty without touching DB")
    func emptyInputArray() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: [],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.isEmpty)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == false)
    }

    // MARK: - 7. All-nil input

    @Test("All-nil inReplyTos returns empty (compactMap drops everything)")
    func allNilInput() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: [nil, nil, nil],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.isEmpty)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == false)
    }

    // MARK: - 8. All-empty-after-normalize

    @Test("All-empty-string inReplyTos returns empty (filter drops empty)")
    func allEmptyAfterNormalize() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["", "  ", "<>", " <> "],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.isEmpty)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == false)
    }

    // MARK: - 9. Batch dedup of same In-Reply-To

    @Test("Same In-Reply-To repeated 3× in batch → one parent updated, one ID returned")
    func batchDedupSameParent() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x", "a@x", "a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.count == 1)
        guard updated.count == 1 else { return }
        #expect(updated[0] == parent.id)
    }

    // MARK: - 10. Two replies same parent → one tag-clear PendingOperation

    @Test("Two batch entries referencing the same .reply-tagged parent → exactly one setTag PendingOperation")
    func doubleTagClearGuard() throws {
        let db = try TestDatabase.make()
        try insertParent(db, rfc822: "a@x", actionTag: .reply)

        try db.write { db in
            _ = try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x", "a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        let setTagCount = try db.read { db in
            try PendingOperation
                .filter(Column("type") == OperationType.setTag.rawValue)
                .fetchCount(db)
        }
        #expect(setTagCount == 1, "Set dedup must prevent a second setTag PendingOperation")
    }

    // MARK: - 11. Clears Reply action tag and queues server setTag op

    @Test("Parent with actionTag = .reply → tag cleared to .none and setTag PendingOp queued")
    func clearsReplyActionTagAndQueuesServerOp() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)

        try db.write { db in
            _ = try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.actionTag == ActionTag.none)
        #expect(after?.tagSortOrder == ActionTag.none.sortOrder)
        #expect(after?.isReplied == true)

        let setTagOps = try db.read { db in
            try PendingOperation
                .filter(Column("type") == OperationType.setTag.rawValue)
                .fetchAll(db)
        }
        #expect(setTagOps.count == 1)
        guard setTagOps.count == 1 else { return }
        #expect(setTagOps[0].tagValue == ActionTag.none.rawValue)
        #expect(setTagOps[0].accountId == "acc1")
        #expect(setTagOps[0].folderPath == "INBOX")
        // messageIds JSON should contain the parent's stableId
        #expect(setTagOps[0].messageIds.contains(parent.stableId))
    }

    @Test("Reply-tag clear leaves the parent stamped — a raw-SQL tag write must not break actionTag != nil ⇒ actionTagSetAt != nil")
    func replyTagClearStampsActionTagSetAt() throws {
        let db = try TestDatabase.make()
        // Seeded the legacy way: tag set, stamp NULL — exactly the shape a
        // pre-v81 row has, so the assertion below can only pass if the
        // production UPDATE writes the stamp itself.
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        let before = Date()

        try db.write { db in
            _ = try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        // `ActionTag.none` is a real tag VALUE, not `Optional.none` — the row
        // still CARRIES a tag, so it must carry a stamp.
        #expect(after?.actionTag == ActionTag.none)
        let setAt = try #require(after?.actionTagSetAt, "a row left carrying a tag with a NULL stamp is swept on the very next maintenance pass")
        // 1s slack: GRDB persists Date at millisecond precision, so a stamp
        // taken microseconds after `before` can round just below it.
        #expect(setAt >= before.addingTimeInterval(-1))
        #expect(setAt <= Date().addingTimeInterval(1))
    }

    // MARK: - 12. Other action tags are NOT cleared

    @Test("Parent with actionTag = .archive → tag preserved, no setTag PendingOp written")
    func nonReplyActionTagsArePreserved() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .archive)

        try db.write { db in
            _ = try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.actionTag == .archive, "non-reply tag must be preserved")
        #expect(after?.isReplied == true, "isReplied still flips")
        let setTagCount = try db.read { db in
            try PendingOperation
                .filter(Column("type") == OperationType.setTag.rawValue)
                .fetchCount(db)
        }
        #expect(setTagCount == 0)
    }

    // MARK: - 13. Account isolation

    @Test("Two accounts share an rfc822MessageId — only the matching accountId's parent is updated")
    func accountIsolation() throws {
        let db = try TestDatabase.make()
        let parent1 = try insertParent(db, rfc822: "shared@x", accountId: "acc1")
        let parent2 = try insertParent(db, rfc822: "shared@x", accountId: "acc2")

        try db.write { db in
            _ = try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["shared@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        let after1 = try db.read { try MessageHeader.fetchOne($0, key: parent1.id) }
        let after2 = try db.read { try MessageHeader.fetchOne($0, key: parent2.id) }
        #expect(after1?.isReplied == true)
        #expect(after2?.isReplied == false, "acc2's parent must NOT be touched")
    }

    // MARK: - 14. Untouched columns

    @Test("UPDATE only touches isReplied (and conditionally actionTag/tagSortOrder) — other columns byte-equal")
    func untouchedColumnsAreByteEqual() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")
        let before = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }!

        try db.write { db in
            _ = try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }!

        // isReplied changed (expected)
        #expect(after.isReplied == true)
        #expect(before.isReplied == false)

        // Everything else preserved
        #expect(after.id == before.id)
        #expect(after.messageId == before.messageId)
        #expect(after.subject == before.subject)
        #expect(after.from == before.from)
        #expect(after.fromAddress == before.fromAddress)
        #expect(after.to == before.to)
        #expect(after.cc == before.cc)
        #expect(after.bcc == before.bcc)
        #expect(after.date == before.date)
        #expect(after.snippet == before.snippet)
        #expect(after.isRead == before.isRead)
        #expect(after.isFlagged == before.isFlagged)
        #expect(after.isForwarded == before.isForwarded)
        #expect(after.hasAttachments == before.hasAttachments)
        #expect(after.actionTag == before.actionTag)
        #expect(after.tagSortOrder == before.tagSortOrder)
        #expect(after.folderId == before.folderId)
        #expect(after.folderPath == before.folderPath)
        #expect(after.accountId == before.accountId)
        #expect(after.isInInbox == before.isInInbox)
        #expect(after.notified == before.notified)
        #expect(after.rfc822MessageId == before.rfc822MessageId)
    }

    // MARK: - Historic backfill (v53 migration)

    /// Insert a Sent-folder reply (from `me@example.com` → `you@example.com`)
    /// pointing at parent `parentRfc822` via In-Reply-To.
    @discardableResult
    private func insertSentReply(
        _ db: DatabaseQueue,
        accountId: String = "acc1",
        replyMessageId: String = "uid-reply-1",
        replyRfc822: String = "reply-1@example.com",
        inReplyTo: String
    ) throws -> MessageHeader {
        let folderId = "\(accountId):Sent"
        try db.write { db in
            if try Folder.fetchOne(db, key: folderId) == nil {
                let f = Folder(name: "Sent", path: "Sent", role: .sent, accountId: accountId)
                try f.insert(db)
            }
        }
        var reply = MessageHeader(
            messageId: replyMessageId,
            subject: "Re: Original",
            from: "Me",
            fromAddress: "me@example.com",
            to: "you@example.com",
            date: Date(),
            snippet: "my reply",
            folderId: folderId,
            accountId: accountId,
            folderPath: "Sent",
            isInInbox: false
        )
        reply.rfc822MessageId = replyRfc822
        reply.inReplyTo = inReplyTo
        try db.write { try reply.insert($0) }
        return reply
    }

    @Test("Historic backfill: parent with local Sent reply gets isReplied flipped")
    func historicBackfillFlipsParent() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")
        try insertSentReply(db, inReplyTo: "a@x")

        let count = try db.write { db in
            try ReplyParentResolver.runHistoricBackfill(db: db)
        }

        #expect(count == 1)
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == true)
    }

    @Test("Historic backfill: clears stale .reply action tag on flipped parents")
    func historicBackfillClearsReplyTag() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        try insertSentReply(db, inReplyTo: "a@x")

        try db.write { db in _ = try ReplyParentResolver.runHistoricBackfill(db: db) }

        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == true)
        #expect(after?.actionTag == ActionTag.none)
        #expect(after?.tagSortOrder == ActionTag.none.sortOrder)
    }

    @Test("Historic backfill: skips parents already marked replied")
    func historicBackfillSkipsAlreadyReplied() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", isReplied: true, actionTag: .reply)
        try insertSentReply(db, inReplyTo: "a@x")

        let count = try db.write { db in
            try ReplyParentResolver.runHistoricBackfill(db: db)
        }

        #expect(count == 0, "already-replied parents are filtered out by isReplied = 0")
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        // The .reply tag is NOT cleared because isReplied = 0 filter excluded the row.
        // Acceptable: the going-forward path would have cleared it when it set isReplied.
        #expect(after?.actionTag == .reply)
    }

    @Test("Historic backfill: ignores replies in non-Sent folders (Drafts, Inbox)")
    func historicBackfillIgnoresNonSentFolders() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")
        // A draft of a reply pointing at the parent — user hasn't sent yet.
        let draftFolderId = "acc1:Drafts"
        try db.write { db in
            let f = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
            try f.insert(db)
        }
        var draft = MessageHeader(
            messageId: "draft-1", subject: "Re: Original", from: "Me", fromAddress: "me@example.com",
            to: "you@example.com", date: Date(), snippet: "draft",
            folderId: draftFolderId, accountId: "acc1", folderPath: "Drafts", isInInbox: false
        )
        draft.rfc822MessageId = "draft-1@example.com"
        draft.inReplyTo = "a@x"
        try db.write { try draft.insert($0) }

        let count = try db.write { db in
            try ReplyParentResolver.runHistoricBackfill(db: db)
        }

        #expect(count == 0, "Drafts is not Sent — must not flip parent")
        let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
        #expect(after?.isReplied == false)
    }

    @Test("Historic backfill: account-scoped — acc1 reply does not flip acc2 parent")
    func historicBackfillIsAccountScoped() throws {
        let db = try TestDatabase.make()
        let parent1 = try insertParent(db, rfc822: "shared@x", accountId: "acc1")
        let parent2 = try insertParent(db, rfc822: "shared@x", accountId: "acc2")
        try insertSentReply(db, accountId: "acc1", inReplyTo: "shared@x")

        try db.write { db in _ = try ReplyParentResolver.runHistoricBackfill(db: db) }

        let after1 = try db.read { try MessageHeader.fetchOne($0, key: parent1.id) }
        let after2 = try db.read { try MessageHeader.fetchOne($0, key: parent2.id) }
        #expect(after1?.isReplied == true)
        #expect(after2?.isReplied == false, "acc2 has no Sent reply pointing at this parent")
    }

    @Test("Historic backfill: multiple parents, one pass")
    func historicBackfillBatch() throws {
        let db = try TestDatabase.make()
        let p1 = try insertParent(db, rfc822: "a@x")
        let p2 = try insertParent(db, rfc822: "b@x")
        let p3 = try insertParent(db, rfc822: "c@x")
        try insertSentReply(db, replyMessageId: "uid-r1", replyRfc822: "r1@x", inReplyTo: "a@x")
        try insertSentReply(db, replyMessageId: "uid-r2", replyRfc822: "r2@x", inReplyTo: "b@x")
        try insertSentReply(db, replyMessageId: "uid-r3", replyRfc822: "r3@x", inReplyTo: "c@x")

        let count = try db.write { db in
            try ReplyParentResolver.runHistoricBackfill(db: db)
        }

        #expect(count == 3)
        for parent in [p1, p2, p3] {
            let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
            #expect(after?.isReplied == true)
        }
    }

    @Test("Historic backfill: idempotent — second run is a no-op")
    func historicBackfillIsIdempotent() throws {
        let db = try TestDatabase.make()
        try insertParent(db, rfc822: "a@x")
        try insertSentReply(db, inReplyTo: "a@x")

        let firstCount = try db.write { db in
            try ReplyParentResolver.runHistoricBackfill(db: db)
        }
        let secondCount = try db.write { db in
            try ReplyParentResolver.runHistoricBackfill(db: db)
        }

        #expect(firstCount == 1)
        #expect(secondCount == 0, "second run should find nothing — isReplied = 0 filter excludes already-flipped rows")
    }

    @Test("Historic backfill: does NOT queue server PendingOperations")
    func historicBackfillDoesNotQueuePendingOps() throws {
        let db = try TestDatabase.make()
        try insertParent(db, rfc822: "a@x", actionTag: .reply)
        try insertSentReply(db, inReplyTo: "a@x")

        try db.write { db in _ = try ReplyParentResolver.runHistoricBackfill(db: db) }

        // Per ADR-IOS-036 (action tags local-only) and the migration's
        // intent, we must NOT queue any setTag PendingOps for the historic
        // backlog (would flood the queue with thousands of ops).
        let pendingCount = try db.read { try PendingOperation.fetchCount($0) }
        #expect(pendingCount == 0)
    }

    // MARK: - 15. Batch with multiple replies referencing different parents

    @Test("Batch of three replies referencing three different parents updates all three")
    func batchMultipleParents() throws {
        let db = try TestDatabase.make()
        let p1 = try insertParent(db, rfc822: "a@x")
        let p2 = try insertParent(db, rfc822: "b@x")
        let p3 = try insertParent(db, rfc822: "c@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                inReplyTos: ["a@x", "b@x", "c@x"],
                folderRole: .sent,
                accountId: "acc1",
                db: db
            )
        }

        #expect(updated.count == 3)
        guard updated.count == 3 else { return }
        let updatedSet = Set(updated)
        #expect(updatedSet == Set([p1.id, p2.id, p3.id]))

        // All three flipped
        for parent in [p1, p2, p3] {
            let after = try db.read { try MessageHeader.fetchOne($0, key: parent.id) }
            #expect(after?.isReplied == true, "parent \(parent.rfc822MessageId ?? "?") should be replied")
        }
    }
}
