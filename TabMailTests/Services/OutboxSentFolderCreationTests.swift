/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The system property: a message the server accepted for delivery leaves the
/// sender a copy in a Sent folder on their IMAP server, even when the account
/// has no local Sent row. The SERVER's Sent folder (by SPECIAL-USE or by name)
/// takes the copy; only when the server has none is a folder named "Sent"
/// created in the personal namespace, so an existing Sent folder never gets a
/// duplicate beside it. The outbox row is finished only once that copy exists.
///
/// Each case runs the real outbox drain (`AccountManager.drainOutbox`, its
/// pending-Sent-append phase) and the real `IMAPProvider` against
/// `FakeIMAPServer` in the mode where, as on a real server, SELECT and APPEND
/// refuse a mailbox that does not exist, so only CREATE can make one.
///
/// `.serialized` + `.processGlobalState`: each case rebinds the process-global
/// `AppDatabase.shared` the drain writes through. example.com addresses only;
/// every instant derives from `Date()`.
@Suite("Outbox Sent copy when the account has no Sent folder", .serialized, .processGlobalState)
struct OutboxSentFolderCreationTests {

    // MARK: - Fixture

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    /// A temporary database installed as `AppDatabase.shared`, holding one IMAP
    /// account and its Inbox, plus a Sent row only when `sentFolderPath` is given
    /// and an ordinary (`.custom`) row for each of `customFolderPaths`.
    private func makeFixture(sentFolderPath: String? = nil, customFolderPaths: [String] = []) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }
        let account = Account(
            emailAddress: "sent-\(UUID().uuidString.lowercased())@example.com",
            displayName: "Sender", provider: .imap)
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id).insert(db)
            if let sentFolderPath {
                try Folder(name: sentFolderPath, path: sentFolderPath, role: .sent, accountId: account.id).insert(db)
            }
            for path in customFolderPaths {
                try Folder(name: path, path: path, role: .custom, accountId: account.id).insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: account.id)
    }

    private func finish(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    /// A message SMTP already accepted whose Sent copy is still owed: the state
    /// the outbox drain's pending-Sent-append phase picks up.
    private func seedSentAwaitingCopy(_ fixture: Fixture) throws -> (outboxId: String, messageId: String) {
        let messageId = "<\(UUID().uuidString)@example.com>"
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "Sent copy", body: "Body of the send")
        var message = OutboxMessage(accountId: fixture.accountId, draft: draft)
        message.status = OutboxStatus.sending.rawValue
        message.sentAt = Date().addingTimeInterval(-60)
        message.sentMessageId = messageId
        message.appendedToSent = false
        message.holdUntil = Date().addingTimeInterval(-3600)
        let seeded = message
        try fixture.pool.write { db in try seeded.insert(db) }
        return (seeded.id, messageId)
    }

    private func outboxRow(_ fixture: Fixture, _ id: String) throws -> OutboxMessage? {
        try fixture.pool.read { db in try OutboxMessage.fetchOne(db, key: id) }
    }

    private static func strictServer(
        mailboxes: [String: [FakeIMAPServer.Message]],
        capabilities: [String] = FakeIMAPServer.defaultCapabilities
    ) -> FakeIMAPServer {
        let server = FakeIMAPServer(
            username: "sent-\(UUID().uuidString.lowercased())", capabilities: capabilities, mailboxes: mailboxes)
        server.requireExistingMailboxes()
        return server
    }

    /// Runs one outbox drain with a connected `IMAPProvider` for the fixture's
    /// account, against `server`.
    private func drainOutbox(_ fixture: Fixture, against server: FakeIMAPServer) async throws {
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        await TestProviderRegistry.withRegisteredProvider(accountId: fixture.accountId, provider: provider) {
            await AccountManager.shared.drainOutbox()
        }
        try? await provider.disconnect()
    }

    /// `mailbox` holds exactly one message, the one with `messageId`
    /// (compared with or without angle brackets).
    private static func holdsOnly(_ server: FakeIMAPServer, _ mailbox: String, _ messageId: String) -> Bool {
        server.messageIDs(in: mailbox).count == 1
            && server.flags(in: mailbox, rfc822MessageId: messageId) != nil
    }

    private static func createCommands(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter { $0.uppercased().hasPrefix("CREATE") }
    }

    // MARK: - Cases

    /// RED-FIRST: before the fix the drain found no Sent row, marked the copy
    /// as made without asking the server, and finished the row, so the sender
    /// kept no copy anywhere.
    @Test("No Sent folder: a Sent folder is created and the sent message's copy goes into it")
    func noSentFolderCreatesSentAndKeepsTheCopy() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let (outboxId, messageId) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(mailboxes: ["INBOX": [], "Projects": []])
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(server.mailboxExists("Sent"), "no Sent folder was created on the server")
        #expect(Self.holdsOnly(server, "Sent", messageId), "the sent message's copy is not in the new Sent folder")
        #expect(Self.createCommands(server).count == 1, "exactly one CREATE: \(Self.createCommands(server))")
        #expect(try outboxRow(fixture, outboxId) == nil, "the row was not finished once its copy was kept")
    }

    /// RED-FIRST: a server that keeps every folder under INBOX gets the new
    /// folder in its personal namespace (`INBOX.Sent`), where the next folder
    /// sync gives it the Sent role by name.
    @Test("No Sent folder on a server that keeps folders under INBOX: INBOX.Sent is created and holds the copy")
    func noSentFolderUnderInboxNamespaceCreatesInboxSent() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let (outboxId, messageId) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(mailboxes: ["INBOX": [], "INBOX.Projects": []])
        server.setHierarchy(delimiter: ".", personalNamespacePrefix: "INBOX.")
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(server.mailboxExists("INBOX.Sent"), "no Sent folder was created in the INBOX. namespace")
        #expect(!server.mailboxExists("Sent"), "the folder was created outside the personal namespace")
        #expect(Self.holdsOnly(server, "INBOX.Sent", messageId))
        #expect(try outboxRow(fixture, outboxId) == nil)
    }

    /// RED-FIRST: the server already has a "Sent" folder the account holds no
    /// Sent row for (an earlier send created it before a folder sync saw it, or
    /// the first send runs before the first folder sync). The server is asked
    /// first, so no CREATE is sent and the copy lands in that folder.
    @Test("A Sent folder the account has no row for: no CREATE, and the copy lands there")
    func existingUnroledSentFolderTakesTheCopy() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let (outboxId, messageId) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(mailboxes: ["INBOX": [], "Sent": []])
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(Self.createCommands(server).isEmpty, "a CREATE was sent although the server has a Sent folder")
        #expect(Self.holdsOnly(server, "Sent", messageId))
        #expect(try outboxRow(fixture, outboxId) == nil)
    }

    /// RED-FIRST: an existing account on a server that keeps folders under
    /// INBOX and sends no special-use attributes. Its Sent folder
    /// `INBOX.Sent Items` was stored as an ordinary folder before such names
    /// were recognised, and folder sync never rewrites a stored role, so the
    /// account still has no Sent row. The copy must go into the server's real
    /// Sent folder: creating `INBOX.Sent` beside it would leave the user a
    /// second Sent folder, visible in every mail client.
    @Test("A Sent folder stored as an ordinary folder takes the copy; no second Sent folder is created")
    func sentFolderStoredAsCustomTakesTheCopy() async throws {
        let fixture = try makeFixture(customFolderPaths: ["INBOX.Sent Items"])
        defer { finish(fixture) }
        let (outboxId, messageId) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(mailboxes: ["INBOX": [], "INBOX.Sent Items": []])
        server.setHierarchy(delimiter: ".", personalNamespacePrefix: "INBOX.")
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(Self.createCommands(server).isEmpty, "a CREATE was sent although the server has a Sent folder")
        #expect(!server.mailboxExists("INBOX.Sent"), "a second Sent folder was created beside the real one")
        #expect(Self.holdsOnly(server, "INBOX.Sent Items", messageId), "the copy is not in the server's Sent folder")
        #expect(try outboxRow(fixture, outboxId) == nil)
    }

    /// RED-FIRST: a server that advertises SPECIAL-USE and marks its
    /// non-English Sent folder `\Sent` only on `LIST ... RETURN (SPECIAL-USE)`
    /// (RFC 6154 §2). The account's row for it is ordinary, as stored before
    /// the RETURN listing was read. The copy goes to that folder; no CREATE.
    @Test("A Sent folder only RETURN (SPECIAL-USE) marks takes the copy; no CREATE")
    func specialUseSentFolderTakesTheCopy() async throws {
        let fixture = try makeFixture(customFolderPaths: ["Envoyes"])
        defer { finish(fixture) }
        let (outboxId, messageId) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(
            mailboxes: ["INBOX": [], "Envoyes": []],
            capabilities: FakeIMAPServer.defaultCapabilities + ["SPECIAL-USE"])
        server.setSpecialUse("\\Sent", for: "Envoyes", onPlainList: false)
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(Self.createCommands(server).isEmpty, "a CREATE was sent although the server marks a folder \\Sent")
        #expect(!server.mailboxExists("Sent"), "a second Sent folder was created beside the real one")
        #expect(Self.holdsOnly(server, "Envoyes", messageId), "the copy is not in the server's Sent folder")
        #expect(try outboxRow(fixture, outboxId) == nil)
    }

    /// RED-FIRST: when the folder cannot be created and does not exist, no copy
    /// was kept, so the row must stay owed (retried on a later drain), not be
    /// finished as if the copy existed.
    @Test("A Sent folder that cannot be created leaves the copy owed, not marked done")
    func failedCreateKeepsTheCopyOwed() async throws {
        let fixture = try makeFixture()
        defer { finish(fixture) }
        let (outboxId, _) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(mailboxes: ["INBOX": []])
        server.failCommand(containing: "CREATE", onMatch: 1, message: "Quota exceeded")
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(!server.mailboxExists("Sent"))
        let row = try outboxRow(fixture, outboxId)
        #expect(row != nil, "the row was finished although no Sent copy exists")
        #expect(row?.appendedToSent == false, "the copy was recorded as made although it was not")
        #expect(row?.sentAt != nil)
    }

    /// Guard: an account that has a Sent folder never sends CREATE.
    @Test("An account with a Sent folder appends to it and never creates one")
    func existingSentRowNeverCreates() async throws {
        let fixture = try makeFixture(sentFolderPath: "Sent Items")
        defer { finish(fixture) }
        let (outboxId, messageId) = try seedSentAwaitingCopy(fixture)
        let server = Self.strictServer(mailboxes: ["INBOX": [], "Sent Items": []])
        try server.start()
        defer { server.stop() }

        try await drainOutbox(fixture, against: server)

        #expect(Self.createCommands(server).isEmpty, "a CREATE was sent for an account that has a Sent folder")
        #expect(Self.holdsOnly(server, "Sent Items", messageId))
        #expect(!server.mailboxExists("Sent"))
        #expect(try outboxRow(fixture, outboxId) == nil)
    }
}
