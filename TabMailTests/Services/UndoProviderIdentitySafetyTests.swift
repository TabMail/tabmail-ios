/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("Undo provider identity safety", .processGlobalState)
struct UndoProviderIdentitySafetyTests {
    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    @MainActor
    private func install(provider: AccountProvider, accountId: String = "undo-provider") throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("undo.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.write { db in
            var account = Account(
                emailAddress: "undo@example.com",
                displayName: "Undo",
                provider: provider
            )
            account.id = accountId
            try account.insert(db)
            var inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId)
            inbox.lastKnownUidValidity = 41
            try inbox.insert(db)
            var archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
            archive.lastKnownUidValidity = 52
            try archive.insert(db)
            var other = Folder(name: "Other", path: "Other", role: .custom, accountId: accountId)
            other.lastKnownUidValidity = 63
            try other.insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func uninstall(_ fixture: Fixture) {
        // See `UndoDestructiveActionTests.uninstall` for the full reasoning.
        // Short version: the old comment named a real hazard (unlinking
        // SQLite/WAL under an open descriptor) and discharged it by leaking —
        // six fresh UUID directories per run of this suite, collected by
        // nothing. The registry closes before it unlinks, which is the ordering
        // the comment was reaching for.
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous,
            pool: fixture.pool,
            directory: fixture.directory)
    }

    private func sourceHeader(
        _ fixture: Fixture,
        providerId: String,
        rfc: String? = nil,
        sourcePath: String = "INBOX",
        sourceEpoch: Int? = 41,
        actionTag: ActionTag? = .reply
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: providerId,
            subject: "Undo \(providerId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "undo@example.com",
            date: Date(),
            snippet: "body",
            folderId: "\(fixture.accountId):\(sourcePath)",
            accountId: fixture.accountId,
            folderPath: sourcePath,
            isInInbox: sourcePath == "INBOX"
        )
        header.rfc822MessageId = rfc
        header.observedUidValidity = sourceEpoch
        header.actionTag = actionTag
        return header
    }

    private func installOptimisticallyMoved(
        _ original: MessageHeader,
        destinationPath: String = "Archive",
        destinationEpoch: Int? = nil,
        pool: DatabasePool
    ) throws {
        try pool.write { db in
            try original.insert(db)
            try MessageHeader.filter(Column("id") == original.id).updateAll(
                db,
                Column("folderId").set(to: "\(original.accountId):\(destinationPath)"),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: false),
                Column("observedUidValidity").set(to: destinationEpoch),
                Column("actionTag").set(to: nil as String?),
                Column("tagSortOrder").set(to: 99)
            )
        }
    }

    @Test("Undo annihilates only an exact never-attempted provider-ID move and restores the exact local member")
    @MainActor
    func exactNeverAttemptedAnnihilation() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "101", rfc: "same@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)
        try await fixture.pool.write { db in
            try PendingOperation(
                type: .move,
                messageIds: ["101"],
                accountId: fixture.accountId,
                folderPath: "INBOX",
                destinationPath: "Archive",
                observedUidValidity: 41
            ).insert(db)
        }

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(result.0?.folderPath == "INBOX")
        #expect(result.0?.observedUidValidity == 41)
        #expect(result.0?.actionTag == .reply)
        #expect(result.1.isEmpty, "an exact unattempted move is physically annihilated")
    }

    @Test("Undo never annihilates an attempted move whose provider outcome may be unknown")
    @MainActor
    func attemptedMoveIsNeverAnnihilated() async throws {
        let fixture = try install(provider: .gmail)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "gmail-201", sourceEpoch: nil)
        try installOptimisticallyMoved(original, pool: fixture.pool)
        try await fixture.pool.write { db in
            var attempted = PendingOperation(
                type: .move, messageIds: [original.messageId], accountId: fixture.accountId,
                folderPath: "INBOX", destinationPath: "Archive"
            )
            attempted.status = PendingStatus.inFlight.rawValue
            try attempted.insert(db)
        }

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let ops = try await fixture.pool.read { try PendingOperation.fetchAll($0) }
        #expect(ops.contains { $0.status == PendingStatus.inFlight.rawValue })
        #expect(ops.contains { $0.status == PendingStatus.queued.rawValue && $0.folderPath == "Archive" })
    }

    @Test("Undo refuses partial-batch, cross-mailbox, and cross-epoch cancellation")
    @MainActor
    func cancellationMustMatchWholeBundle() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let partial = sourceHeader(fixture, providerId: "301", rfc: "partial@example.com")
        let mailbox = sourceHeader(fixture, providerId: "401", rfc: "mailbox@example.com")
        let epoch = sourceHeader(fixture, providerId: "501", rfc: "epoch@example.com", sourceEpoch: 41)
        try installOptimisticallyMoved(partial, pool: fixture.pool)
        try installOptimisticallyMoved(mailbox, pool: fixture.pool)
        try installOptimisticallyMoved(epoch, pool: fixture.pool)
        try await fixture.pool.write { db in
            try PendingOperation(type: .move, messageIds: ["301", "302"], accountId: fixture.accountId,
                                 folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 41).insert(db)
            try PendingOperation(type: .move, messageIds: ["401"], accountId: fixture.accountId,
                                 folderPath: "Other", destinationPath: "Archive", observedUidValidity: 63).insert(db)
            try PendingOperation(type: .move, messageIds: ["501"], accountId: fixture.accountId,
                                 folderPath: "INBOX", destinationPath: "Archive", observedUidValidity: 40).insert(db)
        }

        for original in [partial, mailbox, epoch] {
            await AccountManager.shared.undoDestructiveAction(
                [original], accountId: fixture.accountId, originalOpType: .move,
                fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
            )
        }

        let result = try await fixture.pool.read { db -> ([PendingOperation], [MessageHeader]) in
            let headers = try [partial.id, mailbox.id, epoch.id].compactMap { id in
                try MessageHeader.fetchOne(db, key: id)
            }
            return (try PendingOperation.fetchAll(db), headers)
        }
        #expect(result.0.count == 3)
        #expect(result.0.allSatisfy { $0.status == PendingStatus.queued.rawValue })
        #expect(result.1.allSatisfy { $0.folderPath == "Archive" }, "a refused cancellation performs no local restore")
    }

    @Test("Completed stable-provider Undo queues one native-ID inverse without RFC authority")
    @MainActor
    func completedStableProviderUndo() async throws {
        let fixture = try install(provider: .gmail)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "gmail-601", rfc: "shared@example.com", sourceEpoch: nil)
        try installOptimisticallyMoved(original, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(result.0?.folderPath == "INBOX")
        #expect(result.1.count == 1)
        #expect(result.1.first?.messageIds == ["gmail-601"])
        #expect(result.1.first?.messageIds.contains("shared@example.com") == false)
    }

    @Test("Completed IMAP Undo without a proven destination UID and epoch fails closed with zero local or provider mutation")
    @MainActor
    func completedImapWithoutDestinationProofFailsClosed() async throws {
        let fixture = try install(provider: .imap)
        defer { uninstall(fixture) }
        let original = sourceHeader(fixture, providerId: "701", rfc: "imap@example.com")
        try installOptimisticallyMoved(original, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [original], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: original.id), try PendingOperation.fetchAll(db))
        }
        #expect(result.0?.folderPath == "Archive")
        #expect(result.0?.observedUidValidity == nil)
        #expect(result.1.isEmpty)
    }

    @Test("Undo after a completed move mutates exactly the moved provider address or nothing")
    @MainActor
    func completedUndoExactAddressOrNothing() async throws {
        let fixture = try install(provider: .outlook)
        defer { uninstall(fixture) }
        let intended = sourceHeader(fixture, providerId: "graph-801", rfc: "duplicate@example.com", sourceEpoch: nil)
        let decoy = sourceHeader(fixture, providerId: "graph-802", rfc: "duplicate@example.com", sourceEpoch: nil, actionTag: .archive)
        try installOptimisticallyMoved(intended, pool: fixture.pool)
        try installOptimisticallyMoved(decoy, pool: fixture.pool)

        await AccountManager.shared.undoDestructiveAction(
            [intended], accountId: fixture.accountId, originalOpType: .move,
            fromFolderPath: "Archive", toFolderPath: "INBOX", toFolderId: "\(fixture.accountId):INBOX"
        )

        let result = try await fixture.pool.read { db in
            (
                try MessageHeader.fetchOne(db, key: intended.id),
                try MessageHeader.fetchOne(db, key: decoy.id),
                try PendingOperation.fetchAll(db)
            )
        }
        #expect(result.0?.folderPath == "INBOX")
        #expect(result.1?.folderPath == "Archive")
        #expect(result.1?.actionTag == nil, "the unrelated destination row stays byte-for-byte locally moved")
        #expect(result.2.count == 1)
        #expect(result.2.first?.messageIds == ["graph-801"])
    }
}
