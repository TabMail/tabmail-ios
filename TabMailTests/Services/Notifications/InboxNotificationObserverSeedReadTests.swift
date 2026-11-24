/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// The launch seed of `InboxNotificationObserver` (#1385). It runs at every database open, inside the write that
/// registers the observer, and reads `rowid, accountId, messageId` of every inbox row. Through the plain
/// `(isInInbox, date)` index that is one index entry plus one table row per inbox message. The deferred index
/// `messageHeader_inboxMembers` (`SyncEngine.deferredIndexes`) holds exactly the inbox rows and carries both columns,
/// so once the background maintenance pass has built it and refreshed the planner statistics, the seed reads that
/// index alone.
///
/// The seed's statement is not pinned with `INDEXED BY` (the index is absent until the pass runs), so the planner
/// must choose the index. These tests record the statements the real `seed` runs, with `Database.trace` on a database
/// built by the production migrations, and plan each one in every statistics state a device can be in once the pass
/// has run. The pass is reproduced by its two steps: the production DDL (`SyncEngine.createDeferredIndexes`) and the
/// bare whole-database `ANALYZE` its statistics refresh runs. The refresh function itself carries a process-wide
/// single-flight latch, and `DeferredIndexBuildTests` already drives the real pass over every deferred index.
@Suite("The inbox notification seed reads only the inbox-members index once the maintenance pass has run")
struct InboxNotificationObserverSeedReadTests {

    /// The SQL the connection ran. `trace` fires on the queue's own thread, hence the `Mutex`.
    private final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        var all: [String] { statements.withLock { $0 } }
        func clear() { statements.withLock { $0.removeAll() } }
    }

    /// Records each cleared `accountId/messageId`.
    private final class ClearRecorder: Sendable {
        private let calls = Mutex<[String]>([])
        func record(_ accountId: String, _ messageId: String) { calls.withLock { $0.append("\(accountId)/\(messageId)") } }
        var all: [String] { calls.withLock { $0 } }
    }

    /// When the maintenance pass ran relative to the mail.
    enum Regime: String, CaseIterable, CustomTestStringConvertible {
        /// An upgraded device: the mail is there when the pass builds the index and analyzes it.
        case upgraded
        /// A fresh install: the pass runs on an empty table, and the mail arrives afterwards.
        case freshInstall
        /// Every message is in an inbox, so the index holds the whole table.
        case everythingInInbox

        var testDescription: String { rawValue }
    }

    private static let index = "messageHeader_inboxMembers"

    /// A database built by the production migrations (so it carries the statistics the migration chain leaves),
    /// traced into `tape`.
    private static func makeDatabase(trace tape: SQLTape) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.runMigrations(on: queue)
        try TestDatabase.insertAccount(queue, id: "acc1", email: "one@example.com")
        try TestDatabase.insertAccount(queue, id: "acc2", email: "two@example.com")
        return queue
    }

    /// Two accounts' mail, in the inbox and (unless `allInInbox`) in another folder. Returns the
    /// `accountId/messageId` of every inbox row.
    private static func insertMail(_ queue: DatabaseQueue, allInInbox: Bool) throws -> Set<String> {
        var inbox: Set<String> = []
        for (account, messageId, path) in [
            ("acc1", "1", "INBOX"), ("acc1", "2", "INBOX"), ("acc1", "3", "Archive"),
            ("acc2", "1", "INBOX"), ("acc2", "7", "Archive"), ("acc2", "8", "INBOX"),
        ] {
            let folder = allInInbox ? "INBOX" : path
            try TestDatabase.insertMessageHeader(
                queue, messageId: messageId, folderId: "\(account):\(folder)", accountId: account,
                folderPath: folder, isInInbox: folder == "INBOX")
            if folder == "INBOX" { inbox.insert("\(account)/\(messageId)") }
        }
        return inbox
    }

    /// The maintenance pass's two steps, in its order: build the deferred indexes, then analyze.
    private static func runMaintenancePass(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try SyncEngine.createDeferredIndexes(db)
            try db.execute(sql: "ANALYZE")
        }
    }

    /// Seeds an observer on `queue` and registers it, as `AppDatabase` does at every open.
    private static func wire(_ queue: DatabaseQueue, recorder: ClearRecorder) throws -> InboxNotificationObserver {
        let observer = InboxNotificationObserver(clear: { accountId, messageId in recorder.record(accountId, messageId) })
        try queue.write { db in
            try observer.seed(db)
            db.add(transactionObserver: observer)
        }
        return observer
    }

    /// The statements on `messageHeader` the seed ran: everything `tape` recorded from a clear to the seed's end.
    private static func seedStatements(_ tape: SQLTape) -> [String] {
        tape.all.filter { $0.localizedCaseInsensitiveContains("messageHeader") }
    }

    /// What breaks the rule in `sql`'s plan: anything but a covering read of the inbox-members index.
    /// Empty when the plan keeps the rule.
    private static func violations(_ sql: String, in queue: DatabaseQueue) throws -> [String] {
        let plan = try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
        }
        let covering = "USING COVERING INDEX \(index)"
        var broken = plan.filter { !$0.contains(covering) }
        if !plan.contains(where: { $0.contains(covering) }) {
            broken.append("no covering read of \(index) in \(plan)")
        }
        return broken
    }

    private static func indexExists(_ queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
                             arguments: [index]) != nil
        }
    }

    @Test("After the maintenance pass the seed's every statement is a covering read of the inbox-members index",
          arguments: Regime.allCases)
    func seedReadsOnlyTheInboxMembersIndex(regime: Regime) throws {
        let tape = SQLTape()
        let queue = try Self.makeDatabase(trace: tape)
        let inbox: Set<String>
        switch regime {
        case .upgraded:
            inbox = try Self.insertMail(queue, allInInbox: false)
            try Self.runMaintenancePass(queue)
        case .freshInstall:
            try Self.runMaintenancePass(queue)
            inbox = try Self.insertMail(queue, allInInbox: false)
        case .everythingInInbox:
            inbox = try Self.insertMail(queue, allInInbox: true)
            try Self.runMaintenancePass(queue)
        }
        let built = try Self.indexExists(queue)
        #expect(built, "precondition: the pass built \(Self.index)")
        tape.clear()

        let recorder = ClearRecorder()
        let observer = try Self.wire(queue, recorder: recorder)
        let reads = Self.seedStatements(tape)
        #expect(reads.count == 1, "precondition: the seed ran one statement on messageHeader (\(tape.all))")

        var broken: [String] = []
        for sql in reads {
            let lines = try Self.violations(sql, in: queue)
            if !lines.isEmpty { broken.append("\(lines) by \(sql)") }
        }
        #expect(broken.isEmpty, "\(regime): the seed read more than the inbox-members index: \(broken)")

        // The rows it read are the inbox: each is cleared once when it leaves, and nothing else is.
        try queue.write { db in try db.execute(sql: "DELETE FROM messageHeader") }
        #expect(Set(recorder.all) == inbox, "\(regime): the seed's map is not the inbox: \(recorder.all)")
        #expect(recorder.all.count == inbox.count, "\(regime): an inbox row was cleared twice: \(recorder.all)")
        withExtendedLifetime(observer) {}
    }

    @Test("Negative control: before the pass, the same seed statement breaks the rule and still reads the inbox")
    func beforeThePassTheSeedBreaksTheRule() throws {
        let tape = SQLTape()
        let queue = try Self.makeDatabase(trace: tape)
        let inbox = try Self.insertMail(queue, allInInbox: false)
        let built = try Self.indexExists(queue)
        #expect(!built, "precondition: the migration chain alone does not build \(Self.index)")
        tape.clear()

        let recorder = ClearRecorder()
        let observer = try Self.wire(queue, recorder: recorder)
        let reads = Self.seedStatements(tape)
        #expect(reads.count == 1, "precondition: the seed ran one statement on messageHeader (\(tape.all))")
        for sql in reads {
            let lines = try Self.violations(sql, in: queue)
            #expect(!lines.isEmpty, "the rule must catch the seed's plan without the index; it broke nothing: \(sql)")
        }

        // The window the deferral accepts is slower, not different: the seed still holds exactly the inbox.
        try queue.write { db in try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0") }
        #expect(Set(recorder.all) == inbox, "the seed before the pass did not see exactly the inbox: \(recorder.all)")
        withExtendedLifetime(observer) {}
    }
}
