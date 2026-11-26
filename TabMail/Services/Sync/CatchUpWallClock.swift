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

/// One catch-up read's over-age verdict (`SyncEngine.catchUpReadIsOverAge`), as a
/// one-way latch (#1062). The apply checks it before the insert, each insert chunk
/// inside its own write, and the transaction inside its write; once any check finds
/// the read over-age, every later check does too, so a slice suspended at any point
/// still drops what follows and never flips back. `loadsSkipped` records that a
/// load was dropped for it, so the transaction marks the listing unclean.
final class CatchUpReadLatch: Sendable {
    let readStartedAt: Date
    private let state = Mutex<(overAge: Bool, loadsSkipped: Bool)>((false, false))

    init(readStartedAt: Date) { self.readStartedAt = readStartedAt }

    /// Checks the clock now; true once any check has found the read over-age.
    func checkOverAge() -> Bool {
        let overAgeNow = SyncEngine.catchUpReadIsOverAge(readStartedAt: readStartedAt, now: CatchUpWallClock.now())
        return state.withLock { latched in
            if overAgeNow { latched.overAge = true }
            return latched.overAge
        }
    }

    func noteLoadsSkipped() { state.withLock { $0.loadsSkipped = true } }

    var loadsSkipped: Bool { state.withLock { $0.loadsSkipped } }
}
