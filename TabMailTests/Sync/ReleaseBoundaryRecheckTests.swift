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

    /// Kinds no repair path corrects in a stored row (labels, replied/forwarded),
    /// local-only tags, and draft saves: nothing is listed and no catch-up armed.
    @Test("Retired tag, label, replied, forwarded and draft-save actions put nothing on a re-read list and arm no catch-up",
          arguments: [OperationType.setTag, .removeTag, .addUserLabel, .removeUserLabel, .markReplied, .markForwarded, .saveDraft])
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
    @Test("Every retired move and read/flag kind lists its ids in the source, and a move's in its destination",
          arguments: [OperationType.archive, .delete, .move, .markRead, .markUnread, .markFlagged, .markUnflagged])
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

    @Test("An account with no change bookmark is left alone: nothing listed, no catch-up armed")
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

    @Test("Outlook: a retired move lists its id in a synced folder that is not tracked yet, and nothing in a folder outside the syncable set")
    func listedOnlyWhereTheReaderReads() async throws {
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
            #expect(try w.recheck(custom.path).isEmpty, "a folder no reader reads never gets an id that would stick")
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
