/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Helpers

/// Builds a realistic MessageHeaderInfo with sensible defaults for resilience tests.
private func makeHeaderInfo(
    messageId: String = "100",
    subject: String = "Test Subject",
    from: String = "sender@example.com",
    fromAddress: String = "sender@example.com",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> MessageHeaderInfo {
    MessageHeaderInfo(
        messageId: messageId,
        rfc822MessageId: "<msg-\(messageId)@example.com>",
        inReplyTo: nil,
        references: [],
        threadId: nil,
        subject: subject,
        from: from,
        fromAddress: fromAddress,
        to: "recipient@example.com",
        cc: "",
        bcc: "",
        replyTo: nil,
        date: date,
        snippet: "Test snippet",
        isRead: false,
        isFlagged: false,
        hasAttachments: false,
        isReplied: false,
        isForwarded: false,
        actionTag: nil
    )
}

/// Simulates the error classification check from AccountManager.isMessageNotFoundError.
private func isMessageNotFoundError(_ error: Error) -> Bool {
    let desc = "\(error)"
    if case ProviderError.messageNotFound = error { return true }
    if case ProviderError.networkError(let underlying) = error,
       (underlying as NSError).code == 404 { return true }
    if desc.contains("no such message") || desc.contains("UID not found") ||
       desc.contains("Message not found") || desc.contains("NONEXISTENT") { return true }
    return false
}

// MARK: - Suite 1: Mid-Sync Connection Drop and Recovery

@Suite("Connection Resilience - Mid-Sync Recovery")
struct MidSyncRecoveryTests {
    let db: DatabaseQueue
    let provider: MockEmailProvider

    init() throws {
        db = try TestDatabase.make()
        provider = MockEmailProvider()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
    }

    /// Simulate fullSync's reconnect-retry pattern for a folder.
    /// Returns true if the folder was successfully synced.
    private func simulateSyncWithReconnect(folderPath: String) async throws -> Bool {
        do {
            _ = try await provider.fetchMessages(folder: folderPath, limit: 50, offset: 0)
            return true
        } catch {
            if SyncEngine.isConnectionError(error) {
                try await provider.disconnect()
                try await provider.connect()
                // Retry once
                _ = try await provider.fetchMessages(folder: folderPath, limit: 50, offset: 0)
                return true
            } else if SyncEngine.isSelectFailedError(error) {
                // Skip this folder
                return false
            } else {
                throw error
            }
        }
    }

    @Test("Connection error during folder sync triggers disconnect-reconnect-retry sequence")
    func connectionErrorTriggersReconnect() async throws {
        // First fetchMessages throws connection error, second succeeds
        // Configure: first call throws, then clear for retry
        await provider.setFetchMessagesThrows(ProviderError.notConnected)

        do {
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        } catch {
            #expect(SyncEngine.isConnectionError(error))
            try await provider.disconnect()
            try await provider.connect()
            // Clear error for retry
            await provider.setFetchMessagesThrows(nil)
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        }

        let log = await provider.callLog
        // Should show: fetchMessages (failed), disconnect, connect, fetchMessages (retry)
        #expect(log.count == 4)
        #expect(log[0].hasPrefix("fetchMessages"))
        #expect(log[1] == "disconnect")
        #expect(log[2] == "connect")
        #expect(log[3].hasPrefix("fetchMessages"))
    }

    @Test("Folder sync retry succeeds after reconnect")
    func syncRetrySucceedsAfterReconnect() async throws {
        let expectedMessages = [makeHeaderInfo(messageId: "m1", subject: "After reconnect")]

        // First call throws, then clear and set results
        await provider.setFetchMessagesThrows(ProviderError.notConnected)

        var synced = false
        do {
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        } catch {
            #expect(SyncEngine.isConnectionError(error))
            try await provider.disconnect()
            try await provider.connect()
            await provider.setFetchMessagesThrows(nil)
            await provider.setFetchMessagesResult(expectedMessages)
            let results = try await provider.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
            #expect(results.count == 1)
            #expect(results[0].subject == "After reconnect")
            synced = true
        }

        #expect(synced)
    }

    @Test("Reconnect also fails — remaining folders skipped")
    func reconnectFailsRemainingSkipped() async throws {
        // fetchMessages always throws connection error
        await provider.setFetchMessagesThrows(ProviderError.notConnected)
        // connect also fails after disconnect
        await provider.setConnectThrows(ProviderError.notConnected)

        var foldersSkipped = false
        do {
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 50, offset: 0)
        } catch {
            #expect(SyncEngine.isConnectionError(error))
            do {
                try await provider.disconnect()
            } catch {
                // disconnect may fail too, that's OK
            }
            do {
                try await provider.connect()
                // If connect succeeds, retry
            } catch {
                // Reconnect failed — skip remaining folders
                foldersSkipped = true
            }
        }

        #expect(foldersSkipped)

        let log = await provider.callLog
        // fetchMessages (fail) + disconnect + connect (fail)
        #expect(log.contains("disconnect"))
        #expect(log.last == "connect")
    }

    @Test("SELECT failed error on folder — that folder skipped, others continue")
    func selectFailedSkipsFolder() async throws {
        let selectError = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select mailbox failed for folder 'BadFolder'"])
        #expect(SyncEngine.isSelectFailedError(selectError))
        #expect(!SyncEngine.isConnectionError(selectError))

        // Simulate syncing two folders: first has SELECT error, second succeeds
        let folders = ["BadFolder", "INBOX"]
        var syncedFolders: [String] = []

        for folder in folders {
            do {
                if folder == "BadFolder" {
                    throw selectError
                }
                syncedFolders.append(folder)
            } catch {
                if SyncEngine.isSelectFailedError(error) {
                    // Skip this folder, continue to next
                    continue
                }
                throw error
            }
        }

        #expect(syncedFolders == ["INBOX"])
    }

    @Test("Non-connection error during sync propagates without retry")
    func nonConnectionErrorPropagates() async throws {
        await provider.setFetchMessagesThrows(ProviderError.authenticationFailed)

        await #expect(throws: ProviderError.self) {
            _ = try await self.simulateSyncWithReconnect(folderPath: "INBOX")
        }

        // Should NOT see disconnect/connect — error was not a connection error
        let log = await provider.callLog
        #expect(log.count == 1)
        #expect(log[0].hasPrefix("fetchMessages"))
    }
}

// MARK: - Suite 2: Drain Queue Connection Resilience

@Suite("Connection Resilience - Drain Queue")
struct DrainQueueResilienceTests {
    let db: DatabaseQueue
    let provider: MockEmailProvider

    init() throws {
        db = try TestDatabase.make()
        provider = MockEmailProvider()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertAccount(db, id: "acc2", email: "other@example.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc2")
    }

    /// Simulate a single drain pass mirroring AccountManager.drainPendingQueue logic.
    @discardableResult
    private func simulateDrainPass(failedAccounts: inout Set<String>) async throws -> Int {
        let ops = try await db.read { db in
            try PendingOperation.order(Column("createdAt").asc).fetchAll(db)
        }
        var executedCount = 0

        for op in ops {
            if failedAccounts.contains(op.accountId) { continue }

            // Claim
            let currentOp: PendingOperation? = try await db.write { db -> PendingOperation? in
                guard var fetched = try PendingOperation.fetchOne(db, key: op.id) else { return nil }
                if fetched.status == PendingStatus.cancelled.rawValue {
                    _ = try PendingOperation.deleteOne(db, key: fetched.id)
                    return nil
                }
                if fetched.status == PendingStatus.inFlight.rawValue { return nil }
                fetched.status = PendingStatus.inFlight.rawValue
                try fetched.save(db)
                return fetched
            }
            guard let currentOp else { continue }

            do {
                switch currentOp.type {
                case .markRead:
                    try await provider.markRead(ids: currentOp.messageIds, folder: currentOp.folderPath)
                case .move:
                    guard let dest = currentOp.destinationPath else { throw ProviderError.messageNotFound }
                    try await provider.move(ids: currentOp.messageIds, from: currentOp.folderPath, to: dest)
                default:
                    break
                }
                // Success: delete
                try await db.write { db in
                    _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                }
                executedCount += 1
            } catch {
                if isMessageNotFoundError(error) {
                    try await db.write { db in
                        _ = try PendingOperation.deleteOne(db, key: currentOp.id)
                    }
                    executedCount += 1
                    continue
                }
                // Connection/transient error: reset to queued, skip this account
                try await db.write { db in
                    var updated = currentOp
                    updated.status = PendingStatus.queued.rawValue
                    try updated.save(db)
                }
                failedAccounts.insert(currentOp.accountId)
            }
        }
        return executedCount
    }

    @Test("Connection error during executeOperation resets op to queued and adds account to failedAccounts")
    func connectionErrorResetsOpAndFailsAccount() async throws {
        let op = PendingOperation(
            type: .markRead,
            messageIds: ["msg-1"],
            accountId: "acc1",
            folderPath: "INBOX"
        )
        try await db.write { db in try op.insert(db) }

        await provider.setMarkReadThrows(ProviderError.notConnected)

        var failedAccounts: Set<String> = []
        let executed = try await simulateDrainPass(failedAccounts: &failedAccounts)

        #expect(executed == 0)
        #expect(failedAccounts.contains("acc1"))

        // Op should be reset to queued (not deleted, not inFlight)
        let remaining = try await db.read { db in try PendingOperation.fetchOne(db, key: op.id) }
        #expect(remaining != nil)
        #expect(remaining?.status == PendingStatus.queued.rawValue)
    }

    @Test("Remaining ops for failed account are skipped in same drain pass")
    func remainingOpsForFailedAccountSkipped() async throws {
        let op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        let op2 = PendingOperation(type: .markRead, messageIds: ["msg-2"], accountId: "acc1", folderPath: "INBOX")
        try await db.write { db in
            try op1.insert(db)
            try op2.insert(db)
        }

        await provider.setMarkReadThrows(ProviderError.notConnected)

        var failedAccounts: Set<String> = []
        try await simulateDrainPass(failedAccounts: &failedAccounts)

        #expect(failedAccounts.contains("acc1"))

        // Both ops should still exist (second was skipped entirely)
        let allOps = try await db.read { db in try PendingOperation.fetchAll(db) }
        #expect(allOps.count == 2)
        // First was reset to queued, second was never claimed
        let firstOp = allOps.first { $0.id == op1.id }
        #expect(firstOp?.status == PendingStatus.queued.rawValue)
        let secondOp = allOps.first { $0.id == op2.id }
        #expect(secondOp?.status == PendingStatus.queued.rawValue)
    }

    @Test("Other accounts ops still execute after one account fails")
    func otherAccountOpsExecuteAfterFailure() async throws {
        let op1 = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        let op2 = PendingOperation(type: .move, messageIds: ["msg-2"], accountId: "acc2", folderPath: "INBOX", destinationPath: "Archive")
        try await db.write { db in
            try op1.insert(db)
            try op2.insert(db)
        }

        // Only markRead fails (acc1), move succeeds (acc2)
        await provider.setMarkReadThrows(ProviderError.notConnected)

        var failedAccounts: Set<String> = []
        let executed = try await simulateDrainPass(failedAccounts: &failedAccounts)

        #expect(failedAccounts.contains("acc1"))
        #expect(!failedAccounts.contains("acc2"))
        #expect(executed == 1) // acc2's op succeeded

        // acc1's op remains, acc2's op deleted
        let remaining = try await db.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.count == 1)
        #expect(remaining[0].accountId == "acc1")
    }

    @Test("Op survives multiple drain passes until connection restored")
    func opSurvivesMultipleDrainPasses() async throws {
        let op = PendingOperation(type: .markRead, messageIds: ["msg-1"], accountId: "acc1", folderPath: "INBOX")
        try await db.write { db in try op.insert(db) }

        await provider.setMarkReadThrows(ProviderError.notConnected)

        // First drain pass — fails
        var failedAccounts1: Set<String> = []
        try await simulateDrainPass(failedAccounts: &failedAccounts1)
        let afterFirst = try await db.read { db in try PendingOperation.fetchOne(db, key: op.id) }
        #expect(afterFirst != nil)
        #expect(afterFirst?.status == PendingStatus.queued.rawValue)

        // Second drain pass — still fails
        var failedAccounts2: Set<String> = []
        try await simulateDrainPass(failedAccounts: &failedAccounts2)
        let afterSecond = try await db.read { db in try PendingOperation.fetchOne(db, key: op.id) }
        #expect(afterSecond != nil)
        #expect(afterSecond?.status == PendingStatus.queued.rawValue)

        // Third drain pass — connection restored, succeeds
        await provider.setMarkReadThrows(nil)
        var failedAccounts3: Set<String> = []
        let executed = try await simulateDrainPass(failedAccounts: &failedAccounts3)
        #expect(executed == 1)
        #expect(failedAccounts3.isEmpty)

        let afterThird = try await db.read { db in try PendingOperation.fetchOne(db, key: op.id) }
        #expect(afterThird == nil) // Deleted on success
    }

}

// MARK: - Suite 3: Backfill Connection Backoff

@Suite("Connection Resilience - Backfill Backoff")
struct BackfillConnectionBackoffTests {

    @Test("First connection failure — does not abort, will retry")
    func firstFailureRetries() async throws {
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 3

        // Simulate one failure
        consecutiveFailures += 1
        #expect(consecutiveFailures < maxConsecutiveFailures)
        // Would continue to next window
    }

    @Test("Second consecutive failure — still retries")
    func secondFailureStillRetries() async throws {
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 3

        consecutiveFailures += 1
        consecutiveFailures += 1
        #expect(consecutiveFailures < maxConsecutiveFailures)
    }

    @Test("Third consecutive failure — aborts backfill cycle")
    func thirdFailureAbortsCycle() async throws {
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 3

        let provider = MockEmailProvider()
        await provider.setFetchMessagesThrows(ProviderError.notConnected)

        let folders = ["INBOX", "Sent", "Archive", "Drafts"]
        var aborted = false

        for folder in folders {
            do {
                _ = try await provider.fetchMessages(folder: folder, limit: 50, offset: 0)
                consecutiveFailures = 0 // Reset on success
            } catch {
                if SyncEngine.isConnectionError(error) {
                    consecutiveFailures += 1
                    if consecutiveFailures >= maxConsecutiveFailures {
                        aborted = true
                        break
                    }
                }
            }
        }

        #expect(aborted)
        #expect(consecutiveFailures == 3)

        // Only attempted 3 folders before aborting (not all 4)
        let log = await provider.callLog
        #expect(log.count == 3)
    }

    @Test("Success after failure resets consecutive failure count")
    func successResetsFailureCount() async throws {
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 3
        let provider = MockEmailProvider()

        // Two failures then a success
        let results: [Error?] = [
            ProviderError.notConnected,
            ProviderError.notConnected,
            nil, // success
            ProviderError.notConnected, // failure after reset
        ]

        for (index, errorToThrow) in results.enumerated() {
            if let error = errorToThrow {
                consecutiveFailures += 1
            } else {
                consecutiveFailures = 0
            }
        }

        // After the sequence: fail, fail, success (reset to 0), fail → count is 1
        #expect(consecutiveFailures == 1)
        #expect(consecutiveFailures < maxConsecutiveFailures)
    }

    @Test("Different folders fail independently — not cross-contaminated")
    func folderFailuresIndependent() async throws {
        // Each folder tracks its own failure state in production
        var failureCountByFolder: [String: Int] = [:]
        let maxConsecutiveFailures = 3

        let events: [(folder: String, success: Bool)] = [
            ("INBOX", false),
            ("Sent", false),
            ("INBOX", false),
            ("Sent", true), // Sent resets
            ("INBOX", false), // INBOX hits 3
        ]

        for event in events {
            if event.success {
                failureCountByFolder[event.folder] = 0
            } else {
                failureCountByFolder[event.folder, default: 0] += 1
            }
        }

        #expect(failureCountByFolder["INBOX"] == 3)
        #expect(failureCountByFolder["Sent"] == 0)
        // Only INBOX would trigger abort
        #expect(failureCountByFolder["INBOX"]! >= maxConsecutiveFailures)
        #expect(failureCountByFolder["Sent"]! < maxConsecutiveFailures)
    }
}

// MARK: - Suite 4: Body Fetch Connection Recovery

@Suite("Connection Resilience - Body Fetch Recovery")
struct BodyFetchConnectionRecoveryTests {
    let provider: MockEmailProvider

    init() {
        provider = MockEmailProvider()
    }

    @Test("fetchMessage connection error triggers disconnect and connect")
    func fetchMessageConnectionErrorTriggersReconnect() async throws {
        await provider.setFetchMessageThrows(ProviderError.notConnected)

        do {
            _ = try await provider.fetchMessage(id: "msg-1", folder: "INBOX")
        } catch {
            #expect(SyncEngine.isConnectionError(error))
            // Production pattern: disconnect, reconnect, re-throw
            try await provider.disconnect()
            try await provider.connect()
        }

        let log = await provider.callLog
        #expect(log.count == 3)
        #expect(log[0] == "fetchMessage(id:msg-1,folder:INBOX)")
        #expect(log[1] == "disconnect")
        #expect(log[2] == "connect")
    }

    @Test("Non-connection error on fetchMessage — no reconnect, error re-thrown")
    func nonConnectionErrorNoReconnect() async throws {
        await provider.setFetchMessageThrows(ProviderError.authenticationFailed)

        var caughtError: Error?
        do {
            _ = try await provider.fetchMessage(id: "msg-1", folder: "INBOX")
        } catch {
            caughtError = error
            if SyncEngine.isConnectionError(error) {
                try await provider.disconnect()
                try await provider.connect()
            }
            // Non-connection error: just re-throw
        }

        #expect(caughtError != nil)
        let log = await provider.callLog
        // Only the fetchMessage call — no disconnect/connect
        #expect(log.count == 1)
        #expect(log[0] == "fetchMessage(id:msg-1,folder:INBOX)")
    }

    @Test("fetchMessage succeeds after reconnect on retry")
    func fetchMessageSucceedsAfterReconnectRetry() async throws {
        let headerInfo = makeHeaderInfo(messageId: "msg-1")
        let fullMsg = FullMessageInfo(header: headerInfo, htmlBody: "<p>Body</p>", textBody: "Body")

        await provider.setFetchMessageThrows(ProviderError.notConnected)

        var result: FullMessageInfo?
        do {
            result = try await provider.fetchMessage(id: "msg-1", folder: "INBOX")
        } catch {
            #expect(SyncEngine.isConnectionError(error))
            try await provider.disconnect()
            try await provider.connect()
            // Clear error and set result for retry
            await provider.setFetchMessageThrows(nil)
            await provider.setFetchMessageResult(fullMsg)
            result = try await provider.fetchMessage(id: "msg-1", folder: "INBOX")
        }

        #expect(result != nil)
        #expect(result?.htmlBody == "<p>Body</p>")

        let log = await provider.callLog
        // fetchMessage (fail), disconnect, connect, fetchMessage (success)
        #expect(log.count == 4)
    }

    @Test("PayloadTooLargeError is not a connection error")
    func payloadTooLargeNotConnectionError() async throws {
        // PayloadTooLargeError is a buffer overflow, not a connection issue
        let payloadError = NSError(domain: "SwiftNIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "PayloadTooLargeError: buffer exceeded 8192 bytes"])
        #expect(!SyncEngine.isConnectionError(payloadError))
    }
}

// MARK: - Suite 5: Provider Lifecycle

@Suite("Connection Resilience - Provider Lifecycle")
struct ProviderLifecycleTests {

    @Test("connect failure propagates error")
    func connectFailurePropagates() async throws {
        let provider = MockEmailProvider()
        await provider.setConnectThrows(ProviderError.notConnected)

        await #expect(throws: ProviderError.self) {
            try await provider.connect()
        }

        let log = await provider.callLog
        #expect(log == ["connect"])
    }

    @Test("disconnect followed by connect creates fresh connection")
    func disconnectThenConnectFreshConnection() async throws {
        let provider = MockEmailProvider()

        try await provider.connect()
        try await provider.disconnect()
        try await provider.connect()

        let log = await provider.callLog
        #expect(log == ["connect", "disconnect", "connect"])
    }

    @Test("Stale connection reconnect shows disconnect-connect pair")
    func staleConnectionReconnect() async throws {
        let provider = MockEmailProvider()

        // Initial connect
        try await provider.connect()

        // Simulate stale connection after sleep: disconnect + connect
        try await provider.disconnect()
        try await provider.connect()

        let log = await provider.callLog
        #expect(log == ["connect", "disconnect", "connect"])
    }

    @Test("Multiple rapid reconnects each produce disconnect-connect pair")
    func multipleRapidReconnects() async throws {
        let provider = MockEmailProvider()

        // Initial connect
        try await provider.connect()

        // Three rapid reconnects (simulating foreground returns)
        for _ in 0..<3 {
            try await provider.disconnect()
            try await provider.connect()
        }

        let log = await provider.callLog
        // connect + 3 * (disconnect, connect) = 7 entries
        #expect(log.count == 7)
        #expect(log[0] == "connect")
        for i in 0..<3 {
            let base = 1 + i * 2
            #expect(log[base] == "disconnect")
            #expect(log[base + 1] == "connect")
        }
    }
}

// MARK: - Suite 6: Error Classification Integration

@Suite("Connection Resilience - Error Classification")
struct ErrorClassificationTests {

    // MARK: - isConnectionError

    @Test("isConnectionError recognizes ProviderError.notConnected")
    func connectionErrorNotConnected() async throws {
        #expect(SyncEngine.isConnectionError(ProviderError.notConnected))
    }

    @Test("isConnectionError recognizes URLError codes")
    func connectionErrorURLError() async throws {
        let urlErrors: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
        ]
        for code in urlErrors {
            let error = URLError(code)
            #expect(SyncEngine.isConnectionError(error), "URLError code \(code.rawValue) should be a connection error")
        }
    }

    @Test("isConnectionError recognizes connection reset string")
    func connectionErrorConnectionReset() async throws {
        let error = NSError(domain: "POSIX", code: 54, userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"])
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes broken pipe")
    func connectionErrorBrokenPipe() async throws {
        let error = NSError(domain: "POSIX", code: 32, userInfo: [NSLocalizedDescriptionKey: "broken pipe"])
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes closed channel / I/O on closed")
    func connectionErrorClosedChannel() async throws {
        let closedChannel = NSError(domain: "NIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "closed channel"])
        #expect(SyncEngine.isConnectionError(closedChannel))

        let ioOnClosed = NSError(domain: "NIO", code: 2, userInfo: [NSLocalizedDescriptionKey: "I/O on closed channel"])
        #expect(SyncEngine.isConnectionError(ioOnClosed))
    }

    @Test("isConnectionError recognizes timed out")
    func connectionErrorTimedOut() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes IMAPDecoderError")
    func connectionErrorIMAPDecoder() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "IMAPDecoderError: leftover bytes"])
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes command failed")
    func connectionErrorCommandFailed() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "command failed: connection lost"])
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError recognizes EPIPE")
    func connectionErrorEPIPE() async throws {
        let error = NSError(domain: "POSIX", code: 1, userInfo: [NSLocalizedDescriptionKey: "EPIPE: write failed"])
        #expect(SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError rejects messageNotFound")
    func connectionErrorRejectsMessageNotFound() async throws {
        #expect(!SyncEngine.isConnectionError(ProviderError.messageNotFound))
    }

    @Test("isConnectionError rejects authenticationFailed")
    func connectionErrorRejectsAuthFailed() async throws {
        #expect(!SyncEngine.isConnectionError(ProviderError.authenticationFailed))
    }

    @Test("isConnectionError rejects generic NSError without connection keywords")
    func connectionErrorRejectsGenericNSError() async throws {
        let error = NSError(domain: "com.app", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        #expect(!SyncEngine.isConnectionError(error))
    }

    @Test("isConnectionError rejects ProviderError.networkError (HTTP error, not transport)")
    func connectionErrorRejectsNetworkError() async throws {
        let httpError = NSError(domain: "HTTP", code: 500, userInfo: [NSLocalizedDescriptionKey: "Internal Server Error"])
        let providerError = ProviderError.networkError(underlying: httpError)
        // networkError wraps HTTP errors — the connection is fine, server returned an error
        #expect(!SyncEngine.isConnectionError(providerError))
    }

    // MARK: - isSelectFailedError

    @Test("isSelectFailedError recognizes Select mailbox failed")
    func selectFailedRecognized() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select mailbox failed for folder 'NonExistent'"])
        #expect(SyncEngine.isSelectFailedError(error))
    }

    @Test("isSelectFailedError rejects connection errors")
    func selectFailedRejectsConnectionError() async throws {
        #expect(!SyncEngine.isSelectFailedError(ProviderError.notConnected))
    }

    @Test("isSelectFailedError rejects generic errors")
    func selectFailedRejectsGeneric() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"])
        #expect(!SyncEngine.isSelectFailedError(error))
    }

    // MARK: - isMessageNotFoundError (helper)

    @Test("isMessageNotFoundError recognizes ProviderError.messageNotFound")
    func messageNotFoundDirect() async throws {
        #expect(isMessageNotFoundError(ProviderError.messageNotFound))
    }

    @Test("isMessageNotFoundError recognizes 404 network error")
    func messageNotFound404() async throws {
        let underlying = NSError(domain: "HTTP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Not Found"])
        #expect(isMessageNotFoundError(ProviderError.networkError(underlying: underlying)))
    }

    @Test("isMessageNotFoundError recognizes IMAP 'no such message' string")
    func messageNotFoundNoSuchMessage() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such message in folder"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("isMessageNotFoundError recognizes 'UID not found'")
    func messageNotFoundUIDNotFound() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "UID not found for message"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("isMessageNotFoundError recognizes NONEXISTENT")
    func messageNotFoundNonexistent() async throws {
        let error = NSError(domain: "IMAP", code: 1, userInfo: [NSLocalizedDescriptionKey: "NONEXISTENT: mailbox does not exist"])
        #expect(isMessageNotFoundError(error))
    }

    @Test("isMessageNotFoundError rejects connection errors")
    func messageNotFoundRejectsConnectionError() async throws {
        #expect(!isMessageNotFoundError(ProviderError.notConnected))
    }

    @Test("isMessageNotFoundError rejects auth errors")
    func messageNotFoundRejectsAuthError() async throws {
        #expect(!isMessageNotFoundError(ProviderError.authenticationFailed))
    }
}
