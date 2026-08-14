/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("Image failure notice policy — generic failures stay silent")
struct ImageLoadFailureNoticePolicyTests {
    @Test("A valid image-error census is diagnostic-only")
    func validReportIsDiagnosticOnly() {
        #expect(
            ImageLoadFailureReportDisposition.classify(["failed": 2, "deferred": 4])
                == .diagnosticOnly(failed: 2, deferred: 4)
        )
    }

    @Test("Routine single-image failure still cannot select user-visible UI")
    func routineFailureHasNoNoticeDisposition() {
        let disposition = ImageLoadFailureReportDisposition.classify([
            "failed": 1,
            "deferred": 1
        ])
        guard case .diagnosticOnly(let failed, let deferred) = disposition else {
            Issue.record("a valid routine failure must remain a diagnostic")
            return
        }
        #expect(failed == 1)
        #expect(deferred == 1)
    }

    @Test("Malformed input is rejected, not converted into a notice")
    func malformedReportIsRejected() {
        for body: Any in [
            ["failed": -1, "deferred": 1],
            ["failed": 2, "deferred": 1],
            ["failed": true, "deferred": 1],
            "failure"
        ] {
            #expect(ImageLoadFailureReportDisposition.classify(body) == .malformed)
        }
    }
}
