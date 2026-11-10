/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The folder role edits made in Settings, each inside the caller's write
/// transaction. An edit that changes which folder is the account's Inbox marks the
/// account's full sync due (`lastFullSyncAt = NULL`, as Reset does) and returns
/// true, and the caller then starts a sync, so the full sync takes the new
/// Inbox's state and delta cursor. Every provider is treated alike, so this layer
/// stays provider-blind.
enum FolderRoleEdit {
    /// Gives `role` to `folderId`, taking it from any other folder of the account.
    /// Returns whether the edit changed which folder is the Inbox.
    @discardableResult
    static func assign(_ role: FolderRole, to folderId: String, accountId: String, db: Database) throws -> Bool {
        try edit(accountId: accountId, db: db) {
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE accountId = ? AND role = ?",
                arguments: [FolderRole.custom.rawValue, accountId, role.rawValue]
            )
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE id = ?",
                arguments: [role.rawValue, folderId]
            )
        }
    }

    /// Takes `role` from every folder of the account.
    /// Returns whether the edit changed which folder is the Inbox.
    @discardableResult
    static func clear(_ role: FolderRole, accountId: String, db: Database) throws -> Bool {
        try edit(accountId: accountId, db: db) {
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE accountId = ? AND role = ?",
                arguments: [FolderRole.custom.rawValue, accountId, role.rawValue]
            )
        }
    }

    /// Sets one folder's role, leaving the other folders as they are.
    /// Returns whether the edit changed which folder is the Inbox.
    @discardableResult
    static func set(_ role: FolderRole, folderId: String, accountId: String, db: Database) throws -> Bool {
        try edit(accountId: accountId, db: db) {
            try db.execute(
                sql: "UPDATE folder SET role = ? WHERE id = ?",
                arguments: [role.rawValue, folderId]
            )
        }
    }

    private static func edit(accountId: String, db: Database, _ body: () throws -> Void) throws -> Bool {
        let inboxBefore = try inboxIds(accountId: accountId, db: db)
        try body()
        guard try inboxIds(accountId: accountId, db: db) != inboxBefore else { return false }
        _ = try Account
            .filter(Column("id") == accountId)
            .updateAll(db, Column("lastFullSyncAt").set(to: nil as Date?))
        return true
    }

    private static func inboxIds(accountId: String, db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT id FROM folder WHERE accountId = ? AND role = ? ORDER BY id",
            arguments: [accountId, FolderRole.inbox.rawValue]
        )
    }
}
