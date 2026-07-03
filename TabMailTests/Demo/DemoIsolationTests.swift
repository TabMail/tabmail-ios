/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Protects the two load-bearing guarantees of "demo mode coexists with a
/// logged-in user": (1) `DemoSeed.wipe` deletes ONLY demo-namespaced rows and
/// never touches real data; (2) `Account.sidebarRequest` shows only the demo
/// account while demo is active and excludes it otherwise. Both operate on a
/// passed-in DB / are pure, so no global state or `.serialized` is needed.
@Suite("Demo isolation — wipe scoping + sidebar filter")
struct DemoIsolationTests {

    // MARK: - Wipe scoping

    /// Build an in-memory DB with the tables `DemoSeed.wipe` touches, populated
    /// with one real account's rows and one demo account's rows.
    private func makeMixedDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE account (id TEXT)")
            try db.execute(sql: "CREATE TABLE messageHeader (accountId TEXT)")
            try db.execute(sql: "CREATE TABLE messageBody (id TEXT)")
            try db.execute(sql: "CREATE TABLE folder (accountId TEXT)")
            try db.execute(sql: "CREATE TABLE messageAICache (key TEXT)")
            try db.execute(sql: "CREATE TABLE chatTurn (sessionId TEXT)")
            try db.execute(sql: "CREATE TABLE chatHistory (sessionId TEXT)")
            try db.execute(sql: "CREATE TABLE outboxMessage (accountId TEXT)")
            try db.execute(sql: "CREATE TABLE pendingOperation (accountId TEXT)")
            try db.execute(sql: "CREATE TABLE pendingCalendarOperation (accountId TEXT)")
            try db.execute(sql: "CREATE TABLE chatIdMapping (numericId INTEGER, realId TEXT)")
            try db.execute(sql: "CREATE TABLE demoCalendarEvent (id TEXT)")

            let demo = DemoSeed.demoAccountId  // "demo-account"

            // Real (must survive)
            try db.execute(sql: "INSERT INTO account (id) VALUES ('real-1')")
            try db.execute(sql: "INSERT INTO messageHeader (accountId) VALUES ('real-1'), ('real-1')")
            try db.execute(sql: "INSERT INTO messageBody (id) VALUES ('real-1:m1')")
            try db.execute(sql: "INSERT INTO folder (accountId) VALUES ('real-1')")
            try db.execute(sql: "INSERT INTO messageAICache (key) VALUES ('real-1:k')")
            // Every real session shape must survive: inbox UUID, msg-detail, compose.
            try db.execute(sql: "INSERT INTO chatTurn (sessionId) VALUES ('real-session'), ('msg:real-1:stable'), ('compose:d1')")
            try db.execute(sql: "INSERT INTO chatHistory (sessionId) VALUES ('real-session')")
            try db.execute(sql: "INSERT INTO outboxMessage (accountId) VALUES ('real-1')")
            try db.execute(sql: "INSERT INTO pendingOperation (accountId) VALUES ('real-1')")
            try db.execute(sql: "INSERT INTO pendingCalendarOperation (accountId) VALUES ('real-1')")
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (1, 'real-1:INBOX:100')")

            // Demo (must be wiped)
            try db.execute(sql: "INSERT INTO account (id) VALUES (?)", arguments: [demo])
            try db.execute(sql: "INSERT INTO messageHeader (accountId) VALUES (?), (?)", arguments: [demo, demo])
            try db.execute(sql: "INSERT INTO messageBody (id) VALUES (?)", arguments: ["\(demo):m1"])
            try db.execute(sql: "INSERT INTO folder (accountId) VALUES (?)", arguments: [demo])
            try db.execute(sql: "INSERT INTO messageAICache (key) VALUES (?)", arguments: ["\(demo):k"])
            // Every demo session shape (scopedSessionId output): inbox, msg-detail, compose.
            try db.execute(sql: "INSERT INTO chatTurn (sessionId) VALUES ('demo:s1'), ('demo:msg:demo-account:stable'), ('demo:compose:d2')")
            try db.execute(sql: "INSERT INTO chatHistory (sessionId) VALUES ('demo:s1')")
            try db.execute(sql: "INSERT INTO outboxMessage (accountId) VALUES (?)", arguments: [demo])
            try db.execute(sql: "INSERT INTO pendingOperation (accountId) VALUES (?)", arguments: [demo])
            try db.execute(sql: "INSERT INTO pendingCalendarOperation (accountId) VALUES (?)", arguments: [demo])
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (2, '\(demo):INBOX:1')")
            try db.execute(sql: "INSERT INTO demoCalendarEvent (id) VALUES ('e1')")
        }
        return queue
    }

    private func count(_ db: Database, _ table: String, _ whereClause: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(whereClause)") ?? 0
    }

    @Test("wipe() deletes every demo row and leaves all real rows intact")
    func wipeIsScopedToDemo() throws {
        let queue = try makeMixedDB()
        let demo = DemoSeed.demoAccountId

        try queue.write { db in try DemoSeed.wipe(db) }

        // Fetch all counts first (throwing), then assert on plain values — `try`
        // inside `#expect` doesn't propagate cleanly through the macro.
        let c = try queue.read { db -> [String: Int] in
            [
                "demoAccount": try count(db, "account", "id = '\(demo)'"),
                "demoHeaders": try count(db, "messageHeader", "accountId = '\(demo)'"),
                "demoBodies": try count(db, "messageBody", "id LIKE '\(demo):%'"),
                "demoFolders": try count(db, "folder", "accountId = '\(demo)'"),
                "demoCache": try count(db, "messageAICache", "key LIKE '\(demo):%'"),
                "demoChats": try count(db, "chatTurn", "sessionId LIKE 'demo:%'"),
                "demoHistory": try count(db, "chatHistory", "sessionId LIKE 'demo:%'"),
                "demoCalOps": try count(db, "pendingCalendarOperation", "accountId = '\(demo)'"),
                "demoIdMap": try count(db, "chatIdMapping", "realId LIKE '\(demo):%'"),
                "demoOutbox": try count(db, "outboxMessage", "accountId = '\(demo)'"),
                "demoPending": try count(db, "pendingOperation", "accountId = '\(demo)'"),
                "demoCalendar": try count(db, "demoCalendarEvent", "1=1"),
                "realAccount": try count(db, "account", "id = 'real-1'"),
                "realHeaders": try count(db, "messageHeader", "accountId = 'real-1'"),
                "realBodies": try count(db, "messageBody", "id = 'real-1:m1'"),
                "realFolders": try count(db, "folder", "accountId = 'real-1'"),
                "realCache": try count(db, "messageAICache", "key = 'real-1:k'"),
                "realChats": try count(db, "chatTurn", "sessionId IN ('real-session', 'msg:real-1:stable', 'compose:d1')"),
                "realHistory": try count(db, "chatHistory", "sessionId = 'real-session'"),
                "realCalOps": try count(db, "pendingCalendarOperation", "accountId = 'real-1'"),
                "realIdMap": try count(db, "chatIdMapping", "realId = 'real-1:INBOX:100'"),
                "realOutbox": try count(db, "outboxMessage", "accountId = 'real-1'"),
                "realPending": try count(db, "pendingOperation", "accountId = 'real-1'"),
            ]
        }

        // Demo rows all gone.
        #expect(c["demoAccount"] == 0)
        #expect(c["demoHeaders"] == 0)
        #expect(c["demoBodies"] == 0)
        #expect(c["demoFolders"] == 0)
        #expect(c["demoCache"] == 0)
        #expect(c["demoChats"] == 0)
        #expect(c["demoHistory"] == 0)
        #expect(c["demoCalOps"] == 0)
        #expect(c["demoIdMap"] == 0)
        #expect(c["demoOutbox"] == 0)
        #expect(c["demoPending"] == 0)
        #expect(c["demoCalendar"] == 0)
        // Real rows all survive.
        #expect(c["realAccount"] == 1)
        #expect(c["realHeaders"] == 2)
        #expect(c["realBodies"] == 1)
        #expect(c["realFolders"] == 1)
        #expect(c["realCache"] == 1)
        #expect(c["realChats"] == 3)
        #expect(c["realHistory"] == 1)
        #expect(c["realCalOps"] == 1)
        #expect(c["realIdMap"] == 1)
        #expect(c["realOutbox"] == 1)
        #expect(c["realPending"] == 1)
    }

    // MARK: - Memory / email search demo scope predicates

    @Test("MemoryIndex.demoScopeSQL — demo sees only demo: sessions; normal excludes them (NULL = real)")
    func memoryDemoScopePredicate() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE memory_meta (sessionId TEXT)")
            try db.execute(sql: "INSERT INTO memory_meta VALUES ('demo:s1'), ('demo:msg:demo-account:x'), ('real-uuid'), ('msg:real-1:y'), (NULL)")
        }
        func rows(demoActive: Bool) throws -> Int {
            try queue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM memory_meta meta
                    WHERE \(MemoryIndex.demoScopeSQL(demoActive: demoActive, alias: "meta"))
                    """) ?? -1
            }
        }
        #expect(try rows(demoActive: true) == 2)   // both demo: rows
        #expect(try rows(demoActive: false) == 3)  // real-uuid + msg: + NULL
    }

    @Test("SearchIndex demo account scope — SQL predicate + headerId prefix check")
    func searchIndexDemoScope() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE message_meta (accountId TEXT, headerId TEXT)")
            try db.execute(sql: "INSERT INTO message_meta VALUES ('demo-account', 'demo-account:INBOX:1'), ('real-1', 'real-1:INBOX:9')")
        }
        func ids(demoActive: Bool) throws -> [String] {
            try queue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT headerId FROM message_meta meta
                    WHERE \(SearchIndex.demoAccountScopeSQL(demoActive: demoActive, qualifier: "meta."))
                    """)
            }
        }
        #expect(try ids(demoActive: true) == ["demo-account:INBOX:1"])
        #expect(try ids(demoActive: false) == ["real-1:INBOX:9"])

        // Vector-leg assembly check (no SQL scoping there — prefix based)
        #expect(SearchIndex.headerIdInDemoScope("demo-account:INBOX:1", demoActive: true))
        #expect(!SearchIndex.headerIdInDemoScope("real-1:INBOX:9", demoActive: true))
        #expect(SearchIndex.headerIdInDemoScope("real-1:INBOX:9", demoActive: false))
        #expect(!SearchIndex.headerIdInDemoScope("demo-account:INBOX:1", demoActive: false))
    }

    @Test("DemoToolGuard.accountScope filters by demo account in both modes")
    func toolGuardAccountScope() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE messageHeader (accountId TEXT, isInInbox INTEGER)")
            try db.execute(sql: "INSERT INTO messageHeader VALUES ('demo-account', 1), ('real-1', 1)")
        }
        let demoRows = try queue.read { db in
            try Row.fetchAll(db, SQLRequest<Row>(literal: "SELECT * FROM messageHeader WHERE \(DemoToolGuard.accountScope(demoActive: true))"))
        }
        let realRows = try queue.read { db in
            try Row.fetchAll(db, SQLRequest<Row>(literal: "SELECT * FROM messageHeader WHERE \(DemoToolGuard.accountScope(demoActive: false))"))
        }
        #expect(demoRows.count == 1 && (demoRows.first?["accountId"] as String?) == "demo-account")
        #expect(realRows.count == 1 && (realRows.first?["accountId"] as String?) == "real-1")
    }

    // MARK: - Inbox session list scope

    /// Runs `ChatStore.inboxSessionScopeSQL` (the predicate `loadSessions` and
    /// inbox-session eviction share) against a mixed chatTurn table: one of
    /// every session shape in both modes, plus a task session.
    @Test("Inbox session list scope — demo lists only demo inbox sessions; normal mode excludes all demo sessions")
    func inboxSessionScopeIsolatesDemo() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE chatTurn (sessionId TEXT, timestamp DOUBLE)")
            let sessions = [
                "user-inbox-uuid", "msg:real-1:stable", "compose:d1", "task:h1",
                "demo:inbox-uuid", "demo:msg:demo-account:stable", "demo:compose:d2",
            ]
            for (i, sid) in sessions.enumerated() {
                try db.execute(sql: "INSERT INTO chatTurn VALUES (?, ?)", arguments: [sid, Double(i)])
            }
        }

        func listed(demoActive: Bool) throws -> Set<String> {
            try queue.read { db in
                let sql = """
                    SELECT DISTINCT sessionId FROM chatTurn
                    WHERE sessionId IS NOT NULL
                      AND \(ChatStore.inboxSessionScopeSQL(demoActive: demoActive))
                    """
                return Set(try String.fetchAll(db, sql: sql))
            }
        }

        // Demo mode: ONLY demo inbox sessions (msg/compose contexts have their own load paths).
        #expect(try listed(demoActive: true) == ["demo:inbox-uuid"])
        // Normal mode: user inbox + task sessions; no demo sessions of any shape.
        #expect(try listed(demoActive: false) == ["user-inbox-uuid", "task:h1"])
    }

    // MARK: - Sidebar account filter

    /// Minimal `account` table with just the columns `sidebarRequest` references.
    /// We select only `id`, so a full `Account` decode (and full schema) isn't needed.
    private func makeAccountsDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE account (id TEXT, isActive INTEGER, calendarOnly INTEGER, createdAt DOUBLE)
                """)
            let demo = DemoSeed.demoAccountId
            try db.execute(sql: "INSERT INTO account VALUES ('real-1', 1, 0, 1.0)")
            try db.execute(sql: "INSERT INTO account VALUES ('real-2', 1, 0, 2.0)")
            try db.execute(sql: "INSERT INTO account VALUES (?, 1, 0, 0.5)", arguments: [demo])
            try db.execute(sql: "INSERT INTO account VALUES ('cal-only', 1, 1, 3.0)")
            try db.execute(sql: "INSERT INTO account VALUES ('inactive', 0, 0, 4.0)")
        }
        return queue
    }

    @Test("sidebarRequest(demoActive: true) returns ONLY the demo account")
    func sidebarShowsOnlyDemoWhenActive() throws {
        let queue = try makeAccountsDB()
        let ids = try queue.read { db in
            try String.fetchAll(db, Account.sidebarRequest(demoActive: true).select(Column("id")))
        }
        #expect(ids == [DemoSeed.demoAccountId])
    }

    @Test("sidebarRequest(demoActive: false) excludes demo, calendar-only, inactive")
    func sidebarExcludesDemoWhenInactive() throws {
        let queue = try makeAccountsDB()
        let ids = try queue.read { db in
            try String.fetchAll(db, Account.sidebarRequest(demoActive: false).select(Column("id")))
        }
        // Real, active, non-calendar accounts only — ordered by createdAt.
        #expect(ids == ["real-1", "real-2"])
    }

    // MARK: - Sidebar folder filter

    private func makeFoldersDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE folder (id TEXT, accountId TEXT, name TEXT, role TEXT)")
            let demo = DemoSeed.demoAccountId
            try db.execute(sql: "INSERT INTO folder VALUES ('real-1:INBOX', 'real-1', 'Inbox', 'inbox')")
            try db.execute(sql: "INSERT INTO folder VALUES ('real-1:Sent', 'real-1', 'Sent', 'sent')")
            try db.execute(sql: "INSERT INTO folder VALUES (?, ?, 'Demo Inbox', 'inbox')", arguments: ["\(demo):INBOX", demo])
        }
        return queue
    }

    @Test("Folder.sidebarRequest(demoActive: true) returns ONLY demo folders")
    func folderSidebarShowsOnlyDemoWhenActive() throws {
        let queue = try makeFoldersDB()
        let ids = try queue.read { db in
            try String.fetchAll(db, Folder.sidebarRequest(demoActive: true).select(Column("id")))
        }
        #expect(ids == ["\(DemoSeed.demoAccountId):INBOX"])
    }

    @Test("Folder.sidebarRequest(demoActive: false) excludes demo folders")
    func folderSidebarExcludesDemoWhenInactive() throws {
        let queue = try makeFoldersDB()
        let ids = try queue.read { db in
            try String.fetchAll(db, Folder.sidebarRequest(demoActive: false).select(Column("id")))
        }
        // Real folders only, ordered by name.
        #expect(ids == ["real-1:INBOX", "real-1:Sent"])
    }

    /// Replicates the exact query `InboxViewModel` uses to resolve unified-mailbox
    /// folders (role + demo scope). This is the path that was leaking the live
    /// user's inbox into demo mode before `demoScope` was applied.
    @Test("Unified-inbox folder query (role + demoScope) is demo-only when active")
    func unifiedFolderQueryScopedByDemo() throws {
        let queue = try makeFoldersDB()

        let whileActive = try queue.read { db in
            try String.fetchAll(db, Folder
                .filter(Column("role") == "inbox" && Folder.demoScope(demoActive: true))
                .select(Column("id")))
        }
        #expect(whileActive == ["\(DemoSeed.demoAccountId):INBOX"])

        let whileInactive = try queue.read { db in
            try String.fetchAll(db, Folder
                .filter(Column("role") == "inbox" && Folder.demoScope(demoActive: false))
                .select(Column("id")))
        }
        #expect(whileInactive == ["real-1:INBOX"])  // demo inbox NOT aggregated
    }
}
