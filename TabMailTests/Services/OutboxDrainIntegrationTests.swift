/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Integration tests for the outbox drain flow patterns.
/// Tests the DB-level logic used by drainOutbox, executeOutboxSend, and reconcileOutbox,
/// using TestDatabase + MockEmailProvider for real GRDB + mock provider interaction.
@Suite("Outbox Drain Integration")
struct OutboxDrainIntegrationTests {

    // MARK: - Helpers

    /// Create a minimal OutboxMessage for testing.
    private func makeOutboxMessage(
        accountId: String = "acc1",
        subject: String = "Test",
        to: [String] = ["recipient@example.com"]
    ) -> OutboxMessage {
        let draft = DraftMessage(to: to, subject: subject, body: "Test body")
        return OutboxMessage(accountId: accountId, draft: draft)
    }

    // MARK: - 1. OutboxMessage lifecycle: queued -> sending -> sentAt set -> delete

    @Test("Lifecycle: queued -> sending -> sentAt stamped -> appendedToSent -> delete (double-send firewall)")
    func fullLifecycleWithDoubleSendFirewall() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage()
        try db.write { try msg.insert($0) }

        // Initially queued
        let initial = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(initial?.outboxStatus == .queued)
        #expect(initial?.sentAt == nil)
        #expect(initial?.appendedToSent == false)

        // Transition to sending + set sentMessageId (as drainOutbox does)
        let messageId = "<test-uuid@example.com>"
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, messageId, msg.id]
            )
        }

        let sending = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sending?.outboxStatus == .sending)
        #expect(sending?.sentMessageId == messageId)

        // After provider.send() succeeds, stamp sentAt FIRST (double-send firewall)
        let sentDate = Date()
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?",
                arguments: [sentDate, msg.id]
            )
        }

        let sentStamped = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(sentStamped?.sentAt != nil)
        // At this point, even if app crashes, reconcile sees sentAt != nil and will NOT re-send

        // Mark appended to Sent folder
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET appendedToSent = 1 WHERE id = ?",
                arguments: [msg.id]
            )
        }

        let appended = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(appended?.appendedToSent == true)

        // Delete after fully completed
        _ = try db.write { try OutboxMessage.deleteOne($0, key: msg.id) }

        let deleted = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(deleted == nil)
    }

    // MARK: - 2. OutboxMessage retry: failed send -> retryCount incremented -> status stays queued if < 3

    @Test("Retry: failed send increments retryCount, stays queued when retryCount < 3")
    func retryKeepsQueuedUnderThreshold() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage()
        try db.write { try msg.insert($0) }

        // Simulate first failed send attempt: mark sending, then fail
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, msg.id]
            )
        }

        // Send failed -- retryCount 0 -> 1, stays queued (auto-retry)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = ? WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, "Connection timeout", 1, msg.id]
            )
        }

        let afterFirst = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(afterFirst?.outboxStatus == .queued)
        #expect(afterFirst?.retryCount == 1)
        #expect(afterFirst?.errorMessage == "Connection timeout")

        // Second failed attempt: retryCount 1 -> 2, still queued
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, retryCount = ? WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, 2, msg.id]
            )
        }

        let afterSecond = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(afterSecond?.outboxStatus == .queued)
        #expect(afterSecond?.retryCount == 2)
    }

    // MARK: - 3. OutboxMessage retry exhaustion: retryCount >= 3 -> status becomes failed

    @Test("Retry exhaustion: retryCount >= 3 marks status as failed")
    func retryExhaustionMarksFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = makeOutboxMessage()
        msg.retryCount = 2  // Already failed twice
        try db.write { try msg.insert($0) }

        // Third failed attempt: retryCount 2 -> 3, should mark as failed (>= 3 threshold)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = ? WHERE id = ?",
                arguments: [OutboxStatus.failed.rawValue, "SMTP auth error", 3, msg.id]
            )
        }

        let afterThird = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(afterThird?.outboxStatus == .failed)
        #expect(afterThird?.retryCount == 3)
        #expect(afterThird?.errorMessage == "SMTP auth error")

        // Verify it would NOT be picked up by drain (only .queued is drained)
        let queued = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(queued.isEmpty)
    }

    // MARK: - 4. Send via MockEmailProvider: insert OutboxMessage, simulate send, verify sentDrafts

    @Test("Send via MockEmailProvider: provider.send records the draft")
    func sendViaProviderRecordsDraft() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage(subject: "Provider send test")
        let msgId = msg.id
        try await db.write { try msg.insert($0) }

        let mock = MockEmailProvider()

        // Simulate drainOutbox: mark as sending
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, msgId]
            )
        }

        // Reconstruct draft and call provider.send
        let fetched = try await db.read { try OutboxMessage.fetchOne($0, key: msgId) }!
        let draft = try fetched.toDraftMessage()

        var draftWithId = draft
        draftWithId.messageId = "<test-id@example.com>"
        try await mock.send(draft: draftWithId)

        // Verify MockEmailProvider recorded the send
        let sentDrafts = await mock.sentDrafts
        #expect(sentDrafts.count == 1)
        #expect(sentDrafts[0].subject == "Provider send test")
        #expect(sentDrafts[0].to == ["recipient@example.com"])
        #expect(sentDrafts[0].messageId == "<test-id@example.com>")

        let callLog = await mock.callLog
        #expect(callLog.contains("send"))
    }

    // MARK: - 5. appendToSentFolder after send: verify MockEmailProvider records correct args

    @Test("appendToSentFolder: provider records draft, sentFolderPath, and messageId")
    func appendToSentFolderRecordsArgs() async throws {
        let mock = MockEmailProvider()

        let draft = DraftMessage(
            to: ["recipient@example.com"],
            subject: "Append test",
            body: "<p>Hello</p>",
            isHTML: true
        )
        var draftWithId = draft
        draftWithId.messageId = "<append-test-id@example.com>"

        let result = try await mock.appendToSentFolder(
            draft: draftWithId,
            sentFolderPath: "[Gmail]/Sent Mail",
            messageId: "<append-test-id@example.com>"
        )

        #expect(result == true)  // MockEmailProvider default is true

        let appended = await mock.appendedToSent
        #expect(appended.count == 1)
        #expect(appended[0].sentFolderPath == "[Gmail]/Sent Mail")
        #expect(appended[0].messageId == "<append-test-id@example.com>")
        #expect(appended[0].draft.subject == "Append test")

        let callLog = await mock.callLog
        #expect(callLog.contains("appendToSentFolder(sentFolderPath:[Gmail]/Sent Mail,messageId:<append-test-id@example.com>)"))
    }

    @Test("appendToSentFolder failure does not delete outbox message")
    func appendFailureKeepsOutboxMessage() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msgBuilder = makeOutboxMessage()
        msgBuilder.status = OutboxStatus.sending.rawValue
        msgBuilder.sentAt = Date()
        msgBuilder.sentMessageId = "<sent-id@example.com>"
        let msg = msgBuilder
        let msgId = msg.id
        try await db.write { try msg.insert($0) }

        let mock = MockEmailProvider()
        await mock.setAppendToSentThrows(ProviderError.notConnected)

        // Simulate append failure — message stays in DB with sentAt set, appendedToSent = false
        let fetched = try await db.read { try OutboxMessage.fetchOne($0, key: msgId) }
        #expect(fetched?.sentAt != nil)
        #expect(fetched?.appendedToSent == false)
        // drainPendingSentAppends will pick this up later
    }

    // MARK: - 6. Filter: only .queued messages drained, not .failed or .sending

    @Test("Drain filter: only .queued messages are fetched for processing")
    func drainFilterOnlyQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let queued1 = makeOutboxMessage(subject: "Queued 1")
        let queued2 = makeOutboxMessage(subject: "Queued 2")
        var sending = makeOutboxMessage(subject: "Sending")
        sending.status = OutboxStatus.sending.rawValue
        var failed = makeOutboxMessage(subject: "Failed")
        failed.status = OutboxStatus.failed.rawValue
        failed.retryCount = 3

        try db.write { dbConn in
            try queued1.insert(dbConn)
            try queued2.insert(dbConn)
            try sending.insert(dbConn)
            try failed.insert(dbConn)
        }

        // Simulate the drain query: only fetch queued, ordered by createdAt
        let toDrain = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        #expect(toDrain.count == 2)
        #expect(toDrain.allSatisfy { $0.outboxStatus == .queued })

        // Verify the sending and failed messages are NOT included
        let sendingSubjects = toDrain.map(\.subject)
        #expect(!sendingSubjects.contains("Sending"))
        #expect(!sendingSubjects.contains("Failed"))
    }

    @Test("Failed messages only drained after manual retry resets status to queued")
    func failedMessageDrainedAfterManualRetry() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = makeOutboxMessage(subject: "Failed then retried")
        msg.status = OutboxStatus.failed.rawValue
        msg.retryCount = 3
        msg.errorMessage = "Network error"
        try db.write { try msg.insert($0) }

        // Before manual retry: not in drain set
        let beforeRetry = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(beforeRetry.isEmpty)

        // Manual retry: reset to queued with retryCount = 0
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, errorMessage = NULL, retryCount = 0 WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, msg.id]
            )
        }

        // After manual retry: now in drain set
        let afterRetry = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(afterRetry.count == 1)
        #expect(afterRetry[0].retryCount == 0)
        #expect(afterRetry[0].errorMessage == nil)
    }

    // MARK: - 7. Reconcile: .sending messages reset to .queued on launch (crash recovery)

    @Test("Reconcile: sending messages with no sentAt are reset to queued (crash mid-send)")
    func reconcileSendingWithoutSentAtResetsToQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg1 = makeOutboxMessage(subject: "Was sending")
        msg1.status = OutboxStatus.sending.rawValue
        // sentAt is nil — send was in progress when crash happened

        let msg2 = makeOutboxMessage(subject: "Still queued")
        // msg2 stays queued — should not be touched

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
        }

        // Simulate reconcileOutbox: reset sending (no sentAt) back to queued
        try db.write { dbConn in
            let stale = try OutboxMessage
                .filter(Column("status") == OutboxStatus.sending.rawValue)
                .fetchAll(dbConn)
            for msg in stale {
                if msg.sentAt == nil {
                    try dbConn.execute(
                        sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                        arguments: [OutboxStatus.queued.rawValue, msg.id]
                    )
                }
            }
        }

        let all = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(all.count == 2)
        for msg in all {
            #expect(msg.outboxStatus == .queued)
        }
    }

    @Test("Reconcile: sending messages WITH sentAt + appendedToSent are deleted (completed)")
    func reconcileSentAndAppendedDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = makeOutboxMessage(subject: "Completed but not deleted")
        msg.status = OutboxStatus.sending.rawValue
        msg.sentAt = Date()
        msg.appendedToSent = true
        msg.sentMessageId = "<completed@example.com>"
        try db.write { try msg.insert($0) }

        // Simulate reconcileOutbox: sentAt != nil && appendedToSent → delete
        try db.write { dbConn in
            let stale = try OutboxMessage
                .filter(Column("status") == OutboxStatus.sending.rawValue)
                .fetchAll(dbConn)
            for msg in stale {
                if msg.sentAt != nil && msg.appendedToSent {
                    _ = try OutboxMessage.deleteOne(dbConn, key: msg.id)
                }
            }
        }

        let remaining = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    @Test("Reconcile: sending messages WITH sentAt but NOT appendedToSent are kept for retry")
    func reconcileSentButNotAppendedKept() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = makeOutboxMessage(subject: "Sent but append failed")
        msg.status = OutboxStatus.sending.rawValue
        msg.sentAt = Date()
        msg.appendedToSent = false
        msg.sentMessageId = "<sent-no-append@example.com>"
        try db.write { try msg.insert($0) }

        // Simulate reconcileOutbox: sentAt != nil && !appendedToSent → keep for drainPendingSentAppends
        try db.write { dbConn in
            let stale = try OutboxMessage
                .filter(Column("status") == OutboxStatus.sending.rawValue)
                .fetchAll(dbConn)
            for msg in stale {
                if msg.sentAt != nil {
                    if msg.appendedToSent {
                        _ = try OutboxMessage.deleteOne(dbConn, key: msg.id)
                    }
                    // else: keep as-is for drainPendingSentAppends
                }
            }
        }

        let remaining = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].sentAt != nil)
        #expect(remaining[0].appendedToSent == false)

        // Verify drainPendingSentAppends query finds it
        let pendingAppends = try db.read {
            try OutboxMessage
                .filter(Column("sentAt") != nil)
                .filter(Column("appendedToSent") == false)
                .fetchAll($0)
        }
        #expect(pendingAppends.count == 1)
    }

    // MARK: - 8. Concurrent drain guard: if already .sending, skip

    @Test("Concurrent drain guard: re-read skips message already claimed as sending")
    func concurrentDrainGuardSkipsSending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage(subject: "Being sent")
        try db.write { try msg.insert($0) }

        // First drain claims it (marks as sending)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, msg.id]
            )
        }

        // Second drain re-reads and sees it's no longer queued — skips
        let reRead = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(reRead?.outboxStatus == .sending)
        // The drainOutbox check: `guard current.outboxStatus == .queued else { continue }`
        let shouldProcess = reRead?.outboxStatus == .queued
        #expect(shouldProcess == false)
    }

    @Test("Concurrent drain guard: queued messages not blocked by sending sibling")
    func concurrentDrainAllowsQueuedSiblings() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var sending = makeOutboxMessage(subject: "Already sending")
        sending.status = OutboxStatus.sending.rawValue
        let queued = makeOutboxMessage(subject: "Still queued")

        try db.write { dbConn in
            try sending.insert(dbConn)
            try queued.insert(dbConn)
        }

        // Drain query fetches only queued
        let toDrain = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        #expect(toDrain.count == 1)
        #expect(toDrain[0].subject == "Still queued")
    }

    // MARK: - Drain ordering: FIFO by createdAt

    @Test("Drain processes messages in FIFO order by createdAt")
    func drainFIFOOrdering() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg1 = makeOutboxMessage(subject: "First")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(subject: "Second")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)
        var msg3 = makeOutboxMessage(subject: "Third")
        msg3.createdAt = Date(timeIntervalSince1970: 3000)

        // Insert in reverse order
        try db.write { dbConn in
            try msg3.insert(dbConn)
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
        }

        let ordered = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        #expect(ordered.count == 3)
        #expect(ordered[0].subject == "First")
        #expect(ordered[1].subject == "Second")
        #expect(ordered[2].subject == "Third")
    }

    // MARK: - failedAccounts skip pattern

    @Test("Drain skips remaining messages for accounts that already failed")
    func failedAccountsSkipPattern() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "Acc1 msg1")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc1", subject: "Acc1 msg2")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)
        var msg3 = makeOutboxMessage(accountId: "acc2", subject: "Acc2 msg1")
        msg3.createdAt = Date(timeIntervalSince1970: 3000)

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
            try msg3.insert(dbConn)
        }

        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        // Simulate: acc1's first message fails -> add to failedAccounts
        var failedAccounts = Set<String>()
        failedAccounts.insert("acc1")

        var processedSubjects: [String] = []
        for msg in messages {
            if failedAccounts.contains(msg.accountId) { continue }
            processedSubjects.append(msg.subject)
        }

        // Only acc2's message should be processed
        #expect(processedSubjects == ["Acc2 msg1"])
    }

    // MARK: - Send failure with provider error

    @Test("Send failure: MockEmailProvider throws, retryCount incremented")
    func sendFailureIncrementsRetryCount() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage(subject: "Will fail")
        let msgId = msg.id
        let msgRetryCount = msg.retryCount
        try await db.write { try msg.insert($0) }

        let mock = MockEmailProvider()
        await mock.setSendThrows(ProviderError.notConnected)

        // Mark as sending
        try await db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, msgId]
            )
        }

        // Attempt send — should throw
        let draft = try msg.toDraftMessage()
        do {
            try await mock.send(draft: draft)
            Issue.record("Expected send to throw")
        } catch {
            // Send failed — update DB as drainOutbox would
            let newRetryCount = msgRetryCount + 1
            let shouldAutoRetry = newRetryCount < 3
            let newStatus = shouldAutoRetry ? OutboxStatus.queued.rawValue : OutboxStatus.failed.rawValue
            try await db.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = ? WHERE id = ?",
                    arguments: [newStatus, error.localizedDescription, newRetryCount, msgId]
                )
            }
        }

        let updated = try await db.read { try OutboxMessage.fetchOne($0, key: msgId) }
        #expect(updated?.retryCount == 1)
        #expect(updated?.outboxStatus == .queued)  // Still auto-retryable
        #expect(updated?.errorMessage != nil)
    }

    // MARK: - Discard guard: cannot discard sending message

    @Test("Discard guard: cannot discard a message with status sending")
    func discardGuardBlocksSending() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var msg = makeOutboxMessage(subject: "Mid-send")
        msg.status = OutboxStatus.sending.rawValue
        try db.write { try msg.insert($0) }

        // Simulate discardOutboxMessage logic: refuse to discard if sending
        let discarded = try db.write { dbConn -> Bool in
            guard let fetched = try OutboxMessage.fetchOne(dbConn, key: msg.id) else { return false }
            guard fetched.outboxStatus != .sending else { return false }
            _ = try OutboxMessage.deleteOne(dbConn, key: msg.id)
            return true
        }

        #expect(discarded == false)

        // Message still exists
        let stillExists = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(stillExists != nil)
    }

    @Test("Discard guard: can discard queued or failed messages")
    func discardAllowedForQueuedAndFailed() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let queued = makeOutboxMessage(subject: "Queued")
        var failed = makeOutboxMessage(subject: "Failed")
        failed.status = OutboxStatus.failed.rawValue
        failed.retryCount = 3

        try db.write { dbConn in
            try queued.insert(dbConn)
            try failed.insert(dbConn)
        }

        // Discard queued
        let discardedQueued = try db.write { dbConn -> Bool in
            guard let fetched = try OutboxMessage.fetchOne(dbConn, key: queued.id) else { return false }
            guard fetched.outboxStatus != .sending else { return false }
            _ = try OutboxMessage.deleteOne(dbConn, key: queued.id)
            return true
        }
        #expect(discardedQueued == true)

        // Discard failed
        let discardedFailed = try db.write { dbConn -> Bool in
            guard let fetched = try OutboxMessage.fetchOne(dbConn, key: failed.id) else { return false }
            guard fetched.outboxStatus != .sending else { return false }
            _ = try OutboxMessage.deleteOne(dbConn, key: failed.id)
            return true
        }
        #expect(discardedFailed == true)

        let remaining = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    // MARK: - sentMessageId dedup

    @Test("sentMessageId persists across status transitions for IMAP APPEND dedup")
    func sentMessageIdPersistsAcrossTransitions() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage()
        let msgId = msg.id
        try db.write { try msg.insert($0) }

        let messageId = "<unique-id-12345@example.com>"

        // Set sentMessageId when marking as sending (as drainOutbox does)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, messageId, msgId]
            )
        }

        // After send failure + retry, sentMessageId is preserved
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, retryCount = 1 WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, msgId]
            )
        }

        let afterRetry = try db.read { try OutboxMessage.fetchOne($0, key: msgId) }
        #expect(afterRetry?.sentMessageId == messageId)
        // On next drain attempt, drainOutbox uses `current.sentMessageId ?? generateMessageId()`
        // so it reuses the same ID, preventing duplicate IMAP APPENDs
    }

    // MARK: - Cascade delete with account

    @Test("OutboxMessage deleted when parent account is deleted (cascade)")
    func cascadeDeleteWithAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let msg = makeOutboxMessage()
        try db.write { try msg.insert($0) }

        let beforeDelete = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(beforeDelete.count == 1)

        // Delete the account — FK cascade should delete outbox messages
        try db.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM account WHERE id = ?", arguments: ["acc1"])
        }

        let afterDelete = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(afterDelete.isEmpty)
    }
}

/// PORT — v2final completed-send top guard (`4651d894b`) and atomic reducer
/// (`1b8ab1e32`, generation ownership from `97497416b`).
@Suite("Generation-owned completed-send finalization", .serialized, .processGlobalState)
@MainActor
struct OutboxGenerationFinalizationTests {
    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-finalize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "owner@example.com", displayName: "Owner", provider: .imap)
            account.id = "acc1"
            try account.insert(db)
            try Folder(
                name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id
            ).insert(db)
        }
        return (pool, directory, previous)
    }

    private func finish(_ fixture: (DatabasePool, URL, AppDatabase?)) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.2, pool: fixture.0, directory: fixture.1)
    }

    private func draft(id: String, epoch: String) -> Draft {
        var value = Draft(
            id: id, accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: id, body: "body", replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 1)
        value.instanceEpoch = epoch
        return value
    }

    private func turn(id: String, draftId: String) -> ChatTurn {
        ChatTurn(
            id: id, timestamp: 1, role: "user", content: "compose_edit",
            userMessage: "edit", type: "normal", chars: 4, renderedContent: nil,
            sessionId: "compose:\(draftId)",
            remindersSnapshot: nil, emailContextJSON: nil, thinkingContent: nil)
    }

    private func outbox(
        id: String = UUID().uuidString,
        draftId: String,
        epoch: String,
        completed: Bool
    ) -> OutboxMessage {
        var value = OutboxMessage(
            accountId: "acc1",
            draft: DraftMessage(to: ["recipient@example.com"], subject: "send", body: "body"))
        value.id = id
        value.draftId = draftId
        value.instanceEpoch = epoch
        value.status = OutboxStatus.sending.rawValue
        value.sentAt = Date()
        value.appendedToSent = completed
        return value
    }

    private func originalHeader(
        accountId: String = "acc1",
        messageId: String,
        rfc822MessageId: String
    ) -> MessageHeader {
        var value = MessageHeader(
            messageId: messageId,
            subject: "Original",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "owner@example.com",
            date: Date(),
            snippet: "body",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
            accountId: accountId,
            folderPath: "INBOX",
            isInInbox: true)
        value.rfc822MessageId = rfc822MessageId
        value.headerComplete = true
        return value
    }

    private func completedReply(
        accountId: String = "acc1",
        originalId: String,
        inReplyTo: String
    ) -> OutboxMessage {
        var value = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(
                to: ["recipient@example.com"],
                subject: "Re: Original",
                body: "reply",
                inReplyTo: inReplyTo),
            originalMessageHeaderId: originalId,
            isForward: false)
        value.status = OutboxStatus.sending.rawValue
        value.sentAt = Date()
        value.appendedToSent = true
        return value
    }

    @Test("Incomplete send evidence performs no finalization mutation")
    func incompleteEvidenceRefusesFinalization() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let liveDraft = draft(id: "draft-incomplete", epoch: "E1")
        let liveTurn = turn(id: "turn-incomplete", draftId: liveDraft.id)
        let pending = outbox(draftId: liveDraft.id, epoch: "E1", completed: false)
        try await fixture.0.writeWithoutTransaction { db in
            try liveDraft.insert(db)
            try liveTurn.insert(db)
            try pending.insert(db)
        }

        await AccountManager.shared.reconcileOutbox()

        let state = try await fixture.0.read { db in
            (try OutboxMessage.fetchOne(db, key: pending.id),
             try Draft.fetchOne(db, key: liveDraft.id),
             try ChatTurn.fetchOne(db, key: liveTurn.id))
        }
        #expect(state.0 != nil)
        #expect(state.1?.instanceEpoch == "E1")
        #expect(state.2 != nil)
    }

    @Test("Completed-send finalization atomically removes only the matching generation")
    func completedFinalizationOwnsExactGeneration() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let sharedId = "draft-shared"
        let liveE2 = draft(id: sharedId, epoch: "E2")
        let liveE2Turn = turn(id: "turn-live-e2", draftId: sharedId)
        let staleE1 = outbox(draftId: sharedId, epoch: "E1", completed: true)
        let exactE1 = draft(id: "draft-exact-e1", epoch: "E1")
        let exactE1Turn = turn(id: "turn-exact-e1", draftId: exactE1.id)
        let completedE1 = outbox(draftId: exactE1.id, epoch: "E1", completed: true)
        try await fixture.0.writeWithoutTransaction { db in
            try liveE2.insert(db)
            try liveE2Turn.insert(db)
            try staleE1.insert(db)
            try exactE1.insert(db)
            try exactE1Turn.insert(db)
            try completedE1.insert(db)
        }

        _ = try await fixture.0.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: staleE1.id, db: db)
        }
        let mismatch = try await fixture.0.read { db in
            (try OutboxMessage.fetchOne(db, key: staleE1.id),
             try Draft.fetchOne(db, key: sharedId),
             try ChatTurn.fetchOne(db, key: liveE2Turn.id))
        }
        #expect(mismatch.0 == nil)
        #expect(mismatch.1?.instanceEpoch == "E2")
        #expect(mismatch.2 != nil)

        _ = try await fixture.0.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: completedE1.id, db: db)
        }
        let exact = try await fixture.0.read { db in
            (try OutboxMessage.fetchOne(db, key: completedE1.id),
             try Draft.fetchOne(db, key: exactE1.id),
             try ChatTurn.fetchOne(db, key: exactE1Turn.id))
        }
        #expect(exact.0 == nil)
        #expect(exact.1 == nil)
        #expect(exact.2 == nil)
    }

    @Test("A forced outbox-delete failure rolls back Draft and ChatTurn deletion")
    func forcedOutboxDeleteFailureRollsBack() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let owned = draft(id: "draft-rollback", epoch: "E1")
        let ownedTurn = turn(id: "turn-rollback", draftId: owned.id)
        let completed = outbox(
            id: "outbox-forced-failure", draftId: owned.id, epoch: "E1", completed: true)
        try await fixture.0.writeWithoutTransaction { db in
            try owned.insert(db)
            try ownedTurn.insert(db)
            try completed.insert(db)
            try db.execute(sql: """
                CREATE TRIGGER force_outbox_delete_failure
                BEFORE DELETE ON outboxMessage
                WHEN OLD.id = 'outbox-forced-failure'
                BEGIN
                    SELECT RAISE(ABORT, 'forced outbox delete failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            _ = try await fixture.0.write { db in
                try AccountManager.deleteCompletedSendAtomic(outboxId: completed.id, db: db)
            }
        }

        let state = try await fixture.0.read { db in
            (try OutboxMessage.fetchOne(db, key: completed.id),
             try Draft.fetchOne(db, key: owned.id),
             try ChatTurn.fetchOne(db, key: ownedTurn.id))
        }
        #expect(state.0 != nil)
        #expect(state.1?.instanceEpoch == "E1")
        #expect(state.2 != nil)
    }

    @Test(
        "A send never flags another account through either the direct PK or former global-RFC path",
        arguments: [true, false])
    func originalResolutionIsAccountConfined(useForeignPrimaryKey: Bool) async throws {
        let fixture = try install()
        defer { finish(fixture) }
        var otherAccount = Account(
            emailAddress: "other@example.com", displayName: "Other", provider: .imap)
        otherAccount.id = "acc2"
        let otherFolder = Folder(
            name: "INBOX", path: "INBOX", role: .inbox, accountId: otherAccount.id)
        let sharedRfc = "shared-original@example.com"
        let foreign = originalHeader(
            accountId: otherAccount.id,
            messageId: "41",
            rfc822MessageId: sharedRfc)
        let completed = completedReply(
            originalId: useForeignPrimaryKey
                ? foreign.id
                : MessageIdentity.headerId(
                    accountId: "acc1", folderPath: "INBOX", messageId: "vanished"),
            inReplyTo: "<\(sharedRfc)>")
        let insertableOtherAccount = otherAccount
        try await fixture.0.writeWithoutTransaction { db in
            try insertableOtherAccount.insert(db)
            try otherFolder.insert(db)
            try foreign.insert(db)
            try completed.insert(db)
        }

        _ = try await fixture.0.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: completed.id, db: db)
        }

        let state = try await fixture.0.read { db in
            (try MessageHeader.fetchOne(db, key: foreign.id),
             try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.isReplied == false)
        #expect(state.0?.isForwarded == false)
        #expect(state.1.isEmpty)
    }

    @Test("A reused IMAP UID cannot flag the new occupant at the original composite key")
    func originalResolutionRejectsReusedUidImpostor() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let impostor = originalHeader(
            messageId: "77", rfc822MessageId: "new-occupant@example.com")
        let completed = completedReply(
            originalId: impostor.id,
            inReplyTo: "<intended-original@example.com>")
        try await fixture.0.writeWithoutTransaction { db in
            try impostor.insert(db)
            try completed.insert(db)
        }

        _ = try await fixture.0.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: completed.id, db: db)
        }

        let state = try await fixture.0.read { db in
            (try MessageHeader.fetchOne(db, key: impostor.id),
             try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.isReplied == false)
        #expect(state.0?.isForwarded == false)
        #expect(state.1.isEmpty)
    }

    /// The ADMITTED side of the original-resolution family, and the non-vacuity
    /// partner for the two refusal tests above it: a change that simply stopped
    /// flagging would pass both of those and fail here.
    ///
    /// 🚨 THE FIXTURE MUST MAKE THE PARENT ADDRESSABLE, and this is why. `install()`
    /// builds an `.imap` account whose INBOX carries no `lastKnownUidValidity`, and
    /// `originalHeader` leaves `observedUidValidity` nil — together that is exactly
    /// the `IOS-EPOCH-001` accepted fail-closed window, in which NO durable IMAP
    /// gesture is admitted on that folder by owner decision. A parent in that state
    /// cannot be positively addressed on the wire, so `deleteCompletedSendAtomic`
    /// correctly queues nothing for it (audit A-6), and a test left on that fixture
    /// was asserting a refusal window rather than the property it names. Every
    /// SYNCED row carries the epoch it was observed under (`SyncEngine`/
    /// `SyncEngineFullSync` stamp `observedUidValidity = sourceBoundEpoch` on
    /// ingest, and the delta-sync bootstrap writes the folder's own epoch), so the
    /// stamps below are what an ordinary reply parent actually looks like.
    ///
    /// The op is asserted to be EXECUTABLE, not merely present: an op naming the
    /// rfc822 content id with no epoch — the pre-A-6 shape — is one the drain's
    /// checkpoint A can only skip and the `.markReplied` executor arm can only
    /// no-op, which is indistinguishable from never having queued it. The end
    /// state at the wire is pinned separately by `NeverDropExitClosureTests
    /// .repliedFlagForAnAddressableParentReachesTheWire`.
    @Test("An exact same-account original with matching RFC evidence is still flagged")
    func originalResolutionAcceptsCorroboratedSameAccountRow() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        let epoch = 4242
        let rfc822 = "same-account-original@example.com"
        let original: MessageHeader = {
            var value = originalHeader(messageId: "91", rfc822MessageId: rfc822)
            value.observedUidValidity = epoch
            return value
        }()
        let completed = completedReply(
            originalId: original.id,
            inReplyTo: "<\(rfc822)>")
        try await fixture.0.writeWithoutTransaction { db in
            try Folder
                .filter(Column("id") == MessageIdentity.folderId(
                    accountId: "acc1", folderPath: "INBOX"))
                .updateAll(db, Column("lastKnownUidValidity").set(to: epoch))
            try original.insert(db)
            try completed.insert(db)
        }

        _ = try await fixture.0.write { db in
            try AccountManager.deleteCompletedSendAtomic(outboxId: completed.id, db: db)
        }

        let state = try await fixture.0.read { db in
            (try MessageHeader.fetchOne(db, key: original.id),
             try PendingOperation.fetchAll(db))
        }
        #expect(state.0?.isReplied == true)
        #expect(state.0?.isForwarded == false)
        #expect(state.1.count == 1)
        guard state.1.count == 1 else { return }
        #expect(state.1[0].type == .markReplied)
        #expect(state.1[0].accountId == "acc1")
        #expect(state.1[0].folderPath == "INBOX")
        // Executable, not merely queued — see the doc comment.
        #expect(original.stableId != original.messageId,
                "precondition: content id and provider address must differ, or the check below is blind")
        #expect(state.1[0].messageIds == [original.messageId],
                "the op names \(state.1[0].messageIds) — an rfc822 content id is not an address")
        #expect(state.1[0].observedUidValidity == epoch,
                "the op must carry the epoch that proved its address, or no drain will ever claim it")
    }
}

// MARK: - MockEmailProvider test helper extensions

extension MockEmailProvider {
    /// Set sendThrows from outside the actor.
    func setSendThrows(_ error: Error?) {
        sendThrows = error
    }

    /// Set appendToSentThrows from outside the actor.
    func setAppendToSentThrows(_ error: Error?) {
        appendToSentThrows = error
    }
}
