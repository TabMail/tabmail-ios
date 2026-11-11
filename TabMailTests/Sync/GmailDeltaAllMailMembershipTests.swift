/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The Gmail history delta keeps the synthetic All Mail folder in step with the
/// server, by the same membership rule the All Mail listing uses: a message is in
/// All Mail exactly when it carries none of the excluded system labels.
///
/// Every test drives PRODUCTION `SyncEngine.performDeltaSync` against a real
/// `GmailProvider` talking to `StatefulGmailActionServer`, whose `/history`
/// route reports the label changes the fake applied. Each pins the invariant
/// "after the delta, the local rows match the server's labels under the listing
/// rule", never the mechanism.
///
/// The protection tests each pair a protected message with an unprotected twin
/// that changes the same way: the twin proves the delta did reach All Mail, the
/// protected message proves the guard held.
///
/// `.serialized, .processGlobalState`: these tests replace `AppDatabase.shared`
/// and write `AccountManager.shared.recentlyCompleted`, which the trait clears.
@Suite("Gmail history delta keeps All Mail membership in step with the server", .serialized, .processGlobalState)
struct GmailDeltaAllMailMembershipTests {

    private static let accountId = "allmaildelta"
    private static let userLabelId = "Label_1"

    // MARK: - Fixture

    private struct Fixture {
        let pool: DatabasePool
        let account: Account
        let server: StatefulGmailActionServer
        let folders: [String: Folder]

        func folder(_ path: String) -> Folder { folders[path]! }
    }

    /// A message dated well before anything a recent full sync would list.
    private static func oldDate() -> Date {
        Calendar.current.date(byAdding: .day, value: -400, to: Date())!
    }

    private static func seed(_ id: String, labels: Set<String>) -> StatefulGmailActionServer.Seed {
        StatefulGmailActionServer.Seed(
            rfc822MessageId: "\(id)@example.com",
            providerMessageId: id,
            labels: labels,
            internalDate: oldDate()
        )
    }

    /// An account with Inbox, Sent, Trash, All Mail and one user label folder,
    /// whose history cursor is the fake's current `historyId`.
    private static func makeFixture(
        pool: DatabasePool, seeds: [StatefulGmailActionServer.Seed]
    ) throws -> Fixture {
        let server = StatefulGmailActionServer(messages: seeds)
        var account = Account(
            emailAddress: "\(accountId)@example.com",
            displayName: "All Mail delta fixture",
            provider: .gmail
        )
        account.id = accountId
        account.lastHistoryId = server.currentHistoryId()
        let folderList = [
            Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId),
            Folder(name: "Sent", path: "SENT", role: .sent, accountId: accountId),
            Folder(name: "Trash", path: "TRASH", role: .trash, accountId: accountId),
            Folder(name: "All Mail", path: GmailProvider.archivePath, role: .archive, accountId: accountId),
            Folder(name: "Label", path: userLabelId, role: .custom, accountId: accountId),
        ]
        let toInsert = account
        try pool.write { db in
            try toInsert.insert(db)
            for folder in folderList { try folder.insert(db) }
        }
        return Fixture(
            pool: pool,
            account: account,
            server: server,
            folders: Dictionary(uniqueKeysWithValues: folderList.map { ($0.path, $0) })
        )
    }

    /// A local row for `messageId` in `folder`, as a full sync would have left it.
    private static func insertRow(
        _ messageId: String, in folder: Folder, isRead: Bool = false, isFlagged: Bool = false, pool: DatabasePool
    ) throws {
        var header = MessageHeader(
            messageId: messageId,
            subject: "All Mail fixture \(messageId)",
            from: "Fixture",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: oldDate(),
            snippet: "all mail fixture",
            folderId: folder.id,
            accountId: folder.accountId,
            folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        header.rfc822MessageId = "<\(messageId)@example.com>"
        header.isRead = isRead
        header.isFlagged = isFlagged
        header.headerComplete = true
        try pool.write { db in try header.insert(db) }
    }

    private static func insertOp(_ type: OperationType, messageId: String, folderPath: String, pool: DatabasePool) throws {
        var op = PendingOperation(type: type, messageIds: [messageId], accountId: accountId, folderPath: folderPath)
        try pool.write { db in try op.insert(db) }
    }

    private static func row(_ messageId: String, in folder: Folder, pool: DatabasePool) throws -> MessageHeader? {
        try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == messageId && Column("folderId") == folder.id)
                .fetchOne(db)
        }
    }

    /// Run one production delta pass and require it to finish, cursor included.
    private static func runDelta(_ fixture: Fixture) async throws {
        let provider = fixture.server.provider()
        let outcome = try await SyncEngine().performDeltaSync(account: fixture.account, provider: provider)
        #expect(outcome.succeeded, "precondition: the delta pass ran")
        let cursor = try await fixture.pool.read { db in try Account.fetchOne(db, key: accountId) }?.lastHistoryId
        #expect(cursor == fixture.server.currentHistoryId(), "precondition: the pass completed and advanced the cursor")
    }

    private static func withDatabase(_ body: (DatabasePool) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await body(pool)
    }

    // MARK: - Changes to existing All Mail rows

    @Test("A read change and a star change on an old All Mail row reach that row")
    func readAndStarChangesReachAllMailRow() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [
                Self.seed("read-msg", labels: ["UNREAD"]),
                Self.seed("star-msg", labels: []),
            ])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("read-msg", in: allMail, isRead: false, pool: pool)
            try Self.insertRow("star-msg", in: allMail, isRead: true, isFlagged: false, pool: pool)

            f.server.applyLabelChange(providerMessageId: "read-msg", remove: ["UNREAD"])
            f.server.applyLabelChange(providerMessageId: "star-msg", add: ["STARRED"])
            try await Self.runDelta(f)

            #expect(try Self.row("read-msg", in: allMail, pool: pool)?.isRead == true,
                    "the message was read on the server, so its All Mail row must read as read")
            #expect(try Self.row("star-msg", in: allMail, pool: pool)?.isFlagged == true,
                    "the message was starred on the server, so its All Mail row must be flagged")
        }
    }

    @Test("Trashing an old All Mail message removes its All Mail row and adds a Trash row")
    func trashRemovesAllMailRow() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [Self.seed("trash-msg", labels: [])])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("trash-msg", in: allMail, pool: pool)

            f.server.applyLabelChange(providerMessageId: "trash-msg", add: ["TRASH"])
            try await Self.runDelta(f)

            #expect(try Self.row("trash-msg", in: allMail, pool: pool) == nil,
                    "a TRASH-labelled message is not in All Mail, so its row must go")
            #expect(try Self.row("trash-msg", in: f.folder("TRASH"), pool: pool) != nil)
        }
    }

    // MARK: - Moves into and out of All Mail

    @Test("Archiving an old Inbox message moves its row from the Inbox to All Mail")
    func archiveMovesRowToAllMail() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [Self.seed("archive-msg", labels: ["INBOX"])])
            defer { f.server.close() }
            try Self.insertRow("archive-msg", in: f.folder("INBOX"), pool: pool)

            f.server.applyLabelChange(providerMessageId: "archive-msg", remove: ["INBOX"])
            try await Self.runDelta(f)

            #expect(try Self.row("archive-msg", in: f.folder("INBOX"), pool: pool) == nil)
            #expect(try Self.row("archive-msg", in: f.folder(GmailProvider.archivePath), pool: pool) != nil,
                    "a message without INBOX, SENT, TRASH, SPAM or DRAFT is in All Mail")
        }
    }

    @Test("A message moved back to the Inbox leaves All Mail")
    func moveBackToInboxLeavesAllMail() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [Self.seed("return-msg", labels: [])])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("return-msg", in: allMail, pool: pool)

            f.server.applyLabelChange(providerMessageId: "return-msg", add: ["INBOX"])
            try await Self.runDelta(f)

            #expect(try Self.row("return-msg", in: f.folder("INBOX"), pool: pool) != nil)
            #expect(try Self.row("return-msg", in: allMail, pool: pool) == nil,
                    "an INBOX-labelled message is not in All Mail")
        }
    }

    @Test("A user label alone puts a message in All Mail and the label folder; SENT keeps it out of All Mail")
    func userLabelMembership() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [
                Self.seed("label-msg", labels: []),
                Self.seed("sent-label-msg", labels: ["SENT"]),
            ])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            let label = f.folder(Self.userLabelId)

            f.server.applyLabelChange(providerMessageId: "label-msg", add: [Self.userLabelId])
            f.server.applyLabelChange(providerMessageId: "sent-label-msg", add: [Self.userLabelId])
            try await Self.runDelta(f)

            #expect(try Self.row("label-msg", in: allMail, pool: pool) != nil)
            #expect(try Self.row("label-msg", in: label, pool: pool) != nil)
            #expect(try Self.row("sent-label-msg", in: label, pool: pool) != nil)
            #expect(try Self.row("sent-label-msg", in: allMail, pool: pool) == nil,
                    "a SENT-labelled message is not in All Mail, user label or not")
        }
    }

    // MARK: - Protections

    @Test("A pending move keeps the All Mail row the server would remove")
    func pendingMoveBlocksAllMailRemoval() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [
                Self.seed("guarded-msg", labels: []),
                Self.seed("twin-msg", labels: []),
            ])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("guarded-msg", in: allMail, pool: pool)
            try Self.insertRow("twin-msg", in: allMail, pool: pool)
            try Self.insertOp(.move, messageId: "guarded-msg", folderPath: allMail.path, pool: pool)

            f.server.applyLabelChange(providerMessageId: "guarded-msg", add: ["TRASH"])
            f.server.applyLabelChange(providerMessageId: "twin-msg", add: ["TRASH"])
            try await Self.runDelta(f)

            #expect(try Self.row("twin-msg", in: allMail, pool: pool) == nil,
                    "non-vacuity: the unprotected twin's All Mail row is removed")
            #expect(try Self.row("guarded-msg", in: allMail, pool: pool) != nil,
                    "a pending op owns the row until it drains")
        }
    }

    @Test("A pending destructive op stops the All Mail insert")
    func pendingDestructiveBlocksAllMailInsert() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [
                Self.seed("guarded-msg", labels: ["INBOX"]),
                Self.seed("twin-msg", labels: ["INBOX"]),
            ])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("guarded-msg", in: f.folder("INBOX"), pool: pool)
            try Self.insertRow("twin-msg", in: f.folder("INBOX"), pool: pool)
            try Self.insertOp(.delete, messageId: "guarded-msg", folderPath: "INBOX", pool: pool)

            f.server.applyLabelChange(providerMessageId: "guarded-msg", remove: ["INBOX"])
            f.server.applyLabelChange(providerMessageId: "twin-msg", remove: ["INBOX"])
            try await Self.runDelta(f)

            #expect(try Self.row("twin-msg", in: allMail, pool: pool) != nil,
                    "non-vacuity: the unprotected twin is inserted into All Mail")
            #expect(try Self.row("guarded-msg", in: allMail, pool: pool) == nil,
                    "a pending destructive op owns the identity, so no All Mail row appears")
        }
    }

    @Test("A recent completion stops the All Mail insert and the flag overwrite")
    func recentCompletionBlocksAllMailInsertAndFlagOverwrite() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [
                Self.seed("guarded-archive", labels: ["INBOX"]),
                Self.seed("twin-archive", labels: ["INBOX"]),
                Self.seed("guarded-read", labels: ["UNREAD"]),
                Self.seed("twin-read", labels: ["UNREAD"]),
            ])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("guarded-archive", in: f.folder("INBOX"), pool: pool)
            try Self.insertRow("twin-archive", in: f.folder("INBOX"), pool: pool)
            try Self.insertRow("guarded-read", in: allMail, isRead: false, pool: pool)
            try Self.insertRow("twin-read", in: allMail, isRead: false, pool: pool)
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["guarded-archive", "guarded-read"])

            f.server.applyLabelChange(providerMessageId: "guarded-archive", remove: ["INBOX"])
            f.server.applyLabelChange(providerMessageId: "twin-archive", remove: ["INBOX"])
            f.server.applyLabelChange(providerMessageId: "guarded-read", remove: ["UNREAD"])
            f.server.applyLabelChange(providerMessageId: "twin-read", remove: ["UNREAD"])
            try await Self.runDelta(f)

            #expect(try Self.row("twin-archive", in: allMail, pool: pool) != nil,
                    "non-vacuity: the unprotected twin is inserted into All Mail")
            #expect(try Self.row("twin-read", in: allMail, pool: pool)?.isRead == true,
                    "non-vacuity: the unprotected twin's read state is updated")
            #expect(try Self.row("guarded-archive", in: allMail, pool: pool) == nil,
                    "the server state just read is stale for a just-completed op")
            #expect(try Self.row("guarded-read", in: allMail, pool: pool)?.isRead == false,
                    "the server state just read is stale for a just-completed op")
        }
    }

    @Test("A pending flag op keeps the All Mail row's local flags")
    func pendingFlagOpBlocksAllMailFlagOverwrite() async throws {
        try await Self.withDatabase { pool in
            let f = try Self.makeFixture(pool: pool, seeds: [
                Self.seed("guarded-msg", labels: ["UNREAD"]),
                Self.seed("twin-msg", labels: ["UNREAD"]),
            ])
            defer { f.server.close() }
            let allMail = f.folder(GmailProvider.archivePath)
            try Self.insertRow("guarded-msg", in: allMail, isRead: false, pool: pool)
            try Self.insertRow("twin-msg", in: allMail, isRead: false, pool: pool)
            try Self.insertOp(.markUnread, messageId: "guarded-msg", folderPath: allMail.path, pool: pool)

            f.server.applyLabelChange(providerMessageId: "guarded-msg", remove: ["UNREAD"])
            f.server.applyLabelChange(providerMessageId: "twin-msg", remove: ["UNREAD"])
            try await Self.runDelta(f)

            #expect(try Self.row("twin-msg", in: allMail, pool: pool)?.isRead == true,
                    "non-vacuity: the unprotected twin's read state is updated")
            #expect(try Self.row("guarded-msg", in: allMail, pool: pool)?.isRead == false,
                    "the user's pending flag op wins over the server's flags")
        }
    }
}
