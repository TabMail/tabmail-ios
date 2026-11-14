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
/// listing throws while the other accounts' listings are in flight. The refresh
/// still reports the failure as one outcome for the run (`lastSyncFailed`, and
/// the generic banner when the error counts; a sign-in refusal is carried by the
/// sign-in mark instead): the app has no per-account sync-failure state.
@Suite("Pull-to-refresh: one account's failure does not stop the others", .serialized, .processGlobalState,
       .timeLimit(.minutes(2)))
@MainActor
struct RefreshAccountIsolationTests {

    /// How an account behaves in one refresh.
    private enum Role: CaseIterable { case healthy, connectFails, syncFails }

    private struct Member {
        let account: Account
        let inbox: Folder
        let role: Role
        let provider: MockEmailProvider?
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

    /// Builds the accounts, runs `body`, and tears everything down.
    private func withAccounts(
        _ roles: [Role],
        _ body: (DatabasePool, [Member]) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let suffix = UUID().uuidString.prefix(8)
        var members: [Member] = []
        for (index, role) in roles.enumerated() {
            // An IMAP account with no server cannot connect; the mocks stand in for
            // accounts that are already connected.
            let id = "isolation-\(index)-\(suffix)"
            let account = try FolderEpochTestFixture.makeAccount(
                id: id, provider: role == .connectFails ? .imap : .gmail, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: id, path: "INBOX", role: .inbox, pool: pool)
            let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: id, path: "INBOX", pool: pool))
            var provider: MockEmailProvider?
            if role != .connectFails {
                let mock = MockEmailProvider()
                if role == .syncFails {
                    await mock.setFetchMessagesThrows(NSError(domain: "com.example.test", code: 11))
                } else {
                    await mock.setFetchMessagesResult([Self.message("\(index + 1)")])
                }
                await AccountManager.shared.registerProviderForTesting(accountId: id, provider: mock)
                provider = mock
            }
            members.append(Member(account: account, inbox: inbox, role: role, provider: provider))
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
            await AccountManager.shared.unregisterProviderForTesting(accountId: member.account.id)
            await AccountManager.shared.clearAuthFailed(member.account.id)
        }
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

    /// Seeded interleavings: three accounts, each healthy, unable to connect, or
    /// failing its listing; each listing answers after a seeded delay; the folders
    /// are listed in a seeded order. Every healthy account's mail must arrive, and
    /// the refresh reports a failure exactly when some account failed.
    @Test("seeded interleavings: every healthy account is refreshed", arguments: 0..<32)
    func seededInterleavings(seed: Int) async throws {
        var rng = SplitMix64(seed: UInt64(seed) &+ 0x689)
        let roles = (0..<3).map { _ in Role.allCases[rng.pick(Role.allCases.count)] }
        let delaysMs = roles.map { _ in rng.pick(25) }
        let order = Array(0..<roles.count).shuffled(using: &rng)
        try await withAccounts(roles) { pool, members in
            for (member, delay) in zip(members, delaysMs) {
                await member.provider?.setFetchMessagesHook { _ in
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
            await InboxViewModel(folders: order.map { members[$0].inbox }).refreshSync()
            for member in members where member.role == .healthy {
                let count = try Self.inboxCount(member, pool)
                #expect(count == 1,
                        "seed \(seed) roles \(roles) delays \(delaysMs) order \(order): \(member.account.id) was not refreshed")
            }
            #expect(AccountManagerState.shared.lastSyncFailed == roles.contains { $0 != .healthy },
                    "seed \(seed) roles \(roles): the refresh misreported its outcome")
        }
    }
}
