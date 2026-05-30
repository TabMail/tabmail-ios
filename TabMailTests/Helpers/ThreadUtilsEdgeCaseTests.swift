/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ThreadUtils Edge Cases")
struct ThreadUtilsEdgeCaseTests {

    @Test("normalizeSubject with only whitespace")
    func onlyWhitespace() {
        let result = ThreadUtils.normalizeSubject("   ")
        #expect(result.isEmpty)
    }

    @Test("normalizeSubject with nested Re:Fwd: mixed case")
    func nestedMixedCase() {
        let result = ThreadUtils.normalizeSubject("RE: Fwd: re: FW: Hello")
        #expect(result == "Hello")
    }

    @Test("normalizeSubject with Re: but no body")
    func rePrefixNoBody() {
        let result = ThreadUtils.normalizeSubject("Re:")
        #expect(result.isEmpty)
    }

    @Test("normalizeSubject with special characters in subject")
    func specialCharacters() {
        let result = ThreadUtils.normalizeSubject("Re: [URGENT] 🚨 Fix: bug #123")
        #expect(result == "[URGENT] 🚨 Fix: bug #123")
    }

    @Test("normalizeSubject preserves parentheses")
    func preservesParentheses() {
        let result = ThreadUtils.normalizeSubject("Re: Meeting (rescheduled)")
        #expect(result == "Meeting (rescheduled)")
    }

    @Test("normalizeSubject strips AW: (German)")
    func germanReply() {
        let result = ThreadUtils.normalizeSubject("AW: AW: Besprechung")
        #expect(result == "Besprechung")
    }

    @Test("normalizeSubject strips SV: (Scandinavian)")
    func scandinavianReply() {
        let result = ThreadUtils.normalizeSubject("SV: SV: Møde")
        #expect(result == "Møde")
    }

    @Test("normalizeSubject strips VS: (Finnish forward)")
    func finnishForward() {
        let result = ThreadUtils.normalizeSubject("VS: Kokous")
        #expect(result == "Kokous")
    }

    @Test("computeSubjectThreadId nil for empty normalized subject")
    func nilForEmpty() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re:")
        #expect(id == nil)
    }

    @Test("computeSubjectThreadId nil for (no subject)")
    func nilForNoSubject() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "(no subject)")
        #expect(id == nil)
    }

    @Test("computeSubjectThreadId produces deterministic output")
    func deterministic() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Budget Review")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Budget Review")
        #expect(id1 == id2)
    }

    @Test("computeSubjectThreadId groups Re: and Fwd: of same subject")
    func groupsReAndFwd() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Budget")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Fwd: Budget")
        let id3 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Budget")
        #expect(id1 == id2)
        #expect(id2 == id3)
    }

    @Test("computeSubjectThreadId different subjects produce different ids")
    func differentSubjects() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Budget")
        #expect(id1 != id2)
    }

    @Test("computeSubjectThreadId format is subj:accountId:lowercased")
    func formatVerification() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Hello World")
        #expect(id == "subj:acc1:hello world")
    }

    @Test("computeSubjectThreadId with very long subject")
    func veryLongSubject() {
        let longSubject = String(repeating: "a", count: 1000)
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: longSubject)
        #expect(id != nil)
    }

    @Test("computeSubjectThreadId with unicode subject")
    func unicodeSubject() {
        let id = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: 会議の件")
        #expect(id != nil)
        #expect(id?.contains("会議の件") == true)
    }
}
