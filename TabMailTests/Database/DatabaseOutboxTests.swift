/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Outbox")
struct DatabaseOutboxTests {

    @Test("OutboxMessage persists with all fields")
    func outboxPersistsAllFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["recipient@example.com"], subject: "Test", body: "<p>Hello</p>")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched != nil)
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.outboxStatus == .queued)
    }

    @Test("OutboxMessage status transitions: queued → sending → delete")
    func statusTransitions() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        // queued → sending
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }
        let sending = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sending?.outboxStatus == .sending)

        // stamp sentAt
        msg.sentAt = Date()
        try db.write { try msg.update($0) }
        let sent = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sent?.sentAt != nil)

        // delete
        _ = try db.write { try msg.delete($0) }
        let deleted = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(deleted == nil)
    }

    @Test("OutboxMessage cascades on account delete")
    func cascadesOnAccountDelete() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Hi", body: "Hello")
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        // Delete account
        try db.write { _ = try Account.deleteAll($0, keys: ["acc1"]) }

        let remaining = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    @Test("Multiple outbox messages for same account")
    func multipleMessages() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        for i in 0..<3 {
            let draft = DraftMessage(to: ["a@b.com"], subject: "Msg \(i)", body: "Body \(i)")
            let msg = OutboxMessage(accountId: "acc1", draft: draft)
            try db.write { try msg.insert($0) }
        }

        let all = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(all.count == 3)
    }

    @Test("OutboxMessage failed status persists for user retry")
    func failedStatusPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = DraftMessage(to: ["a@b.com"], subject: "Fail", body: "Body")
        var msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 3
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .failed)
        #expect(fetched?.retryCount == 3)
    }
}
