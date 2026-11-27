/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// The Message-ID a provider gave an email's Sent copy, by the Message-ID the send wrote, for this
/// run of the app.
///
/// Gmail replaces the Message-ID a send writes with one of its own, and the send writes its Sent row
/// as Gmail lists the copy (`AccountManager.insertOptimisticSentHeader`), while the outbox row and
/// the summary made at Send know only the send's own Message-ID. The send records the pair here
/// before it writes the Sent row, only when the two differ, and every read that looks for an
/// email's Sent copy by the send's Message-ID looks under the copy's instead: the chat's Sending
/// bubble (`ChatUnsentReply.fetch`), a new email's send follow (`ChatNewEmailSend.fetch`) and the
/// late summary (`SentEmailSummary`). Those reads run inside their own observations or write
/// transactions, so the Sent row's commit re-runs them with the pair already here.
///
/// Kept in memory only: nothing is stored (ADR-004). After a relaunch the pairs are gone; a send
/// killed between its Sent row and its cleanup keeps its bubble until the next drain removes its
/// outbox row, as a send whose copy is not read does.
enum SentCopyLink {
    private struct Key: Hashable {
        let accountId: String
        let sentMessageId: String
    }

    private static let copies = Mutex<[Key: String]>([:])

    /// Records that the email `accountId` sent with `sentMessageId` has its Sent copy under
    /// `copyMessageId`. Both are normalized here; nothing is recorded when they are the same.
    static func record(accountId: String, sentMessageId: String, copyMessageId: String) {
        let sent = EmailFilter.normalizeMessageId(sentMessageId)
        let copy = EmailFilter.normalizeMessageId(copyMessageId)
        guard sent != copy else { return }
        copies.withLock { $0[Key(accountId: accountId, sentMessageId: sent)] = copy }
    }

    /// The normalized Message-ID of the Sent copy of the email `accountId` sent with
    /// `sentMessageId`: the one its provider gave it, else `sentMessageId` itself.
    static func copyMessageId(accountId: String, sentMessageId: String) -> String {
        let sent = EmailFilter.normalizeMessageId(sentMessageId)
        return copies.withLock { $0[Key(accountId: accountId, sentMessageId: sent)] } ?? sent
    }
}
