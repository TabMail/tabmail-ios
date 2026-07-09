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

    /// Reserved after the LAST LLM call finishes for step 7 (staging persist)
    /// + step 8 (notification build). Staging writes measure 1-20ms in
    /// production — this margin comfortably covers that tail so a call that
    /// used its full budget still leaves `process()` time to reach `deliver`.
    static let llmFinishMarginSeconds: TimeInterval = 2.5
    /// Floor below which an LLM call isn't worth starting — `llmCallBudget`
    /// returns nil (skip) rather than handing a call a budget too small to
    /// plausibly complete a summary/action round-trip.
    static let llmMinCallSeconds: TimeInterval = 2

    /// Graceful-exit watchdog. iOS gives an NSE a ~30 s wall-clock budget before
    /// it calls `serviceExtensionTimeWillExpire` and then hard-suspends. Our own
    /// watchdog fires `watchdogSeconds` BEFORE that edge so cleanup (release the
    /// AI lease + deliver a passive notification) happens with comfortable margin
    /// — NOT racing the suspension, which would risk a RUNNINGBOARD 0xdead10cc on
    /// a SQLite write in flight.
    ///
    /// LLM calls are now deadline-budgeted (see `NSEProviderSupport.llmCallBudget`,
    /// `llmFinishMarginSeconds`, `llmMinCallSeconds`): each call's timeout is
    /// capped to what's left of this window minus the finish margin, so a
    /// healthy-but-slow run finishes (or gives up on a call) and reaches step
    /// 7/8 — deliver — on its own, well before this fires. This watchdog is
    /// therefore a true backstop: it should only fire on a truly stuck
    /// non-LLM step (network hang below the deadline-budgeted layer, DB lock,
    /// etc.), not as the normal way a slow LLM call gets cut off.
    static let watchdogSeconds: TimeInterval = 27
}
