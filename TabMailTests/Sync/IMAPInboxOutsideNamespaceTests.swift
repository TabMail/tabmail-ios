/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// An IMAP account whose personal namespace prefix is not INBOX still gets an Inbox.
///
/// RFC 2342 §6 / RFC 3501 §5.1: INBOX always exists and need not sit inside the personal
/// namespace. A server announcing `(("Mail/" "/"))` answers `LIST "" "Mail/*"` without INBOX,
/// so a folder list built only from the namespace patterns has no inbox folder and the Inbox
/// is neither shown nor synced. These cases run the real `IMAPProvider` and a real full sync
/// against `FakeIMAPServer`, whose LIST filters by pattern like a real server.
///
/// Red-first: on the SwiftMail pin before the fix, the "Mail/" case has no INBOX folder (and
/// so no inbox role and no synced header); the "INBOX." case passes on both pins and guards
/// the deduplication.
@Suite("IMAP INBOX outside the personal namespace", .serialized)
struct IMAPInboxOutsideNamespaceTests {

    private static func rfc822(messageId: String) -> String {
        """
        From: Test Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: inbox-outside-namespace\r
        Date: \(rfc5322DateFormatter.string(from: Date()))\r
        Message-ID: <\(messageId)>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        inbox outside namespace body.\r

        """
    }

    private static let rfc5322DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private static func makeEngine(accountId: String, provider: IMAPProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
        return engine
    }

    /// Full sync of a fresh account against a server announcing `prefix`; returns the stored
    /// folders and the headers stored in the INBOX folder.
    private func syncFreshAccount(
        accountId: String, prefix: String, delimiter: String, otherMailbox: String
    ) async throws -> (folders: [Folder], inboxHeaders: [MessageHeader]) {
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [FakeIMAPServer.makeMessage(uid: 1, rfc822Text: Self.rfc822(messageId: "\(accountId)@example.com"))],
            otherMailbox: [],
        ])
        server.setHierarchy(delimiter: delimiter, personalNamespacePrefix: prefix)
        try server.start()
        defer { server.stop() }

        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        let provider = Self.provider(for: server)
        try await provider.connect()
        let engine = await Self.makeEngine(accountId: accountId, provider: provider)
        try await engine.fullSync(account: account, provider: provider)
        try? await provider.disconnect()

        return try await pool.read { db in
            let folders = try Folder.filter(Column("accountId") == accountId).fetchAll(db)
            let headers = try MessageHeader.filter(Column("folderId") == "\(accountId):INBOX").fetchAll(db)
            return (folders, headers)
        }
    }

    @Test("A Mail/ personal prefix still yields an Inbox folder that syncs")
    func mailPrefixYieldsSyncedInbox() async throws {
        let accountId = "inbox-ns-mail"
        let (folders, inboxHeaders) = try await syncFreshAccount(
            accountId: accountId, prefix: "Mail/", delimiter: "/", otherMailbox: "Mail/Sent")

        let inboxes = folders.filter { $0.role == .inbox }
        #expect(inboxes.count == 1, "exactly one folder carries the inbox role; got \(folders.map(\.path))")
        #expect(inboxes.first?.path == "INBOX")
        #expect(folders.contains { $0.path == "Mail/Sent" }, "the namespace folders are still listed")
        #expect(inboxHeaders.count == 1, "the inbox message is synced into the INBOX folder")
        #expect(inboxHeaders.filter { !$0.isInInbox }.isEmpty)
    }

    @Test("An INBOX. personal prefix lists INBOX once")
    func inboxPrefixListsInboxOnce() async throws {
        let accountId = "inbox-ns-inboxdot"
        let (folders, inboxHeaders) = try await syncFreshAccount(
            accountId: accountId, prefix: "INBOX.", delimiter: ".", otherMailbox: "INBOX.Sent")

        #expect(folders.filter { $0.path == "INBOX" }.count == 1)
        #expect(folders.filter { $0.role == .inbox }.count == 1)
        #expect(inboxHeaders.count == 1)
    }
}
