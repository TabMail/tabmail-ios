/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Draft key parsing")
struct DraftKeyParsingTests {

    @Test("draftKey for reply encodes accountId and stableId")
    func replyDraftKey() {
        let key = Draft.draftKey(replyTo: "acct1:msg@example.com", isForward: false, newId: nil)
        #expect(key == "reply:acct1:msg@example.com")
    }

    @Test("draftKey for forward encodes accountId and stableId")
    func forwardDraftKey() {
        let key = Draft.draftKey(replyTo: "acct1:msg@example.com", isForward: true, newId: nil)
        #expect(key == "forward:acct1:msg@example.com")
    }

    @Test("draftKey for new compose uses provided UUID")
    func newDraftKey() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: "test-uuid")
        #expect(key == "new:test-uuid")
    }

    @Test("draftKey for new compose generates UUID when nil")
    func newDraftKeyGenerated() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        #expect(key.hasPrefix("new:"))
        #expect(key.count > "new:".count) // UUID appended
    }

    @Test("draftKey roundtrip: stableId can be extracted from reply key")
    func roundtripReply() {
        let stableKey = "myAccount:some-rfc822@host.com"
        let key = Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        // Parse it back
        #expect(key.hasPrefix("reply:"))
        let rest = String(key.dropFirst("reply:".count))
        let colonIdx = rest.firstIndex(of: ":")!
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        #expect(accountId == "myAccount")
        #expect(stableId == "some-rfc822@host.com")
    }

    @Test("draftKey roundtrip: stableId with colons preserved")
    func roundtripWithColons() {
        // rfc822 message IDs can contain colons
        let stableKey = "acct:complex:id:with:colons@host.com"
        let key = Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        let rest = String(key.dropFirst("reply:".count))
        let colonIdx = rest.firstIndex(of: ":")!
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        #expect(accountId == "acct")
        #expect(stableId == "complex:id:with:colons@host.com")
    }

    @Test("ActiveAgentTracker.messageStableId parsing matches draftKey format")
    @MainActor func trackerParsingConsistency() {
        // The session key for message-detail is "msg:{accountId}:{stableId}"
        // This should parse correctly via ActiveAgentTracker.messageStableId
        let result = ActiveAgentTracker.messageStableId(from: "msg:acct1:rfc822@example.com")
        #expect(result?.accountId == "acct1")
        #expect(result?.stableId == "rfc822@example.com")
    }
}
