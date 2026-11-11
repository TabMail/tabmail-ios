/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@testable import TabMail

/// Shared setup and observations for the Gmail/Exchange backfill page-walk
/// suites (`BackfillPageWalkTokenTests`, `BackfillPageWalkFailureTests`).
enum BackfillPageWalkFixture {
    /// Safety stop for a regressed walk; a correct one needs well under a second per folder.
    static let safetySeconds: TimeInterval = 20
    /// Messages per listing page, so three messages span two pages.
    static let pageSize = 2

    static func deadline() -> Date { Date().addingTimeInterval(safetySeconds) }

    static func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    static func gmailSeed(_ id: String, label: String, daysAgo days: Double) -> StatefulGmailActionServer.Seed {
        StatefulGmailActionServer.Seed(
            rfc822MessageId: "\(id)@example.com", providerMessageId: id, labels: [label],
            internalDate: daysAgo(days))
    }

    static func exchangeSeed(_ id: String, folderId: String, daysAgo days: Double) -> StatefulExchangeActionServer.Seed {
        StatefulExchangeActionServer.Seed(
            rfc822MessageId: "\(id)@example.com", providerMessageId: id, folderId: folderId,
            receivedAt: daysAgo(days))
    }

    static func registeredEngine(accountId: String, provider: any EmailProvider) async -> SyncEngine {
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: provider,
            workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        return engine
    }

    static func setSavedToken(_ token: String, accountId: String, path: String, pool: DatabasePool) throws {
        try pool.write { db in
            _ = try Folder.filter(Column("id") == "\(accountId):\(path)")
                .updateAll(db, Column("backfillPageToken").set(to: token))
        }
    }

    static func folder(_ accountId: String, _ path: String, pool: DatabasePool) throws -> Folder? {
        try FolderEpochTestFixture.readFolder(accountId: accountId, path: path, pool: pool)
    }

    static func messageIds(_ accountId: String, _ path: String, pool: DatabasePool) throws -> Set<String> {
        try pool.read { db in
            try String.fetchSet(db, MessageHeader
                .select(Column("messageId"))
                .filter(Column("folderId") == "\(accountId):\(path)"))
        }
    }

    /// Gmail `messages.list` requests naming `label`, failed and refused ones included.
    static func gmailListRequests(_ server: StatefulGmailActionServer, label: String) -> Int {
        gmailListRequestURLs(server, label: label).count
    }

    /// The `pageToken` of every Gmail `messages.list` request naming `label`, in
    /// order (nil for a request without one).
    static func gmailListPageTokens(_ server: StatefulGmailActionServer, label: String) -> [String?] {
        gmailListRequestURLs(server, label: label).map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageToken" })?.value
        }
    }

    private static func gmailListRequestURLs(_ server: StatefulGmailActionServer, label: String) -> [URL] {
        server.http.recordedCalls().compactMap { call in
            guard call.method == "GET", let url = URL(string: call.url) else { return nil }
            return url.path.hasSuffix("/messages") && call.url.contains("labelIds=\(label)") ? url : nil
        }
    }

    /// Graph listing requests for `folderId`'s messages, failed and refused ones included.
    static func graphListRequests(_ server: StatefulExchangeActionServer, folderId: String) -> Int {
        server.http.recordedCalls().filter { call in
            guard call.method == "GET", let url = URL(string: call.url) else { return false }
            return url.path.hasSuffix("/mailFolders/\(folderId)/messages")
        }.count
    }
}
