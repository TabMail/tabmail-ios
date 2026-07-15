/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("AccountManager.applyManualTag — real path", .serialized, .processGlobalState)
struct ApplyManualTagTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let inbox: Folder
    }

    private func makeFixture(accountEmail: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }

        let accountId = "apply-manual-tag-\(UUID().uuidString)"
        var account = Account(
            emailAddress: accountEmail,
            displayName: "Test",
            provider: .gmail
        )
        account.id = accountId
        let inbox = Folder(
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            accountId: accountId
        )
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
        }
        return Fixture(
            pool: pool,
            directory: directory,
            previous: previous,
            accountId: accountId,
            inbox: inbox
        )
    }

    private func restore(_ fixture: Fixture) {
        // applyManualTag starts an unstructured cache/refinement task. Retain
        // the test DB when the host had no prior AppDatabase so a trailing
        // actor turn cannot dereference a closed/nil process database.
        guard fixture.previous != nil else { return }
        AppDatabase.shared.withLock { $0 = fixture.previous }
        try? fixture.pool.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func makeHeader(
        fixture: Fixture,
        fromAddress: String,
        actionTag: ActionTag? = nil,
        rfc822MessageId: String? = nil
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: "message-\(UUID().uuidString)",
            subject: "Test subject",
            from: "Sender",
            fromAddress: fromAddress,
            to: "recipient@example.com",
            date: Date(),
            snippet: "Test snippet",
            folderId: fixture.inbox.id,
            accountId: fixture.accountId,
            folderPath: fixture.inbox.path,
            isInInbox: true
        )
        header.rfc822MessageId = rfc822MessageId
        header.actionTag = actionTag
        header.tagSortOrder = actionTag?.sortOrder ?? 99
        try fixture.pool.writeWithoutTransaction { try header.insert($0) }
        return header
    }

    @Test("self-sent rejection is case-insensitive and stops every write step")
    func selfSentCaseInsensitiveRejectionUsesProductionGuard() async throws {
        let fixture = try makeFixture(accountEmail: "User@Example.COM")
        defer { restore(fixture) }
        let header = try makeHeader(
            fixture: fixture,
            fromAddress: "user@example.com",
            rfc822MessageId: "<self-sent@example.com>"
        )

        await AccountManager.shared.applyManualTag(header, tag: .reply)

        let stored = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(stored?.actionTag == nil)
        #expect(stored?.tagSortOrder == 99)
        let operations = try await fixture.pool.read { try PendingOperation.fetchAll($0) }
        #expect(operations.isEmpty)
        let cacheRows = try await fixture.pool.read { try MessageAICache.fetchAll($0) }
        #expect(cacheRows.isEmpty)
    }

    @Test("non-self manual tag stays local: header/cache update, no durable provider operation")
    func persistentCacheWriteThroughUsesProductionPath() async throws {
        let fixture = try makeFixture(accountEmail: "recipient@example.com")
        defer { restore(fixture) }
        let rfc822MessageId = "<manual-tag-cache@example.com>"
        let header = try makeHeader(
            fixture: fixture,
            fromAddress: "sender@example.com",
            actionTag: .archive,
            rfc822MessageId: rfc822MessageId
        )

        // The tag is intentionally unchanged: Step 3 still writes the cache,
        // while Step 4 correctly skips its unrelated action-refinement job.
        await AccountManager.shared.applyManualTag(header, tag: .archive)

        let cacheKey = try #require(MessageAICache.cacheKey(
            accountId: fixture.accountId,
            folderPath: fixture.inbox.path,
            rfc822MessageId: rfc822MessageId
        ))
        _ = try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            while true {
                if try await fixture.pool.read({ db in
                    try MessageAICache.fetchOne(db, key: cacheKey) != nil
                }) {
                    return true
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(SyncConfig.backgroundFlushDrainPollSeconds))
            }
        }
        let cache = try await fixture.pool.read { db in
            try MessageAICache.fetchOne(db, key: cacheKey)
        }
        #expect(cache?.actionTag == .archive)

        let operations = try await fixture.pool.read { try PendingOperation.fetchAll($0) }
        #expect(operations.isEmpty, "manual action tags are local-only and must not enter the durable provider queue")

        let refinements = try await fixture.pool.read { try PendingAIRefinement.fetchAll($0) }
        #expect(refinements.isEmpty)
    }

    @Test("manual tag SET stamps actionTagSetAt; clearing it back to nil nils the stamp (Round D-0b)")
    func manualTagStampsAndClearsActionTagSetAt() async throws {
        let fixture = try makeFixture(accountEmail: "recipient@example.com")
        defer { restore(fixture) }
        let header = try makeHeader(
            fixture: fixture,
            fromAddress: "sender@example.com",
            actionTag: nil,
            rfc822MessageId: "<manual-tag-stamp@example.com>"
        )

        let before = Date()
        await AccountManager.shared.applyManualTag(header, tag: .archive)

        let stamped = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(stamped?.actionTag == .archive)
        let setAt = try #require(stamped?.actionTagSetAt)
        #expect(setAt >= before)

        // Clearing the tag must nil the stamp right back out with it.
        await AccountManager.shared.applyManualTag(try #require(stamped), tag: nil)
        let cleared = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(cleared?.actionTag == nil)
        #expect(cleared?.actionTagSetAt == nil)
    }

    @Test("clearing a manual tag stays local and queues no removeTag operation")
    func clearingTagStaysLocal() async throws {
        let fixture = try makeFixture(accountEmail: "recipient@example.com")
        defer { restore(fixture) }
        let header = try makeHeader(
            fixture: fixture,
            fromAddress: "sender@example.com",
            actionTag: .archive,
            rfc822MessageId: "<manual-tag-remove@example.com>"
        )

        await AccountManager.shared.applyManualTag(header, tag: nil)

        let cacheKey = try #require(MessageAICache.cacheKey(
            accountId: fixture.accountId,
            folderPath: fixture.inbox.path,
            rfc822MessageId: header.rfc822MessageId
        ))
        _ = try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            while true {
                if try await fixture.pool.read({ db in
                    try MessageAICache.fetchOne(db, key: cacheKey) != nil
                }) {
                    return true
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(SyncConfig.backgroundFlushDrainPollSeconds))
            }
        }
        let stored = try await fixture.pool.read { db in
            try MessageHeader.fetchOne(db, key: header.id)
        }
        #expect(stored?.actionTag == nil)
        #expect(stored?.tagSortOrder == 99)

        let operations = try await fixture.pool.read { try PendingOperation.fetchAll($0) }
        #expect(operations.isEmpty, "clearing a local action tag must not enter the durable provider queue")
    }

    @Test("Local-only wiring: manual/AI/sync/outbox/NSE admit no durable action-tag jobs")
    func allProductionActionTagWritersStayLocal() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let productionSites: [(category: String, paths: [String])] = [
            ("manual and direct AI", [
                "TabMail/Services/Account/AccountManagerAI.swift",
                "TabMail/Services/AI/ActiveAIQueue.swift",
                "TabMail/Services/Account/AccountManagerQueue.swift",
            ]),
            ("sync reply detection", [
                "TabMail/Services/Sync/ReplyParentResolver.swift",
                "TabMail/Services/Sync/SyncEngine.swift",
                "TabMail/Services/Sync/SyncEngineBackfillDeep.swift",
                "TabMail/Services/Sync/SyncEngineDeltaSync.swift",
                "TabMail/Services/Sync/SyncEngineFullSync.swift",
            ]),
            ("outbox", ["TabMail/Services/Account/AccountManagerOutbox.swift"]),
            ("NSE merge", ["TabMail/Services/NSEDataBridge.swift"]),
        ]
        let forbiddenAdmissions = [
            "queueTagWrite(",
            "queueSetTagPendingOp(",
            "type: .setTag",
            "type: .removeTag",
            "VALUES (?, 'setTag'",
            "VALUES (?, 'removeTag'",
        ]

        for site in productionSites {
            for relativePath in site.paths {
                let path = projectRoot.appendingPathComponent(relativePath)
                let source: String
                do {
                    source = try String(contentsOf: path, encoding: .utf8)
                } catch {
                    Issue.record("Cannot audit \(relativePath); update the local-only wiring contract if the file moved: \(error)")
                    continue
                }
                let normalized = source.replacingOccurrences(
                    of: "\\s+", with: " ", options: .regularExpression
                )
                for forbidden in forbiddenAdmissions {
                    #expect(
                        !normalized.contains(forbidden),
                        "\(site.category) must keep action tags local-only; \(relativePath) contains durable admission pattern \(forbidden)"
                    )
                }
            }
        }
    }
}
