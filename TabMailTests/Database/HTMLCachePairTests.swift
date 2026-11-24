/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #1433: `messageHeader.htmlCachedAt` is the `fetchedAt` of the message's
/// `messageBody` row, NULL when it has none, after every write to either table
/// (migration v116's triggers). The body-cache evict and every "is this message's
/// HTML cached?" read trust it (`HTMLCachePair`), so each test checks the whole
/// table against `messageBody` after each write (`mismatches`), and also checks the
/// header it wrote, so a test cannot pass on a table where every value is NULL.
///
/// The writes are the shapes production uses: record `insert`, `insert(onConflict:)`,
/// `save`, `update` and `deleteOne`; `MessageContentStore.release`'s `IN` list; the
/// prefix deletes (`LIKE`) of the account and folder wipes; a whole-table delete; a
/// body written before its header; the renames (`MessageHeaderRekey.apply`, and the
/// sync paths' delete-then-insert carry, which is the same record calls); and an
/// in-place `UPDATE … SET id` on either table, in either order.
@Suite("HTML-cache pair: messageHeader.htmlCachedAt")
struct HTMLCachePairTests {

    static let triggerNames: Set<String> = [
        "messageBody_htmlCachedAtInsert",
        "messageBody_htmlCachedAtUpdate",
        "messageBody_htmlCachedAtDelete",
        "messageHeader_htmlCachedAtInsert",
        "messageHeader_htmlCachedAtRekey",
    ]

    // MARK: - Helpers

    /// Every header whose `htmlCachedAt` is not exactly its body's `fetchedAt` (NULL
    /// when it has no body), compared as stored.
    static func mismatches(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT id FROM messageHeader
            WHERE htmlCachedAt IS NOT (SELECT fetchedAt FROM messageBody WHERE messageBody.id = messageHeader.id)
            ORDER BY id
            """)
    }

    static func cachedAt(_ db: Database, _ headerId: String) throws -> DatabaseValue {
        try DatabaseValue.fetchOne(
            db, sql: "SELECT htmlCachedAt FROM messageHeader WHERE id = ?", arguments: [headerId]
        ) ?? .null
    }

    static func fetchedAt(_ db: Database, _ id: String) throws -> DatabaseValue {
        try DatabaseValue.fetchOne(
            db, sql: "SELECT fetchedAt FROM messageBody WHERE id = ?", arguments: [id]
        ) ?? .null
    }

    static func body(_ id: String, fetchedAt: Date, html: String = "<p>cached</p>") -> MessageBody {
        var body = MessageBody(contentKey: ContentKey(rawValue: id), htmlContent: html)
        body.fetchedAt = fetchedAt
        return body
    }

    static func hoursAgo(_ hours: Int) -> Date {
        Date().addingTimeInterval(-Double(hours) * 3_600)
    }

    /// One account with an inbox and an Archive folder.
    static func seeded() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        return db
    }

    static func header(_ db: DatabaseQueue, _ messageId: String, folderPath: String = "INBOX") throws -> MessageHeader {
        try TestDatabase.insertMessageHeader(
            db, messageId: messageId, folderId: "acc1:\(folderPath)", folderPath: folderPath,
            isInInbox: folderPath == "INBOX")
    }

    /// Runs `write`, then checks the whole table and that `headerId`'s value is its
    /// body's `fetchedAt` (`cached`) or NULL.
    static func expectPaired(
        _ db: DatabaseQueue, after step: String, headerId: String, cached: Bool,
        _ write: (Database) throws -> Void
    ) throws {
        try db.write { try write($0) }
        let (bad, value, bodyValue) = try db.read { conn in
            (try mismatches(conn), try cachedAt(conn, headerId), try fetchedAt(conn, headerId))
        }
        #expect(bad.isEmpty, "\(step): headers out of step with their bodies: \(bad)")
        #expect(value.isNull == !cached, "\(step): \(headerId) cached is \(!value.isNull), expected \(cached)")
        #expect(value == bodyValue, "\(step): \(headerId) holds \(value), its body \(bodyValue)")
    }

    // MARK: - The schema

    /// The column, its index and the five triggers exist at the end of the whole
    /// migration chain: a later migration that rebuilds either table drops the
    /// triggers with it, and this fails.
    @Test("The chain ends with the column, its index and the five triggers")
    func theChainEndsWithThePair() throws {
        let db = try TestDatabase.make()
        let (triggers, indexColumns, column) = try db.read { conn in
            (Set(try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")),
             try String.fetchAll(conn, sql: "SELECT name FROM pragma_index_info('messageHeader_htmlCachedAt') ORDER BY seqno"),
             try String.fetchAll(conn, sql: "SELECT name FROM pragma_table_info('messageHeader') WHERE name = 'htmlCachedAt'"))
        }
        #expect(Self.triggerNames.isSubset(of: triggers), "missing: \(Self.triggerNames.subtracting(triggers).sorted())")
        #expect(indexColumns == ["isInInbox", "htmlCachedAt"])
        #expect(column == ["htmlCachedAt"])
    }

    /// v116 fills the column from the bodies already cached: a header with a body
    /// takes its `fetchedAt`, inbox or not; a header without one stays NULL; a body
    /// no header holds is left as it is.
    @Test("v116 fills the pair from the bodies already cached")
    func theMigrationFillsThePair() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let db = try DatabaseQueue(configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db, upTo: "v115_addUserLabelLastUsed")
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        let inboxCached = try Self.header(db, "1")
        let inboxBare = try Self.header(db, "2")
        let archiveCached = try Self.header(db, "3", folderPath: "Archive")
        let orphan = "acc1:Archive:4"
        try db.write { conn in
            try Self.body(inboxCached.id, fetchedAt: Self.hoursAgo(1)).insert(conn)
            try Self.body(archiveCached.id, fetchedAt: Self.hoursAgo(900)).insert(conn)
            try Self.body(orphan, fetchedAt: Self.hoursAgo(5)).insert(conn)
        }

        try AppDatabase.runMigrations(on: db)

        let (bad, inboxValue, inboxBody, archiveValue, archiveBody, bareValue, orphanBody) = try db.read { conn in
            (try Self.mismatches(conn),
             try Self.cachedAt(conn, inboxCached.id), try Self.fetchedAt(conn, inboxCached.id),
             try Self.cachedAt(conn, archiveCached.id), try Self.fetchedAt(conn, archiveCached.id),
             try Self.cachedAt(conn, inboxBare.id), try Self.fetchedAt(conn, orphan))
        }
        #expect(bad.isEmpty, "headers out of step with their bodies: \(bad)")
        #expect(!inboxValue.isNull && inboxValue == inboxBody, "an inbox header takes its body's fetchedAt")
        #expect(!archiveValue.isNull && archiveValue == archiveBody, "a header outside the inbox takes its body's fetchedAt")
        #expect(bareValue.isNull, "a header with no body stays NULL")
        #expect(!orphanBody.isNull, "a body no header holds is left as it is")
    }

    // MARK: - Body writes

    @Test("Every body write keeps the pair: insert, ignore, save, update, replace, upsert, delete")
    func bodyWritesKeepThePair() throws {
        let db = try Self.seeded()
        let id = try Self.header(db, "1", folderPath: "Archive").id
        try Self.expectPaired(db, after: "insert", headerId: id, cached: true) { conn in
            try Self.body(id, fetchedAt: Self.hoursAgo(10)).insert(conn)
        }
        try Self.expectPaired(db, after: "insert or ignore over a body", headerId: id, cached: true) { conn in
            try Self.body(id, fetchedAt: Self.hoursAgo(1)).insert(conn, onConflict: .ignore)
        }
        try Self.expectPaired(db, after: "save with a new fetchedAt", headerId: id, cached: true) { conn in
            try Self.body(id, fetchedAt: Self.hoursAgo(8)).save(conn)
        }
        try Self.expectPaired(db, after: "update of the HTML alone", headerId: id, cached: true) { conn in
            try conn.execute(sql: "UPDATE messageBody SET htmlContent = '<p>new</p>' WHERE id = ?", arguments: [id])
        }
        try Self.expectPaired(db, after: "insert or replace", headerId: id, cached: true) { conn in
            try Self.body(id, fetchedAt: Self.hoursAgo(6)).insert(conn, onConflict: .replace)
        }
        try Self.expectPaired(db, after: "upsert", headerId: id, cached: true) { conn in
            try conn.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, '<p>up</p>', ?)
                ON CONFLICT(id) DO UPDATE SET fetchedAt = excluded.fetchedAt, htmlContent = excluded.htmlContent
                """, arguments: [id, Self.hoursAgo(4)])
        }
        try Self.expectPaired(db, after: "deleteOne", headerId: id, cached: false) { conn in
            _ = try MessageBody.deleteOne(conn, key: ContentKey(rawValue: id))
        }
        try Self.expectPaired(db, after: "a body saved where none is", headerId: id, cached: true) { conn in
            try Self.body(id, fetchedAt: Self.hoursAgo(2)).save(conn)
        }
    }

    @Test("Bulk body deletes keep the pair: an IN list, a folder prefix, the whole table")
    func bulkBodyDeletesKeepThePair() throws {
        let db = try Self.seeded()
        let inbox = try (1...3).map { try Self.header(db, "\($0)").id }
        let archive = try (4...6).map { try Self.header(db, "\($0)", folderPath: "Archive").id }
        try db.write { conn in
            for (offset, id) in (inbox + archive).enumerated() {
                try Self.body(id, fetchedAt: Self.hoursAgo(offset + 1)).insert(conn)
            }
        }
        // `MessageContentStore.release`'s shape.
        try Self.expectPaired(db, after: "IN list", headerId: inbox[0], cached: false) { conn in
            try conn.execute(sql: "DELETE FROM messageBody WHERE id IN (?, ?)", arguments: [inbox[0], archive[0]])
        }
        let (listedArchive, unlisted) = try db.read { conn in
            (try Self.cachedAt(conn, archive[0]), try Self.cachedAt(conn, inbox[1]))
        }
        #expect(listedArchive.isNull, "every body the list named is uncached")
        #expect(!unlisted.isNull, "a body the list did not name stays cached")
        // The account and folder wipes' shape.
        let archivePattern = MessageIdentity.escapedHeaderIdLikePrefix(accountId: "acc1", folderPath: "Archive") + "%"
        try Self.expectPaired(db, after: "folder prefix", headerId: archive[1], cached: false) { conn in
            try conn.execute(
                sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#, arguments: [archivePattern])
        }
        let otherFolder = try db.read { try Self.cachedAt($0, inbox[1]) }
        #expect(!otherFolder.isNull, "another folder's body stays cached")
        try Self.expectPaired(db, after: "whole table", headerId: inbox[1], cached: false) { conn in
            try conn.execute(sql: "DELETE FROM messageBody")
        }
        let stillCached = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE htmlCachedAt IS NOT NULL") ?? -1
        }
        #expect(stillCached == 0, "after the whole table goes, no header is cached")
    }

    // MARK: - Header writes

    @Test("A body written before its header is paired when the header arrives, and again after a re-insert")
    func aBodyBeforeItsHeaderIsPaired() throws {
        let db = try Self.seeded()
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "Archive", messageId: "7")
        try db.write { try Self.body(id, fetchedAt: Self.hoursAgo(3)).insert($0) }
        let inserted = try Self.header(db, "7", folderPath: "Archive")
        #expect(inserted.id == id)
        try Self.expectPaired(db, after: "header inserted after its body", headerId: id, cached: true) { _ in }
        try Self.expectPaired(db, after: "header deleted and inserted again", headerId: id, cached: true) { conn in
            _ = try MessageHeader.deleteOne(conn, key: id)
            try inserted.insert(conn)
        }
        try Self.expectPaired(db, after: "header insert or replace", headerId: id, cached: true) { conn in
            try inserted.insert(conn, onConflict: .replace)
        }
    }

    /// The record has no `htmlCachedAt`, so its writes never touch the value.
    @Test("Header record writes leave the pair alone: update, save, a plain UPDATE")
    func headerRecordWritesLeaveThePairAlone() throws {
        let db = try Self.seeded()
        var header = try Self.header(db, "1", folderPath: "Archive")
        try db.write { try Self.body(header.id, fetchedAt: Self.hoursAgo(30)).insert($0) }
        let before = try db.read { try Self.cachedAt($0, header.id) }
        #expect(!before.isNull)
        header.subject = "changed"
        try Self.expectPaired(db, after: "record update", headerId: header.id, cached: true) { conn in
            try header.update(conn)
        }
        header.isRead = true
        try Self.expectPaired(db, after: "record save", headerId: header.id, cached: true) { conn in
            try header.save(conn)
        }
        try Self.expectPaired(db, after: "plain UPDATE", headerId: header.id, cached: true) { conn in
            try conn.execute(sql: "UPDATE messageHeader SET isFlagged = 1 WHERE id = ?", arguments: [header.id])
        }
        let after = try db.read { try Self.cachedAt($0, header.id) }
        #expect(after == before)
    }

    // MARK: - Renames

    /// An in-place rename of either row, in either order, ends exact; so does a header
    /// renamed onto an id whose body is already there.
    @Test("In-place id renames keep the pair, in either order")
    func inPlaceRenamesKeepThePair() throws {
        let db = try Self.seeded()
        let bodyFirst = try Self.header(db, "1", folderPath: "Archive").id
        let headerFirst = try Self.header(db, "2", folderPath: "Archive").id
        let ontoABody = try Self.header(db, "3", folderPath: "Archive").id
        let newBodyFirst = "acc1:Archive:11"
        let newHeaderFirst = "acc1:Archive:12"
        let newOntoABody = "acc1:Archive:13"
        try db.write { conn in
            try Self.body(bodyFirst, fetchedAt: Self.hoursAgo(1)).insert(conn)
            try Self.body(headerFirst, fetchedAt: Self.hoursAgo(2)).insert(conn)
            try Self.body(newOntoABody, fetchedAt: Self.hoursAgo(3)).insert(conn)
        }
        try Self.expectPaired(db, after: "body renamed, then its header", headerId: newBodyFirst, cached: true) { conn in
            try conn.execute(sql: "UPDATE messageBody SET id = ? WHERE id = ?", arguments: [newBodyFirst, bodyFirst])
            let between = try Self.mismatches(conn)
            #expect(between.isEmpty, "between the two renames: \(between)")
            try conn.execute(sql: "UPDATE messageHeader SET id = ? WHERE id = ?", arguments: [newBodyFirst, bodyFirst])
        }
        try Self.expectPaired(db, after: "header renamed, then its body", headerId: newHeaderFirst, cached: true) { conn in
            try conn.execute(sql: "UPDATE messageHeader SET id = ? WHERE id = ?", arguments: [newHeaderFirst, headerFirst])
            let between = try Self.mismatches(conn)
            #expect(between.isEmpty, "between the two renames: \(between)")
            try conn.execute(sql: "UPDATE messageBody SET id = ? WHERE id = ?", arguments: [newHeaderFirst, headerFirst])
        }
        try Self.expectPaired(db, after: "header renamed onto a cached id", headerId: newOntoABody, cached: true) { conn in
            try conn.execute(sql: "UPDATE messageHeader SET id = ? WHERE id = ?", arguments: [newOntoABody, ontoABody])
        }
    }

    /// `MessageHeaderRekey.apply`: the sync and drain renames delete the old rows and
    /// insert the new ones, header first, then the carried body.
    @Test("MessageHeaderRekey.apply carries the pair to the new id")
    func theRekeyCarriesThePair() throws {
        let db = try Self.seeded()
        let old = try Self.header(db, "1", folderPath: "Archive")
        try db.write { try Self.body(old.id, fetchedAt: Self.hoursAgo(20)).insert($0) }
        let oldFetchedAt = try db.read { try Self.fetchedAt($0, old.id) }
        let migrated = MessageHeader(
            messageId: "2", subject: old.subject, from: old.from, fromAddress: old.fromAddress,
            to: old.to, date: old.date, snippet: old.snippet, folderId: old.folderId,
            accountId: old.accountId, folderPath: old.folderPath, isInInbox: old.isInInbox)
        #expect(migrated.id != old.id)
        try Self.expectPaired(db, after: "rekey", headerId: migrated.id, cached: true) { conn in
            let inserted = try MessageHeaderRekey.apply(from: old, to: migrated, db: conn)
            #expect(inserted, "setup: the rekey inserted the new header")
        }
        let (newValue, oldHeaderCount) = try db.read { conn in
            (try Self.cachedAt(conn, migrated.id),
             try MessageHeader.filter(key: old.id).fetchCount(conn))
        }
        #expect(newValue == oldFetchedAt, "the new id carries the old body's fetchedAt")
        #expect(oldHeaderCount == 0, "setup: the old header is gone")
    }

    // MARK: - The reads

    @Test("isCached and cachedHeaderIds answer from the pair")
    func theReadsAnswerFromThePair() throws {
        let db = try Self.seeded()
        let cached = try Self.header(db, "1").id
        let bare = try Self.header(db, "2").id
        let archived = try Self.header(db, "3", folderPath: "Archive").id
        let missing = "acc1:INBOX:404"
        try db.write { conn in
            try Self.body(cached, fetchedAt: Self.hoursAgo(1)).insert(conn)
            try Self.body(archived, fetchedAt: Self.hoursAgo(2)).insert(conn)
            // A body no header holds answers "not cached": the question is about a header.
            try Self.body(missing, fetchedAt: Self.hoursAgo(3)).insert(conn)
        }
        let answers = try db.read { conn in
            try [cached, archived, bare, missing].map { try HTMLCachePair.isCached(conn, headerId: $0) }
        }
        let (among, amongNone) = try db.read { conn in
            (try HTMLCachePair.cachedHeaderIds(conn, among: [cached, bare, archived, missing]),
             try HTMLCachePair.cachedHeaderIds(conn, among: []))
        }
        #expect(answers == [true, true, false, false], "cached, archived, bare, missing: \(answers)")
        #expect(among == Set([cached, archived]))
        #expect(amongNone.isEmpty)
    }

    // MARK: - Stage E1 tripwire

    /// The triggers match a body to its header by id, which is exact only while a
    /// message's content key IS its header id. The day `ContentKey.forHeader` mints
    /// anything else (Stage E1), this fails, and v116's triggers must be pointed at
    /// the content key the header holds before that change ships.
    @Test("A content key is its header id, in both key spaces")
    func contentKeysAreHeaderIds() {
        for space in [ContentKeySpace.stableProviderId, .uidAddressed] {
            for rfc822 in [nil, "<tripwire@example.com>"] as [String?] {
                let key = ContentKey.forHeader(
                    accountId: "acc1", folderPath: "INBOX", providerMessageId: "42",
                    rfc822MessageId: rfc822, space: space)
                let headerId = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "42")
                #expect(key.rawValue == headerId, "\(space), rfc822 \(rfc822 ?? "nil"): \(key.rawValue) != \(headerId)")
            }
        }
    }
}
