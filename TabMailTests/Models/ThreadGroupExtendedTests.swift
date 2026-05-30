/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("ThreadGroup Extended")
struct ThreadGroupExtendedTests {

    @Test("normalizeSubject strips Re: at start")
    func stripsReAtStart() {
        let result = ThreadUtils.normalizeSubject("Re: Hello")
        #expect(result == "Hello")
    }

    @Test("normalizeSubject strips multiple Re: prefixes")
    func stripsMultipleRe() {
        let result = ThreadUtils.normalizeSubject("Re: Re: Re: Hello")
        #expect(result == "Hello")
    }

    @Test("normalizeSubject strips Fwd:")
    func stripsFwd() {
        let result = ThreadUtils.normalizeSubject("Fwd: Hello")
        #expect(result == "Hello")
    }

    @Test("normalizeSubject strips Fw:")
    func stripsFw() {
        let result = ThreadUtils.normalizeSubject("Fw: Hello")
        #expect(result == "Hello")
    }

    @Test("normalizeSubject strips AW: (German reply)")
    func stripsAW() {
        let result = ThreadUtils.normalizeSubject("AW: Hallo")
        #expect(result == "Hallo")
    }

    @Test("normalizeSubject strips SV: (Scandinavian reply)")
    func stripsSV() {
        let result = ThreadUtils.normalizeSubject("SV: Hej")
        #expect(result == "Hej")
    }

    @Test("normalizeSubject strips VS: (Finnish forward)")
    func stripsVS() {
        let result = ThreadUtils.normalizeSubject("VS: Terve")
        #expect(result == "Terve")
    }

    @Test("normalizeSubject case insensitive")
    func caseInsensitive() {
        let result = ThreadUtils.normalizeSubject("re: RE: hello")
        #expect(result == "hello")
    }

    @Test("normalizeSubject trims whitespace")
    func trimsWhitespace() {
        let result = ThreadUtils.normalizeSubject("  Re: Hello World  ")
        #expect(result == "Hello World")
    }

    @Test("normalizeSubject preserves subject without prefix")
    func preservesNoPrefix() {
        let result = ThreadUtils.normalizeSubject("Meeting at 3pm")
        #expect(result == "Meeting at 3pm")
    }

    @Test("normalizeSubject empty string returns empty")
    func emptyString() {
        let result = ThreadUtils.normalizeSubject("")
        #expect(result.isEmpty)
    }

    @Test("normalizeSubject only prefix returns empty")
    func onlyPrefix() {
        let result = ThreadUtils.normalizeSubject("Re:")
        #expect(result.isEmpty)
    }

    @Test("computeSubjectThreadId groups messages with same normalized subject")
    func groupsBySameSubject() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Re: Meeting")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Fwd: Meeting")
        let id3 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting")
        #expect(id1 == id2)
        #expect(id2 == id3)
    }

    @Test("computeSubjectThreadId different accounts produce different ids")
    func differentAccountsDifferentIds() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "Meeting")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc2", subject: "Meeting")
        #expect(id1 != id2)
    }

    @Test("computeSubjectThreadId case insensitive")
    func threadIdCaseInsensitive() {
        let id1 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "MEETING")
        let id2 = ThreadUtils.computeSubjectThreadId(accountId: "acc1", subject: "meeting")
        #expect(id1 == id2)
    }
}
