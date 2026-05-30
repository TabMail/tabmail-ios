/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import os.log

/// Centralized NSE logging. All logs go through here for consistent formatting.
/// In DEBUG builds, logs go to os_log (visible in Xcode console + Console.app).
/// In RELEASE builds, only errors are logged.
enum NSELog {
    private static let logger = Logger(subsystem: "ai.tabmail.ios.NotificationService", category: "NSE")

    static func info(_ message: String) {
        #if DEBUG
        logger.info("🔔 \(message, privacy: .public)")
        #endif
    }

    static func error(_ message: String) {
        logger.error("🔔❌ \(message, privacy: .public)")
    }

    static func timing(_ label: String, _ block: () async -> Void) async {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        await block()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        logger.info("🔔⏱ \(label, privacy: .public): \(ms)ms")
        #else
        await block()
        #endif
    }
}
