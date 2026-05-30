/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ChatStore eviction")
struct ChatEvictionTests {

    private func makeTurn(
        id: String, timestamp: Double, sessionId: String,
        role: String = "assistant", content: String = "text", chars: Int = 10
    ) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: timestamp, role: role,
            content: content, userMessage: nil,
            type: "normal", chars: chars, renderedContent: nil,
            sessionId: sessionId, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    private func makeHistoryTurn(
        id: String, timestamp: Double, sessionId: String,
        content: String = "text", chars: Int = 10
    ) -> ChatHistoryTurn {
        ChatHistoryTurn(
            id: id, timestamp: timestamp, role: "assistant",
            content: content, userMessage: nil,
            sessionId: sessionId, chars: chars, type: "normal"
        )
    }

    // MARK: - Inbox Session Eviction

    @Test("Inbox eviction keeps newest N sessions, deletes oldest")
    func inboxEvictionKeepsNewest() throws {
        let db = try TestDatabase.make()
        // 3 inbox sessions: s0 (oldest), s1, s2 (newest)
        for i in 0..<3 {
            try db.write { dbConn in
                try makeTurn(id: "t\(i)", timestamp: Double(i * 1000), sessionId: "session-\(i)").insert(dbConn)
            }
        }

        // Evict with limit=1
        let evicted = try db.write { dbConn -> Int in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs FROM chatTurn
                WHERE sessionId IS NOT NULL AND sessionId NOT LIKE 'msg:%' AND sessionId NOT LIKE 'compose:%'
                GROUP BY sessionId ORDER BY maxTs DESC
            """)
            var count = 0
            for (index, row) in rows.enumerated() {
                if index < 1 { continue }
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(dbConn)
                count += 1
            }
            return count
        }

        #expect(evicted == 2)
        let remaining = try db.read { try ChatTurn.fetchCount($0) }
        #expect(remaining == 1)
        // Newest session survives
        let survivor = try db.read { try ChatTurn.fetchOne($0, key: "t2") }
        #expect(survivor != nil)
    }

    @Test("Inbox eviction excludes msg: and compose: sessions")
    func inboxEvictionExcludesOtherTypes() throws {
        let db = try TestDatabase.make()
        try db.write { dbConn in
            try makeTurn(id: "inbox1", timestamp: 1000, sessionId: "s1").insert(dbConn)
            try makeTurn(id: "msg1", timestamp: 2000, sessionId: "msg:acct:id1").insert(dbConn)
            try makeTurn(id: "compose1", timestamp: 3000, sessionId: "compose:draft1").insert(dbConn)
        }

        // Evict inbox with limit=0 (evict all inbox sessions)
        let evicted = try db.write { dbConn -> Int in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs FROM chatTurn
                WHERE sessionId IS NOT NULL AND sessionId NOT LIKE 'msg:%' AND sessionId NOT LIKE 'compose:%'
                GROUP BY sessionId ORDER BY maxTs DESC
            """)
            var count = 0
            for row in rows {
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(dbConn)
                count += 1
            }
            return count
        }

        #expect(evicted == 1) // Only inbox session evicted
        let remaining = try db.read { try ChatTurn.fetchCount($0) }
        #expect(remaining == 2) // msg + compose survive
    }

    // MARK: - Compose Session Eviction (TTL)

    @Test("Compose TTL eviction deletes old sessions, keeps recent")
    func composeTTLEviction() throws {
        let db = try TestDatabase.make()
        let now = Date().timeIntervalSince1970 * 1000
        let oldTs = now - (31 * 86400 * 1000) // 31 days ago
        let recentTs = now - (1 * 86400 * 1000) // 1 day ago

        try db.write { dbConn in
            try makeTurn(id: "old1", timestamp: oldTs, sessionId: "compose:old-draft").insert(dbConn)
            try makeTurn(id: "recent1", timestamp: recentTs, sessionId: "compose:recent-draft").insert(dbConn)
        }

        let cutoffMs = (Date().timeIntervalSince1970 - 30 * 86400) * 1000
        let evicted = try db.write { dbConn -> Int in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs FROM chatTurn
                WHERE sessionId LIKE 'compose:%' GROUP BY sessionId HAVING maxTs < ?
            """, arguments: [cutoffMs])
            var count = 0
            for row in rows {
                let sid: String = row["sessionId"]
                _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(dbConn)
                count += 1
            }
            return count
        }

        #expect(evicted == 1)
        let remaining = try db.read { try ChatTurn.fetchOne($0, key: "recent1") }
        #expect(remaining != nil)
    }

    // MARK: - History Turn Cap

    @Test("History cap evicts oldest, keeps newest")
    func historyCapEviction() throws {
        let db = try TestDatabase.make()
        try db.write { dbConn in
            for i in 0..<10 {
                try makeHistoryTurn(id: "h\(i)", timestamp: Double(i * 1000), sessionId: "s").save(dbConn)
            }
        }

        let evicted = try db.write { dbConn -> Int in
            let total = try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM chatHistory") ?? 0
            guard total > 5 else { return 0 }
            try dbConn.execute(sql: """
                DELETE FROM chatHistory WHERE id IN (SELECT id FROM chatHistory ORDER BY timestamp ASC LIMIT ?)
            """, arguments: [total - 5])
            return dbConn.changesCount
        }

        #expect(evicted == 5)
        let oldest = try db.read { try ChatHistoryTurn.fetchOne($0, key: "h0") }
        #expect(oldest == nil)
        let newest = try db.read { try ChatHistoryTurn.fetchOne($0, key: "h9") }
        #expect(newest != nil)
    }

    // MARK: - Session eviction preserves history

    @Test("Session eviction does not touch chatHistory table")
    func sessionEvictionPreservesHistory() throws {
        let db = try TestDatabase.make()
        try db.write { dbConn in
            try makeTurn(id: "t1", timestamp: 1000, sessionId: "old-session").insert(dbConn)
            try makeHistoryTurn(id: "t1", timestamp: 1000, sessionId: "old-session").save(dbConn)
        }

        // Delete the session turn
        try db.write { dbConn in
            _ = try ChatTurn.filter(Column("sessionId") == "old-session").deleteAll(dbConn)
        }

        let sessionCount = try db.read { try ChatTurn.fetchCount($0) }
        let historyCount = try db.read { try ChatHistoryTurn.fetchCount($0) }
        #expect(sessionCount == 0)
        #expect(historyCount == 1) // History preserved
    }
}
