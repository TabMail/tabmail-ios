/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@testable import TabMail

/// Shared setup and observations for the Gmail/Exchange backfill page-walk
/// suites (`BackfillPageWalkTokenTests`, `BackfillPageWalkFailureTests`), and
/// the checkpoint chaining and position oracle of the IMAP UID walk's suites
/// (`BackfillUIDWalkRaceTests`, `BackfillInsertFailureTests`).
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

    /// Insert a header for `messageId` straight into the database, as a path
    /// other than the page walk (scrolling to older mail, another walker) does.
    static func insertHeader(_ messageId: String, accountId: String, path: String, pool: DatabasePool) throws {
        try pool.write { db in
            var header = MessageHeader(
                messageId: messageId, subject: "inserted \(messageId)", from: "Sender",
                fromAddress: "sender@example.com", to: "recipient@example.com",
                date: daysAgo(1), snippet: "inserted",
                folderId: "\(accountId):\(path)", accountId: accountId, folderPath: path,
                isInInbox: false
            )
            header.rfc822MessageId = "\(messageId)@example.com"
            header.headerComplete = true
            try header.insert(db)
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

    // MARK: - Interleaving a walk (`SyncEngine.BackfillWalkCheckpointForTesting`)

    /// Run `body` at the `number`th time any walker reaches `checkpoint`; the
    /// earlier arrivals run through. One-shot, like every walk checkpoint: a
    /// second walker reaching the checkpoint while `body` runs goes straight
    /// through.
    static func atCheckpoint(
        _ number: Int, _ checkpoint: SyncEngine.BackfillWalkCheckpointForTesting,
        _ body: @escaping @Sendable () async -> Void
    ) {
        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock {
            $0[checkpoint] = {
                if number <= 1 {
                    await body()
                } else {
                    BackfillPageWalkFixture.atCheckpoint(number - 1, checkpoint, body)
                }
            }
        }
    }

    static func clearWalkCheckpoints() {
        SyncEngine.backfillWalkCheckpointHooksForTesting.withLock { $0.removeAll() }
    }

    // MARK: - Invariant on the IMAP walk's saved position

    /// The IMAP UID walk's position claims everything above it was loaded: a
    /// complete folder holds every UID the server lists, and a cursor at C
    /// holds every listed UID above C (the walk runs from UIDNEXT down to 1 and
    /// never looks above its cursor again). An incomplete folder with no cursor
    /// claims nothing. Returns what is wrong, or nil. `local` and `server` are
    /// UIDs.
    static func uidPositionClaimsMissingMail(_ folder: Folder, local: Set<Int>, server: [Int]) -> String? {
        let claimed: [Int]
        let position: String
        if folder.backfillComplete {
            claimed = server
            position = "complete"
        } else if let cursor = folder.backfillUidCursor {
            claimed = server.filter { $0 > cursor }
            position = "cursor \(cursor)"
        } else {
            return nil
        }
        let missing = claimed.filter { !local.contains($0) }.sorted()
        guard !missing.isEmpty else { return nil }
        return "the walk stands at \(position) but UIDs \(missing) above that point are not loaded"
    }

    /// Graph listing requests for `folderId`'s messages, failed and refused ones included.
    static func graphListRequests(_ server: StatefulExchangeActionServer, folderId: String) -> Int {
        server.http.recordedCalls().filter { call in
            guard call.method == "GET", let url = URL(string: call.url) else { return false }
            return url.path.hasSuffix("/mailFolders/\(folderId)/messages")
        }.count
    }
}
