/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// `SentCopyLink`: a send's Message-ID leads to the Message-ID its Sent copy carries. The link is
/// process-wide, so each test uses accounts of its own.
@Suite("Sent copy link")
struct SentCopyLinkTests {
    private static func newAccount() -> String { "acc-\(UUID().uuidString)" }

    @Test("A copy under a Message-ID of its own is found by the send's Message-ID, with or without brackets")
    func linksACopyUnderAnotherMessageId() {
        let account = Self.newAccount()
        SentCopyLink.record(
            accountId: account, sentMessageId: "<sent@example.com>", copyMessageId: "<copy@mail.example.com>")
        let bracketed = SentCopyLink.copyMessageId(accountId: account, sentMessageId: "<sent@example.com>")
        let bare = SentCopyLink.copyMessageId(accountId: account, sentMessageId: " sent@example.com ")
        #expect(bracketed == "copy@mail.example.com")
        #expect(bare == "copy@mail.example.com")
    }

    @Test("A copy under the send's own Message-ID, or no copy, leaves the send's Message-ID, normalized")
    func sameOrNoCopyIsTheSendsOwn() {
        let account = Self.newAccount()
        SentCopyLink.record(accountId: account, sentMessageId: "same@example.com", copyMessageId: "<same@example.com>")
        let same = SentCopyLink.copyMessageId(accountId: account, sentMessageId: "<same@example.com>")
        let unrecorded = SentCopyLink.copyMessageId(accountId: account, sentMessageId: "<other@example.com>")
        #expect(same == "same@example.com")
        #expect(unrecorded == "other@example.com")
    }

    @Test("A link belongs to its account")
    func linkBelongsToItsAccount() {
        let account = Self.newAccount()
        let other = Self.newAccount()
        SentCopyLink.record(accountId: account, sentMessageId: "sent@example.com", copyMessageId: "copy@mail.example.com")
        let elsewhere = SentCopyLink.copyMessageId(accountId: other, sentMessageId: "sent@example.com")
        #expect(elsewhere == "sent@example.com")
    }
}
