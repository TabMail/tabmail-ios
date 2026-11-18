/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// On-demand folder sync (`AccountManager.syncFolders(_:connecting:)`) skips a folder whose
/// sync answers HTTP 404 or 410 instead of surfacing an error and abandoning the
/// folders after it.
///
/// The Gmail and Outlook providers report an HTTP status as
/// `ProviderError.networkError(underlying: HTTPError.networkError(statusCode:))`.
/// `HTTPError` has no `CustomNSError` conformance, so its bridged `NSError.code`
/// is the enum case index, not the status: a check that reads the bridged code
/// never sees the 404. These tests throw exactly that shape.
@Suite("Folder sync skips a folder the provider reports gone", .serialized, .processGlobalState)
struct FolderSyncGoneStatusTests {

    private static func httpError(_ status: Int) -> Error {
        ProviderError.networkError(underlying: HTTPError.networkError(statusCode: status))
    }

    private struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let accountId: String
        let folders: [Folder]
        let provider: MockEmailProvider
    }

    private static func makeFixture(accountId: String, error: Error) async throws -> Fixture {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "Archive", role: .archive, pool: pool)
        let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool))
        let archive = try #require(try FolderEpochTestFixture.readFolder(accountId: accountId, path: "Archive", pool: pool))

        let provider = MockEmailProvider()
        await provider.setFetchMessagesThrows(error)
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        return Fixture(pool: pool, dir: dir, previous: previous, accountId: accountId,
                       folders: [inbox, archive], provider: provider)
    }

    private static func tearDown(_ f: Fixture) async {
        await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId)
        AppDatabase.shared.withLock { $0 = f.previous }
        TestDatabaseTeardown.retire(pool: f.pool, directory: f.dir)
    }

    private static func fetchedFolders(_ provider: MockEmailProvider) async -> [String] {
        await provider.callLog.compactMap { entry in
            guard entry.hasPrefix("fetchMessages(folder:") else { return nil }
            return entry.dropFirst("fetchMessages(folder:".count).split(separator: ",").first.map(String.init)
        }
    }

    @Test("A gone folder is skipped and the folders after it still sync", arguments: [404, 410])
    func aGoneFolderIsSkippedAndTheFoldersAfterItStillSync(status: Int) async throws {
        let f = try await Self.makeFixture(accountId: "gone-\(status)", error: Self.httpError(status))

        var surfaced: Error?
        do {
            try await AccountManager.shared.syncFolders(f.folders, connecting: [])
        } catch {
            surfaced = error
        }
        let fetched = await Self.fetchedFolders(f.provider)
        await Self.tearDown(f)

        #expect(surfaced == nil, "an HTTP \(status) means the folder is gone; it must not reach the user as a sync error, got \(String(describing: surfaced))")
        #expect(fetched.contains("INBOX"), "the gone folder was attempted, got \(fetched)")
        #expect(fetched.contains("Archive"), "a gone folder must not abandon the folders after it, got \(fetched)")
    }

    @Test("A status that does not mean gone still reaches the caller")
    func aStatusThatDoesNotMeanGoneStillReachesTheCaller() async throws {
        let f = try await Self.makeFixture(accountId: "not-gone-500", error: Self.httpError(500))

        var surfaced: Error?
        do {
            try await AccountManager.shared.syncFolders(f.folders, connecting: [])
        } catch {
            surfaced = error
        }
        await Self.tearDown(f)

        #expect(surfaced != nil, "only 404 and 410 are skipped; any other status is the caller's to classify")
    }

    @Test("An IMAP listing whose EXISTS 0 its SEARCH did not confirm (contradicted or refused) is skipped and the folders after it still sync",
          arguments: [nil, "Injected refusal"] as [String?])
    func anUnconfirmedListingCountIsSkippedAndTheFoldersAfterItStillSync(refusal: String?) async throws {
        let f = try await Self.makeFixture(
            accountId: "unconfirmed-\(refusal == nil ? "contradicted" : "refused")",
            error: ProviderListingUnconfirmed(folder: "INBOX", refusal: refusal))

        var surfaced: Error?
        do {
            try await AccountManager.shared.syncFolders(f.folders, connecting: [])
        } catch {
            surfaced = error
        }
        let fetched = await Self.fetchedFolders(f.provider)
        await Self.tearDown(f)

        #expect(surfaced == nil, "one folder's unconfirmed listing must not fail the sync, got \(String(describing: surfaced))")
        #expect(fetched.contains("INBOX"), "the folder was attempted, got \(fetched)")
        #expect(fetched.contains("Archive"), "one folder's unconfirmed listing must not abandon the folders after it, got \(fetched)")
    }

    @Test("A lost connection during a pull-to-refresh ends it with that error and publishes nothing")
    func aLostConnectionEndsTheRefreshWithItsErrorAndPublishesNothing() async throws {
        let lost = URLError(.networkConnectionLost)
        let f = try await Self.makeFixture(accountId: "lost-connection", error: lost)
        let before = try f.folders.map { try #require(try FolderEpochTestFixture.readFolder(accountId: f.accountId, path: $0.path, pool: f.pool)) }
        let headersBefore = try await f.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader") ?? 0 }

        var surfaced: Error?
        do {
            try await AccountManager.shared.syncFolders(f.folders, connecting: [])
        } catch {
            surfaced = error
        }
        let after = try f.folders.map { try #require(try FolderEpochTestFixture.readFolder(accountId: f.accountId, path: $0.path, pool: f.pool)) }
        let headersAfter = try await f.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messageHeader") ?? 0 }
        await Self.tearDown(f)

        #expect((surfaced as? URLError)?.code == .networkConnectionLost,
                "a lost connection must reach the user as the same error it did before, got \(String(describing: surfaced))")
        #expect(after == before, "an unproven listing must publish no folder state")
        #expect(headersAfter == headersBefore, "an unproven listing must publish no rows")
    }
}
