/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("OutboxMessage Persistence Extended")
struct OutboxMessagePersistenceExtendedTests {

    // MARK: - Helpers

    private func makeDraft(
        to: [String] = ["a@b.com"],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "Test",
        body: String = "Body",
        isHTML: Bool = false,
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> DraftMessage {
        DraftMessage(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            isHTML: isHTML,
            inReplyTo: inReplyTo,
            references: references
        )
    }

    // MARK: - Insert/fetch/delete round-trips

    @Test("Insert and fetch full round-trip with all fields")
    func fullInsertFetchRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = makeDraft(
            to: ["alice@example.com", "bob@example.com"],
            cc: ["charlie@example.com"],
            bcc: ["secret@example.com"],
            subject: "Project Update",
            body: "<h1>Update</h1><p>Details here</p>",
            isHTML: true,
            inReplyTo: "<original-msg@example.com>",
            references: ["<ref1@example.com>", "<ref2@example.com>"]
        )
        let msg = OutboxMessage(accountId: "acc1", draft: draft, originalMessageHeaderId: "hdr-99", isForward: false)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched != nil)
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.to == ["alice@example.com", "bob@example.com"])
        #expect(fetched?.cc == ["charlie@example.com"])
        #expect(fetched?.bcc == ["secret@example.com"])
        #expect(fetched?.subject == "Project Update")
        #expect(fetched?.body == "<h1>Update</h1><p>Details here</p>")
        #expect(fetched?.isHTML == true)
        #expect(fetched?.inReplyTo == "<original-msg@example.com>")
        #expect(fetched?.references == ["<ref1@example.com>", "<ref2@example.com>"])
        #expect(fetched?.originalMessageHeaderId == "hdr-99")
        #expect(fetched?.isForward == false)
        #expect(fetched?.outboxStatus == .queued)
        #expect(fetched?.retryCount == 0)
        #expect(fetched?.sentAt == nil)
        #expect(fetched?.sentMessageId == nil)
        #expect(fetched?.appendedToSent == false)
        #expect(fetched?.errorMessage == nil)
    }

    @Test("Delete removes the message completely")
    func deleteRemoves() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        try db.write { try msg.insert($0) }
        let msgId = msg.id

        _ = try db.write { try msg.delete($0) }
        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msgId) }
        #expect(fetched == nil)
    }

    @Test("Batch insert and fetchAll")
    func batchInsertFetchAll() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try db.write { db in
            for i in 0..<5 {
                let draft = makeDraft(subject: "Msg \(i)")
                try OutboxMessage(accountId: "acc1", draft: draft).insert(db)
            }
        }

        let all = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(all.count == 5)
    }

    // MARK: - Filter by accountId

    @Test("Filter by accountId returns only matching account messages")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")

        try db.write { db in
            try OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "A1")).insert(db)
            try OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "A2")).insert(db)
            try OutboxMessage(accountId: "acc2", draft: makeDraft(subject: "B1")).insert(db)
        }

        let acc1 = try db.read {
            try OutboxMessage.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1.count == 2)
        #expect(acc1.allSatisfy { $0.accountId == "acc1" })

        let acc2 = try db.read {
            try OutboxMessage.filter(Column("accountId") == "acc2").fetchAll($0)
        }
        #expect(acc2.count == 1)
    }

    @Test("Filter by nonexistent accountId returns empty")
    func filterByNonexistentAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { try OutboxMessage(accountId: "acc1", draft: makeDraft()).insert($0) }

        let result = try db.read {
            try OutboxMessage.filter(Column("accountId") == "nonexistent").fetchAll($0)
        }
        #expect(result.isEmpty)
    }

    // MARK: - Filter by status

    @Test("Filter by status queued returns only queued messages")
    func filterByStatusQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Queued"))
        var m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Sending"))
        m2.status = OutboxStatus.sending.rawValue
        var m3 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Failed"))
        m3.status = OutboxStatus.failed.rawValue

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
            try m3.insert(db)
        }

        let queued = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.queued.rawValue).fetchAll($0)
        }
        #expect(queued.count == 1)
        #expect(queued[0].subject == "Queued")
    }

    @Test("Filter by status sending returns only sending messages")
    func filterByStatusSending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Queued"))
        var m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Sending"))
        m2.status = OutboxStatus.sending.rawValue

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
        }

        let sending = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.sending.rawValue).fetchAll($0)
        }
        #expect(sending.count == 1)
        #expect(sending[0].subject == "Sending")
    }

    @Test("Filter by status failed returns only failed messages")
    func filterByStatusFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Failed"))
        m1.status = OutboxStatus.failed.rawValue
        m1.errorMessage = "SMTP error 550"
        let m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Queued"))

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
        }

        let failed = try db.read {
            try OutboxMessage.filter(Column("status") == OutboxStatus.failed.rawValue).fetchAll($0)
        }
        #expect(failed.count == 1)
        #expect(failed[0].errorMessage == "SMTP error 550")
    }

    // MARK: - Ordering by createdAt

    @Test("Order by createdAt ascending for FIFO drain")
    func orderByCreatedAtAsc() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let base = Date(timeIntervalSince1970: 1710000000)
        var m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "First"))
        m1.createdAt = base
        var m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Second"))
        m2.createdAt = base.addingTimeInterval(60)
        var m3 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Third"))
        m3.createdAt = base.addingTimeInterval(120)

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
            try m3.insert(db)
        }

        let ordered = try db.read {
            try OutboxMessage.order(Column("createdAt").asc).fetchAll($0)
        }
        #expect(ordered[0].subject == "First")
        #expect(ordered[1].subject == "Second")
        #expect(ordered[2].subject == "Third")
    }

    @Test("Order by createdAt descending for display")
    func orderByCreatedAtDesc() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let base = Date(timeIntervalSince1970: 1710000000)
        var m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Old"))
        m1.createdAt = base
        var m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "New"))
        m2.createdAt = base.addingTimeInterval(3600)

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
        }

        let ordered = try db.read {
            try OutboxMessage.order(Column("createdAt").desc).fetchAll($0)
        }
        #expect(ordered[0].subject == "New")
        #expect(ordered[1].subject == "Old")
    }

    // MARK: - sentAt field transitions

    @Test("sentAt transitions from nil to stamped after send")
    func sentAtTransition() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        try db.write { try msg.insert($0) }
        #expect(msg.sentAt == nil)

        let sentDate = Date()
        msg.sentAt = sentDate
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentAt != nil)
    }

    @Test("sentAt non-nil indicates send succeeded for crash recovery")
    func sentAtCrashRecovery() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        msg.sentAt = Date()
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.insert($0) }

        // Simulate reconcileOutbox check: sentAt != nil means send succeeded
        let needsReconcile = try db.read {
            try OutboxMessage
                .filter(Column("sentAt") != nil)
                .filter(Column("status") == OutboxStatus.sending.rawValue)
                .fetchAll($0)
        }
        #expect(needsReconcile.count == 1)
    }

    // MARK: - sentMessageId field

    @Test("sentMessageId persists RFC822 Message-ID for dedup")
    func sentMessageIdPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        try db.write { try msg.insert($0) }

        msg.sentMessageId = "<unique-id-12345@tabmail.ai>"
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentMessageId == "<unique-id-12345@tabmail.ai>")
    }

    @Test("sentMessageId initially nil and can be set before send")
    func sentMessageIdSetBeforeSend() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        #expect(msg.sentMessageId == nil)

        msg.sentMessageId = "<pre-generated@tabmail.ai>"
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.sentMessageId == "<pre-generated@tabmail.ai>")
    }

    // MARK: - appendedToSent flag

    @Test("appendedToSent defaults false and transitions to true")
    func appendedToSentTransition() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        try db.write { try msg.insert($0) }

        let initialFetch = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(initialFetch?.appendedToSent == false)

        msg.appendedToSent = true
        try db.write { try msg.update($0) }

        let updatedFetch = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(updatedFetch?.appendedToSent == true)
    }

    @Test("Filter for pending Sent appends: sentAt != nil AND NOT appendedToSent")
    func filterPendingSentAppends() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        // Message fully done (sentAt + appended)
        var m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Done"))
        m1.sentAt = Date()
        m1.appendedToSent = true

        // Message needs append (sentAt but not appended)
        var m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "NeedsAppend"))
        m2.sentAt = Date()
        m2.appendedToSent = false

        // Message not yet sent
        let m3 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "NotSent"))

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
            try m3.insert(db)
        }

        let pendingAppend = try db.read {
            try OutboxMessage
                .filter(Column("sentAt") != nil)
                .filter(Column("appendedToSent") == false)
                .fetchAll($0)
        }
        #expect(pendingAppend.count == 1)
        #expect(pendingAppend[0].subject == "NeedsAppend")
    }

    // MARK: - Batch status update pattern

    @Test("Batch update all queued to sending for drain lock")
    func batchStatusUpdate() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try db.write { db in
            for i in 0..<3 {
                try OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Q\(i)")).insert(db)
            }
            var failed = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "F1"))
            failed.status = OutboxStatus.failed.rawValue
            try failed.insert(db)
        }

        // Drain should only pick queued, ordered by createdAt
        let toDrain = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }
        #expect(toDrain.count == 3)
    }

    @Test("Reset failed to queued on user retry")
    func resetFailedToQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "FailedMsg"))
        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 3
        msg.errorMessage = "Timeout"
        try db.write { try msg.insert($0) }

        // User taps retry
        msg.status = OutboxStatus.queued.rawValue
        msg.retryCount = 0
        msg.errorMessage = nil
        try db.write { try msg.update($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.outboxStatus == .queued)
        #expect(fetched?.retryCount == 0)
        #expect(fetched?.errorMessage == nil)
    }

    // MARK: - Cascade delete on account removal

    @Test("Outbox messages cascade delete when account is deleted")
    func cascadeDeleteOnAccountRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        try db.write { db in
            try OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Msg1")).insert(db)
            try OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Msg2")).insert(db)
        }

        let beforeCount = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(beforeCount == 2)

        // Delete the account — FK cascade should remove outbox messages
        _ = try db.write { try Account.deleteAll($0, keys: ["acc1"]) }

        let afterCount = try db.read { try OutboxMessage.fetchCount($0) }
        #expect(afterCount == 0)
    }

    // MARK: - Full lifecycle (double-send firewall pattern)

    @Test("Full lifecycle: queued -> sending -> sentAt -> sentMessageId -> appendedToSent -> delete")
    func fullLifecycleDoubleSendFirewall() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Lifecycle"))
        try db.write { try msg.insert($0) }
        #expect(msg.outboxStatus == .queued)

        // Pre-generate Message-ID before send
        msg.sentMessageId = "<lifecycle-id@tabmail.ai>"
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.update($0) }

        // SMTP send succeeds — stamp sentAt FIRST (double-send firewall)
        msg.sentAt = Date()
        try db.write { try msg.update($0) }

        // Verify sentAt is stamped before append
        let afterSend = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(afterSend?.sentAt != nil)
        #expect(afterSend?.appendedToSent == false)

        // IMAP APPEND to Sent folder succeeds
        msg.appendedToSent = true
        try db.write { try msg.update($0) }

        // Now safe to delete
        let beforeDelete = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(beforeDelete?.sentAt != nil)
        #expect(beforeDelete?.sentMessageId == "<lifecycle-id@tabmail.ai>")
        #expect(beforeDelete?.appendedToSent == true)

        _ = try db.write { try msg.delete($0) }
        let afterDelete = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(afterDelete == nil)
    }

    // MARK: - Edge cases

    @Test("Multiple recipients in all address fields persist")
    func multipleRecipientsAllFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = makeDraft(
            to: ["a@a.com", "b@b.com", "c@c.com"],
            cc: ["d@d.com", "e@e.com"],
            bcc: ["f@f.com", "g@g.com", "h@h.com"]
        )
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.to.count == 3)
        #expect(fetched?.cc.count == 2)
        #expect(fetched?.bcc.count == 3)
    }

    @Test("Unicode subject and body persist correctly")
    func unicodeContent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let draft = makeDraft(
            subject: "Terminbestaetigung",
            body: "Bitte bestaetigen Sie den Termin."
        )
        let msg = OutboxMessage(accountId: "acc1", draft: draft)
        try db.write { try msg.insert($0) }

        let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(fetched?.subject == "Terminbestaetigung")
        #expect(fetched?.body.contains("bestaetigen") == true)
    }

    @Test("retryCount increments persist")
    func retryCountIncrements() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = OutboxMessage(accountId: "acc1", draft: makeDraft())
        try db.write { try msg.insert($0) }

        for i in 1...3 {
            msg.retryCount = i
            try db.write { try msg.update($0) }
            let fetched = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
            #expect(fetched?.retryCount == i)
        }
    }

    @Test("databaseTableName is outboxMessage")
    func verifyTableName() {
        #expect(OutboxMessage.databaseTableName == "outboxMessage")
    }

    @Test("Combined filter: queued + specific account + ordered by createdAt")
    func combinedFilterForDrain() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")

        let base = Date(timeIntervalSince1970: 1710000000)
        var m1 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Late"))
        m1.createdAt = base.addingTimeInterval(120)
        var m2 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Early"))
        m2.createdAt = base
        var m3 = OutboxMessage(accountId: "acc2", draft: makeDraft(subject: "Other"))
        m3.createdAt = base.addingTimeInterval(60)
        var m4 = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Failed"))
        m4.status = OutboxStatus.failed.rawValue
        m4.createdAt = base.addingTimeInterval(10)

        try db.write { db in
            try m1.insert(db)
            try m2.insert(db)
            try m3.insert(db)
            try m4.insert(db)
        }

        let toDrain = try db.read {
            try OutboxMessage
                .filter(Column("accountId") == "acc1")
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }
        #expect(toDrain.count == 2)
        #expect(toDrain[0].subject == "Early")
        #expect(toDrain[1].subject == "Late")
    }
}
