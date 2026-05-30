/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ChatTurn")
struct ChatTurnTests {

    @Test("generateId format: timestamp-random")
    func generateIdFormat() {
        let id = ChatTurn.generateId()
        let parts = id.split(separator: "-")
        #expect(parts.count == 2)
        // First part is a timestamp (numeric)
        #expect(Int(parts[0]) != nil)
        // Second part is 6 alphanumeric chars
        #expect(parts[1].count == 6)
    }

    @Test("generateId produces unique IDs")
    func generateIdUnique() {
        let ids = (0..<100).map { _ in ChatTurn.generateId() }
        let uniqueIds = Set(ids)
        #expect(uniqueIds.count == ids.count)
    }

    @Test("databaseTableName is chatTurn")
    func tableName() {
        #expect(ChatTurn.databaseTableName == "chatTurn")
    }

    @Test("ChatTurn GRDB round-trip")
    func grdbRoundTrip() throws {
        let db = try TestDatabase.make()
        let turn = ChatTurn(
            id: "123-abc",
            timestamp: 1000,
            role: "user",
            content: "chat_converse",
            userMessage: "Hello there",
            type: "normal",
            chars: 11,
            renderedContent: "Hello there",
            sessionId: "session-1",
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "123-abc") }
        #expect(fetched != nil)
        #expect(fetched?.role == "user")
        #expect(fetched?.userMessage == "Hello there")
        #expect(fetched?.sessionId == "session-1")
        #expect(fetched?.type == "normal")
        #expect(fetched?.chars == 11)
    }

    @Test("ChatTurn with nil optional fields")
    func nilOptionalFields() throws {
        let db = try TestDatabase.make()
        let turn = ChatTurn(
            id: "456-def",
            timestamp: 2000,
            role: "assistant",
            content: "Sure!",
            userMessage: nil,
            type: "normal",
            chars: 5,
            renderedContent: nil,
            sessionId: nil,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "456-def") }
        #expect(fetched?.userMessage == nil)
        #expect(fetched?.renderedContent == nil)
        #expect(fetched?.sessionId == nil)
        #expect(fetched?.remindersSnapshot == nil)
    }

    @Test("ChatTurn ordering by timestamp")
    func orderByTimestamp() throws {
        let db = try TestDatabase.make()
        let turns = [
            ChatTurn(id: "3-c", timestamp: 3000, role: "user", content: "c", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "1-a", timestamp: 1000, role: "user", content: "a", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "2-b", timestamp: 2000, role: "user", content: "b", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        try db.write { db in
            for turn in turns { try turn.insert(db) }
        }
        let ordered = try db.read {
            try ChatTurn.order(Column("timestamp").asc).fetchAll($0)
        }
        #expect(ordered[0].id == "1-a")
        #expect(ordered[1].id == "2-b")
        #expect(ordered[2].id == "3-c")
    }

    @Test("ChatTurn with remindersSnapshot JSON")
    func remindersSnapshot() throws {
        let db = try TestDatabase.make()
        let turn = ChatTurn(
            id: "789-ghi",
            timestamp: 5000,
            role: "user",
            content: "chat_converse",
            userMessage: "Hi",
            type: "normal",
            chars: 2,
            renderedContent: nil,
            sessionId: "s1",
            remindersSnapshot: "[{\"text\":\"Remember to reply\"}]",
            emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "789-ghi") }
        #expect(fetched?.remindersSnapshot?.contains("Remember to reply") == true)
    }
}
