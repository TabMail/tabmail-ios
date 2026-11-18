/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
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

    private static func expectMarked(accountId: String, parentRfc822: String, pool: DatabasePool) throws {
        let (parent, ops) = try pool.read { db in
            (try MessageHeader.filter(Column("accountId") == accountId && Column("rfc822MessageId") == parentRfc822).fetchOne(db),
             try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db))
        }
        let row = try #require(parent, "precondition: the parent loaded")
        #expect(row.isReplied, "the parent loaded after its reply does not show as replied")
        #expect(row.actionTag == ActionTag.none, "the parent's Reply suggestion was not cleared (\(String(describing: row.actionTag)))")
        #expect(ops.contains { $0.type == .setTag && $0.tagValue == ActionTag.none.rawValue && $0.folderPath == row.folderPath },
                "the cleared tag was not queued for the server")
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

        _ = await engine.runBackfillWalk(account: account, deadline: F.deadline())

        try Self.expectMarked(accountId: accountId, parentRfc822: parentRfc822, pool: pool)
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

        _ = await engine.runBackfill(account: account, deadline: F.deadline())

        try Self.expectMarked(accountId: accountId, parentRfc822: parentRfc822, pool: pool)
    }

    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
