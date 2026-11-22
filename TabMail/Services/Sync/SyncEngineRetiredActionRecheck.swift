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
// An account whose ids are mailbox-local (a UID names a message only in its
// folder; not in `AccountOperationExecutor.accountScopedIdAccountIds`) and that
// holds a change bookmark on any folder takes the rule the drain applies to a
// move retired without proof (ADR-IOS-111, the exit rule):
// - a move: its source and destination folders drop their bookmark with one
//   self-heal owed (`dropChangeBookmark(selfHealDue: true)`), so the full sync
//   lists them and the self-heal reaches below the window. Its ids go on no
//   list: a source UID names nothing, or another message, in the destination,
//   and the optimistic row sits there under the source's address, which a
//   re-read can never prove it owns. Every folder of the account when the
//   destination is not recorded or a folder does not resolve;
// - a read/flag or user-label change: its ids go on its own folder's re-read
//   list (the same numbering), also when a retired move drops that folder: its
//   listing never replaces a held row's user labels, and its baseline read
//   answers the list;
// - a draft delete, or a row whose kind or ids do not read: its folder drops its
//   bookmark the same way (every folder of the account when it does not
//   resolve), since the catch-up there only checks the rows a folder holds;
// - anything else: nothing, as below.
// An account with no bookmark on any folder is left alone: the full sync lists
// every folder.
//
// Per row, for any other account that holds a change bookmark
// (`Account.lastHistoryId`):
// - a move (archive, delete, move) or a read/flag change: its ids go on the
//   re-read list (`FolderChangeState.recheck`) of the folder it was queued on
//   and, for a move, of its destination, whatever that folder's tracking or
//   synced state. Every reader reads every listed folder's list (Gmail reads
//   all lists and answers every folder by the message's labels; Outlook reads a
//   synced folder's list after its delta, also during its baseline, and a folder
//   outside the synced set's list alone on a `.all` pass), and the apply writes
//   the server's answer whatever the folder's held range (ADR-IOS-111). So an
//   older message's optimistic row is corrected in every folder the action
//   named: the full sync's window listing would not do it (its stale sweep is
//   date-bounded on Gmail and Outlook, and it never lists a folder outside the
//   synced set).
// - a draft delete: its folder's catch-up is armed (`markCatchUpLapse`), which
//   loads the server draft back. Its address is a draft resource, not a message
//   id, so it never goes on a list.
// - a user-label change (Gmail label, Outlook category): its ids go on the
//   re-read list of the folder it was queued on. The re-read's record carries
//   the message's whole label set when the reader knows it, and the merge
//   replaces the stored set with it (#882), so the label the gesture added or
//   removed shows as the server has it again (#903). The retired op no longer
//   shields the labels: the boundary deleted it.
// - a replied/forwarded mark: nothing. Neither the re-read nor the catch-up
//   (read, flag, removals, missing mail) corrects a stored row's answered
//   state, so listing it would settle the id with nothing corrected.
//   Registered in IOS-ACTION-003.
// - tags (local-only on these providers, ADR-IOS-036) and draft saves (re-queued
//   by the boundary): nothing.
// - a row whose kind or ids do not read (an older release's kind, ids that are
//   not a JSON list): its folder's catch-up is armed, or every folder's of the
//   account when its folder does not resolve. The same for a move, read/flag or
//   user-label row whose folder no longer exists. Never skipped silently.
// Every retired id is kept, whatever `SyncConfig.changeRecheckLimit`: the set
// is finite and written once, and each pass reads at most the per-pass budget
// (`SyncConfig.changeRereadBudgetPerPass`), so a long list drains over passes.
// The catch-up is not armed for them (it never corrects labels). The apply
// never cuts an id already stored; it cuts only a pass's own additions that
// take a list over the limit (ADR-IOS-111, amendment 2026-11-15, #903).
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
    /// Folders of mailbox-local accounts whose bookmark was dropped (exit rule).
    var droppedBookmarks = 0
}

extension SyncEngine {

    /// Kinds whose optimistic local effect a re-read corrects: a move's folder,
    /// a read or flag change, and a user-label change (#903).
    nonisolated static let retiredActionKindsReadAgain: Set<OperationType> = [
        .archive, .delete, .move, .markRead, .markUnread, .markFlagged, .markUnflagged,
        .addUserLabel, .removeUserLabel,
    ]

    /// Inside the release boundary's transaction, BEFORE its delete: put the
    /// retired actions' message ids on the re-read lists of the folders they
    /// named, or arm the catch-up where a re-read cannot name them.
    nonisolated static func recheckRetiredActions(db: Database) throws -> RetiredActionRecheckSummary {
        var summary = RetiredActionRecheckSummary()
        // An account whose ids name one message across folders, with a change
        // bookmark of its own; and an account whose ids are mailbox-local (a UID
        // names a message only in its folder) holding a bookmark on any folder.
        let accountScoped = try AccountOperationExecutor.accountScopedIdAccountIds(db)
        let bookmarked = Set(try rawStrings(db, "SELECT id FROM account WHERE lastHistoryId IS NOT NULL"))
        let mailboxLocal = Set(try rawStrings(
            db, "SELECT DISTINCT accountId FROM folder WHERE changeCursor IS NOT NULL")).subtracting(accountScoped)
        guard !bookmarked.isEmpty || !mailboxLocal.isEmpty else { return summary }

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
                Self.rawString(row, "id").map { id in
                    RetiredActionFolder(id: id, changeState: Self.rawString(row, "changeState"))
                }
            }
            foldersByKey[key] = found
            if let found { foldersById[found.id] = found }
            return found
        }

        var idsByFolder: [String: [String]] = [:]
        var folderOrder: [String] = []
        var armFolderIds = Set<String>()
        var armAccountIds = Set<String>()
        // Mailbox-local accounts: folders whose local view a retired action may
        // have left wrong where a re-read cannot fix it (ADR-IOS-111 exit rule).
        var dropFolderIds = Set<String>()
        var dropAccountIds = Set<String>()

        let rows = try Row.fetchAll(db, sql: """
            SELECT accountId, folderPath, destinationPath, type, messageIdsJSON
            FROM pendingOperation ORDER BY queuePosition
            """)
        for row in rows {
            guard let accountId = rawString(row, "accountId") else { continue }
            let local = mailboxLocal.contains(accountId)
            guard local || bookmarked.contains(accountId) else { continue }
            // Where a re-read cannot name the messages: on a mailbox-local
            // account the folder's bookmark is dropped with a self-heal owed (its
            // catch-up only checks the rows it holds); otherwise its catch-up is
            // armed. The account's every folder when the folder does not resolve.
            func cannotReRead(_ folderPath: String?) throws {
                if let folderPath, let known = try folder(accountId: accountId, path: folderPath) {
                    if local { dropFolderIds.insert(known.id) } else { armFolderIds.insert(known.id) }
                } else if local {
                    dropAccountIds.insert(accountId)
                } else {
                    armAccountIds.insert(accountId)
                }
            }
            let folderPath = rawString(row, "folderPath")
            let type = rawString(row, "type").flatMap(OperationType.init(rawValue:))
            let ids = rawString(row, "messageIdsJSON")
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            guard let type, let ids, let folderPath else {
                summary.undecodableRows += 1
                try cannotReRead(folderPath)
                continue
            }
            if type == .deleteDraft {
                try cannotReRead(folderPath)
                continue
            }
            guard retiredActionKindsReadAgain.contains(type), !ids.isEmpty else { continue }
            var paths = [folderPath]
            let isMove = PendingOperationSnapshot.destructiveTypes.contains(type)
            if isMove, let destination = rawString(row, "destinationPath") {
                paths.append(destination)
            }
            if local && isMove {
                // A UID names a message only in its folder, so a move's source
                // ids name nothing (or another message) in its destination, and
                // its optimistic row sits in the destination under the source's
                // address, which a re-read can never prove it owns. Both folders
                // take the exit rule a move retired without proof takes.
                for path in paths { try cannotReRead(path) }
                if paths.count == 1 { dropAccountIds.insert(accountId) }
                continue
            }
            for path in paths {
                guard let named = try folder(accountId: accountId, path: path) else {
                    try cannotReRead(nil)
                    continue
                }
                if idsByFolder[named.id] == nil { folderOrder.append(named.id) }
                idsByFolder[named.id, default: []].append(contentsOf: ids)
            }
        }

        for accountId in dropAccountIds.sorted() {
            dropFolderIds.formUnion(try rawStrings(db, "SELECT id FROM folder WHERE accountId = ?", [accountId]))
        }
        // A folder whose bookmark drops below keeps these ids too: its listing
        // and self-heal never replace a held row's user labels, and its next
        // read (the baseline) answers the list.
        for folderId in folderOrder {
            guard let named = foldersById[folderId] else { continue }
            var state = FolderChangeState(raw: named.changeState)
            let before = state
            var listed = Set(state.recheck)
            for id in idsByFolder[folderId] ?? [] where listed.insert(id).inserted {
                state.recheck.append(id)
                summary.listedIds += 1
            }
            if state != before {
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [state.encoded, folderId])
            }
        }
        for folderId in dropFolderIds.sorted() {
            try dropChangeBookmark(folderId: folderId, selfHealDue: true, db: db)
        }
        summary.droppedBookmarks = dropFolderIds.count

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

/// A folder as the boundary reads it: its id and its raw change state.
private struct RetiredActionFolder {
    let id: String
    let changeState: String?
}
