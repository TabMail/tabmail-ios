/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("OutboxMessage")
struct OutboxMessageTests {

    @Test("OutboxStatus raw values")
    func statusRawValues() {
        #expect(OutboxStatus.queued.rawValue == "queued")
        #expect(OutboxStatus.sending.rawValue == "sending")
        #expect(OutboxStatus.failed.rawValue == "failed")
    }

    @Test("sentAt is nil on creation")
    func sentAtNilOnCreation() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.sentAt == nil)
    }

    @Test("sentMessageId is nil on creation")
    func sentMessageIdNilOnCreation() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.sentMessageId == nil)
    }

    @Test("appendedToSent defaults to false")
    func appendedToSentDefault() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.appendedToSent == false)
    }

    @Test("Init sets correct defaults")
    func initDefaults() {
        let draft = DraftMessage(to: ["a@b.com"], cc: ["c@d.com"], subject: "Hi", body: "Hello", isHTML: true)
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(!msg.id.isEmpty)
        #expect(msg.accountId == "acc1")
        #expect(msg.to == ["a@b.com"])
        #expect(msg.cc == ["c@d.com"])
        #expect(msg.subject == "Hi")
        #expect(msg.body == "Hello")
        #expect(msg.isHTML == true)
        #expect(msg.outboxStatus == .queued)
        #expect(msg.retryCount == 0)
        #expect(msg.errorMessage == nil)
        #expect(msg.isForward == false)
    }

    @Test("to/cc/bcc computed properties encode/decode JSON")
    func addressJsonRoundTrip() {
        let draft = DraftMessage(
            to: ["a@b.com", "c@d.com"],
            cc: ["e@f.com"],
            bcc: ["g@h.com"]
        )
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.to == ["a@b.com", "c@d.com"])
        #expect(msg.cc == ["e@f.com"])
        #expect(msg.bcc == ["g@h.com"])
    }

    @Test("outboxStatus computed property FAILS CLOSED to .failed on unknown raw values")
    func outboxStatusFallback() {
        // F2b §1.3 fail-closed decode: never the drainable .queued.
        let draft = DraftMessage()
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.status = "invalid_status"
        #expect(msg.outboxStatus == .failed)
    }

    @Test("isForward preserved")
    func isForward() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Fwd: Hi")
        let msg = OutboxMessage(accountId: "acc1", draft: draft, isForward: true)
        #expect(msg.isForward == true)
    }

    @Test("originalMessageHeaderId preserved")
    func originalMessageHeaderId() {
        let draft = DraftMessage(to: ["a@b.com"])
        let msg = OutboxMessage(accountId: "acc1", draft: draft, originalMessageHeaderId: "header-123")
        #expect(msg.originalMessageHeaderId == "header-123")
    }

    @Test("Each init generates unique id")
    func uniqueIds() {
        let draft = DraftMessage()
        let msg1 = OutboxMessage(accountId: "acc1", draft: draft)
        let msg2 = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg1.id != msg2.id)
    }
}
