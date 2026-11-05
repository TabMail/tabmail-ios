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

    // MARK: - Message-ID of an older build's entries (v96)

    private static func migrated(upTo migration: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: migration)
        return db
    }

    private static func legacyEntry(_ key: String, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO messageAICache (key, rfc822MessageId, summaryBlurb, updatedAt) VALUES (?, NULL, 'kept', ?)",
                       arguments: [key, Date()])
    }

    @Test("v96 gives an older build's entry the Message-ID of the email its key names, and only that")
    func v96RepairsLegacyIdentity() throws {
        let db = try Self.migrated(upTo: "v95_addAITextMessages")
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        try TestDatabase.insertMessageHeader(db, messageId: "1", rfc822MessageId: "live@example.com")
        try db.write { db in
            try Self.legacyEntry("acc1:INBOX:live@example.com", db)
            // The same Message-ID filed under another folder's key: not this header's entry.
            try Self.legacyEntry("acc1:Archive:live@example.com", db)
            // No header: an orphan, left for the purge.
            try Self.legacyEntry("acc1:INBOX:gone@example.com", db)
            try db.execute(sql: "INSERT INTO messageAICache (key, rfc822MessageId, updatedAt) VALUES ('acc1:INBOX:other@example.com', 'other@example.com', ?)",
                           arguments: [Date()])
        }

        try AppDatabase.runMigrations(on: db)

        let ids = try db.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT key, rfc822MessageId FROM messageAICache")
                .map { ($0["key"] as String, $0["rfc822MessageId"] as String?) })
        }
        #expect(ids["acc1:INBOX:live@example.com"] == .some("live@example.com"))
        #expect(ids["acc1:Archive:live@example.com"] == .some(nil))
        #expect(ids["acc1:INBOX:gone@example.com"] == .some(nil))
        #expect(ids["acc1:INBOX:other@example.com"] == .some("other@example.com"))
        let applied = try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v96_repairAICacheMessageIds"))
    }

    @Test("A write-through onto an older build's entry gives it the Message-ID")
    func writeThroughRepairsLegacyIdentity() throws {
        let db = try TestDatabase.make()
        try db.write { db in
            try Self.legacyEntry("acc1:INBOX:old@example.com", db)
            try MessageAICache.writeThrough(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "old@example.com",
                                            cachedReply: "Sure.", replyGeneratedAt: Date(), replyTextMessage: "Sure", db: db)
        }
        let entry = try entry(db, "old@example.com")
        #expect(entry?.rfc822MessageId == "old@example.com")
        #expect(entry?.summaryBlurb == "kept")
        #expect(entry?.replyTextMessage == "Sure")
    }
}
