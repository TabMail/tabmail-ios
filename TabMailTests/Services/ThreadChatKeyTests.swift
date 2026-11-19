/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// The thread key, the reader's merge and budget, and the SQL behind the migration, eviction and
/// the agent toast (ADR-IOS-114, decision 14).
@Suite("Per-thread chat: keys, reader, SQL")
struct ThreadChatKeyTests {

    static let account = "key-acct"

    static func header(
        _ uid: String, account: String = account, folder: String = "INBOX", rfc: String?, thread: String, minutesAgo: Int
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: "Sender", fromAddress: "sender@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-Double(minutesAgo) * 60), snippet: "",
            folderId: "\(account):\(folder)", accountId: account, folderPath: folder, isInInbox: folder == "INBOX")
        header.rfc822MessageId = rfc
        header.computedThreadId = thread
        return header
    }

    static func turn(_ id: String, session: String, minutesAgo: Double, chars: Int = 10) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: Date().addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1000,
            role: "user", content: "chat_converse", userMessage: String(repeating: "a", count: chars), type: "normal",
            chars: chars, renderedContent: nil, sessionId: session, remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil)
    }

    /// A database file migrated up to `migration`, as an older build left it.
    static func migrated(upTo migration: String) throws -> (pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("threadkey_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(pool, upTo: migration)
        return (pool, dir)
    }

    static func insertAccount(_ db: Database, id: String = account) throws {
        var account = Account(emailAddress: "\(id)@example.com", displayName: "A", provider: .imap)
        account.id = id
        try account.insert(db)
        try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: id).insert(db)
        try Folder(name: "Archive", path: "Archive", role: .archive, accountId: id).insert(db)
    }

    // MARK: - Keys

    @Test("A thread's key names its account and computedThreadId, or the header id when it has none; parse reads it back, demo scope included")
    func keyRoundTrip() {
        let threaded = Self.header("7", rfc: "k@example.com", thread: "<root:with:colons@example.com>", minutesAgo: 1)
        let key = ChatThreadKey.key(for: threaded)
        #expect(key == "thread:\(Self.account):<root:with:colons@example.com>")
        let parsed = ChatThreadKey.parse(key)
        #expect(parsed?.accountId == Self.account)
        #expect(parsed?.threadId == "<root:with:colons@example.com>")
        let demo = ChatThreadKey.parse("demo:" + key)
        #expect(demo?.threadId == "<root:with:colons@example.com>")

        let alone = Self.header("8", rfc: "a@example.com", thread: "", minutesAgo: 1)
        #expect(ChatThreadKey.key(for: alone) == "thread:\(Self.account):\(alone.id)")
        #expect(ChatThreadKey.parse(ChatThreadKey.key(for: alone))?.threadId == alone.id)

        for other in ["msg:\(Self.account):x@example.com", "compose:4:abcdd1", "inbox", "thread::t", "thread:acct:", "thread:acct"] {
            #expect(ChatThreadKey.parse(other) == nil, "\(other)")
        }
    }

    @Test("The reader's keys: the newest email's own first, each key once")
    func readerKeysAreDistinctOwnFirst() {
        let newest = Self.header("3", rfc: "n@example.com", thread: "t-1", minutesAgo: 1)
        let sameThread = Self.header("2", rfc: "s@example.com", thread: "t-1", minutesAgo: 5)
        let joined = Self.header("1", rfc: "j@example.com", thread: "t-2", minutesAgo: 9)
        let copy = Self.header("9", account: "key-other", rfc: "n@example.com", thread: "t-1", minutesAgo: 1)
        let keys = ThreadChatReader.keys(about: newest, members: [joined, sameThread, copy, joined])
        #expect(keys == [
            ChatThreadKey.key(for: newest), ChatThreadKey.key(for: joined), ChatThreadKey.key(for: copy),
        ])
    }

    // MARK: - Merge and budget

    @Test("The merge orders by time and keeps each list's own order, so a card stays where its session raised it")
    func mergeIsStableByTime() {
        struct Item: Equatable { let name: String; let time: Int }
        let first = [Item(name: "a1", time: 1), Item(name: "card", time: 1), Item(name: "a5", time: 5)]
        let second = [Item(name: "b2", time: 2), Item(name: "b5", time: 5), Item(name: "b6", time: 6)]
        let merged = ThreadChatReader.merged([first, second], by: \.time).map(\.name)
        #expect(merged == ["a1", "card", "b2", "a5", "b5", "b6"])
        #expect(ThreadChatReader.merged([[Item](), []], by: \.time).isEmpty)
    }

    @Test("The history budget keeps the newest turns, at most maxExchanges exchanges and their characters, in time order")
    func budgetKeepsTheNewest() {
        let maxTurns = ChatStore.maxExchanges * 2
        let many = (0..<(maxTurns + 7)).map { Self.turn("c\($0)", session: "s", minutesAgo: Double(maxTurns + 7 - $0)) }
        let byCount = ThreadChatReader.budgeted(many)
        #expect(byCount.map(\.id) == many.suffix(maxTurns).map(\.id))

        let maxChars = ChatStore.maxExchanges * ChatStore.charsPerExchange
        let big = maxChars / 3 + 1
        let heavy = (0..<4).map { Self.turn("h\($0)", session: "s", minutesAgo: Double(10 - $0), chars: big) }
        #expect(ThreadChatReader.budgeted(heavy).map(\.id) == ["h2", "h3"])
    }

    // MARK: - Migration

    @Test("v107 moves each chat to exactly the key the app now reads for its email, for UID and non-UID ids")
    func migrationKeyIsTheRuntimeKey() throws {
        let (pool, dir) = try Self.migrated(upTo: "v106_repairAICacheMessageIds")
        defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
        let headers = [
            Self.header("11", rfc: "uid-rfc@example.com", thread: "t-uid", minutesAgo: 30),
            Self.header("12", rfc: "uid-alone@example.com", thread: "", minutesAgo: 25),
            Self.header("13", rfc: nil, thread: "t-norfc", minutesAgo: 20),
            Self.header("api-77", rfc: "api@example.com", thread: "t-api", minutesAgo: 15),
            Self.header("4294967296", rfc: "big@example.com", thread: "t-big", minutesAgo: 10),
        ]
        try pool.write { db in
            try Self.insertAccount(db)
            for header in headers { try header.insert(db) }
            for (index, header) in headers.enumerated() {
                try Self.turn("m\(index)", session: "msg:\(header.accountId):\(header.stableId)", minutesAgo: 5).insert(db)
            }
        }

        try AppDatabase.runMigrations(on: pool)

        let sessions = try pool.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, sessionId FROM chatTurn").map {
                ($0["id"] as String, $0["sessionId"] as String)
            })
        }
        #expect(sessions.count == headers.count)
        guard sessions.count == headers.count else { return }
        for (index, header) in headers.enumerated() {
            #expect(sessions["m\(index)"] == ChatThreadKey.key(for: header), "\(header.messageId): \(sessions)")
        }
    }

    @Test("v107 on a realistic database: each table's sessions are found by index, each email by an index, in bounded time")
    func migrationPlanAndTime() throws {
        for analyzed in [false, true] {
            let (pool, dir) = try Self.migrated(upTo: "v106_repairAICacheMessageIds")
            defer { TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: dir) }
            let headers = 20_000, sessions = 400, turnsPerSession = 10, inboxTurns = 3000
            try pool.write { db in
                try Self.insertAccount(db)
                for i in 1...headers {
                    let numeric = i % 4 != 0
                    try Self.header(numeric ? "\(i)" : "api-\(i)", folder: i % 3 == 0 ? "Archive" : "INBOX",
                                    rfc: "m\(i)@example.com", thread: "t-\(i / 3)", minutesAgo: i).insert(db)
                }
                for s in 1...sessions {
                    let i = s * (headers / sessions)
                    let stable = i % 4 != 0 ? "m\(i)@example.com" : "api-\(i)"
                    for t in 0..<turnsPerSession {
                        let turn = Self.turn("s\(s)-\(t)", session: "msg:\(Self.account):\(stable)", minutesAgo: Double(t))
                        try turn.insert(db)
                        try db.execute(
                            sql: "INSERT INTO chatHistory (id, timestamp, role, content, userMessage, sessionId, chars) VALUES (?, ?, ?, ?, ?, ?, ?)",
                            arguments: [turn.id, turn.timestamp, turn.role, turn.content, turn.userMessage, turn.sessionId, turn.chars])
                    }
                }
                for t in 0..<inboxTurns {
                    let turn = Self.turn("i\(t)", session: "inbox-\(t / 10)", minutesAgo: Double(t))
                    try turn.insert(db)
                    try db.execute(
                        sql: "INSERT INTO chatHistory (id, timestamp, role, content, userMessage, sessionId, chars) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [turn.id, turn.timestamp, turn.role, turn.content, turn.userMessage, turn.sessionId, turn.chars])
                }
                if analyzed { try db.execute(sql: "ANALYZE") }
            }
            for table in ["chatTurn", "chatHistory"] {
                let details = try pool.read { db in
                    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + AppDatabase.rekeyChatSessionsByThreadSQL(table: table))
                        .map { $0["detail"] as String }
                }
                // Each email is one index search, never a walk of messageHeader.
                #expect(details.contains { $0.contains("USING INDEX messageHeader_rfc822MessageId (rfc822MessageId=?") },
                        "analyzed=\(analyzed) \(table): \(details)")
                #expect(details.contains { $0.contains("USING INDEX messageHeader_accountId_messageId (accountId=? AND messageId=?)") },
                        "analyzed=\(analyzed) \(table): \(details)")
                #expect(!details.contains { $0.hasPrefix("SCAN h") }, "analyzed=\(analyzed) \(table): \(details)")
                // The sessions are found through the table's sessionId index, not a scan.
                #expect(details.contains { $0.contains("\(table)_sessionId") }, "analyzed=\(analyzed) \(table): \(details)")
                #expect(!details.contains { $0 == "SCAN \(table)" }, "analyzed=\(analyzed) \(table): \(details)")
            }

            let start = Date()
            try pool.write { db in try AppDatabase.rekeyChatSessionsByThread(db) }
            let seconds = Date().timeIntervalSince(start)
            print("[ThreadChatKeyTests] v107 analyzed=\(analyzed) headers=\(headers) sessions=\(sessions) turns=\(sessions * turnsPerSession + inboxTurns)/table: \(String(format: "%.3f", seconds)) s")
            #expect(seconds < 5, "analyzed=\(analyzed): \(seconds) s")
            let left = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chatTurn WHERE sessionId GLOB 'msg:*'") }
            #expect(left == 0)
            let moved = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chatHistory WHERE sessionId GLOB 'thread:*'") }
            #expect(moved == sessions * turnsPerSession)
        }
    }

    // MARK: - Eviction and the agent toast

    @Test("A thread is in the Inbox while any email of its account and thread is; the check is one index search")
    func threadInInbox() throws {
        let db = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db)
        let archived = Self.header("21", folder: "Archive", rfc: "x1@example.com", thread: "t-in", minutesAgo: 5)
        let inbox = Self.header("22", rfc: "x2@example.com", thread: "t-in", minutesAgo: 9)
        let gone = Self.header("23", folder: "Archive", rfc: "x3@example.com", thread: "t-out", minutesAgo: 5)
        let alone = Self.header("24", rfc: "x4@example.com", thread: "", minutesAgo: 5)
        let otherAccount = Self.header("25", account: "key-other", rfc: "x5@example.com", thread: "t-out", minutesAgo: 5)
        try db.write { db in
            try Self.insertAccount(db)
            try Self.insertAccount(db, id: "key-other")
            for header in [archived, inbox, gone, alone, otherAccount] { try header.insert(db) }
        }
        try db.read { db in
            #expect(try ChatStore.isThreadInInbox(sessionId: ChatThreadKey.key(for: archived), db: db))
            #expect(try ChatStore.isThreadInInbox(sessionId: "demo:" + ChatThreadKey.key(for: archived), db: db))
            #expect(try !ChatStore.isThreadInInbox(sessionId: ChatThreadKey.key(for: gone), db: db),
                    "another account's Inbox email of the same thread id is not this thread's")
            #expect(try ChatStore.isThreadInInbox(sessionId: ChatThreadKey.key(for: alone), db: db))
            #expect(try !ChatStore.isThreadInInbox(sessionId: "msg:\(Self.account):x1@example.com", db: db))
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + ChatStore.isThreadInInboxSQL, arguments: [Self.account, "t-in", "t-in"])
                .map { $0["detail"] as String }
            #expect(!plan.contains { $0.hasPrefix("SCAN messageHeader") }, "\(plan)")
        }
    }

    @Test("An agent toast for a thread opens the thread's newest email")
    func toastOpensTheNewestEmail() throws {
        let db = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        AppDatabase.registerAllMigrations(on: &migrator)
        try migrator.migrate(db)
        let older = Self.header("31", rfc: "y1@example.com", thread: "t-toast", minutesAgo: 30)
        let newest = Self.header("32", folder: "Archive", rfc: "y2@example.com", thread: "t-toast", minutesAgo: 3)
        let alone = Self.header("33", rfc: "y3@example.com", thread: "", minutesAgo: 1)
        try db.write { db in
            try Self.insertAccount(db)
            for header in [older, newest, alone] { try header.insert(db) }
        }
        let found = try db.read { db in
            (try ChatThreadKey.newestMessageId(of: ChatThreadKey.key(for: older), db: db),
             try ChatThreadKey.newestMessageId(of: ChatThreadKey.key(for: alone), db: db),
             try ChatThreadKey.newestMessageId(of: ChatThreadKey.key(accountId: Self.account, threadId: "t-none"), db: db))
        }
        #expect(found.0 == newest.id)
        #expect(found.1 == alone.id)
        #expect(found.2 == nil)
    }

    @MainActor
    @Test("A toast routes a thread key to the thread, a compose key to its draft, anything else to the pill")
    func toastDestination() {
        let key = ChatThreadKey.key(accountId: Self.account, threadId: "t-dest")
        #expect(AgentToastPayload.destination(forSessionKey: key) == .thread(key: key))
        #expect(AgentToastPayload.destination(forSessionKey: "msg:\(Self.account):z@example.com") == .chatPill)
        #expect(AgentToastPayload.destination(forSessionKey: "inbox") == .chatPill)
    }
}
