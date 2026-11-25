/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A per-thread chat (`thread:` session) is never an inbox chat.
///
/// A database written by a newer build can hold `thread:` sessions. The inbox
/// chat's session list (`ChatStore.loadSessions`) and its session limit
/// (`evictInboxSessionsSync`, run by sync maintenance) must neither list nor
/// count such a session, and must never delete it: a thread's chat is not the
/// inbox chat's to clear. Both run the real `ChatStore` code against an
/// installed database.
@Suite("Thread chat sessions stay out of the inbox chat's list and limit", .serialized, .processGlobalState)
struct ChatStoreThreadSessionScopeTests {

    /// Sessions newest first: a thread chat, three inbox chats, an older thread chat.
    static let newerThread = "thread:acc-1:thread-newer"
    static let inboxNewest = "inbox-session-a"
    static let inboxMiddle = "inbox-session-b"
    static let inboxOldest = "inbox-session-c"
    static let olderThread = "thread:acc-1:thread-older"
    static let newestFirst = [newerThread, inboxNewest, inboxMiddle, inboxOldest, olderThread]

    private static func seed(_ pool: DatabasePool) throws {
        let now = Date().timeIntervalSince1970 * 1000
        try pool.write { db in
            for (age, sessionId) in newestFirst.enumerated() {
                let turn = ChatTurn(
                    id: "turn-\(UUID().uuidString)", timestamp: now - Double(age) * 60_000, role: "user",
                    content: "chat_converse", userMessage: "a question", type: "normal", chars: 10,
                    renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil,
                    emailContextJSON: nil, thinkingContent: nil)
                try turn.insert(db)
            }
        }
    }

    private static func sessionsLeft(_ pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT sessionId FROM chatTurn WHERE sessionId IS NOT NULL"))
        }
    }

    @Test("The inbox chat's session list never lists or counts a thread chat")
    func inboxSessionListSkipsThreadChats() async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        try Self.seed(pool)

        // Two slots: the two newest INBOX chats fill them; the newer thread chat takes none.
        let firstTwo = try await ChatStore.shared.loadSessions(limit: 2, demoActive: false).map(\.id)
        #expect(Set(firstTwo) == [Self.inboxNewest, Self.inboxMiddle], "listed: \(firstTwo)")

        // Room for all: every inbox chat, no thread chat.
        let all = try await ChatStore.shared.loadSessions(limit: Self.newestFirst.count, demoActive: false).map(\.id)
        #expect(Set(all) == [Self.inboxNewest, Self.inboxMiddle, Self.inboxOldest], "listed: \(all)")
    }

    @Test("The inbox chat's session limit neither counts nor deletes a thread chat")
    func inboxSessionLimitKeepsThreadChats() throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        try Self.seed(pool)

        // Limit 2 over three inbox chats: only the oldest inbox chat goes.
        let evicted = try ChatStore.shared.evictInboxSessionsSync(dbPool: PrioritizedDatabase(pool: pool), limit: 2)
        #expect(evicted == 1, "one inbox chat over the limit")
        let left = try Self.sessionsLeft(pool)
        #expect(left == [Self.newerThread, Self.inboxNewest, Self.inboxMiddle, Self.olderThread], "left: \(left.sorted())")
    }
}
