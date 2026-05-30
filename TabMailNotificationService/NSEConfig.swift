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
}
