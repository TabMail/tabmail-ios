/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Fails the test run when a sync-turn wait overruns
/// `SyncConfig.syncTurnWaitTestBoundSeconds`: a turn holder awaiting a task that
/// needs the same account's turn would otherwise hang the suite. The waiter is
/// released so the run continues; the issue names the waiting caller.
/// Installed once, by `ProcessGlobalTestState.withLock`.
enum TestSyncTurnWaitWatch {
    static let report: @Sendable (_ accountId: String, _ caller: String) -> Void = { accountId, caller in
        Issue.record("sync turn wait overran \(SyncConfig.syncTurnWaitTestBoundSeconds)s: \(caller) waited for account \(accountId)'s turn")
    }

    private static let installed: Void = {
        SyncEngine.syncTurnWaitWatch.withLock { $0 = report }
    }()

    static func installIfNeeded() {
        _ = installed
    }
}
