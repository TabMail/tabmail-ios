/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
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

    /// Counts a region observation's changes, which GRDB reports on its writer queue.
    final class ChangeCounter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func increment() { value.withLock { $0 += 1 } }
    }

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

    /// The column and the five triggers exist at the end of the whole migration
    /// chain: a later migration that rebuilds either table drops the triggers with
    /// it, and this fails. The index is not the chain's: the deferred step builds it.
    @Test("The chain ends with the column and the five triggers; the index waits for the deferred step")
    func theChainEndsWithThePair() throws {
        let db = try TestDatabase.make()
        let triggers = try db.read { conn in
            Set(try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        }
        let column = try db.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM pragma_table_info('messageHeader') WHERE name = 'htmlCachedAt'")
        }
        let missing = try db.read { try SyncEngine.missingDeferredIndexNames($0) }
        #expect(Self.triggerNames.isSubset(of: triggers), "missing: \(Self.triggerNames.subtracting(triggers).sorted())")
        #expect(column == ["htmlCachedAt"])
        #expect(missing.contains(HTMLCachePair.indexName), "the chain built the index; the deferred step must")
    }

    /// A database upgraded with HTML already cached. v116 adds the column empty and
    /// its triggers. Until the deferred step commits, those bodies read as not
    /// cached, no body is deleted, and a pair that is set names its own body's
    /// `fetchedAt` (a body written after v116). The step's one write fills the pair
    /// from every cached body and builds the index; after it the pair equals
    /// `messageBody` exactly. The index existing is the proof the fill ran: a step
    /// that rolls back leaves neither, and a step with the index already there does
    /// not fill again.
    @Test("Before the deferred step old bodies read as not cached; the step fills the pair exactly")
    func theDeferredStepFillsThePair() throws {
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
        let resaved = try Self.header(db, "5", folderPath: "Archive")
        let orphan = "acc1:Archive:4"
        try db.write { conn in
            try Self.body(inboxCached.id, fetchedAt: Self.hoursAgo(1)).insert(conn)
            try Self.body(archiveCached.id, fetchedAt: Self.hoursAgo(900)).insert(conn)
            try Self.body(resaved.id, fetchedAt: Self.hoursAgo(800)).insert(conn)
            try Self.body(orphan, fetchedAt: Self.hoursAgo(5)).insert(conn)
        }
        let headerIds = [inboxCached.id, archiveCached.id, resaved.id, inboxBare.id]
        func bodyIds() throws -> Set<String> {
            try db.read { try Set(String.fetchAll($0, sql: "SELECT id FROM messageBody")) }
        }
        func cachedAnswers() throws -> [Bool] {
            try db.read { conn in try headerIds.map { try HTMLCachePair.isCached(conn, headerId: $0) } }
        }
        func indexMissing() throws -> Bool {
            try db.read { try SyncEngine.missingDeferredIndexNames($0).contains(HTMLCachePair.indexName) }
        }
        let bodiesBefore = try bodyIds()

        try AppDatabase.runMigrations(on: db)
        // A body saved again between v116 and the step: the triggers record it.
        try db.write { conn in try Self.body(resaved.id, fetchedAt: Self.hoursAgo(2)).save(conn) }

        let interimBodies = try bodyIds()
        let interimAnswers = try cachedAnswers()
        let interimWrong = try db.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT id FROM messageHeader
                WHERE htmlCachedAt IS NOT NULL
                  AND htmlCachedAt IS NOT (SELECT fetchedAt FROM messageBody WHERE messageBody.id = messageHeader.id)
                """)
        }
        let interimIndexMissing = try indexMissing()
        #expect(interimBodies == bodiesBefore, "no body is deleted before the step")
        #expect(interimAnswers == [false, false, true, false],
                "inbox, archive, re-saved, bare: only the body saved after v116 reads as cached: \(interimAnswers)")
        #expect(interimWrong.isEmpty, "a pair that is set names its own body's fetchedAt: \(interimWrong)")
        #expect(interimIndexMissing, "the index waits for the step")

        struct Abort: Error {}
        var aborted = false
        do {
            try db.write { conn in
                try SyncEngine.createDeferredIndexes(conn)
                throw Abort()
            }
        } catch is Abort {
            aborted = true
        }
        let rolledBackAnswers = try cachedAnswers()
        let rolledBackIndexMissing = try indexMissing()
        #expect(aborted, "setup: the step's write rolled back")
        #expect(rolledBackAnswers == interimAnswers, "a rolled-back step leaves the pair unfilled: \(rolledBackAnswers)")
        #expect(rolledBackIndexMissing, "and the index unbuilt")

        try db.write { try SyncEngine.createDeferredIndexes($0) }

        let bad = try db.read { try Self.mismatches($0) }
        let answers = try cachedAnswers()
        let bodiesAfter = try bodyIds()
        let indexColumns = try db.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM pragma_index_info('messageHeader_htmlCachedAt') ORDER BY seqno")
        }
        #expect(bad.isEmpty, "headers out of step with their bodies after the step: \(bad)")
        #expect(answers == [true, true, true, false], "inbox, archive, re-saved, bare: \(answers)")
        #expect(bodiesAfter == bodiesBefore, "the step deletes no body, the one no header holds included")
        #expect(indexColumns == ["isInInbox", "htmlCachedAt"])

        // With the index there, a later step does not fill again (a fill reads every
        // cached body). The cleared value stays cleared.
        try db.write { conn in
            try conn.execute(sql: "UPDATE messageHeader SET htmlCachedAt = NULL WHERE id = ?", arguments: [archiveCached.id])
        }
        try db.write { try SyncEngine.createDeferredIndexes($0) }
        let refilled = try db.read { try HTMLCachePair.isCached($0, headerId: archiveCached.id) }
        #expect(!refilled, "the fill ran again though its index was there")
    }

    /// The fill writes one row per header that has a body and no other. A fill of every
    /// header would leave the same values (a header with no body stays NULL) but
    /// rewrite every header row in the step's one write: about 525,000 instead of the
    /// about 104,000 cached ones on the large proof database.
    @Test("The fill writes one header per cached body and no other")
    func theFillWritesOnlyCachedHeaders() throws {
        let db = try Self.seeded()
        let cached = try (1...3).map { try Self.header(db, "\($0)", folderPath: "Archive").id }
        let bare = try (4...8).map { try Self.header(db, "\($0)").id }
        try db.write { conn in
            for (offset, id) in cached.enumerated() {
                try Self.body(id, fetchedAt: Self.hoursAgo(offset + 1)).insert(conn)
            }
            // The state v116 leaves: the column empty for bodies cached before it.
            try conn.execute(sql: "UPDATE messageHeader SET htmlCachedAt = NULL")
        }
        let written = try db.write { conn -> Int in
            try conn.execute(sql: HTMLCachePair.fillSQL)
            return conn.changesCount
        }
        let bad = try db.read { try Self.mismatches($0) }
        #expect(written == cached.count,
                "the fill wrote \(written) header rows; \(cached.count) have a body and \(bare.count) do not")
        #expect(bad.isEmpty, "headers out of step with their bodies after the fill: \(bad)")
    }

    /// The pair's writes touch only `htmlCachedAt`, which the chat pill's reminder
    /// count does not read, so its observation does not re-run on a body save or
    /// delete, or on the fill. Observed through GRDB's own region tracking of the
    /// production statement; a write of a column the count reads is the control.
    @Test("The pair's writes do not re-run the reminder count")
    func thePairsWritesDoNotRerunTheReminderCount() throws {
        let db = try Self.seeded()
        let id = try Self.header(db, "1", folderPath: "Archive").id
        let changes = ChangeCounter()
        let observation = DatabaseRegionObservation(tracking: SQLRequest<Int>(sql: ChatPillState.Session.reminderCountSQL))
        let cancellable = observation.start(in: db, onError: { _ in }, onChange: { _ in changes.increment() })
        try db.write { try Self.body(id, fetchedAt: Self.hoursAgo(1)).insert($0) }
        try db.write { try $0.execute(sql: "UPDATE messageBody SET fetchedAt = ? WHERE id = ?", arguments: [Self.hoursAgo(2), id]) }
        try db.write { try $0.execute(sql: HTMLCachePair.fillSQL) }
        try db.write { _ = try MessageBody.deleteOne($0, key: ContentKey(rawValue: id)) }
        let afterPairWrites = changes.count
        try db.write { try $0.execute(sql: "UPDATE messageHeader SET isInInbox = 1 WHERE id = ?", arguments: [id]) }
        let afterControl = changes.count
        cancellable.cancel()
        #expect(afterPairWrites == 0, "a write of htmlCachedAt alone re-ran the count \(afterPairWrites) times")
        #expect(afterControl == 1, "control: a write of isInInbox re-runs it: \(afterControl)")
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

    /// A body write that keeps its `fetchedAt` writes no header. A record update names
    /// every column, `fetchedAt` included, so the update trigger is considered on
    /// every one; it writes the header only when the id or the cached-at time moves.
    /// An update with a new time is the control.
    @Test("A body record update that keeps fetchedAt writes no header")
    func aBodyUpdateKeepingFetchedAtWritesNoHeader() throws {
        let db = try Self.seeded()
        let id = try Self.header(db, "1", folderPath: "Archive").id
        var body = Self.body(id, fetchedAt: Self.hoursAgo(3))
        try db.write { [body] conn in try body.insert(conn) }
        let counter = HeaderUpdateCounter()
        db.add(transactionObserver: counter)
        body.htmlContent = "<p>edited</p>"
        try db.write { [body] conn in try body.update(conn) }
        let afterKeep = counter.count
        body.fetchedAt = Self.hoursAgo(1)
        try db.write { [body] conn in try body.update(conn) }
        let afterNewTime = counter.count
        db.remove(transactionObserver: counter)
        let bad = try db.read { try Self.mismatches($0) }
        #expect(afterKeep == 0, "an update that kept fetchedAt wrote \(afterKeep) header rows")
        #expect(afterNewTime == 1, "control: an update with a new fetchedAt writes its header once: \(afterNewTime)")
        #expect(bad.isEmpty, "headers out of step with their bodies: \(bad)")
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

    // MARK: - Deletes of both rows

    /// Counts the `messageHeader` rows written through `htmlCachedAt`, the triggers'
    /// writes included: GRDB is told of a trigger's writes when it compiles the
    /// statement that fires it, and SQLite reports each row the trigger changes.
    final class PairRewriteCounter: TransactionObserver, Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            guard case let .update(tableName, columnNames) = eventKind else { return false }
            return tableName == MessageHeader.databaseTableName && columnNames.contains(HTMLCachePair.column)
        }

        func databaseDidChange(with event: DatabaseEvent) {
            guard event.kind == .update, event.tableName == MessageHeader.databaseTableName else { return }
            value.withLock { $0 += 1 }
        }

        func databaseDidCommit(_ db: Database) {}
        func databaseDidRollback(_ db: Database) {}
    }

    /// Counts every `messageHeader` row update, whatever columns it writes, the
    /// triggers' writes included.
    final class HeaderUpdateCounter: TransactionObserver, Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
            guard case let .update(tableName, _) = eventKind else { return false }
            return tableName == MessageHeader.databaseTableName
        }

        func databaseDidChange(with event: DatabaseEvent) {
            guard event.kind == .update, event.tableName == MessageHeader.databaseTableName else { return }
            value.withLock { $0 += 1 }
        }

        func databaseDidCommit(_ db: Database) {}
        func databaseDidRollback(_ db: Database) {}
    }

    /// Account removal and the full wipe delete the headers before the bodies, so
    /// the body-delete trigger finds no header left to rewrite: no header is written
    /// just before it is deleted. The production transactions run as they are; the
    /// control deletes the same bodies first, in a copy of each, and counts one
    /// rewrite per cached header, which is what either order swapped would cost.
    @Test("Account removal and the wipe rewrite no header: headers go before bodies")
    func removalAndWipeRewriteNoHeader() throws {
        func seed() throws -> (db: DatabaseQueue, removed: [String], kept: [String]) {
            let db = try Self.seeded()
            try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")
            try TestDatabase.insertFolder(db, accountId: "acc2")
            let removed = try (1...3).map { try Self.header(db, "\($0)").id }
                + [try Self.header(db, "4", folderPath: "Archive").id]
            let kept = try (5...6).map { messageId in
                try TestDatabase.insertMessageHeader(
                    db, messageId: "\(messageId)", folderId: "acc2:INBOX", accountId: "acc2").id
            }
            try db.write { conn in
                for (offset, id) in (removed + kept).enumerated() {
                    try Self.body(id, fetchedAt: Self.hoursAgo(offset + 1)).insert(conn)
                }
            }
            return (db, removed, kept)
        }
        func rowsLeft(_ db: DatabaseQueue, accountId: String) throws -> Int {
            try db.read { conn in
                try Int.fetchOne(conn, sql: """
                    SELECT (SELECT COUNT(*) FROM messageHeader WHERE accountId = ?)
                         + (SELECT COUNT(*) FROM messageBody WHERE substr(id, 1, length(?) + 1) = ? || ':')
                    """, arguments: [accountId, accountId, accountId]) ?? -1
            }
        }

        let (db, removed, kept) = try seed()
        let counter = PairRewriteCounter()
        db.add(transactionObserver: counter)
        try db.write { try AccountManager.removeAccountRowsTxn($0, accountId: "acc1", wasPrimary: false) }
        let afterRemoval = counter.count
        let removedLeft = try rowsLeft(db, accountId: "acc1")
        let keptCached = try db.read { conn in try kept.map { try HTMLCachePair.isCached(conn, headerId: $0) } }
        #expect(removedLeft == 0, "setup: the removed account's headers and bodies are gone")
        #expect(keptCached == [true, true], "setup: the other account stays cached: \(keptCached)")
        #expect(afterRemoval == 0, "account removal rewrote \(afterRemoval) headers just before deleting them")

        try db.write { try AppDataWiper.wipeRowsTxn($0) }
        let afterWipe = counter.count - afterRemoval
        let wipedLeft = try rowsLeft(db, accountId: "acc2")
        #expect(wipedLeft == 0, "setup: the wipe left rows")
        #expect(afterWipe == 0, "the wipe rewrote \(afterWipe) headers just before deleting them")

        // Control: the bodies deleted while their headers are still there.
        let control = try seed()
        let controlCounter = PairRewriteCounter()
        control.db.add(transactionObserver: controlCounter)
        try control.db.write { conn in
            try conn.execute(
                sql: #"DELETE FROM messageBody WHERE id LIKE ? ESCAPE '\'"#,
                arguments: [MessageIdentity.escapeForLike("acc1") + ":%"])
            try Account.deleteOne(conn, key: "acc1")
        }
        let controlRemoval = controlCounter.count
        try control.db.write { conn in
            try conn.execute(sql: "DELETE FROM messageBody")
            try conn.execute(sql: "DELETE FROM messageHeader")
        }
        let controlWipe = controlCounter.count - controlRemoval
        #expect(controlRemoval == removed.count,
                "control: bodies first rewrites each removed header: \(controlRemoval) of \(removed.count)")
        #expect(controlWipe == control.kept.count,
                "control: bodies first rewrites each header the wipe deletes: \(controlWipe) of \(control.kept.count)")
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

    @Test("isCached answers from the pair")
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
        #expect(answers == [true, true, false, false], "cached, archived, bare, missing: \(answers)")
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
