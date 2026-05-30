/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("UserLabelStore")
struct UserLabelStoreTests {

    // MARK: - Excluded Keywords

    @Test("isExcludedKeyword detects tm_ prefix")
    func excludedTmPrefix() {
        #expect(UserLabelStore.isExcludedKeyword("tm_reply") == true)
        #expect(UserLabelStore.isExcludedKeyword("tm_archive") == true)
        #expect(UserLabelStore.isExcludedKeyword("TM_DELETE") == true)
    }

    @Test("isExcludedKeyword detects conventional flags")
    func excludedConventionalFlags() {
        #expect(UserLabelStore.isExcludedKeyword("$Forwarded") == true)
        #expect(UserLabelStore.isExcludedKeyword("$MDNSent") == true)
        #expect(UserLabelStore.isExcludedKeyword("$Junk") == true)
        #expect(UserLabelStore.isExcludedKeyword("$NotJunk") == true)
        #expect(UserLabelStore.isExcludedKeyword("$HasAttachment") == true)
        #expect(UserLabelStore.isExcludedKeyword("$Phishing") == true)
    }

    @Test("isExcludedKeyword allows user keywords")
    func allowedUserKeywords() {
        #expect(UserLabelStore.isExcludedKeyword("Work") == false)
        #expect(UserLabelStore.isExcludedKeyword("personal") == false)
        #expect(UserLabelStore.isExcludedKeyword("project_alpha") == false)
    }

    @Test("isGmailSystemLabel detects system labels by ID")
    func gmailSystemLabels() {
        #expect(UserLabelStore.isGmailSystemLabel(id: "INBOX") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "SENT") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "STARRED") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "CATEGORY_SOCIAL") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "CATEGORY_CUSTOM") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "[Imap]/Sent") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "[Gmail]/All Mail") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_123") == true)  // Label_N without a name = system label
    }

    @Test("isGmailSystemLabel detects auto-created labels by name")
    func gmailSystemLabelsByName() {
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_123", name: "Notes") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_456", name: "Conversation History") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_789", name: "All Mail") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_3", name: "External") == true)
        // User-created labels have Label_N IDs but proper display names — not excluded
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_100", name: "Work") == false)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_42", name: "Projects") == false)
    }

    @Test("isGmailSystemLabel blocks Label_N IDs without proper name")
    func gmailLabelNPattern() {
        // Label_N with no name (name defaults to ID) — system label
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_46") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_1") == true)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_9999") == true)
        // Not Label_N pattern
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_") == false)
        #expect(UserLabelStore.isGmailSystemLabel(id: "Label_abc") == false)
        #expect(UserLabelStore.isGmailSystemLabel(id: "MyLabel_1") == false)
    }

    // MARK: - Reserved Names

    @Test("isReservedName blocks tm_ prefix")
    func reservedTmPrefix() {
        #expect(UserLabelStore.isReservedName("tm_test") == true)
        #expect(UserLabelStore.isReservedName("TM_TEST") == true)
    }

    @Test("isReservedName blocks IMAP standard flags")
    func reservedImapFlags() {
        #expect(UserLabelStore.isReservedName("\\Seen") == true)
        #expect(UserLabelStore.isReservedName("\\Answered") == true)
        #expect(UserLabelStore.isReservedName("\\Flagged") == true)
        #expect(UserLabelStore.isReservedName("\\Deleted") == true)
        #expect(UserLabelStore.isReservedName("\\Draft") == true)
    }

    @Test("isReservedName blocks conventional IMAP keywords")
    func reservedConventionalKeywords() {
        #expect(UserLabelStore.isReservedName("$Forwarded") == true)
        #expect(UserLabelStore.isReservedName("$Junk") == true)
    }

    @Test("isReservedName blocks Gmail system names")
    func reservedGmailNames() {
        #expect(UserLabelStore.isReservedName("INBOX") == true)
        #expect(UserLabelStore.isReservedName("inbox") == true)
        #expect(UserLabelStore.isReservedName("Sent") == true)
        #expect(UserLabelStore.isReservedName("TRASH") == true)
        #expect(UserLabelStore.isReservedName("SPAM") == true)
        #expect(UserLabelStore.isReservedName("Starred") == true)
        #expect(UserLabelStore.isReservedName("IMPORTANT") == true)
        #expect(UserLabelStore.isReservedName("UNREAD") == true)
        #expect(UserLabelStore.isReservedName("category_social") == true)
    }

    @Test("isReservedName blocks Gmail Label_N pattern")
    func reservedGmailLabelN() {
        #expect(UserLabelStore.isReservedName("Label_46") == true)
        #expect(UserLabelStore.isReservedName("label_1") == true)
        #expect(UserLabelStore.isReservedName("Label_") == false)  // No digits after underscore
        #expect(UserLabelStore.isReservedName("Label_abc") == false)  // Non-numeric suffix
    }

    @Test("isReservedName allows normal user names")
    func allowedNames() {
        #expect(UserLabelStore.isReservedName("Work") == false)
        #expect(UserLabelStore.isReservedName("Personal") == false)
        #expect(UserLabelStore.isReservedName("Project X") == false)
        #expect(UserLabelStore.isReservedName("CS231n") == false)
    }

    // MARK: - Nested Label Splitting

    @Test("splitNestedLabelName splits by slash")
    func splitNested() {
        let segments = UserLabelStore.splitNestedLabelName("Work/Projects/Alpha")
        #expect(segments == ["Work", "Projects", "Alpha"])
    }

    @Test("splitNestedLabelName handles single segment")
    func splitSingle() {
        let segments = UserLabelStore.splitNestedLabelName("Work")
        #expect(segments == ["Work"])
    }

    @Test("splitNestedLabelName handles empty segments")
    func splitEmpty() {
        let segments = UserLabelStore.splitNestedLabelName("Work//Alpha")
        #expect(segments == ["Work", "Alpha"])
    }

    @Test("splitNestedLabelName trims whitespace")
    func splitWhitespace() {
        let segments = UserLabelStore.splitNestedLabelName("Work / Projects / Alpha")
        #expect(segments == ["Work", "Projects", "Alpha"])
    }

    // MARK: - Shared Query Utility: loadLabels

    @Test("loadLabels returns labels grouped by messageId")
    func loadLabelsGrouped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "200")
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Personal", isSystem: false).insert(db)
            try MessageUserLabel(messageId: msg1.id, userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: msg1.id, userLabelId: "L2").insert(db)
            try MessageUserLabel(messageId: msg2.id, userLabelId: "L1").insert(db)
        }
        let result = try db.read { db in
            try UserLabelStore.loadLabels(for: [msg1.id, msg2.id], in: db)
        }
        #expect(result[msg1.id]?.count == 2)
        #expect(result[msg2.id]?.count == 1)
    }

    @Test("loadLabels filters out system labels")
    func loadLabelsFiltersSystem() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            try UserLabel(id: "SYS", accountId: "acc1", name: "STARRED", isSystem: true).insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "SYS").insert(db)
        }
        let result = try db.read { db in
            try UserLabelStore.loadLabels(for: [msg.id], in: db)
        }
        #expect(result[msg.id]?.count == 1)
        #expect(result[msg.id]?.first?.name == "Work")
    }

    @Test("loadLabels returns empty for no messageIds")
    func loadLabelsEmpty() throws {
        let db = try TestDatabase.make()
        let result = try db.read { db in
            try UserLabelStore.loadLabels(for: [], in: db)
        }
        #expect(result.isEmpty)
    }

    @Test("loadLabels sorts alphabetically")
    func loadLabelsSorted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Zebra", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Alpha", isSystem: false).insert(db)
            try UserLabel(id: "L3", accountId: "acc1", name: "Middle", isSystem: false).insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "L2").insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "L3").insert(db)
        }
        let result = try db.read { db in
            try UserLabelStore.loadLabels(for: [msg.id], in: db)
        }
        let names = result[msg.id]?.map(\.name)
        #expect(names == ["Alpha", "Middle", "Zebra"])
    }

    // MARK: - CRUD Methods

    @Test("findByName returns label case-insensitively")
    func findByName() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
        }
        let found = try db.read { db in
            try UserLabelStore.findByName("work", accountId: "acc1", in: db)
        }
        #expect(found?.id == "L1")
    }

    @Test("findByName returns nil for non-existent label")
    func findByNameMissing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let found = try db.read { db in
            try UserLabelStore.findByName("NonExistent", accountId: "acc1", in: db)
        }
        #expect(found == nil)
    }

    @Test("findByName skips system labels")
    func findByNameSkipsSystem() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try UserLabel(id: "SYS", accountId: "acc1", name: "STARRED", isSystem: true).insert(db)
        }
        let found = try db.read { db in
            try UserLabelStore.findByName("STARRED", accountId: "acc1", in: db)
        }
        #expect(found == nil)
    }

    @Test("allLabels returns non-system labels sorted alphabetically")
    func allLabels() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Zebra", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Alpha", isSystem: false).insert(db)
            try UserLabel(id: "SYS", accountId: "acc1", name: "STARRED", isSystem: true).insert(db)
        }
        let labels = try db.read { db in
            try UserLabelStore.allLabels(accountId: "acc1", in: db)
        }
        #expect(labels.count == 2)
        #expect(labels[0].name == "Alpha")
        #expect(labels[1].name == "Zebra")
    }

    @Test("labelsForMessage returns non-system labels for a message")
    func labelsForMessage() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg = try TestDatabase.insertMessageHeader(db)
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Play", isSystem: false).insert(db)
            try UserLabel(id: "SYS", accountId: "acc1", name: "STARRED", isSystem: true).insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: msg.id, userLabelId: "SYS").insert(db)
        }
        let labels = try db.read { db in
            try UserLabelStore.labelsForMessage(msg.id, in: db)
        }
        #expect(labels.count == 1)
        #expect(labels[0].name == "Work")
    }

    // MARK: - Menu Sorting

    @Test("labelsSortedForMenu sorts applied first, then by frequency, then alphabetical")
    func menuSorting() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "200")
        let msg3 = try TestDatabase.insertMessageHeader(db, messageId: "300")
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Personal", isSystem: false).insert(db)
            try UserLabel(id: "L3", accountId: "acc1", name: "Rare", isSystem: false).insert(db)
            // msg1 has "Work" (applied to target message)
            try MessageUserLabel(messageId: msg1.id, userLabelId: "L1").insert(db)
            // "Personal" appears on 2 inbox messages (higher frequency)
            try MessageUserLabel(messageId: msg2.id, userLabelId: "L2").insert(db)
            try MessageUserLabel(messageId: msg3.id, userLabelId: "L2").insert(db)
            // "Rare" appears on 1 inbox message
            try MessageUserLabel(messageId: msg2.id, userLabelId: "L3").insert(db)
        }
        let inboxFolderId = "acc1:INBOX"
        let sorted = try db.read { db in
            try UserLabelStore.labelsSortedForMenu(
                accountId: "acc1",
                messageId: msg1.id,
                inboxFolderIds: [inboxFolderId],
                in: db
            )
        }
        #expect(sorted.count == 3)
        // First: applied label "Work" (checkmarked)
        #expect(sorted[0].label.name == "Work")
        #expect(sorted[0].isApplied == true)
        // Second: "Personal" (frequency 2, higher than "Rare")
        #expect(sorted[1].label.name == "Personal")
        #expect(sorted[1].isApplied == false)
        // Third: "Rare" (frequency 1)
        #expect(sorted[2].label.name == "Rare")
        #expect(sorted[2].isApplied == false)
    }

    // MARK: - Migration v31

    @Test("Migration v31 creates userLabel and messageUserLabel tables")
    func migrationCreatesTable() throws {
        let db = try TestDatabase.make()
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        #expect(tables.contains("userLabel"))
        #expect(tables.contains("messageUserLabel"))
    }

    @Test("Migration v31 adds userLabelId column to pendingOperation")
    func migrationAddsColumn() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        // Insert a PendingOperation with userLabelId
        let op = PendingOperation(
            type: .addUserLabel,
            messageIds: ["msg1"],
            accountId: "acc1",
            folderPath: "INBOX",
            userLabelId: "Label_42"
        )
        try db.write { try op.insert($0) }
        let fetched = try db.read { try PendingOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.userLabelId == "Label_42")
    }

    @Test("Migration v31 creates index on messageUserLabel.userLabelId")
    func migrationCreatesIndex() throws {
        let db = try TestDatabase.make()
        let indexes = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messageUserLabel'")
        }
        #expect(indexes.contains("idx_messageUserLabel_userLabelId"))
    }
}
