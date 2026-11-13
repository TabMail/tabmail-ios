/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A chat turn the pill fails to write to (or delete from) the local chat
/// history must be visible to the user in that chat: the live conversation
/// continues, but reopening the chat would show a different history.
///
/// Uses `.serialized` because it rebinds `AppDatabase.shared`.
@Suite("Chat history write failures are shown in the chat", .serialized, .processGlobalState)
@MainActor
struct ChatHistoryWriteFailureTests {

    private func installTempDB() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current
            current = appDb
            return prev
        }
        return (pool, dir, previous)
    }

    private func tearDown(pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        AppDatabase.shared.withLock { $0 = previous }
        TestDatabaseTeardown.retire(pool: pool, directory: dir)
    }

    private func turn(id: String = UUID().uuidString, role: String = "user", sessionId: String = "inbox-\(UUID().uuidString)") -> ChatTurn {
        ChatTurn(
            id: id, timestamp: Date().timeIntervalSince1970 * 1000, role: role,
            content: role == "user" ? "chat_converse" : "Reply", userMessage: role == "user" ? "Hello" : nil,
            type: "normal", chars: 5, renderedContent: nil, sessionId: sessionId,
            remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
    }

    private func warnings(_ session: ChatPillState.Session) -> [String] {
        session.chatMessages.filter { $0.role == .warning }.map(\.content)
    }

    @Test("A turn that cannot be saved shows a warning in its chat")
    func failedAppendIsShown() async throws {
        let (pool, dir, previous) = try installTempDB()
        defer { tearDown(pool: pool, dir: dir, previous: previous) }
        await MemoryIndex.shared._testReset()
        try await pool.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_turn BEFORE INSERT ON chatTurn BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        let session = ChatPillState.Session()
        let evicted = await session.appendTurn(turn(), admission: nil)

        #expect(evicted == nil)
        #expect(warnings(session) == [ChatPillState.Session.historySaveFailedWarning])
    }

    @Test("A turn that is saved shows no warning")
    func savedAppendIsSilent() async throws {
        let (pool, dir, previous) = try installTempDB()
        defer { tearDown(pool: pool, dir: dir, previous: previous) }
        await MemoryIndex.shared._testReset()

        let session = ChatPillState.Session()
        let saved = turn()
        let evicted = await session.appendTurn(saved, admission: nil)

        #expect(evicted != nil)
        #expect(warnings(session).isEmpty)
        let stored = try await pool.read { db in try ChatTurn.fetchOne(db, key: saved.id) }
        #expect(stored != nil)
    }

    @Test("A demo turn refused after its demo ended shows no warning")
    func refusedDemoTurnIsSilent() async throws {
        let (pool, dir, previous) = try installTempDB()
        defer { tearDown(pool: pool, dir: dir, previous: previous) }
        await MemoryIndex.shared._testReset()

        let session = ChatPillState.Session()
        // No admission: the demo this turn belonged to is over.
        let evicted = await session.appendTurn(turn(sessionId: "demo:\(UUID().uuidString)"), admission: nil)

        #expect(evicted == nil)
        #expect(warnings(session).isEmpty)
    }

    @Test("Removed turns that cannot be deleted show a warning in their chat")
    func failedDeleteIsShown() async throws {
        let (pool, dir, previous) = try installTempDB()
        defer { tearDown(pool: pool, dir: dir, previous: previous) }
        await MemoryIndex.shared._testReset()

        let session = ChatPillState.Session()
        let kept = turn()
        await session.appendTurn(kept, admission: nil)
        try await pool.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_delete BEFORE DELETE ON chatTurn BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        await session.deleteTurns(ids: [kept.id])

        #expect(warnings(session) == [ChatPillState.Session.historyDeleteFailedWarning])
        let stored = try await pool.read { db in try ChatTurn.fetchOne(db, key: kept.id) }
        #expect(stored != nil)
    }

    @Test("Removed turns that are deleted show no warning")
    func deletedTurnsAreSilent() async throws {
        let (pool, dir, previous) = try installTempDB()
        defer { tearDown(pool: pool, dir: dir, previous: previous) }
        await MemoryIndex.shared._testReset()

        let session = ChatPillState.Session()
        let removed = turn()
        await session.appendTurn(removed, admission: nil)

        await session.deleteTurns(ids: [removed.id])

        #expect(warnings(session).isEmpty)
        let stored = try await pool.read { db in try ChatTurn.fetchOne(db, key: removed.id) }
        #expect(stored == nil)
    }

    /// The pill's send, resume, resend and rewind paths are private to the
    /// view, so this pins that every chat history write and delete in it goes
    /// through the session methods above, which show the failure.
    @Test("The chat pill writes chat history only through its session")
    func pillWritesThroughSession() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("TabMail/Views/Inbox/DynamicIslandChatButton.swift"),
            encoding: .utf8)
        #expect(!source.contains("ChatStore.shared.appendTurn("))
        #expect(!source.contains("chatStore.appendTurn("))
        #expect(!source.contains("ChatStore.shared.deleteTurns("))
        #expect(source.contains("session.appendTurn("))
        #expect(source.contains("session.deleteTurns("))
    }
}
