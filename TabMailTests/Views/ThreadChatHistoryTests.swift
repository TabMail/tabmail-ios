/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114: the history a thread's chat sends, when the thread's chat is stored under more than
/// one key (here a thread spanning two accounts).
///
/// THE SYSTEM PROPERTY pinned here, through the real pill's Send, the production reader and a fake
/// backend that reads what the request sent: the history is every key's stored turns in time order
/// (turns of the same time: the thread's newest email's own first), and when it is over the budget
/// (`ChatStore.maxExchanges` exchanges, or their characters) it is the newest turns that fit. What
/// the chat shows keeps a live card where its session raised it.
extension ThreadChatTests {
    /// A stored user turn `seconds` after `base`, as the chat stores one.
    private static func storedTurn(_ words: String, session: String, base: Double, seconds: Int) -> ChatTurn {
        ChatTurn(
            id: "hist-\(UUID().uuidString)", timestamp: base + Double(seconds) * 1000, role: "user",
            content: "chat_converse", userMessage: words, type: "normal", chars: words.count, renderedContent: nil,
            sessionId: session, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
    }

    /// The thread: an email in account A, and a newer reply to it in account B, so the chat has two keys.
    private static func twoKeyThread(_ tag: String) -> (older: MessageHeader, newer: MessageHeader) {
        let older = header("8\(tag)1", from: "Ann Example", rfc: "hist-1\(tag)@example.com", thread: "hist-thread-\(tag)", minutesAgo: 600)
        let newer = header(
            "8\(tag)2", account: accountB, from: "Bea Example", rfc: "hist-2\(tag)@example.com",
            inReplyTo: "hist-1\(tag)@example.com", thread: "hist-2\(tag)@example.com", minutesAgo: 1)
        return (older, newer)
    }

    /// The words of the history turns the request sent (the question itself, last, left out).
    private static func sentHistory(_ body: String) throws -> [String] {
        try messages(body).dropLast().compactMap { message -> String? in
            guard message["role"] as? String == "user" else { return nil }
            // A message's variables sit beside its role and content (`CompletionsMessage.encode`).
            return message["user_message"] as? String
        }
    }

    /// The order the history must have: by time, the newest email's key first on equal times.
    private static func chronological(_ turns: [ChatTurn], ownKey: String) -> [ChatTurn] {
        turns.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp { return lhs.element.timestamp < rhs.element.timestamp }
            let lhsOwn = lhs.element.sessionId == ownKey, rhsOwn = rhs.element.sessionId == ownKey
            if lhsOwn != rhsOwn { return lhsOwn }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    enum Over: String, CaseIterable, CustomTestStringConvertible {
        /// More turns than `maxExchanges` exchanges.
        case turns
        /// Fewer turns, but more characters than the budget.
        case characters
        var testDescription: String { rawValue }
    }

    @Test("The history a thread's chat sends is every key's turns in time order, the newest that fit the budget",
          arguments: Over.allCases)
    func historyAcrossKeysIsChronologicalAndBudgeted(over: Over) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted Send")
        try await HostedAccessibility.withAutomation { try await historyAcrossKeysBody(over: over) }
    }

    private func historyAcrossKeysBody(over: Over) async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let (older, newer) = Self.twoKeyThread(over == .turns ? "t" : "c")
        try Self.insert(older, newer, pool: pool)
        let ownKey = ChatThreadKey.key(for: newer), otherKey = ChatThreadKey.key(for: older)
        #expect(ownKey != otherKey, "control: the thread's chat is stored under two keys")

        // The two keys' turns interleave in time; each key is stored in its own time order. Two
        // turns, one per key, share a time near the newest end.
        let maxTurns = ChatStore.maxExchanges * 2
        let maxChars = ChatStore.maxExchanges * ChatStore.charsPerExchange
        let base = Date().addingTimeInterval(-6 * 3600).timeIntervalSince1970 * 1000
        var turns: [ChatTurn] = []
        switch over {
        case .turns:
            for index in 0..<(maxTurns + 20) {
                let key = index % 2 == 0 ? otherKey : ownKey
                turns.append(Self.storedTurn("turn \(index)", session: key, base: base, seconds: index * 10))
            }
        case .characters:
            let long = maxChars / 4 + 1
            for index in 0..<8 {
                let key = index % 2 == 0 ? ownKey : otherKey
                let words = "turn \(index) " + String(repeating: "x", count: long)
                turns.append(Self.storedTurn(words, session: key, base: base, seconds: index * 10))
            }
        }
        let last = turns.count * 10
        turns.append(Self.storedTurn("same time, other key", session: otherKey, base: base, seconds: last))
        turns.append(Self.storedTurn("same time, own key", session: ownKey, base: base, seconds: last))
        let stored = turns
        try await pool.write { db in for turn in stored { try turn.insert(db) } }

        let expected = ThreadChatReader.budgeted(Self.chronological(turns, ownKey: ownKey)).compactMap(\.userMessage)
        #expect(expected.count < turns.count, "control: the stored chat is over the budget")
        #expect(expected.suffix(2) == ["same time, own key", "same time, other key"], "control: equal times, own key first")
        switch over {
        case .turns: #expect(expected.count == maxTurns, "control: the budget's turn count")
        case .characters: #expect(expected.count < maxTurns && expected.map(\.count).reduce(0, +) <= maxChars,
                                  "control: the characters, not the count, cut it")
        }

        let backend = Backend()
        try await Self.withBackend(backend, chatView: true) {
            try await Self.withPill(newer, inChatView: true) { _, view in
                try await Self.ask("Which day works", in: view, backend: backend)
            }
        }
        let bodies = backend.bodies
        #expect(bodies.count == 1)
        guard bodies.count == 1 else { return }
        let sent = try Self.sentHistory(bodies[0])
        #expect(sent == expected, "\(over): the newest turns that fit, oldest first: sent \(sent.count) \(sent.prefix(3))…\(sent.suffix(3)), expected \(expected.count) \(expected.prefix(3))…\(expected.suffix(3))")
        #expect(sent.first.map { !$0.hasPrefix("turn 0 ") && $0 != "turn 0" } == true, "\(over): the oldest turn is the one dropped")
    }

    @Test("The thread's chat shows a live card where its session raised it, among the other key's turns by time")
    func liveCardKeepsItsPlace() async throws {
        let (pool, directory, previous) = try Self.install()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let (older, newer) = Self.twoKeyThread("l")
        try Self.insert(older, newer, pool: pool)
        let ownKey = ChatThreadKey.key(for: newer), otherKey = ChatThreadKey.key(for: older)
        let base = Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        let turns = [
            Self.storedTurn("older 1", session: otherKey, base: base, seconds: 0),
            Self.storedTurn("newer 1", session: ownKey, base: base, seconds: 10),
            Self.storedTurn("older 2", session: otherKey, base: base, seconds: 20),
            Self.storedTurn("newer 2", session: ownKey, base: base, seconds: 40),
        ]
        try await pool.write { db in for turn in turns { try turn.insert(db) } }
        ChatPillState.shared.removeAllSessions()
        defer { ChatPillState.shared.removeAllSessions() }

        let keys = await ThreadChatReader.keys(about: newer)
        #expect(keys == [ownKey, otherKey], "control: the newest email's key first")
        await ThreadChatReader.load(keys: keys)
        // A request about the older email raised a card after its last turn, before "newer 2".
        let card = AgentToolRouter.ActionConfirmation(
            action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [], onRespond: { _ in })
        ChatPillState.shared.session(for: otherKey).chatMessages.append(ChatMessage(
            role: .agent, content: "", timestamp: Date(timeIntervalSince1970: (base + 30_000) / 1000), actionConfirmation: card))

        let shown = ThreadChatReader.messages(keys: keys).map { $0.actionConfirmation != nil ? "card" : $0.content }
        #expect(shown == ["older 1", "newer 1", "older 2", "card", "newer 2"], "\(shown)")
    }
}
