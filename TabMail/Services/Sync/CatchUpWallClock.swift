/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// The one wall clock of the catch-up's protection of completed user actions
/// (ADR-IOS-107): when an action completed (`AccountManager.recordActionCompleted`),
/// when a catch-up read began (`SyncEngine.runCatchUp`) and when its result is
/// applied (`SyncEngine.applyCatchUpTransaction`). Never `CatchUpContext.clock`,
/// which measures a slice's request budget and which tests move on their own.
enum CatchUpWallClock {
    nonisolated static func now() -> Date {
        #if DEBUG
        if let clock = nowForTesting.withLock({ $0 }) { return clock() }
        #endif
        return Date()
    }

    #if DEBUG
    /// A test's clock; nil (the default) reads the system clock.
    nonisolated static let nowForTesting = Mutex<(@Sendable () -> Date)?>(nil)
    #endif
}
