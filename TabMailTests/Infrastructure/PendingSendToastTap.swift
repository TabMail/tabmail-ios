/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@testable import TabMail

extension PendingSendService {
    /// The toast's Undo tap as its presenter runs it (`PendingSendToastPresenter`: `undoAndReopen()`), returning the compose it
    /// queued to reopen, or nil when it queued none. The reopen queue is emptied before and after,
    /// so no reopen leaks into another test.
    func tapToastUndo() -> ReopenSnapshot? {
        while reopenSnapshot != nil { finishReopen() }
        undoAndReopen()
        let snapshot = reopenSnapshot
        while reopenSnapshot != nil { finishReopen() }
        return snapshot
    }
}
