/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Each text message belongs to its AI result (ADR-IOS-103): it is stored, replaced and restored
/// together with that result, never kept from an older one.
@Suite("AI text messages: schema, cache write-through and restore")
struct AITextMessageStorageTests {

    private func columns(_ db: DatabaseQueue, _ table: String) throws -> Set<String> {
        try db.read { db in Set(try db.columns(in: table).map(\.name)) }
    }

    @Test("v95 adds both text-message columns to messageHeader and messageAICache")
    func migrationAddsColumns() throws {
        let db = try TestDatabase.make()
        for table in ["messageHeader", "messageAICache"] {
            let cols = try columns(db, table)
            #expect(cols.contains("summaryTextMessage"), "\(table)")
            #expect(cols.contains("replyTextMessage"), "\(table)")
        }
        let applied = try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v95_addAITextMessages"))
    }

    @Test("The header round-trips both text messages")
    func headerRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        var header = try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "rt@example.com")
        header.summaryTextMessage = "Summary text"
        header.replyTextMessage = "Reply text"
        try db.write { [header] in try header.update($0) }
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.summaryTextMessage == "Summary text")
        #expect(fetched?.replyTextMessage == "Reply text")
    }

    private func entry(_ db: DatabaseQueue, _ rfc: String) throws -> MessageAICache? {
        try db.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:\(rfc)") }
    }

    @Test("writeThrough stores the text message with its summary and replaces it with the next summary")
    func summaryTextMessageFollowsSummary() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "s@example.com",
                                            summaryBlurb: "First", summaryTextMessage: "First text", db: $0)
        }
        #expect(try entry(db, "s@example.com")?.summaryTextMessage == "First text")

        // A write that does not touch the summary keeps the text message.
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "s@example.com",
                                            actionTag: .reply, db: $0)
        }
        #expect(try entry(db, "s@example.com")?.summaryTextMessage == "First text")

        // A new summary without a text message (a peer's) does not keep the old one.
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "s@example.com",
                                            summaryBlurb: "Peer", db: $0)
        }
        let after = try entry(db, "s@example.com")
        #expect(after?.summaryBlurb == "Peer")
        #expect(after?.summaryTextMessage == nil)
        #expect(after?.actionTag == .reply)
    }

    @Test("writeThrough stores the text message with its reply and replaces it with the next reply")
    func replyTextMessageFollowsReply() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            cachedReply: "Body one", replyTextMessage: "Text one", db: $0)
        }
        #expect(try entry(db, "r@example.com")?.replyTextMessage == "Text one")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            summaryBlurb: "Summary", db: $0)
        }
        #expect(try entry(db, "r@example.com")?.replyTextMessage == "Text one")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            cachedReply: "Body two", db: $0)
        }
        let after = try entry(db, "r@example.com")
        #expect(after?.cachedReply == "Body two")
        #expect(after?.replyTextMessage == nil)
    }

    @Test("restoreIfCached restores each text message with its result")
    func restoreCarriesTextMessages() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "x@example.com",
                                            summaryBlurb: "Summary", summaryTextMessage: "Summary text",
                                            cachedReply: "Reply", replyTextMessage: "Reply text", db: $0)
        }
        var header = MessageHeader(
            messageId: "7", subject: "S", from: "a@example.com", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.rfc822MessageId = "x@example.com"
        try db.write { try MessageAICache.restoreIfCached(into: &header, accountId: "acc1", folderPath: "INBOX", db: $0) }
        #expect(header.summaryBlurb == "Summary")
        #expect(header.summaryTextMessage == "Summary text")
        #expect(header.cachedReply == "Reply")
        #expect(header.replyTextMessage == "Reply text")
    }

    @Test("restoreIfCached does not graft a cached text message onto the header's own result")
    func restoreKeepsHeaderResult() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "y@example.com",
                                            summaryBlurb: "Cached", summaryTextMessage: "Cached text",
                                            cachedReply: "Cached reply", replyTextMessage: "Cached reply text", db: $0)
        }
        var header = MessageHeader(
            messageId: "8", subject: "S", from: "a@example.com", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.rfc822MessageId = "y@example.com"
        header.summaryBlurb = "Own"
        header.cachedReply = "Own reply"
        try db.write { try MessageAICache.restoreIfCached(into: &header, accountId: "acc1", folderPath: "INBOX", db: $0) }
        #expect(header.summaryBlurb == "Own")
        #expect(header.summaryTextMessage == nil)
        #expect(header.cachedReply == "Own reply")
        #expect(header.replyTextMessage == nil)
    }

    // MARK: - Upgrading a database that has AI results

    /// A database file migrated up to `migration`, as an older build left it.
    private static func migrated(upTo migration: String) throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitext_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(pool, upTo: migration)
        return (pool, dir)
    }

    /// Insert `record` with only the columns the table has at this (older) schema.
    private static func insertAtOldSchema<R: EncodableRecord & TableRecord>(_ record: R, _ db: Database) throws {
        let table = R.databaseTableName
        let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
        let values = try record.databaseDictionary.filter { columns.contains($0.key) }
        let names = values.keys.sorted()
        try db.execute(
            sql: "INSERT INTO \(table) (\(names.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(names.map { values[$0]! }))
    }

    private static func header(_ uid: String, folder: String, rfc: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Sender", fromAddress: "sender@example.com",
            to: "acc1@example.com", date: Date(), snippet: "snippet", folderId: "acc1:\(folder)",
            accountId: "acc1", folderPath: folder, isInInbox: folder == "INBOX")
        header.rfc822MessageId = rfc
        header.summaryBlurb = "Old summary"
        header.cachedReply = "Old reply"
        return header
    }

    private static func cacheEntry(_ key: String, rfc: String?, daysAgo: Int) -> MessageAICache {
        var entry = MessageAICache(key: key, rfc822MessageId: rfc)
        entry.summaryBlurb = "Old summary"
        entry.cachedReply = "Old reply"
        entry.updatedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return entry
    }

    @Test("Upgrading a database with AI results keeps them, every text message empty until asked for")
    func upgradeKeepsResults() throws {
        let (pool, dir) = try Self.migrated(upTo: "v94_addDraftServerCopyNamesParent")
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        try pool.write { db in
            var account = Account(emailAddress: "acc1@example.com", displayName: "A", provider: .imap)
            account.id = "acc1"
            try Self.insertAtOldSchema(account, db)
            try Self.insertAtOldSchema(Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1"), db)
            try Self.insertAtOldSchema(Self.header("1", folder: "INBOX", rfc: "plans@example.com"), db)
            try Self.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:plans@example.com", rfc: "plans@example.com", daysAgo: 0), db)
        }

        try AppDatabase.runMigrations(on: pool)

        let header = try pool.read { try MessageHeader.fetchOne($0, key: MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "1")) }
        #expect(header?.summaryBlurb == "Old summary")
        #expect(header?.cachedReply == "Old reply")
        #expect(header?.summaryTextMessage == nil)
        #expect(header?.replyTextMessage == nil)
        let entry = try pool.read { try MessageAICache.fetchOne($0, key: "acc1:INBOX:plans@example.com") }
        #expect(entry?.summaryBlurb == "Old summary")
        #expect(entry?.cachedReply == "Old reply")
        #expect(entry?.summaryTextMessage == nil)
        #expect(entry?.replyTextMessage == nil)
    }

    @Test("An older build's entries without a Message-ID survive the upgrade and the purge while their email is here")
    func legacyEntriesSurviveUpgradeAndPurge() throws {
        let (pool, dir) = try Self.migrated(upTo: "v95_addAITextMessages")
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let aged = SyncConfig.aiCacheOrphanGraceDays + 1
        try pool.write { db in
            var account = Account(emailAddress: "acc1@example.com", displayName: "A", provider: .imap)
            account.id = "acc1"
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
            try Self.header("1", folder: "INBOX", rfc: "stayed@example.com").insert(db)
            try Self.header("2", folder: "Archive", rfc: "moved@example.com").insert(db)
            // Written by an older extension, without the Message-ID.
            try Self.cacheEntry("acc1:INBOX:stayed@example.com", rfc: nil, daysAgo: aged).insert(db)
            try Self.cacheEntry("acc1:INBOX:moved@example.com", rfc: nil, daysAgo: aged).insert(db)
            try Self.cacheEntry("acc1:INBOX:gone@example.com", rfc: nil, daysAgo: aged).insert(db)
        }

        try AppDatabase.runMigrations(on: pool)
        SyncEngine.runPurgeOrphanedAICache(dbPool: PrioritizedDatabase(pool: pool, priority: .background))

        let keys = try pool.read { db in Set(try MessageAICache.fetchAll(db).map(\.key)) }
        #expect(keys == ["acc1:INBOX:stayed@example.com", "acc1:INBOX:moved@example.com"])
        let applied = try pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v96_repairAICacheMessageIds"))
    }
}
