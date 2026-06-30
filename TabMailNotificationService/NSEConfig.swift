/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum NSEConfig {
    static let summaryTimeoutSeconds: TimeInterval = 12
    static let actionTimeoutSeconds: TimeInterval = 12
    static let taskTimeoutSeconds: TimeInterval = 24
    static let followUpTimeoutSeconds: TimeInterval = 5
    static let fanOutTimeoutSeconds: TimeInterval = 5
    static let actionVoteCount = 1
    static let stagingDBBusyTimeoutSeconds: TimeInterval = 2
    static let stagingDBFileName = "nse_staging.sqlite"
    static let schemaVersion = 1

    /// Graceful-exit watchdog. iOS gives an NSE a ~30 s wall-clock budget before
    /// it calls `serviceExtensionTimeWillExpire` and then hard-suspends. Our own
    /// watchdog fires `watchdogSeconds` BEFORE that edge so cleanup (release the
    /// AI lease + deliver a passive notification) happens with comfortable margin
    /// — NOT racing the suspension, which would risk a RUNNINGBOARD 0xdead10cc on
    /// a SQLite write in flight. Set past the AI's own budget (summary 12 s +
    /// action 12 s sequential ≈ 24 s + overhead) so a healthy run finishes and
    /// cancels the watchdog first; it only fires when the NSE has genuinely
    /// overrun and a clean handoff to the main app is the right call.
    static let watchdogSeconds: TimeInterval = 27
}
