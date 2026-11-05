/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// Display name kept distinct from `AIReplyParseTests` (R18d-G3): the run log prints DISPLAY
// names, so two suites sharing one could not be reconciled per suite (`MIS-013`).
@Suite("ReplyResult — reply value and its filtered sentinel")
struct AIReplyTests {

    @Test("filtered is an empty body with no text message")
    func filteredSentinel() {
        #expect(ReplyResult.filtered.body == "")
        #expect(ReplyResult.filtered.textMessage == nil)
    }

    @Test("A peer reply carries no text message")
    func peerReplyHasNoTextMessage() {
        let peer = ReplyResult(body: "From Thunderbird", textMessage: nil)
        #expect(peer != ReplyResult.filtered)
        #expect(peer.textMessage == nil)
    }

    @Test("Equality covers both fields")
    func equality() {
        #expect(ReplyResult(body: "B", textMessage: "T") == ReplyResult(body: "B", textMessage: "T"))
        #expect(ReplyResult(body: "B", textMessage: "T") != ReplyResult(body: "B", textMessage: nil))
        #expect(ReplyResult(body: "B", textMessage: "T") != ReplyResult(body: "C", textMessage: "T"))
    }
}
