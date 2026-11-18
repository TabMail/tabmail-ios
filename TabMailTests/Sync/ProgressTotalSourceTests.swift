/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Backfill progress has its own source per provider (`progressTotal`), held in
/// memory from requests the provider makes anyway, and Fast Sync's completion
/// fails closed across accounts.
@Suite("Backfill progress totals per provider", .serialized, .processGlobalState)
struct ProgressTotalSourceTests {

    // MARK: - Gmail: the profile's total, asked only while crawling

    @Test("Gmail: no request when not crawling; a failed or zero profile read answers none and is asked again; the first total is kept with no further request")
    func gmailProfileTotalIsCachedOnlyOnSuccess() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let step = Mutex(0)
        http.register(path: "/gmail/v1/users/me/profile") { _ in
            let n = step.withLock { value -> Int in value += 1; return value }
            switch n {
            // 400, not 403: the Gmail request layer retries 403 as a rate limit,
            // which would spend the next scripted answer inside the same read.
            case 1: return .status(400)
            case 2: return .json(raw: #"{"emailAddress":"user@example.com","messagesTotal":0,"historyId":"1"}"#)
            default: return .json(raw: #"{"emailAddress":"user@example.com","messagesTotal":42,"historyId":"1"}"#)
            }
        }
        let provider = GmailProvider(userEmail: "user@example.com", accessToken: { _ in "token" }, session: http.session)
        #expect(await provider.progressTotal(crawling: false) == .none)
        #expect(step.withLock { $0 } == 0, "not crawling: no profile request")
        #expect(await provider.progressTotal(crawling: true) == .none, "a failed read answers none")
        #expect(step.withLock { $0 } == 1, "the failed read was one request")
        #expect(await provider.progressTotal(crawling: true) == .none, "a zero total answers none")
        #expect(await provider.progressTotal(crawling: true) == .messages(42))
        let asked = step.withLock { $0 }
        #expect(asked == 3, "each read before a success was asked again")
        #expect(await provider.progressTotal(crawling: true) == .messages(42))
        #expect(step.withLock { $0 } == asked, "the first total is kept: no further request")
    }

    // MARK: - IMAP: STATUS UIDNEXT per folder from the folder list

    @Test("IMAP: a folder whose STATUS gives no UIDNEXT keeps its earlier value; a folder gone from the list drops out")
    func imapFolderListCacheRetainsAndEvicts() async throws {
        let server = FakeIMAPServer(capabilities: FakeIMAPServer.defaultCapabilities,
                                    mailboxes: ["INBOX": [1, 2].map(IMAPChangeReaderTests.message),
                                                "Archive": [1, 2, 3].map(IMAPChangeReaderTests.message)])
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        #expect(await provider.progressTotal(crawling: true) == .notKnownYet)
        _ = try await provider.fetchFolders()
        guard case .uidNext(let first) = await provider.progressTotal(crawling: true) else {
            Issue.record("a folder list gives UIDNEXT per folder"); return
        }
        #expect(first["Archive"] == 4 && first["INBOX"] == 3)

        server.setMessages([1, 2, 3, 4, 5].map(IMAPChangeReaderTests.message), in: "Archive")
        server.setStatusOmits(["UIDNEXT"], for: "Archive")
        _ = try await provider.fetchFolders()
        guard case .uidNext(let second) = await provider.progressTotal(crawling: true) else {
            Issue.record("still a UIDNEXT map"); return
        }
        #expect(second["Archive"] == 4, "no UIDNEXT this time: the earlier value is kept")

        server.markMailboxDeleted("Archive", includeNonexistentCode: true)
        _ = try await provider.fetchFolders()
        guard case .uidNext(let third) = await provider.progressTotal(crawling: true) else {
            Issue.record("still a UIDNEXT map"); return
        }
        #expect(third["Archive"] == nil, "a folder gone from the list drops out")
        #expect(third["INBOX"] == 3)
    }

    // MARK: - The full sync lists folders for a cold provider

    @Test("A full sync with this pass's folder list applied still lists folders when the provider has no total yet (cold), and does not when it has one (warm)",
          arguments: [true, false])
    func coldProviderForcesTheFolderList(_ cold: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let account = try FolderEpochTestFixture.makeAccount(id: "cold-\(cold)", provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account.id, path: "INBOX", role: .inbox, pool: pool)
        let mock = MockEmailProvider()
        await mock.setProgressTotalAnswer(cold ? .notKnownYet : .messages(5))
        await mock.setFetchFoldersResult([
            FolderInfo(name: "INBOX", path: "INBOX", role: .inbox, unreadCount: 0, totalCount: 0,
                       uidNext: nil, highestModSeq: nil, uidValidity: nil)
        ])
        await mock.setFetchMessagesResult([])
        _ = try await SyncEngine().fullSync(
            account: account, provider: mock, plan: SyncEngine.FullSyncPlan(appliedFolderList: ["INBOX"]))
        let listed = await mock.callLogSnapshot().contains("fetchFolders")
        #expect(listed == cold, cold ? "a cold provider gets a complete folder list" : "a warm provider uses the applied list")
    }

    // MARK: - Fast Sync completion across accounts

    static func progress(_ id: String, complete: Bool) -> BackfillProgress {
        var p = BackfillProgress(accountId: id, email: "\(id)@example.com", startedAt: Date(), isPaused: false,
                                 headersDone: true, totalEmails: 10, ftsIndexed: 10)
        p.pendingBodyCount = complete ? 0 : 1
        return p
    }

    @Test("Fast Sync is complete only when every current account has published complete progress")
    func fastSyncCompletionAcrossAccounts() {
        let done = ["a": Self.progress("a", complete: true), "b": Self.progress("b", complete: true)]
        #expect(FastSyncView.allAccountsComplete(accountIds: ["a", "b"], progress: done))
        #expect(!FastSyncView.allAccountsComplete(accountIds: [], progress: done), "no accounts: not complete")
        #expect(!FastSyncView.allAccountsComplete(accountIds: ["a", "b", "c"], progress: done),
                "an account with no progress published yet is not complete")
        var oneBehind = done
        oneBehind["b"] = Self.progress("b", complete: false)
        #expect(!FastSyncView.allAccountsComplete(accountIds: ["a", "b"], progress: oneBehind),
                "one incomplete account keeps it incomplete")
        #expect(FastSyncView.allAccountsComplete(accountIds: ["a"], progress: oneBehind),
                "a removed account's stale progress does not count")
    }
}
