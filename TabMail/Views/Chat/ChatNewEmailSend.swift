/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// A new email's send, as its chat shows it after the compose card's Send (ADR-IOS-114): the
/// send's outbox row while it is there, which the chat shows as its "Sending" bubble
/// (`ChatUnsentReply`, Undo, Retry and Delete included), and the sent email's copy in its
/// account's Sent folder once the provider took it, which the chat then opens as its thread.
/// Read from the database with nothing kept in memory but the key.
///
/// Found by the card's draft id (`ChatNewThreadModel.card`), which the row keeps: a new email has
/// no In-Reply-To to find it by, and a compose reopened by the bubble's Undo keeps that draft, so
/// its send again is found the same way. The row's Message-ID is written with the row; the chat
/// keeps it (`Key.email`), so it finds the Sent copy even when the row has gone before the copy
/// was read (a send that is cleaned up quickly after its copy is written).
struct ChatNewEmailSend: Equatable, Sendable {
    /// The sent email, by its account and normalized Message-ID.
    struct Email: Hashable, Sendable {
        let accountId: String
        let messageId: String
    }

    /// What the chat looks for: the card's draft, and the email its row named, once seen.
    struct Key: Hashable, Sendable {
        let draftId: String
        var email: Email?
    }

    /// The row while it is in the outbox.
    let reply: ChatUnsentReply?
    /// The email the row names (or named, from the key).
    let email: Email?
    /// The sent email's copy in its account's Sent folder: the header the chat opens as its thread.
    let sentCopyId: String?

    /// The send `key` names, now. The outbox holds only unsent mail, so its rows are read whole;
    /// the copy is read by its folder and Message-ID (`messageHeader_rfc822MessageId`).
    nonisolated static func fetch(_ key: Key, db: Database) throws -> ChatNewEmailSend {
        let row = try OutboxMessage
            .filter(Column("draftId") == key.draftId)
            .order(Column("createdAt").desc, Column("id").desc)
            .fetchOne(db)
        let rowEmail = row.flatMap { row in
            row.sentMessageId.map { Email(accountId: row.accountId, messageId: EmailFilter.normalizeMessageId($0)) }
        }
        let email = rowEmail ?? (row == nil ? key.email : nil)
        let sentCopyId = try email.flatMap { try sentCopy(of: $0, db: db) }
        guard let row else { return ChatNewEmailSend(reply: nil, email: email, sentCopyId: sentCopyId) }
        let reply = ChatUnsentReply(
            outboxId: row.id, status: row.outboxStatus, sentAt: row.sentAt, holdUntil: row.holdUntil,
            draftId: row.draftId, instanceEpoch: row.instanceEpoch, filed: sentCopyId != nil,
            textMessage: try SentEmailSummary.textMessage(of: row, db: db))
        return ChatNewEmailSend(reply: reply, email: email, sentCopyId: sentCopyId)
    }

    /// The copy of `email` in its account's Sent folder: the optimistic copy the send writes, or
    /// the server's once a sync has brought it, under the Message-ID the copy carries (its
    /// provider's own, when it gave one: `SentCopyLink`).
    private nonisolated static func sentCopy(of email: Email, db: Database) throws -> String? {
        guard let sent = try Folder
            .filter(Column("accountId") == email.accountId && Column("role") == FolderRole.sent.rawValue)
            .fetchOne(db) else { return nil }
        let copyMessageId = SentCopyLink.copyMessageId(accountId: email.accountId, sentMessageId: email.messageId)
        return try String.fetchOne(
            db, sql: "SELECT id FROM messageHeader INDEXED BY messageHeader_rfc822MessageId WHERE folderId = ? AND rfc822MessageId = ? LIMIT 1",
            arguments: [sent.id, copyMessageId])
    }

    /// The send `key` names, now and after every change, from one observation.
    static func changes(_ key: Key) -> AsyncValueObservation<ChatNewEmailSend> {
        ValueObservation
            .tracking { db in try fetch(key, db: db) }
            .removeDuplicates()
            .values(in: AppDatabase.rawPool)
    }
}
