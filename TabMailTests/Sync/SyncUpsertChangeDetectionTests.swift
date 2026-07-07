/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Guards the change-detection added to `SyncEngineFullSync`'s upsert (2026-07-06).
/// The old path called `existing.update(db)` unconditionally, rewriting every folder
/// row on every full sync — pure WAL churn. The fix uses
/// `existing.updateChanges(db, from: original)`, which must be a NO-OP (no write,
/// returns false) when the server data is unchanged. If `MessageHeader` ever gains an
/// always-dirty column, `unchangedDataIsNoOp` fails and the churn silently returns.
@Suite("Sync upsert change-detection")
struct SyncUpsertChangeDetectionTests {

    @Test("Re-applying identical server data writes nothing (updateChanges == false)")
    func unchangedDataIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")

        // Fetch the STORED row so any GRDB round-trip (date precision, etc.) is already
        // baked in — re-applying these exact values must therefore be a no-op.
        let fetched: MessageHeader = try db.read {
            try MessageHeader.filter(Column("messageId") == "m1").fetchOne($0)!
        }

        try db.write { db in
            var existing = fetched
            let original = existing
            // Mimic the sync upsert re-applying the SAME server values.
            existing.isRead = fetched.isRead
            existing.isFlagged = fetched.isFlagged
            existing.date = fetched.date
            existing.from = fetched.from
            existing.to = fetched.to
            existing.rfc822MessageId = fetched.rfc822MessageId
            let changed = try existing.updateChanges(db, from: original)
            #expect(changed == false, "Identical server data must not write — this is the WAL-churn fix")
        }
    }

    @Test("A changed field still writes and persists (updateChanges == true)")
    func changedFieldPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(db, messageId: "m1", folderId: "acc1:INBOX", accountId: "acc1")

        let fetched: MessageHeader = try db.read {
            try MessageHeader.filter(Column("messageId") == "m1").fetchOne($0)!
        }

        try db.write { db in
            var existing = fetched
            let original = existing
            existing.isRead = !fetched.isRead
            let changed = try existing.updateChanges(db, from: original)
            #expect(changed == true, "A real field change must still write")
        }

        let after: MessageHeader = try db.read {
            try MessageHeader.filter(Column("messageId") == "m1").fetchOne($0)!
        }
        #expect(after.isRead == !fetched.isRead, "The changed field must persist")
    }
}
