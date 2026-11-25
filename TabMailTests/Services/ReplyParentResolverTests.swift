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

    /// Sent copies that answer the given In-Reply-To values, each with a reply's subject.
    static func replies(_ inReplyTos: [String?]) -> [ReplyParentResolver.SentCopy] {
        inReplyTos.map { ReplyParentResolver.SentCopy(inReplyTo: $0, subject: "Re: Original") }
    }

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
        isForwarded: Bool = false,
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
        header.isForwarded = isForwarded
        header.actionTag = actionTag
        if let tag = actionTag { header.tagSortOrder = tag.sortOrder }
        try db.write { try header.insert($0) }
        return header
    }

    // MARK: - 0. Parent side: an inserted parent whose reply is stored in Sent

    /// Store a reply in `folderRole`'s folder of `accountId` whose In-Reply-To is `parent`
    /// (a forward when `subject` starts with a forward prefix).
    private func insertReply(
        _ db: DatabaseQueue, uid: String, to parent: String,
        accountId: String = "acc1", folderPath: String = "Sent", folderRole: FolderRole = .sent,
        subject: String = "Original"
    ) throws {
        let reply = try insertParent(db, rfc822: "reply-\(uid)@x", accountId: accountId,
                                     folderPath: folderPath, folderRole: folderRole, messageId: uid)
        try db.write { db in
            try db.execute(sql: "UPDATE messageHeader SET inReplyTo = ?, subject = ? WHERE id = ?",
                           arguments: [parent, subject, reply.id])
        }
    }

    @Test("Parent side: only a reply stored in a Sent folder of the same account marks an inserted parent")
    func insertedParentMarkedOnlyBySameAccountSentReply() throws {
        let db = try TestDatabase.make()
        // Inserted parents: one answered from Sent, one answered only from
        // another account's Sent, one answered only from a non-Sent folder.
        let matched = try insertParent(db, rfc822: "matched@x", actionTag: .reply)
        let foreign = try insertParent(db, rfc822: "foreign@x", actionTag: .reply)
        let nonSent = try insertParent(db, rfc822: "nonsent@x", actionTag: .reply)
        // A stored parent that a stored reply answers, but that this batch did not insert.
        let unrelated = try insertParent(db, rfc822: "unrelated@x", actionTag: .reply)
        try insertReply(db, uid: "r1", to: "matched@x")
        try insertReply(db, uid: "r2", to: "foreign@x", accountId: "acc2")
        try insertParent(db, rfc822: "foreign@x", accountId: "acc2", actionTag: .reply, messageId: "p-acc2")
        try insertReply(db, uid: "r3", to: "nonsent@x", folderPath: "Archive", folderRole: .archive)
        try insertReply(db, uid: "r4", to: "unrelated@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markInsertedParentsOfStoredReplies(
                insertedRfc822Ids: ["matched@x", "foreign@x", "nonsent@x"], accountId: "acc1", db: db)
        }

        #expect(updated == [matched.id])
        let rows = try db.read { db in
            try MessageHeader.filter(Column("rfc822MessageId") != nil).fetchAll(db)
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byId[matched.id]?.isReplied == true && byId[matched.id]?.actionTag == ActionTag.none)
        for control in [foreign, nonSent, unrelated] {
            #expect(byId[control.id]?.isReplied == false && byId[control.id]?.actionTag == .reply,
                    "\(control.rfc822MessageId ?? "") was marked")
        }
        #expect(rows.filter { $0.accountId == "acc2" }.allSatisfy { !$0.isReplied }, "another account's row was marked")
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1 && ops.first?.type == .setTag && ops.first?.accountId == "acc1"
                && ops.first?.folderPath == "INBOX" && ops.first?.tagValue == ActionTag.none.rawValue,
                "queued ops: \(ops.map { ($0.type, $0.accountId, $0.folderPath, $0.messageIds) })")
    }

    @Test("Parent side: no query and no change when nothing was inserted")
    func insertedParentNoInsertsNoChange() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "p@x", actionTag: .reply)
        try insertReply(db, uid: "r1", to: "p@x")
        let updated = try db.write { db in
            try ReplyParentResolver.markInsertedParentsOfStoredReplies(insertedRfc822Ids: [], accountId: "acc1", db: db)
        }
        #expect(updated.isEmpty)
        #expect(try db.read { try MessageHeader.fetchOne($0, key: parent.id) }?.isReplied == false)
    }

    // MARK: - 1. No-op when folder is not Sent

    @Test("Returns empty and does not touch DB when folder.role != .sent")
    func noOpWhenFolderIsNotSent() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: Self.replies(["a@x"]),
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
                sentCopies: Self.replies(["a@x"]),
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
                sentCopies: Self.replies(["  <a@x>  "]), // whitespace + angle brackets
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
                sentCopies: Self.replies(["unknown@x"]),
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
                sentCopies: Self.replies(["a@x"]),
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
                sentCopies: Self.replies([]),
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
                sentCopies: Self.replies([nil, nil, nil]),
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
                sentCopies: Self.replies(["", "  ", "<>", " <> "]),
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
                sentCopies: Self.replies(["a@x", "a@x", "a@x"]),
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
                sentCopies: Self.replies(["a@x", "a@x"]),
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
                sentCopies: Self.replies(["a@x"]),
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
                sentCopies: Self.replies(["a@x"]),
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
                sentCopies: Self.replies(["a@x"]),
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
                sentCopies: Self.replies(["shared@x"]),
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
                sentCopies: Self.replies(["a@x"]),
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
        let p2 = try insertParent(db, rfc822: "b@x", actionTag: .reply)
        let p3 = try insertParent(db, rfc822: "c@x")

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: Self.replies(["a@x", "b@x", "c@x"]),
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
        let taggedAfter = try db.read { try MessageHeader.fetchOne($0, key: p2.id) }
        #expect(taggedAfter?.actionTag == ActionTag.none,
                "the set consumer must still clear .reply on the matching tagged parent")
        let setTagOps = try db.read { db in
            try PendingOperation
                .filter(Column("type") == OperationType.setTag.rawValue)
                .fetchAll(db)
        }
        #expect(setTagOps.count == 1)
        #expect(setTagOps.first?.messageIds.contains(p2.stableId) == true)
    }

    // MARK: - 16. Forward copies: In-Reply-To with a forward subject (#1492)

    /// A Sent copy naming `inReplyTo`, with the given subject.
    static func copy(_ inReplyTo: String?, subject: String) -> ReplyParentResolver.SentCopy {
        ReplyParentResolver.SentCopy(inReplyTo: inReplyTo, subject: subject)
    }

    /// The parent's marks, tag and stamp, and the queued ops.
    private func state(_ db: DatabaseQueue, _ id: String) throws -> (MessageHeader, [PendingOperation]) {
        let (row, ops) = try db.read { db in
            (try MessageHeader.fetchOne(db, key: id), try PendingOperation.fetchAll(db))
        }
        let header = try #require(row, "the parent row exists")
        return (header, ops)
    }

    @Test("A forward copy marks its original forwarded, never replied, keeps its Reply tag and queues no op")
    func forwardCopyMarksForwardedKeepsReplyTag() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        let before = try state(db, parent.id).0

        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy(" <a@x> ", subject: "Fwd: Original")],
                folderRole: .sent, accountId: "acc1", db: db)
        }

        #expect(updated == [parent.id], "a forwarded parent is reported for the change notification")
        let (after, ops) = try state(db, parent.id)
        #expect(after.isForwarded == true)
        #expect(after.isReplied == false, "a forward is not a reply")
        #expect(after.actionTag == .reply, "the user has not answered it")
        #expect(after.tagSortOrder == before.tagSortOrder)
        #expect(after.actionTagSetAt == before.actionTagSetAt)
        #expect(after.isRead == before.isRead && after.isFlagged == before.isFlagged)
        #expect(ops.isEmpty, "queued ops: \(ops.map { ($0.type, $0.messageIds) })")
    }

    @Test("A copy whose subject starts with a forward prefix marks forwarded", arguments: forwardSubjects)
    func forwardSubjectMarksForwarded(subject: String) throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        _ = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: subject)], folderRole: .sent, accountId: "acc1", db: db)
        }
        let (after, ops) = try state(db, parent.id)
        #expect(after.isForwarded == true && after.isReplied == false && after.actionTag == .reply,
                "\(subject): forwarded \(after.isForwarded), replied \(after.isReplied), tag \(String(describing: after.actionTag))")
        #expect(ops.isEmpty)
    }

    @Test("A copy whose subject does not start with a forward prefix marks replied", arguments: nonForwardSubjects)
    func nonForwardSubjectMarksReplied(subject: String) throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        _ = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: subject)], folderRole: .sent, accountId: "acc1", db: db)
        }
        let (after, ops) = try state(db, parent.id)
        #expect(after.isReplied == true && after.isForwarded == false && after.actionTag == ActionTag.none,
                "\(subject): replied \(after.isReplied), forwarded \(after.isForwarded), tag \(String(describing: after.actionTag))")
        #expect(ops.count == 1 && ops.first?.type == .setTag)
    }

    @Test("A forward copy outside a Sent folder, or with no In-Reply-To, marks nothing")
    func forwardCopyGates() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        let updated = try db.write { db -> [String] in
            var ids = try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: "Fwd: Original")], folderRole: .inbox, accountId: "acc1", db: db)
            ids += try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy(nil, subject: "Fwd: Original"), Self.copy("  ", subject: "Fwd: Original")],
                folderRole: .sent, accountId: "acc1", db: db)
            ids += try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: "Fwd: Original")], folderRole: .sent, accountId: "acc2", db: db)
            return ids
        }
        #expect(updated.isEmpty)
        let (after, ops) = try state(db, parent.id)
        #expect(after.isForwarded == false && after.isReplied == false && after.actionTag == .reply)
        #expect(ops.isEmpty)
    }

    @Test("A reply and a forward of one original in one batch mark it both ways, clear its tag once, report it once")
    func replyAndForwardInOneBatch() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", actionTag: .reply)
        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: "Fwd: Original"), Self.copy("<a@x>", subject: "Re: Original"),
                             Self.copy("a@x", subject: "FW: Original")],
                folderRole: .sent, accountId: "acc1", db: db)
        }
        #expect(updated == [parent.id])
        let (after, ops) = try state(db, parent.id)
        #expect(after.isReplied == true && after.isForwarded == true && after.actionTag == ActionTag.none)
        #expect(ops.count == 1 && ops.first?.type == .setTag && ops.first?.messageIds.contains(parent.stableId) == true,
                "queued ops: \(ops.map { ($0.type, $0.messageIds) })")
    }

    @Test("Forward and reply copies of different originals in one batch mark each its own way")
    func forwardAndReplyOfDifferentParents() throws {
        let db = try TestDatabase.make()
        let forwarded = try insertParent(db, rfc822: "f@x", actionTag: .reply)
        let replied = try insertParent(db, rfc822: "r@x", actionTag: .reply)
        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("f@x", subject: "Fwd: Original"), Self.copy("r@x", subject: "Re: Original")],
                folderRole: .sent, accountId: "acc1", db: db)
        }
        #expect(Set(updated) == [forwarded.id, replied.id] && updated.count == 2)
        let (f, ops) = try state(db, forwarded.id)
        let r = try state(db, replied.id).0
        #expect(f.isForwarded == true && f.isReplied == false && f.actionTag == .reply)
        #expect(r.isReplied == true && r.isForwarded == false && r.actionTag == ActionTag.none)
        #expect(ops.count == 1 && ops.first?.messageIds.contains(replied.stableId) == true
                && ops.first?.messageIds.contains(forwarded.stableId) == false)
    }

    @Test("A forward copy of an original already marked forwarded changes nothing")
    func forwardOfForwardedParentIsNoOp() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", isForwarded: true, actionTag: .reply)
        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: "Fwd: Original")], folderRole: .sent, accountId: "acc1", db: db)
        }
        #expect(updated.isEmpty)
        let (after, ops) = try state(db, parent.id)
        #expect(after.isForwarded == true && after.isReplied == false && after.actionTag == .reply)
        #expect(ops.isEmpty)
    }

    @Test("A forward copy of an original already replied marks it forwarded too")
    func forwardOfRepliedParentMarksForwarded() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", isReplied: true, actionTag: .archive)
        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: [Self.copy("a@x", subject: "Fwd: Original")], folderRole: .sent, accountId: "acc1", db: db)
        }
        #expect(updated == [parent.id])
        let (after, ops) = try state(db, parent.id)
        #expect(after.isForwarded == true && after.isReplied == true && after.actionTag == .archive)
        #expect(ops.isEmpty)
    }

    @Test("A reply copy of an original already forwarded still marks it replied and clears its Reply tag")
    func replyOfForwardedParentMarksReplied() throws {
        let db = try TestDatabase.make()
        let parent = try insertParent(db, rfc822: "a@x", isForwarded: true, actionTag: .reply)
        let updated = try db.write { db in
            try ReplyParentResolver.markParentsReplied(
                sentCopies: Self.replies(["a@x"]), folderRole: .sent, accountId: "acc1", db: db)
        }
        #expect(updated == [parent.id])
        let (after, ops) = try state(db, parent.id)
        #expect(after.isReplied == true && after.isForwarded == true && after.actionTag == ActionTag.none)
        #expect(ops.count == 1 && ops.first?.type == .setTag)
    }

    @Test("Parent side: an inserted original whose forward is stored in Sent is marked forwarded and keeps its Reply tag")
    func insertedParentOfStoredForward() throws {
        let db = try TestDatabase.make()
        let forwardedOnly = try insertParent(db, rfc822: "f@x", actionTag: .reply)
        let both = try insertParent(db, rfc822: "b@x", actionTag: .reply)
        try insertReply(db, uid: "r1", to: "f@x", subject: "Fwd: Original")
        try insertReply(db, uid: "r2", to: "b@x", subject: "FW: Original")
        try insertReply(db, uid: "r3", to: "b@x", subject: "Re: Original")
        // A reply stored in another account's Sent names f@x too; it marks nothing here.
        try insertReply(db, uid: "r4", to: "f@x", accountId: "acc2", subject: "Re: Original")

        let updated = try db.write { db in
            try ReplyParentResolver.markInsertedParentsOfStoredReplies(
                insertedRfc822Ids: ["f@x", "<b@x>"], accountId: "acc1", db: db)
        }

        #expect(Set(updated) == [forwardedOnly.id, both.id] && updated.count == 2)
        let (f, ops) = try state(db, forwardedOnly.id)
        let b = try state(db, both.id).0
        #expect(f.isForwarded == true && f.isReplied == false && f.actionTag == .reply,
                "forwarded \(f.isForwarded), replied \(f.isReplied), tag \(String(describing: f.actionTag))")
        #expect(b.isForwarded == true && b.isReplied == true && b.actionTag == ActionTag.none)
        #expect(ops.count == 1 && ops.first?.messageIds.contains(both.stableId) == true,
                "queued ops: \(ops.map { ($0.type, $0.messageIds) })")
    }
}

/// Subjects a forward's Sent copy starts with (file scope: a `@Test` trait cannot
/// name a static member of its own type).
private let forwardSubjects = ["Fwd: Original", "FWD: Original", "fwd:Original", "Fw: Original",
                               "FW: Original", "  Fwd: Original", "\tFW: Original", "Fwd: Re: Original"]

/// Subjects that are not a forward's: a reply's, a reply to a forward, the
/// ambiguous Vs, localized forward prefixes outside the list, and lookalikes.
private let nonForwardSubjects = ["Re: Original", "Re: Fwd: Original", "RE: FW: Original", "VS: Original",
                                  "Vs: Original", "AW: Original", "SV: Original", "WG: Original", "TR: Original",
                                  "RV: Original", "Fwd Original", "Forward: Original", "Original Fwd: x",
                                  "Original", ""]
