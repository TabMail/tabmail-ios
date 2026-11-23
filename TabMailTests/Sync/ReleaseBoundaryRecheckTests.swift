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
/// the current model cannot decode, or a re-read list that is full in a folder
/// the catch-up checks, arms the folder's catch-up instead; a folder the catch-up
/// never checks keeps every id.
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
        from path: String, to destination: String? = nil, userLabelId: String? = nil
    ) throws {
        var op = PendingOperation(
            type: type, messageIds: ids, accountId: accountId, folderPath: path, destinationPath: destination,
            userLabelId: userLabelId)
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

    @Test("Outlook: a move and a mark-read cleared at the update are listed, and the next sync shows the server's state with no folder listed")
    func outlookRetiredMoveIsReadAgainInBothFolders() async throws {
        try await Outlook.withWorld(seeds: [
            Outlook.seed("ob-move", in: Outlook.inbox, daysAgo: 1),
            Outlook.seed("ob-read", in: Outlook.inbox, daysAgo: 1),
        ]) { w in
            try await w.foregroundPass()
            try await w.foregroundPass()
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.inbox)), "precondition: the Inbox is tracked")
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.archive)), "precondition: the Archive is tracked")
            let moved = try #require(try w.row("ob-move", in: w.inbox), "precondition: listed")
            let read = try #require(try w.row("ob-read", in: w.inbox), "precondition: listed")
            #expect(read.isRead == false, "precondition: unread on the server and here")

            // Unsent move: the row sits in the Archive under the Inbox id, which
            // is still the server's id for the message (in the Inbox).
            try Self.moveRowOptimistically(w.pool, headerId: moved.id, to: try w.folder(w.archive))
            try Self.queue(w.pool, .move, ids: ["ob-move"], accountId: w.accountId, from: w.inbox, to: w.archive)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE id = ?", arguments: [read.id])
            }
            try Self.queue(w.pool, .markRead, ids: ["ob-read"], accountId: w.accountId, from: w.inbox)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.recheck(w.inbox) == ["ob-move", "ob-read"], "the source lists every retired id")
            #expect(try w.recheck(w.archive) == ["ob-move"], "the destination lists the id: Outlook reads folder by folder")

            let listingsBefore = Self.outlookListings(w)
            try await w.foregroundPass()

            #expect(try w.row("ob-move", in: w.inbox) != nil, "the message is back in the Inbox, as on the server")
            #expect(try w.row("ob-move", in: w.archive) == nil, "and no longer shown in the Archive")
            #expect(try w.row("ob-read", in: w.inbox)?.isRead == false, "the message shows unread again, as on the server")
            #expect(Self.outlookListings(w) == listingsBefore, "no folder listing")
            #expect(try w.recheck(w.inbox).isEmpty)
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    // MARK: - User labels (#903)

    /// The stored user labels of a row, by provider label id.
    static func storedLabels(_ pool: DatabasePool, headerId: String) throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT ul.providerLabelId FROM messageUserLabel mul JOIN userLabel ul ON ul.id = mul.userLabelId
                WHERE mul.messageId = ?
                """, arguments: [headerId]))
        }
    }

    /// The optimistic local effect of a label gesture: the row's label set changes.
    static func setLabelOptimistically(
        _ pool: DatabasePool, accountId: String, headerId: String, providerLabelId: String, add: Bool
    ) throws {
        try pool.write { db in
            let label = UserLabel(accountId: accountId, providerLabelId: providerLabelId, name: providerLabelId, isSystem: false)
            try label.insert(db, onConflict: .ignore)
            let labelId = try #require(try String.fetchOne(
                db, sql: "SELECT id FROM userLabel WHERE accountId = ? AND providerLabelId = ?",
                arguments: [accountId, providerLabelId]))
            if add {
                try MessageUserLabel(messageId: headerId, userLabelId: labelId).insert(db, onConflict: .ignore)
            } else {
                try db.execute(sql: "DELETE FROM messageUserLabel WHERE messageId = ? AND userLabelId = ?",
                               arguments: [headerId, labelId])
            }
        }
    }

    @Test("Gmail: a label removal and a label add cleared at the update show the server's labels after the next sync, with no folder listed")
    func gmailRetiredLabelChangesAreReadAgain() async throws {
        try await Gmail.withWorld(seeds: [
            Gmail.seed("rb-unlabel", labels: ["INBOX", Gmail.userLabelId]),
            Gmail.seed("rb-label", labels: ["INBOX"]),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            #expect(try Self.tracking(w.pool, folderId: w.inbox.id), "precondition: the Inbox is tracked")
            let unlabel = try #require(try w.row("rb-unlabel", in: w.inbox), "precondition: listed")
            let label = try #require(try w.row("rb-label", in: w.inbox), "precondition: listed")
            #expect(try Self.storedLabels(w.pool, headerId: unlabel.id) == [Gmail.userLabelId], "precondition: labelled here as on the server")
            #expect(try Self.storedLabels(w.pool, headerId: label.id).isEmpty, "precondition: no label here or on the server")

            // The gestures' optimistic effects, queued and never sent.
            try Self.setLabelOptimistically(w.pool, accountId: w.accountId, headerId: unlabel.id,
                                            providerLabelId: Gmail.userLabelId, add: false)
            try Self.queue(w.pool, .removeUserLabel, ids: ["rb-unlabel"], accountId: w.accountId,
                           from: w.inbox.path, userLabelId: Gmail.userLabelId)
            try Self.setLabelOptimistically(w.pool, accountId: w.accountId, headerId: label.id,
                                            providerLabelId: Gmail.userLabelId, add: true)
            try Self.queue(w.pool, .addUserLabel, ids: ["rb-label"], accountId: w.accountId,
                           from: w.inbox.path, userLabelId: Gmail.userLabelId)
            #expect(try Self.storedLabels(w.pool, headerId: unlabel.id).isEmpty, "precondition: the removal shows locally")
            #expect(try Self.storedLabels(w.pool, headerId: label.id) == [Gmail.userLabelId], "precondition: the add shows locally")

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.pendingOps().isEmpty, "the boundary retired the queue")

            let listingsBefore = GmailChangeReadingTests.windowListings(w)
            let catchUpsBefore = GmailChangeReadingTests.catchUpListings(w).count
            try await w.foregroundPassWithFullSyncDue()

            #expect(try Self.storedLabels(w.pool, headerId: unlabel.id) == [Gmail.userLabelId],
                    "the removed label shows again, as on the server")
            #expect(try Self.storedLabels(w.pool, headerId: label.id).isEmpty,
                    "the added label is gone again, as on the server")
            #expect(GmailChangeReadingTests.windowListings(w) == listingsBefore, "no window listing")
            #expect(GmailChangeReadingTests.catchUpListings(w).count == catchUpsBefore, "no catch-up listing")
            #expect(try Self.recheck(w.pool, folderId: w.inbox.id).isEmpty)
        }
    }

    @Test("Outlook: a category removal and a category add cleared at the update show the server's categories after the next sync, with no folder listed")
    func outlookRetiredCategoryChangesAreReadAgain() async throws {
        try await Outlook.withWorld(seeds: [
            Outlook.seed("ob-unlabel", in: Outlook.inbox, daysAgo: 1, categories: ["Receipts"]),
            Outlook.seed("ob-label", in: Outlook.inbox, daysAgo: 1),
        ]) { w in
            try await w.foregroundPass()
            try await w.foregroundPass()
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.inbox)), "precondition: the Inbox is tracked")
            let unlabel = try #require(try w.row("ob-unlabel", in: w.inbox), "precondition: listed")
            let label = try #require(try w.row("ob-label", in: w.inbox), "precondition: listed")
            #expect(try Self.storedLabels(w.pool, headerId: unlabel.id) == ["Receipts"], "precondition: categorised here as on the server")
            #expect(try Self.storedLabels(w.pool, headerId: label.id).isEmpty, "precondition: no category here or on the server")

            try Self.setLabelOptimistically(w.pool, accountId: w.accountId, headerId: unlabel.id,
                                            providerLabelId: "Receipts", add: false)
            try Self.queue(w.pool, .removeUserLabel, ids: ["ob-unlabel"], accountId: w.accountId,
                           from: w.inbox, userLabelId: "Receipts")
            try Self.setLabelOptimistically(w.pool, accountId: w.accountId, headerId: label.id,
                                            providerLabelId: "Receipts", add: true)
            try Self.queue(w.pool, .addUserLabel, ids: ["ob-label"], accountId: w.accountId,
                           from: w.inbox, userLabelId: "Receipts")
            #expect(try Self.storedLabels(w.pool, headerId: unlabel.id).isEmpty, "precondition: the removal shows locally")
            #expect(try Self.storedLabels(w.pool, headerId: label.id) == ["Receipts"], "precondition: the add shows locally")

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try await w.pool.read { db in try PendingOperation.fetchCount(db) } == 0, "the boundary retired the queue")

            let listingsBefore = Self.outlookListings(w)
            try await w.foregroundPass()

            #expect(try Self.storedLabels(w.pool, headerId: unlabel.id) == ["Receipts"],
                    "the removed category shows again, as on the server")
            #expect(try Self.storedLabels(w.pool, headerId: label.id).isEmpty,
                    "the added category is gone again, as on the server")
            #expect(Self.outlookListings(w) == listingsBefore, "no folder listing")
            #expect(try w.recheck(w.inbox).isEmpty)
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

    @Test("Retired ids beyond the re-read list's limit are all kept and arm no catch-up (#903: they drain over passes)")
    func overflowKeepsEveryRetiredId() async throws {
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
            #expect(after == listed + ["new-a", "new-b", "new-c"], "every retired id is kept past the \(limit) limit")
            #expect(try Self.lapseCount(w.pool, folderId: inboxId) == nil, "no catch-up is armed for retired ids")
            #expect(try Self.lapseCount(w.pool, folderId: w.allMail.id) == nil)
        }
    }

    // MARK: - Which kinds are read again, and where

    static func setTracking(_ pool: DatabasePool, folderIds: [String]) async throws {
        try await pool.write { db in
            for folderId in folderIds {
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(tracking: true).encoded, folderId])
            }
        }
    }

    static func allRecheckIds(_ pool: DatabasePool, accountId: String) throws -> [String] {
        try pool.read { db in
            try Folder.filter(Column("accountId") == accountId).fetchAll(db)
                .flatMap { FolderChangeState(raw: $0.changeState).recheck }
        }
    }

    static func armedFolderIds(_ pool: DatabasePool, accountId: String) throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT id FROM folder WHERE accountId = ? AND json_extract(catchUpState, '$.' || ?) IS NOT NULL
                """, arguments: [accountId, CatchUpLapse.countKey]))
        }
    }

    /// Kinds no repair path corrects in a stored row (replied/forwarded),
    /// local-only tags, and draft saves: nothing is listed and no catch-up armed.
    @Test("Retired tag, replied, forwarded and draft-save actions put nothing on a re-read list and arm no catch-up",
          arguments: [OperationType.setTag, .removeTag, .markReplied, .markForwarded, .saveDraft])
    func kindsLeftOutAreNotListed(kind: OperationType) async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try await Self.setTracking(w.pool, folderIds: w.folders.values.map(\.id))
            try Self.queue(w.pool, kind, ids: ["left-out"], accountId: w.accountId, from: w.inbox.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.allRecheckIds(w.pool, accountId: w.accountId).isEmpty, "\(kind) is not listed")
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId).isEmpty, "\(kind) arms no catch-up")
        }
    }

    /// The kinds a re-read corrects: the source lists the id, and a move's
    /// destination too; no catch-up is armed.
    @Test("Every retired move, read/flag and user-label kind lists its ids in the source, and a move's in its destination",
          arguments: [OperationType.archive, .delete, .move, .markRead, .markUnread, .markFlagged, .markUnflagged,
                      .addUserLabel, .removeUserLabel])
    func kindsReadAgainAreListed(kind: OperationType) async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            let isMove = [OperationType.archive, .delete, .move].contains(kind)
            let destination = kind == .delete ? w.folder("TRASH") : w.allMail
            try Self.queue(w.pool, kind, ids: ["k-1", "k-2"], accountId: w.accountId, from: w.inbox.path,
                           to: isMove ? destination.path : nil)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.recheck(w.pool, folderId: w.inbox.id) == ["k-1", "k-2"], "\(kind) lists its ids in the source")
            #expect(try Self.recheck(w.pool, folderId: destination.id) == (isMove ? ["k-1", "k-2"] : []),
                    "\(kind) lists its ids in a move's destination only")
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId).isEmpty)
        }
    }

    @Test("A retired draft delete arms its Drafts folder's catch-up and lists no id")
    func retiredDraftDeleteArmsTheDraftsCatchUp() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try await Self.setTracking(w.pool, folderIds: w.folders.values.map(\.id))
            try Self.queue(w.pool, .deleteDraft, ids: ["r-draft-resource"], accountId: w.accountId, from: w.drafts.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId) == [w.drafts.id],
                    "the Drafts catch-up loads the server draft back")
            #expect(try Self.allRecheckIds(w.pool, accountId: w.accountId).isEmpty, "a draft resource id is never listed")
        }
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try Self.queue(w.pool, .deleteDraft, ids: ["r-draft-gone"], accountId: w.accountId, from: "DRAFT_gone")
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId) == Set(w.folders.values.map(\.id)),
                    "a draft delete whose folder is gone arms the whole account")
            #expect(try Self.allRecheckIds(w.pool, accountId: w.accountId).isEmpty)
        }
    }

    @Test("A retired row whose kind is unknown to this release, with readable ids, arms its folder's catch-up")
    func unknownKindAloneArmsTheCatchUp() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            let row = PendingOperation(type: .markRead, messageIds: ["unknown-kind"], accountId: w.accountId, folderPath: w.inbox.path)
            try await w.pool.write { db in
                var op = row
                try op.insert(db)
                try db.execute(sql: "UPDATE pendingOperation SET type = 'kindFromAnOlderRelease' WHERE id = ?", arguments: [op.id])
            }
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId) == [w.inbox.id])
            #expect(try Self.allRecheckIds(w.pool, accountId: w.accountId).isEmpty)
        }
    }

    @Test("An account whose ids name one message across folders, with no change bookmark, is left alone: nothing listed, no catch-up armed")
    func accountWithoutBookmarkIsUntouched() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try await Self.setTracking(w.pool, folderIds: w.folders.values.map(\.id))
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE account SET lastHistoryId = NULL WHERE id = ?", arguments: [w.accountId])
            }
            try Self.queue(w.pool, .move, ids: ["nb-move"], accountId: w.accountId, from: w.inbox.path, to: w.allMail.path)
            try Self.queue(w.pool, .markRead, ids: ["nb-read"], accountId: w.accountId, from: w.inbox.path)
            try Self.queue(w.pool, .deleteDraft, ids: ["nb-draft"], accountId: w.accountId, from: w.drafts.path)
            try Self.makeUndecodable(w.pool, accountId: w.accountId, folderPath: w.inbox.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.pendingOps().isEmpty)
            #expect(try Self.allRecheckIds(w.pool, accountId: w.accountId).isEmpty, "the full sync lists every folder of such an account")
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId).isEmpty)
        }
    }

    @Test("A retired row with a known kind but ids that are not a JSON list arms its folder's catch-up")
    func unreadableIdsAloneArmTheCatchUp() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try await Self.setTracking(w.pool, folderIds: [w.inbox.id])
            let row = PendingOperation(type: .markRead, messageIds: ["placeholder"], accountId: w.accountId, folderPath: w.inbox.path)
            try await w.pool.write { db in
                var op = row
                try op.insert(db)
                try db.execute(sql: "UPDATE pendingOperation SET messageIdsJSON = '<not json>' WHERE id = ?", arguments: [op.id])
            }
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId) == [w.inbox.id])
            #expect(try Self.allRecheckIds(w.pool, accountId: w.accountId).isEmpty)
        }
    }

    @Test("A retired move whose destination folder is gone lists the id at its source and arms the whole account's catch-up")
    func goneFolderArmsTheAccount() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            try await Self.setTracking(w.pool, folderIds: [w.inbox.id])
            try Self.queue(w.pool, .move, ids: ["gone-1"], accountId: w.accountId, from: w.inbox.path, to: "Label_gone")
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.recheck(w.pool, folderId: w.inbox.id) == ["gone-1"])
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId) == Set(w.folders.values.map(\.id)))
        }
    }

    @Test("An id already listed, or named by two retired rows, is listed once")
    func idsAreListedOnce() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            let inboxId = w.inbox.id
            try await Self.setTracking(w.pool, folderIds: [w.allMail.id])
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(tracking: true, recheck: ["dup"]).encoded, inboxId])
            }
            try Self.queue(w.pool, .markRead, ids: ["dup"], accountId: w.accountId, from: w.inbox.path)
            try Self.queue(w.pool, .move, ids: ["dup", "other"], accountId: w.accountId, from: w.inbox.path, to: w.allMail.path)
            try Self.queue(w.pool, .markFlagged, ids: ["other"], accountId: w.accountId, from: w.allMail.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.recheck(w.pool, folderId: inboxId) == ["dup", "other"])
            #expect(try Self.recheck(w.pool, folderId: w.allMail.id) == ["dup", "other"])
        }
    }

    @Test("Outlook: a retired move lists its id in every folder it named, tracked, synced or neither")
    func listedInEveryNamedFolder() async throws {
        try await Outlook.withWorld { w in
            let custom = Folder(name: "Projects", path: "fld-custom", role: .custom, accountId: w.accountId)
            try await w.pool.write { db in
                try custom.insert(db)
                try db.execute(sql: "UPDATE account SET lastHistoryId = 'bookmark' WHERE id = ?", arguments: [w.accountId])
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE accountId = ?", arguments: [w.accountId])
            }
            try await Self.setTracking(w.pool, folderIds: [w.folderId(w.inbox)])
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.archive)) == false, "precondition: the Archive is not tracked")
            try Self.queue(w.pool, .move, ids: ["u-custom"], accountId: w.accountId, from: w.inbox, to: custom.path)
            try Self.queue(w.pool, .move, ids: ["u-archive"], accountId: w.accountId, from: w.inbox, to: w.archive)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.recheck(w.inbox) == ["u-custom", "u-archive"])
            #expect(try w.recheck(w.archive) == ["u-archive"], "the reader reads a synced folder's list, tracked or not")
            #expect(try w.recheck(custom.path) == ["u-custom"], "a folder outside the synced set is listed too: its list is read on its own")
            #expect(try Self.armedFolderIds(w.pool, accountId: w.accountId).isEmpty)
        }
    }

    /// The case the full sync cannot repair: its stale sweep is date-bounded on
    /// Outlook, so the listing is set aside here (only the change read runs), as
    /// it would miss an older message in a large folder. The move's source is
    /// synced but not tracked yet, its destination is tracked: the destination's
    /// re-read removes the optimistic row there, and only the source's re-read
    /// puts the message back where the server has it.
    @Test("Outlook: a retired move out of a synced folder that is not tracked yet puts the message back there by the change read alone")
    func untrackedSyncedSourceIsRestoredByTheRead() async throws {
        try await Outlook.withWorld(seeds: [Outlook.seed("ut-move", in: Outlook.inbox, daysAgo: 1)]) { w in
            try w.insertRow("ut-move", in: w.inbox, date: Outlook.daysAgo(1))
            try await w.baselineAll()
            #expect(try w.account().lastHistoryId != nil, "precondition: the account holds a change bookmark")
            try await Self.setTracking(w.pool, folderIds: [w.folderId(w.archive)])
            #expect(try Self.tracking(w.pool, folderId: w.folderId(w.inbox)) == false, "precondition: the Inbox is not tracked")
            let moved = try #require(try w.row("ut-move", in: w.inbox), "precondition: held")

            try Self.moveRowOptimistically(w.pool, headerId: moved.id, to: try w.folder(w.archive))
            try Self.queue(w.pool, .move, ids: ["ut-move"], accountId: w.accountId, from: w.inbox, to: w.archive)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))

            try await w.read()
            #expect(try w.row("ut-move", in: w.inbox) != nil, "the message is back in the untracked Inbox, as on the server")
            #expect(try w.row("ut-move", in: w.archive) == nil, "and no longer shown in the Archive")
            #expect(try w.recheck(w.inbox).isEmpty)
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    // MARK: - Older messages, outside every listing window

    /// Days back for a message older than every world's held range (the Outlook
    /// world holds 30 days; a Gmail folder's window listing is date-bounded).
    static let olderThanHeldDays: Double = 90

    /// Part (i): a source folder whose read is a baseline. A baseline record is
    /// gated by the held range, but one answering a listed id is the server's
    /// answer about that message and restores it.
    @Test("Outlook: an older message archived before the update comes back to an Inbox whose read is a baseline")
    func olderMessageReturnsToABaseliningInbox() async throws {
        try await Outlook.withWorld(seeds: [Outlook.seed("b-old", in: Outlook.inbox, daysAgo: Self.olderThanHeldDays)]) { w in
            try await w.read()
            #expect(try w.account().lastHistoryId != nil, "precondition: the account holds a change bookmark")
            try w.insertRow("b-old", in: w.inbox, date: Outlook.daysAgo(Self.olderThanHeldDays))
            let held = try #require(try w.row("b-old", in: w.inbox), "precondition: held")
            #expect(try w.folder(w.inbox).oldestSyncedDate.map { held.date < $0 } == true,
                    "precondition: the message is older than the Inbox's held range")
            // The Inbox starts a new baseline on its next read.
            let inboxId = w.folderId(w.inbox)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeCursor = NULL, changeState = NULL WHERE id = ?", arguments: [inboxId])
            }

            try Self.moveRowOptimistically(w.pool, headerId: held.id, to: try w.folder(w.archive))
            try Self.queue(w.pool, .archive, ids: ["b-old"], accountId: w.accountId, from: w.inbox, to: w.archive)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))

            #expect(try w.cursor(w.inbox) == nil, "precondition: the Inbox's next read is a baseline")
            try await w.read()
            #expect(try w.row("b-old", in: w.inbox) != nil, "the older message is back in the Inbox, as on the server")
            #expect(try w.row("b-old", in: w.archive) == nil, "and no longer shown in the Archive")
            #expect(try w.recheck(w.inbox).isEmpty)
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    /// The held-range gate stays for everything else: only a listed id passes.
    @Test("Outlook: during a baseline, an older message whose id is listed is inserted and one whose id is not listed is not")
    func baselineGateHoldsForAnUnlistedId() async throws {
        try await Outlook.withWorld(seeds: [
            Outlook.seed("n-listed", in: Outlook.inbox, daysAgo: Self.olderThanHeldDays),
            Outlook.seed("n-unlisted", in: Outlook.inbox, daysAgo: Self.olderThanHeldDays),
        ]) { w in
            let inboxId = w.folderId(w.inbox)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(recheck: ["n-listed"]).encoded, inboxId])
            }
            #expect(try w.cursor(w.inbox) == nil, "precondition: the Inbox's first read is a baseline")
            try await w.read()
            #expect(try w.row("n-listed", in: w.inbox) != nil, "a record answering a listed id applies whatever the range")
            #expect(try w.row("n-unlisted", in: w.inbox) == nil, "a baseline record for an unlisted older message stays the backfill's")
            #expect(try w.recheck(w.inbox).isEmpty)
        }
    }

    /// Part (ii): folders outside the synced set are listed. Gmail reads every
    /// list and answers every folder by the message's labels.
    @Test("Gmail: an older message moved between two custom labels, and read and flag changes inside one, show the server's state again")
    func gmailCustomLabelsAreReadAgain() async throws {
        let old = Gmail.daysAgo(Self.olderThanHeldDays)
        try await Gmail.withWorld(seeds: [
            Gmail.seed("g-move", labels: [Gmail.userLabelId], date: old),
            Gmail.seed("g-read", labels: [Gmail.userLabelId, "UNREAD"], date: old),
            Gmail.seed("g-flag", labels: [Gmail.userLabelId], date: old),
        ]) { w in
            let other = Folder(name: "Receipts", path: "Label_2", role: .custom, accountId: w.accountId)
            let labelId = w.label.id
            try await w.pool.write { db in
                try other.insert(db)
                try db.execute(sql: "UPDATE folder SET isFavorite = 0 WHERE id = ?", arguments: [labelId])
            }
            let moved = try w.insertRow("g-move", in: w.label, date: old)
            try w.insertRow("g-read", in: w.label, date: old, isRead: true)
            try w.insertRow("g-flag", in: w.label, date: old, isFlagged: true)

            try Self.moveRowOptimistically(w.pool, headerId: moved.id, to: other)
            try Self.queue(w.pool, .move, ids: ["g-move"], accountId: w.accountId, from: w.label.path, to: other.path)
            try Self.queue(w.pool, .markRead, ids: ["g-read"], accountId: w.accountId, from: w.label.path)
            try Self.queue(w.pool, .markFlagged, ids: ["g-flag"], accountId: w.accountId, from: w.label.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.recheck(w.pool, folderId: w.label.id) == ["g-move", "g-read", "g-flag"])
            #expect(try Self.recheck(w.pool, folderId: other.id) == ["g-move"])

            try await w.delta()
            #expect(try w.row("g-move", in: w.label) != nil, "the message is back in its label, as on the server")
            #expect(try w.row("g-move", in: other) == nil, "and no longer shown in the other label")
            #expect(try w.row("g-read", in: w.label)?.isRead == false, "unread again, as on the server")
            #expect(try w.row("g-flag", in: w.label)?.isFlagged == false, "not flagged, as on the server")
            #expect(try Self.recheck(w.pool, folderId: w.label.id).isEmpty)
            #expect(try Self.recheck(w.pool, folderId: other.id).isEmpty)
        }
    }

    @Test("Gmail: an older message archived from an Inbox that is synced but not tracked comes back to the Inbox")
    func gmailUntrackedSyncedInboxIsRestored() async throws {
        let old = Gmail.daysAgo(Self.olderThanHeldDays)
        try await Gmail.withWorld(seeds: [Gmail.seed("gu-old", labels: ["INBOX"], date: old)]) { w in
            try await Self.setTracking(w.pool, folderIds: [w.allMail.id])
            #expect(try Self.tracking(w.pool, folderId: w.inbox.id) == false, "precondition: the Inbox is not tracked")
            let held = try w.insertRow("gu-old", in: w.inbox, date: old)
            try Self.moveRowOptimistically(w.pool, headerId: held.id, to: w.allMail)
            try Self.queue(w.pool, .archive, ids: ["gu-old"], accountId: w.accountId, from: w.inbox.path, to: w.allMail.path)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))

            try await w.delta()
            #expect(try w.row("gu-old", in: w.inbox) != nil, "the message is back in the Inbox, as on the server")
            #expect(try w.row("gu-old", in: w.allMail) == nil, "and no longer shown in All Mail")
        }
    }

    /// Part (iii): Outlook reads a non-synced folder's list on its own, by id.
    @Test("Outlook: in a custom folder that is not a favourite, an older message's read change and its move out show the server's state again")
    func outlookCustomFolderIsReadAgain() async throws {
        let customPath = "fld-projects"
        try await Outlook.withWorld(seeds: [
            Outlook.seed("o-read", in: customPath, daysAgo: Self.olderThanHeldDays),
            Outlook.seed("o-move", in: customPath, daysAgo: Self.olderThanHeldDays),
        ]) { w in
            w.server.addFolder(id: customPath, name: "Projects")
            let custom = Folder(name: "Projects", path: customPath, role: .custom, accountId: w.accountId)
            try await w.pool.write { db in try custom.insert(db) }
            try await w.baselineAll()
            #expect(try w.account().lastHistoryId != nil, "precondition: the account holds a change bookmark")
            let old = Outlook.daysAgo(Self.olderThanHeldDays)
            try w.insertRow("o-read", in: customPath, date: old, isRead: true)
            try w.insertRow("o-move", in: customPath, date: old)
            let moved = try #require(try w.row("o-move", in: customPath))

            try Self.moveRowOptimistically(w.pool, headerId: moved.id, to: try w.folder(w.archive))
            try Self.queue(w.pool, .move, ids: ["o-move"], accountId: w.accountId, from: customPath, to: w.archive)
            try Self.queue(w.pool, .markRead, ids: ["o-read"], accountId: w.accountId, from: customPath)
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            let listingsBefore = Self.outlookListings(w)

            try await w.read()
            #expect(try w.row("o-read", in: customPath)?.isRead == false, "unread again, as on the server")
            #expect(try w.row("o-move", in: customPath) != nil, "the message is back in the custom folder, as on the server")
            #expect(try w.row("o-move", in: w.archive) == nil, "and no longer shown in the Archive")
            #expect(try w.recheck(customPath).isEmpty)
            #expect(try w.recheck(w.archive).isEmpty)
            #expect(Self.outlookListings(w) == listingsBefore, "no folder was listed")
            #expect(try w.cursor(customPath) == nil, "the custom folder's read changed no bookmark")
        }
    }

    // MARK: - A folder the catch-up never checks

    static let customPath = "fld-projects"

    /// Adds a custom, non-favourite folder to an Outlook world, on the server and
    /// locally, as the folder list would have stored it.
    static func addCustomFolder(_ w: Outlook.World) async throws -> Folder {
        w.server.addFolder(id: customPath, name: "Projects")
        let custom = Folder(name: "Projects", path: customPath, role: .custom, accountId: w.accountId)
        try await w.pool.write { db in try custom.insert(db) }
        #expect(!SyncEngine.isSyncable(role: custom.role, isFavorite: custom.isFavorite),
                "precondition: the catch-up never checks this folder")
        return custom
    }

    static func setRecheck(_ w: Outlook.World, _ path: String, _ ids: [String]) async throws {
        let folderId = w.folderId(path)
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                           arguments: [FolderChangeState(recheck: ids).encoded, folderId])
        }
    }

    /// The robustness rule behind the list limit: ids are dropped only where the
    /// catch-up will find them. A folder the catch-up never checks keeps every
    /// retired id, and the change passes read them all, each pass within its
    /// re-read budget.
    @Test("Outlook: more retired ids than the list limit in a custom folder are all kept, and every one is read again across passes")
    func customFolderKeepsEveryRetiredIdAndReadsThemAll() async throws {
        let count = SyncConfig.changeRecheckLimit + SyncConfig.changeRereadBudgetPerPass
        let ids = (0..<count).map { String(format: "many-%03d", $0) }
        try await Outlook.withWorld(seeds: ids.map { Outlook.seed($0, in: Self.customPath, daysAgo: Self.olderThanHeldDays) }) { w in
            let custom = try await Self.addCustomFolder(w)
            try await w.baselineAll()
            let old = Outlook.daysAgo(Self.olderThanHeldDays)
            for id in ids { try w.insertRow(id, in: Self.customPath, date: old, isRead: true) }
            try Self.queue(w.pool, .markRead, ids: ids, accountId: w.accountId, from: Self.customPath)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.recheck(Self.customPath) == ids, "every id is kept: no catch-up would find a dropped one")
            #expect(try Self.lapseCount(w.pool, folderId: custom.id) == nil)

            let passes = count / SyncConfig.changeRereadBudgetPerPass + 2
            for _ in 0..<passes {
                let listedBefore = try w.recheck(Self.customPath).count
                if listedBefore == 0 { break }
                let fetchesBefore = w.messageFetches()
                try await w.delta()
                let fetched = w.messageFetches() - fetchesBefore
                #expect(fetched > 0 && fetched <= SyncConfig.changeRereadBudgetPerPass,
                        "one pass reads at most its re-read budget (\(fetched))")
                #expect(try w.recheck(Self.customPath).count < listedBefore, "every pass makes progress")
            }
            #expect(try w.recheck(Self.customPath).isEmpty, "every id was read again")
            let stillRead = try ids.filter { try w.row($0, in: Self.customPath)?.isRead != false }
            #expect(stillRead.isEmpty, "every message shows the server's unread state: \(stillRead.prefix(5))")
        }
    }

    @Test("A re-read list over the limit keeps every id in a folder the catch-up never checks, and is cut, arming the catch-up, in one it checks")
    func applyOverflowDropsOnlyWhereTheCatchUpChecks() async throws {
        try await Outlook.withWorld { w in
            let custom = try await Self.addCustomFolder(w)
            let ids = (0...SyncConfig.changeRecheckLimit).map { "ov-\($0)" }
            let archiveId = w.folderId(w.archive)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE accountId = ?", arguments: [w.accountId])
            }
            let customResult = try await w.pool.write { db in
                try SyncEngine.applyFolderChanges(FolderChanges(folderId: custom.id, status: .notRun, rereadLater: ids), db: db)
            }
            #expect(try w.recheck(Self.customPath).count == ids.count, "the custom folder keeps every id")
            #expect(!customResult.armedCatchUp)
            #expect(try Self.lapseCount(w.pool, folderId: custom.id) == nil)

            let archiveResult = try await w.pool.write { db in
                try SyncEngine.applyFolderChanges(FolderChanges(folderId: archiveId, status: .tracked, rereadLater: ids), db: db)
            }
            #expect(try w.recheck(w.archive).count == SyncConfig.changeRecheckLimit, "a folder the catch-up checks keeps its first ids")
            #expect(archiveResult.armedCatchUp)
            #expect(try Self.lapseCount(w.pool, folderId: archiveId) == 1, "and its catch-up finds the rest")
        }
    }

    /// #903: a stored list over the limit (the boundary's retired ids) is never
    /// cut by a later pass; only that pass's own additions are, and the
    /// catch-up is armed for them.
    @Test("A pass that adds ids to a stored list over the limit keeps every stored id and cuts only its own additions, arming the catch-up")
    func applyCutsOnlyThisPassesAdditions() async throws {
        try await Outlook.withWorld { w in
            let archiveId = w.folderId(w.archive)
            let limit = SyncConfig.changeRecheckLimit
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE accountId = ?", arguments: [w.accountId])
            }

            // Already over the limit: no room, every new id is cut.
            let stored = (0..<(limit + 10)).map { "stored-\($0)" }
            try await Self.setRecheck(w, w.archive, stored)
            let full = try await w.pool.write { db in
                try SyncEngine.applyFolderChanges(
                    FolderChanges(folderId: archiveId, status: .tracked, rereadLater: ["stored-0", "new-0", "new-1"]), db: db)
            }
            let afterFull = try w.recheck(w.archive)
            #expect(Set(afterFull) == Set(stored), "every stored id is kept and no new id fits")
            #expect(afterFull.count == stored.count)
            #expect(full.armedCatchUp)
            #expect(try Self.lapseCount(w.pool, folderId: archiveId) == 1, "the catch-up is armed for the cut additions")

            // Room for one: the first new id is kept, the rest cut.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE id = ?", arguments: [archiveId])
            }
            let near = (0..<(limit - 1)).map { "near-\($0)" }
            try await Self.setRecheck(w, w.archive, near)
            let partial = try await w.pool.write { db in
                try SyncEngine.applyFolderChanges(
                    FolderChanges(folderId: archiveId, status: .tracked, rereadLater: ["add-0", "add-1", "add-2"]), db: db)
            }
            #expect(try w.recheck(w.archive) == near + ["add-0"], "stored ids first, then as many additions as fit")
            #expect(partial.armedCatchUp)
            #expect(try Self.lapseCount(w.pool, folderId: archiveId) == 1)
        }
    }

    /// #903: more retired label ids than the list limit in a folder the
    /// catch-up checks are all kept and drained by the change passes, each
    /// within its re-read budget, until every message shows the server's labels.
    @Test("Outlook: more retired category ids than the list limit in the Inbox are all read again across passes, with no catch-up armed")
    func manyRetiredLabelIdsDrainInACheckedFolder() async throws {
        let count = SyncConfig.changeRecheckLimit + SyncConfig.changeRereadBudgetPerPass
        let ids = (0..<count).map { String(format: "lbl-%03d", $0) }
        try await Outlook.withWorld(seeds: ids.map { Outlook.seed($0, in: Outlook.inbox, daysAgo: 1, categories: ["Receipts"]) }) { w in
            for id in ids { try w.insertRow(id, in: w.inbox, date: Outlook.daysAgo(1)) }
            try await w.baselineAll()
            let inboxId = w.folderId(w.inbox)
            #expect(SyncEngine.isSyncable(role: .inbox, isFavorite: false), "precondition: the catch-up checks the Inbox")
            let headerIds = try ids.map { try #require(try w.row($0, in: w.inbox), "precondition: stored").id }
            #expect(try Self.storedLabels(w.pool, headerId: headerIds[0]) == ["Receipts"], "precondition: the server's category is stored")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET catchUpState = '{}' WHERE accountId = ?", arguments: [w.accountId])
            }
            for headerId in headerIds {
                try Self.setLabelOptimistically(w.pool, accountId: w.accountId, headerId: headerId,
                                                providerLabelId: "Receipts", add: false)
            }
            try Self.queue(w.pool, .removeUserLabel, ids: ids, accountId: w.accountId, from: w.inbox, userLabelId: "Receipts")

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.recheck(w.inbox) == ids, "every retired id is kept past the list limit")
            #expect(try Self.lapseCount(w.pool, folderId: inboxId) == nil, "no catch-up is armed for them")

            let passes = count / SyncConfig.changeRereadBudgetPerPass + 2
            for _ in 0..<passes {
                let listedBefore = try w.recheck(w.inbox).count
                if listedBefore == 0 { break }
                try await w.delta()
                #expect(try w.recheck(w.inbox).count < listedBefore, "every pass makes progress")
            }
            #expect(try w.recheck(w.inbox).isEmpty, "every id was read again")
            let unlabelled = try zip(ids, headerIds).filter { try Self.storedLabels(w.pool, headerId: $0.1) != ["Receipts"] }.map(\.0)
            #expect(unlabelled.isEmpty, "every message shows the server's category again: \(unlabelled.prefix(5))")
            #expect(try Self.lapseCount(w.pool, folderId: inboxId) == nil, "no catch-up was armed for the retired ids")
        }
    }

    /// The folder's re-read list read by raw SQL, for a row whose role the model
    /// cannot decode.
    static func rawRecheck(_ pool: DatabasePool, folderId: String) throws -> [String] {
        FolderChangeState(raw: try pool.read { db in
            try String.fetchOne(db, sql: "SELECT changeState FROM folder WHERE id = ?", arguments: [folderId])
        }).recheck
    }

    @Test("A folder whose role this release cannot read keeps every retired id over the list limit, and no catch-up is armed")
    func unreadableRoleKeepsEveryRetiredId() async throws {
        try await Outlook.withWorld { w in
            let folder = Folder(name: "Later", path: "fld-later", role: .custom, accountId: w.accountId)
            try await w.pool.write { db in
                try folder.insert(db)
                try db.execute(sql: "UPDATE folder SET role = 'roleFromALaterRelease' WHERE id = ?", arguments: [folder.id])
                try db.execute(sql: "UPDATE account SET lastHistoryId = 'bookmark' WHERE id = ?", arguments: [w.accountId])
            }
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            let ids = (0..<(SyncConfig.changeRecheckLimit + 5)).map { "later-\($0)" }
            try Self.queue(w.pool, .markRead, ids: ids, accountId: w.accountId, from: folder.path)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try Self.rawRecheck(w.pool, folderId: folder.id) == ids, "an unreadable role counts as not checked: every id is kept")
            #expect(try Self.lapseCount(w.pool, folderId: folder.id) == nil)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET role = ? WHERE id = ?", arguments: [FolderRole.custom.rawValue, folder.id])
            }
        }
    }

    @Test("A favourite custom folder over the list limit keeps every retired id and arms no catch-up")
    func favouriteCustomFolderKeepsEveryRetiredId() async throws {
        try await Outlook.withWorld { w in
            var folder = Folder(name: "Starred", path: "fld-starred", role: .custom, accountId: w.accountId)
            folder.isFavorite = true
            let favourite = folder
            try await w.pool.write { db in
                try favourite.insert(db)
                try db.execute(sql: "UPDATE account SET lastHistoryId = 'bookmark' WHERE id = ?", arguments: [w.accountId])
            }
            #expect(SyncEngine.isSyncable(role: favourite.role, isFavorite: favourite.isFavorite), "precondition: the catch-up checks it")
            try await Self.seedCatchUpStates(w.pool, accountId: w.accountId)
            let ids = (0..<(SyncConfig.changeRecheckLimit + 5)).map { "star-\($0)" }
            try Self.queue(w.pool, .markRead, ids: ids, accountId: w.accountId, from: favourite.path)

            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: Self.nextRelease()))
            #expect(try w.recheck(favourite.path) == ids, "every retired id is kept")
            #expect(try Self.lapseCount(w.pool, folderId: favourite.id) == nil, "no catch-up is armed for retired ids")
        }
    }

    /// The custom folder's read is the server's answer about listed messages,
    /// never a read of the folder: it reports `.notRun`, so the pass neither
    /// covers nor lists that folder.
    @Test("Outlook: a custom folder's re-read starts no tracking, makes no listing due, and leaves its catch-up and bookmark alone")
    func customFolderReadChangesNoCoverage() async throws {
        try await Outlook.withWorld(seeds: [Outlook.seed("c-read", in: Self.customPath, daysAgo: Self.olderThanHeldDays)]) { w in
            let custom = try await Self.addCustomFolder(w)
            try await w.baselineAll()
            try w.insertRow("c-read", in: Self.customPath, date: Outlook.daysAgo(Self.olderThanHeldDays), isRead: true)
            try await Self.setRecheck(w, Self.customPath, ["c-read"])
            let fullSyncAt = Date().addingTimeInterval(-3_600)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [fullSyncAt, w.accountId])
                try db.execute(sql: "UPDATE folder SET catchUpState = '{\"seen\":1}' WHERE id = ?", arguments: [custom.id])
            }

            let engine = SyncEngine()
            let account = try w.account()
            let request = try await engine.makeChangeRequest(accountId: account.id, scope: .all, deadline: nil)
            let read = try await engine.readAndApplyChanges(account: account, provider: w.provider, request: request)
            let outcome = try #require(read)
            #expect(try w.row("c-read", in: Self.customPath)?.isRead == false, "precondition: the re-read applied")
            #expect(!outcome.trackableFolderIds.contains(custom.id), "the read does not make the folder trackable")
            #expect(try Self.tracking(w.pool, folderId: custom.id) == false)
            let storedFullSyncAt = try w.account().lastFullSyncAt
            let stored = try w.folder(Self.customPath)
            #expect(storedFullSyncAt.map { abs($0.timeIntervalSince(fullSyncAt)) < 1 } == true, "the full sync stays as it was")
            #expect(stored.catchUpState == "{\"seen\":1}", "the catch-up state is untouched")
            #expect(stored.changeCursor == nil, "no bookmark")
        }
    }

    @Test("Outlook: an Inbox-only pass leaves a custom folder's re-read list for a whole-account pass")
    func inboxOnlyPassLeavesTheCustomList() async throws {
        try await Outlook.withWorld(seeds: [Outlook.seed("i-read", in: Self.customPath, daysAgo: Self.olderThanHeldDays)]) { w in
            _ = try await Self.addCustomFolder(w)
            try await w.baselineAll()
            try w.insertRow("i-read", in: Self.customPath, date: Outlook.daysAgo(Self.olderThanHeldDays), isRead: true)
            try await Self.setRecheck(w, Self.customPath, ["i-read"])
            let fetchesBefore = w.messageFetches()

            try await w.read(scope: .inboxOnly)
            #expect(w.messageFetches() == fetchesBefore, "no message of the custom folder is fetched")
            #expect(try w.recheck(Self.customPath) == ["i-read"], "the id stays listed")
            #expect(try w.row("i-read", in: Self.customPath)?.isRead == true)

            try await w.read(scope: .all)
            #expect(try w.recheck(Self.customPath).isEmpty)
            #expect(try w.row("i-read", in: Self.customPath)?.isRead == false)
        }
    }

    @Test("Outlook: a custom folder whose re-read fails keeps its ids, and the other folders' changes and the pass stand")
    func failingCustomReadHoldsBackNothingElse() async throws {
        try await Outlook.withWorld(seeds: [Outlook.seed("f-read", in: Self.customPath, daysAgo: Self.olderThanHeldDays)]) { w in
            _ = try await Self.addCustomFolder(w)
            try await w.baselineAll()
            try w.insertRow("f-read", in: Self.customPath, date: Outlook.daysAgo(Self.olderThanHeldDays), isRead: true)
            try await Self.setRecheck(w, Self.customPath, ["f-read"])
            w.server.deliver(Outlook.seed("f-new", in: Outlook.inbox, daysAgo: 0))
            // Two batches fail: the Inbox new message's last-verb read (#890), then
            // the custom folder's re-read.
            w.server.failBatches([.transportError(.networkConnectionLost), .transportError(.networkConnectionLost)])

            try await w.read()
            #expect(try w.row("f-new", in: w.inbox) != nil, "the Inbox's new message lands")
            #expect(try w.cursor(w.inbox)?.phase == .tracking)
            #expect(try w.recheck(Self.customPath) == ["f-read"], "precondition: the custom read failed; the id stays listed")
            #expect(try w.row("f-read", in: Self.customPath)?.isRead == true)

            try await w.read()
            #expect(try w.recheck(Self.customPath).isEmpty, "the next pass reads it")
            #expect(try w.row("f-read", in: Self.customPath)?.isRead == false)
        }
    }

    @Test("Outlook: a custom folder's re-read stays within the pass's request allowance; the ids not read stay listed")
    func customReadStaysWithinTheAllowance() async throws {
        let ids = (0..<(SyncConfig.graphBatchMaxRequests * 2 + 5)).map { String(format: "al-%02d", $0) }
        try await Outlook.withWorld(seeds: ids.map { Outlook.seed($0, in: Self.customPath) }) { w in
            _ = try await Self.addCustomFolder(w)
            try await w.baselineAll()
            try await Self.setRecheck(w, Self.customPath, ids)
            let fetchesBefore = w.messageFetches()
            // Allowance: the folder-list page, one page per synced folder, and at
            // most one batch; the custom folder's list is read last.
            let syncedFolders = 5
            try await w.read(now: Date(), requests: 1 + syncedFolders + SyncConfig.graphBatchMaxRequests)
            let fetched = w.messageFetches() - fetchesBefore
            #expect(fetched > 0 && fetched <= SyncConfig.graphBatchMaxRequests, "at most one batch, as allowed (\(fetched))")
            let left = try w.recheck(Self.customPath)
            #expect(left.count == ids.count - fetched, "the ids not read stay listed")
            #expect(Set(left).isSubset(of: Set(ids)))
        }
    }

    @Test("A throw inside the re-read step rolls the whole boundary back, and the next launch takes it")
    func throwRollsTheBoundaryBack() async throws {
        try await Gmail.withWorld(seeds: []) { w in
            try await Self.setTracking(w.pool, folderIds: [w.inbox.id])
            try Self.queue(w.pool, .markRead, ids: ["rb-1"], accountId: w.accountId, from: w.inbox.path)
            let stampBefore = try await w.pool.read { db in
                try String.fetchOne(db, sql: "SELECT release FROM appReleaseStamp WHERE id = 1")
            }
            try await w.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER retired_recheck_fails BEFORE UPDATE OF changeState ON folder
                    BEGIN SELECT RAISE(ABORT, 'injected'); END
                    """)
            }
            let release = Self.nextRelease()
            #expect(throws: (any Error).self) {
                try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: release)
            }
            #expect(try w.pendingOps().count == 1, "the queue is kept")
            #expect(try w.account().lastFullSyncAt != nil, "the full sync is not marked due")
            #expect(try await w.pool.read { db in
                try String.fetchOne(db, sql: "SELECT release FROM appReleaseStamp WHERE id = 1")
            } == stampBefore, "the stamp is not moved, so the next launch retries")
            #expect(try Self.recheck(w.pool, folderId: w.inbox.id).isEmpty)

            try await w.pool.write { db in try db.execute(sql: "DROP TRIGGER retired_recheck_fails") }
            #expect(try AppDatabase.retirePreviousReleaseActionQueue(on: w.pool, currentRelease: release))
            #expect(try w.pendingOps().isEmpty)
            #expect(try Self.recheck(w.pool, folderId: w.inbox.id) == ["rb-1"])
        }
    }
}
