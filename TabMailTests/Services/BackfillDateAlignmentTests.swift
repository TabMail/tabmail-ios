/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Backfill Date Alignment")
struct BackfillDateAlignmentTests {

    @Test("BackfillProfile inter-batch delay ordering")
    func interBatchDelayOrdering() {
        // More aggressive profiles have shorter delays
        let lowDelay = BackfillProfile.low.imapInterBatchDelay
        let normalDelay = BackfillProfile.normal.imapInterBatchDelay
        let aggressiveDelay = BackfillProfile.aggressive.imapInterBatchDelay
        let turboDelay = BackfillProfile.turbo.imapInterBatchDelay

        #expect(lowDelay >= normalDelay)
        #expect(normalDelay >= aggressiveDelay)
        #expect(aggressiveDelay >= turboDelay)
    }
}
