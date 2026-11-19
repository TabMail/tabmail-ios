/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The columns of a chat email that decide whether it still needs its summary (ADR-IOS-114
/// decision 9): its body, its summary and its text message. The shown chat observes them for its
/// emails, so a body or summary that lands by any writer reaches the chat. Whether the email still
/// needs work is never decided here: `ActiveAIQueue.enqueueChatSummaries` reads the row again and
/// asks `ActiveAIQueue.summaryDone`. This only tells which emails changed.
struct ChatSummaryState: Equatable, Sendable {
    let id: String
    let bodyComplete: Bool
    let hasSummary: Bool
    let hasTextMessage: Bool

    /// The state of each of `ids` still in the database, by id. Only these columns are read, so a
    /// write to anything else (read state, flags) does not change the observed value.
    nonisolated static func fetch(ids: [String], db: Database) throws -> [ChatSummaryState] {
        guard !ids.isEmpty else { return [] }
        let rows = try MessageHeader
            .select(Column("id"), Column("bodyComplete"), Column("summaryBlurb"), Column("summaryTextMessage"))
            .filter(keys: ids)
            .order(Column("id"))
            .asRequest(of: Row.self)
            .fetchAll(db)
        return rows.map { row in
            let blurb: String? = row["summaryBlurb"]
            let textMessage: String? = row["summaryTextMessage"]
            return ChatSummaryState(id: row["id"], bodyComplete: row["bodyComplete"],
                                    hasSummary: !(blurb ?? "").isEmpty, hasTextMessage: textMessage != nil)
        }
    }

    /// The state of `ids`, now and after every change to it, from one observation.
    static func changes(ids: [String]) -> AsyncValueObservation<[ChatSummaryState]> {
        ValueObservation
            .tracking { db in try fetch(ids: ids, db: db) }
            .removeDuplicates()
            .values(in: AppDatabase.rawPool)
    }

    /// The ids in `current` whose state differs from `previous`, or that `previous` lacks.
    static func changedIds(_ current: [ChatSummaryState], since previous: [ChatSummaryState]) -> Set<String> {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(current.filter { before[$0.id] != $0 }.map(\.id))
    }
}
