/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

extension SyncEngine {

    // MARK: - BGTask Wrapper

    /// Thin wrapper for BGTask execution (SyncScheduler).
    /// Runs the walk within the time budget.
    /// Returns true if any work was done.
    func performBackfill(account: Account, deadline: Date? = nil) async -> Bool {
        let didWork = await runBackfill(account: account, deadline: deadline)
        await updateBackfillProgressForAccount(account)
        return didWork
    }
}
