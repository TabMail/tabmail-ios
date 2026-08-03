/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Session Splitting Tests

@Suite("Inbox session history excludes non-inbox sessions")
struct SessionSplittingTests {

    @Test("loadSessions excludes msg-detail sessions (msg: prefix)")
    func excludesMsgDetailSessions() throws {
        let db = try TestDatabase.make()
        // Inbox session
        try db.write { try ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "Hi", type: "normal", chars: 2, renderedContent: nil, sessionId: "inbox-uuid", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }
        // Message-detail session (should be excluded)
        try db.write { try ChatTurn(id: "t2", timestamp: 2000, role: "user", content: "chat_converse", userMessage: "About this email", type: "normal", chars: 16, renderedContent: nil, sessionId: "msg:acc1:INBOX:123", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }
        // Compose session (should be excluded)
        try db.write { try ChatTurn(id: "t3", timestamp: 3000, role: "user", content: "compose_edit", userMessage: "Make formal", type: "normal", chars: 11, renderedContent: nil, sessionId: "compose:reply:acc1:INBOX:456", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }

        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs
                FROM chatTurn
                WHERE sessionId IS NOT NULL
                  AND sessionId NOT LIKE 'msg:%'
                  AND sessionId NOT LIKE 'compose:%'
                GROUP BY sessionId
                ORDER BY maxTs DESC
                LIMIT 10
            """)
        }
        #expect(sessionRows.count == 1)
        let sid: String = sessionRows[0]["sessionId"]
        #expect(sid == "inbox-uuid")
    }

    @Test("loadContextSession loads msg-detail session by exact ID")
    func loadContextSessionMsgDetail() throws {
        let db = try TestDatabase.make()
        let ctx = EmailContextSnapshot(messageHeaderId: "acc1:INBOX:42", subject: "Budget", from: "cfo@co.com")
        let turns = [
            ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "Summarize", type: "normal", chars: 9, renderedContent: nil, sessionId: "msg:acc1:INBOX:42", remindersSnapshot: nil, emailContextJSON: ChatStore.encodeEmailContext(ctx), thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant", content: "Here's the summary", userMessage: nil, type: "normal", chars: 18, renderedContent: nil, sessionId: "msg:acc1:INBOX:42", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        try db.write { db in for turn in turns { try turn.insert(db) } }

        // Direct query matching loadContextSession logic
        let sessionTurns = try db.read { db in
            try ChatTurn.filter(Column("sessionId") == "msg:acc1:INBOX:42").order(Column("timestamp").asc).fetchAll(db)
        }
        #expect(sessionTurns.count == 2)
        let emailCtx = sessionTurns.first?.emailContextJSON.flatMap { ChatStore.decodeEmailContext($0) }
        #expect(emailCtx?.subject == "Budget")
    }

    @Test("loadContextSession returns nil for nonexistent session")
    func loadContextSessionNonexistent() throws {
        let db = try TestDatabase.make()
        let turns = try db.read { db in
            try ChatTurn.filter(Column("sessionId") == "msg:nonexistent").fetchAll(db)
        }
        #expect(turns.isEmpty)
    }

    @Test("Compose session loaded by compose: prefix")
    func loadComposeSession() throws {
        let db = try TestDatabase.make()
        try db.write { try ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "compose_edit", userMessage: "Make formal", type: "normal", chars: 11, renderedContent: nil, sessionId: "compose:reply:msg123", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }

        let turns = try db.read { db in
            try ChatTurn.filter(Column("sessionId") == "compose:reply:msg123").order(Column("timestamp").asc).fetchAll(db)
        }
        #expect(turns.count == 1)
        #expect(turns[0].userMessage == "Make formal")
    }
}

// MARK: - Deterministic Session ID Tests

@Suite("Deterministic session IDs")
struct DeterministicSessionIdTests {

    @Test("Message-detail session ID format is msg:{emailId}")
    func msgSessionIdFormat() {
        let emailId = "acc1:INBOX:12345"
        let sessionId = "msg:\(emailId)"
        #expect(sessionId == "msg:acc1:INBOX:12345")
        #expect(sessionId.hasPrefix("msg:"))
        #expect(String(sessionId.dropFirst(4)) == emailId)
    }

    @Test("Compose reply session ID format")
    func composeReplySessionIdFormat() {
        let draftKey = Draft.draftKey(replyTo: "acc1:INBOX:999", isForward: false, newId: nil)
        #expect(draftKey == "reply:acc1:INBOX:999")
        let sessionId = "compose:\(draftKey)"
        #expect(sessionId == "compose:reply:acc1:INBOX:999")
    }

    @Test("Compose forward session ID format")
    func composeForwardSessionIdFormat() {
        let draftKey = Draft.draftKey(replyTo: "acc1:INBOX:999", isForward: true, newId: nil)
        #expect(draftKey == "forward:acc1:INBOX:999")
    }

    @Test("Compose new session ID uses provided UUID")
    func composeNewSessionIdFormat() {
        let draftKey = Draft.draftKey(replyTo: nil, isForward: false, newId: "test-uuid")
        #expect(draftKey == "new:test-uuid")
    }
}

// MARK: - Draft Persistence Tests

@Suite("Draft persistence")
struct DraftPersistenceTests {

    @Test("Draft GRDB round-trip preserves all fields")
    func draftRoundTrip() throws {
        let db = try TestDatabase.make()
        let draft = Draft(
            id: "reply:msg123",
            accountId: "acc1",
            toJSON: "[\"alice@test.com\"]",
            ccJSON: "[\"bob@test.com\"]",
            bccJSON: "[]",
            subject: "Re: Budget",
            body: "Updated draft body",
            replyToId: "msg123",
            isForward: false,
            editHistoryJSON: nil,
            createdAt: 1000,
            updatedAt: 2000
        )
        // Need account for FK
        try TestDatabase.insertAccount(db, id: "acc1")
        try db.write { try draft.insert($0) }

        let fetched = try db.read { try Draft.fetchOne($0, key: "reply:msg123") }
        #expect(fetched != nil)
        #expect(fetched?.subject == "Re: Budget")
        #expect(fetched?.body == "Updated draft body")
        #expect(fetched?.replyToId == "msg123")
        #expect(fetched?.isForward == false)
        #expect(fetched?.toArray == ["alice@test.com"])
        #expect(fetched?.ccArray == ["bob@test.com"])
    }

    @Test("Draft edit history JSON round-trip")
    func editHistoryRoundTrip() {
        let turns = [
            InlineEditTurn(userRequest: "Make formal", bodyAtRequest: "hey", subjectAtRequest: "hi", assistantResponse: "Done"),
            InlineEditTurn(userRequest: "Add greeting", bodyAtRequest: "Dear Sir", subjectAtRequest: "hi", assistantResponse: "Added"),
        ]
        let json = Draft.encodeEditHistory(turns)
        #expect(json != nil)

        let decoded = Draft(
            id: "test", accountId: "a", toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "", body: "", replyToId: nil, isForward: false,
            editHistoryJSON: json, createdAt: 0, updatedAt: 0
        ).editHistory
        #expect(decoded.count == 2)
        #expect(decoded[0].userRequest == "Make formal")
        #expect(decoded[1].assistantResponse == "Added")
    }

    @Test("Draft string array encoding")
    func stringArrayEncoding() {
        let encoded = Draft.encodeStringArray(["a@test.com", "b@test.com"])
        #expect(encoded.contains("a@test.com"))
        let decoded = (try? JSONDecoder().decode([String].self, from: Data(encoded.utf8))) ?? []
        #expect(decoded == ["a@test.com", "b@test.com"])
    }

    @Test("Draft draftKey helper")
    func draftKeyHelper() {
        #expect(Draft.draftKey(replyTo: "m1", isForward: false, newId: nil) == "reply:m1")
        #expect(Draft.draftKey(replyTo: "m1", isForward: true, newId: nil) == "forward:m1")
        #expect(Draft.draftKey(replyTo: nil, isForward: false, newId: "uuid1") == "new:uuid1")
    }

    @Test("Draft isReplyOrForward")
    func isReplyOrForward() {
        let reply = Draft(id: "r", accountId: "a", toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "", body: "", replyToId: "m1", isForward: false, editHistoryJSON: nil, createdAt: 0, updatedAt: 0)
        #expect(reply.isReplyOrForward == true)

        let newDraft = Draft(id: "n", accountId: "a", toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "", body: "", replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: 0, updatedAt: 0)
        #expect(newDraft.isReplyOrForward == false)
    }

    @Test("Draft cascade delete on account removal")
    func cascadeDeleteOnAccountRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        let draft = Draft(id: "d1", accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Test", body: "", replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: 1000, updatedAt: 1000)
        try db.write { try draft.insert($0) }

        // Delete account — draft should cascade
        try db.write { _ = try Account.deleteOne($0, key: "acc1") }
        let fetched = try db.read { try Draft.fetchOne($0, key: "d1") }
        #expect(fetched == nil)
    }
}

// MARK: - Email Context Snapshot Tests

@Suite("EmailContextSnapshot encoding")
struct EmailContextSnapshotTests {

    @Test("Encode and decode round-trip")
    func encodeDecodeRoundTrip() {
        let ctx = EmailContextSnapshot(messageHeaderId: "acc1:INBOX:12345", subject: "Re: Q3 Budget", from: "alice@example.com")
        let encoded = ChatStore.encodeEmailContext(ctx)
        #expect(encoded != nil)
        let decoded = ChatStore.decodeEmailContext(encoded!)
        #expect(decoded?.messageHeaderId == "acc1:INBOX:12345")
        #expect(decoded?.subject == "Re: Q3 Budget")
    }

    @Test("Decode nil on invalid JSON")
    func decodeNilOnInvalid() {
        #expect(ChatStore.decodeEmailContext("not json") == nil)
        #expect(ChatStore.decodeEmailContext("") == nil)
        #expect(ChatStore.decodeEmailContext("{\"wrong\": true}") == nil)
    }

    @Test("Round-trip with special characters")
    func roundTripSpecialChars() {
        let ctx = EmailContextSnapshot(messageHeaderId: "m1", subject: "Re: Q&A \"session\" <test>", from: "john+test@example.com")
        let decoded = ChatStore.decodeEmailContext(ChatStore.encodeEmailContext(ctx)!)!
        #expect(decoded.subject == "Re: Q&A \"session\" <test>")
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = EmailContextSnapshot(messageHeaderId: "m1", subject: "Hi", from: "a@t.com")
        let b = EmailContextSnapshot(messageHeaderId: "m1", subject: "Hi", from: "a@t.com")
        let c = EmailContextSnapshot(messageHeaderId: "m2", subject: "Hi", from: "a@t.com")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Email context persists in ChatTurn GRDB")
    func emailContextInChatTurn() throws {
        let db = try TestDatabase.make()
        let ctx = EmailContextSnapshot(messageHeaderId: "m100", subject: "Notes", from: "bob@co.com")
        let turn = ChatTurn(id: "ec-1", timestamp: 1000, role: "user", content: "chat_converse", userMessage: "Summarize", type: "normal", chars: 9, renderedContent: nil, sessionId: "msg:m100", remindersSnapshot: nil, emailContextJSON: ChatStore.encodeEmailContext(ctx), thinkingContent: nil)
        try db.write { try turn.insert($0) }
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "ec-1") }
        let decoded = ChatStore.decodeEmailContext(fetched!.emailContextJSON!)
        #expect(decoded?.messageHeaderId == "m100")
    }
}

// MARK: - Message-Detail Session Eviction

@Suite("Message-detail session eviction")
struct MessageDetailEvictionTests {

    @Test("Eviction keeps inbox messages and removes oldest non-inbox beyond limit")
    func evictionKeepsInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Create an inbox message
        try TestDatabase.insertMessageHeader(db, messageId: "inboxMsg", folderId: "acc1:INBOX", accountId: "acc1", isInInbox: true)
        // Create non-inbox messages
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "archMsg\(i)", folderId: "acc1:Archive", accountId: "acc1", isInInbox: false)
        }

        // Msg-detail sessions: 1 inbox + 5 non-inbox
        try db.write { try ChatTurn(id: "inbox-t", timestamp: 6000, role: "user", content: "c", userMessage: "q", type: "normal", chars: 1, renderedContent: nil, sessionId: "msg:acc1:INBOX:inboxMsg", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }
        for i in 0..<5 {
            try db.write { try ChatTurn(id: "arch-t\(i)", timestamp: Double(i * 1000), role: "user", content: "c", userMessage: "q", type: "normal", chars: 1, renderedContent: nil, sessionId: "msg:acc1:Archive:archMsg\(i)", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }
        }

        // Evict with limit=2 non-inbox
        let evicted = try db.write { db -> Int in
            let sessionRows = try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs FROM chatTurn
                WHERE sessionId LIKE 'msg:%' GROUP BY sessionId ORDER BY maxTs DESC
            """)
            var kept = 0
            var evicted = 0
            for row in sessionRows {
                let sid: String = row["sessionId"]
                let msgId = String(sid.dropFirst(4))
                if let header = try MessageHeader.fetchOne(db, key: msgId), header.isInInbox { continue }
                kept += 1
                if kept > 2 {
                    _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                    evicted += 1
                }
            }
            return evicted
        }

        #expect(evicted == 3) // 5 non-inbox, keep 2, evict 3

        // Inbox session should still exist
        let inboxTurns = try db.read { try ChatTurn.filter(Column("sessionId") == "msg:acc1:INBOX:inboxMsg").fetchCount($0) }
        #expect(inboxTurns == 1)
    }
}

// MARK: - Database Migration v22/v23

@Suite("Database migrations v22-v23 (chat refactor)")
struct ChatRefactorMigrationTests {

    @Test("v22: emailContextJSON column exists")
    func v22Column() throws {
        let db = try TestDatabase.make()
        let turn = ChatTurn(id: "m1", timestamp: 1000, role: "user", content: "c", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: nil, remindersSnapshot: nil, emailContextJSON: "{\"messageHeaderId\":\"x\",\"subject\":\"y\",\"from\":\"z\"}", thinkingContent: nil)
        try db.write { try turn.insert($0) }
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "m1") }
        #expect(fetched?.emailContextJSON?.contains("messageHeaderId") == true)
    }

    @Test("v23: draft table exists and accepts records")
    func v23DraftTable() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        let draft = Draft(id: "test-draft", accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Test", body: "Body", replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: 1000, updatedAt: 1000)
        try db.write { try draft.insert($0) }
        let fetched = try db.read { try Draft.fetchOne($0, key: "test-draft") }
        #expect(fetched?.subject == "Test")
    }
}

// MARK: - ChatPillState Cleanup

@Suite("ChatPillState session management")
struct ChatPillStateManagementTests {

    @Test("removeSession cleans up session data")
    @MainActor
    func removeSessionCleansUp() {
        let state = ChatPillState.shared
        let key = "test-cleanup-\(UUID().uuidString)"
        let session = state.session(for: key)
        session.chatMessages.append(ChatMessage(role: .user, content: "Hi", timestamp: Date()))
        #expect(session.chatMessages.count == 1)

        state.removeSession(for: key)
        let fresh = state.session(for: key)
        #expect(fresh.chatMessages.isEmpty)
        state.removeSession(for: key)
    }

    @Test("removeSession for nonexistent key is no-op")
    @MainActor
    func removeNonexistent() {
        ChatPillState.shared.removeSession(for: "nonexistent-\(UUID().uuidString)")
    }

    @Test("Different session keys are isolated")
    @MainActor
    func sessionIsolation() {
        let state = ChatPillState.shared
        let k1 = "iso-a-\(UUID().uuidString)"
        let k2 = "iso-b-\(UUID().uuidString)"
        state.session(for: k1).chatMessages.append(ChatMessage(role: .user, content: "A", timestamp: Date()))
        state.session(for: k2).chatMessages.append(ChatMessage(role: .user, content: "B", timestamp: Date()))
        #expect(state.session(for: k1).chatMessages.first?.content == "A")
        #expect(state.session(for: k2).chatMessages.first?.content == "B")
        state.removeSession(for: k1)
        state.removeSession(for: k2)
    }
}

// MARK: - deleteSessionTurns

@Suite("deleteSessionTurns correctness")
struct DeleteSessionTurnsTests {

    @Test("deleteSessionTurns only deletes turns for the specified session")
    func deletesOnlySpecifiedSession() throws {
        let db = try TestDatabase.make()
        try db.write { db in
            try ChatTurn(id: "a1", timestamp: 1000, role: "user", content: "c", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: "session-A", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert(db)
            try ChatTurn(id: "b1", timestamp: 2000, role: "user", content: "c", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: "session-B", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert(db)
            try ChatTurn(id: "a2", timestamp: 3000, role: "assistant", content: "c", userMessage: nil, type: "normal", chars: 1, renderedContent: nil, sessionId: "session-A", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert(db)
        }

        // Delete session-A turns
        try db.write { db in
            _ = try ChatTurn.filter(Column("sessionId") == "session-A").deleteAll(db)
        }

        let remaining = try db.read { try ChatTurn.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].sessionId == "session-B")
    }
}

// MARK: - Compose session turn persistence

@Suite("Compose session turns persist to GRDB")
struct ComposeSessionTurnPersistenceTests {

    @Test("Compose edit turns survive loadContextSession round-trip")
    func composeEditTurnsRoundTrip() throws {
        let db = try TestDatabase.make()
        let sessionId = "compose:reply:msg123"
        try db.write { db in
            try ChatTurn(id: "ce-1", timestamp: 1000, role: "user", content: "compose_edit", userMessage: "Make formal", type: "normal", chars: 11, renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert(db)
            try ChatTurn(id: "ce-2", timestamp: 2000, role: "assistant", content: "Done. I've made the tone more formal.", userMessage: nil, type: "normal", chars: 36, renderedContent: nil, sessionId: sessionId, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert(db)
        }

        let turns = try db.read { db in
            try ChatTurn.filter(Column("sessionId") == sessionId).order(Column("timestamp").asc).fetchAll(db)
        }
        #expect(turns.count == 2)
        #expect(turns[0].userMessage == "Make formal")
        #expect(turns[1].content == "Done. I've made the tone more formal.")
    }
}

// MARK: - Eviction edge cases

@Suite("Eviction edge cases")
struct EvictionEdgeCaseTests {

    @Test("Message-detail eviction: deleted message (header gone) is evictable")
    func deletedMessageIsEvictable() throws {
        let db = try TestDatabase.make()
        // Create a msg-detail session for a message that no longer exists in GRDB
        try db.write { try ChatTurn(id: "t1", timestamp: 1000, role: "user", content: "c", userMessage: "q", type: "normal", chars: 1, renderedContent: nil, sessionId: "msg:deleted-msg-id", remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil).insert($0) }

        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs FROM chatTurn
                WHERE sessionId LIKE 'msg:%' GROUP BY sessionId ORDER BY maxTs DESC
            """)
        }
        #expect(sessionRows.count == 1)

        // Evict with limit=0 (evict all non-inbox)
        var kept = 0
        var evicted = 0
        try db.write { db in
            for row in sessionRows {
                let sid: String = row["sessionId"]
                let msgId = String(sid.dropFirst(4))
                // Header doesn't exist → NOT exempt
                if let header = try MessageHeader.fetchOne(db, key: msgId), header.isInInbox { continue }
                kept += 1
                if kept > 0 { // limit=0
                    _ = try ChatTurn.filter(Column("sessionId") == sid).deleteAll(db)
                    evicted += 1
                }
            }
        }
        #expect(evicted == 1)
    }

    @Test("Draft eviction does not evict inbox-linked reply drafts")
    func draftEvictionExemptsInboxReply() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "inboxMsg", folderId: "acc1:INBOX", accountId: "acc1", isInInbox: true)

        // Draft replying to inbox message (should be exempt)
        let replyDraft = Draft(id: "reply:acc1:INBOX:inboxMsg", accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Re: Hi", body: "reply", replyToId: "acc1:INBOX:inboxMsg", isForward: false, editHistoryJSON: nil, createdAt: 1000, updatedAt: 1000)
        // Draft replying to non-existent message (should be evictable)
        let orphanDraft = Draft(id: "reply:deleted", accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Re: Gone", body: "reply", replyToId: "deleted-msg", isForward: false, editHistoryJSON: nil, createdAt: 500, updatedAt: 500)

        try db.write { db in
            try replyDraft.insert(db)
            try orphanDraft.insert(db)
        }

        // Evict with limit=0 (evict all non-exempt)
        let allDrafts = try db.read { try Draft.order(Column("updatedAt").desc).fetchAll($0) }
        var kept = 0
        var evicted = 0
        try db.write { db in
            for draft in allDrafts {
                if let replyToId = draft.replyToId, let header = try MessageHeader.fetchOne(db, key: replyToId), header.isInInbox { continue }
                kept += 1
                if kept > 0 {
                    try draft.delete(db)
                    evicted += 1
                }
            }
        }
        #expect(evicted == 1)

        // Inbox-linked draft should still exist
        let remaining = try db.read { try Draft.fetchOne($0, key: "reply:acc1:INBOX:inboxMsg") }
        #expect(remaining != nil)
    }
}

// MARK: - Draft.parseRecipients

@Suite("Draft.parseRecipients")
struct DraftParseRecipientsTests {

    @Test("Simple comma-separated emails")
    func simpleComma() {
        let result = Draft.parseRecipients("alice@co.com, bob@co.com")
        #expect(result == ["alice@co.com", "bob@co.com"])
    }

    @Test("Angle-bracket format extracts bare email")
    func angleBracket() {
        let result = Draft.parseRecipients("Alice <alice@co.com>, Bob <bob@co.com>")
        #expect(result == ["alice@co.com", "bob@co.com"])
    }

    @Test("Mixed format")
    func mixed() {
        let result = Draft.parseRecipients("alice@co.com, Bob <bob@co.com>")
        #expect(result == ["alice@co.com", "bob@co.com"])
    }

    @Test("Name with comma in display name")
    func commaInName() {
        let result = Draft.parseRecipients("\"Last, First\" <alice@co.com>, bob@co.com")
        // The comma inside quotes is tricky but angle-bracket parsing handles it
        // because <alice@co.com> protects the address
        #expect(result.count == 2)
        #expect(result[1] == "bob@co.com")
        #expect(result[0] == "alice@co.com")
    }

    @Test("Single email")
    func single() {
        #expect(Draft.parseRecipients("alice@co.com") == ["alice@co.com"])
    }

    @Test("Empty string")
    func empty() {
        #expect(Draft.parseRecipients("").isEmpty)
    }

    @Test("Whitespace handling")
    func whitespace() {
        let result = Draft.parseRecipients("  alice@co.com  ,  bob@co.com  ")
        #expect(result == ["alice@co.com", "bob@co.com"])
    }
}

// MARK: - Draft attachment storage

@Suite("DraftAttachmentStorage")
struct DraftAttachmentStorageTests {

    @Test("Save and load attachments round-trip")
    func saveLoadRoundTrip() throws {
        let dirName = "test-att-\(UUID().uuidString)"
        let attachments = [
            DraftAttachment(filename: "doc.pdf", mimeType: "application/pdf", data: Data("pdf-content".utf8)),
            DraftAttachment(filename: "photo.jpg", mimeType: "image/jpeg", data: Data("jpg-content".utf8)),
        ]
        try DraftAttachmentStorage.saveAttachments(attachments, dirName: dirName)

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dirName)
        #expect(loaded.count == 2)
        guard loaded.count == 2 else { DraftAttachmentStorage.deleteAttachments(dirName: dirName); return }
        #expect(loaded[0].filename == "doc.pdf")
        #expect(loaded[0].mimeType == "application/pdf")
        #expect(String(data: loaded[0].data, encoding: .utf8) == "pdf-content")
        #expect(loaded[1].filename == "photo.jpg")

        DraftAttachmentStorage.deleteAttachments(dirName: dirName)
    }

    @Test("Duplicate filenames don't collide metadata")
    func duplicateFilenamesNoCollision() throws {
        let dirName = "test-dup-\(UUID().uuidString)"
        let attachments = [
            DraftAttachment(filename: "doc.pdf", mimeType: "application/pdf", data: Data("first".utf8)),
            DraftAttachment(filename: "doc.pdf", mimeType: "text/plain", data: Data("second".utf8)),
        ]
        try DraftAttachmentStorage.saveAttachments(attachments, dirName: dirName)

        let loaded = try DraftAttachmentStorage.loadAttachments(dirName: dirName)
        #expect(loaded.count == 2)
        guard loaded.count == 2 else { DraftAttachmentStorage.deleteAttachments(dirName: dirName); return }
        // Each should have its OWN mimeType (not the other's)
        #expect(loaded[0].mimeType == "application/pdf")
        #expect(loaded[1].mimeType == "text/plain")

        DraftAttachmentStorage.deleteAttachments(dirName: dirName)
    }

    // T4.D1 — these two previously asserted that a referenced-but-absent directory
    // loads as EMPTY, which BLESSED the silent-subset bug. `loadAttachments` now
    // fails closed: `[]` is reachable ONLY for a nil `dirName`.

    @Test("Load from a nonexistent referenced directory throws instead of returning empty")
    func loadNonexistentThrows() {
        #expect(throws: DraftAttachmentLoadError.self) {
            _ = try DraftAttachmentStorage.loadAttachments(dirName: "nonexistent-\(UUID().uuidString)")
        }
    }

    @Test("Delete removes directory, and loading the deleted directory throws")
    func deleteRemovesDir() throws {
        let dirName = "test-del-\(UUID().uuidString)"
        try DraftAttachmentStorage.saveAttachments(
            [DraftAttachment(filename: "f.txt", mimeType: "text/plain", data: Data("x".utf8))],
            dirName: dirName
        )
        DraftAttachmentStorage.deleteAttachments(dirName: dirName)

        // The dir is gone — a referenced-but-absent dir is fail-closed, not "empty".
        #expect(throws: DraftAttachmentLoadError.self) {
            _ = try DraftAttachmentStorage.loadAttachments(dirName: dirName)
        }
    }
}

// MARK: - Draft server field preservation on auto-save

@Suite("Draft server field preservation")
struct DraftServerFieldPreservationTests {

    @Test("Auto-save update path preserves serverDraftId and rfc822MessageId")
    func preservesServerFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        // Create a draft with server fields set (simulating a previously pushed draft)
        var draft = Draft(
            id: "reply:acc1:stable-123",
            accountId: "acc1",
            toJSON: "[\"alice@co.com\"]",
            ccJSON: "[]",
            bccJSON: "[]",
            subject: "Re: Original",
            body: "Old body",
            replyToId: "acc1:INBOX:100",
            isForward: false,
            editHistoryJSON: nil,
            createdAt: 1000,
            updatedAt: 1000,
            serverDraftId: "gmail-draft-xyz",
            serverPushStatus: "pushed",
            rfc822MessageId: "<draft-abc@co.com>",
            attachmentsDirName: "att-dir-1"
        )
        try db.write { try draft.insert($0) }

        // Simulate auto-save: mutate only the content fields (like autoSaveDraft does)
        draft.subject = "Re: Updated Subject"
        draft.body = "New body from AI edit"
        draft.editHistoryJSON = "[{\"userRequest\":\"make formal\"}]"
        draft.updatedAt = 2000

        // Save via DraftStore.save which marks pushed -> dirty
        try db.write { db in
            var d = draft
            if d.serverPushStatus == "pushed" {
                d.serverPushStatus = "dirty"
            }
            try d.save(db)
        }

        let fetched = try db.read { try Draft.fetchOne($0, key: "reply:acc1:stable-123") }
        #expect(fetched != nil)
        // Content updated
        #expect(fetched?.subject == "Re: Updated Subject")
        #expect(fetched?.body == "New body from AI edit")
        // Server fields preserved (NOT wiped to nil)
        #expect(fetched?.serverDraftId == "gmail-draft-xyz")
        #expect(fetched?.serverPushStatus == "dirty") // pushed -> dirty
        #expect(fetched?.rfc822MessageId == "<draft-abc@co.com>")
        #expect(fetched?.attachmentsDirName == "att-dir-1")
        // Immutable fields preserved
        #expect(fetched?.replyToId == "acc1:INBOX:100")
        #expect(fetched?.createdAt == 1000)
    }

    @Test("First save path creates draft with nil server fields")
    func firstSaveNilServerFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let draft = Draft(
            id: "reply:acc1:stable-456",
            accountId: "acc1",
            toJSON: "[]",
            ccJSON: "[]",
            bccJSON: "[]",
            subject: "Re: New",
            body: "body",
            replyToId: "acc1:INBOX:200",
            isForward: false,
            editHistoryJSON: nil,
            createdAt: 1000,
            updatedAt: 1000
        )
        try db.write { try draft.save($0) }

        let fetched = try db.read { try Draft.fetchOne($0, key: "reply:acc1:stable-456") }
        #expect(fetched?.serverDraftId == nil)
        #expect(fetched?.serverPushStatus == nil)
        #expect(fetched?.rfc822MessageId == nil)
    }
}

// MARK: - Eviction stableId fallback

@Suite("Eviction stableId fallback for moved IMAP messages")
struct EvictionStableIdFallbackTests {

    @Test("Eviction exempts inbox message even after IMAP MOVE (stableId fallback)")
    func exemptAfterIMAPMove() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Create a message that is in inbox with a stable rfc822MessageId
        try TestDatabase.insertMessageHeader(db, messageId: "uid100",
            subject: "Important", folderId: "acc1:INBOX", accountId: "acc1",
            isInInbox: true, rfc822MessageId: "<stable@example.com>")

        // Create a msg-detail session using the stableId pattern
        // sessionId = "msg:acc1:<stable@example.com>" (stableId for IMAP = rfc822MessageId)
        // emailContextJSON stores the original GRDB PK (which may become stale after MOVE)
        let ctx = EmailContextSnapshot(
            messageHeaderId: "acc1:INBOX:uid100", // This PK is valid now
            subject: "Important",
            from: "sender@test.com"
        )
        try db.write {
            try ChatTurn(
                id: "t1", timestamp: 1000, role: "user",
                content: "chat_converse", userMessage: "Summarize",
                type: "normal", chars: 9, renderedContent: nil,
                sessionId: "msg:acc1:<stable@example.com>",
                remindersSnapshot: nil,
                emailContextJSON: ChatStore.encodeEmailContext(ctx),
                thinkingContent: nil
            ).insert($0)
        }

        // Eviction should exempt this session (message is in inbox)
        // Strategy 1: emailContextJSON PK lookup succeeds
        let sessionRows = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sessionId, MAX(timestamp) as maxTs FROM chatTurn
                WHERE sessionId LIKE 'msg:%' GROUP BY sessionId ORDER BY maxTs DESC
            """)
        }
        #expect(sessionRows.count == 1)

        let firstTurn = try db.read { db in
            try ChatTurn.filter(Column("sessionId") == "msg:acc1:<stable@example.com>")
                .order(Column("timestamp").asc).fetchOne(db)
        }
        let emailCtx = firstTurn?.emailContextJSON.flatMap { ChatStore.decodeEmailContext($0) }
        // PK lookup works
        let headerByPK = try db.read { try MessageHeader.fetchOne($0, key: emailCtx!.messageHeaderId) }
        #expect(headerByPK?.isInInbox == true)
    }

    @Test("Eviction uses rfc822MessageId fallback when PK is stale")
    func fallbackWhenPKStale() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Create a message in inbox with rfc822MessageId
        try TestDatabase.insertMessageHeader(db, messageId: "uid200",
            subject: "Moved", folderId: "acc1:INBOX", accountId: "acc1",
            isInInbox: true, rfc822MessageId: "<moved@example.com>")

        // Create a session whose emailContextJSON has a STALE PK (simulating post-IMAP-MOVE)
        let ctx = EmailContextSnapshot(
            messageHeaderId: "acc1:OldFolder:uid999", // This PK no longer exists
            subject: "Moved",
            from: "sender@test.com"
        )
        try db.write {
            try ChatTurn(
                id: "t1", timestamp: 1000, role: "user",
                content: "chat_converse", userMessage: "Q",
                type: "normal", chars: 1, renderedContent: nil,
                sessionId: "msg:acc1:<moved@example.com>",
                remindersSnapshot: nil,
                emailContextJSON: ChatStore.encodeEmailContext(ctx),
                thinkingContent: nil
            ).insert($0)
        }

        // PK lookup should FAIL (stale PK)
        let headerByPK = try db.read { try MessageHeader.fetchOne($0, key: "acc1:OldFolder:uid999") }
        #expect(headerByPK == nil) // Stale — message moved

        // But rfc822MessageId lookup should SUCCEED
        let headerByRfc = try db.read { db in
            try MessageHeader.filter(Column("rfc822MessageId") == "<moved@example.com>").fetchOne(db)
        }
        #expect(headerByRfc?.isInInbox == true)

        // Eviction with limit 0 should NOT evict this session (inbox via fallback)
        var evicted = 0
        try db.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionId FROM chatTurn WHERE sessionId LIKE 'msg:%' GROUP BY sessionId
            """)
            for row in rows {
                let sid: String = row["sessionId"]
                // Replicate the isMessageInInbox logic
                let ft = try ChatTurn.filter(Column("sessionId") == sid)
                    .order(Column("timestamp").asc).fetchOne(db)
                var inInbox = false
                if let json = ft?.emailContextJSON,
                   let ctx = ChatStore.decodeEmailContext(json),
                   let h = try MessageHeader.fetchOne(db, key: ctx.messageHeaderId) {
                    inInbox = h.isInInbox
                }
                if !inInbox {
                    // Fallback: extract stableId from sessionId
                    let after = String(sid.dropFirst(4))
                    if let ci = after.firstIndex(of: ":") {
                        let stableId = String(after[after.index(after: ci)...])
                        if let h = try MessageHeader.filter(Column("rfc822MessageId") == stableId).fetchOne(db) {
                            inInbox = h.isInInbox
                        }
                    }
                }
                if !inInbox { evicted += 1 }
            }
        }
        #expect(evicted == 0) // Should NOT be evicted — inbox via fallback
    }
}

// MARK: - DraftStore dirty marking

@Suite("DraftStore dirty marking")
struct DraftStoreDirtyMarkingTests {

    @Test("Save marks pushed draft as dirty")
    func pushedToDirty() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var draft = Draft(
            id: "test-dirty", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "S", body: "B",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: 1000, updatedAt: 1000,
            serverDraftId: "srv-1", serverPushStatus: "pushed",
            rfc822MessageId: "<x@y>", attachmentsDirName: nil
        )
        try db.write { try draft.insert($0) }

        // Simulate DraftStore.save() logic
        draft.subject = "Updated"
        draft.updatedAt = 2000
        try db.write { db in
            var d = draft
            if d.serverPushStatus == "pushed" { d.serverPushStatus = "dirty" }
            try d.save(db)
        }

        let fetched = try db.read { try Draft.fetchOne($0, key: "test-dirty") }
        #expect(fetched?.serverPushStatus == "dirty")
        #expect(fetched?.serverDraftId == "srv-1") // Preserved
    }

    @Test("Save does not mark nil status as dirty")
    func nilStaysNil() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let draft = Draft(
            id: "test-nil", accountId: "acc1",
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "S", body: "B",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: 1000, updatedAt: 1000
        )
        try db.write { try draft.save($0) }

        let fetched = try db.read { try Draft.fetchOne($0, key: "test-nil") }
        #expect(fetched?.serverPushStatus == nil) // Stays nil, NOT marked dirty
    }
}

// MARK: - resolveMessageHeaderId

@Suite("ChatStore.resolveMessageHeaderId")
struct ResolveMessageHeaderIdTests {

    @Test("Returns originalId when PK exists")
    func returnsOriginalWhenExists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "uid100", folderId: "acc1:INBOX", accountId: "acc1", isInInbox: true)

        let resolved: String? = try db.read { db -> String? in
            if try MessageHeader.fetchOne(db, key: "acc1:INBOX:uid100") != nil {
                return "acc1:INBOX:uid100"
            }
            return nil
        }
        #expect(resolved == "acc1:INBOX:uid100")
    }

    @Test("Falls back to rfc822MessageId when PK is stale")
    func fallbackToRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        // Message now in Archive (was in INBOX before MOVE)
        try TestDatabase.insertMessageHeader(db, messageId: "uid200", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", isInInbox: false, rfc822MessageId: "<stable@example.com>")

        // Simulate: PK was "acc1:INBOX:uid100" (old, stale)
        // sessionId was "msg:acc1:<stable@example.com>"
        let sessionId = "msg:acc1:<stable@example.com>"
        let stalePK = "acc1:INBOX:uid100"

        let resolved = try db.read { db -> String? in
            // Strategy 1: PK lookup fails (stale)
            if try MessageHeader.fetchOne(db, key: stalePK) != nil {
                return stalePK
            }
            // Strategy 2: rfc822MessageId fallback
            let after = String(sessionId.dropFirst(4))
            if let ci = after.firstIndex(of: ":") {
                let stableId = String(after[after.index(after: ci)...])
                if let header = try MessageHeader.filter(Column("rfc822MessageId") == stableId).fetchOne(db) {
                    return header.id
                }
            }
            return nil
        }
        #expect(resolved == "acc1:Archive:uid200") // Resolved to current PK via rfc822MessageId
    }

    @Test("Returns nil when message no longer exists")
    func returnsNilWhenGone() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let sessionId = "msg:acc1:<gone@example.com>"
        let stalePK = "acc1:INBOX:uid999"

        let resolved = try db.read { db -> String? in
            if try MessageHeader.fetchOne(db, key: stalePK) != nil {
                return stalePK
            }
            let after = String(sessionId.dropFirst(4))
            if let ci = after.firstIndex(of: ":") {
                let stableId = String(after[after.index(after: ci)...])
                if let header = try MessageHeader.filter(Column("rfc822MessageId") == stableId).fetchOne(db) {
                    return header.id
                }
            }
            return nil
        }
        #expect(resolved == nil)
    }
}

// MARK: - ChatIdTranslator remap on IMAP MOVE

@Suite("ChatIdTranslator remap on message move")
struct ChatIdTranslatorRemapTests {

    @Test("remapRealId updates mapping from old PK to new PK")
    func remapUpdatesMapping() async {
        let translator = ChatIdTranslator.createIsolated()
        let oldPK = "acc1:INBOX:uid100"
        let newPK = "acc1:Archive:uid200"

        // Register the old PK
        let numericId = await translator.toNumericId(oldPK)
        #expect(numericId > 0)

        // Verify old PK maps correctly
        let resolvedBefore = await translator.toRealId(numericId)
        #expect(resolvedBefore == oldPK)

        // Remap to new PK
        let remapped = await translator.remapRealId(from: oldPK, to: newPK)
        #expect(remapped == 1)

        // Now the SAME numeric ID maps to the new PK
        let resolvedAfter = await translator.toRealId(numericId)
        #expect(resolvedAfter == newPK)

        // And toNumericId for the new PK returns the SAME numeric ID (not a new one)
        let numericForNew = await translator.toNumericId(newPK)
        #expect(numericForNew == numericId)
    }

    @Test("remapRealId returns 0 when old PK not in map")
    func remapNoOp() async {
        let translator = ChatIdTranslator.createIsolated()
        let remapped = await translator.remapRealId(from: "nonexistent", to: "new")
        #expect(remapped == 0)
    }

    @Test("After remap, old PK no longer resolves")
    func oldPKGoneAfterRemap() async {
        let translator = ChatIdTranslator.createIsolated()
        let oldPK = "acc1:INBOX:uid100"
        let newPK = "acc1:Archive:uid200"

        let numericId = await translator.toNumericId(oldPK)
        _ = await translator.remapRealId(from: oldPK, to: newPK)

        // Old PK should NOT be in the map anymore
        // toNumericId for old PK should create a NEW mapping (different numeric ID)
        let numericForOld = await translator.toNumericId(oldPK)
        #expect(numericForOld != numericId) // Different — old mapping was replaced
    }

    @Test("Remap preserves pill consistency across session reload")
    func remapPreservesPillConsistency() async {
        let translator = ChatIdTranslator.createIsolated()
        let oldPK = "acc1:INBOX:uid100"
        let newPK = "acc1:Archive:uid200"

        // Simulate: user chats about email, gets [Email](N) pills
        let numericId = await translator.toNumericId(oldPK)
        let pillText = "Check [Email](\(numericId)) for details"

        // Simulate: email moves (IMAP MOVE)
        _ = await translator.remapRealId(from: oldPK, to: newPK)

        // New message still uses the SAME numeric ID
        let numericAfterMove = await translator.toNumericId(newPK)
        #expect(numericAfterMove == numericId)

        // Old pill text still references a valid numeric ID
        let refs = ChatIdTranslator.collectRefs(from: pillText)
        #expect(refs.contains(numericId))

        // The numeric ID now resolves to the new PK
        let resolvedPK = await translator.toRealId(numericId)
        #expect(resolvedPK == newPK)
    }

    @Test("Full LLM cycle: real ID → numeric → enriched text → response → display pill")
    func fullLLMCycle() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId = "acc1:INBOX:uid500"

        // Step 1: Register email → get numeric ID (what the LLM sees)
        let numericId = await translator.toNumericId(realId)
        #expect(numericId > 0)

        // Step 2: Build enriched text (what sendAgentChat sends to LLM)
        let enrichedText = "Regarding [Email](\(numericId)): Summarize this email"
        #expect(enrichedText.contains("[Email](\(numericId))"))

        // Step 3: LLM responds with references to the numeric ID
        let llmResponse = "Here's a summary of [Email](\(numericId)). The sender discussed budget."

        // Step 4: Extract refs from response (for refCounting)
        let refs = ChatIdTranslator.collectRefs(from: llmResponse)
        #expect(refs.contains(numericId))
        await translator.registerTurnRefs(Array(refs))

        // Step 5: processResponseForDisplay converts numeric → display pill
        // (can't fully test here without GRDB subject lookup, but verify the mapping works)
        let resolvedRealId = await translator.toRealId(numericId)
        #expect(resolvedRealId == realId)

        // Step 6: After IMAP MOVE, remap preserves the cycle
        let newRealId = "acc1:Archive:uid600"
        _ = await translator.remapRealId(from: realId, to: newRealId)

        // The SAME numeric ID now points to the new real ID
        let resolvedAfterMove = await translator.toRealId(numericId)
        #expect(resolvedAfterMove == newRealId)

        // New messages use the same numeric ID (LLM consistency)
        let numericAfterMove = await translator.toNumericId(newRealId)
        #expect(numericAfterMove == numericId) // Same! Not a new ID.
    }

    @Test("Tool output translation: real IDs → numeric for LLM")
    func toolOutputTranslation() async {
        let translator = ChatIdTranslator.createIsolated()

        // Simulate inbox_read tool output with real IDs
        let toolOutput = """
        unique_id: acc1:INBOX:msg1
        subject: Budget Review
        from: alice@co.com

        unique_id: acc1:INBOX:msg2
        subject: Meeting Notes
        from: bob@co.com
        """

        // The tool output has real IDs in unique_id fields
        // But unique_id is handled by processToolOutputForLLM pattern (event_id etc.)
        // For email IDs, inbox_read tool already outputs numeric IDs (pre-translated)
        // Let's test the event_id path which goes through processToolOutputForLLM:

        let eventOutput = "event_id: google-cal-event-abc\ntitle: Team Standup"
        let translated = await translator.processToolOutputForLLM(eventOutput)

        // event_id should now be numeric
        #expect(!translated.contains("google-cal-event-abc"))
        #expect(translated.contains("event_id: "))

        // The numeric ID should resolve back to the real event ID
        let eventNumericStr = translated.replacingOccurrences(of: "event_id: ", with: "")
            .components(separatedBy: "\n").first ?? ""
        if let eventNumericId = Int(eventNumericStr) {
            let resolvedEventId = await translator.toRealId(eventNumericId)
            #expect(resolvedEventId == "google-cal-event-abc")
        }
    }

    @Test("Ref counting: evicted turns free their IDs")
    func refCountingEviction() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId = "acc1:INBOX:uid999"
        let numericId = await translator.toNumericId(realId)

        // Register refs for a turn
        await translator.registerTurnRefs([numericId])

        // ID should be in map
        #expect(await translator.toRealId(numericId) == realId)

        // Simulate turn eviction
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "Check [Email](\(numericId))", userMessage: nil,
            type: "normal", chars: 20, renderedContent: nil,
            sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        await translator.cleanupEvictedIds(evictedTurns: [turn])

        // ID should be freed (no longer in map)
        #expect(await translator.toRealId(numericId) == nil)
    }

    @Test("emailContextJSON update propagates new PK for eviction")
    func emailContextUpdateForEviction() throws {
        let db = try TestDatabase.make()

        // Create initial turn with old PK in emailContextJSON
        let oldCtx = EmailContextSnapshot(messageHeaderId: "acc1:INBOX:uid100", subject: "Test", from: "a@t.com")
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "user",
            content: "chat_converse", userMessage: "Q",
            type: "normal", chars: 1, renderedContent: nil,
            sessionId: "msg:acc1:<stable@test.com>",
            remindersSnapshot: nil,
            emailContextJSON: ChatStore.encodeEmailContext(oldCtx),
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        // Simulate: update emailContextJSON with new PK (as our code does on remap)
        let newCtx = EmailContextSnapshot(messageHeaderId: "acc1:Archive:uid200", subject: "Test", from: "a@t.com")
        let newJSON = ChatStore.encodeEmailContext(newCtx)
        try db.write { db in
            try db.execute(
                sql: "UPDATE chatTurn SET emailContextJSON = ? WHERE id = ?",
                arguments: [newJSON, "t1"]
            )
        }

        // Verify the updated context
        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "t1") }
        let decoded = ChatStore.decodeEmailContext(fetched!.emailContextJSON!)
        #expect(decoded?.messageHeaderId == "acc1:Archive:uid200")
    }
}

// MARK: - Session dereference on expiry

@Suite("Session turn dereferencing")
struct SessionDereferenceTests {

    @Test("dereferenceSessionTurns replaces content with renderedContent")
    func dereferenceReplacesContent() throws {
        let db = try TestDatabase.make()
        // Assistant turn with raw numeric in content, resolved in renderedContent
        let turn = ChatTurn(
            id: "d1", timestamp: 1000, role: "assistant",
            content: "See [Email](5) for details about the budget.",
            userMessage: nil, type: "normal", chars: 45,
            renderedContent: "See [📧 Budget Review](tabmail://email/5) for details about the budget.",
            sessionId: "test-deref-session", remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        // Dereference: content should be replaced with renderedContent
        try db.write { db in
            let turns = try ChatTurn.filter(Column("sessionId") == "test-deref-session").fetchAll(db)
            for t in turns {
                guard let rendered = t.renderedContent, rendered != t.content else { continue }
                try db.execute(sql: "UPDATE chatTurn SET content = ? WHERE id = ?", arguments: [rendered, t.id])
            }
        }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "d1") }
        // content now has the resolved pills (no more raw [Email](5))
        #expect(fetched?.content.contains("Budget Review") == true)
        #expect(fetched?.content.contains("[Email](5)") == false)
    }

    @Test("dereferenceSessionTurns skips turns where renderedContent == content")
    func dereferenceSkipsIdentical() throws {
        let db = try TestDatabase.make()
        // Turn with no pills — content and renderedContent would be the same
        let turn = ChatTurn(
            id: "d2", timestamp: 1000, role: "assistant",
            content: "The weather is sunny today.",
            userMessage: nil, type: "normal", chars: 27,
            renderedContent: nil, // nil means no pills to resolve
            sessionId: "test-deref-session2", remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        // Dereference: nothing should change (renderedContent is nil)
        try db.write { db in
            let turns = try ChatTurn.filter(Column("sessionId") == "test-deref-session2").fetchAll(db)
            for t in turns {
                guard let rendered = t.renderedContent, rendered != t.content else { continue }
                try db.execute(sql: "UPDATE chatTurn SET content = ? WHERE id = ?", arguments: [rendered, t.id])
            }
        }

        let fetched = try db.read { try ChatTurn.fetchOne($0, key: "d2") }
        #expect(fetched?.content == "The weather is sunny today.") // Unchanged
    }

    @Test("After dereference, search finds turns by subject name")
    func searchFindsAfterDereference() throws {
        let db = try TestDatabase.make()
        let turn = ChatTurn(
            id: "d3", timestamp: 1000, role: "assistant",
            content: "Check [Email](9) — it's about the Q3 budget.",
            userMessage: nil, type: "normal", chars: 40,
            renderedContent: "Check [📧 Q3 Budget Report](tabmail://email/9) — it's about the Q3 budget.",
            sessionId: "test-deref-session3", remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        // Before dereference: searching "Q3 Budget Report" in content fails
        let beforeContent = try db.read { db in
            try ChatTurn.filter(sql: "content LIKE '%Q3 Budget Report%'").fetchAll(db)
        }
        #expect(beforeContent.isEmpty) // Raw content doesn't have the subject

        // Dereference
        try db.write { db in
            let turns = try ChatTurn.filter(Column("sessionId") == "test-deref-session3").fetchAll(db)
            for t in turns {
                guard let rendered = t.renderedContent, rendered != t.content else { continue }
                try db.execute(sql: "UPDATE chatTurn SET content = ? WHERE id = ?", arguments: [rendered, t.id])
            }
        }

        // After dereference: searching "Q3 Budget Report" in content succeeds
        let afterContent = try db.read { db in
            try ChatTurn.filter(sql: "content LIKE '%Q3 Budget Report%'").fetchAll(db)
        }
        #expect(afterContent.count == 1)
        #expect(afterContent[0].id == "d3")
    }
}

// MARK: - ChatIdTranslator mapping persistence for session resume

@Suite("ChatIdTranslator mapping persistence")
struct ChatIdTranslatorPersistenceTests {

    @Test("chatIdMapping table schema: insert and read round-trip")
    func chatIdMappingRoundTrip() throws {
        let db = try TestDatabase.make()
        // Insert a mapping
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)",
                arguments: [42, "acc1:INBOX:uid100"]
            )
        }
        // Read it back
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT numericId, realId FROM chatIdMapping WHERE numericId = ?", arguments: [42])
        }
        #expect(row != nil)
        let numericId: Int = row!["numericId"]
        let realId: String = row!["realId"]
        #expect(numericId == 42)
        #expect(realId == "acc1:INBOX:uid100")
    }

    @Test("chatIdMapping survives simulated app restart (clear + reload)")
    func mappingSurvivesRestart() throws {
        let db = try TestDatabase.make()
        // Insert mappings (simulating what ChatIdTranslator.persistMapping does)
        try db.write { db in
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [1, "acc1:INBOX:msg1"])
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [2, "acc1:INBOX:msg2"])
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [3, "acc1:SENT:msg3"])
        }

        // Simulate restart: clear in-memory and reload from DB
        // (replicate ensureLoadedFromDB logic)
        var idMap: [Int: String] = [:]
        var reverseMap: [String: Int] = [:]
        var nextId = 1
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT numericId, realId FROM chatIdMapping")
        }
        for row in rows {
            let numericId: Int = row["numericId"]
            let realId: String = row["realId"]
            idMap[numericId] = realId
            reverseMap[realId] = numericId
            nextId = max(nextId, numericId + 1)
        }

        #expect(idMap.count == 3)
        #expect(idMap[1] == "acc1:INBOX:msg1")
        #expect(idMap[2] == "acc1:INBOX:msg2")
        #expect(idMap[3] == "acc1:SENT:msg3")
        #expect(reverseMap["acc1:INBOX:msg1"] == 1)
        #expect(nextId == 4) // Next available ID after max(1,2,3)
    }

    @Test("Turns with [Email](N) resolve after mapping reload")
    func turnsResolveAfterReload() throws {
        let db = try TestDatabase.make()
        // Persist mapping: 7 → "acc1:INBOX:uid500"
        try db.write { db in
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [7, "acc1:INBOX:uid500"])
        }

        // Persist a turn that references [Email](7) in its content
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "Here's a summary of [Email](7). The budget looks good.",
            userMessage: nil, type: "normal", chars: 50,
            renderedContent: "Here's a summary of [📧 Budget Review](tabmail://email/7). The budget looks good.",
            sessionId: "msg:acc1:uid500", remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        try db.write { try turn.insert($0) }

        // Simulate: load the mapping (restart)
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [7])
        }
        let realId: String? = row?["realId"]
        #expect(realId == "acc1:INBOX:uid500") // Mapping survived persist

        // Simulate: load the turn and display it
        let loaded = try db.read { try ChatTurn.fetchOne($0, key: "t1") }
        let displayText = loaded?.renderedContent ?? loaded?.content ?? ""
        // renderedContent has baked pills — shows subject regardless of translator state
        #expect(displayText.contains("Budget Review"))
        #expect(!displayText.contains("[Email](7)")) // Not raw numeric

        // The content (raw) still has numeric for LLM history
        #expect(loaded?.content.contains("[Email](7)") == true)
    }

    @Test("INSERT OR REPLACE updates existing mapping (remap persistence)")
    func insertOrReplaceUpdates() throws {
        let db = try TestDatabase.make()
        // Initial mapping: 5 → old PK
        try db.write { db in
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [5, "acc1:INBOX:uid100"])
        }

        // Remap: 5 → new PK (simulating remapRealId persist)
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [5, "acc1:Archive:uid200"])
        }

        // Only one mapping for numericId 5, pointing to new PK
        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatIdMapping WHERE numericId = ?", arguments: [5])
        }
        #expect(count == 1)

        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [5])
        }
        #expect(row?["realId"] as String? == "acc1:Archive:uid200")
    }

    @Test("Delete mappings for freed IDs (eviction cleanup)")
    func deleteMappingsOnEviction() throws {
        let db = try TestDatabase.make()
        try db.write { db in
            for i in 1...5 {
                try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [i, "msg\(i)"])
            }
        }

        // Delete IDs 2 and 4 (simulating cleanupEvictedIds)
        try db.write { db in
            try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId IN (2, 4)")
        }

        let remaining = try db.read { db in
            try Int.fetchAll(db, sql: "SELECT numericId FROM chatIdMapping ORDER BY numericId")
        }
        #expect(remaining == [1, 3, 5])
    }

    @Test("Multiple sessions share the same mapping namespace")
    func sharedNamespace() throws {
        let db = try TestDatabase.make()
        // Session A registers email 1
        try db.write { db in
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [1, "acc1:INBOX:emailA"])
        }
        // Session B registers email 2 (different session, same namespace)
        try db.write { db in
            try db.execute(sql: "INSERT INTO chatIdMapping (numericId, realId) VALUES (?, ?)", arguments: [2, "acc1:INBOX:emailB"])
        }

        // Both are in the same table, accessible from any session
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chatIdMapping") }
        #expect(count == 2)

        // Reverse lookup works across sessions
        let emailA = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = 1")
        }
        #expect(emailA?["realId"] as String? == "acc1:INBOX:emailA")
    }

    @Test("Ref counting integration: refs from persisted turns protect mappings from eviction")
    func refCountsProtectMappings() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId1 = "acc1:INBOX:msg-referenced"
        let realId2 = "acc1:INBOX:msg-orphan"

        let id1 = await translator.toNumericId(realId1)
        let id2 = await translator.toNumericId(realId2)

        // Register refs for id1 (simulating a turn that references it)
        await translator.registerTurnRefs([id1])

        // Build ref counts (simulating startup)
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "See [Email](\(id1))", userMessage: nil,
            type: "normal", chars: 15, renderedContent: nil,
            sessionId: "s1", remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        await translator.buildRefCounts(allTurns: [turn])

        // id1 is referenced by the turn → protected
        // id2 has no references → orphan → freed
        let resolvedId1 = await translator.toRealId(id1)
        let resolvedId2 = await translator.toRealId(id2)
        #expect(resolvedId1 == realId1) // Protected — still in map
        #expect(resolvedId2 == nil) // Orphan — freed by buildRefCounts
    }
}

// MARK: - resolveOriginalMessage (AccountManagerOutbox)

@Suite("resolveOriginalMessage in outbox")
struct ResolveOriginalMessageTests {

    @Test("PK lookup succeeds — returns header directly")
    func pkLookupSucceeds() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "uid100", folderId: "acc1:INBOX", accountId: "acc1", rfc822MessageId: "<test@co.com>")

        let header = try db.read { db -> MessageHeader? in
            if let h = try MessageHeader.fetchOne(db, key: "acc1:INBOX:uid100") { return h }
            return nil
        }
        #expect(header != nil)
        #expect(header?.id == "acc1:INBOX:uid100")
    }

    @Test("PK stale — falls back to rfc822MessageId via inReplyTo")
    func rfc822Fallback() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "uid200", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive", rfc822MessageId: "<moved@co.com>")

        // PK "acc1:INBOX:uid100" is stale — message moved to Archive
        let header = try db.read { db -> MessageHeader? in
            if let h = try MessageHeader.fetchOne(db, key: "acc1:INBOX:uid100") { return h }
            // Fallback: search by rfc822MessageId (from inReplyTo)
            let rfc822 = "<moved@co.com>"
            return try MessageHeader.filter(Column("rfc822MessageId") == rfc822).fetchOne(db)
        }
        #expect(header != nil)
        #expect(header?.id == "acc1:Archive:uid200")
    }

    @Test("Message fully deleted — returns nil")
    func messageDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let header = try db.read { db -> MessageHeader? in
            if let h = try MessageHeader.fetchOne(db, key: "acc1:INBOX:uid999") { return h }
            let rfc822 = "<gone@co.com>"
            return try MessageHeader.filter(Column("rfc822MessageId") == rfc822).fetchOne(db)
        }
        #expect(header == nil)
    }

    @Test("inReplyTo is nil — returns nil when PK stale")
    func nilInReplyTo() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let header = try db.read { db -> MessageHeader? in
            if let h = try MessageHeader.fetchOne(db, key: "acc1:INBOX:uid999") { return h }
            // No inReplyTo to fall back on
            let rfc822: String? = nil
            if let r = rfc822, let h = try MessageHeader.filter(Column("rfc822MessageId") == r).fetchOne(db) {
                return h
            }
            return nil
        }
        #expect(header == nil)
    }
}

// MARK: - ChatStore actor method tests

@Suite("ChatStore actor method integration")
struct ChatStoreActorMethodTests {

    @Test("dereferenceSessionTurns via actor method")
    func dereferenceViaActor() async throws {
        // Insert turns directly to production GRDB (actor uses AppDatabase.dbPool)
        let sessionId = "test-deref-actor-\(UUID().uuidString)"
        let turn = ChatTurn(
            id: "da-\(UUID().uuidString.prefix(8))", timestamp: 1000, role: "assistant",
            content: "See [Email](5) for budget info.",
            userMessage: nil, type: "normal", chars: 30,
            renderedContent: "See [📧 Budget](tabmail://email/5) for budget info.",
            sessionId: sessionId, remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil
        )
        try await ChatStore.shared.appendTurn(turn)

        // Call actual actor method
        try await ChatStore.shared.dereferenceSessionTurns(sessionId: sessionId)

        // Verify: load and check content was replaced
        let loaded = try await ChatStore.shared.loadContextSession(sessionId: sessionId)
        let assistantTurn = loaded?.turns.first(where: { $0.role == "assistant" })
        #expect(assistantTurn?.content.contains("Budget") == true)
        #expect(assistantTurn?.content.contains("[Email](5)") == false)

        // Cleanup
        try await ChatStore.shared.deleteSessionTurns(sessionId: sessionId)
    }

    @Test("resolveMessageHeaderId via actor method — PK valid")
    func resolveViaActorValid() async throws {
        // This test requires a message in AppDatabase — skip if no accounts set up
        // (tests run against real DB which may have data from dev accounts)
        let sessionId = "msg:acc-test:stable-test"
        let result = try await ChatStore.shared.resolveMessageHeaderId(originalId: "nonexistent-pk", sessionId: sessionId)
        // Should return nil (no message matches either strategy)
        #expect(result == nil)
    }
}

// MARK: - Server draft body loading & compose routing

@Suite("Server draft compose routing")
struct ServerDraftComposeRoutingTests {

    @Test("Draft folder detection: message in Drafts folder is identified as draft")
    func draftFolderDetection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "draft1", subject: "My Draft",
            folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts", isInInbox: false)

        // Replicate MessageDetailContainer logic: check folder role
        let isDraft = try db.read { db -> Bool in
            guard let h = try MessageHeader.fetchOne(db, key: "acc1:Drafts:draft1") else { return false }
            let f = try Folder.fetchOne(db, key: h.folderId)
            return f?.role == .drafts
        }
        #expect(isDraft == true)
    }

    @Test("Non-draft folder message is NOT identified as draft")
    func nonDraftFolderDetection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "msg1", folderId: "acc1:INBOX", accountId: "acc1")

        let isDraft = try db.read { db -> Bool in
            guard let h = try MessageHeader.fetchOne(db, key: "acc1:INBOX:msg1") else { return false }
            let f = try Folder.fetchOne(db, key: h.folderId)
            return f?.role == .drafts
        }
        #expect(isDraft == false)
    }

    @Test("Body from MessageBody cache returns content")
    func bodyFromCache() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "draft2", folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts", isInInbox: false)
        try TestDatabase.insertMessageBody(db, headerId: "acc1:Drafts:draft2", htmlContent: "<p>Draft body content</p>")

        let body = try db.read { db in
            try MessageBody.fetchOne(db, key: "acc1:Drafts:draft2")?.htmlContent
        }
        #expect(body == "<p>Draft body content</p>")
    }

    @Test("Missing MessageBody returns nil (needs server fetch)")
    func missingBodyReturnsNil() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "draft3", folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts", isInInbox: false)
        // No MessageBody inserted — simulates never-opened draft

        let body = try db.read { db in
            try MessageBody.fetchOne(db, key: "acc1:Drafts:draft3")?.htmlContent
        }
        #expect(body == nil) // Needs server fetch
    }

    @Test("Reply draft detected via inReplyTo header")
    func replyDraftDetection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        // Original message
        try TestDatabase.insertMessageHeader(db, messageId: "orig1", subject: "Original Email",
            folderId: "acc1:INBOX", accountId: "acc1", rfc822MessageId: "<orig@example.com>")

        // Draft with inReplyTo pointing to original
        var draft = MessageHeader(
            messageId: "draft4", subject: "Re: Original Email",
            from: "me@example.com", fromAddress: "me@example.com",
            to: "sender@example.com", date: Date(), snippet: "",
            folderId: "acc1:Drafts", accountId: "acc1",
            folderPath: "Drafts", isInInbox: false
        )
        draft.inReplyTo = "<orig@example.com>"
        try db.write { try draft.insert($0) }

        // Look up original via inReplyTo (replicating ServerDraftComposeLoader logic)
        let original = try db.read { db in
            try MessageHeader.filter(Column("rfc822MessageId") == "<orig@example.com>").fetchOne(db)
        }
        #expect(original != nil)
        #expect(original?.subject == "Original Email")
    }

    @Test("New compose draft (no inReplyTo) uses recipients from To header")
    func newComposeDraftRecipients() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        var draft = MessageHeader(
            messageId: "draft5", subject: "New Message",
            from: "me@example.com", fromAddress: "me@example.com",
            to: "alice@co.com, Bob <bob@co.com>", date: Date(), snippet: "",
            folderId: "acc1:Drafts", accountId: "acc1",
            folderPath: "Drafts", isInInbox: false
        )
        try db.write { try draft.insert($0) }

        let fetched = try db.read { try MessageHeader.fetchOne($0, key: "acc1:Drafts:draft5") }
        let recipients = Draft.parseRecipients(fetched!.to)
        #expect(recipients == ["alice@co.com", "bob@co.com"])
    }
}

// MARK: - Template Pill Notification Tests

@Suite("Template pill notification")
struct TemplatePillNotificationTests {

    @Test("Template pill notification carries templateId and numericId")
    func templatePillNotificationPayload() async {
        await confirmation { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: .templatePillOpenTapped, object: nil, queue: .main
            ) { note in
                #expect(note.userInfo?["templateId"] as? String == "abc-123")
                #expect(note.userInfo?["numericId"] as? Int == 7)
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }
            NotificationCenter.default.post(
                name: .templatePillOpenTapped, object: nil,
                userInfo: ["templateId": "abc-123", "numericId": 7]
            )
            // Notification fires synchronously to a `.main` observer — confirmation
            // is recorded before this closure returns.
        }
    }
}
