/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

// MARK: - The from-server insert guard (#755)
//
// A header insert from a server read may not re-create a message the change
// read has become authoritative for since that server read. A change read can
// prove a message gone (a CONDSTORE removal check, a QRESYNC VANISHED) while
// another path holds a header it fetched earlier: inserting that header
// afterwards keeps a row no later read reports. The paths that list outside the
// account's sync turn snapshot the folder's change bookmark and change state
// before their server read (`changeInsertPremise`) and insert only while both
// are byte-equal inside their own write transaction. A folder without a
// bookmark has no change read and is unaffected. Provider-blind: the bookmark
// and the state are compared as stored bytes.

extension SyncEngine {

    /// The folder's change bookmark and change state as stored before a server
    /// read; nil when the folder row is gone.
    struct ChangeInsertPremise: Sendable, Equatable {
        let changeCursor: String?
        let changeState: String?
    }

    /// The premise to hold over a server read of `folderId`.
    nonisolated static func changeInsertPremise(_ db: Database, folderId: String) throws -> ChangeInsertPremise? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT changeCursor, changeState FROM folder WHERE id = ?", arguments: [folderId])
        else { return nil }
        return ChangeInsertPremise(changeCursor: row["changeCursor"], changeState: row["changeState"])
    }

    /// Whether a header from a server read made under `premise` may be inserted
    /// now, inside the caller's write transaction: the folder still stores no
    /// bookmark, or the same bookmark and state as when the read began.
    nonisolated static func fromServerInsertAllowed(
        _ db: Database, folderId: String, premise: ChangeInsertPremise?
    ) throws -> Bool {
        guard let premise, let now = try changeInsertPremise(db, folderId: folderId) else { return false }
        if now.changeCursor == nil, premise.changeCursor == nil { return true }
        return now == premise
    }
}
