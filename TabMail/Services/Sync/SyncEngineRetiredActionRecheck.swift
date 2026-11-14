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
// is read for its raw columns only: account, folder path(s), kind and message
// ids. Nothing is re-sent or replayed, and no model is decoded: a value that
// does not read is an undecodable row, never a throw, so this can never stop
// `AppDatabase.init`.
//
// Per row, for an account that holds a change bookmark (`Account.lastHistoryId`;
// an account with none, IMAP today, has every folder listed by the full sync and
// is left alone):
// - a move (archive, delete, move) or a read/flag change: its ids go on the
//   re-read list (`FolderChangeState.recheck`) of the folder it was queued on
//   and, for a move, of its destination, but only of a folder whose change state
//   is TRACKED. The change reader reads those messages again and the apply
//   writes what the server says (Gmail places a message by its labels in every
//   folder; Outlook reads folder by folder, so a message the server holds
//   elsewhere is a removal there). An untracked folder gets nothing: the full
//   sync window-lists every untracked syncable folder, and a folder outside the
//   syncable set is listed when it is opened; listing an id there would only
//   stick, because a per-folder reader never reads that folder's list.
// - a draft delete: its folder's catch-up is armed (`markCatchUpLapse`), which
//   loads the server draft back. Its address is a draft resource, not a message
//   id, so it never goes on a list.
// - a user-label change or a replied/forwarded mark: nothing. Neither the re-read
//   (`mergeChangeRecord` writes read, flag, tag, identity and references into a
//   stored row) nor the catch-up (read, flag, removals, missing mail) corrects a
//   stored row's labels or answered state, so listing them would settle the id
//   with nothing corrected. Registered in IOS-ACTION-003.
// - tags (local-only on these providers, ADR-IOS-036) and draft saves (re-queued
//   by the boundary): nothing.
// - a row whose kind or ids do not read (an older release's kind, ids that are
//   not a JSON list): its folder's catch-up is armed, or every folder's of the
//   account when its folder does not resolve. The same for a move or read/flag
//   row whose folder no longer exists. Never skipped silently.
// A list over `SyncConfig.changeRecheckLimit` keeps its first ids and arms the
// folder's catch-up, as the apply does.
//
// The ids are the queue's own: the provider's id for the message in the folder
// the action was queued on. A drained move re-addresses the queued rows after it
// to the destination id the server named (`MessageHeaderRekey
// .readdressQueuedOperations`), and an unsent Outlook move still names the
// original id, which is where the server still has the message. The local row's
// address after an optimistic move is never used. Folders resolve by the path
// the row recorded, never by role (ADR-IOS-059).

/// What the boundary did with the retired rows, for its debug log.
struct RetiredActionRecheckSummary: Sendable, Equatable {
    /// Distinct (folder, id) pairs put on a re-read list.
    var listedIds = 0
    /// Folders whose catch-up was armed.
    var armedFolders = 0
    /// Rows whose kind or ids did not read.
    var undecodableRows = 0
}

extension SyncEngine {

    /// Kinds whose optimistic local effect a re-read corrects: a move's folder
    /// and a read or flag change.
    nonisolated static let retiredActionKindsReadAgain: Set<OperationType> = [
        .archive, .delete, .move, .markRead, .markUnread, .markFlagged, .markUnflagged,
    ]

    /// Inside the release boundary's transaction, BEFORE its delete: put the
    /// retired actions' message ids on the re-read lists of the tracked folders
    /// they named, or arm the catch-up where a re-read cannot name them.
    nonisolated static func recheckRetiredActions(db: Database) throws -> RetiredActionRecheckSummary {
        var summary = RetiredActionRecheckSummary()
        let bookmarked = Set(try rawStrings(db, "SELECT id FROM account WHERE lastHistoryId IS NOT NULL"))
        guard !bookmarked.isEmpty else { return summary }

        // Folder (id, change state) by (account, path), read once per pair.
        var foldersByKey: [String: RetiredActionFolder?] = [:]
        var foldersById: [String: RetiredActionFolder] = [:]
        func folder(accountId: String, path: String) throws -> RetiredActionFolder? {
            let key = "\(accountId)\u{1F}\(path)"
            if let cached = foldersByKey[key] { return cached }
            let row = try Row.fetchOne(
                db, sql: "SELECT id, changeState FROM folder WHERE accountId = ? AND path = ?",
                arguments: [accountId, path])
            let found = row.flatMap { row in
                Self.rawString(row, "id").map { RetiredActionFolder(id: $0, changeState: Self.rawString(row, "changeState")) }
            }
            foldersByKey[key] = found
            if let found { foldersById[found.id] = found }
            return found
        }

        var idsByFolder: [String: [String]] = [:]
        var folderOrder: [String] = []
        var armFolderIds = Set<String>()
        var armAccountIds = Set<String>()

        let rows = try Row.fetchAll(db, sql: """
            SELECT accountId, folderPath, destinationPath, type, messageIdsJSON
            FROM pendingOperation ORDER BY queuePosition
            """)
        for row in rows {
            guard let accountId = rawString(row, "accountId"), bookmarked.contains(accountId) else { continue }
            let folderPath = rawString(row, "folderPath")
            let type = rawString(row, "type").flatMap(OperationType.init(rawValue:))
            let ids = rawString(row, "messageIdsJSON")
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            guard let type, let ids, let folderPath else {
                summary.undecodableRows += 1
                if let folderPath, let known = try folder(accountId: accountId, path: folderPath) {
                    armFolderIds.insert(known.id)
                } else {
                    armAccountIds.insert(accountId)
                }
                continue
            }
            if type == .deleteDraft {
                if let drafts = try folder(accountId: accountId, path: folderPath) {
                    armFolderIds.insert(drafts.id)
                } else {
                    armAccountIds.insert(accountId)
                }
                continue
            }
            guard retiredActionKindsReadAgain.contains(type), !ids.isEmpty else { continue }
            var paths = [folderPath]
            if PendingOperationSnapshot.destructiveTypes.contains(type),
               let destination = rawString(row, "destinationPath") {
                paths.append(destination)
            }
            for path in paths {
                guard let named = try folder(accountId: accountId, path: path) else {
                    armAccountIds.insert(accountId)
                    continue
                }
                guard FolderChangeState(raw: named.changeState).tracking else { continue }
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
            armFolderIds.formUnion(try rawStrings(db, "SELECT id FROM folder WHERE accountId = ?", [accountId]))
        }
        for folderId in armFolderIds.sorted() {
            try markCatchUpLapse(folderId: folderId, db: db)
        }
        summary.armedFolders = armFolderIds.count
        return summary
    }

    /// A column's text, or nil when it is NULL or not text. Never throws or traps.
    private nonisolated static func rawString(_ row: Row, _ column: String) -> String? {
        String.fromDatabaseValue(row[column] as DatabaseValue)
    }

    /// The text values of a one-column query; values that are not text are left out.
    private nonisolated static func rawStrings(
        _ db: Database, _ sql: String, _ arguments: StatementArguments = StatementArguments()
    ) throws -> [String] {
        try DatabaseValue.fetchAll(db, sql: sql, arguments: arguments).compactMap(String.fromDatabaseValue)
    }
}

/// A folder as the boundary reads it: its id and its raw change state only.
private struct RetiredActionFolder {
    let id: String
    let changeState: String?
}
