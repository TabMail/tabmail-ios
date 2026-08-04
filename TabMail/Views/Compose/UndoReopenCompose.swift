/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Reopens compose on the exact Draft generation retained after confirmed Undo.
struct UndoReopenCompose: View {
    let snapshot: PendingSendService.ReopenSnapshot

    var body: some View {
        Self.composeView(for: snapshot)
    }

    static func composeView(for snapshot: PendingSendService.ReopenSnapshot) -> ComposeView {
        // RESTORE — shipped `v1.6.38` (`07a4bb703:UndoReopenCompose.swift`) built the
        // reopened compose as
        //   `ComposeView(replyTo:account:isForward: snapshot.isForward, prefill…)`,
        // its `ReopenSnapshot.isForward` populated from `draft.isForward`. v3's
        // `ReopenSnapshot` is `{ id, authority }`, so the SAME source of truth — the
        // retained row's own `isForward` column — is read here instead.
        //
        // Dropping the argument let `ComposeView.isForward` take its `= false`
        // default. The compose still LOOKED like a forward (the load path quotes from
        // `draft.isForward`), but `send()` captures the VIEW property into
        // `AuthoredSendSnapshot.isForward`, so an undone-and-resent forward was
        // recorded as a REPLY: `persistQueuedSend` set the parent's `isReplied`,
        // cleared its Reply action tag, and stored `OutboxMessage.isForward = false`,
        // which on delivery queues `.markReplied` and STOREs `\Answered` — never
        // `$Forwarded`. Sync converges on the wrong answer rather than repairing it.
        //
        // Account and row are read in ONE snapshot: they are consumed together and a
        // second read could observe a different generation.
        let reopened: (account: Account?, draft: Draft?)? = try? AppDatabase.dbPool.read { db in
            (account: try Account.fetchOne(db, key: snapshot.authority.accountId),
             draft: try Draft.fetchOne(db, key: snapshot.authority.draftId))
        }

        return ComposeView(
            account: reopened?.account,
            isForward: reopened?.draft?.isForward ?? false,
            prefillDraftId: snapshot.authority.draftId,
            retainedDraftAuthority: snapshot.authority
        )
    }
}
