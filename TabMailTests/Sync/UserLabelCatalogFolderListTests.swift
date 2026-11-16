/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// INVARIANT: applying an account's folder list keeps that account's user labels
// in step with the provider's label catalog, and only a provider that HAS a
// server-side catalog may remove labels. Gmail lists its labels as folders, so a
// listed label is stored (system labels flagged, TabMail's reserved `tm_*` names
// left out) and a stored label Gmail no longer lists is removed with its message
// associations. IMAP keywords and Outlook categories have no catalog in the
// folder list: applying a folder list must leave their labels and associations
// exactly as they were, whatever folders it holds.

@Suite("Applying a folder list keeps user labels in step with the provider's catalog")
struct UserLabelCatalogFolderListTests {

    private func folder(_ name: String, _ path: String, _ role: FolderRole = .custom) -> FolderInfo {
        FolderInfo(name: name, path: path, role: role, unreadCount: 0, totalCount: 0)
    }

    /// A database holding one account of `provider`, its inbox, one message in it,
    /// and one stored label `providerLabelId` applied to that message.
    private func seeded(_ provider: AccountProvider, accountId: String, providerLabelId: String, name: String) throws -> (db: DatabaseQueue, account: Account, label: UserLabel, header: MessageHeader) {
        let db = try TestDatabase.make()
        let account = try TestDatabase.insertAccount(db, id: accountId, email: "\(accountId)@example.com", provider: provider)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let header = try TestDatabase.insertMessageHeader(
            db, messageId: "1", folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
            accountId: accountId, folderPath: "INBOX")
        let label = UserLabel(accountId: accountId, providerLabelId: providerLabelId, name: name, isSystem: false)
        try db.write { db in
            try label.insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: label.id).insert(db)
        }
        return (db, account, label, header)
    }

    private func labels(_ db: DatabaseQueue, accountId: String) throws -> [String: UserLabel] {
        try db.read { db in
            Dictionary(uniqueKeysWithValues: try UserLabel
                .filter(Column("accountId") == accountId).fetchAll(db)
                .map { ($0.providerLabelId, $0) })
        }
    }

    private func associations(_ db: DatabaseQueue, messageId: String) throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT userLabelId FROM messageUserLabel WHERE messageId = ?", arguments: [messageId]))
        }
    }

    @Test("Gmail: listed labels are stored, system ones flagged, tm_* left out, and an unlisted label is removed with its associations")
    func gmailCatalogFollowsTheFolderList() throws {
        let s = try seeded(.gmail, accountId: "catalog-gmail", providerLabelId: "Label_old", name: "Old")
        let folders = [
            folder("INBOX", "INBOX", .inbox),
            folder("Work", "Label_100"),
            folder("Forums", "CATEGORY_FORUMS"),
            folder("tm_reply", "Label_200"),
        ]
        try s.db.write { db in _ = try SyncEngine.applyFolderList(folders, account: s.account, db: db) }

        let stored = try labels(s.db, accountId: s.account.id)
        #expect(Set(stored.keys) == ["Label_100", "CATEGORY_FORUMS"], "stored: \(stored.keys.sorted())")
        #expect(stored["Label_100"]?.name == "Work")
        #expect(stored["Label_100"]?.isSystem == false)
        #expect(stored["CATEGORY_FORUMS"]?.isSystem == true)
        #expect(try associations(s.db, messageId: s.header.id).isEmpty,
                "the removed label's association with the message survived")
    }

    @Test("Gmail: a label renamed on the server is renamed in place, keeping its associations; another account's label is untouched")
    func gmailRenameUpdatesTheStoredLabel() throws {
        let s = try seeded(.gmail, accountId: "catalog-gmail-rename", providerLabelId: "Label_7", name: "Old name")
        let other = try TestDatabase.insertAccount(s.db, id: "catalog-gmail-other", email: "catalog-gmail-other@example.com", provider: .gmail)
        let otherLabel = UserLabel(accountId: other.id, providerLabelId: "Label_7", name: "Old name", isSystem: false)
        try s.db.write { db in try otherLabel.insert(db) }

        let folders = [folder("INBOX", "INBOX", .inbox), folder("New name", "Label_7")]
        try s.db.write { db in _ = try SyncEngine.applyFolderList(folders, account: s.account, db: db) }

        let stored = try labels(s.db, accountId: s.account.id)
        #expect(Set(stored.keys) == ["Label_7"], "stored: \(stored.keys.sorted())")
        #expect(stored["Label_7"]?.id == s.label.id, "the renamed label got a new row")
        #expect(stored["Label_7"]?.name == "New name", "the stored label kept the old name")
        #expect(try associations(s.db, messageId: s.header.id) == [s.label.id],
                "the renamed label lost its association with the message")
        #expect(try labels(s.db, accountId: other.id)["Label_7"]?.name == "Old name",
                "another account's label with the same id was renamed")
    }

    @Test("Gmail: when the last user label is deleted on the server, an empty catalog removes the stored label and its associations; another account's label stays")
    func gmailEmptyCatalogRemovesTheLastLabel() throws {
        let s = try seeded(.gmail, accountId: "catalog-gmail-empty", providerLabelId: "Label_7", name: "Receipts")
        let other = try TestDatabase.insertAccount(s.db, id: "catalog-gmail-empty-other", email: "catalog-gmail-empty-other@example.com", provider: .gmail)
        let otherLabel = UserLabel(accountId: other.id, providerLabelId: "Label_7", name: "Receipts", isSystem: false)
        try s.db.write { db in try otherLabel.insert(db) }
        #expect(try associations(s.db, messageId: s.header.id) == [s.label.id], "setup: the label is not on the message")

        // Gmail lists only its system folders: the label catalog is EMPTY, not absent.
        let folders = [folder("INBOX", "INBOX", .inbox)]
        #expect(GmailProvider.userLabelCatalog(from: folders) == [], "setup: the folder list still holds a label")
        try s.db.write { db in _ = try SyncEngine.applyFolderList(folders, account: s.account, db: db) }

        #expect(try labels(s.db, accountId: s.account.id).isEmpty, "the label Gmail no longer has is still stored")
        #expect(try associations(s.db, messageId: s.header.id).isEmpty, "the deleted label is still on the message")
        #expect(try s.db.read { db in try MessageHeader.fetchOne(db, key: s.header.id) } != nil, "the message itself was removed")
        #expect(try labels(s.db, accountId: other.id)["Label_7"] != nil, "another account's label was removed")
    }

    @Test("IMAP, iCloud and Outlook: a folder list leaves the account's labels and their associations untouched", arguments: [AccountProvider.imap, .icloud, .outlook])
    func providersWithoutACatalogKeepTheirLabels(_ provider: AccountProvider) throws {
        let s = try seeded(provider, accountId: "catalog-\(provider.rawValue)", providerLabelId: "receipts", name: "receipts")
        let folders = [folder("INBOX", "INBOX", .inbox), folder("Work", "Work"), folder("receipts", "receipts")]
        try s.db.write { db in _ = try SyncEngine.applyFolderList(folders, account: s.account, db: db) }

        let stored = try labels(s.db, accountId: s.account.id)
        #expect(Set(stored.keys) == ["receipts"], "\(provider) stored: \(stored.keys.sorted())")
        #expect(stored["receipts"]?.name == "receipts", "\(provider) renamed the label")
        #expect(try associations(s.db, messageId: s.header.id) == [s.label.id],
                "\(provider) lost the label's association with the message")
    }
}
