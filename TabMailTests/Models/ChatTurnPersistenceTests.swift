/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ChatTurn Persistence")
struct ChatTurnPersistenceTests {

    // MARK: - Helpers

    private func makeTurn(
        id: String = "t1-abc",
        timestamp: Double = 1000,
        role: String = "user",
        content: String = "chat_converse",
        userMessage: String? = "Hello",
        type: String = "normal",
        chars: Int = 5,
        renderedContent: String? = nil,
        sessionId: String? = nil,
        remindersSnapshot: String? = nil,
        emailContextJSON: String? = nil,
        thinkingContent: String? = nil
    ) -> ChatTurn {
        ChatTurn(
            id: id,
            timestamp: timestamp,
            role: role,
            content: content,
            userMessage: userMessage,
            type: type,
            chars: chars,
            renderedContent: renderedContent,
            sessionId: sessionId,
            remindersSnapshot: remindersSnapshot,
            emailContextJSON: emailContextJSON,
            thinkingContent: thinkingContent
        )
    }

    // MARK: - Insert and fetch round-trip

    @Test("Insert and fetch round-trip preserves all fields")
    func insertFetchRoundTrip() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "rt-001",
            timestamp: 1710000000000,
            role: "user",
            content: "chat_converse",
            userMessage: "Tell me about my inbox",
            type: "normal",
            chars: 23,
            renderedContent: "Tell me about my inbox",
            sessionId: "sess-abc",
            remindersSnapshot: "[{\"text\":\"Follow up on project\"}]"
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "rt-001") }
        #expect(fetched != nil)
        #expect(fetched?.id == "rt-001")
        #expect(fetched?.timestamp == 1710000000000)
        #expect(fetched?.role == "user")
        #expect(fetched?.content == "chat_converse")
        #expect(fetched?.userMessage == "Tell me about my inbox")
        #expect(fetched?.type == "normal")
        #expect(fetched?.chars == 23)
        #expect(fetched?.renderedContent == "Tell me about my inbox")
        #expect(fetched?.sessionId == "sess-abc")
        #expect(fetched?.remindersSnapshot?.contains("Follow up on project") == true)
    }

    @Test("Insert assistant turn round-trip")
    func assistantTurnRoundTrip() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "rt-002",
            role: "assistant",
            content: "You have 3 unread emails.",
            userMessage: nil,
            chars: 26,
            renderedContent: "You have 3 unread [Email](1).",
            sessionId: "sess-abc"
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "rt-002") }
        #expect(fetched?.role == "assistant")
        #expect(fetched?.content == "You have 3 unread emails.")
        #expect(fetched?.userMessage == nil)
        #expect(fetched?.renderedContent == "You have 3 unread [Email](1).")
    }

    // MARK: - Filter by sessionId

    @Test("Filter turns by sessionId returns only matching turns")
    func filterBySessionId() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "s1-t1", timestamp: 1000, sessionId: "session-A"),
            makeTurn(id: "s1-t2", timestamp: 2000, sessionId: "session-A"),
            makeTurn(id: "s2-t1", timestamp: 3000, sessionId: "session-B"),
            makeTurn(id: "s3-t1", timestamp: 4000, sessionId: nil),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let sessionA = try db.read {
            try ChatTurn.filter(Column("sessionId") == "session-A").fetchAll($0)
        }
        #expect(sessionA.count == 2)
        #expect(sessionA.allSatisfy { $0.sessionId == "session-A" })
    }

    @Test("Filter by sessionId returns empty when no match")
    func filterBySessionIdNoMatch() throws {
        let db = try TestDatabase.make()
        try db.write { try makeTurn(id: "t1", sessionId: "session-X").insert($0) }

        let result = try db.read {
            try ChatTurn.filter(Column("sessionId") == "nonexistent").fetchAll($0)
        }
        #expect(result.isEmpty)
    }

    @Test("Filter for nil sessionId (legacy turns)")
    func filterNilSessionId() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "t1", sessionId: "s1"),
            makeTurn(id: "t2", sessionId: nil),
            makeTurn(id: "t3", sessionId: nil),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let legacy = try db.read {
            try ChatTurn.filter(Column("sessionId") == nil).fetchAll($0)
        }
        #expect(legacy.count == 2)
    }

    // MARK: - Filter by role

    @Test("Filter by role user returns only user turns")
    func filterByRoleUser() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "t1", role: "user", content: "chat_converse"),
            makeTurn(id: "t2", role: "assistant", content: "Response"),
            makeTurn(id: "t3", role: "user", content: "chat_converse"),
            makeTurn(id: "t4", role: "system", content: "System msg"),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let userTurns = try db.read {
            try ChatTurn.filter(Column("role") == "user").fetchAll($0)
        }
        #expect(userTurns.count == 2)
    }

    @Test("Filter by role assistant returns only assistant turns")
    func filterByRoleAssistant() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "t1", role: "user"),
            makeTurn(id: "t2", role: "assistant"),
            makeTurn(id: "t3", role: "assistant"),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let assistantTurns = try db.read {
            try ChatTurn.filter(Column("role") == "assistant").fetchAll($0)
        }
        #expect(assistantTurns.count == 2)
    }

    @Test("Filter by role system returns only system turns")
    func filterByRoleSystem() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "t1", role: "user"),
            makeTurn(id: "t2", role: "system", content: "System prompt"),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let systemTurns = try db.read {
            try ChatTurn.filter(Column("role") == "system").fetchAll($0)
        }
        #expect(systemTurns.count == 1)
        #expect(systemTurns[0].content == "System prompt")
    }

    // MARK: - Order by timestamp (createdAt equivalent)

    @Test("Order by timestamp ascending returns chronological order")
    func orderByTimestampAsc() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "t-late", timestamp: 5000),
            makeTurn(id: "t-early", timestamp: 1000),
            makeTurn(id: "t-mid", timestamp: 3000),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let ordered = try db.read {
            try ChatTurn.order(Column("timestamp").asc).fetchAll($0)
        }
        #expect(ordered[0].id == "t-early")
        #expect(ordered[1].id == "t-mid")
        #expect(ordered[2].id == "t-late")
    }

    @Test("Order by timestamp descending returns reverse chronological order")
    func orderByTimestampDesc() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "t1", timestamp: 1000),
            makeTurn(id: "t2", timestamp: 2000),
            makeTurn(id: "t3", timestamp: 3000),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let ordered = try db.read {
            try ChatTurn.order(Column("timestamp").desc).fetchAll($0)
        }
        #expect(ordered[0].id == "t3")
        #expect(ordered[1].id == "t2")
        #expect(ordered[2].id == "t1")
    }

    // MARK: - Delete by session

    @Test("Delete all turns for a session preserves other sessions")
    func deleteBySession() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "s1-t1", timestamp: 1000, sessionId: "session-A"),
            makeTurn(id: "s1-t2", timestamp: 2000, sessionId: "session-A"),
            makeTurn(id: "s2-t1", timestamp: 3000, sessionId: "session-B"),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let deleted = try db.write {
            try ChatTurn.filter(Column("sessionId") == "session-A").deleteAll($0)
        }
        #expect(deleted == 2)

        let remaining = try db.read { try ChatTurn.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].sessionId == "session-B")
    }

    @Test("Delete all turns clears entire table")
    func deleteAll() throws {
        let db = try TestDatabase.make()
        for i in 0..<5 {
            try db.write { try makeTurn(id: "t\(i)", timestamp: Double(i * 1000)).insert($0) }
        }

        _ = try db.write { try ChatTurn.deleteAll($0) }
        let count = try db.read { try ChatTurn.fetchCount($0) }
        #expect(count == 0)
    }

    // MARK: - databaseTableName

    @Test("databaseTableName is chatTurn")
    func verifyTableName() {
        #expect(ChatTurn.databaseTableName == "chatTurn")
    }

    // MARK: - Computed properties and content

    @Test("User turn content is template name, userMessage is raw text")
    func userTurnContentVsUserMessage() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "ct-1",
            content: "chat_converse",
            userMessage: "What are my reminders?"
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "ct-1") }
        #expect(fetched?.content == "chat_converse")
        #expect(fetched?.userMessage == "What are my reminders?")
    }

    @Test("Assistant turn content is the actual response text")
    func assistantTurnContent() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "ct-2",
            role: "assistant",
            content: "Here are your top 5 emails...",
            userMessage: nil
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "ct-2") }
        #expect(fetched?.content == "Here are your top 5 emails...")
        #expect(fetched?.userMessage == nil)
    }

    @Test("renderedContent stores pre-processed text with resolved pills")
    func renderedContentPills() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "rc-1",
            role: "assistant",
            content: "Check [Email](1)",
            renderedContent: "Check [Email: Meeting Notes](tabmail://email/1)"
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "rc-1") }
        #expect(fetched?.renderedContent?.contains("tabmail://email/1") == true)
        #expect(fetched?.content == "Check [Email](1)")
    }

    // MARK: - ChatTurn type field

    @Test("Type normal is the standard chat turn type")
    func typeNormal() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "type-1", type: "normal")
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "type-1") }
        #expect(fetched?.type == "normal")
    }

    @Test("Type session_break indicates session boundary")
    func typeSessionBreak() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "type-2", type: "session_break")
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "type-2") }
        #expect(fetched?.type == "session_break")
    }

    @Test("Type greeting persists")
    func typeGreeting() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "type-3", type: "greeting")
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "type-3") }
        #expect(fetched?.type == "greeting")
    }

    @Test("Type welcome_back persists")
    func typeWelcomeBack() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "type-4", type: "welcome_back")
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "type-4") }
        #expect(fetched?.type == "welcome_back")
    }

    // MARK: - Chars field

    @Test("Chars field persists and is queryable for budget checks")
    func charsBudget() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "c1", timestamp: 1000, chars: 100),
            makeTurn(id: "c2", timestamp: 2000, chars: 250),
            makeTurn(id: "c3", timestamp: 3000, chars: 50),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let totalChars = try db.read {
            try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(chars), 0) FROM chatTurn")
        }
        #expect(totalChars == 400)
    }

    // MARK: - Multiple sessions ordering

    @Test("Distinct sessions ordered by max timestamp")
    func distinctSessionsOrdered() throws {
        let db = try TestDatabase.make()
        let turns = [
            makeTurn(id: "s1-t1", timestamp: 1000, sessionId: "session-old"),
            makeTurn(id: "s1-t2", timestamp: 2000, sessionId: "session-old"),
            makeTurn(id: "s2-t1", timestamp: 5000, sessionId: "session-new"),
            makeTurn(id: "s3-t1", timestamp: 3000, sessionId: "session-mid"),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        let rows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                GROUP BY sessionId
                ORDER BY maxTs DESC
            """)
        }
        #expect(rows.count == 3)
        let sessionId0: String = rows[0]["sessionId"]
        let sessionId1: String = rows[1]["sessionId"]
        let sessionId2: String = rows[2]["sessionId"]
        #expect(sessionId0 == "session-new")
        #expect(sessionId1 == "session-mid")
        #expect(sessionId2 == "session-old")
    }

    // MARK: - Edge cases

    @Test("Large content persists without truncation")
    func largeContent() throws {
        let db = try TestDatabase.make()
        let longContent = String(repeating: "A", count: 10000)
        let turn = makeTurn(id: "large-1", content: longContent, chars: 10000)
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "large-1") }
        #expect(fetched?.content.count == 10000)
    }

    @Test("Unicode content persists correctly")
    func unicodeContent() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(
            id: "unicode-1",
            content: "Appointment with Dr. Schmidt at 3pm. Reply: Ja, ich komme!",
            userMessage: "Tell me about the email from Herr Schmidt",
            chars: 42
        )
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "unicode-1") }
        #expect(fetched?.content.contains("Schmidt") == true)
        #expect(fetched?.userMessage?.contains("Herr Schmidt") == true)
    }

    @Test("Empty userMessage string persists as empty not nil")
    func emptyUserMessageString() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "empty-1", userMessage: "")
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "empty-1") }
        #expect(fetched?.userMessage == "")
    }

    @Test("Duplicate ID insert throws")
    func duplicateIdThrows() throws {
        let db = try TestDatabase.make()
        let turn1 = makeTurn(id: "dup-1")
        let turn2 = makeTurn(id: "dup-1", content: "different")
        try db.write { try turn1.insert($0) }

        #expect(throws: (any Error).self) {
            try db.write { try turn2.insert($0) }
        }
    }

    @Test("remindersSnapshot JSON round-trip with multiple reminders")
    func remindersSnapshotMultiple() throws {
        let db = try TestDatabase.make()
        let snapshot = "[{\"text\":\"Reply to boss\"},{\"text\":\"Send invoice\",\"due\":\"2026-03-15\"}]"
        let turn = makeTurn(id: "rs-1", remindersSnapshot: snapshot)
        try db.write { try turn.insert($0) }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "rs-1") }
        #expect(fetched?.remindersSnapshot == snapshot)
    }

    @Test("generateId produces timestamp-random format")
    func generateIdFormat() {
        let id = ChatTurn.generateId()
        let parts = id.split(separator: "-")
        #expect(parts.count == 2)
        #expect(Int(parts[0]) != nil)
        #expect(parts[1].count == 6)
    }
}
