/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("UserLabel Sync Integration")
struct UserLabelSyncTests {

    // MARK: - MessageHeaderInfo userLabelIds

    @Test("MessageHeaderInfo defaults to empty userLabelIds")
    func headerInfoDefaultLabels() {
        let info = MessageHeaderInfo(
            messageId: "msg1", rfc822MessageId: nil, inReplyTo: nil,
            references: [], threadId: nil, subject: "Test", from: "Sender",
            fromAddress: "sender@test.com", to: "to@test.com", cc: "", bcc: "",
            replyTo: nil, date: Date(), snippet: "", isRead: false, isFlagged: false,
            hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil
        )
        #expect(info.userLabelIds.isEmpty)
    }

    @Test("MessageHeaderInfo carries user label IDs")
    func headerInfoWithLabels() {
        let info = MessageHeaderInfo(
            messageId: "msg1", rfc822MessageId: nil, inReplyTo: nil,
            references: [], threadId: nil, subject: "Test", from: "Sender",
            fromAddress: "sender@test.com", to: "to@test.com", cc: "", bcc: "",
            replyTo: nil, date: Date(), snippet: "", isRead: false, isFlagged: false,
            hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil,
            userLabelIds: ["Label_1", "Label_2"]
        )
        #expect(info.userLabelIds == ["Label_1", "Label_2"])
    }

    // MARK: - Backfill Label Insert

    @Test("Backfill inserts UserLabel and MessageUserLabel for messages with labels")
    func backfillLabelInsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Simulate what backfill does: insert header + labels in same transaction
        try db.write { db in
            let header = MessageHeader(
                messageId: "100", subject: "Test", from: "Sender",
                fromAddress: "sender@test.com", to: "to@test.com",
                date: Date(), snippet: "", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            try header.insert(db)

            let labelIds = ["Label_Work", "Label_Personal"]
            for labelId in labelIds {
                try UserLabel(accountId: "acc1", providerLabelId: labelId, name: labelId, isSystem: false)
                    .insert(db, onConflict: .ignore)
                try MessageUserLabel(messageId: header.id, userLabelId: "acc1:\(labelId)")
                    .insert(db, onConflict: .ignore)
            }
        }

        // Verify
        let labels = try db.read { db in
            try UserLabelStore.labelsForMessage("acc1:INBOX:100", in: db)
        }
        #expect(labels.count == 2)
        let names = Set(labels.map(\.name))
        #expect(names.contains("Label_Work"))
        #expect(names.contains("Label_Personal"))
    }

    @Test("Duplicate backfill insert is idempotent (INSERT OR IGNORE)")
    func backfillIdempotent() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)

        // Insert label twice
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false)
                .insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:L1")
                .insert(db, onConflict: .ignore)
        }
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false)
                .insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:L1")
                .insert(db, onConflict: .ignore)
        }

        let count = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(count == 1)
    }

    // MARK: - Optimistic UI Flow

    @Test("Apply label: inserts join row + queues PendingOperation")
    func applyLabelFlow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)

        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false).insert(db)
        }

        // Simulate applyUserLabel
        try db.write { db in
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:L1")
                .insert(db, onConflict: .ignore)
            let op = PendingOperation(
                type: .addUserLabel,
                messageIds: [header.stableId],
                accountId: header.accountId,
                folderPath: header.folderId,
                userLabelId: "L1"
            )
            try op.insert(db)
        }

        // Verify join row exists
        let joinCount = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(joinCount == 1)

        // Verify PendingOperation exists
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .addUserLabel)
        #expect(ops[0].userLabelId == "L1")
    }

    @Test("Remove label: deletes join row + queues PendingOperation")
    func removeLabelFlow() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)

        // Setup: label applied
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:L1").insert(db)
        }

        // Simulate removeUserLabel
        try db.write { db in
            try MessageUserLabel
                .filter(Column("messageId") == header.id && Column("userLabelId") == "acc1:L1")
                .deleteAll(db)
            let op = PendingOperation(
                type: .removeUserLabel,
                messageIds: [header.stableId],
                accountId: header.accountId,
                folderPath: header.folderId,
                userLabelId: "L1"
            )
            try op.insert(db)
        }

        // Verify join row gone
        let joinCount = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(joinCount == 0)

        // Verify PendingOperation exists
        let ops = try db.read { try PendingOperation.fetchAll($0) }
        #expect(ops.count == 1)
        #expect(ops[0].type == .removeUserLabel)
        #expect(ops[0].userLabelId == "L1")

        // UserLabel still exists (we never delete label definitions)
        let labelCount = try db.read { try UserLabel.fetchCount($0) }
        #expect(labelCount == 1)
    }

    // MARK: - MessageSnapshot with Labels

    @Test("MessageSnapshot carries userLabels from loadLabels")
    func snapshotWithLabels() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)

        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false).insert(db)
            try UserLabel(accountId: "acc1", providerLabelId: "L2", name: "Play", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:L1").insert(db)
            try MessageUserLabel(messageId: header.id, userLabelId: "acc1:L2").insert(db)
        }

        let snapshot = try db.read { db in
            let h = try MessageHeader.fetchOne(db, key: header.id)!
            let labels = try UserLabelStore.loadLabels(for: [h.id], in: db)
            return MessageSnapshot(from: h, userLabels: labels[h.id] ?? [])
        }

        #expect(snapshot.userLabels.count == 2)
        #expect(snapshot.userLabels[0].name == "Play") // Alphabetical
        #expect(snapshot.userLabels[1].name == "Work")
    }

    @Test("MessageSnapshot without labels has empty array")
    func snapshotWithoutLabels() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)

        let snapshot = try db.read { db in
            let h = try MessageHeader.fetchOne(db, key: header.id)!
            let labels = try UserLabelStore.loadLabels(for: [h.id], in: db)
            return MessageSnapshot(from: h, userLabels: labels[h.id] ?? [])
        }

        #expect(snapshot.userLabels.isEmpty)
    }

    // MARK: - Thread-Level Label Union

    @Test("Thread label union collects labels from all messages")
    func threadLabelUnion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "200")

        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false).insert(db)
            try UserLabel(accountId: "acc1", providerLabelId: "L2", name: "Personal", isSystem: false).insert(db)
            try MessageUserLabel(messageId: msg1.id, userLabelId: "acc1:L1").insert(db)
            try MessageUserLabel(messageId: msg2.id, userLabelId: "acc1:L2").insert(db)
        }

        // Load labels for both messages (simulating thread union)
        let allIds = [msg1.id, msg2.id]
        let labelsByMsg = try db.read { db in
            try UserLabelStore.loadLabels(for: allIds, in: db)
        }

        // Union: collect all labels, deduplicate by ID
        var seenIds: Set<String> = []
        var unionLabels: [UserLabel] = []
        for id in allIds {
            for label in labelsByMsg[id] ?? [] {
                if seenIds.insert(label.id).inserted {
                    unionLabels.append(label)
                }
            }
        }

        #expect(unionLabels.count == 2)
        let names = Set(unionLabels.map(\.name))
        #expect(names.contains("Work"))
        #expect(names.contains("Personal"))
    }

    @Test("Thread union deduplicates shared labels")
    func threadUnionDedup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let msg1 = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let msg2 = try TestDatabase.insertMessageHeader(db, messageId: "200")

        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work", isSystem: false).insert(db)
            // Both messages have the same label
            try MessageUserLabel(messageId: msg1.id, userLabelId: "acc1:L1").insert(db)
            try MessageUserLabel(messageId: msg2.id, userLabelId: "acc1:L1").insert(db)
        }

        let allIds = [msg1.id, msg2.id]
        let labelsByMsg = try db.read { db in
            try UserLabelStore.loadLabels(for: allIds, in: db)
        }

        var seenIds: Set<String> = []
        var unionLabels: [UserLabel] = []
        for id in allIds {
            for label in labelsByMsg[id] ?? [] {
                if seenIds.insert(label.id).inserted {
                    unionLabels.append(label)
                }
            }
        }

        #expect(unionLabels.count == 1) // Deduped
        #expect(unionLabels[0].name == "Work")
    }

    // MARK: - IMAP Keyword Extraction

    @Test("isExcludedKeyword rejects $Forwarded case-insensitively")
    func excludedCaseInsensitive() {
        #expect(UserLabelStore.isExcludedKeyword("$FORWARDED") == true)
        #expect(UserLabelStore.isExcludedKeyword("$forwarded") == true)
        #expect(UserLabelStore.isExcludedKeyword("$Forwarded") == true)
    }

    @Test("isExcludedKeyword allows non-standard custom keywords")
    func allowedCustomKeywords() {
        #expect(UserLabelStore.isExcludedKeyword("meeting") == false)
        #expect(UserLabelStore.isExcludedKeyword("urgent") == false)
        #expect(UserLabelStore.isExcludedKeyword("project_alpha") == false)
    }

    // MARK: - Reserved Name Validation for Creation

    @Test("isReservedName case-insensitive for all categories")
    func reservedCaseInsensitive() {
        #expect(UserLabelStore.isReservedName("TM_test") == true)
        #expect(UserLabelStore.isReservedName("\\SEEN") == true)
        #expect(UserLabelStore.isReservedName("inbox") == true)
        #expect(UserLabelStore.isReservedName("INBOX") == true)
        #expect(UserLabelStore.isReservedName("Category_Social") == true)
    }

    @Test("splitNestedLabelName returns empty array for empty string")
    func splitEmpty() {
        let segments = UserLabelStore.splitNestedLabelName("")
        #expect(segments.isEmpty)
    }

    // MARK: - Nested Label Display Segments

    @Test("UserLabelDisplaySegment expands nested label into segments")
    func expandNestedSegments() {
        let label = UserLabel(accountId: "acc1", providerLabelId: "Label_1", name: "Work/Projects/Alpha", isSystem: false)
        let segments = UserLabelDisplaySegment.expand([label])
        let names = segments.map(\.displayName)
        #expect(names == ["Alpha", "Projects", "Work"]) // Alphabetical
        // All segments point to the same parent label
        #expect(segments.allSatisfy { $0.parentLabel.id == "acc1:Label_1" })
    }

    @Test("UserLabelDisplaySegment deduplicates shared segments across labels")
    func expandDeduplicates() {
        let label1 = UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Work/Alpha", isSystem: false)
        let label2 = UserLabel(accountId: "acc1", providerLabelId: "L2", name: "Work/Beta", isSystem: false)
        let segments = UserLabelDisplaySegment.expand([label1, label2])
        let names = segments.map(\.displayName)
        #expect(names == ["Alpha", "Beta", "Work"]) // "Work" appears once, not twice
    }

    @Test("UserLabelDisplaySegment handles non-nested labels")
    func expandNonNested() {
        let label = UserLabel(accountId: "acc1", providerLabelId: "L1", name: "Simple", isSystem: false)
        let segments = UserLabelDisplaySegment.expand([label])
        #expect(segments.count == 1)
        #expect(segments[0].displayName == "Simple")
    }
}
