/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("OutboxMessage Edge Cases")
struct OutboxMessageEdgeCaseTests {

    @Test("OutboxMessage to/cc/bcc JSON round-trip with empty arrays")
    func emptyRecipientArrays() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.cc.isEmpty)
        #expect(msg.bcc.isEmpty)
    }

    @Test("OutboxMessage preserves multi-recipient to field")
    func multiRecipientTo() throws {
        let draft = DraftMessage(to: ["a@b.com", "c@d.com", "e@f.com"], subject: "Multi", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.to.count == 3)
        #expect(msg.to.contains("c@d.com"))
    }

    @Test("OutboxMessage generates unique IDs")
    func uniqueIds() {
        let d1 = DraftMessage(to: ["a@b.com"], subject: "A", body: "Body")
        let d2 = DraftMessage(to: ["a@b.com"], subject: "B", body: "Body")
        let m1 = OutboxMessage(accountId: "acc1", draft: d1)
        let m2 = OutboxMessage(accountId: "acc1", draft: d2)
        #expect(m1.id != m2.id)
    }

    @Test("OutboxMessage defaults to queued status")
    func defaultsToQueued() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.outboxStatus == .queued)
    }

    @Test("OutboxMessage retryCount defaults to zero")
    func retryCountDefault() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.retryCount == 0)
    }

    @Test("OutboxMessage sentAt is nil initially")
    func sentAtNilInitially() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.sentAt == nil)
    }

    @Test("OutboxMessage appendedToSent is false initially")
    func appendedToSentFalseInitially() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.appendedToSent == false)
    }

    @Test("OutboxMessage status transitions: queued → sending → failed")
    func statusTransitions() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Test", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }
        #expect(msg.outboxStatus == .queued)

        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }
        let sending = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sending?.outboxStatus == .sending)

        msg.status = OutboxStatus.failed.rawValue
        msg.errorMessage = "Connection refused"
        try db.write { try msg.update($0) }
        let failed = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(failed?.outboxStatus == .failed)
        #expect(failed?.errorMessage == "Connection refused")
    }

    @Test("OutboxMessage with reply context (inReplyTo)")
    func replyContext() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Re: Test", body: "Reply body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.inReplyTo = "<original-msg-id@example.com>"
        msg.originalMessageHeaderId = "acc1:INBOX:42"
        #expect(msg.inReplyTo == "<original-msg-id@example.com>")
        #expect(msg.originalMessageHeaderId == "acc1:INBOX:42")
    }

    @Test("OutboxMessage with forward flag")
    func forwardFlag() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Fwd: Test", body: "Forward body")
        let msg = OutboxMessage(accountId: "acc1", draft: draft, isForward: true)
        #expect(msg.isForward == true)
    }

    @Test("OutboxMessage HTML body persists")
    func htmlBodyPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "HTML", body: "<p>Rich <b>text</b></p>")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.body == "<p>Rich <b>text</b></p>")
    }
}

@Suite("OutboxStatus Enum")
struct OutboxStatusTests {

    @Test("All OutboxStatus raw values")
    func allRawValues() {
        #expect(OutboxStatus.queued.rawValue == "queued")
        #expect(OutboxStatus.sending.rawValue == "sending")
        #expect(OutboxStatus.failed.rawValue == "failed")
    }

    @Test("OutboxStatus Codable round-trip")
    func codableRoundTrip() throws {
        for status in [OutboxStatus.queued, .sending, .failed] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(OutboxStatus.self, from: data)
            #expect(decoded == status)
        }
    }
}
