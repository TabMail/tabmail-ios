/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// After an update, a retired action's optimistic local state shows the server's
/// state again, also in a folder the change reader tracks (#876).
///
/// The release boundary (`AppDatabase.retirePreviousReleaseActionQueue`) deletes
/// every queued action. A tracked folder gets no window listing (ADR-IOS-111), so
/// the full sync the boundary makes due no longer corrects it there. The
/// invariant pinned here: once the boundary has run and the next sync has read
/// the changes, every message a retired action touched is where the server has
/// it, with the server's read state, and no folder was listed to get there. A row
/// the current model cannot decode, or a re-read list that is full, arms the
/// folder's catch-up instead.
///
/// Worlds: a real `GmailProvider` against `StatefulGmailActionServer`
/// (`GmailDeltaApplyInvariantTests.World`) and a real `ExchangeProvider` against
/// `StatefulExchangeActionServer` (`OutlookChangeReadingTests.World`).
///
/// `.serialized, .processGlobalState`: the worlds replace `AppDatabase.shared`.
@Suite("Release boundary: retired actions are read again", .serialized, .processGlobalState)
struct ReleaseBoundaryRecheckTests {
    typealias Gmail = GmailDeltaApplyInvariantTests
    typealias Outlook = OutlookChangeReadingTests

    /// A release that is not the one recorded: the boundary fires.
    static func nextRelease() -> String { "next-release-\(UUID().uuidString)" }

    static func recheck(_ pool: DatabasePool, folderId: String) throws -> [String] {
        FolderChangeState(raw: try pool.read { db in try Folder.fetchOne(db, key: folderId)?.changeState }).recheck
    }

    static func tracking(_ pool: DatabasePool, folderId: String) throws -> Bool {
        FolderChangeState(raw: try pool.read { db in try Folder.fetchOne(db, key: folderId)?.changeState }).tracking
    }

    /// The lapse count of a folder's catch-up state (nil: none marked).
    static func lapseCount(_ pool: DatabasePool, folderId: String) throws -> Int? {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT json_extract(catchUpState, '$.' || ?) FROM folder WHERE id = ?",
                             arguments: [CatchUpLapse.countKey, folderId])
        }
    }

    /// The optimistic local effect of a move, as `optimisticMoveToFolder` writes
    /// it: the row keeps its id and message id and now sits in the destination.
    static func moveRowOptimistically(_ pool: DatabasePool, headerId: String, to folder: Folder) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE messageHeader SET folderId = ?, folderPath = ?, isInInbox = ? WHERE id = ?",
                           arguments: [folder.id, folder.path, folder.role == .inbox, headerId])
        }
    }

    static func queue(
        _ pool: DatabasePool, _ type: OperationType, ids: [String], accountId: String,
        from path: String, to destination: String? = nil
    ) throws {
        var op = PendingOperation(
            type: type, messageIds: ids, accountId: accountId, folderPath: path, destinationPath: destination)
        try pool.write { db in try op.insert(db) }
    }

    // MARK: - Gmail

    @Test("Gmail: an archive and a mark-read cleared at the update show the server's state after the next sync, with no folder listed")
    func gmailRetiredMoveAndReadAreReadAgain() async throws {
        try await Gmail.withWorld(seeds: [
            Gmail.seed("rb-archive", labels: ["INBOX"]),
            Gmail.seed("rb-read", labels: ["INBOX", "UNREAD"]),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            #expect(try Self.tracking(w.pool, folderId: w.inbox.id), "precondition: the Inbox is tracked")
            #expect(try Self.tracking(w.pool, folderId: w.allMail.id), "precondition: All Mail is tracked")
            let archived = try #require(try w.row("rb-archive", in: w.inbox), "precondition: listed")
            let read = try #require(try w.row("rb-read", in: w.inbox), "precondition: listed")
            #expect(read.isRead == false, "precondition: unread on the server and here")

            // The gestures' optimistic effects, queued and never sent.
            try Self.moveRowOptimistically(w.pool, headerId: archived.id, to: w.allMail)
            try Self.queue(w.pool, .archive, ids: ["rb-archive"], accountId: w.accountId,
                           from: w.inbox.path, to: w.allMail.path)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [read.id])
            }
            try Self.queue(w.pool, .markRead, ids: ["rb-read"], accountId: w.accountId, from: w.inbox.path)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.pendingOps().isEmpty, "the boundary retired the queue")
            #expect(Set(try Self.recheck(w.pool, folderId: w.inbox.id)) == ["rb-archive", "rb-read"],
                    "the source folder lists every retired id")
            #expect(try Self.recheck(w.pool, folderId: w.allMail.id) == ["rb-archive"],
                    "the move's destination lists its id")

            let listingsBefore = GmailChangeReadingTests.windowListings(w)
            let catchUpsBefore = GmailChangeReadingTests.catchUpListings(w).count
            try await w.foregroundPassWithFullSyncDue()

            #expect(try w.row("rb-archive", in: w.inbox) != nil, "the archived message is back in the Inbox, as on the server")
            #expect(try w.row("rb-archive", in: w.allMail) == nil, "and no longer shown in All Mail")
            #expect(try w.row("rb-read", in: w.inbox)?.isRead == false, "the message shows unread again, as on the server")
            #expect(GmailChangeReadingTests.windowListings(w) == listingsBefore, "no window listing")
            #expect(GmailChangeReadingTests.catchUpListings(w).count == catchUpsBefore, "no catch-up listing")
            #expect(try Self.recheck(w.pool, folderId: w.inbox.id).isEmpty)
            #expect(try Self.recheck(w.pool, folderId: w.allMail.id).isEmpty)
        }
    }

    // MARK: - Outlook

    @Test("Outlook: a move cleared at the update lists the id in source and destination, and the next sync shows the server's state with no folder listed")
    func outlookRetiredMoveIsReadAgainInBothFolders() async throws {
        try await Outlook.withWorld(seeds: [Outlook.seed("ob-move", in: Outlook.inbox, daysAgo: 1)]) { w in
            try await w.foregroundPass()
            try await w.foregroundPass()
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.inbox)), "precondition: the Inbox is tracked")
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.archive)), "precondition: the Archive is tracked")
            let moved = try #require(try w.row("ob-move", in: w.inbox), "precondition: listed")

            // Unsent move: the row sits in the Archive under the Inbox id, which
            // is still the server's id for the message (in the Inbox).
            try Self.moveRowOptimistically(w.pool, headerId: moved.id, to: try w.folder(w.archive))
            try Self.queue(w.pool, .move, ids: ["ob-move"], accountId: w.accountId, from: w.inbox, to: w.archive)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.recheck(w.inbox) == ["ob-move"], "the source lists the id")
            #expect(try w.recheck(w.archive) == ["ob-move"], "the destination lists the id: Outlook reads folder by folder")

            let listingsBefore = Self.outlookListings(w)
            try await w.foregroundPass()

            #expect(try w.row("ob-move", in: w.inbox) != nil, "the message is back in the Inbox, as on the server")
            #expect(try w.row("ob-move", in: w.archive) == nil, "and no longer shown in the Archive")
            #expect(Self.outlookListings(w) == listingsBefore, "no folder listing")
            #expect(try w.recheck(w.inbox).isEmpty)
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    /// Folder message listings (`/mailFolders/{id}/messages`, not the delta).
    static func outlookListings(_ w: Outlook.World) -> Int {
        w.server.http.recordedCalls().filter {
            $0.method == "GET" && $0.url.contains("/mailFolders/") && $0.url.contains("/messages")
                && !$0.url.contains("/messages/delta")
        }.count
    }

    // MARK: - Rows that cannot be read, and a full list

    /// Seed every folder of the world with a catch-up state, so a lapse mark
    /// shows (a NULL state already means a full check is due).
    static func seedCatchUpStates(_ pool: DatabasePool, accountId: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE accountId = ?", arguments: [accountId])
        }
    }

    static func makeUndecodable(_ pool: DatabasePool, accountId: String, folderPath: String) throws {
        var op = PendingOperation(type: .markRead, messageIds: ["placeholder"], accountId: accountId, folderPath: folderPath)
        try pool.write { db in
            try op.insert(db)
            try db.execute(sql: """
                UPDATE pendingOperation SET type = 'kindFromAnOlderRelease', messageIdsJSON = '<not json>' WHERE id = ?
                """, arguments: [op.id])
        }
    }

    @Test("A retired row this release cannot decode arms its folder's catch-up, or every folder's when its folder is unknown")
    func undecodableRowArmsTheCatchUp() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try Self.makeUndecodable(w.pool, accountId: w.accountId, folderPath: w.inbox.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.pendingOps().isEmpty, "the undecodable row is retired, not kept")
            #expect(try Self.lapseCount(w.pool, folderId: w.inbox.id) == 1, "its folder's catch-up is armed")
            #expect(try Self.lapseCount(w.pool, folderId: w.allMail.id) == nil, "no other folder's")
        }
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try Self.makeUndecodable(w.pool, accountId: w.accountId, folderPath: "Label_gone")
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            for folder in w.folders.values {
                #expect(try Self.lapseCount(w.pool, folderId: folder.id) == 1,
                        "an unknown folder arms the whole account's catch-up: \(folder.path)")
            }
        }
    }

    @Test("Retired ids beyond the re-read list's limit keep the list at its limit and arm the folder's catch-up")
    func overflowArmsTheCatchUp() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            let limit = SyncConfig.changeRecheckLimit
            let listed = (0..<(limit - 1)).map { "listed-\($0)" }
            let inboxId = w.inbox.id
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(tracking: true, recheck: listed).encoded, inboxId])
            }
            try Self.queue(w.pool, .markFlagged, ids: ["new-a", "new-b", "new-c"], accountId: w.accountId, from: w.inbox.path)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            let after = try Self.recheck(w.pool, folderId: inboxId)
            #expect(after == listed + ["new-a"], "the list keeps its first \(limit) ids")
            #expect(try Self.lapseCount(w.pool, folderId: inboxId) == 1, "the catch-up finds the rest")
            #expect(try Self.lapseCount(w.pool, folderId: w.allMail.id) == nil)
        }
    }
}
