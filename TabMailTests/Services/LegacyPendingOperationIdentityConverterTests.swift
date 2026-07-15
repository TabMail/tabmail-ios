/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite(
    "Released PendingOperation identity conversion",
    .serialized,
    .processGlobalState
)
struct LegacyPendingOperationIdentityConverterTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previousDatabase: AppDatabase?
    }

    private struct StoredOperation {
        let rowId: Int64
        let operation: PendingOperation
        let uidResolutionRetryCount: Int
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
        let database = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current in
            let previous = current
            current = database
            return previous
        }
        return Fixture(
            pool: pool,
            directory: directory,
            previousDatabase: previousDatabase
        )
    }

    private func restore(_ fixture: Fixture) {
        AppDatabase.shared.withLock { $0 = fixture.previousDatabase }
        try? fixture.pool.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func insertAccountAndFolders(
        db: Database,
        accountId: String,
        provider: AccountProvider
    ) throws {
        var account = Account(
            emailAddress: "user@example.com",
            displayName: "User",
            provider: provider
        )
        account.id = accountId
        try account.insert(db)
        try Folder(
            name: "Inbox",
            path: "INBOX",
            role: .inbox,
            accountId: accountId
        ).insert(db)
        try Folder(
            name: "Archive",
            path: "Archive",
            role: .archive,
            accountId: accountId
        ).insert(db)
    }

    private func insertHeader(
        db: Database,
        accountId: String,
        folderPath: String,
        providerMessageId: String,
        rfc822MessageId: String?
    ) throws {
        var header = MessageHeader(
            messageId: providerMessageId,
            subject: "Identity conversion",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "user@example.com",
            date: Date(),
            snippet: "Identity conversion",
            folderId: "\(accountId):\(folderPath)",
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        header.rfc822MessageId = rfc822MessageId
        try header.insert(db)
    }

    private func storedOperation(
        id: String,
        pool: DatabasePool
    ) throws -> StoredOperation? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT rowid AS storedRowId, * FROM pendingOperation WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return StoredOperation(
                rowId: row["storedRowId"],
                operation: try PendingOperation(row: row),
                uidResolutionRetryCount: row["uidResolutionRetryCount"]
            )
        }
    }

    private func withRegisteredProvider(
        accountId: String,
        provider: MockEmailProvider,
        operation: () async throws -> Void
    ) async throws {
        await AccountManager.shared.registerProviderForTesting(
            accountId: accountId,
            provider: provider
        )
        do {
            try await operation()
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }
    }

    @Test("one atomic conversion preserves rowid, FIFO fields, member order, and non-message resources")
    func conversionPreservesSemanticPayloadAndMemberOrder() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-main-\(UUID().uuidString)"

        var operation = PendingOperation(
            type: .move,
            messageIds: [
                "local-resource",
                "<already@example.com>",
                "remote-resource",
                "stale-resource",
                "local-resource",
            ],
            accountId: accountId,
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        operation.id = "legacy-main-\(UUID().uuidString)"
        operation.createdAt = Date().addingTimeInterval(-120)
        operation.retryCount = 2
        operation.status = PendingStatus.inFlight.rawValue
        let operationToInsert = operation
        let canonical = PendingOperation(
            type: .markRead,
            messageIds: ["canonical@example.com"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        let draft = PendingOperation(
            type: .saveDraft,
            messageIds: ["opaque-draft-resource"],
            accountId: accountId,
            folderPath: "Drafts"
        )
        let userLabel = PendingOperation(
            type: .addUserLabel,
            messageIds: ["label-resource"],
            accountId: accountId,
            folderPath: "INBOX",
            userLabelId: "remote-label-1"
        )

        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try insertHeader(
                db: db,
                accountId: accountId,
                folderPath: "INBOX",
                providerMessageId: "local-resource",
                rfc822MessageId: "<Local+Case@Example.COM>"
            )
            try insertHeader(
                db: db,
                accountId: accountId,
                folderPath: "Archive",
                providerMessageId: "local-resource",
                rfc822MessageId: "Local+Case@Example.COM"
            )
            try insertHeader(
                db: db,
                accountId: accountId,
                folderPath: "INBOX",
                providerMessageId: "label-resource",
                rfc822MessageId: "label@example.com"
            )
            try operationToInsert.insert(db)
            try canonical.insert(db)
            try draft.insert(db)
            try userLabel.insert(db)
            try db.execute(
                sql: "UPDATE pendingOperation SET uidResolutionRetryCount = ? WHERE id = ?",
                arguments: [7, operationToInsert.id]
            )
        }
        let before = try #require(try storedOperation(id: operation.id, pool: fixture.pool))
        let canonicalBefore = try #require(
            try storedOperation(id: canonical.id, pool: fixture.pool)
        )
        let draftBefore = try #require(try storedOperation(id: draft.id, pool: fixture.pool))
        let userLabelBefore = try #require(
            try storedOperation(id: userLabel.id, pool: fixture.pool)
        )

        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.setLegacyIdentityResolution(
            providerMessageId: "remote-resource",
            result: .resolved(rfc822MessageId: "<Remote@Example.COM>")
        )
        await provider.setLegacyIdentityResolution(
            providerMessageId: "stale-resource",
            result: .staleOrAmbiguous
        )

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await AccountManager.shared.convertReleasedMessageActionIdentities()
        }

        let after = try #require(try storedOperation(id: operation.id, pool: fixture.pool))
        #expect(after.rowId == before.rowId)
        #expect(after.operation.messageIds == [
            "Local+Case@Example.COM",
            "already@example.com",
            "Remote@Example.COM",
            "Local+Case@Example.COM",
        ])
        #expect(after.operation.id == before.operation.id)
        #expect(after.operation.type == before.operation.type)
        #expect(after.operation.accountId == before.operation.accountId)
        #expect(after.operation.folderPath == before.operation.folderPath)
        #expect(after.operation.destinationPath == before.operation.destinationPath)
        #expect(after.operation.createdAt == before.operation.createdAt)
        #expect(after.operation.retryCount == before.operation.retryCount)
        #expect(after.operation.status == before.operation.status)
        #expect(after.uidResolutionRetryCount == before.uidResolutionRetryCount)
        #expect(after.uidResolutionRetryCount == 7)

        let canonicalAfter = try #require(
            try storedOperation(id: canonical.id, pool: fixture.pool)
        )
        #expect(canonicalAfter.rowId == canonicalBefore.rowId)
        #expect(canonicalAfter.operation.messageIdsJSON == canonicalBefore.operation.messageIdsJSON)
        let draftAfter = try #require(try storedOperation(id: draft.id, pool: fixture.pool))
        #expect(draftAfter.rowId == draftBefore.rowId)
        #expect(draftAfter.operation.messageIdsJSON == draftBefore.operation.messageIdsJSON)
        let userLabelAfter = try #require(
            try storedOperation(id: userLabel.id, pool: fixture.pool)
        )
        #expect(userLabelAfter.rowId == userLabelBefore.rowId)
        #expect(userLabelAfter.operation.messageIds == ["label@example.com"])
        #expect(userLabelAfter.operation.userLabelId == userLabelBefore.operation.userLabelId)
        #expect(userLabelAfter.operation.userLabelId == "remote-label-1")

        let calls = await provider.legacyIdentityResolutionCalls
        #expect(calls.map(\.providerMessageId) == ["remote-resource", "stale-resource"])
    }

    @Test("a later provider uncertainty leaves every released row byte-for-byte unchanged")
    func providerUncertaintyRollsBackEveryRow() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-uncertain-\(UUID().uuidString)"
        let first = PendingOperation(
            type: .markRead,
            messageIds: ["first-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        let second = PendingOperation(
            type: .markFlagged,
            messageIds: ["second-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .outlook)
            try first.insert(db)
            try second.insert(db)
        }
        let beforeFirst = try #require(try storedOperation(id: first.id, pool: fixture.pool))
        let beforeSecond = try #require(try storedOperation(id: second.id, pool: fixture.pool))

        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.setLegacyIdentityResolution(
            providerMessageId: "first-resource",
            result: .resolved(rfc822MessageId: "first@example.com")
        )
        await provider.setLegacyIdentityResolutionError(
            providerMessageId: "second-resource",
            error: ProviderError.notConnected
        )

        await #expect(throws: (any Error).self) {
            try await self.withRegisteredProvider(accountId: accountId, provider: provider) {
                try await AccountManager.shared.convertReleasedMessageActionIdentities()
            }
        }

        let afterFirst = try #require(try storedOperation(id: first.id, pool: fixture.pool))
        let afterSecond = try #require(try storedOperation(id: second.id, pool: fixture.pool))
        #expect(afterFirst.rowId == beforeFirst.rowId)
        #expect(afterFirst.operation.messageIdsJSON == beforeFirst.operation.messageIdsJSON)
        #expect(afterSecond.rowId == beforeSecond.rowId)
        #expect(afterSecond.operation.messageIdsJSON == beforeSecond.operation.messageIdsJSON)
    }

    @Test("empty and authoritatively stale rows disappear without renumbering later FIFO rows")
    func emptyAndStaleRowsAreDeletedAtomically() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-stale-\(UUID().uuidString)"
        let empty = PendingOperation(
            type: .markRead,
            messageIds: [],
            accountId: accountId,
            folderPath: "INBOX"
        )
        let stale = PendingOperation(
            type: .move,
            messageIds: ["gone-resource"],
            accountId: accountId,
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        let later = PendingOperation(
            type: .markUnread,
            messageIds: ["later@example.com"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try empty.insert(db)
            try stale.insert(db)
            try later.insert(db)
        }
        let laterBefore = try #require(try storedOperation(id: later.id, pool: fixture.pool))
        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.setLegacyIdentityResolution(
            providerMessageId: "gone-resource",
            result: .staleOrAmbiguous
        )

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await AccountManager.shared.convertReleasedMessageActionIdentities()
        }

        #expect(try storedOperation(id: empty.id, pool: fixture.pool)?.operation.id == nil)
        #expect(try storedOperation(id: stale.id, pool: fixture.pool)?.operation.id == nil)
        let laterAfter = try #require(try storedOperation(id: later.id, pool: fixture.pool))
        #expect(laterAfter.rowId == laterBefore.rowId)
        #expect(laterAfter.operation.messageIdsJSON == laterBefore.operation.messageIdsJSON)
    }

    @Test("an IMAP destination UID collision is never local conversion evidence")
    func imapDestinationUIDCollisionIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-imap-\(UUID().uuidString)"
        let operation = PendingOperation(
            type: .move,
            messageIds: ["55"],
            accountId: accountId,
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .imap)
            try insertHeader(
                db: db,
                accountId: accountId,
                folderPath: "Archive",
                providerMessageId: "55",
                rfc822MessageId: "unrelated-destination@example.com"
            )
            try operation.insert(db)
        }
        let provider = MockEmailProvider(messageFieldScope: .folder)
        await provider.setLegacyIdentityResolution(
            providerMessageId: "55",
            result: .staleOrAmbiguous
        )

        try await withRegisteredProvider(accountId: accountId, provider: provider) {
            try await AccountManager.shared.convertReleasedMessageActionIdentities()
        }

        #expect(try storedOperation(id: operation.id, pool: fixture.pool)?.operation.id == nil)
        let calls = await provider.legacyIdentityResolutionCalls
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        #expect(calls[0].providerMessageId == "55")
        #expect(calls[0].sourceFolder == "INBOX")
        #expect(calls[0].destinationFolder == "Archive")
    }

    @Test("legacy archive and delete no-op rows never require identity resolution")
    func legacyNoOpRowsAreOutsideConversion() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-no-op-\(UUID().uuidString)"
        let archive = PendingOperation(
            type: .archive,
            messageIds: ["legacy-archive-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        let delete = PendingOperation(
            type: .delete,
            messageIds: ["legacy-delete-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try archive.insert(db)
            try delete.insert(db)
        }
        let archiveBefore = try #require(
            try storedOperation(id: archive.id, pool: fixture.pool)
        )
        let deleteBefore = try #require(
            try storedOperation(id: delete.id, pool: fixture.pool)
        )

        // Deliberately register no provider. These rows are startup cleanup;
        // they must not be able to block the finite identity cutover.
        try await AccountManager.shared.convertReleasedMessageActionIdentities()

        let archiveAfter = try #require(
            try storedOperation(id: archive.id, pool: fixture.pool)
        )
        let deleteAfter = try #require(
            try storedOperation(id: delete.id, pool: fixture.pool)
        )
        #expect(archiveAfter.rowId == archiveBefore.rowId)
        #expect(archiveAfter.operation.messageIdsJSON == archiveBefore.operation.messageIdsJSON)
        #expect(deleteAfter.rowId == deleteBefore.rowId)
        #expect(deleteAfter.operation.messageIdsJSON == deleteBefore.operation.messageIdsJSON)
    }

    @Test("an unresolved active row waits for its provider without mutation")
    func missingProviderBlocksWithoutMutation() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-missing-provider-\(UUID().uuidString)"
        let operation = PendingOperation(
            type: .markRead,
            messageIds: ["legacy-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .outlook)
            try operation.insert(db)
        }
        let before = try #require(
            try storedOperation(id: operation.id, pool: fixture.pool)
        )

        await #expect(
            throws: ReleasedMessageActionIdentityConversionError.missingProvider(
                accountId: accountId
            )
        ) {
            try await AccountManager.shared.convertReleasedMessageActionIdentities()
        }

        let after = try #require(
            try storedOperation(id: operation.id, pool: fixture.pool)
        )
        #expect(after.rowId == before.rowId)
        #expect(after.operation.messageIdsJSON == before.operation.messageIdsJSON)
    }

    @Test("concurrent local identity evidence invalidates the whole conversion")
    func concurrentLocalEvidenceChangeAbortsAtomicApply() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-evidence-race-\(UUID().uuidString)"
        let operation = PendingOperation(
            type: .markRead,
            messageIds: ["trigger-resource", "local-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try insertHeader(
                db: db,
                accountId: accountId,
                folderPath: "INBOX",
                providerMessageId: "local-resource",
                rfc822MessageId: "before@example.com"
            )
            try operation.insert(db)
        }
        let before = try #require(
            try storedOperation(id: operation.id, pool: fixture.pool)
        )

        let provider = MockEmailProvider(messageFieldScope: .account)
        let pool = fixture.pool
        await provider.setLegacyIdentityResolutionHandler { providerMessageId, _, _ in
            guard providerMessageId == "trigger-resource" else {
                return .resolved(rfc822MessageId: "unexpected@example.com")
            }
            try await pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE messageHeader SET rfc822MessageId = ?
                        WHERE accountId = ? AND messageId = ?
                        """,
                    arguments: ["after@example.com", accountId, "local-resource"]
                )
            }
            return .resolved(rfc822MessageId: "trigger@example.com")
        }

        await #expect(
            throws: ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
        ) {
            try await self.withRegisteredProvider(accountId: accountId, provider: provider) {
                try await AccountManager.shared.convertReleasedMessageActionIdentities()
            }
        }

        let after = try #require(
            try storedOperation(id: operation.id, pool: fixture.pool)
        )
        #expect(after.rowId == before.rowId)
        #expect(after.operation.messageIdsJSON == before.operation.messageIdsJSON)
        let changedRFC = try await fixture.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT rfc822MessageId FROM messageHeader
                    WHERE accountId = ? AND messageId = ?
                    """,
                arguments: [accountId, "local-resource"]
            )
        }
        #expect(changedRFC == "after@example.com")
    }

    @Test("a concurrent queue-row change aborts conversion instead of overwriting newer state")
    func concurrentQueueChangeAbortsAtomicApply() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-race-\(UUID().uuidString)"
        let first = PendingOperation(
            type: .markRead,
            messageIds: ["race-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        var changed = PendingOperation(
            type: .markFlagged,
            messageIds: ["changed-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        changed.retryCount = 1
        let changedToInsert = changed
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try first.insert(db)
            try changedToInsert.insert(db)
        }
        let firstBefore = try #require(try storedOperation(id: first.id, pool: fixture.pool))

        let provider = MockEmailProvider(messageFieldScope: .account)
        let pool = fixture.pool
        let changedId = changed.id
        await provider.setLegacyIdentityResolutionHandler { providerMessageId, _, _ in
            if providerMessageId == "race-resource" {
                try await pool.write { db in
                    try db.execute(
                        sql: "UPDATE pendingOperation SET retryCount = ? WHERE id = ?",
                        arguments: [9, changedId]
                    )
                }
                return .resolved(rfc822MessageId: "race@example.com")
            }
            return .resolved(rfc822MessageId: "changed@example.com")
        }

        await #expect(
            throws: ReleasedMessageActionIdentityConversionError.queueChangedDuringConversion
        ) {
            try await self.withRegisteredProvider(accountId: accountId, provider: provider) {
                try await AccountManager.shared.convertReleasedMessageActionIdentities()
            }
        }

        let firstAfter = try #require(try storedOperation(id: first.id, pool: fixture.pool))
        let changedAfter = try #require(try storedOperation(id: changed.id, pool: fixture.pool))
        #expect(firstAfter.rowId == firstBefore.rowId)
        #expect(firstAfter.operation.messageIdsJSON == firstBefore.operation.messageIdsJSON)
        #expect(changedAfter.operation.messageIds == ["changed-resource"])
        #expect(changedAfter.operation.retryCount == 9)
    }

    /// Fix 2 (P1): `resolveLegacyMessageActionIdentity` had no timeout — a
    /// never-returning provider call hung the single-flight preparation
    /// flight forever, and every later `drainPendingQueue()` call joins that
    /// SAME stuck flight (§9.4's `pendingQueuePreparationFlight`) until
    /// process restart. The fix wraps the call in the same
    /// `SyncConfig.pendingOperationTimeoutSeconds` bound the executor already
    /// uses elsewhere — a timeout throws, the flight fails, publishes no
    /// readiness, and the row stays unclaimed for the next trigger to retry.
    @Test("a never-returning legacy identity resolver times out instead of hanging the preparation flight forever")
    func neverReturningResolverTimesOutInsteadOfHangingForever() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-hang-\(UUID().uuidString)"
        let legacyOp = PendingOperation(
            type: .markRead,
            messageIds: ["hang-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try legacyOp.insert(db)
        }

        let (latchStream, latch) = AsyncStream<Void>.makeStream()
        let provider = MockEmailProvider(messageFieldScope: .account)
        await provider.setLegacyIdentityResolutionHandler { _, _, _ in
            var iterator = latchStream.makeAsyncIterator()
            _ = await iterator.next()
            return .resolved(rfc822MessageId: "unreached@example.com")
        }

        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        do {
            // Bounded by the SAME production timeout the fix installs, plus a
            // small margin — proves the drain call itself returns instead of
            // hanging indefinitely (not a fixed arbitrary sleep).
            try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds + 5) {
                await AccountManager.shared.drainPendingQueue()
            }
        } catch {
            latch.finish()
            await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
            throw error
        }

        // The flight failed and cleared — no participant left waiting on it.
        #expect(
            await AccountManager.shared.pendingQueuePreparationParticipantCountForTesting() == 0,
            "the preparation flight must be cleared after the timeout, not stranded"
        )
        // No row was claimed — the timeout is uncertainty, not staleness.
        let afterTimeout = try #require(try storedOperation(id: legacyOp.id, pool: fixture.pool))
        #expect(afterTimeout.operation.status == PendingStatus.queued.rawValue)
        #expect(afterTimeout.operation.messageIds == ["hang-resource"], "payload unchanged — not claimed, not converted")

        // Release the latch and let the resolver succeed — the next external
        // drain trigger retries the complete preparation from scratch.
        latch.finish()
        await provider.setLegacyIdentityResolutionHandler { _, _, _ in
            .resolved(rfc822MessageId: "resolved-after-release@example.com")
        }
        try await withTimeout(seconds: SyncConfig.pendingOperationTimeoutSeconds) {
            await AccountManager.shared.drainPendingQueue()
        }

        let afterRetry = try storedOperation(id: legacyOp.id, pool: fixture.pool)
        #expect(afterRetry == nil, "the row converts and drains once the resolver actually returns")
        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
    }

    @Test("malformed legacy member JSON blocks conversion before provider access")
    func malformedJSONBlocksWithoutMutation() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        let accountId = "converter-malformed-\(UUID().uuidString)"
        let malformed = PendingOperation(
            type: .markRead,
            messageIds: ["malformed-resource"],
            accountId: accountId,
            folderPath: "INBOX"
        )
        try await fixture.pool.write { db in
            try insertAccountAndFolders(db: db, accountId: accountId, provider: .gmail)
            try malformed.insert(db)
            try db.execute(
                sql: "UPDATE pendingOperation SET messageIdsJSON = ? WHERE id = ?",
                arguments: ["{not-json", malformed.id]
            )
        }
        let provider = MockEmailProvider(messageFieldScope: .account)

        await #expect(
            throws: ReleasedMessageActionIdentityConversionError.malformedMessageIds(
                operationId: malformed.id
            )
        ) {
            try await self.withRegisteredProvider(accountId: accountId, provider: provider) {
                try await AccountManager.shared.convertReleasedMessageActionIdentities()
            }
        }

        let stored = try #require(try storedOperation(id: malformed.id, pool: fixture.pool))
        #expect(stored.operation.messageIdsJSON == "{not-json")
        #expect(await provider.legacyIdentityResolutionCalls.isEmpty)
    }
}
