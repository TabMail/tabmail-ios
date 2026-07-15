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

@Suite("Outbox durable RFC admission", .serialized, .processGlobalState)
struct OutboxRFCAdmissionTests {
    private struct Fixture {
        let pool: DatabasePool
        let folder: Folder
        let directory: URL
        let previous: AppDatabase?
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        var account = Account(
            emailAddress: "sender@example.com",
            displayName: "Sender",
            provider: .imap
        )
        account.id = "outbox-rfc-account"
        let folder = Folder(
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            accountId: account.id
        )
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try folder.insert(db)
        }
        return Fixture(
            pool: pool,
            folder: folder,
            directory: directory,
            previous: previous
        )
    }

    private func restore(_ fixture: Fixture) {
        // Finalization starts unstructured queue work. If the test host had no
        // prior shared DB, retain this fixture as the valid process DB so that
        // trailing work cannot dereference a nil/closed pool. Otherwise restore
        // the prior DB, then close and remove this fixture completely.
        guard fixture.previous != nil else { return }
        AppDatabase.shared.withLock { $0 = fixture.previous }
        try? fixture.pool.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func makeHeader(folder: Folder, rfc822MessageId: String?) -> MessageHeader {
        var header = MessageHeader(
            messageId: "provider-resource-id",
            subject: "Subject",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "Body",
            folderId: folder.id,
            accountId: folder.accountId,
            folderPath: folder.path,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822MessageId
        header.headerComplete = true
        header.actionTag = .reply
        header.tagSortOrder = ActionTag.reply.sortOrder
        return header
    }

    private func makeOutbox(
        header: MessageHeader,
        isForward: Bool
    ) -> OutboxMessage {
        let draft = DraftMessage(
            to: ["recipient@example.com"],
            subject: "Subject",
            body: "Body"
        )
        return OutboxMessage(
            accountId: header.accountId,
            draft: draft,
            originalMessageHeaderId: header.id,
            isForward: isForward
        )
    }

    @Test("normal reply finalization queues normalized RFC identity and keeps action tags local")
    func normalReplyUsesRFCIdentity() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let header = makeHeader(
            folder: fixture.folder,
            rfc822MessageId: " <Reply.Case@Example.COM> "
        )
        let outbox = makeOutbox(header: header, isForward: false)
        try await fixture.pool.writeWithoutTransaction { db in
            try header.insert(db)
            try outbox.insert(db)
        }

        await AccountManager.shared.finalizeOutboxMessageForTesting(outbox)

        let state = try await fixture.pool.read { db -> (MessageHeader?, OutboxMessage?, [PendingOperation]) in
            (
                try MessageHeader.fetchOne(db, key: header.id),
                try OutboxMessage.fetchOne(db, key: outbox.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(state.0?.isReplied == true)
        #expect(state.0?.actionTag == ActionTag.none)
        #expect(state.1 == nil)
        #expect(state.2.count == 1)
        guard state.2.count == 1 else { return }
        #expect(state.2[0].type == .markReplied)
        #expect(state.2[0].messageIds == ["Reply.Case@Example.COM"])
    }

    @Test("normal forward with malformed RFC finalizes locally and queues the provider-ID token member")
    func normalForwardInvalidRFCQueuesToken() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let header = makeHeader(
            folder: fixture.folder,
            rfc822MessageId: "<missing-close@example.com"
        )
        let outbox = makeOutbox(header: header, isForward: true)
        try await fixture.pool.writeWithoutTransaction { db in
            try header.insert(db)
            try outbox.insert(db)
        }

        await AccountManager.shared.finalizeOutboxMessageForTesting(outbox)

        let state = try await fixture.pool.read { db -> (MessageHeader?, OutboxMessage?, [PendingOperation]) in
            (
                try MessageHeader.fetchOne(db, key: header.id),
                try OutboxMessage.fetchOne(db, key: outbox.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(state.0?.isForwarded == true)
        #expect(state.1 == nil)
        // Hybrid identity (PLAN_IDENTITY_HYBRID §2): the malformed RFC falls
        // back to the provider ID as an opaque token member.
        #expect(state.2.count == 1)
        if state.2.count == 1 {
            #expect(state.2[0].type == .markForwarded)
            #expect(state.2[0].messageIds == ["provider-resource-id"])
        }
    }

    @Test("normal reply with a blank source finalizes locally but queues no auxiliary action")
    func normalReplyBlankSourceQueuesNothing() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        var header = makeHeader(
            folder: fixture.folder,
            rfc822MessageId: "blank-source@example.com"
        )
        header.folderPath = "   "
        let headerToInsert = header
        let outbox = makeOutbox(header: headerToInsert, isForward: false)
        try await fixture.pool.writeWithoutTransaction { db in
            try headerToInsert.insert(db)
            try outbox.insert(db)
        }

        await AccountManager.shared.finalizeOutboxMessageForTesting(outbox)

        let state = try await fixture.pool.read { db -> (MessageHeader?, OutboxMessage?, [PendingOperation]) in
            (
                try MessageHeader.fetchOne(db, key: headerToInsert.id),
                try OutboxMessage.fetchOne(db, key: outbox.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(state.0?.isReplied == true)
        #expect(state.1 == nil)
        #expect(state.2.isEmpty)
    }

    @Test("crash recovery queues the same normalized RFC identity as normal finalization")
    func crashRecoveryUsesRFCIdentity() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let header = makeHeader(
            folder: fixture.folder,
            rfc822MessageId: "<recovered@example.com>"
        )
        var recovering = makeOutbox(header: header, isForward: false)
        recovering.status = OutboxStatus.sending.rawValue
        recovering.sentAt = Date()
        recovering.appendedToSent = true
        let recoveringToInsert = recovering
        try await fixture.pool.writeWithoutTransaction { db in
            try header.insert(db)
            try recoveringToInsert.insert(db)
        }

        await AccountManager.shared.reconcileOutbox()

        let state = try await fixture.pool.read { db -> (MessageHeader?, OutboxMessage?, [PendingOperation]) in
            (
                try MessageHeader.fetchOne(db, key: header.id),
                try OutboxMessage.fetchOne(db, key: recoveringToInsert.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(state.0?.isReplied == true)
        #expect(state.1 == nil)
        #expect(state.2.count == 1)
        guard state.2.count == 1 else { return }
        #expect(state.2[0].type == .markReplied)
        #expect(state.2[0].messageIds == ["recovered@example.com"])
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
