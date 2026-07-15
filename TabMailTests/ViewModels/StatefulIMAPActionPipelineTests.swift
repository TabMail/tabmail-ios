/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Public-action outcome coverage for the real IMAP adapter and mutable socket
/// server. IMAP stays separate from the REST matrix because its resource ID is
/// a mailbox-local UID and its provider owns a live connection lifecycle.
@Suite("Stateful IMAP public action pipeline", .serialized, .processGlobalState)
@MainActor
struct StatefulIMAPActionPipelineTests {
    enum Setter: String, Sendable {
        case read
        case unread
        case flag
        case unflag

        var initialRead: Bool { self == .unread }
        var initialFlagged: Bool { self == .unflag }
        var expectedRead: Bool {
            switch self {
            case .read: true
            case .unread: false
            case .flag, .unflag: initialRead
            }
        }
        var expectedFlagged: Bool {
            switch self {
            case .flag: true
            case .unflag: false
            case .read, .unread: initialFlagged
            }
        }
    }

    private func makeTestDB()
        throws -> (pool: DatabasePool, inbox: Folder, archive: Folder, previous: AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }
        let account: Account = {
            var value = Account(
                emailAddress: "test@example.com",
                displayName: "Test",
                provider: .imap
            )
            value.id = "acc1"
            return value
        }()
        let inbox = Folder(
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            accountId: account.id
        )
        let archive = Folder(
            name: "Archive",
            path: "Archive",
            role: .archive,
            accountId: account.id
        )
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
        }
        return (pool, inbox, archive, previous)
    }

    private func makeHeader(
        folder: Folder,
        uid: Int,
        rfc822MessageId: String,
        isRead: Bool = false,
        isFlagged: Bool = false
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: String(uid),
            subject: "Stateful IMAP message",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "body",
            folderId: folder.id,
            accountId: folder.accountId,
            folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        header.headerComplete = true
        header.rfc822MessageId = "<\(rfc822MessageId)>"
        header.isRead = isRead
        header.isFlagged = isFlagged
        return header
    }

    private func rfc822(messageId: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return [
            "From: Test Sender <sender@example.com>",
            "To: Recipient <recipient@example.com>",
            "Subject: Stateful IMAP message",
            "Date: \(formatter.string(from: Date()))",
            "Message-ID: <\(messageId)>",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Stateful IMAP body.",
            "",
        ].joined(separator: "\r\n")
    }

    private func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private func resetProcessState() {
        AccountManager.shared.intentionJournal.resetForTesting()
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        UndoService.shared.dismissAll()
    }

    private func restore(previous: AppDatabase?) {
        if previous != nil {
            AppDatabase.shared.withLock { $0 = previous }
        }
        resetProcessState()
    }

    private func drainWriteQueue() async {
        var iterations = 0
        repeat {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task {
                    await AccountManager.shared.enqueueWrite { continuation.resume() }
                }
            }
            iterations += 1
        } while !AccountManager.shared.intentionJournal.isFullyDrainedForTesting()
            && iterations < 200
    }

    private func drainProviderQueue(pool: DatabasePool) async throws {
        for _ in 0..<200 {
            let isEmpty = try await pool.read { db in
                try PendingOperation.fetchCount(db) == 0
            }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            // Public gestures launch their own drain. If that owner is active,
            // repeatedly requesting another drain keeps toggling needsRedrain and
            // can outrun its final quiescence publication under full-suite load.
            if isQuiescent && !isEmpty {
                await AccountManager.shared.drainPendingQueue()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isEmpty = try await pool.read { db in
            try PendingOperation.fetchCount(db) == 0
        }
        let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
        try #require(
            isEmpty && isQuiescent,
            "IMAP provider queue did not become empty and quiescent"
        )
    }

    private func durableRows(
        pool: DatabasePool,
        rfc822MessageId: String
    ) async throws -> [MessageHeader] {
        try await pool.read { db in
            try MessageHeader.fetchAll(db).filter {
                MessageIdentity.durableActionRFC822MessageId($0.rfc822MessageId)
                    == rfc822MessageId
            }
        }
    }

    private func userLabelMemberships(
        pool: DatabasePool,
        rfc822MessageId: String,
        userLabelId: String
    ) async throws -> [MessageUserLabel] {
        try await pool.read { db in
            let messageIds = Set(try MessageHeader.fetchAll(db).filter {
                MessageIdentity.durableActionRFC822MessageId($0.rfc822MessageId)
                    == rfc822MessageId
            }.map(\.id))
            return try MessageUserLabel.fetchAll(db).filter {
                messageIds.contains($0.messageId) && $0.userLabelId == userLabelId
            }
        }
    }

    private func expectPipelineIdle(pool: DatabasePool) async throws {
        let queueIsEmpty = try await pool.read { db in
            try PendingOperation.fetchCount(db) == 0
        }
        let queueIsQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
        #expect(queueIsEmpty)
        #expect(queueIsQuiescent)
        #expect(AccountManager.shared.snapshotOverlay().isEmpty)
        #expect(AccountManager.shared.intentionJournal.isFullyDrainedForTesting())
    }

    private func reconcileWithoutRecentProtection(
        pool: DatabasePool,
        folder: Folder,
        provider: IMAPProvider
    ) async throws {
        _ = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: provider,
            limit: SyncConfig.syncMessageLimit,
            dbPool: PrioritizedDatabase(pool: pool),
            recentlyCompleted: [:]
        )
    }

    private func waitForConsumedInjectedFailure(_ server: FakeIMAPServer) async throws {
        for _ in 0..<200 {
            if server.consumedInjectedFailureCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            server.consumedInjectedFailureCount() > 0,
            "IMAP server did not consume the injected lookup failure"
        )
    }

    private func waitForProviderQueueQuiescence() async throws {
        for _ in 0..<200 {
            if await AccountManager.shared.pendingQueueIsQuiescentForTesting() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            await AccountManager.shared.pendingQueueIsQuiescentForTesting(),
            "IMAP provider queue did not become quiescent after the injected failure"
        )
    }

    @Test("completed archive Undo survives provider recreation and two mailbox-local UID generations")
    func archiveUndoFinalOutcome() async throws {
        let rfc822MessageId = "imap-undo-\(UUID().uuidString.lowercased())@example.com"
        let initialUID = 41
        let message = FakeIMAPServer.makeMessage(
            uid: initialUID,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        try server.start()
        defer { server.stop() }
        let initialProvider = provider(for: server)
        try await initialProvider.connect()
        let (pool, inbox, archive, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        var activeProvider: IMAPProvider? = initialProvider
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: initialProvider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: initialUID,
                rfc822MessageId: rfc822MessageId
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            #expect(viewModel.archive(header.id))
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(folder: archive, provider: initialProvider)

            let archivedRemote = try await initialProvider.fetchMessages(
                folder: "Archive",
                limit: 10,
                offset: 0
            )
            #expect(archivedRemote.count == 1)
            guard archivedRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await initialProvider.disconnect()
                activeProvider = nil
                return
            }
            #expect(archivedRemote[0].rfc822MessageId == rfc822MessageId)
            #expect(server.messageIDs(in: "INBOX").isEmpty)

            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try await initialProvider.disconnect()
            activeProvider = nil
            await UndoService.shared.undo()
            await drainWriteQueue()
            await AccountManager.shared.drainPendingQueue()
            try await waitForProviderQueueQuiescence()
            await AccountManager.shared.resetPendingQueuePreparationForTesting()

            let restartedProvider = provider(for: server)
            try await restartedProvider.connect()
            activeProvider = restartedProvider
            await AccountManager.shared.registerProviderForTesting(
                accountId: "acc1",
                provider: restartedProvider
            )
            try await drainProviderQueue(pool: pool)
            try await syncEngine.syncFolderMessages(folder: inbox, provider: restartedProvider)

            let remote = try await restartedProvider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await restartedProvider.disconnect()
                activeProvider = nil
                return
            }
            #expect(remote[0].rfc822MessageId == rfc822MessageId)
            #expect(remote[0].messageId != String(initialUID))
            #expect(server.messageIDs(in: "Archive").isEmpty)

            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await restartedProvider.disconnect()
                activeProvider = nil
                return
            }
            #expect(local[0].folderId == inbox.id)
            #expect(local[0].folderPath == inbox.path)
            #expect(local[0].isInInbox)
            #expect(local[0].messageId == remote[0].messageId)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            if let activeProvider { try? await activeProvider.disconnect() }
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        if let activeProvider { try await activeProvider.disconnect() }
    }

    @Test("cold notification archive automatically drains through the real IMAP socket")
    func coldNotificationArchiveFinalOutcome() async throws {
        let rfc822MessageId = "imap-cold-\(UUID().uuidString.lowercased())@example.com"
        let initialUID = 45
        let message = FakeIMAPServer.makeMessage(
            uid: initialUID,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, _, archive, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            await NotificationActionRouter.execute(
                actionId: "ARCHIVE",
                transportMessageId: "irrelevant-transport-\(UUID().uuidString.lowercased())",
                rfc822MessageId: "<\(rfc822MessageId)>",
                accountId: "acc1"
            )

            let archiveMessages = try await provider.fetchMessages(
                folder: "Archive",
                limit: 10,
                offset: 0
            )
            #expect(archiveMessages.count == 1)
            guard archiveMessages.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(archiveMessages[0].rfc822MessageId == rfc822MessageId)
            #expect(server.messageIDs(in: "INBOX").isEmpty)

            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: archive,
                provider: provider
            )
            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(local[0].folderId == archive.id)
            #expect(local[0].folderPath == archive.path)
            #expect(!local[0].isInInbox)
            #expect(local[0].messageId == archiveMessages[0].messageId)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test("public IMAP label add and remove converge remotely and through ordinary sync")
    func userLabelFinalOutcomes() async throws {
        let rfc822MessageId = "imap-label-\(UUID().uuidString.lowercased())@example.com"
        let labelId = "project\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let uid = 47
        let message = FakeIMAPServer.makeMessage(
            uid: uid,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: uid,
                rfc822MessageId: rfc822MessageId
            )
            let label = UserLabel(
                id: labelId,
                accountId: "acc1",
                name: "Project",
                isSystem: false
            )
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try label.insert(db)
            }
            let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

            #expect(await menu.applyLabel(label))
            try await drainProviderQueue(pool: pool)
            let addedRemote = try await provider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(addedRemote.count == 1)
            guard addedRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(addedRemote[0].userLabelIds.contains(labelId))
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: provider
            )
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).count == 1)

            #expect(await menu.removeLabel(label))
            try await drainProviderQueue(pool: pool)
            let removedRemote = try await provider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(removedRemote.count == 1)
            guard removedRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(!removedRemote[0].userLabelIds.contains(labelId))
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: provider
            )
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test("ambiguous IMAP label add no-ops remotely and ordinary sync removes optimistic membership")
    func ambiguousUserLabelFinalOutcome() async throws {
        let rfc822MessageId = "imap-label-ambiguous-\(UUID().uuidString.lowercased())@example.com"
        let labelId = "project\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let firstUID = 48
        let secondUID = 49
        let first = FakeIMAPServer.makeMessage(
            uid: firstUID,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let second = FakeIMAPServer.makeMessage(
            uid: secondUID,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(
            mailboxes: ["INBOX": [first, second], "Archive": []]
        )
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: firstUID,
                rfc822MessageId: rfc822MessageId
            )
            let label = UserLabel(
                id: labelId,
                accountId: "acc1",
                name: "Project",
                isSystem: false
            )
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try label.insert(db)
            }
            let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

            #expect(await menu.applyLabel(label))
            try await drainProviderQueue(pool: pool)
            let remote = try await provider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(remote.count == 2)
            #expect(remote.allSatisfy { !$0.userLabelIds.contains(labelId) })

            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: provider
            )
            #expect(try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            ).count == 2)
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test("ambiguous IMAP label remove no-ops remotely and ordinary sync restores membership")
    func ambiguousUserLabelRemoveFinalOutcome() async throws {
        let rfc822MessageId = "imap-label-remove-ambiguous-\(UUID().uuidString.lowercased())@example.com"
        let labelId = "project\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let firstUID = 50
        let secondUID = 51
        let first = FakeIMAPServer.makeMessage(
            uid: firstUID,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let second = FakeIMAPServer.makeMessage(
            uid: secondUID,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(
            mailboxes: ["INBOX": [first, second], "Archive": []]
        )
        server.setFlags([labelId], in: "INBOX", uid: firstUID)
        server.setFlags([labelId], in: "INBOX", uid: secondUID)
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: firstUID,
                rfc822MessageId: rfc822MessageId
            )
            let label = UserLabel(
                id: labelId,
                accountId: "acc1",
                name: "Project",
                isSystem: false
            )
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try label.insert(db)
                try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: labelId)
                    .insert(db)
            }
            let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

            #expect(await menu.removeLabel(label))
            try await drainProviderQueue(pool: pool)
            let remote = try await provider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(remote.count == 2)
            #expect(remote.allSatisfy { $0.userLabelIds.contains(labelId) })

            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: provider
            )
            #expect(try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            ).count == 2)
            #expect(try await userLabelMemberships(
                pool: pool,
                rfc822MessageId: rfc822MessageId,
                userLabelId: labelId
            ).count == 2)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test(
        "public read and flag setters converge through the real IMAP socket",
        arguments: [Setter.read, .unread, .flag, .unflag]
    )
    func setterFinalOutcome(setter: Setter) async throws {
        let rfc822MessageId = "imap-setter-\(UUID().uuidString.lowercased())@example.com"
        let uid = 51
        let message = FakeIMAPServer.makeMessage(
            uid: uid,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        var initialFlags = Set<String>()
        if setter.initialRead { initialFlags.insert("\\Seen") }
        if setter.initialFlagged { initialFlags.insert("\\Flagged") }
        server.setFlags(initialFlags, in: "INBOX", uid: uid)
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: uid,
                rfc822MessageId: rfc822MessageId,
                isRead: setter.initialRead,
                isFlagged: setter.initialFlagged
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            switch setter {
            case .read, .unread:
                viewModel.toggleRead(header.id)
            case .flag, .unflag:
                viewModel.toggleFlag(header.id)
            }
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(folder: inbox, provider: provider)

            let remote = try await provider.fetchMessages(folder: "INBOX", limit: 10, offset: 0)
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(remote[0].isRead == setter.expectedRead)
            #expect(remote[0].isFlagged == setter.expectedFlagged)

            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(local[0].folderId == inbox.id)
            #expect(local[0].messageId == remote[0].messageId)
            #expect(local[0].isRead == setter.expectedRead)
            #expect(local[0].isFlagged == setter.expectedFlagged)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test("public action against a missing RFC target stale-drops and final sync removes the ghost")
    func missingTargetFinalOutcome() async throws {
        let rfc822MessageId = "imap-missing-\(UUID().uuidString.lowercased())@example.com"
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Archive": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, archive, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: 71,
                rfc822MessageId: rfc822MessageId
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            #expect(viewModel.archive(header.id))
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: provider
            )
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: archive,
                provider: provider
            )

            #expect(server.messageIDs(in: "INBOX").isEmpty)
            #expect(server.messageIDs(in: "Archive").isEmpty)
            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test("public action against an ambiguous RFC target no-ops and final sync restores remote truth")
    func ambiguousTargetFinalOutcome() async throws {
        let rfc822MessageId = "imap-ambiguous-\(UUID().uuidString.lowercased())@example.com"
        let firstUID = 81
        let secondUID = 82
        let messages = [firstUID, secondUID].map { uid in
            FakeIMAPServer.makeMessage(
                uid: uid,
                rfc822Text: rfc822(messageId: rfc822MessageId)
            )
        }
        let server = FakeIMAPServer(mailboxes: ["INBOX": messages, "Archive": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: firstUID,
                rfc822MessageId: rfc822MessageId
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            viewModel.toggleRead(header.id)
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)
            try await reconcileWithoutRecentProtection(
                pool: pool,
                folder: inbox,
                provider: provider
            )

            let remote = try await provider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(remote.count == 2)
            guard remote.count == 2 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(remote.allSatisfy { $0.rfc822MessageId == rfc822MessageId })
            #expect(remote.allSatisfy { !$0.isRead && !$0.isFlagged })

            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 2)
            guard local.count == 2 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(local.allSatisfy { $0.folderId == inbox.id })
            #expect(local.allSatisfy { !$0.isRead && !$0.isFlagged })
            #expect(Set(local.map(\.messageId)) == Set(remote.map(\.messageId)))
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    @Test("transient RFC lookup failure survives provider recreation and reaches final state")
    func transientRestartFinalOutcome() async throws {
        let rfc822MessageId = "imap-restart-\(UUID().uuidString.lowercased())@example.com"
        let uid = 91
        let message = FakeIMAPServer.makeMessage(
            uid: uid,
            rfc822Text: rfc822(messageId: rfc822MessageId)
        )
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        try server.start()
        defer { server.stop() }
        let initialProvider = provider(for: server)
        try await initialProvider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        var activeProvider: IMAPProvider? = initialProvider
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: initialProvider
        )

        do {
            let header = makeHeader(
                folder: inbox,
                uid: uid,
                rfc822MessageId: rfc822MessageId
            )
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            server.failNextCommand(containing: rfc822MessageId)
            viewModel.toggleRead(header.id)
            await drainWriteQueue()
            try await waitForConsumedInjectedFailure(server)
            try await waitForProviderQueueQuiescence()

            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try await initialProvider.disconnect()
            activeProvider = nil
            await AccountManager.shared.resetPendingQueuePreparationForTesting()

            let restartedProvider = provider(for: server)
            try await restartedProvider.connect()
            activeProvider = restartedProvider
            await AccountManager.shared.registerProviderForTesting(
                accountId: "acc1",
                provider: restartedProvider
            )
            try await drainProviderQueue(pool: pool)
            let syncEngine = await AccountManager.shared.syncEngine
            try await syncEngine.syncFolderMessages(folder: inbox, provider: restartedProvider)

            let remote = try await restartedProvider.fetchMessages(
                folder: "INBOX",
                limit: 10,
                offset: 0
            )
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await restartedProvider.disconnect()
                return
            }
            #expect(remote[0].isRead)
            let local = try await durableRows(
                pool: pool,
                rfc822MessageId: rfc822MessageId
            )
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await restartedProvider.disconnect()
                return
            }
            #expect(local[0].isRead)
            #expect(local[0].messageId == remote[0].messageId)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            if let activeProvider {
                try? await activeProvider.disconnect()
            }
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        if let activeProvider {
            try await activeProvider.disconnect()
        }
    }

    // MARK: - Provider-adapter Law 4 classification (Round E)

    /// `deleteDraft`'s non-numeric-id fallback (`resolveUID` →
    /// `searchByMessageId`) is a Message-ID SEARCH, not a UID lookup. An
    /// empty Drafts mailbox means the search completes SUCCESSFULLY with
    /// zero results — authoritative absence (Law 4: the draft is already
    /// gone) — which must no-op rather than throw
    /// `ProviderError.uidResolutionFailed` and retry forever. A FAILED
    /// search (connection error) is the untouched contrast case and still
    /// throws — not exercised here since it requires no new adapter logic.
    @Test("IMAP deleteDraft with a non-numeric id whose Message-ID search succeeds but finds nothing no-ops")
    func deleteDraftNonNumericConfirmedAbsentNoOps() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": [], "Archive": [], "Drafts": []])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        try await provider.deleteDraft(
            draftId: "not-a-uid-\(UUID().uuidString.lowercased())@example.com",
            draftsFolderPath: "Drafts"
        )
    }

    /// Source mailbox confirmed gone (RFC 5530 `[NONEXISTENT]` hint shape).
    /// The op is enqueued directly as a durable row (not via the gesture
    /// layer) targeting a custom folder — a realistic "user had a custom
    /// mailbox, it was deleted remotely before the move drained" scenario.
    /// `IMAPProvider.withActionConnection`'s own SELECT no longer guesses
    /// from `IMAPError.selectFailed`'s unstructured reason text; it probes
    /// via LIST (`mailboxConfirmedAbsent`) and normal-returns (Law 4). A
    /// second, independent op queued right after proves the protected-front
    /// frontier is never wedged by the confirmed-absent no-op.
    @Test("public move whose source mailbox is confirmed gone ([NONEXISTENT] hint) terminal-no-ops through the real drain, and a later op still proceeds")
    func mailboxGoneSourceFinalOutcome() async throws {
        let rfc822MessageId = "imap-gone-source-\(UUID().uuidString.lowercased())@example.com"
        let uid = 201
        let message = FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: rfc822MessageId))
        let otherRfc822MessageId = "imap-gone-source-other-\(UUID().uuidString.lowercased())@example.com"
        let otherUID = 202
        let otherMessage = FakeIMAPServer.makeMessage(uid: otherUID, rfc822Text: rfc822(messageId: otherRfc822MessageId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [otherMessage], "Projects": [message], "Archive": []])
        server.markMailboxDeleted("Projects", includeNonexistentCode: true)
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            // Inserted directly as a durable row — this test pins the
            // provider adapter's mailbox-gone classification, not admission
            // or gesture-layer role resolution.
            let staleOp = PendingOperation(
                type: .move,
                messageIds: [rfc822MessageId],
                accountId: "acc1",
                folderPath: "Projects",
                destinationPath: "Archive"
            )
            let laterHeader = makeHeader(folder: inbox, uid: otherUID, rfc822MessageId: otherRfc822MessageId)
            try await pool.writeWithoutTransaction { db in
                try staleOp.insert(db)
                try laterHeader.insert(db)
            }
            let viewModel = InboxViewModel(folders: [inbox])
            viewModel.toggleRead(laterHeader.id)
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)

            let remaining = try await pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(remaining == 0, "the gone-source move terminal-no-ops and the later markRead completes")

            let laterRemote = try await provider.fetchMessages(folder: "INBOX", limit: 10, offset: 0)
            #expect(laterRemote.count == 1)
            guard laterRemote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(laterRemote[0].isRead, "the later op was not wedged behind the gone-source op")
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    /// Destination mailbox confirmed gone, deliberately in the plain,
    /// non-RFC-5530 `NO Mailbox does not exist` shape (no `[NONEXISTENT]`
    /// code) — the shape some real servers send, and the one the OLD
    /// queue-side `"NONEXISTENT"` substring scrape could never classify
    /// (that fragile scrape was the ONLY thing standing between this
    /// scenario and an infinite-retry wedge of the whole FIFO frontier).
    /// `IMAPProvider.move`'s destination SELECT now proves absence via LIST
    /// regardless of which shape the SELECT failure carries.
    @Test("public archive whose destination mailbox is confirmed gone (plain NO, non-RFC-5530 shape) terminal-no-ops through the real drain, and a later op still proceeds")
    func mailboxGoneDestinationFinalOutcome() async throws {
        let rfc822MessageId = "imap-gone-dest-\(UUID().uuidString.lowercased())@example.com"
        let uid = 211
        let message = FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: rfc822MessageId))
        let otherRfc822MessageId = "imap-gone-dest-other-\(UUID().uuidString.lowercased())@example.com"
        let otherUID = 212
        let otherMessage = FakeIMAPServer.makeMessage(uid: otherUID, rfc822Text: rfc822(messageId: otherRfc822MessageId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message, otherMessage], "Archive": []])
        server.markMailboxDeleted("Archive", includeNonexistentCode: false)
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(folder: inbox, uid: uid, rfc822MessageId: rfc822MessageId)
            let otherHeader = makeHeader(folder: inbox, uid: otherUID, rfc822MessageId: otherRfc822MessageId)
            try await pool.writeWithoutTransaction { db in
                try header.insert(db)
                try otherHeader.insert(db)
            }
            let viewModel = InboxViewModel(folders: [inbox])

            #expect(viewModel.archive(header.id))
            // A second, independent op queued right after the gone-
            // destination archive proves the protected-front frontier is
            // never wedged.
            viewModel.toggleRead(otherHeader.id)
            await drainWriteQueue()
            try await drainProviderQueue(pool: pool)

            let remote = try await provider.fetchMessages(folder: "INBOX", limit: 10, offset: 0)
            #expect(remote.count == 2, "the gone-destination archive is a whole-op no-op — both messages stay in INBOX")
            guard remote.count == 2 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(remote.contains { $0.rfc822MessageId == rfc822MessageId }, "the archived message was never moved")
            let laterRemote = remote.first { $0.rfc822MessageId == otherRfc822MessageId }
            #expect(laterRemote?.isRead == true, "the later op was not wedged behind the gone-destination op")

            try await reconcileWithoutRecentProtection(pool: pool, folder: inbox, provider: provider)
            let local = try await durableRows(pool: pool, rfc822MessageId: rfc822MessageId)
            #expect(local.count == 1)
            guard local.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(local[0].isInInbox, "ordinary sync converges the optimistic local move back to remote truth")
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }

    /// Contrast case for both gone-mailbox tests above: the destination
    /// SELECT fails, but LIST proves the mailbox still EXISTS (or, in the
    /// `listAlsoFails` variant, LIST itself fails) — neither shape is
    /// authoritative absence, so the op must stay queued, payload unchanged,
    /// and the drain must stop (protected frontier) rather than guess. A
    /// later drain, once the injected one-shot failure(s) are consumed,
    /// completes the move normally.
    @Test(
        "public move whose destination SELECT transiently fails blocks the frontier then succeeds on retry",
        arguments: [false, true]
    )
    func transientDestinationSelectFinalOutcome(listAlsoFails: Bool) async throws {
        let rfc822MessageId = "imap-transient-select-\(UUID().uuidString.lowercased())@example.com"
        let uid = 221
        let message = FakeIMAPServer.makeMessage(uid: uid, rfc822Text: rfc822(messageId: rfc822MessageId))
        let server = FakeIMAPServer(mailboxes: ["INBOX": [message], "Archive": []])
        server.failNextCommand(containing: "Archive")
        if listAlsoFails {
            server.failNextCommand(containing: "LIST")
        }
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        let (pool, inbox, _, previous) = try makeTestDB()
        defer { restore(previous: previous) }
        resetProcessState()
        await AccountManager.shared.registerProviderForTesting(
            accountId: "acc1",
            provider: provider
        )

        do {
            let header = makeHeader(folder: inbox, uid: uid, rfc822MessageId: rfc822MessageId)
            try await pool.writeWithoutTransaction { db in try header.insert(db) }
            let viewModel = InboxViewModel(folders: [inbox])

            #expect(viewModel.archive(header.id))
            await drainWriteQueue()

            // First attempt: the injected transient SELECT (and, in the
            // listAlsoFails case, the LIST probe) failure fires once.
            // Neither classifies as authoritative absence, so the op must
            // stay queued, unchanged, for retry rather than being dropped.
            await AccountManager.shared.drainPendingQueue()
            let afterFirstAttempt = try await pool.read { db in try PendingOperation.fetchAll(db) }
            #expect(afterFirstAttempt.count == 1, "a transient SELECT failure must not drop the op")
            #expect(afterFirstAttempt.first?.destinationPath == "Archive", "payload unchanged")
            #expect(server.messageIDs(in: "INBOX").contains { $0.contains(rfc822MessageId) }, "the message never moved on the failed attempt")

            // Second attempt: the one-shot injected failure(s) are consumed —
            // SELECT (and LIST, if it also failed) now succeed normally, and
            // the move completes.
            try await drainProviderQueue(pool: pool)
            let remote = try await provider.fetchMessages(folder: "Archive", limit: 10, offset: 0)
            #expect(remote.count == 1)
            guard remote.count == 1 else {
                await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
                try? await provider.disconnect()
                return
            }
            #expect(remote[0].rfc822MessageId == rfc822MessageId)
            #expect(server.messageIDs(in: "INBOX").isEmpty)
            try await expectPipelineIdle(pool: pool)
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
            try? await provider.disconnect()
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: "acc1")
        try await provider.disconnect()
    }
}
