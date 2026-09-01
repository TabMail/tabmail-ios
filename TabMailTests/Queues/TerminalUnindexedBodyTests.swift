/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("Terminal-unindexed body state", .serialized, .processGlobalState)
struct TerminalUnindexedBodyTests {
    private func bodyHeader(
        messageId: String,
        folderId: String,
        folderPath: String,
        isInInbox: Bool,
        subject: String
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: folderId,
            accountId: "terminal-account",
            folderPath: folderPath,
            isInInbox: isInInbox
        )
        header.headerComplete = true
        header.observedUidValidity = 7
        return header
    }

    private func makeSwappedDatabase() throws -> (
        header: MessageHeader,
        pool: DatabasePool,
        restore: () -> Void
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("terminal.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }

        var account = Account(
            emailAddress: "terminal@example.com",
            displayName: "Terminal",
            provider: .imap
        )
        account.id = "terminal-account"
        var folder = Folder(
            name: "Archive",
            path: "Archive",
            role: .archive,
            accountId: account.id
        )
        folder.lastKnownUidValidity = 7
        folder.backfillComplete = true
        var header = MessageHeader(
            messageId: "42",
            subject: "Bounded fetch unsupported",
            from: "sender@example.com",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "",
            folderId: folder.id,
            accountId: account.id,
            folderPath: folder.path,
            isInInbox: false
        )
        header.headerComplete = true
        header.observedUidValidity = folder.lastKnownUidValidity
        try pool.write { db in
            try account.insert(db)
            try folder.insert(db)
            try header.insert(db)
        }

        let restore = {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: directory)
        }
        return (header, pool, restore)
    }

    @Test("Protocol refusal retires automatic work without claiming empty or indexed")
    func terminalStateIsTruthfulAndExcludedFromQueues() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let header = fixture.header
        let headerId = header.id
        let pool = fixture.pool
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )

        #expect(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: 7,
            fetchedRfc822MessageId: nil
        ))

        let state = try await pool.read { db in
            let row = try MessageHeader.fetchOne(db, key: headerId)
            let candidates = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messageHeader
                WHERE headerComplete = 1
                  AND bodyComplete = 0
                  AND bodyEmptyConfirmed = 0
                  AND bodyIndexingFailureReason IS NULL
                """) ?? 0
            return (row, candidates)
        }
        let stored = try #require(state.0)
        #expect(stored.bodyComplete == false)
        #expect(stored.bodyEmptyConfirmed == false)
        #expect(stored.bodyIndexingFailureReason
                == BodyIndexingFailureReason.partialFetchUnsupported.rawValue)
        #expect(state.1 == 0)
    }

    @Test("Terminal rows stay excluded after queue restart and progress recomputation")
    func terminalStateConvergesAcrossRestartAndProgress() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let header = fixture.header
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )
        #expect(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: 7,
            fetchedRfc822MessageId: nil
        ))

        // Exercise both production restart selectors with the same terminal
        // row in their respective populations. If either drops its terminal
        // predicate, repopulation leaves storage non-empty immediately.
        try await fixture.pool.write { database in
            try database.execute(
                sql: "UPDATE messageHeader SET isInInbox = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }
        let activeQueue = ActiveBodyQueue()
        await activeQueue.repopulateFromDatabase()
        #expect(await activeQueue.isIdle)

        try await fixture.pool.write { database in
            try database.execute(
                sql: "UPDATE messageHeader SET isInInbox = 0 WHERE id = ?",
                arguments: [header.id]
            )
        }
        let backfillQueue = BackfillBodyQueue()
        await backfillQueue.repopulateFromDatabase()
        #expect(await backfillQueue.isIdle)

        let storedAccount = try await fixture.pool.read { database in
            try Account.fetchOne(database, key: header.accountId)
        }
        let account = try #require(storedAccount)
        let engine = SyncEngine()
        await engine.updateBackfillProgressForAccount(account)
        let progress = await MainActor.run {
            AccountManagerState.shared.backfillProgressByAccount[header.accountId]
        }
        #expect(progress?.pendingBodyCount == 0)
        #expect(progress?.unindexedBodyCount == 1)
        #expect(progress?.isFullyComplete == true)
        await MainActor.run {
            AccountManagerState.shared.backfillProgressByAccount[header.accountId] = nil
        }
    }

    @Test("Smart Reindex clears the terminal reason for a fresh attempt")
    func smartReindexRestoresRetryability() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let header = fixture.header
        let headerId = header.id
        let pool = fixture.pool
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )
        #expect(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: 7,
            fetchedRfc822MessageId: nil
        ))

        let engine = SyncEngine()
        await engine.resetCrawlState()

        let stored = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }
        #expect(stored?.bodyIndexingFailureReason == nil)
        #expect(stored?.bodyComplete == false)
        #expect(stored?.bodyEmptyConfirmed == false)
    }

    @Test("A stale failure cannot overwrite a concurrently completed body")
    func completedBodyWinsTerminalizationRace() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let header = fixture.header
        let headerId = header.id
        let pool = fixture.pool
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 1 WHERE id = ?",
                arguments: [headerId]
            )
        }
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )

        #expect(!(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: 7,
            fetchedRfc822MessageId: nil
        )))

        let stored = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }
        #expect(stored?.bodyComplete == true)
        #expect(stored?.bodyIndexingFailureReason == nil)
    }

    @Test("A failure observed after UIDVALIDITY turnover cannot retire the old row")
    func epochTurnoverRefusesTerminalization() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let header = fixture.header
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )

        #expect(!(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: 8,
            fetchedRfc822MessageId: nil
        )))

        let stored = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(stored?.bodyIndexingFailureReason == nil)
    }

    @Test("A matching Message-ID cannot override contradictory UIDVALIDITY evidence")
    func epochContradictionOutranksMatchingMessageIdentity() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        var updatedHeader = fixture.header
        updatedHeader.rfc822MessageId = "stable@example.com"
        let header = updatedHeader
        try await fixture.pool.write { database in try header.update(database) }
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )

        #expect(!(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: 8,
            fetchedRfc822MessageId: "stable@example.com"
        )))

        let stored = try await fixture.pool.read { database in
            try MessageHeader.fetchOne(database, key: header.id)
        }
        #expect(stored?.bodyIndexingFailureReason == nil)
    }

    @Test("Matching fetched Message-ID proves identity when SELECT omits UIDVALIDITY")
    func messageIdentityCanProveTerminalization() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        var updatedHeader = fixture.header
        updatedHeader.rfc822MessageId = "<stable@example.com>"
        let header = updatedHeader
        try await fixture.pool.write { db in try header.update(db) }
        let item = BodyFetchProcessor.Item(
            headerId: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            isInInbox: false
        )

        #expect(await BodyFetchProcessor.markBodyUnindexed(
            item: item,
            reason: .partialFetchUnsupported,
            observedUidValidity: nil,
            fetchedRfc822MessageId: "stable@example.com"
        ))
    }

    @Test("Stuck diagnostics separate runnable and terminal bodyless rows")
    func diagnosticsClassifyBodyStatesWithoutOverlap() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let id = fixture.header.id

        var counts = await StuckMessageDiagnostics.bodyStatusCounts(in: fixture.pool)
        #expect(counts == .init(lockedEmpty: 0, failing: 0, pending: 1, terminalUnindexed: 0))

        try await fixture.pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET emptyFetchCount = 2 WHERE id = ?",
                arguments: [id]
            )
        }
        counts = await StuckMessageDiagnostics.bodyStatusCounts(in: fixture.pool)
        #expect(counts == .init(lockedEmpty: 0, failing: 1, pending: 0, terminalUnindexed: 0))

        try await fixture.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET emptyFetchCount = 0, bodyIndexingFailureReason = ?
                    WHERE id = ?
                    """,
                arguments: [BodyIndexingFailureReason.partialFetchUnsupported.rawValue, id]
            )
        }
        counts = await StuckMessageDiagnostics.bodyStatusCounts(in: fixture.pool)
        #expect(counts == .init(lockedEmpty: 0, failing: 0, pending: 0, terminalUnindexed: 1))
        #expect(counts.runnable == 0)
    }

    @Test("Active inbox queue converges after a bounded-fetch refusal")
    func activeQueueConvergesAndLeavesSiblingRetryable() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let target = bodyHeader(
            messageId: "42", folderId: "terminal-account:INBOX",
            folderPath: "INBOX", isInInbox: true,
            subject: "Bounded fetch unsupported"
        )
        let sibling = bodyHeader(
            messageId: "43", folderId: "terminal-account:INBOX",
            folderPath: "INBOX", isInInbox: true,
            subject: "Retryable sibling"
        )
        let originalHeaderId = fixture.header.id
        try await fixture.pool.write { db in
            var inbox = Folder(
                name: "INBOX", path: "INBOX", role: .inbox,
                accountId: target.accountId
            )
            inbox.lastKnownUidValidity = 7
            try inbox.insert(db)
            _ = try MessageHeader.deleteOne(db, key: originalHeaderId)
            try target.insert(db)
            try sibling.insert(db)
        }

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessageThrows(ProviderError.bodyIndexingUnsupported(
            messageId: target.messageId,
            observedUidValidity: 7,
            fetchedRfc822MessageId: nil
        ))
        await AccountManager.shared.registerProviderForTesting(
            accountId: target.accountId, provider: provider
        )
        let queue = ActiveBodyQueue()
        await queue.enqueueBatch([target, sibling])
        await queue.awaitDrain()
        await AccountManager.shared.unregisterProviderForTesting(accountId: target.accountId)

        let state = try await fixture.pool.read { db in
            (
                try MessageHeader.fetchOne(db, key: target.id),
                try MessageHeader.fetchOne(db, key: sibling.id)
            )
        }
        #expect(state.0?.bodyIndexingFailureReason
                == BodyIndexingFailureReason.partialFetchUnsupported.rawValue)
        #expect(state.1?.bodyIndexingFailureReason == nil)
        #expect(state.1?.bodyComplete == false)
        #expect(await queue.isIdle)
    }

    @Test("Backfill non-inbox queue converges after a bounded-fetch refusal")
    func backfillQueueConvergesAndLeavesSiblingRetryable() async throws {
        let fixture = try makeSwappedDatabase()
        defer { fixture.restore() }
        let target = fixture.header
        let sibling = bodyHeader(
            messageId: "43", folderId: target.folderId,
            folderPath: target.folderPath, isInInbox: false,
            subject: "Retryable sibling"
        )
        try await fixture.pool.write { db in try sibling.insert(db) }

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessageThrows(ProviderError.bodyIndexingUnsupported(
            messageId: target.messageId,
            observedUidValidity: 7,
            fetchedRfc822MessageId: nil
        ))
        await AccountManager.shared.registerProviderForTesting(
            accountId: target.accountId, provider: provider
        )
        let queue = BackfillBodyQueue()
        await queue.enqueue([
            .init(
                headerId: target.id, accountId: target.accountId,
                folderPath: target.folderPath, messageId: target.messageId,
                isInInbox: false
            ),
            .init(
                headerId: sibling.id, accountId: sibling.accountId,
                folderPath: sibling.folderPath, messageId: sibling.messageId,
                isInInbox: false
            ),
        ])
        await queue.awaitDrain()
        await AccountManager.shared.unregisterProviderForTesting(accountId: target.accountId)

        let state = try await fixture.pool.read { db in
            (
                try MessageHeader.fetchOne(db, key: target.id),
                try MessageHeader.fetchOne(db, key: sibling.id)
            )
        }
        #expect(state.0?.bodyIndexingFailureReason
                == BodyIndexingFailureReason.partialFetchUnsupported.rawValue)
        #expect(state.1?.bodyIndexingFailureReason == nil)
        #expect(state.1?.bodyComplete == false)
        #expect(await queue.isIdle)
    }
}
