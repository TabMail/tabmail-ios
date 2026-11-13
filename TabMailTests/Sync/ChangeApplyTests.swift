/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The generic change apply (ADR-IOS-111), driven through the public entry
/// (`SyncEngine.performDeltaSync`) with a scripted `MockEmailProvider` reader, so
/// every rule is checked independently of any provider's reader.
///
/// `.serialized, .processGlobalState`: these tests swap `AppDatabase.shared` and
/// write `AccountManager.shared`'s recently-completed set.
@Suite("Change apply: the generic rules", .serialized, .processGlobalState)
struct ChangeApplyTests {

    struct World {
        let pool: DatabasePool
        let accountId: String
        let mock: MockEmailProvider

        var inboxId: String { "\(accountId):INBOX" }
        var archiveId: String { "\(accountId):Archive" }
        var draftsId: String { "\(accountId):Drafts" }

        func account() throws -> Account {
            try pool.read { db in try Account.fetchOne(db, key: accountId) }!
        }

        /// Script the next reads: each call takes the next builder.
        func script(_ builders: [@Sendable (ChangeCursor, ChangeRequest) -> ChangeSet]) async {
            let queue = Mutex(builders)
            await mock.setChangeReader { cursor, request in
                let next = queue.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                return next?(cursor, request) ?? ChangeSet(account: .keep, folderList: nil, folders: [])
            }
        }

        @discardableResult
        func pass() async throws -> (succeeded: Bool, hadChanges: Bool) {
            try await SyncEngine().performDeltaSync(account: try account(), provider: mock)
        }

        func outcome() async throws -> ChangePassOutcome {
            try await SyncEngine().performChangePass(account: try account(), provider: mock)
        }

        func row(_ messageId: String, in folderId: String) throws -> MessageHeader? {
            try pool.read { db in
                try MessageHeader.filter(Column("messageId") == messageId && Column("folderId") == folderId).fetchOne(db)
            }
        }

        func state(_ folderId: String) throws -> FolderChangeState {
            FolderChangeState(raw: try pool.read { db in try Folder.fetchOne(db, key: folderId)?.changeState })
        }

        func insertRow(_ messageId: String, in folderId: String, path: String, isRead: Bool = false, isFlagged: Bool = false) throws {
            var header = MessageHeader(
                messageId: messageId, subject: "apply \(messageId)", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: Date().addingTimeInterval(-3 * 86_400), snippet: "apply fixture",
                folderId: folderId, accountId: accountId, folderPath: path, isInInbox: path == "INBOX")
            header.rfc822MessageId = ChangeApplyTests.rfc(messageId)
            header.isRead = isRead
            header.isFlagged = isFlagged
            header.headerComplete = true
            try pool.write { db in try header.insert(db) }
        }

        func insertOp(_ type: OperationType, ids: [String], path: String) throws {
            var op = PendingOperation(type: type, messageIds: ids, accountId: accountId, folderPath: path)
            try pool.write { db in try op.insert(db) }
        }
    }

    static func rfc(_ id: String) -> String { "\(id)-apply@example.com" }

    static func info(_ id: String, isRead: Bool = false, isFlagged: Bool = false, labels: [String] = []) -> MessageHeaderInfo {
        var info = MessageHeaderInfo(
            messageId: id, rfc822MessageId: rfc(id), inReplyTo: nil,
            references: ["parent-\(id)@example.com"], threadId: nil, subject: "apply \(id)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
            date: Date().addingTimeInterval(-2 * 86_400), snippet: "apply snippet",
            isRead: isRead, isFlagged: isFlagged, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
        info.userLabelIds = labels
        return info
    }

    static func withWorld(_ body: (World) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let accountId = "capply-\(UUID().uuidString.prefix(8).lowercased())"
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Apply", provider: .gmail)
        account.id = accountId
        account.lastHistoryId = "100"
        account.lastFullSyncAt = Date()
        let toInsert = account
        try await pool.write { db in
            try toInsert.insert(db)
            for (path, role) in [("INBOX", FolderRole.inbox), ("Archive", .archive), ("Drafts", .drafts)] {
                try Folder(name: path, path: path, role: role, accountId: accountId).insert(db)
            }
        }
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        let world = World(pool: pool, accountId: accountId, mock: MockEmailProvider())
        try await body(world)
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        await UnreadCountManager.shared.awaitIdleForTesting()
    }

    /// A tracked read naming only the given folders' changes.
    static func tracked(
        _ request: ChangeRequest, cursor: String = "200", addressEpoch: Int? = nil,
        records: [String: [ChangeRecord]] = [:], removals: [String: [String]] = [:]
    ) -> ChangeSet {
        ChangeSet(account: .set(cursor), folderList: nil, folders: request.folders.map {
            FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: addressEpoch,
                          records: records[$0.id] ?? [], removals: removals[$0.id] ?? [])
        })
    }

    // MARK: - Insert, merge, cursor

    @Test("A full record inserts the row with its fields, references and user labels; the cursor is stored last")
    func insertsAndStoresCursor() async throws {
        try await Self.withWorld { w in
            let inboxId = w.inboxId
            await w.script([{ _, request in
                Self.tracked(request, records: [inboxId: [ChangeRecord(header: Self.info("a1", labels: ["Label_7"]))]])
            }])
            let result = try await w.pass()
            #expect(result.succeeded && result.hadChanges)
            let row = try #require(try w.row("a1", in: w.inboxId))
            #expect(row.rfc822MessageId == Self.rfc("a1") && row.subject == "apply a1" && row.isInInbox)
            let refs = try await w.pool.read { db in
                try String.fetchAll(db, sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?", arguments: [row.id])
            }
            #expect(!refs.isEmpty, "the references rows are written")
            let labels = try await w.pool.read { db in
                try String.fetchAll(db, sql: "SELECT ul.providerLabelId FROM messageUserLabel mul JOIN userLabel ul ON ul.id = mul.userLabelId WHERE mul.messageId = ?", arguments: [row.id])
            }
            #expect(labels == ["Label_7"])
            #expect(try w.account().lastHistoryId == "200")
        }
    }

    @Test("A partial record writes only the fields it carries")
    func partialRecordMergesPresentFieldsOnly() async throws {
        try await Self.withWorld { w in
            try w.insertRow("p1", in: w.inboxId, path: "INBOX", isRead: false, isFlagged: true)
            let inboxId = w.inboxId
            await w.script([{ _, request in
                var record = ChangeRecord(messageId: "p1")
                record.isRead = true
                return Self.tracked(request, records: [inboxId: [record]])
            }])
            try await w.pass()
            let row = try #require(try w.row("p1", in: w.inboxId))
            #expect(row.isRead == true, "the present field is written")
            #expect(row.isFlagged == true, "an absent field never overwrites")
            #expect(row.rfc822MessageId == Self.rfc("p1"), "an absent identity is kept")
        }
    }

    @Test("Replaying the same read leaves the same rows")
    func replayIsIdempotent() async throws {
        try await Self.withWorld { w in
            let inboxId = w.inboxId
            let build: @Sendable (ChangeCursor, ChangeRequest) -> ChangeSet = { _, request in
                Self.tracked(request, records: [inboxId: [ChangeRecord(header: Self.info("r1"))]])
            }
            await w.script([build, build])
            try await w.pass()
            try await w.pass()
            let count = try await w.pool.read { db in
                try MessageHeader.filter(Column("accountId") == w.accountId).fetchCount(db)
            }
            #expect(count == 1)
        }
    }

    // MARK: - Shields and the re-read list

    @Test("A flag change kept back under a pending flag op is re-read and lands once the op is gone")
    func flagShieldRechecks() async throws {
        try await Self.withWorld { w in
            try w.insertRow("f1", in: w.inboxId, path: "INBOX")
            try w.insertOp(.markUnread, ids: ["f1"], path: "INBOX")
            let inboxId = w.inboxId
            let seen = Mutex<[[String: [String]]]>([])
            let build: @Sendable (ChangeCursor, ChangeRequest) -> ChangeSet = { _, request in
                seen.withLock { $0.append(request.recheck) }
                return Self.tracked(request, records: [inboxId: [ChangeRecord(header: Self.info("f1", isRead: true, isFlagged: true))]])
            }
            await w.script([build, build])
            try await w.pass()
            #expect(try w.row("f1", in: w.inboxId)?.isFlagged == false, "kept back under the shield")
            #expect(try w.state(w.inboxId).recheck == ["f1"], "and put on the re-read list")

            try await w.pool.write { db in _ = try PendingOperation.deleteAll(db) }
            try await w.pass()
            let row = try w.row("f1", in: w.inboxId)
            #expect(row?.isFlagged == true && row?.isRead == true, "the re-read lands once nothing shields it")
            #expect(try w.state(w.inboxId).recheck.isEmpty, "and leaves the list")
            #expect(seen.withLock { $0.last?[inboxId] } == ["f1"], "the next read was asked to re-read it")
        }
    }

    @Test("An insert kept back under a pending destructive op or a recent completion goes on the re-read list")
    func insertShieldsRecheck() async throws {
        try await Self.withWorld { w in
            try w.insertOp(.archive, ids: ["d1"], path: "INBOX")
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["d2"])
            let archiveId = w.archiveId
            await w.script([{ _, request in
                Self.tracked(request, records: [archiveId: [
                    ChangeRecord(header: Self.info("d1")), ChangeRecord(header: Self.info("d2")),
                ]])
            }])
            try await w.pass()
            #expect(try w.row("d1", in: w.archiveId) == nil)
            #expect(try w.row("d2", in: w.archiveId) == nil)
            #expect(Set(try w.state(w.archiveId).recheck) == ["d1", "d2"])
        }
    }

    @Test("A removal is kept back by the user's op on the same message in ANY folder when ids are stable")
    func removalAccountWideIdentity() async throws {
        try await Self.withWorld { w in
            try w.insertRow("x1", in: w.inboxId, path: "INBOX")
            try w.insertOp(.markRead, ids: ["x1"], path: "Archive")
            let inboxId = w.inboxId
            await w.script([{ _, request in Self.tracked(request, removals: [inboxId: ["x1"]]) }])
            try await w.pass()
            #expect(try w.row("x1", in: w.inboxId) != nil, "the account-wide identity term protects it")
            #expect(try w.state(w.inboxId).recheck == ["x1"])
        }
    }

    @Test("With an address epoch the identity term stays folder-scoped")
    func removalEpochScoped() async throws {
        try await Self.withWorld { w in
            try w.insertRow("u1", in: w.inboxId, path: "INBOX")
            try w.insertOp(.markRead, ids: ["u1"], path: "Archive")
            let inboxId = w.inboxId
            await w.script([{ _, request in Self.tracked(request, addressEpoch: 7, removals: [inboxId: ["u1"]]) }])
            try await w.pass()
            #expect(try w.row("u1", in: w.inboxId) == nil, "the same id in another folder is another message")
        }
    }

    @Test("A recent completion keeps a row the read removes, for one pass")
    func removalRecentCompletion() async throws {
        try await Self.withWorld { w in
            try w.insertRow("rc1", in: w.inboxId, path: "INBOX")
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["rc1"])
            let inboxId = w.inboxId
            let build: @Sendable (ChangeCursor, ChangeRequest) -> ChangeSet = { _, request in
                Self.tracked(request, removals: [inboxId: ["rc1"]])
            }
            await w.script([build, build])
            try await w.pass()
            #expect(try w.row("rc1", in: w.inboxId) != nil)
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            try await w.pass()
            #expect(try w.row("rc1", in: w.inboxId) == nil, "the removal converges once the protection lifts")
            #expect(try w.state(w.inboxId).recheck.isEmpty)
        }
    }

    @Test("Over the re-read limit, the extra ids are not kept and the folder's catch-up is armed")
    func recheckOverflowArmsCatchUp() async throws {
        try await Self.withWorld { w in
            let ids = (0...SyncConfig.changeRecheckLimit).map { "ov\($0)" }
            try w.insertOp(.archive, ids: ids, path: "INBOX")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE id = ?", arguments: [w.archiveId])
            }
            let archiveId = w.archiveId
            await w.script([{ _, request in
                Self.tracked(request, records: [archiveId: ids.map { ChangeRecord(header: Self.info($0)) }])
            }])
            try await w.pass()
            #expect(try w.state(w.archiveId).recheck.count == SyncConfig.changeRecheckLimit)
            let lapses = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT json_extract(catchUpState, '$.' || ?) FROM folder WHERE id = ?",
                                 arguments: [CatchUpLapse.countKey, w.archiveId])
            }
            #expect(lapses == 1, "the folder's catch-up is armed")
        }
    }

    // MARK: - Drafts and Sent placeholders

    @Test("A Drafts insert replaces the placeholder with the same rfc822 and carries its body")
    func draftsPlaceholderDedup() async throws {
        try await Self.withWorld { w in
            try w.insertRow("local-draft", in: w.draftsId, path: "Drafts")
            let oldId = MessageIdentity.headerId(accountId: w.accountId, folderPath: "Drafts", messageId: "local-draft")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET rfc822MessageId = ? WHERE id = ?", arguments: [Self.rfc("srv-draft"), oldId])
                try MessageBody(contentKey: ContentKey(rawValue: oldId), htmlContent: "kept body").insert(db)
            }
            let draftsId = w.draftsId
            await w.script([{ _, request in
                Self.tracked(request, records: [draftsId: [ChangeRecord(header: Self.info("srv-draft"))]])
            }])
            try await w.pass()
            let rows = try await w.pool.read { db in try MessageHeader.filter(Column("folderId") == w.draftsId).fetchAll(db) }
            guard rows.count == 1 else { Issue.record("expected one Drafts row, got \(rows.count)"); return }
            #expect(rows[0].messageId == "srv-draft")
            let body = try await w.pool.read { db in try MessageBody.fetchOne(db, key: ContentKey(rawValue: rows[0].id)) }
            #expect(body?.htmlContent == "kept body")
        }
    }

    // MARK: - Failure, refusal, candidate

    @Test("A failed read applies the removals it has, keeps the cursor and throws")
    func failedReadAppliesRemovalsAndThrows() async throws {
        struct ReadFailed: Error {}
        try await Self.withWorld { w in
            try w.insertRow("gone1", in: w.inboxId, path: "INBOX")
            let inboxId = w.inboxId
            await w.script([{ _, request in
                ChangeSet(account: .keep, folderList: nil, folders: request.folders.map {
                    FolderChanges(folderId: $0.id, status: .failed(ReadFailed()), removals: $0.id == inboxId ? ["gone1"] : [])
                })
            }])
            await #expect(throws: ReadFailed.self) { try await w.pass() }
            #expect(try w.row("gone1", in: w.inboxId) == nil, "the removal is applied")
            #expect(try w.account().lastHistoryId == "100", "the cursor is kept")
        }
    }

    @Test("A refusal clears the bookmark, untracks every folder, marks a lapse, makes the full sync due, and reads again with no bookmark")
    func refusalHandlerAndReread() async throws {
        try await Self.withWorld { w in
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ?, catchUpState = '{}' WHERE accountId = ?",
                               arguments: [FolderChangeState(tracking: true).encoded, w.accountId])
            }
            let cursors = Mutex<[String?]>([])
            await w.script([
                { cursor, request in
                    cursors.withLock { $0.append(cursor.account) }
                    return .uniform(request, account: .clear, status: .refused(.expired))
                },
                { cursor, request in
                    cursors.withLock { $0.append(cursor.account) }
                    return .uniform(request, account: .candidate("300"), status: .baselineReady)
                },
            ])
            let outcome = try await w.outcome()
            #expect(cursors.withLock { $0 } == ["100", nil], "the same pass reads again without a bookmark")
            #expect(outcome.succeeded == false && outcome.needsListing && outcome.candidate == "300")
            let account = try w.account()
            #expect(account.lastHistoryId == nil && account.lastFullSyncAt == nil)
            #expect(try w.state(w.inboxId).tracking == false)
            let lapses = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT json_extract(catchUpState, '$.' || ?) FROM folder WHERE id = ?",
                                 arguments: [CatchUpLapse.countKey, w.inboxId])
            }
            #expect(lapses == 1, "exactly one lapse mark")
        }
    }

    @Test("A candidate is stored after the listings with no lapse mark, and only the folders listed become tracked")
    func candidateCommitsAfterListings() async throws {
        try await Self.withWorld { w in
            try await w.pool.write { db in
                _ = try Account.filter(Column("id") == w.accountId).updateAll(db, Column("lastHistoryId").set(to: nil as String?))
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE accountId = ?", arguments: [w.accountId])
            }
            await w.script([{ _, request in .uniform(request, account: .candidate("400"), status: .baselineReady) }])
            let outcome = try await w.outcome()
            #expect(try w.account().lastHistoryId == nil, "a candidate is not stored by the read")
            #expect(try w.account().lastFullSyncAt == nil, "the full sync is due")

            // Only the Inbox's listing finished: Archive's and Drafts' failed.
            try await SyncEngine().commitChangeBaseline(account: try w.account(), outcome: outcome, listedFolderIds: [w.inboxId])
            #expect(try w.account().lastHistoryId == "400", "a folder whose listing failed does not hold the bookmark back")
            #expect(try w.state(w.inboxId).tracking)
            #expect(try !w.state(w.archiveId).tracking && !w.state(w.draftsId).tracking,
                    "a folder not listed stays untracked, so a later full sync lists it")
            let lapses = try await w.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder WHERE accountId = ? AND json_extract(catchUpState, '$.' || ?) IS NOT NULL",
                                 arguments: [w.accountId, CatchUpLapse.countKey])
            }
            #expect(lapses == 0, "no lapse mark (#783)")
        }
    }

    // MARK: - The re-read budget

    @Test("One pass asks for at most the re-read budget, taking the folders' lists in turn; the ids not asked for stay listed")
    func rereadBudgetPerPass() async throws {
        try await Self.withWorld { w in
            let budget = SyncConfig.changeRereadBudgetPerPass
            let inboxIds = (0..<(budget + 10)).map { "rb-inbox-\($0)" }
            let archiveIds = (0..<5).map { "rb-archive-\($0)" }
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(recheck: inboxIds).encoded, w.inboxId])
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(recheck: archiveIds).encoded, w.archiveId])
            }
            let asked = Mutex<[String: [String]]>([:])
            await w.script([{ _, request in
                asked.withLock { $0 = request.recheck }
                return Self.tracked(request)
            }])
            try await w.pass()
            let request = asked.withLock { $0 }
            #expect(Set(request.values.flatMap { $0 }).count == budget, "one pass asks for the budget, no more")
            #expect(request[w.archiveId] == archiveIds, "a short list is not starved by a long one")
            #expect(request[w.inboxId] == Array(inboxIds.prefix(budget - archiveIds.count)), "a list is asked for from its front")
            #expect(try w.state(w.inboxId).recheck == inboxIds, "no id is dropped: the ids not asked for, and those not answered, stay")
            #expect(try w.state(w.archiveId).recheck == archiveIds)
        }
    }

    @Test("The re-read budget counts distinct ids and takes the lists position by position")
    func rereadIdsWithinBudgetTakesListsInTurn() {
        let chosen = SyncEngine.rereadIdsWithinBudget([["a1", "a2", "a3"], ["b1"], ["a1", "c2"]], budget: 3)
        #expect(chosen == ["a1", "b1", "a2"])
        #expect(SyncEngine.rereadIdsWithinBudget([["a1"], ["a1"]], budget: 3) == ["a1"])
    }

    @Test("A re-read id kept back again goes to the back of its list, behind the ids the pass did not read")
    func keptBackAgainGoesToTheBack() async throws {
        try await Self.withWorld { w in
            try w.insertRow("rot-a", in: w.inboxId, path: "INBOX")
            try w.insertRow("rot-b", in: w.inboxId, path: "INBOX")
            try w.insertOp(.markRead, ids: ["rot-a"], path: "INBOX")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(recheck: ["rot-a", "rot-b", "rot-c"]).encoded, w.inboxId])
            }
            let inboxId = w.inboxId
            await w.script([{ _, request in
                Self.tracked(request, records: [inboxId: [
                    ChangeRecord(header: Self.info("rot-a", isRead: true)),
                    ChangeRecord(header: Self.info("rot-b", isRead: true)),
                ]])
            }])
            try await w.pass()
            #expect(try w.state(w.inboxId).recheck == ["rot-c", "rot-a"],
                    "rot-b applied and left; rot-a was kept back again and waits behind rot-c")
        }
    }

    @Test("The folder list carried by the read is applied: a new folder appears, a vanished one goes")
    func folderListApplied() async throws {
        try await Self.withWorld { w in
            await w.script([{ _, request in
                var set = Self.tracked(request)
                set.folderList = [
                    FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 0),
                    FolderInfo(name: "Archive", path: "Archive", role: .archive, unreadCount: 0, totalCount: 0),
                    FolderInfo(name: "Projects", path: "Label_9", role: .custom, unreadCount: 0, totalCount: 0),
                ]
                return set
            }])
            let outcome = try await w.outcome()
            #expect(outcome.appliedFolderList != nil)
            let paths = try await w.pool.read { db in
                Set(try Folder.filter(Column("accountId") == w.accountId).fetchAll(db).map(\.path))
            }
            #expect(paths == ["INBOX", "Archive", "Label_9"])
        }
    }

    @Test("A provider without a reader keeps its pre-existing change path")
    func noReaderFallsThrough() async throws {
        try await Self.withWorld { w in
            let outcome = try await w.outcome()
            #expect(outcome.fromReader == false && outcome.succeeded == false)
        }
    }
}
