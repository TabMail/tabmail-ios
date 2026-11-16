/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Provider-agnostic incremental sync result. Collapses Gmail `history.list`,
/// Graph `$delta`, and IMAP IDLE/CONDSTORE into one shape.
struct HistoryDelta: Sendable {
    /// Opaque forward cursor. Gmail historyId / Graph deltaLink / IMAP MODSEQ.
    let cursor: String
    let added: [DeltaMessageRef]
    let removed: [DeltaMessageRef]
    let labelsAdded: [DeltaLabelChange]
    let labelsRemoved: [DeltaLabelChange]
}

struct DeltaMessageRef: Sendable {
    let providerMessageId: String
    let providerLabels: [String]
}

struct DeltaLabelChange: Sendable {
    let providerMessageId: String
    let labelIds: [String]
    /// Current labels on the message AFTER the change (Gmail supplies this; useful
    /// for NSE to distinguish "archived from inbox" vs "moved to another label while
    /// still in inbox").
    let currentLabels: [String]
}

/// One Gmail `users.history.list` page, record by record, for a reader that
/// can stop after any record and resume there (`startHistoryId` = that
/// record's id returns the records after it).
struct HistoryPage: Sendable {
    /// The page's `historyId`: the mailbox's current history id when it was served.
    let historyId: String
    /// In Gmail's order, increasing id.
    let records: [HistoryRecord]
    /// Nil on the last page.
    let nextPageToken: String?
}

/// One history record: its id and the changes it names (`changes.cursor` is empty).
struct HistoryRecord: Sendable {
    let id: String
    let changes: HistoryDelta
}
