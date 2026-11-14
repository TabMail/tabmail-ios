/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - Retired actions are read again at the release boundary (#876)
//
// The release boundary (`AppDatabase.retirePreviousReleaseActionQueue`) deletes
// every queued action. A gesture whose action never reached the server has
// already changed the local rows (an archived message shown in the Archive, a
// message shown read). The boundary's full sync used to correct that by listing
// every folder; a folder the change reader tracks gets no window listing
// (ADR-IOS-111 decision 4), so nothing would correct it there.
//
// So, inside the boundary's transaction and before its delete, each retired row
// is read for three things only: its account, its folders and its message ids.
// Nothing is re-sent or replayed. Each id goes on the re-read list
// (`FolderChangeState.recheck`) of the folder the action was queued on and, for a
// move, of its destination too: the change reader reads those messages again on
// its next pass and the apply writes what the server says (Gmail places a
// message by its labels in every folder; Outlook reads folder by folder, so a
// message the server holds elsewhere is a removal in that folder).
//
// The ids are the queue's own, the provider's id for the message in the folder
// the action was queued on: a move that drained re-addresses the queued rows that
// follow it to the destination id the server named
// (`MessageHeaderRekey.readdressQueuedOperations`), and an unsent Outlook move
// still names the original id, which is where the server still has the message.
// That is an id the server can answer for; the local row's address after an
// optimistic move (the source id under the destination folder) is not used.
//
// Scope: accounts that hold a change bookmark (`Account.lastHistoryId`), the same
// test the full sync uses to skip tracked folders. An account with no bookmark
// has every folder listed by the boundary's full sync, as before (IMAP today).
//
// A row the current model cannot decode (an action kind this release does not
// know, ids that are not a JSON list) is not skipped: its folder's catch-up is
// armed (`markCatchUpLapse`, one whole-folder check), or every folder's of its
// account when its folder is not known. The same for a decoded row whose folder
// no longer exists. A list over `SyncConfig.changeRecheckLimit` keeps the first
// ids and arms the folder's catch-up, as the apply does.

/// What the boundary did with the retired rows, for its debug log.
struct RetiredActionRecheckSummary: Sendable, Equatable {
    /// Distinct (folder, id) pairs put on a re-read list.
    var listedIds = 0
    /// Folders whose catch-up was armed (overflow, undecodable row, unknown folder).
    var armedFolders = 0
    /// Rows the current model could not decode.
    var undecodableRows = 0
}

extension SyncEngine {

    /// The action kinds whose gesture changed local rows before the server heard
    /// of it. Tags are local-only on the providers with a change reader
    /// (ADR-IOS-036), and draft saves and deletes are the drafts' own
    /// (`saveDraft` is re-queued by the boundary).
    nonisolated static let retiredActionKindsWithLocalEffect: Set<OperationType> = [
        .archive, .delete, .move, .markRead, .markUnread, .markFlagged, .markUnflagged,
        .addUserLabel, .removeUserLabel, .markReplied, .markForwarded,
    ]

    /// Inside the release boundary's transaction, BEFORE its delete: put the
    /// retired actions' message ids on the re-read lists of the folders they
    /// named, or arm the catch-up where they cannot be named.
    nonisolated static func recheckRetiredActions(db: Database) throws -> RetiredActionRecheckSummary {
        var summary = RetiredActionRecheckSummary()
        let bookmarked = Set(try String.fetchAll(
            db, sql: "SELECT id FROM account WHERE lastHistoryId IS NOT NULL"))
        guard !bookmarked.isEmpty else { return summary }

        // Folder rows by (account, path), read once per pair.
        var foldersByKey: [String: Folder?] = [:]
        var foldersById: [String: Folder] = [:]
        func folder(accountId: String, path: String) throws -> Folder? {
            let key = "\(accountId)\u{1F}\(path)"
            if let cached = foldersByKey[key] { return cached }
            let found = try Folder
                .filter(Column("accountId") == accountId && Column("path") == path)
                .fetchOne(db)
            foldersByKey[key] = found
            if let found { foldersById[found.id] = found }
            return found
        }

        var idsByFolder: [String: [String]] = [:]
        var folderOrder: [String] = []
        var armFolderIds = Set<String>()
        var armAccountIds = Set<String>()

        let rows = try Row.fetchAll(db, sql: "SELECT * FROM pendingOperation ORDER BY queuePosition")
        for row in rows {
            guard let accountId = row["accountId"] as String?, bookmarked.contains(accountId) else { continue }
            guard let op = try? PendingOperation(row: row),
                  let data = op.messageIdsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else {
                summary.undecodableRows += 1
                if let path = row["folderPath"] as String?, let known = try folder(accountId: accountId, path: path) {
                    armFolderIds.insert(known.id)
                } else {
                    armAccountIds.insert(accountId)
                }
                continue
            }
            guard retiredActionKindsWithLocalEffect.contains(op.type), !ids.isEmpty else { continue }
            var paths = [op.folderPath]
            if PendingOperationSnapshot.destructiveTypes.contains(op.type), let destination = op.destinationPath {
                paths.append(destination)
            }
            for path in paths {
                guard let named = try folder(accountId: accountId, path: path) else {
                    armAccountIds.insert(accountId)
                    continue
                }
                if idsByFolder[named.id] == nil { folderOrder.append(named.id) }
                idsByFolder[named.id, default: []].append(contentsOf: ids)
            }
        }

        for folderId in folderOrder {
            guard let named = foldersById[folderId] else { continue }
            var state = FolderChangeState(raw: named.changeState)
            let before = state
            var listed = Set(state.recheck)
            for id in idsByFolder[folderId] ?? [] where listed.insert(id).inserted {
                state.recheck.append(id)
                summary.listedIds += 1
            }
            if state.recheck.count > SyncConfig.changeRecheckLimit {
                state.recheck = Array(state.recheck.prefix(SyncConfig.changeRecheckLimit))
                armFolderIds.insert(folderId)
            }
            if state != before {
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [state.encoded, folderId])
            }
        }

        for accountId in armAccountIds.sorted() {
            armFolderIds.formUnion(try String.fetchAll(
                db, sql: "SELECT id FROM folder WHERE accountId = ?", arguments: [accountId]))
        }
        for folderId in armFolderIds.sorted() {
            try markCatchUpLapse(folderId: folderId, db: db)
        }
        summary.armedFolders = armFolderIds.count
        return summary
    }
}
