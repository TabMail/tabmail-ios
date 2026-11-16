/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// ADR-IOS-114: the TabMail chat of an email belongs to its thread, `thread:<accountId>:<threadId>`.
/// The thread id is the one the inbox groups by (`ThreadGroupBuilder`): `computedThreadId`, or
/// the header's own id when it has none. Stored turns carry the key in `sessionId`, with the
/// `demo:` scope while a demo runs (`DemoModeStore.scopedSessionId`); the in-process session
/// (`ChatPillState.session(for:)`) uses the bare key. `AppDatabase` v107 moved every per-email
/// chat (`msg:<accountId>:<stableId>`) to its thread's key.
enum ChatThreadKey {
    static let prefix = "thread:"

    /// The key of `header`'s thread.
    static func key(for header: MessageHeader) -> String {
        key(accountId: header.accountId, id: header.id, computedThreadId: header.computedThreadId)
    }

    /// The key of the thread of the email with header id `id`.
    static func key(accountId: String, id: String, computedThreadId: String) -> String {
        key(accountId: accountId, threadId: computedThreadId.isEmpty ? id : computedThreadId)
    }

    static func key(accountId: String, threadId: String) -> String {
        "\(prefix)\(accountId):\(threadId)"
    }

    /// The emails of a key's thread, as SQL over `messageHeader`; arguments: account id, thread
    /// id, thread id. Served by `messageHeader_computedThreadId` and the primary key.
    static let memberSQL = "accountId = ? AND (computedThreadId = ? OR (computedThreadId = '' AND id = ?))"

    /// The header id of the newest email of a key's thread (an agent toast opens it), or nil
    /// when the thread has no email left.
    static func newestMessageId(of sessionKey: String, db: Database) throws -> String? {
        guard let (accountId, threadId) = parse(sessionKey) else { return nil }
        return try String.fetchOne(db, sql: "SELECT id FROM messageHeader WHERE \(memberSQL) ORDER BY date DESC, id DESC LIMIT 1",
                                   arguments: [accountId, threadId, threadId])
    }

    /// The account and thread a key (bare or `demo:`-scoped) names. An account id holds no
    /// colon; a thread id may (a Message-ID, a header id), so the split is at the first one.
    static func parse(_ sessionKey: String) -> (accountId: String, threadId: String)? {
        var key = Substring(sessionKey)
        if key.hasPrefix("demo:") { key = key.dropFirst("demo:".count) }
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let accountId = String(rest[..<colon]), threadId = String(rest[rest.index(after: colon)...])
        guard !accountId.isEmpty, !threadId.isEmpty else { return nil }
        return (accountId, threadId)
    }
}

/// The one reader of a thread's TabMail chat, for what the pill shows and for the history a
/// request sends (ADR-IOS-114). A thread's emails can carry more than one key: a copy in another
/// account, or two threads a newer email joins. The chat is every key's turns, merged by time,
/// so joined chats read as one with no re-keying. Each key keeps its own in-process session,
/// where its live state stays: a confirmation card raised by a request about one email shows,
/// in place, in the chat of the thread's newest email.
@MainActor
enum ThreadChatReader {

    /// The keys of `newest`'s chat: its own first, then those of every other email of the thread
    /// the chat shows (`ThreadDetection.related`, every account, copies included).
    static func keys(newest: MessageHeader) async -> [String] {
        let pool = AppDatabase.rawPool
        let members: [MessageHeader] = await Task.detached {
            do {
                let related = try ThreadDetection.related(to: newest, in: pool)
                return related.messages + related.copies
            } catch {
                BackgroundSyncLogger.logDebug("[ThreadChat] Thread lookup failed, own key only: \(error)")
                return []
            }
        }.value
        return keys(newest: newest, members: members)
    }

    nonisolated static func keys(newest: MessageHeader, members: [MessageHeader]) -> [String] {
        var seen = Set<String>()
        return ([newest] + members).map(ChatThreadKey.key(for:)).filter { seen.insert($0).inserted }
    }

    /// Reads each key's stored turns into its session, once per session.
    static func load(keys: [String]) async {
        for key in keys {
            await ChatPillState.shared.session(for: key)
                .loadStoredTurns(sessionId: DemoModeStore.scopedSessionId(key))
        }
    }

    /// The chat as shown: every key's messages, live cards included, merged by time.
    static func messages(keys: [String]) -> [ChatMessage] {
        merged(keys.map { ChatPillState.shared.session(for: $0).chatMessages }, by: \.timestamp)
    }

    /// The history a request sends: every key's turns merged by time, within the budget.
    static func history(keys: [String]) -> [ChatTurn] {
        budgeted(merged(keys.map { ChatPillState.shared.session(for: $0).sessionTurns }, by: \.timestamp))
    }

    /// Display messages for stored turns (text only; cards are live state, never stored).
    nonisolated static func chatMessages(for turns: [ChatTurn]) -> [ChatMessage] {
        turns.compactMap { turn -> ChatMessage? in
            switch turn.role {
            case "user":
                let displayText = turn.renderedContent ?? turn.userMessage ?? turn.content
                return ChatMessage(role: .user, content: displayText, timestamp: Date(timeIntervalSince1970: turn.timestamp / 1000))
            case "assistant":
                guard turn.type == "normal" else { return nil }
                let displayText = turn.renderedContent ?? turn.content
                return ChatMessage(role: .agent, content: displayText, timestamp: Date(timeIntervalSince1970: turn.timestamp / 1000))
            default:
                return nil
            }
        }
    }

    /// The lists merged by `time`, each list's own order kept (a stable k-way merge), so a card
    /// stays where its session raised it.
    nonisolated static func merged<T, Time: Comparable>(_ lists: [[T]], by time: (T) -> Time) -> [T] {
        var next = Array(repeating: 0, count: lists.count)
        var result: [T] = []
        result.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        while true {
            var pick: Int?
            for (index, list) in lists.enumerated() where next[index] < list.count {
                guard let current = pick else { pick = index; continue }
                if time(list[next[index]]) < time(lists[current][next[current]]) { pick = index }
            }
            guard let index = pick else { return result }
            result.append(lists[index][next[index]])
            next[index] += 1
        }
    }

    /// The newest turns within `ChatStore`'s budget: at most `maxExchanges` exchanges and
    /// `maxExchanges * charsPerExchange` characters, in time order.
    nonisolated static func budgeted(_ turns: [ChatTurn]) -> [ChatTurn] {
        let maxTurns = ChatStore.maxExchanges * 2
        let maxChars = ChatStore.maxExchanges * ChatStore.charsPerExchange
        var kept: [ChatTurn] = []
        var chars = 0
        for turn in turns.reversed() {
            guard kept.count < maxTurns, chars + turn.chars <= maxChars else { break }
            chars += turn.chars
            kept.append(turn)
        }
        return kept.reversed()
    }
}
