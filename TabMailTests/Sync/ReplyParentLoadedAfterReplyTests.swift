/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// A reply the user sent is already stored in Sent (its folder's walk is
/// complete), and the message it answers loads later, through the backfill
/// walk of another folder. The parent must then show as replied, its "Reply"
/// suggestion cleared and that clear queued for the server, as it would had
/// the parent been stored first. Pinned on the IMAP UID walk and the Gmail
/// page walk.
///
/// `.serialized, .processGlobalState`: replaces `AppDatabase.shared`, binds
/// listening sockets.
@Suite("Backfill — a parent loaded after its stored reply is marked replied", .serialized, .processGlobalState)
struct ReplyParentLoadedAfterReplyTests {
    private typealias F = BackfillPageWalkFixture

    /// Store a reply in the account's Sent folder whose In-Reply-To names
    /// `parentRfc822`, and an AI-cache entry that tags the parent "Reply" in
    /// `parentPath` when it is inserted.
    private static func seedReplyAndTag(
        accountId: String, sentPath: String, parentPath: String, parentRfc822: String, pool: DatabasePool
    ) throws {
        try pool.write { db in
            var sent = Folder(name: sentPath, path: sentPath, role: .sent, accountId: accountId)
            sent.backfillComplete = true
            try sent.insert(db)
            var reply = MessageHeader(
                messageId: "9001", subject: "Re: the parent", from: "Me",
                fromAddress: "me@example.com", to: "sender@example.com",
                date: Date(), snippet: "my reply",
                folderId: sent.id, accountId: accountId, folderPath: sentPath, isInInbox: false)
            reply.rfc822MessageId = "reply-loaded-first@example.com"
            reply.inReplyTo = parentRfc822
            try reply.insert(db)
            let key = try #require(MessageAICache.cacheKey(
                accountId: accountId, folderPath: parentPath, rfc822MessageId: parentRfc822))
            var cache = MessageAICache(key: key, rfc822MessageId: parentRfc822)
            cache.actionTag = .reply
            try cache.insert(db)
        }
    }

    /// Collects the header ids announced with `.messageDataDidChange` while alive.
    final class Announced: @unchecked Sendable {
        private final class Box: Sendable { let ids = Mutex<Set<String>>([]) }
        private let box = Box()
        private var token: (any NSObjectProtocol)?
        init() {
            let box = self.box
            token = NotificationCenter.default.addObserver(forName: .messageDataDidChange, object: nil, queue: nil) { note in
                if let id = note.object as? String { _ = box.ids.withLock { $0.insert(id) } }
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
        func contains(_ id: String) -> Bool { box.ids.withLock { $0.contains(id) } }
    }

    private static func expectMarked(
        accountId: String, parentRfc822: String, pool: DatabasePool, announced: (String) -> Bool
    ) throws {
        let (parent, ops) = try pool.read { db in
            (try MessageHeader.filter(Column("accountId") == accountId && Column("rfc822MessageId") == parentRfc822).fetchOne(db),
             try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db))
        }
        let row = try #require(parent, "precondition: the parent loaded")
        #expect(row.isReplied, "the parent loaded after its reply does not show as replied")
        #expect(row.actionTag == ActionTag.none, "the parent's Reply suggestion was not cleared (\(String(describing: row.actionTag)))")
        #expect(ops.contains { $0.type == .setTag && $0.tagValue == ActionTag.none.rawValue
                    && $0.folderPath == row.folderPath && $0.messageIds == [row.stableId] },
                "the cleared tag was not queued for the server: \(ops.map { ($0.type, $0.folderPath, $0.messageIds) })")
        #expect(announced(row.id), "the parent's change was not announced")
    }

    @Test("IMAP UID walk: a parent loaded after its stored reply is marked replied")
    func parentLoadedAfterItsStoredReplyIsMarkedRepliedIMAP() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "reply-first-imap"
        let parentRfc822 = "parent-loaded-later@example.com"
        let epoch = 4_242
        let message = FakeIMAPServer.makeMessage(uid: 7, rfc822Text: """
            From: Test Sender <sender@example.com>\r
            To: Me <me@example.com>\r
            Subject: the parent\r
            Date: \(Self.rfc2822(Date().addingTimeInterval(-3_600)))\r
            Message-ID: <\(parentRfc822)>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            parent body.\r

            """)
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Sent": []])
        server.setUidValidity(epoch, for: "INBOX")
        server.honorSearchUIDSetCriterion()
        try server.start()
        defer { server.stop() }
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try Self.seedReplyAndTag(accountId: accountId, sentPath: "Sent", parentPath: "INBOX",
                                 parentRfc822: parentRfc822, pool: pool)
        try await pool.write { db in
            var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            inbox.backfillComplete = false
            inbox.backfillUidCursor = 7
            inbox.lastKnownUidValidity = epoch
            try inbox.insert(db)
        }
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await imap.connect()
        defer { Task { try? await imap.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

        let announced = Announced()
        _ = await engine.runBackfillWalk(account: account, deadline: F.deadline())

        try Self.expectMarked(accountId: accountId, parentRfc822: parentRfc822, pool: pool, announced: announced.contains)
    }

    @Test("Gmail page walk: a parent loaded after its stored reply is marked replied")
    func parentLoadedAfterItsStoredReplyIsMarkedRepliedGmail() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "reply-first-gmail"
        let parentRfc822 = "gparent@example.com"
        let server = StatefulGmailActionServer(messages: [F.gmailSeed("gparent", label: "INBOX", daysAgo: 1)])
        defer { server.close() }
        server.servePagedListings(pageSize: F.pageSize)
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try Self.seedReplyAndTag(accountId: accountId, sentPath: "SENT", parentPath: "INBOX",
                                 parentRfc822: parentRfc822, pool: pool)
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        let announced = Announced()
        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        try Self.expectMarked(accountId: accountId, parentRfc822: parentRfc822, pool: pool, announced: announced.contains)
    }

    @Test("Full sync: a parent loaded after its stored reply is marked replied")
    func parentLoadedAfterItsStoredReplyIsMarkedRepliedFullSync() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "reply-first-fullsync"
        let parentRfc822 = "fullsync-parent@example.com"
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try Self.seedReplyAndTag(accountId: accountId, sentPath: "Sent", parentPath: "INBOX",
                                 parentRfc822: parentRfc822, pool: pool)
        let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([Self.parentInfo(uid: "7", rfc822: parentRfc822)])

        // `runSyncMessages` hands the ids to announce to its caller, which posts them.
        let result = try await SyncEngine.runSyncMessages(
            for: inbox, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        try Self.expectMarked(accountId: accountId, parentRfc822: parentRfc822, pool: pool,
                              announced: { result.replyDetectIds.contains($0) })
    }

    @Test("Scroll to older mail: a parent loaded after its stored reply is marked replied")
    func parentLoadedAfterItsStoredReplyIsMarkedRepliedScroll() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let accountId = "reply-first-scroll"
        let parentRfc822 = "scrollparent@example.com"
        let server = StatefulGmailActionServer(messages: [
            F.gmailSeed("anchor", label: "INBOX", daysAgo: 1),
            F.gmailSeed("scrollparent", label: "INBOX", daysAgo: 5),
        ])
        defer { server.close() }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try F.insertHeader("anchor", accountId: accountId, path: "INBOX", pool: pool)
        try await pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET providerDate = date WHERE messageId = 'anchor'")
        }
        try Self.seedReplyAndTag(accountId: accountId, sentPath: "SENT", parentPath: "INBOX",
                                 parentRfc822: parentRfc822, pool: pool)
        let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
        let engine = await F.registeredEngine(accountId: accountId, provider: server.provider())

        let announced = Announced()
        _ = try await engine.fetchOlderMessages(folders: [inbox])

        try Self.expectMarked(accountId: accountId, parentRfc822: parentRfc822, pool: pool, announced: announced.contains)
    }

    private static func parentInfo(uid: String, rfc822: String) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: uid, rfc822MessageId: rfc822, inReplyTo: nil, references: [],
            threadId: nil, subject: "the parent", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: Date().addingTimeInterval(-3_600), snippet: "parent",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
