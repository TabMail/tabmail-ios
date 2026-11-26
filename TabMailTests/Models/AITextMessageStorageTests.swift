/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Each text message belongs to its AI result (ADR-IOS-114): it is stored, replaced and restored
/// together with that result, never kept from an older one.
@Suite("AI text messages: schema, cache write-through and restore")
struct AITextMessageStorageTests {

    private func columns(_ db: DatabaseQueue, _ table: String) throws -> Set<String> {
        try db.read { db in Set(try db.columns(in: table).map(\.name)) }
    }

    @Test("v105 adds both text-message columns to messageHeader and messageAICache")
    func migrationAddsColumns() throws {
        let db = try TestDatabase.make()
        for table in ["messageHeader", "messageAICache"] {
            let cols = try columns(db, table)
            #expect(cols.contains("summaryTextMessage"), "\(table)")
            #expect(cols.contains("replyTextMessage"), "\(table)")
        }
        let applied = try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v105_addAITextMessages"))
        // The chat view's migrations are numbered after main's newest (v104) and run in that order.
        let order = [
            "v103_addFolderChangeCursor", "v104_addReplyAllAndMarkSentAt",
            "v105_addAITextMessages", "v106_repairAICacheMessageIds",
            "v107_rekeyChatSessionsByThread", "v108_addReplyChangeCommand",
        ]
        #expect(applied.filter { order.contains($0) } == order)
    }

    @Test("v109 (the chat field's words) registers right after v108: an install at v108 with a stored change command upgrades to the words table and keeps the command")
    func chatFieldWordsFollowsReplyChangeCommand() throws {
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        // Registration order, which is the order an upgrade runs them (the ledger's own listing is
        // not: it can come back sorted by name).
        let identifiers = migrator.migrations
        let v108 = try #require(identifiers.firstIndex(of: "v108_addReplyChangeCommand"))
        let v109 = try #require(identifiers.firstIndex(of: "v109_addChatFieldWords"))
        #expect(v109 == v108 + 1, "v109 registers right after v108: \(identifiers.suffix(4))")

        // A device on the release with v108: a reply's change command is stored.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(db, upTo: "v108_addReplyChangeCommand")
        let wordsAtV108 = try db.read { try $0.tableExists("chatFieldWords") }
        #expect(!wordsAtV108, "control: the words table is not there before v109")
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "cmd@example.com")
        try db.write {
            try $0.execute(sql: "UPDATE messageHeader SET replyChangeCommand = ? WHERE id = ?",
                           arguments: ["ask for the agenda", header.id])
        }

        // The upgrade.
        try migrator.migrate(db)
        let wordsAfter = try db.read { try $0.tableExists("chatFieldWords") }
        #expect(wordsAfter, "the upgrade adds the words table")
        let command = try db.read {
            try String.fetchOne($0, sql: "SELECT replyChangeCommand FROM messageHeader WHERE id = ?", arguments: [header.id])
        }
        #expect(command == "ask for the agenda", "the stored change command is kept")
        try db.write {
            try ChatFieldWordsRecord(sessionId: "thread:acc1:t1", words: "Unsent words", updatedAt: Date()).insert($0)
        }
        let words = try db.read { try ChatFieldWordsRecord.fetchOne($0, key: "thread:acc1:t1")?.words }
        #expect(words == "Unsent words", "the new table takes a chat's words")
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

    @Test("v108 adds the change command column to messageHeader and messageAICache")
    func migrationAddsChangeCommand() throws {
        let db = try TestDatabase.make()
        for table in ["messageHeader", "messageAICache"] {
            #expect(try columns(db, table).contains("replyChangeCommand"), "\(table)")
        }
    }

    @Test("The change command follows its reply through the cache: stored, kept, replaced, restored")
    func changeCommandFollowsReply() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "c@example.com",
                                            reply: ReplyResult(body: "Body one", textMessage: "Text one", changeCommand: "say no"), db: $0)
        }
        #expect(try entry(db, "c@example.com")?.replyChangeCommand == "say no")
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "c@example.com",
                                            summaryBlurb: "Summary", db: $0)
        }
        #expect(try entry(db, "c@example.com")?.replyChangeCommand == "say no", "a summary leaves the reply's command")

        var header = MessageHeader(
            messageId: "9", subject: "S", from: "a@example.com", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        header.rfc822MessageId = "c@example.com"
        try db.write { try MessageAICache.restoreIfCached(into: &header, accountId: "acc1", folderPath: "INBOX", db: $0) }
        #expect(header.cachedReply == "Body one")
        #expect(header.replyChangeCommand == "say no")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "c@example.com",
                                            reply: ReplyResult(body: "Body two", textMessage: nil), db: $0)
        }
        #expect(try entry(db, "c@example.com")?.replyChangeCommand == nil, "a new reply never keeps an older reply's command")
    }

    @Test("writeThrough stores the text message with its reply and replaces it with the next reply")
    func replyTextMessageFollowsReply() throws {
        let db = try TestDatabase.make()
        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            reply: ReplyResult(body: "Body one", textMessage: "Text one"), db: $0)
        }
        #expect(try entry(db, "r@example.com")?.replyTextMessage == "Text one")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            summaryBlurb: "Summary", db: $0)
        }
        #expect(try entry(db, "r@example.com")?.replyTextMessage == "Text one")

        try db.write {
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "r@example.com",
                                            reply: ReplyResult(body: "Body two", textMessage: nil), db: $0)
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
                                            reply: ReplyResult(body: "Reply", textMessage: "Reply text"), db: $0)
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
                                            reply: ReplyResult(body: "Cached reply", textMessage: "Cached reply text"), db: $0)
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
            try TestDatabase.insertAtOldSchema(account, db)
            try TestDatabase.insertAtOldSchema(Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1"), db)
            try TestDatabase.insertAtOldSchema(Self.header("1", folder: "INBOX", rfc: "plans@example.com"), db)
            try TestDatabase.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:plans@example.com", rfc: "plans@example.com", daysAgo: 0), db)
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

    @Test("An older build's entries without a Message-ID: the upgrade fills the ones whose email is where the key says, and the purge keeps only those")
    func legacyEntriesSurviveUpgradeAndPurge() async throws {
        let (pool, dir) = try Self.migrated(upTo: "v105_addAITextMessages")
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let aged = SyncConfig.aiCacheOrphanGraceDays + 1
        try await pool.write { db in
            var account = Account(emailAddress: "acc1@example.com", displayName: "A", provider: .imap)
            account.id = "acc1"
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
            try TestDatabase.insertAtOldSchema(Self.header("1", folder: "INBOX", rfc: "stayed@example.com"), db)
            try TestDatabase.insertAtOldSchema(Self.header("2", folder: "Archive", rfc: "moved@example.com"), db)
            // Written by an older extension, without the Message-ID.
            try TestDatabase.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:stayed@example.com", rfc: nil, daysAgo: aged), db)
            try TestDatabase.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:moved@example.com", rfc: nil, daysAgo: aged), db)
            try TestDatabase.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:gone@example.com", rfc: nil, daysAgo: aged), db)
        }

        try AppDatabase.runMigrations(on: pool)

        // The upgrade fills the Message-ID of the entry whose email is in the folder its key
        // names. The moved email's entry and the gone email's entry stay without one.
        let ids = try await pool.read { db in
            Dictionary(uniqueKeysWithValues: try MessageAICache.fetchAll(db).map { ($0.key, $0.rfc822MessageId) })
        }
        #expect(ids["acc1:INBOX:stayed@example.com"] == .some("stayed@example.com"))
        #expect(ids["acc1:INBOX:moved@example.com"] == .some(nil))
        #expect(ids["acc1:INBOX:gone@example.com"] == .some(nil))
        // A Device Sync peer asks by Message-ID (`RootView`'s probe handler), which still
        // answers once the header is gone. The deletion is rolled back for the purge below.
        let probeBlurb = try await pool.write { db -> String? in
            var probe: MessageAICache?
            try db.inSavepoint {
                _ = try MessageHeader.deleteOne(db, key: MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "1"))
                probe = try MessageAICache.filter(Column("rfc822MessageId") == "stayed@example.com").fetchOne(db)
                return .rollback
            }
            return probe?.summaryBlurb
        }
        #expect(probeBlurb == "Old summary")

        await SyncEngine.runPurgeOrphanedAICache(dbPool: PrioritizedDatabase(pool: pool, priority: .background), checkpointWAL: {})

        let keys = try await pool.read { db in Set(try MessageAICache.fetchAll(db).map(\.key)) }
        // The moved email's entry has no Message-ID: an orphan, made again if ever needed.
        #expect(keys == ["acc1:INBOX:stayed@example.com"])
        let applied = try await pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v106_repairAICacheMessageIds"))
    }

    /// Storage maintenance runs `ANALYZE` once per schema change, so a device upgrading to
    /// v106 can hold planner statistics for a cache with many entries that have no Message-ID.
    /// `sqlite_stat1` keeps one average per index column, so those statistics call
    /// `rfc822MessageId IS NULL` a near-unique lookup. The repair must still scan the headers once
    /// and look each one up in the cache by key; with the cache as the outer loop it scans every
    /// header once per such entry, minutes on a large mailbox before any screen appears.
    @Test("v106 scans the headers once and looks each up in the cache by key, with planner statistics for many entries without a Message-ID")
    func repairPlanWithStatistics() throws {
        let (pool, dir) = try Self.migrated(upTo: "v105_addAITextMessages")
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let headers = 2000, entries = 600, withoutId = 150, gone = 5
        try pool.write { db in
            var account = Account(emailAddress: "acc1@example.com", displayName: "A", provider: .imap)
            account.id = "acc1"
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
            for i in 1...headers {
                try TestDatabase.insertAtOldSchema(Self.header("\(i)", folder: "INBOX", rfc: "m\(i)@example.com"), db)
            }
            // The first `withoutId` entries were written by an older extension, without the
            // Message-ID; the rest carry it.
            for i in 1...entries {
                try TestDatabase.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:m\(i)@example.com", rfc: i <= withoutId ? nil : "m\(i)@example.com", daysAgo: 0), db)
            }
            // Entries without a Message-ID whose email is not on the device.
            for i in 1...gone {
                try TestDatabase.insertAtOldSchema(Self.cacheEntry("acc1:INBOX:gone\(i)@example.com", rfc: nil, daysAgo: 0), db)
            }
        }
        // Planned on the writer, the connection the migration runs on, right after its ANALYZE
        // loaded the new statistics.
        let (stat, details) = try pool.write { db in
            try db.execute(sql: "ANALYZE")
            return (try String.fetchOne(db, sql: "SELECT stat FROM sqlite_stat1 WHERE idx = 'messageAICache_rfc822MessageId'"),
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + AppDatabase.repairAICacheMessageIdsSQL).map { $0["detail"] as String })
        }
        // The statistics the scenario needs are in place.
        #expect(stat != nil)
        // messageHeader is the outer loop, scanned once; the cache is searched by its key and
        // never through its Message-ID index.
        #expect(details.first?.hasPrefix("SCAN h") == true, "\(details)")
        #expect(details.contains { $0.hasPrefix("SEARCH messageAICache") && $0.contains("(key=?)") }, "\(details)")
        #expect(!details.contains { $0.contains("messageAICache_rfc822MessageId") }, "\(details)")

        try AppDatabase.runMigrations(on: pool)

        // The same rows are filled: every entry whose email is where its key says gets that
        // email's Message-ID, the rest are unchanged.
        let ids = try pool.read { db in
            Dictionary(uniqueKeysWithValues: try MessageAICache.fetchAll(db).map { ($0.key, $0.rfc822MessageId) })
        }
        var expected: [String: String?] = [:]
        for i in 1...entries { expected["acc1:INBOX:m\(i)@example.com"] = .some("m\(i)@example.com") }
        for i in 1...gone { expected["acc1:INBOX:gone\(i)@example.com"] = .some(nil) }
        #expect(ids == expected)
        let applied = try pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v106_repairAICacheMessageIds"))
    }
}
