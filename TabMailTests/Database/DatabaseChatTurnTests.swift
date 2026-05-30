/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database ChatTurn CRUD")
struct DatabaseChatTurnTests {

    @Test("Insert and fetch chat turns")
    func insertAndFetch() throws {
        let db = try TestDatabase.make()
        let turn1 = ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "Hello", type: "normal", chars: 5, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
        let turn2 = ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "Hi there!", userMessage: nil, type: "normal", chars: 9, renderedContent: "Hi there!", sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)

        try db.write { db in
            try turn1.insert(db)
            try turn2.insert(db)
        }

        let turns = try db.read { try ChatTurn.fetchAll($0) }
        #expect(turns.count == 2)
    }

    @Test("Delete turn by ID")
    func deleteById() throws {
        let db = try TestDatabase.make()
        let turn = ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "test", userMessage: nil, type: "normal", chars: 4, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
        try db.write { try turn.insert($0) }
        try db.write { _ = try ChatTurn.deleteOne($0, key: "t1") }
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "t1") }
        #expect(fetched == nil)
    }

    @Test("Count turns")
    func countTurns() throws {
        let db = try TestDatabase.make()
        for i in 0..<5 {
            let turn = ChatTurn(id: "t\(i)", timestamp: Double(i * 1000), role: "user", content: "msg", userMessage: nil, type: "normal", chars: 3, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
            try db.write { try turn.insert($0) }
        }
        let count = try db.read { try ChatTurn.fetchCount($0) }
        #expect(count == 5)
    }

    @Test("Sum chars via SQL")
    func sumChars() throws {
        let db = try TestDatabase.make()
        let turns = [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "a", userMessage: nil, type: "normal", chars: 100, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "user", content: "b", userMessage: nil, type: "normal", chars: 200, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        try db.write { db in
            for turn in turns { try turn.insert(db) }
        }
        let totalChars = try db.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(chars), 0) FROM chatTurn") }
        #expect(totalChars == 300)
    }

    @Test("Filter by sessionId")
    func filterBySession() throws {
        let db = try TestDatabase.make()
        let turns = [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "a", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "user", content: "b", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: "s2", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 3000, role: "user", content: "c", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        try db.write { db in
            for turn in turns { try turn.insert(db) }
        }
        let s1Turns = try db.read {
            try ChatTurn.filter(Column("sessionId") == "s1").fetchAll($0)
        }
        #expect(s1Turns.count == 2)
    }

    @Test("Delete oldest turns (FIFO budget enforcement)")
    func deleteOldestFIFO() throws {
        let db = try TestDatabase.make()
        for i in 0..<10 {
            let turn = ChatTurn(id: "t\(i)", timestamp: Double(i * 1000), role: "user", content: "msg", userMessage: nil, type: "normal", chars: 10, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
            try db.write { try turn.insert($0) }
        }

        // Delete the 5 oldest turns
        try db.write { db in
            let oldest = try ChatTurn
                .order(Column("timestamp").asc)
                .limit(5)
                .fetchAll(db)
            for old in oldest {
                try old.delete(db)
            }
        }

        let remaining = try db.read { try ChatTurn.order(Column("timestamp").asc).fetchAll($0) }
        #expect(remaining.count == 5)
        #expect(remaining[0].id == "t5") // oldest remaining is t5
    }
}
