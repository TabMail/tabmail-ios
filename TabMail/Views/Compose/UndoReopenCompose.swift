/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Presents a fresh ComposeView populated from a `PendingSendService.ReopenSnapshot`.
///
/// Called from RootView when the user taps Undo on the send toast. The Draft
/// row has already been deleted by `PendingSendService.undo()` so this compose
/// is NOT bound to any existing draft — close → save-draft prompt flows
/// through the existing `saveDraftAndDismiss` path as if the user had typed
/// the content fresh. Attachments and replyTo context are restored from the
/// snapshot so the reopened compose matches what the user had at send time.
struct UndoReopenCompose: View {
    let snapshot: PendingSendService.ReopenSnapshot

    var body: some View {
        // Resolve replyTo MessageHeader + Account synchronously. Tiny reads
        // on an in-process DB; no loading spinner needed.
        let replyTo: MessageHeader? = snapshot.replyToId.flatMap { id in
            try? AppDatabase.dbPool.read { db in try MessageHeader.fetchOne(db, key: id) }
        }
        let account: Account? = try? AppDatabase.dbPool.read { db in
            try Account.fetchOne(db, key: snapshot.accountId)
        }

        ComposeView(
            replyTo: replyTo,
            account: account,
            isForward: snapshot.isForward,
            prefillTo: snapshot.to.isEmpty ? nil : snapshot.to,
            prefillCc: snapshot.cc.isEmpty ? nil : snapshot.cc,
            prefillBcc: snapshot.bcc.isEmpty ? nil : snapshot.bcc,
            prefillSubject: snapshot.subject.isEmpty ? nil : snapshot.subject,
            prefillBody: snapshot.body.isEmpty ? nil : snapshot.body,
            prefillAttachments: snapshot.attachments.isEmpty ? nil : snapshot.attachments,
            prefillTreatAsUnsavedChanges: true
        )
    }
}
