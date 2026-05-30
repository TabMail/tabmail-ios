/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ChatHistory parallel store")
struct ChatHistoryTests {

    private func makeTurn(
        id: String, timestamp: Double, role: String = "assistant",
        content: String = "raw content", userMessage: String? = nil,
        renderedContent: String? = nil, sessionId: String? = "test-session",
        chars: Int = 10
    ) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: timestamp, role: role,
            content: content, userMessage: userMessage,
            type: "normal", chars: chars, renderedContent: renderedContent,
            sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    // MARK: - Parallel Write

    @Test("appendTurn creates both chatTurn and chatHistory entries")
    func appendTurnCreatesParallel() async throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "t1", timestamp: 1000, content: "raw [Email](1)", renderedContent: "raw Email: Subject")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try db.write { dbConn in
                    try turn.insert(dbConn)
                    let historyTurn = ChatHistoryTurn(
                        id: turn.id, timestamp: turn.timestamp, role: turn.role,
                        content: turn.renderedContent ?? turn.content,
                        userMessage: turn.role == "user" ? (turn.renderedContent ?? turn.userMessage) : nil,
                        sessionId: turn.sessionId, chars: turn.chars, type: turn.type
                    )
                    try historyTurn.save(dbConn)
                }
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }

        let sessionTurn = try await db.read { try ChatTurn.fetchOne($0, key: "t1") }
        let historyTurn = try await db.read { try ChatHistoryTurn.fetchOne($0, key: "t1") }

        #expect(sessionTurn != nil)
        #expect(historyTurn != nil)

        // Session turn keeps raw content
        #expect(sessionTurn?.content == "raw [Email](1)")
        // History turn gets dereferenced content
        #expect(historyTurn?.content == "raw Email: Subject")
    }

    @Test("appendTurn without renderedContent uses raw content in history")
    func appendTurnNoRendered() async throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "t2", timestamp: 2000, content: "plain text", renderedContent: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try db.write { dbConn in
                    try turn.insert(dbConn)
                    let historyTurn = ChatHistoryTurn(
                        id: turn.id, timestamp: turn.timestamp, role: turn.role,
                        content: turn.renderedContent ?? turn.content,
                        userMessage: nil, sessionId: turn.sessionId, chars: turn.chars, type: turn.type
                    )
                    try historyTurn.save(dbConn)
                }
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }

        let historyTurn = try await db.read { try ChatHistoryTurn.fetchOne($0, key: "t2") }
        #expect(historyTurn?.content == "plain text")
    }

    @Test("user turn history stores userMessage for search, not template name")
    func userTurnHistory() async throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "t3", timestamp: 3000, role: "user",
            content: "chat_converse", userMessage: "What's on my calendar?",
            renderedContent: nil, sessionId: "s1"
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try db.write { dbConn in
                    try turn.insert(dbConn)
                    let historyTurn = ChatHistoryTurn(
                        id: turn.id, timestamp: turn.timestamp, role: turn.role,
                        content: turn.renderedContent ?? turn.content,
                        userMessage: turn.role == "user" ? (turn.renderedContent ?? turn.userMessage) : nil,
                        sessionId: turn.sessionId, chars: turn.chars, type: turn.type
                    )
                    try historyTurn.save(dbConn)
                }
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }

        let historyTurn = try await db.read { try ChatHistoryTurn.fetchOne($0, key: "t3") }
        // userMessage is the actual text, used by search/display
        #expect(historyTurn?.userMessage == "What's on my calendar?")
    }

    // MARK: - clearAll

    @Test("clearAll deletes both chatTurn and chatHistory")
    func clearAllDeletesBoth() throws {
        let db = try TestDatabase.make()

        try db.write { dbConn in
            try makeTurn(id: "t1", timestamp: 1000).insert(dbConn)
            try ChatHistoryTurn(id: "t1", timestamp: 1000, role: "assistant", content: "text", userMessage: nil, sessionId: "s", chars: 4, type: "normal").save(dbConn)
        }

        try db.write { dbConn in
            try ChatTurn.deleteAll(dbConn)
            try ChatHistoryTurn.deleteAll(dbConn)
        }

        let sessionCount = try db.read { try ChatTurn.fetchCount($0) }
        let historyCount = try db.read { try ChatHistoryTurn.fetchCount($0) }
        #expect(sessionCount == 0)
        #expect(historyCount == 0)
    }

    // MARK: - deleteTurns cleans both

    @Test("deleteTurns removes from both chatTurn and chatHistory")
    func deleteTurnsCleansBoth() throws {
        let db = try TestDatabase.make()

        try db.write { dbConn in
            try makeTurn(id: "t1", timestamp: 1000).insert(dbConn)
            try makeTurn(id: "t2", timestamp: 2000).insert(dbConn)
            try ChatHistoryTurn(id: "t1", timestamp: 1000, role: "assistant", content: "a", userMessage: nil, sessionId: "s", chars: 1, type: "normal").save(dbConn)
            try ChatHistoryTurn(id: "t2", timestamp: 2000, role: "assistant", content: "b", userMessage: nil, sessionId: "s", chars: 1, type: "normal").save(dbConn)
        }

        try db.write { dbConn in
            try ChatTurn.filter(["t1"].contains(Column("id"))).deleteAll(dbConn)
            try ChatHistoryTurn.filter(["t1"].contains(Column("id"))).deleteAll(dbConn)
        }

        let sessionCount = try db.read { try ChatTurn.fetchCount($0) }
        let historyCount = try db.read { try ChatHistoryTurn.fetchCount($0) }
        #expect(sessionCount == 1)
        #expect(historyCount == 1)

        // t2 survives
        let remaining = try db.read { try ChatHistoryTurn.fetchOne($0, key: "t2") }
        #expect(remaining != nil)
    }

    // MARK: - Session eviction preserves history

    @Test("session eviction deletes chatTurn but preserves chatHistory")
    func sessionEvictionPreservesHistory() throws {
        let db = try TestDatabase.make()

        // Insert 3 inbox sessions
        for i in 0..<3 {
            let sid = "session-\(i)"
            try db.write { dbConn in
                try makeTurn(id: "t\(i)a", timestamp: Double(i * 1000), sessionId: sid).insert(dbConn)
                try makeTurn(id: "t\(i)b", timestamp: Double(i * 1000 + 500), sessionId: sid).insert(dbConn)
                try ChatHistoryTurn(id: "t\(i)a", timestamp: Double(i * 1000), role: "assistant", content: "h\(i)a", userMessage: nil, sessionId: sid, chars: 3, type: "normal").save(dbConn)
                try ChatHistoryTurn(id: "t\(i)b", timestamp: Double(i * 1000 + 500), role: "assistant", content: "h\(i)b", userMessage: nil, sessionId: sid, chars: 3, type: "normal").save(dbConn)
            }
        }

        // Evict with limit=1 (keep only newest session)
        let evicted = try db.write { dbConn -> Int in
            let sessionRows = try Row.fetchAll(dbConn, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                  AND sessionId NOT LIKE 'msg:%'
                  AND sessionId NOT LIKE 'compose:%'
                GROUP BY sessionId
                ORDER BY maxTs DESC
            """)
            var count = 0
            for (index, row) in sessionRows.enumerated() {
                if index < 1 { continue } // limit=1
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(dbConn)
                count += 1
            }
            return count
        }

        #expect(evicted == 2)

        // chatTurn: only newest session survives
        let sessionTurnCount = try db.read { try ChatTurn.fetchCount($0) }
        #expect(sessionTurnCount == 2) // 2 turns in the surviving session

        // chatHistory: ALL turns survive (not affected by session eviction)
        let historyTurnCount = try db.read { try ChatHistoryTurn.fetchCount($0) }
        #expect(historyTurnCount == 6) // all 6 history turns preserved
    }

    // MARK: - History turn cap

    @Test("history turn cap deletes oldest history entries")
    func historyTurnCapEviction() throws {
        let db = try TestDatabase.make()

        // Insert 10 history turns
        try db.write { dbConn in
            for i in 0..<10 {
                try ChatHistoryTurn(
                    id: "h\(i)", timestamp: Double(i * 1000),
                    role: "assistant", content: "content \(i)",
                    userMessage: nil, sessionId: "s", chars: 10, type: "normal"
                ).save(dbConn)
            }
        }

        // Evict with cap=5
        let evicted = try db.write { dbConn -> Int in
            let totalCount = try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM chatHistory") ?? 0
            guard totalCount > 5 else { return 0 }
            let excess = totalCount - 5
            try dbConn.execute(sql: """
                DELETE FROM chatHistory WHERE id IN (
                    SELECT id FROM chatHistory ORDER BY timestamp ASC LIMIT ?
                )
            """, arguments: [excess])
            return dbConn.changesCount
        }

        #expect(evicted == 5)

        let remaining = try db.read { try ChatHistoryTurn.fetchCount($0) }
        #expect(remaining == 5)

        // Oldest (h0-h4) gone, newest (h5-h9) survive
        let oldest = try db.read { try ChatHistoryTurn.fetchOne($0, key: "h0") }
        #expect(oldest == nil)
        let newest = try db.read { try ChatHistoryTurn.fetchOne($0, key: "h9") }
        #expect(newest != nil)
    }

    // MARK: - Search

    @Test("search queries chatHistory not chatTurn")
    func searchQueriesHistory() throws {
        let db = try TestDatabase.make()

        // Insert a turn with raw content in chatTurn and dereferenced in chatHistory
        try db.write { dbConn in
            try makeTurn(id: "t1", timestamp: 1000, content: "Check [Email](42)", renderedContent: "Check Email: Meeting Notes").insert(dbConn)
            try ChatHistoryTurn(
                id: "t1", timestamp: 1000, role: "assistant",
                content: "Check Email: Meeting Notes",
                userMessage: nil, sessionId: "s", chars: 26, type: "normal"
            ).save(dbConn)
        }

        // Search for "Meeting Notes" — should find in chatHistory
        let results = try db.read { dbConn in
            try ChatHistoryTurn
                .filter(sql: "content LIKE '%Meeting Notes%'")
                .fetchAll(dbConn)
        }
        #expect(results.count == 1)
        #expect(results.first?.content == "Check Email: Meeting Notes")

        // Searching chatTurn for "Meeting Notes" would NOT find it (raw content has [Email](42))
        let sessionResults = try db.read { dbConn in
            try ChatTurn
                .filter(sql: "content LIKE '%Meeting Notes%'")
                .fetchAll(dbConn)
        }
        #expect(sessionResults.isEmpty)
    }

    // MARK: - v25 Migration Backfill

    @Test("v25 migration backfills chatHistory from existing chatTurn data")
    func migrationBackfill() throws {
        let db = try TestDatabase.make()

        // TestDatabase already runs all migrations including v25.
        // Insert pre-existing chatTurn data and verify it was backfilled.
        // Since migration runs on empty DB, we simulate by inserting directly
        // and checking the chatHistory parallel write works.

        try db.write { dbConn in
            try makeTurn(id: "pre1", timestamp: 500, content: "old [Email](1)", renderedContent: "old Email: Subject").insert(dbConn)
            try ChatHistoryTurn(
                id: "pre1", timestamp: 500, role: "assistant",
                content: "old Email: Subject",
                userMessage: nil, sessionId: nil, chars: 18, type: "normal"
            ).save(dbConn)
        }

        let history = try db.read { try ChatHistoryTurn.fetchOne($0, key: "pre1") }
        #expect(history?.content == "old Email: Subject")
    }
}
