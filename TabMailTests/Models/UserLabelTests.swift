/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("UserLabel Model")
struct UserLabelTests {

    // MARK: - UserLabel CRUD

    @Test("Insert and fetch UserLabel")
    func insertFetchUserLabel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
        }
        // The primary key is the account-prefixed SURROGATE, not the provider's
        // own label id (D10 / `IOS-LABEL-001`).
        let fetched = try db.read { try UserLabel.fetchOne($0, key: "acc1:Label_1") }
        #expect(fetched != nil)
        #expect(fetched?.name == "Work")
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.providerLabelId == "Label_1")
        #expect(fetched?.isSystem == false)
    }

    /// ⚠️ RE-SCOPED, NOT DELETED (D10 / `IOS-LABEL-001`). Its previous display name
    /// was **"UserLabel round-trip preserves all fields"** and its previous body
    /// asserted `fetched?.id == "sys_starred"` after constructing the row with
    /// `id: "sys_starred"` — i.e. it ENCODED the defect, pinning the bare provider
    /// label id as the primary key. That identity is exactly what made two accounts
    /// sharing a label name share one row. The round-trip property it was really
    /// after is preserved below; only the id it expects has changed, and the new
    /// name says which id that is.
    @Test("UserLabel round-trip preserves all fields under the surrogate id")
    func userLabelRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "sys_starred", name: "STARRED", isSystem: true).insert(db)
        }
        let fetched = try db.read { try UserLabel.fetchOne($0, key: "acc1:sys_starred") }
        #expect(fetched?.id == "acc1:sys_starred")
        #expect(fetched?.providerLabelId == "sys_starred")
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.name == "STARRED")
        #expect(fetched?.isSystem == true)
    }

    @Test("UserLabel upsert with save()")
    func userLabelUpsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
        }
        // Upsert with new name
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work Updated", isSystem: false).save(db)
        }
        let fetched = try db.read { try UserLabel.fetchOne($0, key: "acc1:Label_1") }
        #expect(fetched?.name == "Work Updated")
        // Should still be only 1 record
        let count = try db.read { try UserLabel.fetchCount($0) }
        #expect(count == 1)
    }

    // MARK: - MessageUserLabel Join

    @Test("Insert and fetch MessageUserLabel")
    func insertFetchMessageUserLabel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db)
        }
        let rows = try db.read { try MessageUserLabel.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].messageId == header.id)
        #expect(rows[0].userLabelId == "acc1:Label_1")
    }

    @Test("MessageUserLabel composite PK prevents duplicates")
    func messageUserLabelDuplicatePrevention() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db)
        }
        // Second insert with onConflict: .ignore should not throw
        try db.write { db in
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db, onConflict: .ignore)
        }
        let count = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(count == 1)
    }

    @Test("MessageUserLabel JOIN with UserLabel via association")
    func messageUserLabelJoin() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
            try UserLabel(accountId: "acc1", providerLabelId: "Label_2", name: "Personal", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_2").insert(db)
        }
        let rows = try db.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == header.id)
                .including(required: MessageUserLabel.userLabel)
                .asRequest(of: MessageUserLabelWithUserLabel.self)
                .fetchAll(db)
        }
        #expect(rows.count == 2)
        let names = Set(rows.map(\.userLabel.name))
        #expect(names.contains("Work"))
        #expect(names.contains("Personal"))
    }

    // MARK: - Cascade Deletes

    @Test("Deleting messageHeader cascades to messageUserLabel")
    func cascadeMessageToLabel() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db)
        }
        // Delete message header
        try db.write { db in
            _ = try MessageHeader.deleteAll(db, keys: [header.id])
        }
        let joinCount = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(joinCount == 0)
        // UserLabel should still exist
        let labelCount = try db.read { try UserLabel.fetchCount($0) }
        #expect(labelCount == 1)
    }

    @Test("Deleting userLabel cascades to messageUserLabel")
    func cascadeLabelToJoin() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db)
        }
        // Delete label
        try db.write { db in
            _ = try UserLabel.deleteAll(db, keys: ["acc1:Label_1"])
        }
        let joinCount = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(joinCount == 0)
    }

    @Test("Deleting account cascades to userLabel and messageUserLabel")
    func cascadeAccountToLabels() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:Label_1").insert(db)
        }
        // Delete account
        try db.write { db in
            _ = try Account.deleteAll(db, keys: ["acc1"])
        }
        let labelCount = try db.read { try UserLabel.fetchCount($0) }
        let joinCount = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(labelCount == 0)
        #expect(joinCount == 0)
    }

    // MARK: - PendingOperation Extensions

    @Test("PendingOperation addUserLabel type and userLabelId field")
    func pendingOpAddUserLabel() throws {
        let op = PendingOperation(
            type: .addUserLabel,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            userLabelId: "Label_1"
        )
        #expect(op.type == .addUserLabel)
        #expect(op.userLabelId == "Label_1")
        #expect(op.messageIds == ["msg1"])
        #expect(op.status == PendingStatus.queued.rawValue)
    }

    @Test("PendingOperation removeUserLabel type")
    func pendingOpRemoveUserLabel() throws {
        let op = PendingOperation(
            type: .removeUserLabel,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            userLabelId: "Label_2"
        )
        #expect(op.type == .removeUserLabel)
        #expect(op.userLabelId == "Label_2")
    }

    @Test("PendingOperation userLabelId defaults to nil")
    func pendingOpUserLabelIdDefault() {
        let op = PendingOperation(
            type: .setTag,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            tagValue: "reply"
        )
        #expect(op.userLabelId == nil)
    }

    @Test("PendingOperation with userLabelId persists to GRDB")
    func pendingOpUserLabelIdPersistence() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let op = PendingOperation(
            type: .addUserLabel,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            userLabelId: "Label_42"
        )
        try db.write { try op.insert($0) }
        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.type == .addUserLabel)
        #expect(fetched?.userLabelId == "Label_42")
    }
}
