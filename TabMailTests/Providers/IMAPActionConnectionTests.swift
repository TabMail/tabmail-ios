/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("IMAPProvider action-connection liveness")
struct IMAPActionConnectionTests {
    @Test("Liveness NOOP runs only after the idle threshold")
    func livenessCheckUsesIdleThreshold() {
        let now = Date(
            timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down)
        )
        let threshold = SyncConfig.imapPoolLivenessCheckSeconds

        #expect(!IMAPProvider.shouldCheckConnectionLiveness(lastUsed: now, now: now))
        #expect(!IMAPProvider.shouldCheckConnectionLiveness(
            lastUsed: now.addingTimeInterval(-threshold),
            now: now
        ), "The exact threshold does not require a NOOP because production uses a strict greater-than check")
        #expect(IMAPProvider.shouldCheckConnectionLiveness(
            lastUsed: now.addingTimeInterval(-(threshold + 1)),
            now: now
        ), "A connection older than the threshold must be liveness-checked")
        #expect(IMAPProvider.shouldCheckConnectionLiveness(
            lastUsed: nil,
            now: now
        ), "A connection with no prior-use receipt must be liveness-checked")
    }
}
