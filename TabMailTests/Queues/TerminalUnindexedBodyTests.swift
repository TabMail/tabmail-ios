/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("Terminal-unindexed body state", .serialized, .processGlobalState)
struct TerminalUnindexedBodyTests {
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
            reason: .partialFetchUnsupported
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
            reason: .partialFetchUnsupported
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
            reason: .partialFetchUnsupported
        )))

        let stored = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: headerId)
        }
        #expect(stored?.bodyComplete == true)
        #expect(stored?.bodyIndexingFailureReason == nil)
    }
}
