/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@testable import TabMail

/// A saved chat about one email as the tests read it back: the session ids its
/// turns and their history copies are stored under, and the email its first
/// turn names (`EmailContextSnapshot`).
struct SavedChat: Equatable, Sendable {
    let turnSessions: Set<String>
    let historySessions: Set<String>
    let namedEmail: String?
}

/// Writes and reads a saved chat about one email the way the message chat
/// stores it: a question naming the email, and a reply, in `chatTurn` and in
/// `chatHistory`. `tag` makes the turn ids unique to one test.
enum SavedChatFixture {

    /// The chat's session id for the email with `stableId`, in the user's own
    /// form or a demo's.
    static func sessionId(accountId: String, stableId: String, demo: Bool = false) -> String {
        let sessionId = ChatStore.messageSessionId(accountId: accountId, stableId: stableId)
        return demo ? "demo:\(sessionId)" : sessionId
    }

    static func insert(tag: String, sessionId: String, namingHeaderId headerId: String, db: Database) throws {
        let now = Date().timeIntervalSince1970 * 1000
        let context = ChatStore.encodeEmailContext(EmailContextSnapshot(
            messageHeaderId: headerId, subject: "Fixture", from: "sender@example.com"))
        let turns = [
            ChatTurn(
                id: "\(tag)-1", timestamp: now, role: "user", content: "chat_converse",
                userMessage: "What does this ask?", type: "normal", chars: 19, renderedContent: nil,
                sessionId: sessionId, remindersSnapshot: nil, emailContextJSON: context, thinkingContent: nil),
            ChatTurn(
                id: "\(tag)-2", timestamp: now + 1, role: "assistant", content: "It asks for a date.",
                userMessage: nil, type: "normal", chars: 19, renderedContent: nil,
                sessionId: sessionId, remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil),
        ]
        for turn in turns {
            try turn.insert(db)
            try ChatHistoryTurn(
                id: turn.id, timestamp: turn.timestamp, role: turn.role, content: turn.content,
                userMessage: turn.userMessage, sessionId: sessionId, chars: turn.chars, type: turn.type
            ).insert(db)
        }
    }

    static func read(tag: String, db: Database) throws -> SavedChat {
        let ids = ["\(tag)-1", "\(tag)-2"]
        let turns = try ChatTurn.filter(keys: ids).fetchAll(db)
        let history = try ChatHistoryTurn.filter(keys: ids).fetchAll(db)
        let first = turns.first { $0.id == "\(tag)-1" }
        return SavedChat(
            turnSessions: Set(turns.compactMap(\.sessionId)),
            historySessions: Set(history.compactMap(\.sessionId)),
            namedEmail: first?.emailContextJSON.flatMap(ChatStore.decodeEmailContext)?.messageHeaderId)
    }

    /// How the chat reads when it is saved under `sessionId` and names `headerId`.
    static func expected(sessionId: String, namingHeaderId headerId: String) -> SavedChat {
        SavedChat(turnSessions: [sessionId], historySessions: [sessionId], namedEmail: headerId)
    }

    /// Removes the chat, for a suite that writes to a shared database.
    static func delete(tag: String, db: Database) throws {
        let ids = ["\(tag)-1", "\(tag)-2"]
        _ = try ChatTurn.deleteAll(db, keys: ids)
        _ = try ChatHistoryTurn.deleteAll(db, keys: ids)
    }
}
