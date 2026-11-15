/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Pull-to-refresh (`InboxViewModel.refreshSync`) also reads what changed on the
/// server for each account (#902), not only the newest mail of the folder on
/// screen.
///
/// The property asserted is the user's: a message in a folder that is NOT on
/// screen, marked read elsewhere, shows as read once the pull ends. The reader is
/// a scripted `MockEmailProvider` change reader (the generic apply, ADR-IOS-111),
/// so nothing here is provider-specific. With two accounts, one whose change read
/// throws does not stop the other's change from landing.
@Suite("Pull-to-refresh reads what changed for each account", .serialized, .processGlobalState,
       .timeLimit(.minutes(2)))
@MainActor
struct RefreshChangeReadTests {

    private struct Member {
        let accountId: String
        let inbox: Folder
        let archiveId: String
        let mock: MockEmailProvider
    }

    nonisolated private static func rfc(_ id: String) -> String { "\(id)-refresh@example.com" }

    /// Builds one Gmail-shaped account per entry (bookmark set, full sync recent),
    /// with an unread message "old" in Archive, registered as connected.
    private func withAccounts(_ count: Int, _ body: (DatabasePool, [Member]) async throws -> Void) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let manager = AccountManager.shared
        let suffix = UUID().uuidString.prefix(8).lowercased()
        var members: [Member] = []
        for index in 0..<count {
            let id = "refreshread-\(index)-\(suffix)"
            var account = Account(emailAddress: "\(id)@example.com", displayName: "Refresh", provider: .gmail)
            account.id = id
            account.lastHistoryId = "100"
            account.lastFullSyncAt = Date()
            let toInsert = account
            try await pool.write { db in
                try toInsert.insert(db)
                try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: id).insert(db)
                try Folder(name: "Archive", path: "Archive", role: .archive, accountId: id).insert(db)
                var header = MessageHeader(
                    messageId: "old", subject: "refresh old", from: "Sender",
                    fromAddress: "sender@example.com", to: "recipient@example.com",
                    date: Date().addingTimeInterval(-30 * 86_400), snippet: "refresh fixture",
                    folderId: "\(id):Archive", accountId: id, folderPath: "Archive", isInInbox: false)
                header.rfc822MessageId = Self.rfc("old")
                header.isRead = false
                header.headerComplete = true
                try header.insert(db)
            }
            let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: id, path: "INBOX", pool: pool))
            let mock = MockEmailProvider()
            await manager.registerProviderForTesting(accountId: id, provider: mock)
            await manager.syncEngine.register(
                accountId: id, provider: mock,
                workQueue: ProviderWorkQueue(provider: mock, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
            members.append(Member(accountId: id, inbox: inbox, archiveId: "\(id):Archive", mock: mock))
        }
        await manager.clearRecentlyCompletedForTesting()
        let state = AccountManagerState.shared
        let saved = (state.syncErrorBanner, state.lastSyncCompletedAt, state.lastSyncFailed)
        defer {
            state.syncErrorBanner = saved.0
            state.lastSyncCompletedAt = saved.1
            state.lastSyncFailed = saved.2
        }
        var thrown: Error?
        do { try await body(pool, members) } catch { thrown = error }
        for member in members {
            await manager.syncEngine.remove(accountId: member.accountId)
            await manager.unregisterProviderForTesting(accountId: member.accountId)
        }
        await manager.clearRecentlyCompletedForTesting()
        await UnreadCountManager.shared.awaitIdleForTesting()
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        if let thrown { throw thrown }
    }

    /// The server's reader: "old" in Archive is now read.
    private static func markOldRead(_ member: Member) async {
        let archiveId = member.archiveId
        await member.mock.setChangeReader { _, request in
            var record = ChangeRecord(messageId: "old")
            record.isRead = true
            return ChangeSet(account: .set("200"), folderList: nil, folders: request.folders.map {
                FolderChanges(folderId: $0.id, status: .tracked, addressEpoch: nil,
                              records: $0.id == archiveId ? [record] : [], removals: [])
            })
        }
    }

    private static func oldIsRead(_ member: Member, _ pool: DatabasePool) throws -> Bool? {
        try pool.read { db in
            try MessageHeader
                .filter(Column("messageId") == "old" && Column("folderId") == member.archiveId)
                .fetchOne(db)?.isRead
        }
    }

    @Test("a message marked read elsewhere, in a folder not on screen, shows read after the pull")
    func pullAppliesTheServersChanges() async throws {
        try await withAccounts(1) { pool, members in
            let member = try #require(members.first)
            await Self.markOldRead(member)
            await InboxViewModel(folders: [member.inbox]).refreshSync()
            let read = try Self.oldIsRead(member, pool)
            #expect(read == true,
                    "the pull re-listed the inbox only; the change to the Archive message did not land")
        }
    }

    @Test("one account's failing change read does not stop the other account's changes, in either order")
    func failingChangeReadDoesNotStopTheOtherAccount() async throws {
        for failingFirst in [true, false] {
            try await withAccounts(2) { pool, members in
                guard members.count == 2 else { return }
                let failing = members[failingFirst ? 0 : 1]
                let healthy = members[failingFirst ? 1 : 0]
                await failing.mock.setChangeReader { _, _ in
                    throw NSError(domain: "com.example.test", code: 12)
                }
                await Self.markOldRead(healthy)
                await InboxViewModel(folders: members.map(\.inbox)).refreshSync()
                let healthyRead = try Self.oldIsRead(healthy, pool)
                let failingRead = try Self.oldIsRead(failing, pool)
                #expect(healthyRead == true,
                        "the healthy account's change did not land (failing account first: \(failingFirst))")
                #expect(failingRead == false)
            }
        }
    }
}
