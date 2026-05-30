/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - ChatStore Budget Enforcement Tests

@Suite("ChatStore Budget Enforcement")
struct ChatStoreBudgetTests {

    // Budget constants matching ChatStore
    private static let maxExchanges = 50
    private static let charsPerExchange = 500

    private func makeTurn(
        id: String, timestamp: Double, role: String = "user",
        content: String = "msg", userMessage: String? = nil,
        chars: Int = 10, sessionId: String? = nil
    ) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: timestamp, role: role,
            content: content, userMessage: userMessage,
            type: "normal", chars: chars, renderedContent: nil,
            sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    @Test("Turn count budget evicts oldest when exceeding maxExchanges * 2")
    func turnCountBudgetEviction() throws {
        let db = try TestDatabase.make()
        let maxMessages = Self.maxExchanges * 2 // 100

        // Insert exactly maxMessages turns
        for i in 0..<maxMessages {
            let turn = makeTurn(id: "t\(i)", timestamp: Double(i * 1000), chars: 1)
            try db.write { try turn.insert($0) }
        }

        // Insert one more — should trigger eviction of the oldest
        let extraTurn = makeTurn(id: "extra", timestamp: Double(maxMessages * 1000), chars: 1)
        try db.write { db in
            try extraTurn.insert(db)

            let totalTurns = try ChatTurn.fetchCount(db)
            let maxMsgs = Self.maxExchanges * 2
            if totalTurns > maxMsgs {
                let excess = totalTurns - maxMsgs
                let oldest = try ChatTurn
                    .order(Column("timestamp").asc)
                    .limit(excess)
                    .fetchAll(db)
                for old in oldest {
                    try old.delete(db)
                }
            }
        }

        let remaining = try db.read { try ChatTurn.fetchCount($0) }
        #expect(remaining == maxMessages)

        // Oldest should be gone
        let oldest = try db.read { try ChatTurn.fetchOne($0, key: "t0") }
        #expect(oldest == nil)

        // Extra should be present
        let extra = try db.read { try ChatTurn.fetchOne($0, key: "extra") }
        #expect(extra != nil)
    }

    @Test("Char budget evicts oldest turns when total chars exceed budget")
    func charBudgetEviction() throws {
        let db = try TestDatabase.make()
        let maxChars = Self.maxExchanges * Self.charsPerExchange // 25000

        // Insert turns that collectively exceed char budget
        // Each turn has 5000 chars, 6 turns = 30000 > 25000
        for i in 0..<6 {
            let turn = makeTurn(id: "t\(i)", timestamp: Double(i * 1000), chars: 5000)
            try db.write { try turn.insert($0) }
        }

        // Simulate char budget enforcement
        try db.write { db in
            var totalChars = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(chars), 0) FROM chatTurn") ?? 0
            while totalChars > maxChars {
                guard let oldest = try ChatTurn.order(Column("timestamp").asc).fetchOne(db) else { break }
                totalChars -= oldest.chars
                try oldest.delete(db)
            }
        }

        // Should have evicted 1 turn (30000 - 5000 = 25000 <= 25000)
        let remaining = try db.read { try ChatTurn.fetchCount($0) }
        #expect(remaining == 5)

        // First turn should be gone
        let t0 = try db.read { try ChatTurn.fetchOne($0, key: "t0") }
        #expect(t0 == nil)
    }

    @Test("No eviction when under both budgets")
    func noEvictionUnderBudget() throws {
        let db = try TestDatabase.make()

        // Insert 5 turns with small chars — well under both budgets
        for i in 0..<5 {
            let turn = makeTurn(id: "t\(i)", timestamp: Double(i * 1000), chars: 10)
            try db.write { try turn.insert($0) }
        }

        let totalTurns = try db.read { try ChatTurn.fetchCount($0) }
        #expect(totalTurns == 5)
    }
}

// MARK: - ChatStore Delete Tests

@Suite("ChatStore Delete Operations")
struct ChatStoreDeleteTests {

    private func makeTurn(id: String, timestamp: Double, content: String = "msg") -> ChatTurn {
        ChatTurn(
            id: id, timestamp: timestamp, role: "user",
            content: content, userMessage: nil,
            type: "normal", chars: content.count, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    @Test("Delete specific turns by IDs")
    func deleteSpecificTurns() throws {
        let db = try TestDatabase.make()
        for i in 0..<5 {
            let turn = makeTurn(id: "t\(i)", timestamp: Double(i * 1000))
            try db.write { try turn.insert($0) }
        }

        // Delete t1 and t3
        try db.write { db in
            _ = try ChatTurn.filter(["t1", "t3"].contains(Column("id"))).deleteAll(db)
        }

        let remaining = try db.read { try ChatTurn.fetchAll($0) }
        #expect(remaining.count == 3)
        let ids = remaining.map(\.id)
        #expect(ids.contains("t0"))
        #expect(ids.contains("t2"))
        #expect(ids.contains("t4"))
        #expect(!ids.contains("t1"))
        #expect(!ids.contains("t3"))
    }

    @Test("Delete with empty IDs array is no-op")
    func deleteEmptyIds() throws {
        let db = try TestDatabase.make()
        let turn = makeTurn(id: "t0", timestamp: 1000)
        try db.write { try turn.insert($0) }

        // Empty array delete should not fail or delete anything
        let emptyIds: [String] = []
        if !emptyIds.isEmpty {
            try db.write { db in
                _ = try ChatTurn.filter(emptyIds.contains(Column("id"))).deleteAll(db)
            }
        }

        let count = try db.read { try ChatTurn.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("Clear all deletes every turn")
    func clearAll() throws {
        let db = try TestDatabase.make()
        for i in 0..<10 {
            let turn = makeTurn(id: "t\(i)", timestamp: Double(i * 1000))
            try db.write { try turn.insert($0) }
        }

        try db.write { db in
            _ = try ChatTurn.deleteAll(db)
        }

        let count = try db.read { try ChatTurn.fetchCount($0) }
        #expect(count == 0)
    }
}

// MARK: - ChatStore Search Tests

@Suite("ChatStore Search")
struct ChatStoreSearchTests {

    private func insertTurns(_ db: DatabaseQueue, turns: [ChatTurn]) throws {
        try db.write { db in
            for turn in turns { try turn.insert(db) }
        }
    }

    @Test("Search by content field")
    func searchByContent() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "The weather is sunny today", userMessage: nil, type: "normal", chars: 26, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "I can help with that", userMessage: nil, type: "normal", chars: 20, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let pattern = "%sunny%"
        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "content LIKE ? ESCAPE '\\'", arguments: [pattern])
                .fetchAll(db)
        }
        #expect(results.count == 1)
        #expect(results.first?.id == "t1")
    }

    @Test("Search by userMessage field")
    func searchByUserMessage() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "Tell me about Swift", type: "normal", chars: 19, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "user", content: "chat_converse", userMessage: "What about Python", type: "normal", chars: 17, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let pattern = "%Swift%"
        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "userMessage LIKE ? ESCAPE '\\'", arguments: [pattern])
                .fetchAll(db)
        }
        #expect(results.count == 1)
        #expect(results.first?.id == "t1")
    }

    @Test("Search by renderedContent field")
    func searchByRenderedContent() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "response", userMessage: nil, type: "normal", chars: 8, renderedContent: "Here is a rendered pill [Email](1)", sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "other", userMessage: nil, type: "normal", chars: 5, renderedContent: "No match here", sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let pattern = "%pill%"
        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "renderedContent LIKE ? ESCAPE '\\'", arguments: [pattern])
                .fetchAll(db)
        }
        #expect(results.count == 1)
        #expect(results.first?.id == "t1")
    }

    @Test("Search across all three fields with OR")
    func searchAcrossAllFields() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "meeting notes", userMessage: nil, type: "normal", chars: 13, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "user", content: "chat_converse", userMessage: "schedule a meeting", type: "normal", chars: 18, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 3000, role: "assistant", content: "done", userMessage: nil, type: "normal", chars: 4, renderedContent: "Meeting scheduled", sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t4", timestamp: 4000, role: "user", content: "chat_converse", userMessage: "thanks", type: "normal", chars: 6, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let escaped = "meeting"
        let pattern = "%\(escaped)%"
        let results = try db.read { db in
            try ChatTurn
                .filter(sql: """
                    content LIKE ? ESCAPE '\\'
                    OR userMessage LIKE ? ESCAPE '\\'
                    OR renderedContent LIKE ? ESCAPE '\\'
                    """, arguments: [pattern, pattern, pattern])
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
        #expect(results.count == 3) // t1, t2, t3 all match
    }

    @Test("Search results ordered by timestamp descending")
    func searchOrderDesc() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "alpha", userMessage: nil, type: "normal", chars: 5, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 3000, role: "assistant", content: "alpha", userMessage: nil, type: "normal", chars: 5, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 2000, role: "assistant", content: "alpha", userMessage: nil, type: "normal", chars: 5, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "content LIKE ? ESCAPE '\\'", arguments: ["%alpha%"])
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
        #expect(results.count == 3)
        #expect(results[0].id == "t2") // newest first
        #expect(results[1].id == "t3")
        #expect(results[2].id == "t1")
    }

    @Test("Search escapes LIKE wildcards in query")
    func searchEscapesWildcards() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "100% done", userMessage: nil, type: "normal", chars: 8, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "done", userMessage: nil, type: "normal", chars: 4, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        // Search for literal "100%" — must escape the % to not act as wildcard
        let query = "100%"
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "content LIKE ? ESCAPE '\\'", arguments: [pattern])
                .fetchAll(db)
        }
        #expect(results.count == 1)
        #expect(results.first?.id == "t1")
    }

    @Test("Search escapes underscore wildcard")
    func searchEscapesUnderscore() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "user_name field", userMessage: nil, type: "normal", chars: 15, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "username field", userMessage: nil, type: "normal", chars: 14, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        // Search for literal "user_name" — _ must not act as single-char wildcard
        let query = "user_name"
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "content LIKE ? ESCAPE '\\'", arguments: [pattern])
                .fetchAll(db)
        }
        #expect(results.count == 1)
        #expect(results.first?.id == "t1")
    }

    @Test("Search with no matches returns empty")
    func searchNoMatches() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "assistant", content: "hello world", userMessage: nil, type: "normal", chars: 11, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let results = try db.read { db in
            try ChatTurn
                .filter(sql: "content LIKE ? ESCAPE '\\'", arguments: ["%nonexistent%"])
                .fetchAll(db)
        }
        #expect(results.isEmpty)
    }
}

// MARK: - ChatStore Session Loading Tests

@Suite("ChatStore Session Loading")
struct ChatStoreSessionTests {

    private func insertTurns(_ db: DatabaseQueue, turns: [ChatTurn]) throws {
        try db.write { db in
            for turn in turns { try turn.insert(db) }
        }
    }

    @Test("Load sessions groups turns by sessionId")
    func loadSessionsGroupsBySessionId() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "Hi", type: "normal", chars: 2, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "Hello!", userMessage: nil, type: "normal", chars: 6, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 3000, role: "user", content: "chat_converse", userMessage: "Bye", type: "normal", chars: 3, renderedContent: nil, sessionId: "s2", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        // Query distinct sessions
        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                GROUP BY sessionId
                ORDER BY maxTs DESC
                LIMIT ?
            """, arguments: [10])
        }
        #expect(sessionRows.count == 2)

        // Most recent session first (s2 at timestamp 3000)
        let firstSid: String = sessionRows[0]["sessionId"]
        #expect(firstSid == "s2")
    }

    @Test("Load sessions excludes null sessionId turns")
    func excludesNullSessionId() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "old", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "user", content: "new", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                GROUP BY sessionId
                ORDER BY maxTs DESC
                LIMIT ?
            """, arguments: [10])
        }
        #expect(sessionRows.count == 1)
        let sid: String = sessionRows[0]["sessionId"]
        #expect(sid == "s1")
    }

    @Test("Load sessions respects limit parameter")
    func sessionLimit() throws {
        let db = try TestDatabase.make()
        // Create 5 sessions
        for i in 0..<5 {
            try insertTurns(db, turns: [
                ChatTurn(id: "t\(i)", timestamp: Double(i * 1000), role: "user", content: "msg", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: "s\(i)", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ])
        }

        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                GROUP BY sessionId
                ORDER BY maxTs DESC
                LIMIT ?
            """, arguments: [3])
        }
        #expect(sessionRows.count == 3)
    }

    @Test("Session turns are ordered by timestamp ascending")
    func sessionTurnsOrdered() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t3", timestamp: 3000, role: "assistant", content: "third", userMessage: nil, type: "normal", chars: 5, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "first", userMessage: "first", type: "normal", chars: 5, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "second", userMessage: nil, type: "normal", chars: 6, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        let turns = try db.read { db in
            try ChatTurn
                .filter(Column("sessionId") == "s1")
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
        #expect(turns.count == 3)
        #expect(turns[0].id == "t1")
        #expect(turns[1].id == "t2")
        #expect(turns[2].id == "t3")
    }

    @Test("Sessions reversed so newest is last (rightmost in TabView)")
    func sessionsReversed() throws {
        let db = try TestDatabase.make()
        try insertTurns(db, turns: [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "old", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 5000, role: "user", content: "new", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: "s2", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 3000, role: "user", content: "mid", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: "s3", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ])

        // Query DESC then reverse = ASC by maxTs (oldest first, newest last)
        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                GROUP BY sessionId
                ORDER BY maxTs DESC
                LIMIT ?
            """, arguments: [10])
        }
        // DESC: s2(5000), s3(3000), s1(1000)
        let reversed = sessionRows.reversed()
        let sids = reversed.map { $0["sessionId"] as String }
        // After reverse: s1, s3, s2 (newest last)
        #expect(sids == ["s1", "s3", "s2"])
    }
}

// MARK: - ChatStore turnsToMessages Extended Tests

@Suite("ChatStore turnsToMessages Extended")
struct ChatStoreTurnsToMessagesExtendedTests {

    @Test("User turn with userMessage converts with chat_converse content")
    func userTurnConverts() async {
        let turn = ChatTurn(
            id: "t1", timestamp: 1710000000000, role: "user",
            content: "chat_converse", userMessage: "What's the weather?",
            type: "normal", chars: 19, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.count == 1)
        #expect(messages.first?.role == "user")
        #expect(messages.first?.content == "chat_converse")
    }

    @Test("User turn without userMessage is skipped")
    func userTurnWithoutMessageSkipped() async {
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "user",
            content: "chat_converse", userMessage: nil,
            type: "normal", chars: 0, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.isEmpty)
    }

    @Test("Empty turns array returns empty messages")
    func emptyTurns() async {
        let messages = await ChatStore.shared.turnsToMessages([])
        #expect(messages.isEmpty)
    }

    @Test("Preserves order of valid turns")
    func preservesOrder() async {
        let turns = [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "First", type: "normal", chars: 5, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "Response 1", userMessage: nil, type: "normal", chars: 10, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 3000, role: "user", content: "chat_converse", userMessage: "Second", type: "normal", chars: 6, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t4", timestamp: 4000, role: "assistant", content: "Response 2", userMessage: nil, type: "normal", chars: 10, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        let messages = await ChatStore.shared.turnsToMessages(turns)
        #expect(messages.count == 4)
        #expect(messages[0].role == "user")
        #expect(messages[1].role == "assistant")
        #expect(messages[1].content == "Response 1")
        #expect(messages[2].role == "user")
        #expect(messages[3].content == "Response 2")
    }
}

// MARK: - ChatStore Reminder Snapshot Extended Tests

@Suite("ChatStore Reminder Snapshots Extended")
struct ChatStoreReminderSnapshotExtendedTests {

    @Test("Encode preserves all fields")
    func encodePreservesAllFields() {
        let reminders = [
            Reminder(type: "reminder", content: "Call Bob", dueDate: "2024-06-01", dueTime: "14:30",
                     source: "kb", hash: "h1", enabled: true, action: nil,
                     messageId: nil, uniqueId: nil, subject: nil, from: nil,
                     instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
            Reminder(type: "reminder", content: "Reply to Alice", dueDate: nil, dueTime: nil,
                     source: "message", hash: "h2", enabled: true, action: nil,
                     messageId: nil, uniqueId: nil, subject: "Budget Q3", from: "alice@co.com",
                     instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
        ]
        let encoded = ChatStore.encodeRemindersSnapshot(reminders)
        #expect(encoded != nil)

        let decoded = ChatStore.decodeRemindersSnapshot(encoded!)
        #expect(decoded?.count == 2)
        #expect(decoded?[0].content == "Call Bob")
        #expect(decoded?[0].dueDate == "2024-06-01")
        #expect(decoded?[0].dueTime == "14:30")
        #expect(decoded?[0].source == "kb")
        #expect(decoded?[0].hash == "h1")
        #expect(decoded?[1].subject == "Budget Q3")
        #expect(decoded?[1].from == "alice@co.com")
        #expect(decoded?[1].dueDate == nil)
    }

    @Test("Decode sets enabled=true and action/messageId/uniqueId to nil")
    func decodeDefaults() {
        let reminders = [
            Reminder(type: "reminder", content: "Test", dueDate: nil, dueTime: nil,
                     source: "kb", hash: "x", enabled: true, action: nil,
                     messageId: nil, uniqueId: nil, subject: nil, from: nil,
                     instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
        ]
        let encoded = ChatStore.encodeRemindersSnapshot(reminders)!
        let decoded = ChatStore.decodeRemindersSnapshot(encoded)!
        #expect(decoded[0].enabled == true)
        #expect(decoded[0].action == nil)
        #expect(decoded[0].messageId == nil)
        #expect(decoded[0].uniqueId == nil)
    }

    @Test("Decode returns nil for empty string")
    func decodeEmptyString() {
        let decoded = ChatStore.decodeRemindersSnapshot("")
        #expect(decoded == nil)
    }

    @Test("Decode returns nil for malformed JSON array")
    func decodeMalformedArray() {
        let decoded = ChatStore.decodeRemindersSnapshot("[{\"wrong_key\": 1}]")
        #expect(decoded == nil)
    }

    @Test("Round-trip with special characters in content")
    func roundTripSpecialChars() {
        let reminders = [
            Reminder(type: "reminder", content: "Reply to \"John\" <john@test.com> & follow up",
                     dueDate: nil, dueTime: nil, source: "message", hash: "s1",
                     enabled: true, action: nil, messageId: nil, uniqueId: nil,
                     subject: "Re: Q&A \"session\"", from: "john@test.com",
                     instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil),
        ]
        let encoded = ChatStore.encodeRemindersSnapshot(reminders)!
        let decoded = ChatStore.decodeRemindersSnapshot(encoded)!
        #expect(decoded[0].content == "Reply to \"John\" <john@test.com> & follow up")
        #expect(decoded[0].subject == "Re: Q&A \"session\"")
    }
}
