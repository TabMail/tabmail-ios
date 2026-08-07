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
            try db.execute(sql: "CREATE TABLE draft (accountId TEXT)")
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
            try db.execute(sql: "INSERT INTO draft (accountId) VALUES ('real-1')")
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
            try db.execute(sql: "INSERT INTO draft (accountId) VALUES (?)", arguments: [demo])
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
                "demoDrafts": try count(db, "draft", "accountId = '\(demo)'"),
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
                "realDrafts": try count(db, "draft", "accountId = 'real-1'"),
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
        #expect(c["demoDrafts"] == 0)
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
        #expect(c["realDrafts"] == 1)
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
        #expect(SearchIndex.contentKeyInDemoScope(ContentKey(rawValue: "demo-account:INBOX:1"), demoActive: true))
        #expect(!SearchIndex.contentKeyInDemoScope(ContentKey(rawValue: "real-1:INBOX:9"), demoActive: true))
        #expect(SearchIndex.contentKeyInDemoScope(ContentKey(rawValue: "real-1:INBOX:9"), demoActive: false))
        #expect(!SearchIndex.contentKeyInDemoScope(ContentKey(rawValue: "demo-account:INBOX:1"), demoActive: false))
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

// MARK: - R17-1 — a demo move is a header PRIMARY-KEY change

/// `DemoProvider.move` deletes the header row and re-inserts it under the
/// destination-folder primary key, so it is a member of the class *"every code
/// path that changes a header's primary key"* — the same class as
/// `BackfillBodyQueue.rekeyRemappedHeader`, `DraftStore.migrateExactPlaceholder`
/// and `SyncEngineFullSync.canonicalizeLocalRows`.
///
/// It is separated from `DemoIsolationTests` because it drives the real provider
/// against an installed `AppDatabase.shared`, so unlike that suite it does mutate
/// global state and must be `.serialized`.
@Suite("Demo move — the re-key carries the header's FK children", .serialized)
struct DemoMoveRekeyChildrenTests {

    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-move-rekey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    private func finish(_ fixture: (DatabasePool, URL, AppDatabase?)) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.2, pool: fixture.0, directory: fixture.1)
    }

    /// 🚨 THE INVARIANT, as the system property and not the mechanism
    /// (`MIS-015`): **a header that changes its primary key keeps its labels and
    /// its threading edges.** No assertion names `MessageHeaderRekey.apply`.
    ///
    /// `messageHeader` has exactly two surviving cascading children —
    /// `messageUserLabel.messageId` (`v82`) and `messageReference.messageHeaderId`
    /// (`v27`) — and this path's hand-rolled `delete` → reassign `id` → `insert`
    /// restored neither. It also stranded the `messageBody` row: since
    /// `v70_dropMessageBodyHeaderFK` the body is no longer cascaded away, so it
    /// was left ORPHANED under the id the message no longer has, and the moved
    /// message rendered blank. Demo mode has no server, so nothing re-fetches any
    /// of it and every loss is permanent for the life of the demo account.
    @Test("A demo move carries the message's labels, threading edges and body to the new id")
    func demoMoveCarriesHeaderChildren() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let pool = fixture.0
        let accountId = DemoSeed.demoAccountId
        let parentRfc = "r17-1-demo-parent@example.com"
        let oldId = MessageIdentity.headerId(
            accountId: accountId, folderPath: "INBOX", messageId: "d1")
        let newId = MessageIdentity.headerId(
            accountId: accountId, folderPath: "ARCHIVE", messageId: "d1")

        try await pool.write { db in
            var account = Account(
                emailAddress: "demo@example.com", displayName: "Demo", provider: .imap)
            account.id = accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
            try Folder(
                name: "Archive", path: "ARCHIVE", role: .archive, accountId: accountId).insert(db)
            var header = MessageHeader(
                messageId: "d1", subject: "Re: demo", from: "Peer",
                fromAddress: "peer@example.com", to: "demo@example.com", date: Date(),
                snippet: "", folderId: "\(accountId):INBOX", accountId: accountId,
                folderPath: "INBOX", isInInbox: true)
            header.inReplyTo = parentRfc
            try header.insert(db)
            try ThreadUtils.insertMessageReferences(for: header, db: db)
            let label = UserLabel(
                accountId: accountId, providerLabelId: "keep", name: "Keep", isSystem: false)
            try label.insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: header.id, userLabelId: label.id).insert(db)
            try MessageBody(
                contentKey: ContentKey(rawValue: header.id),
                htmlContent: "<p>demo body</p>").insert(db)
        }

        // MIS-030 — anchor the fixture BEFORE the act, so the post-move
        // assertions cannot pass against rows that never existed.
        let before = try await pool.read { db -> (Int, Int, Bool) in
            (try MessageUserLabel.filter(Column("messageId") == oldId).fetchCount(db),
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageReference WHERE messageHeaderId = ?",
                arguments: [oldId]) ?? 0,
             try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) != nil)
        }
        #expect(before.0 == 1, "precondition: the user applied a label to the message")
        #expect(before.1 == 1, "precondition: the message has a threading edge to its parent")
        #expect(before.2, "precondition: the message has a cached body")

        let provider = DemoProvider(accountId: accountId)
        try await provider.move(ids: ["d1"], from: "INBOX", to: "ARCHIVE")

        let after = try await pool.read { db -> (Bool, [String], [String], String?, Bool) in
            (try MessageHeader.fetchOne(db, key: newId) != nil,
             try MessageUserLabel.filter(Column("messageId") == newId)
                .fetchAll(db).map(\.userLabelId),
             try String.fetchAll(
                db,
                sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?",
                arguments: [newId]),
             try MessageBody.fetchOne(db, key: ContentKey(rawValue: newId))?.htmlContent,
             try MessageBody.fetchOne(db, key: ContentKey(rawValue: oldId)) != nil)
        }
        #expect(after.0, "setup: the move must have re-keyed the header to the destination")
        #expect(after.1 == ["\(accountId):keep"],
                """
                the user's label must follow the message to the folder it was moved to — \
                the re-key's delete cascades `messageUserLabel` and NOTHING can rebuild \
                it, and demo has no server to re-fetch it from
                """)
        #expect(after.2 == [parentRfc],
                "and the threading edge, or the message falls out of its own conversation")
        #expect(after.3 == "<p>demo body</p>",
                """
                and the cached body, which since `v70_dropMessageBodyHeaderFK` is not \
                cascaded but ORPHANED under the old id — leaving the moved message blank
                """)
        #expect(after.4 == false, "and nothing may be left stranded under the retired id")
    }
}

// MARK: - R17b-B1 — a demo draft re-save is a DELETE + RE-INSERT of the same message

/// `DemoProvider.saveDraft` re-materialised the draft's `messageHeader` row by
/// deleting it and inserting a replacement under the **same** primary key.
///
/// That makes it a member of the class *"every code path that DELETEs a
/// `messageHeader` row and re-inserts a row for the same message"* — which is
/// strictly wider than the key-change class R17-1 enumerated, because the harm
/// was never that the key moved. `ON DELETE CASCADE` on `messageUserLabel`
/// (`v82`) and `messageReference` (`v27`) fires on **any** header delete, and an
/// insert restores neither.
///
/// Separated from `DemoIsolationTests` for the same reason
/// `DemoMoveRekeyChildrenTests` is: it drives the real provider against an
/// installed `AppDatabase.shared`, so it mutates global state and must be
/// `.serialized`.
@Suite("Demo draft save — re-materialising in place keeps the header's FK children", .serialized)
struct DemoDraftSaveChildrenTests {

    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-draft-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    private func finish(_ fixture: (DatabasePool, URL, AppDatabase?)) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.2, pool: fixture.0, directory: fixture.1)
    }

    /// Seed the demo account, a Drafts folder, and one draft header carrying the
    /// two pieces of state a header delete destroys.
    private func seed(
        pool: DatabasePool, accountId: String, draftId: String, parentRfc: String
    ) async throws -> String {
        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: "DRAFTS", messageId: draftId)
        try await pool.write { db in
            var account = Account(
                emailAddress: "demo@example.com", displayName: "Demo", provider: .imap)
            account.id = accountId
            try account.insert(db)
            try Folder(
                name: "Drafts", path: "DRAFTS", role: .drafts, accountId: accountId).insert(db)
            var header = MessageHeader(
                messageId: draftId, subject: "old subject", from: "Demo",
                fromAddress: "demo@example.com", to: "peer@example.com", date: Date(),
                snippet: "", folderId: "\(accountId):DRAFTS", accountId: accountId,
                folderPath: "DRAFTS", isInInbox: false)
            header.rfc822MessageId = draftId
            header.inReplyTo = parentRfc
            try header.insert(db)
            try ThreadUtils.insertMessageReferences(for: header, db: db)
            let label = UserLabel(
                accountId: accountId, providerLabelId: "keep", name: "Keep", isSystem: false)
            try label.insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: header.id, userLabelId: label.id).insert(db)
        }
        return headerId
    }

    /// 🚨 THE INVARIANT, stated as the system property rather than the mechanism
    /// (`MIS-015`): **a message re-materialised in place keeps its labels and its
    /// threading edges.** No assertion names `delete`, `insert`, `update` or
    /// `MessageHeaderRekey`.
    ///
    /// A reply draft is the case that bites: it carries `In-Reply-To`, so its
    /// edge to the message being replied to was destroyed on every autosave, and
    /// demo mode has no server from which any of it could be re-fetched.
    @Test("A demo draft re-save keeps the draft's labels and threading edges")
    func demoDraftResaveKeepsHeaderChildren() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let pool = fixture.0
        let accountId = DemoSeed.demoAccountId
        let draftId = "demo-draft-r17b"
        let parentRfc = "r17b-demo-parent@example.com"
        let headerId = try await seed(
            pool: pool, accountId: accountId, draftId: draftId, parentRfc: parentRfc)

        // MIS-030 — anchor the fixture BEFORE the act, so a post-save assertion
        // cannot pass vacuously against rows that never existed.
        let before = try await pool.read { db -> (Int, Int) in
            (try MessageUserLabel.filter(Column("messageId") == headerId).fetchCount(db),
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageReference WHERE messageHeaderId = ?",
                arguments: [headerId]) ?? 0)
        }
        #expect(before.0 == 1, "precondition: the user applied a label to this draft")
        #expect(before.1 == 1, "precondition: the reply draft has a threading edge to its parent")

        let provider = DemoProvider(accountId: accountId)
        let draft = DraftMessage(
            to: ["peer@example.com"], subject: "new subject", body: "edited body",
            inReplyTo: parentRfc)
        _ = try await provider.saveDraft(
            draft, existingIdentity: .demo(localId: draftId), draftsFolderPath: "DRAFTS")

        let after = try await pool.read { db -> (String?, [String], [String]) in
            (try MessageHeader.fetchOne(db, key: headerId)?.subject,
             try MessageUserLabel.filter(Column("messageId") == headerId)
                .fetchAll(db).map(\.userLabelId),
             try String.fetchAll(
                db,
                sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?",
                arguments: [headerId]))
        }
        #expect(after.0 == "new subject", "setup: the save must have applied the edit")
        #expect(after.1 == ["\(accountId):keep"],
                """
                the user's label must survive a re-save of the same draft — nothing in \
                the database can rebuild it, and demo has no server to re-fetch it from
                """)
        #expect(after.2 == [parentRfc],
                "and the threading edge, or the reply falls out of its own conversation")
    }

    /// The same invariant read from the durability end: a draft the user edits
    /// twice must still be there, with the second edit's content.
    ///
    /// This is a distinct end state, not a restatement: since
    /// `v70_dropMessageBodyHeaderFK` the `messageBody` row is NOT cascaded by a
    /// header delete, so it outlived the delete and collided with the
    /// unconditional body insert that followed.
    @Test("A demo draft edited twice keeps the second edit")
    func demoDraftSurvivesASecondSave() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let pool = fixture.0
        let accountId = DemoSeed.demoAccountId
        try await pool.write { db in
            var account = Account(
                emailAddress: "demo@example.com", displayName: "Demo", provider: .imap)
            account.id = accountId
            try account.insert(db)
            try Folder(
                name: "Drafts", path: "DRAFTS", role: .drafts, accountId: accountId).insert(db)
        }

        let provider = DemoProvider(accountId: accountId)
        let first = try await provider.saveDraft(
            DraftMessage(to: ["peer@example.com"], subject: "v1", body: "first body"),
            existingIdentity: nil, draftsFolderPath: "DRAFTS")
        guard case .created(let identity) = first, case .demo(let localId) = identity else {
            Issue.record("setup: the first save must mint a demo draft identity")
            return
        }
        // MIS-030 — the second save is only meaningful if the first one landed.
        let seeded = try await pool.read { db in
            try MessageHeader.filter(Column("accountId") == accountId).fetchCount(db)
        }
        #expect(seeded == 1, "precondition: the first save created exactly one draft header")

        _ = try await provider.saveDraft(
            DraftMessage(to: ["peer@example.com"], subject: "v2", body: "second body"),
            existingIdentity: .demo(localId: localId), draftsFolderPath: "DRAFTS")

        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: "DRAFTS", messageId: localId)
        let after = try await pool.read { db -> (Int, String?, String?) in
            (try MessageHeader.filter(Column("accountId") == accountId).fetchCount(db),
             try MessageHeader.fetchOne(db, key: headerId)?.subject,
             try MessageBody.fetchOne(db, key: ContentKey(rawValue: headerId))?.htmlContent)
        }
        #expect(after.0 == 1, "the draft is still exactly one row")
        #expect(after.1 == "v2", "and it carries the second edit's subject")
        #expect(after.2 == "second body", "and the second edit's body")
    }

    /// ⚠️ THE ASYMMETRY GUARD, and it must hold in BOTH directions (`MIS-005`,
    /// `MIS-026`). A delete that genuinely DISCARDS a draft — the user threw it
    /// away — must keep cascading its children away; only a delete that
    /// re-materialises the *same* message is a member of the class above.
    ///
    /// This test is deliberately GREEN before and after the fix: it is the anchor
    /// that proves the fix did not over-reach into the discard path. If it ever
    /// goes red, a carrier has been added where a cascade belongs.
    @Test("Discarding a demo draft still cascades its labels and threading edges away")
    func demoDraftDeleteStillCascades() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let pool = fixture.0
        let accountId = DemoSeed.demoAccountId
        let draftId = "demo-draft-discarded"
        let parentRfc = "r17b-demo-discard-parent@example.com"
        let headerId = try await seed(
            pool: pool, accountId: accountId, draftId: draftId, parentRfc: parentRfc)

        let before = try await pool.read { db -> (Int, Int) in
            (try MessageUserLabel.filter(Column("messageId") == headerId).fetchCount(db),
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageReference WHERE messageHeaderId = ?",
                arguments: [headerId]) ?? 0)
        }
        #expect(before.0 == 1, "precondition: the discarded draft carried a label")
        #expect(before.1 == 1, "precondition: the discarded draft carried a threading edge")

        let provider = DemoProvider(accountId: accountId)
        try await provider.deleteDraft(identity: .demo(localId: draftId))

        let after = try await pool.read { db -> (Bool, Int, Int) in
            (try MessageHeader.fetchOne(db, key: headerId) != nil,
             try MessageUserLabel.filter(Column("messageId") == headerId).fetchCount(db),
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messageReference WHERE messageHeaderId = ?",
                arguments: [headerId]) ?? 0)
        }
        #expect(after.0 == false, "the discarded draft is gone")
        #expect(after.1 == 0, "and its label association went with it")
        #expect(after.2 == 0, "and so did its threading edges — a discard must still cascade")
    }
}
