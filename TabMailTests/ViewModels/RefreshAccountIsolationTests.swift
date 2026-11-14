/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A pull-to-refresh of several accounts (`InboxViewModel.refreshSync`) refreshes
/// every account that can be refreshed, whatever happens to the others.
///
/// The property asserted is the user's: a healthy account's new mail is in the
/// database when the refresh ends. Two ways an account fails are covered: it
/// cannot connect (an IMAP account with no server, unregistered, so
/// `AccountManager.connectAccount` throws before any network), and its folder
/// listing throws while the other accounts' listings are in flight. An account
/// with no provider yet connects in the refresh itself, against a local
/// `FakeIMAPServer`, and its mail must arrive too; a slow one (its greeting held)
/// must not hold back the others. The refresh
/// still reports the failure as one outcome for the run (`lastSyncFailed`, and
/// the generic banner when the error counts; a sign-in refusal is carried by the
/// sign-in mark instead): the app has no per-account sync-failure state.
@Suite("Pull-to-refresh: one account's failure does not stop the others", .serialized, .processGlobalState,
       .timeLimit(.minutes(2)))
@MainActor
struct RefreshAccountIsolationTests {

    /// How an account behaves in one refresh.
    /// - `healthy`: already connected (a registered mock); its listing succeeds.
    /// - `connects`: no provider yet; it connects in the refresh to a local
    ///   `FakeIMAPServer`, then syncs.
    /// - `slowConnect`: as `connects`, but the server holds its greeting until the
    ///   test releases it.
    /// - `connectFails`: an IMAP account with no server; its connect throws.
    /// - `syncFails`: already connected; its listing throws.
    private enum Role { case healthy, connects, slowConnect, connectFails, syncFails }

    /// The roles the seeded test draws from (a slow connect needs the test to
    /// release it, so it has its own test).
    private static let fuzzRoles: [Role] = [.healthy, .connects, .connectFails, .syncFails]

    /// Roles whose mail must arrive.
    private static func succeeds(_ role: Role) -> Bool {
        role == .healthy || role == .connects || role == .slowConnect
    }

    private struct Member {
        let account: Account
        let inbox: Folder
        let role: Role
        let provider: MockEmailProvider?
        let server: FakeIMAPServer?
    }

    /// Opened once; waiters poll it. A test-only rendezvous between two mocks.
    private actor Latch {
        private var opened = false
        func open() { opened = true }
        func wait() async {
            while !opened { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    private static func message(_ uid: String) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: uid, rfc822MessageId: "isolation-\(uid)@example.com", inReplyTo: nil,
            references: [], threadId: nil, subject: "isolation \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: Date().addingTimeInterval(-3_600), snippet: "isolation",
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    /// One message in the IMAP INBOX of a `connects` account, dated an hour ago.
    private static func imapMessage(_ tag: String) -> FakeIMAPServer.Message {
        let date = FixedDateFormat.formatter("EEE, dd MMM yyyy HH:mm:ss Z", timeZone: .gmt)
            .string(from: Date().addingTimeInterval(-3_600))
        return FakeIMAPServer.makeMessage(uid: 1, rfc822Text: """
            From: Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: isolation \(tag)\r
            Date: \(date)\r
            Message-ID: <isolation-\(tag)@example.com>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            isolation fixture body.\r

            """)
    }

    /// Builds the accounts, runs `body`, and tears everything down.
    private func withAccounts(
        _ roles: [Role],
        _ body: (DatabasePool, [Member]) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let manager = AccountManager.shared
        let suffix = UUID().uuidString.prefix(8)
        let usesServer = roles.contains { $0 == .connects || $0 == .slowConnect }
        // The local fake server speaks plain TCP.
        if usesServer { manager.setIMAPUseTLSOverrideForTesting(false) }
        var members: [Member] = []
        for (index, role) in roles.enumerated() {
            // An IMAP account with no server cannot connect; one pointed at a local
            // fake server connects in the refresh; the mocks stand in for accounts
            // that are already connected.
            let id = "isolation-\(index)-\(suffix)"
            let account: Account
            var server: FakeIMAPServer?
            switch role {
            case .connects, .slowConnect:
                let fake = FakeIMAPServer(mailboxes: ["INBOX": [Self.imapMessage(id)]])
                try fake.start()
                if role == .slowConnect { fake.holdGreetings() }
                var imap = Account(emailAddress: "\(id)@example.com", displayName: "Isolation", provider: .imap)
                imap.id = id
                imap.imapHost = "127.0.0.1"
                imap.imapPort = fake.port
                imap.imapUsername = fake.username
                let toInsert = imap
                try await pool.write { db in try toInsert.insert(db) }
                try KeychainHelper.save(fake.password, for: KeychainHelper.passwordKey(accountId: id))
                account = imap
                server = fake
            case .connectFails:
                account = try FolderEpochTestFixture.makeAccount(id: id, provider: .imap, pool: pool)
            case .healthy, .syncFails:
                account = try FolderEpochTestFixture.makeAccount(id: id, provider: .gmail, pool: pool)
            }
            try FolderEpochTestFixture.insertFolder(accountId: id, path: "INBOX", role: .inbox, pool: pool)
            let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: id, path: "INBOX", pool: pool))
            var provider: MockEmailProvider?
            if role == .healthy || role == .syncFails {
                let mock = MockEmailProvider()
                if role == .syncFails {
                    await mock.setFetchMessagesThrows(NSError(domain: "com.example.test", code: 11))
                } else {
                    await mock.setFetchMessagesResult([Self.message("\(index + 1)")])
                }
                await AccountManager.shared.registerProviderForTesting(accountId: id, provider: mock)
                provider = mock
            }
            members.append(Member(account: account, inbox: inbox, role: role, provider: provider, server: server))
        }
        let state = AccountManagerState.shared
        let saved = (state.syncErrorBanner, state.lastSyncCompletedAt, state.lastSyncFailed)
        // Each run starts from no failure and no banner, so what the refresh
        // reports is its own outcome.
        state.syncErrorBanner = nil
        state.lastSyncFailed = false
        defer {
            state.syncErrorBanner = saved.0
            state.lastSyncCompletedAt = saved.1
            state.lastSyncFailed = saved.2
        }
        var thrown: Error?
        do { try await body(pool, members) } catch { thrown = error }
        for member in members {
            let id = member.account.id
            if let server = member.server {
                if let live = await manager.provider(accountId: id) { try? await live.disconnect() }
                await manager.syncEngine.remove(accountId: id)
                KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: id))
                server.stop()
            }
            await manager.unregisterProviderForTesting(accountId: id)
            await manager.clearAuthFailed(id)
        }
        if usesServer { manager.setIMAPUseTLSOverrideForTesting(nil) }
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        if let thrown { throw thrown }
    }

    private static func inboxCount(_ member: Member, _ pool: DatabasePool) throws -> Int {
        try FolderEpochTestFixture.headerCount(accountId: member.account.id, path: "INBOX", pool: pool)
    }

    @Test("an account that cannot connect does not stop the other account's refresh, in either order")
    func connectFailureDoesNotStopTheOtherAccount() async throws {
        for failingFirst in [true, false] {
            try await withAccounts(failingFirst ? [.connectFails, .healthy] : [.healthy, .connectFails]) { pool, members in
                let healthy = try #require(members.first { $0.role == .healthy })
                await InboxViewModel(folders: members.map(\.inbox)).refreshSync()
                let count = try Self.inboxCount(healthy, pool)
                #expect(count == 1,
                        "the healthy account's new mail did not arrive (failing account first: \(failingFirst))")
                #expect(AccountManagerState.shared.lastSyncFailed, "the refresh hid the failing account")
                #expect(AccountManagerState.shared.syncErrorBanner == nil,
                        "a sign-in refusal is carried by the sign-in mark, never the generic banner")
            }
        }
    }

    @Test("an account whose listing fails does not cancel the other account's listing in flight")
    func syncFailureDoesNotCancelTheOtherAccount() async throws {
        try await withAccounts([.syncFails, .healthy]) { pool, members in
            let failing = try #require(members.first { $0.role == .syncFails }?.provider)
            let healthyMember = try #require(members.first { $0.role == .healthy })
            let healthy = try #require(healthyMember.provider)
            let failingStarted = Latch()
            await failing.setFetchMessagesHook { _ in await failingStarted.open() }
            // The healthy listing is still in flight when the failing one throws.
            await healthy.setFetchMessagesHook { _ in
                await failingStarted.wait()
                try? await Task.sleep(for: .milliseconds(100))
            }
            await InboxViewModel(folders: members.map(\.inbox)).refreshSync()
            let count = try Self.inboxCount(healthyMember, pool)
            #expect(count == 1, "the healthy account's new mail did not arrive")
            #expect(AccountManagerState.shared.lastSyncFailed, "the refresh hid the failing account")
            #expect(AccountManagerState.shared.syncErrorBanner == InboxErrorBanner.genericMessage,
                    "a counted sync failure raises the banner")
        }
    }

    @Test("an account with no provider yet connects in the refresh and its mail arrives, next to one that cannot connect")
    func connectingAccountIsSyncedAfterItsConnect() async throws {
        for failingFirst in [true, false] {
            try await withAccounts(failingFirst ? [.connectFails, .connects] : [.connects, .connectFails]) { pool, members in
                let connecting = try #require(members.first { $0.role == .connects })
                #expect(await AccountManager.shared.provider(accountId: connecting.account.id) == nil,
                        "the account must start with no provider, so the refresh connects it")
                await InboxViewModel(folders: members.map(\.inbox)).refreshSync()
                let count = try Self.inboxCount(connecting, pool)
                #expect(count == 1,
                        "the account that connected in the refresh was not synced (failing account first: \(failingFirst))")
                #expect(AccountManagerState.shared.lastSyncFailed, "the refresh hid the failing account")
            }
        }
    }

    /// The healthy account's mail is in the database while the slow account's
    /// connect is still waiting for its greeting: the greeting is released only
    /// after that, and the slow account then connects and syncs too. If the
    /// connects ran before the syncs, the healthy mail could only arrive after the
    /// slow connect ended, which it can do here only by timing out, and then the
    /// slow account's mail never arrives.
    @Test("a slow connect does not hold back the other account's refresh")
    func slowConnectDoesNotDelayTheOtherAccount() async throws {
        try await withAccounts([.slowConnect, .healthy]) { pool, members in
            let slow = try #require(members.first { $0.role == .slowConnect })
            let slowServer = try #require(slow.server)
            let healthy = try #require(members.first { $0.role == .healthy })
            let viewModel = InboxViewModel(folders: members.map(\.inbox))
            let refresh = Task { await viewModel.refreshSync() }
            // Release the greeting only once the healthy mail is in AND the slow
            // connect is waiting on it.
            while try Self.inboxCount(healthy, pool) == 0 || slowServer.heldGreetingCount() == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            slowServer.releaseGreetings()
            await refresh.value
            let slowCount = try Self.inboxCount(slow, pool)
            #expect(slowCount == 1,
                    "the slow account did not connect and sync after its greeting was released, so the healthy mail waited for its connect")
            #expect(!AccountManagerState.shared.lastSyncFailed, "every account synced, yet the refresh reported a failure")
        }
    }

    /// Seeded interleavings: three accounts, each healthy, connecting in the
    /// refresh, unable to connect, or failing its listing; each listing answers after a seeded delay; the folders
    /// are listed in a seeded order. Every healthy account's mail must arrive, and
    /// the refresh reports a failure exactly when some account failed.
    @Test("seeded interleavings: every account that can be refreshed is refreshed", arguments: 0..<32)
    func seededInterleavings(seed: Int) async throws {
        var rng = SplitMix64(seed: UInt64(seed) &+ 0x689)
        let roles = (0..<3).map { _ in Self.fuzzRoles[rng.pick(Self.fuzzRoles.count)] }
        let delaysMs = roles.map { _ in rng.pick(25) }
        let order = Array(0..<roles.count).shuffled(using: &rng)
        try await withAccounts(roles) { pool, members in
            for (member, delay) in zip(members, delaysMs) {
                await member.provider?.setFetchMessagesHook { _ in
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
            await InboxViewModel(folders: order.map { members[$0].inbox }).refreshSync()
            for member in members where Self.succeeds(member.role) {
                let count = try Self.inboxCount(member, pool)
                #expect(count == 1,
                        "seed \(seed) roles \(roles) delays \(delaysMs) order \(order): \(member.account.id) was not refreshed")
            }
            #expect(AccountManagerState.shared.lastSyncFailed == roles.contains { !Self.succeeds($0) },
                    "seed \(seed) roles \(roles): the refresh misreported its outcome")
        }
    }
}
