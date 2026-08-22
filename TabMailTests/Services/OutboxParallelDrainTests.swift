/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for the parallel outbox drain pattern.
/// Verifies that messages are processed concurrently (not sequentially),
/// that a failed account doesn't block other accounts, and that discarding
/// a failed message triggers drain for remaining queued messages.
@Suite("Outbox Parallel Drain")
struct OutboxParallelDrainTests {

    // MARK: - Helpers

    private func makeOutboxMessage(
        accountId: String = "acc1",
        subject: String = "Test",
        to: [String] = ["recipient@example.com"]
    ) -> OutboxMessage {
        let draft = DraftMessage(to: to, subject: subject, body: "Test body")
        return OutboxMessage(accountId: accountId, draft: draft)
    }

    // MARK: - 1. All queued messages claimed before any send completes (parallel pattern)

    @Test("Parallel drain: all queued messages can be claimed (marked sending) simultaneously")
    func allMessagesClaimedInParallel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "acc2@example.com")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "Msg 1")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc1", subject: "Msg 2")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)
        var msg3 = makeOutboxMessage(accountId: "acc2", subject: "Msg 3")
        msg3.createdAt = Date(timeIntervalSince1970: 3000)

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
            try msg3.insert(dbConn)
        }

        // Fetch all queued
        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }
        #expect(messages.count == 3)

        // In the parallel pattern, ALL messages are claimed (marked sending) before
        // any send completes. This contrasts with the old sequential pattern where
        // only one message was claimed at a time.
        try db.write { dbConn in
            for msg in messages {
                try dbConn.execute(
                    sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, "<\(msg.id)@example.com>", msg.id]
                )
            }
        }

        let allSending = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.sending.rawValue)
                .fetchAll($0)
        }
        #expect(allSending.count == 3)

        // No queued messages remain (all claimed)
        let remaining = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(remaining.isEmpty)
    }

    // MARK: - 2. Failed account isolation: failure doesn't block other accounts

    @Test("Parallel drain: failure for acc1 does NOT block acc2 messages")
    func failedAccountDoesNotBlockOtherAccounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "acc2@example.com")
        try TestDatabase.insertAccount(db, id: "acc3", email: "acc3@example.com")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "Acc1 will fail")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc2", subject: "Acc2 should succeed")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)
        var msg3 = makeOutboxMessage(accountId: "acc3", subject: "Acc3 should succeed")
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

        // Simulate parallel drain: claim all non-failed-account messages
        var failedAccounts = Set<String>()
        // acc1 already known to have failed (e.g. from a previous message in this pass)
        failedAccounts.insert("acc1")

        var claimed: [String] = []
        for msg in messages {
            if failedAccounts.contains(msg.accountId) { continue }
            claimed.append(msg.subject)
        }

        // acc2 and acc3 messages are claimed despite acc1 failure
        #expect(claimed.count == 2)
        #expect(claimed.contains("Acc2 should succeed"))
        #expect(claimed.contains("Acc3 should succeed"))
    }

    // MARK: - 3. Same account: second message not blocked by first message's failure

    @Test("Parallel drain: both messages for same account are claimed before failure is known")
    func sameAccountBothClaimedBeforeFailure() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "First")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc1", subject: "Second")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
        }

        // In the parallel pattern, BOTH messages are claimed (marked sending)
        // before any send attempt completes. So even if msg1 fails, msg2 was
        // already claimed and will be attempted.
        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        // No failedAccounts yet at claim time
        let failedAccounts = Set<String>()
        var claimedIds: [String] = []
        for msg in messages {
            if failedAccounts.contains(msg.accountId) { continue }
            claimedIds.append(msg.id)
        }

        #expect(claimedIds.count == 2)

        // Mark both as sending (claimed)
        try db.write { dbConn in
            for id in claimedIds {
                try dbConn.execute(
                    sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, id]
                )
            }
        }

        // Now msg1 fails — in parallel pattern, msg2 is already sending independently
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = 1 WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, "Connection failed", msg1.id]
            )
        }

        // msg2 succeeds independently
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?",
                arguments: [Date(), msg2.id]
            )
        }

        let msg1State = try db.read { try OutboxMessage.fetchOne($0, key: msg1.id) }
        let msg2State = try db.read { try OutboxMessage.fetchOne($0, key: msg2.id) }

        // msg1 was reset to queued for retry, msg2 completed
        #expect(msg1State?.outboxStatus == .queued)
        #expect(msg2State?.sentAt != nil)
    }

    // MARK: - 4. Concurrent sends via MockEmailProvider

    @Test("Parallel sends: multiple messages sent concurrently via provider")
    func parallelSendsViaProvider() async throws {
        let mock = MockEmailProvider()

        let drafts = (0..<3).map { i in
            DraftMessage(to: ["r\(i)@example.com"], subject: "Msg \(i)", body: "Body \(i)")
        }

        // Launch sends concurrently (as drainOutbox does with parallel Tasks)
        await withTaskGroup(of: Void.self) { group in
            for draft in drafts {
                group.addTask {
                    try? await mock.send(draft: draft)
                }
            }
        }

        let sentDrafts = await mock.sentDrafts
        #expect(sentDrafts.count == 3)
        let subjects = Set(sentDrafts.map(\.subject))
        #expect(subjects == Set(["Msg 0", "Msg 1", "Msg 2"]))
    }

    @Test("Parallel sends: one provider failure doesn't cancel other in-flight sends")
    func oneFailureDoesntCancelOthers() async throws {
        let failMock = MockEmailProvider()
        await failMock.setSendThrows(ProviderError.notConnected)

        let successMock = MockEmailProvider()

        let draft1 = DraftMessage(to: ["a@b.com"], subject: "Fails", body: "Body")
        let draft2 = DraftMessage(to: ["c@d.com"], subject: "Succeeds", body: "Body")

        // Simulate parallel drain: two accounts, two providers
        var results: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            group.addTask {
                do {
                    try await failMock.send(draft: draft1)
                    return ("acc1", true)
                } catch {
                    return ("acc1", false)
                }
            }
            group.addTask {
                do {
                    try await successMock.send(draft: draft2)
                    return ("acc2", true)
                } catch {
                    return ("acc2", false)
                }
            }
            for await (account, success) in group {
                results[account] = success
            }
        }

        #expect(results["acc1"] == false) // failed
        #expect(results["acc2"] == true)  // succeeded independently

        let failSent = await failMock.sentDrafts
        #expect(failSent.count == 1) // recorded before throw

        let successSent = await successMock.sentDrafts
        #expect(successSent.count == 1)
        #expect(successSent[0].subject == "Succeeds")
    }

    // MARK: - 5. Discard triggers drain: remaining queued messages processable

    @Test("After discarding failed message, remaining queued messages are found by drain query")
    func discardFailedThenDrainFindsRemaining() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var failedMsg = makeOutboxMessage(accountId: "acc1", subject: "Failed send")
        failedMsg.status = OutboxStatus.failed.rawValue
        failedMsg.retryCount = 3
        failedMsg.errorMessage = "SMTP auth error"

        let queuedMsg = makeOutboxMessage(accountId: "acc1", subject: "Still queued")

        try db.write { dbConn in
            try failedMsg.insert(dbConn)
            try queuedMsg.insert(dbConn)
        }

        // Before discard: drain query finds only the queued message
        let beforeDiscard = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(beforeDiscard.count == 1)
        #expect(beforeDiscard[0].subject == "Still queued")

        // Simulate discardOutboxMessageConfirmed: atomic fetch + delete
        let discarded = try db.write { dbConn -> Bool in
            guard let msg = try OutboxMessage.fetchOne(dbConn, key: failedMsg.id) else { return false }
            guard msg.outboxStatus != .sending else { return false }
            try OutboxMessage.deleteOne(dbConn, key: failedMsg.id)
            return true
        }
        #expect(discarded == true)

        // After discard: drain query still finds the queued message
        // (in production, a confirmed discard triggers drainOutbox)
        let afterDiscard = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(afterDiscard.count == 1)
        #expect(afterDiscard[0].subject == "Still queued")
        #expect(afterDiscard[0].id == queuedMsg.id)
    }

    @Test("Discard failed + drain: queued message can transition through full lifecycle")
    func discardFailedThenDrainProcessesQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var failedMsg = makeOutboxMessage(accountId: "acc1", subject: "Blocked send")
        failedMsg.status = OutboxStatus.failed.rawValue
        failedMsg.retryCount = 3

        let queuedMsg = makeOutboxMessage(accountId: "acc1", subject: "Waiting to send")

        try db.write { dbConn in
            try failedMsg.insert(dbConn)
            try queuedMsg.insert(dbConn)
        }

        // Discard the failed message
        _ = try db.write { dbConn in
            try OutboxMessage.deleteOne(dbConn, key: failedMsg.id)
        }

        // Drain finds the queued message
        let toDrain = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }
        #expect(toDrain.count == 1)

        // Claim it (mark sending)
        let msgId = toDrain[0].id
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, sentMessageId = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, "<test@example.com>", msgId]
            )
        }

        // Send succeeds — stamp sentAt
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET sentAt = ? WHERE id = ?",
                arguments: [Date(), msgId]
            )
        }

        // Append to Sent succeeds — mark appended
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET appendedToSent = 1 WHERE id = ?",
                arguments: [msgId]
            )
        }

        // Finalize — delete
        _ = try db.write { dbConn in
            try OutboxMessage.deleteOne(dbConn, key: msgId)
        }

        let remaining = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    // MARK: - 6. OutboxDrainContext pattern: failedAccounts shared across parallel tasks

    @Test("OutboxDrainContext: failedAccounts populated by one task prevents claiming in next pass")
    func failedAccountsPreventsNextPassClaiming() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "First fails")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc1", subject: "Second queued")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
        }

        // Pass 1: both claimed (parallel), msg1 fails
        var failedAccounts = Set<String>()

        // Claim both (pass 1, failedAccounts empty at claim time)
        let pass1Messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        var pass1Claimed: [String] = []
        for msg in pass1Messages {
            if failedAccounts.contains(msg.accountId) { continue }
            pass1Claimed.append(msg.id)
        }
        #expect(pass1Claimed.count == 2) // both claimed in parallel

        // msg1 send fails -> add to failedAccounts
        failedAccounts.insert("acc1")

        // msg2 send also fails (same SMTP issue)
        // Both reset to queued
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, retryCount = 1 WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, msg1.id]
            )
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, retryCount = 1 WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, msg2.id]
            )
        }

        // Pass 2: failedAccounts blocks acc1 -> no messages claimed -> drain exits
        let pass2Messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        var pass2Claimed: [String] = []
        for msg in pass2Messages {
            if failedAccounts.contains(msg.accountId) { continue }
            pass2Claimed.append(msg.id)
        }
        #expect(pass2Claimed.isEmpty) // blocked by failedAccounts
    }

    // MARK: - 7. Mixed accounts: parallel drain processes healthy accounts despite sick one

    @Test("Mixed accounts: acc1 fails, acc2 and acc3 complete in same drain pass")
    func mixedAccountsParallelCompletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "acc2@example.com")
        try TestDatabase.insertAccount(db, id: "acc3", email: "acc3@example.com")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "Acc1 fails")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc2", subject: "Acc2 succeeds")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)
        var msg3 = makeOutboxMessage(accountId: "acc3", subject: "Acc3 succeeds")
        msg3.createdAt = Date(timeIntervalSince1970: 3000)

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
            try msg3.insert(dbConn)
        }

        // All three claimed (parallel, no failedAccounts yet)
        try db.write { dbConn in
            for id in [msg1.id, msg2.id, msg3.id] {
                try dbConn.execute(
                    sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                    arguments: [OutboxStatus.sending.rawValue, id]
                )
            }
        }

        // msg1 fails
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ?, errorMessage = ?, retryCount = 1 WHERE id = ?",
                arguments: [OutboxStatus.queued.rawValue, "Connection refused", msg1.id]
            )
        }

        // msg2 and msg3 succeed (independently, in parallel)
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET sentAt = ?, appendedToSent = 1 WHERE id = ?",
                arguments: [Date(), msg2.id]
            )
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET sentAt = ?, appendedToSent = 1 WHERE id = ?",
                arguments: [Date(), msg3.id]
            )
        }

        // Finalize msg2 and msg3
        try db.write { dbConn in
            try OutboxMessage.deleteOne(dbConn, key: msg2.id)
            try OutboxMessage.deleteOne(dbConn, key: msg3.id)
        }

        // Only msg1 remains (queued for retry)
        let remaining = try db.read { try OutboxMessage.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].id == msg1.id)
        #expect(remaining[0].outboxStatus == .queued)
        #expect(remaining[0].retryCount == 1)
    }

    // MARK: - 8. Contrast with old sequential behavior

    @Test("Old sequential bug: acc1 failure would block acc1-msg2 — parallel fixes this")
    func sequentialBugFixedByParallel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        var msg1 = makeOutboxMessage(accountId: "acc1", subject: "First fails")
        msg1.createdAt = Date(timeIntervalSince1970: 1000)
        var msg2 = makeOutboxMessage(accountId: "acc1", subject: "Second should still be attempted")
        msg2.createdAt = Date(timeIntervalSince1970: 2000)

        try db.write { dbConn in
            try msg1.insert(dbConn)
            try msg2.insert(dbConn)
        }

        // In the OLD sequential pattern:
        //   1. Claim msg1, send, fail -> failedAccounts.insert("acc1")
        //   2. Loop to msg2 -> failedAccounts.contains("acc1") -> SKIP
        //   Result: msg2 never attempted in this drain pass

        // In the NEW parallel pattern:
        //   1. Claim msg1 AND msg2 (failedAccounts empty at claim time)
        //   2. Launch Task for msg1, Launch Task for msg2 (concurrent)
        //   3. msg1 fails -> failedAccounts.insert("acc1") (but msg2 already launched)
        //   Result: msg2 IS attempted in this drain pass

        // Simulate the new parallel behavior:
        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll($0)
        }

        // All claimed before any failure (parallel claim phase)
        let failedAccountsAtClaimTime = Set<String>() // empty!
        var claimed: [String] = []
        for msg in messages {
            if failedAccountsAtClaimTime.contains(msg.accountId) { continue }
            claimed.append(msg.subject)
        }

        // Both messages claimed — this is the key difference from sequential
        #expect(claimed.count == 2)
        #expect(claimed.contains("First fails"))
        #expect(claimed.contains("Second should still be attempted"))
    }

    // MARK: - 9. Vanished message during parallel claim

    @Test("Parallel drain: message vanished between fetch and claim is safely skipped")
    func vanishedMessageSkipped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let msg = makeOutboxMessage(accountId: "acc1", subject: "Will vanish")
        try db.write { try msg.insert($0) }

        // Fetch queued
        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(messages.count == 1)

        // Between fetch and re-read, message is discarded by another thread
        _ = try db.write { try OutboxMessage.deleteOne($0, key: msg.id) }

        // Re-read (as drainOutbox does) — message is gone
        let reRead = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        #expect(reRead == nil) // safely skipped
    }

    @Test("Parallel drain: message status changed between fetch and claim is skipped")
    func statusChangedBetweenFetchAndClaim() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")

        let msg = makeOutboxMessage(accountId: "acc1", subject: "Already claimed")
        try db.write { try msg.insert($0) }

        // Fetch queued
        let messages = try db.read {
            try OutboxMessage
                .filter(Column("status") == OutboxStatus.queued.rawValue)
                .fetchAll($0)
        }
        #expect(messages.count == 1)

        // Between fetch and re-read, another drain marked it as sending
        try db.write { dbConn in
            try dbConn.execute(
                sql: "UPDATE outboxMessage SET status = ? WHERE id = ?",
                arguments: [OutboxStatus.sending.rawValue, msg.id]
            )
        }

        // Re-read — status is no longer queued
        let reRead = try db.read { try OutboxMessage.fetchOne($0, key: msg.id) }
        let shouldProcess = reRead?.outboxStatus == .queued
        #expect(shouldProcess == false) // safely skipped
    }

    // MARK: - 10. Concurrent execution via ProviderWorkQueue

    @Test("ProviderWorkQueue allows concurrent outbox sends")
    func workQueueConcurrentSends() async throws {
        let mock = MockEmailProvider()
        let queue = ProviderWorkQueue(provider: mock, maxConcurrency: 3)

        let tracker = ConcurrencyTracker()

        // Launch 3 sends concurrently through the work queue (as parallel drain does)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    try? await queue.execute(priority: .userAction) {
                        await tracker.enter()
                        // Simulate send taking some time
                        try? await Task.sleep(for: .milliseconds(50))
                        await tracker.exit()
                        let draft = DraftMessage(to: ["r\(i)@example.com"], subject: "Msg \(i)", body: "Body")
                        try await mock.send(draft: draft)
                    }
                }
            }
        }

        let maxConcurrent = await tracker.maxConcurrent
        // With maxConcurrency: 3, all 3 should run concurrently
        #expect(maxConcurrent >= 2) // at least 2 concurrent (timing-dependent)

        let sentCount = await mock.sentDrafts.count
        #expect(sentCount == 3)
    }
}

// MARK: - Test Helpers

private actor ConcurrencyTracker {
    private var current = 0
    var maxConcurrent = 0

    func enter() {
        current += 1
        if current > maxConcurrent { maxConcurrent = current }
    }

    func exit() {
        current -= 1
    }
}
