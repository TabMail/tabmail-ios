/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ChatStore turnsToMessages")
struct ChatStoreTurnsToMessagesTests {

    @Test("Assistant turn converts to assistant role")
    func assistantTurnConverts() async {
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "Here's my response", userMessage: nil,
            type: "normal", chars: 20, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.count == 1)
        #expect(messages.first?.role == "assistant")
        #expect(messages.first?.content == "Here's my response")
    }

    @Test("Session break turns are skipped")
    func sessionBreakSkipped() async {
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "break", userMessage: nil,
            type: "session_break", chars: 5, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.isEmpty)
    }

    @Test("Unknown role is skipped")
    func unknownRoleSkipped() async {
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "system",
            content: "system msg", userMessage: nil,
            type: "normal", chars: 10, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.isEmpty)
    }

    @Test("Assistant turn with thinking encodes thinking in JSON")
    func assistantTurnWithThinking() async throws {
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "Response", userMessage: nil,
            type: "normal", chars: 8, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: "I reasoned about this"
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.count == 1)
        let data = try JSONEncoder().encode(messages[0])
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["thinking"] as? String == "I reasoned about this")
        #expect(dict["role"] as? String == "assistant")
        #expect(dict["content"] as? String == "Response")
    }

    @Test("Assistant turn without thinking has no thinking key in JSON (backward compat)")
    func assistantTurnWithoutThinking() async throws {
        let turn = ChatTurn(
            id: "t1", timestamp: 1000, role: "assistant",
            content: "Response", userMessage: nil,
            type: "normal", chars: 8, renderedContent: nil,
            sessionId: nil, remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        let messages = await ChatStore.shared.turnsToMessages([turn])
        #expect(messages.count == 1)
        let data = try JSONEncoder().encode(messages[0])
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["thinking"] == nil)
        #expect(dict["role"] as? String == "assistant")
    }

    @Test("Mixed turns convert in order, skipping invalid")
    func mixedTurns() async {
        let turns = [
            ChatTurn(id: "t1", timestamp: 1000, role: "user",
                     content: "chat_converse", userMessage: "Hi",
                     type: "normal", chars: 2, renderedContent: nil,
                     sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t2", timestamp: 2000, role: "assistant",
                     content: "Hello!", userMessage: nil,
                     type: "normal", chars: 6, renderedContent: nil,
                     sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t3", timestamp: 3000, role: "assistant",
                     content: "break", userMessage: nil,
                     type: "session_break", chars: 5, renderedContent: nil,
                     sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
            ChatTurn(id: "t4", timestamp: 4000, role: "user",
                     content: "chat_converse", userMessage: nil,
                     type: "normal", chars: 0, renderedContent: nil,
                     sessionId: nil, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        let messages = await ChatStore.shared.turnsToMessages(turns)
        // t1 (user with msg) + t2 (assistant normal) = 2, t3 session_break + t4 nil userMessage skipped
        #expect(messages.count == 2)
    }
}

@Suite("ChatStore Reminder Snapshots")
struct ChatStoreReminderSnapshotTests {

    @Test("Encode and decode reminder snapshots round-trip")
    func reminderRoundTrip() {
        let reminders = [
            Reminder(type: "reminder", content: "Follow up with Alice", dueDate: "2024-03-15", dueTime: "10:00",
                     source: "email", hash: "abc123", enabled: true, action: nil,
                     messageId: nil, uniqueId: nil, subject: "Re: Budget", from: "alice@test.com",
                     instruction: nil, scheduleDays: nil, scheduleDate: nil, scheduleTime: nil, timezone: nil, rawLine: nil)
        ]
        let encoded = ChatStore.encodeRemindersSnapshot(reminders)
        #expect(encoded != nil)

        let decoded = ChatStore.decodeRemindersSnapshot(encoded!)
        #expect(decoded?.count == 1)
        #expect(decoded?.first?.content == "Follow up with Alice")
        #expect(decoded?.first?.dueDate == "2024-03-15")
        #expect(decoded?.first?.hash == "abc123")
        #expect(decoded?.first?.subject == "Re: Budget")
    }

    @Test("Decode nil on invalid JSON")
    func decodeNilOnInvalid() {
        let decoded = ChatStore.decodeRemindersSnapshot("not json")
        #expect(decoded == nil)
    }

    @Test("Encode empty array")
    func encodeEmptyArray() {
        let encoded = ChatStore.encodeRemindersSnapshot([])
        #expect(encoded != nil)
        let decoded = ChatStore.decodeRemindersSnapshot(encoded!)
        #expect(decoded?.isEmpty == true)
    }
}
