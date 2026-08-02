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
        let account: Account? = try? AppDatabase.dbPool.read { db in
            try Account.fetchOne(db, key: snapshot.authority.accountId)
        }

        return ComposeView(
            account: account,
            prefillDraftId: snapshot.authority.draftId,
            retainedDraftAuthority: snapshot.authority
        )
    }
}
