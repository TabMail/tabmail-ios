/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("OutboxMessage Extended")
struct OutboxMessageExtendedTests {

    @Test("OutboxStatus rawValues")
    func statusRawValues() {
        #expect(OutboxStatus.queued.rawValue == "queued")
        #expect(OutboxStatus.sending.rawValue == "sending")
        #expect(OutboxStatus.failed.rawValue == "failed")
    }

    @Test("OutboxMessage generates unique IDs")
    func uniqueIds() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg1 = OutboxMessage(accountId: "acc1", draft: draft)
        let msg2 = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg1.id != msg2.id)
    }

    @Test("OutboxMessage initial status is queued")
    func initialStatusQueued() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.outboxStatus == .queued)
    }

    @Test("OutboxMessage sentAt initially nil")
    func sentAtInitiallyNil() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.sentAt == nil)
    }

    @Test("OutboxMessage sentMessageId initially nil")
    func sentMessageIdInitiallyNil() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.sentMessageId == nil)
    }

    @Test("OutboxMessage appendedToSent defaults to false")
    func appendedToSentDefault() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.appendedToSent == false)
    }

    @Test("OutboxMessage retryCount defaults to 0")
    func retryCountDefault() {
        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        #expect(msg.retryCount == 0)
    }

    @Test("Failed status after 3 retries")
    func failedAfterRetries() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Fail", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        // Simulate 3 failed retries
        msg.retryCount = 3
        msg.status = OutboxStatus.failed.rawValue
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .failed)
        #expect(fetched?.retryCount == 3)
    }

    @Test("Manual retry resets retryCount to 0")
    func manualRetryResetsCount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Retry", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        msg.retryCount = 3
        msg.status = OutboxStatus.failed.rawValue
        try db.write { try msg.insert($0) }

        // User taps retry
        msg.retryCount = 0
        msg.status = OutboxStatus.queued.rawValue
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .queued)
        #expect(fetched?.retryCount == 0)
    }
}
